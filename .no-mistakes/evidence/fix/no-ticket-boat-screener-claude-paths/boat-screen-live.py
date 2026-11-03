import json, os, pathlib, subprocess, tarfile, tempfile
root = pathlib.Path.cwd()
evidence = pathlib.Path('~/.no-mistakes/evidence/01M6FDKGN978FD7WPYB3HY52FT')
rows=[]
def git(work,*args):
    return subprocess.run(['git','-C',str(work),*args],capture_output=True,check=True).stdout.decode().strip()
with tempfile.TemporaryDirectory(prefix='.boat-live-',dir=root) as tmp:
    tmp=pathlib.Path(tmp)
    for name,path,content,link,accept in [
        ('combined-core-paths','.claude/skills','../.agents/skills',True,True),
        ('clean-reimage','.claude/commands/reimage-dev.md','# Rebuild development image\n',False,True),
        ('historical-reimage-secret','.claude/commands/reimage-dev.md','API_SECRET=do-not-disclose-fixture',False,False),
        ('historical-reimage-binary','.claude/commands/reimage-dev.md','hello\x00world',False,False),
        ('skills-escape','.claude/skills','../../outside',True,False),
        ('skills-absolute','.claude/skills','/outside',True,False),
        ('skills-secret','.claude/skills','../API_SECRET=do-not-disclose-fixture',True,False),
        ('skills-ordinary-file','.claude/skills','ordinary text',False,False),
        ('other-claude-symlink','.claude/other','../readme.md',True,False),
        ('other-symlink','other-link','readme.md',True,False),
        ('unlisted-claude-file','.claude/commands/other.md','ordinary text',False,False),
        ('bearer-prose','.agents/skills/verify-app/features.md','Use bearer decisions.\nBearer shares, are discussed.\n',False,True),
        ('bearer-credential','.agents/skills/verify-app/features.md','Bearer do-not-disclose-fixture',False,False),
    ]:
        case=tmp/name; work=case/'source'; work.mkdir(parents=True)
        git(work,'init','-q'); git(work,'config','user.name','Verification'); git(work,'config','user.email','verify@example.invalid')
        (work/'readme.md').write_text('Safe source\n')
        git(work,'add','.'); git(work,'commit','-qm','Initial safe source')
        target=work/path; target.parent.mkdir(parents=True,exist_ok=True)
        if link: target.symlink_to(content)
        else: target.write_text(content)
        if name=='combined-core-paths':
            (work/'.claude/commands').mkdir()
            (work/'.claude/commands/reimage-dev.md').write_text('# Rebuild development image\n')
            (work/'.agents/skills').mkdir(parents=True)
            (work/'.agents/skills/verify.md').write_text('Verify the application\n')
        git(work,'add','--force','.'); git(work,'commit','-qm','Add Claude source')
        if not accept:
            target.unlink(); git(work,'add','--all'); git(work,'commit','-qm','Clean current source')
        git(work,'update-ref','refs/remotes/origin/main','HEAD')
        home=case/'home'; (home/'config').mkdir(parents=True)
        # No real credentials or remote calls: screening precedes admission, which
        # stops on this explicitly absent disposable key. Boat itself is not mocked.
        (home/'config/boat-keys').write_text(str(case/'absent-key')+'\n')
        env=dict(os.environ,FM_HOME=str(home),HOME=str(home),GIT_CONFIG_NOSYSTEM='1',GIT_CONFIG_GLOBAL='/dev/null')
        cmd=['bash',str(root/'bin/fm-boat-run.sh'),'run','--worktree',str(work),'--output',str(case/'output'),'--history-depth','50','--','true']
        p=subprocess.run(cmd,env=env,capture_output=True,text=True,timeout=20)
        result=json.loads((case/'output/result.json').read_text())
        assert 'do-not-disclose-fixture' not in p.stdout+p.stderr+json.dumps(result)
        row={'scenario':name,'exit':p.returncode,'result':result,'stderr':p.stderr.strip()}
        archive=case/'output/upload/source.tar.gz'
        if accept:
            assert p.returncode==69 and result['kind']=='unavailable' and result.get('source_sha256'),row
            restored=case/'restored'; restored.mkdir()
            with tarfile.open(archive) as t:
                row['archive_paths']=[n for n in t.getnames() if not n.startswith('.git/')]
                t.extractall(restored,filter='data')
            assert not (restored/'.claude/skills').is_symlink()
            git(restored,'fsck','--no-reflogs')
            row['history_integrity']='git fsck passed'
            if name=='combined-core-paths':
                assert not (restored/'.claude/skills').exists()
                assert git(restored,'cat-file','blob','HEAD:.claude/skills')=='../.agents/skills'
                assert (restored/'.claude/commands/reimage-dev.md').read_text()=='# Rebuild development image\n'
                row['skills_blob']='../.agents/skills'; row['working_tree_skills']='absent'
            if name=='clean-reimage': assert path in row['archive_paths']
        else:
            assert p.returncode==2 and result['kind']=='invalid' and 'history refused:' in p.stderr,row
            assert not archive.exists(),row
            row['archive']='not created'
        rows.append(row)
        print(name+': PASS '+p.stderr.strip())
(evidence/'boat-screen-live.json').write_text(json.dumps(rows,indent=2)+'\n')
