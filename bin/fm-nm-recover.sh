#!/usr/bin/env bash
# Recover a terminal run's stale private mirror without rewriting task history.
# Usage: fm-nm-recover.sh <task-worktree> <exact-branch> [--home <home>] [--task <id>]
#
# Reads version-matched `axi status` TOON and the registered local state DB.
# An active run is reattached, never cancelled. Unreturned custody must first
# follow the installed tool's supported sync guidance. For returned custody,
# compare only refs/heads/<exact-branch> in this repository's registered gate.
# Every gate-only nonempty, nonmerge commit must have a stable patch-ID match
# in the local history (including changes subsequently superseded there).
# Unique commits are printed with their subjects; empty/merge commits and
# incomplete history refuse rather than pretending to have a patch-ID proof.
# After proof, copy the old head's objects and anchor it locally under
# refs/no-mistakes/recover-local/<run>-<old-head> with a create-only guard.
# Recheck task/run identity, then delete only the stale gate branch with its
# expected old value. The gate receives no objects, tags, or other ref writes.
# No reset, merge, push, daemon operation, DB write, or pipeline start occurs.
# Deletion requires the owning FM_HOME and FM_TASK_ID (or --home and --task).
# Every successful deletion is recorded in that home's state/<task>.status and
# published through fm-parent-channel-lib.sh with home, task, ref and old head.
# FM_STATE_OVERRIDE selects the local state directory when set. A primary home
# has no parent channel: its local task status is the durable record and output
# explicitly says parent_report: not_applicable_primary_home. A reporting error
# returns 3 with changed:true already printed and the deletion left intact;
# local status and stderr name a failed parent report. No report is emitted for
# a refused proof or a no-op. Each actual deletion gets its own event key.
# Retry the original run/rerun command after action: retry_pipeline. Repeated
# invocation after deletion is a no-op. Unknown schemas or unsafe states fail
# closed. Python 3 (stdlib sqlite3), Git, and no-mistakes are required.
set -euo pipefail
if [ "${1:-}" = --help ]; then
  sed -n '2,/^set -/p' "$0" | sed '$d; s/^# *//'
  exit 0
fi
if [ "$#" -lt 2 ]; then
  echo "usage: fm-nm-recover.sh <task-worktree> <exact-branch> [--home <home>] [--task <id>]" >&2
  exit 2
fi
exec python3 - "${BASH_SOURCE[0]}" "$@" <<'PY'
import argparse
import json
import os
from pathlib import Path
import re
import sqlite3
import subprocess
import sys
import uuid
from contextlib import closing


class Refused(Exception):
    pass


class ReportFailed(Exception):
    pass


def command(args, cwd, env=None, allowed=(0,), data=None):
    result = subprocess.run(args, cwd=cwd, env=env or os.environ, input=data,
                            text=True, capture_output=True, timeout=30)
    if result.returncode not in allowed:
        raise Refused("%s: %s" % (" ".join(args), result.stderr.strip() or result.stdout.strip()))
    return result.stdout.strip()


def toon(text):
    # Only the scalar/object subset containing run and branch_sync identity.
    # Ignore tables, but never accept duplicate scalar keys or guessed nesting.
    fields, stack = {}, [(-1, "")]
    for line in text.splitlines():
        match = re.fullmatch(r"( *)([A-Za-z_]+):(?: (.*))?", line)
        if not match:
            continue
        indent, key, value = len(match[1]), match[2], match[3]
        while stack[-1][0] >= indent:
            stack.pop()
        path = stack[-1][1] + key
        if path in fields:
            raise Refused("duplicate structured status field: " + path)
        fields[path] = value
        if value is None:
            stack.append((indent, path + "."))
        elif value.startswith('"'):
            fields[path] = json.loads(value)
    return fields


