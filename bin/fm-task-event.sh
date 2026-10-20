#!/usr/bin/env bash
# fm-task-event.sh - publish an optional, tracker-neutral lifecycle event.
# Usage: fm-task-event.sh <task-id> <event> [--summary <text>] [--key <key>]
#        [--ticket <opaque-ticket>] [--pr <url>] [--ticket-scope <complete|partial>]
# --ticket-scope supplies the teardown snapshot after metadata retirement.
# docs/configuration.md owns the hook and versioned JSON contract.
# Snapshot local metadata and publish an ordered spool entry before returning.
# A detached --drain process serializes hook calls using the shared lock helpers.
# Only local publication takes a foreground lock, bounded to one second.
# Each consumer attempt is bounded by fm_run_timed; failure advances the queue.
# A crash before removal may replay an event on the next emission. No idle
# retry daemon runs, and consumers should tolerate duplicate delivery.
# Empty-queue handoff holds the enqueue lock while releasing the delivery lock,
# so an enqueue racing drainer exit cannot lose its wake.
# The hook receives one JSON argument, never a shell-evaluated command string.
# A home with only config/ticket-sync-hook delivers through bin/fm-ticket-sync.sh
# and logs that compatibility path once.
# Failures append to state/task-events.log and never fail a lifecycle producer;
# a consumer failure also appends one actionable line to a live task's status,
# at most once per task per hour.
# FM_TASK_EVENT_TIMEOUT sets the hook bound in seconds (default 60).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME=${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}
STATE=${FM_STATE_OVERRIDE:-$FM_HOME/state}
CONFIG=${FM_CONFIG_OVERRIDE:-$FM_HOME/config}
export FM_HOME FM_STATE_OVERRIDE="$STATE" FM_CONFIG_OVERRIDE="$CONFIG"
events_enabled() { [ -e "$CONFIG/task-event-hook" ] || [ -e "$CONFIG/ticket-sync-hook" ]; }
if [ "${1:-}" != --drain ] && ! events_enabled; then exit 0; fi

QUEUE="$STATE/task-events"
ENQUEUE_LOCK="$STATE/.task-event-enqueue.lock"
DELIVERY_LOCK="$STATE/.task-event-delivery.lock"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

report_failure() {
  printf '%s task_id=%s event=%s exit=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$ID" "$EVENT" "$1" >> "$STATE/task-events.log" 2>/dev/null || true
}

surface_failure() {  # <exit-code>
  local status="$STATE/$ID.status" marker="$STATE/.$ID.task-event-failure" now last=0
  [ -f "$status" ] && [ ! -L "$status" ] || return 0
  now=$(date +%s) || return 0
  [ ! -f "$marker" ] || IFS= read -r last < "$marker" || true
  case "$last" in ''|*[!0-9]*) last=0 ;; esac
  [ $((now - last)) -ge 3600 ] || return 0
  printf '%s\n' "$now" > "$marker" 2>/dev/null || return 0
  # shellcheck source=bin/fm-classify-lib.sh
  . "$SCRIPT_DIR/fm-classify-lib.sh"
  printf '%s\n' "$(status_stamp_line "actionable: task event hook failed event=$EVENT exit=$1; see state/task-events.log")" \
    >> "$status" 2>/dev/null || true
}

fail_delivery() {  # <exit-code>
  report_failure "$1"
  surface_failure "$1"
}

deliver() {
  local hook='' count=0 line bound=${FM_TASK_EVENT_TIMEOUT:-60} rc=0
  case "$bound" in ''|*[!0-9]*|0) bound=60 ;; esac
  if [ -e "$CONFIG/task-event-hook" ]; then
    [ -f "$CONFIG/task-event-hook" ] || { fail_delivery 126; return; }
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in ''|'#'*) continue ;; esac
      hook=$line; count=$((count + 1))
    done < "$CONFIG/task-event-hook"
    if [ "$count" -ne 1 ] || [ "${hook#/}" = "$hook" ] || [ ! -f "$hook" ] || [ ! -x "$hook" ]; then
      fail_delivery 126
      return
    fi
  elif [ -e "$CONFIG/ticket-sync-hook" ]; then
    hook="$SCRIPT_DIR/fm-ticket-sync.sh"
    if [ ! -e "$STATE/.task-event-compat-noted" ] && : > "$STATE/.task-event-compat-noted" 2>/dev/null; then
      printf '%s compatibility: config/ticket-sync-hook alone delivers task events through bin/fm-ticket-sync.sh; name a consumer in config/task-event-hook to migrate\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$STATE/task-events.log" 2>/dev/null || true
    fi
  else
    return 0
  fi
  # shellcheck source=bin/fm-timeout-lib.sh
  . "$SCRIPT_DIR/fm-timeout-lib.sh"
  fm_run_timed "$bound" "$hook" "$PAYLOAD" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 0 ] || fail_delivery "$rc"
}

