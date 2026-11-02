#!/usr/bin/env bash
# Live scenario: `fm-control.sh <task> exit` parks a real Claude Code worker
# running on Herdr with editorMode vim ("-- INSERT --") and a running background
# shell ("1 shell") - the reported failure shape. Also: exit from vim command
# mode (after Escape). Runs in a private fm-lab-* Herdr session and a marked lab
# FM_HOME; everything is torn down on exit.
# Usage: fm-control-exit-vim-shell-live.sh <repo-root> <evidence-dir>
set -u
ROOT=$1
EV=$2
cd "$ROOT"
# shellcheck source=/dev/null
. "$ROOT/tests/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane
fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

SESSION=$("$ROOT/bin/fm-herdr-lab.sh" name ctlexit-vim)
export HERDR_SESSION="$SESSION"
SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/fm-ctlexit.XXXXXX"); SCRATCH=$(cd "$SCRATCH" && pwd -P)
LAB_PREPARED=0
cleanup() {
  local rc=$?
  trap - EXIT
  [ "$LAB_PREPARED" = 1 ] && { herdr_safe_stop_and_delete "$SESSION" || rc=1; }
  rm -rf "$SCRATCH"
  exit "$rc"
}
trap cleanup EXIT
fm_herdr_lab_prepare "$SESSION" || fail "could not prepare lab session"
LAB_PREPARED=1

HOME_DIR="$SCRATCH/home"
"$ROOT/bin/fm-lab-home.sh" create "$HOME_DIR" >/dev/null || fail "lab home create failed"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/data/vimexit"
printf '# Task\n## Captain'"'"'s intent\nLab exit check.\n\n## Firstmate spec\nNone.\n' > "$HOME_DIR/data/vimexit/brief.md"
PROJ="$SCRATCH/proj"; WT="$SCRATCH/wt"
mkdir -p "$PROJ"; git -C "$PROJ" init -q; echo '# p' > "$PROJ/README.md"
git -C "$PROJ" add README.md
git -C "$PROJ" -c user.name=t -c user.email=t@example.invalid commit -qm init
git -C "$PROJ" worktree add --quiet -b vimexit "$WT"

. "$ROOT/bin/fm-backend.sh"
fm_backend_source herdr || fail "backend source"
CRAW=$(fm_backend_herdr_container_ensure "$WT") || fail "container_ensure"
CONTAINER=${CRAW%%$'\t'*}; SEEDED=${CRAW#*$'\t'}; WSID=${CONTAINER#*:}
read -r TAB PANE <<EOF
$(fm_backend_herdr_create_task "$CONTAINER" fm-vimexit "$WT" "$SEEDED")
EOF
[ -n "$PANE" ] || fail "create_task gave no pane"
T="$SESSION:$PANE"
cat > "$HOME_DIR/state/vimexit.meta" <<EOF
window=$T
endpoint_task_id=vimexit
worktree=$WT
project=$PROJ
harness=claude
kind=ship
mode=no-mistakes
yolo=off
model=default
effort=default
backend=herdr
herdr_session=$SESSION
herdr_workspace_id=$WSID
herdr_tab_id=$TAB
herdr_pane_id=$PANE
EOF

screen() { herdr pane read "$PANE" --source visible --session "$SESSION" 2>/dev/null || true; }
agent_status() { herdr agent get "$PANE" --session "$SESSION" 2>/dev/null | jq -r '.result.agent.agent_status // empty'; }

launch_claude_vim() {
  fm_backend_herdr_send_text_line "$T" "cd $WT && CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false CLAUDE_CODE_SEND_FEEDBACK=0 claude --dangerously-skip-permissions --settings '{\"feedbackDrafts\":\"off\",\"editorMode\":\"vim\"}'" \
    || fail "could not launch claude"
  local i=0 trusted=0
  while [ "$i" -lt 90 ]; do
    s=$(screen)
    case "$s" in
      *'Yes, I trust this folder'*)
        [ "$trusted" = 0 ] && { trusted=1; herdr pane send-keys "$PANE" down enter --session "$SESSION" >/dev/null; } ;;
      *'bypass permissions on'*)
        case "$(agent_status)" in idle|done) case "$s" in *'-- INSERT --'*) return 0 ;; esac ;; esac ;;
    esac
    i=$((i + 1)); sleep 1
  done
  screen > "$EV/launch-timeout.screen.txt"
  fail "claude never reached an idle vim INSERT composer"
}

run_exit() {  # <label>
  local out rc
  out=$(env -u NO_MISTAKES_GATE FM_HOME="$HOME_DIR" HERDR_SESSION="$SESSION" FM_SPAWN_NO_GUARD=1 \
    "$ROOT/bin/fm-control.sh" vimexit exit 2>&1); rc=$?
  printf '$ fm-control.sh vimexit exit\n%s\n(rc=%s)\n' "$out" "$rc" > "$EV/$1.fm-control.txt"
  cat "$EV/$1.fm-control.txt"
  return "$rc"
}

# --- Scenario A: vim INSERT + running background shell (the bug report) ------
launch_claude_vim
fm_backend_herdr_send_text_submit "$T" 'Use your Bash tool with run_in_background set to true to start the command sleep 900, then reply with exactly BGUP and do nothing else.' 3 0.4 0.4 >/dev/null \
  || fail "could not ask for a background shell"
i=0; up=0
while [ "$i" -lt 120 ]; do
  case "$(screen)" in *' shell'*) case "$(agent_status)" in idle|done) up=1; break ;; esac ;; esac
  i=$((i + 1)); sleep 1
done
[ "$up" = 1 ] || { screen > "$EV/A-no-shell.screen.txt"; fail "no background shell rendered"; }
sleep 2
screen > "$EV/A-before-exit.screen.txt"
grep -q -- '-- INSERT --' "$EV/A-before-exit.screen.txt" || fail "A: composer not in vim INSERT before exit"
grep -q ' shell' "$EV/A-before-exit.screen.txt" || fail "A: no shell count before exit"
run_exit A || fail "A: fm-control exit failed on vim INSERT + background shell"
screen > "$EV/A-after-exit.screen.txt"
st=$(fm_backend_agent_state herdr "$T")
[ "$st" = dead ] || fail "A: agent state after exit is '$st', not dead"
herdr pane get "$PANE" --session "$SESSION" >/dev/null 2>&1 || fail "A: endpoint pane vanished"
pass "A: fm-control exit parked a vim-INSERT Claude with a running background shell (agent=$st, pane kept)"

# --- Scenario B: vim COMMAND mode (Escape first), no background shell ---------
launch_claude_vim
herdr pane send-keys "$PANE" escape --session "$SESSION" >/dev/null
sleep 1.5
screen > "$EV/B-before-exit.screen.txt"
grep -q -- '-- INSERT --' "$EV/B-before-exit.screen.txt" && fail "B: Escape did not leave INSERT mode"
run_exit B || fail "B: fm-control exit failed from vim command mode"
screen > "$EV/B-after-exit.screen.txt"
st=$(fm_backend_agent_state herdr "$T")
[ "$st" = dead ] || fail "B: agent state after exit is '$st', not dead"
pass "B: fm-control exit parked a vim command-mode Claude (agent=$st)"

# --- Scenario C (adversarial): exit again on the parked worker is idempotent --
run_exit C || fail "C: second exit on a parked worker failed"
grep -q 'already-stopped' "$EV/C.fm-control.txt" || fail "C: second exit did not report already-stopped"
pass "C: a repeat exit on the parked worker is an idempotent already-stopped"
