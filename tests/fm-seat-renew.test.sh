#!/usr/bin/env bash
# Guarded renewal through public CLI, with disposable fake vendor credentials.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-seat-renew.XXXXXX")
mkdir -p "$TMP_ROOT/bin" "$TMP_ROOT/home/config" "$TMP_ROOT/home/state" "$TMP_ROOT/seats/seat-one"
export FM_HOME="$TMP_ROOT/home" RENEW_TEST_ROOT="$TMP_ROOT" FM_SEAT_LOCK_ROOT="$TMP_ROOT/locks"
export PATH="$TMP_ROOT/bin:$PATH"
for provider in claude codex; do
  printf '%s\n' "$TMP_ROOT/seats" > "$FM_HOME/config/$provider-seats-root"
done
cat > "$TMP_ROOT/bin/quota-axi" <<'QUOTA'
#!/usr/bin/env bash
case " $* " in *' --no-credential-refresh '*) ;; *) exit 99 ;; esac
cat "$RENEW_TEST_ROOT/quota.json"
QUOTA
cat > "$TMP_ROOT/bin/claude" <<'VENDOR'
#!/usr/bin/env bash
[ "$*" = '--safe-mode doctor' ] || exit 99
printf 'claude\n' >> "$RENEW_TEST_ROOT/vendor-called"
cp "$RENEW_TEST_ROOT/after.json" "$RENEW_TEST_ROOT/quota.json"
VENDOR
cat > "$TMP_ROOT/bin/codex" <<'VENDOR'
#!/usr/bin/env python3
import json, os, pathlib, sys
assert sys.argv[1:] == ['app-server','--listen','stdio://']
p=pathlib.Path(os.environ['RENEW_TEST_ROOT'])
with (p/'vendor-called').open('a') as out: out.write('codex\n')
for line in sys.stdin:
    data=json.loads(line)
    assert data['method'] in ('initialize','initialized','account/read')
    if data['method']=='initialize':
        print(json.dumps({'id':data['id'],'result':{'userAgent':'test'}}),flush=True)
    elif data['method']=='account/read':
        assert data['params']=={'refreshToken':True}
        (p/'quota.json').write_text((p/'after.json').read_text())
        print(json.dumps({'id':data['id'],'result':{'account':None,'requiresOpenaiAuth':True}}),flush=True)
