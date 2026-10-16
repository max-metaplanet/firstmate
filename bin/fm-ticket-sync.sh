#!/usr/bin/env bash
# fm-ticket-sync.sh - fire this home's optional ticket-sync hook for one task
# milestone, without ever making the caller wait on it or fail with it.
#
# docs/configuration.md owns the public contract (the config entry, the hook's
# own command line, and the events). This header owns only the writer
# mechanics.
#
# Off by default. Every producer guards its call with one file test on the
# home's config/ticket-sync-hook entry, so while that entry is absent this
# script is never run and the milestone costs one file test. It repeats that
# test so a direct invocation does nothing either.
#
# Producers, one call per transition rather than per poll:
#   bin/fm-spawn.sh         start (fresh ticketed spawns only, never relaunch)
#   bin/fm-pr-check.sh      review <pr-url> (a newly recorded pr=, not the
#                           merge-time re-record from bin/fm-pr-merge.sh and
#                           not a re-arm of the same URL)
#   bin/fm-pr-merge.sh      done <pr-url> (only after the forge proved MERGED)
#   bin/fm-captain-hold.sh  waiting <reason> (a fresh captain hold, not a
#                           repeat of one already active)
#
# Usage:
#   fm-ticket-sync.sh <task-id> start
#   fm-ticket-sync.sh <task-id> review <pr-url>
#   fm-ticket-sync.sh <task-id> done <pr-url>
#   fm-ticket-sync.sh <task-id> waiting <text>
#
# The ticket comes from the task's recorded ticket= metadata and from nowhere
# else: prose is never parsed for one. A task with no record, no ticket, or the
# explicit no-ticket marker fires nothing, so an unticketed fleet never reaches
# a hook. bin/fm-dod-lib.sh's fm_ticket_valid owns that grammar.
#
# The hook runs in a detached, bounded child: this script returns as soon as
# that child is started, so a slow or wedged hook delays no spawn, no PR
# registration, no merge, and no captain hold. The child holds none of the
# caller's standard streams, so a producer whose own output is captured cannot
# be kept waiting by a hook that outlives it either.
# bin/fm-timeout-lib.sh owns the bound, which is why nothing here re-derives
# the coreutils/BSD/perl selection macOS makes necessary.
#
# A hook that fails, cannot be run, or hits its bound is reported as one status
# line on the task naming the event and the exit code, and never as a failure
# of the producer:
#   actionable: ticket sync hook failed ticket=<id> event=<event> exit=<code>
# Exit code 124 is the bound (bin/fm-timeout-lib.sh's convention) and carries
# the bound it hit; 126 is a configured hook that could not be run at all. The
# line is appended plainly, so it surfaces to supervision like any other
# unread status, and it deliberately carries no part of a `waiting` text: the
# event name is what firstmate needs to re-run the milestone by hand.
#
# Environment: FM_HOME, FM_STATE_OVERRIDE, and FM_CONFIG_OVERRIDE resolve the
# home exactly as the other bin/ scripts do. FM_TICKET_SYNC_TIMEOUT overrides
# the seconds the hook is given (default 60).
#
# Exit status: 0 whenever the milestone was handled or deliberately skipped,
# including every hook failure, and 2 on a usage error. Producers ignore the
# status so it can never change theirs.
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
HOOK_CONFIG="$CONFIG/ticket-sync-hook"

usage() {
  echo "usage: fm-ticket-sync.sh <task-id> start | <task-id> review <pr-url> | <task-id> done <pr-url> | <task-id> waiting <text>" >&2
  exit 2
}

# Repeat the producers' own gate: a direct invocation on a home that configured
# no hook must do exactly as much as a guarded one, which is nothing.
[ -e "$HOOK_CONFIG" ] || exit 0

[ "$#" -ge 2 ] || usage
ID=$1
EVENT=$2
shift 2
case "$EVENT" in
  start) [ "$#" -eq 0 ] || usage ;;
  review|done) [ "$#" -eq 1 ] && [ -n "$1" ] || usage ;;
  waiting) [ "$#" -eq 1 ] && [ -n "$1" ] || usage ;;
  *) usage ;;
esac
case "$ID" in
  ''|*[!a-zA-Z0-9_-]*) usage ;;
esac

# fm_ticket_valid and FM_TICKET_NONE (the ticket grammar), status_stamp_line
# (the status append), and fm_run_timed (the bound) all arrive with this one
# source; none of them is re-derived here.
# shellcheck source=bin/fm-dod-lib.sh
. "$SCRIPT_DIR/fm-dod-lib.sh"

STATUS="$STATE/$ID.status"
BOUND=${FM_TICKET_SYNC_TIMEOUT:-60}
case "$BOUND" in
  ''|*[!0-9]*|0) BOUND=60 ;;
esac

# One status line, appended plainly so supervision reads it as unread status.
# A status file that cannot be written is not worth failing over here: the
# producer already succeeded and this script reports nothing else.
report_failure() {  # <exit-code>
  local line="actionable: ticket sync hook failed ticket=$TICKET event=$EVENT exit=$1"
  [ "$1" != 124 ] || line="$line bound=${BOUND}s"
  printf '%s\n' "$(status_stamp_line "$line")" >> "$STATUS" 2>/dev/null || true
}

# The task's own record is the only source for the ticket. An absent record is
# the ordinary case for a backlog row that was never dispatched, so it is as
# silent as an unticketed task.
META="$STATE/$ID.meta"
[ -f "$META" ] && [ ! -L "$META" ] || exit 0
TICKET=$(grep '^ticket=' "$META" | tail -1 | cut -d= -f2- || true)
[ -n "$TICKET" ] || exit 0
[ "$TICKET" != "$FM_TICKET_NONE" ] || exit 0
fm_ticket_valid "$TICKET" fm-ticket-sync.sh 2>/dev/null || exit 0

# The configured hook: one directive line, with blank and "#" comment lines
# ignored, naming an absolute path to an executable. Anything else resolves to
# a hook that cannot be run, which is reported rather than guessed at - a home
# that configured a milestone sync and silently got none is the failure this
# whole script exists to prevent.
HOOK=
HOOK_LINES=0
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    ''|'#'*) continue ;;
  esac
  HOOK=$line
  HOOK_LINES=$((HOOK_LINES + 1))
done < "$HOOK_CONFIG"
if [ "$HOOK_LINES" -ne 1 ] || [ -z "$HOOK" ] || [ "${HOOK#/}" = "$HOOK" ] \
  || [ ! -f "$HOOK" ] || [ ! -x "$HOOK" ]; then
  printf 'error: %s does not name one absolute path to an executable hook\n' "$HOOK_CONFIG" >&2
  report_failure 126
  exit 0
fi

# Detached and bounded: the child owns the whole wait, and it holds none of
# this process's streams, so nothing downstream of a producer can block on it.
(
  rc=0
  fm_run_timed "$BOUND" "$HOOK" "$TICKET" "$EVENT" "$@" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 0 ] || report_failure "$rc"
) </dev/null >/dev/null 2>&1 &
disown 2>/dev/null || true
exit 0
