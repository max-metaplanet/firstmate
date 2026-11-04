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
import fcntl
import hashlib
import json
import os
import runpy
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

def managed(p, env, task='reuse-task', generation='generation-1'):
    (p / 'home/state' / (task + '.meta')).write_text(
        'endpoint_task_id=' + task + '\nkind=ship\nspawn_gen=' + generation +
        '\nworktree=' + str(p / 'work') + '\n')
    return dict(env, FM_TASK_ID=task, FM_TASK_GENERATION=generation)

def next_run(p, env, command='exit 0', options=(), wait=True):
    output = p / 'output'
    if output.exists():
        output.rename(p / ('output-' + str(len(list(p.glob('output*'))))))
    return launch(p, env, command, options, wait)

def cleanup_task(env, task='reuse-task', generation='generation-1'):
    return subprocess.run(['bash', str(repo / 'bin/fm-boat-run.sh'), 'cleanup-task',
                           '--task', task, '--generation', generation],
                          env=env, capture_output=True, timeout=20)

def bookkeeping_holders(record):
    lockfile = record.parent.parent / (record.stem + '.lock')
    identity = lockfile.stat()
    holders = []
    for line in Path('/proc/locks').read_text().splitlines():
        fields = line.split()
        if '->' in fields:
            continue
        major, minor, inode = fields[5].split(':')
        if (int(major, 16), int(minor, 16), int(inode)) != (
                os.major(identity.st_dev), os.minor(identity.st_dev), identity.st_ino):
            continue
        process = Path('/proc') / fields[4]
        try:
            command = (process / 'cmdline').read_bytes().split(b'\0')
        except FileNotFoundError:
            continue
        expected = os.fsencode(repo / 'bin/fm-boat-run.py')
        assert command[1:5] == [expected, b'expire', b'--lease', record.stem.encode()] or (
            command[1:3] == [expected, b'reap']), ('unexpected fixture lock holder', fields[4], command)
        matching_fds = []
        try:
            descriptors = list((process / 'fd').iterdir())
        except FileNotFoundError:
            continue
        for fd in descriptors:
            try:
                target = fd.stat()
                if (target.st_dev, target.st_ino) == (identity.st_dev, identity.st_ino):
                    matching_fds.append((process / 'fdinfo' / fd.name).read_text())
            except FileNotFoundError:
                pass
        if not matching_fds:
            continue
        holders.append(dict(pid=int(fields[4]), kernel=line, fds=matching_fds))
    return holders


def wait_for_expiry_cleanup(record):
    lockfile = record.parent.parent / (record.stem + '.lock')
    seen = []
    for _ in range(200):
        seen.extend(bookkeeping_holders(record))
        with lockfile.open('r') as handle:
            try:
                fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                pass
            else:
                assert json.loads(record.read_text())['cleanup'] == 'deleted'
                (record.parent.parent / 'expiry-holder-proof.json').write_text(json.dumps(seen))
                return
        time.sleep(.1)
    raise AssertionError('identified fixture expiry holder did not finish cleanup')


def creates(state):
    return sum(json.loads(line)[0] == 'new' for line in (state / 'calls.jsonl').read_text().splitlines())

def permission_case(name, boundary, settings=None, reused=False):
    p, state, env = case(name, settings)
    env = managed(p, env)
    if reused:
        assert launch(p, env).returncode == 0
        (p / 'output').rename(p / 'initial-output')
    prefix = '''import errno,json,os,signal,subprocess,sys
original_wait = subprocess.Popen.wait
def waited(self, *args, **kwargs):
    code = original_wait(self, *args, **kwargs)
    if self.args[0] == 'timeout':
        def denied(target, number):
            owned = int((root/'source/child.pid').read_text())
            assert number == signal.SIGKILL
            assert os.getpgid(owned) == target if BOUNDARY == 'killpg' else target == owned
            if BOUNDARY == 'kill':
                assert os.getsid(owned) == os.getpgid(owned) == owned
                assert b'FM_BOAT_RUN_TOKEN=' not in open('/proc/'+str(owned)+'/environ', 'rb').read()
            print(json.dumps(dict(injected=BOUNDARY, target=target,
                effective_uid=os.geteuid(), survivor_uid=os.stat('/proc/'+str(owned)).st_uid)),
                file=sys.stderr, flush=True)
            raise PermissionError(errno.EPERM, 'injected signal permission refusal')
        setattr(os, BOUNDARY, denied)
    return code
subprocess.Popen.wait = waited
'''.replace('BOUNDARY', repr(boundary))
    shim = p / 'signal-cli.py'
    shim.write_text('''import runpy,subprocess,sys
fixture = sys.argv.pop(1)
original_popen = subprocess.Popen
def start(argv, *args, **kwargs):
    if len(argv) > 4 and argv[:2] == ['python3', '-c'] and argv[4] == 'run':
        argv = list(argv)
        argv[2] = PREFIX + argv[2]
    return original_popen(argv, *args, **kwargs)
subprocess.Popen = start
runpy.run_path(fixture, run_name='__main__')
'''.replace('PREFIX', repr(prefix)))
    (p / 'boat').write_text('#!/bin/sh\nexec python3 ' + shlex.join(
        [str(shim), str(fixture), str(state)]) + ' "$@"\n')
    survivor = 'sleep 2 >/dev/null 2>&1 & echo $! > child.pid'
    if boundary == 'kill':
        survivor = ('mkfifo ready; setsid env -i PATH="$PATH" sh -c '
                    "'echo $$ > ready; exec sleep 2' >/dev/null 2>&1 & "
                    'read -r pid < ready; echo "$pid" > child.pid')
    r = launch(p, env, 'echo dispatch >> dispatched; echo preserved-output; ' +
               survivor + '; exit 7')
    remote = state / 'bx_fixture0/fm-job/source'
    assert (remote / 'dispatched').read_text() == 'dispatch\n'
    calls = [json.loads(line) for line in (state / 'calls.jsonl').read_text().splitlines()]
    assert creates(state) == 1
    assert sum(call[0] == 'exec' and '--stream' in call for call in calls) == (2 if reused else 1)
    assert all(call[call.index('--ttl') + 1] == '7200' for call in calls if call[0] == 'new')
    pid = int((remote / 'child.pid').read_text())
    path = Path('/proc') / str(pid) / 'stat'
    deadline = time.monotonic() + 4
    while path.exists() and time.monotonic() < deadline:
        if path.read_text().rsplit(')', 1)[1].split()[0] == 'Z':
            break
        time.sleep(.05)
    assert not path.exists() or path.read_text().rsplit(')', 1)[1].split()[0] == 'Z', pid
    return p, state, env, r

if sys.platform.startswith('linux'):
    sentinel = subprocess.Popen(['sleep', '90'])
    try:
        for boundary in ('killpg', 'kill'):
            for reused in (False, True):
                p, state, env, r = permission_case('permission-' + boundary + '-' + str(reused),
                                                  boundary, reused=reused)
                evidence = result(p)
                assert r.returncode == 74 and r.stdout == b'preserved-output\n', (r.stderr, evidence)
                assert evidence['kind'] == 'completed' and evidence['remote_exit'] == 7, evidence
                assert evidence['reused'] == reused and evidence['cleanup'] == 'deleted', evidence
                cleanup = evidence['process_cleanup']
                assert cleanup['state'] == 'refused' and cleanup['operation'] == boundary, cleanup
                assert cleanup['errno'] == 1 and cleanup['effective_uid'] == os.geteuid(), cleanup
                assert cleanup['target'] > 0 and evidence['lease']['state'] != 'idle', evidence
                assert b'injected' in (p / 'output/command.log').read_bytes()
                assert sentinel.poll() is None
                calls = [json.loads(line) for line in (state / 'calls.jsonl').read_text().splitlines()]
                assert [call[1] for call in calls if call[0] == 'delete'] == [evidence['vm_id']]
                empty(state)
        print('ok - injected post-wait group and adopted-child signal refusal preserves exit/output, deletes exact leases and never retries', flush=True)

        p, state, env, r = permission_case('permission-no-terminal', 'killpg',
                                           {'missing_terminal': True})
        assert r.returncode == 74 and result(p)['kind'] == 'execution-unknown', (r.stderr, result(p))
        assert result(p)['remote_exit'] is None and result(p)['cleanup'] == 'deleted'
        assert b'preserved-output' in (p / 'output/command.log').read_bytes()
        empty(state)
        print('ok - missing terminal evidence remains unknown after signal refusal and confirmed deletion', flush=True)

        p, state, env, r = permission_case('permission-delete-failed', 'killpg',
                                           {'delete_failed': True})
        evidence = result(p)
        assert r.returncode == 70 and evidence['cleanup'] == 'pending', (r.stderr, evidence)
        assert evidence['kind'] == 'completed' and evidence['remote_exit'] == 7, evidence
        job = json.loads(next((state / 'jobs').glob('*.json')).read_text())
        assert job['lease_state'] != 'idle' and job['ttl'] == 7200, job
        (state / 'fixture.json').write_text('{}')
        assert reap(env).returncode == 0 and creates(state) == 1
        empty(state)
        print('ok - unconfirmed deletion quarantines the lease and reap deletes it without execution', flush=True)
    finally:
        sentinel.terminate()
        sentinel.wait()

def launch_lost_response(p, state, env, fault):
    driver = p / 'lost-response.py'
    driver.write_text('''import importlib.util, pathlib, subprocess, sys, time
spec = importlib.util.spec_from_file_location('adapter', sys.argv.pop(1))
adapter = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = adapter
spec.loader.exec_module(adapter)
state = pathlib.Path(sys.argv.pop(1))
fault = sys.argv.pop(1)
real_popen = subprocess.Popen
class LostResponse(real_popen):
    def communicate(self, *args, timeout=None, **kwargs):
        value = super().communicate(*args, timeout=timeout, **kwargs)
        if timeout is None:
            return value
        upload = self.args[1] == 'scp' and not self.args[2].startswith('bx_')
        verify = self.args[1] == 'exec' and 'sha256sum -c' in self.args[-1]
        command = self.args[1] == 'exec' and '--stream' in self.args
        mkdir = self.args[1] == 'exec' and 'mkdir' in self.args
        prepare = self.args[1] == 'exec' and 'prepare' in self.args
        if prepare and fault.startswith('reset-'):
            marker = state / 'reset-transport-failed'
            if not marker.exists() or fault == 'reset-timeout-persistent':
                marker.touch()
                if fault == 'reset-cli':
                    self.returncode = 1
                    return b'', b'transport unavailable'
                if fault == 'reset-missing':
                    return b'', b''
                raise subprocess.TimeoutExpired(self.args, timeout)
        if fault.startswith('reset-'):
            return value
        if upload and fault != 'mkdir-unknown':
            archive = state / self.args[3].split(':', 1)[0] / 'fm-job/source.tar.gz'
            if fault == 'missing':
                archive.unlink()
            elif fault == 'partial':
                archive.write_bytes(archive.read_bytes()[:10])
            elif fault == 'mismatch':
                data = archive.read_bytes()
                archive.write_bytes(bytes([data[0] ^ 1]) + data[1:])
            elif fault == 'owner-changed':
                meta = state.parent / 'reuse-task.meta'
                meta.write_text(meta.read_text().replace('generation-1', 'generation-2'))
            elif fault == 'expired':
                now = time.time()
                time.time = lambda: now + 7200
        if ((upload and fault != 'mkdir-unknown') or (verify and fault == 'verify-unknown')
                or (command and fault == 'command-unknown') or (mkdir and fault == 'mkdir-unknown')):
            raise subprocess.TimeoutExpired(self.args, timeout, output=b'boat_fixture_secret')
        return value
subprocess.Popen = LostResponse
sys.exit(adapter.main())
''')
    return subprocess.run([sys.executable, str(driver), str(repo / 'bin/fm-boat-run.py'),
                           str(state), fault, 'run', '--worktree', str(p / 'work'),
                           '--output', str(p / 'output'), '--', 'cat', 'tracked.txt'],
                          env=env, capture_output=True, timeout=30)

