#!/usr/bin/env bash
# Live lead-restart successor guard (live-harness-optin family).
#
# Exercises two real leader replacements in one isolated Herdr pane. The
# successor must run session start and take the lab lock without a submitted
# follow-up. The second replacement exercises the recorded launch argv rather
# than reconstructing the previous operational-input prompt as command flags.
#
# FM_LEAD_RESTART_SUCCESSOR_LIVE_PROVIDER selects claude (default) or codex.
# Both begin with a real Claude lead whose FM_HOME is assigned only inline;
# the pane shell carries a different marked fallback home. A successor that
# loses the leader environment therefore fails safely and observably.
# Codex uses a private seat home containing a copied auth.json, never a shared
# seat daemon or IPC directory. No remote-control daemon is started by this
# guard. Repository primary hooks remain enabled; approve their trust before
# the first restart when the installed harness requires it.
#
# Run explicitly with FM_LEAD_RESTART_SUCCESSOR_LIVE=1 after harness upgrades.
# FM_LEAD_RESTART_SUCCESSOR_LIVE_SEAT_DIR names a usable Claude seat.
# FM_LEAD_RESTART_SUCCESSOR_LIVE_CODEX_HOME names the credential source for
# Codex; only auth.json is copied and it is always deleted during cleanup.
# FM_LEAD_RESTART_SUCCESSOR_LIVE_SCRATCH overrides the sibling scratch root.
# Logs and lab state remain there for inspection, with credentials removed.
# This opt-in guard spends tokens and never substitutes a fake model turn.
# Every Herdr call goes through bin/fm-herdr-lab.sh, including production calls.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}

fail() { printf 'not ok - %s: %s\n' "${HARNESS_LABEL:-live successor}" "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

PROVIDER=${FM_LEAD_RESTART_SUCCESSOR_LIVE_PROVIDER:-claude}
case "$PROVIDER" in claude|codex) ;; *) fail "unsupported successor provider: $PROVIDER" ;; esac
LIVE_TOOLS=(herdr jq claude)
[ "$PROVIDER" != codex ] || LIVE_TOOLS+=(codex)
fm_live_gate opt-in FM_LEAD_RESTART_SUCCESSOR_LIVE "${LIVE_TOOLS[@]}"

[ -x "$LAB_HELPER" ] || fail "FM_LEAD_RESTART_SUCCESSOR_LIVE=1 but the Herdr lab helper is not executable at $LAB_HELPER"

# The seat the lab lead runs on. A restart refuses the ambient default profile
# as a destination, so this guard needs a named seat directory; it restarts in
# place on that one seat, so no seat record, rotation, or account changes.
SEAT_DIR=${FM_LEAD_RESTART_SUCCESSOR_LIVE_SEAT_DIR:-${CLAUDE_CONFIG_DIR:-}}
[ -n "$SEAT_DIR" ] && [ -d "$SEAT_DIR" ] ||
  fail "FM_LEAD_RESTART_SUCCESSOR_LIVE=1 needs a named Claude seat profile directory; set FM_LEAD_RESTART_SUCCESSOR_LIVE_SEAT_DIR, or run it from a session whose CLAUDE_CONFIG_DIR names one"
SEAT_DIR=$(cd -P "$SEAT_DIR" && pwd -P)
SEATS_ROOT=${SEAT_DIR%/*}
SEAT_NAME=${SEAT_DIR##*/}
[ -n "$SEATS_ROOT" ] && [ -n "$SEAT_NAME" ] ||
  fail "the seat profile $SEAT_DIR does not sit in a seats root this guard can name"

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane

