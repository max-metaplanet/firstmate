import os,pathlib,subprocess,sys,tempfile,time,json,shutil
root=pathlib.Path.cwd(); wrapper=str(root/'bin/fm-build-lock.py'); cap=str(root/'bin/fm-memcap.sh')
with tempfile.TemporaryDirectory(dir=root/'state',prefix='test-nested-') as scratch:
 p=pathlib.Path(scratch)
 env=dict(os.environ,FM_BUILD_LOCK_FILE=str(p/'pool'),FM_BUILD_LOCK_INSTALL_DIR=str(p/'installed'),FM_TEST_SCRATCH_ROOT=str(p),FM_HEAVY_SLOTS='1',TMPDIR=str(p))
 for k in ['FM_BUILD_LOCK_HELD','FM_BUILD_LOCK_BYPASS','NODE_OPTIONS','FM_LINT_ROOT_MEMORY_KIB']: env.pop(k,None)
 probe='''import os,pathlib,json
cgroup=next(x[3:] for x in pathlib.Path('/proc/self/cgroup').read_text().splitlines() if x.startswith('0::'))
print(json.dumps(dict(pid=os.getpid(),held=os.environ['FM_BUILD_LOCK_HELD'],memory_max=int((pathlib.Path('/sys/fs/cgroup')/cgroup.lstrip('/')/'memory.max').read_text()))))
'''
 for slots in [1,2]:
  env['FM_HEAVY_SLOTS']=str(slots)
  budget=int(subprocess.check_output([cap,'--budget-bytes','--share',str(slots)],env=env))
  r=subprocess.run([wrapper,'--',wrapper,'--',sys.executable,'-c',probe],env=env,capture_output=True,text=True,timeout=20)
  print('NESTED',slots,'exit',r.returncode,'observed',r.stdout,'stderr',r.stderr,flush=True)
  assert r.returncode==0
  d=json.loads(r.stdout); assert d['held']==str(d['pid']) and d['memory_max']==budget//os.sysconf('SC_PAGE_SIZE')*os.sysconf('SC_PAGE_SIZE')
 env['FM_HEAVY_SLOTS']='1'
 # Disposable scripts supply workloads; the actual product runner and wrapper execute them.
 repo=p/'repo'; (repo/'bin').mkdir(parents=True); (repo/'tests').mkdir()
 for name in ['fm-test-run.sh','fm-build-lock.py','fm-build-lock.js','fm-memcap.sh']: shutil.copy2(root/'bin'/name,repo/'bin'/name)
 shutil.copy2(root/'tests/git-config-helpers.sh',repo/'tests/git-config-helpers.sh')
 a=repo/'tests/fm-brief.test.sh'; b=repo/'tests/fm-composer-lib.test.sh'
 a.write_text('printf "workload-a\\n"\n'); b.write_text('printf "workload-b\\n"\n')
 holder=subprocess.Popen([wrapper,'--',sys.executable,'-c','import pathlib,sys,time; pathlib.Path(sys.argv[1]).touch(); time.sleep(4)',str(p/'ready')],env=env)
 runner=None
 try:
  deadline=time.monotonic()+10
  while not (p/'ready').exists():
   assert time.monotonic()<deadline
   time.sleep(.03)
  r=subprocess.run(['bash',str(repo/'bin/fm-test-run.sh'),'--jobs','2','--max-wall-ms','2000','--json',str(p/'timing.json'),'tests/fm-brief.test.sh','tests/fm-composer-lib.test.sh'],env=env,capture_output=True,text=True,timeout=35)
  print('RUNNER exit',r.returncode,'stdout',r.stdout,'stderr',r.stderr,flush=True)
  d=json.loads((p/'timing.json').read_text()); print('TIMING',json.dumps(d),flush=True)
  assert r.returncode==1 and d['summary']['duration_ms']>=3500 and d['summary']['failed']==0
  assert holder.wait(10)==0
 finally:
  if holder.poll() is None: holder.kill()
  holder.wait()
print('NESTED CGROUP IDENTITY, SHARED MEMORY CAPS, AND SLOT WAIT BUDGET: PASS')
