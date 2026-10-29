exec(compile(open('~/firstmate/data/heavy-slots/live-common.py').read(),'live-common.py','exec'))
assert (PROOF/'round6-comparisons.exit').read_text()=='0'
assert not list((LAB/'state').glob('*.meta'))
run('s8-start-private-tmux',['tmux','-S',S['socket'],'-f','/dev/null','new-session','-d','-s','live','bash --noprofile --norc'],expect=0)
run('s8-tmux-shell',['tmux','-S',S['socket'],'set-option','-g','default-shell','/bin/bash'],expect=0)
run('s8-tmux-command',['tmux','-S',S['socket'],'set-option','-g','default-command','bash --noprofile --norc'],expect=0)
result=run('s8-tmux-identity',['tmux','-S',S['socket'],'display-message','-p','#{socket_path},#{pid},0'],expect=0)
S['tmux']=result.stdout.strip(); S['prefix']='hs3312234-s8'; ENV['TMUX']=S['tmux']
(PROOF/'live-scenario8-settings.json').write_text(json.dumps(S,indent=2))
project2=LAB/'projects/tiny2'
run('s8-init-origin2',['git','init','--bare',str(LAB/'origin2.git')],expect=0)
run('s8-clone-project2',['git','clone',str(LAB/'origin2.git'),str(project2)],expect=0)
(project2/'README.md').write_text('Disposable live scenario8 fixture.\n')
run('s8-add-project2',['git','-C',str(project2),'add','README.md'],expect=0)
run('s8-commit-project2',['git','-C',str(project2),'-c','user.name=Live fixture','-c','user.email=fixture@example.invalid','-c','core.hooksPath=/dev/null','commit','-m','Fixture baseline'],expect=0)
run('s8-push-local-origin2',['git','-C',str(project2),'push','origin','HEAD'],expect=0)
basebrief=(LAB/'data/hs3312234-a/brief.md').read_text()
for suffix,repo in [('u','tiny'),('f','tiny'),('p','tiny'),('e','tiny2'),('l','tiny2')]:
    ident=S['prefix']+'-'+suffix; directory=LAB/'data'/ident; directory.mkdir()
    (directory/'brief.md').write_text(basebrief.replace('hs3312234-a',ident).replace('Drive the grant, admission-over-cap and deferred-replay scenarios live against a throwaway FM_HOME with tiny caps, recording each result.','Run live scenario8 in the same private named lab: unused flags, independent cap grants, and legacy replay records.'))
    run('s8-add-'+suffix,['bash',str(SOURCE/'bin/fm-tasks-axi.sh'),'add',ident,'Live scenario8 '+suffix,'--kind','ship','--queue','--repo',repo],expect=0)
base=['--mode','local-only','--yolo','off','--ticket','no-ticket','--commit-type','chore','--harness','codex','--effort','low','--backend','tmux']
def caps(fleet,project):
    (LAB/'config/fleet-capacity').write_text(str(fleet)+'\n')
    (LAB/'config/project-capacity').write_text('tiny '+str(project)+'\ntiny2 10\n')
def spawn(suffix,project=PROJECT,flag=False,expect=0,label=None):
    return run(label or ('s8-spawn-'+suffix),['bash',str(SOURCE/'bin/fm-spawn.sh'),S['prefix']+'-'+suffix,str(project),*base,*(['--ad-hoc-slot'] if flag else [])],expect=expect)
def meta(suffix):return (LAB/'state'/(S['prefix']+'-'+suffix+'.meta')).read_text()
def grants(suffix,fleet=False,project=False):
    value=meta(suffix)
    assert ('ad_hoc_fleet_slot=1' in value)==fleet,value
    assert ('ad_hoc_project_slot=1' in value)==project,value
    (PROOF/('s8-meta-'+suffix+'.txt')).write_text(value)
def marker(suffix):
    ident=S['prefix']+'-'+suffix; path=LAB/'data'/ident/'started.txt'; trusted=False
    for _ in range(120):
        if path.exists():break
        pane=subprocess.run(['tmux','-S',S['socket'],'capture-pane','-p','-t','live:fm-'+ident,'-S','-45'],env=ENV,capture_output=True,text=True).stdout
        if 'Do you trust the contents of this directory?' in pane and not trusted:
            (PROOF/('s8-trust-'+suffix+'.txt')).write_text(pane)
            run('s8-trust-enter-'+suffix,['tmux','-S',S['socket'],'send-keys','-t','live:fm-'+ident,'Enter'],expect=0); trusted=True
        time.sleep(1)
    assert path.read_text().strip()=='real Codex worker started'
    run('s8-pane-'+suffix,['tmux','-S',S['socket'],'capture-pane','-p','-t','live:fm-'+ident,'-S','-45'],expect=0)
