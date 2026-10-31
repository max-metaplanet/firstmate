#!/usr/bin/env python3
"""Local half of the pre-ready heavy-test check. bin/fm-boat-prepush.sh is the
documented entry point and its header owns the operator contract."""

from __future__ import annotations

import argparse
import json
import os
import re
import shlex
import subprocess
import sys
import tempfile
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
WRAPPER = HERE / 'fm-boat-test-wrapper.sh'
RUNNER = HERE / 'fm-boat-prepush-remote.py'

# Boat's published compute rate and the machine multipliers its usage API
# reports. Every number derived from these is an estimate printed as one: the
# adapter exposes no final invoice or billed-seconds field.
DOLLARS_PER_SECOND = 0.00001
MULTIPLIER = {'default': 1, 'large': 2}

MARKER = re.compile(r'^FM_BOAT_PREPUSH_(PLAN|LANE|SUMMARY) (\{.*\})$')

# The head's own changed-file reader, imported by absolute file URL from a file
# that never enters the source tree. Only the diff is computed here, because
# the screened upload deliberately carries no ancestry for the remote planner.
FILES_HELPER = r'''
import path from 'node:path';
import { pathToFileURL } from 'node:url';
const root = process.argv[2];
const { readChangedFiles } = await import(
  pathToFileURL(path.join(root, '.github/scripts/test-plan/shard-scope.mjs')).href
);
process.stdout.write(JSON.stringify(await readChangedFiles(root, process.argv[3], process.argv[4])));
'''


class Refusal(Exception):
    def __init__(self, message, code=2):
        super().__init__(message)
        self.code = code


def git(worktree: Path, *args: str) -> str:
    result = subprocess.run(['git', '-C', str(worktree), *args],
                            capture_output=True, text=True)
    if result.returncode != 0:
        raise Refusal('git %s failed in %s: %s'
                      % (' '.join(args), worktree, result.stderr.strip()))
    return result.stdout.strip()


def resolve_base(worktree: Path, base: str | None) -> str:
    """The revision the change is measured against, as a full object name.

    Default is the tracked default branch, read from origin's own HEAD, because
    that is what the project's own planner diffs a pull request against.
    """
    if base:
        return git(worktree, 'rev-parse', '--verify', base + '^{commit}')
    for candidate in ('refs/remotes/origin/HEAD', 'refs/remotes/origin/main'):
        try:
            return git(worktree, 'rev-parse', '--verify', candidate + '^{commit}')
        except Refusal:
            continue
    raise Refusal('cannot resolve a base revision: no origin/HEAD or origin/main in '
                  '%s; name one with --base' % worktree)


def changed_files(worktree: Path, scratch: Path, base: str, head: str) -> list:
    helper = scratch / 'changed-files.mjs'
    helper.write_text(FILES_HELPER, encoding='utf-8')
    result = subprocess.run(['node', str(helper), str(worktree), base, head],
                            capture_output=True, text=True)
    if result.returncode != 0:
        raise Refusal("the head's own changed-file reader refused: %s"
                      % (result.stderr.strip() or 'exit %d' % result.returncode))
    files = json.loads(result.stdout)
    if not files:
        raise Refusal('%s..%s changes no file: there is nothing to check' % (base[:12], head[:12]))
    return files


def command_string(files: list) -> str:
    """The one command string the Boat test wrapper takes.

    The runner is written beside the uploaded source rather than into it, so the
    project's unused-file check never sees a helper the change did not add.
    """
    runner = RUNNER.read_text(encoding='utf-8')
    if 'FM_PREPUSH_RUNNER_EOF' in runner:
        raise Refusal('the remote runner contains the heredoc terminator')
    return (
        'set -euo pipefail\n'
        'FM_PREPUSH_DIR="$(dirname "$PWD")/prepush"\n'
        'mkdir -p "$FM_PREPUSH_DIR"\n'
        "cat > \"$FM_PREPUSH_DIR/runner.py\" <<'FM_PREPUSH_RUNNER_EOF'\n"
        + runner +
        '\nFM_PREPUSH_RUNNER_EOF\n'
        'export FM_PREPUSH_DIR\n'
        'export FM_PREPUSH_FILES=' + shlex.quote(json.dumps(files)) + '\n'
        'exec python3 "$FM_PREPUSH_DIR/runner.py"\n'
    )


