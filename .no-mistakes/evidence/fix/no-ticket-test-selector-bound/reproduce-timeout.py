import os, pathlib, shutil, subprocess, tempfile, time

root = pathlib.Path('~/.no-mistakes/worktrees/c0c4fcacb05a/01M6EWD6SAHZXB5H9JHBR6RVEN')
evidence = pathlib.Path(__file__).parent
scratch = pathlib.Path(tempfile.mkdtemp(prefix='.nm-timeout-proof-', dir=root))
probe = scratch / 'hang.test.sh'
probe.write_text('printf "test started\\n"\nsleep 8\nprintf "test survived outer deadline\\n"\n')
env = os.environ.copy()
env.update(FM_TEST_SCRATCH_ROOT=str(scratch), TMPDIR=str(scratch), TMP=str(scratch),
           FM_BUILD_LOCK_FILE=str(scratch / 'heavy.lock'), FM_HEAVY_SLOTS='1')
for key in ['FM_BUILD_LOCK_BYPASS', 'FM_BUILD_LOCK_HELD', 'NODE_OPTIONS']:
    env.pop(key, None)
try:
    with open(evidence / 'timeout-slot-transcript.txt', 'w', buffering=1) as log:
        start = time.monotonic()
        child = subprocess.run(['bin/fm-build-lock.py', '--', 'bash', '-c',
            '. bin/fm-timeout-lib.sh; fm_exec_timed 2 1 bash bin/fm-test-run.sh --per-script-timeout-secs 1500 "$1"',
            'deadline', str(probe)], cwd=root, env=env, stdout=log, stderr=log, timeout=15)
        elapsed = time.monotonic() - start
        log.write(f'Outer runner exited {child.returncode} after {elapsed:.3f}s (deadline 2s).\n')
        assert child.returncode == 124 and elapsed < 6
        start = time.monotonic()
        result = subprocess.run(['bin/fm-build-lock.py', '--', 'bash', '-c',
            'printf "next command acquired slot\\n"'], cwd=root, env=env,
            stdout=log, stderr=log, timeout=15)
        waited = time.monotonic() - start
        log.write(f'Next command exit={result.returncode}; slot wait={waited:.3f}s after the timeout had returned.\n')
        assert result.returncode == 0 and waited > 4
        log.write('Confirmed: a test survives the outer deadline and retains the heavy slot until its own exit.\n')
        log.write('\nCounterfactual: disable only the nested per-script watchdog.\n')
        start = time.monotonic()
        child = subprocess.run(['bin/fm-build-lock.py', '--', 'bash', '-c',
            '. bin/fm-timeout-lib.sh; fm_exec_timed 2 1 bash bin/fm-test-run.sh --per-script-timeout-secs 0 "$1"',
            'deadline', str(probe)], cwd=root, env=env, stdout=log, stderr=log, timeout=15)
        assert child.returncode == 124
        result = subprocess.run(['bin/fm-build-lock.py', '--', 'bash', '-c',
            'printf "counterfactual slot reacquired\\n"'], cwd=root, env=env,
            stdout=log, stderr=log, timeout=15)
        elapsed = time.monotonic() - start
        log.write(f'Counterfactual outer timeout plus slot reacquisition elapsed={elapsed:.3f}s; exit={result.returncode}.\n')
        assert result.returncode == 0 and elapsed < 6
finally:
    shutil.rmtree(scratch)
