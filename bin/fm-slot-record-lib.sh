# shellcheck shell=bash
# Shared cross-record working-copy check: does another task record on this
# machine already name the copy this operation is about to use?
#
# ONE OWNER for that walk. Three scripts ask the identical question -
# bin/fm-teardown.sh refuses to return a pool slot a second record names
# (returning it would kill that task's processes and reset its copy),
# bin/fm-spawn.sh refuses to launch into a copy a second record names (two
# workers in one copy silently overwrite each other), and bin/fm-slot-release.sh
# refuses to act unless a second record really does name the copy - so the walk
# lives here and none of them restates it.
#
# The question is deliberately asked of the RECORDS, never of Treehouse's own
# in-use flag. That flag reports the processes running under a slot, so a slot
# whose worker has exited reads free while a task record still names it, and a
# fresh launch is then handed the same copy. Observed 2026-09-24: a paused
# scout's agent died with a machine restart, Treehouse reported its slot
# available, the next spawn took it, and afterwards teardown refused BOTH
# records through this check - a deadlock no supported command broke. The launch
# side of the same check is what stops the pair forming; bin/fm-slot-release.sh
# is the supported, non-forced way out of one that already exists.
#
# Both the worktree= and home= fields are scanned: a secondmate home is a
# working copy too, and handing it to a crewmate is the same collision.
#
# A record carrying worktree_claim=released is skipped entirely: it has
# explicitly disclaimed its recorded copy through bin/fm-slot-release.sh, which
# writes that line only once the copy is proved to hold no unlanded work. That
# is what lets one record step out of a collision without losing the copy path
# its own endpoint validation still needs.
#
# Callers must already source bin/fm-wake-lib.sh (fm_firstmate_root_home),
# bin/fm-secondmate-registry-lib.sh (secondmate_registry_parse_line), and
# bin/fm-backend.sh (fm_meta_get).

# Reason a scan could not run, for the caller's own refusal wording. The two
# callers refuse in different voices ("REFUSED: ... nothing was changed" versus
# "error: ... refusing to launch"), so this library never prints.
# shellcheck disable=SC2034 # Output global, read by the sourcing caller.
FM_SLOT_RECORD_ERROR=

# Every local Firstmate home's state directory, reachable from the record's own
# home: the local root, and each local secondmate registered below it. A remote
# registry entry is skipped - its records live on another machine and cannot
# name a copy here. Returns non-zero with FM_SLOT_RECORD_ERROR set.
FM_SLOT_RECORD_STATES=()
fm_slot_record_local_states() {  # <record-state>
  local record_state=$1 root home reg line child known existing i=0
  local -a homes
  FM_SLOT_RECORD_ERROR=
  FM_SLOT_RECORD_STATES=("$record_state")
  root=$(fm_firstmate_root_home "$FM_HOME") || {
    FM_SLOT_RECORD_ERROR="cannot resolve the root Firstmate home"
    return 1
  }
  homes=("$root")
  while [ "$i" -lt "${#homes[@]}" ]; do
    home=${homes[$i]}
    i=$((i + 1))
    known=0
    for existing in "${FM_SLOT_RECORD_STATES[@]}"; do
      [ "$existing" != "$home/state" ] || known=1
    done
    [ "$known" = 1 ] || FM_SLOT_RECORD_STATES+=("$home/state")
    reg="$home/data/secondmates.md"
    [ ! -e "$reg" ] && [ ! -L "$reg" ] && continue
    [ -f "$reg" ] && [ ! -L "$reg" ] || {
      FM_SLOT_RECORD_ERROR="local Firstmate registry is unsafe at $reg"
      return 1
    }
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in
        "- "*)
          secondmate_registry_parse_line "$line" || {
            FM_SLOT_RECORD_ERROR="malformed local Firstmate registry entry in $reg"
            return 1
          }
          [ "$SECONDMATE_REGISTRY_REMOTE" -eq 0 ] || continue
          child=$(fm_slot_record_canonical_dir "$SECONDMATE_REGISTRY_HOME") || {
            # shellcheck disable=SC2034 # Output global, read by the sourcing caller.
            FM_SLOT_RECORD_ERROR="registered local Firstmate home is unavailable: $SECONDMATE_REGISTRY_HOME"
            return 1
          }
          known=0
          for existing in "${homes[@]}"; do
            [ "$existing" != "$child" ] || known=1
          done
          [ "$known" = 1 ] || homes+=("$child")
          ;;
      esac
    done < "$reg"
  done
}

