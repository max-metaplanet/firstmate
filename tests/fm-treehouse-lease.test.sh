#!/usr/bin/env bash
# Reboot recovery of recorded task slots without mutating worktree contents.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/treehouse-lease-helpers.sh
. "$ROOT/tests/treehouse-lease-helpers.sh"
TMP_ROOT=$(fm_test_tmproot fm-treehouse-lease)
FM_TEST_CLEANUP_DIRS+=("$TMP_ROOT")
trap fm_test_cleanup EXIT
fm_git_identity fmtest fmtest@example.invalid
export FM_HOME="$TMP_ROOT/home"
mkdir -p "$FM_HOME/state" "$TMP_ROOT/pool/1" "$TMP_ROOT/fakebin"
git init -qb main "$TMP_ROOT/project"
git -C "$TMP_ROOT/project" commit -qm initial --allow-empty
git -C "$TMP_ROOT/project" worktree add -q --detach "$TMP_ROOT/pool/1/project"
slot="$TMP_ROOT/pool/1/project"
printf '{"worktrees":[{"name":"1","path":"%s","owner_pid":99999999}]}\n' "$slot" \
  > "$TMP_ROOT/pool/treehouse-state.json"
fm_test_treehouse_durable_lease "$TMP_ROOT/fakebin" "$TMP_ROOT/pool"
export PATH="$TMP_ROOT/fakebin:$PATH"
# shellcheck source=bin/fm-backend.sh disable=SC1091
. "$ROOT/bin/fm-backend.sh"
# shellcheck source=bin/fm-wake-lib.sh disable=SC1091
. "$ROOT/bin/fm-wake-lib.sh"
# shellcheck source=bin/fm-treehouse-lease-lib.sh disable=SC1091
. "$ROOT/bin/fm-treehouse-lease-lib.sh"
meta="$FM_HOME/state/parked.meta"
printf 'project=%s\nworktree=%s\nkind=ship\nworker_park_phase=parked\n' "$TMP_ROOT/project" "$slot" > "$meta"
fm_treehouse_slot_owner_claim "$slot" parked "$FM_HOME"
printf 'uncommitted work survives\n' > "$slot/payload"
before=$(git -C "$slot" status --porcelain)
head=$(git -C "$slot" rev-parse HEAD)
fm_treehouse_leases_restore "$FM_HOME/state" "$FM_HOME"
jq -e '.worktrees[0].leased == true' "$TMP_ROOT/pool/treehouse-state.json" >/dev/null \
  || fail "reboot recovery left the recorded parked task available"
fm_treehouse_leases_restore "$FM_HOME/state" "$FM_HOME"
[ "$(wc -l < "$TMP_ROOT/pool/lease-calls" | tr -d ' ')" = 1 ] || fail "recovery replaced an existing durable lease"
[ "$(git -C "$slot" status --porcelain)" = "$before" ] || fail "recovery changed worktree contents"
[ "$(git -C "$slot" rev-parse HEAD)" = "$head" ] || fail "recovery moved HEAD"
pass "reboot recovery durably leases a parked record, preserves work, and is idempotent"

for claim in other-task other-home absent unsafe released missing-path; do
  jq 'del(.worktrees[0].leased)' "$TMP_ROOT/pool/treehouse-state.json" > "$TMP_ROOT/pool/state.new"
  mv "$TMP_ROOT/pool/state.new" "$TMP_ROOT/pool/treehouse-state.json"
  fm_treehouse_slot_owner_claim "$slot" parked "$FM_HOME"
  case "$claim" in
    other-task) fm_treehouse_slot_owner_claim "$slot" successor "$FM_HOME" ;;
    other-home) mkdir -p "$TMP_ROOT/other"; fm_treehouse_slot_owner_claim "$slot" parked "$TMP_ROOT/other" ;;
    absent) rm "$TMP_ROOT/pool/1/.fm-slot-owner" ;;
    unsafe) rm "$TMP_ROOT/pool/1/.fm-slot-owner"; ln -s "$meta" "$TMP_ROOT/pool/1/.fm-slot-owner" ;;
    released) printf 'worktree_claim=released\n' >> "$meta" ;;
    missing-path) printf 'worktree=%s/absent\n' "$TMP_ROOT" > "$meta" ;;
  esac
  fm_treehouse_leases_restore "$FM_HOME/state" "$FM_HOME"
  [ "$(wc -l < "$TMP_ROOT/pool/lease-calls" | tr -d ' ')" = 1 ] || fail "$claim record leased a slot"
  rm -f "$TMP_ROOT/pool/1/.fm-slot-owner"
done
pass "foreign, unsafe, absent, released and host-missing records never lease a slot"

printf 'project=%s\nworktree=%s\n' "$TMP_ROOT/project" "$slot" > "$meta"
fm_treehouse_slot_owner_claim "$slot" parked "$FM_HOME"
if FM_TEST_LEASE_WRONG_POOL=1 fm_treehouse_leases_restore "$FM_HOME/state" "$FM_HOME" 2> "$TMP_ROOT/error"; then
  fail "Treehouse's different pool was accepted"
fi
assert_grep 'different pool' "$TMP_ROOT/error" "pool mismatch needs an actionable diagnostic"
[ "$(wc -l < "$TMP_ROOT/pool/lease-calls" | tr -d ' ')" = 1 ] || fail "recovery leased a slot in a different pool"
if FM_TEST_LEASE_FAIL=1 fm_treehouse_leases_restore "$FM_HOME/state" "$FM_HOME" 2> "$TMP_ROOT/error"; then
  fail "lease failure was swallowed"
fi
assert_grep 'TREEHOUSE_LEASE:' "$TMP_ROOT/error" "failure needs an actionable diagnostic"
lock=$(fm_treehouse_project_lock_path "$TMP_ROOT/project")
fm_lock_try_acquire "$lock" || fail "failed lease leaked the project lock"
fm_lock_release "$lock"
pass "lease failures surface and release the project lock"
