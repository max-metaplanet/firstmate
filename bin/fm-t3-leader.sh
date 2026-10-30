#!/usr/bin/env bash
# fm-t3-leader.sh - attended handover between a terminal and a Claude T3 leader.
#
# Usage (FM_HOME must explicitly name the independent Firstmate home):
#   fm-t3-leader.sh prepare --to t3 --model MODEL [--dry-run | --persisted]
#   fm-t3-leader.sh prepare --to terminal --model MODEL [--dry-run | --persisted]
#   fm-t3-leader.sh activate [--dry-run]
#   fm-t3-leader.sh confirm NONCE
#   fm-t3-leader.sh status
#
# This is opt-in and attended. Prepare must run inside the current lock-owning
# leader. Persist conversation-only open work before --persisted, exit that
# leader normally, then run activate from a separate shell. For a T3 leader,
# use the host's process controls to stop only the recorded outgoing Claude
# PID before activating the terminal; the T3 CLI has no session-stop command.
# Nothing here stops a process, removes a session lock, changes T3 settings,
# or reserves the home against a third leader. Activation refuses a still-live
# outgoing PID and any live/unknown lock owner; the successor must take the
# existing exclusive lock through normal project hooks before it may act.
# A competing leader winning that claim is a failed handover, never permission
# to steal its lock. Confirm proves the successor owns it before recording done.
#
# The persistent record is state/.t3-leader-handover.json. An uncertain launch
# keeps phase=starting and refuses a retry: reconcile its exact T3 project and
# thread before doing anything else. No automatic retry or rollback is safe.
# A confirmed record may be replaced by the next prepare. Dry-run never writes
# or contacts T3 and includes the same current ownership/liveness checks.
#
# Forward activation requires FM_T3_BIN (default t3), FM_T3_BASE_DIR, and the
# provider claudeAgent with the explicit advertised MODEL. Terminal activation
# execs FM_T3_LEADER_CLAUDE_BIN (default claude) with that model in FM_HOME.
# Forward activation also requires config/supervision-host-off, because only
# native Claude Stop-owned supervision has live proof inside T3.
# Read this tool's status after a launch; success requires phase=confirmed.
# Only Claude leaders are supported. Workers' backend selection is independent.
# shellcheck disable=SC2016 # Single-quoted jq filters intentionally contain variables.
set -euo pipefail
umask 077

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"
# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
# shellcheck source=bin/fm-persist-request-lib.sh
. "$SCRIPT_DIR/fm-persist-request-lib.sh"
# shellcheck source=bin/fm-t3-home-lib.sh
. "$SCRIPT_DIR/fm-t3-home-lib.sh"
usage() { sed -n '2,/^set -/p' "${BASH_SOURCE[0]}" | sed '$d; s/^# \{0,1\}//'; }
die() { printf 'fm-t3-leader: %s\n' "$*" >&2; exit 1; }
[ "$#" -gt 0 ] || { usage >&2; exit 2; }
verb=$1
shift
case "$verb" in -h|--help|help) usage; exit 0 ;; esac
[ -n "${FM_HOME:-}" ] || die 'FM_HOME must explicitly name the Firstmate home'
[ -z "${FM_ROOT_OVERRIDE:-}${FM_STATE_OVERRIDE:-}${FM_DATA_OVERRIDE:-}${FM_CONFIG_OVERRIDE:-}" ] || die 'unset Firstmate path overrides; FM_HOME is the handover boundary'
home=$(cd "$FM_HOME" && pwd -P) || die 'Firstmate home is unavailable'
if [ -e "$home/.fm-secondmate-home" ] || [ -L "$home/.fm-secondmate-home" ]; then
  die 'secondmate T3 placement is parent-owned; this handover tool accepts a primary Firstmate home only'
fi
state="$home/state"
record="$state/.t3-leader-handover.json"
fm_primary_scope_matches "$home" "$state" || die 'leader handover requires an independent Firstmate home, not a task worktree'
# The home and its existing state directory are verified before importing the
# wake library, whose normal source-time initialization may create state.
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
command -v jq >/dev/null || die 'jq is required'
[ ! -L "$record" ] || die 'handover record must not be a symlink'

dry=0 persisted=0 destination='' model=''
nonce=${1:-}
if [ "$verb" = confirm ]; then
  [ "$#" -eq 1 ] || die 'confirm requires exactly one nonce'
  shift
fi
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run) dry=1; shift ;;
    --persisted) persisted=1; shift ;;
    --to) [ "$#" -gt 1 ] || die '--to requires a destination'; destination=$2; shift 2 ;;
    --model) [ "$#" -gt 1 ] || die '--model requires a model'; model=$2; shift 2 ;;
    *) die "unknown argument: $1" ;;
  esac
