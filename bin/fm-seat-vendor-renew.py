#!/usr/bin/env python3
"""Run the vendor-owned token-free refresh primitive under the caller's lease.

Usage: fm-seat-vendor-renew.py --provider claude|codex --profile ABS
Claude alone accepts an empty profile for its ordinary ambient Keychain store.
The caller owns expiry, live-owner checks, canonical identity, the exclusive
seat lock, and the post-refresh quota verdict. This internal adapter performs
none of those checks and must not be offered as an unguarded panel action.

Claude uses its noninteractive doctor startup; Codex uses only initialize,
initialized, and account/read(refreshToken=true). No login or model request is
sent. Child output is consumed privately and never returned. stdout contains a
non-secret completion JSON; exit 0 means the primitive returned successfully,
not that credentials are fresh (the caller must verify that separately).

There is deliberately no killing timeout. SIGINT/SIGTERM/SIGHUP are deferred
until the vendor exits, and its separate process group isolates terminal or
watcher cancellation. The caller must likewise retain its lock until this
process exits. FM_SEAT_LOCK_FD passes the caller's open lock descriptor through
to the vendor, so killing a coordinator does not release its lock while the
vendor remains alive. The started stderr event also reports the child PID.
"""

import argparse
import json
import os
from pathlib import Path
import queue
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time


def emit(value, stream=sys.stdout):
    print(json.dumps(value, separators=(",", ":")), file=stream, flush=True)


