#!/usr/bin/env bash
# Managed machine-local no-mistakes Claude wrapper installation and launch.
# Use fm-seat.sh pipeline-install / pipeline-check as the operator entry point.
#
# Usage:
#   fm-seat-pipeline.sh install|check [--destination <path>] --claude <path>
#   fm-seat-pipeline.sh launch <home> <claude-path> [claude-args...]
#
# install writes only the selected wrapper (default ~/.no-mistakes/bin-wrappers/
# claude) and this home's state/.claude-seat-pipeline-wrapper.json receipt.
# It binds the wrapper to this home and this checkout's helper, so use a stable
# installation checkout, not a disposable worktree. It changes no no-mistakes
# config; configure that wrapper as its Claude binary separately.
# check compares the installed wrapper to the current template without writes.
# Both require the absolute, executable native Claude path (not the wrapper).
# --destination lets tests and a staged install stay entirely in scratch space.
#
# launch ignores inherited Firstmate path overrides and the worker's profile.
# It resolves the bound home's active seat fresh, validates a managed-profile
# NM_CLAUDE_CONFIG_DIR override, and refuses excluded/resting/missing seats.
# The shared extra-usage dispatch gate reads the selected profile; no launch
# bypass is offered. Refusals exit 75, with a reason on stderr and no Claude.
# It then records a PID/start stamp under state/claude-pipeline and execs Claude,
# preserving stdin, stdout, argv, exit status, and signal delivery. Completed
# records are pruned at the next launch; readers verify PID plus start stamp.
# No running agent or pipeline run is ever cancelled, killed, or restarted here.
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME=${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}
CONFIG=${FM_CONFIG_OVERRIDE:-$FM_HOME/config}
STATE=${FM_STATE_OVERRIDE:-$FM_HOME/state}
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-seat-lib.sh
. "$SCRIPT_DIR/fm-seat-lib.sh"
# shellcheck source=bin/fm-quota-axi-lib.sh
. "$SCRIPT_DIR/fm-quota-axi-lib.sh"

die() { printf 'pipeline Claude: %s\n' "$*" >&2; exit 75; }
usage() { sed -n '2,/^set -u/{ /^#/s/^# *//p; }' "$0"; exit 2; }

wrapper_text() {
  printf '#!/usr/bin/env bash\n'
  printf 'FM_PIPELINE_TOOL=%q\nFM_PIPELINE_HOME=%q\nFM_PIPELINE_CLAUDE=%q\n' \
    "$SCRIPT_DIR/fm-seat-pipeline.sh" "$FM_HOME" "$native"
  tail -n +2 "$SCRIPT_DIR/templates/no-mistakes-claude.sh"
}

