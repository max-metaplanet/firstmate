#!/usr/bin/env bash
# Portable mirror/ACP contract tests. Every T3 and crew-state call is fake.
set -euo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
work=$(fm_test_tmproot fm-t3-mirrors)
python3 - "$ROOT" "$work" <<'PY'
import fcntl
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time

root, work = map(Path, sys.argv[1:])
scripts = work / 'bin'
scripts.mkdir()
for name in ('fm-t3-mirrors.sh', 'fm-t3-mirrors.py', 'fm-t3-mirror-relay.py'):
    shutil.copy(root / 'bin' / name, scripts / name)
crew = scripts / 'fm-crew-state.sh'
crew.write_text('''#!/usr/bin/env bash
cat "$FM_STATE_OVERRIDE/$1.current"
''')
fake = scripts / 't3'
fake.write_text('''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
args = sys.argv[1:]
text = sys.stdin.read() if args[:2] in (['thread', 'start'], ['thread', 'send']) else ''
with open(os.environ['MIRROR_CALLS'], 'a') as f:
    f.write(json.dumps({'args': args, 'text': text}) + '\\n')
base = Path(args[args.index('--base-dir') + 1])
def turn(text):
    payload = text.split("[fm-t3-mirror]: # '", 1)[1][:-1]
    update = json.loads(payload)
    outcomes = {
        'working': ('Work is in progress.', 'Firstmate will post the next meaningful change.'),
        'paused': ('Waiting for an external condition.', 'Firstmate will check when the wait clears.'),
        'done': ('The recorded work is ready.', 'Firstmate will handle delivery and landing.'),
        'blocked': ('Work is blocked.', 'Firstmate will inspect the blocker.'),
        'failed': ('The recorded work failed.', 'Firstmate will inspect the failure.'),
    }
    outcome, action = outcomes[update['state']]
    kind = 'Secondmate' if update['kind'] == 'secondmate' else 'Worker'
    lines = [f"{outcome} ({update['state']})", f"{kind} · {update['task']}"]
    if update.get('phase'):
        lines.append(f"Validation step: {update['phase']}.")
    if update.get('event'):
        lines.append(f"Last recorded event: {update['event']} (historical).")
    lines.append(f"Next: {action}")
    if update.get('pr'):
        lines.append(update['pr'])
    lines.append(f"Observed: {update['observed_at']}")
    return [{'role': 'user', 'text': text}, {'role': 'assistant', 'text': '\\n\\n'.join(lines) + '\\n'}]
if (base / 'unreachable').exists():
    print('secret auth-token-in-error', file=sys.stderr)
    sys.exit(3)
if (base / 'slow').exists():
    import time
    time.sleep(8)
if args[:2] == ['project', 'add']:
    marker = base / 'project'
    if marker.exists():
        print(f"ProjectAlreadyExistsError: An active project already exists for '{args[2]}'", file=sys.stderr)
        sys.exit(1)
    marker.write_text(args[2])
    print('Added project mirror-project')
elif args[:2] == ['thread', 'start']:
    count = base / 'count'
    n = int(count.read_text()) + 1 if count.exists() else 1
    count.write_text(str(n))
    (base / f'turns-mirror-{n}.json').write_text(json.dumps(turn(text)))
    (base / f'identity-mirror-{n}.json').write_text(json.dumps({
        'threadId': f'mirror-{n}', 'projectId': 'mirror-project',
        'title': args[args.index('--title') + 1],
        'providerInstanceId': args[args.index('--provider') + 1], 'model': 'mirror'}))
    if (base / 'uncertain-create').exists():
        sys.exit(4)
    result = {'threadId': f'mirror-{n}', 'runId': f'run-{n}'}
    if '--wait' in args:
        result.update(status='completed', reply='synthetic reply', error=None)
    else:
        result['projectId'] = 'mirror-project'
    print(json.dumps(result))
elif args[:2] == ['thread', 'send']:
    if (base / 'uncertain-send').exists():
        sys.exit(4)
    path = base / f'turns-{args[2]}.json'
    path.write_text(json.dumps(json.loads(path.read_text()) + turn(text)))
    print('{"status":"completed"}')
elif args[:2] == ['thread', 'show']:
    print(json.dumps({'thread': json.loads((base / f'identity-{args[2]}.json').read_text()),
                      'messages': json.loads((base / f'turns-{args[2]}.json').read_text())}))
else:
    sys.exit(9)
''')
fake.chmod(0o755)
base = work / 'base'
base.mkdir()
calls_path = work / 'calls'
env = dict(os.environ, FM_HOME=str(work / 'home'), FM_T3_BIN=str(fake),
           FM_T3_BASE_DIR=str(base), MIRROR_CALLS=str(calls_path))
