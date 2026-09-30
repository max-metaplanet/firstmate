#!/usr/bin/env bash
# fm-lead-restart.sh - move the PRIMARY firstmate session itself onto another
# Claude seat, by replacing its own process in its own terminal.
#
# Usage:
#   fm-lead-restart.sh --check --to <seat>
#   fm-lead-restart.sh --to <seat> --persisted [--launch-command <cmd>] [--grace <s>]
#   fm-lead-restart.sh --handover-stage <plan-file>     (internal; detached)
#
# WHY THIS IS NOT A SEAT SWITCH. bin/fm-seat.sh switch rewrites one config line
# that only a fresh spawn reads, so it moves NEW workers and never disturbs
# anything running - including the lead, which keeps the account it launched on
# until something replaces its process. There is no way to move a running Claude
# Code process to another credential store, so the only way the lead itself
# changes account is to be replaced: tell nothing to wind down, start another
# claude on the new seat in the same terminal, resuming the same session, and
# end the old process. A seat is a profile directory whose contents symlink the
# shared ~/.claude body, so the session the successor resumes is the same
# session: the seat is the brain, the sessions and settings are the body.
#
# WHAT DELIBERATELY DOES NOT HAPPEN. Running workers are not told anything and
# are not moved. Steering is a durable inbox, status is a durable log, and every
# task keeps the seat recorded in its own task record, so a lead swap is
# invisible to them; a crew notification step would be a message that changes
# nothing. The one real worker-facing effect is supervision, and it is handled
# by NOT touching it: the watcher is a separate process with its own singleton
# lock, it is never in the kill below, and the successor's own arm attaches to a
# live watcher instead of starting a second one. So the cycle count goes from
# one to one, and the durable wake queue holds anything that arrives meanwhile.
#
# THE FIVE THINGS THAT MUST BE ESTABLISHED, never guessed. Any one of them
# missing is a refusal, and a refusal at this stage leaves the old lead running
# and in charge, because nothing has been touched yet:
#   1. This home's lock is held by a live CLAUDE session. Other harnesses are
#      refused by name; no adapter is built for them here.
#   2. The lead's OWN profile, from state/.lock-runtime (bin/fm-lock.sh writes
#      it bound to the lock's pid). config/claude-seat is NOT that answer: it
#      names the seat new workers get and moves without the lead.
#   3. The destination seat, named by the caller, with a profile directory that
#      exists and a login the probe proves usable. bin/fm-seat.sh owns seat
#      selection; this command never picks one.
#   4. The session id to resume, from the sidecar beside the lock.
#   5. The pane, and the lead's own launch command, from the lock-runtime record
#      and the lock-owning process's real argv. `establish_launch_command` below
#      owns why a flattened argv is accepted only when it provably round-trips.
#
# THE HANDOVER. Between the old lead's exit and the successor's own acquisition
# the lock names a dead pid, which every other session reads as reclaimable. So
# a bounded reservation is armed first, through bin/fm-lock.sh handover, while
# the old lead still holds the lock: from that moment until the successor takes
# over, only the outgoing session (by its session id) or the successor (by the
# nonce it is launched with) may hold this home. There is never a moment with
# two holders, because the successor is started only after the old process is
# proven gone, and never a moment the home is open to a third session, because
# the reservation covers exactly that gap.
#
# WHAT A FAILURE LEAVES. Every check above runs before anything is touched, so a
# refusal leaves the old lead running and in charge with the reason reported.
# After the detached stage has ended the old process there is no going back to
# it, and the stage says so plainly: it records the outcome in
# state/.lead-restart.result, drops the reservation so the home is not held
# shut, and queues a wake. Recovery is then one command in that same terminal -
# the successor command is printed in the result and staged as a file to source -
# and every durable record, task, worktree, and PR is untouched, because this
# command only ever replaced one process.
#
# Environment knobs:
#   FM_LEAD_RESTART_GRACE        seconds before the old process is ended (5)
#   FM_LEAD_RESTART_EXIT_WAIT    seconds to wait for it to exit after TERM (30)
#   FM_LEAD_RESTART_START_WAIT   seconds to wait for the successor process (120)
#   FM_LEAD_RESTART_CLAIM_WAIT   seconds to wait for it to take the lock (300)
#
# Exit status: 0 the handover is armed and the detached stage is running (or,
# with --check, everything needed is established); 1 a refusal, with the old
# lead untouched; 2 invalid use.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-quota-axi-lib.sh
. "$SCRIPT_DIR/fm-quota-axi-lib.sh"
# shellcheck source=bin/fm-seat-lib.sh
. "$SCRIPT_DIR/fm-seat-lib.sh"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# The persist gate this refuses without is the same contract a second mate's
# restart applies; that file owns its wording.
# shellcheck source=bin/fm-persist-request-lib.sh
. "$SCRIPT_DIR/fm-persist-request-lib.sh"

