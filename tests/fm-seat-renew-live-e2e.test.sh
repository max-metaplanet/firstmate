#!/usr/bin/env bash
# Token-free vendor guard with empty Codex auth and synthetic Claude auth.
# Real live stores are never read: fresh homes and a fake security executable
# isolate Claude's Keychain. A refused loopback proxy blocks network traffic.
# The expired-vs-fresh Claude comparison observes its actual OAuth refresh lock.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate default-on FM_SEAT_RENEW_LIVE_E2E jq python3
if ! command -v claude >/dev/null 2>&1 && ! command -v codex >/dev/null 2>&1; then
  printf 'skip: live: codex absent\n'
  fm_live_gate default-on FM_SEAT_RENEW_LIVE_E2E claude
fi
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-seat-renew-live.XXXXXX")
mkdir -p "$TMP_ROOT/home" "$TMP_ROOT/codex" "$TMP_ROOT/claude"
checked=0
for provider in claude codex; do
  if ! command -v "$provider" >/dev/null 2>&1; then
    case "${FM_SEAT_RENEW_LIVE_E2E:-${FM_LIVE:-}}" in 1) fail "$provider absent for requested live guard" ;; esac
    printf 'skip: live: %s absent\n' "$provider"
    continue
  fi
  checked=$((checked + 1))
  version=$("$provider" --version)
  if [ "$provider" = codex ]; then
    if env -i HOME="$TMP_ROOT/home" PATH="$PATH" CODEX_HOME="$TMP_ROOT/codex" \
      codex login status > "$TMP_ROOT/codex-login-status" 2>&1; then
      fail "$version: empty isolated CODEX_HOME unexpectedly reports logged in"
    fi
    rg -q 'Not logged in' "$TMP_ROOT/codex-login-status" || fail "$version: empty-home login status contract changed"
    [ ! -e "$TMP_ROOT/codex/auth.json" ] || fail "$version: read-only login status created auth.json"
    pass "$version: empty CODEX_HOME reports Not logged in without credential creation"
    python3 - "$TMP_ROOT" "$ROOT" <<'LOCKPROOF'
