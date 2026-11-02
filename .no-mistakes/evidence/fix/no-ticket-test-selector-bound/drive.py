import json, os, pathlib, subprocess, tempfile, time, shutil

ROOT = pathlib.Path('~/.no-mistakes/worktrees/c0c4fcacb05a/01M6EWD6SAHZXB5H9JHBR6RVEN')
EVIDENCE = pathlib.Path(__file__).parent
scratch = pathlib.Path(tempfile.mkdtemp(prefix='.nm-test-live-', dir=ROOT))
probe = ROOT / 'tests/fm-nm-disposable-budget-probe.test.sh'
env = os.environ.copy()
env.update(FM_TEST_SCRATCH_ROOT=str(scratch), TMPDIR=str(scratch), TMP=str(scratch),
           FM_BUILD_LOCK_FILE=str(scratch / 'heavy.lock'), FM_HEAVY_SLOTS='1',
           FM_BUILD_LOCK_INSTALL_DIR=str(scratch / 'installed'))
env.pop('FM_BUILD_LOCK_BYPASS', None)
env.pop('FM_BUILD_LOCK_HELD', None)
env.pop('NODE_OPTIONS', None)
log = open(EVIDENCE / 'live-transcript.txt', 'w', buffering=1)

def run(label, argv, overrides=None, expected=0, timeout=60):
    start = time.monotonic()
    result = subprocess.run(argv, cwd=ROOT, env=env | (overrides or {}),
                            text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            timeout=timeout)
    elapsed = time.monotonic() - start
    log.write(f'\n### {label}\nargv={json.dumps(argv)}\n{result.stdout}\nexit={result.returncode}; elapsed_s={elapsed:.3f}\n')
    assert result.returncode == expected, (label, result.returncode, result.stdout)
    return result.stdout, elapsed

def scope(label, paths):
    changed = scratch / 'paths'
    changed.write_text('\n'.join(paths) + '\n')
    out, _ = run(label, ['bash', 'bin/fm-ci-change-scope.sh', '--local'],
                 {'FM_CI_EVENT': 'pull_request', 'FM_CI_CHANGED_PATHS_FILE': str(changed)})
    return dict(line.split('=', 1) for line in out.splitlines() if '=' in line)

def weight(paths):
    out, _ = run('Real runner timing hints for selected paths',
                 ['bash', 'bin/fm-test-run.sh', '--list-weighted', *paths])
    return sum(int(line.split('\t')[0]) for line in out.splitlines())

holder = None
try:
    config = json.loads(subprocess.check_output(['ruby', '-ryaml', '-rjson', '-e',
        'puts JSON.generate(YAML.load_file(ARGV[0]))', '.no-mistakes.yaml'], cwd=ROOT, text=True))
    assert not config.get('test', {}).get('allow_approve_over_failure', False)
    log.write('Typed YAML: test.allow_approve_over_failure is not enabled.\n')
    command = config['commands']['test']
    seat = scope('Reported PR 205 path set', ['bin/fm-seat-lib.sh', 'bin/fm-seat.sh',
        'bin/fm-spawn.sh', 'docs/claude-seats.md', 'tests/fm-seat.test.sh'])
    selected, deferred = seat['local_scripts'].split(), seat['local_deferred'].split()
    modeled = weight(selected)
    assert int(seat['local_budget_ms']) == 150000 and modeled <= 150000
    assert 'tests/fm-seat.test.sh' in deferred
    assert not set(selected) & set(deferred)
    log.write(f'PR205 selected={len(selected)}; deferred={len(deferred)}; modeled_ms={modeled}; execution_bound_s=900\n')

    narrow = scope('Adversarial mixed cheap, expensive, and live paths', [
        'tests/fm-quota-choose.test.sh', 'tests/fm-seat.test.sh',
        'tests/fm-backend-herdr-smoke.test.sh'])
    assert narrow['local_scripts'] == 'tests/fm-quota-choose.test.sh'
    assert {'tests/fm-seat.test.sh', 'tests/fm-backend-herdr-smoke.test.sh'} <= set(narrow['local_deferred'].split())
    full = scope('Shared scaffolding retains full scope but bounded local coverage', ['tests/lib.sh'])
    assert full['full'] == 'true'
    assert weight(full['local_scripts'].split()) <= 150000
    assert {'tests/fm-seat.test.sh', 'tests/fm-backend-herdr-smoke.test.sh',
            'tests/fm-supervision-host-live-e2e.test.sh'} <= set(full['local_deferred'].split())

    # The test script is disposable input to the real runner, not a runner stub.
    probe.write_text('printf "probe execution started\\n"\nsleep "${PROBE_SLEEP:-0}"\nprintf "probe execution finished\\n"\nexit "${PROBE_RC:-0}"\n')
    changed = scratch / 'probe-paths'
    changed.write_text(str(probe.relative_to(ROOT)) + '\n')
    probeenv = {'FM_CI_CHANGED_PATHS_FILE': str(changed)}
    # Hold a private real slot, with a handshake proving acquisition.
    ready = scratch / 'slot-held'
    holder = subprocess.Popen(['bin/fm-build-lock.py', '--', 'bash', '-c',
        'touch "$1"; sleep 7', 'hold', str(ready)], cwd=ROOT, env=env,
        stdout=log, stderr=log)
    end = time.monotonic() + 10
    while not ready.exists():
        assert holder.poll() is None and time.monotonic() < end
        time.sleep(.05)
    out, elapsed = run('Unmodified configured Test command queues then executes the real selector and runner',
        ['bash', '-c', command], probeenv | {'PROBE_SLEEP': '1'})
    assert 'probe execution finished' in out and elapsed >= 7
    assert holder.wait(timeout=5) == 0
    holder = None
    run('Unmodified configured command propagates a failing real test',
        ['bash', '-c', command], probeenv | {'PROBE_RC': '7'}, expected=1)

    out, elapsed = run('Real bounded runner terminates a hung test and releases its slot',
        ['bin/fm-build-lock.py', '--', 'bash', '-c',
         '. bin/fm-timeout-lib.sh; fm_exec_timed 2 1 bash bin/fm-test-run.sh --per-script-timeout-secs 1500 "$1"',
         'timeout-probe', str(probe.relative_to(ROOT))], {'PROBE_SLEEP': '30'}, expected=124)
    assert 'probe execution started' in out and 'probe execution finished' not in out and elapsed < 10
    run('Slot is reusable after deadline termination',
        ['bin/fm-build-lock.py', '--', 'bash', '-c', 'printf "slot reacquired after timeout\\n"'])
    log.write('\nAll targeted live checks completed successfully. No deferred suite executed.\n')
finally:
    if holder is not None:
        holder.wait(timeout=15)
    probe.unlink(missing_ok=True)
    shutil.rmtree(scratch)
    log.close()