home = Path(env['FM_HOME'])
state = home / 'state'
config = home / 'config'
state.mkdir(parents=True)
config.mkdir()
# Do not inherit the enclosing task's home overrides into fixtures.
for key in ('FM_STATE_OVERRIDE', 'FM_CONFIG_OVERRIDE', 'FM_ROOT_OVERRIDE'):
    env.pop(key, None)

def command(*args, environment=env):
    result = subprocess.run(['bash', str(scripts / 'fm-t3-mirrors.sh'), *args], env=environment,
                            capture_output=True, text=True, timeout=15)
    assert result.returncode == 0, result.stderr
    return result

def calls(kind=None):
    values = [json.loads(line) for line in calls_path.read_text().splitlines()] if calls_path.exists() else []
    return [item for item in values if item['args'][:2] == kind] if kind else values

def task(name, kind='ship', current='working'):
    (state / f'{name}.meta').write_text(f'kind={kind}\nspawn_gen=first\n')
    (state / f'{name}.current').write_text(f'state: {current} · source: run-step · step review TOKEN=private-secret\n')
    (state / f'{name}.status').write_text('working [at=123]: secret-value DO_NOT_FORWARD\n')

command('sync')
command('kick')
assert not calls() and not (state / 't3-mirrors').exists()
(config / 't3-mirrors').write_text('0\n')
command('sync')
assert not calls() and not (state / 't3-mirrors').exists()
print('ok - off by default creates no state and never calls T3')

(config / 't3-mirrors').write_text('1\n')
task('alpha')
task('platform', 'secondmate', 'paused')
before = {p.name: p.read_bytes() for p in state.glob('*.meta')}
command('sync')
assert len(calls(['thread', 'start'])) == 2
maps = state / 't3-mirrors' / 'tasks'
alpha = json.loads((maps / 'alpha.json').read_text())
platform = json.loads((maps / 'platform.json').read_text())
assert alpha['threadId'] != platform['threadId'] and alpha['projectId'] == platform['projectId']
assert alpha['title'].startswith('Mirror · Worker · alpha')
assert any('Secondmate · platform' in item['args'][item['args'].index('--title') + 1]
           for item in calls(['thread', 'start']))
command('sync')
assert len(calls(['thread', 'start'])) == 2 and not calls(['thread', 'send'])
assert before == {p.name: p.read_bytes() for p in state.glob('*.meta')}
print('ok - one mapping per task and secondmate, with unchanged endpoint metadata')

turns_path = base / f"turns-{alpha['threadId']}.json"
turns = json.loads(turns_path.read_text())
legacy_update = json.loads(turns[0]['text'].split("[fm-t3-mirror]: # '", 1)[1][:-1])
turns[0]['text'] = json.dumps(legacy_update)
turns_path.write_text(json.dumps(turns))
legacy_record = dict(alpha, pending=alpha['fingerprint'], pending_update=legacy_update)
legacy_record.pop('pending_prompt', None)
(maps / 'alpha.json').write_text(json.dumps(legacy_record))
command('sync')
assert not calls(['thread', 'send'])
assert not json.loads((maps / 'alpha.json').read_text())['pending']
print('ok - a legacy pending JSON prompt is confirmed without replaying delivery')

(state / 'alpha.current').write_text('state: done · source: run-step · checks green secret-value\n')
(state / 'alpha.status').write_text('done [at=456]: PR https://github.com/example/project/pull/7 secret-value\n')
command('sync')
assert len(calls(['thread', 'send'])) == 1
sent = calls(['thread', 'send'])[0]
assert sent['args'][2] == alpha['threadId']
assert sent['text'].splitlines()[0] == 'Update · done · alpha'
update = json.loads(sent['text'].split("[fm-t3-mirror]: # '", 1)[1][:-1])
assert update['state'] == 'done' and update['pr'] == 'https://github.com/example/project/pull/7'
assert 'secret-value' not in calls_path.read_text() and 'DO_NOT_FORWARD' not in calls_path.read_text()
assert 'private-secret' not in calls_path.read_text()
command('sync', environment=dict(env, FM_T3_BIN='/missing', FM_T3_BASE_DIR='/missing'))
assert len(calls(['thread', 'send'])) == 1
print('ok - meaningful updates use the saved binding and never forward raw status or crew prose')

