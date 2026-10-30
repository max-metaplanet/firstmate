#!/usr/bin/env bash
# Real-process build serialization, NODE_OPTIONS interception, recursion, crash
# release and the daemon drop-in.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(mktemp -d "$FM_TEST_SCRATCH_ROOT/fm-build-lock.XXXXXX")
python3 - "$ROOT" "$TMP_ROOT" <<'PY'
import configparser
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time

root, scratch = map(Path, sys.argv[1:])
wrapper = root / 'bin/fm-build-lock.py'
option = subprocess.run([str(wrapper), 'node-option'], capture_output=True, text=True, check=True).stdout.strip()
env = dict(os.environ, FM_BUILD_LOCK_FILE=str(scratch / 'build.lock'))
for name in ('FM_BUILD_LOCK_BYPASS', 'FM_BUILD_LOCK_HELD', 'NODE_OPTIONS'):
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
    one.kill()
    one.wait(10)
    wait_file(scratch / 'two')
    (scratch / 'two.release').touch()
    assert two.wait(10) == 0
    print('ok - concurrent builds wait visibly, bypass works, SIGKILL releases the slot')

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
    for name in ('fm-build-lock.py', 'fm-build-lock.js'):
        shutil.copy2(root / 'bin' / name, checkout / name)
    installed = scratch / 'installed'
    install_env = dict(env, FM_BUILD_LOCK_INSTALL_DIR=str(installed), NODE_OPTIONS='--max-old-space-size=512')
    env_file = scratch / 'node-options.sh'
    for _ in range(2):
        subprocess.run([str(checkout / 'fm-build-lock.py'), 'node-env-file', str(env_file)],
                       env=install_env, check=True, timeout=5)
        install_env['NODE_OPTIONS'] = subprocess.run(
            ['sh', '-c', '. "$1" && printf %s "$NODE_OPTIONS"', '_', str(env_file)],
            env=install_env, capture_output=True, text=True, check=True).stdout
    assert install_env['NODE_OPTIONS'] == f'--max-old-space-size=512 --require={installed}/fm-build-lock.js', \
        install_env['NODE_OPTIONS']
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
for name in ('FM_BUILD_LOCK_BYPASS', 'FM_BUILD_LOCK_HELD', 'NODE_OPTIONS', 'FM_HEAVY_SLOTS'):
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
    running[1].kill()
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
        }
        for name, (rel, head) in entries.items():
            cli = scratch / rel
            cli.parent.mkdir(parents=True, exist_ok=True)
            cli.write_text(head + shared)
            cli.chmod(0o755)
        localbin = scratch / 'node_modules/.bin'
        localbin.mkdir(exist_ok=True)
        for name in ('vitest', 'playwright', 'playwright-package'):
            link = localbin / name if name != 'playwright-package' else localbin / 'package' / 'playwright'
            link.parent.mkdir(exist_ok=True)
            link.symlink_to(scratch / entries[name][0])
            entries[name + '-bin'] = (str(link.relative_to(scratch)), None)
        preload = {'NODE_OPTIONS': option, 'FM_HEAVY_SLOTS': '1'}
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
        ]
        light = [
            ('vitest', ['--version']),
            ('vitest', ['watch']),
            ('vitest', ['--watch']),
            ('playwright', ['install']),
            ('playwright-package', ['install']),
            ('playwright-package', ['test', '--help']),
            ('tsc', ['one-file.ts', '--noEmit']),
            ('tsc', ['--watch', '-p', 'tsconfig.json']),
            ('tsc', ['-w']),
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
            child = subprocess.Popen(command,
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
            result = subprocess.run(['node', str(scratch / entries[name][0]), *args],
                                    env=dict(env, **preload), stdin=subprocess.DEVNULL,
                                    capture_output=True, timeout=30)
            assert result.returncode == 0 and result.stdout.startswith(b'ran:'), result.stderr
            assert b'waiting' not in result.stderr, f'{name} {" ".join(args)} took a heavy slot'
        (scratch / 'block-light.release').touch()
        assert blocker.wait(10) == 0
        print('ok - the preload locks Vitest, Playwright and whole-project tsc and passes the rest through')
    else:
        print('skip - heavy CLI interception needs node installed')
finally:
    for child in children:
        if child.poll() is None:
            child.kill()
        child.wait()
PY
