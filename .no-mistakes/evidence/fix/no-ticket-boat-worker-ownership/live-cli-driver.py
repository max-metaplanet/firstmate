import json, os, subprocess
from pathlib import Path
root=Path.cwd(); scratch=root/'.boat-test-phase/live'; scratch.mkdir()
home=scratch/'home'; (home/'state').mkdir(parents=True)
metadata=home/'state/proof-task.meta'
metadata.write_text(f'endpoint_task_id=proof-task\nkind=ship\nspawn_gen=proof-launch-1\nworktree={root}\n')
env=dict(os.environ,FM_HOME=str(home),FM_TASK_ID='proof-task',FM_TASK_GENERATION='proof-launch-1',PYTHONDONTWRITEBYTECODE='1')
env.pop('NO_MISTAKES_EXECUTION_REF',None); env.pop('NO_MISTAKES_EXECUTION_SOCKET',None)
cli=['bash',str(root/'bin/fm-boat-run.sh')]
def run(args,custom=env):
 r=subprocess.run(cli+args,env=custom,text=True,capture_output=True,timeout=30)
 print(json.dumps(dict(argv=args,exit=r.returncode,stdout=r.stdout.strip(),stderr=r.stderr.strip())),flush=True)
 return r
r=run(['caller-origin','--worktree',str(root)])
assert r.returncode==0
assert json.loads(r.stdout)==dict(namespace='firstmate',home=str(home),task='proof-task',generation='proof-launch-1')
for key,value in [('FM_TASK_GENERATION','old-launch'),('FM_TASK_ID','other-task')]:
 assert run(['caller-origin','--worktree',str(root)],dict(env,**{key:value})).returncode==70
with metadata.open('a') as f: f.write('spawn_gen=proof-launch-1\n')
assert run(['caller-origin','--worktree',str(root)]).returncode==70
metadata.write_text(f'endpoint_task_id=proof-task\nkind=ship\nspawn_gen=proof-launch-1\nworktree={root}\n')
owner=dict(home=str(home),task='proof-task',generation='proof-launch-1',worktree=str(root))
valid=dict(kind='completed',remote_exit=0,adapter_exit=0,provider='boat',cleanup='retained',lease=dict(state='idle',owner=owner))
result=scratch/'result.json'
for label,doc,expected in [('exact',valid,'completed'),('stale',dict(valid,lease=dict(state='idle',owner=dict(owner,generation='old-launch'))),'adapter-failure'),('foreign-home',dict(valid,lease=dict(state='idle',owner=dict(owner,home=str(scratch/'other-home')))),'adapter-failure'),('foreign-task',dict(valid,lease=dict(state='idle',owner=dict(owner,task='other-task'))),'adapter-failure'),('busy',dict(valid,lease=dict(state='busy',owner=owner)),'adapter-failure'),('cleanup-unknown',dict(valid,cleanup='unknown'),'adapter-failure'),('deleted-operator',dict(valid,cleanup='deleted'),'completed')]:
 result.write_text(json.dumps(doc)); print(label,flush=True)
 r=run(['check-result','--worktree',str(root),'--result',str(result),'--exit','0'])
 assert r.returncode==0 and r.stdout.strip()==expected
print('All public CLI origin and retained-result scenarios passed; no Boat allocation attempted.',flush=True)
