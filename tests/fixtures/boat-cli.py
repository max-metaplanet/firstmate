#!/usr/bin/env python3
"""Local-only Boat CLI fixture; exercises the adapter through its executable."""
import fcntl
import json
import os
import re
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tarfile

# Test wrapper supplies its own record root outside the isolated CLI HOME.
root = Path(sys.argv[1])
fixture = json.loads((root / 'fixture.json').read_text())
state_path = root / 'fake-vms.json'
args = sys.argv[2:]
command = args[0]
with (root / 'cli-homes.jsonl').open('a') as log:
    log.write(json.dumps(str(Path.home())) + '\n')
assert Path.home().stat().st_mode & 0o777 == 0o700
socket_name = 'a_2132ad_bc475afe_7f03ead2afad3b1fe20707c8d2dbd1f2d5802bcc'
assert len(os.fsencode(Path.home() / '.ssh' / socket_name)) < 100
with (root / 'fake.lock').open('a') as handle:
    fcntl.flock(handle, fcntl.LOCK_EX)
    state = json.loads(state_path.read_text()) if state_path.exists() else []
    with (root / 'calls.jsonl').open('a') as log:
        log.write(json.dumps(args) + '\n')
    assert os.environ['BOAT_API_KEY'] == 'boat_fixture_secret'
    assert 'DEV_SECRET' not in os.environ
    assert 'NODE_OPTIONS' not in os.environ
    if fixture.get('unreachable') and command == 'limits':
        sys.exit(1)
    if command == 'limits':
        print(json.dumps({'starts': {w: {'remaining': fixture.get('remaining', 10)}
                                    for w in ('minute', 'hour', 'day')}}))
    elif command == 'list':
        print(json.dumps({'sandboxes': state, 'pageInfo': {'hasMore': fixture.get('hasMore', False)}}))
    elif command == 'new':
        assert '--no-env' in args and '--no-snapshots' in args
        name = args[args.index('--name') + 1]
        state.append({'id': 'bx_fixture' + str(len(state)), 'name': name})
        state_path.write_text(json.dumps(state))
        if fixture.get('lost_create'):
            sys.exit(1)
        print(json.dumps({'event': 'created', 'id': state[-1]['id']}))
        print(json.dumps({'event': 'ready', 'id': state[-1]['id']}))
    elif command == 'delete':
        if fixture.get('delete_failed'):
            sys.exit(1)
        for pidfile in (root / args[1]).glob('process-*'):
            try:
                os.killpg(int(pidfile.read_text()), signal.SIGKILL)
            except ProcessLookupError:
                pass
        state = [vm for vm in state if vm['id'] != args[1]]
        state_path.write_text(json.dumps(state))
        print(json.dumps({'id': 'bdop_fixture', 'status': 'completed'}))
    elif command == 'deletion':
        print(json.dumps({'id': args[2], 'status': 'completed'}))
    elif command == 'push':
        if fixture.get('push_failed'):
            sys.exit(1)
        # Boat push uses Git's tracked/nonignored manifest. Exercise the real
        # consumer here so an archive hidden by an enclosing ignore is rejected.
        manifest = subprocess.check_output(['git', '-C', args[2], 'ls-files',
                                            '--cached', '--others', '--exclude-standard'])
        if b'source.tar.gz' not in manifest.splitlines():
            sys.exit(1)
        remote = root / args[1] / 'fm-job'
        remote.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(Path(args[2]) / 'source.tar.gz', remote / 'source.tar.gz')
        with tarfile.open(remote / 'source.tar.gz') as archive:
            (root / 'uploaded.json').write_text(json.dumps(archive.getnames()))
    elif command == 'scp':
        vm_id, name = args[1].split(':', 1)
        assert name == '/home/user/fm-job/artifacts.tar.gz'
        shutil.copyfile(root / vm_id / 'fm-job/artifacts.tar.gz', args[2])
        if fixture.get('unsafe_artifact'):
            with tarfile.open(args[2], 'w:gz') as archive:
                archive.addfile(tarfile.TarInfo('../escape'))
    elif command != 'exec':
        raise RuntimeError('unexpected Boat call')

if command == 'exec':
    remote = root / args[1] / 'fm-job'
    argv = [a.replace('/home/user/fm-job', str(remote)) for a in args[args.index('--') + 1:]]
    if len(argv) == 3 and argv[:2] == ['bash', '-c'] and argv[2].startswith('sudo -n fallocate'):
        size = re.search(r'fallocate -l ([1-4])G ', argv[2])
        assert size
        (root / 'swap.json').write_text(json.dumps(int(size[1])))
        print(json.dumps({'exitCode': 0, 'stdout': '', 'stderr': ''}))
        sys.exit(0)
    if fixture.get('transport_failed') and '--stream' in args:
        sys.exit(1)
    # The credential stays in the fake CLI process, never the simulated VM.
    env = {'PATH': os.environ['PATH'], 'HOME': str(root / 'remote-home')}
    # Simulated remote processes do not keep the CLI's local stdout pipe open
    # after a transport interrupt. Deleting the fake VM terminates their group.
    argv = [a.replace('timeout -k', 'timeout --foreground -k') for a in argv]
    proc = subprocess.Popen(argv, env=env, start_new_session=True,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    (remote.parent / ('process-' + str(proc.pid))).write_text(str(proc.pid))
    out, err = proc.communicate()
    terminal = {'exitCode': proc.returncode, 'stdoutTruncated': False,
                'stderrTruncated': False, 'success': proc.returncode == 0}
    if '--stream' in args:
        print(json.dumps({'type': 'started', 'commandId': 'cmd_fixture'}))
        print(json.dumps({'type': 'stdout', 'data': out.decode()}))
        print(json.dumps({'type': 'stderr', 'data': err.decode()}))
        if not fixture.get('missing_terminal'):
            print(json.dumps(dict(terminal, type='exit')))
    else:
        print(json.dumps(dict(terminal, stdout=out.decode(), stderr=err.decode())))
    sys.exit(proc.returncode)
