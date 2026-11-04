import datetime
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

def calls(state):
    path = state / 'calls.jsonl'
    return [json.loads(line)[0] for line in path.read_text().splitlines()] if path.exists() else []


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

p, state, env = upstash_case('boat-first', {'remaining': 20})
assert launch(p, env).returncode == 0
assert not upstash_calls(state)
assert result(p)['provider'] == 'boat'
print('ok - a successful Boat allocation never touches Upstash')

for window in ('hour', 'day'):
    p, state, env = upstash_case(window + '-all-accounts', {window + '_remaining': 0})
    other = state / 'account-2'
    other.mkdir()
    (other / 'fixture.json').write_text(json.dumps({window + '_remaining': 0}))
    key1 = Path(env['HOME']) / '.config/boat/api-key'
    key2 = Path(env['HOME']) / 'second-account'
    key2.write_text('boat_fixture_second')
    config = p / 'home/config/boat-keys'
    config.parent.mkdir()
    config.write_text(str(key1) + '\n' + str(key2) + '\n')
    r = launch(p, env)
    assert r.returncode == 0 and result(p)['provider'] == 'upstash', r.stderr
    assert calls(state) == ['limits', 'list'] and calls(other) == ['limits', 'list']
    assert [x['operation'] for x in upstash_calls(state)].count('create') == 1
print('ok - hour/day exhaustion tries every eligible Boat account before Upstash')

p, state, env = upstash_case('instance-sdk')
interpreter = state / 'upstash-sdk-0.4.0/bin/python3'
interpreter.parent.mkdir(parents=True)
interpreter.write_text('#!/bin/sh\nprintf selected > ' + shlex.quote(str(p / 'sdk-used')) +
                       '\nexec ' + shlex.quote(sys.executable) + ' "$@"\n')
interpreter.chmod(0o755)
assert launch(p, env).returncode == 0
assert (p / 'sdk-used').read_text() == 'selected'
print('ok - unchanged entry point automatically uses the reproducible instance-local SDK interpreter')

p, state, env = upstash_case('success')
r = launch(p, env, 'test -z "$DEV_SECRET$BOAT_API_KEY$UPSTASH_BOX_API_KEY$NODE_OPTIONS"; '
           'cat tracked.txt input.txt; mkdir report; echo proof > report/file',
           ('--input', 'input.txt', '--artifact', 'report'))
assert r.returncode == 0, r.stderr
assert b'working edit\nextra\n' in r.stdout
assert (p / 'output/artifacts/report/file').read_text() == 'proof\n'
assert result(p)['provider'] == 'upstash' and result(p)['actual_size'] == 'small'
assert result(p)['resources'] == {'cpu': 2, 'memory_gib': 4, 'disk_gib': 10}
assert result(p)['kind'] == 'completed' and result(p)['cleanup'] == 'deleted'
assert [x['operation'] for x in upstash_calls(state)].count('create') == 1
assert json.loads((state / 'upstash-vms.json').read_text()) == []
assert not (state / 'calls.jsonl').read_text().count('"new"')
assert b'upstash_fixture_secret' not in r.stdout + r.stderr
for path in (p / 'output').rglob('*'):
    if path.is_file():
        assert b'upstash_fixture_secret' not in path.read_bytes(), path
budget = next(state.glob('upstash-monthly-*.json'))
assert json.loads(budget.read_text())['reserved_cpu_seconds'] == 2 * (1800 + 900 + 180)
print('ok - Boat quota falls back to one free small box with screened source, artifacts and cleanup')

for name, settings, expected in [
    ('env', {'account_env': True}, 69),
    ('readonly-failure', {'list_error': True}, 69),
    ('create-cap', {'create_rejected': 429}, 75),
    ('create-budget', {'create_rejected': 402}, 75),
    ('create-unauthenticated', {'create_rejected': 401}, 69),
    ('create-auth', {'create_rejected': 403}, 69),
]:
    p, state, env = upstash_case(name, upstash_settings=settings)
    r = launch(p, env)
    assert r.returncode == expected, (name, r.stderr)
    assert result(p)['kind'] == 'unavailable', result(p)
    assert b'upstash_fixture_secret' not in r.stdout + r.stderr
    assert not any(x['operation'] == 'exec' for x in upstash_calls(state))
print('ok - account environment, read-only failure and explicit create rejection remain unavailable')

for status, expected in ((401, 69), (403, 69), (402, 75), (429, 75)):
    p, state, env = upstash_case('reservation-refund-' + str(status))
    assert launch(p, env).returncode == 0
    budget = next(state.glob('upstash-monthly-*.json'))
    prior = json.loads(budget.read_text())
    assert prior['reserved_cpu_seconds'] == 5760
    (state / 'upstash.json').write_text(json.dumps({'create_rejected': status}))
    for attempt in range(3):
        (p / 'output').rename(p / ('output-' + str(attempt)))
        r = launch(p, env)
        assert r.returncode == expected and result(p)['kind'] == 'unavailable', r.stderr
        assert json.loads(budget.read_text()) == prior
        records = [json.loads(path.read_text()) for path in (state / 'jobs').glob('*.json')]
        rejected = [job for job in records if not job['create_started']]
        assert len(rejected) == attempt + 1
        assert all(job['reserved_cpu_seconds'] == 0 and job['cleanup'] == 'deleted'
                   for job in rejected)
    (p / 'output').rename(p / 'output-rejected')
    (state / 'upstash.json').write_text('{}')
    assert launch(p, env).returncode == 0
    assert json.loads(budget.read_text())['reserved_cpu_seconds'] == 11520
    assert [x['operation'] for x in upstash_calls(state)].count('create') == 5
