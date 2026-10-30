import os,json,subprocess,tempfile,pathlib,shutil,signal
root=pathlib.Path.cwd(); evidence=pathlib.Path('~/.no-mistakes/evidence/01M67304E3V3P5TE1FDWREZXF6')
lab=pathlib.Path(tempfile.mkdtemp(prefix='.binding-live-',dir=root)); main=lab/'main'; mate=lab/'mate'
keys=['FM_HOME','FM_ROOT','FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE']
def run(args,cwd=root,env=None):
 return subprocess.run(args,cwd=cwd,env=env,check=True,text=True,capture_output=True).stdout
def bind(home,dry=False):
 return run(['bash','-c','. "$1/bin/fm-t3-home-lib.sh"; fm_t3_bind_claude_home "$2" "${3:-}"','verify',str(root),str(home)]+(['--dry-run'] if dry else []))
log=[]
def record(x): log.append(x); (evidence/'binding-results.txt').write_text('\n'.join(log)+'\n'); print(x,flush=True)
def probe(name,home,explicit=False):
 env=os.environ.copy()
 for k in keys+['CLAUDECODE','CLAUDE_PID','CLAUDE_CODE_SESSION_ID','FM_TASK_ID']: env.pop(k,None)
 if explicit: env['FM_HOME']=str(home)
 command=['claude','--print','--no-session-persistence','--setting-sources','project,local','--dangerously-skip-permissions','--tools','Bash','--model','sonnet','--system-prompt','You are running an isolated verification. Execute only the exact Bash command requested, then reply PROBE_DONE.', 'Run exactly one Bash tool command: python3 -c \'import os,json; print(json.dumps({k:os.environ.get(k) for k in ["FM_HOME","FM_ROOT","BINDING_PROBE","MATE_PROBE"]}))\' > probe-env.json; bash bin/fm-lock.sh status > tool-proof. Then reply PROBE_DONE.']
 (evidence/(name+'-command.json')).write_text(json.dumps({'cwd':str(home),'FM_HOME':env.get('FM_HOME'),'argv':command},indent=2))
 p=subprocess.Popen(command,cwd=home,env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,start_new_session=True)
 try: out,err=p.communicate(timeout=150)
 except subprocess.TimeoutExpired:
  os.killpg(p.pid,signal.SIGTERM);out,err=p.communicate();raise RuntimeError('Claude timed out: '+name)
 (evidence/(name+'-claude.txt')).write_text('exit='+str(p.returncode)+'\n'+out+'\n'+err)
 if p.returncode != 0:
  record(name+': Claude unavailable: '+out.strip())
  for f in ['hook-proof','hook-env.json']:
   if (home/f).exists(): shutil.copy2(home/f,evidence/(name+'-'+f))
  if (home/'hook-env.json').exists():
   data=json.loads((home/'hook-env.json').read_text());record(name+': REAL SessionStart env='+json.dumps(data)+'; '+(home/'hook-proof').read_text().strip());return data
  return None
 data=json.loads((home/'probe-env.json').read_text())
 for f in ['probe-env.json','tool-proof','hook-proof']:
  shutil.copy2(home/f,evidence/(name+'-'+f))
 record(name+': '+json.dumps(data)+'; tool='+ (home/'tool-proof').read_text().strip()+'; hook='+ (home/'hook-proof').read_text().strip())
 return data
