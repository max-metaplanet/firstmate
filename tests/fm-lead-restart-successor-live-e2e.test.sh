#!/usr/bin/env bash
# Live lead-restart successor guard (live-harness-optin family).
#
# A lead restart replaces the firstmate process with `claude --resume <id>` in
# the same terminal, and this home's lock is taken by an AGENT action - the
# first turn running bin/fm-session-start.sh - not by the process coming up.
# Whether a resumed interactive Claude takes any turn at all on its own is a
# vendor behavior: Claude Code's own session-open adapter routes a `--resume`
# to the nudge tier, and a nudge nobody reads is not a turn. A stub lead cannot
# prove either half, because a stand-in takes the lock from its own script no
# matter what it was launched with. So this guard runs the real transaction
# against real Claude Code in an isolated Herdr lab: a real lead holding a
# throwaway home, the real bin/fm-lead-restart.sh handover, and a real resumed
# successor that must take that home with nothing typed into its terminal after
# the restart was armed.
#
# It fails naming the harness and version rather than degrading quietly.
#
# Run explicitly with FM_LEAD_RESTART_SUCCESSOR_LIVE=1 after a Claude Code
# upgrade, and before trusting a refreshed docs/verification/runtime-backends.md
# "Lead restart successor" entry.
# It spends model tokens: two short turns in the outgoing lead plus the
# successor's own session start.
# The real permission flag is part of what is measured, not an oversight: the
# replacement's command is rebuilt from the outgoing lead's own argv, and the
# primary runs with the flag config/claude-permission-mode selects, so a guard
# that launched a restricted agent would prove nothing about the command that
# actually runs - and the successor's first turn has to read a record and run
# a whole session start, which no narrow tool allowlist could carry. It stays
# opt-in and every prompt it submits is a literal in this file.
# Every Herdr call, including the ones the production scripts make from inside
# the lab pane, is routed through bin/fm-herdr-lab.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

fm_live_gate opt-in FM_LEAD_RESTART_SUCCESSOR_LIVE herdr jq claude

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
SESSION=$("$LAB_HELPER" name lead-restart-live)
export FM_HERDR_LAB="$SESSION"
TMP_ROOT=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-lead-restart-successor-live.XXXXXX")
FAKEBIN="$TMP_ROOT/fakebin"
HOME_DIR="$TMP_ROOT/home"
mkdir -p "$FAKEBIN" "$HOME_DIR/state" "$HOME_DIR/config" "$HOME_DIR/data"
printf '%s\n' "$SEATS_ROOT" > "$HOME_DIR/config/claude-seats-root"
SUCCESSOR_PID=''

cleanup() {
  local rc=$? stray
  trap - EXIT
  # The successor is a real firstmate holding a throwaway home: end it before
  # the lab goes away so it cannot outlive the pane it was started in.
  [ -z "$SUCCESSOR_PID" ] || kill "$SUCCESSOR_PID" 2>/dev/null || true
  # Anything else it started for that home - a supervision cycle, say - is
  # addressed by this home's own unique path, never by a sweep over a name
  # other homes' processes share.
  for stray in $(PATH="$ORIGINAL_PATH" pgrep -f "$HOME_DIR" 2>/dev/null || true); do
    [ "$stray" = "$$" ] || kill "$stray" 2>/dev/null || true
  done
  if ! PATH="$ORIGINAL_PATH" "$LAB_HELPER" teardown "$SESSION"; then
    rc=1
  fi
  rm -rf "$TMP_ROOT"
  exit "$rc"
}
trap cleanup EXIT

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

"$LAB_HELPER" provision "$SESSION" || fail "could not provision the isolated Herdr lab"
export PATH="$FAKEBIN:$ORIGINAL_PATH"

# shellcheck source=bin/backends/herdr.sh
. "$ROOT/bin/backends/herdr.sh"

