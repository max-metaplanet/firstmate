#!/usr/bin/env bash
# Opt-in credentialed live regression for the Claude Code Calm mod
# (.claude/mods/firstmate-calm) in a real Claude Code TUI under tmux, mirroring the
# Pi interactive case in tests/fm-calm-pi-extension.test.sh. It proves, against the
# installed Claude Code and the shipped project auto-load path (.claude/skills):
#   1. With neither FM_CALM_ENABLED nor its deprecated alias enabling the mod, the mod
#      is a complete no-op even though Claude Code loads its hooks module and the
#      per-home preference is already on: /calm is not a command, the stock working row
#      shows, the boat never appears, and tool rows draw as stock. The module-loaded
#      assertion is the point of the gate: Claude Code no longer withholds the surface,
#      so the mod's own flag is the only thing keeping it inert.
#   2. With FM_CALM_ENABLED=1 and the deprecated alias off, the sailboat replaces the
#      working row and moves, tool rows draw at zero height, /calm restores them and
#      persists off, /calm hides them again and persists on, all without a Calm output
#      row in the transcript. The zero-height operational user row is not reachable from
#      a terminal on this Claude Code, which strips the envelope's invisible marker in
#      the composer; phase 5 is the tripwire for restoring that case.
#   3. `claude --continue` restores the transcript with those rows still hidden.
#   4. The deprecated CLAUDE_CODE_ENABLE_FUNCTION_HOOKS=1 alone still activates the mod,
#      so an unmigrated session keeps Calm, and FM_CALM_ENABLED=0 beside that alias
#      deactivates it, so the firstmate-owned flag decides when the two disagree.
#   5. The composer still strips an exact operational envelope's invisible marker, which
#      is why 2's hidden-row case is not live coverage any more.
# Both names are set per launch through --settings, which outranks every settings file
# on the host, so no phase depends on what this machine's own settings export.
# The project and FM_HOME are isolated; Claude keeps using its existing managed
# authentication and one trusted temporary folder. A few Haiku turns are submitted.
# shellcheck disable=SC2016 # the model, not this test shell, reads the prompt text
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_CLAUDE_CALM_LIVE_E2E claude tmux

MOD="$ROOT/.claude/mods/firstmate-calm"
OPERATIONAL_INPUT="$ROOT/bin/fm-operational-input.sh"
CLAUDE_VERSION=$(claude --version 2>/dev/null || true)
[ -n "$CLAUDE_VERSION" ] || fail "claude is installed but reports no version"
LAB=$(fm_test_tmproot fm-calm-claude-live)
PROJECT="$LAB/project"
FM_HOME_DIR="$LAB/fmhome"
DEBUG_LOG_OFF="$LAB/debug-off.log"
DEBUG_LOG_ON="$LAB/debug-on.log"
DEBUG_LOG_RESUME="$LAB/debug-resume.log"
DEBUG_LOG_LEGACY="$LAB/debug-legacy.log"
DEBUG_LOG_DISAGREE="$LAB/debug-disagree.log"
DEBUG_LOG_MARKER="$LAB/debug-marker.log"
SOCKET="fm-calm-claude-$$"
SESSION="fm-calm-claude-e2e"
HULL='╲▁▁▁╱'
SAIL='◿│◣'

cleanup() {
  local i=0
  tmux -L "$SOCKET" kill-server 2>/dev/null || true
  # Claude's debug logger may still be flushing into the lab for a moment.
  while [ "$i" -lt 20 ] && pgrep -f "debug-file '$LAB/" >/dev/null 2>&1; do
    sleep 0.25
    i=$((i + 1))
  done
  rm -rf "$LAB" 2>/dev/null || true
  fm_test_cleanup
}
trap cleanup EXIT

mkdir -p "$PROJECT/.claude/skills" "$FM_HOME_DIR/config"
ln -s "$MOD" "$PROJECT/.claude/skills/firstmate-calm"
printf 'alpha\nbeta\ngamma\n' >"$PROJECT/notes.txt"
printf 'on\n' >"$FM_HOME_DIR/config/calm"

# Claude Code refuses to nest inside another Claude session, so the inherited session
# markers are dropped from the lab's environment; the activation names are set per
# launch through --settings only, never written into a settings file on disk.
unset_inherited() {
  local name
  while IFS= read -r name; do
    printf -- '-u %s ' "$name"
  done < <(env | grep -E '^(CLAUDECODE|CLAUDE_CODE_[A-Z_]+|CLAUDE_CONFIG_DIR)=' | cut -d= -f1 | sort -u)
}

