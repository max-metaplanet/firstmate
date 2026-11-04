#!/usr/bin/env python3
"""Best-effort mirror publisher; fm-t3-mirrors.sh owns the public contract."""

import datetime
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import sys
import time
import uuid

# Import the shared presentation vocabulary without starting the ACP server.
import importlib.util

sys.dont_write_bytecode = True
SPEC = importlib.util.spec_from_file_location("mirror_relay", Path(__file__).with_name("fm-t3-mirror-relay.py"))
RELAY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(RELAY)


IDENTITY = RELAY.IDENTITY
MirrorError = IDENTITY.MirrorError
read_json = IDENTITY.read_json
write_json = IDENTITY.write_json
run = IDENTITY.run
SPEC = importlib.util.spec_from_file_location("mirror_redact", Path(__file__).with_name("fm-t3-redact.py"))
REDACT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(REDACT)


class Publisher:
    def __init__(self, home, state, config):
        self.home = str(home.resolve())
        self.state = state.resolve()
        self.config = config.resolve()
        self.root = self.state / "t3-mirrors"
        if self.root.is_symlink():
            raise MirrorError("symlinked-mirror-directory")
        self.root.mkdir(mode=0o700, exist_ok=True)
        self.records = self.root / "tasks"
        if self.records.is_symlink():
            raise MirrorError("symlinked-mirror-directory")
        self.records.mkdir(mode=0o700, exist_ok=True)
        self.connection = None

    def log(self, error, task="home"):
        # Never include exception strings, command output, status prose, or auth.
        stamp = datetime.datetime.now(datetime.timezone.utc).isoformat()
        path = self.root / "errors.log"
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_APPEND | os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd, "w") as stream:
            stream.write(f"{stamp} {task} {error}\n")

    def bind(self):
        path = self.root / "connection.json"
        if path.exists():
            connection = read_json(path)
        else:
            base = os.environ.get("FM_T3_BASE_DIR")
            binary = shutil.which(os.environ.get("FM_T3_BIN", "t3"))
            if not base or not Path(base).is_dir() or not binary:
                raise MirrorError("t3-connection-unavailable")
            provider_file = self.config / "t3-mirror-provider"
            provider = provider_file.read_text().strip() if provider_file.exists() else "acpRegistry_firstmate_mirror"
            connection = {"version": 1, "home": self.home, "base": str(Path(base).resolve()),
                          "binary": os.path.abspath(binary), "provider": provider}
            write_json(path, connection)
        if (connection.get("version") != 1 or connection.get("home") != self.home
                or not all(isinstance(connection.get(key), str) and connection[key].startswith("/")
                           for key in ("base", "binary"))
                or not isinstance(connection.get("provider"), str)
                or not re.fullmatch(r"acpRegistry_[A-Za-z0-9_-]+", connection["provider"])):
            raise MirrorError("invalid-connection")
        self.connection = connection

    def t3(self, *args, text=None):
        return run([self.connection["binary"], *args, "--base-dir", self.connection["base"]], text)

    def project(self, record):
        workspace = Path(record["workspace"])
        workspace.mkdir(mode=0o700, parents=True, exist_ok=True)
        if workspace.resolve() != workspace:
            raise MirrorError("symlinked-presentation-workspace")
        code, out, err = self.t3("project", "add", str(workspace), "--title", record["title"])
        if code and not ("ProjectAlreadyExistsError" in out + err
                         and f"An active project already exists for '{workspace}'" in out + err):
            raise MirrorError("project-unavailable")

    def observe(self, task, metadata):
        env = dict(os.environ, FM_HOME=self.home, FM_STATE_OVERRIDE=str(self.state),
                   FM_CONFIG_OVERRIDE=str(self.config), FM_CREW_STATE_NO_FORGE="1", FM_PEEK_NO_GUARD="1")
        try:
            code, out, _ = run(["bash", str(Path(__file__).with_name("fm-crew-state.sh")), task], env=env)
        except MirrorError:
            code, out = 1, ""
        raw = out.splitlines()[0] if out.splitlines() and not code else ""
        match = re.fullmatch(r"state: ([a-z-]+) · source: [^\n]+? · (.*)", raw)
        state = match[1] if match and match[1] in RELAY.STATES else "unreadable"
        detail = match[2] if match else ""
        phase_match = re.search(r"^(?:parked at |step[=: ]+)?([a-z-]+)(?:\b|$)", detail)
        phase = phase_match[1] if phase_match and phase_match[1] in RELAY.PHASES else None
        # Status prose and crew detail are untrusted and can contain credentials.
        # Project only enum values and canonical public PR URLs, never raw text.
        status = self.state / f"{task}.status"
        event = None
        url = None
        if status.is_file() and not status.is_symlink():
            with status.open("rb") as stream:
                stream.seek(max(0, status.stat().st_size - 32768))
                lines = stream.read().decode("utf-8", errors="replace").splitlines()
            for line in reversed(lines):
                if event is None:
                    event_match = re.match(r"([a-z-]+)(?:\s+\[[^\]\n]*\])*:", line)
                    if event_match and event_match[1] in RELAY.EVENTS:
                        event = event_match[1]
                if url is None:
                    found = re.search(r"https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/pull/[0-9]+(?=\s|$)", line)
                    if found:
                        url = found[0]
                if event and url:
                    break
        values = dict(line.split("=", 1) for line in metadata.splitlines() if "=" in line)
        try:
            code, capture, _ = run(["bash", str(Path(__file__).with_name("fm-peek.sh")), task, "80"], env=env)
            tail = REDACT.redact_lines(capture) if code == 0 else []
        except (OSError, MirrorError):
            tail = []
        return {"schema": "fm-t3-mirror.v2", "task": task, "tail": tail,
                "kind": "secondmate" if values.get("kind") == "secondmate" else "worker",
                "state": state, "phase": phase, "event": event, "pr": url}

    def save_task(self, path, record):
        write_json(path, record)

    def thread(self, record):
        return IDENTITY.verify(self.records / f"{record['task']}.json", record)

    def retire(self, path):
        record = read_json(path)
        if record.get("version") != 2:
            raise MirrorError("legacy-shared-project-preserved")
        # Revocation is durable before any fallible T3 operation.
        record["retired"] = True
        write_json(path, record)
        IDENTITY.verify(path, record, live_task=False)
        if record["phase"] == "setup":
            self.project(record)
            code, _, _ = self.t3("project", "remove", record["workspace"])
        else:
            code, _, _ = self.t3("project", "remove", record["projectId"], "--force")
        if code:
            raise MirrorError("cleanup-removal-unconfirmed")
        path.unlink()

    def confirm(self, path, record):
        update = record.get("pending_update")
        if not isinstance(update, dict):
            raise MirrorError("uncertain-send-inspect-t3")
        result = self.thread(record)
        prompt = record["pending_prompt"]
        expected = RELAY.render([{"type": "text", "text": prompt}])
        matching_prompt = False
        for message in result.get("messages", []):
            if message.get("role") == "user":
                matching_prompt = message.get("text") == prompt
            elif matching_prompt and message.get("role") == "assistant" and message.get("text") == expected:
                record.update(fingerprint=record["pending"], pending=None,
                              pending_update=None, pending_prompt=None, observed_at=update["observed_at"])
                self.save_task(path, record)
                return
        raise MirrorError("relay-reply-unconfirmed")

    def publish(self, task, metadata):
        path = self.records / f"{task}.json"
        incarnation = IDENTITY.task_identity(metadata)
        record = read_json(path) if path.exists() else None
        if record and (record.get("retired") or record.get("incarnation") != incarnation):
            self.retire(path)
            record = None
        update = self.observe(task, metadata)
        if (self.state / f"{task}.meta").read_text() != metadata:
            return
        # Leave room for JSON-RPC/T3 wrappers inside the ACP request bound.
        while len(RELAY.update_prompt(update).encode()) > 8000 and update["tail"]:
            update["tail"].pop(0)
        fingerprint = hashlib.sha256(json.dumps(update, sort_keys=True).encode()).hexdigest()
        if record and record.get("phase") != "setup":
            self.thread(record)
            if record.get("pending"):
                self.confirm(path, record)
            if record.get("fingerprint") == fingerprint:
                return
        update["observed_at"] = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        prompt = RELAY.update_prompt(update)
        if record is None:
            nonce = str(uuid.uuid4())
            workspace = self.root / "workspaces" / task / nonce
            record = {"version": 2, "home": self.home, "state": str(self.state), "config": str(self.config),
                      "task": task, "incarnation": incarnation, "connection": self.connection,
                      "nonce": nonce, "workspace": str(workspace), "phase": "setup",
                      "providerInstanceId": self.connection["provider"], "model": "mirror",
                      "pending": fingerprint, "pending_update": update, "pending_prompt": prompt}
            record["title"] = IDENTITY.title(record)
            self.save_task(path, record)
        if record["phase"] == "setup":
            IDENTITY.verify(path, record, live_task=False)
            self.project(record)
            IDENTITY.current_task(record)
            record.update(phase="creating", pending=fingerprint, pending_update=update, pending_prompt=prompt)
            self.save_task(path, record)
            code, out, _ = self.t3("thread", "start", record["workspace"], "-", "--title", record["title"],
                                   "--provider", self.connection["provider"], "--model", "mirror", "--json", text=prompt)
            if code:
                raise MirrorError("uncertain-creation-inspect-t3")
            result = json.loads(out)
            if not isinstance(result, dict) or not all(
                    isinstance(result.get(key), str) and result[key] for key in ("threadId", "projectId")):
                raise MirrorError("uncertain-creation-inspect-t3")
            record.update(threadId=result["threadId"], projectId=result["projectId"], phase="ready")
            self.save_task(path, record)
            self.confirm(path, record)
        else:
            record.update(pending=fingerprint, pending_update=update, pending_prompt=prompt)
            self.save_task(path, record)
            self.thread(record)
            code, _, _ = self.t3("thread", "send", record["threadId"], "-", "--wait", "--json", text=prompt)
            if code:
                raise MirrorError("uncertain-send-inspect-t3")
            self.confirm(path, record)
        self.save_task(path, record)

    def sync(self):
        self.bind()
        deadline = time.monotonic() + 45
        for path in sorted(self.records.glob("*.json")):
            if time.monotonic() > deadline:
                self.log("pass-budget-exhausted")
                break
            if not (self.state / f"{path.stem}.meta").exists():
                try:
                    self.retire(path)
                except (MirrorError, OSError, ValueError, TypeError, KeyError) as error:
                    self.log(str(error) if isinstance(error, MirrorError) else "cleanup-unavailable", path.stem)
        metas = sorted(self.state.glob("*.meta"))
        cursor = self.root / "cursor.json"
        last = read_json(cursor).get("task", "") if cursor.exists() else ""
        metas = [meta for meta in metas if meta.stem > last] + [meta for meta in metas if meta.stem <= last]
        for meta in metas:
            task = meta.stem
            if not RELAY.TASK_ID.fullmatch(task) or meta.is_symlink():
                continue
            if time.monotonic() > deadline:
                self.log("pass-budget-exhausted")
                break
            try:
                self.publish(task, meta.read_text())
            except MirrorError as error:
                self.log(str(error), task)
            except (OSError, ValueError, TypeError, KeyError):
                self.log("invalid-or-unavailable-task-record", task)
            write_json(cursor, {"task": task})


def main():
    command, home, state, config = sys.argv[1:5]
    os.umask(0o077)
    publisher = Publisher(Path(home), Path(state), Path(config))
    lock_path = publisher.root / "publisher.lock"
    fd = os.open(lock_path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "w") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return
        if command == "retire":
            task = sys.argv[5]
            if RELAY.TASK_ID.fullmatch(task) and not (publisher.state / f"{task}.meta").exists():
                path = publisher.records / f"{task}.json"
                if path.exists():
                    try:
                        publisher.bind()
                        publisher.retire(path)
                    except MirrorError as error:
                        publisher.log(str(error), task)
            return
        try:
            publisher.sync()
        except MirrorError as error:
            publisher.log(str(error))
        except (OSError, ValueError, TypeError):
            publisher.log("unavailable-mirror-records")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, MirrorError):
        print("T3 mirrors: unavailable; supervision continues", file=sys.stderr)
