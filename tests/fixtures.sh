#!/usr/bin/env bash
# tests/fixtures.sh - shared fake-toolchain and spawn-world builders.
#
# Source this from a test file:
#   # shellcheck source=tests/fixtures.sh
#   . "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
#
# Generic reporters, temp roots, git fixtures, and fail/pass/fm_test_cleanup
# come from tests/lib.sh, pulled in below. This file owns the shared fake
# no-mistakes, gh, gh-axi, tmux, ssh, and spawn-world helpers. Wake-queue mocks
# stay in wake-helpers.sh; secondmate-lifecycle mocks stay in
# secondmate-helpers.sh.
#
# FM_TEST_NO_MISTAKES_VERSION is the single default version for the shared fake
# no-mistakes banner. Override a single case with FM_FAKE_NO_MISTAKES_VERSION
# rather than editing a stub body.

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if [ -n "${FM_TEST_FIXTURES_SOURCED:-}" ]; then
  return 0
fi
FM_TEST_FIXTURES_SOURCED=1

# Production floor lives in bin/fm-bootstrap.sh (NO_MISTAKES_MIN). Keep this
# equal to that floor so a bump is one constant here plus that production pin.
export FM_TEST_NO_MISTAKES_VERSION=1.46.0
export FM_TEST_NO_MISTAKES_FAKE_VERSION="no-mistakes version v${FM_TEST_NO_MISTAKES_VERSION} (fake)"
export FM_TEST_NO_MISTAKES_FAKE_VERSION_TS="${FM_TEST_NO_MISTAKES_FAKE_VERSION} 2026-06-27T00:02:18Z"
export FM_TEST_GH_AXI_VERSION=0.1.29

# --- fake no-mistakes -------------------------------------------------------

# fm_test_fake_no_mistakes <fakebin>
# Drops a no-mistakes stub that answers --version with
# FM_TEST_NO_MISTAKES_FAKE_VERSION (or FM_FAKE_NO_MISTAKES_VERSION when set)
# and exits 0 for every other invocation.
fm_test_fake_no_mistakes() {
  local fakebin=$1
  cat > "$fakebin/no-mistakes" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = --version ]; then
  printf '%s\\n' "\${FM_FAKE_NO_MISTAKES_VERSION:-$FM_TEST_NO_MISTAKES_FAKE_VERSION}"
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/no-mistakes"
}

# fm_test_fake_no_mistakes_init_doctor <fakebin>
# Secondmate-lifecycle stub: init/doctor touch marker files; other verbs exit 2.
# Does not answer --version (those suites never probe the floor).
fm_test_fake_no_mistakes_init_doctor() {
  local fakebin=$1
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
set -eu
case "${1:-}" in
  init) touch .no-mistakes-init ;;
  doctor) touch .no-mistakes-doctor ;;
  *) exit 2 ;;
esac
SH
  chmod +x "$fakebin/no-mistakes"
}

# --- fake gh / gh-axi -------------------------------------------------------

# fm_test_fake_gh <fakebin>
# Authenticates (`gh auth status` exits 0) and otherwise exits 0.
fm_test_fake_gh() {
  local fakebin=$1
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = auth ] && [ "${2:-}" = status ]; then
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/gh"
}

# fm_test_fake_gh_axi <fakebin>
# Answers --version with FM_FAKE_GH_AXI_VERSION or FM_TEST_GH_AXI_VERSION.
fm_test_fake_gh_axi() {
  local fakebin=$1
  fm_fake_version_tool "$fakebin" gh-axi FM_FAKE_GH_AXI_VERSION "$FM_TEST_GH_AXI_VERSION"
}

# --- fake tmux / ssh / sleep ------------------------------------------------

