#!/usr/bin/env bash
# Idle-pool enforcement shared by teardown and fm-pool-prune.sh.
# fm-pool-prune.sh's help owns the command and safety contract.
# Requires fm-wake-lib.sh and fm-secondmate-registry-lib.sh.

fm_pool_prune_locked() { # <project> <config-dir> <state-dir> [--apply]
  local project=$1 config=$2 state=$3 lock pid current root
  shift 3
  lock=$(fm_treehouse_project_lock_path "$project") || return 1
  fm_current_pid current || return 1
  pid=$(cat "$lock/pid" 2>/dev/null) || return 1
  [ "$pid" = "$current" ] || { echo 'pool prune: shared project lock is not held' >&2; return 1; }
  root=$(fm_firstmate_root_home "$FM_HOME") || return 1
  [ "$root" -ef "$FM_HOME" ] || config=$root/config
  fm_local_firstmate_state_dirs "$state" || {
    echo "pool prune: $FM_LOCAL_FIRSTMATE_ERROR" >&2
    return 1
  }
  python3 "$FM_WAKE_LIB_DIR/fm-pool-prune.py" --project "$project" \
    --config "$config/treehouse-idle-cap" "$@" --state-dirs "${FM_LOCAL_FIRSTMATE_STATES[@]}"
}
