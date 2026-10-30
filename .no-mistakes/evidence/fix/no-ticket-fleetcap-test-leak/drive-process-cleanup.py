import os, pathlib, signal, subprocess, time, json
root = pathlib.Path.cwd()
scratch = root / '.test-phase-scratch'
env = dict(os.environ, FM_TEST_SCRATCH_ROOT=str(scratch), TMPDIR=str(scratch), GIT_CEILING_DIRECTORIES=str(scratch))
def processes():
    return [dict(zip(('pid','ppid','pgid','stat','comm'), line.split(None,4))) for line in subprocess.check_output(['ps','-axo','pid=,ppid=,pgid=,stat=,comm='],text=True).splitlines()]
def live(rows, groups):
    return [r for r in rows if int(r['pgid']) in groups and not r['stat'].startswith('Z')]
marker = scratch / 'outer-timeout-marker'
script = r'''
. tests/fm-fleet-capacity.test.sh
checkpoint() {
  printf '%s\n%s\n' "$BASHPID" "$case_dir" > "$PWD/.test-phase-scratch/outer-timeout-marker"
  while :; do sleep 0.1; done
}
test_adaptive_concurrent_homes checkpoint
'''
p = subprocess.Popen(['bash','-c',script],env=env,start_new_session=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
groups = {p.pid}
try:
    deadline = time.monotonic()+30
    while not marker.exists():
        assert p.poll() is None and time.monotonic()<deadline, 'checkpoint not reached'
        time.sleep(.05)
    owner, case = marker.read_text().splitlines()
    deadline = time.monotonic()+5
    while time.monotonic()<deadline:
        rows=processes(); descendants={int(owner)}
        while True:
            found={int(r['pid']) for r in rows if int(r['ppid']) in descendants}
            if found <= descendants: break
            descendants |= found
        groups |= {int(r['pgid']) for r in rows if int(r['pid']) in descendants}
        if len(groups)==3: break
        time.sleep(.05)
    assert len(groups)==3, groups
    print(json.dumps({'scenario':'outer runner timeout kills entire suite group','before':live(rows,groups)}),flush=True)
    start=time.monotonic()
    os.killpg(p.pid, signal.SIGTERM)
    out,err=p.communicate(timeout=10)
    deadline=time.monotonic()+5
    while live(processes(),groups) and time.monotonic()<deadline: time.sleep(.05)
    survivors=live(processes(),groups)
    print(json.dumps({'exit':p.returncode,'elapsed_seconds':round(time.monotonic()-start,3),'survivors':survivors,'stdout':out,'stderr':err}),flush=True)
    assert p.returncode in (-15,143) and not survivors
finally:
    for group in groups:
        try: os.killpg(group,signal.SIGKILL)
        except ProcessLookupError: pass
    p.communicate()

for function in ('fm_lock_acquire_wait','fm_lock_acquire_wait_max'):
    for mode in ('deleted-parent','released-lock','initially-missing-parent'):
        parent=scratch / (function+'-'+mode)
        lock=parent/'lock'
        if mode != 'initially-missing-parent':
            lock.mkdir(parents=True)
            (lock/'pid').write_text(str(os.getpid())+'\n')
        command='. bin/fm-wake-lib.sh; "$1" "$2" 120; rc=$?; printf "waiter_return=%s\\n" "$rc"; exit "$rc"'
        p=subprocess.Popen(['bash','-c',command,'_',function,str(lock)],env=env,start_new_session=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
        try:
            if mode != 'initially-missing-parent':
                time.sleep(.3)
                assert p.poll() is None, 'waiter did not respect live owner'
                (lock/'pid').unlink(); lock.rmdir()
                if mode=='deleted-parent': parent.rmdir()
            start=time.monotonic()
            out,err=p.communicate(timeout=3)
            expected=0 if mode=='released-lock' else 1
            print(json.dumps({'function':function,'scenario':mode,'exit':p.returncode,'expected_exit':expected,'elapsed_seconds':round(time.monotonic()-start,3),'stdout':out,'stderr':err}),flush=True)
            assert p.returncode==expected
        finally:
            if p.poll() is None: os.killpg(p.pid,signal.SIGKILL)
            p.communicate()
