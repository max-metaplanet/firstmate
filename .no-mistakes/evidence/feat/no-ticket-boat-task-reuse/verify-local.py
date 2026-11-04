import fcntl
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile

repo = Path.cwd()
evidence = Path('~/.no-mistakes/evidence/01M6J76EKE8D0YSJCYCX6XA9S4')
scratch = Path(tempfile.mkdtemp(prefix='.boat-verification-', dir=repo))
logs = []
env = {k: v for k, v in os.environ.items() if not k.startswith(('FM_', 'GIT_', 'BOAT_', 'UPSTASH_', 'TASKS_AXI'))}
env.update(HOME=str(scratch / 'user'), GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL='/dev/null', GIT_CEILING_DIRECTORIES=str(scratch))
Path(env['HOME']).mkdir()
home = scratch / 'home'
(home / 'state/boat-offload/jobs').mkdir(parents=True)
env['FM_HOME'] = str(home)
work = scratch / 'source'
work.mkdir()

def call(args, expected):
    proc = subprocess.run(['bash', str(repo / 'bin/fm-boat-run.sh'), *args], env=env, text=True, capture_output=True, timeout=20)
    logs.append(dict(args=args, exit=proc.returncode, stdout=proc.stdout, stderr=proc.stderr))
    assert proc.returncode == expected, logs[-1]
    return proc

def git(*args):
    subprocess.run(['git', '-C', str(work), *args], env=env, check=True, capture_output=True)

def identity(task, generation='g1', root=work):
    owner = dict(home=str(home), task=task, generation=generation, worktree=str(root))
    (home / ('state/' + task + '.meta')).write_text('endpoint_task_id=' + task + '\nkind=ship\nspawn_gen=' + generation + '\nworktree=' + str(root) + '\n')
    digest = hashlib.sha256((str(home) + '\0' + task).encode()).hexdigest()
    return owner, home / ('state/boat-offload/jobs/task-' + digest + '.json')

try:
    git('init', '-q')
    (work / 'visible.txt').write_text('fresh source\n')
    (work / '.env').write_text('screening sentinel only\n')
    git('add', '.')
    git('-c', 'user.name=Validation', '-c', 'user.email=validation@example.invalid', 'commit', '-qm', 'disposable input')
    env['FM_TASK_ID'] = 'screen'
    owner, record = identity('screen')
    out = scratch / 'screen-output'
    call(['run', '--worktree', str(work), '--output', str(out), '--', 'sh', '-c', 'echo must-not-execute'], 69)
    result = json.loads((out / 'result.json').read_text())
    assert result['kind'] == 'unavailable' and result['cleanup'] == 'deleted'
    assert result['remote_exit'] is None and result['lease']['owner'] == owner
    with tarfile.open(out / 'upload/source.tar.gz') as archive:
        names = archive.getnames()
        assert 'visible.txt' in names and '.env' not in names and not any('.git' in n.split('/') for n in names), names
    logs.append(dict(scenario='screened source and missing credentials', result=result, archive_members=names))

    out = scratch / 'unsafe-output'
    call(['run', '--worktree', str(work), '--output', str(out), '--input', '.env', '--', 'true'], 2)
    result = json.loads((out / 'result.json').read_text())
    assert result['kind'] == 'invalid' and result['remote_exit'] is None
    logs.append(dict(scenario='explicit excluded input refused', result=result))

    missing = scratch / 'removed-worker-source'
    missing.mkdir()
    owner, record = identity('removed-source', root=missing)
    record.write_text(json.dumps(dict(owner=owner, cleanup='deleted')))
    missing.rmdir()
    for _ in range(2):
        call(['cleanup-task', '--task', 'removed-source', '--generation', 'g1'], 0)
    closed = json.loads(record.read_text())
    assert closed['closing'] == owner and closed['cleanup'] == 'deleted'
    logs.append(dict(scenario='cleanup after removed source is idempotent', persisted=closed))

    owner, record = identity('generation')
    record.write_text(json.dumps(dict(owner=owner, cleanup='retained', lease_state='idle')))
    before = record.read_bytes()
    call(['cleanup-task', '--task', 'generation', '--generation', 'wrong-generation'], 70)
    assert record.read_bytes() == before
    logs.append(dict(scenario='wrong generation cannot clean lease', persisted=json.loads(before)))
    record.unlink()

    owner, record = identity('active')
    record.write_text(json.dumps(dict(owner=owner, cleanup='retained', lease_state='busy')))
    before = record.read_bytes()
    with (record.parent.parent / (record.stem + '.lock')).open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        call(['cleanup-task', '--task', 'active', '--generation', 'g1'], 70)
    assert record.read_bytes() == before
    logs.append(dict(scenario='active command cannot be cleaned concurrently', persisted=json.loads(before)))
    record.unlink()

    owner, record = identity('foreign')
    owner['home'] = str(scratch / 'other-home')
    record.write_text(json.dumps(dict(owner=owner, cleanup='retained', lease_state='idle')))
    before = record.read_bytes()
    call(['reap'], 70)
    assert record.read_bytes() == before
    logs.append(dict(scenario='reap refuses another home', persisted=json.loads(before)))
    record.unlink()
    call(['reap'], 0)
    logs.append(dict(scenario='reap accepts confirmed deleted records', result='all deleted records preserved'))
    marker = scratch / 'local-command-count'
    wrapper_env = dict(env, FM_BUILD_LOCK_BYPASS='1')
    command = 'echo executed >> ' + str(marker)
    for remote_only, expected in [(False, 0), (True, 69)]:
        wrapper_env['FM_BOAT_TEST_LOCAL_FALLBACK'] = '0' if remote_only else '1'
        wrapper_env['FM_BOAT_TEST_UNAVAILABLE_WAIT_SECS'] = '0'
        proc = subprocess.run(['bash', str(repo / 'bin/fm-boat-test-wrapper.sh'), command], cwd=work, env=wrapper_env, text=True, capture_output=True, timeout=20)
        logs.append(dict(scenario='wrapper remote-only refuses unavailable' if remote_only else 'wrapper permitted local fallback executes once', exit=proc.returncode, stdout=proc.stdout, stderr=proc.stderr, command=command, build_lock_bypass='1 for trivial marker command only'))
        assert proc.returncode == expected, logs[-1]
        assert marker.read_text() == 'executed\n', marker.read_text()
    assert len(list((scratch / '.fm-test-scratch').glob('fm-boat-test.*/boat-*/result.json'))) == 2
finally:
    (evidence / 'local-product-transcript.json').write_text(json.dumps(logs, indent=2) + '\n')
    shutil.rmtree(scratch)
print('Local product verification completed; transcript retained.')
