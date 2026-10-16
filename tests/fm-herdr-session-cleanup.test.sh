#!/usr/bin/env bash
# Focused safety tests for bin/fm-herdr-session-cleanup.sh.
# Covers one exact cleanup, every title/journal/topology/agent/process refusal,
# locked revalidation races, focus refusal, read errors, repeat idempotence,
# and the per-run journal index that keeps discovery off a per-candidate rescan.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-herdr-session-cleanup)
FM_TEST_CLEANUP_DIRS+=("$TMP_ROOT")
trap fm_test_cleanup EXIT

export FM_HOME="$TMP_ROOT/home"
export FM_STATE_OVERRIDE="$FM_HOME/state"
export FM_CONFIG_OVERRIDE="$FM_HOME/config"
mkdir -p "$FM_STATE_OVERRIDE" "$FM_CONFIG_OVERRIDE"
touch "$FM_CONFIG_OVERRIDE/herdr-presentation-spaces"
printf '%s\n' herdr > "$FM_CONFIG_OVERRIDE/backend"
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
fm_fake_exit0 "$FAKEBIN" herdr
export PATH="$FAKEBIN:$PATH"
export FM_HERDR_SESSION_CLEANUP_SOURCE_ONLY=1
# shellcheck source=/dev/null
. "$ROOT/bin/fm-herdr-session-cleanup.sh"
unset FM_HERDR_SESSION_CLEANUP_SOURCE_ONLY

# The idle-shell proof now lives in the backend as
# fm_backend_herdr_pane_idle_shell_pid; prove it still reads Linux argv
# arrays (no argv0 field) and rejects malformed executable identities.
FAKE_PS="$TMP_ROOT/fake-ps"
cat > "$FAKE_PS" <<'SH'
#!/usr/bin/env bash
case "$*" in
  "-axo pid=,ppid=") printf '1 0\n67 1\n' ;;
  "-p 67 -o stat=") printf 'Ss\n' ;;
  *) exit 1 ;;
esac
SH
chmod +x "$FAKE_PS"
LINUX_PROCESS_INFO='{"result":{"type":"pane_process_info","process_info":{"pane_id":"w2:p1","shell_pid":67,"foreground_process_group_id":67,"foreground_processes":[{"argv":["/bin/sh"],"name":"sh","pid":67}]}}}'
argv_pid=$(
  # shellcheck disable=SC2329 # invoked indirectly by the idle-shell proof.
  fm_backend_herdr_cli() { printf '%s\n' "$LINUX_PROCESS_INFO"; }
  FM_HERDR_PS_BIN="$FAKE_PS" fm_backend_herdr_pane_idle_shell_pid test w2:p1
) || fail "Linux Herdr process argv array was not accepted"
[ "$argv_pid" = 67 ] || fail "idle-shell proof printed the wrong shell pid: $argv_pid"
if (
  # shellcheck disable=SC2329 # invoked indirectly by the idle-shell proof.
  fm_backend_herdr_cli() { printf '%s\n' '{"result":{"type":"pane_process_info","process_info":{"pane_id":"w2:p1","shell_pid":67,"foreground_process_group_id":67,"foreground_processes":[{"argv":[67],"name":"sh","pid":67}]}}}'; }
  FM_HERDR_PS_BIN="$FAKE_PS" FM_BACKEND_HERDR_IDLE_SHELL_PROOF_POLLS=1 \
    fm_backend_herdr_pane_idle_shell_pid test w2:p1
) >/dev/null 2>&1; then
  fail "non-string Herdr process argv was accepted"
fi
pass "process proof reads Linux Herdr argv arrays and rejects malformed executable identities"

TOKEN=AbCdEfGhIjKlMnOpQrStUv
ID=task
WS=w2
TAB=w2:t1
PANE=w2:p1
TITLE="└ task · p:$TOKEN"
FIXTURE_DIR="$TMP_ROOT/fixture"
LOCK_LOG="$TMP_ROOT/locks.log"
CLOSE_LOG="$TMP_ROOT/closes.log"
mkdir -p "$FIXTURE_DIR"

