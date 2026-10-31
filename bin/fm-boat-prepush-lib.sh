#!/usr/bin/env bash
# fm-boat-prepush-lib.sh - which projects run the pre-ready heavy-test check,
# and on what machine, timeout and Git history.
#
# A core-like project's heavy test lanes are too slow and too hungry to run in
# a worker's own copy, so they go to one disposable Boat machine before the
# worker marks its pull request ready. Firstmate cannot tell from a project's
# code whether that check is worth a machine, so the captain declares the
# projects that run it. Without a declaration nothing changes and a ship
# worker's definition of done renders exactly as it does today.
#
# This file is the single owner of the declaration format and of the lookup.
# docs/configuration.md "Pre-ready Boat check" is the operator reference,
# bin/fm-boat-prepush.sh owns the check itself, and bin/fm-dod-lib.sh owns the
# definition-of-done paragraph a declared project gains.
#
# Declaration: <config-dir>/boat-prepush in the active home's config directory.
# One line per project:
#   <project-name> [type=default|large] [timeout=SECONDS] [history-depth=N]
# <project-name> is the project's registered name, which is the basename of its
# clone directory, and it is the FIRST whitespace-separated field, so a name
# containing spaces cannot be declared here. Every later field is an optional
# <key>=<value> token and the keys may appear in any order.
#   type           default (4 CPU/8 GB) or large (8 CPU/16 GB), default
#                  `default`. xlarge is refused: a pre-ready gate does not
#                  spend the largest machine Boat offers.
#   timeout        whole seconds, 1..2700, default 2700, the bound
#                  bin/fm-boat-run.sh --timeout documents.
#   history-depth  whole Git fetch depth, 1..1000, omitted by default. Omitted
#                  means the synthetic two-commit history
#                  bin/fm-boat-test-wrapper.sh builds.
# Blank lines are ignored. A line is a comment when it is `#` or when it starts
# with `#` followed by whitespace; a name glued to a leading `#`, such as
# `#repo`, is a project rather than a comment, so write every note as `# note`.
# Any other shape, an unknown key, a key given twice on one line, a project
# named twice, or an unreadable file makes the whole declaration unreadable,
# and the lookup refuses rather than guessing which projects were meant to be
# gated. An absent file is not an error and means no project declares the
# check.
#
# No side effects on source, and nothing else is sourced.

# The config directory holding this home's declaration, resolved exactly as
# bin/fm-external-review-lib.sh resolves its own.
fm_boat_prepush_config_dir() {
  printf '%s\n' "${CONFIG:-${FM_CONFIG_OVERRIDE:-${FM_HOME:-}/config}}"
}

# 0 when <value> is a whole number from 1 to <max>, written without a leading
# zero. The length guard keeps a pasted digit run out of shell arithmetic.
_fm_boat_prepush_bounded() {  # <value> <max>
  case "$1" in
    '' | *[!0-9]* | 0*) return 1 ;;
  esac
  [ "${#1}" -le "${#2}" ] && [ "$1" -le "$2" ]
}

# Record <message> as the reason the whole declaration is unreadable and drop
# any fields already matched, so no caller can act on half a declaration.
_fm_boat_prepush_refuse() {  # <lineno> <message>
  FM_BOAT_PREPUSH_ERROR="$FM_BOAT_PREPUSH_FILE line $1 $2"
  FM_BOAT_PREPUSH_DECLARED=
  FM_BOAT_PREPUSH_TYPE=
  FM_BOAT_PREPUSH_TIMEOUT=
  FM_BOAT_PREPUSH_HISTORY_DEPTH=
}

