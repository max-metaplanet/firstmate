#!/usr/bin/env bash
# Real-process build serialization, NODE_OPTIONS interception, recursion, crash
# release and the daemon drop-in.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(mktemp -d "$FM_TEST_SCRATCH_ROOT/fm-build-lock.XXXXXX")
python3 - "$ROOT" "$TMP_ROOT" <<'PY'
import configparser
import json
import os
import signal
import resource
from pathlib import Path
import shutil
import subprocess
import sys
import time

root, scratch = map(Path, sys.argv[1:])
wrapper = root / 'bin/fm-build-lock.py'
option = subprocess.run([str(wrapper), 'node-option'], capture_output=True, text=True, check=True).stdout.strip()
env = dict(os.environ, FM_BUILD_LOCK_FILE=str(scratch / 'build.lock'))
for name in ('FM_BUILD_LOCK_BYPASS', 'FM_BUILD_LOCK_HELD', 'NODE_OPTIONS', 'FM_TASK_ID'):
    env.pop(name, None)
children = []


def wait_file(path):
    for _ in range(300):
        if path.exists():
            return
        time.sleep(.03)
    raise AssertionError(f'timed out waiting for {path}')


def launch(command, name, extra=None):
    selected = dict(env, MARKER=str(scratch / name), RELEASE=str(scratch / (name + '.release')))
    selected.update(extra or {})
    log = open(scratch / (name + '.err'), 'w')
    child = subprocess.Popen(command, env=selected, stderr=log)
    log.close()
    children.append(child)
    return child