def attempt(worktree: Path, output: Path, size: str, timeout: int,
            history_depth: int | None, command: str) -> dict:
    """One whole-machine run, start to finish, on one machine size."""
    log = output / ('attempt-%s.log' % size)
    env = dict(os.environ)
    env['FM_BOAT_TYPE'] = size
    env['FM_BOAT_TEST_TIMEOUT'] = str(timeout)
    if history_depth is not None:
        env['FM_BOAT_TEST_HISTORY_DEPTH'] = str(history_depth)
    started = time.monotonic()
    plan, lanes, summary, unavailable = None, [], None, False
    with log.open('w', encoding='utf-8') as sink:
        process = subprocess.Popen(
            ['bash', str(WRAPPER), command], cwd=str(worktree), env=env,
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
            errors='replace', bufsize=1)
        for line in process.stdout:
            sink.write(line)
            sys.stderr.write(line)
            if 'Boat unavailable' in line:
                unavailable = True
            match = MARKER.match(line.rstrip('\n'))
            if not match:
                continue
            kind, document = match.group(1), json.loads(match.group(2))
            if kind == 'PLAN':
                plan = document
            elif kind == 'LANE':
                lanes.append(document)
            else:
                summary = document
        process.stdout.close()
        adapter_exit = process.wait()
    sys.stderr.flush()
    wall = round(time.monotonic() - started, 2)
    return {
        'size': size,
        'adapter_exit': adapter_exit,
        'wall_s': wall,
        'dollars_estimate': round(wall * DOLLARS_PER_SECOND * MULTIPLIER[size], 5),
        'log': str(log),
        'plan': plan,
        'lanes': lanes,
        'summary': summary,
        # The wrapper falls back to the local machine when Boat is unavailable.
        # That is right for a single pipeline test command and wrong for a whole
        # heavy suite, so the remote runner refuses it and this records why the
        # attempt produced no verdict.
        'boat_unavailable': unavailable,
    }


def verdict(run: dict) -> tuple:
    """(ok, failing lane names, oom_only). A run that produced no summary is a
    failure of the check itself, never a pass."""
    summary = run.get('summary')
    if summary is None or run.get('adapter_exit') != 0:
        return False, [], False
    failed = list(summary.get('failed') or [])
    return (not failed), failed, bool(summary.get('oom'))


def should_retry_large(run: dict) -> bool:
    """A larger machine is bought only for PROVEN memory exhaustion, and only
    when nothing else failed.

    An ordinary assertion failure is already the answer and paying for a second
    machine would not change it. A mixed result is red either way, so it buys
    nothing. A run that produced no verdict at all is a failure of the check
    rather than evidence about memory, so it never buys one either.
    """
    ok, failed, oom_only = verdict(run)
    return bool(not ok and failed and oom_only and run['size'] == 'default')


