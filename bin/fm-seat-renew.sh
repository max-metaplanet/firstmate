#!/usr/bin/env bash
# Read renewal status without touching credentials or launching vendor CLIs.
# Usage: fm-seat-renew.sh --provider claude|codex [--check] <name|default>
# Prints the fm-seat-renew-lib.sh decision JSON. --check exits 0 after a valid
# read request, including an unknown result. Without --check only healthy exits
# 0; invalid, expired_refreshable, and unknown exit 1 without mutation.
# Exit 2 is invalid input or a missing dependency. No renewal adapter is enabled.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
FM_SEAT_PROVIDER=claude
check=0
name=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --provider)
      [ "$#" -ge 2 ] || { echo 'error: --provider requires claude or codex' >&2; exit 2; }
      FM_SEAT_PROVIDER=$2; shift 2 ;;
    --check) check=1; shift ;;
    --help|-h)
      echo 'Usage: fm-seat-renew.sh --provider claude|codex [--check] <name|default>'
      echo 'Read-only renewal status. Automatic renewal is unavailable until exclusive ownership is proven.'
      exit 0 ;;
    -*) echo "error: unknown option: $1" >&2; exit 2 ;;
    *) [ -z "$name" ] || { echo 'error: expected one seat name' >&2; exit 2; }
      name=$1; shift ;;
  esac
done
case "$FM_SEAT_PROVIDER" in claude|codex) ;; *) echo 'error: unsupported provider' >&2; exit 2 ;; esac
command -v jq >/dev/null 2>&1 || { echo 'error: jq is required' >&2; exit 2; }
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-quota-axi-lib.sh
. "$SCRIPT_DIR/fm-quota-axi-lib.sh"
# shellcheck source=bin/fm-seat-lib.sh
. "$SCRIPT_DIR/fm-seat-lib.sh"
# shellcheck source=bin/fm-seat-renew-lib.sh
. "$SCRIPT_DIR/fm-seat-renew-lib.sh"
fm_seat_name_valid "$name" || { echo 'error: invalid seat name' >&2; exit 2; }
profile=$(fm_seat_config_dir "$name") || exit 2
json=$(fm_seat_quota_json "$profile") || json='{}'
result=$(fm_seat_renewal_from "$json" "$profile" "$name") || exit 2
printf '%s\n' "$result"
[ "$check" -eq 1 ] && exit 0
printf '%s\n' "$result" | jq -e '.state == "healthy"' >/dev/null
