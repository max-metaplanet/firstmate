#!/usr/bin/env bash
# Mirror publication, deletion proofs and ACP steering through executable interfaces.
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

root, work = map(Path, sys.argv[1:])
scripts = work / 'bin'
scripts.mkdir()
for name in ('fm-t3-mirrors.sh', 'fm-t3-mirrors.py', 'fm-t3-mirror-relay.py',
             'fm-t3-mirror-identity.py', 'fm-t3-redact.py'):
    shutil.copy(root / 'bin' / name, scripts / name)
(scripts / 'fm-crew-state.sh').write_text('cat "$FM_STATE_OVERRIDE/$1.current"\n')
(scripts / 'fm-peek.sh').write_text('cat "$FM_STATE_OVERRIDE/$1.capture"\n')
(scripts / 'fm-send.sh').write_text('''python3 - "$@" <<'SEND'
import json, os, sys
from pathlib import Path
state = Path(os.environ['FM_STATE_OVERRIDE'])
meta = dict(line.split('=', 1) for line in (state / (sys.argv[1] + '.meta')).read_text().splitlines())
if os.environ.get('FM_SEND_EXPECTED_SPAWN_GEN', '') != meta.get('spawn_gen', ''):
    sys.exit(1)
if os.environ.get('FM_SEND_EXPECTED_REMOTE_HOST', '') != meta.get('remote_host', ''):
    sys.exit(1)
with open(state / 'sent', 'a') as stream:
    stream.write(json.dumps({'task': sys.argv[1], 'text': sys.argv[2],
                            'generation': os.environ.get('FM_SEND_EXPECTED_SPAWN_GEN'),
                            'host': os.environ.get('FM_SEND_EXPECTED_REMOTE_HOST')}) + '\\n')
sys.exit(1 if (state / 'send-failure').exists() else 0)
SEND
''')
fake = scripts / 't3'
fake.write_text('''#!/usr/bin/env python3
import hashlib, json, os, subprocess, sys, time
from pathlib import Path
args = sys.argv[1:]
base = Path(args[args.index('--base-dir') + 1])
text = sys.stdin.read() if args[:2] in (['thread', 'start'], ['thread', 'send']) else ''
with open(base / 'calls', 'a') as stream:
    stream.write(json.dumps({'args': args, 'text': text}) + '\\n')
if (base / 'unreachable').exists():
    print('DO_NOT_LEAK auth=secret', file=sys.stderr)
    sys.exit(3)
def get(path):
    return json.loads(path.read_text())
def save(path, value):
    path.write_text(json.dumps(value))
def turn(cwd):
    requests = [
        {'jsonrpc': '2.0', 'id': 1, 'method': 'session/new', 'params': {'cwd': cwd}},
    ]
    process = subprocess.Popen([sys.executable, str(Path(__file__).with_name('fm-t3-mirror-relay.py'))],
                               stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
    process.stdin.write(json.dumps(requests[0]) + '\\n'); process.stdin.flush()
    session = json.loads(process.stdout.readline())['result']['sessionId']
    request = {'jsonrpc': '2.0', 'id': 2, 'method': 'session/prompt',
               'params': {'sessionId': session, 'prompt': [{'type': 'text', 'text': text}]}}
    out, _ = process.communicate(json.dumps(request) + '\\n', timeout=3)
    reply = json.loads(out.splitlines()[0])['params']['update']['content']['text']
    return [{'role': 'user', 'text': text}, {'role': 'assistant', 'text': reply}]
if args[:2] == ['project', 'add']:
    if (base / 'project-failure').exists():
        sys.exit(4)
    project_path = base / ('project-' + hashlib.sha256(args[2].encode()).hexdigest() + '.json')
    if project_path.exists():
        print(f"ProjectAlreadyExistsError: An active project already exists for '{args[2]}'", file=sys.stderr)
        sys.exit(4)
    save(project_path, {'id': 'project-' + Path(args[2]).name, 'workspace': args[2]})
    if (base / 'teardown-in-project').exists():
        (Path(os.environ['FM_HOME']) / 'state' / (Path(args[2]).parent.name + '.meta')).unlink()
    if (base / 'project-timeout').exists():
        (base / 'project-timeout').unlink()
        time.sleep(7)
    print('added')
elif args[:2] == ['thread', 'start']:
    n = len(list(base.glob('identity-*.json'))) + 1
    thread = f'thread-{n}'
    project = get(base / ('project-' + hashlib.sha256(args[2].encode()).hexdigest() + '.json'))['id']
    save(base / f'identity-{thread}.json', {'threadId': thread, 'projectId': project,
         'title': args[args.index('--title') + 1], 'providerInstanceId': args[args.index('--provider') + 1],
         'model': args[args.index('--model') + 1], 'workspace': args[2]})
    save(base / f'turns-{thread}.json', turn(args[2]))
    if (base / 'uncertain-create').exists():
        sys.exit(4)
    print(json.dumps({'threadId': thread, 'projectId': project}))
elif args[:2] == ['thread', 'show']:
    print(json.dumps({'thread': get(base / f'identity-{args[2]}.json'),
                      'messages': get(base / f'turns-{args[2]}.json')}))
elif args[:2] == ['thread', 'send']:
    if (base / 'uncertain-send').exists():
        sys.exit(4)
    path = base / f'turns-{args[2]}.json'
    save(path, get(path) + turn(get(base / f'identity-{args[2]}.json')['workspace']))
    print('{}')
elif args[:2] == ['thread', 'list']:
    project = args[args.index('--project') + 1]
    rows = [get(path) for path in base.glob('identity-*.json') if get(path)['projectId'] == project]
    if (base / 'extra-thread').exists():
        rows.append({'threadId': 'unrelated', 'projectId': project})
    print(json.dumps(rows))
elif args[:2] == ['project', 'remove']:
    if (base / 'remove-failure').exists():
        sys.exit(4)
    projects = [(path, get(path)) for path in base.glob('project-*.json')]
    path, project = next((path, value) for path, value in projects
                         if args[2] in (value['id'], value['workspace']))
    if '--force' not in args and any(get(path)['projectId'] == project['id'] for path in base.glob('identity-*.json')):
        sys.exit(4)
    (base / ('removed-' + project['id'])).touch()
    path.unlink()
    print('removed')
else:
    sys.exit(9)
''')
fake.chmod(0o755)
base = work / 'base'; base.mkdir()
home = work / 'home'
state = home / 'state'; state.mkdir(parents=True)
config = home / 'config'; config.mkdir()
env = {k: v for k, v in os.environ.items() if not k.startswith('FM_')}
env.update(FM_HOME=str(home), FM_T3_BIN=str(fake), FM_T3_BASE_DIR=str(base))
maps = state / 't3-mirrors' / 'tasks'

