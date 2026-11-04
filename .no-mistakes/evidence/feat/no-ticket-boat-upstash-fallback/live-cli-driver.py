import json, os, pathlib, subprocess, sys
root=pathlib.Path.cwd()
base=root/'.fm-test-scratch/upstash-validation/live'
base.mkdir()
evidence=pathlib.Path('~/.no-mistakes/evidence/01M6HWD5RYP8APCG3CY6YXPHT7')
rows=[]
for name in ['missing-optional-key', 'unsafe-key-permissions', 'large-refused', 'xlarge-refused', 'swap-refused', 'local-allowed', 'local-forbidden', 'unsafe-key-local-forbidden']:
    p=base/name
    work=p/'work'; work.mkdir(parents=True)
    user=p/'user'; user.mkdir()
    home=p/'home'; state=home/'state/boat-offload'; state.mkdir(parents=True)
    (state/'upstash-sdk-0.4.0').symlink_to(root/'.fm-test-scratch/upstash-validation/sdk',target_is_directory=True)
    env={k:v for k,v in os.environ.items() if not k.startswith(('FM_', 'GIT_', 'XDG_', 'PYTHON', 'BOAT_', 'UPSTASH_'))}
    env.update(HOME=str(user), FM_HOME=str(home), GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL='/dev/null', FM_BUILD_LOCK_INSTALL_DIR=str(p/'lock-install'), FM_BOAT_TEST_UNAVAILABLE_WAIT_SECS='0', PYTHONDONTWRITEBYTECODE='1')
    def invoke(argv, **kw):
        return subprocess.run(argv,env=env,capture_output=True,text=True,check=True,**kw)
    invoke(['git','init','-q',str(work)])
    (work/'proof.txt').write_text('disposable secret-free source\n')
    invoke(['git','-C',str(work),'add','.'])
    invoke(['git','-C',str(work),'-c','user.name=Validation','-c','user.email=validation@example.invalid','commit','-qm','validation source'])
    options=[]
    if name in ['unsafe-key-permissions','large-refused','xlarge-refused','swap-refused','unsafe-key-local-forbidden']:
        key=user/'.config/upstash/box-api-key'; key.parent.mkdir(parents=True)
        key.write_text('disposable-invalid-credential-not-for-network')
        key.chmod(0o644 if name.startswith('unsafe-key') else 0o600)
    if name in ['large-refused','xlarge-refused']:
        (home/'config').mkdir()
        (home/'config/boat-keys').write_text(str(user/'.config/boat/api-key')+' types=default,large,xlarge\n')
        options=['--type',name.split('-')[0]]
    if name=='swap-refused': options=['--swap-gib','1']
    if name in ['local-allowed','local-forbidden','unsafe-key-local-forbidden']:
        env['FM_BOAT_TEST_LOCAL_FALLBACK']='1' if name=='local-allowed' else '0'
        cmd=['bash',str(root/'bin/fm-boat-test-wrapper.sh'),'printf "local command executed\\n"; printf proof > local-ran; exit 23']
    else:
        cmd=['bash',str(root/'bin/fm-boat-run.sh'),'run','--worktree',str(work),'--output',str(p/'output'),*options,'--','bash','-c','printf unexpected > remote-ran']
    r=subprocess.run(cmd,cwd=work,env=env,capture_output=True,text=True,timeout=45)
    results=list((p/'output').glob('result.json'))+list((p/'.fm-test-scratch').glob('fm-boat-test.*/boat-*/result.json'))
    assert len(results)==1,(name,results,r.stderr)
    result=json.loads(results[0].read_text())
    expected=23 if name=='local-allowed' else 69
    assert r.returncode==expected,(name,r.returncode,r.stderr,result)
    assert result['kind']=='unavailable' and result['cleanup']=='deleted',result
    assert (work/'local-ran').exists()==(name=='local-allowed')
    assert not (work/'remote-ran').exists()
    row=dict(scenario=name,exit=r.returncode,stdout=r.stdout,stderr=r.stderr,result=result,local_command_executed=(work/'local-ran').exists())
    rows.append(row)
    print(name, 'exit='+str(r.returncode), result.get('execution_error'), 'local='+str(row['local_command_executed']),flush=True)
(evidence/'live-cli-results.json').write_text(json.dumps(rows,indent=2)+'\n')