fm_backend_name() { printf herdr; }
fm_backend_herdr_session() { printf test; }
fm_backend_herdr_presentation_session_lock_path() { printf '%s/presentation.lock' "$TMP_ROOT"; }
fm_lock_try_acquire() {
  printf '%s\n' "$1" >> "$LOCK_LOG"
  mkdir "$1" 2>/dev/null
}
fm_lock_release() { rm -rf -- "$1"; }
fm_backend_herdr_pane_idle_shell_pid() { [ ! -e "$FIXTURE_DIR/process-unsafe" ] && printf '67\n'; }
fm_backend_herdr_projection_focus_snapshot() {
  [ ! -e "$FIXTURE_DIR/focus-unreadable" ] || return 1
  printf 'w1\t%s' "$(cat "$FIXTURE_DIR/active-tab")"
}

fixture_workspace_json() {
  local title=$1 tabs=$2 panes=$3 focused=false active=$TAB
  [ "$(cat "$FIXTURE_DIR/active-tab")" = "$TAB" ] && focused=true
  printf '{"workspace_id":"%s","label":"%s","focused":%s,"active_tab_id":"%s","tab_count":%s,"pane_count":%s}' \
    "$WS" "$title" "$focused" "$active" "$tabs" "$panes"
}

fixture_workspaces() {
  local title tabs panes
  title=$(cat "$FIXTURE_DIR/title")
  tabs=$(cat "$FIXTURE_DIR/tabs")
  panes=$(cat "$FIXTURE_DIR/panes")
  printf '[{"workspace_id":"w1","label":"firstmate","focused":%s,"active_tab_id":"w1:t1","tab_count":1,"pane_count":1},' \
    "$( [ "$(cat "$FIXTURE_DIR/active-tab")" = w1:t1 ] && printf true || printf false )"
  fixture_workspace_json "$title" "$tabs" "$panes"
  if [ -e "$FIXTURE_DIR/duplicate-token" ]; then
    printf ',{"workspace_id":"w3","label":"└ copy · p:%s","focused":false,"active_tab_id":"w3:t1","tab_count":1,"pane_count":1}' "$TOKEN"
  fi
  # Extra live candidates whose labels derive from this home's other journals,
  # which is the shape a shared named session actually has: many candidates
  # against many journals. Their own workspaces carry no tab or pane rows, so
  # each one matches a journal and is then preserved by the topology proof.
  if [ -e "$FIXTURE_DIR/decoys" ]; then
    printf ',{"workspace_id":"w10","label":"└ decoy-one · p:%s","focused":false,"active_tab_id":"w10:t1","tab_count":1,"pane_count":1}' "$(index_token 1)"
    printf ',{"workspace_id":"w11","label":"└ decoy-two · p:%s","focused":false,"active_tab_id":"w11:t1","tab_count":1,"pane_count":1}' "$(index_token 2)"
    printf ',{"workspace_id":"w12","label":"└ decoy-three · p:%s","focused":false,"active_tab_id":"w12:t1","tab_count":1,"pane_count":1}' "$(index_token 3)"
  fi
  printf ']'
}

fixture_tabs() {
  local count i
  count=$(cat "$FIXTURE_DIR/tabs")
  printf '['
  i=1
  while [ "$i" -le "$count" ]; do
    [ "$i" -eq 1 ] || printf ','
    printf '{"tab_id":"%s:t%s","workspace_id":"%s","focused":false,"label":"fm-task"}' "$WS" "$i" "$WS"
    i=$((i + 1))
  done
  printf ']'
}

fixture_panes() {
  local count i
  count=$(cat "$FIXTURE_DIR/panes")
  printf '['
  i=1
  while [ "$i" -le "$count" ]; do
    [ "$i" -eq 1 ] || printf ','
    printf '{"pane_id":"%s:p%s","tab_id":"%s:t%s","workspace_id":"%s","agent_status":"unknown"}' \
      "$WS" "$i" "$WS" "$i" "$WS"
    i=$((i + 1))
  done
  printf ']'
}