def get(path):
    return json.loads(path.read_text())

def calls(verb):
    path = base / 'calls'
    return [json.loads(line) for line in path.read_text().splitlines()
            if json.loads(line)['args'][:2] == verb] if path.exists() else []

def command(*args, environment=env):
    result = subprocess.run(['bash', str(scripts / 'fm-t3-mirrors.sh'), *args], env=environment,
                            capture_output=True, text=True, timeout=15)
    assert result.returncode == 0, result.stderr

def task(name, remote=False):
    (state / f'{name}.meta').write_text('kind=secondmate\nremote_host=host-a\n' if remote else 'kind=ship\nspawn_gen=first\n')
    (state / f'{name}.current').write_text('state: working · source: run-step · step review TOKEN=DO_NOT_LEAK\n')
    (state / f'{name}.status').write_text('working [at=123]: DO_NOT_LEAK\n')
    (state / f'{name}.capture').write_text('● Updated the validation helper.\nAPI_TOKEN=DO_NOT_LEAK\nTests passed.\n')

class Relay:
    def __init__(self, record, load=False):
        self.process = subprocess.Popen([sys.executable, str(scripts / 'fm-t3-mirror-relay.py')],
                                        stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, env=env)
        assert self.rpc('initialize', {})[-1]['result']['agentCapabilities'] == {'loadSession': True}
        reply = self.rpc('session/load' if load else 'session/new',
                         {'sessionId': 'existing-acp-session', 'cwd': record['workspace']})[-1]['result']
        self.session = 'existing-acp-session' if load else reply['sessionId']
    def rpc(self, method, params):
        self.process.stdin.write(json.dumps({'jsonrpc': '2.0', 'id': 1, 'method': method, 'params': params}) + '\n')
        self.process.stdin.flush()
        messages = []
        while True:
            item = json.loads(self.process.stdout.readline()); messages.append(item)
            if item.get('id') == 1:
                return messages
    def prompt(self, text, wrapped=False):
        blocks = [{'type': 'text', 'text': text}]
        if wrapped:
            blocks = [
                {'type': 'text', 'text': '<t3_code_instructions>Host policy</t3_code_instructions>\n\n<user_request>\n' + text + '\n</user_request>'},
                {'type': 'text', 'text': '<runtime_info>Context</runtime_info>'}]
        return self.rpc('session/prompt', {'sessionId': self.session, 'prompt': blocks})[0]['params']['update']['content']['text']
    def close(self):
        self.process.stdin.close()
        assert self.process.wait(timeout=3) == 0