ORIGINAL_PATH=$PATH
LAB_HOME_HELPER=${LAB_HOME_HELPER:-$ROOT/bin/fm-lab-home.sh}
SCRATCH=${FM_LEAD_RESTART_SUCCESSOR_LIVE_SCRATCH:-$ROOT/../.fm-test-scratch}
mkdir -p "$SCRATCH" || fail "cannot create scratch root"
TMP_ROOT=$(mktemp -d "$SCRATCH/lead-successor-$PROVIDER.XXXXXX")
export FM_HERDR_LAB_STATE_DIR="$TMP_ROOT/tripwires"
SESSION=$("$LAB_HELPER" name firstmate-on-codex)
export FM_HERDR_LAB="$SESSION"
FAKEBIN="$TMP_ROOT/fakebin"
HOME_DIR="$TMP_ROOT/home"
FALLBACK_HOME="$TMP_ROOT/fallback-home"
TRUST_HOME="$TMP_ROOT/trust-home"
CODEX_SEAT="$TMP_ROOT/codex-seats/lab-codex"
SUCCESSOR_PID=''
PANE=''
PROVISIONED=0
cleanup() {
  local rc=$? stray
  trap - EXIT
  if [ -n "$PANE" ]; then
    PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" pane read "$PANE" --source recent --lines 160 > "$TMP_ROOT/pane-final.txt" 2>&1 || true
  fi
  [ -z "$SUCCESSOR_PID" ] || kill "$SUCCESSOR_PID" 2>/dev/null || true
  for stray in $(PATH="$ORIGINAL_PATH" pgrep -f "$TMP_ROOT" 2>/dev/null || true); do
    [ "$stray" = "$$" ] || kill "$stray" 2>/dev/null || true
  done
  [ ! -f "$HOME_DIR/.fm-lab-home" ] || "$LAB_HOME_HELPER" teardown "$HOME_DIR" || rc=1
  [ ! -f "$FALLBACK_HOME/.fm-lab-home" ] || "$LAB_HOME_HELPER" teardown "$FALLBACK_HOME" || rc=1
  [ ! -f "$TRUST_HOME/.fm-lab-home" ] || "$LAB_HOME_HELPER" teardown "$TRUST_HOME" || rc=1
  if [ "$PROVISIONED" = 1 ]; then
    PATH="$ORIGINAL_PATH" "$LAB_HELPER" teardown "$SESSION" || rc=1
  fi
  rm -f "$CODEX_SEAT/auth.json"
  printf 'live successor evidence: %s (cleanup exit %s)\n' "$TMP_ROOT" "$rc"
  exit "$rc"
}
trap cleanup EXIT
"$LAB_HOME_HELPER" create "$HOME_DIR" >/dev/null || fail "cannot create lab home"
"$LAB_HOME_HELPER" create "$FALLBACK_HOME" >/dev/null || fail "cannot create fallback lab home"
mkdir -p "$FAKEBIN"
printf '%s\n' "$SEATS_ROOT" > "$HOME_DIR/config/claude-seats-root"
if [ "$PROVIDER" = codex ]; then
  AUTH_SOURCE=${FM_LEAD_RESTART_SUCCESSOR_LIVE_CODEX_HOME:-${CODEX_HOME:-}}
  [ -n "$AUTH_SOURCE" ] && [ -f "$AUTH_SOURCE/auth.json" ] || fail "Codex proof needs FM_LEAD_RESTART_SUCCESSOR_LIVE_CODEX_HOME with auth.json"
  (umask 077; mkdir -p "$CODEX_SEAT"; cp "$AUTH_SOURCE/auth.json" "$CODEX_SEAT/auth.json") || fail "cannot copy lab Codex authentication"
  chmod 700 "$CODEX_SEAT"
  cat > "$CODEX_SEAT/config.toml" <<EOF
model = "gpt-6.1-sol"
model_reasoning_effort = "low"
approval_policy = "never"
sandbox_mode = "danger-full-access"
[projects."$ROOT"]
trust_level = "trusted"
EOF
  printf '%s\n' "$TMP_ROOT/codex-seats" > "$HOME_DIR/config/codex-seats-root"
fi

