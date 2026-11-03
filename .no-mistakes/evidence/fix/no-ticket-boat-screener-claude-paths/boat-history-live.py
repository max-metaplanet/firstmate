import json, os, pathlib, subprocess, tarfile, tempfile
repo = pathlib.Path.cwd()
evidence = pathlib.Path(__file__).parent
records = []
def git(p, *args):
    return subprocess.run(['git','-C',str(p),*args], check=True, capture_output=True).stdout
with tempfile.TemporaryDirectory(prefix='.boat-validation-', dir=repo) as scratch:
    scratch = pathlib.Path(scratch)
    old = scratch/'before.py'
    old.write_bytes(git(repo, 'show', '8c8bd9464e651a0634c7de245f5bbc867751fb7e:bin/fm-boat-run.py'))
    cases = [
        ('core-paths', 'clean', '../.agents/skills', True),
        ('reimage-only', 'clean', None, True),
        ('skills-only', None, '../.agents/skills', True),
        ('current-secret', 'edited-secret', None, True),
        ('historical-secret', 'secret', None, False),
        ('historical-binary', 'binary', None, False),
        ('escaping-link', None, '../../outside', False),
        ('absolute-link', None, '/outside', False),
        ('credential-link', None, '../API_SECRET=never-disclose', False),
        ('ordinary-skills-file', None, 'regular', False),
        ('unlisted-claude-file', None, 'unlisted', False),
        ('other-symlink', None, 'other', False),
    ]
    for name, command, link, accepted in cases:
        p = scratch/name; p.mkdir()
        work = p/'work'; work.mkdir()
        git(work,'init','-q','--template=')
        git(work,'config','user.name','Validation')
        git(work,'config','user.email','validation@example.invalid')
        (work/'tracked.txt').write_text('ordinary source\n')
        commandpath=work/'.claude/commands/reimage-dev.md'
        if command:
            commandpath.parent.mkdir(parents=True)
            commandpath.write_bytes({'clean': b'# Reimage development\nRebuild the image.\n', 'edited-secret':b'# Reimage development\n', 'secret':b'API_SECRET=never-disclose\n', 'binary':b'\x00\xff'}[command])
        if link:
            target=work/'.claude/skills'; target.parent.mkdir(exist_ok=True)
            if link == 'regular': target.write_text('ordinary file\n')
            elif link == 'unlisted': (work/'.claude/unlisted.md').write_text('ordinary file\n')
            elif link == 'other': (work/'other-link').symlink_to('tracked.txt')
            else: target.symlink_to(link)
        git(work,'add','--force','.')
        git(work,'commit','-qm','source snapshot')
        if not accepted:
            for target in [commandpath, work/'.claude/skills', work/'.claude/unlisted.md',work/'other-link']:
                if target.exists() or target.is_symlink(): target.unlink()
            git(work,'add','--all'); git(work,'commit','-qm','clean tip')
        git(work,'update-ref','refs/remotes/origin/main','HEAD')
        if command == 'edited-secret': commandpath.write_text('API_SECRET=never-disclose\n')
        home=p/'home'; (home/'config').mkdir(parents=True)
        (home/'config/boat-keys').write_text(str(p/'deliberately-absent-key')+'\n')
        user=p/'user'; user.mkdir()
        env=dict(os.environ,FM_HOME=str(home),HOME=str(user))
        for key in list(env):
            if key.startswith('GIT_') or key.startswith('FM_') and key != 'FM_HOME': env.pop(key)
        def drive(label, program):
            output=p/label
            argv=[*program,'run','--worktree',str(work),'--output',str(output),'--history-depth','2','--','true']
            r=subprocess.run(argv,env=env,capture_output=True,timeout=20)
            result=json.loads((output/'result.json').read_text())
            assert b'never-disclose' not in r.stdout+r.stderr
            record={'case':name,'version':label,'exit':r.returncode,'result':result,'stderr':r.stderr.decode().strip()}
            records.append(record)
            print(json.dumps(record),flush=True)
            return r,output,result,record
        r,out,result,record=drive('target',['bash',str(repo/'bin/fm-boat-run.sh')])
        if accepted:
            assert r.returncode == 69 and result['kind']=='unavailable', record
            assert result['error']=='Boat key unavailable', record
            with tarfile.open(out/'upload/source.tar.gz') as archive:
                names=archive.getnames()
                assert '.claude/skills' not in names
                assert ('other-link' not in names)
                if command and command != 'edited-secret':
                    assert archive.extractfile('.claude/commands/reimage-dev.md').read()==commandpath.read_bytes()
                if command=='edited-secret': assert '.claude/commands/reimage-dev.md' not in names
                extracted=p/'export'; extracted.mkdir()
                archive.extractall(extracted,filter='data')
            fsck=git(extracted,'fsck','--no-reflogs').decode().strip()
            if link:
                assert git(extracted,'cat-file','blob','HEAD:.claude/skills')==link.encode()
                assert not (extracted/'.claude/skills').is_symlink()
            record['archive_verified']={'reimage_in_source':'.claude/commands/reimage-dev.md' in names,'skills_in_source':False,'git_fsck':fsck or 'clean','skills_blob_preserved':bool(link)}
            print(json.dumps({'case':name,'archive_verified':record['archive_verified']}),flush=True)
        else:
            assert r.returncode==2 and result['kind']=='invalid', record
            assert 'history refused:' in result['error'],record
            assert not (out/'upload/source.tar.gz').exists(),record
            assert not list((home/'state/boat-offload/jobs').glob('*.json')),record
        if name in ('reimage-only','skills-only'):
            before,_,before_result,before_record=drive('before',['python3',str(old)])
            assert before.returncode==2 and 'history refused:' in before_result['error'],before_record
(evidence/'boat-history-results.json').write_text(json.dumps(records,indent=2)+'\n')
print('Disposable repositories and homes removed; all history and archive assertions passed.')