fm_backend_herdr_cli() {
  local _session=$1 first=${2:-} second=${3:-} title tabs panes
  shift
  [ ! -e "$FIXTURE_DIR/error-${first}-${second}" ] || return 1
  if [ -e "$FIXTURE_DIR/closed" ]; then
    case "$first $second" in
      "pane get") printf '%s\n' '{"error":{"code":"pane_not_found"}}' >&2; return 1 ;;
      "workspace list") printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w1","label":"firstmate","focused":true,"active_tab_id":"w1:t1","tab_count":1,"pane_count":1}]}}'; return 0 ;;
    esac
  fi
  if [ -e "$FIXTURE_DIR/race" ] && [ -e "$FIXTURE_DIR/snapshotted" ] && [ "$first $second" = "workspace list" ]; then
    printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w1","label":"firstmate","focused":true,"active_tab_id":"w1:t1","tab_count":1,"pane_count":1},{"workspace_id":"w2","label":"renamed","focused":false,"active_tab_id":"w2:t1","tab_count":1,"pane_count":1}]}}'
    return 0
  fi
  title=$(cat "$FIXTURE_DIR/title")
  tabs=$(cat "$FIXTURE_DIR/tabs")
  panes=$(cat "$FIXTURE_DIR/panes")
  case "$first $second" in
    "workspace list")
      printf '{"result":{"workspaces":'; fixture_workspaces; printf '}}\n'
      ;;
    "workspace get")
      printf '{"result":{"workspace":'; fixture_workspace_json "$title" "$tabs" "$panes"; printf '}}\n'
      ;;
    "tab list")
      printf '{"result":{"tabs":'; fixture_tabs; printf '}}\n'
      ;;
    "pane list")
      printf '{"result":{"panes":'; fixture_panes; printf '}}\n'
      ;;
    "pane get")
      printf '{"result":{"pane":{"pane_id":"%s","tab_id":"%s","workspace_id":"%s"}}}\n' "$PANE" "$TAB" "$WS"
      ;;
    "agent get")
      case "$(cat "$FIXTURE_DIR/agent")" in
        absent) printf '%s\n' '{"error":{"code":"agent_not_found"}}' >&2; return 1 ;;
        live) printf '%s\n' '{"result":{"agent":{"agent_status":"idle"}}}' ;;
        unknown) printf '%s\n' '{"error":{"code":"internal_error"}}' >&2; return 1 ;;
      esac
      ;;
    "api snapshot")
      : > "$FIXTURE_DIR/snapshotted"
      printf '{"result":{"snapshot":{"focused_workspace_id":"w1","focused_tab_id":"%s","focused_pane_id":"w1:p1","workspaces":' "$(cat "$FIXTURE_DIR/active-tab")"
      fixture_workspaces
      printf ',"tabs":'; fixture_tabs
      printf ',"panes":'; fixture_panes
      printf '}}}\n'
      ;;
    "session list")
      printf '%s\n' '{"sessions":[{"name":"test","running":true,"socket_path":"/tmp/fake.sock"}]}'
      ;;
    "pane close")
      : > "$FIXTURE_DIR/closed"
      ;;
    *) return 1 ;;
  esac
}

fm_backend_herdr_projection_close_pane_focus_preserving() {
  [ ! -e "$FIXTURE_DIR/focus-refuse" ] || return 1
  [ "${3:-}" = no-agent ] || return 1
  printf '%s\n' "$*" >> "$CLOSE_LOG"
  : > "$FIXTURE_DIR/closed"
}

write_v1() { # <id> [token]
  local id=$1 token=${2:-$TOKEN}
  {
    printf 'version=1\n'
    printf 'task_id=%s\n' "$id"
    printf 'projection_id=%s\n' "$token"
  } > "$FM_STATE_OVERRIDE/$id.herdr-presentation"
}

write_v2() { # <home> <workspace> <tab> <pane>
  local home=$1 workspace=$2 tab=$3 pane=$4
  {
    printf 'version=2\n'
    printf 'task_id=%s\n' "$ID"
    printf 'projection_id=%s\n' "$TOKEN"
    printf 'home=%s\n' "$home"
    printf 'session=test\nworkspace_id=%s\ntab_id=%s\npane_id=%s\n' "$workspace" "$tab" "$pane"
    printf 'parent_workspace_id=w1\nparent_label=firstmate\nworkspace_label=%s\ntask_label=fm-%s\n' "$TITLE" "$ID"
  } > "$FM_STATE_OVERRIDE/$ID.herdr-presentation"
}

