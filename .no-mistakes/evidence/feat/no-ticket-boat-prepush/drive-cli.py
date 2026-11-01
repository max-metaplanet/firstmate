import os, pathlib, subprocess, tempfile, shutil, json
root=pathlib.Path.cwd()
evidence=pathlib.Path('~/.no-mistakes/evidence/01M6CMQYVESQYCNMD3GZBJJMSZ')
scratch=pathlib.Path(tempfile.mkdtemp(prefix='.prepush-live-',dir=root))
log=(evidence/'cli-transcript.txt').open('w')
env=dict(os.environ, PYTHONDONTWRITEBYTECODE='1', BOAT_NO_UPDATE='1', GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_NOSYSTEM='1')
for k in ('FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE','CONFIG'):
    env.pop(k,None)
def run(args,cwd=None,expected=0):
    p=subprocess.run(args,cwd=cwd or root,env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=45)
    log.write('$ '+ ' '.join(map(str,args))+'\n'+p.stdout+'\nexit='+str(p.returncode)+'\n'); log.flush()
    assert p.returncode==expected,(args,p.returncode,p.stdout)
    return p.stdout
try:
    repo=scratch/'project'; repo.mkdir()
    home=scratch/'home'; (home/'config').mkdir(parents=True)
    env['FM_HOME']=str(home)
    run(['git','init','-q'],repo)
    run(['git','config','user.email','test@example.invalid'],repo)
    run(['git','config','user.name','Disposable test'],repo)
    (repo/'file').write_text('base\n')
    run(['git','add','.'],repo); run(['git','commit','-qm','base'],repo)
    base=run(['git','rev-parse','HEAD'],repo).strip()
    run(['git','update-ref','refs/remotes/origin/release/x',base],repo)
    run(['git','update-ref','refs/remotes/origin/main',base],repo)
    run(['git','symbolic-ref','refs/remotes/origin/HEAD','refs/remotes/origin/main'],repo)
    (repo/'file').write_text('head\n');run(['git','add','.'],repo);run(['git','commit','-qm','head'],repo)
    head=run(['git','rev-parse','HEAD'],repo).strip()
    command=['bash',str(root/'bin/fm-boat-prepush.sh'),'--worktree',str(repo),'--output',str(scratch/'out')]
    out=run(command+['--expected-head','0'*40],expected=2)
    assert 'does not match expected PR head' in out
    (repo/'file').write_text('unstaged\n')
    out=run(command+['--expected-head',head],expected=2);assert 'tracked checkout content differs' in out
    run(['git','add','.'],repo)
    out=run(command+['--expected-head',head],expected=2);assert 'tracked checkout content differs' in out
    run(['git','restore','--staged','file'],repo);run(['git','restore','file'],repo)
    (repo/'untracked').write_text('permitted')
    # The fixture owns only the project's changed-file input contract. No lane
    # or Boat response is replaced; heavy execution remains untested.
    planner=repo/'.github/scripts/test-plan'; planner.mkdir(parents=True)
    (planner/'shard-scope.mjs').write_text("import {execFileSync} from 'node:child_process'; export async function readChangedFiles(root,base,head){return execFileSync('git',['-C',root,'diff','--name-only',base,head],{encoding:'utf8'}).trim().split('\\n').filter(Boolean)}\n")
    (home/'config/boat-keys').write_text(str(home/'absent-test-key')+'\n')
    # The adapter runs without any authority to inspect the operator's login.
    for name,extra in [('remote-only',['--base','release/x']),('default',[])]:
        out=run(command+extra+['--expected-head',head],expected=1)
        assert base[:12]+'..'+head[:12] in out
        assert 'Boat key unavailable' in out or 'Boat unavailable' in out
        verdict=json.loads((scratch/'out/verdict.json').read_text());assert not verdict['green']
        shutil.copyfile(scratch/'out/verdict.json',evidence/(name+'-verdict.json'))
    # A deliberately stale local branch must lose to the remote-tracking base.
    run(['git','branch','release/x',head],repo)
    out=run(command+['--base','release/x','--expected-head',head],expected=1)
    assert base[:12]+'..'+head[:12] in out
    run(['python3',str(root/'bin/fm-boat-prepush-remote.py')],cwd=repo,expected=70)
    # Exercise the generated worker instructions as the owned output contract.
    (home/'config/boat-prepush').write_text('satellite timeout=1200 history-depth=50\n')
    script='source bin/fm-dod-lib.sh\nfm_dod_block "$1" test fm/test none release/x "" "" "" "$2"\n'
    for mode in ('no-mistakes','direct-PR'):
        out=run(['bash','-c',script,'driver',mode,'satellite'])
        assert 'fm-boat-prepush.sh --timeout 1200 --base release/x --history-depth 50' in out
        assert '--expected-head' in out
        (evidence/(mode+'-instructions.txt')).write_text(out)
        out=run(['bash','-c',script,'driver',mode,'unlisted']);assert 'fm-boat-prepush.sh' not in out
    (home/'config/boat-prepush').write_text('satellite timeout=1200\nsatellite timeout=90\n')
    out=run(['bash','-c',script,'driver','no-mistakes','satellite'],expected=1)
    assert 'second time' in out
    log.write('All targeted CLI and rendered-output assertions passed. No remote lane was run.\n')
finally:
    shutil.rmtree(scratch)
    log.close()
