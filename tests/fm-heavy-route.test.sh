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
    (work / '.gitignore').write_text('node_modules/\n')
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
    for name in ('FM_BUILD_LOCK_BYPASS', 'FM_BUILD_LOCK_HELD', 'NODE_OPTIONS', 'CI'):
        env.pop(name, None)
    for name in tuple(env):
        if name.startswith(('TURBO_', 'NX_', 'LERNA_')):
            env.pop(name)
    return p, work, config, state, env


def publish(config, env, home=None):
    return subprocess.run([route, 'publish', '--home', str(home or config.parent),
                           '--config', str(config)], env=env, capture_output=True, text=True,
                          timeout=30)


# `held=` is set only by fm-build-lock.py, so it says a heavy slot was claimed.
REPORT = 'printf "ran cwd=%s held=%s\\n" "$(pwd)" "${FM_BUILD_LOCK_HELD:-}"'


fixture_index = 0


def executable_command(work, command):
    global fixture_index
    if len(command) < 3 or command[1] != '-c' or command[0] not in ('bash', sys.executable):
        return command
    root = Path(subprocess.run(['git', '-C', str(work), 'rev-parse', '--show-toplevel'],
                check=True, capture_output=True, text=True).stdout.strip())
    fixture_index += 1
    script = root / ('routing-fixture-%d' % fixture_index)
    interpreter = 'bash' if command[0] == 'bash' else 'python3'
    script.write_text('#!/usr/bin/env ' + interpreter + '\n' + command[2] + '\n')
    script.chmod(0o755)
    subprocess.run(['git', '-C', str(root), 'add', script.name], check=True, capture_output=True)
    subprocess.run(['git', '-C', str(root), 'commit', '--only', '-qm', 'executable fixture',
                    '--', script.name], check=True, capture_output=True)
    args = command[4:] if interpreter == 'bash' else command[3:]
    return (str(script), *args)


def run(work, env, kind='vitest', command=('bash', '-c', REPORT), cwd=None, timeout=90,
        input=None):
    command = executable_command(work, command)
    return subprocess.run([route, '--kind', kind, '--', *command], env=env,
                          cwd=str(cwd or work), capture_output=True, text=True, timeout=timeout,
                          input=input)


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
print('ok - no worker marker and a credential-needing kind stay in a slot')

p, work, config, state, env = case('routed', declaration=DECLARED)
assert publish(config, env).returncode == 0
r = run(work, env)
assert r.returncode == 0, r.stderr
assert called(state)
assert r.stdout.endswith('held=\n'), ('a routed command must not hold a local slot', r.stdout)
assert 'vitest on Boat' in r.stderr, r.stderr
assert 'bootstrapped' not in r.stdout, r.stdout
assert 'bootstrapped' in r.stderr, r.stderr
assert 'boat_fixture_secret' not in r.stdout + r.stderr
print('ok - a declared project runs the kind on Boat, outside the local slots')

for name, payload, exit_code, bootstrap in (
    ('json', '[{"filePath":"tracked.txt","messages":[]}]', 0, 'true'),
    ('failed', '[{"filePath":"tracked.txt","errorCount":1}]', 1, 'true'),
    ('empty', '', 0, 'true'), ('bytes', 'a\n\nb\tend', 0, 'true'),
    ('fallback-json', '[{"filePath":"tracked.txt","messages":[]}]', 0, 'false'),
):
    p, work, config, state, env = case('stdout-' + name,
        declaration='smokeproj bootstrap=' + shlex.quote(
            'echo installation progress; echo setup diagnostic >&2; ' + bootstrap) + '\n')
    (work / 'eslint.py').write_text(
        'import sys\nassert sys.argv[1:] == [".", "--format", "json"]\n'
        'sys.stderr.write("command diagnostic\\n")\n'
        'sys.stdout.write(%r)\nsys.exit(%d)\n' % (payload, exit_code))
    subprocess.run(['git', '-C', str(work), 'add', 'eslint.py'], check=True, capture_output=True)
    subprocess.run(['git', '-C', str(work), 'commit', '-qm', 'eslint fixture'],
                   check=True, capture_output=True)
    assert publish(config, env).returncode == 0
    r = run(work, env, kind='eslint',
            command=(sys.executable, str(work / 'eslint.py'), '.', '--format', 'json'))
    assert called(state) and r.returncode == exit_code, (name, r.stderr)
    assert r.stdout == payload, (name, r.stdout)
    assert 'installation progress' in r.stderr and 'setup diagnostic' in r.stderr, r.stderr
    assert 'command diagnostic' in r.stderr, r.stderr
    assert 'fm-heavy-command-' not in r.stdout + r.stderr, (r.stdout, r.stderr)
    assert ('running locally' in r.stderr) == (bootstrap == 'false'), r.stderr
    if 'json' in name or name == 'failed':
        assert json.loads(r.stdout)[0]['filePath'] == 'tracked.txt', r.stdout
print('ok - routed ESLint JSON and other output retain their exact bytes without protocol markers')

p, work, config, state, env = case('staged-new', declaration=DECLARED)
assert publish(config, env).returncode == 0
(work / 'deep/staged.txt').write_text('staged content\n')
subprocess.run(['git', '-C', str(work), 'add', 'deep/staged.txt'], check=True,
               capture_output=True)
(work / 'tracked.txt').write_text('edited content\n')
r = run(work, env, command=('cat', 'deep/staged.txt', 'tracked.txt'))
assert r.returncode == 0, r.stderr
assert called(state)
assert 'staged content\nedited content\n' in r.stdout, r.stdout
print('ok - a routed run sees newly staged and edited files, not only HEAD')

p, work, config, state, env = case('untracked-new', declaration=DECLARED)
assert publish(config, env).returncode == 0
(work / 'deep/scratch.csv').write_text('not for upload\n')
r = run(work, env)
assert r.returncode == 0, r.stderr
assert not called(state)
assert not r.stdout.endswith('held=\n'), r.stdout
assert 'untracked file deep/scratch.csv' in r.stderr, r.stderr
print('ok - an untracked file keeps the run local and the notice names it')

for name, kind, args in (
    ('next-build', 'next-build', ()),
    ('vitest-update', 'vitest', ('run', '-u')),
    ('vitest-coverage', 'vitest', ('run', '--coverage')),
    ('eslint-fix', 'eslint', ('.', '--fix')),
    ('eslint-fix-equals', 'eslint', ('.', '--fix=true')),
    ('eslint-fix-value', 'eslint', ('.', '--fix', 'true')),
    ('eslint-no-fix-equals', 'eslint', ('.', '--no-fix=false')),
    ('eslint-no-fix-value', 'eslint', ('.', '--no-fix', 'false')),
    ('eslint-output', 'eslint', ('.', '--output-file', 'lint.txt')),
    ('eslint-output-equals', 'eslint', ('.', '--output-file=lint.txt')),
    ('eslint-output-short', 'eslint', ('.', '-o', 'lint.txt')),
    ('eslint-output-short-equals', 'eslint', ('.', '-o=lint.txt')),
    ('eslint-cache', 'eslint', ('.', '--cache')),
    ('eslint-cache-equals', 'eslint', ('.', '--cache=true')),
    ('eslint-cache-value', 'eslint', ('.', '--cache', 'true')),
    ('eslint-cache-negated', 'eslint', ('.', '--no-cache=false')),
    ('eslint-cache-file', 'eslint', ('.', '--cache', '--cache-file', 'lint.cache')),
    ('eslint-cache-file-equals', 'eslint', ('.', '--cache', '--cache-file=lint.cache')),
    ('eslint-cache-location', 'eslint', ('.', '--cache', '--cache-location', 'cache')),
    ('eslint-cache-location-equals', 'eslint', ('.', '--cache', '--cache-location=cache')),
    ('eslint-suppress-all', 'eslint', ('.', '--suppress-all')),
    ('eslint-suppress-all-equals', 'eslint', ('.', '--suppress-all=true')),
    ('eslint-suppress-all-value', 'eslint', ('.', '--suppress-all', 'true')),
    ('eslint-suppress-rule', 'eslint', ('.', '--suppress-rule', 'no-unused-vars')),
    ('eslint-suppress-rule-equals', 'eslint', ('.', '--suppress-rule=no-unused-vars')),
    ('eslint-prune', 'eslint', ('.', '--prune-suppressions')),
    ('eslint-prune-equals', 'eslint', ('.', '--prune-suppressions=true')),
    ('eslint-prune-value', 'eslint', ('.', '--prune-suppressions', 'true')),
    ('eslint-suppressions-location', 'eslint', ('.', '--suppressions-location', 's.json')),
    ('eslint-suppressions-location-equals', 'eslint', ('.', '--suppressions-location=s.json')),
    ('eslint-stdin-filename', 'eslint', ('.', '--stdin-filename', 'file.js')),
):
    p, work, config, state, env = case('writes-' + name, declaration=DECLARED)
    assert publish(config, env).returncode == 0
    r = run(work, env, kind=kind, command=('bash', '-c', REPORT, 'tool', *args))
    assert r.returncode == 0, (name, r.stderr)
    assert not r.stdout.endswith('held=\n'), (name, r.stdout)
    assert not called(state), name
    assert 'would not bring back' in r.stderr, (name, r.stderr)
print('ok - a command whose outputs would stay on Boat runs locally')

for index, args in enumerate((('--fix=false',), ('--fix', 'false'),
                              ('--no-fix',), ('--no-fix=true',),
                              ('--no-fix', 'true'), ('--cache=false',),
                              ('--cache', 'false'), ('--no-cache',),
                              ('--suppress-all=false',), ('--suppress-all', 'false'),
                              ('--prune-suppressions=false',),
                              ('--prune-suppressions', 'false'),
                              ('--stdin=false',), ('--stdin', 'false'),
                              ('--no-stdin',), ('--no-stdin=true',))):
    p, work, config, state, env = case('eslint-readonly-' + str(index), declaration=DECLARED)
    assert publish(config, env).returncode == 0
    r = run(work, env, kind='eslint', command=('bash', '-c', REPORT, 'eslint', '.', *args))
    assert r.returncode == 0 and called(state), (args, r.stdout, r.stderr)
    assert r.stdout.endswith('held=\n'), (args, r.stdout)
