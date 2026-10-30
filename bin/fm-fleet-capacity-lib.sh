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
# handoff alone does not free a place. fm-worker-park-lib.sh owns verified
# parked records; those release their place, while incomplete exits and launch
# reservations retain it.
# A secondmate endpoint with a readable home holds no place when that home's
# structured backlog has no in-flight rows and its state has no worker metadata.
# Missing, unsafe or unreadable inventory keeps the secondmate's place.
# Child secondmate records are supervisors, not in-flight work; their own
# workers are counted independently by the local-home walk as usual.
# Admitting a ship or scout counts its home's secondmate even before the new
# worker record exists, so activation cannot exceed the cap.
# A holder whose record carries ad_hoc_fleet_slot=1 was admitted on a one-time grant
# above the declaration (bin/fm-spawn.sh --ad-hoc-slot). It holds a place like
# any other agent AND raises the effective fleet cap by one while it does, so
# the places an ordinary spawn sees are unchanged and the grant admits only the
# task it was given to. Its count is reported separately so a refusal and the
# fleet view can say how many places are ad hoc.
# The supervising lead of the root home has no task record and is not counted.
# Remote homes are never walked, because their agents run on another machine.
#
# Race safety: bin/fm-spawn.sh takes the fleet lock (fm_fleet_capacity_lock_path)
# before counting and keeps it until the new task record is published, so two
# concurrent spawns anywhere on this machine can never both take the last place.
# The lock is taken only when a cap is declared. Freeing a place needs no lock.
# A spawn waits at most 120s for a busy admission lock, then defers with exit
# 75. A parked secondmate relaunch re-enters fleet admission and defers at once
# rather than waiting under its lifecycle lock.
#
# Requires bin/fm-project-capacity-lib.sh and its own prerequisites to be
# sourced first. No side effects on source.

# shellcheck source=bin/fm-worker-park-lib.sh
. "${BASH_SOURCE[0]%/*}/fm-worker-park-lib.sh"

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

# Prove a secondmate has no in-flight work, without interpreting its terminal.
# Use the same addressed backlog reader as lifecycle transitions, bounded so a
# stalled adapter keeps the place rather than wedging admission. Source in a
# subshell so probing another home cannot reset the caller's backlog state.
fm_fleet_capacity_secondmate_idle() ( # <meta> [activating-state]
  local home child kind inventory_backend listing
  [ -z "$(fm_meta_get "$1" remote_host)" ] || return 1
  fm_meta_get_to home "$1" worktree
  [ "$home/state" != "${2:-}" ] || return 1
  case "$home" in /*) ;; *) return 1 ;; esac
  for child in "$home" "$home/state" "$home/data"; do
    [ -d "$child" ] && [ ! -L "$child" ] && [ -r "$child" ] && [ -x "$child" ] || return 1
  done
  for child in "$home/state"/*.meta; do
    [ -e "$child" ] || [ -L "$child" ] || continue
    [ -f "$child" ] && [ ! -L "$child" ] && [ -r "$child" ] || return 1
    fm_meta_get_to kind "$child" kind
    [ "$kind" = secondmate ] || return 1
  done
  # shellcheck source=bin/fm-tasks-axi-lib.sh
  . "${BASH_SOURCE[0]%/*}/fm-tasks-axi-lib.sh"
  # shellcheck source=bin/fm-backlog-transition-lib.sh
  . "${BASH_SOURCE[0]%/*}/fm-backlog-transition-lib.sh"
  inventory_backend=$(fm_tasks_axi_backend "$home") || return 1
  if [ "$inventory_backend" = markdown ]; then
    [ -f "$home/data/backlog.md" ] && [ ! -L "$home/data/backlog.md" ] && [ -r "$home/data/backlog.md" ] || return 1
  fi
  listing=$(FM_TASKS_AXI_TIMEOUT=5 fm_backlog_row_list "$home/data" --state in_flight) || return 1
  printf '%s\n' "$listing" | grep -qx 'count: 0'
)

# Count the live agents holding a place in the fleet.
# <own-id> in <first-state> is the task being admitted and is not counted.
# An optional ship/scout <kind> activates that home's secondmate place.
# Sets FM_FLEET_CAPACITY_OCCUPANTS and FM_FLEET_CAPACITY_OCCUPANT_IDS, each
# holder outside <first-state> qualified with its home, the array
# FM_FLEET_CAPACITY_OCCUPANT_METAS with those exact holders' metadata paths, and
# FM_FLEET_CAPACITY_ADHOC with how many of them hold an ad hoc grant.
# An empty <own-id> counts every record (read-only display callers).
# Returns 1 with
# FM_FLEET_CAPACITY_ERROR when the local homes or a task record cannot be read.
# shellcheck disable=SC2034 # the FM_FLEET_CAPACITY_* results are read by bin/fm-spawn.sh.
fm_fleet_capacity_occupants() {  # <first-state> <own-id> [kind]
  local first=$1 self=$2 state meta kind='' backend='' target='' label i n=0 gone=, activating_state=
  local -a metas=() states=() backends=() targets=()
  case "${3:-}" in ship | scout) activating_state=$first ;; esac
  FM_FLEET_CAPACITY_OCCUPANTS=0
  FM_FLEET_CAPACITY_ADHOC=0
  FM_FLEET_CAPACITY_OCCUPANT_IDS=
  FM_FLEET_CAPACITY_OCCUPANT_METAS=()
  FM_FLEET_CAPACITY_PARKED_METAS=()
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
      if fm_worker_park_load "$meta"; then
        FM_FLEET_CAPACITY_PARKED_METAS+=("$meta")
        continue
      fi
      fm_backend_of_meta_to backend "$meta"
      fm_backend_target_of_meta_to target "$meta"
      [ -n "$target" ] || fm_meta_get_to target "$meta" window
      # An unverified exit and an in-flight launch retain their reservation.
      if [ "$(fm_meta_get "${meta%.meta}.park" phase)" = parking ]; then target=; fi
      label=${meta##*/}; label=${label%.meta}
      if [ -f "$state/.spawn-$label.lock/pid" ] && kill -0 "$(cat "$state/.spawn-$label.lock/pid")" 2>/dev/null; then target=; fi
      if [ -f "${meta%.meta}.park" ] && [ -f "$state/.control-$label.lock/pid" ] &&
        kill -0 "$(cat "$state/.control-$label.lock/pid")" 2>/dev/null; then target=; fi
      if [ "$kind" = secondmate ] && [ -n "$target" ] &&
        fm_fleet_capacity_secondmate_idle "$meta" "$activating_state" 2>/dev/null; then
        continue
      fi
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
    if [ "$(fm_ad_hoc_slot_granted "$meta" fleet)" = 1 ]; then
      FM_FLEET_CAPACITY_ADHOC=$((FM_FLEET_CAPACITY_ADHOC + 1))
      label="$label (ad hoc)"
    fi
    FM_FLEET_CAPACITY_OCCUPANT_IDS="${FM_FLEET_CAPACITY_OCCUPANT_IDS:+$FM_FLEET_CAPACITY_OCCUPANT_IDS, }$label"
    i=$((i + 1))
  done
  return 0
}

