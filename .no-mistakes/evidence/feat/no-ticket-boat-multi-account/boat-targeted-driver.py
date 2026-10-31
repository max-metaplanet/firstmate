import datetime
import json
import os
from pathlib import Path
import signal
import shlex
import subprocess
import sys
import time

repo = Path(sys.argv[1])
base = Path(os.environ['CASE_ROOT'])
fixture = repo / 'tests/fixtures/boat-cli.py'

def git(root, *args):
    return subprocess.run(['git', '-C', str(root), *args], check=True,
                          capture_output=True)

def case(name, settings=None):
    p = base / name
    p.mkdir()
    work = p / 'work'
    work.mkdir()
    git(work, 'init', '-q')
    git(work, 'config', 'user.name', 'Fixture')
    git(work, 'config', 'user.email', 'fixture@example.invalid')
    (work / 'tracked.txt').write_text('committed\n')
    (work / 'deleted.txt').write_text('delete me\n')
    (work / '.env').write_text('never upload\n')
    (work / '.npmrc').write_text('token=never upload\n')
    git(work, 'add', '.')
    git(work, 'commit', '-qm', 'fixture')
    (work / 'tracked.txt').write_text('working edit\n')
    (work / 'deleted.txt').unlink()
    (work / 'input.txt').write_text('extra\n')
    (work / 'unselected.txt').write_text('not requested\n')
    state = p / 'home/state/boat-offload'
    (state / 'jobs').mkdir(parents=True)
    (state / 'fixture.json').write_text(json.dumps(settings or {}))
    wrapper = p / 'boat'
    wrapper.write_text('#!/bin/sh\nexec python3 ' + shlex.quote(str(fixture)) + ' ' +
                       shlex.quote(str(state)) + ' "$@"\n')
    wrapper.chmod(0o755)
    user = p / 'user'
    (user / '.config/boat').mkdir(parents=True)
    (user / '.config/boat/api-key').write_text('boat_fixture_secret')
    env = dict(os.environ, HOME=str(user), FM_HOME=str(p / 'home'),
               FM_BOAT_BIN=str(wrapper), DEV_SECRET='host-only',
               NODE_OPTIONS='--require=/should/not/travel.js')
    return p, state, env

def launch(p, env, command='exit 0', options=(), wait=True):
    argv = ['bash', str(repo / 'bin/fm-boat-run.sh'), 'run',
            '--worktree', str(p / 'work'), '--output', str(p / 'output'),
            *options, '--', 'bash', '-c', command]
    if wait:
        return subprocess.run(argv, env=env, capture_output=True, timeout=30)
    return subprocess.Popen(argv, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)

def result(p):
    return json.loads((p / 'output/result.json').read_text())

def empty(state):
    assert json.loads((state / 'fake-vms.json').read_text()) == []
    assert all(json.loads(p.read_text())['cleanup'] == 'deleted' for p in (state / 'jobs').glob('*.json'))

def reap(env):
    return subprocess.run(['bash', str(repo / 'bin/fm-boat-run.sh'), 'reap'],
                          env=env, capture_output=True, timeout=20)

def multi(name, first=None, second=None, caps='live_cap=6 pending_cap=6 daily_cap=170'):
    p, state, env = case(name, first)
    other = state / 'account-2'
    other.mkdir()
    (other / 'fixture.json').write_text(json.dumps(second or {}))
    key1 = Path(env['HOME']) / '.config/boat/api-key'
    key2 = Path(env['HOME']) / 'second-account'
    key2.write_text('boat_fixture_second')
    config = p / 'home/config/boat-keys'
    config.parent.mkdir()
    config.write_text('# Ordered accounts\n~/.config/boat/api-key\n' +
                      shlex.quote(str(key2)) + ' ' + caps + '\n')
    return p, state, other, env, key1, key2, config


def calls(state):
    path = state / 'calls.jsonl'
    return [json.loads(line)[0] for line in path.read_text().splitlines()] if path.exists() else []


