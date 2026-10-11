#!/usr/bin/env bash
# Parked-secondmate session continuity for fm-secondmate-park and fm-spawn.
# Source this library, then call fm_secondmate_resume_capture <meta> before
# stopping the mate: FM_SECONDMATE_RESUME_MODE/HARNESS/REF describe the captured
# session, or mode=fresh when no supported exact session identity is available.
# Claude uses the same lock-session owner as fm-lead-restart; Pi uses the
# existing runtime identity and resume-flag owners. No recent-session guessing.
# fm_secondmate_resume_load <marker> <home> <harness> validates a persisted
# waking marker and sets those same globals; exact capture never falls back to
# fresh on wake. The park command owns the marker's lifecycle and schema.

_FM_SECONDMATE_RESUME_DIR=${BASH_SOURCE[0]%/*}
# shellcheck source=bin/fm-backend.sh
. "$_FM_SECONDMATE_RESUME_DIR/fm-backend.sh"
# shellcheck source=bin/fm-control-lib.sh
. "$_FM_SECONDMATE_RESUME_DIR/fm-control-lib.sh"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$_FM_SECONDMATE_RESUME_DIR/fm-session-lock-lib.sh"
unset _FM_SECONDMATE_RESUME_DIR

fm_secondmate_resume_capture() { # <meta>
  local meta=$1 home backend target identity agent ref flag
  FM_SECONDMATE_RESUME_MODE=fresh
  FM_SECONDMATE_RESUME_HARNESS=$(fm_meta_get "$meta" harness)
  FM_SECONDMATE_RESUME_REF=
  [ "$(fm_meta_get "$meta" kind)" = secondmate ] || return 1
  home=$(fm_meta_get "$meta" home)
  [ -n "$home" ] || return 1
  case "$FM_SECONDMATE_RESUME_HARNESS" in
    claude)
      ref=$(fm_session_lock_recorded_session_id "$home/state") || return 0
      ;;
    pi|pi-signed)
      backend=$(fm_backend_of_meta "$meta")
      [ "$backend" = herdr ] || return 0
      fm_backend_source "$backend" || return 1
      target=$(fm_backend_target_of_meta "$meta")
      fm_backend_herdr_parse_target "$target" || return 1
      identity=$(fm_backend_herdr_pane_agent_session_ref "$FM_BACKEND_HERDR_SESSION" "$FM_BACKEND_HERDR_PANE") || return 0
      agent=${identity%%$'\t'*}
      ref=${identity#*$'\t'}
      flag=$(fm_control_relaunch_resume_flag "$FM_SECONDMATE_RESUME_HARNESS" "$agent") || return 0
      [ -n "$flag" ] || return 0
      ;;
    *) return 0 ;;
  esac
  case "$ref" in ''|*$'\n'*|*$'\r'*) return 0 ;; esac
  FM_SECONDMATE_RESUME_MODE=exact
  FM_SECONDMATE_RESUME_REF=$ref
}

# Exact-one-field parsing rejects an ambiguous marker instead of picking a
# convenient duplicate. Values are data, never sourced or evaluated.
fm_secondmate_resume_field() { # <marker> <key>
  awk -v key="$2" 'index($0, key "=") == 1 { n++; value=substr($0,length(key)+2) }
    END { if (n != 1) exit 1; print value }' "$1"
}

fm_secondmate_resume_load() { # <marker> <home> <harness>
  local marker=$1 home=$2 harness=$3 recorded_home phase persisted
  FM_SECONDMATE_RESUME_MODE=
  FM_SECONDMATE_RESUME_HARNESS=
  FM_SECONDMATE_RESUME_REF=
  [ -f "$marker" ] && [ ! -L "$marker" ] && [ -r "$marker" ] || return 1
  recorded_home=$(fm_secondmate_resume_field "$marker" home) || return 1
  phase=$(fm_secondmate_resume_field "$marker" phase) || return 1
  persisted=$(fm_secondmate_resume_field "$marker" persisted) || return 1
  [ "$recorded_home" = "$home" ] && [ "$phase" = waking ] && [ "$persisted" = 1 ] || return 1
  FM_SECONDMATE_RESUME_MODE=$(fm_secondmate_resume_field "$marker" resume_mode) || return 1
  FM_SECONDMATE_RESUME_HARNESS=$(fm_secondmate_resume_field "$marker" resume_harness) || return 1
  FM_SECONDMATE_RESUME_REF=$(fm_secondmate_resume_field "$marker" resume_ref) || return 1
  [ "$FM_SECONDMATE_RESUME_HARNESS" = "$harness" ] || return 1
  case "$FM_SECONDMATE_RESUME_MODE:$FM_SECONDMATE_RESUME_HARNESS" in
    exact:claude|exact:pi|exact:pi-signed)
      case "$FM_SECONDMATE_RESUME_REF" in ''|*$'\n'*|*$'\r'*) return 1 ;; esac
      ;;
    fresh:*) [ -z "$FM_SECONDMATE_RESUME_REF" ] || return 1 ;;
    *) return 1 ;;
  esac
}
