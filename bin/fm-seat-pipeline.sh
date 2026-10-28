#!/usr/bin/env bash
# Managed machine-local no-mistakes Claude wrapper installation and launch.
# Use fm-seat.sh pipeline-install / pipeline-check as the operator entry point.
#
# Usage:
#   fm-seat-pipeline.sh install|check [--destination <path>] --claude <path>
#   fm-seat-pipeline.sh launch --default-profile <dir> <home> <claude-path> [claude-args...]
#
# install writes only the selected wrapper (default ~/.no-mistakes/bin-wrappers/
# claude). It binds the wrapper to this home and this checkout's helper, so use a stable
# installation checkout, not a disposable worktree. It changes no no-mistakes
# config; configure that wrapper as its Claude binary separately. It also binds
# the default-seat profile the installing shell would hand a worker (its
# CLAUDE_CONFIG_DIR, empty for the ambient login), so install from the lead's
# environment.
# check compares the installed wrapper to the current template without writes.
# Both require the absolute, executable native Claude path (not the wrapper).
# --destination lets tests and a staged install stay entirely in scratch space.
#
# launch ignores inherited Firstmate path overrides and the worker's profile.
# When the launching daemon's PATH carries no quota-axi, the extra-usage gate
# reads it through the home's recorded quota tool path, so a tool only a login
# shell can find does not turn every launch into a hold; with no record either,
# a hold on the quota read that failed names the missing record rather than the
# seat's quota.
# It resolves the bound home's active seat fresh, validates a managed-profile
# NM_CLAUDE_CONFIG_DIR override, and refuses excluded/resting/missing seats.
# On the default seat it uses the lead's recorded ambient profile; while none is
# recorded it warns and uses the wrapper's installed default profile instead.
# The shared extra-usage dispatch gate reads the selected profile; no launch
# bypass is offered. Refusals exit 75, with a reason on stderr and no Claude.
# It then records a PID/start stamp under state/claude-pipeline and execs Claude,
# preserving stdin, stdout, argv, exit status, and signal delivery. Completed
# records are pruned at the next launch; readers verify PID plus start stamp.
# No running agent or pipeline run is ever cancelled, killed, or restarted here.
# The managed agent and its children receive the build-lock preload in
# NODE_OPTIONS; fm-build-lock.py install-daemon-env covers the daemon's own
# configured commands. fm-build-lock.py owns the lock and explicit bypass.
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
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"

die() { printf 'pipeline Claude: %s\n' "$*" >&2; exit 75; }
usage() { sed -n '2,/^set -u/{ /^#/s/^# *//p; }' "$0"; exit 2; }

wrapper_text() {
  printf '#!/usr/bin/env bash\n'
  printf 'FM_PIPELINE_TOOL=%q\nFM_PIPELINE_HOME=%q\nFM_PIPELINE_CLAUDE=%q\nFM_PIPELINE_DEFAULT_PROFILE=%q\n' \
    "$SCRIPT_DIR/fm-seat-pipeline.sh" "$FM_HOME" "$native" "$default_profile"
  tail -n +2 "$SCRIPT_DIR/templates/no-mistakes-claude.sh"
}