fm_slot_record_canonical_dir() {  # <path>
  local target=$1
  [ -n "$target" ] || return 1
  [ -d "$target" ] || return 1
  ( CDPATH='' cd -- "$target" && pwd -P )
}

# A short " (in Firstmate home <home>)" when the record just found lives in
# another home on this machine, and nothing when it is this one's. Every refusal
# below names a command to run against that record, and those commands resolve
# their home from FM_HOME, so the operator has to be told which home to run
# them in.
fm_slot_record_other_home_hint() {  # <record-state>
  local record_state=$1 other_state
  [ -n "$FM_SLOT_RECORD_OTHER_META" ] || return 0
  other_state=${FM_SLOT_RECORD_OTHER_META%/*}
  [ "$other_state" != "$record_state" ] || return 0
  printf ' (in Firstmate home %s)' "${other_state%/state}"
}

# Does a task record other than <record-meta> name <copy>?
#   0 - yes; the finding is in FM_SLOT_RECORD_OTHER_*
#   1 - no, including when <copy> is not an existing directory
#   2 - the scan could not run; the reason is in FM_SLOT_RECORD_ERROR
# <record-meta> is excluded by path, so a record that does not exist yet (a
# fresh spawn, whose metadata is published later) excludes nothing and is
# scanned exactly like any other caller.
# shellcheck disable=SC2034 # Output globals, read by the sourcing caller.
FM_SLOT_RECORD_OTHER_ID=
# shellcheck disable=SC2034 # Output globals, read by the sourcing caller.
FM_SLOT_RECORD_OTHER_FIELD=
# shellcheck disable=SC2034 # Output globals, read by the sourcing caller.
FM_SLOT_RECORD_OTHER_META=
# shellcheck disable=SC2034 # Output globals, read by the sourcing caller.
FM_SLOT_RECORD_SLOT=
fm_slot_record_other_claim() {  # <record-meta> <record-state> <copy>
  local record_meta=$1 record_state=$2 copy=$3
  local slot state_dir other other_id field other_path other_slot
  FM_SLOT_RECORD_OTHER_ID=
  FM_SLOT_RECORD_OTHER_FIELD=
  FM_SLOT_RECORD_OTHER_META=
  FM_SLOT_RECORD_SLOT=
  slot=$(fm_slot_record_canonical_dir "$copy") || return 1
  # shellcheck disable=SC2034 # Output global, read by the sourcing caller.
  FM_SLOT_RECORD_SLOT=$slot
  fm_slot_record_local_states "$record_state" || return 2
  for state_dir in "${FM_SLOT_RECORD_STATES[@]}"; do
    for other in "$state_dir"/*.meta; do
      [ -f "$other" ] && [ ! -L "$other" ] || continue
      [ "$other" != "$record_meta" ] || continue
      other_id=$(basename "$other" .meta)
      [ "$(fm_meta_get "$other" worktree_claim)" != released ] || continue
      for field in worktree home; do
        other_path=$(fm_meta_get "$other" "$field")
        [ -n "$other_path" ] || continue
        other_slot=$(fm_slot_record_canonical_dir "$other_path") || continue
        [ "$other_slot" = "$slot" ] || continue
        # shellcheck disable=SC2034 # Output globals, read by the sourcing caller.
        FM_SLOT_RECORD_OTHER_ID=$other_id
        # shellcheck disable=SC2034 # Output globals, read by the sourcing caller.
        FM_SLOT_RECORD_OTHER_FIELD=$field
        # shellcheck disable=SC2034 # Output globals, read by the sourcing caller.
        FM_SLOT_RECORD_OTHER_META=$other
        return 0
      done
    done
  done
  return 1
}
