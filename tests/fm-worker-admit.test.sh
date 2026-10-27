#!/usr/bin/env bash
# Deferred replay through the public record and parking tick interfaces.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
command -v tasks-axi >/dev/null || { printf 'ok - skipped: tasks-axi unavailable\n'; exit 0; }
ADMIT_TEST_ROOT=$(fm_test_tmproot fm-worker-admit)
export ADMIT_TEST_ROOT ROOT
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
SCRATCH = Path(os.environ['ADMIT_TEST_ROOT'])


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
if (h/'full').exists(): sys.exit(75)
subprocess.run(['python3', str(h/'bin/fm-worker-admit.py'), 'verify', ident, os.environ['FM_WORKER_AUTO_ADMIT_DIGEST']], check=True)
ticket=args[args.index('--ticket')+1] if '--ticket' in args else ''
if ticket and ticket != 'no-ticket':
 result=subprocess.run(['bash', str(h/'bin/fm-work-intake.sh'), 'admission-check', ticket])
 if result.returncode: sys.exit(result.returncode)
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

    def add(self, ident, priority=2, ticket='no-ticket'):
        self.tasks('add', ident, ident, '--kind', 'ship', '--queue', '--priority', str(priority))
        directory = self.home / 'data' / ident
        directory.mkdir()
        (directory / 'brief.md').write_text("# Task\n## Captain's intent\nImplement accepted work.\n## Firstmate spec\nUse recorded flags.\n")
        args = [str(self.home / 'project'), 'direct-PR', 'off', ticket, 'feat', 'fm/',
                'release/test', 'codex', 'model/accepted', 'high', 'tmux', '', 'partial', '0', '0']
        self.command('python3', str(self.home / 'bin/fm-worker-admit.py'), 'record', ident, *args)
        return self.home / 'state' / (ident + '.deferred-spawn.json')

    def tick(self):
        return self.command('bash', str(self.home / 'bin/fm-worker-park.sh'), 'tick')

    def launches(self):
        path = self.home / 'launches'
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def test_freed_slot_replays_exact_flags_once(self):
        record = self.add('next')
        (self.home / 'full').touch()
        self.tick()
        self.assertEqual(self.launches(), [])
        self.assertTrue(record.exists())
        (self.home / 'full').unlink()
        self.tick()
        self.assertEqual(self.launches(), [['next', str(self.home / 'project'), '--mode', 'direct-PR',
            '--yolo', 'off', '--base-branch', 'release/test', '--harness', 'codex', '--model',
            'model/accepted', '--effort', 'high', '--backend', 'tmux', '--ticket', 'no-ticket',
            '--commit-type', 'feat', '--ticket-scope', 'partial']])
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
        self.tick()
        self.assertEqual([args[0] for args in self.launches()], ['eligible'])
        audit = [json.loads(line) for line in (self.home / 'state/worker-admission.jsonl').read_text().splitlines()]
        skipped = {row['task'] for row in audit if row['result'] == 'skipped'}
        self.assertTrue({'held', 'blocked', 'future', 'incomplete', 'changed', 'missing'} <= skipped)

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
        self.assertIn('--branch-prefix', self.launches()[0])
        self.assertIn('accepted/', self.launches()[0])

    def test_andrew_owned_and_created_unassigned_are_excluded(self):
        for exclusion in ('andrew_owned', 'andrew_created_unassigned'):
            with self.subTest(exclusion=exclusion):
                path = self.add(exclusion, ticket='ENG-1')
                fixture = deepcopy(json.loads((ROOT / 'tests/fixtures/clickup-queue-v1.json').read_text()))
                row = fixture['candidates'][0]
                row['eligibility'].update(eligible=False, exclusion_reasons=[exclusion])
                row['scope']['comments_complete'] = True
                (self.home / 'source.json').write_text(json.dumps(fixture))
                hook = self.home / 'source'
                hook.write_text('''#!/usr/bin/env python3
from datetime import datetime, timezone
import json, pathlib, sys
v=json.loads((pathlib.Path(__file__).parent/'source.json').read_text())
v['observed_at']=datetime.now(timezone.utc).isoformat()
if '--refresh' in sys.argv:
 v['mode']='refresh'; v['coverage'].update(complete=False,all_pages_read=False,absence_means_withdrawal=False)
print(json.dumps(v))
''')
                hook.chmod(0o755)
                (self.home / 'config/work-intake-hook').write_text(str(hook))
                self.tick()
                self.assertTrue(path.exists())
                self.assertEqual(self.launches(), [])


unittest.main(verbosity=2)
PY
