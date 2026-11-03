import json, os, pathlib, shutil, subprocess, tarfile
R = pathlib.Path.cwd()
B = R / '.fm-test-scratch/boat-live-validation'
E = pathlib.Path('~/.no-mistakes/evidence/01M6FFQ4GGRBJDZCB7MQ06AZ1W')
H = B / 'home'
(H / 'config').mkdir(parents=True, exist_ok=True)
U = B / 'user'
U.mkdir(exist_ok=True)
env = dict(os.environ, HOME=str(U), FM_HOME=str(H), FM_BUILD_LOCK_INSTALL_DIR=str(B/'install'), FM_BUILD_LOCK_FILE=str(B/'heavy.lock'), FM_HEAVY_SLOTS='1', FM_TASK_ID='live-validation')
for key in ('NODE_OPTIONS','FM_BUILD_LOCK_HELD','FM_BUILD_LOCK_BYPASS','FM_BOAT_BIN'):
    env.pop(key, None)
# Explicitly refer only to a missing disposable key, never operator credentials.
(H/'config/boat-keys').write_text(str(B/'missing-boat-key')+'\n')
log=[]
def call(args, cwd=None, **kw):
    return subprocess.run(list(map(str,args)), cwd=cwd, env=env, capture_output=True, text=True, timeout=90, **kw)
def git(work,*args):
    p=call(['git','-C',work,*args]); assert p.returncode==0,p.stderr
    return p.stdout.strip()
def init(name):
    w=B/name; w.mkdir()
    git(w,'init','-q');git(w,'config','user.name','Live validation');git(w,'config','user.email','test@example.invalid')
    return w
def commit(w,msg):
    git(w,'add','-A');git(w,'commit','-qm',msg)
    return git(w,'rev-parse','HEAD')
def runboat(w,name,history=None,inputs=()):
    out=B/name
    args=['bash',R/'bin/fm-boat-run.sh','run','--worktree',w,'--output',out]
    if history: args+=['--history-depth',str(history)]
    for item in inputs: args+=['--input',item]
    p=call(args+['--','true'])
    result=json.loads((out/'result.json').read_text())
    log.append({'case':name,'exit':p.returncode,'stdout':p.stdout,'stderr':p.stderr,'result':result})
    return p,out,result
# Drive actual archive preparation through the public adapter, before key admission.
w=init('source-project')
files={'.npmrc':'registry=https://registry.npmjs.org/\n', '.claude/settings.json':'{"permissions":{"allow":[]}}\n', '.claude/settings.local.json':'Bearer decisions, stay with reviewers.\n', '.claude/settings.example.json':'Bearer shares.\n', '.claude/commands/reimage-dev.md':'Use Bearer shortCredential\n', '.github/tools/jev/vendor/.claude/agents/security-compliance.md':'review carefully\n', '.github/tools/jev/vendor/.claude/agents/release-engineer.md':'Bearer shares, stay scoped\n', '.claude/private.md':'excluded fixture\n', '.env':'excluded fixture\n', 'vendor/runtime.js':'original\n', 'deleted.txt':'deleted\n', '.gitignore':'node_modules/\n'}
for n,v in files.items():
    f=w/n;f.parent.mkdir(parents=True,exist_ok=True);f.write_text(v)
(w/'.claude/skills').symlink_to('../skills')
(w/'skills').mkdir();(w/'skills/readme').write_text('safe skill\n')
head=commit(w,'source fixture')
git(w,'update-ref','refs/remotes/origin/main',head)
(w/'vendor/runtime.js').write_text('edited\n');(w/'deleted.txt').unlink()
(w/'added.txt').write_text('newly staged\n');git(w,'add','added.txt')
p,out,res=runboat(w,'source-evidence',inputs=['added.txt'])
assert p.returncode==69 and res['kind']=='unavailable' and 'Boat key unavailable' in p.stderr
with tarfile.open(out/'upload/source.tar.gz') as tar:
    names=tar.getnames()
    for n in ('.npmrc','.claude/settings.json','.claude/settings.local.json','.claude/settings.example.json','.github/tools/jev/vendor/.claude/agents/security-compliance.md','.github/tools/jev/vendor/.claude/agents/release-engineer.md','added.txt'):
        assert n in names,n
    for n in ('.claude/commands/reimage-dev.md','.claude/private.md','.env','.claude/skills','deleted.txt'):
        assert n not in names,n
    assert tar.extractfile('vendor/runtime.js').read()==b'edited\n'
    assert tar.extractfile('added.txt').read()==b'newly staged\n'
