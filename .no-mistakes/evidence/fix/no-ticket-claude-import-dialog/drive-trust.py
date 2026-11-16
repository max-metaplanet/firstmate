import os, pathlib, subprocess, json, pty, fcntl, termios, struct, select, time, signal, html, re
root=pathlib.Path.cwd(); lab=root/'.live-trust'; evidence=pathlib.Path('~/.no-mistakes/evidence/01M7K5HMNEBSF8Q21D700K2S72')
log=[]
def run(args,env=None,ok=True):
 p=subprocess.run([str(a) for a in args],env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
 log.append('$ '+' '.join(str(a) for a in args)+'\n'+p.stdout+f'exit={p.returncode}\n')
 if ok: assert p.returncode==0,p.stdout
 return p

def repo(path):
 path.mkdir(parents=True,exist_ok=True); run(['git','init','-q',path]);run(['git','-C',path,'-c','user.name=Lab','-c','user.email=lab@example.invalid','commit','-q','--allow-empty','-m','fixture'])
config=lab/'profile';config.mkdir(); env=os.environ.copy();env['CLAUDE_CONFIG_DIR']=str(config);env['HOME']=str(lab/'home');pathlib.Path(env['HOME']).mkdir()
store=config/'.claude.json';store.write_text(json.dumps({'hasCompletedOnboarding':True,'theme':'dark','projects':{},'unrelated':{'keep':42}}))
project=lab/'project';repo(project);outside=lab/'outside';outside.mkdir();(outside/'EXTERNAL.md').write_text('Disposable test instruction: the verification word is ORCHID.\n');(project/'CLAUDE.md').write_text('@../outside/EXTERNAL.md\n')
trust=root/'bin/fm-claude-trust.sh'
def register(*args):return run([trust,*args],env=env)
def state():return json.loads(store.read_text())
def flags(key,declined=False):
 entry=state()['projects'][str(key)];assert entry['hasTrustDialogAccepted'] is True
 assert entry['hasClaudeMdExternalIncludesApproved'] is (not declined)
 assert entry['hasClaudeMdExternalIncludesWarningShown'] is True
register('--project',project);flags(project);assert state()['unrelated']=={'keep':42}
wt=lab/'worker';run(['git','-C',project,'worktree','add','-q','-b','worker',wt]);register(wt,project);flags(wt);flags(project)
# The user's decision is the independent oracle: false/true must stay false/true,
# but every key must receive workspace trust and an unrelated entry must survive.
s=state();s['projects'][str(project)]={'hasClaudeMdExternalIncludesApproved':False,'hasClaudeMdExternalIncludesWarningShown':True,'custom':'keep'};store.write_text(json.dumps(s));register(wt,project);flags(project,True);flags(wt);assert state()['projects'][str(project)]['custom']=='keep'
# Structurally seeded linked secondmate home, with eligible clones and escaping paths.
mate=lab/'mate';run(['git','-C',project,'worktree','add','-q','-b','mate',mate]);(mate/'.fm-secondmate-home').write_text('labmate\n');(mate/'AGENTS.md').touch();(mate/'bin').mkdir()
for d in ['data','state','config','projects']:(mate/d).mkdir()
fresh=mate/'projects'/'fresh';repo(fresh);declined=mate/'projects'/'declined';repo(declined);stray=mate/'projects'/'stray';stray.mkdir();(mate/'projects'/'escape').symlink_to(project,target_is_directory=True)
s=state();s['projects'][str(declined)]={'hasClaudeMdExternalIncludesApproved':False,'hasClaudeMdExternalIncludesWarningShown':True};store.write_text(json.dumps(s))
register('--secondmate-home',mate,'labmate');flags(mate);flags(project,True);flags(fresh);flags(declined,True);assert str(stray) not in state()['projects'];assert str(mate/'projects'/'escape') not in state()['projects']
before=store.read_bytes();p=run([trust,'--project',stray],env=env,ok=False);assert p.returncode!=0;assert store.read_bytes()==before
log.append('Persisted store after actual CLI registrations:\n'+store.read_text()+'\n')
(evidence/'registration-transcript.txt').write_text('\n'.join(log))
# Real Claude TUI, isolated user data; set a nonzero grid before exec, drain master.
master,slave=pty.openpty();fcntl.ioctl(slave,termios.TIOCSWINSZ,struct.pack('HHHH',36,120,0,0));cli_env=env.copy();cli_env['TERM']='xterm-256color';cli_env['CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION']='false'
p=subprocess.Popen(['claude','--setting-sources','project,local','--permission-mode','auto'],cwd=project,env=cli_env,stdin=slave,stdout=slave,stderr=slave,start_new_session=True);os.close(slave);chunks=[]
try:
 until=time.time()+18
 while time.time()<until and p.poll() is None:
  if select.select([master],[],[],0.3)[0]:
   try:chunks.append(os.read(master,65536))
   except OSError:break
finally:
 if p.poll() is None:os.killpg(p.pid,signal.SIGTERM)
 try:p.wait(timeout=5)
 except subprocess.TimeoutExpired:os.killpg(p.pid,signal.SIGKILL);p.wait()
 os.close(master)
raw=b''.join(chunks);(evidence/'claude-isolated.ansi').write_bytes(raw)
text=raw.decode(errors='replace');text=re.sub(r'\x1b\][^\x07]*(?:\x07|\x1b\\)','',text);text=re.sub(r'\x1b\[[0-?]*[ -/]*[@-~]','',text);text=re.sub(r'\x1b[=>]','',text)
(evidence/'claude-isolated.txt').write_text(text)
(evidence/'claude-isolated.html').write_text('<!doctype html><meta charset="utf-8"><title>Actual isolated Claude terminal output</title><body style="background:#161616;color:#eee"><pre>'+html.escape(text)+'</pre></body>')
print('Registration scenarios passed. Real Claude child reaped, exit:',p.returncode);print(text[-10000:])