lab() { env PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" "$@"; }
VERSION=$(PATH="$ORIGINAL_PATH" claude --version 2>/dev/null | head -1 || printf 'version-unknown')
HERDR_VER=$(PATH="$ORIGINAL_PATH" herdr --version 2>/dev/null | head -1 || printf 'herdr-unknown')

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

# The pane's own shell carries both, so the detached handover stage and the
# successor the stage starts there inherit them. FM_HOME has to be exported
# rather than prefixed onto the lead's launch: the replacement is started by
# sourcing a staged file in this shell, and it resolves its home from the
# environment that shell hands it, exactly as the real primary resolves its
# own from the terminal it was started in.
lab pane run "$PANE" "export PATH='$FAKEBIN':\$PATH FM_HOME='$HOME_DIR'" >/dev/null ||
  fail "could not pin the lab Herdr wrapper and home into the pane shell"

# The outgoing lead: a real Claude in the lab pane, on the named seat, holding
# the throwaway home. Its launch prompt is a positional argument, the same
# carrier the replacement uses, so a Claude that ignored one would strand this
# guard here rather than let it pass on a stand-in.
lab pane run "$PANE" "CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false CLAUDE_CODE_SEND_FEEDBACK=0 CLAUDE_CONFIG_DIR='$SEAT_DIR' claude --dangerously-skip-permissions 'Run bin/fm-lock.sh once, then stop and report only the line it printed.'" >/dev/null ||
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

# Arm the real restart from inside the lead, which is the only session allowed
# to replace it. This is the LAST thing sent to this pane: everything after it
# has to happen with no human and no test input at all.
i=0
while [ "$i" -lt 120 ]; do
  case "$(lab agent get "$PANE" 2>/dev/null | jq -r '.result.agent.agent_status // empty')" in
    idle | done) break ;;
  esac
  i=$((i + 1))
  sleep 1
done
ARM="FM_LEAD_RESTART_CLAIM_WAIT=240 bin/fm-lead-restart.sh --to $SEAT_NAME --refresh --persisted --launch-command 'claude --dangerously-skip-permissions'"
verdict=$(fm_backend_herdr_send_text_submit "$TARGET" \
  "Run exactly this, and nothing else, reporting only what it prints: $ARM" 3 0.4 0.4) ||
  fail "the restart instruction could not be submitted to Claude Code ($VERSION) on $HERDR_VER"
[ "$verdict" = empty ] ||
  fail "the restart instruction did not land in the composer (verdict '$verdict')"

wait_for 300 "[ -f '$HOME_DIR/state/.lead-restart.result' ]" ||
  fail "the restart never reported an outcome; pane: $(lab pane read "$PANE" --source recent --lines 60 2>/dev/null || true)"
wait_for 300 "grep -q '^state=' '$HOME_DIR/state/.lead-restart.result' 2>/dev/null" ||
  fail "the restart outcome never carried a state"
OUT=$(cat "$HOME_DIR/state/.lead-restart.result")
case "$OUT" in
  *"state=done"*) ;;
  *) fail "Claude Code ($VERSION) on $HERDR_VER: the replacement never took the home with nothing typed into its terminal: $OUT; pane: $(lab pane read "$PANE" --source recent --lines 80 2>/dev/null || true)" ;;
esac

NEW_PID=$(cat "$HOME_DIR/state/.lock")
SUCCESSOR_PID=$NEW_PID
[ "$NEW_PID" != "$OLD_PID" ] ||
  fail "the home's lock still names the process that was replaced"
kill -0 "$NEW_PID" 2>/dev/null || fail "the replacement that took the home is no longer running"
# The lock is held by a session start the replacement ran itself: the matching
# completion record is what separates "an agent took the lock" from "the lead
# came up and took the helm". It is published only after every startup stage
# finishes, while the lock is taken by the first one, so the swap reports done
# before this record exists and it is waited for rather than read at once.
wait_for 240 "[ -s '$HOME_DIR/state/.session-start-complete' ]" ||
  fail "the replacement took the lock but never completed the session start it was prompted to run: $(ls -a "$HOME_DIR/state")"
NEW_ARGS=$(PATH="$ORIGINAL_PATH" ps -ww -o args= -p "$NEW_PID" 2>/dev/null || true)
case "$NEW_ARGS" in
  *"--resume $SESSION_ID"*) ;;
  *) fail "the replacement did not resume the session being handed over: $NEW_ARGS" ;;
esac
case "$NEW_ARGS" in
  *'Firstmate operational input waiting'*) ;;
  *) fail "the replacement was not launched on the session-start instruction: $NEW_ARGS" ;;
esac
pass "live lead restart: Claude Code ($VERSION) on $HERDR_VER resumes session $SESSION_ID on its own, runs session start, and takes the home with nothing typed into its terminal after the restart was armed"
