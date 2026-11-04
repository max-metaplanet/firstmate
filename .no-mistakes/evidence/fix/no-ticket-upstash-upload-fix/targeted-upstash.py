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

p, state, env = upstash_case('observed-bundle', upstash_settings={'max_upload_bytes': 8 * 1024 * 1024})
payload = os.urandom(69_209_507)
(p / 'work/payload').write_bytes(payload)
digest = hashlib.sha256(payload).hexdigest()
del payload
r = launch(p, env, 'sha256sum payload > proof; echo working; cat tracked.txt',
           ('--input', 'payload', '--artifact', 'proof'))
assert r.returncode == 0, (r.stderr, result(p))
assert result(p)['kind'] == 'completed' and result(p)['cleanup'] == 'deleted'
assert 69_209_507 <= result(p)['upload_bytes'] < 70_000_000
assert (p / 'output/artifacts/proof').read_text().split()[0] == digest
assert b'working edit' in r.stdout
assert [x['operation'] for x in upstash_calls(state)].count('create') == 1
assert not list((p / 'output/upload').glob('upstash-parts-*'))
print('ok - observed 69.2 MB screened archive transfers intact under a smaller per-file ceiling')


print(json.dumps(dict(case='observed-bundle', result=result(p), proof=(p/'output/artifacts/proof').read_text(), upload_requests=[x for x in upstash_calls(state) if x['operation']=='upload'])))
for name, settings, local_allowed, expected in [
    ('remote', {}, True, 0),
    ('local', {'create_rejected': 429}, True, 23),
    ('no-local', {'create_rejected': 429}, False, 75),
    ('unknown-no-local', {'unknown_exec': True}, True, 74),
    ('upload-local', {'upload_error': True, 'upload_status': 400}, True, 23),
    ('upload-too-large', {'upload_error': True, 'upload_status': 413}, True, 23),
    ('upload-capacity', {'upload_error': True, 'upload_status': 429}, True, 23),
    ('upload-no-local', {'upload_error': True, 'upload_status': 400}, False, 69),
    ('upload-unknown', {'upload_error': True}, True, 74),
    ('upload-timeout', {'upload_error': True, 'upload_status': 408}, True, 74),
    ('upload-server-error', {'upload_error': True, 'upload_status': 500}, True, 74),
    ('upload-corrupt', {'corrupt_upload': True}, True, 74),
    ('upload-cleanup-pending', {'upload_error': True, 'upload_status': 400,
                              'delete_error': True}, True, 70),
]:
    p, state, env = upstash_case('wrapper-' + name, upstash_settings=settings)
    env.update(LOCAL_ONLY='yes', FM_BUILD_LOCK_FILE=str(p / 'heavy.lock'),
               FM_BOAT_TEST_UNAVAILABLE_WAIT_SECS='0',
               FM_BOAT_TEST_LOCAL_FALLBACK='1' if local_allowed else '0')
    command = 'if [ "${LOCAL_ONLY:-}" = yes ]; then touch local-ran; exit 23; fi; echo remote'
    r = subprocess.run(['bash', str(repo / 'bin/fm-boat-test-wrapper.sh'), command],
                       cwd=p / 'work', env=env, capture_output=True, timeout=30)
    print(json.dumps(dict(case=name, exit=r.returncode, local_ran=(p / 'work/local-ran').exists(), stderr=r.stderr.decode(), results=[json.loads(x.read_text()) for x in p.glob('.fm-test-scratch/fm-boat-test.*/boat-*/result.json')])))
    assert r.returncode == expected, (name, r.stderr)
    assert (p / 'work/local-ran').exists() == (name in (
        'local', 'upload-local', 'upload-too-large', 'upload-capacity'))
print('ok - real wrapper orders Boat then Upstash then permitted heavy-slot local fallback')
