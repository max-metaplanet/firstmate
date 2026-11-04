import hashlib,json,os,subprocess,tarfile,shutil
from pathlib import Path
repo=Path.cwd()
base=repo/'.test-boat-live'; base.mkdir(exist_ok=True)
evidence=Path('~/.no-mistakes/evidence/01M6JGR1CN1V1RZJ5MY33VPJFJ')
work=base/'source'; work.mkdir()
user=base/'user'; user.mkdir()
env=dict(os.environ,HOME=str(user),FM_HOME=str(base/'home'),XDG_CONFIG_HOME=str(user/'.config'),GIT_CONFIG_NOSYSTEM='1',GIT_CONFIG_GLOBAL='/dev/null',GIT_CEILING_DIRECTORIES=str(base),BOAT_NO_UPDATE='1')
for key in list(env):
    if key.startswith('GIT_') and key not in ('GIT_CONFIG_NOSYSTEM','GIT_CONFIG_GLOBAL','GIT_CEILING_DIRECTORIES'):
        del env[key]
for key in ('FM_TASK_ID','FM_BOAT_BIN','FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_CONFIG_OVERRIDE','FM_DATA_OVERRIDE','FM_PROJECTS_OVERRIDE','BOAT_API_KEY','BOAT_API_URL','UPSTASH_BOX_API_KEY'):
    env.pop(key,None)
def git(*args):
    return subprocess.run(['git','-C',str(work),*args],env=env,check=True,capture_output=True)
def run(name,*args):
    result=subprocess.run(['bash',str(repo/'bin/fm-boat-run.sh'),'run','--worktree',str(work),'--output',str(base/name),*args,'--','bash','-c','echo REMOTE_COMMAND_RAN'],env=env,capture_output=True,timeout=90)
    doc=json.loads((base/name/'result.json').read_text())
    (evidence/(name+'-result.json')).write_text(json.dumps(doc,indent=2)+'\n')
    print(name, 'exit',result.returncode,'stderr',result.stderr.decode().strip())
    print(json.dumps(doc,sort_keys=True))
    assert b'REMOTE_COMMAND_RAN' not in result.stdout
    return result,doc
git('init','-q');git('config','user.name','Isolated validation');git('config','user.email','validation@example.invalid')
(work/'required.txt').write_text('committed\n');(work/'deleted.txt').write_text('must be absent\n')
git('add','.');git('commit','-qm','source fixture');git('update-ref','refs/remotes/origin/main','HEAD')
(work/'required.txt').write_text('current working source\n');(work/'deleted.txt').unlink()
(work/'.env').write_text('PRIVATE_VALUE=must-never-leave\n')
(work/'unselected.txt').write_text('not selected\n')
payload=os.urandom(143149102);expected=hashlib.sha256(payload).hexdigest();(work/'payload.bin').write_bytes(payload);del payload
try:
    r,d=run('large-preparation','--input','payload.bin','--history-depth','2')
    assert r.returncode==69 and d['kind']=='unavailable' and d['remote_exit'] is None and d['cleanup']=='deleted',d
    archive=base/'large-preparation/upload/source.tar.gz'
    assert d['upload_bytes']==archive.stat().st_size and d['upload_bytes']>=143149102
    assert hashlib.sha256(archive.read_bytes()).hexdigest()==d['source_sha256']
    assert d['history']=='screened' and d['push_timeout_seconds']==600
    with tarfile.open(archive) as t:
        names=t.getnames()
        assert all(n in ('required.txt','payload.bin','.git') or n.startswith('.git/') for n in names),names
        assert hashlib.sha256(t.extractfile('payload.bin').read()).hexdigest()==expected
        assert t.extractfile('required.txt').read()==b'current working source\n'
    print('Archive manifest:',json.dumps(names))
    print('Independent input SHA256:',expected)
    print('PASS: incident-sized source archive preserves payload and edited source, screened history, omissions, exact archive digest and 600-second bound. Transfer was NOT attempted.')
    r,d=run('secret-input-refused','--input','.env')
    assert r.returncode==2 and d['remote_exit'] is None and d['cleanup']=='not-created',d
    assert not (base/'secret-input-refused/upload/source.tar.gz').exists()
    print('PASS: explicit credential input refused before archive or remote allocation.')
finally:
    shutil.rmtree(base)
