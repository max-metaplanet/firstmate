#!/usr/bin/env bash
# Public-interface renewal decisions and proof that no vendor process starts.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-seat-renew.XXXXXX")
mkdir -p "$TMP_ROOT/bin" "$TMP_ROOT/home/config" "$TMP_ROOT/seats/seat-one"
export FM_HOME="$TMP_ROOT/home" RENEW_TEST_ROOT="$TMP_ROOT"
export PATH="$TMP_ROOT/bin:$PATH"
for provider in claude codex; do
  printf '%s\n' "$TMP_ROOT/seats" > "$FM_HOME/config/$provider-seats-root"
  cat > "$TMP_ROOT/bin/$provider" <<'VENDOR'
#!/usr/bin/env bash
printf 'unexpected vendor launch\n' >> "$RENEW_TEST_ROOT/vendor-called"
exit 99
VENDOR
  chmod +x "$TMP_ROOT/bin/$provider"
done
cat > "$TMP_ROOT/bin/quota-axi" <<'QUOTA'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$RENEW_TEST_ROOT/quota-args"
case " $* " in *' --no-credential-refresh '*) ;; *) exit 99 ;; esac
cat "$RENEW_TEST_ROOT/quota.json"
QUOTA
chmod +x "$TMP_ROOT/bin/quota-axi"

for provider in claude codex; do
  for state in invalid expired_refreshable healthy unknown; do
    case "$state" in
      invalid) row='{"source":"unavailable","attempts":[{"status":"skipped","error":"credentials_invalid"}]}' ;;
      expired_refreshable) row='{"source":"unavailable","state":{"authStatus":"expired_refreshable"}}' ;;
      healthy) row='{"source":"oauth","state":{"status":"fresh"}}' ;;
      unknown) row='{"source":"unavailable","state":{"status":"auth_required"},"attempts":[{"status":"failed","error":"401"}]}' ;;
    esac
    jq -cn --arg provider "$provider" --argjson row "$row" '{providers:[$row + {provider:$provider}]}' > "$TMP_ROOT/quota.json"
    result=$(bash "$ROOT/bin/fm-seat-renew.sh" --provider "$provider" --check seat-one)
    assert_equals "$state" "$(printf '%s\n' "$result" | jq -r .state)" "$provider $state classified"
    printf '%s\n' "$result" | jq -e '.supported == false and (.command | contains("--check seat-one"))' >/dev/null || fail 'unsafe renewal advertised'
    if [ "$state" = invalid ]; then
      printf '%s\n' "$result" | jq -e --arg profile "$TMP_ROOT/seats/seat-one" '.loginCommand | contains($profile)' >/dev/null || fail 'exact profile absent from login command'
    else
      printf '%s\n' "$result" | jq -e '.loginCommand == null' >/dev/null || fail 'unproven sign-out offered login'
    fi
    if bash "$ROOT/bin/fm-seat-renew.sh" --provider "$provider" seat-one > "$TMP_ROOT/result.json"; then
      [ "$state" = healthy ] || fail "renewal request accepted $state"
    else
      [ "$state" != healthy ] || fail 'healthy no-op refused'
    fi
  done
done
printf 'not json\n' > "$TMP_ROOT/quota.json"
result=$(bash "$ROOT/bin/fm-seat-renew.sh" --provider codex --check seat-one)
assert_equals unknown "$(printf '%s\n' "$result" | jq -r .state)" 'malformed read remains unknown'
# A coordinator can take its own lock with no vendor process started, but that
# lock is not a vendor session ownership lease. Even this favorable setup must
# not enable renewal, and concurrent callers must both remain read-only.
mkdir "$TMP_ROOT/private-renewal.lock"
printf '%s\n' '{"providers":[{"provider":"codex","source":"unavailable","state":{"authStatus":"expired_refreshable"}}]}' > "$TMP_ROOT/quota.json"
for attempt in first second; do
  (
    if bash "$ROOT/bin/fm-seat-renew.sh" --provider codex seat-one > "$TMP_ROOT/$attempt.json"; then
      exit 1
    fi
    jq -e '.state == "expired_refreshable" and .supported == false' "$TMP_ROOT/$attempt.json" >/dev/null
  ) &
  case "$attempt" in first) first_pid=$! ;; second) second_pid=$! ;; esac
done
wait "$first_pid" || fail 'first concurrent renewal escaped the ownership boundary'
wait "$second_pid" || fail 'second concurrent renewal escaped the ownership boundary'
[ ! -e "$TMP_ROOT/vendor-called" ] || fail 'vendor CLI launched'
pass 'both vendors classify renewal state and refuse unsafe renewal without starting vendor CLIs'