# The activation names this launch exports, as a settings `env` object. A name left out
# of <gate> is genuinely unset for that session; --settings outranks the host's own
# settings files, whose env block may still carry the deprecated alias.
settings_json() {  # <gate: name=value...>
  local gate pair json=''
  for gate in $1; do
    pair="\"${gate%%=*}\":\"${gate#*=}\""
    json="${json:+$json,}$pair"
  done
  printf '{\"feedbackDrafts\":\"off\",\"env\":{%s}}' "$json"
}

launch() {  # <debug-log> <gate: name=value...> [claude args...]
  local log=$1 settings
  settings=$(settings_json "$2")
  shift 2
  tmux -L "$SOCKET" kill-session -t "$SESSION" 2>/dev/null || true
  tmux -L "$SOCKET" new-session -d -s "$SESSION" -x 160 -y 44 -c "$PROJECT" \
    "env $(unset_inherited) FM_HOME='$FM_HOME_DIR' CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false CLAUDE_CODE_SEND_FEEDBACK=0 claude --model haiku --dangerously-skip-permissions --settings '$settings' --debug-file '$log' $*; printf '\nCLAUDE_EXIT=%s\n' \"\$?\"; sleep 30"
}

# The gate values each phase launches with: the deprecated alias is pinned off wherever
# the firstmate flag is the subject, so neither case can pass on the other's value.
GATE_OFF='CLAUDE_CODE_ENABLE_FUNCTION_HOOKS=0'
GATE_ON='FM_CALM_ENABLED=1 CLAUDE_CODE_ENABLE_FUNCTION_HOOKS=0'
GATE_LEGACY_ONLY='CLAUDE_CODE_ENABLE_FUNCTION_HOOKS=1'
GATE_DISAGREEING='FM_CALM_ENABLED=0 CLAUDE_CODE_ENABLE_FUNCTION_HOOKS=1'

# Wait until Claude Code reports this session's own load of the Calm hooks module, which
# every phase needs: with the surface no longer withheld, an unloaded module would make
# an inert phase prove nothing.
wait_module_loaded() {  # <debug-log>
  local log=$1 i=0
  while [ "$i" -lt 200 ] && ! grep -q 'hooks module firstmate-calm@skills-dir loaded' "$log"; do
    sleep 0.1
    i=$((i + 1))
  done
  grep -q 'hooks module firstmate-calm@skills-dir loaded' "$log" \
    || fail "Claude Code $CLAUDE_VERSION did not load the Calm hooks module from the project's .claude/skills path"
}

screen() {
  tmux -L "$SOCKET" capture-pane -p -t "$SESSION" 2>/dev/null || true
}

send() {
  tmux -L "$SOCKET" send-keys -t "$SESSION" -l "$1"
}

enter() {
  tmux -L "$SOCKET" send-keys -t "$SESSION" Enter
}

# Whether the screen is a startup dialog rather than the session: the folder-trust
# dialog draws its own option cursor with the composer's glyph, so it is answered
# before any text is matched.
dialog_open() {  # <screen text>
  case "$1" in
    *'trust this folder'*|*'Enter to confirm'*) return 0 ;;
  esac
  return 1
}

# The folder-trust dialog opens with its cursor on "No, exit", so Enter alone would
# end the session: move the cursor onto the trusting option first, then confirm.
answer_trust_dialog() {  # <screen text>
  local selected
  case "$1" in
    *'Yes, I trust this folder'*) : ;;
    *) return 0 ;;
  esac
  selected=$(printf '%s\n' "$1" | grep -F '❯' | head -1)
  case "$selected" in
    *'Yes, I trust this folder'*) enter ;;
    *) tmux -L "$SOCKET" send-keys -t "$SESSION" Down ;;
  esac
}