cmd_install() {
  local verb=$1 destination="${HOME:-}/.no-mistakes/bin-wrappers/claude" native='' tmp default_profile
  shift
  default_profile=$(fm_seat_config_dir "$FM_SEAT_DEFAULT_NAME")
  while [ $# -gt 0 ]; do
    case "$1" in
      --destination) [ $# -ge 2 ] || usage; destination=$2; shift 2 ;;
      --claude) [ $# -ge 2 ] || usage; native=$2; shift 2 ;;
      *) usage ;;
    esac
  done
  case "$FM_HOME:$destination:$native" in /*:/*:/*) ;; *) die 'home, destination and native Claude must be absolute paths' ;; esac
  case "$default_profile" in ''|/*) ;; *) die 'the default-seat profile must be an absolute path' ;; esac
  [ -x "$native" ] && [ ! -d "$native" ] || die 'native Claude binary is not executable'
  [ "$native" != "$destination" ] && [ ! "$native" -ef "$destination" ] || die 'native Claude must not be the wrapper itself'
  if [ "$verb" = check ]; then
    if [ ! -x "$destination" ] || ! cmp -s "$destination" <(wrapper_text); then
      die "wrapper is absent or differs from the template: $destination"
    fi
    printf 'pipeline wrapper matches: %s\n' "$destination"
    return 0
  fi
  mkdir -p "$(dirname "$destination")" || die 'could not create wrapper directory'
  tmp=$(umask 077; mktemp "$destination.XXXXXX") || die 'could not stage wrapper'
  if ! { wrapper_text > "$tmp" && chmod 700 "$tmp" && mv -f "$tmp" "$destination"; }; then
    rm -f "$tmp"; die 'could not install wrapper';
  fi
  printf 'pipeline wrapper installed: %s\n' "$destination"
}

# quota_tool_path <state>
# The directory this launch must add to PATH before it can read quota. A daemon
# starts this wrapper with the daemon's own PATH, which need not carry
# quota-axi at all; the gate would then read no quota and hold every launch as
# unreadable while the same seat reads fine from a shell.
#
# Three outcomes, because they are three different launches:
#   0  the directory to prepend, from the home's recorded quota tool path
#   1  nothing to prepend: this launch finds the tool on its own PATH
#   2  no tool and no record naming one, which is a hold cause of its own
# bin/fm-seat-lib.sh owns the record and checks it rather than trusting it.
quota_tool_path() {
  ! command -v quota-axi >/dev/null 2>&1 || return 1
  fm_seat_quota_tool_recorded "$1" || return 2
}

cmd_launch() {
  [ $# -ge 4 ] && [ "$1" = --default-profile ] || usage
  local default_profile=$2 native=$4 selection name profile reason record pid started actual
  local quota_path='' quota_rc=0 decision
  # The recorded quota tool path is firstmate's to write, never the launching
  # daemon's: a daemon that found the tool only through that record knows no
  # better location than the one already there. Suppressing the recorder here
  # is what keeps this launch a pure reader of it (bin/fm-seat-lib.sh).
  FM_SEAT_QUOTA_TOOL_RECORDED=1
  FM_HOME=$3
  shift 4
  case "$FM_HOME:$native" in /*:/*) ;; *) die 'home and native Claude must be absolute paths' ;; esac
  [ -d "$FM_HOME/config" ] || die "bound home config is missing: $FM_HOME/config"
  CONFIG="$FM_HOME/config"
  STATE="$FM_HOME/state"
  unset FM_SEAT_READ_MEMO_DIR FM_SEAT_READ_DEADLINE
  selection=$(fm_seat_pipeline_selection) || die 'could not resolve pipeline seat'
  name=$(printf '%s' "$selection" | jq -r '.seat')
  profile=$(printf '%s' "$selection" | jq -r '.profile')
  reason=$(printf '%s' "$selection" | jq -r '.blockedReason // empty')
  [ -z "$reason" ] || die "HELD pipeline-agent launch on seat $name: $reason; fm-seat.sh pipeline-move selects another seat for subsequent launches (clear a rejected NM_CLAUDE_CONFIG_DIR override in the pipeline environment)"
  if [ "$(printf '%s' "$selection" | jq -r '.profileRecorded')" = false ]; then
    profile=$default_profile
    selection=$(printf '%s' "$selection" | jq -c --arg p "$profile" '.profile = $p')
    printf "pipeline Claude: warning: the default seat's profile is not recorded for this home's lead; using the wrapper's installed default profile %s. Restarting the lead records it\n" "${profile:-(ambient default login)}" >&2
  fi
  quota_path=$(quota_tool_path "$STATE") || quota_rc=$?
  [ "$quota_rc" -eq 0 ] || quota_path=''
  decision=$(
    [ -z "$quota_path" ] || PATH="$quota_path:$PATH"
    fm_seat_dispatch_decision "$profile"
  )
  if ! reason=$(fm_seat_dispatch_reason "$decision" "pipeline seat $name" "pipeline agent"); then
    # A launch that could never run quota-axi at all did not read quota and
    # find it wanting; it never read any. Saying so names the missing record
    # an operator can restore, where "quota could not be read" sends them to
    # the seat instead.
    if [ "$quota_rc" -eq 2 ] && fm_seat_dispatch_read_failed "$decision"; then
      die "HELD pipeline-agent launch on seat $name: no recorded quota tool path, so this launch read no quota at all - quota-axi is not on the launching process's PATH and no directory holding it is recorded for this home. Any firstmate command that reads quota from a shell that can run the tool records one"
    fi
    die "HELD pipeline-agent launch on seat $name: $reason"
  fi
  case "$reason" in
    *source=fresh-cache*|*source=last-good-fallback*) printf 'pipeline Claude: %s\n' "$reason" >&2 ;;
  esac
  [ -x "$native" ] && [ ! -d "$native" ] || die "native Claude is not executable: $native"
  # Never let a daemon's inherited worker profile determine the actual login.
  if [ -n "$profile" ]; then
    export CLAUDE_CONFIG_DIR="$profile"
  else
    unset CLAUDE_CONFIG_DIR
  fi
  unset FM_AMBIENT_CLAUDE_CONFIG_DIR CLAUDE_SECURESTORAGE_CONFIG_DIR
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
  build_option=$("$SCRIPT_DIR/fm-build-lock.py" node-option) || die 'could not resolve the build lock preload'
  case " ${NODE_OPTIONS-} " in
    *" $build_option "*) ;;
    *) export NODE_OPTIONS="${NODE_OPTIONS:+$NODE_OPTIONS }$build_option" ;;
  esac
  exec python3 "$SCRIPT_DIR/fm-seat-lock.py" guard --provider claude \
    --profile "$profile" -- "$native" "$@"
}

command -v jq >/dev/null 2>&1 || die 'jq is required'
case "${1-}" in
  install|check) verb=$1; shift; cmd_install "$verb" "$@" ;;
  launch) shift; cmd_launch "$@" ;;
  *) usage ;;
esac
