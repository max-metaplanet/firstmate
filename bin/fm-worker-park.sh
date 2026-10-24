#!/usr/bin/env bash
# Park external-wait workers without discarding their work or merge watch.
# Usage: fm-worker-park.sh auto <id>
#        fm-worker-park.sh park <id> <reason> [until-epoch]
#        fm-worker-park.sh record-exited <id> <reason> [until-epoch]
#        fm-worker-park.sh wake <id> <reason>
#        fm-worker-park.sh request <id> <reason> [failing-check-set]
#        fm-worker-park.sh hint <id> <external-wait-reason>
#        fm-worker-park.sh tick
#        fm-worker-park.sh status  # read-only JSON capacity observation
#
# fm-worker-park-lib.sh owns the record and queue format. All record writes
# serialize on state/.worker-park-<id>.lock. Park always uses fm-control exit;
# record-exited adopts a hand-exited worker only after the same verified exit.
# Dirty/unreadable worktrees, open decisions and live/unreadable validation
# state refuse parking. No teardown, merge, push or quota action is performed.
# auto recognizes registered ready PRs with yolo=off and paused declarations
# naming upstream/maintainer, merge bot/queue, captain review/merge, or CI-only
# waits. Other paused waits need an until farther away than the threshold in
# config/worker-park-minutes (positive integer, default 10). External waits may
# also name until; its expiry and changed/resolved status queue a resume.
# tick is driven by the existing watcher, never a separate polling daemon.
# Contribution feedback and fm-send steering call request, because their
# callers may hold locks the relaunch needs; wake durably queues, then resumes
# at once. A request may name the canonical set of red check identities the
# observer saw; an identical set already recorded on the parked worker queues
# nothing, because that worker has acted on exactly those red lanes already.
# A set that differs, is absent, or cannot be recognized queues as before.
# tick retries deferred resumes and wakes parked workers with pending inbox
# steering. fm-spawn owns both capacity checks and priority
# admission. Exit 75 means deferred, not failed: the request is queued, or the
# record was busy and the caller retries from its own durable source.
set -uo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
FM_HOME=${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}
export FM_HOME
CONFIG=${FM_CONFIG_OVERRIDE:-$FM_HOME/config}
[ "${1:-}" != status ] || FM_WAKE_READ_ONLY=1
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-worker-park-lib.sh
. "$SCRIPT_DIR/fm-worker-park-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-nm-run-lib.sh
. "$SCRIPT_DIR/fm-nm-run-lib.sh"
# shellcheck source=bin/fm-busy-lib.sh
. "$SCRIPT_DIR/fm-busy-lib.sh"
# shellcheck source=bin/fm-project-capacity-lib.sh
. "$SCRIPT_DIR/fm-project-capacity-lib.sh"
# shellcheck source=bin/fm-fleet-capacity-lib.sh
. "$SCRIPT_DIR/fm-fleet-capacity-lib.sh"
# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"

