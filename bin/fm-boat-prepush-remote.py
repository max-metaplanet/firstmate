#!/usr/bin/env python3
"""Remote half of the pre-ready heavy-test check (bin/fm-boat-prepush.sh).

This file never runs on the operator's machine. bin/fm-boat-prepush.py ships it
to a disposable remote machine inside the one command string the Test wrapper
takes, writes it NEXT TO the uploaded source rather than inside it, and runs it
with the source tree as the working directory. Keeping it outside the source
tree is deliberate: a helper written into the tree becomes an unreferenced file
the project's own unused-file check reports, which is one of the Boat-only false
failures this check exists to remove.

It installs the project's frozen dependencies, asks the PULL REQUEST HEAD's own
repository planner which heavy lanes that change selects, and runs the selected
lanes ONE AT A TIME. Running them together is what the capacity measurement
proved exhausts even a 16 GB machine, so sequential execution is the contract
rather than a tuning choice.

Protocol with the local half, on stdout, one JSON document per line:

    FM_BOAT_PREPUSH_PLAN <json>     the resolved plan and lane selection
    FM_BOAT_PREPUSH_LANE <json>     one per lane, as soon as it finishes
    FM_BOAT_PREPUSH_SUMMARY <json>  once, last

Each lane document carries name, group, exit, wall_s, oom and skipped. `oom` is
true only on PROVEN memory exhaustion: a kernel cgroup kill counted from
memory.events, exit 137, or V8's own heap-exhaustion diagnostic. The local half
retries on a larger machine only for that proof, so a plain assertion failure
must never set it.

Lane output is streamed to this process's stdout as it happens, so the adapter's
captured command log holds the full failure text a reader needs.

Exit status is 0 whenever every selected lane was executed and reported, even
when lanes failed: the per-lane verdict is the result, and the local half owns
the overall pass/fail decision. A nonzero exit here means this runner itself
could not produce a verdict.
"""

from __future__ import annotations

import json
import os
import re
import shutil
import signal
import threading
from collections import deque
import shlex
import subprocess
import sys
import time
from pathlib import Path

# Environment variables that survive into a lane. Everything else is dropped so
# a lane sees the project's CI environment rather than this runner's setup.
# Inherited setup variables leaking into a lane is one of the Boat-only false
# failures this check removes: a test that fakes a service startup reads them
# and behaves as if the real service were already configured.
ENV_KEEP = (
    'PATH', 'HOME', 'LANG', 'LC_ALL', 'TERM', 'USER', 'LOGNAME', 'SHELL',
    'TMPDIR', 'PNPM_HOME', 'SHLVL', 'PWD',
)
ENV_KEEP_PREFIX = ('COREPACK_', 'NVM_', 'XDG_', 'npm_config_')

# The project's CI environment common to every heavy lane. These are the public
# dummy values its own workflows set, never a credential.
CI_ENV = {
    'CI': 'true',
    'SKIP_ENV_VALIDATION': '1',
    'NODE_ENV': 'test',
    'TZ': 'Asia/Tokyo',
    'RESEND_API_KEY': 're_test_000000000000000000000000',
    'SUPABASE_SECRET_KEY_CORE': 'test-supabase-secret-key',
    'NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY_CORE': 'test-supabase-anon-key',
    'NEXT_PUBLIC_SUPABASE_URL_CORE': 'http://localhost:54321',
    # The project's workflows read the real local Turbo cache. Disabling cache
    # writes is what left the lint warning ratchet with no per-workspace log to
    # count, and forcing every task globally is what broke a cache fixture, so
    # this check runs the lanes the way the workflows run them and relies on the
    # machine being fresh for its cache misses.
    'TURBO_CACHE': 'local:rw',
    'DIFF_BASE': 'refs/remotes/origin/main',
}

