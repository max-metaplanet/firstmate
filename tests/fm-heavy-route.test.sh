#!/usr/bin/env bash
# Where a worker's heavy command runs: the declaration reader, the Boat-first
# decision, the remote command the adapter is given, and every fallback to a
# local heavy slot. Each case drives bin/fm-heavy-route.py as a process and
# judges it by what the fake Boat CLI was asked to do and by whether the
# command ran inside a heavy slot, never by how the script decided.
set -euo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
CASE_ROOT=$(fm_test_tmproot fm-heavy-route)
export CASE_ROOT
python3 - "$ROOT" <<'PY'
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys

repo = Path(sys.argv[1])
base = Path(os.environ['CASE_ROOT'])
route = str(repo / 'bin/fm-heavy-route.py')
fixture = repo / 'tests/fixtures/boat-cli.py'


def case(name, project='smokeproj', declaration=None):
    """A worktree, a Firstmate home with a fake Boat account, and an install dir."""
    p = base / name
    work = p / project
    work.mkdir(parents=True)
    for args in (('init', '-q'), ('config', 'user.name', 'Fixture'),
                 ('config', 'user.email', 'fixture@example.invalid')):
        subprocess.run(['git', '-C', str(work), *args], check=True, capture_output=True)
    (work / 'tracked.txt').write_text('committed\n')
    (work / 'deep').mkdir()
    (work / 'deep/nested.txt').write_text('nested\n')
    subprocess.run(['git', '-C', str(work), 'add', '-A'], check=True, capture_output=True)
    subprocess.run(['git', '-C', str(work), 'commit', '-qm', 'fixture'], check=True,
                   capture_output=True)
    config = p / 'home/config'
    config.mkdir(parents=True)
    if declaration is not None:
        (config / 'boat-heavy').write_text(declaration)
    state = p / 'home/state/boat-offload'
    (state / 'jobs').mkdir(parents=True)
    (state / 'fixture.json').write_text('{}')
    wrapper = p / 'boat'
    wrapper.write_text('#!/bin/sh\nexec python3 ' + shlex.quote(str(fixture)) + ' ' +
                       shlex.quote(str(state)) + ' "$@"\n')
    wrapper.chmod(0o755)
    user = p / 'user'
    (user / '.config/boat').mkdir(parents=True)
    (user / '.config/boat/api-key').write_text('boat_fixture_secret')
    env = dict(os.environ, HOME=str(user), FM_BOAT_BIN=str(wrapper),
               FM_BUILD_LOCK_INSTALL_DIR=str(p / 'install'),
               FM_BUILD_LOCK_FILE=str(p / 'heavy.lock'), FM_HEAVY_SLOTS='1',
               FM_TASK_ID='fixture-task', DEV_SECRET='host-only')
    for name in ('FM_BUILD_LOCK_BYPASS', 'FM_BUILD_LOCK_HELD', 'FM_HEAVY_ROUTE', 'NODE_OPTIONS'):
        env.pop(name, None)
    return p, work, config, state, env


def publish(config, env, home=None):
    return subprocess.run([route, 'publish', '--home', str(home or config.parent),
                           '--config', str(config)], env=env, capture_output=True, text=True,
                          timeout=30)


# `held=` is set only by fm-build-lock.py, so it says a heavy slot was claimed.
REPORT = 'printf "ran cwd=%s held=%s\\n" "$(pwd)" "${FM_BUILD_LOCK_HELD:-}"'


def run(work, env, kind='tsc', command=('bash', '-c', REPORT), cwd=None, timeout=90):
    return subprocess.run([route, '--kind', kind, '--', *command], env=env,
                          cwd=str(cwd or work), capture_output=True, text=True, timeout=timeout)


def commit_cli(work, body):
    """The local node_modules CLI the preload intercepts, plus the tracked copy
    the remote bootstrap installs from. node_modules never travels, so a routed
    command finds its tool only where the project's own bootstrap puts it."""
    cli = work / 'node_modules/typescript/bin/tsc'
    cli.parent.mkdir(parents=True)
    cli.write_text(body)
    (work / 'tools').mkdir()
    (work / 'tools/tsc.js').write_text(body)
    subprocess.run(['git', '-C', str(work), 'add', 'tools'], check=True, capture_output=True)
    subprocess.run(['git', '-C', str(work), 'commit', '-qm', 'tool'], check=True,
                   capture_output=True)
    return cli


def called(state):
    return (state / 'calls.jsonl').exists()


def remote_script(state):
    """The command string the adapter handed the VM, past its own bootstrap."""
    for line in (state / 'calls.jsonl').read_text().splitlines():
        call = json.loads(line)
        if call[0] == 'exec' and 'source.tar.gz' not in call[-1]:
            return call[-1]
    raise AssertionError('the fake Boat CLI was never asked to run the command')


DECLARED = "smokeproj bootstrap='echo bootstrapped' timeout=900\n"
INSTALLS = ("smokeproj bootstrap='mkdir -p node_modules/typescript/bin && "
            "cp tools/tsc.js node_modules/typescript/bin/tsc' timeout=900\n")

