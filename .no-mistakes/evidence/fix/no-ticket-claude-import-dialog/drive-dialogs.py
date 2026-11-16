import os,pathlib,subprocess,json,pty,fcntl,termios,struct,select,time,signal,html,re
root=pathlib.Path.cwd();lab=root/'.live-trust';ev=pathlib.Path('~/.no-mistakes/evidence/01M7K5HMNEBSF8Q21D700K2S72');store=lab/'profile/.claude.json';env=os.environ.copy();env.update(HOME=str(lab/'home'),CLAUDE_CONFIG_DIR=str(lab/'profile'),TERM='xterm-256color',CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION='false');project=lab/'project';wt=lab/'worker'
def launch(name,cwd,expected):
 master,slave=pty.openpty();fcntl.ioctl(slave,termios.TIOCSWINSZ,struct.pack('HHHH',36,120,0,0));p=subprocess.Popen(['claude','--setting-sources','project,local','--permission-mode','auto'],cwd=cwd,env=env,stdin=slave,stdout=slave,stderr=slave,start_new_session=True);os.close(slave);chunks=[]
 try:
  until=time.time()+10
  while time.time()<until and p.poll() is None:
   if select.select([master],[],[],.25)[0]:
    try:chunks.append(os.read(master,65536))
    except OSError:break
 finally:
  if p.poll() is None:os.killpg(p.pid,signal.SIGTERM)
  try:p.wait(timeout=4)
  except subprocess.TimeoutExpired:os.killpg(p.pid,signal.SIGKILL);p.wait()
  os.close(master)
 raw=b''.join(chunks);(ev/(name+'.ansi')).write_bytes(raw);text=raw.decode(errors='replace');text=re.sub(r'\x1b\][^\x07]*(?:\x07|\x1b\\)','',text);text=re.sub(r'\x1b\[[0-?]*[ -/]*[@-~]','',text);text=re.sub(r'\x1b[=>78]','',text);(ev/(name+'.txt')).write_text(text);(ev/(name+'.html')).write_text('<!doctype html><meta charset="utf-8"><title>'+name+'</title><body style="background:#161616;color:#eee"><pre>'+html.escape(text)+'</pre></body>');collapsed=re.sub(r'\s+','',text)
 if expected=='dialog':assert 'AllowexternalCLAUDE.mdfileimports?' in collapsed,text
 else:
  assert 'automodeon' in collapsed and '❯' in text,text
  assert 'AllowexternalCLAUDE.mdfileimports?' not in collapsed,text
  assert 'Quick safety check' not in text,text
 print(name+': '+expected+' observed; child reaped with exit '+str(p.returncode),flush=True)
s=json.loads(store.read_text());s['projects'][str(project)]={'hasTrustDialogAccepted':True};store.write_text(json.dumps(s));launch('control-trust-only',project,'dialog')
p=subprocess.run([str(root/'bin/fm-claude-trust.sh'),'--project',str(project)],env=env,text=True,capture_output=True);assert p.returncode==0,p.stderr;(ev/'approved-registration.txt').write_text(p.stdout);launch('approved-project',project,'composer')
(wt/'CLAUDE.md').write_text('@../outside/EXTERNAL.md\n');launch('approved-new-worktree',wt,'composer')