PLAN="$STATE/.lead-restart"
RESULT="$STATE/.lead-restart.result"

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "${BASH_SOURCE[0]}"
  exit 2
}
die() { printf 'error: %s\n' "$1" >&2; exit 1; }

GRACE=${FM_LEAD_RESTART_GRACE:-5}
EXIT_WAIT=${FM_LEAD_RESTART_EXIT_WAIT:-30}
START_WAIT=${FM_LEAD_RESTART_START_WAIT:-120}
CLAIM_WAIT=${FM_LEAD_RESTART_CLAIM_WAIT:-300}

# --- establishment -----------------------------------------------------------

# The pid this home's lock names, once it is proven to be a live harness.
# Everything below reads that one process, so a home whose lock is free, stale,
# or unreadable is refused here rather than half-way through.
established_lock_pid() {
  local pid
  fm_session_lock_inspect "$STATE"
  [ "$FM_LOCK_INSPECT_STATE" = held ] ||
    die "this home's session lock is not held by a live firstmate session (it reads $FM_LOCK_INSPECT_STATE), so there is no lead here to restart"
  pid=$FM_LOCK_INSPECT_PID
  printf '%s\n' "$pid"
}

# The lead is a Claude session or this refuses. The evidence is the session id
# recorded beside the lock: bin/fm-lock.sh writes it only for a session that
# proved a trusted Claude session id, so its presence IS the harness proof and
# its value is the id the successor resumes. No other harness is supported and
# none is guessed at: an adapter that cannot resume a session by id in a new
# process would be a different mechanism, not a flag on this one.
established_session_id() {
  fm_session_lock_recorded_session_id "$STATE" ||
    die "this home's lead is not a Claude session with a resumable session id (nothing is recorded beside the lock), and a lead restart is built for Claude only; no other worker runtime is supported here"
}

# The pane the lead runs in, from the lock-owner runtime record. bin/fm-lock.sh
# records it only when bin/fm-supervisor-target-lib.sh ESTABLISHED one, never
# its guessed fallback, so an absent record means refuse rather than restart
# into whatever terminal that fallback happens to name.
ESTABLISHED_BACKEND=
ESTABLISHED_TARGET=
established_pane() {
  ESTABLISHED_BACKEND=$(fm_session_lock_runtime_field "$STATE" backend) || ESTABLISHED_BACKEND=
  ESTABLISHED_TARGET=$(fm_session_lock_runtime_field "$STATE" target) || ESTABLISHED_TARGET=
  [ -n "$ESTABLISHED_BACKEND" ] && [ -n "$ESTABLISHED_TARGET" ] ||
    die "the terminal the lead runs in is not established for this session, so a replacement could not be started where the captain is looking; it is recorded at the next session start"
  case "$ESTABLISHED_BACKEND" in
    tmux | herdr) ;;
    *) die "the lead's terminal runs on '$ESTABLISHED_BACKEND', which has no verified way to start a replacement in the same pane" ;;
  esac
  fm_backend_target_exists "$ESTABLISHED_BACKEND" "$ESTABLISHED_TARGET" ||
    die "the lead's own terminal ($ESTABLISHED_TARGET) could not be confirmed to exist, so nothing would be started there"
}