fail() { printf 'worker-park: %s\n' "$*" >&2; exit 1; }
VERB=${1:-}; ID=${2:-}
FAILING_CHECKS=''
case "$VERB" in
  -h|--help) sed -n '2,/^set /{ /^#/s/^# \{0,1\}//p; }' "$0"; exit 0 ;;
  auto|park|record-exited|wake|request|hint)
    case "$ID" in ''|*[!A-Za-z0-9._-]*|.*) fail 'an exact task id is required' ;; esac
    case "$VERB/${4:-}" in request/*$'\n'*|request/*$'\r'*) fail 'the failing-check set must be one line' ;; esac ;;
  tick|status) ;;
  *) fail 'expected auto, park, record-exited, wake or tick' ;;
esac

write_record() { # phase reason until queued_at wake_reason status_line [resume_error]
  # FAILING_CHECKS rides every write, so a recorded red set survives the
  # resume and the next park rather than resetting each cycle.
  local staged generation endpoint
  generation=$(fm_meta_get "$META" spawn_gen)
  endpoint=$(fm_backend_target_of_meta "$META")
  [ -n "$endpoint" ] || return 1
  staged=$(mktemp "$STATE/.$ID.park.XXXXXX") || return 1
  { printf 'phase=%s\ngeneration=%s\nendpoint=%s\nreason=%s\nuntil=%s\nqueued_at=%s\nwake_reason=%s\nstatus_line=%s\nresume_error=%s\nfailing_checks=%s\n' \
      "$1" "${generation:-legacy}" "$endpoint" "$2" "$3" "$4" "$5" "$6" "${7:-0}" "$FAILING_CHECKS"; } > "$staged" &&
    chmod 600 "$staged" && mv "$staged" "$RECORD"
  local rc=$?
  rm -f "$staged"
  return "$rc"
}

safe_to_park() {
  local wt dirty probe run_status busy backend endpoint harness
  backend=$(fm_backend_of_meta "$META")
  endpoint=$(fm_backend_target_of_meta "$META")
  harness=$(fm_meta_get "$META" harness)
  busy=$(fm_busy_classify "$backend" "$endpoint" "$harness" "$ID" "$STATE" 2>/dev/null) || busy=unknown
  if [ "$VERB" = record-exited ]; then
    [ "$(fm_backend_agent_state "$backend" "$endpoint" 2>/dev/null)" = dead ] || return 1
  else
    case "$busy" in
      idle\ *) ;;
      busy\ *) return 1 ;;
      *)
        # Marker-only adapters have no semantic idle hook. A completed turn
        # newer than the declaration is the existing positive completion signal.
        [ -f "$STATE/$ID.turn-ended" ] && [ "$STATE/$ID.turn-ended" -nt "$STATE/$ID.status" ] || return 1 ;;
    esac
  fi
  [ -z "$(find "$STATE/$ID.inbox" -maxdepth 1 -name '*.msg' -print 2>/dev/null)" ] || return 1
  case "$(fm_meta_get "$META" kind)" in ship|scout) ;; *) return 1 ;; esac
  [ -f "$STATE/$ID.status" ] && [ -r "$STATE/$ID.status" ] && [ ! -L "$STATE/$ID.status" ] || return 1
  [ -z "$(status_own_open_decisions "$STATE/$ID.status")" ] || return 1
  wt=$(fm_meta_get "$META" worktree)
  [ -d "$wt" ] || return 1
  dirty=$(git -C "$wt" status --porcelain --untracked-files=normal 2>/dev/null) || return 1
  [ -z "$dirty" ] || return 1
  if [ "$(fm_meta_get "$META" mode)" = no-mistakes ]; then
    probe=$(fm_nm_run_checked "$wt" 15 axi status) || return 1
    run_status=$(fm_nm_strip_quotes "$(fm_nm_field "$probe" status)")
    case "$run_status" in
      completed|failed|cancelled) ;;
      '') printf '%s' "$probe" | grep -Eq '^runs_on_current_branch: 0$|no active run|no run|run: null' || return 1 ;;
      *)
        # no-mistakes may retain its merge monitor after the CI-ready return.
        # crew-state owns that distinction from executing validation.
        probe=$("$SCRIPT_DIR/fm-crew-state.sh" "$ID" 2>/dev/null) || return 1
        case "$probe" in 'state: done '* ) ;; *) return 1 ;; esac ;;
    esac
  fi
}

park() {
  local reason=$1 until=${2:-0} line
  case "$until" in ''|*[!0-9]*) fail 'until must be epoch seconds' ;; esac
  fm_worker_park_load "$META" && return 0
  if ! safe_to_park; then
    case "$VERB" in park|record-exited) printf 'worker-park: %s is not safe to park\n' "$ID" >&2; return 1 ;; esac
    return 0
  fi
  line=$(status_current_line "$STATE/$ID.status" '')
  write_record parking "$reason" "$until" 0 '' "$line" || return 1
  if "$SCRIPT_DIR/fm-control.sh" "$ID" exit; then
    write_record parked "$reason" "$until" 0 '' "$line" || return 1
    if [ -n "$(find "$STATE/$ID.inbox" -maxdepth 1 -name '*.msg' -print 2>/dev/null)" ] ||
      [ "$(status_current_line "$STATE/$ID.status" '')" != "$line" ]; then
      queue_wake 'steering or status arrived during verified exit' || return 1
    fi
    printf 'parked: %s waiting on %s\n' "$ID" "$reason"
  else
    # The attempted record is deliberately retained as parking. Capacity and
    # recovery still treat this agent as active until exit has been verified.
    return 1
  fi
}

auto() {
  local line verb pr yolo until=0 now minutes=10 lowered
  fm_worker_park_load "$META" && return 0
  line=$(status_current_line "$STATE/$ID.status" '')
  if [ "$(fm_meta_get "$RECORD" phase)" = active ] && [ "$(fm_meta_get "$RECORD" status_line)" = "$line" ]; then return 0; fi
  if [ "$(fm_meta_get "$RECORD" phase)" = hint ] && [ "$(fm_meta_get "$RECORD" status_line)" = "$line" ]; then
    park "$(fm_meta_get "$RECORD" reason)"
    return
  fi
  verb=$(status_line_verb "$line")
  pr=$(fm_meta_get "$META" pr)
  yolo=$(fm_meta_get "$META" yolo)
  if [ "$verb" = "done" ] && [ -n "$pr" ] && [ "$yolo" = off ] && [[ "$line" == *"PR $pr"* ]]; then
    park "merge approval for $pr"
    return
  fi
  [ "$verb" = paused ] || return 0
  now=$(date +%s)
  until=$(status_paused_until "$line") || until=0
  if [ -e "$CONFIG/worker-park-minutes" ]; then
    minutes=$(cat "$CONFIG/worker-park-minutes") || return 1
    case "$minutes" in ''|*[!0-9]*|0*|???????*) fail 'invalid config/worker-park-minutes' ;; esac
  fi
  lowered=$(printf '%s' "$line" | tr '[:upper:]' '[:lower:]')
  case "$lowered" in
    *upstream*maintainer*|*awaiting*maintainer*|*waiting*maintainer*|*merge*bot*|*merge*queue*|*captain*merge*|*captain*review*|*ci-only*|*waiting*' ci'*|*waiting*' checks'*)
      park "$line" "$until" ;;
    *) [ "$until" -le "$((now + minutes * 60))" ] || park "$line" "$until" ;;
  esac
}

# A parked worker was already relaunched for the red checks its record names
# and found nothing new to do there, so the same set earns no second slot and
# no second relaunch. A different, absent or unrecognized set still does.
failing_set_is_new() { # <canonical failing set, empty when the caller names none>
  [ -n "$1" ] || return 0
  fm_worker_park_load "$META" || return 0
  [ "$(fm_meta_get "$RECORD" failing_checks)" != "$1" ]
}

queue_wake() {
  if ! fm_worker_park_load "$META"; then
    if [ "$(fm_meta_get "$RECORD" phase)" = hint ]; then
      write_record active "$1" 0 0 '' "$(status_current_line "$STATE/$ID.status" '')"
    fi
    return 0
  fi
  local at=$FM_WORKER_PARK_QUEUED_AT error
  error=$(fm_meta_get "$RECORD" resume_error)
  [ "$VERB" != wake ] || error=0
  [ "$FM_WORKER_PARK_PHASE" = queued ] || at=$(date +%s)
  write_record queued "$FM_WORKER_PARK_REASON" "$FM_WORKER_PARK_UNTIL" "$at" "$1" \
    "$(fm_meta_get "$RECORD" status_line)" "${error:-0}"
}

resume() {
  local reason rc=0 failure_phase
  fm_worker_park_load "$META" || return 0
  [ "$FM_WORKER_PARK_PHASE" = queued ] || return 0
  [ "$(fm_meta_get "$RECORD" resume_error)" != 1 ] || return 0
  reason=$(fm_meta_get "$RECORD" wake_reason)
  "$SCRIPT_DIR/fm-control.sh" "$ID" relaunch --note "Automatically resumed from external wait. Reason: $reason. Read the durable instruction inbox before continuing." || rc=$?
  if [ "$rc" -ne 0 ] && [ "$rc" -ne 75 ]; then
    failure_phase=parking
    if fm_worker_park_load "$META"; then failure_phase=queued; fi
    write_record "$failure_phase" "$FM_WORKER_PARK_REASON" "$FM_WORKER_PARK_UNTIL" "$FM_WORKER_PARK_QUEUED_AT" "$reason" "$(fm_meta_get "$RECORD" status_line)" 1 || return 1
    fm_wake_append check "worker-resume-$ID" "check: parked worker $ID could not resume; work preserved; inspect fm-control and retry worker-park wake" || return 1
  fi
  [ "$rc" -ne 0 ] || write_record active "$FM_WORKER_PARK_REASON" 0 0 '' "$(fm_meta_get "$RECORD" status_line)"
  return "$rc"
}

one() {
  META="$STATE/$ID.meta"; RECORD="$STATE/$ID.park"
  [ -f "$META" ] && [ ! -L "$META" ] || return 0
  case "$VERB" in
    auto|tick|hint) [ -n "$(fm_backend_target_of_meta "$META")" ] || return 0 ;;
  esac
  local lock
  lock="$STATE/.worker-park-$ID.lock"
  if ! fm_lock_try_acquire "$lock"; then
    case "$VERB" in request|wake) return 75 ;; *) return 0 ;; esac
  fi
  case "${3:-}" in *$'\n'*|*$'\r'*) fail 'reason must be one line' ;; esac
  FAILING_CHECKS=$(fm_meta_get "$RECORD" failing_checks)
  case "$VERB" in
    auto) auto ;;
    park|record-exited) park "${3:-external wait}" "${4:-0}" ;;
    hint)
      if ! fm_worker_park_load "$META"; then
        local line
        line=$(status_current_line "$STATE/$ID.status" '')
        if [ "$(fm_meta_get "$RECORD" phase)" != active ] || [ "$(fm_meta_get "$RECORD" status_line)" != "$line" ]; then
          write_record hint "${3:-external wait}" 0 0 '' "$line"
        fi
      fi ;;
    request)
      if failing_set_is_new "${4:-}"; then
        [ -z "${4:-}" ] || FAILING_CHECKS=$4
        queue_wake "${3:-external wait cleared}"
      fi ;;
    wake) queue_wake "${3:-external wait cleared}" && resume ;;
    tick)
      if fm_worker_park_load "$META"; then
        if [ "$FM_WORKER_PARK_PHASE" = parked ]; then
          local line old
          line=$(status_current_line "$STATE/$ID.status" '')
          old=$(fm_meta_get "$RECORD" status_line)
          if [ -n "$(find "$STATE/$ID.inbox" -maxdepth 1 -name '*.msg' -print 2>/dev/null)" ]; then
            queue_wake 'steering waiting in the instruction inbox'
          elif [ "$line" != "$old" ]; then
            queue_wake "task status changed: $line"
          elif [ "$FM_WORKER_PARK_UNTIL" -gt 0 ] && [ "$(date +%s)" -ge "$FM_WORKER_PARK_UNTIL" ]; then
            queue_wake 'declared wait time reached'
          fi
        fi
        resume
      else
        auto
      fi ;;
  esac
  local rc=$?
  fm_lock_release "$lock" || return 1
  return "$rc"
}

if [ "$VERB" = status ]; then
  fm_fleet_capacity_observation "$FM_HOME" "$CONFIG" "$STATE"
elif [ "$VERB" = tick ]; then
  # Sampling/admission uses the shared root lock, released before relaunch.
  fm_fleet_load_tick "$FM_HOME" "$CONFIG" || exit 1
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    ID=${meta##*/}; ID=${ID%.meta}
    one || true
  done
else
  one "$@"
fi