def sent():
    return (state / 'sent').read_text().splitlines() if (state / 'sent').exists() else []

command('sync'); command('kick')
assert not (state / 't3-mirrors').exists() and not calls(['project', 'add'])
(config / 't3-mirrors').write_text('1\n')
task('retry')
(base / 'project-failure').touch()
command('sync')
assert calls(['project', 'add']) and not calls(['thread', 'start'])
setup = get(maps / 'retry.json')
assert setup['phase'] == 'setup'
unready = Relay(setup, load=True)
assert 'refused' in unready.prompt('do not steer before thread creation') and not sent()
unready.close()
(base / 'project-failure').unlink()
command('sync')
retried = get(maps / 'retry.json')
assert retried['phase'] == 'ready' and not retried['pending']
assert retried['nonce'] == setup['nonce']
assert len(calls(['thread', 'start'])) == 1
(state / 'retry.meta').unlink()
command('retire', 'retry')
assert not (maps / 'retry.json').exists()
assert (base / ('removed-' + retried['projectId'])).exists()
print('ok - project setup failure retries publication and the recovered mirror retires normally')
task('setup-race')
(base / 'teardown-in-project').touch()
before = len(calls(['thread', 'start']))
command('sync')
(base / 'teardown-in-project').unlink()
raced = get(maps / 'setup-race.json')
assert raced['phase'] == 'setup' and not (state / 'setup-race.meta').exists()
assert len(calls(['thread', 'start'])) == before
intruder = base / 'identity-intruder.json'
intruder.write_text(json.dumps({'projectId': 'project-' + raced['nonce']}))
command('retire', 'setup-race')
assert (maps / 'setup-race.json').exists()
assert not (base / ('removed-project-' + raced['nonce'])).exists()
intruder.unlink()
command('retire', 'setup-race')
assert not (maps / 'setup-race.json').exists()
assert (base / ('removed-project-' + raced['nonce'])).exists()
assert '--force' not in calls(['project', 'remove'])[-1]['args']
task('ambiguous-setup')
(base / 'project-timeout').touch()
command('sync')
ambiguous = get(maps / 'ambiguous-setup.json')
assert ambiguous['phase'] == 'setup' and len(calls(['thread', 'start'])) == before
command('sync')
recovered = get(maps / 'ambiguous-setup.json')
assert recovered['phase'] == 'ready' and not recovered['pending']
assert recovered['nonce'] == ambiguous['nonce']
assert recovered['projectId'] == 'project-' + ambiguous['nonce']
assert len(calls(['thread', 'start'])) == before + 1
(state / 'ambiguous-setup.meta').unlink()
command('retire', 'ambiguous-setup')
assert not (maps / 'ambiguous-setup.json').exists()
print('ok - teardown during project setup retires the empty project; timed-out project add retries the same workspace')
task('alpha'); task('platform', True)
command('sync')
alpha, platform = get(maps / 'alpha.json'), get(maps / 'platform.json')
assert alpha['projectId'] != platform['projectId']
assert alpha['workspace'] != platform['workspace']
assert not alpha['pending'] and not platform['pending']
assert platform['incarnation'] == {'remote_host': 'host-a'}
reply = get(base / f"turns-{alpha['threadId']}.json")[-1]['text']
assert 'Updated the validation helper.' in reply and 'Tests passed.' in reply
assert 'DO_NOT_LEAK' not in (base / 'calls').read_text() and 'DO_NOT_LEAK' not in reply
starts = len(calls(['thread', 'start']))
command('sync', environment=dict(env, FM_T3_BIN='/missing', FM_T3_BASE_DIR='/missing'))
assert len(calls(['thread', 'start'])) == starts and not calls(['thread', 'send'])
print('ok - distinct per-task projects show real redacted tails; saved connections and dedup survive restart')

