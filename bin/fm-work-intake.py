#!/usr/bin/env python3
"""Receipt and source evidence owner for fm-work-intake.sh; see its public help."""
import argparse
from contextlib import contextmanager
from datetime import datetime, timezone
import fcntl
import hashlib
import json
import math
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import time
import tomllib

BIN = Path(__file__).resolve().parent
HOME = Path(os.environ['FM_HOME']).resolve()
DATA = Path(os.environ['FM_DATA_OVERRIDE']).resolve()
STATE = Path(os.environ['FM_STATE_OVERRIDE']).resolve()
CONFIG = Path(os.environ['FM_CONFIG_OVERRIDE']).resolve()
RECEIPT = STATE / 'work-intake.json'
DECODER = json.JSONDecoder()


class IntakeError(Exception):
    pass


def require(ok, reason):
    if not ok:
        raise IntakeError(reason)


def load(path, default=None):
    return json.loads(path.read_text()) if path.exists() else default


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(',', ':')).encode()).hexdigest()


def stamp(value):
    require(isinstance(value, str), 'missing observation time')
    parsed = datetime.fromisoformat(value.replace('Z', '+00:00'))
    require(parsed.tzinfo is not None, 'observation time needs timezone')
    return parsed.timestamp()


def atomic(path, value):
    tmp = path.with_name(path.name + '.' + str(os.getpid()))
    try:
        with tmp.open('w') as stream:
            json.dump(value, stream, indent=2, sort_keys=True)
            stream.write('\n')
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(tmp, path)
    finally:
        tmp.unlink(missing_ok=True)


@contextmanager
def locked():
    STATE.mkdir(parents=True, exist_ok=True)
    with (STATE / '.work-intake.lock').open('a') as stream:
        limit = time.monotonic() + 60
        while True:
            try:
                fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                require(time.monotonic() < limit, 'receipt lock busy; retry next supervision pass')
                time.sleep(.1)
        yield


def run(command, *, env=None, timeout=15):
    process = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, text=True, env=env, start_new_session=True)
    try:
        out, err = process.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGTERM)
        try:
            process.communicate(timeout=1)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.communicate()
        raise IntakeError('bounded command exceeded its deadline') from None
    require(process.returncode == 0, 'command failed: ' + Path(command[0]).name)
    return out


def hook_path(override=None):
    value = override or (CONFIG / 'work-intake-hook').read_text().strip()
    path = Path(value)
    require(path.is_absolute() and path.is_file() and os.access(path, os.X_OK),
            'work-intake-hook must name one absolute executable')
    return str(path)


def source(hook, reference=None):
    args = [hook, '--json']
    if reference is not None:
        args += ['--refresh', reference]
    value = json.loads(run(args, timeout=55))
    require(value.get('schema') == 'clickup-axi.queue' and type(value.get('version')) is int
            and value['version'] == 1, 'unsupported queue snapshot schema/version')
    require(value.get('mode') == ('refresh' if reference else 'scan'), 'wrong snapshot mode')
    require(isinstance(value.get('source_namespace'), str) and value['source_namespace'], 'missing source namespace')
    age = time.time() - stamp(value.get('observed_at'))
    require(-30 <= age <= 300, 'stale or future source observation')
    coverage = value.get('coverage', {})
    require(isinstance(coverage, dict) and isinstance(value.get('report'), dict), 'invalid coverage/report envelope')
    rows = value.get('candidates')
    require(isinstance(rows, list) and coverage.get('task_count') == len(rows), 'invalid candidate count')
    if reference:
        require(len(rows) == 1 and rows[0].get('source_ref') == reference, 'refresh identity mismatch')
        require(all(coverage.get(k) is False for k in ('complete', 'all_pages_read', 'absence_means_withdrawal')),
                'refresh cannot establish scan completeness')
    else:
        require(all(coverage.get(k) is True for k in ('complete', 'all_pages_read', 'absence_means_withdrawal')),
                'partial scan ignored')
    refs = set()
    for row in rows:
        require(isinstance(row, dict), 'invalid candidate object')
        ref = row.get('source_ref')
        require(isinstance(ref, str) and ref and ref not in refs, 'duplicate or missing source reference')
        refs.add(ref)
        require(isinstance(row.get('source_revision'), str) and row['source_revision'], 'missing source revision')
        require(isinstance(row.get('title'), str) and row['title'].strip(), 'missing candidate title')
        require(isinstance(row.get('ticket'), str) and isinstance(row.get('url'), str), 'missing explicit ticket link')
        eligible = row.get('eligibility', {})
        require(isinstance(eligible, dict), 'invalid eligibility object')
        require(type(eligible.get('eligible')) is bool and isinstance(eligible.get('exclusion_reasons'), list),
                'invalid eligibility evidence')
        require(not eligible['eligible'] or not eligible['exclusion_reasons'], 'contradictory eligibility')
        require(isinstance(row.get('scope'), dict) and isinstance(row.get('dates'), dict), 'missing scope/date evidence')
        require(isinstance(row.get('priority'), dict), 'missing priority evidence')
        if eligible['eligible']:
            require(type(row['priority'].get('rank')) is int and 1 <= row['priority']['rank'] <= 4,
                    'invalid priority rank')
        if reference:
            require(row['scope'].get('comments_complete') is True, 'incomplete scope refresh')
    return value