print('ok - confirmed create rejections refund only their reservation and allow later admission')

for machine_type, swap in [('large', '0'), ('xlarge', '0'), ('default', '1')]:
    p, state, env = upstash_case('resources-' + machine_type + swap)
    (p / 'home/config').mkdir()
    key = Path(env['HOME']) / '.config/boat/api-key'
    (p / 'home/config/boat-keys').write_text(str(key) + ' types=default,large,xlarge\n')
    r = launch(p, env, options=('--type', machine_type, '--swap-gib', swap))
    assert r.returncode == 69 and result(p)['kind'] == 'unavailable', r.stderr
    assert not upstash_calls(state)
print('ok - explicit large/xlarge and swap never silently downgrade to free small')

p, state, env = upstash_case('capacity')
(state / 'upstash-vms.json').write_text(json.dumps([
    dict(id='foreign-' + str(i), name='foreign', labels=[], status='paused') for i in range(10)]))
assert launch(p, env).returncode == 75
assert not any(x['operation'] in ('create', 'delete') for x in upstash_calls(state))
p, state, env = upstash_case('budget')
import hashlib
key = Path(env['HOME']) / '.config/upstash/box-api-key'
identity = hashlib.sha256(os.fsencode(key)).hexdigest()
month = datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m')
(state / ('upstash-monthly-' + identity + '.json')).write_text(json.dumps(
    dict(month=month, reserved_cpu_seconds=5 * 3600)))
assert launch(p, env).returncode == 75
assert not any(x['operation'] == 'create' for x in upstash_calls(state))
print('ok - read-only box capacity and durable monthly reservation exhaustion prevent compute')

for name, settings, command, expected_kind in [
    ('lost-create', {'lost_create': True}, 'exit 0', 'adapter-error'),
    ('unknown-exec', {'unknown_exec': True}, 'echo once', 'execution-unknown'),
    ('missing-marker', {'missing_marker': True}, 'exit 0', 'execution-unknown'),
    ('secret-response', {'secret_output': True}, 'exit 0', 'adapter-error'),
    ('truncated', {'truncated': True}, 'exit 0', 'adapter-error'),
]:
    p, state, env = upstash_case(name, upstash_settings=settings)
    r = launch(p, env, command)
    assert r.returncode == 74, (name, r.stderr, result(p))
    assert result(p)['kind'] == expected_kind, (name, result(p))
    assert result(p)['cleanup'] == 'deleted'
    assert [x['operation'] for x in upstash_calls(state)].count('create') == 1
    assert b'upstash_fixture_secret' not in r.stdout + r.stderr
    assert json.loads((state / 'upstash-vms.json').read_text()) == []
    budget = next(state.glob('upstash-monthly-*.json'))
    assert json.loads(budget.read_text())['reserved_cpu_seconds'] == 5760
print('ok - lost create, unknown execution, incomplete markers and credential responses never retry')

for code in (7, 69, 75, 124):
    p, state, env = upstash_case('completed-' + str(code))
    r = launch(p, env, 'mkdir report; echo failed > report/log; exit ' + str(code),
               ('--artifact', 'report'))
    assert r.returncode == code and result(p)['kind'] == 'completed', r.stderr
    assert result(p)['remote_exit'] == code and result(p)['cleanup'] == 'deleted'
    assert (p / 'output/artifacts/report/log').read_text() == 'failed\n'
    assert [x['operation'] for x in upstash_calls(state)].count('create') == 1
print('ok - Upstash failed remote exits preserve artifacts and never become unavailable')

p, state, env = upstash_case('reap', upstash_settings={'delete_error': True})
r = launch(p, env)
assert r.returncode == 70 and result(p)['cleanup'] == 'pending', r.stderr
records = list((state / 'jobs').glob('*.json'))
assert len(records) == 1 and json.loads(records[0].read_text())['provider'] == 'upstash'
(state / 'upstash.json').write_text('{}')
assert reap(env).returncode == 0
assert reap(env).returncode == 0
assert json.loads(records[0].read_text())['cleanup'] == 'deleted'
assert json.loads((state / 'upstash-vms.json').read_text()) == []
print('ok - failed Upstash cleanup retains a provider-owned record and reap converges')

p, state, env = upstash_case('boat-lost-create', {'lost_create': True})
r = launch(p, env)
assert r.returncode != 0 and result(p)['kind'] != 'unavailable'
assert not upstash_calls(state)
print('ok - an unknown Boat create cannot run a second provider even when cleanup succeeds')

for name, settings, local_allowed, expected in [
    ('remote', {}, True, 0),
    ('local', {'create_rejected': 429}, True, 23),
    ('no-local', {'create_rejected': 429}, False, 75),
    ('unknown-no-local', {'unknown_exec': True}, True, 74),
]:
    p, state, env = upstash_case('wrapper-' + name, upstash_settings=settings)
    env.update(LOCAL_ONLY='yes', FM_BUILD_LOCK_FILE=str(p / 'heavy.lock'),
               FM_BOAT_TEST_UNAVAILABLE_WAIT_SECS='0',
               FM_BOAT_TEST_LOCAL_FALLBACK='1' if local_allowed else '0')
    command = 'if [ "${LOCAL_ONLY:-}" = yes ]; then touch local-ran; exit 23; fi; echo remote'
    r = subprocess.run(['bash', str(repo / 'bin/fm-boat-test-wrapper.sh'), command],
                       cwd=p / 'work', env=env, capture_output=True, timeout=30)
    assert r.returncode == expected, (name, r.stderr)
    assert (p / 'work/local-ran').exists() == (name == 'local')
print('ok - real wrapper orders Boat then Upstash then permitted heavy-slot local fallback')