# The profile the LEAD itself runs under, as recorded beside the lock. An empty
# value is the ambient default profile, which is a real answer; a record that
# does not name the current lock owner is no answer at all.
established_lead_profile() {
  fm_session_lock_runtime_field "$STATE" profile ||
    die "the account the lead itself runs on is not recorded for this session, so this cannot tell which seat it is moving off; it is recorded at the next session start"
}

# --- launch command ----------------------------------------------------------

# Print the lock-owning process's argv as one shell command line, or fail.
#
# An exact argv source is used where one exists: Linux /proc/<pid>/cmdline is
# NUL-separated, so every word boundary survives and the command is rebuilt with
# no interpretation at all.
#
# Everywhere else the only readable source is the FLATTENED argument string,
# where an argument that contained a space is indistinguishable from two
# arguments. Rebuilding a command from that is a guess, and this command refuses
# to guess about the thing it is going to run in the captain's terminal. So a
# flattened string is accepted only when it provably round-trips:
#   - every character is from a conservative set, with single spaces only, so
#     no quote, backslash, control character, or shell metacharacter is being
#     silently dropped or re-interpreted;
#   - it is short, because a long command line is where multi-word arguments
#     actually live (a pasted system prompt, a settings blob);
#   - the first word is an existing executable whose path names claude, so a
#     path containing a space fails here rather than being split;
#   - no two consecutive words after it are both non-flags. That is exactly the
#     signature of an argument that contained a space, and rejecting it is what
#     turns "probably fine" into "cannot have been split".
# Anything else is reported as not established, and --launch-command is the
# operator's way to state it exactly.
LAUNCH_CHARS_OK='^[A-Za-z0-9._/=:@,+-]+( [A-Za-z0-9._/=:@,+-]+)*$'
LAUNCH_MAX_CHARS=512
establish_launch_argv() {  # <pid>
  local pid=$1 flat first token prev=- rest
  if [ -r "/proc/$pid/cmdline" ]; then
    # Exact argv: NUL-separated, so every word boundary survives whatever
    # characters the words contain. A word carrying a newline is refused rather
    # than emitted, because the one-word-per-line form below could not carry it.
    while IFS= read -r -d '' token; do
      case "$token" in *$'\n'*) return 1 ;; esac
      printf '%s\n' "$token"
    done < "/proc/$pid/cmdline"
    return 0
  fi
  flat=$(ps -ww -o args= -p "$pid" 2>/dev/null | head -n 1) || return 1
  flat=${flat%"${flat##*[![:space:]]}"}
  [ -n "$flat" ] || return 1
  [ "${#flat}" -le "$LAUNCH_MAX_CHARS" ] || return 1
  local LC_ALL=C
  [[ "$flat" =~ $LAUNCH_CHARS_OK ]] || return 1
  first=${flat%% *}
  command -v "$first" >/dev/null 2>&1 || return 1
  fm_harness_path_name "$(command -v "$first")" >/dev/null 2>&1 || return 1
  rest=${flat#"$first"}
  for token in $rest; do
    case "$token" in
      -*) prev=flag ;;
      *)
        [ "$prev" != value ] || return 1
        prev=value
        ;;
    esac
  done
  # Safe to split on spaces: the pattern above proved single spaces only, and
  # its character set contains no glob character, so no word is expanded here.
  # shellcheck disable=SC2086 # Deliberate split of a string proved space-separated.
  printf '%s\n' $flat
}

