#!/usr/bin/env bash
# fm-crew-state-lib.sh - shared status-declaration mapping for crew readers.
# Requires fm-classify-lib.sh. Sourcing performs no reads or writes.
# This maps a reconciled declaration, not live pipeline or endpoint evidence.
# fm-crew-state.sh owns reconciliation against those authoritative live sources.

fm_crew_log_state() {  # <reconciled-status-line> [<output-variable>]
  local _fm_crew_log_verdict=unknown _fm_crew_log_verb
  if status_is_paused "$1"; then
    _fm_crew_log_verdict=paused
  else
    status_line_verb "$1" _fm_crew_log_verb
    case "$_fm_crew_log_verb" in
      working|blocked|done|failed) _fm_crew_log_verdict=$_fm_crew_log_verb ;;
      needs-decision) _fm_crew_log_verdict=parked ;;
    esac
  fi
  if [ -n "${2:-}" ]; then
    printf -v "$2" '%s' "$_fm_crew_log_verdict"
  else
    printf '%s\n' "$_fm_crew_log_verdict"
  fi
}
