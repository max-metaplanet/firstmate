import pathlib, os, subprocess, sys, json, threading, http.server, shlex, time
root=pathlib.Path.cwd(); scratch=root/'.fm-test-scratch/bounded-evidence'; lab=scratch/'lab'
if not lab.exists(): subprocess.run(['bash','bin/fm-lab-home.sh','create',str(lab)],check=True,stdout=subprocess.DEVNULL)
bindir=scratch/'bin'; bindir.mkdir(exist_ok=True); socket='/proc/self/cwd/.fm-test-scratch/bounded-evidence/tmux.sock'
wrapper=bindir/'tmux'; wrapper.write_text('#!/bin/sh\nexec /usr/bin/tmux -S '+shlex.quote(socket)+' "$@"\n'); wrapper.chmod(0o700)
worker=scratch/'polytoken'; 
if not worker.exists(): worker.symlink_to(sys.executable)
worker_script=scratch/'terminal.py'; worker_script.write_text('import sys\nfor line in sys.stdin:\n    if line.strip()=="/quit": break\n')
env={k:v for k,v in os.environ.items() if not k.startswith('FM_')}; env.update(FM_HOME=str(lab),PATH=str(bindir)+':'+os.environ['PATH'],FM_CONTROL_POLL='0.01',FM_CONTROL_SETTLE_WAIT='0.1')
mode='settled'; posted=False; captured=[]; results=[]
class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self,*args): pass
    def do_GET(self):
        assert self.path=='/sync'
        self.send_response(200); self.end_headers(); self.wfile.write(json.dumps({'turn': None if posted and mode not in ('timeout','refused') else {'generation':1}}).encode())
    def do_POST(self):
        global posted
        assert self.path=='/turn/cancel'
        assert self.headers['Authorization']=='Bearer fixture-only-token'
        self.rfile.read(int(self.headers['Content-Length']))
        path=lab/'state/t1.control-interrupt.jsonl'
        captured.append([json.loads(l) for l in path.read_text().splitlines()] if path.is_file() else [])
        posted=True; self.send_response(500 if mode=='refused' else 200); self.end_headers()
server=http.server.HTTPServer(('127.0.0.1',0),Handler); thread=threading.Thread(target=server.serve_forever); thread.start()
def tmux(*args): return subprocess.run([str(wrapper),*args],env=env,check=True,capture_output=True,text=True)
try:
    tmux('-f','/dev/null','new-session','-d','-s','fixture','-n','fm-t1',shlex.quote(str(worker))+' '+shlex.quote(str(worker_script))+'; exec /bin/bash')
    time.sleep(.3)
    (lab/'state/credential.json').write_text('{"token":"fixture-only-token"}')
    (lab/'state/t1.meta').write_text('window=fixture:fm-t1\nendpoint_task_id=t1\nworktree='+str(scratch)+'\nproject='+str(scratch)+'\nharness=polytoken\nkind=ship\nbackend=tmux\npolytoken_port='+str(server.server_port)+'\npolytoken_credential='+str(lab/'state/credential.json')+'\n')
    for mode in ():
        posted=False; captured.clear(); path=lab/'state/t1.control-interrupt.jsonl'
        if path.exists(): path.unlink()
        if mode=='logging-failure': path.mkdir()
        p=subprocess.run(['bash','bin/fm-control.sh','t1','interrupt'],env=env,capture_output=True,text=True,timeout=15)
        events=[json.loads(l) for l in path.read_text().splitlines()] if path.is_file() else []
        compact=[(e['action'],e['phase'],e['detail']) for e in events]
        result={'scenario':mode,'exit':p.returncode,'output':p.stdout+p.stderr,'events':compact,'before_post': [[(e['action'],e['phase']) for e in c] for c in captured]}; results.append(result)
        if mode=='logging-failure':
            assert p.returncode==0 and posted and 'warning: interrupt diagnostics could not append' in p.stderr
            assert 'cancel=cancelled' in p.stdout
            path.rmdir()
        else:
            assert captured and captured[0][-1]['phase']=='attempt',result
            expected=[('rest','attempt','turn-cancel'),('rest','failed' if mode=='refused' else 'delivered','turn-cancel')]
            if mode=='settled': expected.append(('cancellation','observed','cancelled'))
            assert compact==expected,result
            assert (p.returncode==0)==(mode=='settled'),result
            assert 'fixture-only-token' not in path.read_text()
    mode='settled'; posted=False; captured.clear()
    path=lab/'state/t1.control-interrupt.jsonl'
    if path.exists(): path.unlink()
    gen=subprocess.check_output(['bash','bin/fm-busy-event.sh','arm',str(lab/'state'),'t1','--state','busy'],text=True,env=env).strip()
    with (lab/'state/t1.meta').open('a') as f: f.write('busy_gen='+gen+'\n')
    env['FM_CONTROL_EXIT_WAIT']='3'
    p=subprocess.run(['bash','bin/fm-control.sh','t1','exit'],env=env,capture_output=True,text=True,timeout=15)
    events=[json.loads(l) for l in path.read_text().splitlines()]
    result={'scenario':'exit-initiated-interrupt','exit':p.returncode,'output':p.stdout+p.stderr,'events':[(e['action'],e['phase'],e['detail']) for e in events]}; results.append(result)
    assert p.returncode==1 and "composer state is 'unknown'" in p.stderr,result
    assert all(e['verb']=='exit' and e['generation']==gen for e in events),result
    assert result['events']==[('rest','attempt','turn-cancel'),('rest','delivered','turn-cancel'),('cancellation','observed','cancelled')],result
    print(json.dumps([{'scenario':r['scenario'],'exit':r['exit'],'events':r['events']} for r in results],indent=2))
finally:
    server.shutdown(); server.server_close(); thread.join()
    stopped=subprocess.run([str(wrapper),'kill-server'],env=env,capture_output=True,text=True)
    (scratch/'control-probe.json').write_text(json.dumps({'transport':'real curl to loopback HTTP fixture; real terminal process; simulated vendor semantics','results':results,'tmux_cleanup_exit':stopped.returncode},indent=2))
    assert stopped.returncode==0,stopped.stderr
