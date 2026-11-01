# Adversarial: hold test_adaptive_concurrent_homes at its checkpoint, SIGKILL the
# whole suite process group (no traps can run), delete the scratch root (as the
# no-mistakes worktree teardown did), then watch for surviving fm-spawn.sh.
import os, signal, subprocess, sys, time, shutil
from pathlib import Path
suite, marker = sys.argv[1], Path(sys.argv[2])
script = r'''
. "$1"
marker=$2
checkpoint() {
  case_pid=$(exec sh -c 'printf "%s" "$PPID"')
  printf '%s\n%s\n%s\n' "$case_pid" "$case_dir" "$TMP_ROOT" > "$marker"
  while :; do sleep 0.1; done
}
test_adaptive_concurrent_homes checkpoint
'''
p = subprocess.Popen(['bash', '-c', script, '_', suite, str(marker)], start_new_session=True,
                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
t0 = time.monotonic()
while not marker.exists() or len(marker.read_text().splitlines()) < 3:
    assert p.poll() is None and time.monotonic() - t0 < 60, 'no checkpoint'
    time.sleep(0.05)
case_pid, case_dir, tmp_root = marker.read_text().splitlines()
time.sleep(1.0)
def spawns():
    out = subprocess.check_output(['ps', '-axo', 'pid=,ppid=,pgid=,stat=,pcpu=,etimes=,args='], text=True)
    return [l for l in out.splitlines() if 'fm-spawn.sh' in l and case_dir in l]
before = spawns()
print(f'checkpoint reached; case_dir={case_dir}')
print(f'fm-spawn.sh processes before kill: {len(before)}')
for l in before: print('  ', l.strip()[:200])
os.killpg(p.pid, signal.SIGKILL); p.wait()
shutil.rmtree(tmp_root, ignore_errors=True)
print(f'SIGKILLed suite pgid {p.pid}; deleted scratch root {tmp_root}')
kill_t = time.monotonic()
last = None
while time.monotonic() - kill_t < 120:
    s = spawns()
    if not s:
        last = time.monotonic() - kill_t; break
    time.sleep(1)
if last is None:
    print('FAIL: fm-spawn.sh survivors after 120s:')
    for l in spawns(): print('  ', l.strip()[:200])
    for l in spawns(): os.kill(int(l.split()[0]), signal.SIGKILL)
    sys.exit(1)
print(f'PASS: all fixture fm-spawn.sh processes gone {last:.1f}s after group-kill')
