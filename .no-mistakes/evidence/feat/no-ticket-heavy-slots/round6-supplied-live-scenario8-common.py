from pathlib import Path
import json,os,subprocess,time
PROOF=Path('~/firstmate/data/heavy-slots')
S=json.loads((PROOF / 'live-scenario8-settings.json').read_text())
LAB=Path(S['lab']); SOURCE=Path(S['source']); PROJECT=Path(S['project'])
ENV=dict(os.environ,FM_HOME=str(LAB),TMUX=S['tmux'],TREEHOUSE_ROOT=str(LAB / 'pool'),TMPDIR=str(LAB / 'tmp'),FM_BUILD_LOCK_INSTALL_DIR=str(LAB / 'installed'),FM_BACKEND='tmux',FM_SPAWN_NO_GUARD='1',DISABLE_AUTOUPDATER='1')
for key in ['NO_MISTAKES_GATE','FM_GATE_REFUSE_BYPASS','FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE','FM_TASK_ID','TASKS_AXI_FILE','TASKS_AXI_BACKEND']:
    ENV.pop(key,None)
def run(label,args,timeout=180,expect=None):
    result=subprocess.run(['timeout','--kill-after=10s',str(timeout),*args],env=ENV,cwd=SOURCE,capture_output=True,text=True,timeout=timeout+30)
    (PROOF / (label+'.log')).write_text(result.stdout+result.stderr)
    (PROOF / (label+'.exit')).write_text(str(result.returncode))
    print(label,'exit='+str(result.returncode),result.stdout,result.stderr,flush=True)
    if expect is not None and result.returncode!=expect:
        raise RuntimeError(label+' unexpected exit '+str(result.returncode))
    return result
