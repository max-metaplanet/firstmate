#!/usr/bin/env python3
"""Deferred launch records for fm-worker-park.sh's existing admission tick.

Usage: fm-worker-admit.py record ID PROJECT MODE YOLO TICKET COMMIT_TYPE
       BRANCH_PREFIX BASE_BRANCH HARNESS MODEL EFFORT BACKEND UPSTREAM_CONSENT
       TICKET_SCOPE IGNORE_SEAT_HOLD HERDR_RESUME_LOCK_WAIT
       fm-worker-admit.py tick
       fm-worker-admit.py verify ID RECORD_SHA256

Only a fresh ship's capacity deferral records authorization. The v1 record at
state/<id>.deferred-spawn.json binds every resolved launch axis to the filled
brief's SHA256; empty optional axes explicitly retain their default semantics.
Records are data, never shell. Changed briefs and incomplete records are
discarded and require a new explicit dispatch, as are records whose backlog row
is gone, no longer queued or no longer a ship, or whose task metadata exists.
Held, blocked and date-gated queued ships keep theirs. Any successful fresh
launch of the task consumes the record.

Exit 75 is the only capacity retry; under replay, fm-spawn also exits 75 for
the away spend cap and seat-quota holds. A fleet-wide deferral ends the tick's
replays and a project deferral skips that project's remaining records until
the next tick. Any other refusal backs off and retries;
after REFUSALS consecutive refusals the record is quarantined with its reason,
reported once as a blocked line in state/<id>.status, and never replayed. An
explicit dispatch clears it: launching consumes the record and a new capacity
deferral rewrites it without the refusal history a replay carries forward.

The parking tick resumes workers first, then calls tick here. A home-local
advisory lock serializes selection through launch. Spawn's existing task-set,
task, project and fleet locks remain authoritative against all other launches.
tasks-axi ready owns dependency/hold clearance; priority then queue age orders
new work. worker-admission.jsonl records the first deferral, each admission or
refusal, quarantine and discarded record; records still waiting append nothing.
The watcher already calls this tick independently of a firstmate turn, including
after teardown, park and verified exit. This helper never merges or polls.
"""
import fcntl
import hashlib
import importlib.util
import json
import math
import os
from pathlib import Path
import re
import subprocess
import sys
import time

sys.dont_write_bytecode = True
BIN = Path(__file__).absolute().parent
HOME = Path(os.environ['FM_HOME'])
STATE = Path(os.environ.get('FM_STATE_OVERRIDE') or HOME / 'state')
DATA = Path(os.environ.get('FM_DATA_OVERRIDE') or HOME / 'data')
CONFIG = Path(os.environ.get('FM_CONFIG_OVERRIDE') or HOME / 'config')
KEYS = ('project mode yolo ticket commit_type branch_prefix base_branch harness '
        'model effort backend upstream_consent ticket_scope ignore_seat_hold herdr_resume_lock_wait').split()
REFUSALS = 3
BACKOFF = 60


def require(ok, reason):
    if not ok:
        raise ValueError(reason)


def event(ident, result, reason):
    with (STATE / 'worker-admission.jsonl').open('a') as stream:
        stream.write(json.dumps(dict(at=time.time(), task=ident, result=result, reason=reason)) + '\n')


def brief_digest(ident):
    path = DATA / ident / 'brief.md'
    require(path.is_file() and not path.is_symlink(), 'filled brief missing or unsafe')
    return hashlib.sha256(path.read_bytes()).hexdigest()


