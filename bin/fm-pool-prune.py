#!/usr/bin/env python3
"""Idle-pool decisions. Invoked under the Firstmate project lock by the shell owner."""

import argparse
import json
from pathlib import Path
import re
import subprocess
import sys


def run(*args, cwd=None, timeout=60):
    return subprocess.check_output(args, cwd=cwd, text=True, stderr=subprocess.PIPE,
                                   timeout=timeout).strip()


def git(path, *args):
    return run("git", "--no-optional-locks", "-C", str(path), *args)


def cap_for(config, project):
    value = {"default": 2, "projects": {}}
    if config.exists() or config.is_symlink():
        if config.is_symlink() or not config.is_file():
            raise ValueError("unsafe idle-cap configuration")
        def unique(pairs):
            result = {}
            for key, item in pairs:
                if key in result:
                    raise ValueError("duplicate idle-cap key: " + key)
                result[key] = item
            return result
        value = json.loads(config.read_text(), object_pairs_hook=unique)
    if (not isinstance(value, dict) or set(value) != {"default", "projects"}
            or not isinstance(value["projects"], dict)):
        raise ValueError("idle cap requires default and projects")
    caps = [value["default"], *value["projects"].values()]
    if any(type(cap) is not int or not 0 <= cap <= 999999 for cap in caps):
        raise ValueError("idle caps must be integers between 0 and 999999")
    if any(not name or "/" in name for name in value["projects"]):
        raise ValueError("idle-cap project names must be directory basenames")
    return value["projects"].get(project.name, value["default"])


def task_copies(states):
    copies = set()
    for state in states:
        if state.is_symlink() or not state.is_dir():
            raise ValueError("cannot inspect task state: " + str(state))
        for meta in state.iterdir():
            if not meta.name.endswith(".meta"):
                continue
            if meta.is_symlink() or not meta.is_file():
                raise ValueError("unsafe task record: " + str(meta))
            for line in meta.read_text().splitlines():
                if line.startswith("worktree=") and line[9:]:
                    path = Path(line[9:])
                    if not path.is_absolute():
                        raise ValueError("relative task worktree: " + str(meta))
                    copies.add(path.resolve())
    return copies


def inventory(project):
    rows = json.loads(run("treehouse", "status", "--json", cwd=project))
    if not isinstance(rows, list):
        raise ValueError("invalid Treehouse inventory")
    paths = set()
    for row in rows:
        if (not isinstance(row, dict) or not isinstance(row.get("path"), str)
                or not Path(row["path"]).is_absolute() or not isinstance(row.get("status"), str)
                or not isinstance(row.get("processes"), list)
                or not isinstance(row.get("lease_id"), str)):
            raise ValueError("incomplete Treehouse inventory")
        path = Path(row["path"])
        if path.is_symlink() or not path.is_dir() or path.resolve() in paths:
            raise ValueError("unsafe or duplicate Treehouse path: " + str(path))
        paths.add(path.resolve())
    return rows


def publication(path):
    remote = {}
    for line in git(path, "ls-remote", "--heads", "origin").splitlines():
        sha, ref = line.split()
        remote[ref] = sha
    if not remote:
        raise ValueError("origin has no verifiable heads")
    head = git(path, "rev-parse", "HEAD")
    ref = git(path, "rev-parse", "--symbolic-full-name", "HEAD")
    if ref != "HEAD" and remote.get(ref) != head:
        raise ValueError("checked-out branch is not published on origin: " + ref)
    for sha in set(remote.values()):
        if head == sha:
            return
        result = subprocess.run(["git", "-C", str(path), "merge-base", "--is-ancestor", head, sha],
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=60)
        if result.returncode == 0:
            return
    raise ValueError("HEAD is not published on origin")


def activity(row):
    if row["lease_id"] or row.get("lease_holder") or row.get("leased_at") or row["status"] == "leased":
        return "leased"
    if row["processes"] or row["status"] in ("in-use", "you're here"):
        return "in use"
    return ""


