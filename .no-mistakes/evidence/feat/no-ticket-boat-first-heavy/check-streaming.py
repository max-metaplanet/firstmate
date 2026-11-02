import pathlib, os, subprocess, sys
root=pathlib.Path.cwd(); base=root/'.test-validation/live'; work=base/'project'; home=base/'home'
# Runtime probes reject whole-file reads on ordinary source and Git blob hashing
# during a default CLI upload. Archive bytes remain independently checked by
# drive-boat.py. This checks executed I/O, not source spelling.
probe=r'''
import pathlib, hashlib, runpy, sys
ordinary=pathlib.Path(sys.argv[2])/'ordinary.bin'
original=pathlib.Path.read_bytes
calls=[]
def read(path):
    if path == ordinary: raise AssertionError('ordinary file read whole')
    return original(path)
def no_hash(*args,**kwargs):
    raise AssertionError('unexpected object-id hashing in default upload')
pathlib.Path.read_bytes=read
hashlib.new=no_hash
script=sys.argv[1]; work=sys.argv[2]; output=sys.argv[3]
sys.argv=[script,'run','--worktree',work,'--output',output,'--','true']
runpy.run_path(script,run_name='__main__')
'''
env=dict(os.environ,HOME=str(home),FM_HOME=str(home),TMPDIR=str(base),BOAT_NO_UPDATE='1',PYTHONDONTWRITEBYTECODE='1')
for key in list(env):
    if key.startswith('GIT_') or key in ('BOAT_API_KEY','BOAT_TOKEN'):env.pop(key,None)
r=subprocess.run([sys.executable,'-c',probe,str(root/'bin/fm-boat-run.py'),str(work),str(base/'stream-probe')],env=env,capture_output=True,text=True,timeout=60)
print('Default CLI runtime I/O probe: exit',r.returncode);print(r.stderr,end='')
assert r.returncode==69,(r.returncode,r.stderr)
assert (base/'stream-probe/upload/source.tar.gz').exists()
print('Default upload finished without whole-file ordinary-source reads or Git object-id hashing; stopped at missing disposable Boat key as expected.')