if sys.platform.startswith('linux'):
    for failure in ('push_failed_once', 'push_failed', 'prepare_failed', 'corrupt_upload'):
        p, state, env = case('fresh-owned-' + failure, {failure: True})
        env = managed(p, env)
        r = launch(p, env, 'echo must-not-run')
        evidence = result(p)
        assert r.returncode == 74, (failure, r.returncode, r.stdout, r.stderr, evidence)
        assert evidence['kind'] == 'adapter-error' and evidence['remote_exit'] is None, evidence
        assert evidence['creates'] == creates(state) == 1, (failure, evidence)
        assert not evidence.get('reuse_fallback'), evidence
        calls = [json.loads(line) for line in (state / 'calls.jsonl').read_text().splitlines()]
        assert not any('--stream' in call for call in calls), (failure, calls)
        assert b'must-not-run' not in r.stdout
        empty(state)
    print('ok - fresh owned source failures preserve the first error and delete without another start', flush=True)

    for ownership in ('fresh', 'reused', 'unowned'):
        p, state, env = case('complete-upload-lost-response-' + ownership)
        if ownership != 'unowned':
            env = managed(p, env)
        if ownership == 'reused':
            assert launch(p, env).returncode == 0
            (p / 'output').rename(p / 'initial-output')
        r = launch_lost_response(p, state, env, 'complete')
        evidence = result(p)
        calls = [json.loads(line) for line in (state / 'calls.jsonl').read_text().splitlines()]
        commands = sum('--stream' in call for call in calls)
        assert creates(state) == 1 and not evidence.get('reuse_fallback'), evidence
        assert 'boat_fixture_secret' not in json.dumps(evidence)
        assert b'boat_fixture_secret' not in r.stdout + r.stderr
        if ownership == 'unowned':
            assert r.returncode == 74 and evidence['kind'] == 'adapter-error', (r.stderr, evidence)
            assert evidence['remote_exit'] is None and commands == 0, evidence
        else:
            assert r.returncode == 0 and r.stdout.endswith(b'working edit\n'), (r.stderr, r.stdout, evidence)
            assert evidence['kind'] == 'completed' and evidence['remote_exit'] == 0, evidence
            assert evidence['upload_recovered'] and evidence['cleanup'] == 'retained', evidence
            assert commands == (2 if ownership == 'reused' else 1), calls
            archive = p / 'output/upload/source.tar.gz'
            assert archive.stat().st_size == evidence['upload_bytes']
            assert hashlib.sha256(archive.read_bytes()).hexdigest() == evidence['source_sha256']
            assert cleanup_task(env).returncode == 0
        empty(state)
    print('ok - a complete exact owned archive survives a lost scp response and executes once', flush=True)

    for fault in ('missing', 'partial', 'mismatch', 'verify-unknown', 'command-unknown',
                  'mkdir-unknown', 'owner-changed', 'expired'):
        p, state, env = case('lost-response-' + fault)
        env = managed(p, env)
        r = launch_lost_response(p, state, env, fault)
        evidence = result(p)
        calls = [json.loads(line) for line in (state / 'calls.jsonl').read_text().splitlines()]
        assert r.returncode == 74 and evidence['remote_exit'] is None, (fault, r.stderr, evidence)
        assert evidence['kind'] == ('execution-unknown' if fault == 'command-unknown'
                                    else 'adapter-error'), (fault, evidence)
        assert sum('--stream' in call for call in calls) == (fault == 'command-unknown'), (fault, calls)
        assert creates(state) == evidence['creates'] == 1 and not evidence.get('reuse_fallback'), evidence
        assert 'TimeoutExpired' in evidence['error'], (fault, evidence)
        assert 'boat_fixture_secret' not in json.dumps(evidence)
        assert b'boat_fixture_secret' not in r.stdout + r.stderr
        empty(state)
    print('ok - incomplete, mismatched, unknown, stale and expired transfers never authorize execution or another start', flush=True)

for history_mode in (False, True):
    for selection in ('untracked', 'committed', 'staged'):
        p, state, env = case('source-selection-' + selection + '-' + str(history_mode),
                             clean_history=True)
        work = p / 'work'
        files = {'new source.ts': b'current new source\n',
                 'tab\tand\nnewline.ts': b'pathname proof\x00\xff\n'}
        for name, data in files.items():
            (work / name).write_bytes(b'index bytes\n' if selection == 'staged' else data)
        if selection != 'untracked':
            git(work, 'add', '--', *files)
        if selection == 'committed':
            git(work, 'commit', '-qm', 'new source fixture')
        if selection == 'staged':
            for name, data in files.items():
                (work / name).write_bytes(data)
        head = git(work, 'rev-parse', 'HEAD').stdout.decode().strip()
        git(work, 'update-ref', 'refs/remotes/origin/main', head)
        options = ('--history-depth', '1') if history_mode else ()
        r = launch(p, env, options=options)
        assert r.returncode == 0, (selection, history_mode, r.stderr)
        with tarfile.open(p / 'output/upload/source.tar.gz') as archive:
            names = set(archive.getnames())
            expected = {'tracked.txt'} | (set(files) if selection != 'untracked' else set())
            actual = {name for name in names if name != '.git' and not name.startswith('.git/')}
            assert actual == expected, (selection, history_mode, actual, expected)
            assert archive.extractfile('tracked.txt').read() == b'working edit\n'
            for name, data in files.items():
                if selection != 'untracked':
                    assert archive.extractfile(name).read() == data, name
        assert result(p)['source_head'] == head
        assert result(p)['history'] == ('screened' if history_mode else 'synthetic')
        assert hashlib.sha256((p / 'output/upload/source.tar.gz').read_bytes()).hexdigest() == result(p)['source_sha256']
        empty(state)
        print('ok - actual archive source selection and bytes for ' + selection +
              ', history=' + str(history_mode), flush=True)

for history_mode in (False, True):
    p, state, env = case('index-changes-' + str(history_mode), clean_history=True)
    work = p / 'work'
    git(work, 'mv', 'tracked.txt', 'renamed.txt')
    (work / 'renamed.txt').write_bytes(b'after staged rename\n')
    (work / 'gone.ts').write_bytes(b'staged then deleted\n')
    (work / '.env.staged').write_bytes(b'never upload\n')
    (work / '.npmrc').write_bytes(b'_authToken=fixture-never-upload\n')
    key = work / 'account-material.txt'
    key.write_bytes(b'boat_fixture_secret')
    (p / 'home/config').mkdir()
    (p / 'home/config/boat-keys').write_text(str(key) + '\n')
    git(work, 'add', '--force', '.')
    (work / 'gone.ts').unlink()
    (work / 'deleted.txt').write_bytes(b'restored after staged deletion\n')
    head = git(work, 'rev-parse', 'HEAD').stdout.decode().strip()
    git(work, 'update-ref', 'refs/remotes/origin/main', head)
    options = ('--history-depth', '1') if history_mode else ()
    r = launch(p, env, options=options)
    assert r.returncode == 0, r.stderr
    with tarfile.open(p / 'output/upload/source.tar.gz') as archive:
        names = {name for name in archive.getnames() if name != '.git' and not name.startswith('.git/')}
        assert names == {'renamed.txt', 'deleted.txt', 'input.txt', 'unselected.txt'}, names
        assert archive.extractfile('deleted.txt').read() == b'restored after staged deletion\n'
        assert archive.extractfile('renamed.txt').read() == b'after staged rename\n'
    assert b'fixture-never-upload' not in r.stdout + r.stderr
    assert result(p)['source_head'] == head
    assert result(p)['history'] == ('screened' if history_mode else 'synthetic')
    empty(state)

    for label, target, accepted in [('inside', 'tracked.txt', True),
                                     ('absolute', '/etc/passwd', False),
                                     ('escape', '../outside', False)]:
        p, state, env = case('staged-link-' + label + '-' + str(history_mode), clean_history=True)
        work = p / 'work'
        (work / 'link').symlink_to(target)
        git(work, 'add', '--', 'link')
        git(work, 'update-ref', 'refs/remotes/origin/main', 'HEAD')
        r = launch(p, env, options=options)
        assert r.returncode == (0 if accepted else 2), (label, r.stderr)
        if accepted:
            with tarfile.open(p / 'output/upload/source.tar.gz') as archive:
                assert 'link' not in archive.getnames()
            empty(state)
        else:
            assert not (state / 'calls.jsonl').exists()
print('ok - staged renames/deletions, secret paths, key files and symlinks keep existing screening')

p, state, env = case('archive-file-copy', {'directory_push_refused': True})
(p / 'work/payload').write_bytes(os.urandom(8 * 1024 * 1024))
r = launch(p, env, 'sha256sum payload; cat tracked.txt', ('--input', 'payload'))
assert r.returncode == 0, r.stderr
assert hashlib.sha256((p / 'work/payload').read_bytes()).hexdigest().encode() in r.stdout
assert b'working edit' in r.stdout
assert result(p)['kind'] == 'completed' and result(p)['remote_exit'] == 0
assert result(p)['upload_bytes'] >= 8 * 1024 * 1024
assert hashlib.sha256((p / 'output/upload/source.tar.gz').read_bytes()).hexdigest() == result(p)['source_sha256']
assert json.loads((state / 'uploaded.json').read_text()) == ['payload', 'tracked.txt']
empty(state)
print('ok - prepared source reaches execution when directory synchronization is unavailable')

p, state, env = case('corrupted-archive-copy', {'corrupt_upload': True})
r = launch(p, env, 'echo user-command-ran')
assert r.returncode == 74 and result(p)['remote_exit'] is None, (r.stderr, result(p))
assert b'user-command-ran' not in r.stdout
empty(state)
print('ok - exact archive hash verification refuses corrupted transport before user execution')

