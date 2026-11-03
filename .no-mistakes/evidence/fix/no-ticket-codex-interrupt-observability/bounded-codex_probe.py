import os, pathlib, pty, subprocess, time, select, json, signal, fcntl, termios, struct
root=pathlib.Path.cwd(); scratch=root/'.fm-test-scratch/bounded-evidence'; home=scratch/'final-home'; home.mkdir(exist_ok=True); ch=home/'codex'; ch.mkdir(exist_ok=True)
exe=subprocess.check_output(['which','codex'],text=True).strip()
children=[]; records=[]
try:
    for label in ('session-a','session-b'):
        master,slave=pty.openpty(); fcntl.ioctl(slave,termios.TIOCSWINSZ,struct.pack('HHHH',35,120,0,0))
        env={k:v for k,v in os.environ.items() if k in ('PATH','LANG','TERM','LD_LIBRARY_PATH')}; env.update(HOME=str(home),CODEX_HOME=str(ch),FM_HOME=label,TERM='xterm-256color',TMPDIR=str(scratch))
        p=subprocess.Popen([exe,'--no-daemon','--disable','hooks','-c','notify=["bash","-c","true"]'],cwd=scratch,env=env,stdin=slave,stdout=slave,stderr=slave,start_new_session=True); os.close(slave)
        children.append((p,master)); records.append({'session':label,'pid':p.pid,'output':''})
        if label == 'session-a':
            until=time.monotonic()+6
            while time.monotonic()<until:
                if select.select([master],[],[],0.1)[0]:
                    try:
                        b=os.read(master,65536); records[-1]['output']+=b.decode(errors='replace')
                        if b'\x1b[6n' in b: os.write(master,b'\x1b[1;1R')
                    except OSError: pass
    deadline=time.monotonic()+12
    while time.monotonic()<deadline:
        for (p,fd),r in zip(children,records):
            if select.select([fd],[],[],0.1)[0]:
                try:
                    b=os.read(fd,65536); r['output']+=b.decode(errors='replace')
                    if b'\x1b[6n' in b: os.write(fd,b'\x1b[1;1R')
                    if b'Update now' in b and not r.get('update_dismissed'):
                        os.write(fd,b'\x1b'); r['update_dismissed']=True
                except OSError: pass
    # Read only exact descendants of our test processes, using PPIDs from procfs.
    allprocs={}
    for entry in pathlib.Path('/proc').iterdir():
        if not entry.name.isdigit(): continue
        try:
            fields=(entry/'stat').read_text().rsplit(')',1)[1].split(); allprocs[int(entry.name)]=int(fields[1])
        except (OSError,ValueError,IndexError): pass
    for (p,fd),r in zip(children,records):
        owned={p.pid}
        for _ in range(10): owned|={pid for pid,ppid in allprocs.items() if ppid in owned}
        r['processes']=[]
        for pid in sorted(owned):
            try:
                proc=pathlib.Path('/proc')/str(pid); env=(proc/'environ').read_bytes().split(b'\0')
                r['processes'].append({'pid':pid,'cmd':(proc/'cmdline').read_bytes().replace(b'\0',b' ').decode(errors='replace'),'markers':[v.decode(errors='replace') for v in env if v.startswith((b'FM_HOME=',b'CODEX_HOME='))], 'sockets':[os.readlink(f) for f in (proc/'fd').iterdir() if f.is_symlink() and os.readlink(f).startswith('socket:')]})
            except OSError: pass
        r['pre_cleanup_exit']=p.poll()
finally:
    for p,fd in children:
        if p.poll() is None: os.killpg(p.pid,signal.SIGTERM)
    for (p,fd),r in zip(children,records):
        try: r['cleanup_exit']=p.wait(timeout=5)
        except subprocess.TimeoutExpired:
            os.killpg(p.pid,signal.SIGKILL); r['cleanup_exit']=p.wait(timeout=5)
        os.close(fd)
(scratch/'codex-probe.json').write_text(json.dumps(records,indent=2))
for r in records:
    print(json.dumps({'session':r['session'],'signin': 'Choose how you want to use Codex' in r['output'],'processes':[(p['pid'],p['cmd'].split(' ')[0].split('/')[-1],p['markers'][-1]) for p in r['processes']], 'cleanup_exit':r['cleanup_exit']}))
