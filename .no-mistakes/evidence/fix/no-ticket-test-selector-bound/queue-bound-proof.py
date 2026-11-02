import os, pathlib, subprocess, tempfile, shutil, time
root=pathlib.Path.cwd()
scratch=pathlib.Path(tempfile.mkdtemp(prefix=".nm-queue-proof-",dir=root))
env=os.environ.copy()
env.update(FM_BUILD_LOCK_FILE=str(scratch/"heavy.lock"),FM_HEAVY_SLOTS="1",TMPDIR=str(scratch),FM_TEST_SCRATCH_ROOT=str(scratch))
for key in ("FM_BUILD_LOCK_BYPASS","FM_BUILD_LOCK_HELD","NODE_OPTIONS"): env.pop(key,None)
try:
 with open(pathlib.Path(__file__).parent/"queue-bound-transcript.txt","w",buffering=1) as log:
  probe=scratch/"success.test.sh"
  probe.write_text('printf "queued test executed successfully\\n"\nsleep .2\n')
  ready=scratch/"ready"
  holder=subprocess.Popen(["bin/fm-build-lock.py","--","bash","-c",'touch "$1"; sleep 5',"hold",str(ready)],env=env,stdout=log,stderr=log)
  try:
   until=time.monotonic()+5
   while not ready.exists():
    assert holder.poll() is None and time.monotonic()<until
    time.sleep(.05)
   start=time.monotonic()
   child=subprocess.run(["bin/fm-build-lock.py","--","bash","-c",'. bin/fm-timeout-lib.sh; fm_exec_timed 2 1 bash bin/fm-test-run.sh "$1"',"queue",str(probe)],env=env,stdout=log,stderr=log,timeout=12)
   elapsed=time.monotonic()-start
   assert holder.wait(timeout=2)==0
   log.write(f"Queued longer than the 2s execution deadline: elapsed={elapsed:.3f}s, exit={child.returncode}.\n")
   assert child.returncode==0 and elapsed>=4.5
  finally:
   if holder.poll() is None: holder.terminate(); holder.wait(timeout=3)
finally: shutil.rmtree(scratch)