print('ok - explicitly disabled ESLint fixes still permit a remote verdict')

for index, args in enumerate((('--stdin',), ('--stdin=true',), ('--stdin', 'true'),
                              ('--no-stdin=false',), ('--no-stdin', 'false'))):
    p, work, config, state, env = case('eslint-stdin-' + str(index), declaration=DECLARED)
    assert publish(config, env).returncode == 0
    reader = ('import json, os, sys; source = sys.stdin.read(); '
              'print(json.dumps({"source": source, "held": bool(os.environ.get('
              '"FM_BUILD_LOCK_HELD"))})); sys.exit(2 if source else 0)')
    r = run(work, env, kind='eslint', command=(sys.executable, '-c', reader, *args),
            input='let =\n')
    assert r.returncode == 2, (args, r.stdout, r.stderr)
    assert json.loads(r.stdout) == {'source': 'let =\n', 'held': True}, r.stdout
    assert not called(state), args
print('ok - enabled stdin options preserve piped source and its local failure verdict')

for kind in ('eslint', 'tsc', 'vitest', 'playwright', 'queue-preflight'):
    for index, args in enumerate((('--unrecognized-routing-option',),
                                  ('--unrecognized-routing-option=true',),
                                  ('--fix=perhaps',), ('--format',), ('--format=',),
                                  ('-',), ('--', '--stdin'))):
        p, work, config, state, env = case('unknown-' + kind + '-' + str(index),
            declaration="smokeproj bootstrap=true local-only=\n")
        assert publish(config, env).returncode == 0
        r = run(work, env, kind=kind, command=('bash', '-c', REPORT, 'tool', *args))
        assert r.returncode == 0 and not called(state), (kind, args, r.stderr)
        assert not r.stdout.endswith('held=\n'), (kind, args, r.stdout)
print('ok - unknown, malformed and ambiguous options stay local for every routed kind')

for index, args in enumerate((('init',), ('watch',), ('--reporter', 'html'),
                              ('--reporter', './custom-reporter.js'))):
    p, work, config, state, env = case('vitest-ambiguous-' + str(index), declaration=DECLARED)
    assert publish(config, env).returncode == 0
    r = run(work, env, command=('bash', '-c', REPORT, 'vitest', *args))
    assert r.returncode == 0 and not called(state), (args, r.stderr)
    assert not r.stdout.endswith('held=\n'), (args, r.stdout)
print('ok - ambiguous Vitest subcommands and file-writing or custom reporters stay local')

p, work, config, state, env = case('opaque-shell', declaration=DECLARED)
assert publish(config, env).returncode == 0
r = subprocess.run([route, '--kind', 'vitest', '--', 'bash', '-c', REPORT],
                   env=env, cwd=str(work), capture_output=True, text=True, timeout=60)
assert r.returncode == 0 and not called(state), r.stderr
assert not r.stdout.endswith('held=\n'), r.stdout
print('ok - an opaque shell command stays local rather than hiding options from the allowlist')

# A stand-in tsc: --showConfig prints the resolved configuration tsc would, with
# noEmit taken from NOEMIT; any other run reports where it ran.
FAKE_TSC = ('if [ "${@: -1}" = --showConfig ]; then '
            'printf "{\\"compilerOptions\\":{\\"noEmit\\":%s}}" "$NOEMIT"; exit 0; fi; ' + REPORT)
for name, noemit, args, routed in (
    ('config-noemit', 'true', (), True),
    ('config-emits', 'false', (), False),
    ('build', 'true', ('-b',), False),
    ('build-long', 'true', ('--build',), False),
    ('unparsable-config', 'broken', (), False),
):
    p, work, config, state, env = case('tsc-' + name, declaration=DECLARED)
    assert publish(config, env).returncode == 0
    r = run(work, dict(env, NOEMIT=noemit), kind='tsc',
            command=('bash', '-c', FAKE_TSC, 'tsc', *args))
    assert r.returncode == 0, (name, r.stderr)
    assert called(state) == routed, (name, r.stderr)
    assert r.stdout.endswith('held=\n') == routed, (name, r.stdout)
print('ok - tsc goes to Boat only when its resolved configuration proves noEmit')

TSC_OUTPUTS = '''import json, os, sys
from pathlib import Path
options = json.loads(Path('tsconfig.json').read_text())['compilerOptions']
args = sys.argv[1:]
for name in ('noEmit', 'incremental', 'composite'):
    flag = '--' + name
    if flag in args:
        index = args.index(flag) + 1
        value = args[index] if index < len(args) else 'true'
        options[name] = value != 'false'
if '--showConfig' in args:
    print(json.dumps({'compilerOptions': options}))
else:
    if options.get('incremental') or options.get('composite'):
        Path(options.get('tsBuildInfoFile', 'cache.tsbuildinfo')).write_text('build info\\n')
    print('ran held=' + os.environ.get('FM_BUILD_LOCK_HELD', ''))
'''
for name, settings, args, routed in (
    ('incremental-config', {'incremental': True}, (), True),
    ('named-config', {'incremental': True, 'tsBuildInfoFile': 'cache.tsbuildinfo'}, (), False),
    ('named-without-incremental', {'tsBuildInfoFile': 'cache.tsbuildinfo'}, (), False),
    ('named-cli', {'incremental': True}, ('--tsBuildInfoFile', 'cache.tsbuildinfo'), False),
    ('named-cli-equals', {'incremental': True}, ('--tsBuildInfoFile=cache.tsbuildinfo',), False),
    ('emit-enabled', {'noEmit': False}, (), False),
    ('emit-unspecified', {'noEmit': None}, (), False),
    ('composite-config', {'composite': True}, (), False),
    ('composite-without-incremental', {'composite': True, 'incremental': False}, (), False),
    ('incremental-cli', {}, ('--incremental',), False),
    ('incremental-cli-value', {}, ('--incremental', 'true'), False),
    ('composite-cli', {}, ('--composite', 'true'), False),
    ('incremental-disabled', {'incremental': True}, ('--incremental', 'false'), True),
    ('composite-disabled', {'composite': True}, ('--composite', 'false'), True),
    ('both-disabled', {'incremental': False, 'composite': False}, (), True),
):
    p, work, config, state, env = case('tsc-output-' + name, declaration=DECLARED)
    (work / 'tsc.py').write_text(TSC_OUTPUTS)
    compiler_options = {key: value for key, value in {'noEmit': True, **settings}.items()
                        if value is not None}
    (work / 'tsconfig.json').write_text(json.dumps({'compilerOptions': compiler_options}))
    subprocess.run(['git', '-C', str(work), 'add', 'tsc.py', 'tsconfig.json'],
                   check=True, capture_output=True)
    subprocess.run(['git', '-C', str(work), 'commit', '-qm', 'tsc fixture'],
                   check=True, capture_output=True)
    assert publish(config, env).returncode == 0
    r = run(work, env, kind='tsc', command=(sys.executable, str(work / 'tsc.py'), *args))
    assert r.returncode == 0 and called(state) == routed, (name, r.stdout, r.stderr)
    if routed:
        assert not (work / 'cache.tsbuildinfo').exists(), name
        assert r.stdout == 'ran held=\n', (name, r.stdout)
    else:
        if settings.get('incremental') or settings.get('composite') or '--incremental' in args:
            if 'false' not in args:
                assert (work / 'cache.tsbuildinfo').read_text() == 'build info\n', name
        assert not r.stdout.endswith('held=\n'), (name, r.stdout)
    notice = 'heavy-route: the incremental cache is not preserved for this run\n'
    assert r.stderr.count(notice) == int(name == 'incremental-config'), (name, r.stderr)
    assert 'incremental cache' not in r.stdout, (name, r.stdout)
print('ok - tsc routes implicit incremental caches but preserves named outputs locally')

for flag in ('--generateTrace', '--generateCpuProfile', '--tsBuildInfoFile'):
    for spelling in ('separate', 'equals'):
        p, work, config, state, env = case(flag[2:] + '-' + spelling, declaration=DECLARED)
        assert publish(config, env).returncode == 0
        probe = p / 'probe'
        diagnostic = ('if [ "${@: -1}" = --showConfig ]; then touch "$PROBE"; '
                      'echo \'{"compilerOptions":{"noEmit":true}}\'; exit 0; fi; ' + REPORT)
        args = (flag, 'diagnostic') if spelling == 'separate' else (flag + '=diagnostic',)
        r = run(work, dict(env, PROBE=str(probe)), kind='tsc',
                command=('bash', '-c', diagnostic, 'tsc', '--noEmit', *args))
        assert r.returncode == 0 and not called(state), (flag, spelling, r.stderr)
        assert not r.stdout.endswith('held=\n'), r.stdout
        assert not probe.exists(), 'diagnostic outputs must be detected before probing tsc'
print('ok - tsc trace, CPU profile and named build-info options stay local without probes')

p, work, config, state, env = case('vitest-snapshot', declaration=DECLARED)
assert publish(config, env).returncode == 0
snapshot = ('if [ -n "${CI:-}" ]; then echo "Snapshot \\`adds 1\\` mismatched"; exit 1; fi; ' +
            'test -n "${FM_BUILD_LOCK_HELD:-}" && printf "local retry\\n"')
r = run(work, env, command=('bash', '-c', snapshot))
assert r.returncode == 0, (r.returncode, r.stderr)
assert called(state)
assert r.stdout == 'local retry\n', r.stdout
assert 'snapshot it may not write under CI' in r.stderr, r.stderr
print('ok - a remote vitest snapshot failure under CI is no verdict and reruns locally')

