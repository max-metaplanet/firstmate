import os, sys, json, subprocess, tempfile, shutil, tarfile
from pathlib import Path
repo=Path.cwd()
evidence=Path('~/.no-mistakes/evidence/01M6F69E73DAH81GDVY9A8R0JM')
root=Path(tempfile.mkdtemp(prefix='.nm-live-',dir=repo))
logs=[]
env={k:v for k,v in os.environ.items() if not k.startswith(('FM_','BOAT_','GIT_')) and k not in ('NODE_OPTIONS','CI')}
env.update(HOME=str(root/'user'),FM_HOME=str(root/'home'),FM_BUILD_LOCK_INSTALL_DIR=str(root/'install'),FM_BUILD_LOCK_FILE=str(root/'heavy.lock'),FM_HEAVY_SLOTS='1',FM_TASK_ID='isolated-validation',TMPDIR=str(root),GIT_CONFIG_NOSYSTEM='1',GIT_CONFIG_GLOBAL='/dev/null',GIT_AUTHOR_NAME='Validation',GIT_AUTHOR_EMAIL='test@example.invalid',GIT_COMMITTER_NAME='Validation',GIT_COMMITTER_EMAIL='test@example.invalid')
(root/'user').mkdir(); (root/'home/config').mkdir(parents=True)
work=root/'sampleproject'; work.mkdir()
def run(args,cwd=work,input=None):
    r=subprocess.run([str(x) for x in args],cwd=cwd,env=env,input=input,capture_output=True,timeout=90)
    return r

def git(*args):
    r=run(['git',*args]); assert r.returncode==0,r.stderr; return r.stdout.decode().strip()

def record(name,r):
    logs.append({'scenario':name,'exit':r.returncode,'stdout':r.stdout.decode(errors='replace'),'stderr':r.stderr.decode(errors='replace')})

