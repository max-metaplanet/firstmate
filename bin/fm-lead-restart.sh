#!/usr/bin/env bash
# fm-lead-restart.sh - move or refresh the PRIMARY firstmate session on a
# Claude or Codex seat, by replacing its own process in its own terminal.
#
# Usage:
#   fm-lead-restart.sh --check [--provider claude|codex] --to <seat> [--refresh]
#   fm-lead-restart.sh [--provider claude|codex] --to <seat> --persisted [--refresh]
#                      [--launch-command <cmd>] [--grace <s>]
#   fm-lead-restart.sh --handover-stage <plan-file>     (internal; detached)
#
# --refresh permits the explicitly named seat to be the lead's current seat.
# It uses the same persist gate and handover, without changing seat records or
# rotation; without it, a same-seat destination is refused.
#
# WHY THIS IS NOT A SEAT SWITCH. bin/fm-seat.sh switch rewrites one config line
# that only a fresh spawn reads, so it moves NEW workers and never disturbs
# anything running - including the lead, which keeps the account it launched on
# until something replaces its process. There is no way to move a running Claude
# Code process to another credential store, so the only way the lead itself
# changes account is to be replaced: tell the crew, start another claude on the
# new seat in the same terminal, resuming only a Claude-to-Claude session, and end the old
# process. Seats may share a projects directory or keep separate histories.
# Claude-to-Claude preflight, including --check, makes the current transcript
# and its companion directory available in the destination with per-session
# links. The links retain writes made by the old lead until it exits; unrelated
# destination history is never replaced. A missing, unreadable, ambiguous, or
# conflicting history refuses before the old process is ended.
#
# WHAT THE CREW IS TOLD, AND WHY IT IS CHEAP. Before the old process is ended,
# each live direct report of this home gets one short notice that the lead is
# restarting onto another seat, that its own work, seat, and steering inbox are
# unaffected, and that it should carry on without replying. Nothing changes for
# a worker - steering is a durable inbox, status is a durable log, and every task
# keeps the seat recorded in its own task record - so the notice is sent
# fire-and-forget: no acknowledgement is expected and no re-ring ladder spans
# the swap. A worker the notice cannot reach never blocks the restart; it is
# named in the result instead. Workers are not moved. The one real worker-facing
# effect is supervision, and it is handled by NOT touching it: the watcher is a
# separate process with its own singleton lock, it is never in the kill below,
# and the successor's own arm attaches to a live watcher instead of starting a
# second one. So the cycle count goes from one to one, and the durable wake
# queue holds anything that arrives meanwhile.
#
# THE FIVE THINGS THAT MUST BE ESTABLISHED, never guessed. Any one of them
# missing is a refusal, and a refusal at this stage leaves the old lead running
# and in charge, because nothing has been touched yet:
#   1. This home's lock is held by a live Claude or embedded Codex session.
#      A shared Codex app-server is never terminated as a leader.
#   2. The lead's OWN profile, from state/.lock-runtime (bin/fm-lock.sh writes
#      it bound to the lock's pid). config/claude-seat is NOT that answer: it
#      names the seat new workers get and moves without the lead.
#   3. The destination seat, named by the caller, with a profile directory that
#      exists and a login the probe proves usable. bin/fm-seat.sh owns seat
#      selection; this command never picks one.
#   4. For Claude-to-Claude, the session id from the lock sidecar and its
#      readable transcript in the destination profile's projects directory.
#      Cross-provider moves and all Codex moves start fresh from durable records.
#   5. The pane, and the lead's own launch command, from the lock-runtime record
#      and the lock-owning process's real argv. `establish_launch_command` below
#      owns why a flattened argv is accepted only when it provably round-trips.
#
# Codex successors always use --no-daemon: tool ancestry then belongs to the
# TUI rather than a shared app-server. Remote Control is not available through
# the separate managed daemon for this embedded session. Automatic selection
# excludes Codex unless config/lead-codex-auto explicitly enables it; fm-seat.sh
# owns that policy. An explicit --provider codex is a manual destination.
#
# WHY THE REPLACEMENT IS GIVEN A PROMPT. A resumed Claude session comes up at
# an empty composer and takes no turn until something is submitted to it, and
# the home's lock is taken by an AGENT action - bin/fm-session-start.sh, run in
# the replacement's first turn - not by the process coming up. So a replacement
# launched with nothing to do holds this home's terminal while the home itself
# stays unlocked and unsupervised until a human types into it (observed
# 2026-10-17: a successor sat idle for about eight hours). Claude Code's native
# session-open adapter cannot close that gap either, because a `--resume` is
# routed to the nudge tier, and a nudge in context is still only read on a turn
# that nothing starts. The replacement therefore carries an initial prompt, the
# one session-start instruction bin/fm-operational-input.sh owns, delivered the
# way every other Claude launch prompt carries Firstmate instructions: the
# envelope is published as a record in this home's operational inbox and only
# its printable doorbell rides the command line, because Claude Code strips the
# typed marker from a launch prompt. A record that cannot be published is a
# refusal, before anything is touched.
#
# REMOTE CONTROL FOLLOWS THE LEAD, by default. Remote Control is a property of
# the PROCESS, so a replacement starts without it even though it resumes the
# same session, and the captain had to turn it back on by hand. So the outgoing
# lead's state is read first and the replacement is launched with
# `--remote-control` when it was on. The state is EVIDENCE, never a guess: the
# per-pid session record Claude Code keeps in <profile>/sessions/<pid>.json
# carries `bridgeSessionId` while Remote Control is connected, whether it was
# turned on by that flag or by `/rc` in the running session, and carries null or
# nothing once it is off (verified 2026-10-16 on Claude Code 2.1.301;
# docs/verification/runtime-backends.md owns the exact commands and output).
# A record that cannot be read, or that does not name the session being handed
# over, means the state is UNDETERMINABLE: nothing is turned on, and the outcome
# line says so rather than guessing. After the successor takes the home the same
# field is read back on it, so the outcome reports whether Remote Control
# actually followed rather than that a flag was passed.
# This is the LEAD's restart only: no worker, secondmate, or ordinary relaunch
# reads or carries any of it.
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
#   FM_LEAD_RESTART_RC_WAIT      seconds to wait for Remote Control to connect
#                                in the replacement before the outcome reports
#                                that it did not follow (60)
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
# The successor's initial prompt is Firstmate operational input, and this file
# owns both its wording and the record-backed carrier Claude needs for it.
# shellcheck source=bin/fm-operational-input.sh
. "$SCRIPT_DIR/fm-operational-input.sh"
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
RC_WAIT=${FM_LEAD_RESTART_RC_WAIT:-60}
NOTICE_WAIT=30

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

