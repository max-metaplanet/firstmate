import os, sys, json, subprocess, shutil
from pathlib import Path
repo=Path.cwd(); root=repo/'.nm-tsc-live'; work=root/'core'; work.mkdir()
evidence=Path('~/.no-mistakes/evidence/01M6F69E73DAH81GDVY9A8R0JM')
env={k:v for k,v in os.environ.items() if not k.startswith(('FM_','BOAT_','GIT_')) and k not in ('NODE_OPTIONS','CI')}
env.update(HOME=str(root/'user'),FM_HOME=str(root/'home'),FM_BUILD_LOCK_INSTALL_DIR=str(root/'install'),FM_BUILD_LOCK_FILE=str(root/'heavy.lock'),FM_HEAVY_SLOTS='1',FM_TASK_ID='isolated-validation',TMPDIR=str(root),GIT_CONFIG_NOSYSTEM='1',GIT_CONFIG_GLOBAL='/dev/null',GIT_AUTHOR_NAME='Validation',GIT_AUTHOR_EMAIL='test@example.invalid',GIT_COMMITTER_NAME='Validation',GIT_COMMITTER_EMAIL='test@example.invalid')
(root/'user').mkdir(); config=root/'home/config'; config.mkdir(parents=True)
(config/'boat-heavy').write_text("core bootstrap='echo noisy-bootstrap >&2; npm install --ignore-scripts --no-audit --no-fund'\n")
(work/'node_modules').symlink_to(root/'node_modules',target_is_directory=True)
(work/'.gitignore').write_text('node_modules/\n*.tsbuildinfo\n*.js\ntrace/\n*.cpuprofile\n')
(work/'index.ts').write_text('const result: number = 42;\n')
(work/'package.json').write_text('{"private":true,"dependencies":{"typescript":"5.9.3"}}\n')
logs=[]
def run(args):
 return subprocess.run([str(x) for x in args],cwd=work,env=env,capture_output=True,timeout=90)
def git(*a):
 r=run(['git',*a]); assert r.returncode==0,r.stderr
try:
 git('init','-q')
 r=run([repo/'bin/fm-heavy-route.py','publish','--home',root/'home','--config',config]); assert r.returncode==0,r.stderr
 cli=['node',str(work/'node_modules/typescript/bin/tsc')]
 cases=[
 ('implicit-incremental-valid',{'noEmit':True,'incremental':True},[],True,0,None),
 ('implicit-incremental-type-error',{'noEmit':True,'incremental':True},[],True,2,None),
 ('no-incremental-valid',{'noEmit':True},[],True,0,None),
 ('named-config',{'noEmit':True,'incremental':True,'tsBuildInfoFile':'named.tsbuildinfo'},[],False,0,'named.tsbuildinfo'),
 ('named-cli',{'noEmit':True,'incremental':True},['--tsBuildInfoFile','named.tsbuildinfo'],False,0,'named.tsbuildinfo'),
 ('named-cli-equals',{'noEmit':True,'incremental':True},['--tsBuildInfoFile=named.tsbuildinfo'],False,None,None),
 ('composite-config',{'noEmit':True,'composite':True},[],False,0,'tsconfig.tsbuildinfo'),
 ('composite-cli',{'noEmit':True},['--composite'],False,None,None),
 ('build-long',{'noEmit':True},['--build'],False,0,None),
 ('build-short',{'noEmit':True},['-b'],False,0,None),
 ('emit-enabled',{},[],False,0,'index.js'),
 ('trace',{'noEmit':True},['--generateTrace','trace'],False,0,'trace/trace.json'),
 ('cpu-profile',{'noEmit':True},['--generateCpuProfile','profile.cpuprofile'],False,0,'profile.cpuprofile'),
 ('explicit-incremental',{'noEmit':True},['--incremental'],False,0,'tsconfig.tsbuildinfo'),
 ('unknown-option',{'noEmit':True},['--invented-future-output=lost'],False,None,None)]
 for name,opts,args,eligible,expected,artifact in cases:
  for f in ('named.tsbuildinfo','tsconfig.tsbuildinfo','index.js','profile.cpuprofile'):
   (work/f).unlink(missing_ok=True)
  shutil.rmtree(work/'trace',ignore_errors=True)
  (work/'index.ts').write_text('const result: number = '+('"wrong"' if 'type-error' in name else '42')+';\n')
  (work/'tsconfig.json').write_text(json.dumps({'compilerOptions':dict(lib=['es5'],skipLibCheck=True,**opts),'files':['index.ts']}))
  git('add','-A'); git('commit','--allow-empty','-qm',name)
  original=run(cli+args)
  # Remove outputs from the independent direct invocation before exercising routing.
  for f in ('named.tsbuildinfo','tsconfig.tsbuildinfo','index.js','profile.cpuprofile'):
   (work/f).unlink(missing_ok=True)
  shutil.rmtree(work/'trace',ignore_errors=True)
  r=run([repo/'bin/fm-heavy-route.py','--kind','tsc','--',*cli,*args])
  stdout=r.stdout.decode(); stderr=r.stderr.decode()
  logs.append(dict(scenario=name,command=cli+args,exit=r.returncode,stdout=stdout,stderr=stderr,direct_exit=original.returncode,direct_stdout=original.stdout.decode(),output_present=bool(artifact and (work/artifact).exists())))
  assert r.returncode==original.returncode,(name,r.stderr,original.stderr)
  assert r.stdout==original.stdout,(name,r.stdout,original.stdout)
  if expected is not None: assert r.returncode==expected,(name,r.stdout,r.stderr)
  assert ('on Boat' in stderr)==eligible,(name,stderr)
  assert stderr.count('heavy-route: the incremental cache is not preserved for this run\n')==int(eligible and bool(opts.get('incremental'))),(name,stderr)
  if eligible: assert 'Boat key unavailable' in stderr and 'discarded remote stdout' in stderr,(name,stderr)
  if artifact: assert (work/artifact).exists(),(name,artifact)
 logs.append({'result':'All real TypeScript boundary and output-preservation assertions passed; eligible commands attempted Boat, then fell back because the isolated account has no API key. Authenticated remote execution remains untested.'})
finally:
 (evidence/'tsc-live-transcript.json').write_text(json.dumps(logs,indent=2)+'\n')
 shutil.rmtree(root)
