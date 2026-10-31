#!/usr/bin/env bash
# Boat offload lifecycle, clean source transfer, failure/fallback boundaries,
# explicit artifacts, provider budgets, interrupts, lost responses and reaping.
set -euo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
CASE_ROOT=$(fm_test_tmproot fm-boat-run)
export CASE_ROOT
python3 - "$ROOT" <<'PY'
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

p, state, env = case('success')
r = launch(p, env, 'cat tracked.txt input.txt; test -z "$DEV_SECRET$BOAT_API_KEY$NODE_OPTIONS"; mkdir -p report; echo proof > report/file',
           ('--input', 'input.txt', '--artifact', 'report'))
assert r.returncode == 0, r.stderr
assert (p / 'output/artifacts/report/file').read_text() == 'proof\n'
assert b'working edit\nextra\n' in r.stdout
assert result(p)['remote_exit'] == 0
names = json.loads((state / 'uploaded.json').read_text())
assert names == ['input.txt', 'tracked.txt'], names
assert b'boat_fixture_secret' not in r.stdout + r.stderr
for home in map(json.loads, (state / 'cli-homes.jsonl').read_text().splitlines()):
    assert not Path(home).exists(), home
empty(state)
print('ok - source edits/deletions, explicit inputs, artifacts, credential isolation and short CLI HOME cleanup')
assert not (state / 'swap.json').exists()
p, state, env = case('swap')
assert launch(p, env, options=('--swap-gib', '4')).returncode == 0
assert json.loads((state / 'swap.json').read_text()) == 4
assert result(p)['swap_gib'] == 4
empty(state)
print('ok - remote swap is explicit and disabled by default')

p, state, env = case('local-slot-held')
env['FM_BUILD_LOCK_FILE'] = str(p / 'heavy.lock')
env.pop('FM_BUILD_LOCK_BYPASS', None)
holder_script = '''import pathlib,sys,time
p=pathlib.Path(sys.argv[1]); (p/'held').write_text('ready')
while not (p/'release').exists(): time.sleep(.05)
'''
holder = subprocess.Popen(['python3', str(repo / 'bin/fm-build-lock.py'), '--',
                           'python3', '-c', holder_script, str(p)], env=env,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE)
try:
    for _ in range(200):
        if (p / 'held').exists():
            break
        time.sleep(.05)
    else:
        raise AssertionError('local heavy slot never acquired')
    assert launch(p, env).returncode == 0
finally:
    (p / 'release').touch()
    out, err = holder.communicate(timeout=10)
assert holder.returncode == 0, err
empty(state)
print('ok - offload completes while the local heavy slot is occupied')

for name, command, code, options in [
    ('remote-failure', 'mkdir report; echo failure > report/log; exit 7', 7, ('--artifact', 'report')),
    ('timeout', 'sleep 10', 124, ('--timeout', '1')),
    ('missing-artifact', 'exit 0', 74, ('--artifact', 'missing')),
    ('link-artifact', 'ln -s /etc/passwd report', 74, ('--artifact', 'report')),
    ('nested-secret-artifact', 'mkdir report; echo secret > report/.env', 74, ('--artifact', 'report')),
]:
    p, state, env = case(name)
    r = launch(p, env, command, options)
    assert r.returncode == code, (name, r.returncode, r.stderr)
    if name == 'remote-failure':
        assert (p / 'output/artifacts/report/log').read_text() == 'failure\n'
    empty(state)
print('ok - remote failure, timeout, missing and symlink artifacts all delete the VM')

p, state, env = case('stderr')
r = launch(p, env, 'echo failure >&2; exit 9')
assert r.returncode == 9, r.stderr
assert b'failure' in (p / 'output/command.log').read_bytes()
empty(state)
print('ok - command log includes stderr on nonzero remote exit')

p, state, env = case('unsafe-return', {'unsafe_artifact': True})
r = launch(p, env, 'mkdir report; echo proof > report/log', ('--artifact', 'report'))
assert r.returncode == 2, r.stderr
assert not (p / 'escape').exists()
empty(state)
p, state, env = case('missing-terminal', {'missing_terminal': True})
assert launch(p, env, 'echo partial').returncode == 74
assert (p / 'output/command.log').read_text() == 'partial\n'
assert result(p)['kind'] == 'execution-unknown'
empty(state)
print('ok - unsafe returned archive and incomplete JSONL result fail closed')