# A Claude outgoing session must prove its session id from the lock sidecar.
# Codex has no cross-provider resume identity and uses nonce-only handover.
established_session_id() {
  fm_session_lock_recorded_session_id "$STATE" ||
    die "this home's lead is not a Claude session with a resumable session id (nothing is recorded beside the lock), so its Claude conversation cannot be resumed"
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

# The native profile the LEAD itself runs under, as recorded beside the lock.
# An empty Claude value is the ambient default profile, which is a real answer; a record that
# does not name the current lock owner is no answer at all.
established_lead_profile() {
  fm_session_lock_runtime_field "$STATE" profile ||
    die "the account the lead itself runs on is not recorded for this session, so this cannot tell which seat it is moving off; it is recorded at the next session start"
}

# Only the current session is shared, never the destination's entire projects
# tree. Locate it under the recorded outgoing profile rather than assuming an
# encoding of the working directory or falling back to another account's files.
# Existing links to the same files (including a shared projects tree) are an
# idempotent success; any other destination entry is preserved and refused.
establish_resumable_history() {
  local profile=${LEAD_PROFILE:-${HOME:-}/.claude} candidate source='' project destination name
  case "$SESSION_ID" in
    '' | *[!a-zA-Z0-9-]*) die 'cannot resume: the recorded Claude session id is not a safe history filename' ;;
  esac
  for candidate in "$profile/projects/"*/"$SESSION_ID.jsonl"; do
    [ -e "$candidate" ] || continue
    [ -z "$source" ] || die "cannot resume: session $SESSION_ID has multiple transcripts under $profile/projects"
    source=$candidate
  done
  [ -n "$source" ] && [ -f "$source" ] && [ -r "$source" ] && [ -s "$source" ] ||
    die "cannot resume: session $SESSION_ID has no readable nonempty transcript under $profile/projects"
  project=$(cd -P -- "$(dirname "$source")" && pwd -P) || die 'cannot resume: the source project directory is inaccessible'
  destination="$TO_PROFILE/projects/$(basename "$(dirname "$source")")"
  # Create the companion directory even before the first subagent uses it, so
  # companions written after preflight are visible through the same link.
  (umask 077; mkdir -p "$project/$SESSION_ID" "$destination") ||
    die "cannot resume: session directories could not be prepared for seat '$TO_SEAT'"
  [ -r "$project/$SESSION_ID" ] && [ -x "$project/$SESSION_ID" ] ||
    die "cannot resume: session $SESSION_ID companion directory is unreadable"
  for name in "$SESSION_ID.jsonl" "$SESSION_ID"; do
    [ ! "$project/$name" -ef "$destination/$name" ] || continue
    [ ! -e "$destination/$name" ] && [ ! -L "$destination/$name" ] ||
      die "cannot resume: destination history already exists at $destination/$name; refusing to replace it"
    ln -s "$project/$name" "$destination/$name" ||
      die "cannot resume: could not link session history at $destination/$name"
    [ "$project/$name" -ef "$destination/$name" ] ||
      die "cannot resume: destination history does not reach $project/$name"
  done
}

# --- remote control ----------------------------------------------------------

# The directory Claude Code keeps its per-pid session records in, for a session
# running under profile $1. An empty profile is the ambient default profile,
# whose records live under $HOME/.claude. Read the profile's own path whether
# its registry is shared or private to that seat.
rc_records_dir() {  # <profile>
  if [ -n "$1" ]; then
    printf '%s/sessions\n' "$1"
    return 0
  fi
  [ -n "${HOME:-}" ] || return 1
  printf '%s/.claude/sessions\n' "$HOME"
}