# The old-space ceiling the admin-center heap sweep measured as the lowest that
# still completes that build on the default machine, against a 2560 that failed
# with V8 heap exhaustion and an 8192 default the cgroup killed. It is applied
# only to the lane that runs Turbo `build`, because that is the one selected
# heavy lane an admin-center build can be reached through.
ADMIN_BUILD_HEAP_MB = 3072

# Turbo workspace concurrency for the shard that fans out across every
# remaining workspace. Uncapped, that shard peaked above 8 GiB and was killed on
# the default machine; capped it passed every sampled change at 2.6-3.2 GiB.
WIDE_SHARD_CONCURRENCY = 2
MEASURED_DATABASE_SUITES = ('db', 'actions', 'runtime')

V8_HEAP_EXHAUSTION = re.compile(
    r'Ineffective mark-compacts near heap limit|'
    r'JavaScript heap out of memory|'
    r'FATAL ERROR: .*Allocation failed')

# Git's own diagnostics for an object the repository does not have. The screened
# upload carries no real ancestry by default, so a fixture that reads a pinned
# historical commit fails for the transport rather than for the change. These
MISSING_HISTORY = re.compile(
    r'exists on disk, but not in|'
    r'unknown revision or path not in the working tree|'
    r'fatal: bad object|'
    r'fatal: not a valid object name|'
    r'fatal: invalid object name|'
    r'fatal: Invalid revision range')


class Unusable(Exception):
    """This runner cannot produce a verdict at all."""


def emit(kind: str, document: dict) -> None:
    sys.stdout.write('FM_BOAT_PREPUSH_%s %s\n' % (kind, json.dumps(document, sort_keys=True)))
    sys.stdout.flush()


def lane_env(overlay: dict) -> dict:
    env = {k: v for k, v in os.environ.items()
           if k in ENV_KEEP or k.startswith(ENV_KEEP_PREFIX)}
    env.update(CI_ENV)
    env.update({k: v for k, v in overlay.items() if v is not None})
    for key, value in overlay.items():
        if value is None:
            env.pop(key, None)
    return env


def cgroup_oom_kills() -> int:
    """Kernel-counted memory-cgroup kills, so an OOM needs no log guesswork.

    Returns -1 when the counter cannot be read, which makes the exit code and
    the V8 diagnostic the only OOM evidence rather than silently reading zero.
    """
    try:
        own = Path('/proc/self/cgroup').read_text(encoding='utf-8').strip().split(':')[-1]
    except OSError:
        return -1
    base = Path('/sys/fs/cgroup')
    for relative in (own.lstrip('/'), 'user.slice', ''):
        events = base / relative / 'memory.events'
        try:
            for line in events.read_text(encoding='utf-8').splitlines():
                field, _, value = line.partition(' ')
                if field == 'oom_kill':
                    return int(value)
        except (OSError, ValueError):
            continue
    return -1


def missing_evidence(text: str) -> str:
    for line in text.splitlines():
        if 'fatal:' in line and MISSING_HISTORY.search(line):
            return line.strip()
    return ''