# Every bare `herdr` the production scripts run inside the pane is re-executed
# through the lab helper, and a call naming any other session is refused rather
# than reaching the captain's fleet.
cat > "$FAKEBIN/herdr" <<EOF
#!/usr/bin/env bash
set -u
args=("\$@")
n=\${#args[@]}
if [ "\$n" -ge 2 ] && [ "\${args[\$((n-2))]}" = --session ]; then
  [ "\${args[\$((n-1))]}" = "$SESSION" ] || { echo "wrapper refused foreign session" >&2; exit 97; }
  args=("\${args[@]:0:\$((n-2))}")
else
  echo "wrapper requires trailing --session $SESSION" >&2
  exit 98
fi
exec env PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" "\${args[@]}"
EOF
chmod +x "$FAKEBIN/herdr"

PROVISIONED=1
"$LAB_HELPER" provision "$SESSION" || fail "could not provision the isolated Herdr lab"
export PATH="$FAKEBIN:$ORIGINAL_PATH"

# shellcheck source=bin/backends/herdr.sh
. "$ROOT/bin/backends/herdr.sh"

lab() { env PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" "$@"; }
VERSION=$(PATH="$ORIGINAL_PATH" claude --version 2>/dev/null | head -1 || printf 'version-unknown')
HERDR_VER=$(PATH="$ORIGINAL_PATH" herdr --version 2>/dev/null | head -1 || printf 'herdr-unknown')
SUCCESSOR_VERSION=$VERSION
[ "$PROVIDER" != codex ] || SUCCESSOR_VERSION=$(PATH="$ORIGINAL_PATH" codex --version 2>/dev/null | head -1 || printf 'version-unknown')
HARNESS_LABEL="$PROVIDER ($SUCCESSOR_VERSION) on $HERDR_VER"

if [ "$PROVIDER" = codex ]; then
  "$LAB_HOME_HELPER" create "$TRUST_HOME" >/dev/null || fail "cannot create hook-trust lab home"
  TRUST_WS=$(lab workspace create --cwd "$ROOT" --label codex-hook-trust --no-focus) || fail "cannot create hook-trust pane"
  TRUST_PANE=$(printf '%s' "$TRUST_WS" | jq -er '.result.root_pane.pane_id') || fail "missing hook-trust pane"
  lab pane run "$TRUST_PANE" "PATH='$FAKEBIN':\$PATH FM_HOME='$TRUST_HOME' FM_ROOT_OVERRIDE='$ROOT' CODEX_HOME='$CODEX_SEAT' codex --no-daemon --no-alt-screen -a never -s danger-full-access -m gpt-6.1-sol" >/dev/null || fail "cannot open Codex hook-trust setup"
  i=0
  HOOKS_TRUSTED=0
  TRUST_IDLE=0
  while [ "$i" -lt 120 ]; do
    TRUST_SCREEN=$(lab pane read "$TRUST_PANE" --source visible 2>/dev/null || true)
    case "$TRUST_SCREEN" in
      *'Hooks need review'*'Trust all and continue'*)
        if [ "$HOOKS_TRUSTED" = 0 ]; then
          printf '%s\n' "$TRUST_SCREEN" > "$TMP_ROOT/codex-hook-review.txt"
          lab pane send-keys "$TRUST_PANE" down enter >/dev/null || fail "cannot trust repository hooks in lab"
          HOOKS_TRUSTED=1
        fi
        ;;
      *'Ask Codex to do anything'*)
        if [ "$HOOKS_TRUSTED" = 1 ]; then
          TRUST_IDLE=$((TRUST_IDLE + 1))
          [ "$TRUST_IDLE" -lt 3 ] || break
        fi
        ;;
    esac
    i=$((i + 1))
    sleep 1
  done
  [ "$i" -lt 120 ] || fail "Codex never completed hook-trust setup"
  lab pane read "$TRUST_PANE" --source visible > "$TMP_ROOT/codex-hook-trusted.txt"
  lab pane send-keys "$TRUST_PANE" ctrl+c >/dev/null || fail "cannot close Codex setup"
  sleep 1
  lab pane send-keys "$TRUST_PANE" ctrl+c >/dev/null || fail "cannot finish closing Codex setup"