# Wait until the screen shows <text> (a fixed string), answering the folder-trust
# dialog on the way; the wait is iteration-counted so it stretches under load.
wait_screen() {  # <text> <what> [iterations]
  local text=$1 what=$2 limit=${3:-400} i=0 shot
  while [ "$i" -lt "$limit" ]; do
    shot=$(screen)
    case "$shot" in
      *'CLAUDE_EXIT='*)
        printf '%s\n' "$shot" >&2
        fail "Claude Code $CLAUDE_VERSION exited while waiting for $what"
        ;;
    esac
    if dialog_open "$shot"; then
      answer_trust_dialog "$shot"
    else
      case "$shot" in
        *"$text"*) return 0 ;;
      esac
    fi
    sleep 0.25
    i=$((i + 1))
  done
  printf '%s\n' "$(screen)" >&2
  fail "Claude Code $CLAUDE_VERSION never showed $what"
}

wait_idle() {  # wait for the composer prompt with no dialog over it
  wait_screen '❯' 'the composer prompt'
  # A settled composer, not a dialog cursor: give a late dialog one more chance.
  sleep 1
  if dialog_open "$(screen)"; then
    wait_screen '❯' 'the composer prompt after the startup dialog'
  fi
}

# Type a slash command prefix without submitting and report whether the typeahead
# lists the mod's command; then clear the composer.
command_listed() {  # <command>
  local listed=0 i=0 shot
  send "/$1"
  while [ "$i" -lt 40 ]; do
    shot=$(screen)
    case "$shot" in
      *"Toggle Firstmate's Calm"*) listed=1; break ;;
    esac
    sleep 0.1
    i=$((i + 1))
  done
  tmux -L "$SOCKET" send-keys -t "$SESSION" C-u
  sleep 0.3
  return $((1 - listed))
}

hull_column() {  # <screen text>
  printf '%s\n' "$1" | awk -v hull="$HULL" 'index($0, hull) { print index($0, hull); exit }'
}

# The answer names words that live only in notes.txt, so the settled turn is told apart
# from the echoed prompt by "gamma" on screen with no working row left.
PROMPT='Run this exact bash command with the Bash tool: sleep 5; cat notes.txt   Then reply with one short sentence naming the three words.'

# The stock working row on this build: `✢ Propagating… (1s · ↓ 114 tokens)`.
working_row_shown() {  # <screen text>
  case "$1" in
    *'… ('*) return 0 ;;
  esac
  return 1
}

# Wait until the turn has settled: the answer is on screen and no working row or
# boat remains.
wait_settled() {  # <what> [iterations]
  local what=$1 limit=${2:-600} i=0 shot
  while [ "$i" -lt "$limit" ]; do
    shot=$(screen)
    case "$shot" in
      *'CLAUDE_EXIT='*)
        printf '%s\n' "$shot" >&2
        fail "Claude Code $CLAUDE_VERSION exited while waiting for $what"
        ;;
      *'gamma'*)
        if ! working_row_shown "$shot"; then
          case "$shot" in
            *"$HULL"*) ;;
            *) return 0 ;;
          esac
        fi
        ;;
    esac
    sleep 0.25
    i=$((i + 1))
  done
  printf '%s\n' "$(screen)" >&2
  fail "Claude Code $CLAUDE_VERSION never settled $what"
}

# --- 1. Gate off: a complete no-op even with the preference on --------------------
launch "$DEBUG_LOG_OFF" "$GATE_OFF"
wait_idle
# The module loads: Claude Code no longer withholds the surface, so this phase proves
# the mod's own gate, not the platform's.
wait_module_loaded "$DEBUG_LOG_OFF"
if command_listed calm; then
  fail "Claude Code $CLAUDE_VERSION lists /calm although neither FM_CALM_ENABLED nor the deprecated alias enables the mod"
fi
send "$PROMPT"
enter
# Sample every frame until the turn settles: the boat must never appear, and the
# stock working row must have been seen, or the flag-off case proved nothing.
saw_working=0
i=0
while [ "$i" -lt 600 ]; do
  off_frame=$(screen)
  case "$off_frame" in
    *"$HULL"*|*"$SAIL"*)
      printf '%s\n' "$off_frame" >&2
      fail "the working ship appeared although the gate is off"
      ;;
    *'CLAUDE_EXIT='*)
      printf '%s\n' "$off_frame" >&2
      fail "Claude Code $CLAUDE_VERSION exited during the gate-off turn"
      ;;
  esac
  if working_row_shown "$off_frame"; then
    saw_working=1
  elif [ "$saw_working" -eq 1 ]; then
    case "$off_frame" in
      *'gamma'*) break ;;
    esac
  fi
  sleep 0.1
  i=$((i + 1))