def recover():
    publisher = Path(sys.argv[1]).resolve().parent / "fm-parent-channel-lib.sh"
    parser = argparse.ArgumentParser()
    parser.add_argument("worktree")
    parser.add_argument("branch")
    parser.add_argument("--home", default=os.environ.get("FM_HOME"))
    parser.add_argument("--task", default=os.environ.get("FM_TASK_ID"))
    args = parser.parse_args(sys.argv[2:])
    wt, branch = Path(args.worktree).resolve(strict=True), args.branch
    # A caller's repository-location overrides must not redirect any Git write.
    overrides = ("GIT_DIR", "GIT_WORK_TREE", "GIT_COMMON_DIR", "GIT_INDEX_FILE",
                 "GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES",
                 "GIT_SHALLOW_FILE", "GIT_GRAFT_FILE", "GIT_REPLACE_REF_BASE")
    for key in overrides:
        if key in os.environ:
            raise Refused("unset repository override before recovery: " + key)
    env = dict(os.environ, GIT_NO_LAZY_FETCH="1", GIT_NO_REPLACE_OBJECTS="1",
               NO_MISTAKES_NO_UPDATE_CHECK="1", GIT_TERMINAL_PROMPT="0")

    def git(*args, gate=False, alternate=False, allowed=(0,), data=None):
        local_env = dict(env)
        if alternate:
            local_env["GIT_ALTERNATE_OBJECT_DIRECTORIES"] = str(gate_dir / "objects")
        prefix = ["git", "--git-dir=" + str(gate_dir)] if gate else ["git", "-C", str(wt)]
        return command(prefix + list(args), wt, local_env, allowed, data)

    if Path(git("rev-parse", "--show-toplevel")).resolve() != wt:
        raise Refused("worktree argument must name its exact repository root")
    git("check-ref-format", "refs/heads/" + branch)
    head = git("rev-parse", "HEAD")

    def check_local():
        if git("symbolic-ref", "--quiet", "--short", "HEAD") != branch:
            raise Refused("checked-out branch does not match exact task branch " + branch)
        if git("rev-parse", "HEAD") != head or git("status", "--porcelain"):
            raise Refused("task HEAD changed or worktree is not clean")

    check_local()
    if git("rev-parse", "--is-shallow-repository") != "false":
        raise Refused("complete history is required for the patch-ID proof")
    common = Path(git("rev-parse", "--path-format=absolute", "--git-common-dir")).resolve()
    if common.name != ".git" or (common / "info/grafts").exists():
        raise Refused("unsupported common directory or grafted history")
    primary = common.parent
    nm_home = Path(os.environ.get("NM_HOME", str(Path.home() / ".no-mistakes")))
    if not nm_home.is_absolute():
        nm_home = wt / nm_home
    nm_home = nm_home.resolve()
    database = (nm_home / "state.sqlite").as_uri() + "?mode=ro"

    def status():
        fields = toon(command(["no-mistakes", "axi", "status"], wt, env))
        if fields.get("run.branch") != branch or fields.get("branch_sync.local.branch") != branch:
            raise Refused("structured status does not bind this exact task branch")
        if fields.get("branch_sync.local.head") != head or fields.get("branch_sync.local.clean") != "true":
            raise Refused("structured status does not bind the clean local HEAD")
        return fields

    state = status()
    run_id = state.get("run.id", "")
    if not re.fullmatch(r"[A-Za-z0-9_-]+", run_id):
        raise Refused("missing or invalid selected run identity")

    def registered_run():
        with closing(sqlite3.connect(database, uri=True, timeout=5)) as db:
            db.execute("BEGIN")
            repos = db.execute("SELECT id, working_path FROM repos").fetchall()
            matches = [(rid, path) for rid, path in repos if Path(path).resolve() == primary]
            if len(matches) != 1:
                raise Refused("no unambiguous registered repository for " + str(primary))
            rid = matches[0][0]
            if not re.fullmatch(r"[a-f0-9]{12}", rid):
                raise Refused("unrecognized gate repository identity")
            rows = db.execute("SELECT id, status FROM runs WHERE repo_id=? AND branch=? "
                              "ORDER BY created_at DESC, id DESC", (rid, branch)).fetchall()
        if not rows or rows[0][0] != run_id:
            raise Refused("selected status run differs from the newest registered branch run")
        if any(st not in ("completed", "failed", "cancelled") for _, st in rows):
            raise Refused("branch has an active or unknown registered run; reattach instead")
        if state.get("run.status") != rows[0][1]:
            raise Refused("run status disagrees with registered terminal state")
        return nm_home / "repos" / (rid + ".git")

    if state.get("run.status") in ("pending", "running", "fixing", "ci"):
        print("action: reattach_active_run\nrun: " + run_id)
        return
    gate_dir = registered_run().resolve(strict=True)
    if state.get("branch_sync.state") not in ("custody_returned", "user_owned"):
        raise Refused("custody is not returned; follow installed axi sync guidance first")
    if state.get("branch_sync.next_action.code") in ("recover_custody", "continue_active_run"):
        raise Refused("run still owns custody; follow installed axi sync guidance first")
    if state.get("branch_sync.pipeline.run") != run_id:
        raise Refused("branch synchronization names a different run")
    if Path(git("config", "--get", "remote.no-mistakes.url")).resolve() != gate_dir:
        raise Refused("no-mistakes remote differs from the registered local gate")
    if git("rev-parse", "--is-bare-repository", gate=True) != "true":
        raise Refused("registered gate is not bare")
    if (gate_dir / "shallow").exists() or (gate_dir / "info/grafts").exists():
        raise Refused("gate history is shallow or grafted")
    ref = "refs/heads/" + branch
    if git("symbolic-ref", "--quiet", ref, gate=True, allowed=(0, 1)):
        raise Refused("task gate ref is symbolic; refusing to follow it")
    old = git("rev-parse", "--verify", "--quiet", ref, gate=True, allowed=(0, 1))
    if not old:
        print("action: retry_pipeline\nchanged: false\nreason: task gate ref already absent")
        return
    # Read gate objects through an alternate, without fetching into the gate.
    git("cat-file", "-e", old + "^{commit}", alternate=True)
    stale = git("rev-list", old, "--not", head, alternate=True).splitlines()
    if not stale:
        print("action: retry_pipeline\nchanged: false\nreason: gate head is already in local history")
        return
    unique = []
    equivalents = {line.split()[1] for line in git("-c", "patchid.stable=true", "cherry", head, old, alternate=True).splitlines()
                   if line.startswith("- ")}
    for sha in stale:
        parents = git("rev-list", "--parents", "-n", "1", sha, alternate=True).split()[1:]
        if len(parents) != 1 or sha not in equivalents:
            subject = git("show", "-s", "--format=%s", sha, alternate=True)
            unique.append(sha + " " + subject)
    if unique:
        raise Refused("gate commits without a patch-ID preservation proof:\n" + "\n".join(unique))
    # Require explicit attribution before deletion. Never infer the owning home
    # from the project checkout or derive the task id from its branch spelling.
    if not args.home or not args.task or args.task.startswith(".") or not re.fullmatch(r"[A-Za-z0-9._-]+", args.task):
        raise Refused("deletion reporting requires FM_HOME and FM_TASK_ID, or --home and --task")
    home = Path(args.home).resolve(strict=True)
    if not home.is_dir() or not publisher.is_file():
        raise Refused("owning home or parent-channel publisher is unavailable")
    state_dir = Path(os.environ.get("FM_STATE_OVERRIDE") or home / "state").resolve()
    anchor = "refs/no-mistakes/recover-local/" + run_id + "-" + old
    # Fetch objects only, then use a create-only ref guard in the task repo.
    git("fetch", "--no-tags", "--no-write-fetch-head", str(gate_dir), old)
    existing = git("rev-parse", "--verify", "--quiet", anchor, allowed=(0, 1))
    if existing and existing != old:
        raise Refused("local recovery anchor unexpectedly names another commit: " + anchor)
    check_local()
    transaction = "start\noption no-deref\nverify refs/heads/%s %s\n" % (branch, head)
    transaction += ("verify %s %s\n" if existing else "create %s %s\n") % (anchor, old)
    git("update-ref", "--stdin", data=transaction + "prepare\ncommit\n")
    fresh = status()
    identity_keys = ("run.id", "run.branch", "run.status", "branch_sync.state",
                     "branch_sync.next_action.code", "branch_sync.pipeline.run",
                     "branch_sync.pipeline.current_head", "branch_sync.pipeline.submitted_head")
    if (any(fresh.get(key) != state.get(key) for key in identity_keys)
            or registered_run().resolve() != gate_dir):
        raise Refused("run changed during proof; preserved anchor, left gate untouched")
    check_local()
    git("update-ref", "--no-deref", "-d", ref, old, gate=True)
    print("action: retry_pipeline\nchanged: true\nrun: %s\nbranch: %s\nanchor: %s\n"
          "reason: stale gate head preserved; all gate-only patches occur in local history" %
          (run_id, branch, anchor))
    # The deletion has happened. Always show that outcome, even if delivery
    # fails, and retain the local event independently of parent delivery.
    sys.stdout.flush()
    event = "nm-recover-" + uuid.uuid4().hex
    line = "note [key=%s]: no-mistakes gate ref removed %s" % (event, json.dumps({
        "home": str(home), "task": args.task, "ref": ref, "old_head": old,
        "run": run_id, "anchor": anchor}, ensure_ascii=True))
    try:
        report = subprocess.run(["bash", "-c", r'''
set -u
# shellcheck source=bin/fm-parent-channel-lib.sh
. "$1" || exit 3
report_home=$2 report_state=$3 report_task=$4
line=$(status_stamp_line "$5")
local_rc=0 parent_rc=0
fm_parent_channel_append_once "$report_state/$report_task.status" "$line" || local_rc=$?
fm_parent_channel_report "$report_home" "$report_state" "$line" || parent_rc=$?
if [ "$local_rc" -eq 0 ]; then
  printf 'local_record: %s\n' "$report_state/$report_task.status"
else
  echo 'local_record: failed'
fi
case "$parent_rc" in
  0) echo 'parent_report: delivered' ;;
  1) echo 'parent_report: not_applicable_primary_home' ;;
  *)
    printf 'parent_report: failed\nparent_report_code: %s\n' "$parent_rc"
    failure="note: recovery deletion already completed; parent report failed (rc=$parent_rc): $line"
    printf '%s\n' "$failure" >&2
    fm_parent_channel_append_once "$report_state/$report_task.status" "$(status_stamp_line "$failure")" || local_rc=$?
    ;;
esac
if [ "$local_rc" -ne 0 ]; then
  echo 'recovery deletion already completed; local recovery record failed' >&2
fi
[ "$local_rc" -eq 0 ] && [ "$parent_rc" -le 1 ]
''', "fm-nm-recover-report", str(publisher), str(home), str(state_dir), args.task, line],
            cwd=wt, env=env, text=True, capture_output=True, timeout=30)
    except (OSError, subprocess.TimeoutExpired) as error:
        raise ReportFailed("deletion already completed; report could not finish: " + str(error))
    if report.stdout:
        print(report.stdout, end="")
    if report.stderr:
        print(report.stderr, end="", file=sys.stderr)
    if report.returncode:
        raise ReportFailed("deletion already completed; reporting failed (exit %s)" % report.returncode)


try:
    recover()
except ReportFailed as error:
    print("report: failed\nreason: " + str(error), file=sys.stderr)
    sys.exit(3)
except (Refused, OSError, TypeError, ValueError, sqlite3.Error, subprocess.TimeoutExpired) as error:
    print("action: refused\nreason: " + str(error), file=sys.stderr)
    sys.exit(1)
PY