def fields(line):
    values = []
    while line:
        line = line.lstrip()
        if line.startswith('"'):
            value, length = DECODER.raw_decode(line)
            line = line[length:]
        else:
            value, sep, rest = line.partition(',')
            line = sep + rest
        values.append(value)
        if line:
            require(line.startswith(','), 'invalid tasks-axi field separator')
            line = line[1:]
    return values


def queue_rows(home=HOME, archive=False):
    env = dict(os.environ, FM_HOME=str(home), FM_DATA_OVERRIDE=str(home / 'data'),
               FM_CONFIG_OVERRIDE=str(home / 'config'), FM_STATE_OVERRIDE=str(home / 'state'))
    if home == HOME:
        env.update(FM_DATA_OVERRIDE=str(DATA), FM_CONFIG_OVERRIDE=str(CONFIG), FM_STATE_OVERRIDE=str(STATE))
    out = run([str(BIN / 'fm-tasks-axi.sh'), 'list-archive' if archive else 'list',
               '--limit', '1000000', '--fields', 'body,links,held,hold_kind,hold_reason,blocked_by,priority,created'], env=env)
    rows, columns, expected = [], None, None
    for line in out.splitlines():
        header = re.fullmatch(r'tasks\[(\d+)\]\{([^}]+)\}:', line)
        if header:
            expected, columns = int(header[1]), header[2].split(',')
        elif columns and len(rows) < expected and line.startswith('  '):
            values = fields(line.strip())
            require(len(values) == len(columns), 'invalid tasks-axi row')
            rows.append(dict(zip(columns, values), owner_home=str(home)))
    require(expected == len(rows) or 'count: 0' in out, 'incomplete tasks-axi index')
    return rows


def index():
    rows = queue_rows() + queue_rows(archive=True)
    unavailable = False
    registry = DATA / 'secondmates.md'
    if registry.exists():
        # Keep registry grammar with its existing owner, including remote forms.
        script = '''. "$1/fm-secondmate-registry-lib.sh"
while IFS= read -r line; do
  case "$line" in
    '- '*) secondmate_registry_parse_line "$line" || exit 2
      printf '%s\\t%s\\n' "$SECONDMATE_REGISTRY_REMOTE" "$SECONDMATE_REGISTRY_HOME" ;;
  esac
done < "$2"
'''
        for line in run(['bash', '-c', script, '_', str(BIN), str(registry)]).splitlines():
            remote, path = line.split('\t', 1)
            if remote == '1':
                unavailable = True
            else:
                other = Path(path).resolve()
                require(other != HOME, 'secondmate registry points to intake home')
                rows += queue_rows(other) + queue_rows(other, archive=True)
    # Only this home's recorded live tasks, never another home's endpoints.
    for path in STATE.glob('*.meta'):
        meta = dict(line.split('=', 1) for line in path.read_text().splitlines() if '=' in line)
        if meta.get('ticket') and meta['ticket'] != 'no-ticket':
            ident = path.stem
            if not any(r['id'] == ident and r['owner_home'] == str(HOME) for r in rows):
                rows.append(dict(id=ident, state='in_flight', body='Ticket: ' + meta['ticket'], owner_home=str(HOME)))
    return rows, unavailable