cmd_install() {
  local verb=$1 destination="${HOME:-}/.no-mistakes/bin-wrappers/claude" native='' tmp receipt
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --destination) [ $# -ge 2 ] || usage; destination=$2; shift 2 ;;
      --claude) [ $# -ge 2 ] || usage; native=$2; shift 2 ;;
      *) usage ;;
    esac
  done
  case "$FM_HOME:$destination:$native" in /*:/*:/*) ;; *) die 'home, destination and native Claude must be absolute paths' ;; esac
  [ -x "$native" ] && [ ! -d "$native" ] || die 'native Claude binary is not executable'
  [ "$native" != "$destination" ] && [ ! "$native" -ef "$destination" ] || die 'native Claude must not be the wrapper itself'
  if [ "$verb" = check ]; then
    if [ ! -x "$destination" ] || ! cmp -s "$destination" <(wrapper_text); then
      die "wrapper is absent or differs from the template: $destination"
    fi
    printf 'pipeline wrapper matches: %s\n' "$destination"
    return 0
  fi
  mkdir -p "$(dirname "$destination")" "$STATE" || die 'could not create wrapper/state directory'
  tmp=$(umask 077; mktemp "$destination.XXXXXX") || die 'could not stage wrapper'
  if ! { wrapper_text > "$tmp" && chmod 700 "$tmp" && mv -f "$tmp" "$destination"; }; then
    rm -f "$tmp"; die 'could not install wrapper';
  fi
  receipt=$(umask 077; mktemp "$STATE/.pipeline-wrapper.XXXXXX") || die 'could not stage installation receipt'
  if ! { jq -cn --arg path "$destination" --arg home "$FM_HOME" --arg native "$native" \
    --arg tool "$SCRIPT_DIR/fm-seat-pipeline.sh" \
    '{path: $path, home: $home, native: $native, tool: $tool}' > "$receipt" &&
    mv -f "$receipt" "$STATE/.claude-seat-pipeline-wrapper.json"; }; then
      rm -f "$receipt"; die 'wrapper installed but receipt could not be written';
  fi
  printf 'pipeline wrapper installed: %s\n' "$destination"
}

cmd_launch() {
  [ $# -ge 2 ] || usage
  FM_HOME=$1
  local native=$2 selection name profile reason record pid started actual
  shift 2
  case "$FM_HOME:$native" in /*:/*) ;; *) die 'home and native Claude must be absolute paths' ;; esac
  [ -d "$FM_HOME/config" ] || die "bound home config is missing: $FM_HOME/config"
  CONFIG="$FM_HOME/config"
  STATE="$FM_HOME/state"
  unset FM_SEAT_READ_MEMO_DIR FM_SEAT_READ_DEADLINE
  selection=$(fm_seat_pipeline_selection) || die 'could not resolve pipeline seat'
  name=$(printf '%s' "$selection" | jq -r '.seat')
  profile=$(printf '%s' "$selection" | jq -r '.profile')
  reason=$(printf '%s' "$selection" | jq -r '.blockedReason // empty')
  [ -z "$reason" ] || die "HELD on $name: $reason; fm-seat.sh pipeline-move selects another seat for subsequent launches (clear a rejected NM_CLAUDE_CONFIG_DIR override in the pipeline environment)"
  if ! reason=$(fm_seat_dispatch_reason "$(fm_seat_dispatch_decision "$profile")"); then
    die "HELD on $name: $reason"
  fi
  [ -x "$native" ] && [ ! -d "$native" ] || die "native Claude is not executable: $native"
  # Never let a daemon's inherited worker profile determine the actual login.
  if [ -n "$profile" ]; then
    export CLAUDE_CONFIG_DIR="$profile"
  else
    unset CLAUDE_CONFIG_DIR
  fi
  unset FM_AMBIENT_CLAUDE_CONFIG_DIR
  mkdir -p "$STATE/claude-pipeline" || die 'could not create pipeline launch records'
  for record in "$STATE/claude-pipeline"/*.json; do
    [ -f "$record" ] || continue
    pid=$(jq -r '.pid // empty' "$record" 2>/dev/null) || continue
    case "$pid" in ''|*[!0-9]*) continue ;; esac
    started=$(jq -r '.started // empty' "$record" 2>/dev/null) || continue
    actual=$(LC_ALL=C ps -p "$pid" -o lstart= 2>/dev/null) || actual=''
    [ -n "$started" ] && [ "$actual" = "$started" ] || rm -f "$record"
  done
  started=$(LC_ALL=C ps -p "$$" -o lstart=) || die 'could not establish launch process start time'
  record=$(umask 077; mktemp "$STATE/claude-pipeline/launch.XXXXXX") || die 'could not stage launch record'
  if ! { printf '%s' "$selection" | jq -c --argjson pid "$$" --arg started "$started" \
    '. + {pid: $pid, started: $started}' > "$record" && mv "$record" "$record.json"; }; then
      rm -f "$record"; die 'could not record pipeline launch';
  fi
  exec "$native" "$@"
}

command -v jq >/dev/null 2>&1 || die 'jq is required'
case "${1-}" in
  install|check) verb=$1; shift; cmd_install "$verb" "$@" ;;
  launch) shift; cmd_launch "$@" ;;
  *) usage ;;
esac
