import os, subprocess, json
from pathlib import Path
root=Path.cwd(); lab=root/'.test-orchestrated-boat'; work=lab/'project'; home=lab/'home'
evidence=Path('~/.no-mistakes/evidence/01M6FPT0Q83JFMAH69XRKGBNXD')
env={k:v for k,v in os.environ.items() if not k.startswith(('FM_', 'TURBO_', 'NX_', 'LERNA_', 'npm_config_', 'NPM_CONFIG_')) and k not in ('NODE_OPTIONS','CI','BOAT_API_KEY')}
env.update(HOME=str(lab/'user'), XDG_CONFIG_HOME=str(lab/'user/.config'), FM_HOME=str(home), FM_BUILD_LOCK_INSTALL_DIR=str(lab/'install'), FM_BUILD_LOCK_FILE=str(lab/'heavy.lock'), FM_TASK_ID='isolated-live-test', FM_HEAVY_SLOTS='1', XDG_DATA_HOME=str(lab/'user/.local/share'), PNPM_HOME=str(lab/'user/pnpm'), PATH=str(work/'node_modules/.bin')+os.pathsep+env['PATH'], TURBO_TELEMETRY_DISABLED='1')
# Telemetry switch is removed below because the router conservatively rejects TURBO_* overrides.
env.pop('TURBO_TELEMETRY_DISABLED')
(work/'.gitignore').write_text('node_modules/\n.turbo/\n')
pkg=json.loads((work/'package.json').read_text()); pkg.update(name='project',private=True,packageManager='pnpm@10.20.0'); (work/'package.json').write_text(json.dumps(pkg))
(work/'pnpm-workspace.yaml').write_text('packages:\n  - packages/*\n')
(work/'turbo.json').write_text(json.dumps({'tasks':{'type-check':{'cache':False,'outputs':[]}}}))
for name in ('a','b'):
 d=work/'packages'/name; d.mkdir(parents=True,exist_ok=True)
 (d/'package.json').write_text(json.dumps({'name':name,'version':'1.0.0','scripts':{'type-check':'tsc --noEmit'}}))
 (d/'tsconfig.json').write_text('{"compilerOptions":{"noEmit":true},"files":["index.ts"]}')
 (d/'index.ts').write_text('const value: number = 1;\n')
for args in (['init','-q'],['config','user.name','Test'],['config','user.email','test@example.invalid'],['add','.'],['commit','--allow-empty','-qm','disposable project']):
 subprocess.run(['git',*args],cwd=work,env=env,check=True,capture_output=True)
(home/'config/boat-heavy').write_text("project bootstrap='npm ci --ignore-scripts' timeout=60\n")
subprocess.run([str(root/'bin/fm-heavy-route.py'),'publish','--home',str(home),'--config',str(home/'config')],env=env,check=True,capture_output=True)
env['NODE_OPTIONS']=subprocess.run([str(root/'bin/fm-build-lock.py'),'node-option'],env=env,check=True,capture_output=True,text=True).stdout.strip()
results=[]
def drive(name,args,expect,attempts,mutate=None):
 if mutate: mutate()
 r=subprocess.run(['node',*args],cwd=work,env=env,capture_output=True,text=True,timeout=90)
 text='$ node '+ ' '.join(args)+'\nexit='+str(r.returncode)+'\nSTDOUT\n'+r.stdout+'\nSTDERR\n'+r.stderr
 (evidence/(name+'.log')).write_text(text)
 print(text,flush=True)
 assert r.returncode==expect,(name,r.returncode)
 assert r.stderr.count('orchestrator on Boat')==attempts,(name,r.stderr)
 assert r.stderr.count('running locally in a heavy slot')==1,(name,r.stderr)
 results.append({'name':name,'exit':r.returncode,'boat_attempts':attempts})
 return r
for tool,args in [('pnpm',['-r','type-check']),('pnpm',['--filter=a','type-check']),('turbo',['type-check'])]:
 r=drive(tool+('-filtered' if '--filter=a' in args else '-relative')+'-unavailable',['./node_modules/.bin/'+tool,*args],0,1)
 assert 'Boat did not run it' in r.stderr
 assert 'type-check' in r.stdout
# Input boundary: an untracked file must prevent even the Boat attempt.
(work/'untracked.txt').write_text('not uploaded\n')
r=drive('untracked-input-refusal',['./node_modules/.bin/pnpm','-r','type-check'],0,0)
assert 'untracked file untracked.txt' in r.stderr
(work/'untracked.txt').unlink()
# Cache writes must stay local even though all tasks are otherwise safe.
(work/'turbo.json').write_text(json.dumps({'tasks':{'type-check':{'cache':True,'outputs':[]}}}))
r=drive('cache-writing-stays-local',['./node_modules/.bin/turbo','type-check'],0,0)
assert 'writes files Boat would not bring back' in r.stderr
# Propagate a real compiler failure through fallback without retrying children.
(work/'packages/a/index.ts').write_text('const value: number = "wrong";\n')
r=drive('local-failure-verdict',['./node_modules/.bin/pnpm','-r','type-check'],2,1)
assert 'TS2322' in r.stdout
(evidence/'live-results.json').write_text(json.dumps(results,indent=2)+'\n')
for result in lab.glob('.fm-test-scratch/**/result.json'):
 print('ADAPTER RESULT',result.read_text(),flush=True)