def reserved(state, key, count):
    for i in range(count):
        (state / 'jobs' / ('reserved-' + str(i) + '.json')).write_text(json.dumps({
            'account_key_file': str(key), 'cleanup': 'pending', 'create_started': False}))



def show(label, r, state):
    print('\nSCENARIO:', label)
    print('adapter exit:', r.returncode)
    print('adapter stdout:', r.stdout.decode().strip())
    print('adapter stderr:', r.stderr.decode().strip())
    print('provider calls:', (state / 'calls.jsonl').read_text())
    if (state / 'uploaded.json').exists():
        print('uploaded archive manifest:', (state / 'uploaded.json').read_text())

p,state,env=case('default')
r=launch(p,env,'echo default-account; test -z "$BOAT_API_KEY$DEV_SECRET$NODE_OPTIONS"')
assert r.returncode == 0, r.stderr
empty(state)
show('No config uses default account; credentials absent from execution; cleanup completes',r,state)

p,state,other,env,k1,k2,config=multi('scoped', {'remaining':0}, {'required_environment':'temp-max-dev','deletion_forbidden':True}, caps='live_cap=6 pending_cap=6 daily_cap=170 environment=temp-max-dev cleanup_confirmation=list')
r=launch(p,env,'echo account-two; test -z "$BOAT_API_KEY$DEV_SECRET"')
assert r.returncode==0,r.stderr
assert 'new' not in calls(state)
assert 'new' in calls(other) and 'deletion' not in calls(other)
empty(other)
show('Exhausted first account selects scoped second account and confirms cleanup through list',r,other)

for selected in ['.claude/settings.json','.claude/settings.local.json','.claude/settings.example.json']:
 for route in ['tracked','input']:
  for scheme in ['postgresql','mysql','redis','amqp','mongodb+srv','https']:
   label=selected.replace('/','-')+'-'+route+'-'+scheme
   p,state,env=case(label)
   target=p/'work'/selected
   target.parent.mkdir()
   target.write_text('{"env":{"DATABASE_URL":"'+scheme+'://app:dbpass@db.internal/app"}}')
   if route=='tracked':
    git(p/'work','add','--force',selected)
    git(p/'work','commit','-qm','credential fixture')
   options=('--input',selected) if route=='input' else ()
   r=launch(p,env,'test ! -e '+shlex.quote(selected)+'; echo credential-file-absent',options)
   assert r.returncode==0,(label,r.stderr)
   assert selected not in json.loads((state/'uploaded.json').read_text())
   assert b'excluded allowlisted file' in r.stderr
   assert b'dbpass' not in r.stdout+r.stderr
   empty(state)
   print('REFUSED',route,selected,scheme,'with content-free warning; executed command observed file absent')

p,state,env=case('clean-allowlist')
for name,content in [('.npmrc','registry=https://registry.npmjs.org/\n'),('.claude/settings.local.json','{"permissions":{"allow":[]}}'),('vendor/lib.js','module.exports = {}'),('.ssh/key','excluded'),('.aws/config','excluded'),('.config/file','excluded')]:
 target=p/'work'/name
 target.parent.mkdir(exist_ok=True,parents=True)
 target.write_text(content)
git(p/'work','add','--force','.')
git(p/'work','commit','-qm','clean fixture')
r=launch(p,env,'cat .npmrc .claude/settings.local.json vendor/lib.js; test ! -e .ssh/key; test ! -e .aws/config; test ! -e .config/file')
assert r.returncode==0,r.stderr
uploaded=json.loads((state/'uploaded.json').read_text())
assert all(x in uploaded for x in ['.npmrc','.claude/settings.local.json','vendor/lib.js'])
assert all(x not in uploaded for x in ['.ssh/key','.aws/config','.config/file'])
empty(state)
show('Clean allowlisted settings and vendor source arrive; other secret paths remain absent',r,state)
print('\nAll focused adapter checks passed. Provider executable was the repository fake; no real Boat access attempted.')
