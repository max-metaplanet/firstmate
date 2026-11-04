#!/usr/bin/env bash
# Wrapper exit/fallback contract through an adapter stub, plus real adapter
# source isolation and conservative Git scoping through the local fake Boat CLI.
set -euo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
CASE_ROOT=$(fm_test_tmproot fm-boat-test-wrapper)
export CASE_ROOT
python3 - "$ROOT" <<'PY'
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys

repo = Path(sys.argv[1])
root = Path(os.environ['CASE_ROOT'])
tools = root / 'bin'
tools.mkdir()
for name in ('fm-boat-test-wrapper.sh', 'fm-build-lock.py', 'fm-memcap.sh'):
    shutil.copy2(repo / 'bin' / name, tools / name)

# Boundary stub records exact adapter inputs, never calls Boat, and optionally
# returns broken evidence independently of the wrapper's result classifier.
adapter = tools / 'fm-boat-run.sh'
adapter.write_text('''#!/usr/bin/env python3
import json,os,pathlib,subprocess,sys
args=sys.argv[1:]
if args[:1]==["check-result"]:
    sys.exit(subprocess.call([sys.executable,ADAPTER_IMPLEMENTATION,*args]))
settings=json.loads(os.environ['SETTINGS'])
pathlib.Path(os.environ['CALLS']).write_text(json.dumps(args))
history=pathlib.Path(os.environ['CALLS']+'.history')
calls=json.loads(history.read_text()) if history.exists() else []
calls.append(args)
history.write_text(json.dumps(calls))
if isinstance(settings,list):
    settings=settings[min(len(calls)-1,len(settings)-1)]
output=pathlib.Path(args[args.index('--output')+1])
assert not output.exists()
output.mkdir()
if settings.get('result') != 'missing':
    (output/'result.json').write_text(settings['result'] if isinstance(settings['result'],str) else json.dumps(settings['result']))
print('adapter output',flush=True)
sys.exit(settings['exit'])
'''.replace('ADAPTER_IMPLEMENTATION', repr(str(repo / 'bin/fm-boat-run.py'))))
adapter.chmod(0o755)

# Bash's elapsed clock and sleep form the time boundary for retry fixtures.
# Unsetting SECONDS removes its automatic ticking; each backoff advances it
# explicitly so adapter startup and CI scheduling cannot consume the budget.
clock = root / 'clock.bash'
clock.write_text('''unset SECONDS
SECONDS=0
sleep() { SECONDS=$((SECONDS + $1)); }
''')

def case(name):
    p = root / name
    p.mkdir()
    work = p / 'work'
    work.mkdir()
    env = dict(os.environ, SETTINGS='', CALLS=str(p / 'calls.json'),
               FM_BUILD_LOCK_FILE=str(p / 'heavy.lock'), FM_HEAVY_SLOTS='1',
               LOCAL_ONLY='inherited locally')
    env.pop('FM_BUILD_LOCK_BYPASS', None)
    env.pop('FM_BUILD_LOCK_HELD', None)
    env.pop('FM_BOAT_TYPE', None)
    for name in ('FM_BOAT_TEST_LOCAL_FALLBACK', 'FM_BOAT_TEST_UNAVAILABLE_WAIT_SECS',
                 'FM_BOAT_TEST_UNAVAILABLE_RETRY_SECS'):
        env.pop(name, None)
    return p, work, env

def launch(work, env, command, wrapper=tools / 'fm-boat-test-wrapper.sh'):
    return subprocess.run([str(wrapper), command], cwd=work, env=env,
                          capture_output=True, timeout=30)

def settings(env, code, kind, **extra):
    result = dict(kind=kind, adapter_exit=code, **extra)
    env['SETTINGS'] = json.dumps({'exit': code, 'result': result})

for owner_home, owner_task, ok in (('/fixture/home', 'fixture-task', False),
                                  ('/other/home', 'fixture-task', False),
                                  ('/fixture/home', 'other-task', False)):
    p, work, env = case('retained-' + owner_home.replace('/', '-') + '-' + owner_task)
    env.update(FM_HOME='/fixture/home', FM_TASK_ID='fixture-task')
    settings(env, 0, 'completed', remote_exit=0, cleanup='retained', provider='boat',
             lease=dict(state='idle', owner=dict(home=owner_home, task=owner_task)))
    r = launch(work, env, 'touch local-ran')
    assert (r.returncode == 0) == ok, (ok, r.stderr)
    assert not (work / 'local-ran').exists()
print('ok - ambient home/task without frozen launch evidence cannot validate retained results')

