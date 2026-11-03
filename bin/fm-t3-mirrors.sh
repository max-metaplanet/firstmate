#!/usr/bin/env bash
# fm-t3-mirrors.sh - optional T3 conversation mirrors with inbox steering.
#
# Usage: fm-t3-mirrors.sh kick|sync
#        fm-t3-mirrors.sh retire TASK_ID
# kick starts a detached, bounded best-effort pass; sync runs it in the caller.
# Errors log fixed classes and task ids, never raw output or credentials.
# Enable with config/t3-mirrors containing exactly 1. Off creates no state.
# retire also works while off, after task metadata is gone. It revokes steering,
# removes a ready project's thread only after the single-thread identity proof.
# Setup-only projects use non-forced removal, which refuses a nonempty project.
# Failed proofs/removals keep the mapping for inspection/retry.
# Neither the task endpoint nor its lifecycle changes.
#
# Set FM_T3_BIN and FM_T3_BASE_DIR as for fm-t3.sh. First sync binds the absolute
# CLI/base/home/provider in STATE/t3-mirrors/connection.json; later overrides
# are ignored. Register fm-t3-mirror-relay.py as a local ACP provider with model
# mirror, default id acpRegistry_firstmate_mirror; config/t3-mirror-provider may
# select another acpRegistry_ id before the first sync. Setup edits no providers.
#
# Each mapping in STATE/t3-mirrors/tasks/TASK.json is version 2 and records its
# home/state/config, task incarnation, nonce, workspace, thread/project/title,
# provider/model, connection, and send journal. Workspace/project paths are
# STATE/t3-mirrors/workspaces/TASK/NONCE. ACP cwd locates that same mapping on
# new/load without another registry. No identity is accepted from prompt text.
# One shared verifier checks publication and inbound steering. Local tasks bind
# spawn_gen; markerless remote secondmates bind remote_host as fm-send does.
# The relay calls only fm-send.sh for ordinary typed instructions, with its
# final locked generation/remote-host guard; command/key prefixes are refused.
# Backend-neutral fm-peek captures are bounded and redacted before publication.
#
# The setup phase saves the nonce/workspace before project add; failed or timed-out
# setup retries the same workspace automatically. The creating phase is saved
# before thread start; an uncertain thread creation is held rather than retried.
# Returned thread/project ids are saved even if task retirement raced creation,
# preserving cleanup identity without allowing steering to a retired task.
# Matching prompt/reply receipts confirm sends. Unconfirmed sends are held for
# inspection, never replayed. Legacy version-1 shared-project
# mappings are preserved for manual reconciliation, never deleted automatically.
# Maps/journals remain private to the selected home; no fleet locks are taken.
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