done
case "$verb" in
  prepare) ;;
  activate|status|confirm)
    [ -z "$destination$model" ] && [ "$persisted" -eq 0 ] || die 'destination/model/persisted apply only to prepare'
    ;;
  *) die "unknown command: $verb" ;;
esac

locked=0
cleanup() { [ "$locked" -eq 0 ] || fm_lock_release "$state/.t3-leader-handover.lock"; }
trap cleanup EXIT
claim_record() {
  fm_lock_acquire_wait_max "$state/.t3-leader-handover.lock" 5 || die 'another handover command owns the record'
  locked=1
}
read_record() {
  [ -f "$record" ] && [ -r "$record" ] || die 'no prepared handover record'
  jq -e --arg home "$home" '.version == 1 and .home == $home and (.outgoingPid | type == "number" and . > 0 and . == floor) and (.nonce | type == "string" and test("^[a-f0-9]{32}$")) and (.model | type == "string" and length > 0) and (.destination == "t3" or .destination == "terminal")' "$record" >/dev/null || die 'invalid handover record; reconcile it before proceeding'
}
replace_record() {
  local temporary
  temporary=$(mktemp "$state/.t3-leader-handover.XXXXXX") || die 'cannot stage handover record'
  if ! jq "$@" "$record" > "$temporary" || ! mv -f "$temporary" "$record"; then
    rm -f "$temporary"
    die 'cannot update handover record'
  fi
}
check_departed() {
  local outgoing
  outgoing=$(jq -r '.outgoingPid' "$record")
  if kill -0 "$outgoing" 2>/dev/null || ps -p "$outgoing" -o pid= >/dev/null 2>&1; then
    die "outgoing leader pid $outgoing still exists; exit it normally before activation"
  fi
  fm_session_lock_inspect "$state"
  case "$FM_LOCK_INSPECT_STATE" in
    free|stale) ;;
    *) die "home is not free for handover (lock=$FM_LOCK_INSPECT_STATE pid=$FM_LOCK_INSPECT_PID); leave its owner untouched" ;;
  esac
}

