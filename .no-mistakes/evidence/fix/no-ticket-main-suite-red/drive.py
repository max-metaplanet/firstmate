import os, pathlib, subprocess, tempfile, shutil, time, signal, json
root=pathlib.Path.cwd()
evidence=pathlib.Path('~/.no-mistakes/evidence/01M6A6TW1AS883DH4468K9EYW4')
lab=pathlib.Path(tempfile.mkdtemp(prefix='.checkpoint-live-',dir=root))
rows=[]
env=os.environ.copy()
for k in list(env):
    if k in ('FM_HOME','FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_CONFIG_OVERRIDE','FM_DATA_OVERRIDE','FM_PROJECTS_OVERRIDE'): env.pop(k)
env.update(FM_POLL='1',FM_SIGNAL_GRACE='1',FM_CHECK_INTERVAL='999999',FM_HEARTBEAT='999999')
children=[]
def run(name,command,expected,action=None,policy=False):
    home=lab/name
    subprocess.run(['bash','bin/fm-lab-home.sh','create',str(home)],check=True,capture_output=True)
    e=env|{'FM_HOME':str(home)}
    if policy:
        (home/'config/fleet-capacity').write_text('2\n')
        (home/'config/fleet-load-policy').write_text('{"mode":"observe","floor":1,"ceiling":2,"start":1}\n')
    p=subprocess.Popen([str(command),'--seconds','4' if action else '1'],env=e,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,preexec_fn=(lambda: signal.signal(signal.SIGINT, signal.SIG_IGN)) if action=='stop' else None)
    children.append(p)
    if action:
        deadline=time.monotonic()+8
        while not (home/'state/.watch.lock/pid').exists() or not (home/'state/.last-watcher-beat').exists():
            assert p.poll() is None, f'{name} exited early'
            assert time.monotonic()<deadline, f'{name} not ready'
            time.sleep(.02)
        pid=int((home/'state/.watch.lock/pid').read_text())
        if action=='stop':
            until=time.monotonic()+15
            while p.poll() is None and time.monotonic()<until:
                try: os.kill(pid,signal.SIGSTOP)
                except ProcessLookupError: break
                time.sleep(.001)
        elif action=='kill': os.kill(pid,signal.SIGKILL)
        elif action=='signal': (home/'state/demo.status').write_text('done: isolated live validation\n')
    out,err=p.communicate(timeout=20)
    row={'scenario':name,'exit':p.returncode,'expected':expected,'stdout':out,'stderr':err}
    if policy:
        path=home/'state/fleet-load.json'
        assert path.exists(), 'configured policy did not run its sampler'
        row['fleet_load_state']=json.loads(path.read_text())
    rows.append(row)
    print(json.dumps(row),flush=True)
    assert p.returncode==expected, row
    if action=='signal':
        assert 'signal:' in out
        queue=(home/'state/.wake-queue').read_text()
        assert '\tsignal\tdemo.status\t' in queue
        row['persisted_queue']=queue
    elif expected==124: assert 'checkpoint: no actionable wake' in out
try:
    oldbin=lab/'old-bin'; oldbin.mkdir()
    for path in (root/'bin').iterdir():
        if path.name!='fm-watch-checkpoint.sh': (oldbin/path.name).symlink_to(path)
    old=oldbin/'fm-watch-checkpoint.sh'
    old.write_bytes(subprocess.check_output(['git','show','7e8b978d:bin/fm-watch-checkpoint.sh']))
    old.chmod(0o755)
    run('quiet',root/'bin/fm-watch-checkpoint.sh',124)
    run('signal',root/'bin/fm-watch-checkpoint.sh',0,'signal')
    run('base-forced-deadline',old,137,'stop')
    run('head-forced-deadline',root/'bin/fm-watch-checkpoint.sh',124,'stop')
    run('head-real-kill',root/'bin/fm-watch-checkpoint.sh',137,'kill')
    run('configured-policy-still-ticks',root/'bin/fm-watch-checkpoint.sh',124,policy=True)
finally:
    for p in children:
        if p.poll() is None:
            p.kill(); p.communicate()
    (evidence/'live-checkpoints.json').write_text(json.dumps(rows,indent=2)+'\n')
    shutil.rmtree(lab)