def vendor_environment(provider, profile):
    env = os.environ.copy()
    # An explicit seat must never be answered by an inherited token, host auth
    # snapshot, API key, alternative store, or third-party provider selector.
    exact = {
        "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL",
        "OPENAI_API_KEY", "CODEX_API_KEY", "CODEX_ACCESS_TOKEN",
        "OPENAI_BASE_URL", "CODEX_REFRESH_TOKEN_URL_OVERRIDE",
        "CODEX_APP_SERVER_LOGIN_CLIENT_ID", "CLAUDE_CODE_CUSTOM_OAUTH_URL",
        "USE_LOCAL_OAUTH", "USE_STAGING_OAUTH",
        "CLAUDE_CONFIG_DIR", "CLAUDE_SECURESTORAGE_CONFIG_DIR", "CODEX_HOME",
        "CLAUDECODE", "CLAUDE_CODE_SIMPLE", "CLAUDE_BG_AUTH_SNAPSHOT_PATH",
        "CLAUDE_SESSION_INGRESS_TOKEN_FILE", "CLAUDE_TRUSTED_DEVICE_TOKEN",
    }
    prefixes = (
        "CLAUDE_CODE_OAUTH_", "CLAUDE_CODE_API_KEY_", "CLAUDE_CODE_HOST_",
        "CLAUDE_CODE_SESSION_", "CLAUDE_CODE_REMOTE", "CLAUDE_CODE_USE_",
        "CLAUDE_CODE_GATEWAY_", "CLAUDE_CODE_WEBSOCKET_AUTH_",
        "CLAUDE_LOCAL_OAUTH_",
    )
    for key in list(env):
        if key in exact or key.startswith(prefixes):
            env.pop(key, None)
    env.update(NO_COLOR="1", TERM="dumb", NO_BROWSER="1", NO_OPEN_BROWSER="1",
               DISABLE_AUTOUPDATER="1")
    if provider == "claude":
        # Unset and explicit ~/.claude identify different macOS Keychain stores.
        if profile:
            env["CLAUDE_CONFIG_DIR"] = profile
            env["CLAUDE_SECURESTORAGE_CONFIG_DIR"] = profile
        env["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] = "1"
    else:
        env["CODEX_HOME"] = profile
    return env


class Vendor:
    def __init__(self, args, env, cwd):
        pass_fds = ()
        if "FM_SEAT_LOCK_FD" in os.environ:
            raw_fd = os.environ["FM_SEAT_LOCK_FD"]
            if not raw_fd.isdecimal() or int(raw_fd) < 3:
                raise OSError("invalid seat lock descriptor")
            lock_fd = int(raw_fd)
            os.fstat(lock_fd)
            pass_fds = (lock_fd,)
        self.child = subprocess.Popen(args, env=env, cwd=cwd, stdin=subprocess.PIPE,
                                      stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                      start_new_session=True, text=True, encoding="utf-8",
                                      errors="replace", bufsize=1, pass_fds=pass_fds)
        self.messages = queue.Queue()
        self.pending_reported = False
        self.started = time.monotonic()
        threading.Thread(target=self.read, daemon=True).start()
        emit({"status": "started", "pid": self.child.pid}, sys.stderr)

    def read(self):
        for line in self.child.stdout:
            try:
                message = json.loads(line)
            except (ValueError, TypeError):
                continue
            if isinstance(message, dict) and "id" in message:
                self.messages.put(message)
        self.messages.put(None)

    def notice(self):
        if not self.pending_reported and time.monotonic() - self.started >= 45:
            emit({"status": "pending", "pid": self.child.pid,
                  "reason": "vendor still running; retain seat lock"}, sys.stderr)
            self.pending_reported = True

    def send(self, message):
        self.child.stdin.write(json.dumps(message) + "\n")
        self.child.stdin.flush()

    def response(self, request_id):
        while True:
            try:
                message = self.messages.get(timeout=0.2)
            except queue.Empty:
                self.notice()
                continue
            if message is None:
                raise RuntimeError("vendor closed protocol before responding")
            if message.get("id") == request_id:
                if "error" in message or "result" not in message:
                    raise RuntimeError("vendor refused refresh protocol")
                return

    def finish(self):
        try:
            self.child.stdin.close()
        except (BrokenPipeError, OSError):
            pass
        while True:
            try:
                return self.child.wait(timeout=0.2)
            except subprocess.TimeoutExpired:
                self.notice()


def run(provider, profile):
    executable = shutil.which(provider)
    if not executable:
        emit({"status": "unavailable", "reason": "vendor executable missing"})
        return 2
    # Our pipeline wrapper chooses its own seat and can therefore redirect this
    # request. Inspect its identifying header before any vendor execution.
    with open(executable, "rb") as candidate:
        header = candidate.read(65536)
    if b"FM_PIPELINE_TOOL=" in header:
        emit({"status": "unavailable",
              "reason": "managed pipeline wrapper cannot select renewal credentials; use native vendor executable"})
        return 2
    # Retain scratch material for diagnosis; never put it inside a live profile.
    cwd = tempfile.mkdtemp(prefix="fm-seat-vendor-renew-")
    args = ([executable, "--safe-mode", "doctor"] if provider == "claude" else
            [executable, "app-server", "--listen", "stdio://"])
    vendor = Vendor(args, vendor_environment(provider, profile), cwd)
    protocol_ok = True
    if provider == "codex":
        try:
            vendor.send({"id": 1, "method": "initialize", "params": {
                "clientInfo": {"name": "firstmate-seat-renewal", "version": "1"}}})
            vendor.response(1)
            vendor.send({"method": "initialized"})
            vendor.send({"id": 2, "method": "account/read",
                         "params": {"refreshToken": True}})
            vendor.response(2)
        except (RuntimeError, OSError):
            protocol_ok = False
    code = vendor.finish()
    ok = protocol_ok and code == 0
    emit({"status": "completed" if ok else "failed", "provider": provider,
          "pid": vendor.child.pid, "exitCode": code, "protocolSuccess": protocol_ok})
    return 0 if ok else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--provider", choices=("claude", "codex"), required=True)
    parser.add_argument("--profile", required=True)
    args = parser.parse_args()
    ambient_claude = args.provider == "claude" and args.profile == ""
    if not ambient_claude and (not Path(args.profile).is_absolute() or
                              not Path(args.profile).is_dir()):
        parser.error("--profile must be an existing absolute directory (or empty for ordinary Claude)")
    for signum in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(signum, lambda _signum, _frame: None)
    try:
        return run(args.provider, args.profile)
    except OSError:
        emit({"status": "unavailable", "reason": "vendor launch failed"})
        return 2


if __name__ == "__main__":
    sys.exit(main())