# Optional load policy: root config/fleet-load-policy is absent, `off`, or a
# JSON object {"mode":"observe"|"enforce","floor":6,"ceiling":8,"start":8}.
# A JSON object with mode off is invalid: status reports it and admission keeps
# the static cap. Mode is not part of the state identity, so observed history
# carries into enforce. Capacity-change wakes are sent only in enforce mode.
# Enabled limits are positive integers with floor <= start <= ceiling and
# require fleet-capacity. The static cap always bounds the policy. Observe
# reports the desired cap/hold but never applies either. Off does no sampling.
# macOS sampling/reduction is delegated to fm-fleet-load.py, not a daemon.
# state/fleet-load.json is one atomic v1 record containing config/boot identity,
# raw signals, monotonic/UTC time, target, streaks, last adjustment and hold.
# The caller holds .fleet-capacity.lock across refresh, counting and publication.
# Tick releases it before any relaunch. Status never refreshes or writes it.
# FM_FLEET_LOAD_TELEMETRY and FM_FLEET_LOAD_CLOCK name isolated JSON test inputs;
# the helper's reader owns their shape. Never set them for an operational home.

fm_fleet_load_enabled() { # <config-dir>
  local raw
  [ -e "$1/fleet-load-policy" ] || [ -L "$1/fleet-load-policy" ] || return 1
  raw=$(cat "$1/fleet-load-policy" 2>/dev/null) || return 0
  [ "$raw" != off ]
}