# Print `on`, `off`, or `undeterminable` for the Claude session running as pid $1
# under profile $2 and resuming session id $3.
#
# The record is proof only while it provably describes THAT session: the file is
# named by pid, and its own sessionId must be the id being handed over, so a
# recycled pid or a stale record left by an earlier session is undeterminable
# rather than evidence. `bridgeSessionId` is the Remote Control connection; it is
# absent before Remote Control is ever used and null after it is disconnected,
# and both mean off.
rc_state_of() {  # <pid> <profile> <session-id>
  local pid=$1 profile=$2 session=$3 dir record recorded bridge
  dir=$(rc_records_dir "$profile") || { printf 'undeterminable\n'; return 0; }
  record="$dir/$pid.json"
  command -v jq >/dev/null 2>&1 || { printf 'undeterminable\n'; return 0; }
  [ -f "$record" ] && [ ! -L "$record" ] || { printf 'undeterminable\n'; return 0; }
  recorded=$(jq -r '.sessionId // empty' "$record" 2>/dev/null) || recorded=''
  [ -n "$recorded" ] && [ "$recorded" = "$session" ] || { printf 'undeterminable\n'; return 0; }
  bridge=$(jq -r 'if (.bridgeSessionId // null) == null then "" else (.bridgeSessionId | tostring) end' \
    "$record" 2>/dev/null) || { printf 'undeterminable\n'; return 0; }
  [ -n "$bridge" ] && printf 'on\n' || printf 'off\n'
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
# When <follow-rc> is 1, the replacement also carries --remote-control, so the
# Remote Control the outgoing lead had comes back up with it. An argv that
# already names the flag keeps its own spelling, including the session name it
# may carry: adding a second one would rename the remote session for no reason.
# <prompt> is the initial prompt the replacement starts its first turn on (the
# header's "WHY THE REPLACEMENT IS GIVEN A PROMPT"). It is the trailing
# positional argument, where Claude Code takes a launch prompt, so it can never
# be read as the optional value of the --resume immediately before it.
compose_successor_command() {  # <profile> <session> <ambient> <follow-rc> <prompt>; argv on stdin
  local profile=$1 session=$2 ambient=$3 follow_rc=${4:-0} prompt=${5-}
  local token drop_value=0 out='' has_rc=0 argv_json claude_profile
  local -a words=()
  while IFS= read -r token; do
    [ -n "$token" ] || continue
    if [ "$drop_value" -eq 1 ]; then
      drop_value=0
      case "$token" in -*) ;; *) continue ;; esac
    fi
    case "$token" in
      --resume | -r | --session-id | --teleport | --from-pr)
        drop_value=1; continue ;;
      --resume=* | --session-id=* | --teleport=* | --from-pr=* | --continue | -c | --fork-session)
        continue ;;
      --remote-control | --remote-control=*) has_rc=1 ;;
      "$FM_OPERATIONAL_DOORBELL_PREFIX"*) continue ;;
    esac
    words+=("$token")
  done
  # Persist the prompt-free argv so a second restart does not depend on ps's
  # flattened rendering of the previous one-shot, multiword launch prompt.
  argv_json=$(printf '%s\n' "${words[@]}" | jq -Rsc 'split("\n")[:-1]') || return 1
  for token in "${words[@]}"; do out="$out $(printf '%q' "$token")"; done
  claude_profile=$profile
  if [ "$TO_PROVIDER" = codex ]; then
    claude_profile=$(fm_session_lock_runtime_field "$STATE" claude_profile) || claude_profile=$LEAD_PROFILE
  fi
  # A pane shell does not retain assignments prefixed onto the old launch.
  # Carry this home's identity explicitly rather than inherit the shell's home.
  printf 'FM_HOME=%q FM_ROOT_OVERRIDE=%q FM_STATE_OVERRIDE=%q FM_CONFIG_OVERRIDE=%q FM_DATA_OVERRIDE=%q FM_LEAD_LAUNCH_ARGV=%q ' \
    "$FM_HOME" "$FM_ROOT" "$STATE" "$CONFIG" "${FM_DATA_OVERRIDE:-$FM_HOME/data}" "$argv_json"
  printf 'FM_AMBIENT_CLAUDE_CONFIG_DIR=%q CLAUDE_CONFIG_DIR=%q ' "$ambient" "$claude_profile"
  if [ "$TO_PROVIDER" = codex ]; then
    printf 'CODEX_HOME=%q env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID -u CLAUDECODE%s %q\n' "$profile" "$out" "$prompt"
  else
    [ "$follow_rc" != 1 ] || [ "$has_rc" -eq 1 ] || out="$out --remote-control"
    printf 'env -u CLAUDE_SECURESTORAGE_CONFIG_DIR -u CLAUDE_CODE_CHILD_SESSION CLAUDE_CODE_FORCE_SESSION_PERSISTENCE=1%s ' "$out"
    if [ "$SESSION_MODE" = resume ]; then
      printf -- '--resume %q %q\n' "$session" "$prompt"
    else
      printf -- '--session-id %q %q\n' "$session" "$prompt"
    fi
  fi
}