# fm_test_fake_tmux_spawn <fakebin>
# Spawn-world tmux: pane_current_path from FM_FAKE_PANE_PATH, session named
# firstmate, window ops succeed, send-keys succeed. When FM_FAKE_LAUNCH_LOG is
# set, each send-keys -l payload is appended one per line. When FM_FAKE_PANE_LOG
# is set, each send-keys TEXT-LINE payload (the pre-launch pane exports, which
# carry no -l) is appended there instead, one per line in send order. Optional
# FM_FAKE_DUPLICATE_WINDOW is printed from list-windows.
#
# The pane path defaults to empty when FM_FAKE_PANE_PATH is unset. Window
# cleanup and option operations are no-ops. Launch logging is env-gated, so
# suites that do not set FM_FAKE_LAUNCH_LOG keep a silent send-keys.
fm_test_fake_tmux_spawn() {
  local fakebin=$1
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*)
    # Opt-in per-window pane paths: a batch spawn launches several tasks, and
    # each really gets its OWN pool copy, so a suite that needs that shape
    # points FM_FAKE_PANE_PATH_BY_WINDOW at a directory holding one file per
    # window name whose contents is that window's path. Unset, every window
    # keeps reporting the single FM_FAKE_PANE_PATH exactly as before.
    if [ -n "${FM_FAKE_PANE_PATH_BY_WINDOW:-}" ]; then
      fm_target=
      fm_prev=
      for fm_a in "$@"; do
        [ "$fm_prev" != "-t" ] || fm_target=$fm_a
        fm_prev=$fm_a
      done
      case "$fm_target" in
        @*) fm_win=${fm_target#@} ;;
        *) fm_win=${fm_target##*:} ;;
      esac
      if [ -n "$fm_win" ] && [ -f "$FM_FAKE_PANE_PATH_BY_WINDOW/$fm_win" ]; then
        cat "$FM_FAKE_PANE_PATH_BY_WINDOW/$fm_win"
        exit 0
      fi
    fi
    printf '%s\n' "${FM_FAKE_PANE_PATH:-}"
    exit 0
    ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows)
    if [ -n "${FM_FAKE_DUPLICATE_WINDOW:-}" ]; then
      printf '%s\n' "$FM_FAKE_DUPLICATE_WINDOW"
    fi
    exit 0
    ;;
  new-window)
    # Only under the opt-in above does this answer with a window id, so the
    # per-window lookup has a target to key on; otherwise it stays silent and
    # the spawn resolves an empty target exactly as it does today.
    if [ -n "${FM_FAKE_PANE_PATH_BY_WINDOW:-}" ]; then
      fm_name=
      fm_prev=
      for fm_a in "$@"; do
        [ "$fm_prev" != "-n" ] || fm_name=$fm_a
        fm_prev=$fm_a
      done
      [ -z "$fm_name" ] || printf '@%s\n' "$fm_name"
    fi
    exit 0
    ;;
  has-session|new-session|kill-window|set-window-option) exit 0 ;;
  send-keys)
    if [ -n "${FM_FAKE_LAUNCH_LOG:-}" ]; then
      prev=
      for a in "$@"; do
        if [ "$prev" = "-l" ]; then
          # A spawn types a short line sourcing its staged launch file; log
          # the staged command itself so suites assert what the pane runs.
          # Direct literals past the terminal line buffer are truncated, so a
          # long launch only survives when it arrived through that short source.
          case "$a" in
            ". '"*"'")
              staged=${a#". '"}
              staged=${staged%"'"}
              if [ -f "$staged" ]; then
                a=$(cat "$staged")
              elif [ "${#a}" -gt 1024 ]; then
                a=${a:0:1024}
              fi
              ;;
            *)
              if [ "${#a}" -gt 1024 ]; then
                a=${a:0:1024}
              fi
              ;;
          esac
          printf '%s\n' "$a" >> "$FM_FAKE_LAUNCH_LOG"
        fi
        prev=$a
      done
    fi
    # The pre-launch pane exports ride the text-line form
    # (`send-keys -t <target> <text> Enter`), which carries no -l flag, so a
    # suite that asserts on what the pane shell received opts in with its own
    # log. Skip the flags, the target, and the trailing key so only the payload
    # is recorded, one per line, in send order.
    if [ -n "${FM_FAKE_PANE_LOG:-}" ]; then
      shift
      skip_next=
      literal=
      for a in "$@"; do
        if [ -n "$skip_next" ]; then skip_next=; continue; fi
        case "$a" in
          -t) skip_next=1; continue ;;
          -l) literal=1; continue ;;
          Enter|C-m) continue ;;
          *) [ -n "$literal" ] || printf '%s\n' "$a" >> "$FM_FAKE_PANE_LOG" ;;
        esac
      done
    fi
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
}

