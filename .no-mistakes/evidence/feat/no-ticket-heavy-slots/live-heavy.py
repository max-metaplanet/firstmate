import os,sys,subprocess,time
from pathlib import Path
root=Path.cwd(); scratch=root/'.test-phase'; project=scratch/'packages'
wrapper=root/'bin/fm-build-lock.py'
env=dict(os.environ,FM_BUILD_LOCK_FILE=str(scratch/'live.lock'),FM_BUILD_LOCK_INSTALL_DIR=str(scratch/'live-install'),FM_HEAVY_SLOTS='1')
for k in ('NODE_OPTIONS','FM_BUILD_LOCK_HELD','FM_BUILD_LOCK_BYPASS'): env.pop(k,None)
env['NODE_OPTIONS']=subprocess.check_output([str(wrapper),'node-option'],env=env,text=True).strip()
(project/'simple.test.js').write_text("import {test,expect} from 'vitest'; test('isolated live check',()=>expect(2+2).toBe(4));\n")
(project/'simple.spec.js').write_text("const {test,expect}=require('@playwright/test'); test('isolated live check',()=>expect(2+2).toBe(4));\n")
evidence=Path('~/.no-mistakes/evidence/01M64N0N0G8XM8MK440VZDFA4P')
for cli,args in [('vitest',['run','simple.test.js']),('playwright',['test','simple.spec.js','--workers=1','--reporter=line'])]:
 marker=scratch/(cli+'.held'); release=scratch/(cli+'.release')
 holder=subprocess.Popen([str(wrapper),'--',sys.executable,'-c','import pathlib,sys,time; pathlib.Path(sys.argv[1]).touch();\nwhile not pathlib.Path(sys.argv[2]).exists(): time.sleep(.03)',str(marker),str(release)],env=env)
 child=None
 try:
  until=time.monotonic()+10
  while not marker.exists():
   assert time.monotonic()<until
   time.sleep(.03)
  version=subprocess.run([str(project/'node_modules/.bin'/cli),'--version'],env=env,cwd=project,capture_output=True,text=True,timeout=10)
  assert version.returncode==0,version.stderr
  with (evidence/(cli+'-live.log')).open('w') as log:
   log.write(f'Command: node_modules/.bin/{cli} '+ ' '.join(args)+'\nLightweight --version while slot held: '+version.stdout+'\n');log.flush()
   child=subprocess.Popen([str(project/'node_modules/.bin'/cli),*args],env=env,cwd=project,stdout=log,stderr=log)
   until=time.monotonic()+15
   while 'waiting for a heavy slot' not in (evidence/(cli+'-live.log')).read_text():
    assert child.poll() is None,'suite escaped the occupied slot'
    assert time.monotonic()<until,'suite did not queue'
    time.sleep(.03)
   time.sleep(.4)
   assert child.poll() is None
   log.write('Observed: real suite queued behind the only slot. Releasing holder.\n');log.flush()
   release.touch(); assert holder.wait(10)==0
   rc=child.wait(60)
   log.write(f'Final suite exit: {rc}\n')
   assert rc==0
 finally:
  release.touch()
  for p in (child,holder):
   if p is not None and p.poll() is None: p.kill();p.wait()
print('Real Vitest and Playwright .bin CLIs queued, light version commands stayed available, both suites exited 0 after release.')
