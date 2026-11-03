#!/usr/bin/env python3
"""Shared mirror identity boundary for publication, steering and retirement."""

import json
import os
from pathlib import Path
import re
import signal
import subprocess

TASK_ID = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}\Z")
THREAD_KEYS = ("threadId", "projectId", "title", "providerInstanceId", "model")
BINDING_KEYS = (*THREAD_KEYS, "home", "state", "config", "task", "nonce", "workspace", "incarnation", "connection")


class MirrorError(Exception):
    pass


def read_json(path):
    if path.is_symlink():
        raise MirrorError("symlinked-record")
    value = json.loads(path.read_text())
    if not isinstance(value, dict):
        raise MirrorError("invalid-record")
    return value


def write_json(path, value):
    if path.is_symlink():
        raise MirrorError("symlinked-record")
    temporary = path.with_name(path.name + ".new")
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "w") as stream:
        json.dump(value, stream)
        stream.flush()
        os.fsync(stream.fileno())
    temporary.replace(path)


def run(args, text=None, env=None, timeout=6):
    process = subprocess.Popen(args, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, text=True, env=env, start_new_session=True)
    try:
        stdout, stderr = process.communicate(text, timeout=timeout)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        process.communicate()
        raise MirrorError("command-timeout") from None
    return process.returncode, stdout, stderr


def task_identity(metadata):
    values = {}
    for line in metadata.splitlines():
        key, separator, value = line.partition("=")
        if separator:
            if key in values:
                raise MirrorError("duplicate-task-field")
            values[key] = value
    generation = values.get("spawn_gen", "")
    host = values.get("remote_host", "")
    if host:
        if values.get("kind") != "secondmate" or generation:
            raise MirrorError("invalid-remote-identity")
        return {"remote_host": host}
    if not generation:
        raise MirrorError("missing-task-generation")
    return {"spawn_gen": generation}


def title(record):
    return f"Mirror · {record['task']} · {Path(record['home']).name} · {record['nonce']}"


def current_task(record):
    meta = Path(record["state"]) / f"{record['task']}.meta"
    if meta.is_symlink() or not meta.is_file():
        raise MirrorError("retired-task")
    if task_identity(meta.read_text()) != record["incarnation"]:
        raise MirrorError("task-incarnation-mismatch")


def record_for_workspace(workspace):
    """ACP new/load both carry cwd; the path locates the existing mapping."""
    cwd = Path(workspace)
    if not cwd.is_absolute() or cwd.resolve() != cwd or len(cwd.parents) < 4:
        raise MirrorError("invalid-workspace")
    root = cwd.parents[2]
    task = cwd.parent.name
    if root.name != "t3-mirrors" or cwd.parents[1].name != "workspaces" or not TASK_ID.fullmatch(task):
        raise MirrorError("invalid-workspace")
    path = root / "tasks" / f"{task}.json"
    record = read_json(path)
    if record.get("workspace") != str(cwd) or record.get("nonce") != cwd.name:
        raise MirrorError("workspace-binding-mismatch")
    return path, record


def verify(path, expected, live_task=True):
    """One identity check, used in both directions. No identity comes from text."""
    record = read_json(path)
    if (record.get("version") != 2 or record.get("phase") != "ready"
            or any(record.get(key) != expected.get(key) for key in BINDING_KEYS)
            or (live_task and record.get("retired"))):
        raise MirrorError("invalid-task-mapping")
    task = record.get("task")
    if not isinstance(task, str) or not TASK_ID.fullmatch(task):
        raise MirrorError("invalid-task-mapping")
    for key in ("home", "state", "config", "workspace"):
        value = record.get(key)
        if not isinstance(value, str) or not Path(value).is_absolute() or Path(value).resolve() != Path(value):
            raise MirrorError("invalid-task-mapping")
    root = Path(record["state"]) / "t3-mirrors"
    workspace = root / "workspaces" / task / record["nonce"]
    if (path != root / "tasks" / f"{task}.json" or workspace != Path(record["workspace"])
            or record["title"] != title(record)
            or not all(isinstance(record.get(key), str) and record[key] for key in THREAD_KEYS)):
        raise MirrorError("invalid-task-mapping")
    connection = read_json(root / "connection.json")
    if (connection != record["connection"] or connection.get("home") != record["home"]
            or record["providerInstanceId"] != connection.get("provider") or record["model"] != "mirror"):
        raise MirrorError("connection-identity-mismatch")
    if live_task:
        current_task(record)
    code, out, _ = run([connection["binary"], "thread", "show", record["threadId"],
                        "--messages", "10", "--json", "--base-dir", connection["base"]])
    if code:
        raise MirrorError("mirror-thread-unavailable")
    result = json.loads(out)
    thread = result.get("thread", {}) if isinstance(result, dict) else {}
    if not isinstance(thread, dict) or any(thread.get(key) != record[key] for key in THREAD_KEYS):
        raise MirrorError("mirror-thread-identity-mismatch")
    code, out, _ = run([connection["binary"], "thread", "list", "--project", record["projectId"],
                        "--json", "--base-dir", connection["base"]])
    if code:
        raise MirrorError("mirror-inventory-unavailable")
    inventory = json.loads(out)
    if (not isinstance(inventory, list) or len(inventory) != 1
            or not isinstance(inventory[0], dict)
            or (inventory[0].get("id") or inventory[0].get("threadId")) != record["threadId"]
            or inventory[0].get("projectId") != record["projectId"]):
        raise MirrorError("mirror-project-not-single-thread")
    if live_task:
        current_task(record)
    # A retire/remap during a CLI read also revokes the sampled binding.
    latest = read_json(path)
    if (any(latest.get(key) != record[key] for key in BINDING_KEYS)
            or (live_task and latest.get("retired"))):
        raise MirrorError("mapping-changed")
    return result