def clean(suffix):
    ident=S['prefix']+'-'+suffix
    run('s8-exit-'+suffix,['bash',str(SOURCE/'bin/fm-control.sh'),ident,'exit'],expect=0)
    run('s8-teardown-'+suffix,['bash',str(SOURCE/'bin/fm-teardown.sh'),ident],expect=0)
def snapshot(label):
    r=run(label,['bash',str(SOURCE/'bin/fm-fleet-snapshot.sh'),'--json'],expect=0)
    return json.loads(r.stdout)
def relaunch(suffix):
    (LAB/'data'/(S['prefix']+'-'+suffix)/'started.txt').unlink(missing_ok=True)
    run('s8-relaunch-'+suffix,['bash',str(SOURCE/'bin/fm-control.sh'),S['prefix']+'-'+suffix,'relaunch','--note','Continue the disposable live scenario8 liveness fixture. Write your started marker again, then remain paused. Do not modify project files or Git refs.'],timeout=240,expect=0)
    marker(suffix)
# Unused flag must not mint either grant in a free ordinary place.
caps(1,1); spawn('u',flag=True); marker('u'); grants('u')
spawn('f',expect=75,label='s8-unused-flag-no-extra-capacity')
v=snapshot('s8-unused-snapshot'); assert v['capacity']['occupancy']==1 and v['capacity']['ad_hoc']==0,v['capacity']
print('SCENARIO8 unused flag PASSED',flush=True)
# Only fleet is full; a fleet grant must not enlarge project capacity.
caps(1,2); spawn('f',flag=True); marker('f'); grants('f',fleet=True)
relaunch('f'); grants('f',fleet=True)
r=spawn('p',expect=75,label='s8-fleet-grant-does-not-inflate-project'); assert 'deferred: project' in r.stderr+r.stdout
clean('f'); print('SCENARIO8 fleet-only grant PASSED',flush=True)
# Only project is full; project grant must not enlarge fleet capacity.
caps(3,1); spawn('p',flag=True); marker('p'); grants('p',project=True)
relaunch('p'); grants('p',project=True)
spawn('e',project=project2); marker('e'); grants('e')
r=spawn('l',project=project2,expect=75,label='s8-project-grant-does-not-inflate-fleet'); assert 'deferred: this machine' in r.stderr+r.stdout
v=snapshot('s8-independent-project-snapshot'); assert v['capacity']['occupancy']==3 and v['capacity']['ad_hoc']==0,v['capacity']
print('SCENARIO8 project-only grant PASSED',flush=True)
# Authentic generated v1 record without newer key: the legacy public protocol.
record=LAB/'state'/(S['prefix']+'-l.deferred-spawn.json')
value=json.loads(record.read_text()); assert value.pop('ad_hoc_slot')=='0'
record.write_text(json.dumps(value,indent=2)+'\n')
(PROOF/'s8-legacy-input.json').write_text(record.read_text())
import hashlib
run('s8-verify-legacy',['python3',str(SOURCE/'bin/fm-worker-admit.py'),'verify',S['prefix']+'-l',hashlib.sha256(record.read_bytes()).hexdigest()],expect=0)
run('s8-legacy-full-tick',['bash',str(SOURCE/'bin/fm-worker-park.sh'),'tick'],timeout=240,expect=0)
assert record.exists() and not (LAB/'state'/(S['prefix']+'-l.meta')).exists()
clean('e')
run('s8-legacy-admit-tick',['bash',str(SOURCE/'bin/fm-worker-park.sh'),'tick'],timeout=240,expect=0)
marker('l'); grants('l'); assert not record.exists()
print('SCENARIO8 legacy no implicit grant PASSED',flush=True)
for suffix in ['u','p','l']:clean(suffix)
caps(1,1)
v=snapshot('s8-cleaned-snapshot'); assert v['capacity']['occupancy']==0 and v['capacity']['ad_hoc']==0,v['capacity']
assert not list((LAB/'state').glob('*.meta'))
run('s8-private-tmux-close',['tmux','-S',S['socket'],'kill-server'],expect=0)
print('SCENARIO8 ALL LIVE CHECKS AND CLEANUP PASSED',flush=True)
