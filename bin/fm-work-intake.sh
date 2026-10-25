#!/usr/bin/env bash
# Optional source intake over this home's tasks-axi queue.
# Usage: fm-work-intake.sh preview [--hook /absolute/executable] [--json]
#        fm-work-intake.sh poll [--json]
#        fm-work-intake.sh status [--json]
#        fm-work-intake.sh refresh <local-id> [--json]
#        fm-work-intake.sh review <local-id> --decision-file <path> [--json]
#        fm-work-intake.sh check <local-id> [--json]
#
# config/work-intake-hook contains one absolute executable path, never shell text.
# The trusted, GET-only source receives `--json` or `--json --refresh <opaque-ref>`.
# config/work-intake-enabled must contain exactly `1` to permit receipt/queue writes.
# Without it poll is a no-op; preview is available without activation and writes
# neither queue nor receipt. No command starts a worker or emits a lifecycle event.
# config/work-intake-include-backlog-and-unassigned=1 passes the queue flag of
# that name through the hook on scans and refreshes; the default is off.
# The hook must forward queue arguments. An older clickup-axi without the flag
# reports a warning and uses default eligibility instead.
# Python 3.11+ is required. The source envelope follows the v1 queue contract;
# ClickUp configuration and normalization belong to the private hook and adapter.
#
# Polls coalesce for 300 seconds, back off after failures, and bound each source
# invocation to 55 seconds. check always performs a fresh full-candidate read.
# After source, review, authority, dependency and hold clearance, check takes
# opt-in candidates through clickup-axi assign --add <configured_user_id> and
# status --to 'up next', in that order where needed. Each write is refreshed
# and verified before continuing; failure refuses dispatch. The existing launch
# owner still emits started only after a successful launch.
# Source failures prevent imported dispatch, never independent local work.
# Receipt state/work-intake.json owns stable identity, planned/imported/existing/
# conflict phases, owning home, source observations, cached semantic review and tombstones.
# One home-local advisory lock serializes receipt writers; atomic replacement
# publishes state. A planned receipt precedes add, so a crash after add recovers
# that exact ID rather than minting another. Receipts are never pruned with Done.
# Existing queued, live, archived and registered local secondmate rows are
# reconciled before add. Identity is an exact Source reference:, Ticket: or
# Ticket URL: body line, a live task's meta ticket, or the ticket key leading the
# title of a row without a Source reference: line. One match records an existing-phase dedupe tombstone; intake never
# holds, gates or refuses rows it did not create. Unavailable remote ownership
# blocks new imports. Multiple matches are a conflict, never an automatic split
# or handoff.
#
# review consumes a firstmate-authored JSON decision with authorized=true,
# project, kind (ship|scout), reason, source_revision, and identity_checked=true. Optional
# deferred/blocked/unresolved_scope flags keep work held. captain_order,
# incident, security_authorized, latest_start, confirmed_due, deadline_source, deadline_timezone,
# review_buffer_ms and dependency_benefit provide explicit ordering evidence.
# Scope review must read refresh output, including comments and parent.
# A pending take retains its reviewed evidence across retries only for the
# expected assignment or status change; changed scope still requires re-review.
# Remote scope is untrusted evidence and cannot authorize supervisor exceptions.
# Only this source's exact external hold may be released; competing holds stay.
# Local notes, dependencies, priority overrides and briefs are never replaced.
#
# check returns 0 for independent or pre-existing work and eligible, reviewed imported work;
# 1 for ineligible/unreviewed/unavailable imported work; 2 for invalid invocation.
# Live import activation is an operator action outside the preview workflow.
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
case "${1:-}" in
  -h|--help|'') sed -n '2,/^set -eu/{ /^set -eu/d; s/^# \{0,1\}//; p; }' "$0"; exit 0 ;;
esac
if [ "${1:-}" = check ] && [ ! -e "$STATE/work-intake.json" ]; then
  exit 0
fi
# shellcheck source=bin/fm-tasks-axi-lib.sh
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-backlog-transition-lib.sh
. "$SCRIPT_DIR/fm-backlog-transition-lib.sh"
if [ "${1:-}" != check ] && [ "${1:-}" != preview ] && [ "${1:-}" != status ] && [ "$(cat "$CONFIG/work-intake-enabled" 2>/dev/null || true)" = 1 ]; then
  if ! fm_backlog_transition_applies "$CONFIG" "$DATA" ship; then
    printf 'work-intake: requires transactional tasks-axi backlog: %s\n' "${FM_BACKLOG_TRANSITION_ERROR:-$FM_BACKLOG_TRANSITION_SKIP}" >&2
    exit 2
  fi
fi
export FM_HOME FM_CONFIG_OVERRIDE="$CONFIG" FM_DATA_OVERRIDE="$DATA" FM_STATE_OVERRIDE="$STATE"
exec python3 "$SCRIPT_DIR/fm-work-intake.py" "$@"
