import datetime
import hashlib
import json
import os
from pathlib import Path
import signal
import shlex
import subprocess
import sys
import tarfile
import time

repo = Path(sys.argv[1])
base = Path(os.environ['CASE_ROOT'])
fixture = repo / 'tests/fixtures/boat-cli.py'

def git(root, *args):
    return subprocess.run(['git', '-C', str(root), *args], check=True,
                          capture_output=True)

def case(name, settings=None, clean_history=False):
    p = base / name
    p.mkdir()
    work = p / 'work'
    work.mkdir()
    git(work, 'init', '-q')
    git(work, 'config', 'user.name', 'Fixture')
    git(work, 'config', 'user.email', 'fixture@example.invalid')
    (work / 'tracked.txt').write_text('committed\n')
    (work / 'deleted.txt').write_text('delete me\n')
    if not clean_history:
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
    argv = ['bash', str(repo / '.test-upstash-phase/base/bin/fm-boat-run.sh'), 'run',
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
    return subprocess.run(['bash', str(repo / '.test-upstash-phase/base/bin/fm-boat-run.sh'), 'reap'],
                          env=env, capture_output=True, timeout=20)

def upstash_case(name, boat_settings=None, upstash_settings=None):
    p, state, env = case('upstash-' + name, boat_settings or {'remaining': 0})
    (state / 'upstash.json').write_text(json.dumps(upstash_settings or {}))
    key = Path(env['HOME']) / '.config/upstash/box-api-key'
    key.parent.mkdir(parents=True)
    key.write_text('upstash_fixture_secret')
    key.chmod(0o600)
    env.update(PYTHONPATH=str(repo / 'tests/fixtures'), FM_UPSTASH_FIXTURE_ROOT=str(state))
    return p, state, env

def upstash_calls(state):
    path = state / 'upstash-calls.jsonl'
    return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []


p, state, env = upstash_case('base-repro', upstash_settings={'max_upload_bytes': 8 * 1024 * 1024})
(p / 'work/payload').write_bytes(os.urandom(9 * 1024 * 1024))
r = launch(p, env, 'echo should-not-run', ('--input', 'payload'))
proof = dict(case='base-upload-cap-regression', exit=r.returncode, stdout=r.stdout.decode(), stderr=r.stderr.decode(), result=result(p), uploads=[x for x in upstash_calls(state) if x['operation']=='upload'])
print(json.dumps(proof))
assert r.returncode == 74 and result(p)['kind'] == 'adapter-error'
assert b'should-not-run' not in r.stdout