def refusal(row, project, copies):
    path = Path(row["path"])
    reason = activity(row)
    if reason:
        return reason
    marker = path.parent / ".fm-slot-owner"
    if marker.exists() or marker.is_symlink():
        return "Firstmate slot claim exists"
    if path.resolve() in copies:
        return "recorded Firstmate task copy"
    if row["status"] != "available":
        return "Treehouse status " + row["status"]
    if (row.get("branch_error") or row.get("recovery_reason")
            or row.get("flavor") not in (None, "git")):
        return "unverified Git copy"
    if path.resolve() == project:
        return "project primary checkout"
    common = Path(git(path, "rev-parse", "--path-format=absolute", "--git-common-dir")).resolve()
    if common != Path(git(project, "rev-parse", "--path-format=absolute", "--git-common-dir")).resolve():
        return "different Git common directory"
    if git(path, "status", "--porcelain=v1", "--untracked-files=all", "--ignore-submodules=none"):
        return "uncommitted changes"
    publication(path)
    return ""


def allocated(path):
    return int(run("du", "-sk", str(path)).split()[0]) * 1024


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project", type=Path, required=True)
    parser.add_argument("--config", type=Path, required=True)
    parser.add_argument("--state-dirs", type=Path, nargs="+", required=True)
    parser.add_argument("--apply", action="store_true")
    parser.add_argument("--limit", type=int)
    parser.add_argument("--no-measure", action="store_true")
    args = parser.parse_args()
    project = args.project.resolve()
    cap = cap_for(args.config, project)
    version = re.fullmatch(r"v?(\d+)\.(\d+)\.(\d+)", run("treehouse", "--version"))
    if not version or tuple(map(int, version.groups())) < (3, 1, 3):
        raise ValueError("safe exact-target destroy requires Treehouse >=3.1.3")
    rows = inventory(project)
    copies = task_copies(args.state_dirs)
    idle = [row for row in rows if not activity(row)]
    excess = max(0, len(idle) - cap)
    report = dict(project=project.name, cap=cap, idle_before=len(idle), dry_run=not args.apply,
                  copies_pruned=0, bytes_reclaimed=0, copies_would_prune=0,
                  bytes_would_reclaim=0, inspection_errors=0, copies=[])
    selected = 0
    for row in sorted(rows, key=lambda item: item["path"]):
        decision = dict(path=row["path"], decision="keep")
        report["copies"].append(decision)
        if excess == 0 or selected == args.limit:
            continue
        try:
            reason = refusal(row, project, copies)
            if reason:
                decision.update(decision="refuse", reason=reason)
                continue
            path = Path(row["path"])
            size = 0 if args.no_measure else allocated(path)
            run("treehouse", "destroy", str(path), cwd=project)
            if args.apply:
                # Re-read both ownership planes after the provider preview.
                fresh = {item["path"]: item for item in inventory(project)}
                if str(path) not in fresh:
                    raise ValueError("copy disappeared from Treehouse inventory")
                reason = refusal(fresh[str(path)], project, task_copies(args.state_dirs))
                if reason:
                    raise ValueError(reason)
                run("treehouse", "destroy", str(path), "--yes", cwd=project, timeout=None)
                if path.exists():
                    raise ValueError("Treehouse left the copy present")
                report["copies_pruned"] += 1
                report["bytes_reclaimed"] += size
            else:
                report["copies_would_prune"] += 1
                report["bytes_would_reclaim"] += size
            decision.update(decision="pruned" if args.apply else "would-prune", allocated_bytes=size)
            excess -= 1
            selected += 1
        except (ValueError, OSError, subprocess.SubprocessError) as error:
            report["inspection_errors"] += 1
            decision.update(decision="refuse", reason=str(error))
    report["idle_after"] = len(idle) - report["copies_pruned"]
    report["unmet_cap"] = excess
    print(json.dumps(report))
    if excess and selected == args.limit:
        return 3
    return 1 if excess or report["inspection_errors"] else 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        print("pool prune: " + str(error), file=sys.stderr)
        sys.exit(1)