done
[ "$saw_working" -eq 1 ] || fail "Claude Code $CLAUDE_VERSION showed no stock working row during the gate-off turn, so the no-op case cannot be judged"
wait_settled 'the turn with the gate off'
off_settled=$(screen)
case "$off_settled" in
  *'Bash('*|*'shell command'*) : ;;
  *)
    printf '%s\n' "$off_settled" >&2
    fail "the stock tool row did not draw while the gate is off"
    ;;
esac
send '/exit'
enter
sleep 2
pass "Claude Code $CLAUDE_VERSION with the gate off: the hooks module loads and still does nothing - no /calm, stock working row, stock tool rows, no boat, preference on ignored"

# --- 2. Gate on: the boat, the hidden rows, the toggle, the persisted choice -------
launch "$DEBUG_LOG_ON" "$GATE_ON"
wait_idle
wait_module_loaded "$DEBUG_LOG_ON"
# The engine logs one benign notice for every options-less hooks module ("options
# requested but its manifest declares no userConfig"); anything else is a real problem.
if grep -E '\[(WARN|ERROR)\].*firstmate-calm' "$DEBUG_LOG_ON" | grep -v 'declares no userConfig' >&2; then
  fail "Claude Code $CLAUDE_VERSION loaded the Calm mod with a warning or error"
fi
command_listed calm || fail "Claude Code $CLAUDE_VERSION does not list /calm with FM_CALM_ENABLED=1"
send "$PROMPT"
enter
wait_screen "$HULL" 'the working ship during a real turn' 200
boat_one=$(screen)
case "$boat_one" in
  *"$SAIL"*) : ;;
  *)
    printf '%s\n' "$boat_one" >&2
    fail "the working ship lost its sail"
    ;;
esac
column_one=$(hull_column "$boat_one")
column_two=$column_one
i=0
while [ "$i" -lt 120 ]; do
  boat_two=$(screen)
  column_two=$(hull_column "$boat_two")
  if [ -n "$column_two" ] && [ "$column_two" != "$column_one" ]; then
    break
  fi
  sleep 0.1
  i=$((i + 1))
done
[ -n "$column_two" ] && [ "$column_two" != "$column_one" ] \
  || fail "the working ship never moved (hull stayed at column $column_one)"
wait_settled 'the turn with FM_CALM_ENABLED=1'
on_settled=$(screen)
case "$on_settled" in
  *"$HULL"*|*"$SAIL"*) fail "the working ship stayed on screen after the turn settled" ;;
  *'Bash('*|*'shell command'*|*'notes.txt)'*)
    printf '%s\n' "$on_settled" >&2
    fail "a tool row drew while Calm was on"
    ;;
esac

# /calm off: rows restore, the preference persists off, no Calm output row.
send '/calm'
enter
wait_screen 'shell command' 'the restored tool row after /calm off' 200
[ "$(cat "$FM_HOME_DIR/config/calm")" = off ] || fail "/calm did not persist off"
restored=$(screen)
# The toggle answers with a transient toast under the prompt, never a transcript row:
# the plugin's name must leave the screen once the toast expires.
case "$restored" in
  *'Calm off'*) : ;;
  *)
    printf '%s\n' "$restored" >&2
    fail "/calm off showed no Calm off notice"
    ;;
esac
i=0
while [ "$i" -lt 60 ]; do
  restored=$(screen)
  case "$restored" in
    *'firstmate-calm'*|*'Calm off'*) ;;
    *) break ;;
  esac
  sleep 0.25
  i=$((i + 1))
done
case "$restored" in
  *'firstmate-calm'*|*'Calm off'*)
    printf '%s\n' "$restored" >&2
    fail "/calm left a Calm row in the transcript after its notice should have expired"
    ;;
esac

# /calm on: rows hide again, the preference persists on. The loop watches the same
# restored tool row the wait above matched, so it cannot fall through on a row spelling
# this build never draws and then race the toggle.
send '/calm'
enter
i=0
while [ "$i" -lt 200 ]; do
  hidden_again=$(screen)
  case "$hidden_again" in
    *'Bash('*|*'shell command'*) ;;
    *) break ;;
  esac
  sleep 0.1
  i=$((i + 1))
done
case "$hidden_again" in
  *'Bash('*|*'shell command'*)
    printf '%s\n' "$hidden_again" >&2
    fail "/calm on did not hide the rows again"
    ;;