first_queued() {
  NEXT=''
  local entry
  for entry in "$QUEUE"/[0-9]*.json; do
    [ -f "$entry" ] || continue
    NEXT=$entry
    break
  done
}

drain() {
  ID=queue EVENT=delivery
  if ! fm_lock_acquire_wait_bounded "$DELIVERY_LOCK" 1; then
    # An active drainer owns every published entry, including the final recheck.
    fm_pid_alive "${FM_LOCK_HELD_PID:-}" || report_failure 125
    return 0
  fi
  trap 'fm_lock_release "$ENQUEUE_LOCK"; fm_lock_release "$DELIVERY_LOCK"' EXIT
  trap 'exit 143' TERM INT HUP
  while :; do
    first_queued
    if [ -z "$NEXT" ]; then
      fm_lock_acquire_wait_bounded "$ENQUEUE_LOCK" 1 || { report_failure 125; return; }
      first_queued
      if [ -z "$NEXT" ]; then
        fm_lock_release "$DELIVERY_LOCK"
        fm_lock_release "$ENQUEUE_LOCK"
        return 0
      fi
      fm_lock_release "$ENQUEUE_LOCK"
    fi
    PAYLOAD=$(cat "$NEXT") || { report_failure 125; return; }
    ID=$(printf '%s' "$PAYLOAD" | jq -r '.task_id')
    EVENT=$(printf '%s' "$PAYLOAD" | jq -r '.event')
    deliver
    rm -f "$NEXT" || { report_failure 125; return; }
  done
}

if [ "${1:-}" = --drain ]; then
  drain
  exit 0
fi
events_enabled || exit 0

usage() {
  echo 'usage: fm-task-event.sh <task-id> <event> [--summary text] [--key key] [--ticket ticket] [--pr url] [--ticket-scope complete|partial]' >&2
  exit 2
}
[ "$#" -ge 2 ] || usage
ID=$1 EVENT=$2
shift 2
case "$ID" in ''|*[!a-zA-Z0-9_-]*) usage ;; esac
case "$EVENT" in
  started|blocked|waiting|resumed|decision-answered|pr-opened|pr-merged|finished|cancelled) ;;
  *) usage ;;
esac

TICKET='' PR='' SUMMARY='' KEY='' SUMMARY_SET=0 TICKET_SCOPE=partial
if [ -f "$STATE/$ID.meta" ] && [ ! -L "$STATE/$ID.meta" ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      ticket=*) TICKET=${line#ticket=} ;;
      pr=*) PR=${line#pr=} ;;
      ticket_scope=*) TICKET_SCOPE=${line#ticket_scope=} ;;
    esac
  done < "$STATE/$ID.meta"
fi
while [ "$#" -gt 0 ]; do
  [ "$#" -ge 2 ] || usage
  case "$1" in
    --summary) SUMMARY=$2; SUMMARY_SET=1 ;;
    --key) KEY=$2 ;;
    --ticket) TICKET=$2 ;;
    --ticket-scope) TICKET_SCOPE=$2 ;;
    --pr) PR=$2 ;;
    *) usage ;;
  esac
  shift 2
done
case "$EVENT" in pr-opened|pr-merged) [ -n "$PR" ] || usage ;; esac
case "$TICKET" in no-ticket|none) TICKET= ;; esac
[ "$TICKET_SCOPE" = complete ] && [ -n "$TICKET" ] || TICKET_SCOPE=partial
if [ "$SUMMARY_SET" -eq 0 ]; then
  # Reuse the status parser, including stamped and note-head keyed records.
  # shellcheck source=bin/fm-classify-lib.sh
  . "$SCRIPT_DIR/fm-classify-lib.sh"
  SUMMARY=$(status_line_note "$(last_worker_status_line "$STATE/$ID.status")")
