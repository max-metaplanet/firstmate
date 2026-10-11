#!/usr/bin/env bash
# Behavior tests for bin/fm-task-timing.sh.
#
# The timing ledger is a report input, not a gate: cleanup has already succeeded
# by the time a line is written, so every failure path here must stay silent
# about blocking and exit 0. These tests drive the recorder through its command
# interface against hand-written task records, which is the same shape
# bin/fm-teardown.sh hands it.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-task-timing)
TIMING="$ROOT/bin/fm-task-timing.sh"

make_timing_home() {  # <name> -> home path
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/data" "$home/state"
  printf '%s\n' "$home"
}

record() {  # <home> <task-id>
  FM_HOME="$1" FM_STATE_OVERRIDE="$1/state" FM_DATA_OVERRIDE="$1/data" \
    "$TIMING" record "$2" 2>&1
}

# Read one JSON field from the single line recorded for <task>. Prints the
# Python repr of the value, so a JSON null is distinguishable from the string
# "null" and from an empty string.
field() {  # <ledger> <task> <key>
  python3 -I -c '
import json, sys
ledger, task, key = sys.argv[1], sys.argv[2], sys.argv[3]
for line in open(ledger):
    rec = json.loads(line)
    if rec["task"] == task:
        print(repr(rec[key]))
        break
else:
    print("MISSING")
' "$1" "$2" "$3"
}

# A complete ship record yields every field a work-impact report needs, so lead
# time (merged - dispatched) and the review wait (merged - PR opened) are both
# computable from the one line.
test_complete_record_carries_every_timing() {
  local home ledger
  home=$(make_timing_home complete)
  ledger="$home/data/task-timing.jsonl"
  cat > "$home/state/t-full.meta" <<'META'
kind=ship
mode=no-mistakes
project=/projects/demo
branch=feat/ENG-630-t-full
ticket=ENG-630
commit_type=feat
dispatched_at=1791600000
spawn_gen=s1791600000.11.7
pr=https://github.com/owner/repo/pull/42
pr_at=1791603600
META
  printf '1791610800\n' > "$home/state/t-full.merged-at"
  record "$home" t-full >/dev/null || fail "recording a complete task should succeed"
  assert_equals "'ENG-630'" "$(field "$ledger" t-full ticket)" "the ticket was not recorded"
  assert_equals "'feat'" "$(field "$ledger" t-full commit_type)" "the commit type was not recorded"
  assert_equals "1791600000" "$(field "$ledger" t-full dispatched_at)" "the dispatch time was not recorded"
  assert_equals "1791603600" "$(field "$ledger" t-full pr_opened_at)" "the PR-opened time was not recorded"
  assert_equals "1791610800" "$(field "$ledger" t-full merged_at)" "the merge time was not recorded"
  assert_equals "'https://github.com/owner/repo/pull/42'" "$(field "$ledger" t-full pr_url)" \
    "the PR URL was not recorded"
  assert_equals "'demo'" "$(field "$ledger" t-full project)" "the project was not recorded"
  pass "fm-task-timing.sh: a complete ship record carries every timing field"
}

# A task that never reached a pull request, and one dispatched before any ticket
# existed, must record those legs as absent rather than as a zero a consumer
# would subtract.
test_missing_values_are_recorded_as_absent() {
  local home ledger
  home=$(make_timing_home sparse)
  ledger="$home/data/task-timing.jsonl"
  cat > "$home/state/t-sparse.meta" <<'META'
kind=ship
mode=local-only
project=/projects/demo
branch=fm/t-sparse
dispatched_at=1791600000
spawn_gen=s1791600000.12.1
META
  record "$home" t-sparse >/dev/null || fail "recording a sparse task should succeed"
  assert_equals "None" "$(field "$ledger" t-sparse ticket)" "an absent ticket must be null"
  assert_equals "None" "$(field "$ledger" t-sparse commit_type)" "an absent commit type must be null"
  assert_equals "None" "$(field "$ledger" t-sparse pr_opened_at)" "an absent PR-opened time must be null"
  assert_equals "None" "$(field "$ledger" t-sparse merged_at)" "an absent merge time must be null"
  assert_equals "None" "$(field "$ledger" t-sparse pr_url)" "an absent PR URL must be null"
  assert_equals "1791600000" "$(field "$ledger" t-sparse dispatched_at)" "the dispatch time was not recorded"
  pass "fm-task-timing.sh: values the records never carried are recorded as absent"
}

