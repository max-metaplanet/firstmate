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
for name in ('fm-boat-test-wrapper.sh', 'fm-build-lock.py'):
    shutil.copy2(repo / 'bin' / name, tools / name)

# Boundary stub records exact adapter inputs, never calls Boat, and optionally
# returns broken evidence independently of the wrapper's result classifier.
adapter = tools / 'fm-boat-run.sh'
adapter.write_text('''#!/usr/bin/env python3
import json,os,pathlib,sys
args=sys.argv[1:]
settings=json.loads(os.environ['SETTINGS'])
pathlib.Path(os.environ['CALLS']).write_text(json.dumps(args))
output=pathlib.Path(args[args.index('--output')+1])
assert not output.exists()
output.mkdir()
if settings.get('result') != 'missing':
    (output/'result.json').write_text(settings['result'] if isinstance(settings['result'],str) else json.dumps(settings['result']))
print('adapter output',flush=True)
sys.exit(settings['exit'])
''')
adapter.chmod(0o755)

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
    return p, work, env

def launch(work, env, command, wrapper=tools / 'fm-boat-test-wrapper.sh'):
    return subprocess.run([str(wrapper), command], cwd=work, env=env,
                          capture_output=True, timeout=30)

def settings(env, code, kind, **extra):
    result = dict(kind=kind, adapter_exit=code, **extra)
    env['SETTINGS'] = json.dumps({'exit': code, 'result': result})

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
PY