for code in (0, 7, 69, 75, 70, 74, 143):
    p, work, env = case('completed-' + str(code))
    settings(env, code, 'completed', remote_exit=code, cleanup='deleted')
    command = "printf '%s\\n' 'one argument; $literal' > local-ran; exit 91"
    r = launch(work, env, command)
    assert r.returncode == code, (code, r.stderr)
    assert r.stdout == b'adapter output\n'
    assert not (work / 'local-ran').exists()
    assert not (p / 'heavy.lock').exists(), 'remote execution claimed local lock'
    args = json.loads((p / 'calls.json').read_text())
    assert args[:3] == ['run', '--worktree', str(work)]
    assert args[-1] == command, args
    assert '--type' not in args
    output = Path(args[args.index('--output') + 1]).resolve()
    assert work not in output.parents and output != work
    assert str(output / 'result.json').encode() in r.stderr
print('ok - completed remote exits and output propagate; no local rerun or heavy slot')

for code in (69, 75):
    p, work, env = case('unavailable-' + str(code))
    settings(env, code, 'unavailable')
    # The actual heavy lock must be held by the local command, with cwd and
    # caller environment intact. An unlocked rerun fails the flock assertion.
    check = '''import fcntl,os,pathlib
assert os.environ['LOCAL_ONLY']=='inherited locally'
assert os.environ.get('FM_BUILD_LOCK_HELD')
with open(os.environ['FM_BUILD_LOCK_FILE'],'a') as f:
    try: fcntl.flock(f,fcntl.LOCK_EX|fcntl.LOCK_NB)
    except BlockingIOError: pass
    else: raise AssertionError('local fallback ran without heavy lock')
pathlib.Path('local-ran').write_text('one argument; $literal')
print('local fallback output')
raise SystemExit(23)
'''
    r = launch(work, env, 'python3 -c ' + shlex.quote(check))
    assert r.returncode == 23, r.stderr
    assert (work / 'local-ran').read_text() == 'one argument; $literal'
    assert b'local fallback output' in r.stdout
    assert b'running locally through heavy build lock' in r.stderr
print('ok - only 69/75 unavailable falls back, preserving cwd, environment, exit and heavy lock')

for code in (69, 75):
    p, work, env = case('boat-only-retry-' + str(code))
    env.update(FM_BOAT_TEST_LOCAL_FALLBACK='0',
               FM_BOAT_TEST_UNAVAILABLE_WAIT_SECS='5',
               FM_BOAT_TEST_UNAVAILABLE_RETRY_SECS='1', BASH_ENV=str(clock))
    env['SETTINGS'] = json.dumps([
        {'exit': code, 'result': {'kind': 'unavailable', 'adapter_exit': code}},
        {'exit': 0, 'result': {'kind': 'completed', 'adapter_exit': 0,
                               'remote_exit': 0, 'cleanup': 'deleted'}}])
    r = launch(work, env, 'touch local-ran')
    assert r.returncode == 0, r.stderr
    calls = json.loads((p / 'calls.json.history').read_text())
    assert len(calls) == 2, calls
    outputs = [args[args.index('--output') + 1] for args in calls]
    assert len(set(outputs)) == 2, outputs
    assert not (work / 'local-ran').exists()
    assert not (p / 'heavy.lock').exists()
print('ok - Boat-only retries unavailable 69/75 with fresh evidence and never runs locally')

p, work, env = case('boat-only-exhausted')
env.update(FM_BOAT_TEST_LOCAL_FALLBACK='0',
           FM_BOAT_TEST_UNAVAILABLE_WAIT_SECS='2',
           FM_BOAT_TEST_UNAVAILABLE_RETRY_SECS='1', BASH_ENV=str(clock))
settings(env, 75, 'unavailable')
r = launch(work, env, 'touch local-ran')
assert r.returncode == 75, r.stderr
assert not (work / 'local-ran').exists()
assert not (p / 'heavy.lock').exists()
calls = json.loads((p / 'calls.json.history').read_text())
# A two-second budget permits attempts at t=0 and t=1, never at t=2.
assert len(calls) == 2, calls
outputs = [args[args.index('--output') + 1] for args in calls]
assert len(set(outputs)) == len(calls), outputs
assert b'Boat unavailable' in r.stderr
assert f'after {len(calls)} attempts'.encode() in r.stderr
assert str(Path(outputs[-1]) / 'result.json').encode() in r.stderr
print('ok - Boat-only fails after the unavailable bound without local side effects')

