#!/usr/bin/env bash
# fm-path-lib.sh - fork-free pathname and small-file helpers with no source-time
# side effects, so read-only callers can load them without any library's state
# setup.
#
# Each assigns <output-variable> exactly what `$(dirname -- <path>)` or
# `$(basename -- <path>)` would: POSIX component rules, and the command
# substitution's removal of trailing newlines.

fm_dirname_to() {  # <output-variable> <path>
  local fm_path=$2
  case "$fm_path" in
    '') fm_path=. ;;
    *[!/]*)
      fm_path=${fm_path%"${fm_path##*[!/]}"}
      case "$fm_path" in
        */*)
          fm_path=${fm_path%/*}
          fm_path=${fm_path%"${fm_path##*[!/]}"}
          [ -n "$fm_path" ] || fm_path=/
          ;;
        *) fm_path=. ;;
      esac
      ;;
    *) fm_path=/ ;;
  esac
  while [ "${fm_path%$'\n'}" != "$fm_path" ]; do fm_path=${fm_path%$'\n'}; done
  printf -v "$1" '%s' "$fm_path"
}

fm_basename_to() {  # <output-variable> <path>
  local fm_path=$2
  case "$fm_path" in
    '') ;;
    *[!/]*) fm_path=${fm_path%"${fm_path##*[!/]}"}; fm_path=${fm_path##*/} ;;
    *) fm_path=/ ;;
  esac
  while [ "${fm_path%$'\n'}" != "$fm_path" ]; do fm_path=${fm_path%$'\n'}; done
  printf -v "$1" '%s' "$fm_path"
}

# Read <file> into <output-variable> with no program start and no subshell.
# `$(cat f)` costs both, and one supervision poll reads a dozen small marker
# files this way.
# The value matches `$(cat f)`: every trailing newline is stripped. A missing or
# unreadable file leaves the variable empty and returns 1, which is the same
# answer `$(cat f 2>/dev/null || true)` produces.
# The marker files this serves are plain text; a NUL byte would truncate the
# read, so callers that may face binary content keep using cat.
fm_read_file_to() {  # <output-variable> <file>
  local fm_read_content=''
  if [ ! -f "$2" ] || [ ! -r "$2" ]; then
    printf -v "$1" '%s' ''
    return 1
  fi
  # Reading to a NUL delimiter consumes the whole file and reports end-of-file
  # as a non-zero status, which is the expected outcome rather than a failure.
  IFS= read -r -d '' fm_read_content < "$2" || true
  while [ "${fm_read_content%$'\n'}" != "$fm_read_content" ]; do
    fm_read_content=${fm_read_content%$'\n'}
  done
  printf -v "$1" '%s' "$fm_read_content"
}