VENDOR
chmod +x "$TMP_ROOT/bin/claude" "$TMP_ROOT/bin/codex" "$TMP_ROOT/bin/quota-axi"
fixture() {
  local provider=$1 state=$2 destination=${3:-quota.json}
  jq -cn --arg provider "$provider" --arg state "$state" \
    '{providers:[{provider:$provider,source:(if $state == "healthy" then "oauth" else "unavailable" end),
      state:{authStatus:(if $state == "invalid" then "credentials_invalid" else $state end),status:(if $state == "healthy" then "fresh" else "unknown" end)}}]}' > "$TMP_ROOT/$destination"
}
for provider in claude codex; do
  # Different global lock roots isolate the two public state machines.
  export FM_SEAT_LOCK_ROOT="$TMP_ROOT/$provider-locks"
  for state in invalid expired_refreshable healthy unknown; do
    fixture "$provider" "$state"
    result=$(bash "$ROOT/bin/fm-seat-renew.sh" --provider "$provider" --check seat-one)
    assert_equals "$state" "$(printf '%s\n' "$result" | jq -r .state)" "$provider $state classified"
    printf '%s\n' "$result" | jq -e '.supported and .lastRenewal == null' >/dev/null || fail 'missing renewal projection'
    if [ "$state" = invalid ]; then
      printf '%s\n' "$result" | jq -e --arg profile "$TMP_ROOT/seats/seat-one" '.loginCommand | contains($profile)' >/dev/null || fail 'missing exact login command'
    fi
  done
  [ ! -e "$TMP_ROOT/vendor-called" ] || fail 'read-only check launched vendor'
  fixture "$provider" healthy
  bash "$ROOT/bin/fm-seat-renew.sh" --provider "$provider" seat-one > "$TMP_ROOT/result.json"
  [ ! -e "$TMP_ROOT/vendor-called" ] || fail 'healthy seat launched vendor'
  fixture "$provider" expired_refreshable
  fixture "$provider" healthy after.json
  bash "$ROOT/bin/fm-seat-renew.sh" --provider "$provider" seat-one > "$TMP_ROOT/result.json"
  jq -e '.state == "healthy" and .outcome == "renewed" and .lastRenewal > 0' "$TMP_ROOT/result.json" >/dev/null || fail "$provider renewal not verified"
  assert_equals "$provider" "$(cat "$TMP_ROOT/vendor-called")" 'one token-free vendor launch'
  mv "$TMP_ROOT/vendor-called" "$TMP_ROOT/$provider-vendor-first"
  # Invalid results raise a durable check and latch until external login is fresh.
  fixture "$provider" expired_refreshable
  fixture "$provider" invalid after.json
  if bash "$ROOT/bin/fm-seat-renew.sh" --provider "$provider" seat-one > "$TMP_ROOT/result.json"; then fail 'invalid post-state accepted'; fi
  jq -e '.state == "invalid" and .outcome == "invalid" and .loginCommand != null' "$TMP_ROOT/result.json" >/dev/null || fail 'invalid result missing'
  grep -q -- "$provider-seat: seat-one credentials-invalid; renewal stopped; run:" "$FM_HOME/state/.wake-queue" || fail 'missing immediate invalid wake'
  mv "$TMP_ROOT/vendor-called" "$TMP_ROOT/$provider-vendor-invalid"
  fixture "$provider" expired_refreshable
  if bash "$ROOT/bin/fm-seat-renew.sh" --provider "$provider" seat-one > "$TMP_ROOT/result.json"; then fail 'latched seat resumed'; fi
  [ ! -e "$TMP_ROOT/vendor-called" ] || fail 'latched invalid seat refreshed again'
  jq -e '.outcome == "invalid" and .loginCommand != null' "$TMP_ROOT/result.json" >/dev/null || fail 'latched result lost login command'
  bash "$ROOT/bin/fm-seat-renew.sh" --provider "$provider" --check seat-one > "$TMP_ROOT/result.json"
  jq -e '.outcome == "invalid" and .loginCommand != null and (.reason | contains("stopped"))' "$TMP_ROOT/result.json" >/dev/null || fail 'panel lost latched login guidance'
  fixture "$provider" healthy
  bash "$ROOT/bin/fm-seat-renew.sh" --provider "$provider" seat-one > /dev/null
  fixture "$provider" expired_refreshable
  fixture "$provider" healthy after.json
  # Shared managed session lease excludes renewal and concurrent attempts.
  # shellcheck disable=SC2016  # Fixture arguments expand in the child.
  python3 "$ROOT/bin/fm-seat-lock.py" guard --provider "$provider" --profile "$TMP_ROOT/seats/seat-one" -- \
    bash -c 'touch "$1"; while [ ! -e "$2" ]; do sleep .05; done' held "$TMP_ROOT/held-$provider" "$TMP_ROOT/release-$provider" &
  holder=$!
  for _ in $(seq 1 100); do [ ! -e "$TMP_ROOT/held-$provider" ] || break; sleep .05; done
  [ -e "$TMP_ROOT/held-$provider" ] || fail 'session fixture never acquired lock'
  if bash "$ROOT/bin/fm-seat-renew.sh" --provider "$provider" seat-one > "$TMP_ROOT/result.json"; then fail 'renewal crossed managed lease'; fi
  jq -e '.outcome == "busy"' "$TMP_ROOT/result.json" >/dev/null || fail 'busy result absent'
  [ ! -e "$TMP_ROOT/vendor-called" ] || fail 'vendor raced managed session'
  touch "$TMP_ROOT/release-$provider"
  wait "$holder"