p, work, config, state, env = case('vitest-snapshot-json', declaration=DECLARED)
assert publish(config, env).returncode == 0
snapshot = ('if [ -n "${CI:-}" ]; then ' +
            shlex.join(['printf', '%s', '{"attempt":"remote"}']) +
            '; echo "Snapshot missing" >&2; exit 1; fi; '
            'test -n "${FM_BUILD_LOCK_HELD:-}" && ' +
            shlex.join(['printf', '%s', '{"attempt":"local"}']))
r = run(work, env, command=('bash', '-c', snapshot))
assert r.returncode == 0 and called(state), (r.returncode, r.stderr)
assert r.stdout == '{"attempt":"local"}', r.stdout
assert json.loads(r.stdout) == {'attempt': 'local'}, r.stdout
assert 'Snapshot missing' in r.stderr and 'discarded remote stdout' in r.stderr, r.stderr
print('ok - snapshot fallback discards the remote JSON report and returns one local document')

for name, result_kind, remote_exit in (('result', 'execution-unknown', None),
                                       ('dispatch', 'completed', 0)):
    p, work, config, state, env = case('unconfirmed-' + name, declaration=DECLARED)
    assert publish(config, env).returncode == 0
    adapter_bin = p / 'adapter-bin'
    adapter_bin.mkdir()
    adapter = adapter_bin / 'fm-boat-run.sh'
    adapter.write_text('#!/usr/bin/env python3\n'
        'import json, sys\nfrom pathlib import Path\n'
        'output = Path(sys.argv[sys.argv.index("--output") + 1])\n'
        'output.mkdir(parents=True)\n'
        '(output / "result.json").write_text(json.dumps(%r))\n'
        '(output / "command.log").write_text(\'unconfirmed attempt\\n\')\n'
        'sys.stdout.write(\'{"attempt":"remote"}\')\n' % {
            'kind': result_kind, 'remote_exit': remote_exit, 'cleanup': 'deleted'})
    adapter.chmod(0o755)
    routing_record = Path(env['FM_BUILD_LOCK_INSTALL_DIR']) / 'boat-route'
    loaded = json.loads(routing_record.read_text())
    loaded['bin'] = str(adapter_bin)
    routing_record.write_text(json.dumps(loaded))
    r = run(work, env, command=('bash', '-c',
        'test -n "${FM_BUILD_LOCK_HELD:-}" && ' +
        shlex.join(['printf', '%s', '{"attempt":"local"}'])))
    assert r.returncode == 0, (name, r.stderr)
    assert r.stdout == '{"attempt":"local"}', (name, r.stdout)
    assert json.loads(r.stdout) == {'attempt': 'local'}, (name, r.stdout)
    assert 'discarded remote stdout' in r.stderr, (name, r.stderr)
print('ok - unconfirmed result and dispatch both discard remote stdout before local retry')

ORCHESTRATOR = '#!/usr/bin/env bash\nwhile [ "$1" != -- ]; do shift; done\nshift\n"$@"\nexit $?\n'
for name, tool, flags, routed in (
    ('turbo', 'turbo', ('run', 'type-check'), False),
    ('pnpm-filter', 'pnpm', ('--filter', 'app', 'exec'), False),
    ('pnpm-recursive', 'pnpm', ('-r', 'exec'), False),
    ('pnpm-single', 'pnpm', ('exec',), True),
):
    p, work, config, state, env = case('orchestrated-' + name, declaration=DECLARED)
    assert publish(config, env).returncode == 0
    fake = p / 'tools' / tool
    fake.parent.mkdir()
    fake.write_text(ORCHESTRATOR)
    fake.chmod(0o755)
    heavy_command = executable_command(work, ('bash', '-c', REPORT))
    r = subprocess.run([str(fake), *flags, '--', route, '--kind', 'vitest', '--',
                        *heavy_command], env=env, cwd=str(work), capture_output=True, text=True,
                       timeout=90)
    assert r.returncode == 0, (name, r.stderr)
    assert called(state) == routed, (name, r.stderr)
    assert r.stdout.endswith('held=\n') == routed, (name, r.stdout)
    if not routed:
        assert 'runs under ' + tool in r.stderr, (name, r.stderr)
print('ok - a heavy command under turbo or a fanned-out pnpm keeps a local slot')


def orchestrator_case(name, tool='turbo', declaration=None, cache=False, script='tsc --noEmit'):
    install = ('mkdir -p node_modules/{turbo/bin,nx/bin,lerna/dist,pnpm/bin,typescript/bin,.bin}; '
               'cp tools/orchestrator.cjs node_modules/turbo/bin/turbo; '
               'cp tools/orchestrator.cjs node_modules/nx/bin/nx.js; '
               'cp tools/orchestrator.cjs node_modules/lerna/dist/cli.js; '
               'cp tools/orchestrator.cjs node_modules/pnpm/bin/pnpm.cjs; '
               'cp tools/tsc node_modules/typescript/bin/tsc; '
               'ln -s ../typescript/bin/tsc node_modules/.bin/tsc; '
               'ln -s ../pnpm/bin/pnpm.cjs node_modules/.bin/pnpm; '
               'ln -s ../nx/bin/nx.js node_modules/.bin/nx; '
               'ln -s ../lerna/dist/cli.js node_modules/.bin/lerna; '
               'ln -s ../turbo/bin/turbo node_modules/.bin/turbo')
    declared = 'smokeproj bootstrap=' + shlex.quote(install) + '\n'
    p, work, config, state, env = case(name, declaration=declaration or declared)
    (work / 'tools').mkdir()
    child = r"""#!/usr/bin/env node
const fs = require('fs');
if (process.argv.includes('--showConfig')) {
  console.log(fs.readFileSync('tsconfig.json', 'utf8')); process.exit(0);
}
console.log('child marker=' + (process.env.FM_HEAVY_ORCHESTRATOR || '') +
  ' held=' + (process.env.FM_BUILD_LOCK_HELD || ''));
"""
    parent = r"""#!/usr/bin/env node
const fs = require('fs');
const path = require('path');
const cp = require('child_process');
const dirs = ['packages/a', 'packages/b'];
if (process.env.FM_ORCHESTRATOR_PROBE_LOG &&
    (process.argv.includes('--dry=json') || process.argv.includes('list') || process.argv[2] === 'config')) {
  fs.appendFileSync(process.env.FM_ORCHESTRATOR_PROBE_LOG, 'probed\n');
}
function setting(key) {
  let value = 'undefined';
  for (const file of [process.env.npm_config_globalconfig,
    path.join(process.env.HOME || '', '.npmrc'), '.npmrc']) {
    if (!file || !fs.existsSync(file)) continue;
    for (const line of fs.readFileSync(file, 'utf8').split('\n')) {
      const at = line.indexOf('=');
      if (at >= 0 && line.slice(0, at).trim() === key) value = line.slice(at + 1).trim();
    }
  }
  if (key === 'report-summary' && fs.existsSync('pnpm-workspace.yaml')) {
    for (const line of fs.readFileSync('pnpm-workspace.yaml', 'utf8').split('\n')) {
      if (line.startsWith('reportSummary:')) value = line.slice('reportSummary:'.length).trim();
    }
  }
  if (key === 'tasks' && fs.existsSync('pnpm-workspace.yaml') &&
      fs.readFileSync('pnpm-workspace.yaml', 'utf8').split('\n').some((line) => line.startsWith('tasks:'))) {
    value = 'configured';
  }
  const envKey = 'npm_config_' + key.replaceAll('-', '_');
  for (const [name, configured] of Object.entries(process.env)) {
    if (name.toLowerCase() === envKey) value = configured;
  }
  return value;
}
if (process.argv[2] === 'config') {
  if (process.argv[3] !== 'get' || !process.argv[4]) process.exit(42);
  const key = process.argv[4];
  const probes = fs.existsSync('tools/config-probe.json')
    ? JSON.parse(fs.readFileSync('tools/config-probe.json')) : {};
  const probe = probes[key];
  if (probe) {
    process.stdout.write(probe.stdout);
    process.exit(probe.exit || 0);
  }
  console.log(setting(key));
} else if (process.argv.includes('--dry=json')) {
  const definition = JSON.parse(fs.readFileSync(process.env.TURBO_ROOT_TURBO_JSON || 'turbo.json', 'utf8')).tasks['type-check'];
  const tasks = dirs.map((directory) => ({directory, task: 'type-check',
    command: JSON.parse(fs.readFileSync(directory + '/package.json')).scripts['type-check'],
    resolvedTaskDefinition: definition}));
  if (definition.dependsOn.includes('^build')) {
    for (const directory of dirs) tasks.push({directory, task: 'build', command: 'tsc -b',
      resolvedTaskDefinition: {cache: false, outputs: []}});
  }
  console.log(JSON.stringify({tasks}));
} else if (process.argv.includes('list')) {
  const selected = ['filter', 'filter-prod', 'workspace-packages'].some((key) => setting(key) !== 'undefined')
    ? dirs.slice(0, 1) : dirs;
  console.log(JSON.stringify(selected.map((dir) => ({path: path.resolve(dir)}))));
} else {
  console.log('parent held=' + (process.env.FM_BUILD_LOCK_HELD || ''));
  if (fs.realpathSync(process.argv[1]).includes('/pnpm/') && setting('tasks') !== 'undefined' &&
      fs.existsSync('tools/pnpm-build.cjs')) {
    cp.execFileSync(process.execPath, ['tools/pnpm-build.cjs'], {stdio: 'inherit'});
  }
  if (fs.realpathSync(process.argv[1]).includes('/pnpm/') && setting('include-workspace-root') === 'true') {
    const script = JSON.parse(fs.readFileSync('package.json')).scripts?.['type-check'];
    if (script) {
      const result = cp.spawnSync('sh', ['-c', script], {env: process.env, stdio: 'inherit'});
      if (result.status !== 0) process.exit(result.status || 1);
    }
  }
  let code = 0;
  for (const dir of dirs) {
    const result = cp.spawnSync(process.execPath,
      [path.resolve('node_modules/typescript/bin/tsc'), '--noEmit'],
      {cwd: dir, env: process.env, stdio: 'inherit'});
    code = code || result.status;
  }
  if (fs.realpathSync(process.argv[1]).includes('/pnpm/') && setting('report-summary') === 'true') {
    fs.writeFileSync('pnpm-exec-summary.json', JSON.stringify({marker: process.env.FM_HEAVY_ORCHESTRATOR}));
  }
  const entry = fs.realpathSync(process.argv[1]);
  if (entry.includes('/turbo/')) {
    const graph = process.env.TURBO_ROOT_TURBO_JSON || 'turbo.json';
    console.log('graph=' + graph);
    if (JSON.parse(fs.readFileSync(graph)).tasks['type-check'].dependsOn.includes('^build')) {
      fs.writeFileSync('built-output.txt', 'generated');
    }
    if (process.env.TURBO_RUN_SUMMARY) fs.writeFileSync('turbo-summary.json', '{}');
    if (process.env.TURBO_LOG_FILE) fs.writeFileSync(process.env.TURBO_LOG_FILE, 'log');
  }
  if ((entry.includes('/nx/') || entry.includes('/lerna/')) && process.env.NX_PROFILE) {
    fs.writeFileSync(process.env.NX_PROFILE, '{}');
  }
  process.exit(code);
}
"""
    (work / 'tools/orchestrator.cjs').write_text(parent)
    (work / 'tools/tsc').write_text(child)
    (work / 'tools/tsc').chmod(0o755)
    (work / 'package.json').write_text(json.dumps({'name': 'smokeproj', 'private': True}))
    (work / 'pnpm-workspace.yaml').write_text('packages:\n  - packages/*\n')
    (work / 'turbo.json').write_text(json.dumps({'tasks': {'type-check': {
        'cache': cache, 'outputs': [], 'dependsOn': []}}}))
    (work / 'nx.json').write_text(json.dumps({'targetDefaults': {'type-check': {
        'cache': cache, 'outputs': [], 'dependsOn': []}}}))
    (work / 'lerna.json').write_text(json.dumps({'version': '0.0.0'}))
    for directory in ('packages/a', 'packages/b'):
        d = work / directory
        d.mkdir(parents=True)
        (d / 'package.json').write_text(json.dumps({'name': directory, 'scripts': {'type-check': script, 'build': 'tsc -b'}}))
        (d / 'tsconfig.json').write_text('{"compilerOptions":{"noEmit":true}}')
    subprocess.run(['git', '-C', str(work), 'add', '-A'], check=True, capture_output=True)
    subprocess.run(['git', '-C', str(work), 'commit', '-qm', 'orchestrator fixture'],
                   check=True, capture_output=True)
    subprocess.run(['bash', '-c', install], cwd=work, check=True, capture_output=True)
    option = subprocess.run([str(repo / 'bin/fm-build-lock.py'), 'node-option'], env=env,
                            capture_output=True, text=True, check=True).stdout.strip()
    env['NODE_OPTIONS'] = option
    assert publish(config, env).returncode == 0
    entry = {'turbo': '.bin/turbo', 'nx': 'nx/bin/nx.js',
             'lerna': 'lerna/dist/cli.js', 'pnpm': '.bin/pnpm'}[tool]
    return p, work, config, state, env, work / 'node_modules' / entry


