#!/usr/bin/env bash
# Read dispatch quota from the seats that new workers will use.
# Usage: fm-quota-read.sh [quota-axi arguments...]
# With no arguments, emit quota-axi's default TOON; --json and auth --json
# provide the same evidence formats as quota-axi itself.
# FM_HOME and FM_CONFIG_OVERRIDE select the dispatch home's seat configuration.
# Resolve Claude, Codex and Grok through the launch resolver, in this process
# only. Report non-secret seat paths to stderr and preserve quota stdout.
# Never refresh credentials while collecting dispatch evidence.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-quota-axi-lib.sh
. "$SCRIPT_DIR/fm-quota-axi-lib.sh"
# shellcheck source=bin/fm-seat-lib.sh
. "$SCRIPT_DIR/fm-seat-lib.sh"

for provider in claude codex grok; do
  profile=$(FM_SEAT_PROVIDER=$provider fm_seat_spawn_config_dir) || exit 1
  env_name=$(FM_SEAT_PROVIDER=$provider fm_seat_env_name) || exit 1
  if [ -n "$profile" ]; then
    export "$env_name=$profile"
  else
    unset "$env_name"
  fi
  printf 'dispatch quota: %s seat=%s %s=%s\n' "$provider" \
    "$(FM_SEAT_PROVIDER=$provider fm_seat_active)" "$env_name" "${profile:-<default>}" >&2
done
unset CLAUDE_SECURESTORAGE_CONFIG_DIR
exec quota-axi "$@" --no-credential-refresh