fi

fm_lock_acquire_wait_bounded "$ENQUEUE_LOCK" 1 || { report_failure 125; exit 0; }
trap 'fm_lock_release "$ENQUEUE_LOCK"' EXIT
trap 'exit 143' TERM INT HUP
mkdir -p "$QUEUE" || { report_failure 125; exit 0; }
SEQUENCE=0
if [ -f "$QUEUE/.sequence" ]; then
  IFS= read -r SEQUENCE < "$QUEUE/.sequence" || { report_failure 125; exit 0; }
fi
case "$SEQUENCE" in ''|*[!0-9]*) report_failure 125; exit 0 ;; esac
SEQUENCE=$((SEQUENCE + 1))
if ! printf '%s\n' "$SEQUENCE" > "$QUEUE/.sequence.next" \
  || ! mv "$QUEUE/.sequence.next" "$QUEUE/.sequence"; then
  report_failure 125; exit 0
fi
PAYLOAD=$(jq -cn --arg event "$EVENT" --arg id "$ID" --arg ticket "$TICKET" \
  --arg ticket_scope "$TICKET_SCOPE" \
  --arg pr "$PR" --arg summary "$SUMMARY" --arg key "$KEY" --arg home "$FM_HOME" \
  --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson sequence "$SEQUENCE" \
  '{schema:"firstmate.task-event",version:1,event:$event,task_id:$id,
    ticket:($ticket|if length==0 then null else . end),ticket_scope:$ticket_scope,
    pr_url:($pr|if length==0 then null else . end),merge:null,timestamp:$at,
    summary:($summary|gsub("[\\r\\n\\t]+";" ")|.[0:500]),
    key:($key|if length==0 then null else . end),home:$home,sequence:$sequence}' 2>/dev/null) \
  || { report_failure 125; exit 0; }

# One append per confirmed PR fact, independent of consumer delivery. Preserve
# these across task teardown so another task for the same ticket sees all PRs.
# A task tracks one PR: its next pr-opened supersedes and cancelled retires its
# unmerged PR, so final means every live PR for the ticket has merged. A
# cancelled task whose own PR never merged delivered nothing, so it publishes
# partial scope whatever it declared.
case "$EVENT" in
  pr-opened|pr-merged|cancelled)
    printf '%s\n' "$PAYLOAD" >> "$STATE/task-event-prs.jsonl" 2>/dev/null \
      || { report_failure 125; exit 0; }
    ;;
esac

if [ "$EVENT" = pr-merged ] || [ "$EVENT" = cancelled ]; then
  PAYLOAD=$(jq -cs --argjson event "$PAYLOAD" '
    any(.[]; .event == "pr-merged" and .pr_url == $event.pr_url) as $own_merged |
    [ .[] | select(if $event.ticket == null then .task_id == $event.task_id
      else .ticket == $event.ticket end) ] |
    reduce .[] as $fact ({};
      if $fact.event == "pr-merged" then .[$fact.pr_url] = {task: $fact.task_id, merged: true}
      else with_entries(select(.value.merged or .value.task != $fact.task_id)) |
        if $fact.event == "pr-opened" then
          .[$fact.pr_url] = {task: $fact.task_id, merged: (.[$fact.pr_url].merged // false)}
        else . end
      end) |
    $event + {merge: (if length == 0 then null elif all(.[]; .merged) then "final" else "partial" end)}
      + (if $event.event == "cancelled" and ($own_merged | not) then {ticket_scope: "partial"} else {} end)
  ' "$STATE/task-event-prs.jsonl" 2>/dev/null) || { report_failure 125; exit 0; }
fi

printf -v ENTRY '%020d' "$SEQUENCE"
if ! printf '%s\n' "$PAYLOAD" > "$QUEUE/$ENTRY.pending" \
  || ! mv "$QUEUE/$ENTRY.pending" "$QUEUE/$ENTRY.json"; then
  report_failure 125; exit 0
fi
# Start before releasing enqueue ownership. The drainer's final check uses the
# same lock, so it cannot exit between publication and this wake being issued.
"$SCRIPT_DIR/fm-task-event.sh" --drain </dev/null >/dev/null 2>&1 &
disown 2>/dev/null || true
fm_lock_release "$ENQUEUE_LOCK"
exit 0
