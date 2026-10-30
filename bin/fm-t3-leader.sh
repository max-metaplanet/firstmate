#!/usr/bin/env bash
# fm-t3-leader.sh - automatic forward and attended reverse handover between a terminal and a Claude T3 leader.
#
# Usage (FM_HOME must explicitly name the independent Firstmate home):
#   fm-t3-leader.sh switch --to t3 --model MODEL --persisted [--dry-run]
#   fm-t3-leader.sh prepare --to t3 --model MODEL [--dry-run | --persisted]
#   fm-t3-leader.sh prepare --to terminal --model MODEL [--dry-run | --persisted]
#   fm-t3-leader.sh activate [--dry-run]
#   fm-t3-leader.sh confirm NONCE
#   fm-t3-leader.sh status
#
# Switch runs inside the current Claude terminal leader in tmux. Persist open
# records, then switch --to t3 --model MODEL --persisted: it returns immediately
# and a detached completion stops only the recorded PID after a 3-second grace,
# waits for exit, activates T3, and waits up to 120 seconds for confirmation.
# No exit command or separate terminal is needed. The original tmux pane,
# trusted Claude session id, binary and profile are saved before scheduling.
# Failure resumes that session in the original pane if the lock is free/stale;
# a live/unknown owner is never displaced. Recovery diagnostics and the exact
# manual command are retained in the record and state/.t3-leader-auto.log.
# Prepare/activate remain available for attended reverse handover. Activation
# refuses a live outgoing PID and a live/unknown lock owner. No lock is deleted.
# Uncertain T3 launches are never retried. The persistent record is
# state/.t3-leader-handover.json; completion success requires phase=confirmed.
# FM_T3_LEADER_DELAY (default 3), FM_T3_LEADER_EXIT_TIMEOUT (default 30), and
# FM_T3_LEADER_CONFIRM_TIMEOUT (default 120) are positive integer seconds.
# A confirmed or restored record may be replaced by the next prepare. Dry-run never writes
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
if [ "$verb" = confirm ] || [ "$verb" = complete ]; then
  [ "$#" -eq 1 ] || die 'confirm/complete requires exactly one nonce'
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
  prepare|switch) ;;
  activate|status|confirm|complete)
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
  switch)
    [ "$destination" = t3 ] || die 'automatic switch supports terminal-to-T3 only'
    fm_session_lock_owned_by_self "$state" || die 'switch must run in the current lock-owning leader'
    [ "$("$SCRIPT_DIR/fm-harness.sh")" = claude ] || die 'automatic switch supports Claude only'
    session=$(fm_session_lock_trusted_session_id) || die 'cannot prove the outgoing Claude session id'
    pane=$(fm_session_lock_runtime_field "$state" target) || die 'original terminal pane is not recorded'
    [ "$(fm_session_lock_runtime_field "$state" backend)" = tmux ] || die 'automatic recovery requires the original tmux pane'
    tmux display-message -p -t "$pane" '#{pane_id}' >/dev/null || die 'original tmux pane is unavailable'
    claude=$(command -v "${FM_T3_LEADER_CLAUDE_BIN:-claude}") || die 'Claude CLI is unavailable for recovery'
    [ -f "$home/config/supervision-host-off" ] || die 'forward handover requires config/supervision-host-off'
    [ -d "${FM_T3_BASE_DIR:-}" ] || die 'FM_T3_BASE_DIR is unavailable'
    command -v "${FM_T3_BIN:-t3}" >/dev/null || die 'T3 CLI is unavailable'
    command -v node >/dev/null || die 'Node is required to detach automatic completion'
    fm_t3_bind_claude_home "$home" --dry-run || die 'Claude native home binding is unsafe'
    for seconds in "${FM_T3_LEADER_DELAY:-3}" "${FM_T3_LEADER_EXIT_TIMEOUT:-30}" "${FM_T3_LEADER_CONFIRM_TIMEOUT:-120}"; do
      case "$seconds" in ''|*[!0-9]*|0*) die 'handover timeouts must be positive integers' ;; esac
    done
    if [ "$dry" -eq 1 ]; then
      bash "$SCRIPT_DIR/fm-t3-leader.sh" prepare --to t3 --model "$model" --dry-run
      printf 'dry-run: schedule automatic stop, activation, confirmation and recovery in tmux pane %s\n' "$pane"
      exit 0
    fi
    [ "$persisted" -eq 1 ] || die "before handover, $FM_PERSIST_OPEN_RECORDS_CONTRACT Then switch with --persisted"
    bash "$SCRIPT_DIR/fm-t3-leader.sh" prepare --to t3 --model "$model" --persisted
    claim_record
    read_record
    printf -v resume 'cd %q && exec env -u CLAUDECODE -u CLAUDE_PID -u CLAUDE_CODE_SESSION_ID FM_HOME=%q CLAUDE_CONFIG_DIR=%q %q --resume %q %q' \
      "$home" "$home" "${CLAUDE_CONFIG_DIR:-}" "$claude" "$session" 'The automatic T3 handover failed. Resume Firstmate from durable records; verify normal session lock ownership and report the handover record before supervising.'
    replace_record --arg pane "$pane" --arg session "$session" --arg resume "$resume" '. + {automatic:true,pane:$pane,outgoingSession:$session,resumeCommand:$resume}'
    nonce=$(jq -r .nonce "$record")
    cleanup
    locked=0
    completion=$(node -e '
      const fs = require("node:fs");
      const { spawn } = require("node:child_process");
      const log = fs.openSync(process.argv[3], "a", 0o600);
      const child = spawn("bash", [process.argv[1], "complete", process.argv[2]], {
        detached: true, stdio: ["ignore", log, log]
      });
      child.on("error", error => { console.error(error.message); process.exitCode = 1; });
      child.unref();
      console.log(child.pid);
    ' "$SCRIPT_DIR/fm-t3-leader.sh" "$nonce" "$state/.t3-leader-auto.log") || die 'could not detach completion; outgoing leader remains running'
    printf 'automatic handover scheduled (completion pid %s); end this turn; no further typing required\n' "$completion"
    ;;
  complete)
    [ "$dry" -eq 0 ] || die 'complete has no dry-run mode'
    read_record
    jq -e --arg nonce "$nonce" '.automatic == true and .phase == "prepared" and .nonce == $nonce' "$record" >/dev/null || die 'no matching automatic handover'
    # Serialize completion itself, independently of activate/confirm record edits.
    fm_lock_try_acquire "$state/.t3-leader-completion.lock" || die 'automatic completion already running'
    recover=0
    finish_automatic() {
      local result=$? phase pane resume deadline restored_pid
      trap - EXIT
      cleanup
      locked=0
      if [ "$recover" -eq 1 ]; then
        claim_record
        phase=$(jq -r .phase "$record")
        if [ "$phase" != confirmed ]; then
          pane=$(jq -r .pane "$record")
          resume=$(jq -r .resumeCommand "$record")
          fm_session_lock_inspect "$state"
          replace_record --arg command "$resume" '. + {phase:"recovery-needed",recoveryCommand:$command}'
          case "$FM_LOCK_INSPECT_STATE" in
            free|stale)
              if tmux respawn-pane -k -t "$pane" "$resume"; then
                replace_record '.phase="restoring"'
                deadline=$((SECONDS + ${FM_T3_LEADER_CONFIRM_TIMEOUT:-120}))
                while [ "$SECONDS" -lt "$deadline" ]; do
                  restored_pid=$(cat "$state/.lock" 2>/dev/null || true)
                  if [ "$(fm_session_lock_recorded_session_id "$state" || true)" = "$(jq -r .outgoingSession "$record")" ] \
                    && fm_harness_pid_alive "$restored_pid"; then
                    replace_record --argjson pid "$restored_pid" '. + {phase:"restored",restoredPid:$pid}'
                    printf 'outgoing Claude session restored in original pane %s (pid %s)\n' "$pane" "$restored_pid"
                    break
                  fi
                  sleep 1
                done
                if [ "$(jq -r .phase "$record")" != restored ]; then
                  replace_record '.phase="recovery-needed"'
                  printf 'resume did not reclaim the lock; in original pane %s run: %s\n' "$pane" "$resume" >&2
                fi
              else
                printf 'automatic recovery failed; in original pane %s run: %s\n' "$pane" "$resume" >&2
              fi
              ;;
            *) printf 'recovery left lock owner untouched (lock=%s pid=%s); once free, in pane %s run: %s\n' "$FM_LOCK_INSPECT_STATE" "$FM_LOCK_INSPECT_PID" "$pane" "$resume" >&2 ;;
          esac
        fi
      fi
      cleanup
      fm_lock_release "$state/.t3-leader-completion.lock"
      exit "$result"
    }
    trap finish_automatic EXIT
    trap 'exit 1' HUP INT TERM
    sleep "${FM_T3_LEADER_DELAY:-3}"
    outgoing=$(jq -r .outgoingPid "$record")
    if [ "$(cat "$state/.lock")" != "$outgoing" ] || ! fm_harness_pid_alive "$outgoing"; then
      die 'recorded outgoing leader no longer owns the lock; nothing stopped'
    fi
    recover=1
    kill -TERM "$outgoing" || die 'could not stop outgoing leader'
    deadline=$((SECONDS + ${FM_T3_LEADER_EXIT_TIMEOUT:-30}))
    while kill -0 "$outgoing" 2>/dev/null; do
      [ "$SECONDS" -lt "$deadline" ] || die 'outgoing leader did not exit; no replacement launched'
      sleep 1
    done
    # shellcheck source=bin/fm-timeout-lib.sh
    . "$SCRIPT_DIR/fm-timeout-lib.sh"
    fm_run_timed "${FM_T3_LEADER_CONFIRM_TIMEOUT:-120}" bash "$SCRIPT_DIR/fm-t3-leader.sh" activate || die 'T3 activation failed; restoring outgoing session when safe'
    deadline=$((SECONDS + ${FM_T3_LEADER_CONFIRM_TIMEOUT:-120}))
    while [ "$(jq -r .phase "$record")" != confirmed ]; do
      [ "$SECONDS" -lt "$deadline" ] || die 'successor did not confirm; restoring outgoing session when safe'
      sleep 1
    done
    printf 'automatic handover confirmed\n'
    ;;
  prepare)
    case "$destination" in t3|terminal) ;; *) die '--to must be t3 or terminal; only Claude leaders are supported' ;; esac
    [ -n "$model" ] || die '--model must name an advertised Claude model'
    fm_session_lock_owned_by_self "$state" || die 'prepare must run in the current lock-owning leader'
    if [ -f "$record" ] && ! jq -e '.phase == "confirmed" or .phase == "restored"' "$record" >/dev/null; then
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
    if [ -f "$record" ] && ! jq -e '.phase == "confirmed" or .phase == "restored"' "$record" >/dev/null; then
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
    printf -v startup_command 'FM_HOME=%q FM_T3_LEADER_HANDOVER=%q bash bin/fm-session-start.sh' "$home" "$nonce"
    prompt="Continue as Firstmate in $home using its durable records. Your native SessionStart hooks must acquire this home's normal session lock before you do any work. Verify that the startup digest names exactly $home as its Firstmate home; if it names another home, remain read-only and report the mismatch without touching either fleet. If startup reports a foreign lock, remain read-only and report it. If the startup digest is absent or reports T3 VIEW-ONLY, run $startup_command exactly once and read it. This nonce authorizes only this deliberate Claude leader transition. After verified ownership in that exact home, run $confirm_command to confirm this deliberate handover, then resume the emitted supervision protocol."
    if [ "$destination" = t3 ]; then
      [ -n "${FM_T3_BASE_DIR:-}" ] || die 'FM_T3_BASE_DIR must name the running T3 data directory'
      base=$(cd "$FM_T3_BASE_DIR" && pwd -P) || die 'T3 base directory is unavailable'
      binary=$(command -v "${FM_T3_BIN:-t3}") || die 'T3 CLI is unavailable'
      binary=$(cd "$(dirname "$binary")" && printf '%s/%s' "$(pwd -P)" "$(basename "$binary")")
      fm_t3_bind_claude_home "$home" || die 'could not bind native hooks to the handover home'
      replace_record --arg binary "$binary" --arg base "$base" '. + {phase:"starting",binary:$binary,base:$base}'
      output="$state/.t3-leader-launch.$nonce.json"
      [ ! -e "$output" ] && [ ! -L "$output" ] || die 'previous T3 launch output exists; reconcile it before activation'
      project_output="$state/.t3-leader-project.$nonce.txt"
      if ! "$binary" project add "$home" --title Firstmate --base-dir "$base" > "$project_output" 2>&1; then
        # T3 resolves thread start by the exact workspace path. Only this typed
        # duplicate-project error permits reuse; all other failures stay fatal.
        if ! grep -F 'ProjectAlreadyExistsError' "$project_output" >/dev/null \
          || ! grep -F "An active project already exists for '$home'" "$project_output" >/dev/null; then
          die "project registration failed; inspect $project_output"
        fi
        printf 'reusing existing T3 project at %s\n' "$home"
      fi
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
