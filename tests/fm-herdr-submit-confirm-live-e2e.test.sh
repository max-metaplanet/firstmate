#!/usr/bin/env bash
# Live Herdr submit-confirmation guard (live-harness-optin family).
#
# Herdr's native agent_status can stay idle for a whole landed Claude turn, and
# a busy-queued Enter can keep proven pending text visible. A stub cannot prove
# either signal. This guard launches real Claude Code in an isolated Herdr lab
# and requires fm_backend_herdr_send_text_submit to report empty for a landed
# idle steer. It fails naming the harness and version rather than degrading
# quietly.
#
# It also covers the modal composer, which only a real Claude can prove: with
# `editorMode: vim` the composer has a command mode whose keystrokes are editor
# commands, so a doorbell typed there is eaten from the front and never
# submitted. Both editor modes are PINNED rather than inherited from the
# operator's own settings, the indicator is asserted to be present in one and
# absent in the other so neither case can go vacuous, and the real steering
# doorbell is delivered through the real fm_task_inbox_ring in text-entry mode,
# in command mode after an Escape, and on a composer with no modal editor.
#
# Run explicitly with FM_HERDR_SUBMIT_CONFIRM_LIVE=1 after a Herdr or Claude
# upgrade, and before trusting a refreshed docs/verification/runtime-backends.md
# "Herdr submit confirmation" entry.
# Every Herdr call, including adapter calls, is routed through bin/fm-herdr-lab.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

fm_live_gate opt-in FM_HERDR_SUBMIT_CONFIRM_LIVE herdr jq claude

[ -x "$LAB_HELPER" ] || fail "FM_HERDR_SUBMIT_CONFIRM_LIVE=1 but the Herdr lab helper is not executable at $LAB_HELPER"

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane

ORIGINAL_PATH=$PATH
SESSION=$("$LAB_HELPER" name herdr-submit-confirm-live)
TMP_ROOT=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-herdr-submit-confirm-live.XXXXXX")
FAKEBIN="$TMP_ROOT/fakebin"
mkdir -p "$FAKEBIN"
CHECKED=0

cleanup() {
  local rc=$?
  trap - EXIT
  if ! PATH="$ORIGINAL_PATH" "$LAB_HELPER" teardown "$SESSION"; then
    rc=1
  fi
  rm -rf "$TMP_ROOT"
  exit "$rc"
}
trap cleanup EXIT

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

# shellcheck source=/dev/null
. "$ROOT/bin/backends/herdr.sh"

lab() { env PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" "$@"; }
WS_JSON=$(lab workspace create --cwd "$ROOT" --label fm-submitlive --no-focus) \
  || fail "could not create the isolated submit-confirm workspace"
PANE=$(printf '%s' "$WS_JSON" | jq -er '.result.root_pane.pane_id') \
  || fail "workspace create did not return a pane id"
TARGET="$SESSION:$PANE"
VERSION=$(PATH="$ORIGINAL_PATH" claude --version 2>/dev/null | head -1 || printf 'version-unknown')
HERDR_VER=$(PATH="$ORIGINAL_PATH" herdr --version 2>/dev/null | head -1 || printf 'herdr-unknown')

# editorMode is pinned, never inherited: the operator's own settings decide
# whether a Claude composer is modal at all, and a guard that reads one mode on
# one machine and the other elsewhere proves nothing about either.
lab pane run "$PANE" "CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false CLAUDE_CODE_SEND_FEEDBACK=0 claude --dangerously-skip-permissions --settings '{\"feedbackDrafts\":\"off\",\"editorMode\":\"normal\"}'" >/dev/null \
  || fail "could not launch Claude Code ($VERSION) in the isolated Herdr pane"

idle=0
i=0
while [ "$i" -lt 45 ]; do
  st=$(lab agent get "$PANE" 2>/dev/null | jq -r '.result.agent.agent_status // empty')
  case "$st" in
    idle|done) idle=1; break ;;
    blocked)
      # A fresh checkout path stops on Claude's folder-trust prompt, which the
      # pre-send proof would read as a non-empty composer. Accept it and keep
      # waiting for a real idle composer. The prompt preselects "No, exit", so
      # move to "Yes" before confirming; a bare Enter quits Claude.
      case "$(lab pane read "$PANE" --source visible 2>/dev/null || true)" in
        *'Yes, I trust this folder'*) lab pane send-keys "$PANE" down enter >/dev/null \
          || fail "could not accept Claude's folder-trust prompt" ;;
      esac
      ;;
  esac
  i=$((i + 1))
  sleep 1
done
[ "$idle" = 1 ] || fail "Claude Code ($VERSION) on $HERDR_VER never registered an idle agent in the lab pane"

