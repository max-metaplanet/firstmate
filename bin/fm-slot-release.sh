#!/usr/bin/env bash
# Release one task record's claim on a working copy that a second task record on
# this machine also names, so the pair stops deadlocking each other's cleanup.
# Usage: fm-slot-release.sh <task-id>
#
# WHY THIS EXISTS. bin/fm-teardown.sh refuses to return a pool slot that another
# task record names, because returning it would kill that task's processes and
# reset its copy. That refusal is symmetric: once two records name one copy,
# each is refused because of the other and no supported command breaks the pair
# (observed 2026-09-24, after a machine restart left a dead worker's record
# naming a slot Treehouse then reallocated). bin/fm-spawn.sh now refuses to
# create the pair in the first place; this command is the way out of one that
# already exists.
#
# WHAT IT WILL NOT DO. It never forces, never discards, and never touches the
# copy, the worker, or the pool. It adds one line - worktree_claim=released - to
# one task record, and only after every one of these holds:
#
#   - Another task record on this machine really does name the same copy. A
#     record that is merely stale is cleanup's job, not this command's.
#   - The copy's own slot-owner claim does not name THIS record. That claim is
#     positive proof of which task actually took the slot (bin/fm-wake-lib.sh),
#     so releasing the claimant would strand the slot; the refusal names the
#     other record to release instead. An unreadable claim proves nothing and
#     refuses too.
#   - The copy holds no uncommitted changes and no unlanded commits, judged by
#     the same test teardown uses (bin/fm-unlanded-work-lib.sh). Releasing is
#     what lets the OTHER record's teardown reset that copy, so the work has to
#     be provably safe to lose before this command will authorize that.
#   - The record is not a secondmate's. A secondmate home is retired through
#     secondmate-provisioning, never by un-naming it here.
#
# Afterwards the released record still records its copy PATH - bin/fm-backend.sh
# refuses to validate an endpoint without one, so removing it would only trade
# one wedge for another - but no longer claims it. Its own cleanup then takes the
# existing not-my-slot path: it kills nothing under that copy, inspects nothing
# in it, returns nothing to the pool, and removes only its own records. The other
# record's cleanup proceeds normally and returns the copy.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-lock-lib.sh
. "$SCRIPT_DIR/fm-lock-lib.sh"
# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-slot-record-lib.sh
. "$SCRIPT_DIR/fm-slot-record-lib.sh"
# shellcheck source=bin/fm-unlanded-work-lib.sh
. "$SCRIPT_DIR/fm-unlanded-work-lib.sh"

usage() {
  sed -n '2,4p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
  ''|-h|--help) usage; exit 2 ;;
esac
if [ "$#" -ne 1 ]; then
  echo "error: expected exactly one task id" >&2
  usage >&2
  exit 2
fi
ID=$1
case "$ID" in
  ''|*[!A-Za-z0-9._-]*|.|..) echo "error: invalid task id '$ID'" >&2; exit 2 ;;
esac

META="$STATE/$ID.meta"
[ -d "$STATE" ] && [ ! -L "$STATE" ] || { echo "REFUSED: state directory is unavailable; nothing was changed" >&2; exit 1; }
[ -f "$META" ] && [ ! -L "$META" ] || { echo "REFUSED: no task record for $ID; nothing was changed" >&2; exit 1; }

if [ "$(fm_meta_get "$META" worktree_claim)" = released ]; then
  echo "REFUSED: task $ID has already released its claim on its recorded working copy; nothing was changed" >&2
  echo "Clean it up the ordinary way instead (bin/fm-teardown.sh $ID)." >&2
  exit 1
fi

KIND=$(fm_meta_get "$META" kind)
[ -n "$KIND" ] || KIND=ship
if [ "$KIND" = secondmate ]; then
  echo "REFUSED: task $ID is a second mate's home record, not a task's working copy; nothing was changed" >&2
  echo "Retire a second mate through the secondmate-provisioning procedure instead." >&2
  exit 1
fi

WT=$(fm_meta_get "$META" worktree)
PROJ=$(fm_meta_get "$META" project)
PR_URL=$(fm_meta_get "$META" pr)
if [ -z "$WT" ]; then
  echo "REFUSED: task $ID's record names no working copy, so it holds no claim to release; nothing was changed" >&2
  exit 1
fi
[ -d "$WT" ] || {
  echo "REFUSED: task $ID's recorded working copy $WT is not a readable directory, so its contents cannot be proved safe; nothing was changed" >&2
  exit 1
}

RELEASE_LOCKS=()
release_cleanup() {
  local lock
  for lock in ${RELEASE_LOCKS[@]+"${RELEASE_LOCKS[@]}"}; do
    fm_lock_release "$lock" || true
  done
  RELEASE_LOCKS=()
  [ -z "${META_TMP:-}" ] || rm -f -- "$META_TMP" 2>/dev/null || true
}
META_TMP=
trap release_cleanup EXIT
trap 'exit 1' HUP INT TERM

# Serialize against a concurrent allocation or return of the same pool slot, on
# the one lock bin/fm-spawn.sh and bin/fm-teardown.sh both take. A copy that is
# not a pool slot (an Orca worktree, a plain checkout) has no such lock and
# needs none: nothing else hands it out.
if fm_treehouse_pool_slot "$PROJ" "$WT"; then
  TREEHOUSE_LOCK=$(fm_treehouse_project_lock_path "$PROJ") || {
    echo "REFUSED: cannot resolve the shared Treehouse project lock for ${PROJ:-<missing>}; nothing was changed" >&2
    exit 1
  }
  fm_lock_try_acquire "$TREEHOUSE_LOCK" || {
    echo "REFUSED: another Treehouse slot allocation or return is in progress for $PROJ; nothing was changed" >&2
    exit 1
  }
  RELEASE_LOCKS+=("$TREEHOUSE_LOCK")