def report(runs: list, out) -> None:
    final = runs[-1]
    out.write('\npre-ready heavy-test check\n')
    for run in runs:
        out.write('  attempt on the %s machine: %.1f min, about $%.5f (estimate), '
                  'adapter exit %d\n'
                  % (run['size'], run['wall_s'] / 60, run['dollars_estimate'],
                     run['adapter_exit']))
        out.write('  full output: %s\n' % run['log'])
    plan = (final.get('plan') or {}).get('plan') or {}
    if plan:
        node = plan.get('node') or {}
        out.write('  change: %d changed files; %s of %s shards selected\n'
                  % (plan.get('changed_files', 0), node.get('run_count', '?'),
                     node.get('total', '?')))
    if final.get('boat_unavailable'):
        out.write('  no disposable machine was available, and this check refuses to run a '
                  'whole heavy suite on the local machine\n')
    if not final['lanes']:
        out.write('  no lane reported a verdict\n')
    for lane in final['lanes']:
        state = ('pass' if lane['exit'] == 0 else
                 'unavailable' if lane.get('history_only') else 'FAIL')
        note = ''
        if lane['exit'] != 0:
            note = ' exit %d' % lane['exit']
            if lane.get('oom'):
                note += ', out of memory (%s)' % lane['oom_evidence']
            if lane.get('missing_history'):
                note += ', reads Git objects this upload does not carry'
        out.write('  %-26s %-4s %6.1fs%s\n'
                  % (lane.get('label') or lane['name'], state, lane['wall_s'], note))
    not_run = (final.get('summary') or {}).get('database_not_run') or []
    if not_run:
        out.write('  not run on Boat (neither pass nor fail): %s; '
                  'forge CI remains the authority for these suites.\n' % ', '.join(not_run))
    excused = [(lane['name'], test) for lane in final['lanes']
               for test in lane.get('history_excused', [])]
    for name, test in excused:
        out.write('  unavailable %s / %s: %s\n'
                  % (name, test['name'], test['evidence']))
    if excused:
        out.write("  The forge's required checks remain the authority for these "
                  "unavailable cases; green here does not mean full parity.\n")
    ok, failed, _ = verdict(final)
    out.write('  verdict: %s (%s machine)\n'
              % ('green' if ok else 'RED - ' + ', '.join(failed) if failed
                 else 'RED - the check produced no verdict', final['size']))


def main(argv: list) -> int:
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument('--worktree', default='.')
    parser.add_argument('--base', default=None)
    parser.add_argument('--expected-head', default=None)
    parser.add_argument('--timeout', type=int, default=2700)
    parser.add_argument('--history-depth', type=int, default=None)
    parser.add_argument('--output', default=None)
    args = parser.parse_args(argv)

    if not 1 <= args.timeout <= 2700:
        raise Refusal('--timeout must be 1..2700 seconds')
    if args.history_depth is not None and not 1 <= args.history_depth <= 1000:
        raise Refusal('--history-depth must be 1..1000')
    if not os.environ.get('FM_HOME'):
        raise Refusal('FM_HOME must name the home whose config/boat-keys this run may use')

    worktree = Path(args.worktree).resolve()
    top = Path(git(worktree, 'rev-parse', '--show-toplevel')).resolve()
    if top != worktree:
        raise Refusal('--worktree must be a repository root; %s is inside %s' % (worktree, top))

    head = git(worktree, 'rev-parse', 'HEAD^{commit}')
    if args.expected_head is not None:
        if args.expected_head != head:
            raise Refusal('checkout HEAD %s does not match expected PR head %s'
                          % (head, args.expected_head))
        if git(worktree, 'status', '--porcelain', '--untracked-files=no', '--ignore-submodules=none'):
            raise Refusal('tracked checkout content differs from expected PR head %s; '
                          'staged or unstaged changes cannot certify that commit' % head)

    output = Path(args.output).resolve() if args.output else Path(
        tempfile.mkdtemp(prefix='fm-boat-prepush.', dir=str(worktree.parent)))
    output.mkdir(parents=True, exist_ok=True)

    base = resolve_base(worktree, args.base)
    files = changed_files(worktree, output, base, head)
    command = command_string(files)

    sys.stderr.write('fm-boat-prepush: %s..%s, %d changed files; evidence under %s\n'
                     % (base[:12], head[:12], len(files), output))

    runs = [attempt(worktree, output, 'default', args.timeout, args.history_depth, command)]
    if should_retry_large(runs[-1]):
        sys.stderr.write('fm-boat-prepush: every failing lane ran out of memory; '
                         'retrying once on the large machine\n')
        runs.append(attempt(worktree, output, 'large', args.timeout,
                            args.history_depth, command))
    ok, failed, _ = verdict(runs[-1])

    report(runs, sys.stdout)
    record = {'base': base, 'head': head, 'changed_files': len(files),
              'green': ok, 'failed': failed, 'attempts': runs}
    (output / 'verdict.json').write_text(json.dumps(record, indent=2), encoding='utf-8')
    return 0 if ok else 1


if __name__ == '__main__':
    try:
        sys.exit(main(sys.argv[1:]))
    except Refusal as error:
        sys.stderr.write('fm-boat-prepush: %s\n' % error)
        sys.exit(error.code)