# Same task id in another home gets its own thread in the same presentation project.
other_home = work / 'other-home'
(other_home / 'config').mkdir(parents=True)
(other_home / 'state').mkdir()
(other_home / 'config' / 't3-mirrors').write_text('1\n')
(other_home / 'state' / 'alpha.meta').write_text('kind=scout\n')
(other_home / 'state' / 'alpha.current').write_text('state: blocked · source: status-log · private-secret\n')
command('sync', environment=dict(env, FM_HOME=str(other_home)))
assert len(calls(['thread', 'start'])) == 3
other = json.loads((other_home / 'state' / 't3-mirrors' / 'tasks' / 'alpha.json').read_text())
assert other['threadId'] != alpha['threadId']
assert all(item['args'][2] == str(base / 'userdata' / 'firstmate-mirrors') for item in calls(['project', 'add']))
print('ok - home/task identities remain distinct in one shared project')

(base / 'unreachable').touch()
(state / 'alpha.current').write_text('state: failed · source: status-log · private-secret\n')
command('sync')
assert (maps / 'alpha.json').exists()
assert 'secret' not in (state / 't3-mirrors' / 'errors.log').read_text()
send_count = len(calls(['thread', 'send']))
(base / 'unreachable').unlink()
command('sync')
assert len(calls(['thread', 'send'])) == send_count + 1
assert not json.loads((maps / 'alpha.json').read_text())['pending']
print('ok - unreachable preflight returns success, logs safe errors, and safely catches up on recovery')

(base / 'uncertain-send').touch()
(state / 'alpha.current').write_text('state: working · source: status-log · resumed\n')
command('sync')
send_count = len(calls(['thread', 'send']))
(base / 'uncertain-send').unlink()
command('sync')
assert len(calls(['thread', 'send'])) == send_count
assert json.loads((maps / 'alpha.json').read_text())['pending']
print('ok - uncertain sends read for a receipt and never blindly replay')

identity_path = base / f"identity-{platform['threadId']}.json"
identity = json.loads(identity_path.read_text())
identity_path.write_text(json.dumps(dict(identity, providerInstanceId='claudeAgent')))
(state / 'platform.current').write_text('state: working · source: status-log · resumed\n')
send_count = len(calls(['thread', 'send']))
command('sync')
assert len(calls(['thread', 'send'])) == send_count
assert 'mirror-thread-identity-mismatch' in (state / 't3-mirrors' / 'errors.log').read_text()
identity_path.write_text(json.dumps(identity))
command('sync')
assert len(calls(['thread', 'send'])) == send_count + 1
print('ok - a repurposed thread receives no mirror prompt or model invocation')

task('uncertain')
(base / 'uncertain-create').touch()
command('sync')
starts = len(calls(['thread', 'start']))
(base / 'uncertain-create').unlink()
command('sync')
assert len(calls(['thread', 'start'])) == starts
assert json.loads((maps / 'uncertain.json').read_text())['phase'] == 'creating'
print('ok - ambiguous creation preserves intent and retry cannot duplicate a thread')

# Retirement does not contact T3 or act on records that still have live metadata.
count = len(calls())
command('retire', 'alpha')
assert (maps / 'alpha.json').exists()
(state / 'alpha.meta').unlink()
(config / 't3-mirrors').write_text('0\n')
command('retire', 'alpha')
assert not (maps / 'alpha.json').exists() and (maps / 'platform.json').exists()
assert len(calls()) == count
assert (other_home / 'state' / 't3-mirrors' / 'tasks' / 'alpha.json').exists()
command('retire', '../platform')
assert (maps / 'platform.json').exists()
print('ok - retirement while disabled removes only the exact retired task mapping and preserves T3 history')

(config / 't3-mirrors').write_text('1\n')
with (state / 't3-mirrors' / 'publisher.lock').open('w') as lock:
    fcntl.flock(lock, fcntl.LOCK_EX)
    command('sync')
    assert len(calls()) == count
print('ok - overlapping syncs skip without waiting or duplicating sends')