done
# A managed worker that leaves a daemon behind must not pin the seat once the worker exits.
# shellcheck disable=SC2016  # Fixture arguments expand in the child.
python3 "$ROOT/bin/fm-seat-lock.py" guard --provider codex --profile "$TMP_ROOT/seats/seat-one" -- \
  bash -c 'sleep 60 </dev/null >/dev/null 2>&1 & printf "%s\n" "$!" > "$1"' worker "$TMP_ROOT/daemon-pid"
daemon=$(cat "$TMP_ROOT/daemon-pid")
kill -0 "$daemon" 2>/dev/null || fail 'daemon fixture did not outlive its managed worker'
bash "$ROOT/bin/fm-seat-renew.sh" --provider codex seat-one > "$TMP_ROOT/result.json" || true
kill -0 "$daemon" 2>/dev/null || fail 'renewal disturbed the leftover daemon'
kill "$daemon"
jq -e '.state == "healthy" and .outcome == "renewed"' "$TMP_ROOT/result.json" >/dev/null || fail "leftover daemon pinned the seat lease: $(cat "$TMP_ROOT/result.json")"
assert_equals codex "$(cat "$TMP_ROOT/vendor-called")" 'renewal proceeded past the leftover daemon'
rm "$TMP_ROOT/vendor-called"
# Ordinary Claude must retain its absent selector, not select a named ~/.claude Keychain.
fixture claude invalid
result=$(FM_AMBIENT_CLAUDE_CONFIG_DIR='' CLAUDE_CONFIG_DIR='' bash "$ROOT/bin/fm-seat-renew.sh" --provider claude --check default)
assert_equals 'env -u CLAUDE_SECURESTORAGE_CONFIG_DIR -u CLAUDE_CONFIG_DIR claude' "$(printf '%s' "$result" | jq -r .loginCommand)" 'ordinary Claude login targets the unselected store'
# Scheduling includes in-use default seats; Codex is skipped on a home that does not use it.
profiles() {
  HOME="$TMP_ROOT/user" CLAUDE_CONFIG_DIR='' FM_AMBIENT_CLAUDE_CONFIG_DIR='' CODEX_HOME='' \
    FM_CONFIG_OVERRIDE="$TMP_ROOT/claude-only-config" bash "$ROOT/bin/fm-seat-renew.sh" --profiles
}
mkdir -p "$TMP_ROOT/user/.claude" "$TMP_ROOT/claude-only-config"
printf '%s\n' "$TMP_ROOT/user/no-seats" > "$TMP_ROOT/claude-only-config/claude-seats-root"
profiles > "$TMP_ROOT/profiles"
jq -se '. == [{provider:"claude",name:"default",profile:""}]' "$TMP_ROOT/profiles" >/dev/null \
  || fail "ordinary Claude default must schedule with its unset selector, and unused Codex not at all: $(cat "$TMP_ROOT/profiles")"
mkdir -p "$TMP_ROOT/user/.codex"
profiles > "$TMP_ROOT/profiles"
jq -se --arg codex "$TMP_ROOT/user/.codex" 'any(.[]; . == {provider:"codex",name:"default",profile:$codex})' "$TMP_ROOT/profiles" >/dev/null \
  || fail "an existing Codex home must schedule its default seat: $(cat "$TMP_ROOT/profiles")"