TOKEN="FMHERDRPONG$$_$RANDOM"
verdict=$(fm_backend_herdr_send_text_submit "$TARGET" "Reply with exactly $TOKEN and nothing else." 3 0.4 0.4) \
  || fail "send_text_submit failed to run against Claude Code ($VERSION) on $HERDR_VER"
CHECKED=1
[ "$verdict" = empty ] \
  || fail "Claude Code ($VERSION) on $HERDR_VER: a landed idle steer must confirm empty, got '$verdict'"

# Confirm the instruction reached Claude, not merely that the composer cleared.
# The token occurs once in the submitted prompt and once in Claude's reply.
landed=0
i=0
screen=''
while [ "$i" -lt 45 ]; do
  screen=$(lab pane read "$PANE" --source recent --lines 200 2>/dev/null || true)
  occurrences=$(printf '%s\n' "$screen" | grep -F -c "$TOKEN" || true)
  if [ "$occurrences" -ge 2 ]; then
    landed=1
    break
  fi
  i=$((i + 1))
  sleep 1
done
[ "$landed" = 1 ] \
  || fail "Claude Code ($VERSION) on $HERDR_VER: submit reported '$verdict' but the expected reply never rendered"
pass "live Herdr submit confirm: Claude Code ($VERSION) on $HERDR_VER reports empty and renders the requested reply in isolated session $SESSION"

# Away-mode digests start with U+2063, which Claude's composer read-back drops.
# The pre-Enter proof must still accept the rest of the payload.
# shellcheck source=bin/fm-operational-input.sh
. "$ROOT/bin/fm-operational-input.sh"
i=0
while [ "$i" -lt 45 ]; do
  st=$(lab agent get "$PANE" 2>/dev/null | jq -r '.result.agent.agent_status // empty')
  case "$st" in idle|done) break ;; esac
  i=$((i + 1))
  sleep 1
done
OP_TOKEN="FMHERDROPPONG$$_$RANDOM"
op_text=
fm_operational_input_encode away-supervisor "Reply with exactly $OP_TOKEN and nothing else." op_text \
  || fail "could not encode an away-supervisor payload"
verdict=$(fm_backend_herdr_send_text_submit "$TARGET" "$op_text" 3 0.4 0.4) \
  || fail "send_text_submit failed to run an operational payload against Claude Code ($VERSION) on $HERDR_VER"
[ "$verdict" = empty ] \
  || fail "Claude Code ($VERSION) on $HERDR_VER: a landed U+2063 operational payload must confirm empty, got '$verdict'"
landed=0
i=0
while [ "$i" -lt 45 ]; do
  screen=$(lab pane read "$PANE" --source recent --lines 200 2>/dev/null || true)
  occurrences=$(printf '%s\n' "$screen" | grep -F -c "$OP_TOKEN" || true)
  if [ "$occurrences" -ge 2 ]; then
    landed=1
    break
  fi
  i=$((i + 1))
  sleep 1
done
[ "$landed" = 1 ] \
  || fail "Claude Code ($VERSION) on $HERDR_VER: operational submit reported '$verdict' but the expected reply never rendered"
pass "live Herdr submit confirm: Claude Code ($VERSION) on $HERDR_VER submits a U+2063 away-supervisor payload whose read-back drops the mark"

# --- The modal composer: a vim-mode Claude, in and out of text entry ---------
#
# Claude's `editorMode: vim` composer has a command mode whose keystrokes are
# editor commands. Escape - Claude's own interrupt key - leaves text entry, and
# a doorbell typed after that is eaten from the front: `: Firstma` becomes the
# space, find-backwards, replace, till and append commands, and only the
# remainder is inserted. Nothing but a real Claude can prove which characters
# it consumes, which is why this runs live. Both modes must deliver the REAL
# constant doorbell line through the REAL fm_task_inbox_ring, the same call
# fm-send and the watcher's re-ring make.
# shellcheck source=bin/fm-task-inbox-lib.sh
. "$ROOT/bin/fm-task-inbox-lib.sh"

VIM_WS_JSON=$(lab workspace create --cwd "$ROOT" --label fm-submitlive-vim --no-focus) \
  || fail "could not create the isolated vim-mode workspace"
VIM_PANE=$(printf '%s' "$VIM_WS_JSON" | jq -er '.result.root_pane.pane_id') \
  || fail "vim workspace create did not return a pane id"
VIM_TARGET="$SESSION:$VIM_PANE"
lab pane run "$VIM_PANE" "CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false CLAUDE_CODE_SEND_FEEDBACK=0 claude --dangerously-skip-permissions --settings '{\"feedbackDrafts\":\"off\",\"editorMode\":\"vim\"}'" >/dev/null \
  || fail "could not launch a vim-mode Claude Code ($VERSION) in the isolated Herdr pane"

