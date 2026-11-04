import json,os,pathlib,subprocess
root=pathlib.Path.cwd(); p=root/'.fm-test-scratch/upstash-validation/upload-limit'
work=p/'work';work.mkdir(parents=True)
user=p/'user'; key=user/'.config/upstash/box-api-key'; key.parent.mkdir(parents=True);key.write_text('disposable-invalid-credential-not-for-network');key.chmod(0o600)
home=p/'home'
env={k:v for k,v in os.environ.items() if not k.startswith(('FM_','GIT_','XDG_','PYTHON','BOAT_','UPSTASH_'))}
env.update(HOME=str(user),FM_HOME=str(home),GIT_CONFIG_NOSYSTEM='1',GIT_CONFIG_GLOBAL='/dev/null',PYTHONDONTWRITEBYTECODE='1')
subprocess.run(['git','init','-q',str(work)],env=env,check=True)
with (work/'payload.bin').open('wb') as f:
    for _ in range(101):f.write(os.urandom(1_000_000))
subprocess.run(['git','-C',str(work),'add','.'],env=env,check=True)
subprocess.run(['git','-C',str(work),'-c','user.name=Validation','-c','user.email=validation@example.invalid','commit','-qm','upload limit source'],env=env,check=True)
r=subprocess.run(['bash',str(root/'bin/fm-boat-run.sh'),'run','--worktree',str(work),'--output',str(p/'output'),'--','true'],env=env,capture_output=True,text=True,timeout=45)
result=json.loads((p/'output/result.json').read_text())
assert r.returncode==69 and result['kind']=='unavailable' and result['upload_bytes']>100_000_000,(r.returncode,r.stderr,result)
assert result['execution_error']=='Upstash source archive exceeds the 100 MB upload limit',result
assert result['cleanup']=='deleted'
evidence=pathlib.Path('~/.no-mistakes/evidence/01M6HWD5RYP8APCG3CY6YXPHT7')
(evidence/'upload-limit-result.json').write_text(json.dumps(dict(exit=r.returncode,stdout=r.stdout,stderr=r.stderr,result=result),indent=2)+'\n')
print(r.stderr.strip(),result['upload_bytes'])
