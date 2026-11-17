from pathlib import Path
import json, os, subprocess, hashlib, shutil
root=Path.cwd(); lab=root/'.test-live-seat'; evidence=Path('~/.no-mistakes/evidence/01M7KE9CPC59S5TAQ2V3K6VFM3')
log=[]
for part in ['home/config','home/state','home/data','user','seats/codex-max','seats/codex-max2','claude','grok','xdg']:
 (lab/part).mkdir(parents=True,exist_ok=True)
for seat in ['codex-max','codex-max2']:
 (lab/'seats'/seat/'auth.json').write_text(json.dumps({'auth_mode':'apikey','OPENAI_API_KEY':'disposable-invalid-'+seat}))
(lab/'home/config/codex-seats-root').write_text(str(lab/'seats')+'\n')
def run(args, env, expected=0):
 p=subprocess.run(args,env=env,text=True,capture_output=True,timeout=30)
 log.append('$ '+' '.join(args)+'\nexit='+str(p.returncode)+'\n'+p.stdout+p.stderr)
 assert p.returncode==expected,(args,p.returncode,p.stdout,p.stderr)
 return p
try:
 env=dict(os.environ,HOME=str(lab/'user'),FM_HOME=str(lab/'home'),FM_CONFIG_OVERRIDE=str(lab/'home/config'),FM_STATE_OVERRIDE=str(lab/'home/state'),FM_DATA_OVERRIDE=str(lab/'home/data'),FM_ROOT_OVERRIDE=str(root),CODEX_HOME=str(lab/'seats/codex-max'),CLAUDE_CONFIG_DIR=str(lab/'claude'),GROK_HOME=str(lab/'grok'),XDG_CONFIG_HOME=str(lab/'xdg'))
 for k in ['FM_AMBIENT_CLAUDE_CONFIG_DIR','CLAUDE_SECURESTORAGE_CONFIG_DIR','QUOTA_AXI_SNAPSHOT']:env.pop(k,None)
 config=lab/'home/config'
 (config/'crew-dispatch.json').write_text(json.dumps({'rules':[{'kind':'implementation','use':[{'harness':'claude'},{'harness':'codex'}]}]}))
 (config/'dispatch-prefer').write_text('# preserved comment\nreview=claude\nimplementation=claude\n')
 run(['bash','bin/fm-prefer.sh','set','implementation','codex'],env)
 p=run(['bash','bin/fm-prefer.sh','show'],env)
 assert 'prefer codex for implementation' in p.stdout and 'prefer claude for review' in p.stdout
 assert (config/'dispatch-prefer').read_text()=='# preserved comment\nreview=claude\nimplementation=codex\n'
 run(['bash','bin/fm-prefer.sh','set','implementation','auto'],env)
 assert (config/'dispatch-prefer').read_text()=='# preserved comment\nreview=claude\n'
 run(['bash','bin/fm-prefer.sh','set','implementation','codex'],env)
 # Real quota-axi auth output is the public credential-source contract.
 auth_args=['bash','bin/fm-quota-read.sh','auth','--provider','codex','--full','--json']
 hashes={p:hashlib.sha256(p.read_bytes()).hexdigest() for p in (lab/'seats').glob('*/auth.json')}
 for seat in ['codex-max2','codex-max','codex-max2']:
  (config/'codex-seat').write_text(seat+'\n')
  p=run(auth_args,env)
  src=json.loads(p.stdout)['auth'][0]['sources'][0]
  assert src['source']=='auth-json' and src['path']==str(lab/'seats'/seat/'auth.json')
 owner=lab/'seats/codex-max2'
 alias=lab/'seats/alias';alias.mkdir(exist_ok=True);(alias/'auth.json').symlink_to(owner/'auth.json')
 (config/'codex-seat').write_text('alias\n')
 p=run(auth_args,env);assert json.loads(p.stdout)['auth'][0]['sources'][0]['path']==str(owner/'auth.json')
 for setting in ['missing','../codex-max']:
  (config/'codex-seat').write_text(setting+'\n')
  p=run(auth_args,env,1);assert not p.stdout and 'error:' in p.stderr
 assert all(hashlib.sha256(p.read_bytes()).hexdigest()==h for p,h in hashes.items())
 log.append('Credential hashes unchanged; preference update preserved the other kind and comments.\n')
 # Stream exact source bytes over inherited pipes. A loader supplies relative
 # library imports; no product logic or vendor command is stubbed or rewritten.
 remote=r'''
import os,sys,json,subprocess,threading
payload=json.load(sys.stdin)
for label,files in payload.items():
 pipes={name:os.pipe() for name in files}
 def writer(fd,data):
  with os.fdopen(fd,'w') as f:f.write(data)
 threads=[]
 for name,(r,w) in pipes.items():
  t=threading.Thread(target=writer,args=(w,files[name]));t.start();threads.append(t)
 cases='\n'.join(name+') builtin source /dev/fd/'+str(pipes[name][0])+' ;;' for name in files if name!='fm-prefer.sh')
 loader='function .() { case "${1##*/}" in\n'+cases+'\n*) return 99 ;;\nesac; }; builtin source /dev/fd/'+str(pipes['fm-prefer.sh'][0])+' show'
 env=dict(os.environ,HOME='/dev/null',FM_HOME='/dev/null',FM_ROOT_OVERRIDE='/dev/null',FM_CONFIG_OVERRIDE='/dev/null',FM_STATE_OVERRIDE='/dev/null',FM_DATA_OVERRIDE='/dev/null')
 p=subprocess.run(['/bin/bash','-c',loader],env=env,pass_fds=tuple(r for r,w in pipes.values()),text=True,capture_output=True,timeout=20)
 print(label+' /bin/bash show exit='+str(p.returncode)+'\n'+p.stdout+p.stderr,flush=True)
 for r,w in pipes.values():os.close(r)
 for t in threads:t.join()
 if label=='base': assert p.returncode!=0 and "unexpected token `;;'" in p.stderr
 else: assert p.returncode==0 and 'no preference declared' in p.stdout
'''
 files={name:(root/'bin'/name).read_text() for name in ['fm-prefer.sh','fm-prefer-lib.sh','fm-control-lib.sh']}
 base=dict(files);base['fm-prefer.sh']=subprocess.check_output(['git','show','57139883133be497b457c346a6fcac653c633475:bin/fm-prefer.sh'],text=True)
 # Python program and source payload travel in argv/stdin, never remote files.
 import shlex
 p=subprocess.run(['ssh','-o','BatchMode=yes','-o','ConnectTimeout=5','-o','StrictHostKeyChecking=yes','telos64','python3 -c '+shlex.quote(remote)],input=json.dumps({'base':base,'target':files}),text=True,capture_output=True,timeout=50)
 log.append('$ ssh telos64 python3 (in-memory exact-source loader, base then target)\nexit='+str(p.returncode)+'\n'+p.stdout+p.stderr)
 assert p.returncode==0,(p.stdout,p.stderr)
finally:
 (evidence/'seat-preference-transcript.txt').write_text('\n'.join(log))
 shutil.rmtree(lab)