try:
 main.mkdir();run(['git','init','-q',str(main)])
 archive=subprocess.run(['git','archive','HEAD','bin'],cwd=root,stdout=subprocess.PIPE,check=True).stdout
 subprocess.run(['tar','xf','-','-C',str(main)],input=archive,check=True)
 run(['git','add','bin'],cwd=main);run(['git','-c','user.name=Verification','-c','user.email=verify@example.invalid','commit','-qm','fixture'],cwd=main)
 run(['git','worktree','add','-qb','mate',str(mate)],cwd=main)
 env_hook='python3 -c \'import os,json; print(json.dumps({k:os.environ.get(k) for k in ["FM_HOME","FM_ROOT","BINDING_PROBE","MATE_PROBE"]}))\' > "$CLAUDE_PROJECT_DIR/hook-env.json"; '
 hook={'SessionStart':[{'hooks':[{'type':'command','command':env_hook+'bash "$CLAUDE_PROJECT_DIR/bin/fm-lock.sh" status > "$CLAUDE_PROJECT_DIR/hook-proof"'}]}]}
 original={'env':dict({k:'' for k in keys},FM_HOME=str(main),FM_ROOT=str(main),BINDING_PROBE='preserved'),'permissions':{'allow':['Bash(*)']},'hooks':hook,'unknown':{'keep':[1,True]}}
 for home in [main,mate]: (home/'.claude').mkdir()
 settings=main/'.claude/settings.local.json';settings.write_text(json.dumps(original))
 (mate/'.claude/settings.local.json').write_text(json.dumps({'env':{'FM_HOME':str(mate),'MATE_PROBE':'visible'},'hooks':hook}))
 before=probe('before-explicit-mate',mate,True)
 if before is not None:
  assert before['FM_HOME']==str(main),'Reported precedence did not reproduce'
  record('COUNTERFACTUAL reproduced: main settings override explicit mate home and mate local settings')
 raw=settings.read_bytes();bind(main,True);assert settings.read_bytes()==raw
 bind(main); migrated=json.loads(settings.read_text());expected=dict(original);expected['env']={'BINDING_PROBE':'preserved'};assert migrated==expected
 shutil.copy2(settings,evidence/'migrated-settings.json')
 raw=settings.read_bytes();bind(main);assert settings.read_bytes()==raw
 record('MIGRATION: seven routing keys removed; unrelated env, hooks, permissions and unknown data preserved; dry-run unchanged; repeat identical')
 after=probe('after-explicit-mate',mate,True)
 if after is not None: assert after['FM_HOME']==str(mate) and after['BINDING_PROBE']=='preserved' and after['MATE_PROBE']=='visible'
 # Remove mate routing too, as a native binding does; no inherited home remains.
 bind(mate)
 after_unset=None
 if after is not None:
  after_unset=probe('after-unset-mate',mate);assert after_unset['FM_HOME'] is None and after_unset['FM_ROOT'] is None
 env=os.environ.copy()
 for k in keys: env.pop(k,None)
 shutil.rmtree(main/'state',ignore_errors=True)
 result=run(['bash',str(mate/'bin/fm-lock.sh'),'status'],cwd=mate,env=env)
 assert result.strip()=='lock: free'
 assert not (main/'state').exists()
 (evidence/'checkout-local-lock-status.txt').write_text(result+'mate state exists; main state absent\n')
 assert (mate/'state').is_dir()
 record('OWN-HOME: direct checkout-local fm-lock.sh status with all seven routing keys unset reports lock: free, creates mate state only; Claude model-driven Bash execution remains untested; real SessionStart routing captured separately')
 absent=lab/'absent';absent.mkdir();bind(absent);assert not (absent/'.claude').exists();record('ABSENT: binding does not create settings')
 settings.write_text('{"env":');raw=settings.read_bytes()
 try: bind(main);raise AssertionError('malformed settings accepted')
 except subprocess.CalledProcessError: assert settings.read_bytes()==raw
 settings.unlink();target=lab/'target.json';target.write_text('{"env":{"CUSTOM":"safe"}}');settings.symlink_to(target)
 try: bind(main);raise AssertionError('symlink accepted')
 except subprocess.CalledProcessError: assert settings.is_symlink() and target.read_text()=='{"env":{"CUSTOM":"safe"}}'
 record('GUARDS: malformed JSON and symlinked settings refuse without altering original or target')
finally:
 shutil.rmtree(lab)
 record('CLEANUP: disposable repository and linked copy removed')
