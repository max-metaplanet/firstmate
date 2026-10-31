import json, os, pathlib, shutil, subprocess, tarfile, tempfile
ROOT = pathlib.Path.cwd()
EVIDENCE = pathlib.Path('~/.no-mistakes/evidence/01M67XVE7Y1BJFVJ5HDK2V7883')
lab = pathlib.Path(tempfile.mkdtemp(prefix='.boat-validation-', dir=ROOT))
log = []
def record(s):
    log.append(s)
    print(s, flush=True)
def git(p, *args):
    return subprocess.check_output(['git', '-C', str(p), *args], stderr=subprocess.PIPE).decode().strip()
def fixture(name):
    p = lab / name
    w = p / 'source'; w.mkdir(parents=True)
    git(w, 'init', '-q', '--template=')
    git(w, 'config', 'user.name', 'Boat validation')
    git(w, 'config', 'user.email', 'validation@example.invalid')
    (w/'file.txt').write_text('initial\n')
    commit(w, 'initial')
    home = p / 'home'; (home/'config').mkdir(parents=True)
    # Explicitly absent disposable key: never consult operator credentials.
    (home/'config/boat-keys').write_text(str(p/'absent-api-key')+'\n')
    env = dict(os.environ, HOME=str(home), FM_HOME=str(home), GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL='/dev/null', BOAT_NO_UPDATE='1')
    for key in list(env):
        if key.startswith('GIT_') and key not in ('GIT_CONFIG_NOSYSTEM','GIT_CONFIG_GLOBAL'):
            del env[key]
    return p,w,env
def commit(w, message):
    git(w, 'add', '--all', '--force'); git(w, 'commit', '-qm', message)
def run(p,w,env,name,depth=None,wrapper=False):
    if wrapper:
        env = dict(env, FM_BOAT_TEST_HISTORY_DEPTH=str(depth))
        cmd=['bash',str(ROOT/'bin/fm-boat-test-wrapper.sh'),'echo UNEXPECTED_TEST_EXECUTION']
    else:
        cmd=['bash',str(ROOT/'bin/fm-boat-run.sh'),'run','--worktree',str(w),'--output',str(p/name)]
        if depth is not None: cmd += ['--history-depth',str(depth)]
        cmd += ['--','bash','-c','git log --oneline --all']
    r = subprocess.run(cmd,cwd=w,env=env,capture_output=True,text=True,timeout=30)
    record(f'{name}: exit={r.returncode}\n{r.stdout}{r.stderr}')
    assert 'UNEXPECTED_TEST_EXECUTION' not in r.stdout
    return r