esac
[ "$(cat "$FM_HOME_DIR/config/calm")" = on ] || fail "/calm did not persist on"
case "$hidden_again" in
  *'gamma'*) : ;;
  *) fail "Calm on hid a genuine assistant reply" ;;
esac

send '/exit'
enter
sleep 2
pass "Claude Code $CLAUDE_VERSION with FM_CALM_ENABLED=1 and the deprecated alias off: the mod auto-loads from .claude/skills, /calm exists, the sailboat replaces and moves in the working row, tool rows draw at zero height, and /calm restores and re-hides them while persisting the shared preference"

# --- 3. Resume: the restored transcript keeps the hidden rows hidden ---------------
launch "$DEBUG_LOG_RESUME" "$GATE_ON" --continue
wait_screen 'gamma' 'the resumed transcript' 400
sleep 1
resumed=$(screen)
case "$resumed" in
  *'Bash('*|*'shell command'*|*'notes.txt)'*)
    printf '%s\n' "$resumed" >&2
    fail "the resumed transcript drew a row Calm hides"
    ;;
esac
[ "$(cat "$FM_HOME_DIR/config/calm")" = on ] || fail "resume changed the persisted choice"
send '/exit'
enter
sleep 1
pass "Claude Code $CLAUDE_VERSION resumes the transcript with Calm's hidden rows still hidden and the preference intact"

# --- 4. Migration: the deprecated alias still activates, the new flag overrules it ---
# Both cases are judged by whether the mod serves /calm, so neither submits a turn.
launch "$DEBUG_LOG_LEGACY" "$GATE_LEGACY_ONLY"
wait_idle
wait_module_loaded "$DEBUG_LOG_LEGACY"
command_listed calm \
  || fail "Claude Code $CLAUDE_VERSION does not list /calm on the deprecated CLAUDE_CODE_ENABLE_FUNCTION_HOOKS=1 alone, so an unmigrated session would lose Calm"
send '/exit'
enter
sleep 2
pass "Claude Code $CLAUDE_VERSION activates the Calm mod on the deprecated CLAUDE_CODE_ENABLE_FUNCTION_HOOKS=1 alone, so a session that has not moved to FM_CALM_ENABLED keeps Calm"

launch "$DEBUG_LOG_DISAGREE" "$GATE_DISAGREEING"
wait_idle
wait_module_loaded "$DEBUG_LOG_DISAGREE"
if command_listed calm; then
  fail "Claude Code $CLAUDE_VERSION lists /calm although FM_CALM_ENABLED=0 beside the deprecated alias must deactivate the mod"
fi
send '/exit'
enter
sleep 2
pass "Claude Code $CLAUDE_VERSION leaves the Calm mod inert when FM_CALM_ENABLED=0 disagrees with the deprecated CLAUDE_CODE_ENABLE_FUNCTION_HOOKS=1, so the firstmate-owned flag decides"

# --- 5. The bound on phase 2: an operational envelope cannot reach a row from here ----
# This Claude Code strips an invisible character out of submitted composer input and
# asks for a second Enter, so an exact operational envelope typed or pasted into the TUI
# would arrive as plain ASCII that the canonical classifier correctly reads as
# non-operational. The zero-height operational row therefore keeps its coverage in the
# mod's own plugin suites and in the classifier parity corpus of
# tests/fm-calm-claude-mod.test.sh, and this phase is the tripwire for that bound: the
# moment Claude Code stops sanitizing the marker, this step fails and says to restore
# the live hidden-row case in phase 2. Delivering that marker to a Claude pane is
# firstmate's own input concern, not Calm's, and is not this guard's subject. It runs
# last, submits no turn, and never clears the composer, so the envelope it leaves there
# cannot reach another step.
launch "$DEBUG_LOG_MARKER" "$GATE_ON"
wait_idle
wait_module_loaded "$DEBUG_LOG_MARKER"
operational=$(printf 'signal: %s/state/probe.status changed' "$LAB" | "$OPERATIONAL_INPUT" encode watcher) \
  || fail "could not encode the operational probe"
send "$operational"
enter
wait_screen 'invisible character' "the composer stripping the operational envelope's marker; if Claude Code now submits it intact, restore phase 2's live zero-height operational-row case" 200
pass "Claude Code $CLAUDE_VERSION strips an exact operational envelope's invisible marker out of the composer, so the live zero-height operational-row case is unreachable from a terminal and its coverage stays in the mod's own suites"
