#!/usr/bin/env bash
# fm-heavy-slots-lib.sh - how many heavy commands this machine runs at once.
#
# A heavy command is one whose peak memory can exhaust the machine: a Next
# production build, a Vitest run, a Playwright browser run, a whole-project
# tsc. The slot is claimed when such a command starts, not reserved when a
# worker spawns, so a worker that never runs one never holds a slot and a
# worker that runs several holds one at a time. A worker waiting for a slot
# just waits; waiting is not a failure.
#
# This file is the single owner of the declaration format and of where the
# number is published. bin/fm-build-lock.py owns the pool itself - the slot
# files, what counts as heavy, recursion, release, and the bypass -
# docs/configuration.md "Heavy slots" is the operator reference, and
# bin/fm-spawn.sh owns where the publication runs.
#
# Declaration: config/heavy-slots in the local root Firstmate home, resolved
# like config/fleet-capacity (fm_project_capacity_config_dir). It holds one
# positive integer of at most six digits on its own line. Blank lines and lines
# starting with `#` are ignored. An absent file declares one slot. Any other
# shape, a second number, or an unreadable file makes the declaration
# unreadable and the caller refuses rather than guessing the captain's limit.
#
# Publication: the pool is machine-wide for one OS user, and the heavy command
# that claims a slot runs in a worker pane or the no-mistakes daemon, neither of
# which can read this home's configuration. So every ship or scout launch
# rewrites bin/fm-build-lock.py's installed record from this declaration, and
# every heavy command reads that record when it starts. Changing the file
# applies at the next launch, or immediately through
# `FM_HEAVY_SLOTS=<n> bin/fm-build-lock.py node-option`.
#
# Requires bin/fm-project-capacity-lib.sh and its own prerequisites to be
# sourced first. No side effects on source.

# Read the declared heavy-slot count.
# Sets FM_HEAVY_SLOTS_FILE to the declaration path and FM_HEAVY_SLOTS to the
# count, which is 1 when no file declares one. Returns 1 with
# FM_HEAVY_SLOTS_ERROR when the declaration is unreadable.
fm_heavy_slots_lookup() {  # <config-dir>
  local line lineno=0 found=
  FM_HEAVY_SLOTS_FILE="$1/heavy-slots"
  FM_HEAVY_SLOTS=1
  FM_HEAVY_SLOTS_ERROR=
  if [ ! -e "$FM_HEAVY_SLOTS_FILE" ] && [ ! -L "$FM_HEAVY_SLOTS_FILE" ]; then
    return 0
  fi
  if [ ! -f "$FM_HEAVY_SLOTS_FILE" ] || [ ! -r "$FM_HEAVY_SLOTS_FILE" ]; then
    FM_HEAVY_SLOTS_ERROR="$FM_HEAVY_SLOTS_FILE is not a readable regular file"
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
        FM_HEAVY_SLOTS_ERROR="$FM_HEAVY_SLOTS_FILE line $lineno is not a positive integer"
        FM_HEAVY_SLOTS=1
        return 1
        ;;
    esac
    if [ "${#line}" -gt 6 ] || [ -n "$found" ]; then
      FM_HEAVY_SLOTS_ERROR="$FM_HEAVY_SLOTS_FILE line $lineno is a second or over-long number"
      FM_HEAVY_SLOTS=1
      return 1
    fi
    found=$line
  done < "$FM_HEAVY_SLOTS_FILE"
  [ -z "$found" ] || FM_HEAVY_SLOTS=$found
  return 0
}

# Publish the declared count into the machine's installed preload record, so
# every heavy command started afterwards reads this home's declaration.
# Returns 1 with FM_HEAVY_SLOTS_ERROR when the declaration is unreadable or the
# record cannot be written, so a launch refuses rather than running heavy
# commands against a stale pool size.
# shellcheck disable=SC2034 # FM_HEAVY_SLOTS_ERROR is read by bin/fm-spawn.sh.
fm_heavy_slots_publish() {  # <config-dir> <bin-dir>
  local out
  fm_heavy_slots_lookup "$1" || return 1
  if ! out=$(FM_HEAVY_SLOTS="$FM_HEAVY_SLOTS" "$2/fm-build-lock.py" node-option 2>&1); then
    FM_HEAVY_SLOTS_ERROR="the heavy-slot pool record could not be written ($out)"
    return 1
  fi
  return 0
}
