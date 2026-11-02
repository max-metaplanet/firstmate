import os, subprocess, pathlib, sys, json, tarfile, shutil
root=pathlib.Path.cwd(); base=root/'.test-validation/live'; base.mkdir()
evidence=pathlib.Path('~/.no-mistakes/evidence/01M6ETEDTK4SWC8755G9TC2DWA')
work=base/'project'; work.mkdir(); home=base/'home'; home.mkdir()
env=dict(os.environ,HOME=str(home),FM_HOME=str(home),TMPDIR=str(base), BOAT_NO_UPDATE='1',FM_BUILD_LOCK_FILE=str(base/'heavy.lock'),FM_BUILD_LOCK_INSTALL_DIR=str(base/'install'),FM_TASK_ID='isolated-validation')
for key in list(env):
    if key.startswith('GIT_') or key in ('FM_BUILD_LOCK_HELD','FM_BUILD_LOCK_BYPASS','NODE_OPTIONS','BOAT_API_KEY','BOAT_TOKEN'): env.pop(key,None)
def git(*args,cwd=work,check=True):
    return subprocess.run(['git','-C',str(cwd),*args],env=env,capture_output=True,text=True,check=check)
git('init','-q'); git('config','user.name','Validation');git('config','user.email','validation@example.invalid')
(work/'ordinary.bin').write_bytes(bytes(range(256))*32768)
(work/'stable.txt').write_text('API_SECRET=synthetic-uploaded-by-design\n')
for i in range(55):
    (work/'version.txt').write_text(str(i)+'\n'); git('add','.');git('commit','-qm','revision '+str(i))
for path,content in {'.npmrc':'//registry.npmjs.org/:_authToken=synthetic-only\n','.claude/settings.local.json':'{"apiKey":"synthetic-only"}\n','dirty.txt':'API_SECRET=synthetic-dirty\n','deleted.txt':'API_SECRET=synthetic-deleted\n','.env.production':'API_SECRET=synthetic-excluded\n','secrets/value.txt':'API_SECRET=synthetic-secret-path\n'}.items():
    p=work/path;p.parent.mkdir(parents=True,exist_ok=True);p.write_text(content)
git('add','--force','.');git('commit','-qm','screened fixtures')
head=git('rev-parse','HEAD').stdout.strip()
oids={path:git('rev-parse','HEAD:'+path).stdout.strip() for path in ('.npmrc','.claude/settings.local.json','dirty.txt','deleted.txt','.env.production','secrets/value.txt')}
git('update-ref','refs/remotes/origin/main','HEAD');(work/'dirty.txt').write_text('clean dirty edit\n');(work/'deleted.txt').unlink()
# Execute the real CLI; no account is installed in the disposable HOME. Source
# preparation must still finish before account admission reports unavailable.
for depth in (None,20,50):
    output=base/('out-'+str(depth));args=['bash',str(root/'bin/fm-boat-run.sh'),'run','--worktree',str(work),'--output',str(output)]
    if depth: args+=['--history-depth',str(depth)]
    args+=['--','true'];r=subprocess.run(args,env=env,capture_output=True,text=True,timeout=60)
    print('CLI history_depth=%s exit=%s stdout=%r stderr=%r'%(depth,r.returncode,r.stdout,r.stderr))
    result=json.loads((output/'result.json').read_text());assert result['kind']=='unavailable',result
    assert result['cleanup'] in ('not-created','deleted'),result
    shutil.copyfile(output/'result.json',evidence/('archive-'+str(depth)+'-result.json'))
    extracted=base/('extracted-'+str(depth));extracted.mkdir()
    with tarfile.open(output/'upload/source.tar.gz') as tf: tf.extractall(extracted,filter='data')
    assert (extracted/'ordinary.bin').read_bytes()==(work/'ordinary.bin').read_bytes()
    assert (extracted/'dirty.txt').read_text()=='clean dirty edit\n'
    assert (extracted/'stable.txt').read_text()==(work/'stable.txt').read_text()
    assert not any((extracted/p).exists() for p in ('.npmrc','.claude/settings.local.json','.env.production','deleted.txt','secrets/value.txt'))
    if depth:
        assert git('rev-parse','HEAD',cwd=extracted).stdout.strip()==head
        assert int(git('rev-list','--count','--all',cwd=extracted).stdout)==depth
        for path,oid in oids.items(): assert git('cat-file','blob',oid,cwd=extracted,check=False).returncode!=0,path
        assert git('fsck','--no-reflogs',cwd=extracted).returncode==0
        print('ARCHIVE depth=%s: original HEAD preserved; %s commits; six screened blobs unavailable; dirty edit preserved; binary bytes exact'%(depth,depth))
    else:
        assert not (extracted/'.git').exists();print('ARCHIVE default: no Git metadata; binary bytes exact; screened paths absent; dirty edit preserved')
# Drive real routing, using real Boat CLI with the isolated unauthenticated home.
config=home/'config';config.mkdir();(config/'boat-heavy').write_text("project bootstrap='true' timeout=30\n")
route=root/'bin/fm-heavy-route.py'
r=subprocess.run([str(route),'publish','--home',str(home),'--config',str(config)],env=env,capture_output=True,text=True);assert r.returncode==0,r.stderr
for name,kind,args in [('unavailable','vitest',[]),('output-writing','eslint',['--fix']),('credential-kind','queue-preflight',[])]:
    cmd=['bash','-c','printf "local slot=%s\\n" "$FM_BUILD_LOCK_HELD"; exit 7','--',*args]
    r=subprocess.run([str(route),'--kind',kind,'--',*cmd],env=env,cwd=work,capture_output=True,text=True,timeout=60)
    print('ROUTE %s exit=%s stdout=%r stderr=%r'%(name,r.returncode,r.stdout,r.stderr));assert r.returncode==7
    assert 'local slot=' in r.stdout and r.stdout.strip()!='local slot='
    if name=='unavailable': assert 'Boat did not run it' in r.stderr
    else: assert 'on Boat' not in r.stderr
print('All local live assertions passed. Remote execution cannot run with the isolated HOME: Boat key unavailable; no account or operator data accessed.')