for name, settings, code in [('rate', {'remaining': 0}, 75),
                             ('unreachable', {'unreachable': True}, 69),
                             ('pagination', {'hasMore': True}, 69)]:
    p, state, env = case(name, settings)
    r = launch(p, env)
    assert r.returncode == code, (name, r.stderr)
    assert result(p)['kind'] == 'unavailable'
    assert 'new' not in [a[0] for a in map(json.loads, (state / 'calls.jsonl').read_text().splitlines())]
print('ok - unavailable, rate limits and incomplete listing preserve explicit fallback')

p, state, env = case('capacity')
(state / 'fake-vms.json').write_text(json.dumps([{'id':'bx_foreign1'}, {'id':'bx_foreign2'}]))
assert launch(p, env).returncode == 75
assert len(json.loads((state / 'fake-vms.json').read_text())) == 2
p, state, env = case('daily')
(state / 'daily.json').write_text(json.dumps({'date': datetime.datetime.now(datetime.timezone.utc).date().isoformat(), 'attempts':75}))
assert launch(p, env).returncode == 75
print('ok - two-account-VM and local daily cap never create or delete foreign work')

p, state, env = case('concurrent')
workers = [launch(p, env, 'sleep 3', ('--output', str(p / ('output-' + str(i)))), wait=False)
           for i in range(2)]
for _ in range(200):
    calls = (state / 'calls.jsonl').read_text() if (state / 'calls.jsonl').exists() else ''
    if calls.count('--stream') == 2:
        break
    time.sleep(.05)
else:
    raise AssertionError('two jobs never started')
assert launch(p, env).returncode == 75
for worker in workers:
    out, err = worker.communicate(timeout=20)
    assert worker.returncode == 0, err
empty(state)
print('ok - concurrent admission runs two jobs and rejects a third')

for name, settings in [('push-failure', {'push_failed': True}),
                       ('transport', {'transport_failed': True})]:
    p, state, env = case(name, settings)
    r = launch(p, env)
    assert r.returncode == 74, r.stderr
    assert result(p)['kind'] != 'unavailable'
    empty(state)
p, state, env = case('lost-create', {'lost_create': True})
assert launch(p, env).returncode == 69
empty(state)
print('ok - failed upload/transport and lost create response clean up by recorded id/name')

p, state, env = case('delete-failed', {'delete_failed': True})
assert launch(p, env).returncode == 70
assert result(p)['cleanup'] == 'pending'
(state / 'fixture.json').write_text('{}')
assert reap(env).returncode == 0
assert reap(env).returncode == 0
empty(state)
print('ok - failed deletion is durable and reap is repeatable')

for sig in (signal.SIGTERM, signal.SIGINT):
    p, state, env = case('signal-' + str(sig))
    proc = launch(p, env, 'echo started; sleep 30', wait=False)
    for _ in range(200):
        if (state / 'calls.jsonl').exists() and '--stream' in (state / 'calls.jsonl').read_text():
            break
        time.sleep(.05)
    else:
        raise AssertionError('command never started')
    assert reap(env).returncode == 0  # must skip the live job
    assert len(json.loads((state / 'fake-vms.json').read_text())) == 1
    proc.send_signal(sig)
    out, err = proc.communicate(timeout=15)
    assert proc.returncode == 128 + sig, (sig, proc.returncode, err)
    empty(state)
print('ok - live reap skips active jobs; INT and TERM run cleanup')

p, state, env = case('unsafe-input')
assert launch(p, env, options=('--input', '.env')).returncode == 2
assert not (state / 'calls.jsonl').exists()
p, state, env = case('source-symlink')
(p / 'work/tracked.txt').unlink()
(p / 'work/tracked.txt').symlink_to('/etc/passwd')
assert launch(p, env).returncode == 2
assert not (state / 'calls.jsonl').exists()
print('ok - unsafe input and tracked symlink are rejected before Boat')

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


p, state, other, env, key1, key2, config = multi('ordered')
assert launch(p, env).returncode == 0
assert 'new' in calls(state) and not calls(other)
assert 'deletion' in calls(state)
print('ok - configured accounts preserve first-account priority')

