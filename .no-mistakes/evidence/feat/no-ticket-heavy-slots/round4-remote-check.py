from pathlib import Path
import os, subprocess, json, hashlib, base64, time, signal
os.umask(0o022)
r=Path.cwd(); s=r/'.test-phase-round4'; home=s/'home'; pkg=s/'package'; ev=Path('~/.no-mistakes/evidence/01M64N0N0G8XM8MK440VZDFA4P')
subprocess.run(['bash','bin/fm-lab-home.sh','create',str(home)],check=True,capture_output=True)
text=(r/'tests/fm-extension-binding.test.sh').read_text(); fn=text[text.index('make_package() {'):text.index('\nbind_package() {')]
subprocess.run(['bash','-c',fn+'\nmake_package "$1" org.example.remote ext-remote', 'fixture',str(pkg)],check=True)
def digest(b):return 'sha256:'+hashlib.sha256(b).hexdigest()
def canonical(v):return json.dumps(v,sort_keys=True,separators=(',',':')).encode()
entries=[];payloads=[];tree=hashlib.sha256(b'firstmate-package-tree-v1\0');total=0
for p in sorted(pkg.iterdir()):
 b=p.read_bytes(); executable=bool(p.stat().st_mode&0o111); d=digest(b);total+=len(b)
 tree.update(b'F\0'+p.name.encode()+b'\0'+(b'x\0' if executable else b'-\0')+str(len(b)).encode()+b'\0'+d.encode()+b'\0')
 entries.append(dict(path=p.name,type='file',mode=493 if executable else 420,size=len(b),sha256=d));payloads.append(base64.b64encode(b).decode())
manifest=dict(schema='firstmate.extension-package-transfer-manifest.v1',extension_id='org.example.remote',extension_version='1.2.3',package_digest='sha256:'+tree.hexdigest(),entry_count=len(entries),total_bytes=total,entries=entries)
envelope=dict(schema='firstmate.extension-package-transfer.v1',manifest=manifest,manifest_sha256=digest(canonical(manifest)),payloads=payloads)
e=dict(os.environ,FM_HOME=str(home),FM_PROCEVENT_CLAIM_ROOT=str(s/'claims'))
for k in ('FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE','FM_GATE_REFUSE_BYPASS','TASKS_AXI_FILE','TASKS_AXI_BACKEND'):e.pop(k,None)
log=(ev/'round4-remote-activation.log').open('w'); runner=None; release=s/'release'; marker=s/'active'
def run(args,expected=0,inp=None):
 started=time.monotonic();p=subprocess.run(args,env=e,input=inp,capture_output=True,text=True,timeout=20)
 log.write('$ '+' '.join(args)+'\n'+p.stdout+p.stderr+f'exit={p.returncode}; elapsed={time.monotonic()-started:.3f}s\n');log.flush()
 assert p.returncode==expected,(args,p.stdout,p.stderr);return p
try:
 run(['bin/fm-extension.sh','receive-transfer-bind','--adapter','ext-remote','--trust-same-user-code'],inp=canonical(envelope).decode())
 run(['bin/fm-procevent.sh','register-extension','ext-remote','remote-active-source','--config-ref',f'active-block|{marker}|{release}'])
 with (ev/'round4-remote-runner.log').open('w') as out:
  runner=subprocess.Popen(['bin/fm-procevent.sh','start','remote-active-source'],env=e,stdout=out,stderr=out,start_new_session=True)
  deadline=time.monotonic()+15
  while not marker.exists():
   assert runner.poll() is None; assert time.monotonic()<deadline;time.sleep(.05)
  for args in (['register-extension','ext-remote','remote-active-source','--config-ref','replacement'],['register','lavish','remote-active-source','--','/bin/echo','replacement']):
   p=run(['bin/fm-procevent.sh']+args,1);assert 'prior runner remains active' in p.stderr
   os.kill(int(marker.read_text()),0)
  log.write('Both replacements refused while the original extension poll was still alive.\n');log.flush()
  release.touch();rc=runner.wait(25);assert rc==0,rc
 assert not (home/'state/procevent/remote-active-source.source').exists()
 run(['bin/fm-procevent.sh','handled','remote-active-source','1'])
 run(['bin/fm-procevent.sh','register','lavish','remote-active-source','--','/bin/echo','replacement'])
 run(['bin/fm-procevent.sh','retire','remote-active-source','--if-matches','lavish','--','/bin/echo','replacement'])
 p=run(['bin/fm-procevent.sh','register-extension','ext-remote','remote-active-source','--config-ref','replacement'])
 owner=next(x.split(': ',1)[1] for x in p.stdout.splitlines() if x.startswith('owner-token: '))
 run(['bin/fm-procevent.sh','retire','remote-active-source','--if-owner',owner])
 log.write('After the original poll exited 0, both built-in and extension replacement succeeded; registrations retired.\n')
finally:
 release.touch()
 if runner and runner.poll() is None:
  os.killpg(runner.pid,signal.SIGTERM)
  try:runner.wait(5)
  except subprocess.TimeoutExpired:os.killpg(runner.pid,signal.SIGKILL);runner.wait()
 log.close()