p, work, env = case('boat-only-completed-75')
env.update(FM_BOAT_TEST_LOCAL_FALLBACK='0',
           FM_BOAT_TEST_UNAVAILABLE_WAIT_SECS='2',
           FM_BOAT_TEST_UNAVAILABLE_RETRY_SECS='1', BASH_ENV=str(clock))
settings(env, 75, 'completed', remote_exit=75, cleanup='deleted')
r = launch(work, env, 'touch local-ran')
assert r.returncode == 75, r.stderr
assert len(json.loads((p / 'calls.json.history').read_text())) == 1
assert not (work / 'local-ran').exists()
print('ok - Boat-only completed remote 75 propagates without retry')

p, work, env = case('boat-only-missing-retry-result')
env.update(FM_BOAT_TEST_LOCAL_FALLBACK='0',
           FM_BOAT_TEST_UNAVAILABLE_WAIT_SECS='5',
           FM_BOAT_TEST_UNAVAILABLE_RETRY_SECS='1', BASH_ENV=str(clock))
env['SETTINGS'] = json.dumps([
    {'exit': 75, 'result': {'kind': 'unavailable', 'adapter_exit': 75}},
    {'exit': 75, 'result': 'missing'}])
r = launch(work, env, 'touch local-ran')
assert r.returncode == 75 and b'adapter failure' in r.stderr, r.stderr
assert len(json.loads((p / 'calls.json.history').read_text())) == 2
assert not (work / 'local-ran').exists()
print('ok - retry cannot reuse stale unavailable evidence or retry adapter failures')

p, work, env = case('nonzero-fallback-setting')
env.update(FM_BOAT_TEST_LOCAL_FALLBACK='other',
           FM_BOAT_TEST_UNAVAILABLE_WAIT_SECS='invalid',
           FM_BOAT_TEST_UNAVAILABLE_RETRY_SECS='invalid')
settings(env, 75, 'unavailable')
r = launch(work, env, 'touch local-ran')
assert r.returncode == 0 and (work / 'local-ran').exists(), r.stderr
assert len(json.loads((p / 'calls.json.history').read_text())) == 1
print('ok - any fallback setting except 0 preserves local execution and ignores retry settings')

for code, kind in ((2, 'invalid'), (74, 'adapter-error'), (70, 'completed'),
                   (143, 'interrupted'), (69, 'execution-unknown'),
                   (75, 'adapter-error'), (74, 'unavailable')):
    p, work, env = case('failure-' + str(code) + '-' + kind)
    settings(env, code, kind, remote_exit=0, cleanup='pending')
    r = launch(work, env, 'touch local-ran')
    assert r.returncode == code, r.stderr
    assert not (work / 'local-ran').exists()
    assert b'adapter failure' in r.stderr and b'result.json:' in r.stderr
print('ok - invalid input, transport, cleanup, signals and uncertain outcomes fail loudly')

for index, result in enumerate(('missing', '{broken', '[]', '{}',
                                 {'kind': 'completed', 'remote_exit': 0})):
    p, work, env = case('invalid-evidence-' + str(index))
    env['SETTINGS'] = json.dumps({'exit': 0, 'result': result})
    r = launch(work, env, 'touch local-ran')
    assert r.returncode == 74, r.stderr
    assert b'adapter failure' in r.stderr and b'result.json:' in r.stderr
    assert not (work / 'local-ran').exists()
print('ok - missing, malformed or incomplete success evidence fails closed')

for index, result in enumerate(('missing', '{broken', {'kind': 'completed', 'remote_exit': 69},
                                 {'kind': 'unavailable', 'adapter_exit': 75})):
    p, work, env = case('unsafe-fallback-' + str(index))
    env['SETTINGS'] = json.dumps({'exit': 69, 'result': result})
    r = launch(work, env, 'touch local-ran')
    assert r.returncode == 69 and not (work / 'local-ran').exists()
    assert b'adapter failure' in r.stderr
print('ok - unavailable exit alone, malformed evidence and mismatched exit cannot rerun locally')

for args in ([], [''], ['   '], ['one', 'two']):
    r = subprocess.run([str(tools / 'fm-boat-test-wrapper.sh'), *args],
                       capture_output=True)
    assert r.returncode == 2 and b'exactly one' in r.stderr
print('ok - command must be one nonempty argument')

p, work, env = case('timeout-override')
settings(env, 0, 'completed', remote_exit=0, cleanup='deleted')
env['FM_BOAT_TEST_TIMEOUT'] = '1500'
r = launch(work, env, 'exit 0')
assert r.returncode == 0, r.stderr
args = json.loads((p / 'calls.json').read_text())
assert args[args.index('--timeout') + 1] == '1500'
print('ok - explicit timeout reaches the adapter without changing the command interface')