for name, first in [('day', {'day_remaining': 0}), ('hour', {'hour_remaining': 0}),
                    ('minute', {'minute_remaining': 0}), ('disabled', {'canStart': False}),
                    ('paid', {'nextStartDollars': 1}), ('offline', {'unreachable': True}),
                    ('incomplete', {'hasMore': True})]:
    p, state, other, env, key1, key2, config = multi('skip-' + name, first)
    r = launch(p, env, 'test -z "$BOAT_API_KEY$DEV_SECRET"; echo second-account')
    assert r.returncode == 0, (name, r.stderr)
    assert 'new' not in calls(state) and 'new' in calls(other)
    assert b'second-account' in r.stdout
    assert b'boat_fixture' not in r.stdout + r.stderr
    job = next(json.loads(f.read_text()) for f in (state / 'jobs').glob('*.json'))
    assert job['account_key_file'] == str(key2) and job['cleanup'] == 'deleted'
    empty(other)
print('ok - account-specific provider budgets, costs and availability skip to the next key')

p, state, other, env, key1, key2, config = multi('missing-first-key')
key1.unlink()
assert launch(p, env).returncode == 0
empty(other)

for name, count, cap, expected in [('live-below', 5, 'live_cap=6', 0),
                                    ('live-full', 6, 'live_cap=6', 75),
                                    ('pending-below', 5, 'pending_cap=6', 0),
                                    ('pending-full', 6, 'pending_cap=6', 75)]:
    p, state, other, env, key1, key2, config = multi(name, {'remaining': 0}, caps=cap)
    if name.startswith('live'):
        (other / 'fake-vms.json').write_text(json.dumps([{'id': 'bx_foreign' + str(i)} for i in range(count)]))
    else:
        reserved(state, key2, count)
    r = launch(p, env)
    assert r.returncode == expected, (name, r.stderr)
    assert ('new' in calls(other)) == (expected == 0)
    if name.startswith('live'):
        assert len(json.loads((other / 'fake-vms.json').read_text())) == count
    else:
        assert all(json.loads(f.read_text())['cleanup'] == 'pending'
                   for f in (state / 'jobs').glob('reserved-*.json'))
print('ok - each configured live and pending cap allows its last slot and rejects overflow')

p, state, other, env, key1, key2, config = multi('per-account-daily')
today = datetime.datetime.now(datetime.timezone.utc).date().isoformat()
(state / 'daily.json').write_text(json.dumps({'date': today, 'attempts': 75}))
assert launch(p, env).returncode == 0
assert json.loads((state / 'daily.json').read_text())['attempts'] == 75
second_daily, = state.glob('daily-*.json')
assert json.loads(second_daily.read_text())['attempts'] == 1
second_daily.write_text(json.dumps({'date': today, 'attempts': 169}))
assert launch(p, env, options=('--output', str(p / 'last-slot'))).returncode == 0
assert json.loads(second_daily.read_text())['attempts'] == 170
assert launch(p, env, options=('--output', str(p / 'no-slot'))).returncode == 75
print('ok - default daily counter is preserved and second account has its own configured daily cap')

for name, settings in [('owned-reap', {'delete_failed': True}),
                        ('owned-lost-create', {'lost_create': True})]:
    p, state, other, env, key1, key2, config = multi(name, {'remaining': 0}, settings)
    (state / 'fake-vms.json').write_text(json.dumps([{'id': 'bx_fixture0'}]))
    r = launch(p, env)
    assert r.returncode == (70 if name == 'owned-reap' else 69), r.stderr
    assert len(json.loads((state / 'fake-vms.json').read_text())) == 1
    if name == 'owned-reap':
        config.unlink()
        (other / 'fixture.json').write_text('{}')
        assert reap(env).returncode == 0
        assert reap(env).returncode == 0
    empty(other)
    assert len(json.loads((state / 'fake-vms.json').read_text())) == 1
    assert 'delete' not in calls(state)
print('ok - lost-create cleanup and reap after removing config use the owning account only')

p, state, other, env, key1, key2, config = multi(
    'environment-list-cleanup', {'remaining': 0},
    {'required_environment': 'temp-max-dev', 'deletion_forbidden': True, 'delete_failed': True},
    caps='live_cap=6 pending_cap=6 daily_cap=170 environment=temp-max-dev cleanup_confirmation=list')