def orchestration_run(work, env, cli, args):
    return subprocess.run(['node', str(cli), *args], env=env, cwd=work,
                          capture_output=True, text=True, timeout=120)


def starts(state):
    if not called(state):
        return 0
    return sum(json.loads(line)[0] == 'new' for line in (state / 'calls.jsonl').read_text().splitlines())


for tool, args in (('turbo', ['type-check']), ('nx', ['run-many', '-t', 'type-check']),
                   ('nx', ['run', 'a:type-check']), ('lerna', ['run', 'type-check']),
                   ('pnpm', ['-r', 'type-check']), ('pnpm', ['--recursive', 'run', 'type-check']),
                   ('pnpm', ['-F', 'a', 'type-check']), ('pnpm', ['-Fa', 'type-check']),
                   ('pnpm', ['--filter=a', 'run', 'type-check'])):
    p, work, config, state, env, cli = orchestrator_case('whole-' + tool + '-' + str(fixture_index), tool)
    fixture_index += 1
    r = orchestration_run(work, env, cli, args)
    assert r.returncode == 0, (tool, args, r.stdout, r.stderr)
    assert starts(state) == 1, (tool, args, r.stderr)
    assert r.stdout.count('child marker=remote held=\n') == 2, (tool, r.stdout, r.stderr)
    assert 'parent held=\n' in r.stdout, r.stdout
    assert r.stderr.count('orchestrator on Boat') == 1, r.stderr
    assert 'running locally' not in r.stderr, r.stderr
print('ok - turbo, nx, lerna and recursive/filtered pnpm route one whole run; two children start no jobs')

for index, (tool, args) in enumerate((('turbo', ['type-check']),
                                     ('nx', ['run-many', '-t', 'type-check']),
                                     ('lerna', ['run', 'type-check']),
                                     ('pnpm', ['-r', 'type-check']),
                                     ('pnpm', ['--filter=a', 'type-check']))):
    for mode in ('canonical', 'symlink', 'require-pair', 'require-equals', 'local', 'ancestor'):
        p, work, config, state, env, cli = orchestrator_case(
            'relative-launcher-' + str(index) + '-' + mode, tool)
        launcher = cli.resolve().relative_to(work) if mode in ('canonical', 'ancestor') else (
            Path('node_modules/.bin') / tool)
        node_flags = []
        preload = str(Path(env['FM_BUILD_LOCK_INSTALL_DIR']) / 'fm-build-lock.js')
        if mode == 'require-pair':
            node_flags = ['--require', preload]
        elif mode == 'require-equals':
            node_flags = ['--require=' + preload]
        command = ['node', *node_flags, './' + str(launcher), *args]
        if mode == 'local':
            command.append('--mystery')
        elif mode == 'ancestor':
            outer = p / 'outer' / tool
            outer.parent.mkdir()
            outer.write_text(ORCHESTRATOR)
            outer.chmod(0o755)
            outer_flags = ['-r', 'exec'] if tool == 'pnpm' else ['run', 'type-check']
            command = [str(outer), *outer_flags, '--', *command]
        r = subprocess.run(command, env=env, cwd=work, capture_output=True, text=True, timeout=120)
        assert r.returncode == 0, (tool, mode, r.stdout, r.stderr)
        if mode in ('local', 'ancestor'):
            assert not called(state), (tool, mode, r.stdout, r.stderr)
            assert r.stderr.count('running locally in a heavy slot') == 1, (tool, mode, r.stderr)
            assert r.stdout.count('child marker=local held=') == 2, (tool, mode, r.stdout, r.stderr)
            if mode == 'ancestor':
                assert 'runs under ' + tool in r.stderr, r.stderr
        else:
            assert starts(state) == 1, (tool, mode, r.stdout, r.stderr)
            assert r.stdout.count('child marker=remote held=\n') == 2, (tool, mode, r.stdout, r.stderr)
            assert 'running locally' not in r.stderr, (tool, mode, r.stderr)
print('ok - relative and symlink launchers route once, including preload flags, while true ancestors and fallback children stay local')

for source in ('user', 'global', 'environment'):
    for enabled in (False, True):
        p, work, config, state, env, cli = orchestrator_case(
            'pnpm-root-' + source + '-' + str(enabled), 'pnpm')
        value = 'true' if enabled else 'false'
        if source == 'environment':
            env['NPM_CONFIG_INCLUDE_WORKSPACE_ROOT'] = value
        else:
            path = Path(env['HOME']) / '.npmrc' if source == 'user' else p / 'global.npmrc'
            path.write_text('include-workspace-root=' + value + '\n')
            if source == 'global':
                env['npm_config_globalconfig'] = str(path)
        package = json.loads((work / 'package.json').read_text())
        package['scripts'] = {'type-check': 'node tools/root-failure.cjs'}
        (work / 'package.json').write_text(json.dumps(package))
        (work / 'tools/root-failure.cjs').write_text(
            "console.log('root marker=' + process.env.FM_HEAVY_ORCHESTRATOR); process.exit(9);\n")
        subprocess.run(['git', '-C', str(work), 'add', '-A'], check=True, capture_output=True)
        subprocess.run(['git', '-C', str(work), 'commit', '-qm', 'Root inclusion fixture'],
                       check=True, capture_output=True)
        r = orchestration_run(work, env, cli, ['-r', 'type-check'])
        assert r.returncode == (9 if enabled else 0), (source, enabled, r.stdout, r.stderr)
        assert starts(state) == (0 if enabled else 1), (source, enabled, r.stderr)
        if enabled:
            assert 'root marker=local' in r.stdout, (source, r.stdout, r.stderr)
        else:
            assert r.stdout.count('child marker=remote held=\n') == 2, (source, r.stdout, r.stderr)

for name, key, stdout, exit_code in (
    ('unavailable', 'include-workspace-root', '', 42),
    ('ambiguous', 'include-workspace-root', 'false\ntrue\n', 0),
    ('empty', 'include-workspace-root', '', 0),
    ('unknown', 'include-workspace-root', 'null\n', 0),
    ('later-unavailable', 'filter-prod', '', 42),
):
    p, work, config, state, env, cli = orchestrator_case('pnpm-config-' + name, 'pnpm')
    (work / 'tools/config-probe.json').write_text(json.dumps({key: {'stdout': stdout, 'exit': exit_code}}))
    subprocess.run(['git', '-C', str(work), 'add', '-A'], check=True, capture_output=True)
    subprocess.run(['git', '-C', str(work), 'commit', '-qm', 'Unavailable config fixture'],
                   check=True, capture_output=True)
    r = orchestration_run(work, env, cli, ['-r', 'type-check'])
    assert r.returncode == 0 and starts(state) == 0, (name, r.stdout, r.stderr)
    assert r.stdout.count('child marker=local held=') == 2, (name, r.stdout, r.stderr)