# The same task id in another home has a separate mapping and project.
other = work / 'other-home'
(other / 'state').mkdir(parents=True); (other / 'config').mkdir()
(other / 'config' / 't3-mirrors').write_text('1\n')
for suffix in ('meta', 'current', 'capture'):
    shutil.copy(state / f'alpha.{suffix}', other / 'state' / f'alpha.{suffix}')
command('sync', environment=dict(env, FM_HOME=str(other)))
other_record = get(other / 'state' / 't3-mirrors' / 'tasks' / 'alpha.json')
assert other_record['projectId'] != alpha['projectId']
assert other_record['workspace'] != alpha['workspace']
print('ok - the same task id in another home has an independent project and mapping')


relay = Relay(alpha)
marker = work / 'not-executed'
for text in (f'please inspect $(touch {marker})', f'touch {marker}', 'two lines\nwith a quote \' and `backticks`'):
    assert 'Instruction recorded for alpha' in relay.prompt(text)
assert not marker.exists() and len(sent()) == 3
assert json.loads(sent()[-1])['text'] == 'two lines\nwith a quote \' and `backticks`'
for text in ('/exit', '$skill', '--key Enter', '   ', 'x' * 4001):
    assert 'refused' in relay.prompt(text)
assert len(sent()) == 3
assert 'error' in relay.rpc('tools/call', {'name': 'shell'})[-1]
assert 'error' in relay.rpc('session/set_model', {'modelId': 'llm'})[-1]
# Payload text cannot rebind a session or recover missing ACP cwd.
no_context = Relay(dict(alpha, workspace=str(work)))
assert no_context.prompt(get(base / f"turns-{alpha['threadId']}.json")[0]['text']).startswith('Work is in progress.')
before = len(sent())
assert 'refused' in no_context.prompt('do not infer identity from that update')
assert len(sent()) == before
no_context.close()
relay.close()
relay = Relay(alpha, load=True)
assert 'Instruction recorded' in relay.prompt('resume after actual process restart', wrapped=True)
assert json.loads(sent()[-1])['generation'] == 'first'
remote = Relay(platform, load=True)
assert 'Instruction recorded for platform' in remote.prompt('check remote work', wrapped=True)
assert json.loads(sent()[-1])['host'] == 'host-a'
remote.close()
print('ok - actual ACP restart loads the existing mapping without an update; typed turns use fm-send for local and markerless remote tasks')

# The same live identity mutations must stop publication AND inbound delivery.
identity_path = base / f"identity-{alpha['threadId']}.json"
identity = get(identity_path)
for field in ('threadId', 'projectId', 'title', 'providerInstanceId', 'model'):
    identity_path.write_text(json.dumps(dict(identity, **{field: 'different'})))
    (state / 'alpha.capture').write_text(f'new output for {field}\n')
    before = len(calls(['thread', 'send'])); delivered = len(sent())
    command('sync')
    assert len(calls(['thread', 'send'])) == before, field
    assert 'refused' in relay.prompt('must not steer renamed/reused thread'), field
    assert len(sent()) == delivered, field
identity_path.write_text(json.dumps(identity))
for field in ('nonce', 'task', 'home', 'state', 'config'):
    original = get(maps / 'alpha.json')
    changed = dict(original, **{field: 'changed'})
    (maps / 'alpha.json').write_text(json.dumps(changed))
    delivered = len(sent())
    before = len(calls(['thread', 'send']))
    command('sync')
    assert len(calls(['thread', 'send'])) == before, field
    assert 'refused' in relay.prompt('must not use a changed mapping'), field
    assert len(sent()) == delivered, field
    (maps / 'alpha.json').write_text(json.dumps(original))
(state / 'send-failure').touch()
assert 'unconfirmed' in relay.prompt('a send may already be recorded')
(state / 'send-failure').unlink()
print('ok - thread/project/title/provider/model and mapping mismatches refuse both directions; send failures report uncertain delivery')

