#!/usr/bin/env bash
# Park a registered local secondmate without removing its home or records.
# Usage: FM_HOME=<parent> fm-secondmate-park.sh <id> park|unpark
#
# park asks the existing correlated open-record persist gate, refuses without
# its answer, then stops the agent through fm-control exit and stops its home
# supervision host and watcher. Any child metadata, in-flight backlog work, or
# outstanding incoming instruction refuses parking. unpark uses fm-spawn's
# relaunch or missing-endpoint secondmate respawn path and is also fm-send's automatic wake path; fm-crew-state
# shows the parked state. Exact session resume uses the existing recorded reference
# when available, otherwise output explicitly reports a fresh session.
# Remote homes are unsupported and refuse before mutation.
#
# Parent state/.secondmate-park-<id> is the durable authority, published by
# rename under the same per-mate lock as liveness. Fields: schema=1, home,
# phase=preparing|parking|parked|waking, persist_corr, persisted=0|1,
# resume_mode=fresh|exact, resume_harness, resume_ref, spawn_gen. Any record suppresses
# liveness recovery; parking/parked suppress the child's supervision startup.
# A failed persist removes preparing; failures after confirmation retain the
# record so liveness cannot undo a partial park. Retry park to finish a stop.
# A failed wake preserves the parked record and every inbox message. Lifecycle
# outcomes are parent-channel check wakes. Commands never retire registration.
# FM_SECONDMATE_PERSIST_WAIT (900) and FM_SECONDMATE_PERSIST_POLL (5) have the
# same meanings as fm-secondmate-restart. Work arriving during park is durably
# queued before fm-send waits for this lock, then wakes and rings the inbox.
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
case "${1:-}" in -h|--help) sed -n '2,/^set -u/{ /^set -u/d; s/^# \{0,1\}//; p; }' "$0"; exit 0 ;; esac
ID=${1:-} ACTION=${2:-}
case "$ID" in ''|*[!A-Za-z0-9._-]*) echo 'error: an exact secondmate id is required' >&2; exit 2 ;; esac
case "$ACTION:$#" in park:2|unpark:2) ;; *) echo 'usage: fm-secondmate-park.sh <id> park | unpark' >&2; exit 2 ;; esac
[ -n "${FM_HOME:-}" ] && [ -d "$FM_HOME" ] || { echo 'error: explicit FM_HOME is required' >&2; exit 1; }
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# The child's binding names parent/state, so a different state directory would
# hide the authority from that child. Refuse rather than creating split state.
[ "$STATE" = "$FM_HOME/state" ] || { echo 'error: park requires the parent home state directory' >&2; exit 1; }
# shellcheck source=bin/fm-secondmate-liveness-lib.sh
. "$SCRIPT_DIR/fm-secondmate-liveness-lib.sh"
# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"
# shellcheck source=bin/fm-secondmate-park-lib.sh
. "$SCRIPT_DIR/fm-secondmate-park-lib.sh"
# shellcheck source=bin/fm-secondmate-restart-lib.sh
. "$SCRIPT_DIR/fm-secondmate-restart-lib.sh"
# shellcheck source=bin/fm-secondmate-resume-lib.sh
. "$SCRIPT_DIR/fm-secondmate-resume-lib.sh"
# shellcheck source=bin/fm-pending-reply-lib.sh
. "$SCRIPT_DIR/fm-pending-reply-lib.sh"
# shellcheck source=bin/fm-tasks-axi-lib.sh
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-backlog-transition-lib.sh
. "$SCRIPT_DIR/fm-backlog-transition-lib.sh"
# shellcheck source=bin/fm-task-inbox-lib.sh
. "$SCRIPT_DIR/fm-task-inbox-lib.sh"
fail() { echo "error: $*" >&2; exit 1; }
META="$STATE/$ID.meta"
RECORD="$STATE/.secondmate-park-$ID"
validate_identity() {
  secondmate_registry_line_for_id "$FM_HOME/data/secondmates.md" "$ID" || fail "no unique registered secondmate $ID"
  [ "$SECONDMATE_REGISTRY_REMOTE" = 0 ] && [ -z "$(fm_meta_get "$META" remote_host)" ] || fail 'remote secondmate parking is unsupported'
  [ "$(fm_meta_get "$META" kind)" = secondmate ] || fail 'metadata is not a secondmate'
  MATE_HOME=$SECONDMATE_REGISTRY_HOME
  [ -d "$MATE_HOME" ] && [ ! -L "$MATE_HOME" ] || fail 'secondmate home is missing or symlinked'
  [ "$(fm_meta_get "$META" home)" = "$MATE_HOME" ] && [ "$(fm_meta_get "$META" worktree)" = "$MATE_HOME" ] || fail 'registered home disagrees with metadata'
  [ "$(cat "$MATE_HOME/.fm-secondmate-home" 2>/dev/null)" = "$ID" ] || fail 'secondmate home identity does not match'
  fm_secondmate_parent_record_parse "$MATE_HOME/.fm-secondmate-parent" || fail 'secondmate parent binding is invalid'
  [ "$FM_SECONDMATE_PARENT_ROUTE" = local ] && [ "$FM_SECONDMATE_PARENT_HOME" = "$FM_HOME" ] || fail 'secondmate belongs to another parent'
}
validate_identity
fm_sm_live_require_locks
fm_lock_acquire_wait "$STATE/.secondmate-liveness-$ID.lock"
CHILD_SET_LOCK=''
OWN_PREPARING=0
cleanup() {
  # Only our unconfirmed preparation is safe to roll back: nothing stopped.
  if [ "$OWN_PREPARING" = 1 ] && [ "${PERSISTED:-0}" = 0 ]; then
    rm -f "$RECORD"
  fi
  [ -z "$CHILD_SET_LOCK" ] || fm_lock_release "$CHILD_SET_LOCK"
  fm_secondmate_liveness_unlock "$ID"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
validate_identity
PERSISTED=0 CORR='' MODE=fresh RESUME_HARNESS='' REF=''
SPAWN_GEN=$(fm_meta_get "$META" spawn_gen)
write_record() { # <phase>
  local tmp
  tmp=$(mktemp "$RECORD.XXXXXX") || return 1
  { printf 'schema=1\nhome=%s\nphase=%s\npersist_corr=%s\npersisted=%s\nresume_mode=%s\nresume_harness=%s\nresume_ref=%s\nspawn_gen=%s\n' \
    "$MATE_HOME" "$1" "$CORR" "$PERSISTED" "$MODE" "$RESUME_HARNESS" "$REF" "$SPAWN_GEN" > "$tmp" && mv -f "$tmp" "$RECORD"; } || { rm -f "$tmp"; return 1; }
}
report() { # <outcome>
  printf '%s: %s; session=%s\n' "$ID" "$1" "$MODE"
  fm_wake_append check "secondmate-park-$ID" "check: secondmate $ID $1 (session=$MODE)" || return 1
}
read_record() {
  [ -f "$RECORD" ] && [ ! -L "$RECORD" ] || fail 'park record is not an ordinary file'
  [ "$(fm_meta_get "$RECORD" schema)" = 1 ] && [ "$(fm_meta_get "$RECORD" home)" = "$MATE_HOME" ] || fail 'park record identity is invalid'
  PERSISTED=$(fm_meta_get "$RECORD" persisted)
  CORR=$(fm_meta_get "$RECORD" persist_corr)
  MODE=$(fm_meta_get "$RECORD" resume_mode)
  RESUME_HARNESS=$(fm_meta_get "$RECORD" resume_harness)
  REF=$(fm_meta_get "$RECORD" resume_ref)
  SPAWN_GEN=$(fm_meta_get "$RECORD" spawn_gen)
}
check_idle() {
  local child pending backend listing
  for child in "$MATE_HOME/state"/*.meta; do
    [ ! -e "$child" ] || { echo "error: secondmate has outstanding child work: $child" >&2; return 1; }
  done
  backend=$(fm_tasks_axi_backend "$MATE_HOME") || return 1
  if [ "$backend" != markdown ] || [ -e "$MATE_HOME/data/backlog.md" ]; then
    listing=$(fm_backlog_row_list "$MATE_HOME/data" --state in_flight) || { echo 'error: cannot prove secondmate backlog idle' >&2; return 1; }
    printf '%s\n' "$listing" | grep -q '^count: 0$' || { echo 'error: secondmate backlog has in-flight work or unreadable listing' >&2; return 1; }
  fi
  [ "${1:-}" != after-persist ] || return 0
  pending=$(fm_task_inbox_oldest_unhandled "$STATE" "$ID" 2>/dev/null) || pending=''
  [ -z "$pending" ] || { echo "error: secondmate has an incoming instruction: $pending" >&2; return 1; }
}
ring_pending() {
  local pending
  pending=$(fm_task_inbox_oldest_unhandled "$STATE" "$ID" 2>/dev/null) || pending=''
  if [ -n "$pending" ]; then
    fm_task_inbox_ring "$(fm_backend_of_meta "$META")" "$(fm_backend_target_of_meta "$META")" "$pending" "fm-$ID" || true
  fi
}
if [ "$ACTION" = unpark ]; then
  if ! fm_secondmate_park_present "$STATE" "$ID"; then printf '%s: already unparked\n' "$ID"; exit 0; fi
  read_record
  if [ "$(fm_meta_get "$RECORD" phase)" = preparing ] && [ "$PERSISTED" = 0 ]; then
    # Acquiring the park lock proves the previous preparation no longer owns
    # it. It never stopped the mate; restore normal delivery, including after
    # SIGKILL or a parent restart where an EXIT trap could not run.
    rm -f "$RECORD" || fail 'cannot clear interrupted persist preparation'
    report 'interrupted park cancelled; normal delivery restored' || exit 1
    ring_pending
    exit 0
  fi
  [ "$PERSISTED" = 1 ] || fail 'park persistence was not confirmed; retry park before waking'
  if [ "$(fm_meta_get "$RECORD" phase)" = waking ]; then
    current_state=$(fm_backend_agent_state "$(fm_backend_of_meta "$META")" "$(fm_backend_target_of_meta "$META")") || current_state=unreadable
    current_gen=$(fm_meta_get "$META" spawn_gen)
    if [ "$current_state" = alive ] && [ -n "$current_gen" ] && [ "$current_gen" != "$SPAWN_GEN" ]; then
      rm -f "$RECORD" || fail 'cannot clear completed wake'
      report "$ACTION reconciled after interrupted wake"
      exit $?
    fi
    case "$current_state" in dead|missing) write_record parked || fail 'cannot retry wake' ;; *) fail "interrupted wake has endpoint state $current_state; keep inbox and reconcile before retry" ;; esac
  fi
  [ "$(fm_meta_get "$RECORD" phase)" = parked ] || fail 'park did not finish; retry park to finish stopping before waking'
  write_record waking || fail 'cannot record wake'
  backend=$(fm_backend_of_meta "$META")
  current_state=$(fm_backend_agent_state "$backend" "$(fm_backend_target_of_meta "$META")") || current_state=unreadable
  case "$current_state" in
    dead) spawn_args=("$ID" --relaunch) ;;
    missing) spawn_args=("$ID" "$MATE_HOME" --secondmate --backend "$backend" --harness "$RESUME_HARNESS") ;;
    *) fail "parked endpoint state is $current_state; refusing duplicate launch" ;;
  esac
  if "$SCRIPT_DIR/fm-spawn.sh" "${spawn_args[@]}"; then
    rm -f "$RECORD" || fail 'agent launched but park record could not be cleared'
    report "$ACTION complete" || exit 1
    # An explicit unpark also delivers already queued work, including work whose
    # earlier automatic wake failed. No record is removed or rewritten here.
    ring_pending
    exit 0
  fi
  write_record parked || true
  report 'wake failed; still parked, inbox preserved' || true
  exit 1
fi
CHILD_SET_LOCK=$(fm_task_set_lock_path "$MATE_HOME/state") || fail 'cannot resolve child task set lock'
fm_lock_try_acquire "$CHILD_SET_LOCK" || { CHILD_SET_LOCK=''; fail 'child task publication is in progress; retry park'; }
if fm_secondmate_park_present "$STATE" "$ID"; then
  read_record
  if [ "$(fm_meta_get "$RECORD" phase)" = parked ]; then report 'already parked'; exit $?; fi
  [ "$(fm_meta_get "$RECORD" phase)" != waking ] || fail 'wake was interrupted; run unpark to reconcile it before parking again'
  [ "$PERSISTED" = 1 ] || { rm -f "$RECORD" || fail 'cannot clear interrupted persist preparation'; }
fi
if [ "$PERSISTED" != 1 ]; then
  check_idle || exit 1
  fm_secondmate_restart_capable "$META" || fail "$FM_SECONDMATE_RESTART_REASON"
  WAIT=${FM_SECONDMATE_PERSIST_WAIT:-900} POLL=${FM_SECONDMATE_PERSIST_POLL:-5}
  case "$WAIT" in ''|*[!0-9]*) fail 'invalid persist wait' ;; esac
  case "$POLL" in ''|0|*[!0-9]*) fail 'invalid persist poll' ;; esac
  REQUEST="I am about to park your agent. Before that, $FM_PERSIST_OPEN_RECORDS_CONTRACT Then acknowledge this instruction in your durable inbox and reply on your parent channel saying it is done, or saying what you deliberately left alone and why."
  CORR=$(fm_pending_reply_create "$FM_HOME" "$STATE" "$ID" "$REQUEST") || fail 'cannot track persist answer'
  OWN_PREPARING=1
  write_record preparing || fail 'cannot record persist preparation'
  if ! FM_PENDING_REPLY_EXISTING_CORR="$CORR" "$SCRIPT_DIR/fm-send.sh" "$ID" "$REQUEST"; then
    rm -f "$RECORD"
    fm_pending_reply_discard_undelivered "$STATE" "$CORR" || true
    fail 'persist request delivery failed; agent was not stopped'
  fi
  deadline=$(($(date +%s) + WAIT))
  until fm_pending_reply_try_resolve "$STATE" "$CORR"; do
    if [ "$(date +%s)" -ge "$deadline" ]; then
      rm -f "$RECORD"
      report 'park refused: persist answer missing; agent left running' || true
      exit 1
    fi
    sleep "$POLL"
  done
  # Recheck child work after the mate wrote its durable records. New parent
  # inbox work is intentionally deferred and will wake it after this lock.
  if ! check_idle after-persist; then rm -f "$RECORD"; exit 1; fi
  fm_secondmate_resume_capture "$META" || fail 'cannot capture resume disposition'
  MODE=$FM_SECONDMATE_RESUME_MODE RESUME_HARNESS=$FM_SECONDMATE_RESUME_HARNESS REF=$FM_SECONDMATE_RESUME_REF
  PERSISTED=1
fi
write_record parking || fail 'cannot record parking'
if ! "$SCRIPT_DIR/fm-control.sh" "$ID" exit; then report 'park incomplete: agent stop failed; retry park' || true; exit 1; fi
if ! FM_HOME="$MATE_HOME" FM_STATE_OVERRIDE="$MATE_HOME/state" FM_CONFIG_OVERRIDE="$MATE_HOME/config" \
  "$SCRIPT_DIR/fm-supervision-host.sh" --stop; then report 'park incomplete: supervision stop failed; retry park' || true; exit 1; fi
write_record parked || fail 'cannot record completed park'
report parked