for key, value in (('filter', 'packages/a'), ('filter-prod', 'packages/a'),
                   ('workspace-packages', 'packages/a'), ('ignore-workspace', 'true'),
                   ('legacy-dir-filtering', 'true'), ('test-pattern', 'tests/**'),
                   ('changed-files-ignore-pattern', '**'), ('link-workspace-packages', 'true'),
                   ('shared-workspace-lockfile', 'false'), ('resume-from', 'packages/b')):
    p, work, config, state, env, cli = orchestrator_case('pnpm-selection-' + key, 'pnpm')
    env['npm_config_' + key.replace('-', '_')] = value
    if key in ('filter', 'filter-prod', 'workspace-packages'):
        path = work / 'packages/b/package.json'
        package = json.loads(path.read_text())
        package['scripts']['type-check'] = 'node custom-typecheck.js'
        path.write_text(json.dumps(package))
    subprocess.run(['git', '-C', str(work), 'add', '-A'], check=True, capture_output=True)
    subprocess.run(['git', '-C', str(work), 'commit', '--allow-empty', '-qm', 'Effective selection fixture'],
                   check=True, capture_output=True)
    r = orchestration_run(work, env, cli, ['-r', 'type-check'])
    assert r.returncode == 0 and starts(state) == 0, (key, r.stdout, r.stderr)
print('ok - pnpm proves effective root exclusion and refuses hidden selection overrides or ambiguous config probes')

for tool in ('turbo', 'pnpm'):
    for form in ('long', 'long-equals', 'short', 'attached', 'short-equals'):
        for selector in ('[HEAD^]', 'a...[main]', 'a'):
            p, work, config, state, env, cli = orchestrator_case(
                'filter-history-' + tool + '-' + form + '-' + str(fixture_index), tool)
            fixture_index += 1
            flags = {'long': ['--filter', selector], 'long-equals': ['--filter=' + selector],
                     'short': ['-F', selector], 'attached': ['-F' + selector],
                     'short-equals': ['-F=' + selector]}[form]
            args = [*flags, 'type-check'] if tool == 'pnpm' else ['type-check', *flags]
            r = orchestration_run(work, env, cli, args)
            history = selector != 'a'
            assert r.returncode == 0 and starts(state) == (0 if history else 1), (tool, form, selector, r.stdout, r.stderr)
            if history:
                assert not called(state), (tool, form, selector)
                assert r.stderr.count('running locally in a heavy slot') == 1, r.stderr
                assert r.stdout.count('child marker=local held=') == 2, (r.stdout, r.stderr)
            else:
                assert r.stdout.count('child marker=remote held=\n') == 2, (r.stdout, r.stderr)
print('ok - Turbo and pnpm history selectors stay local across filter aliases while ordinary filters route once')

for source in ('workspace', 'repository', 'user', 'global', 'environment'):
    for enabled in (False, True):
        p, work, config, state, env, cli = orchestrator_case(
            'pnpm-report-' + source + '-' + str(enabled), 'pnpm')
        value = 'true' if enabled else 'false'
        if source == 'workspace':
            path = work / 'pnpm-workspace.yaml'
            path.write_text(path.read_text() + 'reportSummary: ' + value + '\n')
        elif source == 'environment':
            env['NPM_CONFIG_REPORT_SUMMARY'] = value
        else:
            path = {'repository': work / '.npmrc', 'user': Path(env['HOME']) / '.npmrc',
                    'global': p / 'global.npmrc'}[source]
            path.write_text('report-summary=' + value + '\n')
            if source == 'global':
                env['npm_config_globalconfig'] = str(path)
        subprocess.run(['git', '-C', str(work), 'add', '-A'], check=True, capture_output=True)
        subprocess.run(['git', '-C', str(work), 'commit', '--allow-empty', '-qm', 'Summary configuration fixture'],
                       check=True, capture_output=True)
        r = orchestration_run(work, env, cli, ['-r', 'type-check'])
        assert r.returncode == 0 and starts(state) == (0 if enabled else 1), (source, enabled, r.stdout, r.stderr)
        summary = work / 'pnpm-exec-summary.json'
        if enabled:
            assert not called(state), (source, r.stderr)
            assert r.stderr.count('running locally in a heavy slot') == 1, r.stderr
            assert json.loads(summary.read_text()) == {'marker': 'local'}, (source, r.stdout, r.stderr)
        else:
            assert not summary.exists(), (source, r.stdout, r.stderr)

for name, stdout, exit_code in (('ambiguous', 'false\ntrue\n', 0), ('empty', '', 0),
                                 ('unknown', 'null\n', 0), ('unavailable', '', 42)):
    p, work, config, state, env, cli = orchestrator_case('pnpm-summary-probe-' + name, 'pnpm')
    (work / 'tools/config-probe.json').write_text(json.dumps({
        'report-summary': {'stdout': stdout, 'exit': exit_code}}))
    subprocess.run(['git', '-C', str(work), 'add', '-A'], check=True, capture_output=True)
    subprocess.run(['git', '-C', str(work), 'commit', '-qm', 'Ambiguous summary fixture'],
                   check=True, capture_output=True)
    r = orchestration_run(work, env, cli, ['-r', 'type-check'])
    assert r.returncode == 0 and not called(state), (name, r.stdout, r.stderr)
    assert r.stderr.count('running locally in a heavy slot') == 1, r.stderr
    assert not (work / 'pnpm-exec-summary.json').exists(), (name, r.stdout, r.stderr)
print('ok - effective pnpm summaries are retained locally and ambiguous summary probes cannot route')

for tool, key, value, artifact in (
    ('turbo', 'TURBO_ROOT_TURBO_JSON', 'turbo-alt.json', None),
    ('turbo', 'TURBO_RUN_SUMMARY', 'true', 'turbo-summary.json'),
    ('turbo', 'TURBO_LOG_FILE', 'turbo.log', 'turbo.log'),
    ('turbo', 'TURBO_BINARY_PATH', 'alternate-turbo', None),
    ('turbo', 'TURBO_CACHE_DIR', 'alternate-cache', None),
    ('turbo', 'TURBO_SCM_BASE', 'main', None),
    ('nx', 'NX_PROFILE', 'profile.json', 'profile.json'),
    ('lerna', 'NX_PROFILE', 'profile.json', 'profile.json'),
    ('nx', 'NX_TASKS_RUNNER', 'custom', None),
    ('lerna', 'NX_DEFAULT_PROJECT', 'b', None),
    ('nx', 'NX_FORCE_REUSE_CACHED_GRAPH', 'true', None),
    ('lerna', 'NX_WORKSPACE_DATA_DIRECTORY', 'custom-data', None),
    ('lerna', 'NX_BATCH_MODE', 'true', None),
):
    p, work, config, state, env, cli = orchestrator_case('environment-' + tool + '-' + key, tool)
    env[key] = value
    probe_log = p / 'probes.log'
    env['FM_ORCHESTRATOR_PROBE_LOG'] = str(probe_log)
    if key == 'TURBO_ROOT_TURBO_JSON':
        (work / 'turbo-alt.json').write_text((work / 'turbo.json').read_text())
        graph = json.loads((work / 'turbo.json').read_text())
        graph['tasks']['type-check']['dependsOn'] = ['^build']
        (work / 'turbo.json').write_text(json.dumps(graph))
        subprocess.run(['git', '-C', str(work), 'add', '-A'], check=True, capture_output=True)
        subprocess.run(['git', '-C', str(work), 'commit', '-qm', 'Alternate graph fixture'],
                       check=True, capture_output=True)
    args = ['run-many', '-t', 'type-check'] if tool == 'nx' else (
        ['run', 'type-check'] if tool == 'lerna' else ['type-check'])
    r = orchestration_run(work, env, cli, args)
    assert r.returncode == 0 and not called(state), (tool, key, r.stdout, r.stderr)
    assert not probe_log.exists(), (tool, key)
    assert r.stderr.count('running locally in a heavy slot') == 1, r.stderr
    assert r.stdout.count('child marker=local held=') == 2, (r.stdout, r.stderr)
    if artifact:
        assert (work / artifact).is_file(), (key, r.stdout, r.stderr)
    if key == 'TURBO_ROOT_TURBO_JSON':
        assert 'graph=turbo-alt.json' in r.stdout and not (work / 'built-output.txt').exists(), r.stdout
print('ok - graph and file-output environment overrides stay local before orchestrator probes')

for tool in ('turbo', 'nx', 'lerna'):
    for mode in ('copy-with-local', 'copy-without-local', 'alias-local', 'remote-missing'):
        p, work, config, state, env, cli = orchestrator_case('launcher-' + tool + '-' + mode, tool)
        local_entry = cli.resolve()
        if mode != 'remote-missing':
            suffix = {'turbo': 'turbo/bin/turbo', 'nx': 'nx/bin/nx.js', 'lerna': 'lerna/dist/cli.js'}[tool]
            external = p / 'global' / suffix
            external.parent.mkdir(parents=True)
            if mode == 'alias-local':
                external.symlink_to(local_entry)
            else:
                external.write_bytes(local_entry.read_bytes())
                external.chmod(0o755)
                if mode == 'copy-without-local':
                    local_entry.rename(local_entry.with_name('unused-entry'))
            cli = external
        else:
            record_path = Path(env['FM_BUILD_LOCK_INSTALL_DIR']) / 'boat-route'
            record = json.loads(record_path.read_text())
            record['projects']['smokeproj']['bootstrap'] += '; mv ' + shlex.quote(
                str(local_entry.relative_to(work))) + ' node_modules/unavailable-entry'
            record_path.write_text(json.dumps(record))
        args = ['run-many', '-t', 'type-check'] if tool == 'nx' else (
            ['run', 'type-check'] if tool == 'lerna' else ['type-check'])
        r = orchestration_run(work, env, cli, args)
        assert r.returncode == 0, (tool, mode, r.stdout, r.stderr)
        if mode == 'alias-local':
            assert starts(state) == 1 and r.stdout.count('child marker=remote held=\n') == 2, (tool, mode, r.stdout, r.stderr)
        else:
            assert starts(state) == (1 if mode == 'remote-missing' else 0), (tool, mode, r.stdout, r.stderr)
            assert r.stderr.count('running locally in a heavy slot') == 1, (tool, mode, r.stderr)
            assert r.stdout.count('child marker=local held=') == 2, (tool, mode, r.stdout, r.stderr)
            assert r.stdout.count('parent held=') == 1, (tool, mode, r.stdout, r.stderr)
            if mode == 'remote-missing':
                assert 'setup did not dispatch' in r.stderr, r.stderr