def history_failures(name: str, output: str, report: Path | None) -> tuple:
    failures = []
    complete = False
    if name == 'repository-scripts' and report is not None:
        try:
            document = json.loads(report.read_text(encoding='utf-8'))
            complete = document.get('numRuntimeErrorTestSuites', 0) == 0
            for suite in document['testResults']:
                failed = [test for test in suite['assertionResults']
                          if test['status'] == 'failed']
                if suite.get('status') == 'failed' and not failed:
                    complete = False
                for test in failed:
                    evidence = [missing_evidence(message) for message in test['failureMessages']]
                    failures.append({
                        'name': test['fullName'],
                        'evidence': evidence[0] if evidence and all(evidence) else '',
                    })
            complete = complete and len(failures) == document['numFailedTests']
        except (OSError, ValueError, KeyError, TypeError):
            complete = False
    elif name == 'ci-scripts':
        records = []
        pattern = re.compile(r'^( *)not ok \d+ - ([^\n]+)\n(.*?)(?=^ *\.{3}$)',
                             re.MULTILINE | re.DOTALL)
        for match in pattern.finditer(output):
            indent, title, diagnostic = match.groups()
            depth = len(indent)
            children = []
            while records and records[-1][0] > depth:
                children.insert(0, records.pop())
            if re.search(r'failureType: [\'"]?subtestsFailed', diagnostic):
                count = re.search(r'(\d+) subtests? failed', diagnostic)
                valid = count is not None and int(count[1]) == len(children)
                records.append((depth, [test for _, tests in children for test in tests]
                                if valid else [{'name': title, 'evidence': ''}]))
            else:
                records.append((depth, [{'name': title,
                                        'evidence': missing_evidence(diagnostic)}]))
        failures = [test for _, tests in records for test in tests]
        counts = re.findall(r'^# fail (\d+)$', output, re.MULTILINE)
        complete = (bool(counts) and sum(map(int, counts)) == len(failures)
                    and not re.search(r'^✗ (?:COVERAGE:|[^\n]*?(?:ZERO tests|could not parse|ZERO \*\.test))',
                                      output, re.MULTILINE))
    excused = [test for test in failures if test['evidence']]
    return excused, bool(complete and failures and len(excused) == len(failures))


def run_lane(name: str, group: str, argv: list, overlay: dict, cwd: Path,
             timeout: float = 600) -> dict:
    """Run one lane to completion, streaming its output, and judge an OOM."""
    sys.stdout.write('\n===== lane %s =====\n' % name)
    sys.stdout.flush()
    before = cgroup_oom_kills()
    started = time.monotonic()
    # Both markers are judged line by line as the lane streams, rather than
    # from a retained tail: a suite of thousands of tests prints its first
    # missing-object diagnostic long before its summary.
    heap = False
    history = ''
    output = []
    tail = deque(maxlen=40)
    timed_out = threading.Event()
    report = next((Path(arg.split('=', 1)[1]) for arg in argv
                   if arg.startswith('--outputFile=')), None)
    if name == 'repository-scripts' and report is not None:
        report.unlink(missing_ok=True)
    process = subprocess.Popen(
        argv, cwd=str(cwd), env=lane_env(overlay),
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
        errors='replace', bufsize=1, start_new_session=True)

    def stop(sig):
        try:
            os.killpg(process.pid, sig)
        except ProcessLookupError:
            pass

    killer = threading.Timer(timeout + 5, stop, args=(signal.SIGKILL,))

    def expire():
        timed_out.set()
        stop(signal.SIGTERM)

    deadline = threading.Timer(timeout, expire)
    killer.start()
    deadline.start()
    for line in process.stdout:
        sys.stdout.write(line)
        tail.append(line)
        if name in ('ci-scripts', 'repository-scripts'):
            output.append(line)
        if not heap and V8_HEAP_EXHAUSTION.search(line):
            heap = True
        if not history:
            found = MISSING_HISTORY.search(line)
            if found:
                history = found.group(0)
    process.stdout.close()
    exit_code = process.wait()
    deadline.cancel()
    if timed_out.is_set():
        stop(signal.SIGKILL)
        exit_code = 124
    killer.cancel()
    deadline.join()
    killer.join()
    sys.stdout.flush()
    wall = round(time.monotonic() - started, 2)
    after = cgroup_oom_kills()
    killed = before >= 0 and after > before
    excused, history_only = history_failures(name, ''.join(output), report)
    oom = not timed_out.is_set() and bool(killed or exit_code == 137 or heap)
    return {
        'name': name,
        'group': group,
        'exit': exit_code,
        'wall_s': wall,
        'skipped': False,
        'timeout': timed_out.is_set(),
        'output_tail': ''.join(tail)[-8000:],
        'oom': oom,
        'history_excused': excused if exit_code != 0 else [],
        'history_only': exit_code == 1 and history_only and not oom and not timed_out.is_set(),
        'oom_evidence': ('cgroup oom_kill' if killed else
                         'exit 137' if exit_code == 137 else
                         'V8 heap exhaustion' if heap else ''),
        # Named only for a lane that failed, so a passing lane that merely
        # mentions a missing object never carries the label.
        'missing_history': history if exit_code != 0 else '',
    }