# fm_test_fake_tmux_send <fakebin>
# Send-world tmux: logs send-keys -l payloads to FM_SEND_LOG, reports a numeric
# cursor_y, and renders an empty bordered composer so the submit path reads
# empty. Env knobs:
#   FM_FAKE_TMUX_SEND_FAIL=1  send-keys exits 1
#   FM_FAKE_TMUX_COMPOSER=pending  capture-pane shows leftover composer text
fm_test_fake_tmux_send() {
  local fakebin=$1
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  send-keys)
    [ "${FM_FAKE_TMUX_SEND_FAIL:-0}" = 1 ] && exit 1
    shift
    literal=0
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    if [ "$literal" = 1 ]; then
      printf '%s' "${1:-}" >> "${FM_SEND_LOG:-/dev/null}"
    fi
    exit 0
    ;;
  display-message)
    for a in "$@"; do
      case "$a" in *cursor_y*) printf '1\n'; exit 0 ;; esac
    done
    printf 'fakepane\n'
    exit 0
    ;;
  capture-pane)
    if [ "${FM_FAKE_TMUX_COMPOSER:-}" = pending ]; then
      printf '╭──────────────╮\n│ leftover txt │\n╰──────────────╯\n'
    else
      printf '╭────╮\n│    │\n╰────╯\n'
    fi
    exit 0
    ;;
  list-windows) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
}

# fm_test_fake_ssh <fakebin> [name]
# Records argv to FM_SSH_LOG, consumes stdin, exits FM_FAKE_SSH_RC (default 0).
# Default name is fake-ssh so tests can point FM_SSH_BIN at it without
# shadowing a real ssh on PATH.
fm_test_fake_ssh() {
  local fakebin=$1 name=${2:-fake-ssh}
  cat > "$fakebin/$name" <<'SH'
#!/usr/bin/env bash
cat > /dev/null
printf '%s\n' "$*" >> "${FM_SSH_LOG:-/dev/null}"
exit "${FM_FAKE_SSH_RC:-0}"
SH
  chmod +x "$fakebin/$name"
}

# fm_test_fake_sleep_noop <fakebin>
fm_test_fake_sleep_noop() {
  local fakebin=$1
  cat > "$fakebin/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/sleep"
}

# fm_test_fake_sleep_log <fakebin>
# Records each requested duration to FM_SLEEP_LOG instead of sleeping.
fm_test_fake_sleep_log() {
  local fakebin=$1
  cat > "$fakebin/sleep" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${1:-}" >> "${FM_SLEEP_LOG:-/dev/null}"
exit 0
SH
  chmod +x "$fakebin/sleep"
}

# --- spawn-world ------------------------------------------------------------

# fm_test_spawn_home <home> [harness]
# Minimal firstmate home layout plus watcher-liveness beat. Optional harness
# pin is written to config/crew-harness.
fm_test_spawn_home() {
  local home=$1 harness=${2-}
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  touch "$home/state/.last-watcher-beat"
  if [ -n "$harness" ]; then
    printf '%s\n' "$harness" > "$home/config/crew-harness"
  fi
}

# fm_test_spawn_brief <home> <id> [captain-intent]
fm_test_spawn_brief() {
  local home=$1 id=$2 intent=${3:-brief for $2}
  mkdir -p "$home/data/$id"
  cat > "$home/data/$id/brief.md" <<EOF
# Task
## Captain's intent
$intent

## Firstmate spec
Exercise the spawn behavior under test.
EOF
}

# fm_test_make_spawn_fakebin <dir> [extra-exit0-tool...]
# Creates <dir>/fakebin with the spawn tmux stub, a no-op treehouse, and any
# extra exit-0 tools. Echoes the fakebin path.
fm_test_make_spawn_fakebin() {
  local dir=$1 fakebin
  shift
  fakebin=$(fm_fakebin "$dir")
  fm_test_fake_tmux_spawn "$fakebin"
  fm_fake_exit0 "$fakebin" treehouse "$@"
  printf '%s\n' "$fakebin"
}

# Drop-in name used by the spawn suites. Extra args are additional exit-0 tools
# (gh, gh-axi, pi, ...).
make_spawn_fakebin() {
  fm_test_make_spawn_fakebin "$@"
}

