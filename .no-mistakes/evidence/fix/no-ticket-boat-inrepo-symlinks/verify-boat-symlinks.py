import importlib.util, sys, subprocess, tempfile, pathlib, os, tarfile, json, contextlib, io, shutil
root=pathlib.Path.cwd()
evidence=pathlib.Path('~/.no-mistakes/evidence/01M6FH13KMKW3GP6AGY47PMGK1')
evidence.mkdir(parents=True,exist_ok=True)
spec=importlib.util.spec_from_file_location('boat',root/'bin/fm-boat-run.py'); boat=importlib.util.module_from_spec(spec); sys.modules['boat']=boat; spec.loader.exec_module(boat)
base=pathlib.Path(tempfile.mkdtemp(dir=root/'.test-boat-symlinks'))
def git(p,*args):
    return subprocess.run(['git','-C',str(p),*args],check=True,capture_output=True).stdout
rows=[]
try:
 for historical in (False,True):
  for label,target,accepted in [('connect','../../tracked.txt',True),('escape','../../../outside',False),('absolute','/outside',False),('escape-reenter','../../../repo/tracked.txt',False),('credential','../../API_SECRET=do-not-disclose',False),('binary',b'../../bad-\xff',False)]:
   p=base/(str(historical)+'-'+label); p.mkdir(); git(p,'init','-q'); git(p,'config','user.name','Lab'); git(p,'config','user.email','lab@example.invalid')
   (p/'tracked.txt').write_text('ordinary source\n'); (p/'run.sh').write_text('#!/bin/sh\nexit 0\n'); (p/'run.sh').chmod(0o755)
   link=p/'.agents/skills/verify-connect'; link.parent.mkdir(parents=True); link.symlink_to(target)
   git(p,'add','.'); git(p,'commit','-qm','fixture')
   if historical:
    link.unlink(); git(p,'add','-u'); git(p,'commit','-qm','remove link')
   git(p,'update-ref','refs/remotes/origin/main','HEAD')
   home=base/(p.name+'-home'); (home/'config').mkdir(parents=True); state=home/'state/boat-offload'; (state/'jobs').mkdir(parents=True)
   key=home/'unused-key'; (home/'config/boat-keys').write_text(str(key)+' pending_cap=1\n')
   (state/'jobs/reserved.json').write_text(json.dumps({'cleanup':'pending','account_key_file':str(key)}))
   cliout=base/(p.name+'-cli-output')
   command=['bash',str(root/'bin/fm-boat-run.sh'),'run','--worktree',str(p),'--output',str(cliout)]
   if historical: command+=['--history-depth','2']
   command+=['--','true']
   run=subprocess.run(command,env=dict(os.environ,FM_HOME=str(home)),capture_output=True,timeout=10)
   assert run.returncode==(75 if accepted else 2),(run.returncode,run.stderr)
   cliresult=json.loads((cliout/'result.json').read_text())
   assert cliresult['cleanup']==('deleted' if accepted else 'not-created'),cliresult
   if accepted:
    with tarfile.open(cliout/'upload/source.tar.gz') as tar: assert '.agents/skills/verify-connect' not in tar.getnames(); assert tar.extractfile('tracked.txt').read()==b'ordinary source\n'
   rows.append({'mode':'history' if historical else 'source','case':label+' public CLI','exit':run.returncode,'stderr':run.stderr.decode(),'result':cliresult})
   archive=base/(p.name+'.tar.gz'); notice=io.StringIO(); failure=None
   try:
    with contextlib.redirect_stderr(notice): result=boat.source(p,[],archive,set(),2 if historical else None)
   except boat.Failure as exc: failure=exc
   if accepted:
    assert failure is None,str(failure)
    with tarfile.open(archive) as tar:
     names=tar.getnames(); assert '.agents/skills/verify-connect' not in names
     assert tar.extractfile('tracked.txt').read()==b'ordinary source\n'
     assert tar.getmember('run.sh').mode & 0o111 == 0o111
     if historical:
      dest=base/'unpacked'; dest.mkdir(); tar.extractall(dest,filter='data')
      blob=git(dest,'cat-file','blob','HEAD~1:.agents/skills/verify-connect'); assert blob==b'../../tracked.txt'
      git(dest,'fsck','--no-reflogs'); shutil.rmtree(dest)
    assert notice.getvalue().count('skipped in-repo symlink:')==1
    shutil.copyfile(archive,evidence/('boat-'+p.name+'.tar.gz'))
    outcome='accepted; symlink omitted; ordinary file bytes and executable mode preserved'+('; historical target blob retained and git fsck passed' if historical else '')
   else:
    assert failure is not None and failure.code==2,(label,failure)
    assert 'do-not-disclose' not in str(failure)+notice.getvalue()
    outcome='refused: '+str(failure)
   rows.append({'mode':'history-only link' if historical else 'current source','case':label,'outcome':outcome,'notice':notice.getvalue().strip()})
 # Current symlink parent and submodule remain refusals.
 for label in ('parent','submodule'):
  p=base/label; p.mkdir(); git(p,'init','-q'); git(p,'config','user.name','Lab'); git(p,'config','user.email','lab@example.invalid'); (p/'tracked.txt').write_text('plain\n'); git(p,'add','.'); git(p,'commit','-qm','initial')
  if label=='parent':
   (p/'dir').mkdir(); (p/'dir/link').symlink_to('../tracked.txt'); git(p,'add','.'); git(p,'commit','-qm','link'); (p/'dir').rename(p/'real'); (p/'dir').symlink_to('real')
  else:
   oid=git(p,'rev-parse','HEAD').decode().strip(); git(p,'update-index','--add','--cacheinfo','160000,'+oid+',module'); git(p,'commit','-qm','gitlink')
  try: boat.source(p,[],base/(label+'.tar.gz'),set()); raise AssertionError('unexpected acceptance')
  except boat.Failure as exc: assert exc.code==2; rows.append({'case':label,'outcome':'refused: '+str(exc)})
 # Reproduce the reported failure using the base version's real packager.
 baseline=base/'baseline.py'; baseline.write_bytes(git(root,'show','1cbc038168ee3b497254afc7b88babf0c65768b5:bin/fm-boat-run.py'))
 spec=importlib.util.spec_from_file_location('baseline',baseline); old=importlib.util.module_from_spec(spec); sys.modules['baseline']=old; spec.loader.exec_module(old)
 try: old.source(base/'False-connect',[],base/'old.tar.gz',set()); raise AssertionError('baseline unexpectedly accepted')
 except old.Failure as exc: rows.append({'case':'baseline connect reproduction','outcome':str(exc)})
 (evidence/'boat-symlink-product-proof.json').write_text(json.dumps(rows,indent=2)+'\n')
 print(json.dumps(rows,indent=2))
finally:
 shutil.rmtree(base)