# The initial prompt the replacement comes up on, published as a record in this
# home's operational inbox; the doorbell naming it is what the command line
# carries. Publishing here rather than at arm time means the printed plan is
# the command that will actually run, and a home whose record cannot be written
# refuses while the old lead is still untouched.
establish_session_start_prompt() {
  local doorbell
  fm_operational_record_write "$STATE" session-start "$FM_OPERATIONAL_SESSION_START_BODY" doorbell ||
    die "the session-start instruction the replacement starts on could not be recorded under $STATE/$FM_OPERATIONAL_RECORD_DIRNAME, so the replacement would come up with nothing to do and this home would stay unheld"
  printf '%s\n' "$doorbell"
}

# --- shared preflight --------------------------------------------------------

TO_PROVIDER=claude
LEAD_HARNESS=''
SESSION_MODE=resume
SUCCESSOR_SESSION=''
KEEP_HOST=0
TO_SEAT=''
LEAD_PID=''
LEAD_PROFILE=''
LEAD_SEAT=''
SESSION_ID=''
TO_PROFILE=''
LAUNCH_ARGV=''
SUCCESSOR_PROMPT=''
SUCCESSOR_CMD=''
# on, off, undeterminable, or kept (not on, but the launch command names it).
LEAD_RC=''

preflight() {  # <launch-command-override>
  local override=$1 state follow=0 recorded args permission ambient
  [ -n "$TO_SEAT" ] || die "no destination seat was named; bin/fm-seat.sh owns which seat to move to and passes it here"
  [ "$TO_SEAT" != "$FM_SEAT_DEFAULT_NAME" ] ||
    die "the ambient default profile is never a lead-restart destination: nothing here can tell which account it currently holds, and the lead must not be moved onto an account nobody named"
  fm_seat_name_valid "$TO_SEAT" || die "invalid seat name: $TO_SEAT"
  FM_SEAT_PROVIDER=$TO_PROVIDER
  TO_PROFILE=$(fm_seat_config_dir "$TO_SEAT") || die "seat '$TO_SEAT' does not resolve to a profile directory"
  [ -d "$TO_PROFILE" ] || die "seat '$TO_SEAT' has no profile directory at $TO_PROFILE"

  LEAD_PID=$(established_lock_pid) || exit 1
  LEAD_HARNESS=$(fm_session_lock_runtime_field "$STATE" harness) || LEAD_HARNESS=claude
  case "$LEAD_HARNESS" in
    claude) SESSION_ID=$(established_session_id) || exit 1 ;;
    codex)
      args=$(ps -ww -o args= -p "$LEAD_PID" 2>/dev/null) || die 'cannot inspect the Codex lock owner'
      case " $args " in
        *' --no-daemon '*) ;;
        *) die 'the Codex lock owner is not an embedded TUI (--no-daemon); refusing to terminate a potentially shared daemon' ;;
      esac
      SESSION_ID="pid-$LEAD_PID"
      ;;
    *) die "leader restart does not support $LEAD_HARNESS" ;;
  esac
  SESSION_MODE=fresh
  [ "$LEAD_HARNESS:$TO_PROVIDER" != claude:claude ] || SESSION_MODE=resume
  SUCCESSOR_SESSION=$SESSION_ID
  if [ "$SESSION_MODE" = fresh ] && [ "$TO_PROVIDER" = claude ]; then
    SUCCESSOR_SESSION=$(python3 -c 'import uuid; print(uuid.uuid4())') || die 'could not create a fresh Claude session id'
  fi
  LEAD_PROFILE=$(established_lead_profile) || exit 1
  LEAD_SEAT=$(FM_SEAT_PROVIDER="$LEAD_HARNESS" fm_seat_name_of_profile "$LEAD_PROFILE")
  [ "$LEAD_PROFILE" != "$TO_PROFILE" ] || [ "$REFRESH" -eq 1 ] ||
    die "the lead is already running on seat '$TO_SEAT'; use --refresh to restart in place"
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

  if [ "$TO_PROVIDER" = codex ]; then
    [ -z "$override" ] || die 'Codex leaders use the verified embedded launch; --launch-command is Claude-only'
    command -v codex >/dev/null 2>&1 || die 'codex is not installed'
    codex --help 2>/dev/null | grep -q -- '--no-daemon' || die 'this Codex CLI does not support the required --no-daemon launch'
    # A Codex leader always starts fresh on the agreed model. CLI configuration
    # supplies effort and project hooks; worker hook-disabling flags do not apply.
    LAUNCH_ARGV=$(printf '%s\n' codex --no-daemon --model gpt-6.1-sol --dangerously-bypass-approvals-and-sandbox)
  elif [ -n "$override" ]; then
    # An operator-stated command is already exact; it is split on whitespace
    # only because it was typed as one string, with globbing off so no word is
    # expanded, and the composed result is printed before anything runs.
    local -a override_words=()
    set -f
    # shellcheck disable=SC2206 # Deliberate word split of an operator-stated command.
    override_words=($override)
    set +f
    LAUNCH_ARGV=$(printf '%s\n' "${override_words[@]}")
  elif [ "$LEAD_HARNESS" = codex ]; then
    permission=$(cat "$CONFIG/claude-permission-mode" 2>/dev/null || printf bypass)
    case "$permission" in
      bypass) LAUNCH_ARGV=$(printf '%s\n' claude --model opus --dangerously-skip-permissions) ;;
      auto) LAUNCH_ARGV=$(printf '%s\n' claude --model opus --permission-mode auto) ;;
      *) die 'invalid config/claude-permission-mode; expected bypass or auto' ;;
    esac
  else
    recorded=$(fm_session_lock_runtime_field "$STATE" launch_argv) || recorded=''
    if [ -n "$recorded" ]; then
      LAUNCH_ARGV=$(printf '%s' "$recorded" | jq -er 'select(type == "array" and length > 0 and all(.[]; type == "string" and (contains("\n") | not))) | .[]') || die 'recorded leader launch argv is invalid'
    else
      LAUNCH_ARGV=$(establish_launch_argv "$LEAD_PID") ||
      die "the lead's own launch command could not be established from its running process, so the replacement could not be started with the same flags; re-run with --launch-command '<the exact command this session was started with>'"
    fi
  fi
  LEAD_RC=off
  [ "$LEAD_HARNESS" != claude ] || LEAD_RC=$(rc_state_of "$LEAD_PID" "$LEAD_PROFILE" "$SESSION_ID")
  [ "$LEAD_RC" != on ] || follow=1
  if [ "$TO_PROVIDER" = codex ]; then
    LEAD_RC=unavailable
  elif [ "$LEAD_HARNESS" = codex ]; then
    LEAD_RC=requested; follow=1
  else
    [ "$LEAD_RC" = on ] || ! printf '%s\n' "$LAUNCH_ARGV" | grep -Eq -- '^--remote-control(=|$)' || LEAD_RC=kept
  fi
  ambient=$(fm_session_lock_runtime_field "$STATE" ambient) || ambient=${FM_AMBIENT_CLAUDE_CONFIG_DIR-${CLAUDE_CONFIG_DIR:-}}
  [ "$LEAD_HARNESS" != claude ] || ambient=${FM_AMBIENT_CLAUDE_CONFIG_DIR-$LEAD_PROFILE}
  KEEP_HOST=0
  if [ "$LEAD_HARNESS:$TO_PROVIDER" = claude:codex ] && [ ! -e "$CONFIG/supervision-host" ] && [ ! -e "$CONFIG/supervision-host-off" ]; then
    KEEP_HOST=1
  fi
  [ "$SESSION_MODE" != resume ] || establish_resumable_history
  SUCCESSOR_PROMPT=$(establish_session_start_prompt) || exit 1
  SUCCESSOR_CMD=$(printf '%s\n' "$LAUNCH_ARGV" | compose_successor_command "$TO_PROFILE" "$SUCCESSOR_SESSION" "$ambient" "$follow" "$SUCCESSOR_PROMPT") || die 'could not compose the successor command'

}

