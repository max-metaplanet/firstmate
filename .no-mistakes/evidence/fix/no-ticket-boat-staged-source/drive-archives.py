import hashlib,json,os,pathlib,subprocess,tarfile,tempfile
R=pathlib.Path.cwd()
E=pathlib.Path('~/.no-mistakes/evidence/01M6JJKFZGSDSG2PMMPT6ZS2V6')
records=[]
def git(w,*args):
 return subprocess.run(['git','-C',str(w),*args],check=True,capture_output=True).stdout.decode().strip()
with tempfile.TemporaryDirectory(prefix='.archive-live-',dir=R) as tmp:
 t=pathlib.Path(tmp)
 old=t/'baseline.py'; old.write_bytes(subprocess.check_output(['git','show','71b04003bf2c3104ebb8de76b3bb728872048822:bin/fm-boat-run.py']))
 for depth in (None,1):
  for variant in ('staged','boundaries','escape'):
   p=t/(variant+str(depth)); w=p/'repo'; w.mkdir(parents=True)
   home=p/'home'; home.mkdir(); (home/'config').mkdir()
   key=w/'account-material.txt'
   (home/'config/boat-keys').write_text(str(key)+'\n')
   git(w,'init','-q'); git(w,'config','user.name','Archive lab'); git(w,'config','user.email','lab@example.invalid')
   (w/'tracked.txt').write_text('committed\n'); (w/'deleted.txt').write_text('committed deletion\n')
   git(w,'add','.'); git(w,'commit','-qm','initial'); head=git(w,'rev-parse','HEAD'); git(w,'update-ref','refs/remotes/origin/main',head)
   (w/'tracked.txt').write_text('working edit\n'); (w/'deleted.txt').unlink()
   files={'offer-dates.ts':b'export const dates = [];\n','claim-writes.ts':b'export const claim = true;\n','space tab\tnewline\n.ts':b'bytes\x00\xff'}
   for n in files: (w/n).write_bytes(b'index version\n')
   git(w,'add','--',*files)
   for n,b in files.items(): (w/n).write_bytes(b)
   (w/'untracked.ts').write_text('unselected\n')
   expected={'tracked.txt':b'working edit\n',**files}
   if variant=='boundaries':
    git(w,'mv','tracked.txt','renamed.txt'); expected['renamed.txt']=expected.pop('tracked.txt')
    for n,b in {'.env.staged':b'never upload\n','.npmrc':b'_authToken=never-upload\n','gone.ts':b'deleted\n','account-material.txt':b'key bytes\n'}.items(): (w/n).write_bytes(b)
    git(w,'add','--force','.'); (w/'gone.ts').unlink(); key.unlink()
    # Retain configured key path while proving path screening, without contacting providers.
    key.write_text(''); expected['untracked.ts']=b'unselected\n'
    (w/'deleted.txt').write_text('restored after index deletion\n'); expected['deleted.txt']=b'restored after index deletion\n'
    (w/'safe-link').symlink_to('renamed.txt'); git(w,'add','safe-link')
   if variant=='escape':
    (w/'escape').symlink_to('../outside'); git(w,'add','escape')
   opts=[] if depth is None else ['--history-depth','1']
   def run(label,program):
    output=p/label
    argv=[*program,'run','--worktree',str(w),'--output',str(output),*opts,'--','true']
    env=dict(os.environ,HOME=str(home),FM_HOME=str(home),PYTHONDONTWRITEBYTECODE='1')
    for n in list(env):
     if n.startswith('FM_') and n not in ('FM_HOME',): env.pop(n)
    r=subprocess.run(argv,capture_output=True,text=True,env=env,timeout=25)
    archive=output/'upload/source.tar.gz'
    observed={}
    if archive.exists():
     with tarfile.open(archive) as a:
      observed={m.name:a.extractfile(m).read() for m in a.getmembers() if m.isfile() and not m.name.startswith('.git/')}
    rec={'variant':variant,'history_depth':depth,'version':label,'exit':r.returncode,'stderr':r.stderr,'archive_files':sorted(observed)}
    if (output/'result.json').exists(): rec['result']=json.loads((output/'result.json').read_text())
    records.append(rec)
    return r,archive,observed,rec
   if variant=='staged':
    r,a,obs,rec=run('before',['python3',str(old)])
    assert not any(n in obs for n in files),rec
   r,a,obs,rec=run('after',['bash',str(R/'bin/fm-boat-run.sh')])
   if variant=='escape':
    assert r.returncode==2 and not a.exists() and 'symlink' in r.stderr,rec
   else:
    assert r.returncode==69 and 'Boat key unavailable' in r.stderr,rec
    assert obs==expected,(rec,expected)
    assert rec['result']['source_head']==head
    assert rec['result']['source_sha256']==hashlib.sha256(a.read_bytes()).hexdigest()
    assert rec['result']['history']==('synthetic' if depth is None else 'screened')
    # Retain the actual generated archive as product evidence.
    (E/(variant+'-'+str(depth)+'.tar.gz')).write_bytes(a.read_bytes())
(E/'archive-transcript.json').write_text(json.dumps(records,indent=2)+'\n')
print(json.dumps(records,indent=2))
