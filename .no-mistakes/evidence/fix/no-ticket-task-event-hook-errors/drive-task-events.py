import os, pathlib, subprocess, tempfile, shutil, json, time
root=pathlib.Path.cwd()
evidence=pathlib.Path('~/.no-mistakes/evidence/01M6CMVYPTC0Q67FHHB3BMKFDJ')
lab=pathlib.Path(tempfile.mkdtemp(prefix='.task-event-live-',dir=root))
transcript=[]
def say(s):
    transcript.append(s)
    print(s,flush=True)
def wait_idle(home):
    for _ in range(400):
        if not list((home/'state/task-events').glob('*.json')) and not (home/'state/.task-event-delivery.lock').exists():
            return
        time.sleep(.05)
    raise AssertionError('delivery did not become idle')
def setup(name,body):
    home=lab/name
    for sub in ('state','config','tmp'): (home/sub).mkdir(parents=True)
    (home/'state/task.status').write_text('working: validating hook delivery\n')
    hook=home/'hook'
    hook.write_text('#!/usr/bin/env bash\nprintf "%s\\n" "$1" >> "$FM_HOME/received.jsonl"\n'+body+'\n')
    hook.chmod(0o700)
    (home/'config/task-event-hook').write_text(str(hook)+'\n')
    return home

def emit(home,event,timeout='2',tmp=None):
    env=dict(os.environ)
    for key in list(env):
        if key.startswith('FM_') and key.endswith('_OVERRIDE'): env.pop(key)
    env.update(FM_HOME=str(home),FM_STATE_OVERRIDE=str(home/'state'),FM_CONFIG_OVERRIDE=str(home/'config'),FM_TASK_EVENT_TIMEOUT=timeout,TMPDIR=str(tmp or home/'tmp'))
    cmd=['bash','bin/fm-task-event.sh','task',event,'--summary','live CLI validation']
    if event.startswith('pr-'): cmd+=['--pr','https://example.org/repository/pull/42']
    result=subprocess.run(cmd,env=env,capture_output=True,text=True,timeout=10)
    assert result.returncode==0,(result.returncode,result.stderr)
    assert not result.stdout and not result.stderr,(result.stdout,result.stderr)
    wait_idle(home)
    assert not list((home/'tmp').iterdir()),'stderr temporary file leaked'
    return result

def log(home): return (home/'state/task-events.log').read_text()
def received(home): return [json.loads(s) for s in (home/'received.jsonl').read_text().splitlines()]
try:
    h=setup('contention', "printf 'reading configuration\\nerror: another clickup-axi writer is active; retry this event\\n\\n' >&2\nexit 1")
    events=['started','resumed','pr-opened','pr-merged']
    for event in events: emit(h,event)
    records=received(h)
    assert [r['event'] for r in records]==events,'unexpected retries or missing deliveries'
    assert all(r['schema']=='firstmate.task-event' and r['version']==1 and r['ticket'] is None for r in records)
    assert all('exit=1 reason="error: another clickup-axi writer is active; retry this event"' in s for s in log(h).splitlines())
    assert len(log(h).splitlines())==4
    assert (h/'state/task.status').read_text().count('task event hook failed')==1
    say('Contention: four CLI emissions returned 0; hook received each event once using firstmate.task-event v1 with ticket=null; one actionable status notification.')
    say(log(h).strip())
    h=setup('safety', "printf 'progress chatter\\nerror: チケット rejected Bearer pk_12345678901234567890123456789012 for \"task\" at C:\\path\\tmanual\\rrepair\\033[31m\\n\\n' >&2\nexit 7")
    emit(h,'started')
    output=log(h)
    assert 'pk_12345678901234567890123456789012' not in output
    assert '[redacted]' in output and 'チケット' in output and 'progress chatter' not in output
    assert len(output.splitlines())==1
    reason=output.split('reason="',1)[1].rstrip('\n')[:-1]
    assert '"' not in reason and '\\' not in reason and not any(ord(c)<32 for c in reason)
    say('Safety: last nonempty error retained; synthetic credential redacted; quotes, backslashes, control bytes removed; Japanese error preserved.')
    say(output.strip())
    (h/'hook').write_text('#!/usr/bin/env bash\nprintf "%s\\n" "$1" >> "$FM_HOME/received.jsonl"\nprintf "error: " >&2\nfor ((i=0;i<120;i++)); do printf "refused again " >&2; done\nprintf "\\n" >&2\nexit 1\n')
    emit(h,'resumed')
    reason=log(h).splitlines()[1].split('reason="',1)[1][:-1]
    assert len(reason)==200
    say('Length bound: long error produced a reason field of exactly 200 characters.')
    say(log(h).splitlines()[1])
    h=setup('silent', 'exit 9')
    emit(h,'started')
    assert 'exit=9' in log(h) and 'reason=' not in log(h)
    say('Silent failure: '+log(h).strip())
    (h/'hook').write_text('#!/usr/bin/env bash\nprintf "%s\\n" "$1" >> "$FM_HOME/received.jsonl"\nprintf "successful stderr noise\\n" >&2\nprintf "successful stdout noise\\n"\nexit 0\n')
    emit(h,'resumed')
    assert len(received(h))==2 and len(log(h).splitlines())==1
    say('Recovery: subsequent successful event delivered once; stdout/stderr suppressed and no success failure record appended.')
    h=setup('timeout', "printf 'tracker unavailable\\n' >&2\nsleep 10")
    t=time.monotonic(); emit(h,'started',timeout='1'); elapsed=time.monotonic()-t
    assert elapsed<8 and 'exit=124' in log(h) and 'tracker unavailable' in log(h)
    assert len(received(h))==1
    say('Timeout: one bounded attempt ended exit=124 and preserved pre-timeout error; CLI producer returned 0.')
    say(log(h).strip())
    (h/'hook').write_text('#!/usr/bin/env bash\nprintf "%s\\n" "$1" >> "$FM_HOME/received.jsonl"\nexit 0\n')
    emit(h,'resumed'); assert len(received(h))==2
    say('Timeout recovery: next queued event delivered successfully; drainer completed.')
    say('All targeted live CLI scenarios passed; all drainers completed and temporary captures were removed.')
finally:
    shutil.rmtree(lab)
    (evidence/'task-event-cli-transcript.txt').write_text('\n'.join(transcript)+'\n')