# What the plan, the check, and the outcome all say about Remote Control, from
# the state $1 established before the swap.
rc_plan_line() {  # <state>
  case "$1" in
    unavailable) printf 'unavailable for the embedded Codex successor; automatic Codex moves require explicit opt-in\n' ;;
    requested) printf 'requested for the fresh Claude successor, with connection read-back after claim\n' ;;
    on) printf 'on in this session, so the replacement is launched with it\n' ;;
    off) printf 'off in this session, so the replacement is not given it\n' ;;
    kept) printf 'not on in this session, but the replacement keeps the --remote-control its launch command already names\n' ;;
    *) printf 'undeterminable for this session, so the replacement is not given it\n' ;;
  esac
}

report_plan() {
  printf 'providers: %s -> %s\n' "$LEAD_HARNESS" "$TO_PROVIDER"
  printf 'lead seat: %s\n' "$LEAD_SEAT"
  printf 'destination seat: %s (%s)\n' "$TO_SEAT" "$TO_PROFILE"
  if [ "$SESSION_MODE" = resume ]; then
    printf 'session resumed: %s\n' "$SESSION_ID"
  else
    printf 'session: fresh %s, rebuilt from durable records\n' "$TO_PROVIDER"
  fi
  printf 'first turn: the replacement is prompted to run bin/fm-session-start.sh and take this home\n'
  printf 'terminal: %s %s\n' "$ESTABLISHED_BACKEND" "$ESTABLISHED_TARGET"
  printf 'remote control: %s\n' "$(rc_plan_line "$LEAD_RC")"
  printf 'replacement command: %s\n' "$SUCCESSOR_CMD"
}

# --- the armed handover ------------------------------------------------------