# Print the successor's command line, given the lead's argv one word per line on
# stdin: the same command, with every session-selection flag removed and one
# --resume for the session being handed over, run under the destination seat's
# profile. Every word is re-quoted, so the printed line is what runs.
#
# The session flags are removed rather than left alone because a second --resume
# would be ambiguous and --fork-session would mint a NEW session id, which is
# exactly the successor that could not take this handover: the reservation and
# the lock sidecar both name the id being resumed.
compose_successor_command() {  # <profile-dir> <session-id>  (argv on stdin)
  local profile=$1 session=$2 token drop_value=0 out=''
  while IFS= read -r token; do
    [ -n "$token" ] || continue
    if [ "$drop_value" -eq 1 ]; then
      drop_value=0
      case "$token" in -*) ;; *) continue ;; esac
    fi
    case "$token" in
      --resume | -r | --session-id | --teleport | --from-pr)
        drop_value=1
        continue
        ;;
      --resume=* | --session-id=* | --teleport=* | --from-pr=* | --continue | -c | --fork-session)
        continue
        ;;
    esac
    out="$out $(printf '%q' "$token")"
  done
  printf 'CLAUDE_CONFIG_DIR=%q%s --resume %q\n' "$profile" "$out" "$session"
}

# --- shared preflight --------------------------------------------------------

TO_SEAT=''
LEAD_PID=''
LEAD_PROFILE=''
LEAD_SEAT=''
SESSION_ID=''
TO_PROFILE=''
LAUNCH_ARGV=''
SUCCESSOR_CMD=''

# Name the seat a profile directory belongs to, or the default seat for the
# ambient profile. A profile outside the seats root is reported by its path, so
# a lead running on an unmanaged profile still reads honestly.
seat_name_of_profile() {  # <profile-dir>
  local profile=$1 name
  [ -n "$profile" ] || { printf '%s\n' "$FM_SEAT_DEFAULT_NAME"; return 0; }
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    [ "$(fm_seat_dir "$name")" = "$profile" ] || continue
    printf '%s\n' "$name"
    return 0
  done < <(fm_seat_list)
  printf '%s\n' "$profile"
}

preflight() {  # <launch-command-override>
  local override=$1 state
  [ -n "$TO_SEAT" ] || die "no destination seat was named; bin/fm-seat.sh owns which seat to move to and passes it here"
  [ "$TO_SEAT" != "$FM_SEAT_DEFAULT_NAME" ] ||
    die "the ambient default profile is never a lead-restart destination: nothing here can tell which account it currently holds, and the lead must not be moved onto an account nobody named"
  fm_seat_name_valid "$TO_SEAT" || die "invalid seat name: $TO_SEAT"
  TO_PROFILE=$(fm_seat_dir "$TO_SEAT") || die "seat '$TO_SEAT' does not resolve to a profile directory"
  [ -d "$TO_PROFILE" ] || die "seat '$TO_SEAT' has no profile directory at $TO_PROFILE"

  LEAD_PID=$(established_lock_pid) || exit 1
  SESSION_ID=$(established_session_id) || exit 1
  LEAD_PROFILE=$(established_lead_profile) || exit 1
  LEAD_SEAT=$(seat_name_of_profile "$LEAD_PROFILE")
  [ "$LEAD_PROFILE" != "$TO_PROFILE" ] ||
    die "the lead is already running on seat '$TO_SEAT'"
  established_pane || exit 1

  # The successor must be PROVEN signed in before anything is armed. An
  # undecided probe is not proof and is refused here even though a worker spawn
  # would accept it under --force: a worker that fails on its first message is
  # one lost task, while a lead that cannot start leaves the captain with no
  # firstmate in that terminal.
  fm_seat_logged_in "$TO_PROFILE"
  state=$?
  case "$state" in
    0) ;;
    "$FM_SEAT_LOGIN_EXPIRED_RENEWABLE") ;;
    1) die "seat '$TO_SEAT' is not logged in, so the replacement firstmate would fail on its first message" ;;
    *) die "seat '$TO_SEAT' could not be confirmed logged in, and a lead restart never crosses that uncertainty" ;;
  esac

  if [ -n "$override" ]; then
    # An operator-stated command is already exact; it is split on whitespace
    # only because it was typed as one string, with globbing off so no word is
    # expanded, and the composed result is printed before anything runs.
    local -a override_words=()
    set -f
    # shellcheck disable=SC2206 # Deliberate word split of an operator-stated command.
    override_words=($override)
    set +f
    LAUNCH_ARGV=$(printf '%s\n' "${override_words[@]}")
  else
    LAUNCH_ARGV=$(establish_launch_argv "$LEAD_PID") ||
      die "the lead's own launch command could not be established from its running process, so the replacement could not be started with the same flags; re-run with --launch-command '<the exact command this session was started with>'"
  fi
  SUCCESSOR_CMD=$(printf '%s\n' "$LAUNCH_ARGV" | compose_successor_command "$TO_PROFILE" "$SESSION_ID")
}