print('ok - external launchers require a proven project entry and missing remote entries fall back once')

for index, flags in enumerate((['-t', 'fix:lint'], ['--target', 'fix:lint'],
                               ['--targets', 'fix:lint'], ['-t=fix:lint'],
                               ['--target=fix:lint'], ['--targets=lint,fix:lint'])):
    p, work, config, state, env, cli = orchestrator_case('nx-literal-target-' + str(index), 'nx')
    path = work / 'packages/a/package.json'
    package = json.loads(path.read_text())
    package['scripts'].update({'lint': 'tsc --noEmit', 'fix:lint': 'node ../../tools/fix-lint.cjs'})
    path.write_text(json.dumps(package))
    (work / 'tools/fix-lint.cjs').write_text(
        "require('fs').writeFileSync('../../tracked.txt', 'fixed locally');\n"
        "console.log('colon marker=' + process.env.FM_HEAVY_ORCHESTRATOR);\n")
    parent = r"""#!/usr/bin/env node
const cp = require('child_process');
const fs = require('fs');
const script = JSON.parse(fs.readFileSync('packages/a/package.json')).scripts['fix:lint'];
const result = cp.spawnSync('sh', ['-c', script], {cwd: 'packages/a', env: process.env, stdio: 'inherit'});
process.exit(result.status);
"""
    (work / 'tools/orchestrator.cjs').write_text(parent)
    cli.write_text(parent)
    subprocess.run(['git', '-C', str(work), 'add', '-A'], check=True, capture_output=True)
    subprocess.run(['git', '-C', str(work), 'commit', '-qm', 'Literal Nx target fixture'],
                   check=True, capture_output=True)
    r = orchestration_run(work, env, cli, ['run-many', *flags, '--skipNxCache'])
    assert r.returncode == 0 and not called(state), (flags, r.stdout, r.stderr)
    assert r.stderr.count('running locally in a heavy slot') == 1, r.stderr
    assert 'colon marker=local' in r.stdout, (r.stdout, r.stderr)
    assert (work / 'tracked.txt').read_text() == 'fixed locally'

p, work, config, state, env, cli = orchestrator_case('nx-safe-colon-target', 'nx')
for directory in (work / 'packages/a', work / 'packages/b'):
    path = directory / 'package.json'
    package = json.loads(path.read_text())
    package['scripts']['test:ci'] = 'tsc --noEmit'
    path.write_text(json.dumps(package))
subprocess.run(['git', '-C', str(work), 'add', '-A'], check=True, capture_output=True)
subprocess.run(['git', '-C', str(work), 'commit', '-qm', 'Safe literal target'], check=True, capture_output=True)
r = orchestration_run(work, env, cli, ['run-many', '--targets=test:ci', '--skipNxCache'])
assert r.returncode == 0 and starts(state) == 1, (r.stdout, r.stderr)
assert r.stdout.count('child marker=remote held=\n') == 2, (r.stdout, r.stderr)
print('ok - Nx option targets retain literal colons while recognized safe literal targets route once')

for source in ('workspace', 'repository', 'user', 'global', 'environment'):
    p, work, config, state, env, cli = orchestrator_case('pnpm-task-graph-' + source, 'pnpm')
    tasks = json.dumps({'type-check': {'dependsOn': ['build']}})
    if source == 'workspace':
        path = work / 'pnpm-workspace.yaml'
        path.write_text(path.read_text() + 'tasks:\n  type-check:\n    dependsOn: [build]\n')
    elif source == 'environment':
        env['NPM_CONFIG_TASKS'] = tasks
    else:
        path = {'repository': work / '.npmrc', 'user': Path(env['HOME']) / '.npmrc',
                'global': p / 'global.npmrc'}[source]
        path.write_text('tasks=' + tasks + '\n')
        if source == 'global':
            env['npm_config_globalconfig'] = str(path)
    for directory in (work / 'packages/a', work / 'packages/b'):
        path = directory / 'package.json'
        package = json.loads(path.read_text())
        package['scripts']['build'] = 'node ../../tools/pnpm-build.cjs'
        path.write_text(json.dumps(package))
    (work / 'tools/pnpm-build.cjs').write_text(
        "require('fs').writeFileSync(require('path').join(__dirname, '../pnpm-build-output.txt'), 'built locally');\n"
        "console.log('build marker=' + process.env.FM_HEAVY_ORCHESTRATOR);\n")
    subprocess.run(['git', '-C', str(work), 'add', '-A'], check=True, capture_output=True)
    subprocess.run(['git', '-C', str(work), 'commit', '-qm', 'pnpm task dependency fixture'],
                   check=True, capture_output=True)
    r = orchestration_run(work, env, cli, ['-r', 'type-check'])
    assert r.returncode == 0 and not called(state), (source, r.stdout, r.stderr)
    assert r.stderr.count('running locally in a heavy slot') == 1, r.stderr
    assert 'build marker=local' in r.stdout, (source, r.stdout, r.stderr)
    assert (work / 'pnpm-build-output.txt').read_text() == 'built locally'

for name, stdout, exit_code in (('unknown', 'null\n', 0), ('ambiguous', '{}\nundefined\n', 0),
                                 ('empty', '', 0), ('unavailable', '', 42)):
    p, work, config, state, env, cli = orchestrator_case('pnpm-tasks-probe-' + name, 'pnpm')
    (work / 'tools/config-probe.json').write_text(json.dumps({'tasks': {'stdout': stdout, 'exit': exit_code}}))
    subprocess.run(['git', '-C', str(work), 'add', '-A'], check=True, capture_output=True)
    subprocess.run(['git', '-C', str(work), 'commit', '-qm', 'Unproven tasks configuration'],
                   check=True, capture_output=True)
    r = orchestration_run(work, env, cli, ['-r', 'type-check'])
    assert r.returncode == 0 and not called(state), (name, r.stdout, r.stderr)
    assert r.stderr.count('running locally in a heavy slot') == 1, r.stderr
print('ok - pnpm task graphs and unproven tasks settings keep dependency outputs local for every configuration owner')

for name, tool, args, script, cache in (
    ('unknown-options', 'turbo', ['type-check', '--mystery'], 'tsc --noEmit', False),
    ('passthrough-fix', 'pnpm', ['-r', 'type-check', '--', '--fix'], 'tsc --noEmit', False),
    ('forwarded-filter', 'pnpm', ['-r', 'run', 'type-check', '--filter=a'], 'tsc --noEmit', False),
    ('forwarded-short-filter', 'pnpm', ['-r', 'type-check', '-F', 'a'], 'tsc --noEmit', False),
    ('forwarded-attached-filter', 'pnpm', ['-r', 'type-check', '-Fa'], 'tsc --noEmit', False),
    ('forwarded-recursive', 'pnpm', ['--filter=a', 'run', 'type-check', '--recursive'], 'tsc --noEmit', False),
    ('shell-script', 'turbo', ['type-check'], 'tsc --noEmit && touch output', False),
    ('unknown-script', 'pnpm', ['-r', 'type-check'], 'node custom-typecheck.js', False),
    ('write-output', 'turbo', ['type-check'], 'tsc --generateTrace trace --noEmit', False),
    ('turbo-cache', 'turbo', ['type-check'], 'tsc --noEmit', True),
    ('nx-cache', 'nx', ['run-many', '-t', 'type-check'], 'tsc --noEmit', True),
):
    p, work, config, state, env, cli = orchestrator_case('reject-' + name, tool, cache=cache, script=script)
    r = orchestration_run(work, env, cli, args)
    assert r.returncode == 0 and starts(state) == 0, (name, r.stdout, r.stderr)
    assert r.stderr.count('running locally in a heavy slot') == 1, (name, r.stderr)
    assert r.stdout.count('child marker=local held=') == 2, (name, r.stdout, r.stderr)
    assert 'parent held=\n' not in r.stdout, (name, r.stdout)
print('ok - unknown options, shell/custom tasks, diagnostic outputs and orchestrator caches stay local with one notice')

for representation in ('package', 'project'):
    for safe in (False, True):
        script = 'tsc --noEmit' if safe else 'node custom-typecheck.js'
        metadata_script = 'node custom-typecheck.js' if safe else 'tsc --noEmit'
        p, work, config, state, env, cli = orchestrator_case(
            'pnpm-nx-' + representation + '-' + str(safe), 'pnpm', script=script)
        directory = work / 'packages/a'
        targets = {'type-check': {'executor': 'nx:run-commands',
                                 'options': {'command': metadata_script}}}
        if representation == 'package':
            path = directory / 'package.json'
            package = json.loads(path.read_text())
            package['nx'] = {'targets': targets}
            path.write_text(json.dumps(package))
        else:
            (directory / 'project.json').write_text(json.dumps({'targets': targets}))
        subprocess.run(['git', '-C', str(work), 'add', '-A'], check=True, capture_output=True)
        subprocess.run(['git', '-C', str(work), 'commit', '-qm', 'Nx metadata'],
                       check=True, capture_output=True)
        r = orchestration_run(work, env, cli, ['-r', 'type-check'])
        assert r.returncode == 0 and starts(state) == int(safe), (representation, safe, r.stdout, r.stderr)
        marker = 'remote' if safe else 'local'
        assert r.stdout.count('child marker=' + marker + ' held=') == 2, (r.stdout, r.stderr)