import fcntl
import json
import os
from pathlib import Path
import subprocess
import sys
import time
root = Path(sys.argv[1])
code_root = Path(sys.argv[2])
path = root / "native-codex.lock"
fd = os.open(path, os.O_CREAT | os.O_RDWR, 0o600)
fcntl.flock(fd, fcntl.LOCK_EX)
env = {"HOME": str(root / "home"), "CODEX_HOME": str(root / "codex"), "PATH": os.environ["PATH"]}
child = subprocess.Popen(["codex", "app-server", "--listen", "stdio://"],
                         env=env, cwd=root, stdin=subprocess.PIPE,
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, pass_fds=(fd,))
os.close(fd)
try:
    time.sleep(1)
    assert child.poll() is None, "empty-auth app-server exited before lease proof"
    scan = subprocess.run([sys.executable, str(code_root / "bin/fm-seat-lock.py"), "owners",
                           "--provider", "codex", "--profile", str(root / "codex"),
                           "--home", str(root / "home")], capture_output=True, text=True, check=True)
    rows = json.loads(scan.stdout)
    tree = subprocess.check_output(["ps", "-axo", "pid=,ppid="], text=True)
    descendants = {child.pid}
    changed = True
    while changed:
        changed = False
        for line in tree.splitlines():
            pid, ppid = map(int, line.split())
            if ppid in descendants and pid not in descendants:
                descendants.add(pid)
                changed = True
    assert any(row["pid"] in descendants for row in rows), "scanner missed real isolated Codex owner"
    probe = os.open(path, os.O_RDWR)
    try:
        try:
            fcntl.flock(probe, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            pass
        else:
            raise AssertionError("installed Codex launcher dropped inherited lease fd")
    finally:
        os.close(probe)
finally:
    child.stdin.close()
    child.wait(timeout=30)
env["FM_SEAT_LOCK_ROOT"] = str(root / "managed-locks")
wrapped = subprocess.Popen([sys.executable, str(code_root / "bin/fm-seat-lock.py"), "guard",
                            "--provider", "codex", "--profile", str(root / "codex"), "--",
                            "codex", "app-server", "--listen", "stdio://"],
                           env=env, cwd=root, stdin=subprocess.PIPE,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
try:
    time.sleep(1)
    assert wrapped.poll() is None, "managed wrapper exited before native process proof"
    tree = subprocess.check_output(["ps", "-axo", "pid=,ppid="], text=True)
    descendants = {wrapped.pid}
    for _ in range(10):
        for line in tree.splitlines():
            pid, ppid = map(int, line.split())
            if ppid in descendants:
                descendants.add(pid)
    scan = subprocess.run([sys.executable, str(code_root / "bin/fm-seat-lock.py"), "owners",
                           "--provider", "codex", "--profile", str(root / "codex"),
                           "--home", str(root / "home")], capture_output=True, text=True, check=True)
    assert any(row["pid"] in descendants for row in json.loads(scan.stdout)), "scanner missed managed native Codex"
    recognized = False
    for pid in descendants - {wrapped.pid}:
        comm = subprocess.run(["ps", "-p", str(pid), "-o", "comm="], capture_output=True, text=True).stdout.strip()
        if not comm:
            continue
        verdict = subprocess.check_output(["bash", "-c", '. "$1/bin/fm-agent-process-lib.sh"; fm_agent_process_classify "$2" "$2" "" "$3"',
                                           "bash", str(code_root), comm, str(pid)], text=True)
        recognized |= verdict == "agent"
    assert recognized, "managed wrapper hid native Codex from process classifier"
finally:
    wrapped.stdin.close()
    wrapped.wait(timeout=30)
LOCKPROOF
    pass "$version: installed app-server launcher retains inherited lease descriptor until exit"
    pass "$version: owner scanner detects the real isolated app-server"
    pass "$version: managed lease wrapper preserves native owner and agent-process classification"
    env -i HOME="$TMP_ROOT/home" PATH="$PATH" CODEX_HOME="$TMP_ROOT/codex" \
      codex app-server generate-json-schema --out "$TMP_ROOT/schema" > "$TMP_ROOT/schema-output" 2>&1 || fail "$version: protocol schema generation failed"
    jq -e '.properties.refreshToken.type == "boolean"' "$TMP_ROOT/schema/v2/GetAccountParams.json" >/dev/null || fail "$version: account/read refreshToken capability changed"
    env -i HOME="$TMP_ROOT/home" PATH="$PATH" \
      python3 "$ROOT/bin/fm-seat-vendor-renew.py" --provider codex --profile "$TMP_ROOT/codex" \
      > "$TMP_ROOT/codex-protocol.json" 2> "$TMP_ROOT/codex-protocol-events" || fail "$version: empty-home refresh protocol failed"
    jq -e '.status == "completed" and .protocolSuccess' "$TMP_ROOT/codex-protocol.json" >/dev/null || fail "$version: no refresh protocol completion"
    [ ! -e "$TMP_ROOT/codex/auth.json" ] || fail "$version: empty-home protocol created credentials"
    pass "$version: real initialize/account-read refresh protocol completed with empty auth and no model turn"
  else
    env -i HOME="$TMP_ROOT/home" PATH="$PATH" CLAUDE_CONFIG_DIR="$TMP_ROOT/claude" DISABLE_AUTOUPDATER=1 \
      claude auth --help > "$TMP_ROOT/claude-help" 2>&1 || fail "$version: auth help failed"
    rg -q 'login' "$TMP_ROOT/claude-help" || fail "$version: documented login command changed"
    pass "$version: auth help exposes login"
    if [ "$(uname -s)" != Darwin ]; then
      printf 'skip: live: Claude synthetic Keychain refresh guard requires macOS\n'
      continue
    fi
    mkdir -p "$TMP_ROOT/fakebin"
    cat > "$TMP_ROOT/fakebin/security" <<'SECURITY'
#!/usr/bin/env bash
if [ -n "${FM_RENEW_LIVE_GATE:-}" ]; then
  : > "$FM_RENEW_LIVE_GATE.ready"
  while [ ! -e "$FM_RENEW_LIVE_GATE.release" ]; do sleep 0.02; done
fi
if [ -d "$CLAUDE_CONFIG_DIR/.oauth_refresh.lock" ]; then
  printf 'locked credential reread\n' >> "$CLAUDE_CONFIG_DIR/refresh-observed"
fi
case " $* " in
  *' find-generic-password '*)
    case " $* " in *' -w '*) cat "$CLAUDE_CONFIG_DIR/.credentials.json" ;; esac
    exit 0 ;;
  *) exit 44 ;;