def matches(row, candidate):
    body = row.get('body', '')
    identities = {'Source reference: ' + candidate['source_ref'], 'Ticket: ' + candidate['ticket'],
                  'Ticket URL: ' + candidate['url']}
    return any(line.strip() in identities for line in body.splitlines())


def mutate(*args):
    return run([str(BIN / 'fm-tasks-axi.sh'), *args])


def source_hold(entry):
    return 'work intake ' + entry['local_id'] + ' requires source and scope clearance'


def hold(entry, row, blocked):
    if entry['owner_home'] != str(HOME) or row.get('state') != 'queued':
        return
    reason = source_hold(entry)
    ours = row.get('hold_kind') == 'external' and row.get('hold_reason') == reason
    if blocked and row.get('held') != 'yes':
        mutate('hold', row['id'], '--kind', 'external', '--reason', reason)
    elif not blocked and ours:
        mutate('unhold', row['id'])


def current(state, ident):
    found = [entry for entry in state['entries'].values() if entry['local_id'] == ident]
    require(len(found) == 1, 'import identity missing or ambiguous')
    return found[0]


def local_row(entry):
    require(entry['owner_home'] == str(HOME), 'work belongs to another home; use supervised handoff')
    rows = [r for r in queue_rows() if r['id'] == entry['local_id']]
    require(len(rows) == 1, 'imported row missing; retain receipt and reconcile rather than reimport')
    return rows[0]


def review_valid(entry, row):
    review = entry.get('review')
    if not review or review['revision'] != entry.get('full_revision'):
        return False
    decision = review['decision']
    return (decision.get('authorized') is True and decision.get('identity_checked') is True
            and not any(decision.get(k) for k in ('deferred', 'blocked', 'unresolved_scope'))
            and row.get('repo') == decision['project'] and row.get('kind') == decision['kind']
            and review['local_scope'] == digest({k: row.get(k) for k in ('body', 'blocked_by')}))


def eligible(entry):
    return entry.get('present') is True and entry['candidate']['eligibility']['eligible'] is True


def refresh(state, entry, hook):
    value = source(hook, entry['source_ref'])
    require(value['source_namespace'] == state['source_namespace'], 'source namespace changed; reconcile configuration')
    row = value['candidates'][0]
    if row['eligibility']['eligible'] and not eligible(entry):
        entry['eligible_since'] = time.time()
    if entry.get('full_revision') != row['source_revision']:
        entry.pop('review', None)
    entry.update(candidate=row, full_revision=row['source_revision'], present=True)
    return row


def order(entry, row=None):
    decision = entry.get('review', {}).get('decision', {})
    candidate = entry['candidate']
    dates = candidate['dates']
    priority = candidate['priority'].get('rank') or 3
    if row and str(row.get('priority', '-')).isdigit():
        priority = int(row['priority']) + 1
    return (decision.get('captain_order', 1e20),
            0 if decision.get('incident') or decision.get('security_authorized') else 1,
            stamp(decision['latest_start']) if decision.get('latest_start') else 1e20,
            priority, stamp(decision['confirmed_due']) if decision.get('confirmed_due') else 1e20,
            -decision.get('dependency_benefit', 0), entry.get('eligible_since', 1e20), candidate['source_ref'])