i=0
vim_idle=0
while [ "$i" -lt 45 ]; do
  st=$(lab agent get "$VIM_PANE" 2>/dev/null | jq -r '.result.agent.agent_status // empty')
  case "$st" in
    idle|done) vim_idle=1; break ;;
    blocked)
      case "$(lab pane read "$VIM_PANE" --source visible 2>/dev/null || true)" in
        *'Yes, I trust this folder'*) lab pane send-keys "$VIM_PANE" down enter >/dev/null \
          || fail "could not accept Claude's folder-trust prompt in the vim pane" ;;
      esac
      ;;
  esac
  i=$((i + 1))
  sleep 1
done
[ "$vim_idle" = 1 ] \
  || fail "a vim-mode Claude Code ($VERSION) on $HERDR_VER never registered an idle agent in the lab pane"
sleep 2

INSERT_SIGNAL=$(fm_composer_modal_entry_signal claude) \
  || fail "claude must carry a text-entry indicator"
vim_entry_state() {  # <pane>
  if fm_composer_modal_entry_shown "$INSERT_SIGNAL" \
    "$(lab pane read "$1" --source visible 2>/dev/null || true)"; then
    printf 'insert'
  else
    printf 'other'
  fi
}

# The whole guard rests on this being a genuinely modal pane: without the
# indicator rendered, the "command mode" case below would be indistinguishable
# from an ordinary Claude and could pass without testing anything.
[ "$(vim_entry_state "$VIM_PANE")" = insert ] \
  || fail "Claude Code ($VERSION) on $HERDR_VER did not render $INSERT_SIGNAL with editorMode vim, so this guard cannot tell command mode from a non-modal composer"
[ "$(vim_entry_state "$PANE")" = other ] \
  || fail "Claude Code ($VERSION) on $HERDR_VER rendered $INSERT_SIGNAL with editorMode normal, so the indicator is not proof of a modal composer"

MODAL_STATE=$(mktemp -d "$TMP_ROOT/modal-state.XXXXXX")
ring_a_doorbell() {  # <target> <pane> <task> <label>
  local target=$1 pane=$2 task=$3 label=$4 rec rc=0 held
  rec=$(fm_task_inbox_write "$MODAL_STATE" "$task" "reply is not required; this is a delivery guard") \
    || fail "could not write the $label steering record"
  fm_task_inbox_ring herdr "$target" "$rec" || rc=$?
  [ "$rc" = 0 ] \
    || fail "Claude Code ($VERSION) on $HERDR_VER: the doorbell to a $label composer reported a failed ring ($rc), so no instruction would be delivered"
  sleep 1.5
  held=$(fm_backend_herdr_composer_content "$target" 200 2>/dev/null || true)
  [ -z "${held//[$' \t\r\n\v\f']/}" ] \
    || fail "Claude Code ($VERSION) on $HERDR_VER: the doorbell to a $label composer was left unsubmitted in the input box: $held"
  # A landed doorbell starts a turn; wait it out so the next case begins idle.
  i=0
  while [ "$i" -lt 60 ]; do
    case "$(lab agent get "$pane" 2>/dev/null | jq -r '.result.agent.agent_status // empty')" in
      idle|done) break ;;
    esac
    i=$((i + 1))
    sleep 1
  done
}

ring_a_doorbell "$VIM_TARGET" "$VIM_PANE" modal-entry "vim text-entry"
pass "live Herdr doorbell: Claude Code ($VERSION) on $HERDR_VER submits the doorbell to a vim-mode composer taking text"

lab pane send-keys "$VIM_PANE" escape >/dev/null \
  || fail "could not send Escape to the vim-mode pane"
sleep 1
[ "$(vim_entry_state "$VIM_PANE")" = other ] \
  || fail "Claude Code ($VERSION) on $HERDR_VER: Escape did not leave text entry, so the command-mode case below would not be tested"
ring_a_doorbell "$VIM_TARGET" "$VIM_PANE" modal-command "vim command-mode"
pass "live Herdr doorbell: Claude Code ($VERSION) on $HERDR_VER recovers and submits the doorbell to a vim-mode composer an interrupt key left in command mode"

ring_a_doorbell "$TARGET" "$PANE" non-modal "non-modal"
pass "live Herdr doorbell: Claude Code ($VERSION) on $HERDR_VER submits the doorbell to a Claude composer with no modal editor"

[ "$CHECKED" -gt 0 ] || fail "FM_HERDR_SUBMIT_CONFIRM_LIVE=1 checked no harness"
