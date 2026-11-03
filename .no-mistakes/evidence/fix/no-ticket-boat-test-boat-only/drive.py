import os, pathlib, tempfile, subprocess, json, time, shutil
repo=pathlib.Path.cwd()
ev=pathlib.Path('~/.no-mistakes/evidence/01M6FF2VKA9VJAAGBZQDZC90Y0')
root=pathlib.Path(tempfile.mkdtemp(prefix='.boat-live-',dir=repo))
try:
 for name,cap,fallback,wait,retry in [('missing-key',False,'0','3','1'),('pending-cap',True,'0','3','1'),('zero-wait',False,'0','0','1'),('capped-backoff',False,'0','1','60'),('default-fallback',False,None,'3','1'),('invalid-bound',False,'0','bad','1')]:
  case=root/name; work=case/'work'; work.mkdir(parents=True)
  subprocess.run(['git','init','-q',str(work)],check=True)
  subprocess.run(['git','-C',str(work),'-c','user.name=Test','-c','user.email=test@example.invalid','commit','--allow-empty','-qm','Disposable source'],check=True)
  home=case/'home'; home.mkdir()
  user=case/'user'; user.mkdir()
  if cap:
   jobs=home/'state/boat-offload/jobs'; jobs.mkdir(parents=True)
   for i in range(2): (jobs/f'reserved-{i}.json').write_text(json.dumps({'cleanup':'pending'}))
  env=dict(os.environ,HOME=str(user),FM_HOME=str(home),FM_BUILD_LOCK_FILE=str(case/'heavy.lock'),FM_BOAT_TEST_TIMEOUT='1500',FM_BOAT_TEST_UNAVAILABLE_WAIT_SECS=wait,FM_BOAT_TEST_UNAVAILABLE_RETRY_SECS=retry)
  for k in ('FM_BOAT_TYPE','FM_BOAT_TEST_HISTORY_DEPTH','FM_BUILD_LOCK_HELD','FM_BUILD_LOCK_BYPASS','FM_BOAT_TEST_LOCAL_FALLBACK'): env.pop(k,None)
  if fallback is not None: env['FM_BOAT_TEST_LOCAL_FALLBACK']=fallback
  start=time.monotonic()
  p=subprocess.run(['bash',str(repo/'bin/fm-boat-test-wrapper.sh'),'printf "LOCAL EXECUTION\\n"; touch local-ran'],cwd=work,env=env,capture_output=True,text=True,timeout=15)
  elapsed=time.monotonic()-start
  results=[json.loads(f.read_text()) for f in sorted((case/'.fm-test-scratch').glob('fm-boat-test.*/boat-*/result.json'))]
  record={'scenario':name,'exit':p.returncode,'elapsed_seconds':round(elapsed,3),'local_command_executed':(work/'local-ran').exists(),'heavy_lock_created':(case/'heavy.lock').exists(),'adapter_results':results,'stdout':p.stdout,'stderr':p.stderr}
  (ev/f'{name}.json').write_text(json.dumps(record,indent=2)+'\n')
  print(name,p.returncode,round(elapsed,3),'attempts',len(results),'local',record['local_command_executed'],flush=True)
  if name=='invalid-bound': assert p.returncode==2 and not results
  elif name=='default-fallback': assert p.returncode==0 and record['local_command_executed'] and record['heavy_lock_created']
  else:
   assert p.returncode==(75 if cap else 69)
   assert not record['local_command_executed'] and not record['heavy_lock_created']
   assert all(r['kind']=='unavailable' for r in results)
   assert elapsed<8
   if name in ('missing-key','pending-cap'): assert len(results)>=2
   else: assert len(results)==1
finally:
 shutil.rmtree(root)