p, work, config, state, env = case('undeclared')
assert publish(config, env).returncode == 0
r = run(work, env)
assert r.returncode == 0, r.stderr
assert 'held=' in r.stdout and not r.stdout.endswith('held=\n'), r.stdout
assert not called(state)
assert 'heavy-route' not in r.stderr, r.stderr
print('ok - an undeclared project keeps the local heavy slot and says nothing new')

for name, overrides, kind in (
    ('no-task-marker', {'FM_TASK_ID': None}, 'tsc'),
    ('forced-local', {'FM_HEAVY_ROUTE': 'local'}, 'tsc'),
    ('local-only-kind', {}, 'queue-preflight'),
    ('local-only-browser', {}, 'playwright'),
):
    p, work, config, state, env = case(name, declaration=DECLARED)
    assert publish(config, env).returncode == 0
    for key, value in overrides.items():
        if value is None:
            env.pop(key, None)
        else:
            env[key] = value
    r = run(work, env, kind=kind)
    assert r.returncode == 0, (name, r.stderr)
    assert not r.stdout.endswith('held=\n'), (name, r.stdout)
    assert not called(state), name
print('ok - no worker marker, a forced local run, and a credential-needing kind stay in a slot')

p, work, config, state, env = case('routed', declaration=DECLARED)
assert publish(config, env).returncode == 0
r = run(work, env)
assert r.returncode == 0, r.stderr
assert called(state)
assert r.stdout.endswith('held=\n'), ('a routed command must not hold a local slot', r.stdout)
assert 'tsc on Boat' in r.stderr, r.stderr
assert 'bootstrapped' in r.stdout, r.stdout
assert 'boat_fixture_secret' not in r.stdout + r.stderr
print('ok - a declared project runs the kind on Boat, outside the local slots')

p, work, config, state, env = case('remote-shape', declaration=DECLARED)
assert publish(config, env).returncode == 0
r = run(work / 'deep', env, command=('bash', '-c', 'true'))
assert r.returncode == 0, r.stderr
assert '\ncd deep\n' in remote_script(state), remote_script(state)

p, work, config, state, env = case('remote-argv', declaration=DECLARED)
assert publish(config, env).returncode == 0
preload = Path(env['FM_BUILD_LOCK_INSTALL_DIR']) / 'fm-build-lock.js'
r = run(work, env, command=(
    sys.executable, '--require=' + str(preload), '--keep-me',
    str(work / 'node_modules/tool/bin/cli.js'), '-p', str(work / 'tsconfig.json'),
    '--outDir=' + str(work / 'out'), 'tracked.txt'))
script = remote_script(state)
assert '\nexec ' + Path(sys.executable).name + ' --keep-me ' in script, script
assert 'fm-build-lock.js' not in script, script
assert '/home/user/fm-job/source/node_modules/tool/bin/cli.js' in script, script
assert '--outDir=/home/user/fm-job/source/out' in script, script
assert ' tracked.txt' in script, script
assert str(work) not in script, script
assert 'echo bootstrapped' in script, script
print('ok - the remote command keeps the cwd and the real flags, drops the preload, '
      'and rewrites worktree paths')

p, work, config, state, env = case('remote-exit', declaration=DECLARED)
assert publish(config, env).returncode == 0
r = run(work, env, command=('bash', '-c', 'exit 3'))
assert r.returncode == 3, (r.returncode, r.stderr)
assert called(state)
print('ok - a completed remote run is the verdict and its exit is the exit')

p, work, config, state, env = case('budget-spent', declaration=DECLARED)
(state / 'fixture.json').write_text(json.dumps({'remaining': 0}))
assert publish(config, env).returncode == 0
r = run(work, env)
assert r.returncode == 0, r.stderr
assert not r.stdout.endswith('held=\n'), r.stdout
assert 'running locally in a heavy slot' in r.stderr, r.stderr
print('ok - a Boat account with nothing left falls back to a local heavy slot, and says so')

p, work, config, state, env = case('copy-gone', declaration=DECLARED)
assert publish(config, env).returncode == 0
record = Path(env['FM_BUILD_LOCK_INSTALL_DIR']) / 'boat-route'
loaded = json.loads(record.read_text())
loaded['bin'] = str(p / 'removed-checkout/bin')
record.write_text(json.dumps(loaded))
r = run(work, env)
assert r.returncode == 0, r.stderr
assert not r.stdout.endswith('held=\n'), r.stdout
assert 'the recorded Firstmate copy is gone' in r.stderr, r.stderr
assert not called(state)
print('ok - a routing record naming a Firstmate copy that is gone runs the command locally')

p, work, config, state, env = case('bad-kind', declaration=DECLARED)
assert publish(config, env).returncode == 0
r = run(work, env, kind='not-a-kind')
assert r.returncode == 2 and 'unknown heavy kind' in r.stderr, (r.returncode, r.stderr)
assert not called(state)
r = subprocess.run([route], env=env, capture_output=True, text=True, timeout=30)
assert r.returncode == 2 and 'fm-heavy-route.py --kind' in r.stderr, r.stderr
print('ok - an unknown kind and a malformed invocation refuse instead of running anything')