rm -r "$TMP_ROOT/user/.codex"
# The watcher returns immediately; detached jobs honor a shared 15-minute cadence.
# The default Codex home aliases seat-one's auth.json, so both share one scheduled job.
export FM_SEAT_LOCK_ROOT="$TMP_ROOT/scheduled-locks"
printf '{}\n' > "$TMP_ROOT/seats/seat-one/auth.json"
mkdir -p "$TMP_ROOT/user/.codex"
ln -s "$TMP_ROOT/seats/seat-one/auth.json" "$TMP_ROOT/user/.codex/auth.json"
fixture codex expired_refreshable
fixture codex healthy after.json
HOME="$TMP_ROOT/user" CODEX_HOME='' CLAUDE_CONFIG_DIR='' FM_AMBIENT_CLAUDE_CONFIG_DIR='' bash "$ROOT/bin/fm-seat-renew.sh" auto > "$TMP_ROOT/auto-output"
for _ in $(seq 1 600); do
  result=$(python3 "$ROOT/bin/fm-seat-lock.py" state --provider codex --profile "$TMP_ROOT/seats/seat-one")
  if printf '%s\n' "$result" | jq -e '.outcome == "renewed"' >/dev/null; then break; fi
  sleep .05
done
printf '%s\n' "$result" | jq -e '.outcome == "renewed"' >/dev/null || fail 'scheduled job never verified renewal'
assert_equals codex "$(cat "$TMP_ROOT/vendor-called")" 'scheduled vendor launch'
fixture codex expired_refreshable
HOME="$TMP_ROOT/user" CODEX_HOME='' CLAUDE_CONFIG_DIR='' FM_AMBIENT_CLAUDE_CONFIG_DIR='' bash "$ROOT/bin/fm-seat-renew.sh" auto > "$TMP_ROOT/auto-output"
sleep .2
assert_equals codex "$(cat "$TMP_ROOT/vendor-called")" 'cadence prevents a second scheduled launch'
# Publication and automatic selection both observe an exclusive renewal lease.
cat > "$TMP_ROOT/exclusive.py" <<'LOCK'
import importlib.util, os, pathlib, sys, time
spec=importlib.util.spec_from_file_location('locks',sys.argv[1]); locks=importlib.util.module_from_spec(spec); spec.loader.exec_module(locks)
p=pathlib.Path(os.environ['RENEW_TEST_ROOT'])
with locks.seat_lock('codex',str(p/'seats/seat-one'),exclusive=True):
    (p/'exclusive-held').touch()
    while not (p/'exclusive-release').exists(): time.sleep(.05)
LOCK
python3 "$TMP_ROOT/exclusive.py" "$ROOT/bin/fm-seat-lock.py" &
holder=$!
for _ in $(seq 1 100); do [ ! -e "$TMP_ROOT/exclusive-held" ] || break; sleep .05; done
[ -e "$TMP_ROOT/exclusive-held" ] || fail 'exclusive fixture never acquired lock'
if bash "$ROOT/bin/fm-seat.sh" --provider codex switch seat-one --force > "$TMP_ROOT/switch-output" 2>&1; then fail 'switch published during renewal'; fi
[ ! -e "$FM_HOME/config/codex-seat" ] || fail 'switch wrote active setting during renewal'
grep -q -- 'renewing' "$TMP_ROOT/switch-output" || fail 'switch did not name renewal hold'
if bash "$ROOT/bin/fm-seat.sh" --provider codex switch --next --force > "$TMP_ROOT/switch-output" 2>&1; then fail 'auto selection crossed renewal'; fi
grep -q -- 'renewing' "$TMP_ROOT/switch-output" || fail 'rotation did not skip renewing seat'
touch "$TMP_ROOT/exclusive-release"
wait "$holder"
bash "$ROOT/bin/fm-seat-renew.sh" arm > "$TMP_ROOT/armed"
[ -s "$FM_HOME/state/seat-renewal.check-trust" ] || fail 'renewal check not trusted'
bash "$ROOT/bin/fm-seat-renew.sh" disarm > /dev/null
[ ! -e "$FM_HOME/state/seat-renewal.check.sh" ] || fail 'renewal check not disarmed'
pass 'renewal rechecks, excludes managed owners, verifies vendor refresh, latches invalid credentials and registers watcher checks'
