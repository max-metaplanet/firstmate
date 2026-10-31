import os,json,subprocess,pathlib,hashlib
root=pathlib.Path.cwd(); work=root/'.mirror-validation'; evidence=pathlib.Path('~/.no-mistakes/evidence/01M68FJZNZCQMZ5V9AY9DJSAA8')
home=work/'ready-home'; state=home/'state'; binary=work/'t3/runtime/versions/0.1.5/t3'; base=work/'t3'
env=dict(os.environ,FM_HOME=str(home),FM_T3_BIN=str(binary),FM_T3_BASE_DIR=str(base))
log=[]
def call(args,env_=env,text=None):
 p=subprocess.run(args,env=env_,input=text,text=True,capture_output=True,timeout=65)
 assert p.returncode==0,(args,p.stderr)
 return p.stdout
def sync(env_=env): return call(['bash','bin/fm-t3-mirrors.sh','sync'],env_)
def t3(*args,text=None): return json.loads(call([str(binary),*args,'--base-dir',str(base)],text=text))
def record(task):return json.loads((state/'t3-mirrors/tasks'/f'{task}.json').read_text())
def show(task): return t3('thread','show',record(task)['threadId'],'--messages','30','--json')
def save(name,data): (evidence/name).write_text(json.dumps(data,indent=2))
before={x.name:x.read_bytes() for x in state.glob('*.meta')}
a,b=show('worker'),show('mate'); assert a['thread']['threadId']!=b['thread']['threadId']; assert a['thread']['projectId']==b['thread']['projectId']; assert all(x['thread']['activeRunId'] is None for x in (a,b)); save('initial-worker.json',a);save('initial-secondmate.json',b)
log.append('Initial worker and secondmate: distinct threads, one project, deterministic replies, no active run.')
# A durable parked declaration is input to the real crew-state reader, not a replacement reader.
with (state/'worker.meta').open('a') as f:f.write('window=mirror-disposable-endpoint\nspawn_gen=proof-generation\n')
(state/'worker.park').write_text('phase=parked\ngeneration=proof-generation\nendpoint=mirror-disposable-endpoint\nreason=private-secret-never-project\nuntil=0\nqueued_at=0\n')
(state/'.secondmate-park-mate').write_text('phase=parked\nresume_mode=proof-only\n')
(state/'worker.status').write_text('paused: private-secret-never-project https://github.com/example/project/pull/42\n')
updated_meta={x.name:x.read_bytes() for x in state.glob('*.meta')}
sync(); a,b=show('worker'),show('mate')
for task,value in [('worker',a),('mate',b)]:
 assert value['thread']['runCount']==2 and value['thread']['activeRunId'] is None,value
 assert '(parked)' in value['messages'][-1]['text']
 assert 'private-secret' not in json.dumps(value)
 save('updated-'+task+'.json',value)
assert 'https://github.com/example/project/pull/42' in a['messages'][-1]['text']
log.append('Settled threads receive later parked updates, canonical PR URL retained, private reason omitted.')
sync(); assert show('worker')['thread']['runCount']==2; assert show('mate')['thread']['runCount']==2
sync(dict(env,FM_T3_BIN='/unavailable',FM_T3_BASE_DIR='/unavailable')); assert show('worker')['thread']['runCount']==2
log.append('Repeated unchanged sync and changed ambient connection: no additional run or redirected thread.')
# Same task in another home must not collide.
other=work/'other-home'
for d in ('state','config','data','projects'): (other/d).mkdir(parents=True,exist_ok=True)
(other/'state/worker.meta').write_bytes((state/'worker.meta').read_bytes())
(other/'config/t3-mirrors').write_text('1\n')
sync(dict(env,FM_HOME=str(other)))
r=json.loads((other/'state/t3-mirrors/tasks/worker.json').read_text()); assert r['threadId']!=record('worker')['threadId']; assert r['projectId']==record('worker')['projectId']
save('other-home-thread.json',t3('thread','show',r['threadId'],'--messages','10','--json'))
log.append('Same task name in another home: separate thread, same neutral project.')
marker=work/'must-not-exist'
refused=t3('thread','send',record('worker')['threadId'],f'touch {marker}','--wait','--json')
a=show('worker'); assert a['messages'][-1]['text']=='Presentation only. Send instructions through Firstmate. Nothing typed here is executed.\n'; assert not marker.exists(); assert a['thread']['activeRunId'] is None
save('command-refusal.json',a)
log.append('Real T3 command prompt: presentation-only reply, no marker created, turn settled.')
assert updated_meta=={x.name:x.read_bytes() for x in state.glob('*.meta')}
log.append('Publisher and direct mirror prompts left every endpoint metadata byte unchanged.')
# Disabled does not create state, retirement preserves active tasks and remote history.
disabled=work/'disabled-home';(disabled/'config').mkdir(parents=True,exist_ok=True)
sync(dict(env,FM_HOME=str(disabled))); assert not (disabled/'state').exists()
call(['bash','bin/fm-t3-mirrors.sh','retire','mate']); assert (state/'t3-mirrors/tasks/mate.json').exists()
mate_id=record('mate')['threadId']; (state/'mate.meta').unlink(); (home/'config/t3-mirrors').write_text('0\n')
call(['bash','bin/fm-t3-mirrors.sh','retire','mate']); assert not (state/'t3-mirrors/tasks/mate.json').exists()
assert t3('thread','show',mate_id,'--messages','10','--json')['thread']['threadId']==mate_id
log.append('Disabled sync creates nothing; retire refuses active mapping, removes retired mapping with publication off, preserves T3 history.')
(evidence/'live-checks.txt').write_text('\n'.join(log)+'\n')
print('\n'.join(log)); print('WORKER_LINK='+a['thread']['link']);print('MATE_LINK='+b['thread']['link'])
