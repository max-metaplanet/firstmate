import json, os, pathlib, subprocess, shutil
root=pathlib.Path.cwd(); lab=root/'.boat-live-test'; evidence=pathlib.Path('~/.no-mistakes/evidence/01M69MH831RGQM6KVY4NK4309X'); repo=lab/'project'; repo.mkdir(); home=lab/'home'; (home/'config').mkdir(parents=True); (lab/'tmp').mkdir()
(home/'config/boat-keys').write_text(str(home/'missing-disposable-key')+' types=default,large\n')
env=dict(os.environ, FM_HOME=str(home), TMPDIR=str(lab/'tmp'), FM_BUILD_LOCK_FILE=str(lab/'build.lock'), PYTHONDONTWRITEBYTECODE='1')
for k in ['FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE']: env.pop(k,None)
def git(*args): return subprocess.check_output(['git','-C',str(repo),*args], text=True,env=env).strip()
git('init','-q'); git('config','user.name','Disposable Test'); git('config','user.email','test@example.invalid')
(repo/'tracked.txt').write_text('base\n'); git('add','.'); git('commit','-qm','base'); base=git('rev-parse','HEAD')
p=repo/'.github/scripts/test-plan'; p.mkdir(parents=True)
(p/'shard-scope.mjs').write_text("import {execFileSync} from 'node:child_process'; export async function readChangedFiles(root,base,head){return execFileSync('git',['-C',root,'diff','--name-only',base,head],{encoding:'utf8'}).trim().split('\\n').filter(Boolean)}\n")
(repo/'tracked.txt').write_text('PR content\n'); git('add','.');git('commit','-qm','PR'); head=git('rev-parse','HEAD')
transcript=[]; results=[]
for case in ['mismatch','unstaged','staged','deleted','staged-deleted','clean','untracked','manual-dirty']:
    git('restore','--source=HEAD','--staged','--worktree','--','tracked.txt')
    if case in ['unstaged','staged','manual-dirty']: (repo/'tracked.txt').write_text('unreviewed correction\n')
    if case in ['deleted','staged-deleted']: (repo/'tracked.txt').unlink()
    if case in ['staged','staged-deleted']:git('add','tracked.txt')
    if case=='untracked': (repo/'untracked.txt').write_text('ignored by upload\n')
    out=lab/('out-'+case)
    command=['bash',str(root/'bin/fm-boat-prepush.sh'),'--worktree',str(repo),'--base',base,'--timeout','60','--output',str(out)]
    if case!='manual-dirty':command+=['--expected-head',base if case=='mismatch' else head]
    r=subprocess.run(command,env=env,capture_output=True,text=True,timeout=35)
    text=r.stdout+r.stderr
    refusal=case in ['mismatch','unstaged','staged','deleted','staged-deleted']
    if refusal:
        assert r.returncode==2 and not out.exists(), (case,r.returncode,text)
        assert ('does not match expected PR head' if case=='mismatch' else 'tracked checkout content differs') in text
        if case=='mismatch': assert base in text and head in text
    else:
        assert r.returncode==1 and 'refusing to run outside a disposable machine' in text, (case,r.returncode,text)
        record=json.loads((out/'verdict.json').read_text()); assert record['head']==head and not record['green']
        assert len(record['attempts'])==1 and record['attempts'][0]['size']=='default'
    transcript.append('SCENARIO '+case+'\nexit='+str(r.returncode)+'\n'+text)
    results.append({'case':case,'expected_refusal':refusal,'exit':r.returncode,'checked_head':head})
(evidence/'boat-cli-transcript.txt').write_text('\n'.join(transcript))
(evidence/'boat-cli-results.json').write_text(json.dumps(results,indent=2))
print(json.dumps(results,indent=2))