def validate(record, ident):
    require(isinstance(record, dict), 'incomplete launch record')
    require(record.get('version') == 1 and record.get('task') == ident, 'invalid record identity/version')
    require(all(isinstance(record.get(k), str) for k in KEYS), 'incomplete launch record')
    require(record['mode'] in ('no-mistakes', 'direct-PR', 'local-only') and
            record['yolo'] in ('on', 'off'), 'missing delivery authority')
    require(record['harness'] and record['backend'], 'missing dispatch profile/backend')
    require(Path(record['project']).is_absolute() and Path(record['project']).is_dir(), 'project unavailable')
    require(bool(record['ticket']) == bool(record['commit_type']), 'incomplete ticket convention')
    require(record['ticket'] or record['branch_prefix'], 'missing branch convention')
    require(record['ticket_scope'] in ('partial', 'complete'), 'missing ticket scope')
    require(all(record[k] in ('0', '1') for k in ('ignore_seat_hold', 'herdr_resume_lock_wait')),
            'incomplete launch options')
    require(type(record.get('queued_at')) in (int, float) and math.isfinite(record['queued_at'])
            and record['queued_at'] > 0, 'missing queue age')
    require(record.get('brief_sha256') == brief_digest(ident), 'brief changed; dispatch explicitly again')


def record(args):
    ident, *values = args
    require(re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]*', ident), 'invalid task id')
    require(len(values) == len(KEYS), 'incomplete launch arguments')
    path = STATE / (ident + '.deferred-spawn.json')
    value = dict(zip(KEYS, values), version=1, task=ident, queued_at=time.time(),
                 brief_sha256=brief_digest(ident))
    validate(value, ident)
    existed = path.exists() and not path.is_symlink()
    if existed:
        old = json.loads(path.read_text())
        value['queued_at'] = old.get('queued_at', value['queued_at'])
        if os.environ.get('FM_WORKER_AUTO_ADMIT') == '1' and old.get('refusals'):
            value['refusals'] = old['refusals']
    write(path, value)
    if not existed:
        event(ident, 'deferred', 'capacity; recorded resolved launch')


def write(path, value):
    staged = path.with_suffix('.json.' + str(os.getpid()))
    try:
        with staged.open('x') as stream:
            os.chmod(staged, 0o600)
            json.dump(value, stream, indent=2)
            stream.write('\n')
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(staged, path)
    finally:
        staged.unlink(missing_ok=True)


def refuse(ident, path, expected, reason):
    try:
        payload = path.read_bytes()
    except FileNotFoundError:
        return
    if hashlib.sha256(payload).hexdigest() != expected:
        return
    value = json.loads(payload)
    value['refusals'] = value.get('refusals', 0) + 1
    if value['refusals'] < REFUSALS:
        value['retry_after'] = time.time() + BACKOFF * 2 ** (value['refusals'] - 1)
        write(path, value)
        event(ident, 'refused', reason)
        return
    value['quarantined'] = reason
    write(path, value)
    event(ident, 'quarantined', reason)
    summary = (reason.splitlines() or ['no output'])[-1]
    with (STATE / (ident + '.status')).open('a') as stream:
        stream.write('blocked [at=%d]: automatic admission quarantined after %d refusals (%s); '
                     'dispatch %s explicitly to clear it\n' % (time.time(), REFUSALS, summary, ident))


def argv(record):
    args = [record['task'], record['project']]
    for key in ('mode', 'yolo', 'base_branch', 'harness', 'model', 'effort', 'backend', 'upstream_consent'):
        if record[key]:
            args += ['--' + key.replace('_', '-'), record[key]]
    if record['ticket']:
        args += ['--ticket', record['ticket'], '--commit-type', record['commit_type'],
                 '--ticket-scope', record['ticket_scope']]
    else:
        args += ['--branch-prefix', record['branch_prefix']]
    for key in ('ignore_seat_hold', 'herdr_resume_lock_wait'):
        if record[key] == '1':
            args.append('--' + key.replace('_', '-'))
    return args