try:
    git('init','-q')
    script=work/'workload'
    script.write_text('#!'+sys.executable+'\nimport os,sys,json\na=sys.argv[1:]\ndata=sys.stdin.read()\nif "--output-file" in a:\n open(a[a.index("--output-file")+1],"w").write("report survives locally\\n")\nprint(json.dumps({"stdin":data,"args":a,"held":bool(os.getenv("FM_BUILD_LOCK_HELD")),"cwd":os.getcwd()}))\nsys.stderr.write("workload diagnostic\\n")\n')
    script.chmod(0o755)
    (work/'.gitignore').write_text('report.json\nnode_modules/\n')
    (work/'ordinary.txt').write_text('original\n')
    (work/'.npmrc').write_text('registry=https://registry.npmjs.org/\n')
    (work/'.claude').mkdir(); (work/'.claude/settings.json').write_text('{"permissions":{"allow":[]}}\n')
    (work/'vendor').mkdir(); (work/'vendor/library.txt').write_text('vendor source\n')
    (work/'.env').write_text('PRIVATE_FIXTURE=withheld\n')
    git('add','-A'); git('commit','-qm','fixture initial')
    for n in range(54):
        (work/'ordinary.txt').write_text('revision %d\n'%n)
        git('add','ordinary.txt'); git('commit','-qm','revision %d'%n)
    git('update-ref','refs/remotes/origin/main','HEAD')
    original_head=git('rev-parse','HEAD')
    (work/'ordinary.txt').write_text('dirty bytes that must travel\n')
    (work/'new.txt').write_text('staged addition\n'); git('add','new.txt')
    config=root/'home/config'
    (config/'boat-heavy').write_text("sampleproject bootstrap='echo bootstrap-diagnostic'\n")
    r=run([repo/'bin/fm-heavy-route.py','publish','--home',root/'home','--config',config]); assert r.returncode==0,r.stderr
    cases=[('stdin-enabled',['--stdin'],'let =\n','eslint'),('stdin-negated-false',['--no-stdin=false'],'let =\n','eslint'),('stdin-separate-true',['--stdin','true'],'let =\n','eslint'),('unknown-option',['--invented-future-output=lost'],'payload\n','eslint'),('ambiguous-option',['--format'],'payload\n','eslint'),('output-report',['--output-file','report.json'],'','eslint'),('next-build-output',[],'','next-build'),('credential-kind',[],'','queue-preflight'),('eligible-but-Boat-unavailable',['--format=json'],'','eslint')]
    for name,args,payload,kind in cases:
        r=run([repo/'bin/fm-heavy-route.py','--kind',kind,'--','./workload',*args],input=payload.encode())
        record(name,r)
        assert r.returncode==0,(name,r.stderr)
        data=json.loads(r.stdout)
        assert data['stdin']==payload and data['held'] and data['args']==args,(name,data)
        assert data['cwd']==str(work)
        if name=='eligible-but-Boat-unavailable':
            assert b'on Boat' in r.stderr and b'discarded remote stdout' in r.stderr,r.stderr
        else:
            assert b'on Boat' not in r.stderr,(name,r.stderr)
    assert (work/'report.json').read_text()=='report survives locally\n'
    # Genuine adapter produces the upload before account admission; no key is supplied.
    for depth in (None,20,50):
        out=root/('archive-'+str(depth))
        cmd=[repo/'bin/fm-boat-run.sh','run','--worktree',work,'--output',out,'--input','new.txt']
        if depth: cmd += ['--history-depth',str(depth)]
        cmd += ['--','true']
        r=run(cmd); record('archive-depth-'+str(depth),r)
        result=json.loads((out/'result.json').read_text())
        assert result['kind']=='unavailable' and not result.get('vm_id'),result
        shutil.copyfile(out/'upload/source.tar.gz', evidence/('source-depth-'+str(depth)+'.tar.gz'))
        extracted=root/('extracted-'+str(depth)); extracted.mkdir()
        with tarfile.open(out/'upload/source.tar.gz') as archive:
            names=archive.getnames()
            assert '.env' not in names and not any('node_modules' in p for p in names)
            for p in ('ordinary.txt','new.txt','.npmrc','.claude/settings.json','vendor/library.txt'):
                assert p in names,(depth,p)
            archive.extractall(extracted,filter='data')
        assert (extracted/'ordinary.txt').read_text()=='dirty bytes that must travel\n'
        assert (extracted/'new.txt').read_text()=='staged addition\n'
        detail={'archive':str(depth),'safe_source_files_present':True,'dirty_and_staged_bytes_preserved':True,'secret_path_excluded':True}
        if depth:
            def exported(*args): return run(['git','-C',extracted,*args])
            rhead=exported('rev-parse','HEAD'); assert rhead.returncode==0
            assert rhead.stdout.decode().strip()==original_head
            count=exported('rev-list','--count','HEAD'); assert int(count.stdout)==depth,count.stdout
            fsck=exported('fsck','--full'); assert fsck.returncode==0,fsck.stderr
            hidden=exported('show','HEAD:.env'); assert hidden.returncode!=0
            detail.update(head_identity_preserved=True,ancestry_commits=int(count.stdout),fsck_exit=fsck.returncode,excluded_history_blob_unreadable=True,git_head_stdout=rhead.stdout.decode(),git_count_stdout=count.stdout.decode(),git_fsck_stdout=fsck.stdout.decode(),git_fsck_stderr=fsck.stderr.decode(),withheld_read_stderr=hidden.stderr.decode())
        else: assert not (extracted/'.git').exists()
        logs.append(detail)
    # Invalid configuration must refuse publication rather than replacing the good record.
    prior=(root/'install/boat-route').read_bytes()
    (config/'boat-heavy').write_text("sampleproject bootstrap=true mysterious=1\n")
    r=run([repo/'bin/fm-heavy-route.py','publish','--home',root/'home','--config',config]); record('invalid-declaration',r)
    assert r.returncode==2 and (root/'install/boat-route').read_bytes()==prior
    logs.append({'result':'all targeted live assertions passed; no remote VM created'})
finally:
    (evidence/'live-transcript.json').write_text(json.dumps(logs,indent=2)+'\n')
    shutil.rmtree(root)
