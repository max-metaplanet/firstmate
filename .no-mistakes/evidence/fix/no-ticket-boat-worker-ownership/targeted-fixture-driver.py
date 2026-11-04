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
    p, state, env = case('task-reuse')
    env = managed(p, env)
    r = launch(p, env, 'echo dirty > leftover; echo cache > "$HOME/cache"; '
               'sleep 90 >/dev/null 2>&1 & echo $!; setsid sleep 90 >/dev/null 2>&1 & echo $!')
    assert r.returncode == 0, r.stderr
    first = result(p)
    assert first['cleanup'] == 'retained' and not first['reused'], first
    pids = [int(line) for line in r.stdout.splitlines()]
    for pid in pids:
        path = Path('/proc') / str(pid) / 'stat'
        assert not path.exists() or path.read_text().split(') ')[1].startswith('Z'), pid
    (p / 'work/tracked.txt').write_text('fresh second source\n')
    (state / 'fixture.json').write_text(json.dumps(dict(remaining=0, canStart=False, nextStartDollars=.03)))
    r = next_run(p, env, 'test ! -e leftover && test ! -e "$HOME/cache" && cat tracked.txt')
    assert r.returncode == 0 and r.stdout == b'fresh second source\n', (r.returncode, r.stderr, r.stdout)
    assert result(p)['reused'] and result(p)['vm_id'] == first['vm_id'], result(p)
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