fi

WS_JSON=$(lab workspace create --cwd "$ROOT" --label fm-leadrestart --no-focus) ||
  fail "could not create the isolated lead-restart workspace"
PANE=$(printf '%s' "$WS_JSON" | jq -er '.result.root_pane.pane_id') ||
  fail "workspace create did not return a pane id"
TARGET="$SESSION:$PANE"

wait_for() {  # <seconds> <shell-test>
  local limit=$1 expr=$2 i=0
  while [ "$i" -lt "$limit" ]; do
    if eval "$expr"; then return 0; fi
    sleep 1
    i=$((i + 1))
  done
  return 1
}

# Deliberately do not export the lead's home into the pane shell. Its fallback
# is a separate empty lab home, so a lost binding never touches a real home.
lab pane run "$PANE" "export PATH='$FAKEBIN':\$PATH FM_ROOT_OVERRIDE='$FALLBACK_HOME'; unset FM_HOME FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE FM_DATA_OVERRIDE" >/dev/null ||
  fail "could not bind the lab wrapper and safe fallback"
lab pane run "$PANE" "FM_HOME='$HOME_DIR' FM_ROOT_OVERRIDE='$ROOT' CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false CLAUDE_CODE_SEND_FEEDBACK=0 CLAUDE_CONFIG_DIR='$SEAT_DIR' claude --dangerously-skip-permissions 'Run bash $ROOT/bin/fm-lock.sh once, then stop and report only the line it printed.'" >/dev/null ||
  fail "could not launch Claude Code ($VERSION) in the isolated Herdr pane"

trusted=0
i=0
while [ "$i" -lt 180 ]; do
  case "$(lab pane read "$PANE" --source visible 2>/dev/null || true)" in
    *'Yes, I trust this folder'*)
      # A fresh worktree path is a folder Claude has not seen. The prompt
      # preselects "No, exit", so move to "Yes" before confirming.
      if [ "$trusted" = 0 ]; then
        trusted=1
        lab pane send-keys "$PANE" down enter >/dev/null ||
          fail "could not accept Claude's folder-trust prompt"
      fi
      ;;
  esac
  [ ! -s "$HOME_DIR/state/.lock" ] || break
  i=$((i + 1))
  sleep 1
done
wait_for 60 "[ -s '$HOME_DIR/state/.lock-session' ] && grep -q '^target=' '$HOME_DIR/state/.lock-runtime' 2>/dev/null" ||
  fail "Claude Code ($VERSION) on $HERDR_VER never took the lab home's lock from its launch prompt: $(cat "$HOME_DIR/state/.lock-runtime" 2>/dev/null)"
OLD_PID=$(cat "$HOME_DIR/state/.lock")
SESSION_ID=$(cat "$HOME_DIR/state/.lock-session")
grep -q "^target=$TARGET\$" "$HOME_DIR/state/.lock-runtime" ||
  fail "the lab lead did not record its own Herdr pane: $(cat "$HOME_DIR/state/.lock-runtime")"
grep -q "^profile=$SEAT_DIR\$" "$HOME_DIR/state/.lock-runtime" ||
  fail "the lab lead did not record the seat it runs on: $(cat "$HOME_DIR/state/.lock-runtime")"
pass "live lead restart: Claude Code ($VERSION) on $HERDR_VER submits its launch prompt unaided and takes the lab home as session $SESSION_ID"