assert launch(p, env).returncode == 70
job = next(json.loads(f.read_text()) for f in (state / 'jobs').glob('*.json'))
assert job['cleanup_confirmation'] == 'list'
config.unlink()
(other / 'fixture.json').write_text(json.dumps({'deletion_forbidden': True}))
assert reap(env).returncode == 0
assert 'delete' in calls(other) and 'deletion' not in calls(other)
empty(other)
print('ok - environment-scoped create retains --no-env and list cleanup survives config removal')

p, state, other, env, key1, key2, config = multi(
    'list-cleanup', {'remaining': 0}, {'deletion_forbidden': True}, caps='cleanup_confirmation=list')
assert launch(p, env).returncode == 0
assert 'delete' in calls(other) and 'deletion' not in calls(other)
empty(other)
print('ok - list-based cleanup completes without the restricted deletion endpoint')

p, state, other, env, key1, key2, config = multi('legacy-reservations')
for i in range(2):
    (state / 'jobs' / ('legacy-' + str(i) + '.json')).write_text(json.dumps({'cleanup': 'pending'}))
assert launch(p, env).returncode == 0
assert 'new' not in calls(state)
empty(other)
print('ok - legacy pending records count against the default account only')

for index, text in enumerate(['', 'relative/path', '~/.config/boat/api-key live_cap=0',
                              '~/.config/boat/api-key live_cap=x', '~/.config/boat/api-key wrong=3',
                              '~/.config/boat/api-key cleanup_confirmation=invalid',
                              '~/.config/boat/api-key environment=',
                              '~/.config/boat/api-key live_cap=3 live_cap=4',
                              '~/.config/boat/api-key\n~/.config/boat/api-key', '"unterminated']):
    p, state, other, env, key1, key2, config = multi('invalid-config-' + str(index))
    config.write_text(text)
    assert launch(p, env).returncode == 2
    assert not calls(state) and not calls(other)
print('ok - invalid configuration fails before contacting any account')

p, state, other, env, key1, key2, config = multi('tracked-key-file', {'remaining': 0})
tracked_key = p / 'work/tracked.txt'
tracked_key.write_text(key2.read_text())
config.write_text(str(key1) + '\n' + str(tracked_key) + '\n')
assert launch(p, env, 'test ! -e tracked.txt').returncode == 0
assert json.loads((other / 'uploaded.json').read_text()) == []
assert launch(p, env, options=('--output', str(p / 'extra-key'), '--input', 'tracked.txt')).returncode == 2
empty(other)
print('ok - configured key files are excluded from tracked source and refused as extra inputs')

p, state, other, env, key1, key2, config = multi('both-full', {'remaining': 0}, {'remaining': 0})
assert launch(p, env).returncode == 75
assert 'new' not in calls(state) + calls(other)
print('ok - exhausted accounts return capacity unavailable without a create')

for name, contents, included in [
    ('npmrc-safe', 'registry=https://registry.npmjs.org/\n', True),
    ('npmrc-credential', '//registry.npmjs.org/:_authToken=fixture-only\n', False),
    ('role-security-safe', '# Security compliance\nReview changes.\n', True),
    ('role-release-safe', '# Release engineer\nReview release readiness.\n', True),
    ('role-secret', 'API_SECRET=fixture-only\n', False),
    ('settings-safe', '{"permissions":{"allow":["Bash(npm test)"]}}', True),
    ('settings-secret', '{"env":{"API_SECRET":"fixture-only"}}', False),
    ('settings-bearer', '{"header":"Bearer fixture-only"}', False),
    ('settings-private-key', '-----BEGIN PRIVATE KEY-----\nfixture-only', False),
    ('settings-postgresql', '{"env":{"DATABASE_URL":"postgresql://app:dbpass@db.internal/app"}}', False),
]:
    p, state, env = case(name)
    selected = '.npmrc' if name.startswith('npmrc') else '.claude/settings.json'
    if name == 'settings-postgresql':
        selected = '.claude/settings.local.json'
    if name.startswith('role-'):
        role = 'release-engineer' if name == 'role-release-safe' else 'security-compliance'
        selected = '.github/tools/jev/vendor/.claude/agents/' + role + '.md'
    target = p / 'work' / selected
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(contents)
    for secret_path in ('.ssh/file', '.aws/file', '.config/file', '.claude/unlisted.json',
                        '.github/tools/jev/vendor/.claude/agents/unlisted.md'):
        secret = p / 'work' / secret_path
        secret.parent.mkdir(parents=True, exist_ok=True)
        secret.write_text('excluded even without credentials')
    vendor = p / 'work/vendor/lib.js'
    vendor.parent.mkdir()
    vendor.write_text('module.exports = {}')
    git(p / 'work', 'add', '--force', '.')
    git(p / 'work', 'commit', '-qm', 'allowlist fixture')
    r = launch(p, env)
    assert r.returncode == 0, (name, r.stderr)
    uploaded = json.loads((state / 'uploaded.json').read_text())
    assert (selected in uploaded) == included, (name, uploaded)
    assert 'vendor/lib.js' in uploaded
    assert not any(x.startswith(('.ssh/', '.aws/', '.config/')) or x == '.claude/unlisted.json'
                   for x in uploaded)
    assert '.github/tools/jev/vendor/.claude/agents/unlisted.md' not in uploaded
    if not included:
        assert b'excluded allowlisted file' in r.stderr
        assert b'fixture-only' not in r.stdout + r.stderr
        assert b'dbpass' not in r.stdout + r.stderr
    empty(state)
