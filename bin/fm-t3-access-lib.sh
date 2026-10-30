#!/usr/bin/env bash
# T3 primary sessions default to read-only, including projects named view-only.
# FM_T3_VIEW_ONLY=1 is the explicit provider-environment marker. The native
# t3 executable in the process ancestry also marks threads automatically.
# Only the deliberate handover nonce or its already-owning Claude session may
# pass. No state is created here; session-start and fm-lock call before writes.
# shellcheck source=bin/fm-primary-scope-lib.sh
. "${BASH_SOURCE[0]%/*}/fm-primary-scope-lib.sh"

fm_t3_read_only() { # <home> <state>
  local home=$1 state=$2 pid=$PPID comm parent marked=${FM_T3_VIEW_ONLY:-0} record
  # Persistent secondmate placement has its own parent-owned startup contract.
  fm_root_is_secondmate_home "$home" && return 1
  if [ "$marked" != 1 ]; then
    while [ "$pid" -gt 1 ] 2>/dev/null; do
      comm=$(ps -p "$pid" -o comm= 2>/dev/null) || break
      case "${comm##*/}" in t3) marked=1; break ;; esac
      parent=$(ps -p "$pid" -o ppid= 2>/dev/null | tr -d ' ') || break
      [ "$parent" != "$pid" ] || break
      pid=$parent
    done
  fi
  [ "$marked" = 1 ] || return 1
  record="$state/.t3-leader-handover.json"
  if [ -f "$record" ] && [ ! -L "$record" ] && command -v jq >/dev/null; then
    if jq -e --arg home "$home" --arg nonce "${FM_T3_LEADER_HANDOVER:-}" '
      .version == 1 and .home == $home and .destination == "t3" and
      .phase == "starting" and ($nonce | length > 0) and .nonce == $nonce
      ' "$record" >/dev/null 2>&1 && fm_session_lock_trusted_session_id >/dev/null; then
      return 1
    fi
    if jq -e --arg home "$home" '.home == $home and .destination == "t3" and (.phase == "starting" or .phase == "confirmed")' "$record" >/dev/null 2>&1 \
      && fm_session_lock_owned_by_self "$state"; then
      return 1
    fi
  fi
  return 0
}
