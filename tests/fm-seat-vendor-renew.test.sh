#!/usr/bin/env bash
# Actual subprocess protocol, cancellation, and inherited lock regression.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
python3 - "$ROOT" <<'PY'
import fcntl
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time

root = Path(sys.argv[1])
scratch = Path(tempfile.mkdtemp(prefix="fm-seat-vendor-test-"))
bin_dir = scratch / "bin"
bin_dir.mkdir()
fixture = '''#!/usr/bin/env python3
import json, os, sys, time
from pathlib import Path
case=Path(os.environ["VENDOR_TEST_CASE"])
provider=Path(sys.argv[0]).name
assert "ANTHROPIC_API_KEY" not in os.environ
assert "CLAUDE_CODE_OAUTH_TOKEN" not in os.environ
assert "CODEX_API_KEY" not in os.environ
assert "CODEX_ACCESS_TOKEN" not in os.environ
fd=os.environ.get("FM_SEAT_LOCK_FD")
if fd: os.fstat(int(fd))
ambient=os.environ.get("VENDOR_TEST_AMBIENT")=="1"
if ambient:
    assert provider=="claude"
    assert "CLAUDE_CONFIG_DIR" not in os.environ
    assert "CLAUDE_SECURESTORAGE_CONFIG_DIR" not in os.environ
    assert "CODEX_HOME" not in os.environ
else:
    assert os.environ["CLAUDE_CONFIG_DIR" if provider=="claude" else "CODEX_HOME"]==str(case)
(case/"vendor-started").write_text(str(os.getpid()))
def settle():
    while not (case/"release").exists(): time.sleep(.01)
if provider=="claude":
    assert sys.argv[1:]==["--safe-mode", "doctor"]
    if not ambient: assert os.environ["CLAUDE_SECURESTORAGE_CONFIG_DIR"]==str(case)
    settle()
else:
    assert sys.argv[1:]==["app-server", "--listen", "stdio://"]
    for expected in ["initialize", "initialized", "account/read"]:
        msg=json.loads(sys.stdin.readline())
        assert msg["method"]==expected
        if expected=="account/read":
            assert msg["params"]=={"refreshToken":True}
            settle()
        if "id" in msg:
            if (case/"reject").exists():
                print(json.dumps({"id":msg["id"],"error":{"message":"do-not-print-vendor-secret"}}),flush=True)
                break
            print(json.dumps({"id":msg["id"],"result":{}}),flush=True)
    assert sys.stdin.read()==""
'''
for provider in ("claude", "codex"):
    path = bin_dir / provider
    path.write_text(fixture)
    path.chmod(0o755)

def start(name, provider, release=True, reject=False, lock=None, ambient=False, path_bin=None):
    case = scratch / name
    case.mkdir()
    if release:
        (case / "release").touch()
    if reject:
        (case / "reject").touch()
    env = dict(os.environ, PATH=str(path_bin or bin_dir) + os.pathsep + os.environ["PATH"],
               VENDOR_TEST_CASE=str(case), ANTHROPIC_API_KEY="wrong",
               CLAUDE_CODE_OAUTH_TOKEN="wrong", CODEX_API_KEY="wrong", CODEX_ACCESS_TOKEN="wrong",
               CLAUDE_CONFIG_DIR="wrong", CLAUDE_SECURESTORAGE_CONFIG_DIR="wrong", CODEX_HOME="wrong",
               VENDOR_TEST_AMBIENT="1" if ambient else "0")
    env.pop("FM_SEAT_LOCK_FD", None)
    if lock is not None:
        env["FM_SEAT_LOCK_FD"] = str(lock)
    process = subprocess.Popen([sys.executable, str(root / "bin/fm-seat-vendor-renew.py"),
                                "--provider", provider, "--profile", "" if ambient else str(case)],
                               env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               text=True, pass_fds=() if lock is None else (lock,))
    return process, case

for provider in ("claude", "codex"):
    process, _ = start(provider, provider)
    out, err = process.communicate(timeout=15)
    assert process.returncode == 0, (provider, out, err)
    assert json.loads(out)["status"] == "completed"
process, _ = start("ambient", "claude", ambient=True)
out, err = process.communicate(timeout=15)
assert process.returncode == 0, (out, err)
assert json.loads(out)["status"] == "completed"
process, case = start("empty-codex", "codex", ambient=True)
out, err = process.communicate(timeout=15)
assert process.returncode == 2 and not (case / "vendor-started").exists()

wrapper_bin = scratch / "wrappers"
wrapper_bin.mkdir()
for provider in ("claude", "codex"):
    wrapper = wrapper_bin / provider
    wrapper.write_text('#!/bin/sh\nFM_PIPELINE_TOOL=/unused\ntouch "$VENDOR_TEST_CASE/wrapper-executed"\n')
    wrapper.chmod(0o755)
    process, case = start("wrapper-" + provider, provider, path_bin=wrapper_bin)
    out, err = process.communicate(timeout=15)
    assert process.returncode == 2, (out, err)
    assert json.loads(out)["status"] == "unavailable"
    assert not (case / "wrapper-executed").exists(), "managed wrapper was executed"
process, _ = start("reject", "codex", reject=True)
out, err = process.communicate(timeout=15)
assert process.returncode == 1
assert "do-not-print-vendor-secret" not in out + err

lock_path = scratch / "seat.lock"
lock = os.open(lock_path, os.O_CREAT | os.O_RDWR, 0o600)
fcntl.flock(lock, fcntl.LOCK_EX)
process, case = start("signals", "codex", release=False, lock=lock)
os.close(lock)
deadline = time.monotonic() + 15
while not (case / "vendor-started").exists():
    assert time.monotonic() < deadline, "fixture never started"
    time.sleep(.01)
for signum in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
    process.send_signal(signum)
    time.sleep(.05)
    assert process.poll() is None, "adapter released wait on cancellation"
process.kill()  # Only the deterministic adapter fixture, never a real vendor.
process.wait(timeout=5)
probe = os.open(lock_path, os.O_RDWR)
try:
    fcntl.flock(probe, fcntl.LOCK_EX | fcntl.LOCK_NB)
except BlockingIOError:
    pass
else:
    raise AssertionError("vendor did not retain inherited seat lock")
(case / "release").touch()
deadline = time.monotonic() + 10
while True:
    try:
        fcntl.flock(probe, fcntl.LOCK_EX | fcntl.LOCK_NB)
        break
    except BlockingIOError:
        assert time.monotonic() < deadline, "fixture retained lock after completion"
        time.sleep(.02)
os.close(probe)
print("ok - vendor refresh sends no model request, preserves ambient Claude, rejects seat wrappers, and retains lease through cancellation")
PY