def read_plan(prepush: Path, source: Path, files: list) -> dict:
    """Ask the head's own planner which lanes this change selects.

    The planner modules are imported from the uploaded source by absolute file
    URL, so the selection is the head's, not a copy of it kept here. Only the
    changed-file list comes from the local half, because the screened upload
    deliberately carries no real ancestry for the planner to diff against.
    """
    helper = prepush / 'plan.mjs'
    helper.write_text(PLAN_HELPER, encoding='utf-8')
    result = subprocess.run(
        ['node', str(helper)], cwd=str(source), text=True, capture_output=True,
        env=lane_env({'FM_PREPUSH_FILES': json.dumps(files)}))
    sys.stderr.write(result.stderr)
    if result.returncode != 0:
        raise Unusable('the head planner refused to produce a plan (exit %d)' % result.returncode)
    try:
        return json.loads(result.stdout)
    except ValueError as exc:
        raise Unusable('the head planner printed no plan document') from exc


PLAN_HELPER = r'''
// Import the PULL REQUEST HEAD's own planner by absolute file URL, from a file
// that lives outside the source tree so the project's unused-file check never
// sees it. The changed-file list arrives as data because the screened upload
// carries no real ancestry to diff.
import path from 'node:path';
import { pathToFileURL } from 'node:url';

const root = process.cwd();
const load = (p) => import(pathToFileURL(path.join(root, p)).href);

const files = JSON.parse(process.env.FM_PREPUSH_FILES);
const [{ nodePlan }, { planQuality }, { readWorkspaces }, { databaseScope, DATABASE_SUITES }, { SHARDS }] =
  await Promise.all([
    load('.depot/scripts/node-plan.mjs'),
    load('.github/scripts/depot-ci/plan-quality.mjs'),
    load('.github/scripts/test-plan/shard-scope.mjs'),
    load('.github/scripts/test-plan/db-scope.mjs'),
    load('.github/scripts/test-plan/shards.mjs'),
  ]);

const workspaces = await readWorkspaces(root);
const node = nodePlan('pull_request', files, workspaces);
const quality = planQuality(files, workspaces);
const database = Object.fromEntries(
  Object.keys(DATABASE_SUITES).map((suite) => [suite, databaseScope(files, suite)]),
);
process.stdout.write(
  JSON.stringify({
    changed_files: files.length,
    wide_shards: SHARDS.filter((shard) => shard.filters.some((filter) => filter.startsWith('!')))
      .map((shard) => shard.name),
    node: {
      run_count: node.run_count,
      total: node.total,
      matrix: node.matrix.map(({ name, filters, passthrough }) => ({
        name,
        filters,
        passthrough,
      })),
    },
    quality,
    database,
  }),
);
'''


