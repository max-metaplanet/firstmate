#!/usr/bin/env bash
# fm-fleet-capacity-lib.sh - how many agents the whole local fleet runs at once
# on this machine, and whether a fresh spawn still fits.
#
# Every running agent costs this machine memory whatever project it works on,
# and too many at once can exhaust it outright. The captain declares one number
# for the whole machine, and bin/fm-spawn.sh defers a fresh ship, scout, or
# local secondmate beyond it exactly as project capacity does
# (bin/fm-project-capacity-lib.sh): nothing is launched, no record is created,
# the backlog item stays queued, and the spawn exits 75. Without a declaration
# nothing changes.
#
# This file is the single owner of the declaration format, of what holds a
# place, and of the admission lock. docs/configuration.md "Fleet capacity" is
# the operator reference, and bin/fm-spawn.sh owns where the check runs.
#
# Declaration: config/fleet-capacity in the local root Firstmate home, resolved
# like config/project-capacity (fm_project_capacity_config_dir). It holds one
# positive integer of at most six digits on its own line. Blank lines and lines
# starting with `#` are ignored. Any other shape, a second number, or an
# unreadable file makes the declaration unreadable, and bin/fm-spawn.sh then
# refuses every fresh spawn rather than guessing the captain's limit.
#
# Occupancy: a place is held by every task record of kind ship, scout, or
# secondmate in any local Firstmate home on this machine
# (fm_local_firstmate_state_dirs in bin/fm-wake-lib.sh) whose agent the backend
# does not report dead or missing (fm_backend_agent_state in bin/fm-backend.sh).
# A record whose agent state cannot be established holds a place, so an
# unreadable endpoint never lets the fleet grow past the cap. A recorded PR
# handoff does not free a place, because a waiting agent still uses memory.
# The supervising lead of the root home has no task record and is not counted.
# Remote homes are never walked, because their agents run on another machine.
#
# Race safety: bin/fm-spawn.sh takes the fleet lock (fm_fleet_capacity_lock_path)
# before counting and keeps it until the new task record is published, so two
# concurrent spawns anywhere on this machine can never both take the last place.
# The lock is taken only when a cap is declared. Freeing a place needs no lock.
#
# Requires bin/fm-project-capacity-lib.sh and its own prerequisites to be
# sourced first. No side effects on source.

# The one lock serializing fleet capacity admission across every local home,
# kept in the root home's state directory.
fm_fleet_capacity_lock_path() {  # <spawning-home>
  local root
  root=$(fm_firstmate_root_home "$1") || return 1
  printf '%s/state/.fleet-capacity.lock\n' "$root"
}

# Read the declared fleet capacity.
# Sets FM_FLEET_CAPACITY_FILE to the declaration path and FM_FLEET_CAPACITY to
# the cap, or to empty when none is declared. Returns 1 with
# FM_FLEET_CAPACITY_ERROR when the declaration is unreadable.
fm_fleet_capacity_lookup() {  # <config-dir>
  local line lineno=0
  FM_FLEET_CAPACITY_FILE="$1/fleet-capacity"
  FM_FLEET_CAPACITY=
  FM_FLEET_CAPACITY_ERROR=
  if [ ! -e "$FM_FLEET_CAPACITY_FILE" ] && [ ! -L "$FM_FLEET_CAPACITY_FILE" ]; then
    return 0
  fi
  if [ ! -f "$FM_FLEET_CAPACITY_FILE" ] || [ ! -r "$FM_FLEET_CAPACITY_FILE" ]; then
    FM_FLEET_CAPACITY_ERROR="$FM_FLEET_CAPACITY_FILE is not a readable regular file"
    return 1
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    line=${line%$'\r'}
    line=${line#"${line%%[![:space:]]*}"}
    line=${line%"${line##*[![:space:]]}"}
    case "$line" in
      '' | '#'*) continue ;;
      *[!0-9]* | 0*)
        FM_FLEET_CAPACITY_ERROR="$FM_FLEET_CAPACITY_FILE line $lineno is not a positive integer"
        FM_FLEET_CAPACITY=
        return 1
        ;;
    esac
    if [ "${#line}" -gt 6 ] || [ -n "$FM_FLEET_CAPACITY" ]; then
      FM_FLEET_CAPACITY_ERROR="$FM_FLEET_CAPACITY_FILE line $lineno is a second or over-long number"
      FM_FLEET_CAPACITY=
      return 1
    fi
    FM_FLEET_CAPACITY=$line
  done < "$FM_FLEET_CAPACITY_FILE"
  return 0
}