def report(snapshot, state, rows, unavailable=False):
    imports, exclusions, proposals = [], [], []
    for candidate in snapshot['candidates']:
        entry = state['entries'].get(candidate['source_ref'])
        found = [r for r in rows if matches(r, candidate)]
        reasons = list(candidate['eligibility']['exclusion_reasons'])
        if entry:
            reasons.append('already_recorded:' + entry['phase'])
        elif found:
            reasons.append('existing_explicit_identity:' + ','.join(r['id'] for r in found))
        elif unavailable:
            reasons.append('remote_ownership_reconciliation_required')
        if reasons:
            exclusions.append(dict(ticket=candidate['ticket'], source_ref=candidate['source_ref'], reasons=reasons))
        else:
            imports.append(dict(ticket=candidate['ticket'], source_ref=candidate['source_ref'],
                                title=candidate['title'], reason='source eligible; scope review required'))
        if candidate['eligibility'].get('proposal') == 'backlog_promotion':
            proposals.append(dict(ticket=candidate['ticket'], source_ref=candidate['source_ref'],
                                  title=candidate['title'], scope=candidate['scope'], dates=candidate['dates'],
                                  priority=candidate['priority'], blockers=candidate['eligibility']['exclusion_reasons'],
                                  reason='proposal only; scope, acceptance criteria, project and deferrals require review'))
    by_ref = {c['source_ref']: c for c in snapshot['candidates']}
    imports.sort(key=lambda item: order(dict(candidate=by_ref[item['source_ref']])))
    proposals.sort(key=lambda item: order(dict(candidate=by_ref[item['source_ref']])))
    return dict(would_import=imports, excluded=exclusions, backlog_proposals=proposals[:3],
                additional_backlog_proposals=max(0, len(proposals) - 3),
                source_report=snapshot['report'], ownership_coverage_gap=snapshot['report'].get('ownership_coverage_gap'),
                eligible_count=sum(c['eligibility']['eligible'] for c in snapshot['candidates']))