p, work, config, state, env = case('no-file')
assert publish(config, env).returncode == 0
assert json.loads((Path(env['FM_BUILD_LOCK_INSTALL_DIR']) / 'boat-route').read_text())[
    'projects'] == {}
print('ok - no declaration publishes an empty record rather than refusing')

p, work, config, state, env = case('declaration-shapes')
good = ("# a comment\n"
        "#\n"
        "\n"
        "smokeproj bootstrap='pnpm install --frozen-lockfile' type=large timeout=1500 "
        "local-only=eslint,vitest\n"
        "other bootstrap=make local-only=\n")
(config / 'boat-heavy').write_text(good)
assert publish(config, env).returncode == 0
projects = json.loads((Path(env['FM_BUILD_LOCK_INSTALL_DIR']) / 'boat-route').read_text())['projects']
assert projects['smokeproj'] == {'bootstrap': 'pnpm install --frozen-lockfile', 'type': 'large',
                                 'timeout': '1500', 'local_only': ['eslint', 'vitest']}, projects
assert projects['other'] == {'bootstrap': 'make', 'type': None, 'timeout': None,
                             'local_only': []}, projects
print('ok - comments, quoted values, an explicit empty local-only and a bare value all read')

for name, text, expected in (
    ('no-bootstrap', 'smokeproj type=large\n', 'with no bootstrap'),
    ('empty-bootstrap', "smokeproj bootstrap=''\n", 'empty bootstrap'),
    ('unknown-key', 'smokeproj bootstrap=make mystery=1\n', 'has no <key>=<value>'),
    ('bare-field', 'smokeproj bootstrap=make large\n', 'has no <key>=<value>'),
    ('repeated-key', 'smokeproj bootstrap=make bootstrap=other\n', 'repeats bootstrap'),
    ('unknown-kind', 'smokeproj bootstrap=make local-only=typecheck\n', 'unknown heavy kind'),
    ('twice', 'smokeproj bootstrap=make\nsmokeproj bootstrap=other\n', 'a second time'),
    ('empty-type', 'smokeproj bootstrap=make type=\n', 'empty type'),
    ('unclosed-quote', "smokeproj bootstrap='make\n", 'shell word list'),
):
    p, work, config, state, env = case('refuse-' + name, declaration=text)
    r = publish(config, env)
    assert r.returncode == 2, (name, r.returncode, r.stderr)
    assert expected in r.stderr, (name, r.stderr)
    assert not (Path(env['FM_BUILD_LOCK_INSTALL_DIR']) / 'boat-route').exists(), name
print('ok - every malformed declaration refuses publication and writes no record')

p, work, config, state, env = case('relative-home', declaration=DECLARED)
r = publish(config, env, home=Path('home'))
assert r.returncode == 2 and 'absolute path' in r.stderr, r.stderr
r = subprocess.run([route, 'publish', '--home', str(config.parent)], env=env,
                   capture_output=True, text=True, timeout=30)
assert r.returncode == 2 and '--home DIR --config DIR' in r.stderr, r.stderr
print('ok - publication needs both absolute directories')

# The preload is the only caller in production, so the one integration case
# drives a real Node heavy command the whole way to the fake Boat CLI.
node = subprocess.run(['sh', '-c', 'command -v node'], capture_output=True, text=True).stdout.strip()
if not node:
    print('skip - the preload integration case needs node installed')
else:
    p, work, config, state, env = case('preload', declaration=INSTALLS)
    cli = commit_cli(work, "console.log('ran tsc held=' + "
                     "(process.env.FM_BUILD_LOCK_HELD || ''));\n")
    option = subprocess.run([str(repo / 'bin/fm-build-lock.py'), 'node-option'], env=env,
                            capture_output=True, text=True, check=True).stdout.strip()
    assert publish(config, env).returncode == 0
    routed = dict(env, NODE_OPTIONS=option)
    r = subprocess.run([node, str(cli), '--noEmit'], env=routed, cwd=str(work),
                       capture_output=True, text=True, timeout=120)
    assert r.returncode == 0, (r.stdout, r.stderr)
    assert called(state), r.stderr
    assert 'ran tsc held=\n' in r.stdout, r.stdout
    assert 'tsc on Boat' in r.stderr, r.stderr
    p, work, config, state, env = case('preload-bypass', declaration=DECLARED)
    cli = commit_cli(work, "console.log('ran tsc');\n")
    assert publish(config, env).returncode == 0
    r = subprocess.run([node, str(cli), '--noEmit'],
                       env=dict(env, NODE_OPTIONS=option, FM_BUILD_LOCK_BYPASS='1'),
                       cwd=str(work), capture_output=True, text=True, timeout=60)
    assert r.returncode == 0 and 'ran tsc' in r.stdout, (r.stdout, r.stderr)
    assert not called(state), 'the single-command bypass must skip routing too'
    print('ok - the preload routes a real heavy Node command to Boat, and the bypass skips both')
PY