# Count the live agents holding a place in the fleet.
# <own-id> in <first-state> is the task being admitted and is not counted.
# Sets FM_FLEET_CAPACITY_OCCUPANTS and FM_FLEET_CAPACITY_OCCUPANT_IDS, each
# holder outside <first-state> qualified with its home, and the array
# FM_FLEET_CAPACITY_OCCUPANT_METAS with those exact holders' metadata paths.
# An empty <own-id> counts every record (read-only display callers).
# Returns 1 with
# FM_FLEET_CAPACITY_ERROR when the local homes or a task record cannot be read.
# shellcheck disable=SC2034 # the FM_FLEET_CAPACITY_* results are read by bin/fm-spawn.sh.
fm_fleet_capacity_occupants() {  # <first-state> <own-id>
  local first=$1 self=$2 state meta kind backend target label i n=0 gone=,
  local -a metas=() states=() backends=() targets=()
  FM_FLEET_CAPACITY_OCCUPANTS=0
  FM_FLEET_CAPACITY_OCCUPANT_IDS=
  FM_FLEET_CAPACITY_OCCUPANT_METAS=()
  FM_FLEET_CAPACITY_ERROR=
  fm_local_firstmate_state_dirs "$first" || {
    FM_FLEET_CAPACITY_ERROR=$FM_LOCAL_FIRSTMATE_ERROR
    return 1
  }
  for state in "${FM_LOCAL_FIRSTMATE_STATES[@]}"; do
    if [ -e "$state" ] && { [ ! -d "$state" ] || [ ! -r "$state" ] || [ ! -x "$state" ]; }; then
      FM_FLEET_CAPACITY_ERROR="local Firstmate state directory $state cannot be read"
      return 1
    fi
    for meta in "$state"/*.meta; do
      [ -f "$meta" ] && [ ! -L "$meta" ] || continue
      [ "$meta" != "$first/$self.meta" ] || continue
      [ -r "$meta" ] || {
        FM_FLEET_CAPACITY_ERROR="task record $meta cannot be read"
        return 1
      }
      fm_meta_get_to kind "$meta" kind
      case "$kind" in
        ship | scout | secondmate) ;;
        *) continue ;;
      esac
      fm_backend_of_meta_to backend "$meta"
      fm_backend_target_of_meta_to target "$meta"
      [ -n "$target" ] || fm_meta_get_to target "$meta" window
      metas[n]=$meta
      states[n]=$state
      backends[n]=$backend
      targets[n]=$target
      n=$((n + 1))
    done
  done
  while IFS= read -r i; do gone="$gone$i,"; done < <(
    i=0
    while [ "$i" -lt "$n" ]; do
      if [ -n "${targets[i]}" ]; then
        (
          case "$(fm_backend_agent_state "${backends[i]}" "${targets[i]}" 2>/dev/null)" in
            (dead | missing) printf '%s\n' "$i" ;;
          esac
        ) &
      fi
      i=$((i + 1))
    done
    wait
  )
  i=0
  while [ "$i" -lt "$n" ]; do
    case "$gone" in
      *",$i,"*) i=$((i + 1)); continue ;;
    esac
    meta=${metas[i]}
    label=${meta##*/}
    label=${label%.meta}
    [ "${states[i]}" = "$first" ] || label="$label in ${states[i]%/*}"
    FM_FLEET_CAPACITY_OCCUPANTS=$((FM_FLEET_CAPACITY_OCCUPANTS + 1))
    FM_FLEET_CAPACITY_OCCUPANT_METAS+=("$meta")
    FM_FLEET_CAPACITY_OCCUPANT_IDS="${FM_FLEET_CAPACITY_OCCUPANT_IDS:+$FM_FLEET_CAPACITY_OCCUPANT_IDS, }$label"
    i=$((i + 1))
  done
  return 0
}