# The actual supervision entry point remains successful when its detached
# publisher cannot reach T3. The fixture has no live endpoint or project.
drain_home = work / 'drain-home'
(drain_home / 'state').mkdir(parents=True)
(drain_home / 'data').mkdir()
(drain_home / 'config').mkdir()
(drain_home / 'config' / 'supervision-host-off').touch()
(drain_home / 'config' / 't3-mirrors').write_text('1\n')
(drain_home / 'state' / 'unavailable.meta').write_text('kind=scout\nbackend=tmux\nwindow=\nworktree=\n')
(base / 'unreachable').touch()
drain_env = dict(env, FM_HOME=str(drain_home), FM_ROOT_OVERRIDE=str(root),
                 FM_CONFIG_OVERRIDE=str(drain_home / 'config'), FM_STATE_OVERRIDE=str(drain_home / 'state'),
                 FM_DATA_OVERRIDE=str(drain_home / 'data'), FM_PROJECTS_OVERRIDE=str(drain_home / 'projects'),
                 FM_SUPERVISION_ACTOR='main')
result = subprocess.run(['bash', str(root / 'bin' / 'fm-wake-drain.sh')], env=drain_env,
                        capture_output=True, text=True, timeout=5)
assert result.returncode == 0, result.stderr
error_log = drain_home / 'state' / 't3-mirrors' / 'errors.log'
deadline = time.monotonic() + 10
while not error_log.exists() and time.monotonic() < deadline:
    time.sleep(.05)
assert error_log.exists() and 'project-unavailable' in error_log.read_text()
(base / 'unreachable').unlink()
print('ok - real wake drain succeeds while detached T3 publication fails')

relay = subprocess.Popen([sys.executable, str(scripts / 'fm-t3-mirror-relay.py')],
                         stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
def rpc(identifier, method, params):
    relay.stdin.write(json.dumps({'jsonrpc': '2.0', 'id': identifier, 'method': method, 'params': params}) + '\n')
    relay.stdin.flush()
    messages = []
    while True:
        message = json.loads(relay.stdout.readline())
        messages.append(message)
        if message.get('id') == identifier:
            return messages

assert rpc(1, 'initialize', {'protocolVersion': 2})[-1]['result']['agentCapabilities'] == {'loadSession': True}
session = rpc(2, 'session/new', {'cwd': str(work), 'mcpServers': [{'name': 'DO_NOT_CALL'}]})[-1]['result']['sessionId']
messages = rpc(3, 'session/prompt', {'sessionId': session, 'prompt': [{'type': 'text', 'text': json.dumps(update)}]})
reply = messages[0]['params']['update']['content']['text']
assert reply.startswith('The recorded work is ready. (done)') and 'Next:' in reply and 'Observed:' in reply
assert update['pr'] in reply and messages[-1]['result']['stopReason'] == 'end_turn'
assert len(messages) == 2
messages = rpc(10, 'session/prompt', {'sessionId': session, 'prompt': [{'type': 'text', 'text': sent['text']}]})
assert messages[0]['params']['update']['content']['text'] == reply
messages = rpc(11, 'session/prompt', {'sessionId': session, 'prompt': [{'type': 'text', 'text': sent['text'].replace('Update · done', 'Update · working')}]})
assert messages[0]['params']['update']['content']['text'].startswith('Presentation only.')
print('ok - short Markdown prompts preserve the exact status and reject mismatched headings')
wrapped = '<t3_code_instructions>Host context</t3_code_instructions>\n\n<user_request>\n' + json.dumps(update) + '\n</user_request>'
messages = rpc(9, 'session/prompt', {'sessionId': session, 'prompt': [
    {'type': 'text', 'text': wrapped}, {'type': 'text', 'text': '<runtime_info>Host metadata</runtime_info>'}]})
assert messages[0]['params']['update']['content']['text'] == reply
marker = work / 'executed'
for prompt in (f'touch {marker}', f'$(touch {marker})', '/bin/sh -c whoami'):
    messages = rpc(4, 'session/prompt', {'sessionId': session, 'prompt': [{'type': 'text', 'text': prompt}]})
    assert messages[0]['params']['update']['content']['text'].startswith('Presentation only.')
assert not marker.exists()
assert 'error' in rpc(5, 'tools/call', {'name': 'shell', 'command': f'touch {marker}'})[-1]
assert 'error' in rpc(6, 'session/set_model', {'modelId': 'some-llm'})[-1]
rpc(7, 'session/load', {'sessionId': session})
messages = rpc(8, 'session/prompt', {'sessionId': session, 'prompt': [{'type': 'text', 'text': json.dumps(update)}]})
assert messages[0]['params']['update']['content']['text'] == reply
relay.stdin.close()
assert relay.wait(timeout=2) == 0 and not marker.exists()
print('ok - real ACP relay formats statuses, settles each prompt, reloads sessions, and refuses commands/tools/models')
PY
