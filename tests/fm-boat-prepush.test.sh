#!/usr/bin/env bash
# Pre-ready heavy-test check: lane selection and sequencing from a head's plan,
# the per-lane environment, the command string's placement of the runner, and
# the memory-only fallback to a larger machine.
set -euo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
CASE_ROOT=$(fm_test_tmproot fm-boat-prepush)
export CASE_ROOT

python3 - "$ROOT" <<'PY'
import importlib.util
import json
import os
import sys
from pathlib import Path

repo = Path(sys.argv[1])
base = Path(os.environ['CASE_ROOT'])


def load(name):
    spec = importlib.util.spec_from_file_location(
        name.replace('-', '_'), repo / 'bin' / (name + '.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


local = load('fm-boat-prepush')
remote = load('fm-boat-prepush-remote')


def plan(**over):
    document = {
        'changed_files': 4,
        'node': {'run_count': 2, 'total': 5, 'matrix': [
            {'name': 'admin-center jsdom', 'filters': ['@core/admin-center'],
             'passthrough': ['--project=jsdom']},
            {'name': 'other-packages',
             'filters': ['!@core/db', '!@core/admin-center'],
             'passthrough': ['--passWithNoTests']},
        ]},
        'quality': {'packages': ['@core/admin-center'], 'app_checks': True,
                    'script_tests': True, 'tooling_only': False,
                    'pipeline_harness': True, 'lingo': True},
        'database': {'db': {'run': False}, 'actions': {'run': False},
                     'runtime': {'run': False}},
    }
    document.update(over)
    return document


# ── lane selection follows the head's plan, in a stable order ───────────────
lanes = remote.select_lanes(plan())
names = [lane['name'] for lane in lanes]
assert names == ['quality-lint', 'quality-typecheck-admin', 'quality-typecheck-other',
                 'quality-test-typecheck', 'node-0', 'node-1', 'ci-scripts',
                 'repository-scripts', 'edge-function'], names

by_name = {lane['name']: lane for lane in lanes}
assert by_name['quality-lint']['env']['CI_AFFECTED_PACKAGES'] == '["@core/admin-center"]'
# The lane that runs Turbo `build` is the one an admin-center build is reached
# through, and it alone carries the measured old-space ceiling.
assert by_name['quality-test-typecheck']['env']['NODE_OPTIONS'] == '--max-old-space-size=3072'
assert by_name['quality-lint']['env']['NODE_OPTIONS'] == ''

# A shard with ordinary filters runs through the head's own shard runner.
assert by_name['node-0']['argv'] == ['node', '.depot/scripts/run-node-shard.mjs']
assert by_name['node-0']['env']['SHARD_NAME'] == 'admin-center jsdom'
assert json.loads(by_name['node-0']['env']['SHARD_FILTERS']) == ['@core/admin-center']
assert 'concurrency' not in ' '.join(by_name['node-0']['argv'])

wide = by_name['node-1']['argv']
assert wide[:3] == ['pnpm', 'test:ci', '--concurrency=2'], wide
assert "--filter=!@core/db" in wide and '--passWithNoTests' in wide
for filters in (['!@core/db', '!@core/admin-center'],
                ['@core/mail', '@core/ui', '@core/bmj-site', '@core/planetgear']):
    selected = remote.select_lanes(plan(node={'matrix': [{
        'name': 'other-packages', 'filters': filters,
        'passthrough': ['--passWithNoTests'],
    }]}))
    shard = next(lane for lane in selected if lane['group'] == 'node')
    assert shard['argv'] == ['pnpm', 'test:ci', '--concurrency=2'] + [
        '--filter=' + f for f in filters] + ['--', '--passWithNoTests']
print('ok - lane order, shard runner, affected packages and the two memory caps')

# ── planner predicates gate the optional lanes ──────────────────────────────
quiet = remote.select_lanes(plan(quality={
    'packages': None, 'app_checks': False, 'script_tests': False,
    'tooling_only': False, 'pipeline_harness': False, 'lingo': False}))
assert [lane['name'] for lane in quiet] == ['node-0', 'node-1', 'ci-scripts']

tooling = remote.select_lanes(plan(quality={
    'packages': None, 'app_checks': False, 'script_tests': True,
    'tooling_only': True, 'pipeline_harness': False, 'lingo': False}))
scripts = {lane['name']: lane['argv'] for lane in tooling}
assert 'scripts/__tests__/planetgear-dev-store.test.ts' in scripts['repository-scripts']

harness_off = remote.select_lanes(plan(quality={
    'packages': None, 'app_checks': False, 'script_tests': True,
    'tooling_only': False, 'pipeline_harness': False, 'lingo': False}))
excluded = {lane['name']: lane['argv'] for lane in harness_off}['repository-scripts']
assert '--exclude' in excluded and 'scripts/__tests__/pipeline-test.test.ts' in excluded

# A plan with no selected shard runs no shard lane at all.
empty = remote.select_lanes(plan(node={'run_count': 0, 'total': 5, 'matrix': []}))
assert not [lane for lane in empty if lane['group'] == 'node']
print('ok - application, script-test, tooling-only and harness predicates select lanes')

# ── a lane sees the project CI environment, not this runner's setup ─────────
os.environ['PGRST_DB_URI'] = 'inherited startup variable'
os.environ['FM_PREPUSH_DIR'] = '/home/user/fm-job/prepush'
env = remote.lane_env({'SHARD_NAME': 'admin-center jsdom'})
assert 'PGRST_DB_URI' not in env, 'an inherited startup variable reached a lane'
assert 'FM_PREPUSH_DIR' not in env
assert env['PATH'] == os.environ['PATH']
assert env['CI'] == 'true' and env['NODE_ENV'] == 'test' and env['TZ'] == 'Asia/Tokyo'
# The project's workflows keep the real local Turbo cache, which is what leaves
# the lint ratchet a per-workspace log to count and keeps a cache fixture true.
assert env['TURBO_CACHE'] == 'local:rw'
assert 'TURBO_FORCE' not in env
assert remote.lane_env({'NODE_OPTIONS': None}).get('NODE_OPTIONS') is None
print('ok - lane environment drops inherited setup and keeps the workflows own cache control')

# ── proven memory exhaustion, and nothing else, buys a larger machine ───────
def run(size, failed, oom):
    return {'size': size, 'adapter_exit': 0, 'summary': {'failed': failed, 'oom': oom}}


assert not local.should_retry_large(run('default', [], False))
assert local.should_retry_large(run('default', ['node-1'], True))
assert not local.should_retry_large(run('default', ['node-1'], False))
assert not local.should_retry_large(run('large', ['node-1'], True))
# A run that produced no verdict is a failure of the check, not memory evidence.
assert not local.should_retry_large({'size': 'default', 'summary': None})
assert local.verdict(run('default', [], False))[0]
for failed, oom in (([], False), (['node-1'], True)):
    broken = {**run('default', failed, oom), 'adapter_exit': 70}
    assert local.verdict(broken) == (False, [], False)
    assert not local.should_retry_large(broken)
print('ok - the larger machine is bought only for a proven memory failure on default')

# ── an out-of-memory lane needs kernel, exit-code or V8 proof ───────────────
def lane(exit_code, output, kills=(0, 0)):
    calls = list(kills)
    remote.cgroup_oom_kills = lambda: calls.pop(0)
    script = 'import sys; sys.stdout.write(%r); sys.exit(%d)' % (output, exit_code)
    return remote.run_lane('probe', 'test', [sys.executable, '-c', script], {}, base)


assert lane(1, 'one assertion failed\n')['oom'] is False
assert lane(137, '')['oom'] is True
heap = lane(1, 'FATAL ERROR: Ineffective mark-compacts near heap limit Allocation failed\n')
assert heap['oom'] is True and heap['oom_evidence'] == 'V8 heap exhaustion'
killed = lane(1, 'worker gone\n', kills=(4, 5))
assert killed['oom'] is True and killed['oom_evidence'] == 'cgroup oom_kill'
# An unreadable counter must never read as zero kills and excuse a real OOM.
assert lane(1, 'worker gone\n', kills=(-1, -1))['oom'] is False
print('ok - out of memory is proven by the kernel, exit 137 or V8, never guessed')

# ── a failure that reads absent history says so, and still fails ────────────
# The screened upload carries no real ancestry, so a fixture reading a pinned
# commit fails for the transport. Labelling it is useful; excusing it would
# hide a real regression that prints the same diagnostic.
absent = lane(1, "fatal: path 'a/b.tsx' exists on disk, but not in 'ee343d6a'\n")
assert absent['missing_history'] == 'exists on disk, but not in', absent
assert absent['exit'] == 1 and absent['oom'] is False
assert lane(1, 'ordinary assertion failure\n')['missing_history'] == ''
# A lane that passed is never labelled, however its output reads.
assert lane(0, "fatal: bad object deadbeef\n")['missing_history'] == ''
print('ok - a failure reading absent history is labelled and still counted as a failure')

import io
import subprocess

assert not any(lane['group'] == 'database' for lane in remote.select_lanes(plan()))
selected_db = remote.select_lanes(plan(database={key: {'run': True}
                                               for key in ('db', 'actions', 'runtime')}))
assert [lane['name'] for lane in selected_db if lane['group'] == 'database'] == [
    'database-db', 'database-actions', 'database-runtime']

subprocess.run(['git', 'init', '--quiet', str(base)], check=True)
original_counter = remote.cgroup_oom_kills
remote.cgroup_oom_kills = lambda: 0
for ordinary in (False, True):
    tap_file = base / ('tap-mixed.test.mjs' if ordinary else 'tap-history.test.mjs')
    tap_file.write_text(
        "import { describe, test } from 'node:test';\n"
        "import { execFileSync } from 'node:child_process';\n"
        "describe('a renamed suite', () => {\n"
        "test('renamed historical test', () => { execFileSync('git', "
        "['show', '1234567890123456789012345678901234567890']); });\n"
        + ("test('ordinary failure', () => { throw new Error('assertion failed'); });\n"
           if ordinary else '') + '});\n')
    result = remote.run_lane('ci-scripts', 'scripts',
                             ['node', '--test', '--test-reporter=tap', str(tap_file)], {}, base)
    assert result['history_only'] is (not ordinary), result
    assert len(result['history_excused']) == 1, result
    assert result['history_excused'][0]['name'] == 'renamed historical test', result
    assert 'fatal:' in result['history_excused'][0]['evidence'], result

for messages, count in ((['fatal: bad object deadbeef'], 1),
                        (['ordinary assertion failure'], 1),
                        (['fatal: bad object deadbeef', 'ordinary assertion failure'], 2),
                        ([], 1)):
    report_path = base / 'vitest-results.json'
    failures = [{'status': 'failed', 'fullName': 'case ' + str(index),
                 'failureMessages': [message]} for index, message in enumerate(messages)]
    document = {'numFailedTests': count, 'numRuntimeErrorTestSuites': 0,
                'testResults': [{'status': 'failed', 'assertionResults': failures}]}
    script = ('from pathlib import Path; import sys; Path(sys.argv[1]).write_text(%r); '
              'sys.exit(1)' % json.dumps(document))
    result = remote.run_lane('repository-scripts', 'scripts',
                            [sys.executable, '-c', script, str(report_path),
                             '--outputFile=' + str(report_path)], {}, base)
    assert result['history_only'] is (messages == ['fatal: bad object deadbeef']), result
    assert len(result['history_excused']) == sum('fatal:' in m for m in messages), result
    if result['history_only']:
        rendered = io.StringIO()
        local.report([{'size': 'default', 'wall_s': 1, 'dollars_estimate': 0,
                       'adapter_exit': 0, 'log': 'probe.log', 'lanes': [result],
                       'summary': {'failed': [], 'oom': False}}], rendered)
        assert 'unavailable repository-scripts / case 0: fatal: bad object deadbeef' in rendered.getvalue()
        assert 'green' in rendered.getvalue() and 'does not mean full parity' in rendered.getvalue()

document = {'numFailedTests': 1, 'numRuntimeErrorTestSuites': 0,
            'testResults': [{'status': 'failed', 'assertionResults': [{
                'status': 'failed', 'fullName': 'two causes',
                'failureMessages': ['fatal: bad object deadbeef', 'ordinary assertion failure'],
            }]}]}
script = ('from pathlib import Path; import sys; Path(sys.argv[1]).write_text(%r); '
          'sys.exit(1)' % json.dumps(document))
result = remote.run_lane('repository-scripts', 'scripts',
                        [sys.executable, '-c', script, str(report_path),
                         '--outputFile=' + str(report_path)], {}, base)
assert not result['history_only'] and not result['history_excused'], result

missing_report = remote.run_lane('repository-scripts', 'scripts',
                                [sys.executable, '-c', 'raise SystemExit(1)'], {}, base)
assert not missing_report['history_only'], missing_report
remote.cgroup_oom_kills = original_counter
print('ok - TAP and Vitest attribute individual history failures and keep mixed or unknown failures red')

service_source = base / 'database-source'
(service_source / '.github/scripts/db-local').mkdir(parents=True)
(service_source / '.github/scripts/action-db').mkdir(parents=True)
(service_source / '.github/scripts/test-plan').mkdir(parents=True)
(service_source / '.github/ci-images.json').write_text(json.dumps({'images': [
    {'repo': 'library/postgres', 'source': 'docker.io/library/postgres', 'digest': 'sha256:' + '1' * 64},
    {'repo': 'postgrest/postgrest', 'source': 'docker.io/postgrest/postgrest', 'digest': 'sha256:' + '2' * 64},
]}))
(service_source / '.github/scripts/example.pg.test.mjs').touch()
service_bin = base / 'service-bin'
service_bin.mkdir()
service_log = base / 'services.jsonl'
failure_file = base / 'service-failure'
for command in ('docker', 'node', 'pnpm'):
    boundary = service_bin / command
    boundary.write_text('#!' + sys.executable + '\n' +
        'import json, sys\nfrom pathlib import Path\n' +
        'name = ' + repr(command) + '\n' +
        'with Path(' + repr(str(service_log)) + ').open("a") as f: f.write(json.dumps([name, *sys.argv[1:]]) + "\\n")\n' +
        'failure = Path(' + repr(str(failure_file)) + ')\n' +
        'if failure.exists() and failure.read_text() in " ".join([name, *sys.argv[1:]]): sys.exit(9)\n' +
        'if name == "docker" and sys.argv[1] == "run": print("a" * 64)\n' +
        'if name == "node" and "--test" in sys.argv: print("# tests 2\\n# skipped 0")\n')
    boundary.chmod(0o755)
for script in ('db-local/restore-snapshot.sh', 'db-local/prd-guards.sh', 'action-db/start-postgrest.sh'):
    (service_source / '.github/scripts' / script).write_text(
        '#!/usr/bin/env bash\nexec node ' + script + '\n')
previous_path = os.environ['PATH']
os.environ['PATH'] = str(service_bin) + os.pathsep + previous_path
try:
    for suite in ('db', 'actions', 'runtime'):
        service_log.write_text('')
        assert remote.run_database(suite, service_source, base / 'service-evidence') == 0
        calls = [json.loads(line) for line in service_log.read_text().splitlines()]
        assert calls[0] == ['docker', 'pull', 'docker.io/library/postgres@sha256:' + '1' * 64], calls
        assert calls[-1][:3] == ['docker', 'rm', '-f'], calls
        if suite == 'runtime':
            assert any(call[:3] == ['node', '--test', '--test-reporter=tap'] for call in calls)
        else:
            assert any(call == ['node', 'db-local/restore-snapshot.sh'] for call in calls)
            assert any(call == ['node', '.github/scripts/db-local/ledger-delta.mjs',
                                '--tiers', 'am', '--base-ref', 'HEAD'] for call in calls)
            expected = ['pnpm', '--filter', '@core/db', 'exec', 'vitest', 'run',
                        '--config', './vitest.instrumented.config.ts', '--reporter=default'] if suite == 'db' else [
                        'pnpm', '--filter', '@core/metaplanet', 'test:postgrest', '--reporter=default']
            assert expected in calls, calls
        for broken in ('restore-snapshot.sh', 'pnpm') if suite != 'runtime' else ('--test',):
            failure_file.write_text(broken)
            assert remote.run_database(suite, service_source, base / 'service-evidence') != 0
            failure_file.unlink()
finally:
    os.environ['PATH'] = previous_path
print('ok - database suites execute their selected commands, clean up, and reject setup or test failure')

saved = (remote.REMOTE_SOURCE, remote.read_plan, remote.install, remote.run_lane, remote.emit)
remote.REMOTE_SOURCE = service_source
remote.read_plan = lambda *args: plan(database={key: {'run': True} for key in ('db', 'actions', 'runtime')})
remote.install = lambda *args: {'name': 'install', 'exit': 0, 'oom': False}
original_cwd = Path.cwd()
original_argv = sys.argv
os.environ['FM_PREPUSH_FILES'] = '["change"]'
os.environ['FM_PREPUSH_DIR'] = str(base / 'main-evidence')
try:
    os.chdir(service_source)
    sys.argv = ['runner.py']
    for broken in ('', 'database-actions'):
        events = []
        ran = []
        def execute(name, group, argv, overlay, cwd):
            ran.append(name)
            return {'name': name, 'exit': int(name == broken), 'oom': False}
        remote.run_lane = execute
        remote.emit = lambda kind, doc: events.append((kind, doc))
        assert remote.main() == 0
        summary = events[-1][1]
        assert ran[-3:] == ['database-db', 'database-actions', 'database-runtime'], ran
        assert local.verdict({'adapter_exit': 0, 'summary': summary})[0] is (broken == '')
finally:
    os.chdir(original_cwd)
    sys.argv = original_argv
    remote.REMOTE_SOURCE, remote.read_plan, remote.install, remote.run_lane, remote.emit = saved
print('ok - remote orchestration runs database lanes sequentially and propagates their red verdict')

# ── the runner refuses to execute anywhere but a disposable machine ─────────
# The Boat test wrapper falls back to the local machine when Boat is
# unavailable. That is right for one pipeline test command and ruinous for a
# whole heavy suite, so the refusal is the guard rather than an assumption.
runner = repo / 'bin/fm-boat-prepush-remote.py'
import subprocess
refused = subprocess.run([sys.executable, str(runner)], cwd=str(base), text=True,
                         capture_output=True,
                         env={**os.environ, 'FM_PREPUSH_DIR': str(base / 'prepush')})
assert refused.returncode == 70, refused
assert 'refusing to run outside a disposable machine' in refused.stderr, refused.stderr
assert str(remote.REMOTE_SOURCE) == '/home/user/fm-job/source'
print('ok - the runner refuses to execute outside the disposable machine')

# ── the remote runner never lands inside the uploaded source ────────────────
files = ['apps/admin-center/page.tsx', "spaces and 'quotes'; $(touch escaped)"]
source = base / 'upload/source'
source.mkdir(parents=True)
probe = base / 'runner-probe.py'
probe.write_text(
    'import json, os, sys\n'
    'from pathlib import Path\n'
    'Path(os.environ["PROBE_RESULT"]).write_text(json.dumps({'
    '"cwd": os.getcwd(), "runner": str(Path(__file__).resolve()), '
    '"prepush": os.environ["FM_PREPUSH_DIR"], '
    '"files": json.loads(os.environ["FM_PREPUSH_FILES"])}))\n'
    'sys.exit(23)\n')
local.RUNNER = probe
result_path = base / 'placement.json'
executed = subprocess.run(['bash', '-c', local.command_string(files)], cwd=source,
                          env={**os.environ, 'PROBE_RESULT': str(result_path)},
                          capture_output=True, text=True)
assert executed.returncode == 23, executed
observed = json.loads(result_path.read_text())
assert observed == {'cwd': str(source), 'runner': str(source.parent / 'prepush/runner.py'),
                    'prepush': str(source.parent / 'prepush'), 'files': files}, observed
assert list(source.iterdir()) == [], list(source.iterdir())
print('ok - the runner is written beside the uploaded source, never into it')

config = base / 'config'
config.mkdir()
(config / 'boat-prepush').write_text('core\n')
mock_bin = base / 'mock-bin'
mock_bin.mkdir()
python_probe = mock_bin / 'python3'
python_probe.write_text('#!' + sys.executable + '\nimport json, sys\n'
                        'print(json.dumps(sys.argv[1:]))\n')
python_probe.chmod(0o755)
for mode in ('no-mistakes', 'direct-PR'):
    for target in ('', 'release/stable', "release/$candidate'quote"):
        rendered = subprocess.run(
            ['bash', '-c',
             'source "$1/bin/fm-dod-lib.sh"; '
             'fm_dod_block "$2" task fm/task none "$3" "" "" "" core',
             'dod-test', str(repo), mode, target],
            env={**os.environ, 'CONFIG': str(config), 'FM_HOME': str(base)},
            capture_output=True, text=True, check=True).stdout
        commands = [part for part in rendered.split('`') if 'fm-boat-prepush.sh --timeout' in part]
        assert len(commands) == 1, commands
        received = subprocess.run(
            ['bash', '-c', commands[0]], cwd=source,
            env={**os.environ, 'PATH': str(mock_bin) + os.pathsep + os.environ['PATH']},
            capture_output=True, text=True, check=True)
        args = json.loads(received.stdout)
        expected = [str(repo / 'bin/fm-boat-prepush.py'),
                    '--timeout', '2700']
        if target:
            expected += ['--base', target]
        assert args == expected, (mode, target, args)
print('ok - both publishing commands forward the explicit base with shell quoting')

PY
pass "fm-boat-prepush"