roles=['.github/tools/jev/vendor/.claude/agents/security-compliance.md','.github/tools/jev/vendor/.claude/agents/release-engineer.md']
try:
    p,w,env=fixture('allowlist')
    for role in roles:
        target=w/role; target.parent.mkdir(parents=True,exist_ok=True); target.write_text('# Role\nReview changes.\n')
    unlisted=w/'.github/tools/jev/vendor/.claude/agents/other.md'; unlisted.write_text('Not allowlisted\n')
    commit(w,'add role files')
    r=run(p,w,env,'default-package'); assert r.returncode==69
    with tarfile.open(p/'default-package/upload/source.tar.gz') as t:
        names=t.getnames(); assert all(x in names for x in roles); assert str(unlisted.relative_to(w)) not in names; assert '.git' not in names
        record('Default package members: '+json.dumps(names))
    (w/roles[0]).write_text('API_SECRET=screening-canary-DO-NOT-PRINT\n')
    r=run(p,w,env,'screened-package'); assert r.returncode==69
    assert 'screening-canary-DO-NOT-PRINT' not in r.stdout+r.stderr
    with tarfile.open(p/'screened-package/upload/source.tar.gz') as t:
        assert roles[0] not in t.getnames() and roles[1] in t.getnames()
        record('Credential-bearing role omitted; other safe role retained.')

    p,w,env=fixture('real-history')
    for i in range(5):
        (w/'file.txt').write_text(f'version {i}\n'); commit(w,f'version {i}')
    base=git(w,'rev-parse','HEAD'); old=git(w,'rev-parse','HEAD~2')
    git(w,'update-ref','refs/remotes/origin/main',base)
    git(w,'checkout','-qb','feature','HEAD~1')
    (w/'feature.txt').write_text('feature\n'); commit(w,'feature')
    head=git(w,'rev-parse','HEAD')
    git(w,'update-ref','refs/heads/unrelated',old); git(w,'update-ref','refs/tags/private',old); git(w,'update-ref','refs/stash',old)
    git(w,'config','remote.origin.url','https://local-only.invalid/private')
    (w/'file.txt').write_text('working edit\n'); (w/'feature.txt').unlink()
    r=run(p,w,env,'bounded-package',2); assert r.returncode==69
    restored=p/'restored'; restored.mkdir()
    with tarfile.open(p/'bounded-package/upload/source.tar.gz') as t: t.extractall(restored,filter='data')
    assert git(restored,'rev-parse','HEAD')==head and git(restored,'rev-parse','origin/main')==base
    assert git(restored,'rev-list','--count','--all')=='3'
    assert set(git(restored,'for-each-ref','--format=%(refname)').splitlines())=={'refs/heads/fm-boat-test','refs/remotes/origin/main'}
    assert git(restored,'remote')=='' and not (restored/'.git/logs').exists()
    assert subprocess.run(['git','-C',str(restored),'cat-file','-e',old],capture_output=True).returncode!=0
    assert (restored/'file.txt').read_text()=='working edit\n' and not (restored/'feature.txt').exists()
    assert git(restored,'fsck','--no-reflogs')==''
    record('Restored shallow Git: '+git(restored,'log','--all','--format=%h %s'))
    record('Restored refs: '+git(restored,'for-each-ref','--format=%(refname) %(objectname)'))
    record('Restored working changes: '+git(restored,'status','--short'))
    record('Old out-of-depth commit unavailable; no local remote, stash, tags, unrelated refs or reflogs; git fsck clean.')

    for name,path,data,message in [
        ('excluded','.env','historical-canary-DO-NOT-PRINT','unsafe path'),
        ('credential','ordinary.txt','password=historical-canary-DO-NOT-PRINT','unsafe content'),
        ('binary','blob.dat','\x00historical-canary-DO-NOT-PRINT','binary content'),
        ('commit','ordinary.txt','ordinary text','API_SECRET=historical-canary-DO-NOT-PRINT'),
        ('role',roles[0],'password=historical-canary-DO-NOT-PRINT','unsafe role'),
    ]:
        p,w,env=fixture('unsafe-'+name)
        target=w/path; target.parent.mkdir(parents=True,exist_ok=True); target.write_text(data); commit(w,message)
        target.unlink(); commit(w,'clean tip'); git(w,'update-ref','refs/remotes/origin/main','HEAD')
        r=run(p,w,env,'refused',2)
        assert r.returncode==2 and 'history refused:' in r.stderr and 'historical-canary-DO-NOT-PRINT' not in r.stdout+r.stderr
        assert not (p/'refused/upload/source.tar.gz').exists()
        record(name+': entire historical export refused before account access, with no canary disclosure.')
        # Depth one deliberately omits unsafe ancestors.
        r=run(p,w,env,'depth-one',1); assert r.returncode==69

    p,w,env=fixture('invalid-options')
    r=run(p,w,env,'missing-base',2); assert r.returncode==2 and 'origin/main' in r.stderr
    for depth in (0,-1,1001,'bad'):
        r=run(p,w,env,'invalid-'+str(depth),depth); assert r.returncode==2
    # Wrapper runs from nested fixture, so its ../ scratch stays within lab.
    r=run(p,w,env,'wrapper-missing-base',2,wrapper=True)
    assert r.returncode==2 and 'origin/main' in r.stderr and 'running locally' not in r.stderr
    record('Wrapper forwards opt-in to real adapter; missing real base fails without local fallback.')
    record('Remote Boat execution not attempted: isolated account has no key, and operator credentials are outside the permitted data boundary.')
finally:
    shutil.rmtree(lab)
    (EVIDENCE/'boat-live-transcript.txt').write_text('\n'.join(log)+'\n')