fi

# 1. There must genuinely be a second record naming this copy.
CLAIM_RC=0
fm_slot_record_other_claim "$META" "$STATE" "$WT" || CLAIM_RC=$?
case "$CLAIM_RC" in
  0) ;;
  1)
    echo "REFUSED: no other task record names $WT, so task $ID's record is the only claim on that copy and there is no collision to resolve; nothing was changed" >&2
    echo "Clean the task up the ordinary way instead (bin/fm-teardown.sh $ID)." >&2
    exit 1
    ;;
  *)
    echo "REFUSED: $FM_SLOT_RECORD_ERROR; nothing was changed" >&2
    exit 1
    ;;
esac
OTHER_ID=$FM_SLOT_RECORD_OTHER_ID
OTHER_HOME_HINT=$(fm_slot_record_other_home_hint "$STATE")
SLOT=$FM_SLOT_RECORD_SLOT

# 2. The slot's own claim must not name this record: the task that actually took
#    the slot keeps it, and the other record is the one to release.
fm_treehouse_slot_owner_state "$WT" "$ID"
case "$FM_TREEHOUSE_SLOT_OWNER" in
  absent|other) ;;
  mine)
    echo "REFUSED: $SLOT's own slot-owner claim names task $ID, so this record is the copy's proven owner and releasing it would strand the slot; nothing was changed" >&2
    echo "Release the other record instead: task $OTHER_ID$OTHER_HOME_HINT (bin/fm-slot-release.sh $OTHER_ID)." >&2
    exit 1
    ;;
  *)
    echo "REFUSED: $SLOT carries a slot-owner claim that cannot be read, so ownership of the copy cannot be established; nothing was changed" >&2
    echo "Inspect or repair the claim file at $(fm_treehouse_slot_owner_marker "$WT" 2>/dev/null || printf 'beside %s' "$SLOT") (task= and home= lines), then re-run." >&2
    exit 1
    ;;
esac

# 3. The copy must hold nothing that releasing could cost. Releasing is what
#    lets task $OTHER_ID's cleanup reset this copy, so the proof is about the
#    copy, not about either record's kind or delivery mode.
DIRTY_RAW=$(git -C "$WT" status --porcelain 2>/dev/null) || {
  echo "REFUSED: cannot inspect $SLOT for uncommitted changes, so it cannot be proved safe to release; nothing was changed" >&2
  exit 1
}
DIRTY=$(printf '%s\n' "$DIRTY_RAW" | grep -vE '^\?\? (\.claude/|\.fm-(grok|kimi)-turnend$)' | head -5 || true)
if [ -n "$DIRTY" ]; then
  echo "REFUSED: $SLOT has uncommitted changes, so releasing task $ID's claim would expose them to task $OTHER_ID's cleanup; nothing was changed" >&2
  printf 'uncommitted changes:\n%s\n' "$DIRTY" >&2
  echo "Commit or land that work first; this command never discards work and has no --force." >&2
  exit 1
fi

UNPUSHED_RAW=$(git -C "$WT" log --oneline HEAD --not --remotes -- 2>/dev/null) || {
  echo "REFUSED: cannot inspect $SLOT for commits not on a remote, so it cannot be proved safe to release; nothing was changed" >&2
  exit 1
}
UNPUSHED=$(printf '%s\n' "$UNPUSHED_RAW" | sed '/^$/d' | head -5)
if [ -n "$UNPUSHED" ]; then
  BRANCH=$(git -C "$WT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo HEAD)
  if ! fm_unlanded_work_is_landed "$WT" "$PROJ" "$BRANCH" "$PR_URL"; then
    echo "REFUSED: $SLOT has work not on any remote and not landed, so releasing task $ID's claim would expose it to task $OTHER_ID's cleanup; nothing was changed" >&2
    printf 'unpushed commits:\n%s\n' "$UNPUSHED" >&2
    echo "Push the branch or land its PR first; this command never discards work and has no --force." >&2
    exit 1
  fi
fi

# 4. Proven. Add the one line, atomically, under the record's own lock.
META_LOCK=$(fm_meta_lock_path "$META") || { echo "REFUSED: cannot resolve the task record lock; nothing was changed" >&2; exit 1; }
fm_lock_acquire_wait "$META_LOCK" || { echo "REFUSED: cannot take the task record lock; nothing was changed" >&2; exit 1; }
RELEASE_LOCKS+=("$META_LOCK")
[ -f "$META" ] && [ ! -L "$META" ] || { echo "REFUSED: task record for $ID went away; nothing was changed" >&2; exit 1; }
umask 077
META_TMP=$(mktemp "$STATE/.fm-slot-release.XXXXXX") || exit 1
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    worktree_claim=*) ;;
    *) printf '%s\n' "$line" >> "$META_TMP" || exit 1 ;;
  esac
done < "$META"
printf 'worktree_claim=released\n' >> "$META_TMP" || exit 1
chmod 0600 "$META_TMP" || exit 1
mv -f -- "$META_TMP" "$META" || exit 1
META_TMP=

printf 'released: task %s no longer claims working copy %s, which stays with task %s%s\n' "$ID" "$SLOT" "$OTHER_ID" "$OTHER_HOME_HINT"
printf 'Task %s can now be cleaned up without touching that copy (bin/fm-teardown.sh %s), and task %s can then be cleaned up normally.\n' "$ID" "$ID" "$OTHER_ID"
