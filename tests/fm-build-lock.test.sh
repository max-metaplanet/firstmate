#!/usr/bin/env bash
# Real-process build serialization, PATH interception, recursion and crash release.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(mktemp -d "$FM_TEST_SCRATCH_ROOT/fm-build-lock.XXXXXX")
python3 - "$ROOT" "$TMP_ROOT" <<'PY'
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time

root, scratch = map(Path, sys.argv[1:])
shim = root / 'bin/build-shims'
wrapper = root / 'bin/fm-build-lock.py'
env = dict(os.environ, PATH=str(shim) + os.pathsep + os.environ['PATH'],
           FM_BUILD_LOCK_FILE=str(scratch / 'build.lock'))
env.pop('FM_BUILD_LOCK_BYPASS', None)
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
if (process.env.NESTED === '1') {
  const child = require('child_process').spawnSync('node', [__filename, 'build'], {
    env: {PATH: process.env.PATH, FM_BUILD_LOCK_FILE: process.env.FM_BUILD_LOCK_FILE,
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
        package_env = {'PATH': str(localbin) + os.pathsep + env['PATH']}
        first = launch(['next', 'build'], 'package', package_env)
        wait_file(scratch / 'package')
        # Direct next shim -> local CLI -> node shim exec chain must not deadlock.
        second = launch(['next', 'build'], 'direct', {'PATH': env['PATH'] + os.pathsep + str(localbin)})
        for _ in range(300):
            if 'waiting for build lock' in (scratch / 'direct.err').read_text():
                break
            time.sleep(.03)
        assert 'waiting for build lock' in (scratch / 'direct.err').read_text()
        assert not (scratch / 'direct').exists()
        for command in (['next', 'dev'], ['next', 'lint'], ['next', 'build', '--help'],
                        ['node', '-e', 'console.log("test")']):
            result = subprocess.run(command, env=dict(env, **package_env), capture_output=True, timeout=5)
            assert result.returncode == 0, result.stderr
        (scratch / 'package.release').touch()
        assert first.wait(10) == 0
        wait_file(scratch / 'direct')
        (scratch / 'direct.release').touch()
        assert second.wait(10) == 0
        # Node closes extra fds and the child env is scrubbed; ancestor ownership survives.
        (scratch / 'nested.release').touch()
        nested = launch(['node', '--no-warnings', str(cli), 'build'], 'nested', {'NESTED': '1'})
        assert nested.wait(12) == 0, (scratch / 'nested.err').read_text()
        assert (scratch / 'nested').exists()
        print('ok - package PATH shadowing, direct next, non-build passthrough and recursive Node builds')
    else:
        print('skip - Node CLI interception needs node installed')

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