def poll(state, hook):
    now = time.time()
    if now < state.get('next_poll', 0) and not any(e['phase'] == 'planned' for e in state['entries'].values()):
        return dict(result='cached', next_poll=state['next_poll'])
    try:
        snapshot = source(hook)
        require(not state.get('source_namespace') or state['source_namespace'] == snapshot['source_namespace'],
                'source namespace changed; reconcile configuration')
        rows, unavailable = index()
    except (IntakeError, OSError, ValueError) as error:
        state['failures'] = min(state.get('failures', 0) + 1, 5)
        state['next_poll'] = now + 300 * 2 ** (state['failures'] - 1)
        state['source_error'] = str(error)
        atomic(RECEIPT, state)
        raise
    previous = state.get('snapshot', {}).get('candidates', [])
    changed = [(c['source_ref'], c['source_revision']) for c in previous] != [
        (c['source_ref'], c['source_revision']) for c in snapshot['candidates']]
    changed = changed or bool(state.get('source_error')) or 'snapshot' not in state
    state.update(source_namespace=snapshot['source_namespace'], next_poll=now + 300, failures=0)
    state.pop('source_error', None)
    result = report(snapshot, state, rows, unavailable)
    seen, imported = set(), []
    for candidate in snapshot['candidates']:
        ref = candidate['source_ref']
        seen.add(ref)
        entry = state['entries'].get(ref)
        if entry is None:
            found = [r for r in rows if matches(r, candidate)]
            if not candidate['eligibility']['eligible'] and not found:
                continue
            if unavailable and not found:
                continue
            ident = found[0]['id'] if len(found) == 1 else 'intake-' + digest([state['source_namespace'], ref])[:20]
            entry = dict(source_ref=ref, local_id=ident, owner_home=found[0]['owner_home'] if len(found) == 1 else str(HOME),
                         phase='imported' if len(found) == 1 else 'conflict' if found else 'planned',
                         eligible_since=now, candidate=candidate, present=True)
            if len(found) > 1:
                entry['conflicts'] = [{'id': r['id'], 'owner_home': r['owner_home']} for r in found]
            state['entries'][ref] = entry
            atomic(RECEIPT, state)
        if entry.get('scan_revision') != candidate['source_revision']:
            entry.pop('review', None)
        if candidate['eligibility']['eligible'] and not eligible(entry):
            entry['eligible_since'] = now
        entry.update(scan_revision=candidate['source_revision'], present=True)
        # Keep full evidence separate from list evidence; their revisions differ.
        entry['candidate'] = candidate
        if entry['phase'] == 'planned':
            exact = [r for r in rows if r['id'] == entry['local_id'] and r['owner_home'] == str(HOME)]
            if exact:
                if 'Source reference: ' + ref not in exact[0].get('body', '').splitlines():
                    entry['phase'] = 'conflict'
                    atomic(RECEIPT, state)
                    continue
            else:
                body = '\n'.join(['Source reference: ' + ref, 'Ticket: ' + candidate['ticket'],
                                  'Ticket URL: ' + candidate['url'], 'Source evidence is retained in the intake receipt.'])
                mutate('add', entry['local_id'], candidate['title'], '--kind', 'ship', '--body', body, '--queue')
                # A test source may kill its parent after observing add; the planned receipt survives.
                rows = queue_rows() + [r for r in rows if r['owner_home'] != str(HOME)]
            entry['phase'] = 'imported'
            imported.append(entry['local_id'])
            atomic(RECEIPT, state)
        matching = [r for r in rows if r['id'] == entry['local_id'] and r['owner_home'] == entry['owner_home']]
        if entry['phase'] == 'imported' and matching:
            hold(entry, matching[0], not eligible(entry) or not review_valid(entry, matching[0]))
    for ref, entry in state['entries'].items():
        if ref not in seen:
            entry['present'] = False
            entry.pop('review', None)
            matching = [r for r in rows if r['id'] == entry['local_id'] and r['owner_home'] == entry['owner_home']]
            if matching:
                hold(entry, matching[0], True)
    state['snapshot'] = snapshot
    atomic(RECEIPT, state)
    return dict(result='polled', changed=changed, imported=imported, **result)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['preview', 'poll', 'refresh', 'review', 'check', 'status'])
    parser.add_argument('id', nargs='?')
    parser.add_argument('--hook')
    parser.add_argument('--decision-file', type=Path)
    parser.add_argument('--json', action='store_true')
    args = parser.parse_args()
    enabled = (CONFIG / 'work-intake-enabled').exists() and (CONFIG / 'work-intake-enabled').read_text().strip() == '1'
    state = load(RECEIPT, dict(version=1, entries={}))
    require(state.get('version') == 1 and isinstance(state.get('entries'), dict), 'invalid receipt; preserve and reconcile')
    if args.command == 'status':
        rows = queue_rows()
        ranked = []
        for entry in state['entries'].values():
            matching = [r for r in rows if r['id'] == entry['local_id'] and entry['owner_home'] == str(HOME)]
            row = matching[0] if len(matching) == 1 else None
            reasons = []
            if not enabled or state.get('source_error'):
                reasons.append('source_disabled_or_unavailable')
            if entry['phase'] != 'imported' or row is None or row.get('state') != 'queued':
                reasons.append('existing_execution_terminal_or_other_owner')
            if not eligible(entry):
                reasons.append('source_ineligible')
            if row is not None:
                if not review_valid(entry, row):
                    reasons.append('scope_review_required')
                if row.get('held') == 'yes' or row.get('blocked_by') not in ('none', '-'):
                    reasons.append('local_hold_or_dependency')
            ranked.append(dict(local_id=entry['local_id'], ticket=entry['candidate']['ticket'],
                               runnable=not reasons, reasons=reasons, order=order(entry, row),
                               ordering_evidence=entry.get('review', {}).get('decision', {}),
                               priority=entry['candidate']['priority']))
        ranked.sort(key=lambda item: (not item['runnable'], item['order']))
        return dict(result='status', ranked=ranked)
    if args.command == 'check' and not any(e['local_id'] == args.id for e in state['entries'].values()):
        return dict(result='independent')
    if args.command == 'poll' and not enabled:
        return dict(result='disabled')
    require(args.hook is None or args.command == 'preview', '--hook is preview-only')
    hook = hook_path(args.hook)
    if args.command == 'preview':
        snapshot = source(hook)
        rows, unavailable = index()
        return dict(result='preview', **report(snapshot, state, rows, unavailable))
    require(enabled, 'source intake disabled; imported dispatch remains suspended')
    require(not (HOME / '.fm-secondmate-home').exists(), 'source intake belongs to the main home only')
    require(not os.environ.get('FM_TASK_ID') or os.environ.get('FM_TEST_SEAM') == '1', 'workers cannot mutate source intake')
    with locked():
        state = load(RECEIPT, dict(version=1, entries={}))
        if args.command == 'poll':
            return poll(state, hook)
        require(args.id, 'local id required')
        entry = current(state, args.id)
        require(entry['phase'] == 'imported', 'identity conflict requires reconciliation')
        row = local_row(entry)
        require(row['state'] == 'queued', 'existing execution or terminal receipt cannot start another worker')
        require(not state.get('source_error') or time.time() >= state.get('next_poll', 0),
                'source backoff active; keep imported work queued')
        try:
            candidate = refresh(state, entry, hook)
        except (IntakeError, OSError, ValueError) as error:
            state['source_error'] = str(error)
            state['failures'] = min(state.get('failures', 0) + 1, 5)
            state['next_poll'] = time.time() + 300 * 2 ** (state['failures'] - 1)
            hold(entry, row, True)
            atomic(RECEIPT, state)
            raise
        if args.command == 'review':
            require(args.decision_file is not None, 'decision file required')
            decision = load(args.decision_file)
            require(isinstance(decision, dict) and decision.get('project') and decision.get('kind') in ('ship', 'scout')
                    and decision.get('reason') and decision.get('identity_checked') is True, 'incomplete scope decision')
            if decision.get('source_revision') != candidate['source_revision']:
                hold(entry, row, True)
                atomic(RECEIPT, state)
                raise IntakeError('review revision changed; read refreshed evidence and review again')
            for key in ('latest_start', 'confirmed_due'):
                if decision.get(key):
                    stamp(decision[key])
                    require(decision.get('deadline_timezone') and decision.get('deadline_source')
                            and type(decision.get('review_buffer_ms')) is int
                            and decision['review_buffer_ms'] >= 0, 'accepted dates require timezone and review buffer')
            for key in ('captain_order', 'dependency_benefit'):
                if key in decision:
                    require(type(decision[key]) in (int, float) and math.isfinite(decision[key]),
                            'invalid ordering evidence')
            mutate('update', args.id, '--repo', decision['project'], '--kind', decision['kind'])
            row = local_row(entry)
            entry['review'] = dict(revision=candidate['source_revision'], decision=decision,
                                   local_scope=digest({k: row.get(k) for k in ('body', 'blocked_by')}))
        cleared = eligible(entry) and review_valid(entry, row)
        hold(entry, row, not cleared)
        atomic(RECEIPT, state)
        if args.command == 'check':
            require(cleared and row.get('blocked_by') in ('none', '-')
                    and (row.get('held') != 'yes' or (row.get('hold_kind') == 'external'
                         and row.get('hold_reason') == source_hold(entry))),
                    'source, scope, dependency or competing hold prevents dispatch')
        return dict(result='cleared' if cleared else 'held', candidate=candidate,
                    local_id=entry['local_id'], order=order(entry, row))


if __name__ == '__main__':
    try:
        result = main()
        if '--json' in sys.argv:
            print(json.dumps(result, indent=2))
        else:
            print(json.dumps(result, indent=2, ensure_ascii=True))
    except (IntakeError, OSError, ValueError, KeyError, TypeError) as error:
        print('work-intake: ' + str(error), file=sys.stderr)
        sys.exit(1)