# Each restart gets one instruction to the current lead. After it is armed,
# neither the harness nor the test receives any further input until ownership
# and session-start completion have both been proved.
for ROUND in 1 2; do
  OLD_PID=$(cat "$HOME_DIR/state/.lock")
  SESSION_ID=$(cat "$HOME_DIR/state/.lock-session" 2>/dev/null || true)
  rm -f "$HOME_DIR/state/.lead-restart.result" "$HOME_DIR/state/.session-start-complete"
  i=0
  while [ "$i" -lt 120 ]; do
    case "$(lab agent get "$PANE" 2>/dev/null | jq -r '.result.agent.agent_status // empty')" in
      idle | done) break ;;
    esac
    i=$((i + 1))
    sleep 1
  done
  [ "$i" -lt 120 ] || fail "round $ROUND lead did not become idle"
  DESTINATION=$SEAT_NAME
  [ "$PROVIDER" != codex ] || DESTINATION='lab-codex'
  ARM="FM_LEAD_RESTART_CLAIM_WAIT=240 bash $ROOT/bin/fm-lead-restart.sh --provider $PROVIDER --to $DESTINATION --refresh --persisted"
  if [ "$ROUND" = 1 ] && [ "$PROVIDER" = claude ]; then
    ARM="$ARM --launch-command 'claude --dangerously-skip-permissions'"
  fi
  verdict=$(fm_backend_herdr_send_text_submit "$TARGET" \
    "Run exactly this, and nothing else, reporting only what it prints: $ARM" 3 0.4 0.4) ||
    fail "round $ROUND restart instruction could not be submitted"
  [ "$verdict" = empty ] || fail "round $ROUND restart instruction did not land (verdict '$verdict')"
  wait_for 300 "grep -q '^state=' '$HOME_DIR/state/.lead-restart.result' 2>/dev/null" ||
    fail "round $ROUND restart never reported an outcome"
  cp "$HOME_DIR/state/.lead-restart.result" "$TMP_ROOT/round-$ROUND.result"
  OUT=$(cat "$HOME_DIR/state/.lead-restart.result")
  case "$OUT" in *"state=done"*) ;; *) fail "$PROVIDER round $ROUND never took the home unaided: $OUT" ;; esac
  NEW_PID=$(cat "$HOME_DIR/state/.lock")
  SUCCESSOR_PID=$NEW_PID
  [ "$NEW_PID" != "$OLD_PID" ] || fail "round $ROUND lock still names outgoing process"
  kill -0 "$NEW_PID" 2>/dev/null || fail "round $ROUND replacement is no longer running"
  [ ! -e "$FALLBACK_HOME/state/.lock" ] || fail "round $ROUND successor acquired fallback home"
  wait_for 240 "[ -s '$HOME_DIR/state/.session-start-complete' ]" ||
    fail "round $ROUND replacement acquired lock but never completed session start"
  cp "$HOME_DIR/state/.lock-runtime" "$TMP_ROOT/round-$ROUND.runtime"
  cp "$HOME_DIR/state/.session-start-complete" "$TMP_ROOT/round-$ROUND.session-start"
  NEW_ARGS=$(PATH="$ORIGINAL_PATH" ps -ww -o args= -p "$NEW_PID" 2>/dev/null || true)
  printf '%s\n' "$NEW_ARGS" > "$TMP_ROOT/round-$ROUND.argv"
  case "$NEW_ARGS" in *'Firstmate operational input waiting'*) ;; *) fail "round $ROUND replacement lacked session-start prompt: $NEW_ARGS" ;; esac
  case "$PROVIDER" in
    claude)
      case "$NEW_ARGS" in *"--resume $SESSION_ID"*) ;; *) fail "round $ROUND did not resume outgoing Claude session: $NEW_ARGS" ;; esac
      ;;
    codex)
      case "$NEW_ARGS" in *--no-daemon*'gpt-6.1-sol'*|*'gpt-6.1-sol'*--no-daemon*) ;; *) fail "round $ROUND Codex was not isolated embedded gpt-6.1-sol: $NEW_ARGS" ;; esac
      case "$NEW_ARGS" in *--managed-daemon*) fail "round $ROUND locked shared daemon" ;; esac
      ;;
  esac
  pass "live lead restart: $HARNESS_LABEL round $ROUND self-started, completed session start, and acquired the inline-bound home without follow-up input"
done
