#!/usr/bin/env bash
# Guarded vendor-owned, token-free seat renewal.
# Usage: fm-seat-renew.sh --provider claude|codex [--check] <name|default>
#        fm-seat-renew.sh arm|disarm|auto
# --check only reads quota and last renewal history. A named mutation rechecks
# under the machine-wide credential lock, excludes live owners, invokes the
# vendor, and verifies fresh state. Exit 0 means healthy; 1 means deferred or
# unsuccessful; 2 means invalid input. Invalid credentials never trigger login.
# arm registers the existing watcher check for both providers. auto starts due
# one-shot jobs (15 minute cadence), outside the watcher's killing timeout.
# These jobs retain their lock until the vendor exits, even if it stalls.
# --profiles and --probe are read-only internal interfaces for the job runner.
# --profiles includes each in-use provider's default seat; ordinary Claude keeps
# an empty profile, its unset Keychain selector, never an explicit ~/.claude.
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
export FM_HOME
FM_SEAT_PROVIDER=claude
check=0
probe=0
probe_profile=''
probe_profile_set=0
name=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --provider) [ "$#" -ge 2 ] || exit 2; FM_SEAT_PROVIDER=$2; shift 2 ;;
    --check) check=1; shift ;;
    --probe) probe=1; shift ;;
    --probe-profile) [ "$#" -ge 2 ] || exit 2; probe_profile=$2; probe_profile_set=1; shift 2 ;;
    --profiles) name=profiles; shift ;;
    --help|-h) sed -n '2,/^set -u/p' "$0" | sed '$d;s/^# *//'; exit 0 ;;
    -*) echo "error: unknown option: $1" >&2; exit 2 ;;
    *) [ -z "$name" ] || exit 2; name=$1; shift ;;
  esac
done
case "$FM_SEAT_PROVIDER" in claude|codex) ;; *) exit 2 ;; esac
command -v jq >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1 || exit 2
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-quota-axi-lib.sh
. "$SCRIPT_DIR/fm-quota-axi-lib.sh"
# shellcheck source=bin/fm-seat-lib.sh
. "$SCRIPT_DIR/fm-seat-lib.sh"
# shellcheck source=bin/fm-seat-renew-lib.sh
. "$SCRIPT_DIR/fm-seat-renew-lib.sh"
case "$name" in
  arm|disarm)
    # shellcheck source=bin/fm-pr-lib.sh
    . "$SCRIPT_DIR/fm-pr-lib.sh"
    # shellcheck source=bin/fm-check-lib.sh
    . "$SCRIPT_DIR/fm-check-lib.sh"
    # shellcheck source=bin/fm-check-shim-lib.sh
    . "$SCRIPT_DIR/fm-check-shim-lib.sh"
    FM_CHECK_SHIM_ID='seat-renewal'
    FM_CHECK_SHIM_LABEL=fm-seat-renew
    if [ "$name" = arm ]; then
      fm_check_shim_arm "$FM_HOME" "$SCRIPT_DIR/fm-seat-renew.sh" auto || exit 1
      echo 'armed: guarded renewal checks for Claude and Codex every 15 minutes'
    else
      fm_check_shim_disarm
      echo 'disarmed: future renewal checks; an in-flight refresh keeps its lock until complete'
    fi
    exit 0 ;;
  auto) exec python3 "$SCRIPT_DIR/fm-seat-renew.py" auto ;;
  profiles)
    for FM_SEAT_PROVIDER in claude codex; do
      fm_seat_provider_in_use || continue
      while IFS= read -r seat; do
        fm_seat_name_valid "$seat" || continue
        profile=$(fm_seat_config_dir "$seat") || continue
        [ "$FM_SEAT_PROVIDER" = claude ] || profile=${profile:-$HOME/.codex}
        [ -z "$profile" ] || [ -d "$profile" ] || continue
        jq -cn --arg provider "$FM_SEAT_PROVIDER" --arg name "$seat" --arg profile "$profile" \
          '{provider:$provider,name:$name,profile:$profile}'
      done < <(printf '%s\n' "$FM_SEAT_DEFAULT_NAME"; fm_seat_list)
    done
    exit 0 ;;
esac
fm_seat_name_valid "$name" || { echo 'error: invalid seat name' >&2; exit 2; }
if [ "$probe_profile_set" -eq 1 ]; then
  [ "$probe" -eq 1 ] || exit 2
  case "$probe_profile" in /*) profile=$probe_profile ;; '') [ "$FM_SEAT_PROVIDER" = claude ] || exit 2; profile='' ;; *) exit 2 ;; esac
else
  profile=$(fm_seat_config_dir "$name") || exit 2
fi
[ "$FM_SEAT_PROVIDER" != codex ] || profile=${profile:-$HOME/.codex}
if [ "$check" -eq 1 ] || [ "$probe" -eq 1 ]; then
  # Never reuse a panel/rotation snapshot for renewal eligibility.
  unset FM_SEAT_READ_MEMO_DIR FM_SEAT_READ_DEADLINE
  json=$(fm_seat_quota_json "$profile") || json='{}'
  if [ "$probe" -eq 1 ]; then export FM_SEAT_RENEW_NO_HISTORY=1; fi
  fm_seat_renewal_from "$json" "$profile" "$name"
else
  exec python3 "$SCRIPT_DIR/fm-seat-renew.py" renew --provider "$FM_SEAT_PROVIDER" --profile "$profile" --name "$name"
fi
