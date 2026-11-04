#!/usr/bin/env python3
"""Deterministic ACP mirror. Render updates; route typed text only via fm-send.

Register as a local ACP Registry provider with no args and model mirror.
ACP cwd locates the existing task mapping on new/load, including after restart.
No model calls, shell evaluation, pane typing, or identity supplied by prompt text.
"""

import base64
import fcntl
import importlib.util
import json
import os
from pathlib import Path
import re
import sys
import uuid


sys.dont_write_bytecode = True
SPEC = importlib.util.spec_from_file_location("mirror_identity", Path(__file__).with_name("fm-t3-mirror-identity.py"))
IDENTITY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(IDENTITY)

NOTICE = "Presentation only. Send instructions through Firstmate. Nothing typed here is executed.\n"
REFUSED = "Steering refused. The mirror identity is unavailable or has changed. Ask Firstmate to reconcile it.\n"
UNCONFIRMED = "Steering delivery is unconfirmed. Do not resend; ask Firstmate to inspect the task inbox.\n"
MODEL = {"modelId": "mirror", "name": "Firstmate status (no AI)"}
STATES = {
    "working": ("Work is in progress.", "Firstmate will post the next meaningful change."),
    "parked": ("Waiting for a decision or review.", "Firstmate will handle the pending gate."),
    "done": ("The recorded work is ready.", "Firstmate will handle delivery and landing."),
    "blocked": ("Work is blocked.", "Firstmate will inspect the blocker."),
    "paused": ("Waiting for an external condition.", "Firstmate will check when the wait clears."),
    "failed": ("The recorded work failed.", "Firstmate will inspect the failure."),
    "quota-blocked": ("The worker is waiting for quota.", "Firstmate will handle account recovery."),
    "unreadable": ("Current state could not be established.", "Firstmate will reconcile the durable records."),
    "unknown": ("Current state is unknown.", "Firstmate will reconcile the durable records."),
}
PHASES = {"intent", "rebase", "review", "test", "document", "lint", "push", "pr", "ci"}
EVENTS = {"working", "needs-decision", "blocked", "paused", "done", "failed", "resolved"}
TASK_ID = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}\Z")
PR_URL = re.compile(r"https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/pull/[0-9]+\Z")


def update_prompt(update):
    """Compact transport stays inert even when a capture contains Markdown."""
    payload = base64.b64encode(json.dumps(update, separators=(",", ":"), ensure_ascii=False).encode()).decode()
    return f"Update · {update['state']} · {update['task']}\n\n[fm-t3-mirror]: # '{payload}'"


def select(prompt):
    if not isinstance(prompt, list) or any(not isinstance(block, dict) or block.get("type") != "text" for block in prompt):
        return None, None
    texts = [block.get("text") for block in prompt]
    if any(not isinstance(text, str) for text in texts):
        return None, None
    texts = [text for text in texts if not text.startswith("<runtime_info>")]
    wrapped = []
    for text in texts:
        if text.startswith("<t3_code_instructions>") and text.endswith("\n</user_request>"):
            _, found, body = text.rpartition("\n<user_request>\n")
            if found:
                wrapped.append(body[:-len("\n</user_request>")])
    if len(wrapped) == 1:
        text = wrapped[0]
    elif not wrapped and len(texts) == 1:
        text = texts[0]
    else:
        return None, None
    heading, separator, payload = text.partition("\n\n[fm-t3-mirror]: # '")
    if separator:
        try:
            update = json.loads(base64.b64decode(payload[:-1], validate=True)) if payload.endswith("'") else None
            if (not isinstance(update, dict) or update.get("schema") != "fm-t3-mirror.v2"
                    or heading != f"Update · {update.get('state')} · {update.get('task')}"):
                return None, None
            return update, None
        except (ValueError, TypeError):
            return None, None
    return None, text