# fm_test_run_spawn <home> <pane-path> <fakebin> [fm-spawn args...]
# Common spawn env. Extra variables in the caller (GROK_HOME, FM_FAKE_LAUNCH_LOG,
# CLAUDE_CONFIG_DIR, ...) are inherited. Does not add --mode/--yolo; ship tests
# that need a delivery contract pass those flags themselves.
fm_test_run_spawn() {
  local home=$1 pane=$2 fakebin=$3
  shift 3
  # A claude spawn pre-registers workspace trust in the launching user's own
  # store (bin/fm-claude-trust.sh), so every spawn here runs against a throwaway
  # HOME; without it the suite would write the developer's real ~/.claude.json.
  # CLAUDE_CONFIG_DIR must be pinned too, and pinned EMPTY: the script resolves
  # the store as ${CLAUDE_CONFIG_DIR:-${HOME:-}}, so a value inherited from the
  # developer's shell would beat the throwaway HOME and the sandbox would not
  # hold, while an empty value falls through to it. Empty rather than a path
  # because bin/fm-spawn.sh prefixes the launch only when the value is non-empty,
  # so every launch-shape assertion in the suite keeps reading the same command.
  # A test that needs the set case opts in through FM_TEST_CLAUDE_CONFIG_DIR.
  local spawn_home=$home/user-home
  mkdir -p "$spawn_home"
  FM_ROOT_OVERRIDE='' FM_HOME="$home" HOME="$spawn_home" \
    CLAUDE_CONFIG_DIR="${FM_TEST_CLAUDE_CONFIG_DIR:-}" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$pane" TMUX="${TMUX:-fake,1,0}" \
    PATH="$fakebin:$PATH" \
    "$ROOT/bin/fm-spawn.sh" "$@" 2>&1
}

# --- send-world stubs -------------------------------------------------------

# make_stubs <dir>
# Send-world fakebin: send tmux + no-op sleep. Echoes the fakebin path.
# Suites that need recording sleep, herdr, or ssh add those on top of this
# fakebin (or replace sleep via fm_test_fake_sleep_log).
make_stubs() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  fm_test_fake_tmux_send "$fakebin"
  fm_test_fake_sleep_noop "$fakebin"
  printf '%s\n' "$fakebin"
}