def intake_module():
    os.environ.update(FM_HOME=str(HOME), FM_STATE_OVERRIDE=str(STATE),
                      FM_DATA_OVERRIDE=str(DATA), FM_CONFIG_OVERRIDE=str(CONFIG))
    spec = importlib.util.spec_from_file_location('intake', BIN / 'fm-work-intake.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def queue_order(intake, row, value, entries):
    matching = [entry for entry in entries.values() if entry.get('local_id') == row['id']]
    if len(matching) == 1 and intake.review_valid(matching[0], row):
        entry = matching[0]
    else:
        created = row.get('created', '')
        age = intake.stamp(created + 'T00:00:00Z') if re.fullmatch(r'\d{4}-\d{2}-\d{2}', created) else value['queued_at']
        entry = dict(candidate=dict(dates={}, priority=dict(rank=3), source_ref=row['id']), eligible_since=age)
    return (*intake.order(entry, row)[:-1], value['queued_at'], row['id'])


def tick():
    if not any(STATE.glob('*.deferred-spawn.json')):
        return
    with (STATE / '.worker-admission.lock').open('a') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return
        intake = intake_module()
        receipts = intake.load(intake.RECEIPT, dict(entries={}))
        rows = {row['id']: row for row in intake.queue_rows()}
        ready = {row['id'] for row in intake.queue_rows(ready=True)}
        now = time.time()
        pending = []
        for path in sorted(STATE.glob('*.deferred-spawn.json')):
            ident = path.name[:-len('.deferred-spawn.json')]
            row = rows.get(ident)
            try:
                require(row is not None and row['state'] == 'queued' and row['kind'] == 'ship',
                        'backlog item is no longer a queued ship')
                require(not (STATE / (ident + '.meta')).exists(), 'task already recorded')
                if ident not in ready or row.get('held') != 'no':
                    continue
                require(path.is_file() and not path.is_symlink(), 'incomplete launch record')
                payload = path.read_bytes()
                value = json.loads(payload)
                validate(value, ident)
                if value.get('quarantined') or value.get('retry_after', 0) > now:
                    continue
                pending.append((row, value, path, hashlib.sha256(payload).hexdigest()))
            except (OSError, ValueError) as error:
                event(ident, 'skipped', str(error) + '; record discarded')
                path.unlink(missing_ok=True)
        pending.sort(key=lambda item: queue_order(intake, item[0], item[1], receipts['entries']))
        deferred_projects = set()
        for row, value, path, expected in pending:
            ident = row['id']
            if value['project'] in deferred_projects:
                continue
            tickets = set(re.findall(r'^Ticket: (ENG-\d+)\s*$', row.get('body', ''), re.MULTILINE))
            if value['ticket'].startswith('ENG-'):
                tickets.add(value['ticket'])
            title_ticket = re.match(r'(ENG-\d+)\b', row.get('title', ''))
            if title_ticket:
                tickets.add(title_ticket[1])
            # The real spawn rechecks backlog, source, authority and capacity
            # under its own locks, including against concurrent manual spawns.
            result = subprocess.run(['bash', str(BIN / 'fm-spawn.sh'), *argv(value)],
                                    env=dict(os.environ, FM_WORKER_AUTO_ADMIT='1',
                                             FM_WORKER_AUTO_ADMIT_TICKETS=','.join(sorted(tickets)),
                                             FM_WORKER_AUTO_ADMIT_DIGEST=expected),
                                    stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                    stderr=subprocess.STDOUT, text=True)
            reason = result.stdout.strip()
            if result.returncode == 0:
                event(ident, 'admitted', reason)
                path.unlink(missing_ok=True)
            elif result.returncode != 75:
                refuse(ident, path, expected, reason)
            elif re.search(r'^deferred: (project |.* in project )', reason, re.MULTILINE):
                deferred_projects.add(value['project'])
            elif re.search(r'^deferred:', reason, re.MULTILINE):
                break


if __name__ == '__main__':
    try:
        if sys.argv[1] == 'record':
            record(sys.argv[2:])
        elif sys.argv[1:] == ['tick']:
            tick()
        elif len(sys.argv) == 4 and sys.argv[1] == 'verify':
            ident, expected = sys.argv[2:]
            path = STATE / (ident + '.deferred-spawn.json')
            require(not path.is_symlink() and hashlib.sha256(path.read_bytes()).hexdigest() == expected,
                    'launch record changed during admission')
            validate(json.loads(path.read_text()), ident)
        else:
            raise ValueError('expected record, tick or verify')
    except Exception as error:
        print('worker-admission: ' + str(error), file=sys.stderr)
        sys.exit(1)
