"""Drive the real bin/fm-work-intake.sh in disposable FM homes. The ClickUp write
boundary is a shim whose exit code comes from the REAL installed clickup-axi
package's write_result() (journal pending -> its own exit code)."""
import json, os, shutil, subprocess, sys, tempfile
from pathlib import Path
from copy import deepcopy

ROOT = Path(sys.argv[1]); REAL_AXI = sys.argv[2]
BASE = json.loads((ROOT / 'tests/fixtures/clickup-queue-v1.json').read_text())
src = (ROOT / 'tests/fm-work-intake.test.sh').read_text()
HOOK = src.split("self.hook.write_text('''", 1)[1].split("''')", 1)[0].replace('\\\\n', '\\n')
SCRATCH = Path(tempfile.mkdtemp(prefix='fm-intake-jp.'))

SHIM = r'''#!/usr/bin/env python3
import json, os, pathlib, sys
p=pathlib.Path(__file__).resolve().parent.parent
args=sys.argv[1:]
with (p/'writes').open('a') as s: s.write(json.dumps(args)+'\n')
step=args[0]; mode=os.environ.get('MODE_'+step, 'ok')
if mode == 'hard-fail':
    print('clickup-axi: ClickUp API rejected write', file=sys.stderr); sys.exit(1)
v=json.loads((p/'source.json').read_text()); r=v['candidates'][0]; e=r['source_evidence']
if mode != 'noop':
    if step == 'assign':
        e.update(ownership='sole', assignee_ids=[int(args[args.index('--add')+1])], is_unassigned=False)
    else:
        e.update(status=args[args.index('--to')+1], is_backlog=False)
        r['scope']['full_comments']=r['scope'].get('full_comments',[])+[{'id':'summary','text':'Up next. Maintained automatically by clickup-axi.'}]
    r['full_revision']=r.get('full_revision', r['source_revision']+'-full')+'-'+step
if mode == 'pending-readfail': v['fail']=True
(p/'source.json').write_text(json.dumps(v))
sys.path.insert(0, os.environ['REAL_AXI'])
from clickup_axi.cli import write_result   # real producer of the exit code
db = 'pending' if mode.startswith('pending') or mode == 'noop' else 'applied'
sys.exit(write_result({'result':'applied','database':{'status':db}}, True, None))
'''

def home(name):
    h = SCRATCH / name
    for d in ('state','config','data','fakeclickup'): (h/d).mkdir(parents=True)
    (h/'.tasks.toml').write_text('backend="markdown"\n[markdown]\npath="data/backlog.md"\narchive="data/retired.md"\ndone_keep=0\n')
    (h/'data/backlog.md').write_text('## In flight\n\n## Queued\n\n## Done\n')
    snap = deepcopy(BASE)
    snap['candidates'][0]['source_evidence'].update(ownership='unassigned', assignee_ids=[], status='backlog',
        is_unassigned=True, is_backlog=True, configured_user_id=42)
    (h/'source.json').write_text(json.dumps(snap))
    (h/'source').write_text(HOOK); (h/'source').chmod(0o755)
    (h/'fakeclickup/clickup-axi').write_text(SHIM); (h/'fakeclickup/clickup-axi').chmod(0o755)
    (h/'config/work-intake-hook').write_text(str(h/'source')+'\n')
    (h/'config/work-intake-include-backlog-and-unassigned').write_text('1\n')
    (h/'config/work-intake-enabled').write_text('1\n')
    env = {**os.environ, 'FM_HOME':str(h), 'FM_DATA_OVERRIDE':str(h/'data'), 'FM_STATE_OVERRIDE':str(h/'state'),
           'FM_CONFIG_OVERRIDE':str(h/'config'), 'FM_TEST_SEAM':'1', 'REAL_AXI':REAL_AXI,
           'PATH':str(h/'fakeclickup')+os.pathsep+os.environ['PATH']}
    for k in ('TASKS_AXI_FILE','TASKS_AXI_BACKEND','FM_TASK_ID'): env.pop(k, None)
    return h, env

def sh(env, *args):
    return subprocess.run(['bash', str(ROOT/'bin/fm-work-intake.sh'), *args, '--json'], env=env, text=True, capture_output=True, timeout=80)

def tasks(h, env, *args):
    return subprocess.run(['bash', str(ROOT/'bin/fm-tasks-axi.sh'), *args], env=env, text=True, capture_output=True).stdout

def scenario(name, modes, expect_ok):
    h, env = home(name)
    ident = json.loads(sh(env,'poll').stdout)['imported'][0]
    fresh = json.loads(sh(env,'refresh',ident).stdout)
    (h/'d.json').write_text(json.dumps(dict(source_revision=fresh['candidate']['source_revision'], authorized=True,
        identity_checked=True, project='fixture-project', kind='ship', reason='accepted scope and duplicate reconciliation checked')))
    assert sh(env,'review',ident,'--decision-file',str(h/'d.json')).returncode == 0
    env2 = {**env, **{'MODE_'+k:v for k,v in modes.items()}}
    r = sh(env2, 'check', ident)
    writes = [json.loads(l)[0] for l in (h/'writes').read_text().splitlines()] if (h/'writes').exists() else []
    show = tasks(h, env, 'show', ident)
    held = 'held: yes' in show
    print(f'=== {name}  modes={modes}')
    print(f'$ fm-work-intake.sh check {ident} --json   -> exit {r.returncode}')
    print('stdout:', (r.stdout.strip()[:200] or '<empty>'))
    print('stderr:', r.stderr.strip() or '<empty>')
    print('clickup writes issued:', writes, '| task held:', held)
    ok = (r.returncode == 0) == expect_ok and (not expect_ok or (json.loads(r.stdout)['result']=='cleared' and not held)) and (expect_ok or held)
    print('RESULT:', 'PASS' if ok else 'FAIL', '\n'); return ok

res = [
 scenario('both-writes-journal-pending', {'assign':'pending','status':'pending'}, True),
 scenario('status-journal-pending-only', {'status':'pending'}, True),
 scenario('baseline-clean-writes', {}, True),
 scenario('assign-real-write-failure', {'assign':'hard-fail'}, False),
 scenario('status-real-write-failure', {'status':'hard-fail'}, False),
 scenario('journal-pending-but-readback-fails', {'assign':'pending-readfail'}, False),
 scenario('journal-pending-but-write-not-applied', {'status':'noop'}, False),
]
shutil.rmtree(SCRATCH)
print('ALL PASS' if all(res) else 'SOME FAILED'); sys.exit(0 if all(res) else 1)