# Read one project's declaration.
# Sets FM_BOAT_PREPUSH_FILE to the declaration path, FM_BOAT_PREPUSH_DECLARED
# to 1 when <project-name> is declared and to empty when it is not, and
# FM_BOAT_PREPUSH_TYPE, FM_BOAT_PREPUSH_TIMEOUT and
# FM_BOAT_PREPUSH_HISTORY_DEPTH to that project's fields, the last empty when
# the declaration omits it.
# Returns 1 with FM_BOAT_PREPUSH_ERROR when the declaration is unreadable.
# shellcheck disable=SC2034 # The five FM_BOAT_PREPUSH_* fields below are this
# function's return values, read by bin/fm-dod-lib.sh after sourcing.
fm_boat_prepush_lookup() {  # <config-dir> <project-name>
  local want=$2 line lineno=0 name key value i seen='|' line_keys
  local ptype ptimeout pdepth
  local -a fields
  FM_BOAT_PREPUSH_FILE="$1/boat-prepush"
  FM_BOAT_PREPUSH_DECLARED=
  FM_BOAT_PREPUSH_TYPE=
  FM_BOAT_PREPUSH_TIMEOUT=
  FM_BOAT_PREPUSH_HISTORY_DEPTH=
  FM_BOAT_PREPUSH_ERROR=
  if [ ! -e "$FM_BOAT_PREPUSH_FILE" ] && [ ! -L "$FM_BOAT_PREPUSH_FILE" ]; then
    return 0
  fi
  if [ ! -f "$FM_BOAT_PREPUSH_FILE" ] || [ ! -r "$FM_BOAT_PREPUSH_FILE" ]; then
    FM_BOAT_PREPUSH_ERROR="$FM_BOAT_PREPUSH_FILE is not a readable regular file"
    return 1
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    line=${line%$'\r'}
    case "${line#"${line%%[![:space:]]*}"}" in
      '' | '#' | '#'[[:space:]]*) continue ;;
    esac
    # A here-string read splits on whitespace without expanding a glob, so a
    # declaration holding `*` names a project rather than this directory.
    read -r -a fields <<< "$line"
    name=${fields[0]}
    ptype=default
    ptimeout=2700
    pdepth=
    line_keys='|'
    for ((i = 1; i < ${#fields[@]}; i++)); do
      case "${fields[$i]}" in
        ?*=*) ;;
        *)
          _fm_boat_prepush_refuse "$lineno" "gives $name the field '${fields[$i]}', which is not <key>=<value>"
          return 1 ;;
      esac
      key=${fields[$i]%%=*}
      value=${fields[$i]#*=}
      case "$line_keys" in
        *"|$key|"*)
          _fm_boat_prepush_refuse "$lineno" "gives $name $key a second time"
          return 1 ;;
      esac
      line_keys="$line_keys$key|"
      case "$key" in
        type)
          case "$value" in
            default | large) ptype=$value ;;
            *)
              _fm_boat_prepush_refuse "$lineno" "gives $name type=$value; this check runs only on default or large"
              return 1 ;;
          esac ;;
        timeout)
          _fm_boat_prepush_bounded "$value" 2700 || {
            _fm_boat_prepush_refuse "$lineno" "gives $name a timeout that is not a whole number of seconds from 1 to 2700"
            return 1
          }
          ptimeout=$value ;;
        history-depth)
          _fm_boat_prepush_bounded "$value" 1000 || {
            _fm_boat_prepush_refuse "$lineno" "gives $name a history depth that is not a whole number from 1 to 1000"
            return 1
          }
          pdepth=$value ;;
        *)
          _fm_boat_prepush_refuse "$lineno" "gives $name the unknown field $key"
          return 1 ;;
      esac
    done
    case "$seen" in
      *"|$name|"*)
        _fm_boat_prepush_refuse "$lineno" "names $name a second time"
        return 1 ;;
    esac
    seen="$seen$name|"
    if [ "$name" = "$want" ]; then
      FM_BOAT_PREPUSH_DECLARED=1
      FM_BOAT_PREPUSH_TYPE=$ptype
      FM_BOAT_PREPUSH_TIMEOUT=$ptimeout
      FM_BOAT_PREPUSH_HISTORY_DEPTH=$pdepth
    fi
  done < "$FM_BOAT_PREPUSH_FILE"
  return 0
}
