import os, subprocess, sys, time, pathlib, re, json, shutil
r=pathlib.Path.cwd(); s=r/'.test-phase-round4/runner'; repo=s/'repo'; repo.mkdir(parents=True)
for name in ('bin','tests'): (repo/name).mkdir()
for name in ('fm-test-run.sh','fm-build-lock.py','fm-build-lock.js'): shutil.copy2(r/'bin'/name,repo/'bin'/name)
shutil.copy2(r/'tests/git-config-helpers.sh',repo/'tests/git-config-helpers.sh')
for n in ('fm-brief','fm-composer-lib'): (repo/'tests'/f'{n}.test.sh').write_text('echo "completed isolated workload"\n')
e=dict(os.environ,FM_BUILD_LOCK_FILE=str(s/'pool.lock'),FM_BUILD_LOCK_INSTALL_DIR=str(s/'installed'),FM_HEAVY_SLOTS='1',TMPDIR=str(s),FM_TEST_SCRATCH_ROOT=str(s))
for n in ('NODE_OPTIONS','FM_BUILD_LOCK_HELD','FM_BUILD_LOCK_BYPASS'):e.pop(n,None)
ev=pathlib.Path('~/.no-mistakes/evidence/01M64N0N0G8XM8MK440VZDFA4P')
holder=subprocess.Popen([str(repo/'bin/fm-build-lock.py'),'--',sys.executable,'-c','import pathlib,sys,time;pathlib.Path(sys.argv[1]).touch();time.sleep(30)',str(s/'ready')],env=e)
runner=None
try:
 end=time.monotonic()+10
 while not (s/'ready').exists():
  assert time.monotonic()<end;time.sleep(.03)
 with (ev/'round4-runner-out.log').open('w') as out, (ev/'round4-runner-err.log').open('w') as err:
  runner=subprocess.Popen(['bash',str(repo/'bin/fm-test-run.sh'),'--jobs','2','--max-wall-ms','2000','--json',str(ev/'round4-runner-timing.json'),'tests/fm-brief.test.sh','tests/fm-composer-lib.test.sh'],env=e,stdout=out,stderr=err)
 end=time.monotonic()+20
 while 'waiting for a heavy slot' not in (ev/'round4-runner-err.log').read_text():
  assert runner.poll() is None;assert time.monotonic()<end;time.sleep(.03)
 time.sleep(3);holder.terminate();holder.wait(10)
 rc=runner.wait(40);assert rc==1,rc
 output=(ev/'round4-runner-out.log').read_text(); summary=re.search(r'FM_TEST_SUMMARY total=2 failed=0 skipped_gate=0 duration_ms=(\d+)',output);assert summary,output
 d=int(summary[1]);assert d>=3000
 j=json.loads((ev/'round4-runner-timing.json').read_text());assert j['summary']['duration_ms']==d
 print(f'Runner queued behind occupied slot for at least 3 seconds, completed both workloads, reported {d}ms in text and JSON, and exited {rc} for the 2000ms invocation budget.')
finally:
 for p in (runner,holder):
  if p is not None and p.poll() is None:p.kill();p.wait()