p, work, env = case('history-input-forwarding')
settings(env, 0, 'completed', remote_exit=0, cleanup='deleted')
env['FM_BOAT_TEST_HISTORY_INPUT'] = str(p / 'history manifest.json')
r = launch(work, env, 'exit 0')
assert r.returncode == 0, r.stderr
args = json.loads((p / 'calls.json').read_text())
assert args[args.index('--history-input') + 1] == env['FM_BOAT_TEST_HISTORY_INPUT']
assert '--history-depth' not in args
print('ok - explicit history input reaches the adapter as one exact path')

for machine_type in ('default', 'large', 'xlarge', 'invalid; literal'):
    p, work, env = case('type-' + machine_type.split(';')[0])
    settings(env, 0, 'completed', remote_exit=0, cleanup='deleted')
    env['FM_BOAT_TYPE'] = machine_type
    r = launch(work, env, 'exit 0')
    assert r.returncode == 0, r.stderr
    args = json.loads((p / 'calls.json').read_text())
    assert args[args.index('--type') + 1] == machine_type, args
    assert args[-1] == 'exit 0'
print('ok - FM_BOAT_TYPE forwards one exact argument for adapter validation')

# Real adapter + fake Boat: independently prove no local Git history/config or
# secrets arrive, and real Git consumers see ALL source changed, including
# unchanged and ignored tracked files. No provider request or VM is started.
p, work, env = case('real-adapter')
def git(*args):
    return subprocess.run(['git', '-C', str(work), *args], check=True, capture_output=True)
git('init', '-q')
git('config', 'user.name', 'Fixture')
git('config', 'user.email', 'fixture@example.invalid')
git('config', 'remote.origin.url', 'https://local-token@example.invalid/core')
files = {'unchanged.txt': 'same\n', 'changed.txt': 'before\n',
         'ignored.txt': 'tracked despite ignore\n', '.gitignore': 'ignored.txt\n',
         '.env': 'never upload\n', '.npmrc': '_authToken=never upload\n'}
for name, contents in files.items():
    (work / name).write_text(contents)
git('add', '--force', '.')
git('commit', '-qm', 'local-history-secret')
(work / 'changed.txt').write_text('working edit\n')
(work / 'untracked.txt').write_text('not uploaded\n')
state = p / 'home/state/boat-offload'
(state / 'jobs').mkdir(parents=True)
(state / 'fixture.json').write_text('{}')
boat = p / 'boat'
boat.write_text('#!/bin/sh\nexec python3 ' + shlex.quote(str(repo / 'tests/fixtures/boat-cli.py')) +
                ' ' + shlex.quote(str(state)) + ' "$@"\n')
boat.chmod(0o755)
user = p / 'user'
(user / '.config/boat').mkdir(parents=True)
(user / '.config/boat/api-key').write_text('boat_fixture_secret')
env.update(HOME=str(user), FM_HOME=str(p / 'home'), FM_BOAT_BIN=str(boat),
           DEV_SECRET='host-only')