print('ok - pnpm screens package scripts independently of both Nx target representations')

def write_nx_target(directory, representation, target):
    if representation == 'package':
        path = directory / 'package.json'
        package = json.loads(path.read_text())
        package['nx'] = {'targets': {'type-check': target}}
        path.write_text(json.dumps(package))
    else:
        (directory / 'project.json').write_text(json.dumps({'targets': {'type-check': target}}))


for tool in ('nx', 'lerna'):
    args = ['run-many', '-t', 'type-check'] if tool == 'nx' else ['run', 'type-check']
    for representation in ('package', 'project'):
        for no_emit in (False, True):
            p, work, config, state, env, cli = orchestrator_case(
                'executor-cwd-' + tool + '-' + representation + '-' + str(no_emit), tool)
            (work / 'tsconfig.json').write_text(json.dumps({'compilerOptions': {'noEmit': no_emit}}))
            child = r"""#!/usr/bin/env node
const fs = require('fs');
const config = JSON.parse(fs.readFileSync('tsconfig.json', 'utf8'));
if (process.argv.includes('--showConfig')) {
  console.log(JSON.stringify(config));
} else {
  if (!config.compilerOptions.noEmit) fs.writeFileSync('typecheck-output.txt', 'emitted');
  console.log('root task marker=' + process.env.FM_HEAVY_ORCHESTRATOR);
}
"""
            parent = r"""#!/usr/bin/env node
const cp = require('child_process');
const path = require('path');
const result = cp.spawnSync(process.execPath,
  [path.resolve('node_modules/typescript/bin/tsc')], {stdio: 'inherit', env: process.env});
process.exit(result.status);
"""
            (work / 'tools/tsc').write_text(child)
            (work / 'node_modules/typescript/bin/tsc').write_text(child)
            (work / 'tools/orchestrator.cjs').write_text(parent)
            cli.write_text(parent)
            for directory in (work / 'packages/a', work / 'packages/b'):
                (directory / 'tsconfig.json').write_text(json.dumps(
                    {'compilerOptions': {'noEmit': not no_emit}}))
                write_nx_target(directory, representation,
                                {'executor': 'nx:run-commands', 'options': {'command': 'tsc'}})
                executable = directory / 'node_modules/.bin/tsc'
                executable.parent.mkdir(parents=True)
                executable.write_text('#!/usr/bin/env node\nconsole.log(' + json.dumps(json.dumps(
                    {'compilerOptions': {'noEmit': not no_emit}})) + ');\n')
                executable.chmod(0o755)
            subprocess.run(['git', '-C', str(work), 'add', '-A'], check=True, capture_output=True)
            subprocess.run(['git', '-C', str(work), 'commit', '-qm', 'Executor cwd fixture'],
                           check=True, capture_output=True)
            r = orchestration_run(work, env, cli, args)
            assert r.returncode == 0 and starts(state) == int(no_emit), (tool, representation, no_emit, r.stdout, r.stderr)
            marker = 'remote' if no_emit else 'local'
            assert 'root task marker=' + marker in r.stdout, (r.stdout, r.stderr)
            assert (work / 'typecheck-output.txt').exists() == (not no_emit)
    for layers in ('defaults-package', 'defaults-project', 'package-project'):
        p, work, config, state, env, cli = orchestrator_case('executor-options-' + tool + '-' + layers, tool)
        (work / 'package.json').rename(work / 'workspace-package.json')
        (work / 'tsconfig.json').write_text('{"compilerOptions":{"noEmit":true}}')
        inherited = {'executor': 'nx:run-commands', 'cache': False,
                     'options': {'args': '--generateTrace trace'}}
        if layers.startswith('defaults'):
            (work / 'nx.json').write_text(json.dumps({'targetDefaults': {'type-check': inherited}}))
        for directory in (work / 'packages/a', work / 'packages/b'):
            if layers == 'package-project':
                write_nx_target(directory, 'package', inherited)
            write_nx_target(directory, 'package' if layers == 'defaults-package' else 'project',
                            {'options': {'command': 'tsc --noEmit'}})
        subprocess.run(['git', '-C', str(work), 'add', '-A'], check=True, capture_output=True)
        subprocess.run(['git', '-C', str(work), 'commit', '-qm', 'Inherited executor options'],
                       check=True, capture_output=True)
        r = orchestration_run(work, env, cli, args)
        assert r.returncode == 0 and starts(state) == 0, (tool, layers, r.stdout, r.stderr)
        assert r.stdout.count('child marker=local held=') == 2, (r.stdout, r.stderr)
print('ok - Nx and Lerna use root executor cwd and binaries, and retain inherited option safety')

for tool in ('nx', 'lerna'):
    args = ['run-many', '-t', 'lint'] if tool == 'nx' else ['run', 'lint']
    for representation in ('defaults', 'package', 'project'):
        for safe in (False, True):
            p, work, config, state, env, cli = orchestrator_case(
                'noop-dependency-' + tool + '-' + representation + '-' + str(safe), tool)
            defaults = {'lint': {'cache': False}, 'build': {'cache': False}}
            dependency = {'dependsOn': ['build']}
            if representation == 'defaults':
                defaults['lint'].update(dependency)
            (work / 'nx.json').write_text(json.dumps({'targetDefaults': defaults}))
            for name in ('a', 'b'):
                directory = work / 'packages' / name
                package = json.loads((directory / 'package.json').read_text())
                package['scripts'] = {'build': 'tsc --noEmit' if safe or name == 'a' else 'node generate.js'}
                if name == 'a':
                    package['scripts']['lint'] = 'tsc --noEmit'
                    if representation == 'defaults':
                        package['nx'] = {'targets': {'lint': {'dependsOn': []}}}
                elif representation == 'package':
                    package['nx'] = {'targets': {'lint': dependency}}
                elif representation == 'project':
                    (directory / 'project.json').write_text(json.dumps({'targets': {'lint': dependency}}))
                (directory / 'package.json').write_text(json.dumps(package))
            (work / 'packages/b/generate.js').write_text(
                "require('fs').writeFileSync('generated.txt', 'build output');\n")
            parent = r"""#!/usr/bin/env node
const cp = require('child_process');
const fs = require('fs');
const path = require('path');
const env = {...process.env, PATH: path.resolve('node_modules/.bin') + path.delimiter + process.env.PATH};
for (const [directory, task] of [['packages/a', 'lint'], ['packages/b', 'build']]) {
  const script = JSON.parse(fs.readFileSync(directory + '/package.json')).scripts[task];
  const result = cp.spawnSync('sh', ['-c', script], {cwd: directory, env, stdio: 'inherit'});
  if (result.status !== 0) process.exit(result.status || 1);
}
console.log('dependency marker=' + process.env.FM_HEAVY_ORCHESTRATOR);
"""
            (work / 'tools/orchestrator.cjs').write_text(parent)
            cli.write_text(parent)
            subprocess.run(['git', '-C', str(work), 'add', '-A'], check=True, capture_output=True)
            subprocess.run(['git', '-C', str(work), 'commit', '-qm', 'Dependency-only target fixture'],
                           check=True, capture_output=True)
            r = orchestration_run(work, env, cli, args)
            assert r.returncode == 0 and starts(state) == int(safe), (tool, representation, safe, r.stdout, r.stderr)
            marker = 'remote' if safe else 'local'
            assert 'dependency marker=' + marker in r.stdout, (r.stdout, r.stderr)
            assert (work / 'packages/b/generated.txt').exists() == (not safe)
print('ok - Nx and Lerna screen dependency-only targets from defaults, package and project metadata')

def run_target_side_effect(work, env, cli, args, state, output):
    parent = r"""#!/usr/bin/env node
const cp = require('child_process');
const path = require('path');
cp.execFileSync(process.execPath, ['tools/side-effect.cjs'], {stdio: 'inherit'});
const result = cp.spawnSync(process.execPath,
  [path.resolve('node_modules/typescript/bin/tsc'), '--noEmit'],
  {cwd: 'packages/a', env: process.env, stdio: 'inherit'});
console.log('side-effect marker=' + process.env.FM_HEAVY_ORCHESTRATOR);
process.exit(result.status);
"""
    (work / 'tools/orchestrator.cjs').write_text(parent)
    cli.write_text(parent)
    (work / 'tools/side-effect.cjs').write_text(
        "require('fs').writeFileSync(" + json.dumps(output) + ", 'retained locally');\n")
    subprocess.run(['git', '-C', str(work), 'add', '-A'], check=True, capture_output=True)
    subprocess.run(['git', '-C', str(work), 'commit', '-qm', 'Target side effect fixture'],
                   check=True, capture_output=True)
    r = orchestration_run(work, env, cli, args)
    assert r.returncode == 0 and starts(state) == 0, (args, output, r.stdout, r.stderr)
    assert 'side-effect marker=local' in r.stdout, (r.stdout, r.stderr)
    assert (work / output).read_text() == 'retained locally'