report_plan() {
  printf 'lead seat: %s\n' "$LEAD_SEAT"
  printf 'destination seat: %s (%s)\n' "$TO_SEAT" "$TO_PROFILE"
  printf 'session resumed: %s\n' "$SESSION_ID"
  printf 'terminal: %s %s\n' "$ESTABLISHED_BACKEND" "$ESTABLISHED_TARGET"
  printf 'replacement command: %s\n' "$SUCCESSOR_CMD"
}

# --- the armed handover ------------------------------------------------------

mint_nonce() {
  LC_ALL=C tr -dc 'a-f0-9' < /dev/urandom 2>/dev/null | head -c 32
}

arm_handover() {
  local nonce window stage_file pid
  nonce=$(mint_nonce)
  case "$nonce" in
    ????????????????????????????????) ;;
    *) die "could not mint a handover token" ;;
  esac
  window=$(( GRACE + EXIT_WAIT + START_WAIT + CLAIM_WAIT ))

  stage_file="$STATE/.lead-restart.launch"
  # A previous attempt's outcome would otherwise be read as this one's below.
  rm -f "$stage_file" "$RESULT" 2>/dev/null || true
  (umask 077; printf 'FM_LEAD_HANDOVER=%s %s\n' "$nonce" "$SUCCESSOR_CMD" > "$stage_file") ||
    die "could not stage the replacement command"

  if ! (umask 077; {
    printf 'nonce=%s\n' "$nonce"
    printf 'session=%s\n' "$SESSION_ID"
    printf 'pid=%s\n' "$LEAD_PID"
    printf 'backend=%s\n' "$ESTABLISHED_BACKEND"
    printf 'target=%s\n' "$ESTABLISHED_TARGET"
    printf 'from_profile=%s\n' "$LEAD_PROFILE"
    printf 'to_seat=%s\n' "$TO_SEAT"
    printf 'to_profile=%s\n' "$TO_PROFILE"
    printf 'launch_file=%s\n' "$stage_file"
    printf 'command=%s\n' "$SUCCESSOR_CMD"
    printf 'grace=%s\n' "$GRACE"
    printf 'exit_wait=%s\n' "$EXIT_WAIT"
    printf 'start_wait=%s\n' "$START_WAIT"
    printf 'claim_wait=%s\n' "$CLAIM_WAIT"
  } > "$PLAN"); then
    rm -f "$stage_file" 2>/dev/null || true
    die "could not record the restart plan"
  fi

  # The reservation is armed while the old lead is still holding the lock, so
  # there is no instant in which this home is unowned and unreserved.
  if ! FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
    "$SCRIPT_DIR/fm-lock.sh" handover "$SESSION_ID" "$nonce" "$window" >/dev/null; then
    rm -f "$stage_file" "$PLAN" 2>/dev/null || true
    die "this home could not be reserved for the replacement session, so nothing was started and this session is still in charge"
  fi

  # Detached exactly as bin/fm-startup-network.sh detaches its worker, and for
  # one extra reason that matters only here: its own process group means the
  # stage survives the very process it is about to end.
  local monitor_was_on=0
  case $- in *m*) monitor_was_on=1 ;; esac
  set -m 2>/dev/null || true
  nohup env FM_HOME="$FM_HOME" FM_ROOT_OVERRIDE="$FM_ROOT" FM_STATE_OVERRIDE="$STATE" \
    FM_CONFIG_OVERRIDE="$CONFIG" \
    "$SCRIPT_DIR/fm-lead-restart.sh" --handover-stage "$PLAN" \
    >/dev/null 2>&1 </dev/null &
  pid=$!
  [ "$monitor_was_on" -eq 1 ] || set +m 2>/dev/null || true
  sleep 0.2
  if ! kill -0 "$pid" 2>/dev/null && [ ! -f "$RESULT" ]; then
    clear_reservation "$nonce"
    rm -f "$stage_file" "$PLAN" 2>/dev/null || true
    die "the replacement could not be started, so nothing was touched and this session is still in charge"
  fi
  printf 'handover armed (worker %s)\n' "$pid"
  report_plan
  printf 'this session ends in %ss; the replacement starts in the same terminal on seat %s\n' "$GRACE" "$TO_SEAT"
}

