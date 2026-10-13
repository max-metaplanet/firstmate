#!/usr/bin/env bash
# Token-free vendor capability inventory; this never claims renewal is enabled.
# Only version, help, generated schema, and login status on an empty home run.
# No login flow, doctor, app-server process, model prompt, or live store is used.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate default-on FM_SEAT_RENEW_LIVE_E2E jq
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
    env -i HOME="$TMP_ROOT/home" PATH="$PATH" CODEX_HOME="$TMP_ROOT/codex" \
      codex app-server generate-json-schema --out "$TMP_ROOT/schema" > "$TMP_ROOT/schema-output" 2>&1 || fail "$version: protocol schema generation failed"
    jq -e '.properties.refreshToken.type == "boolean"' "$TMP_ROOT/schema/v2/GetAccountParams.json" >/dev/null || fail "$version: account/read refreshToken capability changed"
    pass "$version: generated account/read refreshToken schema; automatic renewal remains disabled"
  else
    env -i HOME="$TMP_ROOT/home" PATH="$PATH" CLAUDE_CONFIG_DIR="$TMP_ROOT/claude" DISABLE_AUTOUPDATER=1 \
      claude auth --help > "$TMP_ROOT/claude-help" 2>&1 || fail "$version: auth help failed"
    rg -q 'login' "$TMP_ROOT/claude-help" || fail "$version: documented login command changed"
    pass "$version: auth help exposes login; automatic renewal remains disabled"
  fi
done
[ "$checked" -gt 0 ] || fail 'no installed vendor was checked'