for tool in ('nx', 'lerna'):
    args = ['run-many', '-t', 'type-check'] if tool == 'nx' else ['run', 'type-check']
    for owner in ('defaults', 'package', 'project'):
        for named in (False, True):
            p, work, config, state, env, cli = orchestrator_case(
                'runtime-input-' + tool + '-' + owner + '-' + str(named), tool)
            runtime = {'runtime': 'node tools/side-effect.cjs'}
            target = {'cache': False}
            if not named:
                target['inputs'] = [runtime]
            metadata = {'targets': {'type-check': target}}
            if named:
                metadata['namedInputs'] = {'default': ['hashSource'], 'hashSource': ['version'],
                                          'version': [runtime]}
                path = work / 'packages/b/package.json'
                package = json.loads(path.read_text())
                package['scripts'].pop('type-check')
                path.write_text(json.dumps(package))
            if owner == 'defaults':
                (work / 'nx.json').write_text(json.dumps({
                    'targetDefaults': metadata['targets'],
                    **({'namedInputs': metadata['namedInputs']} if named else {})}))
            elif owner == 'package':
                path = work / 'packages/b/package.json'
                package = json.loads(path.read_text())
                package['nx'] = metadata
                path.write_text(json.dumps(package))
            else:
                (work / 'packages/b/project.json').write_text(json.dumps(metadata))
            run_target_side_effect(work, env, cli, args, state, 'version.json')
        for policy in ('cache', 'outputs', 'options'):
            if owner == 'defaults' and policy == 'options':
                continue
            p, work, config, state, env, cli = orchestrator_case(
                'noop-policy-' + tool + '-' + owner + '-' + policy, tool)
            path = work / 'packages/b/package.json'
            package = json.loads(path.read_text())
            package['scripts'].pop('type-check')
            target = {'cache': False, 'dependsOn': ['typecheck'],
                      policy: {'cache': True, 'outputs': ['noop-output.txt'],
                               'options': {'cwd': 'packages/b'}}[policy]}
            for directory in (work / 'packages/a', work / 'packages/b'):
                package_path = directory / 'package.json'
                current = package if directory.name == 'b' else json.loads(package_path.read_text())
                current['scripts']['typecheck'] = 'tsc --noEmit'
                if owner == 'package' and directory.name == 'b':
                    current['nx'] = {'targets': {'type-check': target}}
                package_path.write_text(json.dumps(current))
            nx = json.loads((work / 'nx.json').read_text())
            nx['targetDefaults']['typecheck'] = {'cache': False}
            if owner == 'defaults':
                nx['targetDefaults']['type-check'] = target
                path = work / 'packages/a/package.json'
                package_a = json.loads(path.read_text())
                package_a['nx'] = {'targets': {'type-check': {'cache': False, 'outputs': [],
                                                            'options': {}, 'dependsOn': []}}}
                path.write_text(json.dumps(package_a))
            elif owner == 'project':
                (work / 'packages/b/project.json').write_text(json.dumps({'targets': {'type-check': target}}))
            (work / 'nx.json').write_text(json.dumps(nx))
            run_target_side_effect(work, env, cli, args, state, 'noop-output.txt')
print('ok - Nx and Lerna keep hashing inputs and scriptless cache/output/option side effects local for every metadata owner')

for name in ('untracked', 'local-only', 'unavailable', 'no-task', 'undeclared', 'outputs',
             'hooks', 'dependency', 'no-proof', 'remote-exit'):
    p, work, config, state, env, cli = orchestrator_case('whole-' + name)
    if name == 'untracked':
        (work / 'forgotten.ts').write_text('untracked input')
    elif name == 'local-only':
        record_path = Path(env['FM_BUILD_LOCK_INSTALL_DIR']) / 'boat-route'
        loaded = json.loads(record_path.read_text())
        loaded['projects']['smokeproj']['local_only'] = ['tsc']
        record_path.write_text(json.dumps(loaded))
    elif name == 'unavailable':
        (state / 'fixture.json').write_text('{"remaining":0}')
    elif name == 'no-task':
        env.pop('FM_TASK_ID')
    elif name == 'undeclared':
        record_path = Path(env['FM_BUILD_LOCK_INSTALL_DIR']) / 'boat-route'
        loaded = json.loads(record_path.read_text()); loaded['projects'] = {}
        record_path.write_text(json.dumps(loaded))
    elif name in ('outputs', 'dependency'):
        graph = json.loads((work / 'turbo.json').read_text())
        if name == 'outputs':
            graph['tasks']['type-check']['outputs'] = ['dist/**']
        else:
            graph['tasks']['type-check']['dependsOn'] = ['^build']
        (work / 'turbo.json').write_text(json.dumps(graph))
    elif name == 'hooks':
        target = work / 'packages/a/package.json'
        data = json.loads(target.read_text()); data['scripts']['pretype-check'] = 'touch hook-output'
        target.write_text(json.dumps(data))
    elif name == 'no-proof':
        (work / 'packages/a/tsconfig.json').write_text('{"compilerOptions":{}}')
    elif name == 'remote-exit':
        child = work / 'tools/tsc'
        child.write_text(child.read_text() + "\nif (process.env.FM_HEAVY_ORCHESTRATOR === 'remote') process.exit(3);\n")
    r = orchestration_run(work, env, cli, ['type-check'])
    if name == 'remote-exit':
        assert r.returncode == 3 and starts(state) == 1, (name, r.stdout, r.stderr)
        assert 'running locally' not in r.stderr, r.stderr
        continue
    assert r.returncode == 0 and starts(state) == 0, (name, r.stdout, r.stderr)
    if name == 'unavailable':
        calls = [json.loads(line) for line in (state / 'calls.jsonl').read_text().splitlines()]
        assert sum(call[0] == 'limits' for call in calls) == 1, calls
    if name not in ('no-task', 'undeclared'):
        assert r.stderr.count('running locally in a heavy slot') == 1, (name, r.stderr)
        assert r.stdout.count('child marker=local held=') == 2, (name, r.stdout)
    else:
        assert 'orchestrator on Boat' not in r.stderr, (name, r.stderr)
        assert 'parent held=\n' in r.stdout, (name, r.stdout)
print('ok - source/local-only/output/hook/config guards and unavailable fallback apply to the whole run; non-workers stay untouched')

p, work, config, state, env = case('remote-shape', declaration=DECLARED)
assert publish(config, env).returncode == 0
r = run(work / 'deep', env, command=('bash', '-c', 'true'))
assert r.returncode == 0, r.stderr
assert '\ncd deep\n' in remote_script(state), remote_script(state)

p, work, config, state, env = case('remote-argv', declaration=DECLARED)
assert publish(config, env).returncode == 0
preload = Path(env['FM_BUILD_LOCK_INSTALL_DIR']) / 'fm-build-lock.js'
r = run(work, env, command=(
    'echo', '--require=' + str(preload), '--root=' + str(work),
    '--dir=' + str(work / 'deep'), 'tracked.txt'))
script = remote_script(state)
assert '\nexec echo ' in script, script
assert 'fm-build-lock.js' not in script, script
assert '--root=/home/user/fm-job/source' in script, script
assert '--dir=/home/user/fm-job/source/deep' in script, script
assert ' tracked.txt' in script, script
assert str(work) not in script, script
assert 'echo bootstrapped' in script, script
print('ok - the remote command keeps the cwd and the real flags, drops the preload, '
      'and rewrites worktree paths')

for flag in ('--root', '--dir'):
    for spelling in ('separate', 'equals'):
        for subdir in ('', 'deep'):
            p, work, config, state, env = case(
                flag[2:] + '-' + spelling + '-' + (subdir or 'root'), declaration=DECLARED)
            assert publish(config, env).returncode == 0
            target = str(work / subdir)
            args = (flag, target) if spelling == 'separate' else (flag + '=' + target,)
            check = ('from pathlib import Path; import sys; '
                     'value = sys.argv[-1].split("=", 1)[-1]; '
                     'assert Path(value) == Path.cwd() / sys.argv[1]; '
                     'assert (Path(value) / sys.argv[2]).is_file(); print("checked remote path")')
            r = run(work, env, command=(sys.executable, '-c', check, './' + subdir,
                    'nested.txt' if subdir else 'tracked.txt', *args))
            assert r.returncode == 0 and called(state), (args, r.stdout, r.stderr)
            assert 'checked remote path' in r.stdout, r.stdout
            assert 'running locally' not in r.stderr, r.stderr
print('ok - root and descendant paths resolve remotely with either option spelling')

for name, bootstrap in (('failed', 'false'), ('exited', 'exit 0'),
                         ('bad-directory', 'mv deep elsewhere')):
    p, work, config, state, env = case('setup-' + name,
        declaration="smokeproj bootstrap=" + shlex.quote(bootstrap) + "\n")
    assert publish(config, env).returncode == 0
    r = run(work, env, cwd=work / 'deep')
    assert r.returncode == 0 and called(state), (name, r.returncode, r.stderr)
    assert not r.stdout.endswith('held=\n'), (name, r.stdout)
    assert 'setup did not dispatch' in r.stderr, (name, r.stderr)
print('ok - failed bootstrap, early exit and missing command cwd fall back locally')

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
    probes = p / 'probes.log'
    cli = commit_cli(work, "if (process.argv.includes('--showConfig')) {"
                     " require('fs').appendFileSync(%r, (process.env.FM_BUILD_LOCK_BYPASS || '')"
                     " + '\\n'); console.log(JSON.stringify({compilerOptions: {noEmit: true}}));"
                     " } else console.log('ran tsc held=' + "
                     "(process.env.FM_BUILD_LOCK_HELD || ''));\n" % str(probes))
    option = subprocess.run([str(repo / 'bin/fm-build-lock.py'), 'node-option'], env=env,
                            capture_output=True, text=True, check=True).stdout.strip()
    assert publish(config, env).returncode == 0
    routed = dict(env, NODE_OPTIONS=option)
    r = subprocess.run([node, str(cli)], env=routed, cwd=str(work),
                       capture_output=True, text=True, timeout=120)
    assert r.returncode == 0, (r.stdout, r.stderr)
    assert called(state), r.stderr
    assert 'ran tsc held=\n' in r.stdout, r.stdout
    assert r.stderr.count('tsc on Boat') == 1, r.stderr
    assert probes.read_text() == '1\n', 'the noEmit probe must run once, outside the preload'
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