# --- detached stage ----------------------------------------------------------

# Drop the reservation this stage armed. It runs detached and outlives the
# process whose ancestry proved ownership, so it proves its authority with the
# nonce it holds instead - the same proof the successor uses.
clear_reservation() {  # <nonce>
  FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_LEAD_HANDOVER="$1" \
    "$SCRIPT_DIR/fm-lock.sh" handover-clear >/dev/null 2>&1 || true
}

plan_field() {  # <key>
  sed -n "s/^$1=//p" "$PLAN_FILE" 2>/dev/null | tail -1
}

record_result() {  # <state> <detail>
  (umask 077; {
    printf 'state=%s\n' "$1"
    printf 'at=%s\n' "$(date +%s)"
    printf 'detail=%s\n' "$2"
    printf 'command=%s\n' "$P_COMMAND"
    printf 'launch_file=%s\n' "$P_LAUNCH_FILE"
  } > "$RESULT") || true
}

handover_stage() {  # <plan-file>
  PLAN_FILE=$1
  [ -f "$PLAN_FILE" ] || exit 1
  local nonce pid backend target to_seat grace exit_wait start_wait claim_wait waited
  nonce=$(plan_field nonce)
  pid=$(plan_field pid)
  backend=$(plan_field backend)
  target=$(plan_field target)
  to_seat=$(plan_field to_seat)
  grace=$(plan_field grace)
  exit_wait=$(plan_field exit_wait)
  start_wait=$(plan_field start_wait)
  claim_wait=$(plan_field claim_wait)
  P_COMMAND=$(plan_field command)
  P_LAUNCH_FILE=$(plan_field launch_file)
  case "$pid" in ''|*[!0-9]*) exit 1 ;; esac
  case "$grace$exit_wait$start_wait$claim_wait" in ''|*[!0-9]*) exit 1 ;; esac

  sleep "$grace"

  # End the old lead, and nothing else. The watcher is a separate process with
  # its own lock and is deliberately not in this kill, so supervision never
  # drops to zero across the swap.
  kill -TERM "$pid" 2>/dev/null || true
  waited=0
  while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt "$exit_wait" ]; do
    sleep 1
    waited=$((waited + 1))
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill -KILL "$pid" 2>/dev/null || true
    waited=0
    while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt 10 ]; do
      sleep 1
      waited=$((waited + 1))
    done
  fi
  if kill -0 "$pid" 2>/dev/null; then
    # Nothing was replaced and the old lead is still the live owner, so the
    # reservation is dropped and the home carries on exactly as it was.
    clear_reservation "$nonce"
    rm -f "$P_LAUNCH_FILE" 2>/dev/null || true
    record_result refused "the firstmate session would not end, so it is still running and still in charge; nothing moved to seat $to_seat"
    fm_wake_append check lead-restart \
      "check: lead-restart: the move to Claude seat $to_seat was abandoned because the current firstmate session would not end; it is still in charge" || true
    exit 1
  fi

  # From here the old process is gone. Everything durable survives it, so the
  # worst outcome below is a terminal that needs one command typed into it.
  # The literal send and the Enter are separated the same way bin/fm-spawn.sh
  # separates them, so the terminal has settled before the line is submitted.
  if ! fm_backend_send_literal "$backend" "$target" ". $P_LAUNCH_FILE" ||
    ! sleep 0.3 ||
    ! fm_backend_send_key "$backend" "$target" Enter; then
    clear_reservation "$nonce"
    record_result stranded "the previous firstmate session ended but the replacement command could not be delivered to its terminal; run '. $P_LAUNCH_FILE' there"
    fm_wake_append check lead-restart \
      "check: lead-restart: the previous firstmate session ended but its replacement could not be started in that terminal; the exact command to run there is in $RESULT" || true
    exit 1
  fi

  waited=0
  while [ "$waited" -lt "$start_wait" ]; do
    fm_backend_agent_alive "$backend" "$target" && break
    sleep 2
    waited=$((waited + 2))
  done
  if ! fm_backend_agent_alive "$backend" "$target"; then
    clear_reservation "$nonce"
    record_result stranded "the replacement was sent to the terminal but no agent came up there within ${start_wait}s; run '. $P_LAUNCH_FILE' there"
    fm_wake_append check lead-restart \
      "check: lead-restart: the replacement firstmate did not come up in its terminal; the exact command to run there is in $RESULT" || true
    exit 1
  fi

  # The reservation clears itself when the successor proves the nonce at its own
  # lock acquisition, so its disappearance is the handover completing rather
  # than anything this stage does.
  waited=0
  while [ "$waited" -lt "$claim_wait" ]; do
    fm_session_lock_handover_live "$STATE" || break
    sleep 5
    waited=$((waited + 5))
  done
  if fm_session_lock_handover_live "$STATE"; then
    record_result started "the replacement is running on seat $to_seat but has not taken this home's lock yet; the reservation lapses on its own"
    exit 0
  fi
  rm -f "$P_LAUNCH_FILE" 2>/dev/null || true
  record_result 'done' "the firstmate session moved to Claude seat $to_seat in the same terminal, resuming the same session"
  exit 0
}

