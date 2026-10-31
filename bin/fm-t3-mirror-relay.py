#!/usr/bin/env python3
"""Deterministic ACP presentation provider. No tools, model calls, or commands.

Register this executable as a local ACP Registry provider in T3, with no args.
Accepts newline-delimited JSON-RPC on stdin/stdout. Only session/prompt with one
fm-t3-mirror.v1 JSON update renders a status, including T3's user_request wrapper.
Other prompt text receives a presentation-only notice. Nothing becomes a steer.
"""

import json
import re
import sys
import uuid


NOTICE = "Presentation only. Send instructions through Firstmate. Nothing typed here is executed.\n"
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


def render(prompt):
    """Render only the bounded status vocabulary, never free-form instructions."""
    try:
        if not isinstance(prompt, list) or any(not isinstance(block, dict) for block in prompt):
            return NOTICE
        candidates = []
        for block in prompt:
            if block.get("type") != "text":
                continue
            text = block.get("text", "")
            if text.startswith("<t3_code_instructions>") and text.endswith("\n</user_request>"):
                _, separator, text = text.rpartition("\n<user_request>\n")
                if not separator:
                    continue
                text = text[:-len("\n</user_request>")]
            try:
                value = json.loads(text)
            except ValueError:
                continue
            if isinstance(value, dict) and value.get("schema") == "fm-t3-mirror.v1":
                candidates.append(value)
        if len(candidates) != 1:
            return NOTICE
        update = candidates[0]
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
        lines.append(f"Observed: {stamp}")
        return "\n\n".join(lines) + "\n"
    except (KeyError, TypeError, ValueError):
        return NOTICE


def serve():
    sessions = set()

    def emit(value):
        print(json.dumps({"jsonrpc": "2.0", **value}), flush=True)

    for line in sys.stdin:
        request = None
        try:
            if len(line) > 16384:
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
                          "agentInfo": {"name": "firstmate-mirror", "version": "1.0.0"}, "authMethods": []}
            elif method in {"session/new", "session/load"}:
                session = str(uuid.uuid4()) if method == "session/new" else params.get("sessionId")
                if not isinstance(session, str) or not session:
                    raise ValueError("invalid session")
                sessions.add(session)
                result = {"models": {"currentModelId": "mirror", "availableModels": [MODEL]}}
                if method == "session/new":
                    result["sessionId"] = session
            elif method == "session/prompt" and params.get("sessionId") in sessions:
                text = render(params.get("prompt", []))
                emit({"method": "session/update", "params": {"sessionId": params["sessionId"],
                      "update": {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": text}}}})
                result = {"stopReason": "end_turn"}
            elif method == "session/set_model" and params.get("modelId") == "mirror":
                result = {}
            else:
                emit({"id": request["id"], "error": {"code": -32601, "message": "Unsupported presentation method"}})
                continue
            emit({"id": request["id"], "result": result})
        except (ValueError, TypeError):
            emit({"id": request.get("id") if isinstance(request, dict) else None,
                  "error": {"code": -32602, "message": "Invalid mirror request"}})


if __name__ == "__main__":
    serve()
