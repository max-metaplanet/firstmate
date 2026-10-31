#!/usr/bin/env bash
# fm-t3-mirrors.sh - optional, presentation-only T3 status threads.
#
# Usage: fm-t3-mirrors.sh kick|sync
#        fm-t3-mirrors.sh retire TASK_ID
# kick starts one detached, bounded sync without waiting for T3.
# sync runs a bounded best-effort pass; failures are logged and return success.
# retire TASK_ID drops only that task's local mapping after metadata retirement.
# Historical T3 conversations remain; the CLI has no individual-thread delete.
# No command reads panes, steers workers, takes fleet locks, or edits endpoints.
#
# Enable with config/t3-mirrors containing exactly 1. Off is a no-op, including
# no Python/T3 dependency or state creation. Retirement also works when off.
# Set FM_T3_BIN and FM_T3_BASE_DIR as for fm-t3.sh; first sync binds the absolute
# CLI and base in state/t3-mirrors/connection.json. Later env overrides are ignored.
# Register fm-t3-mirror-relay.py in T3 as local provider acpRegistry_firstmate_mirror
# with model mirror before enabling. Setup never edits T3 provider settings.
# If T3 assigned another local instance id, put it in config/t3-mirror-provider
# before the first sync; only acpRegistry_ ids are accepted and the id is bound.
# All homes share the neutral BASE/userdata/firstmate-mirrors workspace/project.
# Maps and creation/send journals belong only to HOME/state/t3-mirrors.
# Before sending, the saved thread/project/title/provider/model must still match.
# Delivery is confirmed by a matching prompt and formatted assistant reply from
# thread show. A pending known-thread send is read again on the next pass.
# An uncertain creation with no thread id, or a send with no matching receipt,
# is held for inspection, never blindly replayed. Inspect the saved task journal
# and exact nonce-bearing title in T3 before manual reconciliation.
# Logs contain fixed error classes and task ids, never CLI output or credentials.
set -u

usage() { sed -n '2,/^set -/p' "${BASH_SOURCE[0]}" | sed '$d; s/^# \{0,1\}//'; }
case "${1:-}" in -h|--help|help) usage; exit 0 ;; esac
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
home=${FM_HOME:-${FM_ROOT_OVERRIDE:-${FM_ROOT:-$(dirname "$SCRIPT_DIR")}}}
config=${FM_CONFIG_OVERRIDE:-$home/config}
state=${FM_STATE_OVERRIDE:-$home/state}
case "${1:-}" in
  retire)
    [ "$#" -eq 2 ] || { usage >&2; exit 2; }
    [ -d "$state/t3-mirrors" ] || exit 0
    ;;
  kick|sync)
    [ "$#" -eq 1 ] || { usage >&2; exit 2; }
    [ -f "$config/t3-mirrors" ] && [ "$(cat "$config/t3-mirrors")" = 1 ] || exit 0
    ;;
  *) usage >&2; exit 2 ;;
esac
command -v python3 >/dev/null 2>&1 || { echo 'T3 mirrors: Python 3 unavailable' >&2; exit 0; }
if [ "$1" = kick ]; then
  nohup python3 "$SCRIPT_DIR/fm-t3-mirrors.py" sync "$home" "$state" "$config" </dev/null >/dev/null 2>&1 &
else
  python3 "$SCRIPT_DIR/fm-t3-mirrors.py" "$1" "$home" "$state" "$config" "${2:-}" || true
fi
