#!/usr/bin/env bash
# Session-scoped Herdr invocation shared by the backend and lab helper.
# fm_herdr_cli_run <binary> <session> <arguments...> keeps --session before
# the first -- delimiter and removes inherited socket overrides in the child.
# FM_HERDR_LAB marks lab processes (the lab helper exports the session name
# into its server and command children). A marked process, or one whose ambient
# HERDR_SESSION is a lab, may address only a valid fm-lab-* session.

fm_herdr_cli_lab_name() { # <session>
  [[ "${1:-}" =~ ^fm-lab-[a-zA-Z0-9][a-zA-Z0-9_-]*$ ]]
}

fm_herdr_cli_check_session() { # <session>
  local session=${1:-} lab=${FM_HERDR_LAB:-}
  case "${HERDR_SESSION:-}" in fm-lab-*) lab=1 ;; esac
  if [ -n "$lab" ] && ! fm_herdr_cli_lab_name "$session"; then
    echo "error: Herdr lab refuses session '${session:-<empty>}': delivery requires a named fm-lab-* session" >&2
    return 1
  fi
  [ -n "$session" ] || { echo 'error: Herdr requires an explicit session' >&2; return 1; }
}

fm_herdr_cli_run() ( # <binary> <session> <arguments...>
  local client=$1 session=$2 i
  # Bash 3.2 array slices must not inherit a caller's temporary read delimiter.
  local IFS=$' \t\n'
  shift 2
  fm_herdr_cli_check_session "$session" || return 1
  local -a args=("$@")
  unset HERDR_SOCKET_PATH HERDR_CLIENT_SOCKET_PATH
  # Replace this isolated shell with the client instead of forking another
  # process for every call made while a presentation lock is held.
  for ((i = 0; i < ${#args[@]}; i++)); do
    [ "${args[i]}" != -- ] || break
  done
  HERDR_SESSION="$session" exec "$client" "${args[@]:0:i}" --session "$session" "${args[@]:i}"
)