# Sets FM_FLEET_LOAD_JSON and FM_FLEET_EFFECTIVE_CAPACITY. A hold is a 75 only
# in enforce mode (or invalid configuration); observe retains static admission,
# as does an invalid configuration that reports no hold.
# shellcheck disable=SC2034 # FM_FLEET_EFFECTIVE_CAPACITY is read by bin/fm-spawn.sh.
fm_fleet_load_evaluate() { # <home> <config-dir> <refresh|status>
  local root mode hold staged
  root=$(fm_firstmate_root_home "$1") || return 1
  FM_FLEET_EFFECTIVE_CAPACITY=$FM_FLEET_CAPACITY
  FM_FLEET_LOAD_JSON=
  if ! fm_fleet_load_enabled "$2"; then return 0; fi
  if ! FM_FLEET_LOAD_JSON=$(python3 "${BASH_SOURCE[0]%/*}/fm-fleet-load.py" "$root" "$2" "$FM_FLEET_CAPACITY" "$3"); then
    mode=$(jq -r '.mode? // "invalid"' "$2/fleet-load-policy" 2>/dev/null) || mode=invalid
    [ "$mode" = observe ] && [ -n "$FM_FLEET_CAPACITY" ] || [ "$mode" = enforce ] || mode=invalid
    FM_FLEET_LOAD_JSON=$(jq -cn --arg mode "$mode" --arg cap "$FM_FLEET_CAPACITY" \
      '{mode:$mode,configured:(($cap|tonumber?) // null),effective:(($cap|tonumber?) // null),hold:"fleet-load helper failed",reason:"fleet-load helper failed"}')
    [ "$mode" = observe ] || return 75
    return 0
  fi
  FM_FLEET_EFFECTIVE_CAPACITY=$(printf '%s\n' "$FM_FLEET_LOAD_JSON" | jq -r '.effective // empty')
  mode=$(printf '%s\n' "$FM_FLEET_LOAD_JSON" | jq -r '.mode')
  hold=$(printf '%s\n' "$FM_FLEET_LOAD_JSON" | jq -r '.hold')
  if [ "$3" = refresh ] && [ "$(printf '%s\n' "$FM_FLEET_LOAD_JSON" | jq -r '.transition // false')" = true ]; then
    if STATE="$root/state" FM_WAKE_QUEUE="$root/state/.wake-queue" FM_WAKE_QUEUE_LOCK="$root/state/.wake-queue.lock" \
      fm_wake_append check fleet-load-capacity "check: fleet-load capacity changed; reconsider queued work: $FM_FLEET_LOAD_JSON"; then
      # A failed wake never marks the transition delivered; the next tick retries.
      staged=$(mktemp "$root/state/.fleet-load-notice.XXXXXX") || staged=
      if [ -n "$staged" ]; then
        printf '%s\n' "$FM_FLEET_LOAD_JSON" | jq -rj '.notice_fingerprint' > "$staged" &&
          mv "$staged" "$root/state/.fleet-load-notice"
        rm -f "$staged"
      fi
    fi
  fi
  if { [ "$mode" = invalid ] || [ "$mode" = enforce ]; } && [ -n "$hold" ]; then return 75; fi
}

fm_fleet_load_tick() { # <home> <config-dir>
  local config lock rc=0
  config=$(fm_project_capacity_config_dir "$1" "$2") || return 1
  fm_fleet_load_enabled "$config" || return 0
  fm_fleet_capacity_lookup "$config" || return 1
  lock=$(fm_fleet_capacity_lock_path "$1") || return 1
  fm_lock_try_acquire "$lock" || return 0
  fm_fleet_load_evaluate "$1" "$config" refresh || rc=$?
  fm_lock_release "$lock" || return 1
  [ "$rc" = 0 ] || [ "$rc" = 75 ]
}

# One structured projection for worker-park status and fleet snapshot.
# Endpoint uncertainty is included in occupancy; unreadable inventory is explicit.
fm_fleet_capacity_observation() { # <home> <config-dir> <state-dir>
  local config policy rc=0 occupancy_error='' rows queued
  config=$(fm_project_capacity_config_dir "$1" "$2") || return 1
  fm_fleet_capacity_lookup "$config" || return 1
  fm_fleet_load_evaluate "$1" "$config" status || rc=$?
  [ "$rc" = 0 ] || [ "$rc" = 75 ] || return "$rc"
  policy=${FM_FLEET_LOAD_JSON:-}
  if [ -z "$policy" ]; then
    policy=$(jq -n --arg cap "$FM_FLEET_CAPACITY" '{mode:"off",configured:($cap|tonumber?),effective:($cap|tonumber?),hold:"",reason:"static capacity; adaptation off"}')
    [ -n "$policy" ] || policy='{"mode":"off","configured":null,"effective":null,"hold":""}'
  fi
  fm_fleet_capacity_occupants "$3" '' || occupancy_error=$FM_FLEET_CAPACITY_ERROR
  if rows=$(fm_worker_park_rows "$3"); then
    queued=$(printf '%s\n' "$rows" | awk 'NF {n++} END {print n+0}')
  else
    queued=null
    occupancy_error=${occupancy_error:-parked-worker resume queue unreadable}
  fi
  printf '%s\n' "$policy" | jq --arg error "$occupancy_error" --arg ids "$FM_FLEET_CAPACITY_OCCUPANT_IDS" \
    --argjson occupied "$FM_FLEET_CAPACITY_OCCUPANTS" --argjson queued "$queued" \
    --argjson adhoc "$FM_FLEET_CAPACITY_ADHOC" \
    '. + {occupancy:(if $error == "" then $occupied else null end),occupancy_error:$error,holders:$ids,ad_hoc:(if $error == "" then $adhoc else null end),queued_resumes:$queued}'
}
