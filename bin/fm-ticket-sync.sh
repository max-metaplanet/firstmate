#!/usr/bin/env bash
# fm-ticket-sync.sh - compatibility adapter for the former ticket-sync hook.
#
# bin/fm-task-event.sh delivers here when config/ticket-sync-hook is the only
# configuration; it may also be named explicitly in config/task-event-hook.
# Usage: fm-ticket-sync.sh '<firstmate.task-event v1 JSON>'
# docs/configuration.md owns the event contract; bin/fm-task-event.sh bounds
# this adapter.
#
# Mapping: started/resumed -> <ticket> start, or review <pr-url> when a resumed
# event carries one; blocked/waiting -> <ticket> waiting <summary>; pr-opened
# -> <ticket> review <pr-url>; final pr-merged/cancelled -> done only for
# ticket_scope complete, otherwise review <pr-url>; a cancellation passes its
# PR URL only when state/task-event-prs.jsonl records that PR as merged.
# Other events and null tickets do nothing.
# No ticket syntax is imposed here: the event producer owns ticket selection.
#
# config/ticket-sync-hook contains one absolute executable path, ignoring blank
# and # comment lines. The adapter invokes it synchronously and propagates its
# exit code so the event emitter can log failures. Invalid input exits 2 and an
# invalid configured executable exits 126. An absent configuration is a no-op.
# FM_HOME, FM_CONFIG_OVERRIDE and FM_STATE_OVERRIDE select the home,
# configuration and state directories.
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
HOOK_CONFIG="$CONFIG/ticket-sync-hook"
[ -e "$HOOK_CONFIG" ] || exit 0

[ "$#" -eq 1 ] || { echo "usage: fm-ticket-sync.sh '<event JSON>'" >&2; exit 2; }
PAYLOAD=$1
printf '%s' "$PAYLOAD" | jq -e '
  .schema == "firstmate.task-event" and .version == 1 and
  (.event | type == "string") and
  (.ticket == null or (.ticket | type == "string")) and
  (.pr_url == null or (.pr_url | type == "string")) and
  (.summary | type == "string")
' >/dev/null 2>&1 || { echo 'error: invalid task event' >&2; exit 2; }
TICKET=$(printf '%s' "$PAYLOAD" | jq -r '.ticket // empty')
[ -n "$TICKET" ] || exit 0
EVENT=$(printf '%s' "$PAYLOAD" | jq -r '.event')
case "$EVENT" in
  started) set -- "$TICKET" start ;;
  resumed)
    PR=$(printf '%s' "$PAYLOAD" | jq -r '.pr_url // empty')
    if [ -n "$PR" ]; then set -- "$TICKET" review "$PR"; else set -- "$TICKET" start; fi
    ;;
  blocked|waiting)
    SUMMARY=$(printf '%s' "$PAYLOAD" | jq -r '.summary')
    set -- "$TICKET" waiting "$SUMMARY"
    ;;
  pr-opened)
    PR=$(printf '%s' "$PAYLOAD" | jq -r '.pr_url // empty')
    [ -n "$PR" ] || exit 2
    set -- "$TICKET" review "$PR"
    ;;
  pr-merged)
    [ "$(printf '%s' "$PAYLOAD" | jq -r '.merge')" = final ] || exit 0
    PR=$(printf '%s' "$PAYLOAD" | jq -r '.pr_url // empty')
    [ -n "$PR" ] || exit 2
    ACTION=review
    [ "$(printf '%s' "$PAYLOAD" | jq -r '.ticket_scope // "partial"')" != complete ] || ACTION="done"
    set -- "$TICKET" "$ACTION" "$PR"
    ;;
  cancelled)
    [ "$(printf '%s' "$PAYLOAD" | jq -r '.merge')" = final ] || exit 0
    if [ "$(printf '%s' "$PAYLOAD" | jq -r '.ticket_scope // "partial"')" = complete ]; then
      set -- "$TICKET" "done"
    else
      PR=$(printf '%s' "$PAYLOAD" | jq -r '.pr_url // empty')
      set -- "$TICKET" review
      if [ -n "$PR" ] && jq -ne --arg pr "$PR" 'any(inputs; .event == "pr-merged" and .pr_url == $pr)' \
        "$STATE/task-event-prs.jsonl" >/dev/null 2>&1; then
        set -- "$@" "$PR"
      fi
    fi
    ;;
  *) exit 0 ;;
esac

HOOK=
HOOK_LINES=0
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in ''|'#'*) continue ;; esac
  HOOK=$line
  HOOK_LINES=$((HOOK_LINES + 1))
done < "$HOOK_CONFIG"
if [ "$HOOK_LINES" -ne 1 ] || [ -z "$HOOK" ] || [ "${HOOK#/}" = "$HOOK" ] \
  || [ ! -f "$HOOK" ] || [ ! -x "$HOOK" ]; then
  printf 'error: %s does not name one absolute path to an executable hook\n' "$HOOK_CONFIG" >&2
  exit 126
fi
exec "$HOOK" "$@"
