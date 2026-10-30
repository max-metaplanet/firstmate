import os, pathlib, signal, subprocess, time, json
root = pathlib.Path.cwd()
scratch = root / '.test-phase-scratch'
env = dict(os.environ, FM_TEST_SCRATCH_ROOT=str(scratch), TMPDIR=str(scratch), GIT_CEILING_DIRECTORIES=str(scratch))
def processes():
    return [dict(zip(('pid','ppid','pgid','stat','comm'), line.split(None,4))) for line in subprocess.check_output(['ps','-axo','pid=,ppid=,pgid=,stat=,comm='],text=True).splitlines()]
def live(rows, groups):
    return [r for r in rows if int(r['pgid']) in groups and not r['stat'].startswith('Z')]
marker = scratch / 'actual-deadline-marker-v2'
script = r'''
. tests/fm-fleet-capacity.test.sh
checkpoint() {
  printf '%s\n%s\n' "$BASHPID" "$case_dir" > "$PWD/.test-phase-scratch/actual-deadline-marker-v2"
  while :; do sleep 0.1; done
}
test_adaptive_concurrent_homes checkpoint
'''
p = subprocess.Popen(['bash','-c','. bin/fm-timeout-lib.sh; fm_exec_timed 12 2 bash -c "$1"', '_', script],env=env,start_new_session=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
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
        if len(groups)>=4: break
        time.sleep(.05)
    assert len(groups)>=4, groups
    print(json.dumps({'scenario':'real twelve-second runner deadline reaps entire fixture','before':live(rows,groups)}),flush=True)
    start=time.monotonic()
    out,err=p.communicate(timeout=20)
    deadline=time.monotonic()+5
    while live(processes(),groups) and time.monotonic()<deadline: time.sleep(.05)
    survivors=live(processes(),groups)
    print(json.dumps({'exit':p.returncode,'elapsed_seconds':round(time.monotonic()-start,3),'survivors':survivors,'stdout':out,'stderr':err}),flush=True)
    assert p.returncode == 124 and not survivors
finally:
    for group in groups:
        try: os.killpg(group,signal.SIGKILL)
        except ProcessLookupError: pass
    p.communicate()