mint_hex() {  # <length>
  LC_ALL=C tr -dc 'a-f0-9' < /dev/urandom 2>/dev/null | head -c "$1"
}

arm_handover() {
  local nonce window stage_file pid crew=0 meta
  nonce=$(mint_hex 32)
  case "$nonce" in
    ????????????????????????????????) ;;
    *) die "could not mint a handover token" ;;
  esac
  for meta in "$STATE"/*.meta; do
    [ -e "$meta" ] && crew=$((crew + 1))
  done
  # Every bounded step the stage can spend before the successor claims: the crew
  # notice, the grace, both exit waits, the pane settling, the start, the claim.
  # RC_WAIT is deliberately NOT here: the Remote Control read-back runs after the
  # successor has claimed the home, which is where the reservation already ends.
  window=$(( crew * NOTICE_WAIT + GRACE + EXIT_WAIT + 10 + 10 + START_WAIT + CLAIM_WAIT ))

  stage_file="$STATE/.lead-restart.launch"
  # A previous attempt's outcome would otherwise be read as this one's below.
  rm -f "$stage_file" "$RESULT" 2>/dev/null || true
  (umask 077; printf '( cd -- %q || exit; FM_LEAD_HANDOVER=%s %s )\n' "$FM_ROOT" "$nonce" "$SUCCESSOR_CMD" > "$stage_file") ||
    die "could not stage the replacement command"

  if ! (umask 077; {
    printf 'nonce=%s\n' "$nonce"
    printf 'session=%s\n' "$SUCCESSOR_SESSION"
    printf 'provider=%s\n' "$TO_PROVIDER"
    printf 'session_mode=%s\n' "$SESSION_MODE"
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
    printf 'rc_wait=%s\n' "$RC_WAIT"
    printf 'follow_rc=%s\n' "$LEAD_RC"
  } > "$PLAN"); then
    rm -f "$stage_file" 2>/dev/null || true
    die "could not record the restart plan"
  fi

  if [ "$KEEP_HOST" -eq 1 ]; then
    (umask 077; set -C; printf 'claude\n' > "$CONFIG/supervision-host") ||
      die 'could not preserve the Claude supervision host for the Codex primary'
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

CREW_UNREACHED=''
RC_NOTE=''
# Written whole and renamed into place, so a reader polling for state= never
# sees the state line without the detail that explains it.
record_result() {  # <state> <detail>
  local detail=$2
  [ -z "$RC_NOTE" ] || detail="$detail; $RC_NOTE"
  [ -z "$CREW_UNREACHED" ] ||
    detail="$detail; the restart notice could not be delivered to: $CREW_UNREACHED"
  (umask 077; {
    printf 'state=%s\n' "$1"
    printf 'at=%s\n' "$(date +%s)"
    printf 'detail=%s\n' "$detail"
    printf 'command=%s\n' "$P_COMMAND"
    printf 'launch_file=%s\n' "$P_LAUNCH_FILE"
  } > "$RESULT.tmp.$$" && mv -f "$RESULT.tmp.$$" "$RESULT") || true
}

# Tell every live direct report of this home that the lead is about to restart.
# A task whose pane reads confidently dead has no one to tell; every other
# recorded task, remote ones included, gets one fire-and-forget notice with its
# own fresh delivery id. Sets CREW_UNREACHED to the ids that could not be told.
notify_crew() {  # <what-the-lead-is-doing>
  local meta id did text
  text="The lead first mate is $1. Your own work, seat, and steering inbox are unaffected: carry on, and do not reply to this notice."
  CREW_UNREACHED=''
  for meta in "$STATE"/*.meta; do
    [ -e "$meta" ] || continue
    id=${meta##*/}
    id=${id%.meta}
    [ "$(fm_backend_agent_alive "$(fm_backend_of_meta "$meta")" "$(fm_backend_target_of_meta "$meta")")" != dead ] ||
      continue
    did=$(mint_hex 16)
    fm_run_timed "$NOTICE_WAIT" "$SCRIPT_DIR/fm-send.sh" "$id" --fire-and-forget "$did" "$text" >/dev/null 2>&1 ||
      CREW_UNREACHED="${CREW_UNREACHED:+$CREW_UNREACHED }$id"
  done
}

# True once the lock names a live session other than the one replaced and the
# runtime record bound to it puts that session on the destination profile. That
# is the successor holding this home, which a reservation that merely reached
# its deadline cannot fake.
SUCCESSOR_PID=''
successor_holds_lock() {  # <old-pid> <to-profile>
  local profile harness
  SUCCESSOR_PID=''
  fm_session_lock_inspect "$STATE"
  [ "$FM_LOCK_INSPECT_STATE" = held ] && [ "$FM_LOCK_INSPECT_PID" != "$1" ] || return 1
  profile=$(fm_session_lock_runtime_field "$STATE" profile) || return 1
  [ "$profile" = "$2" ] || return 1
  harness=$(fm_session_lock_runtime_field "$STATE" harness) || harness=claude
  [ "$harness" = "${3:-claude}" ] || return 1
  SUCCESSOR_PID=$FM_LOCK_INSPECT_PID
}

