#!/usr/bin/env bash
# Deferred replay through the public record and parking tick interfaces.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
command -v tasks-axi >/dev/null || { printf 'ok - skipped: tasks-axi unavailable\n'; exit 0; }
ADMIT_TEST_ROOT=$(fm_test_tmproot fm-worker-admit)
export ADMIT_TEST_ROOT ROOT
python3 - <<'PY'
import json
import os
from pathlib import Path
import shutil
import subprocess
import unittest

ROOT = Path(os.environ['ROOT'])
SCRATCH = Path(os.environ['ADMIT_TEST_ROOT'])


AWAY_CAP_ONE = """version: 1
entered: 2026-09-20T01:00:00Z
entered_epoch: 1789600000
expected_return: 2026-09-20T09:00:00Z
reach_channels: none
reach_announced: No phone channel is configured; anything that needs you waits for your return.
spend_max_concurrent_workers: 1
merge_grants:
confirmed: 2026-09-20T01:00:05Z
confirmed_epoch: 1789600005
words: |-
  work the queue overnight
"""


class AdmissionTests(unittest.TestCase):
    def setUp(self):
        self.home = SCRATCH / self._testMethodName
        for directory in ('bin', 'state', 'config', 'data', 'project'):
            (self.home / directory).mkdir(parents=True)
        for path in (ROOT / 'bin').iterdir():
            (self.home / 'bin' / path.name).symlink_to(path)
        for name in ('fm-worker-admit.py', 'fm-work-intake.py'):
            path = self.home / 'bin' / name
            path.unlink()
            shutil.copy(ROOT / 'bin' / name, path)
        spawn = self.home / 'bin/fm-spawn.sh'
        spawn.unlink()
        spawn.write_text('''#!/usr/bin/env bash
exec python3 - "$@" <<'PY_SPAWN'
import json, os, pathlib, subprocess, sys, time
h=pathlib.Path(os.environ['FM_HOME']); args=sys.argv[1:]; ident=args[0]
with (h/'attempts').open('a') as f: f.write(ident+'\\n')
if (h/'real').exists(): os.execvp('bash', ['bash', os.path.join(os.path.dirname(os.path.realpath(h/'bin/fm-tasks-axi.sh')), 'fm-spawn.sh'), *args])
if (h/'seat-held').exists() and args[args.index('--harness')+1] == (h/'seat-held').read_text(): print('deferred: harness '+args[args.index('--harness')+1]+' has no seat room'); sys.exit(75)
if (h/'full').exists(): print((h/'full').read_text()); sys.exit(75)
if (h/'refuse').exists(): print('error: refused by fixture'); sys.exit(1)
subprocess.run(['python3', str(h/'bin/fm-worker-admit.py'), 'verify', ident, os.environ['FM_WORKER_AUTO_ADMIT_DIGEST']], check=True)
with (h/'launches').open('a') as f: f.write(json.dumps(args)+'\\n')
time.sleep(.1)
(h/'state'/f'{ident}.meta').write_text('kind=ship\\n')
subprocess.run(['bash', str(h/'bin/fm-tasks-axi.sh'), 'start', ident], check=True, stdout=subprocess.DEVNULL)
if (h/'one-slot').exists(): (h/'full').touch()
PY_SPAWN
''')
        spawn.chmod(0o755)
        self.env = dict(os.environ, FM_HOME=str(self.home), FM_DATA_OVERRIDE=str(self.home / 'data'),
                        FM_STATE_OVERRIDE=str(self.home / 'state'), FM_CONFIG_OVERRIDE=str(self.home / 'config'),
                        FM_SPAWN_NO_GUARD='1', FM_TEST_SEAM='1')
        self.env.pop('FM_TASK_ID', None)
        self.env.pop('TASKS_AXI_FILE', None)
        self.env.pop('TASKS_AXI_BACKEND', None)
        (self.home / '.tasks.toml').write_text('backend="markdown"\n[markdown]\npath="data/backlog.md"\n')
        (self.home / 'data/backlog.md').write_text('## In flight\n\n## Queued\n\n## Done\n')

    def command(self, *args, ok=True):
        result = subprocess.run(args, env=self.env, text=True, capture_output=True, timeout=30)
        if ok:
            self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        return result

    def tasks(self, *args):
        return self.command('bash', str(self.home / 'bin/fm-tasks-axi.sh'), *args)

    def add(self, ident, priority=2, ticket='no-ticket', project=None, harness='codex'):
        self.tasks('add', ident, ident, '--kind', 'ship', '--queue', '--priority', str(priority))
        directory = self.home / 'data' / ident
        directory.mkdir()
        (directory / 'brief.md').write_text("# Task\n## Captain's intent\nImplement accepted work.\n## Firstmate spec\nUse recorded flags.\n")
        return self.add_record(ident, ticket, project, harness)

    def add_record(self, ident, ticket='no-ticket', project=None, harness='codex'):
        args = [str(project or self.home / 'project'), 'direct-PR', 'off', ticket, 'feat', 'fm/',
                'release/test', harness, 'model/accepted', 'high', 'tmux', '', 'partial', '0', '0']
        self.command('python3', str(self.home / 'bin/fm-worker-admit.py'), 'record', ident, *args)
        return self.home / 'state' / (ident + '.deferred-spawn.json')

    def tick(self):
        return self.command('bash', str(self.home / 'bin/fm-worker-park.sh'), 'tick')

    def attempts(self):
        path = self.home / 'attempts'
        return path.read_text().split() if path.exists() else []

    def audit(self):
        path = self.home / 'state/worker-admission.jsonl'
        return [json.loads(line)['result'] for line in path.read_text().splitlines()]

    def expire_backoff(self, path):
        value = json.loads(path.read_text())
        value['retry_after'] = 0
        path.write_text(json.dumps(value))

    def launches(self):
        path = self.home / 'launches'
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def test_freed_slot_replays_exact_flags_once(self):
        record = self.add('next')
        (self.home / 'full').touch()
        self.tick()
        self.assertEqual(self.launches(), [])
        self.assertTrue(record.exists())
        self.tick()
        audit = (self.home / 'state/worker-admission.jsonl').read_text().splitlines()
        self.assertEqual([json.loads(line)['result'] for line in audit], ['deferred'])
        (self.home / 'full').unlink()
        self.tick()
        self.assertEqual(self.launches(), [['next', str(self.home / 'project'), '--mode', 'direct-PR',
            '--yolo', 'off', '--base-branch', 'release/test', '--harness', 'codex', '--model',
            'model/accepted', '--effort', 'high', '--backend', 'tmux', '--ticket', 'no-ticket',
            '--commit-type', 'feat']])
        self.assertFalse(record.exists())
        self.tick()
        self.assertEqual(len(self.launches()), 1)
        self.assertIn('admitted', (self.home / 'state/worker-admission.jsonl').read_text())

    def test_hold_dependency_future_incomplete_and_changed_brief_skip(self):
        self.add('held', 0)
        self.tasks('hold', 'held', '--kind', 'captain', '--reason', 'decision pending')
        self.add('blocked', 0)
        self.tasks('block', 'blocked', '--by', 'held')
        self.add('future', 0)
        self.tasks('hold', 'future', '--kind', 'future', '--reason', 'later', '--until', '2099-01-01')
        path = self.add('incomplete', 0)
        path.write_text('{}')
        self.add('changed', 0)
        (self.home / 'data/changed/brief.md').write_text('New unreviewed work')
        path = self.add('missing', 0)
        path.unlink()
        self.add('eligible', 4)
        audit_path = self.home / 'state/worker-admission.jsonl'
        audit_path.unlink()
        self.tick()
        self.tick()
        self.assertEqual([args[0] for args in self.launches()], ['eligible'])
        audit = [json.loads(line) for line in audit_path.read_text().splitlines()]
        self.assertEqual(sorted((row['task'], row['result']) for row in audit),
                         [('changed', 'skipped'), ('eligible', 'admitted'), ('incomplete', 'skipped')])
        for ident in ('held', 'blocked', 'future'):
            self.assertTrue((self.home / 'state' / (ident + '.deferred-spawn.json')).exists())
        for ident in ('incomplete', 'changed'):
            self.assertFalse((self.home / 'state' / (ident + '.deferred-spawn.json')).exists())

    def test_priority_age_and_concurrent_frees_admit_once(self):
        self.add('old-normal', 2)
        self.add('first-urgent', 0)
        self.add('second-urgent', 0)
        (self.home / 'one-slot').touch()
        command = ['bash', str(self.home / 'bin/fm-worker-park.sh'), 'tick']
        running = [subprocess.Popen(command, env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE) for _ in range(2)]
        for process in running:
            out, err = process.communicate(timeout=30)
            self.assertEqual(process.returncode, 0, (out, err))
        self.assertEqual([args[0] for args in self.launches()], ['first-urgent'])
        (self.home / 'full').unlink()
        self.tick()
        self.assertEqual([args[0] for args in self.launches()], ['first-urgent', 'second-urgent'])

    def test_branch_prefix_and_existing_metadata_prevent_replay(self):
        path = self.add('existing')
        (self.home / 'state/existing.meta').write_text('kind=ship\n')
        self.add('branch')
        path = self.home / 'state/branch.deferred-spawn.json'
        value = json.loads(path.read_text())
        value.update(ticket='', commit_type='', branch_prefix='accepted/')
        path.write_text(json.dumps(value))
        self.tick()
        self.assertEqual([args[0] for args in self.launches()], ['branch'])
        self.assertFalse((self.home / 'state/existing.deferred-spawn.json').exists())
        self.assertIn('--branch-prefix', self.launches()[0])
        self.assertIn('accepted/', self.launches()[0])

    def test_fleet_deferral_ends_the_tick_and_project_deferral_skips_its_project(self):
        (self.home / 'other').mkdir()
        self.add('first', 0)
        self.add('same-project', 1)
        self.add('other-project', 2, project=self.home / 'other')
        (self.home / 'full').write_text('deferred: project project admits 1 worker(s) at once')
        self.tick()
        self.assertEqual(self.attempts(), ['first', 'other-project'])
        (self.home / 'full').write_text('deferred: this machine runs at most 1 agent(s)')
        self.tick()
        self.assertEqual(self.attempts(), ['first', 'other-project', 'first'])
        self.assertEqual(self.audit(), ['deferred'] * 3)

    def test_away_spend_cap_ends_the_tick_without_counting_refusals(self):
        for ident in ('first', 'second', 'third'):
            self.add(ident)
        (self.home / 'state/.afk-contract').write_text(AWAY_CAP_ONE)
        (self.home / 'state/live.meta').write_text('kind=ship\n')
        (self.home / 'real').touch()
        self.tick()
        self.tick()
        self.assertEqual(self.attempts(), ['first', 'first'])
        self.assertEqual(self.audit(), ['deferred'] * 3)
        self.assertEqual(self.launches(), [])

    def test_seat_hold_skips_its_harness_without_starving_another(self):
        self.add('claude-first', 0, harness='claude')
        self.add('claude-second', 1, harness='claude')
        self.add('codex-next', 2)
        (self.home / 'seat-held').write_text('claude')
        self.tick()
        self.assertEqual(self.attempts(), ['claude-first', 'codex-next'])
        self.assertEqual([args[0] for args in self.launches()], ['codex-next'])
        self.assertTrue((self.home / 'state/claude-second.deferred-spawn.json').exists())

    def test_refusals_back_off_then_quarantine_once_until_explicit_dispatch(self):
        path = self.add('refused')
        (self.home / 'refuse').touch()
        self.tick()
        self.tick()
        self.assertEqual(self.attempts(), ['refused'])
        self.expire_backoff(path)
        self.tick()
        self.expire_backoff(path)
        self.tick()
        self.assertEqual(self.attempts(), ['refused'] * 3)
        self.assertEqual(self.audit(), ['deferred', 'refused', 'refused', 'quarantined'])
        status = (self.home / 'state/refused.status').read_text().splitlines()
        self.assertEqual(len(status), 1)
        self.assertRegex(status[0], r'^blocked \[at=\d+\]: .*quarantined.*refused by fixture')
        self.expire_backoff(path)
        (self.home / 'refuse').unlink()
        self.tick()
        self.tick()
        self.assertEqual(len(self.attempts()), 3)
        self.assertEqual(len((self.home / 'state/refused.status').read_text().splitlines()), 1)
        self.assertTrue(path.exists())
        self.add_record('refused')
        self.tick()
        self.assertEqual([args[0] for args in self.launches()], ['refused'])
        self.assertFalse(path.exists())

    def test_capacity_deferrals_keep_retrying_without_counting_as_refusals(self):
        path = self.add('waiting')
        (self.home / 'full').touch()
        for _ in range(5):
            self.tick()
        self.assertEqual(self.attempts(), ['waiting'] * 5)
        self.assertEqual(self.audit(), ['deferred'])
        self.assertNotIn('refusals', json.loads(path.read_text()))
        (self.home / 'full').unlink()
        self.tick()
        self.assertEqual([args[0] for args in self.launches()], ['waiting'])

    def test_records_for_removed_done_or_non_ship_rows_are_discarded(self):
        paths = {ident: self.add(ident) for ident in ('removed', 'closed', 'scouted', 'kept')}
        self.tasks('rm', 'removed')
        self.tasks('done', 'closed')
        self.tasks('update', 'scouted', '--kind', 'scout')
        self.tasks('hold', 'kept', '--kind', 'captain', '--reason', 'decision pending')
        self.tick()
        self.assertEqual(self.attempts(), [])
        for ident in ('removed', 'closed', 'scouted'):
            self.assertFalse(paths[ident].exists(), ident)
        self.assertTrue(paths['kept'].exists())
        self.assertEqual(self.audit(), ['deferred'] * 4 + ['skipped'] * 3)


unittest.main(verbosity=2)
PY