# A teardown skipped by a busy publisher cannot let the old cwd steer a new run.
(state / 'alpha.meta').unlink()
with (state / 't3-mirrors' / 'publisher.lock').open('w') as lock:
    fcntl.flock(lock, fcntl.LOCK_EX)
    command('retire', 'alpha')
(state / 'alpha.meta').write_text('kind=ship\nspawn_gen=replacement\n')
assert 'refused' in relay.prompt('stale thread')
command('sync')
replacement = get(maps / 'alpha.json')
assert replacement['nonce'] != alpha['nonce'] and replacement['threadId'] != alpha['threadId']
assert (base / ('removed-' + alpha['projectId'])).exists()
assert 'refused' in relay.prompt('old cwd after remap')
relay.close()
remote = Relay(platform)
(state / 'platform.meta').write_text('kind=secondmate\nremote_host=host-b\n')
assert 'refused' in remote.prompt('old remote route')
remote.close()
print('ok - task incarnation and remote route changes revoke old threads even when retirement skipped a busy lock')

# No deletion unless exactly the recorded ordinary thread remains in the project.
(state / 'alpha.meta').unlink()
(base / 'extra-thread').touch()
extra = Relay(replacement)
assert 'refused' in extra.prompt('ambiguous project')
extra.close()
(config / 't3-mirrors').write_text('0\n')
before = len(calls(['project', 'remove']))
command('retire', 'alpha')
assert len(calls(['project', 'remove'])) == before
assert get(maps / 'alpha.json')['retired'] is True
(base / 'extra-thread').unlink()
(base / 'remove-failure').touch()
command('retire', 'alpha')
assert (maps / 'alpha.json').exists()
(base / 'remove-failure').unlink()
command('retire', 'alpha')
assert not (maps / 'alpha.json').exists() and (maps / 'platform.json').exists()
assert (base / ('removed-' + replacement['projectId'])).exists()
print('ok - cleanup while disabled requires the single-thread match and preserves revoked mappings on failed proof/removal')

(config / 't3-mirrors').write_text('1\n')
task('uncertain')
(base / 'uncertain-create').touch()
command('sync')
count = len(calls(['thread', 'start']))
(base / 'uncertain-create').unlink()
command('sync')
assert len(calls(['thread', 'start'])) == count
assert get(maps / 'uncertain.json')['phase'] == 'creating'
# A failed send cannot be blindly replayed by the next pass.
platform = get(maps / 'platform.json')
(base / 'uncertain-send').touch()
(state / 'platform.capture').write_text('changed after send\n')
command('sync')
count = len(calls(['thread', 'send']))
(base / 'uncertain-send').unlink()
command('sync')
assert len(calls(['thread', 'send'])) == count
assert get(maps / 'platform.json')['pending']
(base / 'unreachable').touch()
command('sync')
assert 'DO_NOT_LEAK' not in (state / 't3-mirrors' / 'errors.log').read_text()
print('ok - ambiguous creation and sends preserve journals without replay; unavailable T3 stays best effort with safe logs')

import time
drain = work / 'drain-home'
for directory in ('state', 'config', 'data'):
    (drain / directory).mkdir(parents=True)
(drain / 'config' / 'supervision-host-off').touch()
(drain / 'config' / 't3-mirrors').write_text('1\n')
(drain / 'state' / 'unavailable.meta').write_text('kind=ship\nspawn_gen=first\nbackend=tmux\nwindow=\nworktree=\n')
drain_env = dict(env, FM_HOME=str(drain), FM_ROOT_OVERRIDE=str(root),
                 FM_CONFIG_OVERRIDE=str(drain / 'config'), FM_STATE_OVERRIDE=str(drain / 'state'),
                 FM_DATA_OVERRIDE=str(drain / 'data'), FM_PROJECTS_OVERRIDE=str(drain / 'projects'),
                 FM_SUPERVISION_ACTOR='main')
result = subprocess.run(['bash', str(root / 'bin' / 'fm-wake-drain.sh')], env=drain_env,
                        capture_output=True, text=True, timeout=10)
assert result.returncode == 0, result.stderr
errors = drain / 'state' / 't3-mirrors' / 'errors.log'
for attempt in range(100):
    if errors.exists():
        break
    time.sleep(.1)
assert errors.exists() and 'project-unavailable' in errors.read_text(), errors
print('ok - real wake drain succeeds while detached T3 publication fails')
PY
