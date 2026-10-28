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
        if 'waiting for build lock' in (scratch / 'two.err').read_text():
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
    print('ok - concurrent builds wait visibly, bypass works, SIGKILL releases lock')

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
            if 'waiting for build lock' in (scratch / 'direct.err').read_text():
                break
            time.sleep(.03)
        assert 'waiting for build lock' in (scratch / 'direct.err').read_text()
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
            if 'waiting for build lock' in (scratch / 'daemon.err').read_text():
                break
            time.sleep(.03)
        assert 'waiting for build lock' in (scratch / 'daemon.err').read_text()
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