(E/'source-manifest.json').write_text(json.dumps({'members':names,'edited_vendor':tarfile.open(out/'upload/source.tar.gz').extractfile('vendor/runtime.js').read().decode(),'assertions':'safe allowlist preserved; bearer-token file excluded; skills symlink skipped; tracked edits/deletions and staged input applied'},indent=2)+'\n')
# Real ancestry and promisor omissions: archive git metadata must retain identities.
h=init('history-project')
(h/'safe.txt').write_text('base\n');(h/'old.txt').write_text('Bearer historicalCredential\n')
(h/'.claude').mkdir();(h/'.claude/skills').symlink_to('../skills')
(h/'skills').mkdir();(h/'skills/readme').write_text('safe\n')
base=commit(h,'base history');git(h,'update-ref','refs/remotes/origin/main',base)
oldoid=git(h,'rev-parse','HEAD:old.txt')
(h/'old.txt').write_text('safe now\n');(h/'safe.txt').write_text('head\n')
head=commit(h,'head history')
p,out,res=runboat(h,'history-evidence',history=2)
assert p.returncode==69 and res['kind']=='unavailable',p.stderr
x=B/'extracted-history';x.mkdir()
with tarfile.open(out/'upload/source.tar.gz') as tar: tar.extractall(x,filter='data')
assert git(x,'rev-parse','HEAD')==head
assert git(x,'rev-parse','origin/main')==base
assert git(x,'rev-list','--count','HEAD')=='2'
assert git(x,'log','--format=%s','HEAD')=='head history\nbase history'
assert not (x/'.claude/skills').exists()
assert git(x,'cat-file','-p','HEAD:.claude/skills')=='../skills'
missing=call(['git','-C',x,'cat-file','-e',oldoid]);assert missing.returncode!=0
fsck=call(['git','-C',x,'fsck']);assert fsck.returncode==0,fsck.stderr
(E/'history-proof.json').write_text(json.dumps({'original_head':head,'exported_head':git(x,'rev-parse','HEAD'),'original_main':base,'exported_main':git(x,'rev-parse','origin/main'),'subjects':git(x,'log','--format=%s','HEAD'),'fsck_exit':fsck.returncode,'historical_credential_blob_read_exit':missing.returncode,'skills_target_git_only':git(x,'cat-file','-p','HEAD:.claude/skills')},indent=2)+'\n')
# Commit bytes cannot be withheld: suspicious bearer must refuse the whole upload.
git(h,'commit','--allow-empty','-qm','Bearer unsafeCommitCredential')
p,out,res=runboat(h,'unsafe-history',history=2)
assert p.returncode==2 and 'history refused' in p.stderr and not (out/'upload/source.tar.gz').exists()
# Genuine compiler invoked through the installed worker preload.
t=B/'tooling/node_modules/typescript'
w=init('compiler-project')
(w/'.gitignore').write_text('node_modules/\n*.tsbuildinfo\ntrace/\nprofile.cpuprofile\n')
(w/'node_modules').mkdir();(w/'node_modules/typescript').symlink_to(t)
(w/'index.ts').write_text('const answer: number = 42;\n')
(w/'tsconfig.json').write_text(json.dumps({'compilerOptions':{'noEmit':True,'incremental':True},'files':['index.ts']}))
commit(w,'compiler fixture')
(H/'config/boat-heavy').write_text("compiler-project bootstrap='true'\n")
p=call([R/'bin/fm-heavy-route.py','publish','--home',H,'--config',H/'config']);assert p.returncode==0,p.stderr
p=call([R/'bin/fm-build-lock.py','node-option']);assert p.returncode==0,p.stderr
env['NODE_OPTIONS']=p.stdout.strip()
compiler=['node',w/'node_modules/typescript/bin/tsc']
def compile_case(name,args=(),before=None,expect=0,reason=None):
    if before: before()
    p=call(compiler+list(args),cwd=w)
    log.append({'case':name,'argv':list(map(str,compiler+list(args))),'exit':p.returncode,'stdout':p.stdout,'stderr':p.stderr})
    assert p.returncode==expect,(name,p.stdout,p.stderr)
    if reason: assert reason in p.stderr,(name,p.stderr)
    return p
p=compile_case('eligible-implicit-incremental',reason='Boat did not run it')
assert p.stdout=='' and p.stderr.count('incremental cache is not preserved')==1 and 'tsc on Boat' in p.stderr
(w/'index.ts').write_text('const answer: number = "wrong";\n')
p=compile_case('compiler-error-survives-fallback',expect=2,reason='Boat did not run it')
assert 'TS2322' in p.stdout and 'heavy-route' not in p.stdout
(w/'index.ts').write_text('const answer: number = 42;\n')
p=compile_case('named-build-info-stays-local',['--tsBuildInfoFile','named.tsbuildinfo'],reason='unknown or ambiguous')
assert 'tsc on Boat' not in p.stderr and (w/'named.tsbuildinfo').exists()
p=compile_case('unknown-option-stays-local',['--invented-option'],expect=1,reason='unknown or ambiguous')
assert 'TS5023' in p.stdout and 'tsc on Boat' not in p.stderr
(w/'untracked.ts').write_text('const extra = 1;\n')
p=compile_case('untracked-source-stays-local',reason='untracked file')
assert 'tsc on Boat' not in p.stderr
(w/'untracked.ts').unlink()
for kind in ('queue-preflight','next-build','playwright'):
    p=call([R/'bin/fm-heavy-route.py','--kind',kind,'--','bash','-c','test -n "$FM_BUILD_LOCK_HELD" && printf "local heavy slot claimed\\n"'],cwd=w)
    log.append({'case':kind+'-stays-local','exit':p.returncode,'stdout':p.stdout,'stderr':p.stderr})
    assert p.returncode==0 and p.stdout=='local heavy slot claimed\n' and 'on Boat' not in p.stderr
(E/'live-cli-transcript.json').write_text(json.dumps(log,indent=2)+'\n')
print(json.dumps({'result':'pass','evidence':['source-manifest.json','history-proof.json','live-cli-transcript.json'],'cases':[r['case'] for r in log]},indent=2))
