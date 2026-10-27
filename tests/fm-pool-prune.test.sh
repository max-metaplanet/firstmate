#!/usr/bin/env bash
# Public-command checks with real Git clones and a simulated Treehouse provider.
# Experiments are retained. No shared worktree or pool is administered.
set -eu
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=tests/scratch-root.sh
. "$ROOT/tests/scratch-root.sh"
fm_test_scratch_root_init "$ROOT"
# shellcheck source=tests/git-config-helpers.sh
. "$ROOT/tests/git-config-helpers.sh"
export GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.test
export GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@example.test
unset FM_TASK_ID
python3 - "$ROOT" <<'PY'
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(sys.argv.pop())
BASE = Path(tempfile.mkdtemp(prefix="pool-prune.", dir=os.environ["FM_TEST_SCRATCH_ROOT"]))
REAL_GIT = shutil.which("git")


def git(path, *args):
    return subprocess.check_output([REAL_GIT, "-C", str(path), *args], text=True,
                                   stderr=subprocess.DEVNULL).strip()


class Pool(unittest.TestCase):
    def setUp(self):
        self.base = Path(tempfile.mkdtemp(prefix="case.", dir=BASE))
        self.home = self.base / "home"
        for directory in ("state", "data", "config"):
            (self.home / directory).mkdir(parents=True)
        self.project = self.base / "core"
        self.project.mkdir()
        git(self.project, "init", "-b", "main")
        (self.project / "tracked").write_text("published\n")
        git(self.project, "add", ".")
        git(self.project, "commit", "-m", "initial")
        self.remote = self.base / "origin.git"
        git(self.base, "clone", "--bare", str(self.project), str(self.remote))
        git(self.project, "remote", "add", "origin", str(self.remote))
        self.fakebin = self.base / "fakebin"
        self.fakebin.mkdir()
        self.rows = []
        self.env = dict(os.environ, FM_HOME=str(self.home),
                        FM_CONFIG_OVERRIDE=str(self.home / "config"),
                        FM_STATE_OVERRIDE=str(self.home / "state"),
                        POOL_FIXTURE=str(self.base), REAL_GIT=REAL_GIT,
                        PATH=str(self.fakebin) + os.pathsep + os.environ["PATH"])
        self.env.pop("FM_ROOT_OVERRIDE", None)
        self.tool("git", '''import os, sys
from pathlib import Path
if '--git-common-dir' in sys.argv and not (Path(os.environ['POOL_FIXTURE'])/'different-common').exists():
    print(Path(os.environ['POOL_FIXTURE'])/'core'/'.git')
else:
    os.execv(os.environ['REAL_GIT'], [os.environ['REAL_GIT'], *sys.argv[1:]])
''')
        self.tool("treehouse", '''import json, os, sys
from pathlib import Path
p=Path(os.environ['POOL_FIXTURE'])
args=sys.argv[1:]
with (p/'calls').open('a') as f: f.write(json.dumps(args)+'\\n')
if args == ['--version']:
    print('v2.0.1' if (p/'old-version').exists() else 'v3.1.3')
elif args == ['status','--json']:
    print((p/'rows.json').read_text())
elif args[0] == 'destroy':
    target=Path(args[1])
    if (p/'reject-destroy').exists(): sys.exit(1)
    if '--yes' in args:
        if os.environ.get('POOL_LOCK'):
            with (p/'owners').open('a') as f: f.write(os.readlink(os.environ['POOL_LOCK'])+'\\n')
        if (p/'leave-present').exists(): sys.exit(0)
        target.rename(target.with_name(target.name+'.retained'))
        rows=json.loads((p/'rows.json').read_text())
        (p/'rows.json').write_text(json.dumps([r for r in rows if r['path'] != str(target)]))
    elif (p/'race-claim').exists():
        (target.parent/'.fm-slot-owner').write_text('task=other\\nhome=/foreign\\n')
elif args[0] == 'return':
    pass
else:
    sys.exit(2)
''')

    def tool(self, name, body):
        path = self.fakebin / name
        path.write_text("#!/usr/bin/env python3\n" + body)
        path.chmod(0o755)

    def slot(self, **changes):
        path = self.base / "pool" / str(len(self.rows) + 1) / "core"
        path.parent.mkdir(parents=True)
        git(self.base, "clone", str(self.remote), str(path))
        git(path, "checkout", "--detach")
        row = dict(path=str(path), status="available", lease_id="", processes=[], flavor="git")
        row.update(changes)
        self.rows.append(row)
        return path

    def cap(self, cap):
        (self.home / "config/treehouse-idle-cap").write_text(json.dumps(dict(default=2, projects={"core": cap})))

    def invoke(self, apply=False):
        (self.base / "rows.json").write_text(json.dumps(self.rows))
        result = subprocess.run(["bash", str(ROOT / "bin/fm-pool-prune.sh"), str(self.project),
                                 *(["--apply"] if apply else [])], env=self.env,
                                text=True, capture_output=True, timeout=300)
        self.output = result.stdout + result.stderr
        self.reports = [json.loads(line) for line in result.stdout.splitlines()]
        return result.returncode, self.reports[-1] if self.reports else None

    def calls(self):
        calls = self.base / "calls"
        return [json.loads(line) for line in calls.read_text().splitlines()] if calls.exists() else []

    def removals(self):
        return [call for call in self.calls() if '--yes' in call]

    def refused(self, expected):
        rc, report = self.invoke(True)
        self.assertNotEqual(rc, 0, self.output)
        self.assertEqual(self.removals(), [])
        self.assertIn(expected, self.output)
        return report

    def test_default_and_dry_run(self):
        slots = [self.slot() for _ in range(3)]
        rc, report = self.invoke()
        self.assertEqual(rc, 0, self.output)
        self.assertEqual(report['copies_would_prune'], 1)
        self.assertGreater(report['bytes_would_reclaim'], 0)
        self.assertEqual(report['copies_pruned'], 0)
        self.assertTrue(all(p.exists() for p in slots))
        self.assertEqual(self.removals(), [])

    def test_apply_and_idempotence(self):
        slots = [self.slot() for _ in range(4)]
        self.cap(1)
        rc, report = self.invoke(True)
        self.assertEqual(rc, 0, self.output)
        self.assertEqual(sum(r['copies_pruned'] for r in self.reports), 3)
        self.assertEqual(sum(p.exists() for p in slots), 1)
        self.assertTrue(all(r['bytes_reclaimed'] > 0 for r in self.reports))
        self.assertTrue(all(len(c) == 3 and c[0] == 'destroy' and c[2] == '--yes' for c in self.removals()))
        self.rows = json.loads((self.base/'rows.json').read_text())
        rc, report = self.invoke(True)
        self.assertEqual(rc, 0, self.output)
        self.assertEqual(report['copies_pruned'], 0)

    def test_unmeasured_copy_still_pruned(self):
        slots = [self.slot() for _ in range(2)]
        self.tool("du", "import sys; sys.exit(1)")
        self.cap(0)
        rc, report = self.invoke(True)
        self.assertEqual(rc, 0, self.output)
        self.assertFalse(any(p.exists() for p in slots))
        self.assertEqual(sum(r['copies_pruned'] for r in self.reports), 2)
        self.assertEqual(sum(r['bytes_reclaimed'] for r in self.reports), 0)
        pruned = [c for r in self.reports for c in r['copies'] if c['decision'] == 'pruned']
        self.assertEqual([c['allocated_bytes'] for c in pruned], [None, None])

    def test_active_and_leased_excluded(self):
        active = self.slot(status='in-use', processes=[dict(pid=123, name='worker')])
        leased = self.slot(status='leased', lease_id='durable')
        idle = self.slot()
        self.cap(0)
        rc, report = self.invoke(True)
        self.assertEqual(rc, 0, self.output)
        self.assertEqual(self.reports[0]['idle_before'], 1)
        self.assertTrue(active.exists() and leased.exists())
        self.assertFalse(idle.exists())

    def test_apply_releases_lock_between_copies(self):
        slots = [self.slot() for _ in range(3)]
        self.env['POOL_LOCK'] = subprocess.check_output(
            ['bash', '-c', 'FM_WAKE_READ_ONLY=1; . "$1/bin/fm-wake-lib.sh"; fm_treehouse_project_lock_path "$2"',
             '_', str(ROOT), str(self.project)], env=self.env, text=True).strip()
        self.cap(0)
        rc, report = self.invoke(True)
        self.assertEqual(rc, 0, self.output)
        self.assertFalse(any(p.exists() for p in slots))
        owners = (self.base/'owners').read_text().splitlines()
        self.assertEqual(len(owners), 3)
        self.assertEqual(len(set(owners)), 3, owners)
        self.assertFalse(os.path.lexists(self.env['POOL_LOCK']))

    def test_teardown_prunes_at_most_one_copy(self):
        slots = [self.slot() for _ in range(4)]
        (self.base/'pool/treehouse-state.json').write_text('{}\n')
        (self.home/'state/task.meta').write_text(
            f'window=firstmate:fm-task\nendpoint_task_id=task\nworktree={slots[0]}\n'
            f'project={self.project}\nkind=scout\n')
        self.tool("tmux", "")
        self.cap(0)
        (self.base / "rows.json").write_text(json.dumps(self.rows))
        result = subprocess.run(["bash", str(ROOT / "bin/fm-teardown.sh"), "task", "--force"],
                                env=dict(self.env, FM_GATE_REFUSE_BYPASS="1"), text=True, capture_output=True, timeout=120)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(len(self.removals()), 1, self.calls())
        self.assertEqual(sum(p.exists() for p in slots), 3)
        self.assertNotIn('{', result.stdout)
        self.assertIn('still above its cap', result.stderr)

    def test_dirty(self):
        p = self.slot()
        (p/'untracked').write_text('unlanded')
        self.cap(0)
        self.refused('uncommitted changes')
        self.assertTrue((p/'untracked').exists())

    def test_unpublished_commit(self):
        p = self.slot()
        git(p, 'commit', '--allow-empty', '-m', 'unpublished')
        self.cap(0)
        self.refused('HEAD is not published')

    def test_unpublished_branch(self):
        p = self.slot()
        git(p, 'checkout', '-b', 'local-only')
        self.cap(0)
        self.refused('branch is not published')

    def test_foreign_claim(self):
        p = self.slot()
        (p.parent/'.fm-slot-owner').write_text('task=other\nhome=/foreign\n')
        self.cap(0)
        self.refused('slot claim')

    def test_foreign_home_record(self):
        p = self.slot()
        child = self.base/'secondmate'
        (child/'state').mkdir(parents=True)
        (child/'state/other.meta').write_text('worktree='+str(p)+'\n')
        (self.home/'data/secondmates.md').write_text(f'- child - testing (home: {child}; scope: testing; projects: core; added 2026-10-27)\n')
        self.cap(0)
        self.refused('recorded Firstmate task copy')

    def test_claim_appears_during_preview(self):
        self.slot()
        (self.base/'race-claim').touch()
        self.cap(0)
        self.refused('slot claim')

    def test_failed_destroy(self):
        self.slot()
        (self.base/'reject-destroy').touch()
        self.cap(0)
        self.refused('non-zero exit')

    def test_false_destroy_success(self):
        p = self.slot()
        (self.base/'leave-present').touch()
        self.cap(0)
        rc, report = self.invoke(True)
        self.assertNotEqual(rc, 0)
        self.assertTrue(p.exists())
        self.assertEqual(report['copies_pruned'], 0)

    def test_unknown_remote(self):
        p = self.slot()
        git(p, 'remote', 'set-url', 'origin', str(self.base/'missing'))
        self.cap(0)
        self.refused('non-zero exit')

    def test_different_repository(self):
        self.slot()
        (self.base/'different-common').touch()
        self.cap(0)
        self.refused('different Git common directory')

    def test_malformed_config(self):
        self.slot()
        (self.home/'config/treehouse-idle-cap').write_text('{"default":0,"projects":{},"projects":{}}')
        self.refused('duplicate idle-cap key')

    def test_old_treehouse(self):
        self.slot()
        (self.base/'old-version').touch()
        self.cap(0)
        self.refused('Treehouse >=3.1.3')

    def test_unreadable_registry(self):
        self.slot()
        (self.home/'data/secondmates.md').write_text('- malformed\n')
        self.cap(0)
        self.refused('malformed local Firstmate registry')

    def test_worker_cannot_apply(self):
        self.slot()
        self.env['FM_TASK_ID'] = 'fixture-worker'
        self.cap(0)
        self.refused('task workers cannot administer')


unittest.main(verbosity=2)
PY