def select_lanes(plan: dict) -> list:
    """Turn the head's plan into the ordered lane table this run executes.

    Order is cheapest-signal-first within each group so a reader watching the
    stream sees a broken change fail early, and the groups follow the project's
    own workflow split.
    """
    quality = plan.get('quality') or {}
    packages = quality.get('packages')
    affected = None if packages is None else json.dumps(packages)
    quality_env = {
        'NODE_OPTIONS': '',
        'TURBO_CACHE_DIR': '.turbo/quality-cache',
        'CI_TURBO_QUALITY': '1',
        'CI_AFFECTED_PACKAGES': affected,
    }
    lanes = []

    if quality.get('app_checks'):
        for check in ('lint', 'typecheck-admin', 'typecheck-other', 'test-typecheck'):
            overlay = dict(quality_env)
            if check == 'test-typecheck':
                # The one selected lane that runs Turbo `build`, so the one an
                # admin-center build can be reached through on this machine.
                overlay['NODE_OPTIONS'] = '--max-old-space-size=%d' % ADMIN_BUILD_HEAP_MB
            lanes.append({
                'name': 'quality-' + check,
                'group': 'quality',
                'argv': ['node', '.github/scripts/test-plan/run-affected.mjs', check],
                'env': overlay,
            })

    for index, shard in enumerate(plan.get('node', {}).get('matrix') or []):
        filters = shard.get('filters') or []
        if shard.get('name') in plan['wide_shards']:
            argv = (['pnpm', 'test:ci', '--concurrency=%d' % WIDE_SHARD_CONCURRENCY]
                    + ['--filter=%s' % f for f in filters]
                    + ['--'] + list(shard.get('passthrough') or []))
            overlay = {'NODE_OPTIONS': '--import tsx'}
        else:
            # The head's own shard runner, given the planner's own selection.
            argv = ['node', '.depot/scripts/run-node-shard.mjs']
            overlay = {
                'NODE_OPTIONS': '--import tsx',
                'SHARD_NAME': shard.get('name'),
                'SHARD_FILTERS': json.dumps(filters),
            }
        lanes.append({
            'name': 'node-%d' % index,
            'group': 'node',
            'label': shard.get('name'),
            'argv': argv,
            'env': overlay,
        })

    lanes.append({
        'name': 'ci-scripts',
        'group': 'scripts',
        'argv': ['node', '.github/scripts/run-suites.mjs'],
        'env': {},
    })
    if quality.get('script_tests'):
        if quality.get('tooling_only'):
            argv = ['npx', 'vitest', 'run', 'scripts/__tests__/planetgear-dev-store.test.ts']
        elif not quality.get('pipeline_harness'):
            argv = ['npx', 'vitest', 'run', '--dir', 'scripts',
                    '--exclude', 'scripts/__tests__/pipeline-test.test.ts']
        else:
            argv = ['npx', 'vitest', 'run', '--dir', 'scripts']
        lanes.append({
            'name': 'repository-scripts', 'group': 'scripts',
            'argv': argv + ['--reporter=default', '--reporter=json',
                            '--outputFile=' + str(Path(__file__).resolve().parent / 'repository-scripts.json')],
            'env': {},
        })
    if quality.get('app_checks'):
        lanes.append({
            'name': 'edge-function',
            'group': 'scripts',
            'argv': ['node', '--test', 'supabase/functions/update-btc-rates/index.test.mjs'],
            'env': {},
        })
    for suite in MEASURED_DATABASE_SUITES:
        if ((plan.get('database') or {}).get(suite) or {}).get('run'):
            lanes.append({
                'name': 'database-' + suite, 'group': 'database',
                'argv': [sys.executable, str(Path(__file__).resolve()), '--database', suite],
                'env': {},
            })
    return lanes


