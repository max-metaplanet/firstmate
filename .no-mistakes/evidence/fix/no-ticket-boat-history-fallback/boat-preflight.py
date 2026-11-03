import json, os, pathlib, shutil, subprocess, tarfile, tempfile
ROOT=pathlib.Path.cwd()
E=pathlib.Path('~/.no-mistakes/evidence/01M6FCXAG2JR0JSP41JEV8Q53S')
lab=pathlib.Path(tempfile.mkdtemp(prefix='.boat-live-',dir=ROOT))
records=[]
def git(w,*args):
 return subprocess.check_output(['git','-C',str(w),*args],stderr=subprocess.PIPE).decode().strip()
def drive(name,mode):
 p=lab/name;p.mkdir();w=p/'source';w.mkdir();home=p/'home';home.mkdir()
 git(w,'init','-q');git(w,'config','user.name','Validation');git(w,'config','user.email','validation@example.invalid')
 (w/'tracked.txt').write_text('old source\n')
 old=None
 if mode=='blob':
  (w/'db-services.sh').write_text('POSTGRES_PASSWORD=postgres\n')
 elif mode=='excluded': (w/'.env').write_text('historic sentinel\n')
 elif mode=='binary': (w/'binary.dat').write_bytes(b'\x00\xff')
 elif mode=='symlink': (w/'old-link').symlink_to('tracked.txt')
 git(w,'add','.');git(w,'commit','-qm','bearer historical-sentinel' if mode=='commit' else 'old revision')
 old=git(w,'rev-parse','HEAD')
 for n in ['db-services.sh','.env','binary.dat','old-link']:
  x=w/n
  if x.exists() or x.is_symlink(): x.unlink()
 git(w,'add','-A');git(w,'commit','--allow-empty','-qm','current safe revision')
 if mode!='missing-base':git(w,'update-ref','refs/remotes/origin/main','HEAD')
 (w/'tracked.txt').write_text('current working edit\n')
 if mode=='current-link':
  (w/'current-link').symlink_to('tracked.txt');git(w,'add','.');git(w,'commit','-qm','current unsupported entry')
 if mode=='current-settings':
  (w/'.claude').mkdir();(w/'.claude/settings.json').write_text('{"password":"current-sentinel"}\n');git(w,'add','.');git(w,'commit','-qm','current settings')
 env=dict(os.environ,FM_HOME=str(home),HOME=str(p/'isolated-user'),GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_NOSYSTEM='1')
 argv=['bash',str(ROOT/'bin/fm-boat-run.sh'),'run','--worktree',str(w),'--output',str(p/'output')]
 if mode!='synthetic':argv+=['--history-depth','50']
 argv+=['--','true']
 r=subprocess.run(argv,env=env,capture_output=True,text=True,timeout=20)
 result=json.loads((p/'output/result.json').read_text());a=p/'output/upload/source.tar.gz';names=[]
 if a.exists():
  with tarfile.open(a) as t:
   names=t.getnames()
   assert t.extractfile('tracked.txt').read()==b'current working edit\n'
 if mode in ['blob','excluded','binary','symlink','commit']:
  assert r.returncode==69 and result['history']=='fallback-synthetic',(name,r.stderr,result)
  assert r.stderr.count('falling back to synthetic snapshot; history refused:')==1
  assert not any(n=='.git' or n.startswith('.git/') for n in names)
  assert names==['tracked.txt'],names
  assert 'historical-sentinel' not in r.stdout+r.stderr+json.dumps(result)
 elif mode=='safe':
  assert r.returncode==69 and result['history']=='screened'
  assert any(n.startswith('.git/objects/pack/') for n in names)
 elif mode=='synthetic':
  assert r.returncode==69 and result['history']=='synthetic' and names==['tracked.txt']
 elif mode in ['missing-base','current-link']:
  assert r.returncode!=69 and result['kind'] in ['invalid','adapter-error']
  assert 'fallback-synthetic' not in json.dumps(result) and not a.exists()
 elif mode=='current-settings':
  assert r.returncode==69 and result['history']=='fallback-synthetic'
  assert '.claude/settings.json' not in names
  assert 'current-sentinel' not in r.stdout+r.stderr
 records.append(dict(scenario=name,exit=r.returncode,stderr=r.stderr,result=result,archive_members=names))
for mode in ['blob','excluded','binary','symlink','commit','safe','synthetic','missing-base','current-link','current-settings']:
 drive(mode,mode)
(E/'boat-preflight.json').write_text(json.dumps(records,indent=2)+'\n')
print('Validated real Boat CLI preflight and generated archives for: '+', '.join(x['scenario'] for x in records))
print('No remote calls: isolated HOME has no Boat key; transport exits 69 after successful source preparation.')
finally_cleanup=True
shutil.rmtree(lab)