print('ok - narrow clean settings upload, credential-bearing exceptions warn without content, secret paths stay excluded')

p, state, env = case('bounded-history', clean_history=True)
work = p / 'work'
for i in range(5):
    (work / 'tracked.txt').write_text('version ' + str(i) + '\n')
    git(work, 'add', 'tracked.txt')
    git(work, 'commit', '-qm', 'history ' + str(i))
git(work, 'update-ref', 'refs/remotes/origin/main', 'HEAD')
base_tip = git(work, 'rev-parse', 'HEAD').stdout.decode().strip()
old = git(work, 'rev-parse', 'HEAD~2').stdout.decode().strip()
git(work, 'checkout', '-qb', 'feature', 'HEAD~1')
(work / 'feature.txt').write_text('feature\n')
git(work, 'add', 'feature.txt')
git(work, 'commit', '-qm', 'feature tip')
head = git(work, 'rev-parse', 'HEAD').stdout.decode().strip()
git(work, 'config', 'remote.origin.url', 'https://user:fixture-only@example.invalid/repo')
git(work, 'update-ref', 'refs/heads/private-unrelated', old)
git(work, 'update-ref', 'refs/tags/private-tag', old)
git(work, 'update-ref', 'refs/stash', old)
(work / 'tracked.txt').write_text('dirty edit\n')
(work / 'deleted.txt').unlink(missing_ok=True)
check = """import pathlib,subprocess
def git(*args): return subprocess.check_output(['git',*args]).decode().strip()
assert git('rev-parse','HEAD') == head_tip
assert git('rev-parse','origin/main') == base_tip
assert git('rev-list','--count','--all') == '3'
assert subprocess.run(['git','cat-file','-e',old],capture_output=True).returncode != 0
assert set(git('for-each-ref','--format=%(refname)').splitlines()) == {'refs/heads/fm-boat-test','refs/remotes/origin/main'}
assert git('remote') == ''
assert not pathlib.Path('.git/logs').exists()
assert not pathlib.Path('.git/objects/info/alternates').exists()
assert pathlib.Path('tracked.txt').read_text() == 'dirty edit\\n'
assert not pathlib.Path('deleted.txt').exists()
assert git('status','--porcelain')
assert git('fsck','--no-reflogs') == ''
"""
check = f"head_tip={head!r}; base_tip={base_tip!r}; old={old!r}\n" + check
r = launch(p, env, 'python3 -c ' + shlex.quote(check), ('--history-depth', '2'))
assert r.returncode == 0, (r.stdout, r.stderr, result(p))
empty(state)
print('ok - real Git preserves both tips, bounded ancestry and tracked edits without unrelated refs/config/reflogs')