# A stamp that is not plain digits records no time at all, so it must be
# reported as absent rather than written through as a number.
test_unusable_stamp_is_absent_not_garbage() {
  local home ledger
  home=$(make_timing_home badstamp)
  ledger="$home/data/task-timing.jsonl"
  cat > "$home/state/t-bad.meta" <<'META'
kind=ship
mode=no-mistakes
dispatched_at=not-a-time
pr_at=
spawn_gen=s3.1.1
META
  printf '1791610800\n' > "$home/state/t-bad.merged-at"
  record "$home" t-bad >/dev/null || fail "recording a task with a bad stamp should succeed"
  assert_equals "None" "$(field "$ledger" t-bad dispatched_at)" "a non-numeric stamp must be null"
  assert_equals "1791610800" "$(field "$ledger" t-bad merged_at)" "the usable stamp was lost"
  python3 -I -c 'import json,sys; [json.loads(l) for l in open(sys.argv[1])]' "$ledger" \
    || fail "a bad stamp broke the ledger's JSON"
  pass "fm-task-timing.sh: an unusable stamp is recorded as absent and keeps the line valid JSON"
}

# A retried cleanup must never count a task twice, and must still append other
# tasks' lines to the same ledger.
test_ledger_is_append_only_and_idempotent_per_incarnation() {
  local home ledger before after
  home=$(make_timing_home idempotent)
  ledger="$home/data/task-timing.jsonl"
  printf 'kind=ship\nmode=no-mistakes\ndispatched_at=1791600000\nspawn_gen=s4.1.1\n' \
    > "$home/state/t-one.meta"
  printf 'kind=ship\nmode=no-mistakes\ndispatched_at=1791600500\nspawn_gen=s5.1.1\n' \
    > "$home/state/t-two.meta"
  record "$home" t-one >/dev/null || fail "the first record should succeed"
  before=$(wc -l < "$ledger")
  record "$home" t-one >/dev/null || fail "a repeated record should still succeed"
  after=$(wc -l < "$ledger")
  assert_equals "$before" "$after" "a retried cleanup appended the same incarnation twice"
  record "$home" t-two >/dev/null || fail "a second task should record"
  assert_equals "2" "$(wc -l < "$ledger" | tr -d ' ')" "a second task did not append its own line"

  # A relaunch mints a new incarnation, which is a distinct record.
  printf 'kind=ship\nmode=no-mistakes\ndispatched_at=1791600000\nspawn_gen=s4.2.2\n' \
    > "$home/state/t-one.meta"
  record "$home" t-one >/dev/null || fail "a new incarnation should record"
  assert_equals "3" "$(wc -l < "$ledger" | tr -d ' ')" "a new incarnation did not append its own line"
  pass "fm-task-timing.sh: the ledger appends once per incarnation and never rewrites"
}

# Cleanup has already succeeded when this runs, so a missing or unusable source
# warns and exits 0 rather than turning a finished cleanup into a failure.
test_unusable_sources_never_fail_cleanup() {
  local home out rc
  home=$(make_timing_home unusable)
  out=$(record "$home" t-absent); rc=$?
  expect_code 0 "$rc" "a missing task record must not fail cleanup"
  assert_contains "$out" "no task record" "the warning did not name the missing record"
  assert_absent "$home/data/task-timing.jsonl" "a missing record still wrote a ledger line"

  printf 'kind=ship\nspawn_gen=s6.1.1\n' > "$home/state/t-nodata.meta"
  fm_test_remove_tree "$home/data"
  out=$(record "$home" t-nodata); rc=$?
  expect_code 0 "$rc" "a missing data directory must not fail cleanup"
  assert_contains "$out" "no data directory" "the warning did not name the missing directory"
  pass "fm-task-timing.sh: an unusable source warns and never fails cleanup"
}

# Bad usage is the one refusal: it is an operator mistake rather than a cleanup
# condition, so it must not pass silently.
test_bad_usage_is_refused() {
  local home rc
  home=$(make_timing_home usage)
  FM_HOME="$home" "$TIMING" record >/dev/null 2>&1; rc=$?
  expect_code 2 "$rc" "a missing task id must be refused as bad usage"
  FM_HOME="$home" "$TIMING" bogus t1 >/dev/null 2>&1; rc=$?
  expect_code 2 "$rc" "an unknown subcommand must be refused as bad usage"
  FM_HOME="$home" "$TIMING" record t1 extra >/dev/null 2>&1; rc=$?
  expect_code 2 "$rc" "a surplus argument must be refused as bad usage"
  pass "fm-task-timing.sh: bad usage is refused rather than recorded"
}

test_complete_record_carries_every_timing
test_missing_values_are_recorded_as_absent
test_unusable_stamp_is_absent_not_garbage
test_ledger_is_append_only_and_idempotent_per_incarnation
test_unusable_sources_never_fail_cleanup
test_bad_usage_is_refused