if sys.platform.startswith('linux'):
    p, state, env = case('task-reuse')
    env = managed(p, env)
    r = launch(p, env, 'echo dirty > leftover; echo cache > "$HOME/cache"; '
               'sleep 90 >/dev/null 2>&1 & echo $!; setsid sleep 90 >/dev/null 2>&1 & echo $!')
    assert r.returncode == 0, r.stderr
    first = result(p)
    assert first['cleanup'] == 'retained' and not first['reused'], first
    assert first['process_cleanup'] == {'state': 'confirmed'}, first
    pids = [int(line) for line in r.stdout.splitlines()]
    for pid in pids:
        path = Path('/proc') / str(pid) / 'stat'
        assert not path.exists() or path.read_text().split(') ')[1].startswith('Z'), pid
    (p / 'work/tracked.txt').write_text('fresh second source\n')
    (state / 'fixture.json').write_text(json.dumps(dict(remaining=0, canStart=False, nextStartDollars=.03)))
    r = next_run(p, env, 'test ! -e leftover && test ! -e "$HOME/cache" && cat tracked.txt')
    assert r.returncode == 0 and r.stdout == b'fresh second source\n', (r.returncode, r.stderr, r.stdout)
    assert result(p)['reused'] and result(p)['vm_id'] == first['vm_id'], result(p)
    assert result(p)['process_cleanup'] == {'state': 'confirmed'}, result(p)
    assert creates(state) == 1
    assert reap(env).returncode == 0 and json.loads((state / 'fake-vms.json').read_text())
    assert cleanup_task(env).returncode == 0
    assert cleanup_task(env).returncode == 0
    empty(state)
    r = next_run(p, env)
    assert r.returncode == 70 and creates(state) == 1, (r.returncode, r.stderr)
    print('ok - task reuse saves a start despite exhausted start windows, refreshes source/HOME and kills owned sessions')

    for mutation in ('missing-generation', 'stale-generation', 'missing-task', 'duplicate-meta'):
        p, state, env = case('frozen-' + mutation)
        env = managed(p, env)
        if mutation == 'missing-generation':
            env.pop('FM_TASK_GENERATION')
        elif mutation == 'stale-generation':
            env['FM_TASK_GENERATION'] = 'older-launch'
        elif mutation == 'missing-task':
            env.pop('FM_TASK_ID')
        else:
            with (p / 'home/state/reuse-task.meta').open('a') as stream:
                stream.write('spawn_gen=generation-1\n')
        r = launch(p, env)
        if mutation == 'missing-generation':
            assert r.returncode == 0 and result(p)['cleanup'] == 'deleted' and not result(p).get('lease'), r.stderr
            empty(state)
        else:
            assert r.returncode == 70 and not (state / 'calls.jsonl').exists(), r.stderr
    print('ok - legacy missing generation stays one-shot; partial, stale and ambiguous launch context fails before admission')

    p, state, env = case('pipeline-binding')
    env = managed(p, env)
    r = subprocess.run(['bash', str(repo / 'bin/fm-boat-run.sh'), 'caller-origin',
                        '--worktree', str(p / 'work')], env=env, capture_output=True)
    frozen = json.loads(r.stdout)
    assert frozen == dict(namespace='firstmate', home=str(p / 'home'), task='reuse-task', generation='generation-1')
    assert launch(p, env).returncode == 0
    original = result(p)
    execution = p / 'execution'
    subprocess.run(['git', 'clone', '-q', str(p / 'work'), str(execution)], check=True)
    (execution / 'tracked.txt').write_text('pipeline snapshot\n')
    tools = p / 'tools'
    tools.mkdir()
    cli = tools / 'no-mistakes'
    cli.write_text("""#!/usr/bin/env python3
import json,pathlib,sys
args=sys.argv[1:]
assert args[:2]==['axi','execution-origin'], args
value=json.loads((pathlib.Path(__file__).parent/'reply.json').read_text())
assert args[args.index('--checkout')+1]==value['execution']['execution_checkout']
assert args[args.index('--ref')+1]=='opaque-producer-reference'
assert args[args.index('--socket')+1]=='/fixture/producer.sock'
print(json.dumps(value))
""")
    cli.chmod(0o755)
    reply = dict(protocol_version=1, execution=dict(reference='opaque-producer-reference',
        run_id='fixture-run', source_checkout=str(p / 'work'), source_head=original['source_head'],
        execution_checkout=str(execution), caller_origin=frozen, run_status='running'))
    reply_file = tools / 'reply.json'
    reply_file.write_text(json.dumps(reply))
    pipeline_env = dict(env, PATH=str(tools) + os.pathsep + env['PATH'],
        NO_MISTAKES_EXECUTION_REF='opaque-producer-reference',
        NO_MISTAKES_EXECUTION_SOCKET='/fixture/producer.sock')
    pipeline_env.pop('FM_TASK_ID')
    pipeline_env.pop('FM_TASK_GENERATION')
    r = subprocess.run(['bash', str(repo / 'bin/fm-boat-test-wrapper.sh'), 'cat tracked.txt'],
        env=pipeline_env, cwd=execution, capture_output=True, timeout=30)
    assert r.returncode == 0 and r.stdout == b'pipeline snapshot\n', (r.stderr, r.stdout)
    assert creates(state) == 1
    # The same producer may explicitly associate an auxiliary Test-base copy.
    auxiliary = p / 'test-base'
    subprocess.run(['git', 'clone', '-q', str(p / 'work'), str(auxiliary)], check=True)
    reply['execution']['execution_checkout'] = str(auxiliary)
    pipeline_env.update(FM_TASK_ID='stale-ambient-task', FM_TASK_GENERATION='stale-ambient-generation')
    reply_file.write_text(json.dumps(reply))
    r = subprocess.run(['bash', str(repo / 'bin/fm-boat-test-wrapper.sh'), 'cat tracked.txt'],
        env=pipeline_env, cwd=auxiliary, capture_output=True, timeout=30)
    assert r.returncode == 0 and creates(state) == 1, r.stderr
    for mutation in ('stale', 'foreign', 'namespace', 'source', 'finished', 'partial', 'wrong-checkout'):
        bad = json.loads(json.dumps(reply))
        bad_env = dict(pipeline_env)
        if mutation == 'stale':
            bad['execution']['caller_origin']['generation'] = 'old'
        elif mutation == 'foreign':
            bad['execution']['caller_origin']['home'] = '/other/home'
        elif mutation == 'namespace':
            bad['execution']['caller_origin']['namespace'] = 'another-owner'
        elif mutation == 'source':
            bad['execution']['source_checkout'] = str(auxiliary)
        elif mutation == 'finished':
            bad['execution']['run_status'] = 'passed'
        elif mutation == 'partial':
            bad_env.pop('NO_MISTAKES_EXECUTION_SOCKET')
        else:
            bad['execution']['execution_checkout'] = str(execution)
        reply_file.write_text(json.dumps(bad))
        r = subprocess.run(['bash', str(repo / 'bin/fm-boat-test-wrapper.sh'), 'echo must-not-run'],
            env=bad_env, cwd=auxiliary, capture_output=True, timeout=30)
        assert r.returncode == 70 and creates(state) == 1, (mutation, r.returncode, r.stderr)
    reply_file.write_text(json.dumps(reply))
    prepush = runpy.run_path(str(repo / 'bin/fm-boat-prepush.py'))
    prepush_output = p / 'prepush'
    prepush_output.mkdir()
    prior_env = dict(os.environ)
    try:
        os.environ.clear()
        os.environ.update(pipeline_env)
        prepush_run = prepush['attempt'](auxiliary, prepush_output, 'default', 30, None,
            "cat tracked.txt; printf '%s\\n' 'FM_BOAT_PREPUSH_SUMMARY {\"failed\":[\"probe\"],\"oom\":true}'")
        assert prepush_run['adapter_exit'] == 0 and prepush['should_retry_large'](prepush_run), prepush_run
        assert prepush_run['remote_result']['vm_id'] == original['vm_id'] and creates(state) == 1
    finally:
        os.environ.clear()
        os.environ.update(prior_env)
    assert cleanup_task(env).returncode == 0
    r = subprocess.run(['bash', str(repo / 'bin/fm-boat-test-wrapper.sh'), 'echo tombstone-must-hold'],
        env=pipeline_env, cwd=auxiliary, capture_output=True, timeout=30)
    assert r.returncode == 70 and creates(state) == 1, r.stderr
    empty(state)
    print('ok - wrapper consumes producer primary/auxiliary bindings, rejects foreign/stale/partial evidence and respects cleanup tombstones')

    p, state, env = case('reuse-cleared-descendant')
    env = managed(p, env)
    r = launch(p, env, 'setsid env -i PATH="$PATH" sh -c \'sleep 90 >/dev/null 2>&1 & echo $!\'')
    assert r.returncode == 0, r.stderr
    assert result(p)['process_cleanup'] == {'state': 'confirmed'}, result(p)
    pid = int(r.stdout.strip())
    path = Path('/proc') / str(pid) / 'stat'
    alive = path.exists() and not path.read_text().split(') ')[1].startswith('Z')
    if alive:
        os.kill(pid, signal.SIGKILL)
    cleaned = cleanup_task(env)
    assert cleaned.returncode == 0, (cleaned.returncode, cleaned.stderr)
    assert not alive, 'detached env-cleared descendant survived command completion'
    print('ok - detached env-cleared descendants are reaped before retention')

    for mutation in ('idle', 'hard', 'orphan', 'unknown', 'key'):
        p, state, env = case('lease-' + mutation)
        env = managed(p, env)
        assert launch(p, env).returncode == 0
        record = next((state / 'jobs').glob('*.json'))
        job = json.loads(record.read_text())
        if mutation == 'idle':
            job['idle_expires'] = time.time() - 1
        elif mutation == 'hard':
            job['hard_expires'] = time.time() - 1
        elif mutation == 'orphan':
            (p / 'home/state/reuse-task.meta').unlink()
        elif mutation == 'unknown':
            job['lease_state'] = 'busy'
        else:
            (Path(env['HOME']) / '.config/boat/api-key').write_text('repointed')
        record.write_text(json.dumps(job))
        r = reap(env)
        if mutation == 'key':
            assert r.returncode == 0 and json.loads(record.read_text())['cleanup'] == 'retained'
            r = cleanup_task(env)
            assert r.returncode == 70 and json.loads((state / 'fake-vms.json').read_text()), (
                mutation, r.returncode, r.stderr, json.loads(record.read_text()))
            (Path(env['HOME']) / '.config/boat/api-key').write_text('boat_fixture_secret')
            cleaned = cleanup_task(env)
            assert cleaned.returncode == 0, (cleaned.returncode, cleaned.stderr, json.loads(record.read_text()))
        else:
            assert r.returncode == 0, r.stderr
            for _ in range(100):
                if json.loads(record.read_text())['cleanup'] == 'deleted':
                    break
                time.sleep(.1)
        empty(state)
    print('ok - reap expires idle/hard/orphan/crashed leases and exact cleanup refuses repointed credentials')

    for reaped in (False, True):
        p, state, env = case('cleanup-missing-worktree-' + str(reaped))
        env = managed(p, env)
        assert launch(p, env).returncode == 0
        (p / 'work').rename(p / 'removed-work')
        assert cleanup_task(env, generation='wrong-generation').returncode == 70
        if reaped:
            for _ in range(100):
                assert reap(env).returncode == 0
                if all(json.loads(record.read_text())['cleanup'] == 'deleted'
                       for record in (state / 'jobs').glob('*.json')):
                    break
                time.sleep(.1)
            empty(state)
        for _ in range(100):
            cleaned = cleanup_task(env)
            if cleaned.returncode == 0 or b'active' not in cleaned.stderr:
                break
            time.sleep(.1)
        assert cleaned.returncode == 0, (cleaned.returncode, cleaned.stderr)
        assert cleanup_task(env).returncode == 0
        empty(state)
    print('ok - exact-generation cleanup survives missing source before and after orphan reaping')

    p, state, env = case('killed-owned-dispatch')
    env = managed(p, env)
    proc = launch(p, env, 'sleep 3; echo remote-finished', wait=False)
    for _ in range(200):
        records = list((state / 'jobs').glob('*.json'))
        if records and json.loads(records[0].read_text()).get('execution_started'):
            break
        time.sleep(.05)
    else:
        raise AssertionError('owned command never reached dispatch')
    proc.kill()
    proc.communicate(timeout=15)
    evidence = result(p)
    assert evidence['kind'] == 'execution-unknown' and evidence['lease']['state'] == 'busy', evidence
    assert cleanup_task(env).returncode == 0
    empty(state)
    print('ok - SIGKILL after dispatch preserves owned unknown-execution evidence')

    p, state, env = case('reuse-reset-failure')
    env = managed(p, env)
    assert launch(p, env).returncode == 0
    (state / 'fixture.json').write_text(json.dumps(dict(prepare_failed=True)))
    r = next_run(p, env, 'echo fresh-fallback')
    assert r.returncode == 0 and r.stdout == b'fresh-fallback\n', r.stderr
    assert result(p)['reuse_fallback'] and result(p)['cleanup'] == 'deleted' and creates(state) == 2
    empty(state)
    print('ok - proven pre-execution reset failure deletes the old lease before one ephemeral fallback')

    for fault in ('reset-timeout', 'reset-cli', 'reset-missing', 'reset-timeout-persistent'):
        p, state, env = case('reuse-' + fault)
        env = managed(p, env)
        assert launch(p, env).returncode == 0
        original = result(p)['lease']['owner']
        (p / 'output').rename(p / 'initial-output')
        r = launch_lost_response(p, state, env, fault)
        evidence = result(p)
        assert evidence['reuse_fallback'] and creates(state) == 2, (fault, r.stderr, evidence)
        if fault == 'reset-timeout-persistent':
            assert r.returncode == 74 and evidence['remote_exit'] is None, (r.stderr, evidence)
            calls = [json.loads(line) for line in (state / 'calls.jsonl').read_text().splitlines()]
            assert sum('--stream' in call for call in calls) == 1, calls
        else:
            assert r.returncode == 0 and r.stdout == b'working edit\n', (fault, r.stderr, evidence)
            assert evidence['cleanup'] == 'retained' and evidence['lease']['owner'] == original, evidence
            r = next_run(p, env, 'echo after-reset-transport')
            assert r.returncode == 0 and result(p)['reused'] and creates(state) == 2, r.stderr
        assert cleanup_task(env).returncode == 0
        empty(state)
    print('ok - reset transport replacements retain exact ownership only after successful reset')

    p, state, env = case('reuse-transfer-failure')
    env = managed(p, env)
    assert launch(p, env).returncode == 0
    (state / 'fixture.json').write_text(json.dumps(dict(push_failed_once=True)))
    r = next_run(p, env, 'echo fresh-transfer-fallback')
    assert r.returncode == 0 and r.stdout == b'fresh-transfer-fallback\n', r.stderr
    assert result(p)['reuse_fallback'] and creates(state) == 2
    assert result(p)['cleanup'] == 'retained'
    r = next_run(p, env, 'echo after-transfer')
    assert r.returncode == 0 and result(p)['reused'] and creates(state) == 2, r.stderr
    assert cleanup_task(env).returncode == 0
    empty(state)
    print('ok - confirmed transfer replacement retains exact owner for the next command')

    p, state, env = case('reuse-reset-unconfirmed')
    env = managed(p, env)
    assert launch(p, env).returncode == 0
    (state / 'fixture.json').write_text(json.dumps(dict(prepare_failed=True, delete_failed=True)))
    r = next_run(p, env, 'echo must-not-retry')
    assert r.returncode == 70 and creates(state) == 1, (r.returncode, r.stderr)
    (state / 'fixture.json').write_text('{}')
    assert cleanup_task(env).returncode == 0
    empty(state)
    print('ok - unconfirmed reset cleanup never permits fresh allocation')

    p, state, env = case('reuse-no-duplicate')
    env = managed(p, env)
    assert launch(p, env).returncode == 0
    (state / 'fixture.json').write_text(json.dumps(dict(transport_failed=True)))
    r = next_run(p, env, 'echo must-not-retry')
    assert r.returncode == 74 and result(p)['kind'] == 'execution-unknown' and creates(state) == 1, r.stderr
    empty(state)
    print('ok - unknown reused execution never creates a second sandbox')

    p, state, env = case('reuse-serialize')
    env = managed(p, env)
    first = launch(p, env, 'sleep 2; echo first', wait=False)
    for _ in range(100):
        if (state / 'fake-vms.json').exists():
            break
        time.sleep(.1)
    busy = cleanup_task(env)
    assert busy.returncode == 70, busy.stderr
    assert b'active' in busy.stderr and reap(env).returncode == 0
    active = json.loads(next((state / 'jobs').glob('*.json')).read_text())
    assert active['lease_state'] == 'busy' and not active.get('closing'), active
    second = subprocess.Popen(['bash', str(repo / 'bin/fm-boat-run.sh'), 'run', '--worktree', str(p / 'work'),
        '--output', str(p / 'second-output'), '--', 'bash', '-c', 'test ! -e leftover; echo second'],
        env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    out1, err1 = first.communicate(timeout=20)
    out2, err2 = second.communicate(timeout=20)
    assert first.returncode == second.returncode == 0, (err1, err2)
    assert out1 == b'first\n' and out2 == b'second\n' and creates(state) == 1
    assert cleanup_task(env).returncode == 0
    empty(state)
    print('ok - concurrent task calls serialize while cleanup refuses an active holder')

    p, state, env = case('cleanup-bookkeeping-overlap')
    env = managed(p, env)
    assert launch(p, env).returncode == 0
    record = next((state / 'jobs').glob('*.json'))
    entered, release = p / 'delete-entered', p / 'delete-release'
    (p / 'boat').write_text('#!' + sys.executable + '\n' +
        'import os,pathlib,sys,time\n' +
        'if sys.argv[1] == "delete":\n' +
        ' pathlib.Path(' + repr(str(entered)) + ').write_text(str(os.getppid()))\n' +
        ' for _ in range(200):\n' +
        '  if pathlib.Path(' + repr(str(release)) + ').exists(): break\n' +
        '  time.sleep(.1)\n' +
        ' else: sys.exit(1)\n' +
        'os.execv(sys.executable,[sys.executable,' + repr(str(fixture)) + ',' +
        repr(str(state)) + ',*sys.argv[1:]])\n')
    job = json.loads(record.read_text())
    job['idle_expires'] = time.time() - 1
    staged = record.with_suffix('.fixture')
    staged.write_text(json.dumps(job))
    staged.replace(record)
    reaper = subprocess.Popen(['bash', str(repo / 'bin/fm-boat-run.sh'), 'reap'],
        env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    for _ in range(100):
        if entered.exists():
            break
        time.sleep(.1)
    assert entered.exists(), 'fixture deletion did not reach its explicit release gate'
    observed = bookkeeping_holders(record)
    assert any(holder['pid'] == int(entered.read_text()) for holder in observed), observed
    refused = cleanup_task(env)
    assert refused.returncode == 70 and b'task Boat command active' in refused.stderr, refused.stderr
    release.touch()
    wait_for_expiry_cleanup(record)
    out, err = reaper.communicate(timeout=10)
    assert reaper.returncode == 0, err
    assert cleanup_task(env).returncode == 0
    empty(state)
    print('ok - exact kernel PID/FD proves bookkeeping overlap; bounded fixture wait preserves immediate cleanup refusal')

    p, state, env = case('lease-idle-watcher')
    env = managed(p, env)
    assert launch(p, env).returncode == 0
    record = next((state / 'jobs').glob('*.json'))
    job = json.loads(record.read_text())
    job['idle_expires'] = time.time() - 1
    staged = record.with_suffix('.fixture')
    staged.write_text(json.dumps(job))
    staged.replace(record)
    for _ in range(600):
        if json.loads(record.read_text())['cleanup'] == 'deleted':
            break
        time.sleep(.1)
    empty(state)
    print('ok - the local idle watcher confirms deletion without a reap invocation')

    for mismatch in ('task', 'home', 'generation', 'worktree', 'type'):
        p, state, env = case('reuse-separate-' + mismatch)
        env = managed(p, env)
        assert launch(p, env).returncode == 0
        if mismatch == 'task':
            other = managed(p, env, task='other-task')
        elif mismatch == 'home':
            other_home = p / 'other-home'
            (other_home / 'state').mkdir(parents=True)
            (other_home / 'state/reuse-task.meta').write_text((p / 'home/state/reuse-task.meta').read_text())
            other = dict(env, FM_HOME=str(other_home))
        elif mismatch == 'generation':
            other = managed(p, env, generation='generation-2')
        elif mismatch == 'worktree':
            (p / 'home/state/reuse-task.meta').write_text('endpoint_task_id=reuse-task\nkind=ship\n'
                'spawn_gen=generation-1\nworktree=' + str(repo) + '\n')
            other = env
        else:
            (p / 'home/config').mkdir()
            (p / 'home/config/boat-keys').write_text(str(Path(env['HOME']) / '.config/boat/api-key') +
                                                  ' types=default,large\n')
            other = env
        r = next_run(p, other, options=('--type', 'large') if mismatch == 'type' else ())
        if mismatch == 'worktree':
            assert r.returncode == 70 and creates(state) == 1, r.stderr
        else:
            assert r.returncode == 0 and not result(p)['reused'] and creates(state) == 2, r.stderr
        assert reap(other).returncode == 0
        if mismatch == 'home':
            assert cleanup_task(other).returncode == 0
        if mismatch == 'task':
            assert cleanup_task(other, task='other-task').returncode == 0
        if mismatch == 'worktree':
            wait_for_expiry_cleanup(next((state / 'jobs').glob('*.json')))
            env = managed(p, env)
        assert cleanup_task(env, generation='generation-2' if mismatch == 'generation' else 'generation-1').returncode == 0
    print('ok - tasks, homes, worker generations, worktrees and resource requests cannot consume another lease')

else:
    print('skip - local managed-VM fixtures require Linux /proc and child subreaper; Boat executes on Linux')

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
created = next(json.loads(line) for line in (state / 'calls.jsonl').read_text().splitlines()
               if json.loads(line)[0] == 'new')
assert created[created.index('--type') + 1] == 'default'
print('ok - omitted machine type preserves default on the legacy single account')
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
assert r.stdout == b'', r.stdout
assert b'failure\n' in r.stderr, r.stderr
assert b'failure' in (p / 'output/command.log').read_bytes()
empty(state)
print('ok - command log includes stderr on nonzero remote exit')

for mode in ('streaming', 'blocking'):
    p, state, env = case('streams-' + mode, {'blocking_exec': mode == 'blocking'})
    r = launch(p, env, 'printf \'{"ok":true}\'; printf diagnostic >&2')
    assert r.returncode == 0, (mode, r.stderr)
    assert r.stdout == b'{"ok":true}', (mode, r.stdout)
    assert r.stderr.endswith(b'diagnostic'), (mode, r.stderr)
    assert b'{"ok":true}' not in r.stderr, (mode, r.stderr)
    log = (p / 'output/command.log').read_bytes()
    assert b'{"ok":true}' in log and b'diagnostic' in log, log
    empty(state)
print('ok - streaming and blocking Boat responses keep stdout and stderr separate')

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

def launch_transfer(p, env):
    driver = p / 'transfer-clock.py'
    driver.write_text('''import importlib.util, pathlib, subprocess, sys
spec = importlib.util.spec_from_file_location('adapter', sys.argv.pop(1))
adapter = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = adapter
spec.loader.exec_module(adapter)
state = pathlib.Path(sys.argv.pop(1))
real_popen = subprocess.Popen
class TransferClock(real_popen):
    def communicate(self, *args, timeout=None, **kwargs):
        if (self.args[1] == 'scp' and str(self.args[2]).endswith('/source.tar.gz')
                and timeout is not None and timeout < 400):
            super().communicate(*args, timeout=timeout, **kwargs)
            archive = state / self.args[3].split(':', 1)[0] / 'fm-job/source.tar.gz'
            archive.unlink()
            raise subprocess.TimeoutExpired(self.args, timeout, output=b'boat_fixture_secret')
        return super().communicate(*args, timeout=timeout, **kwargs)
subprocess.Popen = TransferClock
sys.exit(adapter.main())
''')
    return subprocess.run([sys.executable, str(driver), str(repo / 'bin/fm-boat-run.py'),
                           str(p / 'home/state/boat-offload'), 'run', '--worktree', str(p / 'work'),
                           '--output', str(p / 'output'), '--', 'true'],
                          env=env, capture_output=True, timeout=30)

p, state, env = case('large-transfer')
# An incompressible tracked input models the pipeline's already-compressed upload.
(p / 'work/payload').write_bytes(os.urandom(40 * 1024 * 1024))
git(p / 'work', 'add', 'payload')
git(p / 'work', '-c', 'core.hooksPath=/dev/null', 'commit', '-qm', 'Large source fixture')
r = launch_transfer(p, env)
assert r.returncode == 0, r.stderr
assert result(p)['kind'] == 'completed'
assert result(p)['upload_bytes'] >= 40 * 1024 * 1024
assert 400 <= result(p)['push_timeout_seconds'] <= 600
empty(state)
print('ok - a slow large upload gets a bounded size-aware deadline and completes')

for owned in (False, True) if sys.platform.startswith('linux') else (False,):
    p, state, env = case('transfer-timeout-' + str(owned))
    if owned:
        env = managed(p, env)
    r = launch_transfer(p, env)
    evidence = result(p)
    assert r.returncode == 74, r.stderr
    assert evidence['kind'] == 'adapter-error' and evidence['remote_exit'] is None, evidence
    assert 'timeout' in evidence['error'] and 'TimeoutExpired' in evidence['error']
    assert creates(state) == 1, evidence
    assert not evidence.get('reuse_fallback'), evidence
    calls = [json.loads(line) for line in (state / 'calls.jsonl').read_text().splitlines()]
    assert not any('--stream' in call for call in calls), calls
    assert b'boat_fixture_secret' not in r.stdout + r.stderr
    assert 'boat_fixture_secret' not in (p / 'output/result.json').read_text()
    empty(state)
print('ok - an expired fresh upload preserves timeout classification without retry or credential output')

p, state, env = case('cli-os-error')
env['FM_BOAT_BIN'] = str(p / 'missing-boat')
r = launch(p, env)
assert r.returncode == 69, r.stderr
assert 'OS error' in result(p)['error'] and 'FileNotFoundError' in result(p)['error']
print('ok - an unavailable executable reports the OS error class')

p, state, env = case('cli-bad-response', {'malformed_limits': True})
r = launch(p, env)
assert r.returncode == 69, r.stderr
assert 'bad response' in result(p)['error'] and 'JSONDecodeError' in result(p)['error']
assert 'unparseable provider response' not in result(p)['error']
print('ok - an unparseable response reports its class without copying response content')

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

for history_mode in (False, True):
    for label, selected, target, accepted in [
        ('relative', '.agents/skills/verify-connect', '../../tracked.txt', True),
        ('claude-skills', '.claude/skills', '../.agents/skills', True),
        ('root-link', 'link', 'tracked.txt', True),
        ('root-directory', 'link', '.', True),
        ('escape', 'dir/link', '../../outside', False),
        ('escape-reenter', 'dir/link', '../../work/tracked.txt', False),
        ('absolute', 'dir/link', '/outside', False),
        ('secret', 'dir/link', '../API_SECRET=symlink-never-print', False),
        ('binary', 'dir/link', b'../bad-\xff', False),
    ]:
        p, state, env = case('symlink-' + str(history_mode) + '-' + label, clean_history=True)
        work = p / 'work'
        link = work / selected
        link.parent.mkdir(parents=True, exist_ok=True)
        os.symlink(target, link)
        git(work, 'add', '--force', '.')
        git(work, 'commit', '-qm', 'symlink fixture')
        if history_mode and not accepted:
            link.unlink()
            git(work, 'add', '--all')
            git(work, 'commit', '-qm', 'remove unsafe link')
        git(work, 'update-ref', 'refs/remotes/origin/main', 'HEAD')
        options = ('--history-depth', '2') if history_mode else ()
        check = 'test ! -L ' + shlex.quote(selected) + ' && test -f tracked.txt'
        r = launch(p, env, check, options)
        assert r.returncode == (0 if accepted or history_mode else 2), (history_mode, label, r.stdout, r.stderr)
        assert b'symlink-never-print' not in r.stdout + r.stderr
        if accepted:
            uploaded = json.loads((state / 'uploaded.json').read_text())
            assert selected not in uploaded, (selected, uploaded)
            assert 'tracked.txt' in uploaded
            notice = ('boat-offload: skipped in-repo symlink: ' + selected + '\n').encode()
            assert r.stderr.count(notice) == 1, r.stderr
            empty(state)
        elif history_mode:
            assert result(p)['history'] == 'fallback-synthetic'
            assert selected in result(p)['history_reason']
            with tarfile.open(p / 'output/upload/source.tar.gz') as archive:
                assert not any(n == '.git' or n.startswith('.git/') for n in archive.getnames())
            empty(state)
        else:
            assert not (state / 'calls.jsonl').exists()
    for label in ('submodule', 'parent-component'):
        p, state, env = case('unsafe-entry-' + str(history_mode) + '-' + label, clean_history=True)
        work = p / 'work'
        if label == 'submodule':
            oid = git(work, 'rev-parse', 'HEAD').stdout.decode().strip()
            git(work, 'update-index', '--add', '--cacheinfo', '160000,' + oid + ',module')
            git(work, 'commit', '-qm', 'gitlink fixture')
            if history_mode:
                git(work, 'update-index', '--force-remove', 'module')
                git(work, 'commit', '-qm', 'remove gitlink')
        else:
            (work / 'dir').mkdir()
            (work / 'dir/file').write_text('tracked child\n')
            (work / 'dir/link').symlink_to('../tracked.txt')
            git(work, 'add', '.')
            git(work, 'commit', '-qm', 'tracked directory')
            (work / 'dir').rename(work / 'real-dir')
            (work / 'dir').symlink_to('real-dir')
        git(work, 'update-ref', 'refs/remotes/origin/main', 'HEAD')
        r = launch(p, env, options=('--history-depth', '2') if history_mode else ())
        if history_mode and label == 'submodule':
            assert r.returncode == 0, r.stderr
            assert b'history withheld' in r.stderr
            empty(state)
        else:
            assert r.returncode == 2, (history_mode, label, r.stderr)
            assert not (state / 'calls.jsonl').exists()
print('ok - screened in-repo links are skipped; unsafe source links refuse, unsafe history links fall back, and submodules are withheld')

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

for machine_type in ('default', 'large', 'xlarge'):
    p, state, other, env, key1, key2, config = multi(
        'type-' + machine_type, caps='types=' + machine_type)
    config.write_text(shlex.quote(str(key1)) + ' types=large\n' +
                      shlex.quote(str(key2)) + ' types=' + machine_type + '\n')
    r = launch(p, env, options=('--type', machine_type))
    assert r.returncode == 0, r.stderr
    selected = state if machine_type == 'large' else other
    skipped = other if selected == state else state
    assert not calls(skipped), calls(skipped)
    created = next(json.loads(line) for line in (selected / 'calls.jsonl').read_text().splitlines()
                   if json.loads(line)[0] == 'new')
    assert created[created.index('--type') + 1] == machine_type, created
    assert '--no-env' in created and '--no-snapshots' in created
    job = next(json.loads(f.read_text()) for f in (state / 'jobs').glob('*.json'))
    assert job['type'] == machine_type
    empty(selected)
print('ok - exact Boat machine type reaches the first permitting account without probing disallowed accounts')

p, state, other, env, key1, key2, config = multi('type-no-downgrade',
    second={'remaining': 0}, caps='types=default,large,xlarge')
r = launch(p, env, options=('--type', 'xlarge'))
assert r.returncode == 75, r.stderr
assert not calls(state) and 'new' not in calls(other)
print('ok - exhausted permitted account never downgrades to an available default account')

for configured in (False, True):
    p, state, env = case('type-refused-' + str(configured))
    if configured:
        config = p / 'home/config/boat-keys'
        config.parent.mkdir()
        config.write_text('~/.config/boat/api-key\n')
    r = launch(p, env, options=('--type', 'large'))
    assert r.returncode == 2, r.stderr
    assert b'no Boat account permits machine type large' in r.stderr
    assert result(p)['kind'] == 'invalid'
    assert not calls(state) and not list((state / 'jobs').glob('*.json'))
print('ok - legacy and configured accounts require explicit permission for non-default sizes')

p, state, other, env, key1, key2, config = multi('type-filter-key-screening')
tracked_key = p / 'work/tracked.txt'
tracked_key.write_text(key1.read_text())
config.write_text(str(tracked_key) + ' types=default\n' +
                  str(key2) + ' types=large\n')
r = launch(p, env, 'test ! -e tracked.txt', options=('--type', 'large'))
assert r.returncode == 0, r.stderr
assert json.loads((other / 'uploaded.json').read_text()) == []
assert not calls(state)
empty(other)
print('ok - disallowed accounts still contribute their key paths to upload screening')

p, state, env = case('unknown-type')
assert launch(p, env, options=('--type', 'huge')).returncode == 2
assert not calls(state)
print('ok - unknown machine type fails before contacting Boat')

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
                              '~/.config/boat/api-key types=',
                              '~/.config/boat/api-key types=huge',
                              '~/.config/boat/api-key types=default,',
                              '~/.config/boat/api-key types=default,default',
                              '~/.config/boat/api-key types=default types=large',
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
    ('reimage-safe', '# Reimage development\nRebuild the development image.\n', True),
    ('reimage-secret', 'API_SECRET=fixture-only\n', False),
    ('settings-safe', '{"permissions":{"allow":["Bash(npm test)"]}}', True),
    ('settings-secret', '{"env":{"API_SECRET":"fixture-only"}}', False),
    ('settings-bearer', '{"header":"Bearer fixture-only"}', False),
    ('settings-bearer-short', '{"header":"Bearer a9F2k7Q4m8X"}', False),
    ('settings-bearer-single', '{"header":"Bearer x"}', False),
    ('settings-bearer-prose-prefix', '{"header":"Bearer shares-private"}', False),
    ('settings-bearer-quoted-noun', '{"header":"Bearer decisions"}', False),
    ('settings-private-key', '-----BEGIN PRIVATE KEY-----\nfixture-only', False),
    ('settings-postgresql', '{"env":{"DATABASE_URL":"postgresql://app:dbpass@db.internal/app"}}', False),
]:
    p, state, env = case(name)
    selected = '.npmrc' if name.startswith('npmrc') else '.claude/settings.json'
    if name.startswith('reimage-'):
        selected = '.claude/commands/reimage-dev.md'
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
        assert b'a9F2k7Q4m8X' not in r.stdout + r.stderr
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
assert result(p)['history'] == 'screened'
with tarfile.open(p / 'output/upload/source.tar.gz') as archive:
    assert any(n.startswith('.git/objects/pack/') for n in archive.getnames())
empty(state)
print('ok - real Git preserves both tips, bounded ancestry and tracked edits without unrelated refs/config/reflogs')


def manifest(p, work, *, depth=2, objects=None, templates=None, source=None):
    head = git(work, 'rev-parse', 'HEAD').stdout.decode().strip()
    source_ref = git(work, 'symbolic-ref', 'HEAD').stdout.decode().strip()
    git(work, 'update-ref', 'refs/heads/input-base', 'HEAD')
    value = dict(schema='fm-boat-history.v1', source=str(source or work), head=head,
                 head_ref=source_ref, refs={'refs/remotes/origin/main':
                 {'ref': 'refs/heads/input-base', 'oid': head}}, depth=depth,
                 objects=objects or [], templates=templates or [])
    path = p / 'history.json'
    path.write_text(json.dumps(value))
    return path, value


p, state, env = case('explicit-old-input', clean_history=True)
work = p / 'work'
(work / '.env.example').write_text('# Empty configuration template\nAPI_TOKEN=\nURL=""\n')
(work / 'historical.txt').write_text('requested historical bytes\n')
git(work, 'add', '-f', '.env.example', 'historical.txt')
git(work, 'commit', '-qm', 'old snapshot')
old = git(work, 'rev-parse', 'HEAD').stdout.decode().strip()
blob = git(work, 'rev-parse', 'HEAD:historical.txt').stdout.decode().strip()
(work / 'historical.txt').rename(p / 'historical.saved')
git(work, 'add', '-u')
git(work, 'commit', '-qm', 'remove historical file')
tree = git(work, 'rev-parse', 'HEAD^{tree}').stdout.decode().strip()
parent = git(work, 'rev-parse', 'HEAD').stdout.decode().strip()
unsafe = None
for i in range(1002):
    message = 'API_SECRET=fixture-never-upload' if i == 500 else 'safe history ' + str(i)
    parent = git(work, 'commit-tree', tree, '-p', parent, '-m', message).stdout.decode().strip()
    if i == 500:
        unsafe = parent
git(work, 'update-ref', 'HEAD', parent)
(work / 'tracked.txt').write_text('current working bytes\n')
(work / 'staged.txt').write_text('staged addition\n')
git(work, 'add', 'staged.txt')
path, value = manifest(p, work, depth=1, templates=['.env.example'], objects=[
    {'commit': old, 'path': 'historical.txt', 'oid': blob}])
check = f"""import pathlib,subprocess
def git(*args): return subprocess.check_output(['git',*args]).decode().strip()
assert git('rev-parse','HEAD') == {parent!r}
assert git('show',{old + ':historical.txt'!r}) == 'requested historical bytes'
assert subprocess.run(['git','cat-file','-e',{unsafe!r}],capture_output=True).returncode != 0
assert pathlib.Path('tracked.txt').read_text() == 'current working bytes\\n'
assert pathlib.Path('staged.txt').read_text() == 'staged addition\\n'
assert pathlib.Path('.env.example').read_text() == '# Empty configuration template\\nAPI_TOKEN=\\nURL=\"\"\\n'
assert git('fsck','--no-reflogs') == ''
subprocess.run(['git','clone','--quiet','--shared','--no-checkout','.', '../clone'],check=True)
assert subprocess.check_output(['git','-C','../clone','show',{old + ':historical.txt'!r}]).strip() == b'requested historical bytes'
assert subprocess.check_output(['git','-C','../clone','show','HEAD:.env.example']).endswith(b'URL=\"\"\\n')
"""
r = launch(p, env, 'python3 -c ' + shlex.quote(check), ('--history-input', str(path)))
assert r.returncode == 0, (r.stdout, r.stderr, result(p))
proof = result(p)['history_input']
assert proof['sha256'] == hashlib.sha256(path.read_bytes()).hexdigest()
assert proof['head'] == parent and proof['objects'] == value['objects']
assert proof['source'] == str(work) and proof['refs'] == value['refs']
with tarfile.open(p / 'output/upload/source.tar.gz') as archive:
    assert archive.extractfile('.env.example').read() == (work / '.env.example').read_bytes()
    config = archive.extractfile('.git/config').read()
    assert str(work).encode() not in config and b'url' not in config
empty(state)
print('ok - pinned exact snapshot beyond 1000 preserves source bytes and blank template through real shallow clone')

# The same excluded template and deep object remain unavailable without opt-in.
git(work, 'update-ref', 'refs/remotes/origin/main', parent)
r = next_run(p, env, options=('--history-depth', '1'))
assert r.returncode == 0, r.stderr
with tarfile.open(p / 'output/upload/source.tar.gz') as archive:
    assert '.env.example' not in archive.getnames()

# The selected old commit must still pass the ordinary commit/content guards.
value['objects'][0]['commit'] = unsafe
value['objects'][0]['path'] = 'tracked.txt'
value['objects'][0]['oid'] = git(work, 'rev-parse', unsafe + ':tracked.txt').stdout.decode().strip()
path.write_text(json.dumps(value))
before = creates(state)
r = next_run(p, env, options=('--history-input', str(path)))
assert r.returncode == 2 and b'credential-looking or binary commit' in r.stderr, r.stderr
assert creates(state) == before and not (p / 'output/upload/source.tar.gz').exists()
print('ok - selecting credential-bearing history refuses before allocation without synthetic fallback')

p, state, env = case('input-old-secret-blob', clean_history=True)
work = p / 'work'
(work / 'old.txt').write_text('API_SECRET=fixture-never-upload\n')
git(work, 'add', 'old.txt')
git(work, 'commit', '-qm', 'old blob')
old = git(work, 'rev-parse', 'HEAD').stdout.decode().strip()
blob = git(work, 'rev-parse', 'HEAD:old.txt').stdout.decode().strip()
(work / 'old.txt').rename(p / 'old.saved')
git(work, 'add', '-u')
git(work, 'commit', '-qm', 'remove old blob')
path, _ = manifest(p, work, depth=1, objects=[{'commit': old, 'path': 'old.txt', 'oid': blob}])
r = launch(p, env, options=('--history-input', str(path)))
assert r.returncode == 2 and b'old.txt' in r.stderr, r.stderr
assert b'fixture-never-upload' not in r.stderr and not (state / 'calls.jsonl').exists()
print('ok - required credential-bearing historical blob refuses before provisioning')

p, state, env = case('input-preflight-copy', clean_history=True)
work = p / 'work'
(work / '.env.example').write_text('API_TOKEN=\n')
git(work, 'add', '-f', '.env.example')
git(work, 'commit', '-qm', 'template baseline')
common = git(work, 'rev-parse', 'HEAD').stdout.decode().strip()
git(work, 'checkout', '-qb', 'main-input')
(work / 'main.txt').write_text('main change\n')
git(work, 'add', 'main.txt')
git(work, 'commit', '-qm', 'main change')
base_tip = git(work, 'rev-parse', 'HEAD').stdout.decode().strip()
git(work, 'checkout', '-qb', 'feature-input', common)
(work / 'feature.txt').write_text('feature change\n')
git(work, 'add', 'feature.txt')
git(work, 'commit', '-qm', 'feature change')
head = git(work, 'rev-parse', 'HEAD').stdout.decode().strip()
path, value = manifest(p, work, depth=2, templates=['.env.example'], objects=[
    {'commit': head, 'path': '.env.example',
     'oid': git(work, 'rev-parse', 'HEAD:.env.example').stdout.decode().strip()}])
git(work, 'update-ref', 'refs/heads/input-base', base_tip)
value['refs']['refs/remotes/origin/main']['oid'] = base_tip
path.write_text(json.dumps(value))
check = f"""import pathlib,subprocess
def git(*args): return subprocess.check_output(['git',*args]).decode().strip()
assert git('rev-parse','HEAD') == {head!r}
assert git('rev-parse','origin/main') == {base_tip!r}
subprocess.run(['git','clone','--quiet','--shared','--no-checkout','.', '../preflight'],check=True)
def copy(*args): return subprocess.check_output(['git','-C','../preflight',*args]).decode().strip()
copy('update-ref','refs/remotes/origin/main',{base_tip!r})
copy('checkout','--quiet','--detach',{head!r})
copy('-c','user.name=Fixture','-c','user.email=fixture@example.invalid','merge','--quiet','--no-ff','--no-edit',{base_tip!r})
assert copy('rev-parse','HEAD^1') == {head!r}
assert copy('rev-parse','HEAD^2') == {base_tip!r}
assert pathlib.Path('../preflight/.env.example').read_text() == 'API_TOKEN=\\n'
assert pathlib.Path('../preflight/main.txt').read_text() == 'main change\\n'
assert pathlib.Path('../preflight/feature.txt').read_text() == 'feature change\\n'
assert copy('status','--porcelain') == ''
assert copy('fsck','--no-reflogs') == ''
"""
r = launch(p, env, 'python3 -c ' + shlex.quote(check), ('--history-input', str(path)))
assert r.returncode == 0, (r.stdout, r.stderr, result(p))
empty(state)
print('ok - exact-head preflight clone, checkout and merge retain both parents and template bytes')

for label, contents in [('blank', 'SECRET=\n'), ('secret', 'SECRET=fixture-never-upload\n'),
                         ('issued', '# ghp_012345678901234567890123\n'),
                         ('binary', 'SECRET=\n\x00')]:
    p, state, env = case('input-template-' + label, clean_history=True)
    work = p / 'work'
    (work / '.env.example').write_text(contents)
    git(work, 'add', '-f', '.env.example')
    git(work, 'commit', '-qm', 'template')
    path, _ = manifest(p, work, depth=1, templates=['.env.example'])
    r = launch(p, env, options=('--history-input', str(path)))
    assert r.returncode == (0 if label == 'blank' else 2), (label, r.stderr)
    if label != 'blank':
        assert b'fixture-never-upload' not in r.stderr
        assert not (state / 'calls.jsonl').exists()
print('ok - explicit template admission screens exact bytes and never admits populated values or issued keys')

for label in ('changed-ref', 'wrong-object', 'wrong-head', 'unavailable', 'secret-url', 'excluded-template'):
    p, state, env = case('input-refusal-' + label, clean_history=True)
    work = p / 'work'
    git(work, 'commit', '--allow-empty', '-qm', 'next')
    path, value = manifest(p, work, depth=1)
    if label == 'changed-ref':
        value['refs']['refs/remotes/origin/main']['oid'] = git(work, 'rev-parse', 'HEAD~1').stdout.decode().strip()
    elif label == 'wrong-object':
        value['objects'] = [{'commit': value['head'], 'path': 'tracked.txt', 'oid': '1' * 40}]
    elif label == 'wrong-head':
        value['head'] = '1' * 40
    elif label == 'unavailable':
        value['source'] = 'https://127.0.0.1:1/unavailable.git'
    elif label == 'secret-url':
        value['source'] = 'https://user:fixture-never-upload@example.invalid/repo'
    else:
        value['templates'] = ['.env']
    path.write_text(json.dumps(value))
    r = launch(p, env, options=('--history-input', str(path)))
    assert r.returncode == 2, (label, r.stderr)
    assert b'fixture-never-upload' not in r.stderr
    assert not (state / 'calls.jsonl').exists()
    assert result(p)['kind'] != 'unavailable'
print('ok - changed/unavailable sources, object identity and unsafe manifests fail without provisioning or fallback')

p, state, env = case('input-promisor', clean_history=True)
work = p / 'work'
complete = p / 'complete.git'
git(p, 'clone', '--quiet', '--bare', str(work), str(complete))
path, value = manifest(p, work, depth=1, source=complete)
git(complete, 'update-ref', 'refs/heads/input-base', value['head'])
blob = git(work, 'rev-parse', 'HEAD:deleted.txt').stdout.decode().strip()
loose = work / '.git/objects' / blob[:2] / blob[2:]
loose.rename(p / 'withheld-object')
git(work, 'config', 'core.repositoryformatversion', '1')
git(work, 'config', 'extensions.partialclone', 'origin')
git(work, 'config', 'remote.origin.promisor', 'true')
git(work, 'config', 'remote.origin.url', str(complete))
# A complete explicitly pinned source hydrates scratch, never the caller's Git.
r = launch(p, env, options=('--history-input', str(path)))
assert r.returncode == 0, r.stderr
assert not loose.exists()
# Reusing the incomplete checkout as the transport source must fail closed.
value['source'] = str(work)
path.write_text(json.dumps(value))
before = creates(state)
r = next_run(p, env, options=('--history-input', str(path)))
assert r.returncode == 2 and not loose.exists(), r.stderr
assert creates(state) == before
print('ok - promisor source objects come from explicit complete input without lazy hydration of the caller')

for name, contents in [
    ('blocked-decisions', '| State | Notes |\n|' + '-' * 680 + '|---|\n'
     '| blocked | blocked bearer decisions, pending review |\n'),
    ('shares', 'The bearer shares are transferable.\n'),
]:
    p, state, env = case('history-bearer-prose-' + name, clean_history=True)
    work = p / 'work'
    target = work / '.agents/skills/verify-app/features.md'
    target.parent.mkdir(parents=True)
    target.write_text(contents)
    git(work, 'add', '.')
    git(work, 'commit', '-qm', 'document transfer rules')
    git(work, 'update-ref', 'refs/remotes/origin/main', 'HEAD')
    r = launch(p, env, 'test -f .agents/skills/verify-app/features.md',
               ('--history-depth', '2'))
    assert r.returncode == 0, (name, r.stderr)
    assert '.agents/skills/verify-app/features.md' in json.loads((state / 'uploaded.json').read_text())
    empty(state)
print('ok - history accepts bearer prose and long Markdown table separators')

for name, selected, contents, symlink, accepted in [
    ('history-reimage-clean', '.claude/commands/reimage-dev.md', '# Reimage development\n', False, True),
    ('history-reimage-secret', '.claude/commands/reimage-dev.md', 'API_SECRET=historical-value-never-print', False, False),
    ('history-skills-link', '.claude/skills', '../.agents/skills', True, True),
    ('history-other-link', 'other-link', 'tracked.txt', True, True),
    ('history-claude-other-link', '.claude/other', '../tracked.txt', True, True),
    ('history-skills-escape', '.claude/skills', '../../outside', True, False),
    ('history-skills-absolute', '.claude/skills', '/outside', True, False),
    ('history-skills-secret', '.claude/skills', '../API_SECRET=historical-value-never-print', True, False),
    ('history-skills-file', '.claude/skills', 'ordinary file', False, False),
    ('history-local-settings-secret', '.claude/settings.local.json', 'API_SECRET=historical-value-never-print', False, False),
    ('history-claude-unlisted', '.claude/unlisted.md', 'ordinary file', False, False),
]:
    p, state, env = case(name, clean_history=True)
    work = p / 'work'
    target = work / selected
    target.parent.mkdir(parents=True, exist_ok=True)
    if symlink:
        target.symlink_to(contents)
    else:
        target.write_text(contents)
    git(work, 'add', '--force', '.')
    git(work, 'commit', '-qm', 'Claude history fixture')
    if not accepted:
        target.unlink()
        git(work, 'add', '--all')
        git(work, 'commit', '-qm', 'clean current tree')
    git(work, 'update-ref', 'refs/remotes/origin/main', 'HEAD')
    refused = symlink and selected == '.claude/skills' and not accepted
    oid = git(work, 'rev-parse', 'HEAD~1:' + selected).stdout.decode().strip() if not accepted else None
    check = 'test ! -e .git' if refused else 'exit 0'
    if not accepted and not refused:
        check = 'git fsck --no-reflogs && ! git cat-file blob ' + oid + ' >/dev/null 2>&1'
    if symlink and accepted:
        check = 'test ! -L ' + shlex.quote(selected) + ' && test "$(git cat-file blob HEAD:' + \
                selected + ')" = ' + shlex.quote(contents) + ' && git fsck --no-reflogs'
    r = launch(p, env, check, ('--history-depth', '2'))
    assert r.returncode == 0, (name, r.stdout, r.stderr)
    assert b'historical-value-never-print' not in r.stdout + r.stderr
    uploaded = json.loads((state / 'uploaded.json').read_text())
    assert (selected in uploaded) == (accepted and not symlink), (name, uploaded)
    if refused:
        assert r.stderr.count(b'falling back to synthetic snapshot; history refused:') == 1
        assert result(p)['history'] == 'fallback-synthetic'
        assert selected in result(p)['history_reason']
        with tarfile.open(p / 'output/upload/source.tar.gz') as archive:
            assert not any(n == '.git' or n.startswith('.git/') for n in archive.getnames())
    else:
        assert result(p)['history'] == 'screened'
    empty(state)
print('ok - Claude history screens reimage content and permits screened in-repo symlink blobs')

for name, unsafe_path, unsafe_content in [
    ('history-excluded', '.env', 'historical-value-never-print'),
    ('history-credential', 'ordinary.txt', 'API_SECRET=historical-value-never-print'),
    ('history-role-credential', '.github/tools/jev/vendor/.claude/agents/security-compliance.md',
     'password=historical-value-never-print'),
    ('history-binary', 'binary.dat', '\x00historical-value-never-print'),
    ('history-bearer-header', 'ordinary.txt',
     'Authorization: Bearer historical-value-never-print'),
    ('history-bearer-jwt', 'ordinary.txt',
     'bearer eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJmaXh0dXJlIn0.historical-value-never-print'),
    ('history-bearer-opaque', 'ordinary.txt', 'bearer aB09_~+/.historical-value-never-print=='),
    ('history-bearer-minimum', 'ordinary.txt', 'bEaReR\tAb09_~+/.-12=='),
    ('history-bearer-short', 'ordinary.txt', 'Bearer a9F2k7Q4m8X'),
    ('history-bearer-single', 'ordinary.txt', 'Bearer x'),
    ('history-bearer-prose-prefix', 'ordinary.txt', 'Bearer decisions-private'),
    ('history-private-key', 'ordinary.txt', '-----BEGIN RSA PRIVATE KEY-----'),
    ('history-url', 'ordinary.txt', 'https://user:historical-value-never-print@example.invalid'),
    ('history-openai', 'ordinary.txt', 'sk-historical-value-never-print'),
    ('history-github', 'ordinary.txt', 'ghp_0123456789abcdefghij'),
    ('history-github-pat', 'ordinary.txt', 'github_pat_0123456789abcdefghij'),
    ('history-aws', 'ordinary.txt', 'AKIA0123456789ABCDEF'),
]:
    p, state, env = case(name, clean_history=True)
    work = p / 'work'
    target = work / unsafe_path
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(unsafe_content)
    git(work, 'add', '--force', '.')
    git(work, 'commit', '-qm', 'unsafe older blob')
    oid = git(work, 'rev-parse', 'HEAD:' + unsafe_path).stdout.decode().strip()
    target.unlink()
    git(work, 'add', '--all')
    git(work, 'commit', '-qm', 'clean current tree')
    git(work, 'update-ref', 'refs/remotes/origin/main', 'HEAD')
    head = git(work, 'rev-parse', 'HEAD').stdout.decode().strip()
    older = git(work, 'rev-parse', 'HEAD~1').stdout.decode().strip()
    check = f'''import pathlib, subprocess
def git(*args): return subprocess.run(['git', *args], capture_output=True, text=True)
assert git('rev-parse', 'HEAD').stdout.strip() == {head!r}
assert git('cat-file', '-e', {older!r}).returncode == 0, 'the older commit must still be here'
assert git('fsck', '--no-reflogs').stdout.strip() == ''
assert git('fsck', '--no-reflogs').returncode == 0
read = git('cat-file', 'blob', {oid!r})
assert read.returncode != 0, 'a withheld object must not be readable'
assert 'never-print' not in read.stdout
assert not pathlib.Path({unsafe_path!r}).exists()
'''
    r = launch(p, env, 'python3 -c ' + shlex.quote(check), ('--history-depth', '2'))
    assert r.returncode == 0, (name, r.stdout, r.stderr, result(p))
    assert b'history withheld' in r.stderr, (name, r.stderr)
    assert b'never-print' not in r.stdout + r.stderr, name
    assert result(p)['kind'] == 'completed'
    empty(state)
print('ok - an excluded, credential-bearing or binary historical object is withheld '
      'without content, leaving real commits a clean fsck reads')

p, state, env = case('history-current-blob', clean_history=True)
work = p / 'work'
(work / 'current.txt').write_text('API_SECRET=current-tree-value\n')
git(work, 'add', '--all')
git(work, 'commit', '-qm', 'credential-looking current blob')
git(work, 'update-ref', 'refs/remotes/origin/main', 'HEAD')
r = launch(p, env, 'grep -q current-tree-value current.txt && git cat-file -p HEAD:current.txt >/dev/null',
           ('--history-depth', '2'))
assert r.returncode == 0, (r.stdout, r.stderr, result(p))
assert b'history withheld' not in r.stderr, r.stderr
empty(state)
print('ok - a blob a tip still carries travels under history exactly as it travels without it')

for name, path, content in (
    ('history-current-npmrc', '.npmrc', '//registry.npmjs.org/:_authToken=never-print-npm\n'),
    ('history-current-settings', '.claude/settings.local.json',
     '{"apiKey": "sk-never-print-current-key"}\n'),
):
    p, state, env = case(name, clean_history=True)
    work = p / 'work'
    (work / path).parent.mkdir(parents=True, exist_ok=True)
    (work / path).write_text(content)
    git(work, 'add', '--force', '--all')
    git(work, 'commit', '-qm', 'credential-looking screened exception in HEAD')
    git(work, 'update-ref', 'refs/remotes/origin/main', 'HEAD')
    oid = git(work, 'rev-parse', 'HEAD:' + path).stdout.decode().strip()
    check = f'''import pathlib, subprocess
read = subprocess.run(['git', 'cat-file', 'blob', {oid!r}], capture_output=True, text=True)
assert read.returncode != 0, 'a screened exception that fails its screen must not travel in history'
assert 'never-print' not in read.stdout
assert not pathlib.Path({path!r}).exists()
'''
    r = launch(p, env, 'python3 -c ' + shlex.quote(check), ('--history-depth', '2'))
    assert r.returncode == 0, (name, r.stdout, r.stderr, result(p))
    assert b'history withheld' in r.stderr, (name, r.stderr)
    assert b'never-print' not in r.stdout + r.stderr, name
    assert b'never-print' not in (p / 'output/result.json').read_bytes(), name
    empty(state)
print('ok - a screened exception HEAD carries is withheld from history when its content fails the screen')

for name, path, change in (
    ('history-head-edited', 'ordinary.txt', 'edit'),
    ('history-head-deleted', 'ordinary.txt', 'delete'),
    ('history-head-excluded', 'secrets/app.txt', None),
):
    p, state, env = case(name, clean_history=True)
    work = p / 'work'
    (work / path).parent.mkdir(parents=True, exist_ok=True)
    (work / path).write_text('API_SECRET=never-print-head-copy\n')
    git(work, 'add', '--force', '--all')
    git(work, 'commit', '-qm', 'credential-looking blob in HEAD')
    git(work, 'update-ref', 'refs/remotes/origin/main', 'HEAD')
    oid = git(work, 'rev-parse', 'HEAD:' + path).stdout.decode().strip()
    if change == 'edit':
        (work / path).write_text('cleaned in the working tree\n')
    elif change == 'delete':
        (work / path).unlink()
    check = f'''import subprocess
read = subprocess.run(['git', 'cat-file', 'blob', {oid!r}], capture_output=True, text=True)
assert read.returncode != 0, 'HEAD bytes the source archive does not carry must be screened'
assert 'never-print' not in read.stdout
'''
    r = launch(p, env, 'python3 -c ' + shlex.quote(check), ('--history-depth', '2'))
    assert r.returncode == 0, (name, r.stdout, r.stderr, result(p))
    assert b'history withheld' in r.stderr, (name, r.stderr)
    assert b'never-print' not in r.stdout + r.stderr, name
    assert b'never-print' not in (p / 'output/result.json').read_bytes(), name
    empty(state)
print('ok - a HEAD blob the working tree edits, deletes or excludes is screened and withheld')

p, state, env = case('history-base-only-blob', clean_history=True)
work = p / 'work'
start = git(work, 'rev-parse', 'HEAD').stdout.decode().strip()
(work / 'ordinary.txt').write_text('API_SECRET=never-print-base-only\n')
git(work, 'add', '--all')
git(work, 'commit', '-qm', 'credential only origin/main carries')
oid = git(work, 'rev-parse', 'HEAD:ordinary.txt').stdout.decode().strip()
git(work, 'update-ref', 'refs/remotes/origin/main', 'HEAD')
git(work, 'reset', '-q', '--hard', start)
(work / 'other.txt').write_text('head side\n')
git(work, 'add', '--all')
git(work, 'commit', '-qm', 'head side')
check = f'''import subprocess
read = subprocess.run(['git', 'cat-file', 'blob', {oid!r}], capture_output=True, text=True)
assert read.returncode != 0, 'a blob only origin/main carries is screened like history'
'''
r = launch(p, env, 'python3 -c ' + shlex.quote(check), ('--history-depth', '2'))
assert r.returncode == 0, (r.stdout, r.stderr, result(p))
assert b'history withheld' in r.stderr, r.stderr
assert b'never-print' not in r.stdout + r.stderr
empty(state)
print('ok - a credential-looking blob only origin/main carries is withheld')

for root_ref in ('HEAD', 'refs/remotes/origin/main'):
    for ancestor in (False, True):
        for field in ('message', 'author', 'committer', 'extra-header'):
            for credential in (b'API_SECRET=historical-commit-never-print', b'Bearer a9F2k7Q4m8X',
                               b'ghp_historicalcommitneverprint0123'):
                name = 'history-commit-' + root_ref.replace('/', '-') + '-' + str(ancestor) + '-' + field + '-' + str(len(credential))
                p, state, env = case(name, clean_history=True)
                work = p / 'work'
                git(work, 'update-ref', 'refs/remotes/origin/main', 'HEAD')
                raw = git(work, 'cat-file', 'commit', 'HEAD').stdout
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
                r = launch(p, env, 'test ! -e .git', options=('--history-depth', '2'))
                assert r.returncode == 0, (name, r.stderr)
                assert r.stderr.count(b'falling back to synthetic snapshot; history refused:') == 1
                assert credential not in r.stdout + r.stderr
                assert result(p)['history'] == 'fallback-synthetic'
                assert unsafe in result(p)['history_reason']
                with tarfile.open(p / 'output/upload/source.tar.gz') as archive:
                    assert not any(n == '.git' or n.startswith('.git/') for n in archive.getnames())
                empty(state)
print('ok - both history roots screen tip and ancestor commit messages and headers, then fall back without content')

p, state, env = case('history-commit-prose', clean_history=True)
work = p / 'work'
git(work, 'commit', '-q', '--allow-empty', '-m',
    "secrets:scan read the literal URL 'https://user:secret@example.com/path' as real, and "
    'Bearer decisions stay prose')
git(work, 'update-ref', 'refs/remotes/origin/main', 'HEAD')
assert launch(p, env, options=('--history-depth', '2')).returncode == 0
empty(state)
print('ok - a commit message that writes about credentials is prose, not a credential')

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

if sys.platform.startswith('linux'):
    for failure in ('prepare_failed', 'push_failed_once'):
        for fallback in ('upstash', 'local', 'disabled', 'no-key'):
            p, state, env = upstash_case('reuse-' + failure + '-' + fallback, {'remaining': 20})
            env = managed(p, env)
            assert launch(p, env).returncode == 0
            (state / 'fixture.json').write_text(json.dumps({failure: True, 'remaining': 0}))
            if fallback == 'no-key':
                (Path(env['HOME']) / '.config/upstash/box-api-key').unlink()
                r = next_run(p, env)
                assert r.returncode == 75 and result(p)['kind'] == 'unavailable', (r.stderr, result(p))
                assert result(p)['cleanup'] == 'deleted'
            elif fallback == 'upstash':
                r = next_run(p, env, 'echo replacement')
                assert r.returncode == 0 and r.stdout == b'replacement\n', r.stderr
                assert result(p)['provider'] == 'upstash' and result(p)['cleanup'] == 'deleted'
                assert [call['operation'] for call in upstash_calls(state)].count('create') == 1
            else:
                (state / 'upstash.json').write_text(json.dumps({'create_rejected': 429}))
                env.update(LOCAL_ONLY='yes', FM_BUILD_LOCK_FILE=str(p / 'heavy.lock'),
                           FM_BOAT_TEST_UNAVAILABLE_WAIT_SECS='0',
                           FM_BOAT_TEST_LOCAL_FALLBACK='1' if fallback == 'local' else '0')
                r = subprocess.run(['bash', str(repo / 'bin/fm-boat-test-wrapper.sh'),
                    'if [ "${LOCAL_ONLY:-}" = yes ]; then touch local-ran; exit 23; fi; echo remote'],
                    cwd=p / 'work', env=env, capture_output=True, timeout=30)
                assert r.returncode == (23 if fallback == 'local' else 75), (r.returncode, r.stderr)
                assert (p / 'work/local-ran').exists() == (fallback == 'local')
                assert [call['operation'] for call in upstash_calls(state)].count('create') == 1
            assert creates(state) == 1
            empty(state)
    print('ok - reset and upload failures preserve Boat, Upstash and permitted local admission order')

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
    assert r.returncode == expected, (name, r.stderr)
    assert (p / 'work/local-ran').exists() == (name in (
        'local', 'upload-local', 'upload-too-large', 'upload-capacity'))
print('ok - real wrapper orders Boat then Upstash then permitted heavy-slot local fallback')

PY