# --- argument handling -------------------------------------------------------

MODE=arm
LAUNCH_OVERRIDE=''
PERSISTED=0
PLAN_FILE=''
P_COMMAND=''
P_LAUNCH_FILE=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --check) MODE=check; shift ;;
    --persisted) PERSISTED=1; shift ;;
    --to) [ "$#" -ge 2 ] || usage; TO_SEAT=$2; shift 2 ;;
    --launch-command) [ "$#" -ge 2 ] || usage; LAUNCH_OVERRIDE=$2; shift 2 ;;
    --grace) [ "$#" -ge 2 ] || usage; GRACE=$2; shift 2 ;;
    --handover-stage) [ "$#" -ge 2 ] || usage; MODE=stage; PLAN_FILE=$2; shift 2 ;;
    -h | --help) usage ;;
    *) usage ;;
  esac
done

case "$GRACE" in ''|*[!0-9]*) die "--grace takes a whole number of seconds" ;; esac

case "$MODE" in
  stage) handover_stage "$PLAN_FILE" ;;
  check)
    preflight "$LAUNCH_OVERRIDE"
    report_plan
    ;;
  arm)
    # Only the lead may replace the lead. bin/fm-lock.sh refuses the reservation
    # to any other session anyway, but refusing here means a session that is not
    # this home's lead never gets as far as writing a plan for one.
    fm_session_lock_owned_by_self "$STATE" ||
      die "this is not the firstmate session that holds this home, so it cannot replace it"
    preflight "$LAUNCH_OVERRIDE"
    [ "$PERSISTED" -eq 1 ] ||
      die "this replaces the running firstmate session and drops its conversation, keeping every durable record. So first $FM_PERSIST_OPEN_RECORDS_CONTRACT Then re-run with --persisted"
    arm_handover
    ;;
esac
