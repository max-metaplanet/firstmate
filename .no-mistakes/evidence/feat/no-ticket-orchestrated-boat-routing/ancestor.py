import os,subprocess,json,shutil
from pathlib import Path
root=Path.cwd(); lab=root/'.test-orchestrated-boat'; work=lab/'project'; evidence=Path('~/.no-mistakes/evidence/01M6FPT0Q83JFMAH69XRKGBNXD')
env={k:v for k,v in os.environ.items() if not k.startswith(('FM_', 'TURBO_', 'NX_', 'LERNA_', 'npm_config_', 'NPM_CONFIG_')) and k not in ('NODE_OPTIONS','CI','BOAT_API_KEY')}
env.update(HOME=str(lab/'user'),XDG_CONFIG_HOME=str(lab/'user/.config'),XDG_DATA_HOME=str(lab/'user/.local/share'),PNPM_HOME=str(lab/'user/pnpm'),PATH=str(work/'node_modules/.bin')+os.pathsep+env['PATH'],FM_HOME=str(lab/'home'), FM_BUILD_LOCK_INSTALL_DIR=str(lab/'install'),FM_BUILD_LOCK_FILE=str(lab/'heavy.lock'),FM_TASK_ID='isolated-live-test',FM_HEAVY_SLOTS='1')
env['NODE_OPTIONS']=subprocess.run([str(root/'bin/fm-build-lock.py'),'node-option'],env=env,capture_output=True,text=True,check=True).stdout.strip()
(work/'packages/a/index.ts').write_text('const value: number = 1;\n')
args=['node','./node_modules/.bin/pnpm','-r','exec','tsc','--noEmit']
r=subprocess.run(args,cwd=work,env=env,capture_output=True,text=True,timeout=90)
log='$ '+' '.join(args)+'\nexit='+str(r.returncode)+'\nSTDOUT\n'+r.stdout+'\nSTDERR\n'+r.stderr
(evidence/'genuine-pnpm-ancestor.log').write_text(log); print(log)
assert r.returncode==0
assert 'orchestrator on Boat' not in r.stderr
assert r.stderr.count('runs under pnpm -r')==2
# Explicit request for a local pnpm output report must be honored locally.
(work/'pnpm-workspace.yaml').write_text('packages:\n  - packages/*\nreportSummary: true\n')
args=['node','./node_modules/.bin/pnpm','-r','type-check']
r=subprocess.run(args,cwd=work,env=env,capture_output=True,text=True,timeout=90)
report=work/'pnpm-exec-summary.json'
log='$ '+' '.join(args)+'\nexit='+str(r.returncode)+'\nSTDOUT\n'+r.stdout+'\nSTDERR\n'+r.stderr+'\nREPORT\n'+(report.read_text() if report.exists() else 'MISSING')
(evidence/'pnpm-summary-stays-local.log').write_text(log); print(log)
assert r.returncode==0 and 'orchestrator on Boat' not in r.stderr and report.is_file()
shutil.copy2(report,evidence/'pnpm-exec-summary.json')
# Preserve adapter results and the repeatable drivers before deleting the lab.
for i,result in enumerate(sorted(lab.glob('.fm-test-scratch/**/result.json'))):
 shutil.copy2(result,evidence/('adapter-result-'+str(i)+'.json'))
shutil.copy2(lab/'drive.py',evidence/'drive.py')
shutil.copy2(lab/'ancestor.py',evidence/'ancestor.py')