def run_database(suite: str, source: Path, prepush: Path) -> int:
    """Run database suites with only the PR's changed files in the ledger diff.

    The ledger consumes Git rather than a changed-file list. Give that subprocess
    an isolated two-commit view whose base is the uploaded tree minus the changed
    paths. Unchanged migrations disappear from its diff; changed migrations are
    additions, keeping unfingerprinted SQL in fatal tier A. Other lanes retain
    the wrapper's history, including its explicit missing-history boundary.
    """
    images = json.loads((source / '.github/ci-images.json').read_text(encoding='utf-8'))
    approved = {}
    for image in images['images']:
        if image['repo'] in ('library/postgres', 'postgrest/postgrest'):
            if not re.fullmatch(r'sha256:[0-9a-f]{64}', image['digest']):
                raise Unusable('database image is not digest-pinned')
            approved[image['repo']] = image['source'] + '@' + image['digest']
    postgres = approved['library/postgres']
    work = prepush / ('database-' + suite)
    work.mkdir(parents=True, exist_ok=True)
    (work / 'tmp').mkdir(exist_ok=True)
    ledger_git = work / 'ledger.git'
    if suite in ('db', 'actions'):
        files = json.loads((prepush / 'changed-files.json').read_text(encoding='utf-8'))
        subprocess.run(['git', 'init', '--bare', '--quiet', str(ledger_git)], check=True)
        objects = subprocess.check_output(
            ['git', 'rev-parse', '--git-path', 'objects'], cwd=source, text=True).strip()
        (ledger_git / 'objects/info/alternates').write_text(
            str((source / objects).resolve()) + '\n', encoding='utf-8')
        git_env = dict(os.environ, GIT_DIR=str(ledger_git), GIT_WORK_TREE=str(source),
                       GIT_AUTHOR_NAME='Boat-test', GIT_COMMITTER_NAME='Boat-test',
                       GIT_AUTHOR_EMAIL='boat-test@example.invalid',
                       GIT_COMMITTER_EMAIL='boat-test@example.invalid')

        def git(*args, data=None):
            return subprocess.check_output(['git', *args], cwd=source,
                                           env=git_env, input=data).decode().strip()

        tree = subprocess.check_output(['git', 'rev-parse', 'HEAD^{tree}'],
                                       cwd=source, text=True).strip()
        git('read-tree', tree)
        if files:
            git('update-index', '--force-remove', '-z', '--stdin',
                data=('\0'.join(files) + '\0').encode())
        base = git('commit-tree', git('write-tree'), data=b'Unchanged uploaded content\n')
        head = git('commit-tree', tree, '-p', base, data=b'PR changed files\n')
        git('update-ref', 'refs/remotes/origin/main', base)
        git('update-ref', 'HEAD', head)
    dsn = 'postgresql://postgres:postgres@localhost:5432/postgres'
    env = {
        'TMPDIR': str(work / 'tmp'),
        'DB_LOCAL_URL': dsn, 'DEV_DB_URL': dsn, 'SCHEMA_ONLY_DB': 'true',
        'DB_LOCAL_LOGDIR': str(work / 'restore'),
        'NODE_OPTIONS': '--import tsx',
        'LEDGER_DELTA_REPORT': str(work / 'ledger-delta.json'),
        'LEDGER_GIT_DIR': str(ledger_git),
    }
    script = r'''
set -euo pipefail
command -v docker
docker pull "$POSTGRES_IMAGE"
# The approved digest, rather than the distribution default, owns the version.
major=$(docker image inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$POSTGRES_IMAGE" | sed -n 's/^PG_MAJOR=//p')
if [[ ! "$major" =~ ^[1-9][0-9]*$ ]]; then
  echo 'Cannot resolve PostgreSQL client major from the approved server image' >&2
  exit 1
fi
export PATH="/usr/lib/postgresql/$major/bin:$PATH"
native_clients_ready() {
  for tool in psql pg_dump pg_restore createdb dropdb pg_isready; do
    command -v "$tool" >/dev/null || return 1
  done
  psql --version | grep -Eq "\(PostgreSQL\) $major\."
}
install_native_clients() {
  # These changes run only on the disposable VM. Subsequent lanes reuse them.
  . /etc/os-release
  [ -n "${VERSION_CODENAME:-}" ] || return 1
  curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | sudo -n tee /usr/share/keyrings/fm-pgdg.asc >/dev/null || return 1
  printf 'deb [signed-by=/usr/share/keyrings/fm-pgdg.asc] https://apt.postgresql.org/pub/repos/apt %s-pgdg main\n' "$VERSION_CODENAME" | sudo -n tee /etc/apt/sources.list.d/fm-pgdg.list >/dev/null || return 1
  sudo -n apt-get update || return 1
  sudo -n env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "postgresql-client-$major" || return 1
}
if ! native_clients_ready; then
  if ! install_native_clients || ! native_clients_ready; then
    echo "Cannot obtain native PostgreSQL $major clients from PGDG; database lane refused" >&2
    exit 1
  fi
fi
pg=''
cleanup() {
  rc=$?
  trap - EXIT
  if [ -f "$POSTGREST_CIDFILE" ]; then
    docker rm -f "$(cat "$POSTGREST_CIDFILE")" || rc=1
    rm -f "$POSTGREST_CIDFILE"
  fi
  if [ -n "$pg" ]; then docker rm -f "$pg" || rc=1; fi
  exit "$rc"
}
trap cleanup EXIT
pg=$(docker run -d --pull=never -p 127.0.0.1:5432:5432 -e POSTGRES_PASSWORD=postgres "$POSTGRES_IMAGE")
export PG_CONTAINER="$pg"
ready=false
for attempt in {1..120}; do
  if docker exec "$pg" pg_isready -h 127.0.0.1 -p 5432 -U postgres -d postgres; then ready=true; break; fi
  sleep 1
done
[ "$ready" = true ]
'''
    env['POSTGRES_IMAGE'] = postgres
    env['POSTGREST_CIDFILE'] = str(work / 'postgrest.cid')
    if suite in ('db', 'actions'):
        script += r'''
bash .github/scripts/db-local/restore-snapshot.sh
GIT_DIR="$LEDGER_GIT_DIR" GIT_WORK_TREE="$PWD" node .github/scripts/db-local/ledger-delta.mjs --tiers am --base-ref "$DIFF_BASE"
bash .github/scripts/db-local/prd-guards.sh "$PG_CONTAINER" "$DB_LOCAL_URL"
'''
    if suite == 'db':
        env['DB_ASSERTION_REPORT_DIR'] = str(work / 'assertions')
        script += 'pnpm --filter @core/db exec vitest run --config ./vitest.instrumented.config.ts --reporter=default\n'
    elif suite == 'actions':
        env.update({
            'POSTGREST_IMAGE': approved['postgrest/postgrest'],
            'POSTGREST_PULL_POLICY': 'never',
            'POSTGREST_URL': 'http://127.0.0.1:54390',
            'ACTION_DB_URL': dsn,
        })
        script += r'''
docker pull "$POSTGREST_IMAGE"
export POSTGREST_DB_CONTAINER="$pg"
bash .github/scripts/action-db/start-postgrest.sh
pnpm --filter @core/metaplanet test:postgrest --reporter=default
'''
    elif suite == 'runtime':
        for key in ('APPLY_MIGRATIONS', 'OVERLOAD', 'PARITY', 'OVERLOAD_GUARD',
                    'KNOWN_TABLES', 'DUMP_TABLE_CSV', 'REFRESH_DB', 'BG_APPLY',
                    'ROLE_GRANTS', 'SPLIT_CARRY', 'INFRA_SQL_REPLAY',
                    'TICKETING_PRESERVE', 'DDL_GUARD'):
            env[key + '_PG_DSN'] = dsn
        suites = sorted(str(path.relative_to(source))
                        for path in (source / '.github/scripts').rglob('*.pg.test.mjs'))
        if not suites:
            raise Unusable('no live-PostgreSQL test files found')
        script += ('node --test --test-concurrency=1 --test-reporter=tap ' + shlex.join(suites)
                   + ' | tee ' + shlex.quote(str(work / 'runtime.tap')) + '\n')
        script += r'''
tests=$(sed -n 's/^# tests \([0-9]*\)$/\1/p' "$RUNTIME_TAP" | tail -1)
skipped=$(sed -n 's/^# skipped \([0-9]*\)$/\1/p' "$RUNTIME_TAP" | tail -1)
[ -n "$tests" ] && [ "$tests" -gt 0 ] && [ "$skipped" = 0 ]
'''
        env['RUNTIME_TAP'] = str(work / 'runtime.tap')
    else:
        raise Unusable('unsupported database suite: ' + suite)
    return subprocess.run(['bash', '-c', script], cwd=source, env=lane_env(env)).returncode