# fm_test_make_quota_fake <fakebin> <spec>
# A fake quota-axi whose verdict per profile directory is driven by files the
# test writes. <spec> is a directory holding one file per state:
#   <spec>/oauth        newline-separated CLAUDE_CONFIG_DIR values that are logged in
#   <spec>/rate_limited newline-separated CLAUDE_CONFIG_DIR values that are signed
#                       in but whose quota endpoint is rate limiting them
#   <spec>/expired_refreshable  values whose session is signed in but whose
#                       access token has lapsed and can still be renewed
#   <spec>/expired_refreshable_confirmed  the same state reported through
#                       quota-axi's other route, with different error text, so a
#                       case can prove the verdict comes from the authStatus
#                       field and not from any message
#   <spec>/signed_out   values that are genuinely signed out on a Keychain-backed
#                       store, the shape Claude Code leaves after Anthropic
#                       rejects a refresh token
#   <spec>/rejected_401 values whose locally valid credential the usage
#                       endpoint rejected with a 401, which quota-axi reports as
#                       auth_required with a failed keychain attempt
#   <spec>/remaining    percent remaining reported for a logged-in profile's
#                       account-level (all_models) window
#   <spec>/availability optional JSON array replacing the whole
#                       effectiveAvailability list, for scope-specific cases
#   <spec>/remaining_map  optional "<CLAUDE_CONFIG_DIR><TAB><percent>" rows,
#                       giving a profile its OWN percent remaining so a case can
#                       drive candidate seats apart; a profile with no row falls
#                       back to <spec>/remaining
#   <spec>/unreadable_quota  newline-separated CLAUDE_CONFIG_DIR values that are
#                       logged in but whose account-level availability cannot be
#                       read, which must never be guessed at as headroom
#   <spec>/extra_map    optional "<CLAUDE_CONFIG_DIR><TAB><spentUsd>" rows adding
#                       an extra_usage window (kind credits) to that profile's
#                       report, which is where paid overflow spend is observed
#   <spec>/slow         optional seconds every read sleeps before answering, for
#                       a quota endpoint slower than the watcher's budget
# An empty CLAUDE_CONFIG_DIR is spelled "(default)" in the oauth list.
# The fake reproduces the real tool's contract that matters here: an unavailable
# provider still prints a valid report AND exits non-zero.
fm_test_make_quota_fake() {
  local fakebin=$1 spec=$2
  mkdir -p "$spec"
  cat > "$fakebin/quota-axi" <<SH
#!/usr/bin/env bash
set -u
spec="$spec"
key="\${CLAUDE_CONFIG_DIR:-}"
[ -n "\$key" ] || key='(default)'
[ ! -f "\$spec/slow" ] || sleep "\$(cat "\$spec/slow")"
remaining=\$(cat "\$spec/remaining" 2>/dev/null || printf '80')
if [ -f "\$spec/remaining_map" ]; then
  mapped=\$(awk -F'\t' -v k="\$key" '\$1==k{print \$2; exit}' "\$spec/remaining_map")
  [ -z "\$mapped" ] || remaining=\$mapped
fi
availability=\$(cat "\$spec/availability" 2>/dev/null ||
  printf '[{"scope":"all_models","status":"known","effectivePercentRemaining":%s,"runway":{"status":"through_reset"}}]' "\$remaining")
if [ -f "\$spec/unreadable_quota" ] && grep -Fxq "\$key" "\$spec/unreadable_quota"; then
  availability='[]'
fi
windows='[]'
if [ -f "\$spec/extra_map" ]; then
  spent=\$(awk -F'\t' -v k="\$key" '\$1==k{print \$2; exit}' "\$spec/extra_map")
  [ -z "\$spent" ] ||
    windows=\$(printf '[{"id":"extra_usage","kind":"credits","percentUsed":1,"spentUsd":%s,"limitUsd":10000}]' "\$spent")
fi
if [ -f "\$spec/rate_limited" ] && grep -Fxq "\$key" "\$spec/rate_limited"; then
  cat <<'JSON'
{"generatedAt":"2026-01-01T00:00:00Z","schemaVersion":5,"providers":[{"provider":"claude","label":"Claude","source":"unavailable","windows":[],"state":{"status":"rate_limited","error":"Claude quota endpoint rate limited"},"attempts":[{"source":"oauth-file","status":"skipped","error":"credentials_missing"},{"source":"keychain","status":"failed","error":"Claude quota endpoint rate limited"}],"quotaSemantics":{"status":"unknown","effectiveAvailability":[]}}]}
JSON
  exit 1
fi
if [ -f "\$spec/expired_refreshable" ] && grep -Fxq "\$key" "\$spec/expired_refreshable"; then
  # Signed in, access token lapsed, session still renewable. Captured from
  # quota-axi 0.1.53 against a Keychain-backed profile holding an expired
  # credential that still carried a refresh token.
  cat <<'JSON'
{"generatedAt":"2026-01-01T00:00:00Z","schemaVersion":5,"providers":[{"provider":"claude","label":"Claude","source":"unavailable","windows":[],"state":{"status":"unavailable","stale":false,"error":"Claude access token expired","authStatus":"expired_refreshable","sourcesTried":["oauth-file","keychain"]},"attempts":[{"source":"oauth-file","status":"skipped","error":"credentials_missing"},{"source":"keychain","status":"failed","error":"Claude quota endpoint rate limited"}],"quotaSemantics":{"status":"unknown","effectiveAvailability":[]}}]}
JSON
  exit 1
fi
if [ -f "\$spec/expired_refreshable_confirmed" ] && grep -Fxq "\$key" "\$spec/expired_refreshable_confirmed"; then
  # The SAME state reached by the other route, when the quota endpoint rate
  # limited the read and quota-axi confirmed the expiry against the profile
  # endpoint instead. Its error text and attempts differ; only authStatus is
  # common, which is what the classifier is required to key on.
  cat <<'JSON'
{"generatedAt":"2026-01-01T00:00:00Z","schemaVersion":5,"providers":[{"provider":"claude","label":"Claude","source":"unavailable","windows":[],"state":{"status":"unavailable","stale":false,"error":"Claude credential expired","authStatus":"expired_refreshable","sourcesTried":["oauth-file","keychain"]},"attempts":[{"source":"oauth-file","status":"skipped","error":"credentials_missing"},{"source":"keychain","status":"failed","error":"Claude quota endpoint rate limited"},{"source":"oauth-profile","status":"failed","error":"identity_profile_http_401"}],"quotaSemantics":{"status":"unknown","effectiveAvailability":[]}}]}
JSON
  exit 1
fi
if [ -f "\$spec/signed_out" ] && grep -Fxq "\$key" "\$spec/signed_out"; then
  # Genuinely signed out on a Keychain-backed store: Anthropic rejected the
  # refresh token and Claude Code cleared the session in place, leaving the
  # Keychain item present but emptied. Captured from quota-axi 0.1.53 after
  # exactly that happened to a throwaway seat. Note it is NOT the
  # every-attempt-credentials_missing shape - the Keychain attempt reports
  # credentials_invalid.
  cat <<'JSON'
{"generatedAt":"2026-01-01T00:00:00Z","schemaVersion":5,"providers":[{"provider":"claude","label":"Claude","source":"unavailable","windows":[],"state":{"status":"auth_required","stale":false,"error":"credentials_invalid","sourcesTried":["oauth-file","keychain"]},"attempts":[{"source":"oauth-file","status":"skipped","error":"credentials_missing"},{"source":"keychain","status":"skipped","error":"credentials_invalid","credentialPresent":true}],"quotaSemantics":{"status":"unknown","effectiveAvailability":[]}}]}
JSON
  exit 1
fi
if [ -f "\$spec/rejected_401" ] && grep -Fxq "\$key" "\$spec/rejected_401"; then
  # The usage endpoint answered 401 for a credential that is locally unexpired
  # and still holds a refresh token. quota-axi raises auth_required for any 401,
  # so the status matches the signed-out shape while the store proves nothing.
  cat <<'JSON'
{"generatedAt":"2026-01-01T00:00:00Z","schemaVersion":5,"providers":[{"provider":"claude","label":"Claude","source":"unavailable","windows":[],"state":{"status":"auth_required","stale":false,"error":"Claude sign-in required","sourcesTried":["oauth-file","keychain"]},"attempts":[{"source":"oauth-file","status":"skipped","error":"credentials_missing"},{"source":"keychain","status":"failed","error":"Claude sign-in required"}],"quotaSemantics":{"status":"unknown","effectiveAvailability":[]}}]}
JSON
  exit 1
fi
if [ -f "\$spec/oauth" ] && grep -Fxq "\$key" "\$spec/oauth"; then
  semantics_status=known
  [ "\$availability" != '[]' ] || semantics_status=unknown
  cat <<JSON
{"generatedAt":"2026-01-01T00:00:00Z","schemaVersion":5,"providers":[{"provider":"claude","label":"Claude","source":"oauth","account":{"email":"seat-\$(printf '%s' "\$key" | tr -c 'a-zA-Z0-9' '-')@example.test"},"windows":\$windows,"quotaSemantics":{"status":"\$semantics_status","effectiveAvailability":\$availability}}]}
JSON
  exit 0
fi
if [ -f "\$spec/proven_empty" ] && grep -Fxq "\$key" "\$spec/proven_empty"; then
  # A file-backed credential store that was actually read and found empty: the
  # only shape that establishes absence. No keychain attempt is reported.
  cat <<'JSON'
{"generatedAt":"2026-01-01T00:00:00Z","schemaVersion":5,"providers":[{"provider":"claude","label":"Claude","source":"unavailable","windows":[],"state":{"status":"error","error":"credentials_missing"},"attempts":[{"source":"oauth-file","status":"skipped","error":"credentials_missing"}],"quotaSemantics":{"status":"unknown","effectiveAvailability":[]}}]}
JSON
  exit 1
fi
# Default: the store could not be READ. On macOS this is what both a
# never-logged-in profile and a signed-in-but-unapproved one report, so it
# establishes nothing and must read as undecided.
cat <<'JSON'
{"generatedAt":"2026-01-01T00:00:00Z","schemaVersion":5,"providers":[{"provider":"claude","label":"Claude","source":"unavailable","windows":[],"state":{"status":"error","error":"keychain_unreachable"},"attempts":[{"source":"oauth-file","status":"skipped","error":"credentials_missing"},{"source":"keychain","status":"skipped","error":"keychain_unreachable"}],"quotaSemantics":{"status":"unknown","effectiveAvailability":[]}}]}
JSON
exit 1
SH
  chmod +x "$fakebin/quota-axi"
}
