import os, pathlib, subprocess, sys, tempfile, json, time, resource
root=pathlib.Path.cwd()
ev=pathlib.Path('~/.no-mistakes/evidence/01M6CKMJTR75XFWT49Q5D3ZW0F')
with tempfile.TemporaryDirectory(prefix='test-phase-',dir=root/'state') as scratch:
 p=pathlib.Path(scratch)
 env=dict(os.environ,FM_BUILD_LOCK_FILE=str(p/'pool.lock'),FM_BUILD_LOCK_INSTALL_DIR=str(p/'installed'),FM_HEAVY_SLOTS='1',FM_TEST_SCRATCH_ROOT=str(p),TMPDIR=str(p))
 for key in ['FM_BUILD_LOCK_HELD','FM_BUILD_LOCK_BYPASS','NODE_OPTIONS','FM_LINT_ROOT_MEMORY_KIB','FM_LINT_JOBS','FM_MEMCAP_ARGV_UNSET']:
  env.pop(key,None)
 cap=str(root/'bin/fm-memcap.sh'); lock=str(root/'bin/fm-build-lock.py')
 def run(args,**kw):
  r=subprocess.run(args,env=env,capture_output=True,text=True,timeout=25,**kw)
  print('COMMAND',repr(args)); print('EXIT',r.returncode,'STDOUT',r.stdout.strip(),'STDERR',r.stderr.strip(),flush=True)
  return r
 mech=run([cap,'--mechanism']).stdout.strip()
 assert mech in ['rlimit','cgroup'],mech
 args=['','two words','${FM_MEMCAP_ARGV_UNSET}','$HOME','*','a"b']
 for prefix in [[cap,'--bytes','134217728','--'],[cap,'--exec','--bytes','134217728','--'],[lock,'--']]:
  r=run(prefix+[sys.executable,'-c','import sys,json; print(json.dumps(sys.argv[1:]))']+args)
  assert r.returncode==0 and json.loads(r.stdout)==args
  r=run(prefix+['/bin/sh','-c','v=inner; printf "%s" "${v}"'])
  assert r.returncode==0 and r.stdout=='inner'
 r=run([cap,'--bytes','67108864','--',sys.executable,'-c','a=bytearray(128*1024*1024); print("UNBOUNDED")'])
 assert r.returncode!=0 and 'UNBOUNDED' not in r.stdout
 print('SCENARIO runaway cannot allocate 128 MiB under 64 MiB cap: PASS',flush=True)
 for slots in [1,2]:
  env['FM_HEAVY_SLOTS']=str(slots)
  budget=int(run([cap,'--effective-bytes','--share',str(slots)]).stdout)
  probe='import os,resource,json; print(json.dumps(dict(pid=os.getpid(),held=os.environ["FM_BUILD_LOCK_HELD"],limit=resource.getrlimit(resource.RLIMIT_AS)[0])))'
  if mech=='rlimit':
   r=run([lock,'--',lock,'--',sys.executable,'-c',probe])
   d=json.loads(r.stdout); assert r.returncode==0 and d['limit']==budget and str(d['pid'])==d['held']
 env['FM_HEAVY_SLOTS']='1'
 if mech=='rlimit':
  def restrict(): resource.setrlimit(resource.RLIMIT_AS,(100663296,100663296))
  r=run([cap,'--bytes','268435456','--',sys.executable,'-c','import resource; print(resource.getrlimit(resource.RLIMIT_AS)[0])'],preexec_fn=restrict)
  assert r.returncode==0 and int(r.stdout)==100663296
 print('SCENARIO nested wrapper retains identity and finite bound; inherited ceiling respected: PASS',flush=True)
 holder=subprocess.Popen([lock,'--',sys.executable,'-c','import pathlib,sys,time; pathlib.Path(sys.argv[1]).touch(); time.sleep(3)',str(p/'ready')],env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
 try:
  until=time.monotonic()+10
  while not (p/'ready').exists():
   assert time.monotonic()<until
   time.sleep(.03)
  t=time.monotonic()
  r=run([lock,'--','/bin/sh','-c','printf acquired; exit 7'])
  assert r.returncode==7 and r.stdout=='acquired' and 'waiting for a heavy slot' in r.stderr and time.monotonic()-t>2
  assert holder.wait(10)==0
 finally:
  if holder.poll() is None: holder.kill()
  holder.communicate()
 r=run([lock,'--','/bin/sh','-c','printf released'])
 assert r.returncode==0 and r.stdout=='released'
 print('SCENARIO contention waits visibly, status 7 propagates, exited holder releases slot: PASS',flush=True)
print('ALL LIVE WRAPPER SCENARIOS PASSED')