check = '''import os,pathlib,subprocess
def git(*args): return subprocess.check_output(['git',*args]).decode().strip()
assert git('rev-parse','--show-toplevel') == str(pathlib.Path.cwd())
base=git('merge-base','HEAD','origin/main')
missing_ref=os.environ.get('PIPELINE_TEST_BASE_REF')
assert missing_ref, 'core was not told that real base history is unavailable'
missing=subprocess.run(['git','merge-base','HEAD',missing_ref],capture_output=True)
assert missing.returncode != 0 and not missing.stdout, 'synthetic history incorrectly advertised as a real contract base'
assert set(git('diff','--name-only',base,'--').splitlines()) == {'.gitignore','changed.txt','ignored.txt','unchanged.txt'}
assert git('ls-tree',base) == ''
assert git('remote') == ''
assert 'local-history-secret' not in git('log','--format=%B')
assert pathlib.Path('changed.txt').read_text() == 'working edit\\n'
assert not any(pathlib.Path(x).exists() for x in ('.env','.npmrc','untracked.txt'))
assert not any(os.environ.get(x) for x in ('DEV_SECRET','LOCAL_ONLY','BOAT_API_KEY'))
print('remote Git and source proof')
'''
r = launch(work, env, 'python3 -c ' + shlex.quote(check), repo / 'bin/fm-boat-test-wrapper.sh')
assert r.returncode == 0, (r.stdout, r.stderr)
assert b'remote Git and source proof' in r.stdout
assert b'synthetic empty Git base' in r.stdout + r.stderr
assert not (p / 'heavy.lock').exists()
assert json.loads((state / 'fake-vms.json').read_text()) == []
assert git('log', '-1', '--format=%B').stdout.strip() == b'local-history-secret'
assert git('config', 'remote.origin.url').stdout.strip() == b'https://local-token@example.invalid/core'
print('ok - real adapter filters secrets; synthetic history makes all source changed without local metadata')
git('commit', '--allow-empty', '-qm', 'historical fixture POSTGRES_PASSWORD=postgres')
refused_tip = git('rev-parse', 'HEAD').stdout.decode().strip()
# Reuse the real adapter fixture with a clean shallow range. Older unsafe
# history remains outside depth one and must not travel.
git('rm', '--', '.env', '.npmrc')
git('add', 'changed.txt')
git('commit', '-qm', 'clean shallow base')
git('update-ref', 'refs/remotes/origin/main', 'HEAD')
base_tip = git('rev-parse', 'HEAD').stdout.decode().strip()
(work / 'changed.txt').write_text('real tip\n')
git('add', 'changed.txt')
git('commit', '-qm', 'real shallow head')
head_tip = git('rev-parse', 'HEAD').stdout.decode().strip()
(work / 'changed.txt').write_text('dirty real tip\n')
env['FM_BOAT_TEST_HISTORY_DEPTH'] = '1'
check = """import os,pathlib,subprocess
def git(*args): return subprocess.check_output(['git',*args]).decode().strip()
assert git('rev-parse','HEAD') == head_tip
assert git('rev-parse','origin/main') == base_tip
assert git('rev-list','--count','--all') == '2'
assert os.environ['PIPELINE_TEST_BASE_REF'] == 'refs/remotes/origin/main'
assert git('remote') == ''
assert pathlib.Path('changed.txt').read_text() == 'dirty real tip\\n'
assert 'local-history-secret' not in git('log','--all','--format=%B')
print('screened real history wrapper proof')
"""
check = f"head_tip={head_tip!r}; base_tip={base_tip!r}\n" + check
r = launch(work, env, 'python3 -c ' + shlex.quote(check), repo / 'bin/fm-boat-test-wrapper.sh')
assert r.returncode == 0, (r.stdout, r.stderr)
assert b'screened real history wrapper proof' in r.stdout
assert b'screened shallow Git history' in r.stdout + r.stderr
assert b'synthetic empty Git base' not in r.stdout + r.stderr
print('ok - wrapper opt-in preserves real Git tips and sets the real contract base')

env['FM_BOAT_TEST_HISTORY_DEPTH'] = '50'
# The fake reuses VM IDs after deletion; preserve the prior filesystem so this
# attempt starts empty like a newly provisioned Boat VM.
(state / 'bx_fixture0').rename(state / 'previous-history-vm')
check = '''import os,pathlib,subprocess
def git(*args): return subprocess.check_output(['git',*args]).decode().strip()
assert os.environ['PIPELINE_TEST_BASE_REF'] == 'refs/fm-boat/no-local-history'
assert subprocess.run(['git','rev-parse','--verify',os.environ['PIPELINE_TEST_BASE_REF']],capture_output=True).returncode != 0
assert git('ls-tree','origin/main') == ''
assert git('rev-list','--count','--all') == '2'
assert 'local-history-secret' not in git('log','--all','--format=%B')
assert pathlib.Path('changed.txt').read_text() == 'dirty real tip\\n'
print('fallback synthetic base proof')
'''
r = launch(work, env, 'python3 -c ' + shlex.quote(check), repo / 'bin/fm-boat-test-wrapper.sh')
assert r.returncode == 0, (r.stdout, r.stderr)
reason = 'history refused: credential-looking or binary commit: ' + refused_tip
assert ('falling back to synthetic snapshot; ' + reason).encode() in r.stderr
assert b'fallback synthetic base proof' in r.stdout
assert b'synthetic empty Git base' in r.stdout + r.stderr
assert b'screened shallow Git history' not in r.stdout + r.stderr
result_path = next(line.split(': ', 2)[2] for line in r.stderr.decode().splitlines()
                   if line.startswith('boat-test-wrapper: result.json: '))
result = json.loads(Path(result_path).read_text())
assert result['history'] == 'fallback-synthetic'
assert result['history_reason'] == reason
print('ok - refused history uses the synthetic contract base and full-suite fallback')

PY
