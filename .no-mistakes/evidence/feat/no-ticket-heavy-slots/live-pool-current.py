import os, subprocess, sys, time, pathlib, signal
r=pathlib.Path.cwd(); s=r/'.test-phase-current'; w=r/'bin/fm-build-lock.py'
e=dict(os.environ,FM_BUILD_LOCK_FILE=str(s/'pool.lock'),FM_BUILD_LOCK_INSTALL_DIR=str(s/'install'),FM_HEAVY_SLOTS='1')
for k in ('FM_BUILD_LOCK_HELD','FM_BUILD_LOCK_BYPASS','NODE_OPTIONS'): e.pop(k,None)
children=[]
def start(n):
 p=subprocess.Popen([str(w),'--',sys.executable,'-c','import pathlib,sys,time;pathlib.Path(sys.argv[1]).touch();time.sleep(30)',str(s/n)],env=e,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True);children.append(p);return p
def wait(n):
 end=time.monotonic()+8
 while not (s/n).exists():
  assert time.monotonic()<end, n+' never entered'
  time.sleep(.05)
try:
 a=start('A');wait('A');b=start('B');time.sleep(.6)
 assert not (s/'B').exists() and b.poll() is None
 print('Pool size 1: A entered; B stayed queued while A owned the slot.',flush=True)
 a.kill();a.wait();wait('B')
 print('SIGKILL of A released its slot; queued B entered.',flush=True)
 b.terminate();b.wait()
 e['FM_HEAVY_SLOTS']='2';a=start('C');b=start('D');wait('C');wait('D');c=start('E');time.sleep(.6)
 assert not (s/'E').exists() and c.poll() is None
 print('Pool size 2: C and D entered concurrently; E stayed queued.',flush=True)
 a.terminate();a.wait();wait('E')
 print('Releasing C admitted E while D remained running.',flush=True)
finally:
 for p in children:
  if p.poll() is None:p.kill()
  out,err=p.communicate()
  if err: print(err.strip(),flush=True)
print('All child exit statuses collected; isolated slot holders stopped.',flush=True)