write_cross_home_v2() {
  mkdir -p "$TMP_ROOT/other-home"
  write_v2 "$TMP_ROOT/other-home" "$WS" "$TAB" "$PANE"
}

reset_fixture() {
  rm -rf "$FIXTURE_DIR" "$TMP_ROOT"/*.lock "${FM_STATE_OVERRIDE:?}/"*
  mkdir -p "$FIXTURE_DIR"
  : > "$LOCK_LOG"; : > "$CLOSE_LOG"
  printf '%s\n' "$TITLE" > "$FIXTURE_DIR/title"
  printf '1\n' > "$FIXTURE_DIR/tabs"
  printf '1\n' > "$FIXTURE_DIR/panes"
  printf 'w1:t1\n' > "$FIXTURE_DIR/active-tab"
  printf 'absent\n' > "$FIXTURE_DIR/agent"
  write_v1 "$ID"
}

assert_preserved() { # <case>
  local name=$1 had_journal=0
  [ -f "$FM_STATE_OVERRIDE/$ID.herdr-presentation" ] && had_journal=1
  fm_herdr_session_cleanup >/dev/null 2>&1
  if [ "$had_journal" -eq 1 ]; then
    [ -f "$FM_STATE_OVERRIDE/$ID.herdr-presentation" ] || fail "$name retired the journal"
  fi
  [ ! -s "$CLOSE_LOG" ] || fail "$name closed the pane"
  pass "$name preserves the candidate"
}

reset_fixture
fm_herdr_session_cleanup >/dev/null 2>&1
[ ! -e "$FM_STATE_OVERRIDE/$ID.herdr-presentation" ] || fail "positive cleanup kept the journal"
[ "$(wc -l < "$CLOSE_LOG" | tr -d ' ')" = 1 ] || fail "positive cleanup did not close exactly once"
[ "$(sed -n '1p' "$LOCK_LOG")" = "$FM_STATE_OVERRIDE/.spawn-$ID.lock" ] || fail "task lock was not acquired first"
[ "$(sed -n '2p' "$LOCK_LOG")" = "$TMP_ROOT/presentation.lock" ] || fail "presentation lock was not acquired second"
pass "exact stale projection closes one exact pane under task then presentation locks"
fm_herdr_session_cleanup >/dev/null 2>&1
[ "$(wc -l < "$CLOSE_LOG" | tr -d ' ')" = 1 ] || fail "repeat cleanup closed again"
pass "successful cleanup is idempotent on repeat"

reset_fixture; printf '%s\n' '└ malformed p:AbCdEfGhIjKlMnOpQrStUv' > "$FIXTURE_DIR/title"; assert_preserved "malformed title"
reset_fixture; printf '%s\n' '└ missing-token' > "$FIXTURE_DIR/title"; assert_preserved "missing token"
reset_fixture; printf 'version=1\ntask_id=%s\nprojection_id=short\n' "$ID" > "$FM_STATE_OVERRIDE/$ID.herdr-presentation"; assert_preserved "malformed journal"
reset_fixture; : > "$FIXTURE_DIR/duplicate-token"; assert_preserved "duplicate token"
reset_fixture; printf '%s\n' "└ task · p:$TOKEN p:$TOKEN" > "$FIXTURE_DIR/title"; assert_preserved "duplicate title token"
reset_fixture; rm -f "$FM_STATE_OVERRIDE/$ID.herdr-presentation"; assert_preserved "zero journal match"
reset_fixture; write_v1 fm-task; assert_preserved "multiple journal matches"
reset_fixture; rm -f "$FM_STATE_OVERRIDE/$ID.herdr-presentation"; write_cross_home_v2; assert_preserved "cross-home journal"
reset_fixture; write_v2 "$FM_HOME" w9 "$TAB" "$PANE"; assert_preserved "v2 workspace binding mismatch"
reset_fixture; write_v2 "$FM_HOME" "$WS" w9:t1 "$PANE"; assert_preserved "v2 tab binding mismatch"
reset_fixture; write_v2 "$FM_HOME" "$WS" "$TAB" w9:p1; assert_preserved "v2 pane binding mismatch"
reset_fixture; write_v2 "$FM_HOME" "$WS" "$TAB" "$PANE"
fm_herdr_session_cleanup >/dev/null 2>&1
[ ! -e "$FM_STATE_OVERRIDE/$ID.herdr-presentation" ] || fail "matching v2 cleanup kept the journal"
[ "$(wc -l < "$CLOSE_LOG" | tr -d ' ')" = 1 ] || fail "matching v2 cleanup did not close exactly once"
pass "v2 cleanup requires and accepts the exact journal endpoint binding"
reset_fixture; : > "$FM_STATE_OVERRIDE/$ID.meta"; assert_preserved "current task metadata"
reset_fixture; printf 'live\n' > "$FIXTURE_DIR/agent"; assert_preserved "registered agent"
reset_fixture; printf 'unknown\n' > "$FIXTURE_DIR/agent"; assert_preserved "unknown agent"
reset_fixture; printf '2\n' > "$FIXTURE_DIR/tabs"; printf '2\n' > "$FIXTURE_DIR/panes"; assert_preserved "multiple tabs"
reset_fixture; printf '2\n' > "$FIXTURE_DIR/panes"; assert_preserved "multiple panes"
reset_fixture; : > "$FIXTURE_DIR/process-unsafe"; assert_preserved "non-idle shell"
reset_fixture; : > "$FIXTURE_DIR/process-unsafe"; assert_preserved "child process or shell job"
reset_fixture; : > "$FIXTURE_DIR/error-api-snapshot"; assert_preserved "unreadable snapshot"
reset_fixture; : > "$FIXTURE_DIR/error-workspace-get"; assert_preserved "unreadable topology check"
reset_fixture; : > "$FIXTURE_DIR/race"; assert_preserved "revalidation race"
reset_fixture; printf '%s\n' "$TAB" > "$FIXTURE_DIR/active-tab"; assert_preserved "active target"
reset_fixture; : > "$FIXTURE_DIR/focus-refuse"; assert_preserved "focus refusal"

# --- journal indexing -------------------------------------------------------
# Discovery compares every live workspace label in the machine's shared named
# Herdr session against this home's own journals, so the journals are indexed in
# one pass per run instead of being reparsed for every candidate. Two properties
# have to hold together: the indexed answer must be the same answer a
# per-candidate scan gives, and the index must genuinely be that one pass.

index_token() { # <suffix>
  printf 'AbCdEfGhIjKlMnOpQrStU%s' "$1"
}

reset_fixture
rm -f "${FM_STATE_OVERRIDE:?}"/*.herdr-presentation
# A deliberate mix, so parity covers every per-journal verdict the scan makes:
# three plain attempts, one version 2 journal bound to this home and session,
# one bound to another home, and one malformed journal.
write_v1 alpha "$(index_token 1)"
write_v1 bravo "$(index_token 2)"
write_v1 charlie "$(index_token 3)"
{
  printf 'version=2\ntask_id=delta\nprojection_id=%s\n' "$(index_token 4)"
  printf 'home=%s\nsession=test\nworkspace_id=w4\ntab_id=w4:t1\npane_id=w4:p1\n' "$FM_HOME"
  printf 'parent_workspace_id=w1\nparent_label=firstmate\nworkspace_label=└ delta · p:%s\ntask_label=fm-delta\n' \
    "$(index_token 4)"
} > "$FM_STATE_OVERRIDE/delta.herdr-presentation"
mkdir -p "$TMP_ROOT/foreign-home"
{
  printf 'version=2\ntask_id=echo\nprojection_id=%s\n' "$(index_token 5)"
  printf 'home=%s\nsession=test\nworkspace_id=w5\ntab_id=w5:t1\npane_id=w5:p1\n' "$TMP_ROOT/foreign-home"
  printf 'parent_workspace_id=w1\nparent_label=firstmate\nworkspace_label=└ echo · p:%s\ntask_label=fm-echo\n' \
    "$(index_token 5)"
} > "$FM_STATE_OVERRIDE/echo.herdr-presentation"
printf 'version=1\ntask_id=foxtrot\nprojection_id=short\n' \
  > "$FM_STATE_OVERRIDE/foxtrot.herdr-presentation"

HOME_REAL=$(fm_herdr_cleanup_home_identity) || fail "the test home identity was unreadable"
fm_herdr_cleanup_index_journals test "$HOME_REAL" || fail "the journal index could not be built"

# Every candidate title a run could see: one per journal written above, the
# live-fixture title, and titles that match nothing.
INDEX_TITLES=(
  "└ alpha · p:$(index_token 1)"
  "└ bravo · p:$(index_token 2)"
  "└ charlie · p:$(index_token 3)"
  "└ delta · p:$(index_token 4)"
  "└ echo · p:$(index_token 5)"
  "└ foxtrot · p:short"
  "$TITLE"
  "firstmate"
  "└ alpha · p:$(index_token 2)"
)
for title in "${INDEX_TITLES[@]}"; do
  cached=$(fm_herdr_cleanup_journal_matches "$title" test "$HOME_REAL" 1)
  fresh=$(fm_herdr_cleanup_journal_matches "$title" test "$HOME_REAL" 0)
  [ "$cached" = "$fresh" ] \
    || fail "indexed and rescanned matches differ for '$title': [$cached] vs [$fresh]"
done
[ "$(fm_herdr_cleanup_journal_matches "└ alpha · p:$(index_token 1)" test "$HOME_REAL" 1)" \
  = "$(printf '%s\t%s\t%s' "$FM_STATE_OVERRIDE/alpha.herdr-presentation" alpha "$(index_token 1)")" ] \
  || fail "the index did not match the one journal whose label equals the candidate title"
[ -z "$(fm_herdr_cleanup_journal_matches "└ echo · p:$(index_token 5)" test "$HOME_REAL" 1)" ] \
  || fail "the index matched a version 2 journal bound to another home"
[ -z "$(fm_herdr_cleanup_journal_matches "└ foxtrot · p:short" test "$HOME_REAL" 1)" ] \
  || fail "the index matched a malformed journal"
pass "indexed journal matching is identical to a per-candidate rescan across every candidate title"

# The index is one pass per run, so a journal rewritten after it was built keeps
# answering from the index - and anything a mutation depends on, which always
# asks for a rescan, sees the new bytes instead.
write_v1 alpha "$(index_token 6)"
[ "$(fm_herdr_cleanup_journal_matches "└ alpha · p:$(index_token 1)" test "$HOME_REAL" 1)" \
  = "$(printf '%s\t%s\t%s' "$FM_STATE_OVERRIDE/alpha.herdr-presentation" alpha "$(index_token 1)")" ] \
  || fail "a cached lookup reparsed a journal the run had already indexed"
[ -z "$(fm_herdr_cleanup_journal_matches "└ alpha · p:$(index_token 1)" test "$HOME_REAL" 0)" ] \
  || fail "a rescan did not see the rewritten journal"
[ "$(fm_herdr_cleanup_journal_matches "└ alpha · p:$(index_token 6)" test "$HOME_REAL" 0)" \
  = "$(printf '%s\t%s\t%s' "$FM_STATE_OVERRIDE/alpha.herdr-presentation" alpha "$(index_token 6)")" ] \
  || fail "a rescan did not match the rewritten journal's new label"
pass "the per-run index is one pass, and every mutation prerequisite still rescans"

# End to end with several candidates and several journals: exactly the one
# candidate whose topology, metadata, agent, process, and focus all check out is
# retired, and every other journal survives untouched.
reset_fixture
write_v1 decoy-one "$(index_token 1)"
write_v1 decoy-two "$(index_token 2)"
write_v1 decoy-three "$(index_token 3)"
: > "$FIXTURE_DIR/decoys"
fm_herdr_session_cleanup >/dev/null 2>&1
[ ! -e "$FM_STATE_OVERRIDE/$ID.herdr-presentation" ] \
  || fail "the one exact candidate among several was not retired"
for id in decoy-one decoy-two decoy-three; do
  [ -f "$FM_STATE_OVERRIDE/$id.herdr-presentation" ] \
    || fail "a candidate that failed its topology proof lost its journal"
done
[ "$(wc -l < "$CLOSE_LOG" | tr -d ' ')" = 1 ] \
  || fail "a run over several candidates did not close exactly one pane"
pass "a run over several candidates and journals retires only the one exact match"

INTEGRATION_ROOT="$TMP_ROOT/bootstrap-integration"
mkdir -p "$INTEGRATION_ROOT/home/state" "$INTEGRATION_ROOT/home/data" "$INTEGRATION_ROOT/home/config"
cp -R "$ROOT/bin" "$INTEGRATION_ROOT/bin"
TRACE="$INTEGRATION_ROOT/cleanup.trace"
cat > "$INTEGRATION_ROOT/bin/fm-herdr-session-cleanup.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${FM_HOME:?}" >> "${FM_HERDR_CLEANUP_TRACE:?}"
SH
chmod +x "$INTEGRATION_ROOT/bin/fm-herdr-session-cleanup.sh"
printf '%s\n' manual > "$INTEGRATION_ROOT/home/config/backlog-backend"
FM_HOME="$INTEGRATION_ROOT/home" FM_HERDR_CLEANUP_TRACE="$TRACE" FM_BOOTSTRAP_DETECT_ONLY=1 \
  "$INTEGRATION_ROOT/bin/fm-bootstrap.sh" >/dev/null 2>&1
[ ! -e "$TRACE" ] || fail "detect-only bootstrap ran stale projection cleanup"
FM_HOME="$INTEGRATION_ROOT/home" FM_HERDR_CLEANUP_TRACE="$TRACE" \
  "$INTEGRATION_ROOT/bin/fm-bootstrap.sh" >/dev/null 2>&1
[ ! -e "$TRACE" ] || fail "standalone bootstrap ran lock-owned stale projection cleanup"
pass "standalone bootstrap cannot run lock-owned stale projection cleanup"

# The blocking digest must not depend on how many live panes the machine's
# shared named Herdr session holds, so a lock-owning session start hands this
# cleanup to the deferred startup stage instead of running it in front of
# bootstrap. The stage is replaced by a recorder here, so the assertion is about
# what session start itself does with no detached worker to race.
DEFER_LOG="$INTEGRATION_ROOT/deferred-stage.log"
cat > "$INTEGRATION_ROOT/bin/fm-startup-network.sh" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${FM_FAKE_DEFER_LOG:?}"
SH
chmod +x "$INTEGRATION_ROOT/bin/fm-startup-network.sh"
cat > "$INTEGRATION_ROOT/bin/fm-lock.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' 'lock acquired'
SH
chmod +x "$INTEGRATION_ROOT/bin/fm-lock.sh"
FM_HOME="$INTEGRATION_ROOT/home" FM_ROOT_OVERRIDE="$INTEGRATION_ROOT" \
  FM_HERDR_CLEANUP_TRACE="$TRACE" FM_FAKE_DEFER_LOG="$DEFER_LOG" \
  "$INTEGRATION_ROOT/bin/fm-session-start.sh" >/dev/null 2>&1 \
  || fail "lock-owning session start failed"
[ ! -s "$TRACE" ] \
  || fail "lock-owning session start still ran stale projection cleanup on its blocking path"
assert_grep '--locked 1' "$DEFER_LOG" \
  "lock-owning session start did not ask the deferred stage for its locked phases"

: > "$TRACE"
: > "$DEFER_LOG"
cat > "$INTEGRATION_ROOT/bin/fm-lock.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' 'error: another live firstmate session holds the lock' >&2
exit 1
SH
chmod +x "$INTEGRATION_ROOT/bin/fm-lock.sh"
FM_HOME="$INTEGRATION_ROOT/home" FM_ROOT_OVERRIDE="$INTEGRATION_ROOT" \
  FM_HERDR_CLEANUP_TRACE="$TRACE" FM_FAKE_DEFER_LOG="$DEFER_LOG" \
  "$INTEGRATION_ROOT/bin/fm-session-start.sh" >/dev/null 2>&1 \
  || fail "read-only session start failed"
[ ! -s "$TRACE" ] || fail "read-only session start ran stale projection cleanup"
[ ! -s "$DEFER_LOG" ] || fail "read-only session start started the deferred stage"
pass "session start never runs cleanup on its blocking path and defers it only when locked"

printf 'all fm-herdr-session-cleanup tests passed\n'