# Read the SAME field back on the successor, so the outcome reports what Remote
# Control actually did rather than that a flag was passed. The connection is made
# after the session is up, so a bounded wait is given; a state that never arrives
# is reported once and never chased with a retry loop.
verify_rc_followed() {  # <successor-pid> <to-profile> <session-id> <wait>
  local waited=0
  while [ "$waited" -lt "$4" ]; do
    [ "$(rc_state_of "$1" "$2" "$3")" != on ] || return 0
    sleep 2
    waited=$((waited + 2))
  done
  [ "$(rc_state_of "$1" "$2" "$3")" = on ]
}

handover_stage() {  # <plan-file>
  PLAN_FILE=$1
  [ -f "$PLAN_FILE" ] || exit 1
  local nonce pid backend target to_seat to_profile grace exit_wait start_wait claim_wait waited notice outcome
  local session follow_rc rc_wait rc_wake='' provider mode label
  provider=$(plan_field provider); provider=${provider:-claude}
  mode=$(plan_field session_mode); mode=${mode:-resume}
  label=Claude; [ "$provider" != codex ] || label=Codex
  nonce=$(plan_field nonce)
  pid=$(plan_field pid)
  backend=$(plan_field backend)
  target=$(plan_field target)
  to_seat=$(plan_field to_seat)
  to_profile=$(plan_field to_profile)
  grace=$(plan_field grace)
  exit_wait=$(plan_field exit_wait)
  start_wait=$(plan_field start_wait)
  claim_wait=$(plan_field claim_wait)
  P_COMMAND=$(plan_field command)
  P_LAUNCH_FILE=$(plan_field launch_file)
  P_SOURCE_LINE=". $(printf '%q' "$P_LAUNCH_FILE")"
  session=$(plan_field session)
  follow_rc=$(plan_field follow_rc)
  rc_wait=$(plan_field rc_wait)
  case "$rc_wait" in ''|*[!0-9]*) rc_wait=0 ;; esac
  case "$pid" in ''|*[!0-9]*) exit 1 ;; esac
  case "$grace$exit_wait$start_wait$claim_wait" in ''|*[!0-9]*) exit 1 ;; esac

  # Carried into every outcome below, including the ones that never reach a
  # successor: an undeterminable state is the one the captain has to know about,
  # because it is the case where Remote Control was deliberately not turned on.
  if [ "$follow_rc" = undeterminable ]; then
    RC_NOTE='whether Remote Control was on could not be determined for the previous session, so it was not turned on'
    rc_wake="whether Remote Control was on in the previous firstmate session could not be determined, so the replacement on $label seat $to_seat was started without it; if it should be on, turn it on there with /rc"
  fi

  if [ "$(plan_field from_profile)" = "$to_profile" ]; then
    notice="restarting in place on $label seat $to_seat"
    outcome="restarted in place on $label seat $to_seat"
  else
    notice="restarting onto another $label seat ($to_seat)"
    outcome="moved to $label seat $to_seat"
  fi
  notify_crew "$notice"
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
      "check: lead-restart: the move to $label seat $to_seat was abandoned because the current firstmate session would not end; it is still in charge" || true
    exit 1
  fi

  # From here the old process is gone. Everything durable survives it, so the
  # worst outcome below is a terminal that needs one command typed into it.
  # The lock anchor is not necessarily the process that owns the pane, so the
  # pane itself must read back as a bare shell before anything is typed there:
  # a front-end that outlived its anchor would take the line as a prompt.
  waited=0
  while [ "$(fm_backend_agent_alive "$backend" "$target")" != dead ] && [ "$waited" -lt 10 ]; do
    sleep 1
    waited=$((waited + 1))
  done
  if [ "$(fm_backend_agent_alive "$backend" "$target")" != dead ]; then
    clear_reservation "$nonce"
    record_result stranded "the previous firstmate process ended but its terminal did not return to a shell, so nothing was typed into it; if no firstmate is running there, run '$P_SOURCE_LINE' in it"
    fm_wake_append check lead-restart \
      "check: lead-restart: the previous firstmate process ended but its terminal did not return to a shell, so the replacement was not started; the exact command to run there is in $RESULT" || true
    exit 1
  fi
  # The literal send and the Enter are separated the same way bin/fm-spawn.sh
  # separates them, so the terminal has settled before the line is submitted.
  if ! fm_backend_send_literal "$backend" "$target" "$P_SOURCE_LINE" ||
    ! sleep 0.3 ||
    ! fm_backend_send_key "$backend" "$target" Enter; then
    clear_reservation "$nonce"
    record_result stranded "the previous firstmate session ended but the replacement command could not be delivered to its terminal; run '$P_SOURCE_LINE' there"
    fm_wake_append check lead-restart \
      "check: lead-restart: the previous firstmate session ended but its replacement could not be started in that terminal; the exact command to run there is in $RESULT" || true
    exit 1
  fi

  waited=0
  while [ "$waited" -lt "$start_wait" ]; do
    [ "$(fm_backend_agent_alive "$backend" "$target")" != alive ] || break
    sleep 2
    waited=$((waited + 2))
  done
  if [ "$(fm_backend_agent_alive "$backend" "$target")" != alive ]; then
    clear_reservation "$nonce"
    record_result stranded "the replacement was sent to the terminal but no agent came up there within ${start_wait}s; run '$P_SOURCE_LINE' there"
    fm_wake_append check lead-restart \
      "check: lead-restart: the replacement firstmate did not come up in its terminal; the exact command to run there is in $RESULT" || true
    exit 1
  fi

  # The handover is complete only when the lock record itself names the
  # successor; a reservation that is merely gone may just have lapsed.
  waited=0
  while [ "$waited" -lt "$claim_wait" ]; do
    successor_holds_lock "$pid" "$to_profile" "$provider" && break
    sleep 5
    waited=$((waited + 5))
  done
  if ! successor_holds_lock "$pid" "$to_profile" "$provider"; then
    # The replacement is up but never took the home, which is the outcome this
    # stage exists to catch: the process coming up is not the handover, the
    # lock record naming it is. It is recorded as a failure rather than as a
    # swap still in progress, because nothing else will come back to finish it.
    # The reservation is deliberately left to lapse rather than dropped: the
    # replacement still holds the nonce and may yet claim the home with it.
    # No successor to read the field back on, so the follow is reported as
    # requested rather than as achieved.
    [ "$follow_rc" != on ] ||
      RC_NOTE='the replacement was launched with Remote Control, which could not be confirmed because it never took this home'
    record_result failed "the replacement is running on seat $to_seat but never took this home's lock within ${claim_wait}s, so this home has no firstmate holding it; steer that terminal to run bin/fm-session-start.sh, or end what is there and run '$P_SOURCE_LINE' in it"
    fm_wake_append check lead-restart \
      "check: lead-restart: the replacement firstmate came up on $label seat $to_seat but never took this home's lock within ${claim_wait}s, so nothing is holding this home; the outcome and the exact recovery command are in $RESULT" || true
    [ -z "$rc_wake" ] || fm_wake_append check lead-restart "check: lead-restart: $rc_wake" || true
    exit 1
  fi
  rm -f "$P_LAUNCH_FILE" 2>/dev/null || true
  if [ "$follow_rc" = on ] || [ "$follow_rc" = requested ]; then
    if verify_rc_followed "$SUCCESSOR_PID" "$to_profile" "$session" "$rc_wait"; then
      if [ "$follow_rc" = on ]; then
        RC_NOTE='Remote Control was on before and is on again'
      else
        RC_NOTE='Remote Control is connected in the fresh Claude successor'
      fi
    else
      RC_NOTE="Remote Control was requested but could not be confirmed on in the replacement within ${rc_wait}s; turn it on there with /rc"
      [ "$follow_rc" != on ] || RC_NOTE="Remote Control was on before the restart but could not be confirmed on in the replacement within ${rc_wait}s; turn it back on there with /rc"
      rc_wake="Remote Control was requested for the fresh replacement on $label seat $to_seat but could not be confirmed within ${rc_wait}s; turn it on there with /rc"
      [ "$follow_rc" != on ] || rc_wake="Remote Control was on in the previous firstmate session but could not be confirmed on in the replacement on $label seat $to_seat within ${rc_wait}s; turn it back on there with /rc"
    fi
  fi
  [ "$follow_rc" != unavailable ] || RC_NOTE='Remote Control is unavailable for this embedded Codex session'
  if [ "$mode" = resume ]; then
    record_result 'done' "the firstmate session $outcome in the same terminal, resuming the same session"
  else
    record_result 'done' "the firstmate session $outcome in the same terminal, starting fresh from durable records"
  fi
  [ -z "$rc_wake" ] || fm_wake_append check lead-restart "check: lead-restart: $rc_wake" || true
  exit 0
}

# --- argument handling -------------------------------------------------------

MODE=arm
LAUNCH_OVERRIDE=''
PERSISTED=0
REFRESH=0
PLAN_FILE=''
P_COMMAND=''
P_LAUNCH_FILE=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --provider) [ "$#" -ge 2 ] || usage; TO_PROVIDER=$2; shift 2 ;;
    --check) MODE=check; shift ;;
    --persisted) PERSISTED=1; shift ;;
    --refresh) REFRESH=1; shift ;;
    --to) [ "$#" -ge 2 ] || usage; TO_SEAT=$2; shift 2 ;;
    --launch-command) [ "$#" -ge 2 ] || usage; LAUNCH_OVERRIDE=$2; shift 2 ;;
    --grace) [ "$#" -ge 2 ] || usage; GRACE=$2; shift 2 ;;
    --handover-stage) [ "$#" -ge 2 ] || usage; MODE=stage; PLAN_FILE=$2; shift 2 ;;
    -h | --help) usage ;;
    *) usage ;;
  esac
done

case "$TO_PROVIDER" in claude|codex) ;; *) die "unsupported leader provider: $TO_PROVIDER" ;; esac

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
