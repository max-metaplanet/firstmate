#!/usr/bin/env bash
# Recover a terminal run's stale private mirror without rewriting task history.
# Usage: fm-nm-recover.sh <task-worktree> <exact-branch>
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
# Retry the original run/rerun command after action: retry_pipeline. Repeated
# invocation after deletion is a no-op. Unknown schemas or unsafe states fail
# closed. Python 3 (stdlib sqlite3), Git, and no-mistakes are required.
set -euo pipefail
if [ "${1:-}" = --help ]; then
  sed -n '2,/^set -/p' "$0" | sed '$d; s/^# *//'
  exit 0
fi
if [ "$#" -ne 2 ]; then
  echo "usage: fm-nm-recover.sh <task-worktree> <exact-branch>" >&2
  exit 2
fi
exec python3 - "$@" <<'PY'
import json
import os
from pathlib import Path
import re
import sqlite3
import subprocess
import sys
from contextlib import closing


class Refused(Exception):
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
    wt, branch = Path(sys.argv[1]).resolve(strict=True), sys.argv[2]
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


try:
    recover()
except (Refused, OSError, TypeError, ValueError, sqlite3.Error, subprocess.TimeoutExpired) as error:
    print("action: refused\nreason: " + str(error), file=sys.stderr)
    sys.exit(1)
PY
