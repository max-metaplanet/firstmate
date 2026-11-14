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
        'wide_shards': ['other packages'],
        'node': {'run_count': 2, 'total': 5, 'matrix': [
            {'name': 'admin-center jsdom', 'filters': ['@core/admin-center'],
             'passthrough': ['--project=jsdom']},
            {'name': 'other packages',
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
assert not any(arg.startswith('--test-concurrency') for lane in lanes for arg in lane['argv']), lanes
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
for wide_name in ('other packages', 'renamed remaining workspaces'):
    for filters in (['!@core/db', '!@core/admin-center'],
                    ['@core/mail', '@core/ui', '@core/bmj-site', '@core/planetgear']):
        selected = remote.select_lanes(plan(wide_shards=[wide_name], node={'matrix': [{
            'name': wide_name, 'filters': filters,
            'passthrough': ['--passWithNoTests'],
        }]}))
        shard = next(lane for lane in selected if lane['group'] == 'node')
        assert shard['argv'] == ['pnpm', 'test:ci', '--concurrency=2'] + [
            '--filter=' + f for f in filters] + ['--', '--passWithNoTests']
uncapped = remote.select_lanes(plan(wide_shards=[]))
assert next(lane for lane in uncapped if lane['name'] == 'node-1')['argv'] == [
    'node', '.depot/scripts/run-node-shard.mjs']
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
    return {'size': size, 'adapter_exit': 0, 'summary': {'failed': failed, 'oom': oom},
            'remote_result': {'kind': 'completed', 'remote_exit': 0, 'cleanup': 'deleted'}}


assert not local.should_retry_large(run('default', [], False))
assert local.should_retry_large(run('default', ['node-1'], True))
assert not local.should_retry_large(run('default', ['node-1'], False))
assert not local.should_retry_large(run('large', ['node-1'], True))
saved_home, saved_task = os.environ.get('FM_HOME'), os.environ.get('FM_TASK_ID')
os.environ.update(FM_HOME='/fixture/home', FM_TASK_ID='fixture-task')
for home, task, expected in (('/fixture/home', 'fixture-task', False),
                             ('/sibling/home', 'fixture-task', False),
                             ('/fixture/home', 'other-task', False)):
    retained = run('default', ['node-1'], True)
    retained['remote_result'].update(cleanup='retained', provider='boat',
        lease=dict(state='idle', owner=dict(home=home, task=task)))
    assert local.should_retry_large(retained) == expected
for key, previous in (('FM_HOME', saved_home), ('FM_TASK_ID', saved_task)):
    if previous is None:
        os.environ.pop(key, None)
    else:
        os.environ[key] = previous
# A run that produced no verdict is a failure of the check, not memory evidence.
assert not local.should_retry_large({'size': 'default', 'summary': None})
for kind in ('execution-unknown', 'adapter-error', 'unavailable'):
    unknown = {**run('default', ['node-1'], True),
               'remote_result': {'kind': kind, 'cleanup': 'deleted'}}
    assert not local.should_retry_large(unknown)
assert local.verdict(run('default', [], False))[0]
for failed, oom in (([], False), (['node-1'], True)):
    broken = {**run('default', failed, oom), 'adapter_exit': 70}
    assert local.verdict(broken) == (False, [], False)
    assert not local.should_retry_large(broken)
print('ok - the larger machine is bought only for a proven memory failure on default')

upstash_run = {**run('default', [], False), 'provider': 'upstash', 'actual_size': 'small',
               'resources': {'cpu': 2, 'memory_gib': 4, 'disk_gib': 10},
               'wall_s': 60, 'dollars_estimate': None, 'log': 'upstash.log', 'lanes': []}
import io
rendered = io.StringIO()
local.report([upstash_run], rendered)
assert 'upstash small machine' in rendered.getvalue()
assert 'free-plan CPU allowance' in rendered.getvalue()
assert '$' not in rendered.getvalue()
print('ok - Upstash small reports its actual provider and omits Boat compute pricing')

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

# Regression oracle: a hung lane must finish red within its own budget,
# retaining its last output; the next lane must still execute and retain its
# output. The budget leaves the child ample time to start and print.
import io
import subprocess
import time
remote.cgroup_oom_kills = lambda: 0
start = time.monotonic()
try:
    hung = remote.run_lane('hung', 'test', [sys.executable, '-c',
        "import time; print('last diagnostic', flush=True); time.sleep(5)"],
        {}, base, timeout=1.0)
except TypeError:
    raise AssertionError('lane execution has no per-lane timeout')
assert hung['timeout'] and hung['exit'] == 124 and not hung['oom'], hung
assert 'last diagnostic' in hung['output_tail'], hung
assert time.monotonic() - start < 4
following = lane(0, 'following lane completed\n')
assert following['exit'] == 0 and following['output_tail'] == 'following lane completed\n', following
print('ok - a timed-out lane retains diagnostics, stays red, and releases following lanes')

# The adapter may preserve only raw stream frames when transport fails. Split
# a marker across frames to reject parsing each frame as a complete line.
partial_wrapper = base / 'partial-wrapper.sh'
partial_output = base / 'partial-output'
partial_output.mkdir()
raw_log = partial_output / 'command.log'
plan_marker = 'FM_BOAT_PREPUSH_PLAN ' + json.dumps({'lanes': ['done', 'missing']}) + '\n'
lane_marker = 'FM_BOAT_PREPUSH_LANE ' + json.dumps({
    'name': 'done', 'exit': 1, 'wall_s': 1, 'oom': False}) + '\n'
original_wrapper = local.WRAPPER
local.WRAPPER = partial_wrapper
try:
    for payload in (plan_marker + lane_marker, 'ordinary output\n'):
        raw_log.write_text('\n'.join(json.dumps({'type': 'stdout', 'data': chunk})
            for chunk in (payload[:17], payload[17:])) + '\n')
        partial_wrapper.write_text('#!/usr/bin/env bash\nprintf "%s\\n" ' +
            repr('boat-test-wrapper: result.json: ' + str(partial_output / 'result.json')) +
            '\nexit 70\n')
        attempt = local.attempt(base, partial_output, 'default', 30, None, 'unused')
        rendered = io.StringIO()
        local.report([attempt], rendered)
        text = rendered.getvalue()
        assert local.verdict(attempt)[0] is False
        assert not local.should_retry_large(attempt)
        if payload.startswith('FM_'):
            assert [entry['name'] for entry in attempt['lanes']] == ['done'], attempt
            assert 'missing' in text and 'unreported' in text, text
            assert 'no lane reported' not in text, text
        else:
            assert 'no lane reported' in text, text
finally:
    local.WRAPPER = original_wrapper
print('ok - partial stream-framed logs preserve lane verdicts and name unreported lanes')

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

planner_source = base / 'planner-source'
planner_evidence = base / 'planner-evidence'
planner_evidence.mkdir()
for name in ('other packages', 'new canonical shard name'):
    definitions = [
        {'name': 'single workspace', 'filters': ['@core/admin-center'], 'passthrough': []},
        {'name': name, 'filters': ['!@core/db', '!@core/admin-center'],
         'passthrough': ['--passWithNoTests']},
    ]
    matrix = [dict(definitions[0]), {**definitions[1], 'filters': [
        '@core/mail', '@core/ui', '@core/bmj-site', '@core/planetgear']}]
    modules = {
        '.github/scripts/test-plan/shards.mjs': 'export const SHARDS = ' + json.dumps(definitions) + ';',
        '.depot/scripts/node-plan.mjs': 'export function nodePlan() { return ' + json.dumps({
            'run_count': 2, 'total': 2, 'matrix': matrix}) + '; }',
        '.github/scripts/depot-ci/plan-quality.mjs': 'export function planQuality() { return {}; }',
        '.github/scripts/test-plan/shard-scope.mjs': 'export function readWorkspaces() { return []; }',
        '.github/scripts/test-plan/db-scope.mjs':
            'export const DATABASE_SUITES = {db: {}, actions: {}, runtime: {}, gates: {}}; '
            'export function databaseScope() { return {run: true}; }',
    }
    for filename, content in modules.items():
        target = planner_source / filename
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(content)
    resolved = remote.read_plan(planner_evidence, planner_source, ['app/page.tsx'])
    assert resolved['wide_shards'] == [name], resolved
    lanes = remote.select_lanes(resolved)
    shards = [lane for lane in lanes if lane['group'] == 'node']
    assert shards[0]['argv'] == ['node', '.depot/scripts/run-node-shard.mjs'], shards
    assert shards[1]['argv'][:3] == ['pnpm', 'test:ci', '--concurrency=2'], shards
    assert shards[1]['argv'][3:7] == ['--filter=@core/mail', '--filter=@core/ui',
                                    '--filter=@core/bmj-site', '--filter=@core/planetgear'], shards
print('ok - the head canonical definitions determine the cap through narrowing and renames')

assert not any(lane['group'] == 'database' for lane in remote.select_lanes(plan()))
selected_db = remote.select_lanes(plan(database={key: {'run': True}
                                               for key in ('db', 'actions', 'runtime', 'gates')}))
assert [lane['name'] for lane in selected_db if lane['group'] == 'database'] == [
    'database-db', 'database-actions', 'database-runtime']

subprocess.run(['git', 'init', '--quiet', str(base)], check=True)
(base / 'missing.ts').write_text('historical fixture path')
subprocess.run(['git', '-C', str(base), 'add', 'missing.ts'], check=True)
subprocess.run(['git', '-C', str(base), '-c', 'user.name=Test', '-c',
                'user.email=test@example.invalid', 'commit', '--quiet', '-m', 'fixture'], check=True)
original_counter = remote.cgroup_oom_kills
remote.cgroup_oom_kills = lambda: 0
for ordinary, suffix in ((False, ''), (True, ''), (False, ':missing.ts'), (True, ':missing.ts')):
    tap_file = base / ('tap-mixed.test.mjs' if ordinary else 'tap-history.test.mjs')
    tap_file.write_text(
        "import { describe, test } from 'node:test';\n"
        "import { execFileSync } from 'node:child_process';\n"
        "describe('a renamed suite', () => {\n"
        "test('renamed historical test', () => { execFileSync('git', "
        "['show', " + repr(('ee343d6a' if suffix else '1234567890123456789012345678901234567890') + suffix) + "]); });\n"
        + ("test('ordinary failure', () => { throw new Error('assertion failed'); });\n"
           if ordinary else '') + '});\n')
    result = remote.run_lane('ci-scripts', 'scripts',
                             ['node', '--test', '--test-reporter=tap', str(tap_file)], {}, base)
    assert result['history_only'] is (not ordinary), result
    assert len(result['history_excused']) == 1, result
    assert result['history_excused'][0]['name'] == 'renamed historical test', result
    assert 'fatal:' in result['history_excused'][0]['evidence'], result
    if suffix:
        assert result['missing_history'] == 'fatal: invalid object name', result
        assert 'fatal: invalid object name' in result['history_excused'][0]['evidence'], result

for messages, count in ((['fatal: bad object deadbeef'], 1),
                        (["fatal: invalid object name 'ee343d6a'."], 1),
                        (["fatal: invalid object name 'ee343d6a'.", 'ordinary assertion failure'], 2),
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
    assert result['history_only'] is (len(messages) == 1 and messages[0].startswith('fatal:')), result
    assert len(result['history_excused']) == sum('fatal:' in m for m in messages), result
    if result['history_only']:
        rendered = io.StringIO()
        local.report([{'size': 'default', 'wall_s': 1, 'dollars_estimate': 0,
                       'adapter_exit': 0, 'log': 'probe.log', 'lanes': [result],
                       'summary': {'failed': [], 'oom': False}}], rendered)
        assert 'unavailable repository-scripts / case 0: ' + messages[0] in rendered.getvalue()
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
# A synthetic server major keeps installed host clients out of this fixture
# and rejects implementations that hardcode the measured PostgreSQL 17.
client_version = base / 'client-version'
client_version.write_text('99.11')
allow_install = base / 'allow-client-install'
client_tools = ('psql', 'pg_dump', 'pg_restore', 'createdb', 'dropdb', 'pg_isready')
for command in ('docker', 'node', 'pnpm', 'sudo', 'curl', *client_tools):
    boundary = service_bin / command
    boundary.write_text('#!' + sys.executable + '\n' +
        'import json, sys, subprocess\nfrom pathlib import Path\n' +
        'name = ' + repr(command) + '\n' +
        'with Path(' + repr(str(service_log)) + ').open("a") as f: f.write(json.dumps([name, *sys.argv[1:]]) + "\\n")\n' +
        'failure = Path(' + repr(str(failure_file)) + ')\n' +
        'if failure.exists() and failure.read_text() in " ".join([name, *sys.argv[1:]]): sys.exit(9)\n' +
        'if name == "docker" and sys.argv[1:3] == ["image", "inspect"]: print("PG_MAJOR=99")\n' +
        'if name == "psql" and sys.argv[1:] == ["--version"]: print("psql (PostgreSQL) " + Path(' + repr(str(client_version)) + ').read_text())\n' +
        'if name == "sudo":\n' +
        '    if not Path(' + repr(str(allow_install)) + ').exists(): sys.exit(9)\n' +
        '    if "install" in sys.argv: Path(' + repr(str(client_version)) + ').write_text("99.11")\n' +
        '    if "tee" in sys.argv: sys.stdin.read()\n' +
        '    sys.exit(0)\n' +
        'if name == "pnpm":\n' +
        '    for tool in ' + repr(client_tools) + ':\n' +
        '        for _ in range(2): subprocess.run([tool, "--version"], check=True)\n' +
        'if name == "node" and "ledger-delta.mjs" in sys.argv[1]:\n' +
        '    diff = subprocess.check_output(["git", "diff", "--name-status", "refs/remotes/origin/main...HEAD"], text=True)\n' +
        '    Path(' + repr(str(base / 'migration-diff')) + ').write_text(diff)\n' +
        '    if "A\\t" in diff and "candidate.sql" in diff: sys.exit(8)\n' +
        'if name == "docker" and sys.argv[1] == "run": print("a" * 64)\n' +
        'if name == "node" and "--test" in sys.argv: print("# tests 2\\n# skipped 0")\n')
    boundary.chmod(0o755)
for script in ('db-local/restore-snapshot.sh', 'db-local/prd-guards.sh', 'action-db/start-postgrest.sh'):
    (service_source / '.github/scripts' / script).write_text(
        '#!/usr/bin/env bash\nexec node ' + script + '\n')
import shutil
import shlex
wrapper_tools = base / 'wrapper-tools'
wrapper_tools.mkdir()
shutil.copy2(repo / 'bin/fm-boat-test-wrapper.sh', wrapper_tools / 'fm-boat-test-wrapper.sh')
adapter = wrapper_tools / 'fm-boat-run.sh'
adapter.write_text('#!' + sys.executable + '\n' + """
import json, subprocess, sys
from pathlib import Path
args = sys.argv[1:]
if args[:1] == ["check-result"]:
    sys.exit(subprocess.call([sys.executable, ADAPTER_IMPLEMENTATION, *args]))
output = Path(args[args.index('--output') + 1])
output.mkdir(parents=True)
result = subprocess.run(args[args.index('--') + 1:])
(output / 'result.json').write_text(json.dumps({
    'kind': 'completed', 'adapter_exit': result.returncode,
    'remote_exit': result.returncode, 'cleanup': 'deleted',
}))
sys.exit(result.returncode)
""".replace('ADAPTER_IMPLEMENTATION', repr(str(repo / 'bin/fm-boat-run.py'))))
adapter.chmod(0o755)
(service_source / 'candidate.sql').write_text('candidate migration')
subprocess.run(['bash', str(wrapper_tools / 'fm-boat-test-wrapper.sh'), 'true'],
               cwd=service_source, env={key: value for key, value in os.environ.items()
                                       if key != 'FM_BOAT_TEST_HISTORY_DEPTH'},
               capture_output=True, text=True, check=True)
synthetic_base = subprocess.check_output(['git', '-C', str(service_source), 'rev-parse',
                                         'refs/remotes/origin/main'], text=True).strip()
assert subprocess.check_output(['git', '-C', str(service_source), 'ls-tree',
                                synthetic_base], text=True) == ''
assert subprocess.check_output(['git', '-C', str(service_source), 'rev-parse',
                                'HEAD^'], text=True).strip() == synthetic_base
assert 'candidate.sql' in subprocess.check_output([
    'git', '-C', str(service_source), 'diff', '--name-only',
    'refs/remotes/origin/main...HEAD'], text=True).splitlines()
previous_path = os.environ['PATH']
os.environ['PATH'] = str(service_bin) + os.pathsep + previous_path
try:
    (base / 'service-evidence').mkdir()
    (base / 'service-evidence/changed-files.json').write_text('["app/page.tsx"]')
    for suite in ('db', 'actions', 'runtime'):
        service_log.write_text('')
        assert remote.run_database(suite, service_source, base / 'service-evidence') == 0, suite
        if suite != 'runtime':
            assert (base / 'migration-diff').read_text() == '', 'unchanged migration reached ledger replay'
        calls = [json.loads(line) for line in service_log.read_text().splitlines()]
        assert calls[0] == ['docker', 'pull', 'docker.io/library/postgres@sha256:' + '1' * 64], calls
        assert calls[-1][:3] == ['docker', 'rm', '-f'], calls
        # Public lane PATH contract: repeated client calls reach native tools,
        # while Docker starts only the server. Container-per-call fails here.
        if suite != 'runtime':
            for tool in client_tools:
                assert calls.count([tool, '--version']) >= 2, (tool, calls)
        assert len([call for call in calls if call[:2] == ['docker', 'run']]) == 1, calls
        assert not any(call[0] == 'sudo' for call in calls), calls
        assert ['docker', 'exec', 'a' * 64, 'pg_isready', '-h', '127.0.0.1',
                '-p', '5432', '-U', 'postgres', '-d', 'postgres'] in calls, calls
        # core's runtime suites share one database; at the default machine's
        # CPU count, concurrent files race on CREATE ROLE, so only this lane
        # runs them one at a time.
        bounded = [call for call in calls if '--test-concurrency=1' in call]
        if suite == 'runtime':
            assert bounded and all(call[:4] == ['node', '--test', '--test-concurrency=1',
                                                '--test-reporter=tap'] for call in bounded), calls
        else:
            assert not bounded, calls
            assert any(call == ['node', 'db-local/restore-snapshot.sh'] for call in calls)
            assert any(call == ['node', '.github/scripts/db-local/ledger-delta.mjs',
                                '--tiers', 'am', '--base-ref', 'refs/remotes/origin/main'] for call in calls)
            expected = ['pnpm', '--filter', '@core/db', 'exec', 'vitest', 'run',
                        '--config', './vitest.instrumented.config.ts', '--reporter=default'] if suite == 'db' else [
                        'pnpm', '--filter', '@core/metaplanet', 'test:postgrest', '--reporter=default']
            assert expected in calls, calls
        for broken in ('restore-snapshot.sh', 'pnpm') if suite != 'runtime' else ('--test',):
            failure_file.write_text(broken)
            assert remote.run_database(suite, service_source, base / 'service-evidence') != 0
            failure_file.unlink()
    # A client version that disagrees with the approved server must be obtained
    # from PGDG; an unavailable installer must fail before starting a server.
    client_version.write_text('16.15')
    service_log.write_text('')
    assert remote.run_database('runtime', service_source, base / 'service-evidence') != 0
    calls = [json.loads(line) for line in service_log.read_text().splitlines()]
    assert any(call[0] == 'sudo' for call in calls), calls
    assert not any(call[:2] == ['docker', 'run'] for call in calls), calls
    # The package boundary materializes the requested version once; a later
    # suite reuses it. Its package name must follow the approved image major.
    allow_install.touch()
    service_log.write_text('')
    for suite in ('db', 'actions'):
        assert remote.run_database(suite, service_source, base / 'service-evidence') == 0
    calls = [json.loads(line) for line in service_log.read_text().splitlines()]
    installs = [call for call in calls if call[0] == 'sudo' and 'install' in call]
    assert len(installs) == 1 and installs[0][-1] == 'postgresql-client-99', installs
    allow_install.unlink()
    # Ledger contract: an unfingerprinted candidate added by this PR is fatal.
    # The boundary simulates that SQL failure only after observing a real added
    # path from Git; an empty or modified tier would incorrectly pass it.
    (base / 'service-evidence/changed-files.json').write_text('["candidate.sql"]')
    for suite in ('db', 'actions'):
        assert remote.run_database(suite, service_source, base / 'service-evidence') == 8
        assert (base / 'migration-diff').read_text() == 'A\tcandidate.sql\n'
finally:
    os.environ['PATH'] = previous_path
print('ok - database suites execute their selected commands, clean up, and reject setup or test failure')

remote.cgroup_oom_kills = lambda: 0
saved = (remote.REMOTE_SOURCE, remote.read_plan, remote.install, remote.run_lane, remote.emit)
remote.REMOTE_SOURCE = service_source
remote.read_plan = lambda *args: plan(database={key: {'run': True} for key in ('db', 'actions', 'runtime', 'gates')})
remote.install = lambda *args: {'name': 'install', 'exit': 0, 'oom': False, 'wall_s': 0}
original_cwd = Path.cwd()
original_argv = sys.argv
os.environ['FM_PREPUSH_FILES'] = '["change"]'
os.environ['FM_PREPUSH_TIMEOUT'] = '2700'
os.environ['FM_PREPUSH_DIR'] = str(base / 'main-evidence')
try:
    os.chdir(service_source)
    sys.argv = ['runner.py']
    for broken in ('', 'database-actions'):
        events = []
        ran = []
        def execute(name, group, argv, overlay, cwd, timeout=600):
            ran.append(name)
            if name == broken:
                return saved[3](name, group, [sys.executable, '-c',
                    "import time; print('lane diagnostic', flush=True); time.sleep(5)"],
                    {}, cwd, timeout=1.0)
            return {'name': name, 'exit': 0, 'oom': False, 'wall_s': 0}
        remote.run_lane = execute
        remote.emit = lambda kind, doc: events.append((kind, doc))
        assert remote.main() == 0
        summary = events[-1][1]
        assert ran[-3:] == ['database-db', 'database-actions', 'database-runtime'], ran
        assert summary['database_not_run'] == ['gates'], summary
        rendered = io.StringIO()
        local.report([{'size': 'default', 'wall_s': 1, 'dollars_estimate': 0,
                       'adapter_exit': 0, 'log': 'probe.log', 'lanes': summary['lanes'],
                       'summary': summary}], rendered)
        assert 'not run on Boat (neither pass nor fail): gates' in rendered.getvalue()
        assert 'forge CI remains the authority' in rendered.getvalue()
        if not broken:
            assert 'verdict: green' in rendered.getvalue()
        else:
            assert 'timeout' in rendered.getvalue() and 'lane diagnostic' in rendered.getvalue()
            assert summary['failed'] == ['database-actions']
            assert summary['oom'] is False
        assert local.verdict({'adapter_exit': 0, 'summary': summary})[0] is (broken == '')
    # Run-budget contract: the adapter must receive a summary before its
    # deadline, with an active timeout and every never-started lane named.
    # A 600-second lane limit would leave this real subprocess running for 10s
    # and incorrectly report green instead of respecting the 2s lane budget.
    os.environ['FM_PREPUSH_TIMEOUT'] = '12'
    events, limits, ran = [], [], []
    remote.read_plan = lambda *args: plan(node={'matrix': [
        {'name': 'first', 'filters': [], 'passthrough': []},
        {'name': 'second', 'filters': [], 'passthrough': []},
    ]}, quality={})
    def budget_execute(name, group, argv, overlay, cwd, timeout=600):
        ran.append(name)
        limits.append(timeout)
        return saved[3](name, group, [sys.executable, '-c',
            "import time; print('budget diagnostic', flush=True); time.sleep(10)"],
            {}, cwd, timeout=timeout)
    remote.run_lane = budget_execute
    remote.emit = lambda kind, doc: events.append((kind, doc))
    started = remote.time.monotonic()
    assert remote.main() == 0
    elapsed = remote.time.monotonic() - started
    assert events[-1][0] == 'SUMMARY', events
    summary = events[-1][1]
    assert len(ran) == 1 and 0 < limits[0] <= 2, (ran, limits)
    assert elapsed < 6, elapsed
    active = summary['lanes'][-1]
    assert active['timeout'] and active['exit'] == 124 and not active['oom'], active
    assert 'budget diagnostic' in active['output_tail'], active
    planned = next(doc['lanes'] for kind, doc in events if kind == 'PLAN')
    assert summary['unreported'] == planned[1:] and summary['unreported'], summary
    assert set(summary['failed']) == set(planned), summary
    assert not local.should_retry_large({'size': 'default', 'adapter_exit': 0,
                                         'summary': summary})
    print('ok - remaining run budget clamps lanes and preserves the summary')
finally:
    os.environ.pop('FM_PREPUSH_TIMEOUT', None)
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
    '"timeout": os.environ["FM_PREPUSH_TIMEOUT"], '
    '"files": json.loads(os.environ["FM_PREPUSH_FILES"])}))\n'
    'sys.exit(23)\n')
local.RUNNER = probe
result_path = base / 'placement.json'
executed = subprocess.run(['bash', '-c', local.command_string(files, 123)], cwd=source,
                          env={**os.environ, 'PROBE_RESULT': str(result_path)},
                          capture_output=True, text=True)
assert executed.returncode == 23, executed
observed = json.loads(result_path.read_text())
assert observed == {'cwd': str(source), 'runner': str(source.parent / 'prepush/runner.py'),
                    'prepush': str(source.parent / 'prepush'), 'timeout': '123',
                    'files': files}, observed
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
            ['bash', '-c', commands[0].replace('<PR head SHA>', 'a' * 40)], cwd=source,
            env={**os.environ, 'PATH': str(mock_bin) + os.pathsep + os.environ['PATH']},
            capture_output=True, text=True, check=True)
        args = json.loads(received.stdout)
        expected = [str(repo / 'bin/fm-boat-prepush.py'),
                    '--timeout', '2700']
        if target:
            expected += ['--base', target]
        expected += ['--expected-head', 'a' * 40]
        assert args == expected, (mode, target, args)
print('ok - both publishing commands forward the explicit base with shell quoting')

reader = base / '.github/scripts/test-plan/shard-scope.mjs'
reader.parent.mkdir(parents=True, exist_ok=True)
reader.write_text("import { execFileSync } from 'node:child_process';\n"
                  "export function readChangedFiles(root, base, head) {\n"
                  "  return execFileSync('git', ['diff', '--name-only', base, head],\n"
                  "    {cwd: root, encoding: 'utf8'}).trim().split('\\n');\n}\n")
subprocess.run(['git', '-C', str(base), 'add', '.github/scripts/test-plan/shard-scope.mjs'], check=True)
subprocess.run(['git', '-C', str(base), '-c', 'user.name=Test', '-c',
                'user.email=test@example.invalid', 'commit', '--quiet', '-m', 'reader'], check=True)
wrapper_boundary = base / 'verdict-wrapper.sh'
local.WRAPPER = wrapper_boundary
os.environ['FM_HOME'] = str(base)
actual_head = subprocess.check_output(['git', '-C', str(base), 'rev-parse', 'HEAD'], text=True).strip()
old_head = subprocess.check_output(['git', '-C', str(base), 'rev-parse', 'HEAD^'], text=True).strip()
provisioned = base / 'machine-started'
tracked = base / 'missing.ts'
tracked_content = tracked.read_bytes()
for code, named, content_state in (
        (0, False, 'clean'), (1, False, 'clean'),
        (0, True, 'clean'), (1, True, 'clean'),
        (0, True, 'staged'), (0, True, 'unstaged'),
        (0, True, 'deleted'), (0, True, 'staged-deleted'),
        (0, True, 'untracked'), (0, False, 'unstaged')):
    if content_state in ('staged', 'unstaged'):
        tracked.write_bytes(tracked_content + b'\nlocal edit')
    elif content_state in ('deleted', 'staged-deleted'):
        tracked.unlink()
    elif content_state == 'untracked':
        (base / 'untracked-content').write_text('does not travel')
    if content_state in ('staged', 'staged-deleted'):
        subprocess.run(['git', '-C', str(base), 'add', 'missing.ts'], check=True)
    wrapper_boundary.write_text("#!/usr/bin/env bash\ntouch " + shlex.quote(str(provisioned)) + "\nprintf '%s\\n' " +
        shlex.quote('FM_BOAT_PREPUSH_LANE ' + json.dumps({
            'name': 'probe', 'exit': code, 'wall_s': 0, 'oom': False})) + '\n' +
        "printf '%s\\n' " + shlex.quote('FM_BOAT_PREPUSH_SUMMARY ' + json.dumps({
            'failed': ['probe'] if code else [], 'oom': False})) + '\n')
    destination = base / ('verdict-' + str(code) + ('-named-' if named else '-manual-') + content_state)
    arguments = ['--worktree', str(base), '--base', 'HEAD^', '--output', str(destination)]
    if named:
        arguments += ['--expected-head', actual_head]
    if named and content_state in ('staged', 'unstaged', 'deleted', 'staged-deleted'):
        try:
            local.main(arguments)
        except local.Refusal as error:
            assert error.code == 2, error.code
            assert 'tracked checkout content' in str(error), str(error)
        else:
            raise AssertionError('dirty tracked content certified: ' + content_state)
        assert not provisioned.exists(), 'dirty tracked content reached provisioning'
        assert not destination.exists(), 'dirty tracked content reached planning/evidence creation'
        subprocess.run(['git', '-C', str(base), 'restore', '--source=HEAD', '--staged',
                        '--worktree', '--', 'missing.ts'], check=True)
        continue
    assert local.main(arguments) == code
    assert provisioned.exists(), 'matching or omitted head did not reach the machine boundary'
    provisioned.unlink()
    record = json.loads((destination / 'verdict.json').read_text())
    assert record['head'] == actual_head, record
    assert record['green'] is (code == 0), record
    assert record['failed'] == (['probe'] if code else []), record
    assert record['changed_files'] == 1, record
    assert record['attempts'][0]['adapter_exit'] == 0, record
    tracked.write_bytes(tracked_content)
history_path = base / 'history manifest.json'
history_path.write_text(json.dumps({'head': actual_head, 'refs': {
    'refs/remotes/origin/main': {'oid': old_head}}}))
received_history = base / 'received-history'
wrapper_boundary.write_text("#!/usr/bin/env bash\nprintf '%s' \"$FM_BOAT_TEST_HISTORY_INPUT\" > " +
    shlex.quote(str(received_history)) +
    "\nprintf '%s\\n' " + shlex.quote('FM_BOAT_PREPUSH_SUMMARY {"failed":[],"oom":false}') +
    "\ntest -z \"${FM_BOAT_TEST_HISTORY_DEPTH:-}\"\n")
os.environ['FM_BOAT_TEST_HISTORY_DEPTH'] = '50'
assert local.main(['--worktree', str(base), '--base', 'HEAD^', '--expected-head', actual_head,
                   '--history-input', str(history_path), '--output', str(base / 'input-verdict')]) == 0
assert received_history.read_text() == str(history_path)
os.environ.pop('FM_BOAT_TEST_HISTORY_DEPTH')
try:
    local.main(['--history-input', str(history_path), '--history-depth', '2'])
except local.Refusal as error:
    assert 'mutually exclusive' in str(error)
else:
    raise AssertionError('ambiguous history input and depth accepted')
history_path.write_text(json.dumps({'head': actual_head, 'refs': {
    'refs/remotes/origin/main': {'oid': actual_head}}}))
try:
    local.main(['--worktree', str(base), '--base', 'HEAD^', '--history-input', str(history_path),
                '--output', str(base / 'refused-input-verdict')])
except local.Refusal as error:
    assert 'planned head and base' in str(error)
else:
    raise AssertionError('manifest base differs from the selection base')
print('ok - pinned history manifest forwards through prepush without inherited depth ambiguity')
refused_output = base / 'refused-verdict'
try:
    local.main(['--worktree', str(base), '--expected-head', old_head, '--output', str(refused_output)])
except local.Refusal as error:
    assert error.code == 2, error.code
    assert actual_head in str(error) and old_head in str(error), str(error)
else:
    raise AssertionError('mismatched expected head was accepted')
assert not provisioned.exists(), 'a mismatched head reached machine provisioning'
assert not refused_output.exists(), 'a mismatched head created check evidence'
remote_tracked = 'release/prepush-base'
subprocess.run(['git', '-C', str(base), 'update-ref', 'refs/remotes/origin/' + remote_tracked,
                actual_head], check=True)
assert local.resolve_base(base, remote_tracked) == actual_head
subprocess.run(['git', '-C', str(base), 'branch', remote_tracked, old_head], check=True)
assert local.resolve_base(base, remote_tracked) == actual_head, 'stale local branch preferred'
assert local.resolve_base(base, old_head) == old_head
subprocess.run(['git', '-C', str(base), 'update-ref', 'refs/remotes/origin/HEAD', old_head], check=True)
assert local.resolve_base(base, None) == old_head
assert local.resolve_base(base, 'HEAD') == actual_head, 'HEAD resolved through origin/HEAD'
side = subprocess.check_output(['git', '-C', str(base), '-c', 'user.name=Test', '-c',
                                'user.email=test@example.invalid', 'commit-tree', 'HEAD^{tree}',
                                '-p', actual_head, '-m', 'side'], text=True).strip()
subprocess.run(['git', '-C', str(base), 'update-ref', 'refs/remotes/origin/HEAD', side], check=True)
assert local.resolve_base(base, 'HEAD^') == old_head, 'HEAD^ resolved through origin/HEAD'
subprocess.run(['git', '-C', str(base), 'update-ref', '-d', 'refs/remotes/origin/HEAD'], check=True)
subprocess.run(['git', '-C', str(base), 'branch', '-D', '--quiet', remote_tracked], check=True)
subprocess.run(['git', '-C', str(base), 'update-ref', '-d', 'refs/remotes/origin/' + remote_tracked],
               check=True)
try:
    local.resolve_base(base, remote_tracked)
except local.Refusal:
    pass
else:
    raise AssertionError('an unknown base resolved')
print('ok - successful and failing verdicts persist under the output directory')
print('ok - expected head requires clean tracked content before provisioning; untracked and manual edits remain allowed')
print('ok - a named base resolves through its remote-tracking ref before any stale local branch')
print('ok - a revision expression base resolves locally even when origin/HEAD exists')


PY
pass "fm-boat-prepush"
