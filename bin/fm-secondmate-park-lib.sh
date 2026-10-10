#!/usr/bin/env bash
# Read-only secondmate park predicates. The parent record is authoritative;
# bin/fm-secondmate-park.sh owns its format and lifecycle.
FM_SM_PARK_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-secondmate-parent-lib.sh
. "$FM_SM_PARK_LIB_DIR/fm-secondmate-parent-lib.sh"

fm_secondmate_park_present() { # <parent-state> <id>
  [ -e "$1/.secondmate-park-$2" ] || [ -L "$1/.secondmate-park-$2" ]
}

fm_secondmate_home_parked() { # <home>
  local home=$1 id record phase
  [ -f "$home/.fm-secondmate-home" ] || return 1
  id=$(cat "$home/.fm-secondmate-home")
  case "$id" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
  fm_secondmate_parent_record_parse "$home/.fm-secondmate-parent" || return 1
  [ "$FM_SECONDMATE_PARENT_ROUTE" = local ] || return 1
  record="$FM_SECONDMATE_PARENT_HOME/state/.secondmate-park-$id"
  fm_secondmate_park_present "$FM_SECONDMATE_PARENT_HOME/state" "$id" || return 1
  phase=$(sed -n 's/^phase=//p' "$record" 2>/dev/null)
  # Preparing leaves the agent and its supervision alive to answer persistence;
  # waking lets the replacement arm its own supervision on startup.
  case "$phase" in preparing|waking) return 1 ;; esac
  return 0
}
