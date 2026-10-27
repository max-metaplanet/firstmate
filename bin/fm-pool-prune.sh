#!/usr/bin/env bash
# Cap one project's idle Treehouse pool, with a dry run by default.
# Usage: FM_HOME=<home> fm-pool-prune.sh <project-directory> [--apply]
#
# config/treehouse-idle-cap in the local root home sets the per-project cap;
# docs/configuration.md owns its schema. No file means two idle copies.
# Teardown calls the same implementation after releasing its slot and retiring
# its task record, while still holding the shared project lock.
#
# Only unclaimed, unleased, idle, clean Git slots with HEAD and the checked-out
# branch published on origin qualify. Any recorded task copy in a registered
# local home is protected, even when its endpoint is gone. Refusals are reported
# per copy; an unmet cap or any inspection/removal error exits nonzero. Active
# copies do not count against the idle cap. Unsafe idle copies do count, but are
# never removed. Unreadable configuration or inventory prevents all removals.
#
# Requires Treehouse >=3.1.3 for safe-by-default exact-target destroy, Python 3,
# and Git. Uses only `treehouse destroy <path> --yes`, never force, bulk destroy,
# return, orphan pruning, or risk opt-ins. Treehouse rechecks use/lease/landing
# under its own lock. The shared Firstmate project lock covers task claims.
# No local branch refs are deleted. Git verification reads origin's live heads
# without fetching; inability to prove publication preserves the copy.
#
# Output is JSON with per-copy decisions and per-project counts, allocated
# bytes selected by dry run, and allocated bytes removed by apply. Allocation
# is measured with du -sk, not an APFS physical-free-space guarantee.
set -eu
if [ "${1:-}" = --help ] || [ "${1:-}" = -h ]; then
  sed -n '2,/^set /{ /^#/s/^# \{0,1\}//p; }' "$0"
  exit 0
fi
[ "$#" = 1 ] || { [ "$#" = 2 ] && [ "$2" = --apply ]; } || {
  echo 'usage: fm-pool-prune.sh <project-directory> [--apply]' >&2; exit 2;
}
if [ "${2:-}" = --apply ] && [ -n "${FM_TASK_ID:-}" ]; then
  echo 'pool prune: task workers cannot administer the shared pool' >&2
  exit 1
fi
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
FM_HOME=${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}
FM_WAKE_READ_ONLY=1
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"
# shellcheck source=bin/fm-pool-prune-lib.sh
. "$SCRIPT_DIR/fm-pool-prune-lib.sh"
PROJECT=$(cd "$1" && pwd -P)
LOCK=$(fm_treehouse_project_lock_path "$PROJECT")
fm_lock_try_acquire "$LOCK" || { echo 'pool prune: shared project lock is busy' >&2; exit 1; }
trap 'fm_lock_release "$LOCK"' EXIT
fm_pool_prune_locked "$PROJECT" "${FM_CONFIG_OVERRIDE:-$FM_HOME/config}" "$STATE" "${@:2}"
