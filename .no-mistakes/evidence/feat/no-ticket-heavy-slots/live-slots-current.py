from pathlib import Path
import subprocess,os
r=Path.cwd(); h=r/'.test-phase-current/slots-home';
subprocess.run(['bash','bin/fm-lab-home.sh','create',str(h)],check=True,capture_output=True)
(h/'.tasks.toml').write_text('backend = "markdown"\n[markdown]\npath = "data/backlog.md"\n')
(h/'data/backlog.md').write_text('# Backlog\n\n## In flight\n\n## Queued\n\n## Done\n')
(h/'config/fleet-capacity').write_text('3\n')
for n in ('A','B','C','extra'):
 (h/f'state/{n}.meta').write_text(f'kind=ship\nharness=codex\nproject={h}/projects/demo\n'+('ad_hoc_fleet_slot=1\n' if n=='extra' else ''))
env=dict(os.environ,FM_HOME=str(h),FM_BACKEND='tmux')
for k in ('FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE','TASKS_AXI_FILE','TASKS_AXI_BACKEND'):env.pop(k,None)
e=Path('~/.no-mistakes/evidence/01M64N0N0G8XM8MK440VZDFA4P/slots-current.log')
with e.open('w') as log:
 for phase,expected in [('extra grant present','slots 4/3 plus 1 ad hoc'),('extra task record cleaned up','slots 3/3')]:
  if phase.startswith('extra task'): (h/'state/extra.meta').unlink()
  p=subprocess.run(['bash','bin/fm-slots.sh','--home',str(h)],env=env,capture_output=True,text=True,timeout=40)
  log.write(f'{phase}\n$ bin/fm-slots.sh --home <isolated lab>\n'+p.stdout+p.stderr+f'Exit: {p.returncode}\n');log.flush()
  assert p.returncode==0,(p.stdout,p.stderr)
  assert p.stdout.startswith(expected),p.stdout
  assert (h/'config/fleet-capacity').read_text()=='3\n'
 log.write('The fleet-capacity declaration remained 3 after cleanup.\n')
print('Real slots CLI reflected a temporary named grant and its removal without changing the cap.')