for name, unsafe_path, unsafe_content in [
    ('history-excluded', '.env', 'historical-value-never-print'),
    ('history-credential', 'ordinary.txt', 'API_SECRET=historical-value-never-print'),
    ('history-role-credential', '.github/tools/jev/vendor/.claude/agents/security-compliance.md',
     'password=historical-value-never-print'),
    ('history-binary', 'binary.dat', '\x00historical-value-never-print'),
]:
    p, state, env = case(name, clean_history=True)
    work = p / 'work'
    target = work / unsafe_path
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(unsafe_content)
    git(work, 'add', '--force', '.')
    git(work, 'commit', '-qm', 'unsafe older blob')
    target.unlink()
    git(work, 'add', '--all')
    git(work, 'commit', '-qm', 'clean current tree')
    git(work, 'update-ref', 'refs/remotes/origin/main', 'HEAD')
    r = launch(p, env, options=('--history-depth', '2'))
    assert r.returncode == 2, (name, r.stderr)
    assert b'history refused:' in r.stderr
    assert b'historical-value-never-print' not in r.stdout + r.stderr
    assert result(p)['kind'] == 'invalid'
    assert not (state / 'calls.jsonl').exists()
    assert not (p / 'output/upload/source.tar.gz').exists()
print('ok - excluded, credential-bearing and binary historical blobs refuse before Boat, without content')

for root_ref in ('HEAD', 'refs/remotes/origin/main'):
    for ancestor in (False, True):
        for field in ('message', 'author', 'committer', 'extra-header'):
            name = 'history-commit-' + root_ref.replace('/', '-') + '-' + str(ancestor) + '-' + field
            p, state, env = case(name, clean_history=True)
            work = p / 'work'
            git(work, 'update-ref', 'refs/remotes/origin/main', 'HEAD')
            raw = git(work, 'cat-file', 'commit', 'HEAD').stdout
            credential = b'API_SECRET=historical-commit-never-print'
            if field == 'message':
                raw = raw.split(b'\n\n', 1)[0] + b'\n\n' + credential + b'\n'
            elif field == 'extra-header':
                raw = raw.replace(b'\n\n', b'\nx-fixture ' + credential + b'\n\n', 1)
            else:
                raw = raw.replace(field.encode() + b' Fixture ', field.encode() + b' ' + credential + b' ', 1)
            unsafe = subprocess.run(['git', '-C', str(work), 'hash-object', '-t', 'commit', '-w', '--stdin'],
                                    input=raw, capture_output=True, check=True).stdout.decode().strip()
            tip = unsafe
            if ancestor:
                tree = git(work, 'rev-parse', 'HEAD^{tree}').stdout.decode().strip()
                tip = git(work, 'commit-tree', tree, '-p', unsafe, '-m', 'clean descendant').stdout.decode().strip()
            git(work, 'update-ref', root_ref, tip)
            r = launch(p, env, options=('--history-depth', '2'))
            assert r.returncode == 2, (name, r.stderr)
            assert b'history refused:' in r.stderr
            assert b'historical-commit-never-print' not in r.stdout + r.stderr
            assert result(p)['kind'] == 'invalid'
            assert not (state / 'calls.jsonl').exists()
            assert not (p / 'output/upload/source.tar.gz').exists()
print('ok - both history roots screen tip and ancestor commit messages and headers before Boat, without content')

p, state, env = case('history-missing-base', clean_history=True)
r = launch(p, env, options=('--history-depth', '2'))
assert r.returncode == 2 and b'origin/main' in r.stderr
assert not (state / 'calls.jsonl').exists()
for depth in ('0', '-1', '1001', 'not-a-number'):
    p, state, env = case('history-depth-' + depth)
    assert launch(p, env, options=('--history-depth', depth)).returncode == 2
    assert not (state / 'calls.jsonl').exists()
print('ok - history depth and required base fail closed')

p, state, other, env, key1, key2, config = multi('multi-concurrent')
workers = [launch(p, env, 'sleep 8', ('--output', str(p / ('output-' + str(i)))), wait=False)
           for i in range(8)]
try:
    for _ in range(240):
        stream_count = sum((q / 'calls.jsonl').read_text().count('--stream')
                           if (q / 'calls.jsonl').exists() else 0 for q in (state, other))
        if stream_count == 8:
            break
        time.sleep(.05)
    else:
        raise AssertionError('eight jobs never started')
    assert launch(p, env).returncode == 75
    assert calls(state).count('new') == 2 and calls(other).count('new') == 6
finally:
    for worker in workers:
        out, err = worker.communicate(timeout=20)
        assert worker.returncode == 0, err
empty(state)
empty(other)
print('ok - concurrent admission fills 2+6 account slots without oversubscription')

PY