case "$verb" in
  status)
    read_record
    jq 'del(.nonce)' "$record"
    ;;
  prepare)
    case "$destination" in t3|terminal) ;; *) die '--to must be t3 or terminal; only Claude leaders are supported' ;; esac
    [ -n "$model" ] || die '--model must name an advertised Claude model'
    fm_session_lock_owned_by_self "$state" || die 'prepare must run in the current lock-owning leader'
    if [ -f "$record" ] && [ "$(jq -r '.phase' "$record")" != confirmed ]; then
      die 'an unfinished handover already exists; reconcile it rather than replacing it'
    fi
    if [ "$dry" -eq 1 ]; then
      printf 'dry-run: prepare %s -> Claude %s model=%s; then exit outgoing leader and activate from a separate shell\n' "$home" "$destination" "$model"
      exit 0
    fi
    [ "$persisted" -eq 1 ] || die "before handover, $FM_PERSIST_OPEN_RECORDS_CONTRACT Then prepare with --persisted"
    claim_record
    # Recheck ownership and pending work after serializing concurrent prepares.
    fm_session_lock_owned_by_self "$state" || die 'current session no longer owns this home'
    if [ -f "$record" ] && [ "$(jq -r '.phase' "$record")" != confirmed ]; then
      die 'an unfinished handover already exists'
    fi
    outgoing=$(cat "$state/.lock")
    nonce=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
    temporary=$(mktemp "$state/.t3-leader-handover.XXXXXX")
    chmod 600 "$temporary"
    jq -n --arg home "$home" --arg destination "$destination" --arg model "$model" --arg nonce "$nonce" \
      --argjson outgoing "$outgoing" '{version:1,home:$home,destination:$destination,model:$model,nonce:$nonce,outgoingPid:$outgoing,phase:"prepared"}' > "$temporary"
    mv -f "$temporary" "$record"
    printf 'prepared Claude %s handover; exit leader pid %s normally, then run FM_HOME=%q %q activate from a separate shell\n' "$destination" "$outgoing" "$home" "$SCRIPT_DIR/fm-t3-leader.sh"
    ;;
  activate)
    read_record
    [ "$(jq -r '.phase' "$record")" = prepared ] || die 'handover is not prepared; an attempted launch must be reconciled, never retried'
    check_departed
    destination=$(jq -r '.destination' "$record")
    model=$(jq -r '.model' "$record")
    if [ "$destination" = t3 ]; then
      [ -f "$home/config/supervision-host-off" ] && [ ! -L "$home/config/supervision-host-off" ] || die 'forward handover requires explicit config/supervision-host-off; the supervision-host path is not verified in T3'
      fm_t3_bind_claude_home "$home" --dry-run || die 'Claude native home binding is unsafe'
    fi
    if [ "$dry" -eq 1 ]; then
      printf 'dry-run: activate Claude %s model=%s in %s; successor must acquire the normal session lock\n' "$destination" "$model" "$home"
      exit 0
    fi
    claim_record
    read_record
    [ "$(jq -r '.phase' "$record")" = prepared ] || die 'another activation already attempted launch'
    check_departed
    nonce=$(jq -r '.nonce' "$record")
    printf -v confirm_command 'FM_HOME=%q bash %q confirm %q' "$home" "$SCRIPT_DIR/fm-t3-leader.sh" "$nonce"
    printf -v startup_command 'FM_HOME=%q bash bin/fm-session-start.sh' "$home"
    prompt="Continue as Firstmate in $home using its durable records. Your native SessionStart hooks must acquire this home's normal session lock before you do any work. Verify that the startup digest names exactly $home as its Firstmate home; if it names another home, remain read-only and report the mismatch without touching either fleet. If startup reports a foreign lock, remain read-only and report it. If the startup digest is absent, run $startup_command exactly once and read it. After verified ownership in that exact home, run $confirm_command to confirm this deliberate handover, then resume the emitted supervision protocol."
    if [ "$destination" = t3 ]; then
      [ -n "${FM_T3_BASE_DIR:-}" ] || die 'FM_T3_BASE_DIR must name the running T3 data directory'
      base=$(cd "$FM_T3_BASE_DIR" && pwd -P) || die 'T3 base directory is unavailable'
      binary=$(command -v "${FM_T3_BIN:-t3}") || die 'T3 CLI is unavailable'
      binary=$(cd "$(dirname "$binary")" && printf '%s/%s' "$(pwd -P)" "$(basename "$binary")")
      fm_t3_bind_claude_home "$home" || die 'could not bind native hooks to the handover home'
      replace_record --arg binary "$binary" --arg base "$base" '. + {phase:"starting",binary:$binary,base:$base}'
      output="$state/.t3-leader-launch.$nonce.json"
      [ ! -e "$output" ] && [ ! -L "$output" ] || die 'previous T3 launch output exists; reconcile it before activation'
      "$binary" project add "$home" --title Firstmate --base-dir "$base" || die 'project registration failed; inspect the starting handover before retrying'
      cleanup
      locked=0
      (umask 077; set -C; printf '%s\n' "$prompt" | "$binary" thread start "$home" - --title 'Firstmate leader' --provider claudeAgent --model "$model" --base-dir "$base" --json > "$output") || die "thread launch failed or is uncertain; reconcile $output in T3"
      jq -e '(.threadId | type == "string" and length > 0) and (.projectId | type == "string" and length > 0)' "$output" >/dev/null || die 'unexpected launch result; reconcile T3 before retrying'
      claim_record
      replace_record --slurpfile launch "$output" '. + {threadId:$launch[0].threadId,projectId:$launch[0].projectId}'
      printf 'T3 leader launch attempted; run status and require phase=confirmed before treating handover as complete\n'
    else
      binary=$(command -v "${FM_T3_LEADER_CLAUDE_BIN:-claude}") || die 'Claude CLI is unavailable'
      binary=$(cd "$(dirname "$binary")" && printf '%s/%s' "$(pwd -P)" "$(basename "$binary")")
      replace_record '. + {phase:"starting"}'
      cleanup
      locked=0
      cd "$home"
      exec env -u CLAUDECODE -u CLAUDE_PID -u CLAUDE_CODE_SESSION_ID -u FM_TASK_ID -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE FM_HOME="$home" "$binary" --model "$model" "$prompt"
    fi
    ;;
  confirm)
    [ "$dry" -eq 0 ] || die 'confirm has no dry-run mode'
    claim_record
    read_record
    [ "$(jq -r '.phase' "$record")" = starting ] || die 'handover is not awaiting successor confirmation'
    [ "$(jq -r '.nonce' "$record")" = "$nonce" ] || die 'confirmation does not match this handover'
    fm_session_lock_owned_by_self "$state" || die 'only the lock-owning successor may confirm handover'
    successor=$(cat "$state/.lock")
    [ "$successor" != "$(jq -r '.outgoingPid' "$record")" ] || die 'outgoing leader cannot confirm its own handover'
    check_outgoing=$(jq -r '.outgoingPid' "$record")
    ! kill -0 "$check_outgoing" 2>/dev/null || die 'outgoing leader still exists'
    harness=$(FM_HOME="$home" "$SCRIPT_DIR/fm-harness.sh") || die 'cannot identify successor harness'
    [ "$harness" = claude ] || die 'only a Claude successor may confirm handover'
    replace_record --argjson successor "$successor" --arg session "$(fm_session_lock_recorded_session_id "$state" || true)" '. + {phase:"confirmed",successorPid:$successor,successorSession:$session}'
    printf 'handover confirmed: Claude successor pid %s owns %s\n' "$successor" "$home"
    ;;
esac
