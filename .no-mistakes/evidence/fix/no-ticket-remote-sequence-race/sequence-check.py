import concurrent.futures
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path.cwd()
EVIDENCE = Path('~/.no-mistakes/evidence/01M6J3AKF8JTMV9CC71A04XSD8')
records = []

def run(code, env):
    p = subprocess.run(['bash', '-c', 'set -eu\n. "$LIB"\n' + code], env=env, text=True, capture_output=True, timeout=45)
    if p.returncode:
        raise RuntimeError(f'command failed ({p.returncode}): {p.stderr}')
    return p.stdout.strip()

def batch(code, env, n):
    with concurrent.futures.ThreadPoolExecutor(max_workers=n) as pool:
        return list(pool.map(lambda _: run(code, env), range(n)))

def record(name, **data):
    row = dict(name=name, **data)
    records.append(row)
    print(json.dumps(row), flush=True)

with tempfile.TemporaryDirectory(prefix='.sequence-live-', dir=ROOT) as temp:
    fixture = Path(temp)
    env = os.environ.copy()
    env.update(LIB=str(ROOT/'bin/fm-remote-job-lib.sh'), ACCOUNT=str(fixture/'account'),
               FM_REMOTE_JOB_STATE_ROOT=str(fixture/'queue'), FM_REMOTE_JOB_PLATFORM_OVERRIDE='Linux',
               ROOT=str(ROOT), FM_REMOTE_JOB_QUEUE_TIMEOUT='120')
    Path(env['ACCOUNT']).mkdir()
    run('fm_remote_job_prepare_state "$ACCOUNT"', env)
    allocator = '''FM_REMOTE_JOB_STATE=$FM_REMOTE_JOB_STATE_ROOT
FM_REMOTE_JOB_SEQ_CLAIMS=$FM_REMOTE_JOB_STATE/.seq-claims
fm_remote_job_next_seq'''
    version = subprocess.run(['mkdir', '--version'], text=True, capture_output=True, check=True).stdout.strip()
    record('host mkdir', version=version)
    for burst in range(5):
        values = sorted(map(int, batch(allocator, env, 40)))
        expected = list(range(40*burst+1, 40*(burst+1)+1))
        assert values == expected, (values, expected)
        claims = fixture/'queue/.seq-claims'
        assert all((claims/str(v)).is_dir() for v in values)
        assert all((claims/str(v)).stat().st_mode & 0o777 == 0o700 for v in values)
        record('live simultaneous allocation', burst=burst+1, sequences=values, durable_private_claims=True)
    # State files are owned protocol output. The independent oracle is non-reuse
    # of all 200 earlier claims even when the optional hint is absent or invalid.
    for label, content in [('missing hint', None), ('invalid hint', 'invalid\n')]:
        counter=fixture/'queue/seq'
        if content is None:
            counter.unlink()
        else:
            counter.write_text(content)
        value=int(run(allocator, env))
        assert value == (201 if content is None else 202), value
        record('live occupied-claim recovery', condition=label, sequence=value)
    # Real staging publishes complete queued records for real consumer commands.
    stage='fm_remote_job_stage "$ACCOUNT" "$ROOT" "$ACCOUNT" fm-path-lib.sh < /dev/null'
    ids=batch(stage, env, 20)
    assert len(set(ids))==20
    jobs=fixture/'queue/jobs'
    mapping={job: int((jobs/job/'seq').read_text()) for job in ids}
    assert sorted(mapping.values())==list(range(203,223)), mapping
    assert all((jobs/job/'state').read_text().strip()=='queued' for job in ids)
    assert all((fixture/'queue/.seq-claims'/str(seq)).is_dir() for seq in mapping.values())
    assert not list(jobs.glob('.stage.*'))
    record('live concurrent job publication', job_sequences=mapping, all_queued=True, abandoned_stages=0)
    serial=[]
    for _ in range(3):
        job=run(stage,env)
        serial.append(int((jobs/job/'seq').read_text()))
    assert serial==[223,224,225],serial
    record('live completed staging order', sequences=serial)
    # Fault injection models mkdir's observed EEXIST false-success boundary.
    seam=fixture/'seam'
    seam.mkdir()
    mkdir=seam/'mkdir'
    mkdir.write_text('#!/usr/bin/env bash\nfor arg in "$@"; do\n  [ "$arg" != "$CONTENDED" ] || exit 0\ndone\nexec "$REAL_MKDIR" "$@"\n')
    mkdir.chmod(0o700)
    real_mkdir=shutil.which('mkdir')
    old=fixture/'base-lib.sh'
    old.write_bytes(subprocess.run(['git','show','2c13867fcc0634599bf6bec0eb1043bfff21d711:bin/fm-remote-job-lib.sh'],capture_output=True,check=True).stdout)
    for label, library in [('base',old),('target',ROOT/'bin/fm-remote-job-lib.sh')]:
        queue=fixture/label
        injected=env | dict(LIB=str(library), FM_REMOTE_JOB_STATE_ROOT=str(queue))
        run('fm_remote_job_prepare_state "$ACCOUNT"',injected)
        (queue/'.seq-claims/1').mkdir()
        injected.update(PATH=str(seam)+os.pathsep+env['PATH'], REAL_MKDIR=real_mkdir, CONTENDED=str(queue/'.seq-claims/1'))
        value=int(run(allocator,injected))
        assert value==(1 if label=='base' else 2),value
        record('fault-injected false-success regression', revision=label, sequence=value, reused_existing_claim=value==1, live=False)
    # Run the original code with actual uutils, without the injection boundary.
    original=env | dict(LIB=str(old),FM_REMOTE_JOB_STATE_ROOT=str(fixture/'original'))
    run('fm_remote_job_prepare_state "$ACCOUNT"',original)
    reproduced=False
    for burst in range(8):
        (fixture/'original/seq').unlink(missing_ok=True)
        values=list(map(int,batch(allocator,original,40)))
        if len(set(values)) != len(values):
            record('live original race reproduction', burst=burst+1, sequences=values, unique=len(set(values)), allocated=len(values))
            reproduced=True
            break
    if not reproduced:
        record('live original race reproduction', reproduced=False, note='Race did not occur in eight bursts; deterministic injected reproduction above fails before fix.')
record('cleanup', disposable_workspace_removed=not fixture.exists())
(EVIDENCE/'sequence-results.json').write_text(json.dumps(records,indent=2)+'\n')