def render(prompt):
    """Render only the bounded status vocabulary, never free-form instructions."""
    try:
        update, _ = select(prompt)
        if update is None:
            return NOTICE
        task = update["task"]
        state = update["state"]
        stamp = update["observed_at"]
        if not isinstance(task, str) or not TASK_ID.fullmatch(task) or state not in STATES:
            return NOTICE
        if not isinstance(stamp, str) or not re.fullmatch(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ", stamp):
            return NOTICE
        kind = "Secondmate" if update.get("kind") == "secondmate" else "Worker"
        outcome, action = STATES[state]
        lines = [f"{outcome} ({state})", f"{kind} · {task}"]
        phase = update.get("phase")
        if phase in PHASES:
            lines.append(f"Validation step: {phase}.")
        event = update.get("event")
        if event in EVENTS:
            lines.append(f"Last recorded event: {event} (historical).")
        lines.append(f"Next: {action}")
        url = update.get("pr")
        if isinstance(url, str) and PR_URL.fullmatch(url):
            lines.append(url)
        tail = update.get("tail", [])
        if isinstance(tail, list):
            safe = [re.sub(r"[\x00-\x1f\x7f-\x9f]", "", line).replace("`", "'")[:160]
                    for line in tail[-24:] if isinstance(line, str)]
            if safe:
                lines.append("Recent output (redacted):\n```\n" + "\n".join(safe) + "\n```")
        lines.append(f"Observed: {stamp}")
        return "\n\n".join(lines) + "\n"
    except (KeyError, TypeError, ValueError):
        return NOTICE


def steer(workspace, text):
    body = text.strip()
    # These prefixes select fm-send's typed-command/key planes rather than its inbox.
    if not body or len(body) > 4000 or body[0] in "/$-" or "\x00" in body:
        return "Steering refused. Send ordinary instruction text of at most 4000 characters.\n"
    try:
        path, record = IDENTITY.record_for_workspace(workspace)
        fd = os.open(path.parent.parent / "publisher.lock", os.O_RDWR | os.O_NOFOLLOW)
        with os.fdopen(fd, "w") as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                return "Mirror update in progress. Try the instruction again after it settles.\n"
            IDENTITY.verify(path, record)
            environment = {key: value for key, value in os.environ.items() if not key.startswith("FM_")}
            environment.update(FM_HOME=record["home"], FM_STATE_OVERRIDE=record["state"],
                               FM_CONFIG_OVERRIDE=record["config"])
            identity = record["incarnation"]
            if "remote_host" in identity:
                environment["FM_SEND_EXPECTED_REMOTE_HOST"] = identity["remote_host"]
            else:
                environment["FM_SEND_EXPECTED_SPAWN_GEN"] = identity["spawn_gen"]
            try:
                code, _, _ = IDENTITY.run(["bash", str(Path(__file__).with_name("fm-send.sh")),
                                            record["task"], body], env=environment, timeout=40)
            except (IDENTITY.MirrorError, OSError):
                return UNCONFIRMED
            return UNCONFIRMED if code else f"Instruction recorded for {record['task']} through fm-send.\n"
    except (IDENTITY.MirrorError, OSError, ValueError, TypeError, KeyError):
        return REFUSED


def serve():
    sessions = {}

    def emit(value):
        print(json.dumps({"jsonrpc": "2.0", **value}), flush=True)

    for line in sys.stdin:
        request = None
        try:
            if len(line) > 131072:
                raise ValueError("request too large")
            request = json.loads(line)
            if not isinstance(request, dict):
                raise ValueError("invalid request")
            method = request.get("method")
            params = request.get("params", {})
            if not isinstance(params, dict):
                raise ValueError("invalid parameters")
            if "id" not in request:
                continue
            if method == "initialize":
                result = {"protocolVersion": 1, "agentCapabilities": {"loadSession": True},
                          "agentInfo": {"name": "firstmate-mirror", "version": "2.0.0"}, "authMethods": []}
            elif method in {"session/new", "session/load"}:
                session = str(uuid.uuid4()) if method == "session/new" else params.get("sessionId")
                if not isinstance(session, str) or not session:
                    raise ValueError("invalid session")
                # cwd is supplied by ACP on both calls. Never recover from prompt text.
                cwd = params.get("cwd")
                sessions[session] = cwd if isinstance(cwd, str) else None
                result = {"models": {"currentModelId": "mirror", "availableModels": [MODEL]}}
                if method == "session/new":
                    result["sessionId"] = session
            elif method == "session/prompt" and params.get("sessionId") in sessions:
                prompt = params.get("prompt", [])
                update, typed = select(prompt)
                workspace = sessions[params["sessionId"]]
                text = render(prompt) if update is not None else (
                    steer(workspace, typed) if workspace and typed is not None else NOTICE)
                emit({"method": "session/update", "params": {"sessionId": params["sessionId"],
                      "update": {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": text}}}})
                result = {"stopReason": "end_turn"}
            elif method == "session/set_model" and params.get("modelId") == "mirror":
                result = {}
            else:
                emit({"id": request["id"], "error": {"code": -32601, "message": "Unsupported mirror method"}})
                continue
            emit({"id": request["id"], "result": result})
        except (ValueError, TypeError):
            emit({"id": request.get("id") if isinstance(request, dict) else None,
                  "error": {"code": -32602, "message": "Invalid mirror request"}})


if __name__ == "__main__":
    serve()
