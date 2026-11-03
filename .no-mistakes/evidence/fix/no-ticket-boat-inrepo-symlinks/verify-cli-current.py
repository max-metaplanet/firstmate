import json, os, pathlib, shutil, subprocess, tarfile, tempfile
ROOT=pathlib.Path.cwd()
EVID=pathlib.Path('~/.no-mistakes/evidence/01M6FH13KMKW3GP6AGY47PMGK1')
rows=[]
def git(p,*a):
    return subprocess.run(['git','-C',str(p),*a],capture_output=True,check=True).stdout
with tempfile.TemporaryDirectory(prefix='.boat-live-',dir=ROOT) as scratch:
    base=pathlib.Path(scratch)
    def drive(label, name, target, accepted, history=False, remove=False, special=None):
        case=base/label; case.mkdir(); repo=case/'repo'; repo.mkdir()
        git(repo,'init','-q','--template='); git(repo,'config','user.name','Verifier'); git(repo,'config','user.email','verifier@example.invalid')
        (repo/'tracked.txt').write_bytes(b'ordinary source\n')
        (repo/'run.sh').write_bytes(b'#!/bin/sh\nexit 0\n'); (repo/'run.sh').chmod(0o755)
        (repo/'.env').write_text('excluded example\n')
        link=repo/name; link.parent.mkdir(parents=True,exist_ok=True)
        if special=='submodule':
            git(repo,'add','--force','.'); git(repo,'commit','-qm','initial')
            oid=git(repo,'rev-parse','HEAD').decode().strip()
            git(repo,'update-index','--add','--cacheinfo','160000,'+oid+',module')
        else:
            link.symlink_to(target)
        if special!='submodule': git(repo,'add','--force','.')
        git(repo,'commit','-qm','tracked link')
        if remove:
            link.unlink(); git(repo,'add','-u'); git(repo,'commit','-qm','remove link')
        if special=='parent':
            link.parent.rename(repo/'actual'); (repo/'dir').symlink_to('actual')
        if special=='edited-escape':
            link.unlink(); link.symlink_to('../../../outside')
        if special=='untracked-escape':
            link.unlink(); link.write_text('ordinary replacement\n')
        git(repo,'update-ref','refs/remotes/origin/main','HEAD')
        head=git(repo,'rev-parse','HEAD').decode().strip()
        before=git(repo,'status','--porcelain=v1')
        home=case/'home'; (home/'config').mkdir(parents=True)
        state=home/'state/boat-offload'; (state/'jobs').mkdir(parents=True)
        key=home/'no-provider-key'
        (home/'config/boat-keys').write_text(str(key)+' pending_cap=1\n')
        (state/'jobs/reservation.json').write_text(json.dumps({'cleanup':'pending','account_key_file':str(key)}))
        output=case/'output'
        command=['bash',str(ROOT/'bin/fm-boat-run.sh'),'run','--worktree',str(repo),'--output',str(output)]
        if history: command += ['--history-depth','3']
        command += ['--','true']
        env=dict(os.environ,FM_HOME=str(home),HOME=str(case/'user'),PYTHONDONTWRITEBYTECODE='1')
        # The real adapter packages source before its real pending-budget guard.
        # No key exists and no provider CLI is substituted or called.
        run=subprocess.run(command,env=env,capture_output=True,timeout=20)
        result=json.loads((output/'result.json').read_text())
        expected=75 if accepted else 2
        assert run.returncode==expected,(label,run.returncode,run.stderr)
        assert b'never-disclose' not in run.stdout+run.stderr,label
        archive=output/'upload/source.tar.gz'
        row={'case':label,'argv':command,'exit':run.returncode,'stdout':run.stdout.decode(),'stderr':run.stderr.decode(),'result':result}
        if accepted:
            assert b'Boat pending cap reached' in run.stderr,label
            with tarfile.open(archive) as tar:
                names=tar.getnames()
                assert name not in names,(label,names)
                assert '.env' not in names,label
                assert tar.extractfile('tracked.txt').read()==b'ordinary source\n',label
                assert tar.getmember('run.sh').mode & 0o111 == 0o111,label
                row['archive_members']=names
                if history:
                    unpack=case/'unpacked'; unpack.mkdir(); tar.extractall(unpack,filter='data')
                    revision='HEAD~1' if remove else 'HEAD'
                    assert git(unpack,'cat-file','blob',revision+':'+name)==os.fsencode(target)
                    fsck=subprocess.run(['git','-C',str(unpack),'fsck','--no-reflogs'],capture_output=True)
                    assert fsck.returncode==0,(label,fsck.stderr)
                    row['historical_target']=os.fsdecode(target); row['fsck_exit']=fsck.returncode
                    row['fsck_stdout']=fsck.stdout.decode(); row['fsck_stderr']=fsck.stderr.decode()
            assert run.stderr.count(('skipped in-repo symlink: '+name+'\n').encode())==(0 if remove and not history else 1),label
            if label in ('source-connect','history-connect'):
                dest=EVID/('current-'+label+'.tar.gz'); shutil.copyfile(archive,dest); row['saved_archive']=str(dest)
        else:
            assert not archive.exists(),label
            assert result['cleanup']=='not-created',label
        assert git(repo,'status','--porcelain=v1')==before,label
        assert git(repo,'rev-parse','HEAD').decode().strip()==head,label
        if label in ('source-connect','history-connect'):
            baseline=case/'baseline.py'
            baseline.write_bytes(git(ROOT,'show','df10fc4d51c69c5768ae21bdc6562a067bda4057:bin/fm-boat-run.py'))
            oldcommand=['python3',str(baseline),*command[2:]]
            oldcommand[oldcommand.index('--output')+1]=str(case/'baseline-output')
            old=subprocess.run(oldcommand,env=env,capture_output=True,timeout=20)
            assert old.returncode==2,(label,old.returncode,old.stderr)
            assert b'unsupported symlink or submodule' in old.stderr,(label,old.stderr)
            row['baseline_exit']=old.returncode; row['baseline_stderr']=old.stderr.decode()
        rows.append(row)
    for history in (False,True):
        prefix='history-' if history else 'source-'
        for label,name,target,accepted in [
            ('connect','.agents/skills/verify-connect','../../tracked.txt',True),
            ('claude','.claude/skills','../.agents/skills',True),
            ('arbitrary','link','tracked.txt',True),
            ('directory','link','.',True),
            ('escape','dir/link','../../outside',False),
            ('escape-reenter','dir/link','../../repo/tracked.txt',False),
            ('absolute','dir/link','/outside',False),
            ('credential','dir/link','../API_SECRET=never-disclose',False),
            ('binary','dir/link',b'../bad-\xff',False)]:
            drive(prefix+label,name,target,accepted,history,remove=history and not accepted)
        drive(prefix+'parent','dir/link','../tracked.txt',False,history,special='parent')
        drive(prefix+'submodule','module','',False,history,special='submodule')
    drive('history-only-connect','.agents/skills/verify-connect','../../tracked.txt',True,True,True)
    drive('edited-escape','.agents/skills/verify-connect','../../tracked.txt',False,special='edited-escape')
    drive('removed-current-link','.agents/skills/verify-connect','../../tracked.txt',True,remove=True)
    drive('regular-replacement','.agents/skills/verify-connect','../../tracked.txt',True,special='untracked-escape')
(EVID/'current-cli-transcript.json').write_text(json.dumps(rows,indent=2)+'\n')
print(json.dumps({'scenarios':len(rows),'all_passed':True,'evidence':str(EVID/'current-cli-transcript.json')}))