esac
SECURITY
    chmod +x "$TMP_ROOT/fakebin/security"
    for auth_case in expired fresh; do
      profile="$TMP_ROOT/claude-$auth_case"
      mkdir -p "$profile"
      expiry=1
      [ "$auth_case" = expired ] || expiry=4102444800000
      jq -cn --argjson expiry "$expiry" \
        '{claudeAiOauth:{accessToken:"synthetic-access",refreshToken:"synthetic-not-a-credential",
          expiresAt:$expiry,scopes:["user:inference","user:profile"],subscriptionType:"max",rateLimitTier:"default_claude_max_5x"}}' \
        > "$profile/.credentials.json"
      env -i HOME="$TMP_ROOT/home" PATH="$TMP_ROOT/fakebin:$PATH" \
        HTTPS_PROXY=http://127.0.0.1:9 HTTP_PROXY=http://127.0.0.1:9 \
        https_proxy=http://127.0.0.1:9 http_proxy=http://127.0.0.1:9 \
        python3 - "$ROOT" "$profile" "$TMP_ROOT" "$auth_case" \
        > "$TMP_ROOT/claude-$auth_case-result" 2> "$TMP_ROOT/claude-$auth_case-events" <<'CLAUDEPROOF' || fail "$version: synthetic $auth_case doctor or owner scan failed"
import json
import os
from pathlib import Path
import subprocess
import sys
import time
root, profile, scratch, auth_case = sys.argv[1:]
env = dict(os.environ)
gate = Path(scratch) / "claude-owner-gate"
if auth_case == "expired":
    env["FM_RENEW_LIVE_GATE"] = str(gate)
child = subprocess.Popen([sys.executable, str(Path(root) / "bin/fm-seat-vendor-renew.py"),
                          "--provider", "claude", "--profile", profile],
                         env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
try:
    if auth_case == "expired":
        started = json.loads(child.stderr.readline())
        deadline = time.monotonic() + 20
        while not Path(str(gate) + ".ready").exists():
            assert time.monotonic() < deadline, "synthetic secure-store gate never reached"
            time.sleep(.02)
        scan = subprocess.run([sys.executable, str(Path(root) / "bin/fm-seat-lock.py"), "owners",
                               "--provider", "claude", "--profile", profile,
                               "--home", str(Path(scratch) / "home")],
                              capture_output=True, text=True, check=True)
        assert any(row["pid"] == started["pid"] for row in json.loads(scan.stdout)), "scanner missed real isolated Claude owner"
finally:
    Path(str(gate) + ".release").touch()
    out, err = child.communicate(timeout=45)
assert child.returncode == 0, "synthetic doctor failed"
print(out, end="")
CLAUDEPROOF
    done
    [ -s "$TMP_ROOT/claude-expired/refresh-observed" ] || fail "$version: doctor did not enter the refresh lock for expired synthetic credentials"
    [ ! -e "$TMP_ROOT/claude-fresh/refresh-observed" ] || fail "$version: fresh synthetic credentials also entered refresh; differential proof failed"
    pass "$version: real doctor enters vendor refresh lock only for expired synthetic auth; network refused, no model call"
    pass "$version: owner scanner detects the real isolated doctor process"
  fi
done
[ "$checked" -gt 0 ] || fail 'no installed vendor was checked'