holder = scratch / 'hold.py'
holder.write_text('''import os, pathlib, time
pathlib.Path(os.environ['MARKER']).write_text(str(os.getpid()))
while not pathlib.Path(os.environ['RELEASE']).exists(): time.sleep(.03)
''')
explicit = [str(wrapper), '--', sys.executable, str(holder)]
try:
    probe = scratch / 'memory-bound.py'
    mechanism = subprocess.run([str(root / 'bin/fm-memcap.sh'), '--mechanism'],
                               capture_output=True, text=True, check=True).stdout.strip()
    if mechanism != 'none':
        probe.write_text('''import pathlib, resource, sys
limit = resource.getrlimit(resource.RLIMIT_AS)[0]
if sys.argv[1] == 'cgroup':
    for line in pathlib.Path('/proc/self/cgroup').read_text().splitlines():
        if line.startswith('0::'):
            path = pathlib.Path('/sys/fs/cgroup') / line[3:].lstrip('/') / 'memory.max'
            limit = int(path.read_text())
print(limit)
''')
        for slots in (1, 2):
            selected = dict(env, FM_HEAVY_SLOTS=str(slots))
            budget = int(subprocess.run([str(root / 'bin/fm-memcap.sh'), '--budget-bytes',
                                         '--share', str(slots)], env=selected,
                                        capture_output=True, text=True, check=True).stdout)
            bound = subprocess.run([str(wrapper), '--', sys.executable, str(probe), mechanism],
                                   env=selected, capture_output=True, text=True, timeout=10)
            assert bound.returncode == 0, bound.stderr
            if mechanism == 'cgroup':
                expected = budget // os.sysconf('SC_PAGE_SIZE') * os.sysconf('SC_PAGE_SIZE')
            else:
                expected = resource.getrlimit(resource.RLIMIT_AS)[0]
            assert int(bound.stdout) == expected, (bound.stdout, expected)
            identity = subprocess.run([str(wrapper), '--', sys.executable, '-c',
                                       'import os; assert os.environ["FM_BUILD_LOCK_HELD"] == str(os.getpid())'],
                                      env=selected, capture_output=True, text=True, timeout=10)
            assert identity.returncode == 0, identity.stderr
            arguments = ['', '${FM_BUILD_ARGV_UNSET}', 'two words', '$HOME', '*', 'a"b']
            argv_env = dict(selected)
            argv_env.pop('FM_BUILD_ARGV_UNSET', None)
            forwarded = subprocess.run([str(wrapper), '--', sys.executable, '-c',
                                        'import json, sys; print(json.dumps(sys.argv[1:]))', *arguments],
                                       env=argv_env, capture_output=True, text=True, timeout=10)
            assert forwarded.returncode == 0, forwarded.stderr
            assert json.loads(forwarded.stdout) == arguments, forwarded.stdout
        print('ok - commands observe the cgroup bound shared across heavy slots, never an address-space one')
    else:
        print('skip - no memory mechanism for the heavy-slot kernel-bound check')

    one = launch(explicit, 'one')
    wait_file(scratch / 'one')
    two = launch(explicit, 'two')
    wait_file(scratch / 'two.err')
    for _ in range(300):
        if 'waiting for a heavy slot' in (scratch / 'two.err').read_text():
            break
        time.sleep(.03)
    assert f'held by pid {one.pid}' in (scratch / 'two.err').read_text()
    assert not (scratch / 'two').exists(), 'second build overlapped holder'
    bypass = launch(explicit, 'bypass', {'FM_BUILD_LOCK_BYPASS': '1'})
    wait_file(scratch / 'bypass')
    (scratch / 'bypass.release').touch()
    assert bypass.wait(10) == 0
    os.kill(int((scratch / 'one').read_text()), signal.SIGKILL)
    one.wait(10)
    wait_file(scratch / 'two')
    (scratch / 'two.release').touch()
    assert two.wait(10) == 0
    print('ok - concurrent builds wait visibly, bypass works, SIGKILL releases the slot')

    fakebin = scratch / 'fakebin'
    fakebin.mkdir()
    checker = fakebin / 'shellcheck'
    checker.write_text('''#!/bin/sh
if [ "$1" = --version ]; then printf 'version: 0.11.0\n'; exit; fi
printf 'checked\n' >> "$CHECK_LOG"
if [ -n "${CHECK_PROBE:-}" ]; then
  python3 "$CHECK_PROBE" "$CHECK_MECHANISM" >> "$CHECK_BOUNDS"
fi
''')
    checker.chmod(0o755)
    fixture = scratch / 'clean.sh'
    fixture.write_text('#!/bin/sh\nexit 0\n')
    lint_env = dict(env, PATH=str(fakebin) + os.pathsep + env['PATH'],
                    CHECK_LOG=str(scratch / 'lint-checks'))
    blocker = launch(explicit, 'lint-blocker')
    wait_file(scratch / 'lint-blocker')
    lint_log = open(scratch / 'lint.err', 'w')
    lint = subprocess.Popen(['bash', str(root / 'bin/fm-lint.sh'), str(fixture)],
                            env=lint_env, stdout=subprocess.DEVNULL, stderr=lint_log)
    lint_log.close()
    children.append(lint)
    for _ in range(300):
        if 'waiting for a heavy slot' in (scratch / 'lint.err').read_text():
            break
        time.sleep(.03)
    assert 'waiting for a heavy slot' in (scratch / 'lint.err').read_text()
    assert not (scratch / 'lint-checks').exists(), 'direct lint bypassed an occupied slot'
    help_result = subprocess.run(['bash', str(root / 'bin/fm-lint.sh'), '--help'],
                                 env=lint_env, capture_output=True, timeout=5)
    assert help_result.returncode == 0, help_result.stderr
    (scratch / 'lint-blocker.release').touch()
    assert blocker.wait(10) == 0
    assert lint.wait(30) == 0, (scratch / 'lint.err').read_text()
    assert (scratch / 'lint-checks').exists(), 'direct lint did not resume after slot release'
    nested_lint = subprocess.run([str(wrapper), '--', 'bash', str(root / 'bin/fm-lint.sh'),
                                  str(fixture)], env=lint_env, capture_output=True, timeout=30)
    assert nested_lint.returncode == 0, nested_lint.stderr
    if mechanism != 'none':
        bounds_log = scratch / 'lint-bounds'
        shared_lint = subprocess.run([str(wrapper), '--', 'bash', str(root / 'bin/fm-lint.sh'),
                                     '--jobs', '2', str(fixture)],
                                    env=dict(lint_env, FM_HEAVY_SLOTS='2', CHECK_PROBE=str(probe),
                                             CHECK_MECHANISM=mechanism, CHECK_BOUNDS=str(bounds_log)),
                                    capture_output=True, timeout=30)
        assert shared_lint.returncode == 0, shared_lint.stderr
        budget = int(subprocess.run([str(root / 'bin/fm-memcap.sh'), '--budget-bytes',
                                     '--share', '4'], capture_output=True, text=True, check=True).stdout)
        budget = budget // 1024 * 1024
        quantum = os.sysconf('SC_PAGE_SIZE') if mechanism == 'cgroup' else 1024
        expected = budget // quantum * quantum
        inherited = resource.getrlimit(resource.RLIMIT_AS)[1]
        if mechanism == 'rlimit' and inherited != resource.RLIM_INFINITY:
            expected = min(expected, inherited // 1024 * 1024)
        assert bounds_log.read_text().strip() == str(expected)
    print('ok - direct lint queues for a slot, nested lint reuses it, and help stays available')

    if subprocess.run(['bash', '-c', 'ulimit -v 98304'], capture_output=True).returncode == 0:
        rlimit_bin = scratch / 'rlimit-bin'
        rlimit_bin.mkdir()
        no_systemd = rlimit_bin / 'systemd-run'
        no_systemd.write_text('#!/bin/sh\nexit 1\n')
        no_systemd.chmod(0o755)
        if not probe.exists():
            probe.write_text('import resource; print(resource.getrlimit(resource.RLIMIT_AS)[0])\n')
        default = int(subprocess.run([str(root / 'bin/fm-memcap.sh'), '--budget-bytes'],
                                     capture_output=True, text=True, check=True).stdout)
        roomy_kib = default // 1024 + 65536
        for label, requested_kib, ceiling in (('override', roomy_kib, roomy_kib * 2048),
                                               ('inherited', 131072, 98304 * 1024 + 511)):
            inherited = resource.getrlimit(resource.RLIMIT_AS)[1]
            if inherited != resource.RLIM_INFINITY:
                ceiling = min(ceiling, inherited)
            def set_ceiling():
                resource.setrlimit(resource.RLIMIT_AS, (ceiling, ceiling))
            for wrapped in (False, True):
                tag = f'{label}-{wrapped}'
                observed = scratch / (tag + '.bound')
                telemetry = scratch / (tag + '.tsv')
                command = ['bash', str(root / 'bin/fm-lint.sh'), '--jobs', '1',
                           '--telemetry', str(telemetry), str(fixture)]
                if wrapped:
                    command = [str(wrapper), '--', *command]
                result = subprocess.run(command, preexec_fn=set_ceiling, timeout=30,
                                        env=dict(lint_env, PATH=str(rlimit_bin) + os.pathsep + lint_env['PATH'],
                                                 FM_LINT_ROOT_MEMORY_KIB=str(requested_kib), FM_LINT_JOBS='1',
                                                 CHECK_PROBE=str(probe), CHECK_MECHANISM='rlimit',
                                                 CHECK_BOUNDS=str(observed)), capture_output=True, text=True)
                assert result.returncode == 0, result.stderr
                expected = min(requested_kib * 1024, ceiling // 1024 * 1024)
                assert int(observed.read_text()) == expected, (tag, observed.read_text(), expected)
                records = [line.split('\t') for line in telemetry.with_suffix('.roots.tsv').read_text().splitlines()]
                reported = next(row[2] for row in records if row[:2] == ['meta', 'root_memory_limit_kib'])
                assert int(reported) * 1024 == expected, (tag, reported, expected)
        print('ok - direct and wrapped lint honor explicit budgets and report inherited rlimit ceilings')

        generic = subprocess.run([str(wrapper), '--', sys.executable, '-c',
                                  'import resource; print(resource.getrlimit(resource.RLIMIT_AS)[0])'],
                                 env=dict(env, PATH=str(rlimit_bin) + os.pathsep + env['PATH']),
                                 capture_output=True, text=True, timeout=10)
        assert generic.returncode == 0, generic.stderr
        assert int(generic.stdout) == resource.getrlimit(resource.RLIMIT_AS)[0], generic.stdout
        opt_in = ('fm-memcap: no usable systemd user scope; address-space limits are opt-in; '
                  f'running {os.path.basename(sys.executable)} uncapped; '
                  'use bin/fm-boat-run.sh to run it bounded')
        assert opt_in in generic.stderr.splitlines(), generic.stderr
        print('ok - a generic wrapped command on a forced-rlimit host runs with no address-space limit')

    real_node = shutil.which('node')
    if real_node:
        cli = scratch / 'node_modules/next/dist/bin/next'
        cli.parent.mkdir(parents=True)
        cli.write_text('''#!/usr/bin/env node
const fs = require('fs');
if (process.argv[2] !== 'build' || process.argv.includes('--help')) { console.log('pass:' + process.argv.slice(2).join('|')); process.exit(0); }
if (process.env.EXIT) process.exit(Number(process.env.EXIT));
if (process.env.NESTED === '1') {
  const child = require('child_process').spawnSync('node', [__filename, 'build'], {
    env: {PATH: process.env.PATH, NODE_OPTIONS: process.env.NODE_OPTIONS,
          FM_BUILD_LOCK_FILE: process.env.FM_BUILD_LOCK_FILE,
          MARKER: process.env.MARKER, RELEASE: process.env.RELEASE, NESTED: '0'}, stdio: 'inherit', timeout: 8000
  });
  if (child.error) throw child.error;
  process.exit(child.status);
}
fs.writeFileSync(process.env.MARKER, String(process.pid));
const timer = setInterval(() => { if (fs.existsSync(process.env.RELEASE)) clearInterval(timer); }, 30);
''')
        cli.chmod(0o755)
        localbin = scratch / 'node_modules/.bin'
        localbin.mkdir()
        (localbin / 'next').symlink_to(cli)
        # A project's own NODE_OPTIONS stays alongside the preload.
        preload = {'NODE_OPTIONS': '--max-old-space-size=512 ' + option}
        first = launch([str(localbin / 'next'), 'build'], 'package', preload)
        wait_file(scratch / 'package')
        second = launch(['node', str(cli), 'build'], 'direct', preload)
        for _ in range(300):
            if 'waiting for a heavy slot' in (scratch / 'direct.err').read_text():
                break
            time.sleep(.03)
        assert 'waiting for a heavy slot' in (scratch / 'direct.err').read_text()
        assert not (scratch / 'direct').exists()
        for command in (['dev'], ['lint'], ['build', '--help']):
            result = subprocess.run(['node', str(cli), *command], env=dict(env, **preload),
                                    capture_output=True, timeout=5)
            assert result.returncode == 0 and result.stdout.startswith(b'pass:'), result.stderr
            assert b'waiting' not in result.stderr
        (scratch / 'package.release').touch()
        assert first.wait(10) == 0
        wait_file(scratch / 'direct')
        (scratch / 'direct.release').touch()
        assert second.wait(10) == 0
        result = subprocess.run(['node', str(cli), 'build'], env=dict(env, EXIT='3', **preload),
                                capture_output=True, timeout=10)
        assert result.returncode == 3, result.stderr
        # Node closes extra fds and the child env drops lock state; ancestor ownership survives.
        (scratch / 'nested.release').touch()
        nested = launch(['node', '--no-warnings', str(cli), 'build'], 'nested', dict(preload, NESTED='1'))
        assert nested.wait(12) == 0, (scratch / 'nested.err').read_text()
        assert (scratch / 'nested').exists()
        print('ok - preload locks .bin and direct Next builds, passes others through, keeps exit status and recursion')

        # The daemon drop-in gives configured commands the same preload.
        units = scratch / 'units'
        units.mkdir()
        (units / 'no-mistakes-daemon-test.service').write_text('[Service]\nExecStart=/bin/true\n')
        subprocess.run([str(wrapper), 'install-daemon-env', '--unit-dir', str(units)], check=True,
                       capture_output=True, timeout=5)
        parser = configparser.ConfigParser(interpolation=None)
        parser.optionxform = str
        parser.read(units / 'no-mistakes-daemon-test.service.d/fm-build-lock.conf')
        name, value = parser['Service']['Environment'].strip('"').split('=', 1)
        assert name == 'NODE_OPTIONS'
        holder_run = launch(explicit, 'daemon-holder')
        wait_file(scratch / 'daemon-holder')
        daemon = launch(['node', str(cli), 'build'], 'daemon', {'NODE_OPTIONS': value})
        for _ in range(300):
            if 'waiting for a heavy slot' in (scratch / 'daemon.err').read_text():
                break
            time.sleep(.03)
        assert 'waiting for a heavy slot' in (scratch / 'daemon.err').read_text()
        (scratch / 'daemon-holder.release').touch()
        assert holder_run.wait(10) == 0
        wait_file(scratch / 'daemon')
        (scratch / 'daemon.release').touch()
        assert daemon.wait(10) == 0
        print('ok - daemon drop-in environment serializes configured Next builds')
    else:
        print('skip - Node CLI interception needs node installed')

    result = subprocess.run([str(wrapper), 'install-daemon-env', '--unit-dir', str(scratch)],
                            env=env, capture_output=True, timeout=5)
    assert result.returncode == 75 and b'no no-mistakes daemon unit' in result.stderr
    print('ok - daemon drop-in refuses a directory without a daemon unit')

    # NODE_OPTIONS names an installed copy, so removing the checkout that
    # installed it leaves every Node process able to start.
    checkout = scratch / 'checkout/bin'
    checkout.mkdir(parents=True)
    for name in ('fm-build-lock.py', 'fm-build-lock.js', 'fm-heavy-route.py', 'fm-memcap.sh'):
        shutil.copy2(root / 'bin' / name, checkout / name)
    installed = scratch / 'installed'
    install_env = dict(env, FM_BUILD_LOCK_INSTALL_DIR=str(installed), NODE_OPTIONS='--max-old-space-size=512')
    env_file = scratch / 'node-options.sh'
    inherited_path = install_env['PATH']
    for _ in range(2):
        subprocess.run([str(checkout / 'fm-build-lock.py'), 'node-env-file', str(env_file)],
                       env=install_env, check=True, timeout=5)
        install_env['NODE_OPTIONS'], install_env['PATH'] = subprocess.run(
            ['sh', '-c', '. "$1" && printf "%s\\n%s" "$NODE_OPTIONS" "$PATH"', '_', str(env_file)],
            env=install_env, capture_output=True, text=True, check=True).stdout.split('\n')
    assert install_env['NODE_OPTIONS'] == f'--max-old-space-size=512 --require={installed}/fm-build-lock.js', \
        install_env['NODE_OPTIONS']
    # The shim directory leads PATH once, ahead of everything the worker inherited.
    assert install_env['PATH'] == f'{installed}/shims:{inherited_path}', install_env['PATH']
    if shutil.which('fish'):
        result = subprocess.run(['fish', '-c', f"source '{env_file}'; and printf %s $NODE_OPTIONS"],
                                env=install_env, capture_output=True, text=True, check=True)
        assert result.stdout == install_env['NODE_OPTIONS'], result.stdout
    shutil.rmtree(scratch / 'checkout')
    if real_node:
        result = subprocess.run(['node', '-e', '0'], env=install_env, capture_output=True, timeout=5)
        assert result.returncode == 0, result.stderr
        result = subprocess.run(['node', str(cli), 'dev'], env=install_env, capture_output=True, timeout=5)
        assert result.returncode == 0 and result.stdout.startswith(b'pass:'), result.stderr
    print('ok - env file appends the installed preload once and Node survives checkout removal')

    # Lock setup must fail promptly instead of executing a heavy command unlocked.
    result = subprocess.run([str(wrapper), '--', 'true'],
                            env=dict(env, FM_BUILD_LOCK_FILE='relative'), capture_output=True, timeout=5)
    assert result.returncode == 75 and b'must be absolute' in result.stderr
    print('ok - invalid lock configuration fails closed')
finally:
    for child in children:
        if child.poll() is None:
            child.kill()
        child.wait()
PY

# The counted pool: N slots admit N heavy commands at once and queue the next,
# a killed holder frees its slot, and the preload covers the heavy commands
# workers actually run.
POOL_ROOT=$(mktemp -d "$FM_TEST_SCRATCH_ROOT/fm-heavy-pool.XXXXXX")
python3 - "$ROOT" "$POOL_ROOT" <<'PY'
import os
import signal
from pathlib import Path
import pty
import shutil
import subprocess
import sys
import time

root, scratch = map(Path, sys.argv[1:])
wrapper = root / 'bin/fm-build-lock.py'
env = dict(os.environ, FM_BUILD_LOCK_FILE=str(scratch / 'pool.lock'),
           FM_BUILD_LOCK_INSTALL_DIR=str(scratch / 'install'))
for name in ('FM_BUILD_LOCK_BYPASS', 'FM_BUILD_LOCK_HELD', 'NODE_OPTIONS', 'FM_HEAVY_SLOTS',
             'FM_TASK_ID'):
    env.pop(name, None)
children = []


def wait_file(path, limit=300):
    for _ in range(limit):
        if path.exists():
            return True
        time.sleep(.03)
    return False


def launch(name, slots=None, extra=None):
    selected = dict(env, MARKER=str(scratch / name), RELEASE=str(scratch / (name + '.release')))
    if slots is not None:
        selected['FM_HEAVY_SLOTS'] = slots
    selected.update(extra or {})
    log = open(scratch / (name + '.err'), 'w')
    child = subprocess.Popen([str(wrapper), '--', sys.executable, str(holder)],
                             env=selected, stderr=log)
    log.close()
    children.append(child)
    return child


holder = scratch / 'hold.py'
holder.write_text('''import os, pathlib, time
pathlib.Path(os.environ['MARKER']).write_text(str(os.getpid()))
while not pathlib.Path(os.environ['RELEASE']).exists(): time.sleep(.03)
''')
try:
    # The declared size is what the pool offers: three run at once, the fourth waits.
    running = [launch(f'slot{i}', slots='3') for i in range(3)]
    for i in range(3):
        assert wait_file(scratch / f'slot{i}'), f'slot{i} never started under a pool of three'
    queued = launch('queued', slots='3')
    for _ in range(300):
        if 'waiting for a heavy slot' in (scratch / 'queued.err').read_text():
            break
        time.sleep(.03)
    assert 'waiting for a heavy slot' in (scratch / 'queued.err').read_text(), \
        (scratch / 'queued.err').read_text()
    assert not (scratch / 'queued').exists(), 'a fourth heavy command ran in a pool of three'
    assert '3 on this machine' in (scratch / 'queued.err').read_text()

    # SIGKILL frees the slot it held, with no file removed and no cleanup run.
    os.kill(int((scratch / 'slot1').read_text()), signal.SIGKILL)
    running[1].wait(10)
    assert wait_file(scratch / 'queued'), 'a killed holder did not free its slot'
    for name in ('slot0', 'slot2', 'queued'):
        (scratch / (name + '.release')).touch()
    for child in (running[0], running[2], queued):
        assert child.wait(10) == 0
    print('ok - a pool of N admits N heavy commands, queues the next, and SIGKILL frees a slot')

    # The size comes from the installed record when the environment names none,
    # and a size that is not a positive integer is an error, not a guess.
    subprocess.run([str(wrapper), 'node-option'], env=dict(env, FM_HEAVY_SLOTS='2'),
                   check=True, capture_output=True, timeout=5)
    recorded = [launch(f'rec{i}') for i in range(2)]
    for i in range(2):
        assert wait_file(scratch / f'rec{i}'), f'rec{i} never started under the recorded pool of two'
    third = launch('rec-queued')
    for _ in range(300):
        if '2 on this machine' in (scratch / 'rec-queued.err').read_text():
            break
        time.sleep(.03)
    assert '2 on this machine' in (scratch / 'rec-queued.err').read_text(), \
        (scratch / 'rec-queued.err').read_text()
    assert not (scratch / 'rec-queued').exists(), \
        'a third heavy command ran under a recorded pool of two'
    for name in ('rec0', 'rec1', 'rec-queued'):
        (scratch / (name + '.release')).touch()
    for child in (*recorded, third):
        assert child.wait(10) == 0
    bad = subprocess.run([str(wrapper), '--', 'true'], env=dict(env, FM_HEAVY_SLOTS='two'),
                         capture_output=True, timeout=5)
    assert bad.returncode == 75 and b'positive integer' in bad.stderr, bad.stderr
    print('ok - the pool size comes from the installed record and refuses a malformed value')

    def publish(size):
        subprocess.run([str(wrapper), 'node-option'], env=dict(env, FM_HEAVY_SLOTS=str(size)),
                       check=True, capture_output=True, timeout=5)

    def wait_queued(name):
        for _ in range(300):
            if 'waiting for a heavy slot' in (scratch / (name + '.err')).read_text():
                return
            time.sleep(.03)
        raise AssertionError(f'{name} never queued')

    publish(1)
    first = launch('grow-first')
    assert wait_file(scratch / 'grow-first')
    waiter = launch('grow-waiter')
    wait_queued('grow-waiter')
    publish(2)
    assert wait_file(scratch / 'grow-waiter'), 'an existing waiter ignored a newly published slot'
    assert first.poll() is None, 'growth was not exercised with the original slot occupied'
    for name in ('grow-first', 'grow-waiter'):
        (scratch / (name + '.release')).touch()
    assert first.wait(10) == waiter.wait(10) == 0

    for release_retired in (True, False):
        publish(2)
        tag = 'shrink-retired' if release_retired else 'shrink-active'
        first = launch(tag + '-first')
        assert wait_file(scratch / (tag + '-first'))
        second = launch(tag + '-second')
        assert wait_file(scratch / (tag + '-second'))
        waiter = launch(tag + '-waiter')
        wait_queued(tag + '-waiter')
        publish(1)
        time.sleep(.6)
        released = 'second' if release_retired else 'first'
        remaining = 'first' if release_retired else 'second'
        (scratch / (tag + '-' + released + '.release')).touch()
        assert (second if release_retired else first).wait(10) == 0
        assert not wait_file(scratch / (tag + '-waiter'), limit=30), \
            'a waiter exceeded the reduced limit while an existing holder drained'
        (scratch / (tag + '-' + remaining + '.release')).touch()
        assert (first if release_retired else second).wait(10) == 0
        assert wait_file(scratch / (tag + '-waiter')), 'the reduced pool never resumed admission'
        (scratch / (tag + '-waiter.release')).touch()
        assert waiter.wait(10) == 0

    recursive = scratch / 'recursive.py'
    recursive.write_text('''import os, pathlib, subprocess, sys, time
pathlib.Path(os.environ['MARKER']).touch()
while not pathlib.Path(os.environ['TRIGGER']).exists(): time.sleep(.03)
subprocess.run([os.environ['WRAPPER'], '--', sys.executable, '-c',
                'import os, pathlib; pathlib.Path(os.environ["NESTED_MARKER"]).touch()'],
               check=True, timeout=5, close_fds=True)
while not pathlib.Path(os.environ['RELEASE']).exists(): time.sleep(.03)
''')
    publish(2)
    first = launch('recursive-first')
    assert wait_file(scratch / 'recursive-first')
    original_holder = holder
    holder = recursive
    second = launch('recursive-second', extra={
        'TRIGGER': str(scratch / 'recursive-trigger'), 'WRAPPER': str(wrapper),
        'NESTED_MARKER': str(scratch / 'recursive-nested')})
    holder = original_holder
    assert wait_file(scratch / 'recursive-second')
    publish(1)
    (scratch / 'recursive-trigger').touch()
    assert wait_file(scratch / 'recursive-nested'), 'nested work failed to reuse a retired slot'
    assert first.poll() is None, 'recursion was not exercised with the active slot occupied'
    for name in ('recursive-first', 'recursive-second'):
        (scratch / (name + '.release')).touch()
    assert first.wait(10) == second.wait(10) == 0
    print('ok - waiting commands observe growth and shrinkage, draining holders and retired-slot recursion')

    real_node = shutil.which('node')
    if real_node:
        # The CLI entry points pnpm resolves for these packages, so the preload
        # recognizes the commands workers actually run.
        option = subprocess.run([str(wrapper), 'node-option'], env=env, check=True,
                                capture_output=True, text=True, timeout=5).stdout.strip()
        # The fake CLI exits as soon as its RELEASE file exists, so a run that
        # wins a slot finishes on its own. vitest's entry is ESM, the others CJS.
        cjs = """#!/usr/bin/env node
const fs = require('fs');
run(fs);
"""
        esm = """#!/usr/bin/env node
import fs from 'node:fs';
run(fs);
"""
        shared = """
function run(fs) {
  if (!process.env.MARKER) { console.log('ran:' + process.argv.slice(2).join('|')); return; }
  fs.writeFileSync(process.env.MARKER, String(process.pid));
  const timer = setInterval(() => {
    if (fs.existsSync(process.env.RELEASE)) { clearInterval(timer); }
  }, 30);
}
"""
        entries = {
            'vitest': ('node_modules/vitest/vitest.mjs', esm),
            'playwright': ('node_modules/@playwright/test/cli.js', cjs),
            'playwright-package': ('node_modules/playwright/cli.js', cjs),
            'tsc': ('node_modules/typescript/bin/tsc', cjs),
            'eslint': ('node_modules/eslint/bin/eslint.js', cjs),
            'next': ('node_modules/next/dist/bin/next', cjs),
        }
        for name, (rel, head) in entries.items():
            cli = scratch / rel
            cli.parent.mkdir(parents=True, exist_ok=True)
            cli.write_text(head + shared)
            cli.chmod(0o755)
        localbin = scratch / 'node_modules/.bin'
        localbin.mkdir(exist_ok=True)
        for name in ('vitest', 'playwright', 'playwright-package', 'eslint', 'tsc'):
            link = localbin / name if name != 'playwright-package' else localbin / 'package' / 'playwright'
            link.parent.mkdir(exist_ok=True)
            link.symlink_to(scratch / entries[name][0])
            entries[name + '-bin'] = (str(link.relative_to(scratch)), None)
        preload = {'NODE_OPTIONS': option, 'FM_HEAVY_SLOTS': '1'}
        # The one-file exemption needs the named file to exist where the
        # command resolves it, so every case runs in the scratch tree.
        for rel in ('one-file.ts', 'src/one.js', 'src/one.tsx', 'src/one.ts', 'src/a.ts',
                    'src/b.ts', 'app/[locale]/page.tsx', 'tsconfig.json',
                    'apps/admin-center/tsconfig.json'):
            (scratch / rel).parent.mkdir(parents=True, exist_ok=True)
            (scratch / rel).write_text('export {};\n')
        # Off a TTY a bare vitest runs the suite once, as a package test script does.
        # The last case runs on a TTY, where only the run subcommand marks it heavy.
        heavy = [
            ('vitest', ['run'], False),
            ('vitest', [], False),
            ('vitest', ['--run', '--reporter=dot'], False),
            ('vitest', ['--config', 'x', 'run'], True),
            ('playwright', ['test'], False),
            ('playwright-package', ['test'], False),
            ('vitest-bin', ['run'], False),
            ('playwright-bin', ['test'], False),
            ('playwright-package-bin', ['test'], False),
            ('tsc', ['--noEmit', '-p', 'tsconfig.json'], False),
            ('eslint', [], False),
            ('eslint', ['.'], False),
            ('eslint-bin', ['src'], False),
            # A bare extension is a flag value, not the one source file that
            # would exempt the run.
            ('eslint', ['--ext', '.ts', 'src'], False),
            # A config, formatter, or extension list naming a script file is an
            # option value, not the one source file that would exempt the run.
            ('eslint', ['-c', 'eslint.config.mjs', '.'], False),
            ('eslint', ['-f', './formatter.js', 'src'], False),
            ('eslint', ['--ext=.ts,.tsx', 'src'], False),
            ('tsc', ['-p', 'tsconfig.json', '--outFile', 'dist/out.js'], False),
            # Two named source files are more than the one file the exemption covers.
            ('eslint', ['src/a.ts', 'src/b.ts'], False),
            ('tsc', ['--noEmit', 'src/a.ts', 'src/b.ts'], False),
            # A quoted glob the tool expands itself, or a directory beside one
            # file, stands for many files.
            ('eslint', ['src/**/*.ts'], False),
            ('eslint', ['src', 'src/a.ts'], False),
            ('eslint', ['src'], False),
            ('tsc', ['--noEmit', 'src/**/*.ts'], False),
            ('tsc', ['--noEmit', 'src'], False),
            # A real config file is not a source file, and a build builds whole
            # projects, including through the .bin link npx resolves.
            ('tsc', ['--noEmit', 'tsconfig.json'], False),
            ('tsc', ['-b', 'tsconfig.json'], False),
            ('tsc', ['--build', 'apps/admin-center/tsconfig.json'], False),
            ('tsc-bin', ['-b', 'tsconfig.json'], False),
            # Under a build, -v is --verbose rather than --version.
            ('tsc', ['-b', '-v', 'tsconfig.json'], False),
            ('next', ['build'], False),
        ]
        light = [
            ('vitest', ['--version']),
            ('vitest', ['watch']),
            ('vitest', ['--watch']),
            ('playwright', ['install']),
            ('playwright-package', ['install']),
            ('playwright-package', ['test', '--help']),
            ('tsc', ['one-file.ts', '--noEmit']),
            ('tsc', ['--noEmit', 'src/one.js']),
            ('tsc', ['--watch', '-p', 'tsconfig.json']),
            ('tsc', ['-w']),
            # A watch build never exits, so watch wins over the build rule.
            ('tsc', ['-v']),
            ('tsc', ['-b', '--watch']),
            ('tsc', ['-b', '-w']),
            ('tsc', ['--build', '--version']),
            ('eslint', ['--version']),
            ('eslint', ['src/one.tsx']),
            ('eslint', ['-c', 'eslint.config.mjs', 'src/one.ts']),
            ('eslint', ['--max-warnings', '0', 'src/one.ts']),
            ('tsc', ['--target', 'es2020', 'one-file.ts']),
            # App Router paths carry literal brackets; one real such file is light.
            ('eslint', ['app/[locale]/page.tsx']),
            ('tsc', ['--noEmit', 'app/[locale]/page.tsx']),
            ('next', ['dev']),
            ('next', ['start']),
        ]
        for case, (name, args, tty) in enumerate(heavy):
            tag = f'{name}-{case}'
            blocker = launch('block-' + tag, slots='1')
            assert wait_file(scratch / ('block-' + tag)), f'the blocker before {name} never started'
            (scratch / (tag + '.release')).touch()
            log = open(scratch / (tag + '.err'), 'w')
            leader, follower = pty.openpty() if tty else (None, subprocess.DEVNULL)
            command = [str(scratch / entries[name][0]), *args]
            if not name.endswith('-bin'):
                command.insert(0, 'node')
            child = subprocess.Popen(command, cwd=scratch,
                                     env=dict(env, MARKER=str(scratch / tag),
                                              RELEASE=str(scratch / (tag + '.release')), **preload),
                                     stdin=follower, stderr=log)
            log.close()
            if tty:
                os.close(follower)
            children.append(child)
            for _ in range(300):
                if 'waiting for a heavy slot' in (scratch / (tag + '.err')).read_text():
                    break
                time.sleep(.03)
            assert 'waiting for a heavy slot' in (scratch / (tag + '.err')).read_text(), \
                f'{name} {" ".join(args)} did not claim a heavy slot: ' + (scratch / (tag + '.err')).read_text()
            assert not (scratch / tag).exists(), f'{name} ran while the only slot was held'
            (scratch / ('block-' + tag + '.release')).touch()
            assert blocker.wait(10) == 0
            assert child.wait(30) == 0, (scratch / (tag + '.err')).read_text()
            if tty:
                os.close(leader)
            assert (scratch / tag).exists(), f'{name} never ran after its slot freed'
        # The only slot stays held, so a light command that wrongly claims one
        # waits and times out instead of passing.
        blocker = launch('block-light', slots='1')
        assert wait_file(scratch / 'block-light'), 'the blocker before the light cases never started'
        for name, args in light:
            result = subprocess.run(['node', str(scratch / entries[name][0]), *args], cwd=scratch,
                                    env=dict(env, **preload), stdin=subprocess.DEVNULL,
                                    capture_output=True, timeout=30)
            assert result.returncode == 0 and result.stdout.startswith(b'ran:'), result.stderr
            assert b'waiting' not in result.stderr, f'{name} {" ".join(args)} took a heavy slot'
        (scratch / 'block-light.release').touch()
        assert blocker.wait(10) == 0
        print('ok - the preload locks Vitest, Playwright, ESLint, next build and '
              'whole-project tsc and passes the rest through')

        # A shell that ASSIGNS NODE_OPTIONS drops the preload; the PATH shim the
        # worker launch puts first restores it before the real tsc starts.
        shims = Path(option.split('=', 1)[1]).parent / 'shims'
        realbin = scratch / 'realbin'
        realbin.mkdir()
        (realbin / 'tsc').symlink_to(scratch / entries['tsc'][0])
        (realbin / 'vitest').write_text('#!/bin/sh\nprintf %s "$NODE_OPTIONS"\n')
        (realbin / 'vitest').chmod(0o755)
        shim_path = f'{shims}:{realbin}:{env["PATH"]}'
        blocker = launch('block-shim', slots='1')
        assert wait_file(scratch / 'block-shim'), 'the blocker before the shim case never started'
        (scratch / 'shim-tsc.release').touch()
        log = open(scratch / 'shim-tsc.err', 'w')
        child = subprocess.Popen(
            ['sh', '-c', 'NODE_OPTIONS=--max-old-space-size=512 tsc --noEmit -p tsconfig.json'],
            env=dict(env, PATH=shim_path, FM_HEAVY_SLOTS='1', MARKER=str(scratch / 'shim-tsc'),
                     RELEASE=str(scratch / 'shim-tsc.release')),
            stdin=subprocess.DEVNULL, stderr=log)
        log.close()
        children.append(child)
        for _ in range(300):
            if 'waiting for a heavy slot' in (scratch / 'shim-tsc.err').read_text():
                break
            time.sleep(.03)
        assert 'waiting for a heavy slot' in (scratch / 'shim-tsc.err').read_text(), \
            'a shell-assigned NODE_OPTIONS tsc found through the shim took no slot: ' + \
            (scratch / 'shim-tsc.err').read_text()
        assert not (scratch / 'shim-tsc').exists(), 'tsc ran while the only slot was held'
        (scratch / 'block-shim.release').touch()
        assert blocker.wait(10) == 0
        assert child.wait(30) == 0, (scratch / 'shim-tsc.err').read_text()
        assert (scratch / 'shim-tsc').exists(), 'the shimmed tsc never ran after its slot freed'
        # The preload is added once, and a bypass leaves the environment as it was.
        for extra, expected in (({'NODE_OPTIONS': '--max-old-space-size=512'},
                                 f'--max-old-space-size=512 {option}'),
                                ({'NODE_OPTIONS': option}, option),
                                ({'NODE_OPTIONS': '--max-old-space-size=512', 'FM_BUILD_LOCK_BYPASS': '1'},
                                 '--max-old-space-size=512')):
            result = subprocess.run(['vitest'], env=dict(env, PATH=shim_path, **extra),
                                    capture_output=True, text=True, timeout=10)
            assert result.returncode == 0 and result.stdout == expected, (extra, result)
        # With no real command after its own directory the shim reports it
        # missing instead of running itself again.
        result = subprocess.run([str(shims / 'eslint'), '.'], env=dict(env, PATH=str(shims)),
                                capture_output=True, text=True, timeout=10)
        assert result.returncode == 127 and 'eslint: command not found' in result.stderr, result
        print('ok - the PATH shim restores the preload a shell assignment dropped, once, '
              'and never runs itself')
    else:
        print('skip - heavy CLI interception needs node installed')
finally:
    for child in children:
        if child.poll() is None:
            child.kill()
        child.wait()
PY

# Coverage across a project's own environment handling: a child whose
# NODE_OPTIONS the parent assigned, a step whose whole environment was rebuilt
# from an allowlist, and a package script that is heavy as a whole.
ENV_ROOT=$(mktemp -d "$FM_TEST_SCRATCH_ROOT/fm-heavy-env.XXXXXX")
python3 - "$ROOT" "$ENV_ROOT" <<'PY'
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time

root, scratch = map(Path, sys.argv[1:])
wrapper = root / 'bin/fm-build-lock.py'
if not shutil.which('node'):
    print('skip - project environment coverage needs node installed')
    sys.exit(0)

env = dict(os.environ, FM_BUILD_LOCK_FILE=str(scratch / 'pool.lock'),
           FM_BUILD_LOCK_INSTALL_DIR=str(scratch / 'install'), FM_HEAVY_SLOTS='1')
for name in ('FM_BUILD_LOCK_BYPASS', 'FM_BUILD_LOCK_HELD', 'NODE_OPTIONS', 'npm_lifecycle_event',
             'FM_TASK_ID'):
    env.pop(name, None)
option = subprocess.run([str(wrapper), 'node-option'], env=env, check=True,
                        capture_output=True, text=True, timeout=10).stdout.strip()
mechanism = subprocess.run([str(root / 'bin/fm-memcap.sh'), '--mechanism'],
                           capture_output=True, text=True, check=True).stdout.strip()
children = []


def report(path):
    """The subject writes one JSON line naming its slot, cgroup and options."""
    return f'''const fs = require('fs');
let cgroup = '';
try {{ cgroup = fs.readFileSync('/proc/self/cgroup', 'utf8').trim(); }} catch {{}}
fs.writeFileSync({json.dumps(str(path))}, JSON.stringify({{
  pid: process.pid, cgroup,
  options: process.env.NODE_OPTIONS || '',
  held: process.env.FM_BUILD_LOCK_HELD || '',
}}));
'''


# A fake whole-project tsc: heavy by the preload's definition, and quick.
tsc = scratch / 'node_modules/typescript/bin/tsc'
tsc.parent.mkdir(parents=True, exist_ok=True)
tsc.write_text('#!/usr/bin/env node\n' + report(scratch / 'tsc.json'))
tsc.chmod(0o755)
heavy_child = [str(tsc), '--noEmit', '-p', 'tsconfig.json']

holder = scratch / 'hold.py'
holder.write_text('''import os, pathlib, time
pathlib.Path(os.environ['MARKER']).write_text(str(os.getpid()))
while not pathlib.Path(os.environ['RELEASE']).exists(): time.sleep(.03)
''')


def wait_file(path, limit=300):
    for _ in range(limit):
        if path.exists():
            return True
        time.sleep(.03)
    return False


def hold_the_slot(name):
    """Occupy the only slot, so anything that claims one has to wait for it."""
    selected = dict(env, MARKER=str(scratch / name), RELEASE=str(scratch / (name + '.release')))
    child = subprocess.Popen([str(wrapper), '--', sys.executable, str(holder)], env=selected)
    children.append(child)
    assert wait_file(scratch / name), f'the blocker {name} never took the only slot'
    return child


def release(child, name):
    (scratch / (name + '.release')).touch()
    assert child.wait(10) == 0


def wait_for(stream, text, name):
    for _ in range(300):
        if text in stream.read_text():
            return
        time.sleep(.03)
    raise AssertionError(f'{name} never printed {text!r}: {stream.read_text()}')


def run_parent(body, name, extra=None, scrub=None):
    script = scratch / (name + '.js')
    script.write_text(body)
    selected = dict(env, NODE_OPTIONS=option)
    selected.update(extra or {})
    log = open(scratch / (name + '.err'), 'w')
    child = subprocess.Popen(['node', str(script)], env=selected, stderr=log,
                             stdout=subprocess.DEVNULL)
    log.close()
    children.append(child)
    return child


def spawn_call(env_literal):
    return f'''require('child_process').execFileSync({json.dumps(heavy_child[0])},
  {json.dumps(heavy_child[1:])}, {{ env: {env_literal}, stdio: 'inherit' }});
'''


# An allowlist that keeps this test's own pool and install directory, as a real
# allowlist keeps PATH, so the subject resolves the same pool its parent did.
ALLOWLIST = '''const passed = Object.fromEntries(Object.entries(process.env)
  .filter(([key]) => /^(?:PATH|HOME|FM_BUILD_LOCK_FILE|FM_BUILD_LOCK_INSTALL_DIR|FM_HEAVY_SLOTS)$/
    .test(key)));
'''

try:
    # A parent that ASSIGNS NODE_OPTIONS still produces a locked child.
    blocker = hold_the_slot('assign-blocker')
    parent = run_parent(spawn_call("{ ...process.env, NODE_OPTIONS: '--max-old-space-size=6144' }"),
                        'assign')
    wait_for(scratch / 'assign.err', 'waiting for a heavy slot', 'the assigned-options child')
    assert not (scratch / 'tsc.json').exists(), 'the child ran while the only slot was held'
    release(blocker, 'assign-blocker')
    assert parent.wait(30) == 0, (scratch / 'assign.err').read_text()
    recorded = json.loads((scratch / 'tsc.json').read_text())
    assert option in recorded['options'], recorded
    assert '--max-old-space-size=6144' in recorded['options'], recorded
    print('ok - a child whose NODE_OPTIONS the parent assigned still claims a slot')

    # An environment the parent built without NODE_OPTIONS is left alone.
    (scratch / 'tsc.json').unlink()
    blocker = hold_the_slot('scrub-blocker')
    parent = run_parent(ALLOWLIST + spawn_call('passed'), 'scrub')
    assert wait_file(scratch / 'tsc.json'), 'a child with no NODE_OPTIONS was made to wait'
    assert parent.wait(30) == 0, (scratch / 'scrub.err').read_text()
    assert 'waiting' not in (scratch / 'scrub.err').read_text()
    recorded = json.loads((scratch / 'tsc.json').read_text())
    assert recorded['options'] == '', recorded
    release(blocker, 'scrub-blocker')
    print('ok - an environment built without NODE_OPTIONS keeps none')

    # A heavy package script claims one slot for its whole run; a step whose
    # environment was rebuilt from an allowlist takes no slot of its own and is
    # covered by the script's cgroup, and a step that kept NODE_OPTIONS reclaims
    # the same slot instead of deadlocking on the only one.
    (scratch / 'tsc.json').unlink()
    blocker = hold_the_slot('script-blocker')
    body = (report(scratch / 'script.json') + ALLOWLIST + spawn_call('passed') +
            f'''require('fs').copyFileSync({json.dumps(str(scratch / 'tsc.json'))},
  {json.dumps(str(scratch / 'tsc-scrubbed.json'))});
''' + spawn_call("{ ...process.env, NODE_OPTIONS: '--max-old-space-size=6144' }"))
    parent = run_parent(body, 'script', extra={'npm_lifecycle_event': 'queue-preflight'})
    wait_for(scratch / 'script.err', 'waiting for a heavy slot', 'the heavy package script')
    assert not (scratch / 'script.json').exists(), 'the script ran while the only slot was held'
    release(blocker, 'script-blocker')
    assert parent.wait(60) == 0, (scratch / 'script.err').read_text()
    script_run = json.loads((scratch / 'script.json').read_text())
    scrubbed = json.loads((scratch / 'tsc-scrubbed.json').read_text())
    reclaimed = json.loads((scratch / 'tsc.json').read_text())
    assert script_run['held'] == str(script_run['pid']), script_run
    assert scrubbed['options'] == '' and scrubbed['held'] == '', scrubbed
    assert option in reclaimed['options'], reclaimed
    if mechanism == 'cgroup':
        assert script_run['cgroup'].endswith('.scope'), script_run
        assert scrubbed['cgroup'] == script_run['cgroup'], (scrubbed, script_run)
        assert reclaimed['cgroup'] == script_run['cgroup'], (reclaimed, script_run)
    print('ok - a heavy package script holds one slot its steps share, '
          'capped even where their environment dropped the preload')

    # Only queue-preflight is heavy as a whole; any other lifecycle event,
    # including a plain preflight, runs without a slot.
    (scratch / 'tsc.json').unlink()
    blocker = hold_the_slot('other-blocker')
    for event in ('postinstall', 'preflight'):
        parent = run_parent(report(scratch / f'{event}.json'), event,
                            extra={'npm_lifecycle_event': event})
        assert wait_file(scratch / f'{event}.json'), f'a {event} package script claimed a heavy slot'
        assert parent.wait(30) == 0, (scratch / f'{event}.err').read_text()
        assert json.loads((scratch / f'{event}.json').read_text())['held'] == ''
    parent = run_parent(report(scratch / 'named.json'), 'named',
                        extra={'npm_lifecycle_event': 'queue-preflight'})
    wait_for(scratch / 'named.err', 'waiting for a heavy slot', 'a queue-preflight package script')
    release(blocker, 'other-blocker')
    assert parent.wait(30) == 0, (scratch / 'named.err').read_text()
    print('ok - only a queue-preflight package script is heavy as a whole')

    # The promise forms callers reach for get the same repair: each child
    # reports the NODE_OPTIONS it actually received.
    promised = subprocess.run(
        ['node', '-e', '''const util = require('util');
const cp = require('child_process');
const env = { ...process.env, NODE_OPTIONS: '--max-old-space-size=512' };
Promise.all([
  util.promisify(cp.exec)('printf %s "$NODE_OPTIONS"', { env }),
  util.promisify(cp.execFile)('sh', ['-c', 'printf %s "$NODE_OPTIONS"'], { env }),
]).then((results) => console.log(JSON.stringify(results.map(({ stdout }) => stdout))));
'''], env=dict(env, NODE_OPTIONS=option), capture_output=True, text=True, timeout=30)
    assert promised.returncode == 0, promised
    for form, received in zip(('exec', 'execFile'), json.loads(promised.stdout)):
        assert received.split() == ['--max-old-space-size=512', option], (form, received)
    print('ok - promisified exec and execFile children get the preload put back')
finally:
    for child in children:
        if child.poll() is None:
            child.kill()
        child.wait()
PY
