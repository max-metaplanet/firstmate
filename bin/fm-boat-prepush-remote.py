#!/usr/bin/env python3
"""Remote half of the pre-ready heavy-test check (bin/fm-boat-prepush.sh).

This file never runs on the operator's machine. bin/fm-boat-prepush.py ships it
to a disposable Boat VM inside the one command string the Boat test wrapper
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

V8_HEAP_EXHAUSTION = re.compile(
    r'Ineffective mark-compacts near heap limit|'
    r'JavaScript heap out of memory|'
    r'FATAL ERROR: .*Allocation failed')

# Git's own diagnostics for an object the repository does not have. The screened
# upload carries no real ancestry by default, so a fixture that reads a pinned
# historical commit fails for the transport rather than for the change. These
# are Git's wording, not any project's, so the detection does not depend on
# knowing which tests those are. It only LABELS the failure: a lane that failed
# still failed, and the verdict stays red, because the alternative is excusing a
# real regression that happens to print the same diagnostic.
MISSING_HISTORY = re.compile(
    r'exists on disk, but not in|'
    r'unknown revision or path not in the working tree|'
    r'fatal: bad object|'
    r'fatal: not a valid object name|'
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


def run_lane(name: str, group: str, argv: list, overlay: dict, cwd: Path) -> dict:
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
    process = subprocess.Popen(
        argv, cwd=str(cwd), env=lane_env(overlay),
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
        errors='replace', bufsize=1)
    for line in process.stdout:
        sys.stdout.write(line)
        if not heap and V8_HEAP_EXHAUSTION.search(line):
            heap = True
        if not history:
            found = MISSING_HISTORY.search(line)
            if found:
                history = found.group(0)
    process.stdout.close()
    exit_code = process.wait()
    sys.stdout.flush()
    wall = round(time.monotonic() - started, 2)
    after = cgroup_oom_kills()
    killed = before >= 0 and after > before
    return {
        'name': name,
        'group': group,
        'exit': exit_code,
        'wall_s': wall,
        'skipped': False,
        'oom': bool(killed or exit_code == 137 or heap),
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
const [{ nodePlan }, { planQuality }, { readWorkspaces }, { databaseScope, DATABASE_SUITES }] =
  await Promise.all([
    load('.depot/scripts/node-plan.mjs'),
    load('.github/scripts/depot-ci/plan-quality.mjs'),
    load('.github/scripts/test-plan/shard-scope.mjs'),
    load('.github/scripts/test-plan/db-scope.mjs'),
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
        # The shard stated as EXCLUSIONS fans out across every remaining
        # workspace, which is the one that exhausted the default machine
        # uncapped. Capping it by that structural property rather than by its
        # name keeps the rule true when the project renames or resplits shards.
        wide = any(str(f).startswith('!') for f in filters)
        if wide:
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
            'name': 'repository-scripts', 'group': 'scripts', 'argv': argv, 'env': {},
        })
    if quality.get('app_checks'):
        lanes.append({
            'name': 'edge-function',
            'group': 'scripts',
            'argv': ['node', '--test', 'supabase/functions/update-btc-rates/index.test.mjs'],
            'env': {},
        })
    return lanes


def database_selection(plan: dict) -> list:
    """The database suites the head's planner selected, which this check reports
    but does not execute. Those suites run on the project's own CI container
    image, whose PostgreSQL and PostgREST toolchain a stock disposable VM does
    not carry; standing that image up again here would be a second subsystem,
    and it was itself the source of several measurement-environment failures.
    Reporting them as not run keeps the verdict honest instead of letting a
    green line stand for work that never happened.
    """
    return sorted(suite for suite, verdict in (plan.get('database') or {}).items()
                  if isinstance(verdict, dict) and verdict.get('run'))


def install(source: Path) -> dict:
    """Install the change's own frozen dependencies.

    Corepack is enabled first so the package manager is the exact version the
    project's manifest pins, rather than whatever the disposable machine's
    image happens to ship. A machine that already has that version is
    unaffected, so this stays one lane rather than a separate probe.
    """
    return run_lane('install', 'setup', [
        'bash', '-c',
        'corepack enable pnpm >/dev/null 2>&1 || true\nexec pnpm install --frozen-lockfile',
    ], {}, source)


# The only working directory a disposable Boat machine runs the command in
# (bin/fm-boat-run.sh's header owns it). Asserting it is what stops this runner
# executing a whole heavy test suite on the operator's own machine: the Boat
# test wrapper falls back to local execution when Boat is unavailable, and that
# fallback is safe for a single pipeline test command but never for this one.
REMOTE_SOURCE = Path('/home/user/fm-job/source')


def main() -> int:
    source = Path.cwd()
    if source != REMOTE_SOURCE:
        raise Unusable(
            'refusing to run outside a disposable machine: the working directory is %s, '
            'not %s. This check runs a whole heavy test suite and must never fall back to '
            'the local machine.' % (source, REMOTE_SOURCE))
    prepush = Path(os.environ['FM_PREPUSH_DIR'])
    prepush.mkdir(parents=True, exist_ok=True)
    if not (source / '.github/scripts/test-plan').is_dir():
        raise Unusable('the uploaded source carries no .github/scripts/test-plan planner')
    if shutil.which('node') is None:
        raise Unusable('node is not on PATH on this machine')

    results = [install(source)]
    emit('LANE', results[0])
    if results[0]['exit'] != 0:
        emit('SUMMARY', {'lanes': results, 'plan': None, 'database_not_run': [],
                         'failed': ['install'], 'oom': results[0]['oom']})
        return 0

    files = json.loads(os.environ['FM_PREPUSH_FILES'])
    plan = read_plan(prepush, source, files)
    lanes = select_lanes(plan)
    not_run = database_selection(plan)
    emit('PLAN', {'plan': plan, 'lanes': [lane['name'] for lane in lanes],
                  'database_not_run': not_run})

    for lane in lanes:
        result = run_lane(lane['name'], lane['group'], lane['argv'], lane['env'], source)
        result['label'] = lane.get('label') or lane['name']
        result['command'] = ' '.join(lane['argv'])
        results.append(result)
        emit('LANE', result)

    failed = [r['name'] for r in results if r['exit'] != 0]
    emit('SUMMARY', {
        'lanes': results,
        'plan': plan,
        'database_not_run': not_run,
        'failed': failed,
        'oom': bool(failed) and all(r['oom'] for r in results if r['exit'] != 0),
    })
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except Unusable as error:
        sys.stderr.write('fm-boat-prepush-remote: %s\n' % error)
        sys.exit(70)