def install(source: Path, timeout: float = 600) -> dict:
    """Install the change's own frozen dependencies.

    Corepack is enabled first so the package manager is the exact version the
    project's manifest pins, rather than whatever the disposable machine's
    image happens to ship. A machine that already has that version is
    unaffected, so this stays one lane rather than a separate probe.
    """
    return run_lane('install', 'setup', [
        'bash', '-c',
        'corepack enable pnpm >/dev/null 2>&1 || true\nexec pnpm install --frozen-lockfile',
    ], {}, source, timeout=timeout)


# bin/fm-boat-run.sh's header owns the remote working directory on both providers.
# This guard also refuses local execution if invoked without the remote-only
# wrapper setting enforced by bin/fm-boat-prepush.sh's local implementation.
REMOTE_SOURCE = Path('/home/user/fm-job/source')


def main() -> int:
    source = Path.cwd()
    if source != REMOTE_SOURCE:
        raise Unusable(
            'refusing to run outside a disposable machine: the working directory is %s, '
            'not %s. This check runs a whole heavy test suite and must never fall back to '
            'the local machine.' % (source, REMOTE_SOURCE))
    if len(sys.argv) == 3 and sys.argv[1] == '--database':
        return run_database(sys.argv[2], source, Path(__file__).resolve().parent)
    # Leave room for run_lane's five-second kill grace and summary transport.
    deadline = time.monotonic() + float(os.environ['FM_PREPUSH_TIMEOUT']) - 10
    prepush = Path(os.environ['FM_PREPUSH_DIR'])
    prepush.mkdir(parents=True, exist_ok=True)
    if not (source / '.github/scripts/test-plan').is_dir():
        raise Unusable('the uploaded source carries no .github/scripts/test-plan planner')
    if shutil.which('node') is None:
        raise Unusable('node is not on PATH on this machine')

    results = [install(source, max(0, min(600, deadline - time.monotonic())))]
    emit('LANE', results[0])
    if results[0]['exit'] != 0:
        emit('SUMMARY', {'lanes': results, 'plan': None, 'database_not_run': [],
                         'failed': ['install'], 'oom': results[0]['oom']})
        return 0

    files = json.loads(os.environ['FM_PREPUSH_FILES'])
    (prepush / 'changed-files.json').write_text(json.dumps(files), encoding='utf-8')
    plan = read_plan(prepush, source, files)
    lanes = select_lanes(plan)
    not_run = sorted(suite for suite, scope in (plan.get('database') or {}).items()
                     if (scope or {}).get('run') and suite not in MEASURED_DATABASE_SUITES)
    emit('PLAN', {'plan': plan, 'lanes': [lane['name'] for lane in lanes],
                  'database_not_run': not_run})

    unreported = []
    for index, lane in enumerate(lanes):
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            unreported = [pending['name'] for pending in lanes[index:]]
            break
        result = run_lane(lane['name'], lane['group'], lane['argv'], lane['env'], source,
                          timeout=min(600, remaining))
        result['label'] = lane.get('label') or lane['name']
        result['command'] = ' '.join(lane['argv'])
        results.append(result)
        emit('LANE', result)

    failed = [r['name'] for r in results if r['exit'] != 0 and not r.get('history_only')]
    emit('SUMMARY', {
        'lanes': results,
        'plan': plan,
        'database_not_run': not_run,
        'unreported': unreported,
        'failed': failed + unreported,
        'oom': not unreported and bool(failed) and all(r['oom'] for r in results if r['exit'] != 0 and not r.get('history_only')),
    })
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except Unusable as error:
        sys.stderr.write('fm-boat-prepush-remote: %s\n' % error)
        sys.exit(70)
