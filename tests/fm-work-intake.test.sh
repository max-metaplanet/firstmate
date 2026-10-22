#!/usr/bin/env bash
# Public-interface receipt, recovery, ownership and preflight behavior with a fake
# GET-only ClickUp producer and the real tasks-axi queue. No live source calls.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
command -v tasks-axi >/dev/null || { printf 'ok - skipped: tasks-axi unavailable\n'; exit 0; }
INTAKE_TEST_ROOT=$(fm_test_tmproot fm-work-intake)
export INTAKE_TEST_ROOT ROOT
python3 - <<'PY'
from copy import deepcopy
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import shutil
import subprocess
import unittest

ROOT = Path(os.environ['ROOT'])
SCRATCH = Path(os.environ['INTAKE_TEST_ROOT'])
BASE = json.loads((ROOT / 'tests/fixtures/clickup-queue-v1.json').read_text())
REAL_TASKS = shutil.which('tasks-axi')


class IntakeTests(unittest.TestCase):
    def setUp(self):
        self.home = SCRATCH / self._testMethodName
        for name in ('state', 'config', 'data', 'fakebin'):
            (self.home / name).mkdir(parents=True)
        (self.home / '.tasks.toml').write_text('backend="markdown"\n[markdown]\npath="data/backlog.md"\narchive="data/retired.md"\ndone_keep=0\n')
        (self.home / 'data/backlog.md').write_text('## In flight\n\n## Queued\n\n## Done\n')
        self.fixture = self.home / 'source.json'
        self.snapshot = deepcopy(BASE)
        self.save()
        self.hook = self.home / 'source'
        self.hook.write_text('''#!/usr/bin/env python3
import json, pathlib, sys
from datetime import datetime, timezone
p=pathlib.Path(__file__).parent
with (p/'calls').open('a') as stream: stream.write('GET ' + repr(sys.argv[1:]) + '\\n')
v=json.loads((p/'source.json').read_text())
if v.get('fail'): sys.exit(1)
v['observed_at']=datetime.now(timezone.utc).isoformat()
if '--refresh' in sys.argv:
 ref=sys.argv[sys.argv.index('--refresh')+1]
 v['mode']='refresh'
 v['candidates']=[r for r in v['candidates'] if r['source_ref']==ref]
 v['coverage'].update(complete=False,all_pages_read=False,absence_means_withdrawal=False)
 for r in v['candidates']:
  r['source_revision']=r.get('full_revision',r['source_revision']+'-full')
  r['scope']['comments_complete']=True
  r['scope']['comments']=r['scope'].get('full_comments',[])
v['coverage']['task_count']=len(v['candidates'])
for r in v['candidates']: r['observed_at']=v['observed_at']
print(json.dumps(v))
''')
        self.hook.chmod(0o755)
        (self.home / 'config/work-intake-hook').write_text(str(self.hook) + '\n')
        self.env = {**os.environ, 'FM_HOME': str(self.home), 'FM_DATA_OVERRIDE': str(self.home / 'data'),
                    'FM_STATE_OVERRIDE': str(self.home / 'state'), 'FM_CONFIG_OVERRIDE': str(self.home / 'config'),
                    'FM_TEST_SEAM': '1'}
        self.env.pop('TASKS_AXI_FILE', None)
        self.env.pop('TASKS_AXI_BACKEND', None)
        self.env.pop('FM_TASK_ID', None)

    def save(self):
        self.fixture.write_text(json.dumps(self.snapshot))

    def activate(self):
        (self.home / 'config/work-intake-enabled').write_text('1\n')

    def call(self, *args, ok=True, env=None):
        result = subprocess.run(['bash', str(ROOT / 'bin/fm-work-intake.sh'), *args, '--json'],
                                env=env or self.env, text=True, capture_output=True, timeout=80)
        if ok:
            self.assertEqual(result.returncode, 0, result.stderr)
            return json.loads(result.stdout)
        self.assertNotEqual(result.returncode, 0, result.stdout)
        return result

    def tasks(self, *args, home=None):
        env = {**self.env, 'FM_HOME': str(home or self.home), 'FM_DATA_OVERRIDE': str((home or self.home) / 'data')}
        result = subprocess.run(['bash', str(ROOT / 'bin/fm-tasks-axi.sh'), *args], env=env,
                                text=True, capture_output=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout

    def receipt(self):
        return json.loads((self.home / 'state/work-intake.json').read_text())

    def expire(self):
        path = self.home / 'state/work-intake.json'
        state = json.loads(path.read_text())
        state['next_poll'] = 0
        path.write_text(json.dumps(state))

    def imported(self):
        self.activate()
        result = self.call('poll')
        return result['imported'][0]

    def review(self, ident, **extra):
        fresh = self.call('refresh', ident)
        decision = dict(source_revision=fresh['candidate']['source_revision'], authorized=True,
                        identity_checked=True, project='fixture-project', kind='ship', reason='accepted scope and duplicate reconciliation checked')
        decision.update(extra)
        path = self.home / 'decision.json'
        path.write_text(json.dumps(decision))
        return self.call('review', ident, '--decision-file', str(path))

    def test_default_disabled_and_preview_are_read_only(self):
        self.assertEqual(self.call('poll')['result'], 'disabled')
        before = (self.home / 'data/backlog.md').read_bytes()
        result = self.call('preview')
        self.assertEqual(len(result['would_import']), 1)
        self.assertEqual((self.home / 'data/backlog.md').read_bytes(), before)
        self.assertFalse((self.home / 'state/work-intake.json').exists())
        self.assertFalse(list((self.home / 'state').iterdir()))

    def test_live_snapshot_ownership_gap_and_proposals_never_widen(self):
        rows = []
        for number in range(18):
            row = deepcopy(BASE['candidates'][0])
            row.update(source_ref='other-'+str(number), ticket='ENG-'+str(number))
            row['eligibility'].update(eligible=False, exclusion_reasons=['other_owner'])
            row['source_evidence']['ownership']='other'
            rows.append(row)
        for name, reason, proposal in [('deferred', 'backlog_proposal_only', 'backlog_promotion'),
                                       ('unassigned', 'unassigned', 'assignment'),
                                       ('requests', 'outside_active_list', None)]:
            row=deepcopy(BASE['candidates'][0]); row.update(source_ref=name, ticket=name)
            row['eligibility'].update(eligible=False, exclusion_reasons=[reason], proposal=proposal)
            if name=='deferred': row['scope']['description']='Not now. EGM December 18.'
            rows.append(row)
        self.snapshot['candidates']=rows
        self.snapshot['report'].update(ownership_coverage_gap=True,eligible_count=0,up_next_count=18)
        self.save()
        preview=self.call('preview')
        self.assertEqual(preview['eligible_count'],0)
        self.assertTrue(preview['ownership_coverage_gap'])
        self.assertEqual(preview['would_import'],[])
        self.assertEqual(len(preview['excluded']),21)
        self.assertEqual(len(preview['backlog_proposals']),1)
        self.assertIsNone(preview['backlog_proposals'][0]['dates']['hard_deadline'])
        self.activate(); self.assertEqual(self.call('poll')['imported'],[])
        self.assertEqual(self.receipt()['entries'],{})

    def test_repeat_concurrent_scan_and_restart_import_exactly_once(self):
        self.activate()
        commands=[['bash',str(ROOT/'bin/fm-work-intake.sh'),'poll','--json'] for _ in range(2)]
        processes=[subprocess.Popen(c,env=self.env,text=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE) for c in commands]
        results=[]
        for process in processes:
            out,err=process.communicate(timeout=80);self.assertEqual(process.returncode,0,err);results.append(json.loads(out))
        self.assertEqual(sum(len(r.get('imported',[])) for r in results),1)
        ident=next(iter(self.receipt()['entries'].values()))['local_id']
        self.assertIn('state: queued', self.tasks('show',ident))
        self.expire();self.assertEqual(self.call('poll')['imported'],[])
        self.assertEqual(len(self.receipt()['entries']),1)
        self.assertIn('count: 1',self.tasks('list'))
        self.assertFalse(list((self.home/'state').glob('*.meta')))

    def test_crash_after_row_creation_recovers_planned_identity(self):
        fake=self.home/'fakebin/tasks-axi'
        fake.write_text('''#!/bin/bash
"$INTAKE_REAL_TASKS" "$@"
rc=$?
if [ "$rc" = 0 ] && [ "${1:-}" = add ] && [ "${INTAKE_KILL_AFTER_ADD:-}" = 1 ]; then kill -KILL "$PPID"; fi
exit "$rc"
''');fake.chmod(0o755)
        env={**self.env,'PATH':str(fake.parent)+os.pathsep+self.env['PATH'],
             'INTAKE_REAL_TASKS':REAL_TASKS,'INTAKE_KILL_AFTER_ADD':'1'}
        self.activate(); self.call('poll',ok=False,env=env)
        planned=next(iter(self.receipt()['entries'].values()))
        self.assertEqual(planned['phase'],'planned')
        self.assertIn('count: 1',self.tasks('list'))
        self.call('poll')
        finished=next(iter(self.receipt()['entries'].values()))
        self.assertEqual(finished['local_id'],planned['local_id'])
        self.assertEqual(finished['phase'],'imported')
        self.assertIn('count: 1',self.tasks('list'))

    def test_existing_queued_live_archive_and_split_scope_do_not_duplicate(self):
        for kind in ('queued','live','archive','split'):
            with self.subTest(kind=kind):
                home=self.home/kind
                for name in ('data','config','state'): (home/name).mkdir(parents=True)
                (home/'.tasks.toml').write_text((self.home/'.tasks.toml').read_text())
                (home/'data/backlog.md').write_text('## In flight\n\n## Queued\n\n## Done\n')
                env={**self.env,'FM_HOME':str(home),'FM_DATA_OVERRIDE':str(home/'data'),
                     'FM_STATE_OVERRIDE':str(home/'state'),'FM_CONFIG_OVERRIDE':str(home/'config')}
                (home/'config/work-intake-enabled').write_text('1')
                (home/'config/work-intake-hook').write_text(str(self.hook))
                def task(*args):
                    r=subprocess.run(['bash',str(ROOT/'bin/fm-tasks-axi.sh'),*args],env=env,capture_output=True,text=True)
                    self.assertEqual(r.returncode,0,r.stderr);return r.stdout
                task('add','existing','Existing','--body','Ticket: ENG-1')
                if kind=='live': task('start','existing')
                if kind=='archive': task('done','existing');self.assertIn('count: 0',task('list'))
                if kind=='split':task('add','split','Separate accepted scope','--body','Ticket URL: https://app.clickup.com/t/fixture-one')
                out=self.call('poll',env=env)
                self.assertEqual(out['imported'],[])
                state=json.loads((home/'state/work-intake.json').read_text())
                entry=state['entries']['opaque-fixture-one']
                self.assertEqual(entry['phase'],'conflict' if kind=='split' else 'imported')
                self.assertNotIn('intake-',task('list'))

    def test_registered_secondmate_owner_is_preserved(self):
        other=self.home/'mate'
        for name in ('data','config','state'): (other/name).mkdir(parents=True)
        (other/'.tasks.toml').write_text((self.home/'.tasks.toml').read_text())
        (other/'data/backlog.md').write_text('## In flight\n\n## Queued\n\n## Done\n')
        self.tasks('add','mate-task','Accepted elsewhere','--body','Ticket: ENG-1',home=other)
        (self.home/'data/secondmates.md').write_text(f'- mate - Test domain (home: {other}; scope: test; projects: test; added 2026-10-22)\n')
        self.activate();self.assertEqual(self.call('poll')['imported'],[])
        entry=self.receipt()['entries']['opaque-fixture-one']
        self.assertEqual(entry['owner_home'],str(other))
        self.assertIn('count: 0',self.tasks('list'))
        self.call('check','mate-task',ok=False)

    def test_authority_holds_future_and_blockers_override_urgency(self):
        self.snapshot['candidates'][0]['priority'].update(value='urgent',rank=1)
        self.snapshot['candidates'][0]['scope']['description']='EGM tomorrow. Not now.'
        self.save();ident=self.imported()
        self.call('check',ident,ok=False)
        self.review(ident,authorized=False)
        self.call('check',ident,ok=False)
        self.review(ident,deferred=True)
        self.call('check',ident,ok=False)
        self.review(ident,blocked=True)
        self.call('check',ident,ok=False)
        self.review(ident)
        self.assertEqual(self.call('check',ident)['result'],'cleared')
        for kind in ('captain','future','external'):
            self.tasks('hold',ident,'--kind',kind,'--reason','unrelated owner decision')
            self.call('check',ident,ok=False)
            self.assertIn('unrelated owner decision',self.tasks('show',ident))
            self.tasks('unhold',ident)
        self.tasks('add','prerequisite','Unfinished prerequisite')
        self.tasks('block',ident,'--by','prerequisite')
        self.call('check',ident,ok=False)

    def test_full_refresh_detects_scope_changes_with_unchanged_scan_revision(self):
        ident=self.imported();self.review(ident)
        self.snapshot['candidates'][0]['full_revision']='changed-comment'
        self.snapshot['candidates'][0]['scope']['full_comments']=[{'text':'Acceptance criteria changed'}]
        self.save();self.call('check',ident,ok=False)
        self.assertNotIn('review',self.receipt()['entries']['opaque-fixture-one'])
        self.assertEqual(self.call('refresh',ident)['candidate']['scope']['comments'][0]['text'],'Acceptance criteria changed')

    def test_withdrawal_reassignment_invalid_state_and_partial_scan_are_conservative(self):
        ident=self.imported();self.review(ident)
        for reason in ('other_owner','invalid_status','blocked_tags','outside_active_list'):
            self.snapshot['candidates'][0]['eligibility'].update(eligible=False,exclusion_reasons=[reason])
            self.save();self.call('check',ident,ok=False)
            self.assertIn('state: queued',self.tasks('show',ident))
        self.snapshot['candidates'][0]['eligibility'].update(eligible=True,exclusion_reasons=[])
        self.save();self.review(ident)
        self.snapshot['candidates']=[];self.snapshot['coverage']['complete']=False;self.save();self.expire()
        self.call('poll',ok=False)
        self.assertTrue(self.receipt()['entries']['opaque-fixture-one']['present'])
        self.snapshot['coverage']['complete']=True;self.save();self.expire();self.call('poll')
        self.assertFalse(self.receipt()['entries']['opaque-fixture-one']['present'])
        self.assertIn('Ticket: ENG-1',self.tasks('show',ident,'--full'))
        self.assertNotIn('state: done',self.tasks('show',ident))

    def test_outage_retains_receipts_and_independent_work_remains_dispatchable(self):
        ident=self.imported();self.review(ident)
        self.snapshot['fail']=True;self.save();self.expire()
        self.call('poll',ok=False);state=self.receipt()
        self.assertTrue(state['source_error'])
        calls=(self.home/'calls').read_text()
        self.assertEqual(self.call('poll')['result'],'cached')
        self.assertEqual((self.home/'calls').read_text(),calls)
        self.call('check',ident,ok=False)
        self.assertEqual(self.call('check','independent')['result'],'independent')
        self.assertEqual(len(state['entries']),1)

    def test_terminal_tombstone_does_not_reimport_a_reopened_source(self):
        ident=self.imported();self.review(ident)
        self.tasks('done',ident)
        self.assertIn('count: 0',self.tasks('list'))
        self.expire();self.assertEqual(self.call('poll')['imported'],[])
        self.call('check',ident,ok=False)
        self.assertIn('count: 0',self.tasks('list'))
        self.assertEqual(len(self.receipt()['entries']),1)

    def test_source_changes_preserve_local_notes_and_priority(self):
        ident=self.imported()
        self.tasks('update',ident,'--body','Ticket: ENG-1\nConsidered local instructions','--priority','0')
        self.snapshot['candidates'][0]['source_revision']='scan-two'
        self.snapshot['candidates'][0]['scope']['description']='New remote body'
        self.save();self.expire();self.call('poll')
        shown=self.tasks('show',ident,'--full')
        self.assertIn('Considered local instructions',shown)
        self.assertNotIn('New remote body',shown)
        self.assertIn('priority: 0',shown)

    def test_review_revision_binding_and_ranking_preserve_explicit_order(self):
        rows=[]
        for number, priority in [(1,1),(2,4)]:
            row=deepcopy(BASE['candidates'][0])
            row.update(source_ref=f'opaque-{number}',ticket=f'ENG-{number}',title=f'Task {number}',url=f'https://app.clickup.com/t/fixture-{number}')
            row['priority']['rank']=priority
            rows.append(row)
        self.snapshot['candidates']=rows;self.save();self.activate();self.call('poll')
        entries=self.receipt()['entries'];first=entries['opaque-1']['local_id'];second=entries['opaque-2']['local_id']
        self.review(first);self.review(second,captain_order=0)
        ranked=self.call('status')['ranked']
        self.assertEqual([r['local_id'] for r in ranked],[second,first])
        self.assertTrue(all(r['runnable'] for r in ranked))
        self.snapshot['candidates'][1]['full_revision']='changed-after-reading';self.save()
        path=self.home/'decision.json'
        self.call('review',second,'--decision-file',str(path),ok=False)
        self.assertFalse(self.call('status')['ranked'][-1]['runnable'])

    def test_invalid_snapshot_and_namespace_change_preserve_identity(self):
        ident=self.imported()
        original=self.receipt()['entries']
        for field,value in [('version',2),('schema','unknown')]:
            self.snapshot[field]=value;self.save();self.expire();self.call('poll',ok=False)
            self.assertEqual(self.receipt()['entries'],original)
            self.snapshot[field]=BASE[field]
        self.snapshot['source_namespace']='different-owner';self.save();self.expire()
        self.call('poll',ok=False);self.call('check',ident,ok=False)
        self.assertEqual(self.receipt()['entries'],original)

    def test_remote_ownership_and_manual_backends_fail_closed(self):
        (self.home/'data/secondmates.md').write_text('- remote - Test (host: remote.example; root: /repo; home: /home; scope: test; projects: test; added 2026-10-22)\n')
        self.activate();result=self.call('poll')
        self.assertEqual(result['imported'],[])
        self.assertIn('remote_ownership_reconciliation_required',result['excluded'][0]['reasons'])
        (self.home/'config/backlog-backend').write_text('manual')
        self.call('poll',ok=False)
        self.assertIn('count: 0',self.tasks('list'))

    def test_incidental_ticket_mentions_are_not_duplicate_identity(self):
        self.tasks('add','other','Other work','--body','Related discussion mentions ENG-1 incidentally.')
        ident=self.imported()
        self.assertNotEqual(ident,'other')
        self.assertIn('count: 2',self.tasks('list'))


unittest.main(verbosity=2)
PY
