#!/usr/bin/env bash
# Behavior tests for bin/fm-dispatch-predict-lib.sh: the append-only
# dispatch-resolve auto-apply pilot prediction ledger bin/fm-spawn.sh writes
# to. Drives fm_dispatch_predict_log directly with canned resolver --json
# output (no live fm-dispatch-resolve.sh call), so these cover the log's own
# field contract independently of the resolver and of fm-spawn.sh's hook.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-dispatch-predict-lib.sh
. "$ROOT/bin/fm-dispatch-predict-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-dispatch-predict-lib)

last_line() {  # <data-dir>
  tail -n 1 "$1/dispatch-predictions.jsonl"
}

test_clear_result_records_chosen_and_used_profiles() {
  local data line
  data="$TMP_ROOT/clear/data"
  fm_dispatch_predict_log "$data" task-clear-1 \
    '{"status":"clear","rule":"rule_1","confidence":0.95,"auto_apply":true,"chosen":{"profile":{"harness":"codex","model":"gpt-5.6-sol","effort":"high"}}}' \
    not-run true codex gpt-5.6-sol high
  [ -f "$data/dispatch-predictions.jsonl" ] || fail "no ledger file was created"
  line=$(last_line "$data")
  [ "$(jq -r '.task_id' <<<"$line")" = task-clear-1 ] || fail "task_id mismatch: $line"
  [ "$(jq -r '.resolver_status' <<<"$line")" = clear ] || fail "resolver_status mismatch: $line"
  [ "$(jq -r '.rule' <<<"$line")" = rule_1 ] || fail "rule mismatch: $line"
  [ "$(jq -r '.confidence' <<<"$line")" = 0.95 ] || fail "confidence mismatch: $line"
  [ "$(jq -r '.auto_applied' <<<"$line")" = true ] || fail "auto_applied mismatch: $line"
  [ "$(jq -r '.chosen.harness' <<<"$line")" = codex ] || fail "chosen.harness mismatch: $line"
  [ "$(jq -r '.chosen.model' <<<"$line")" = gpt-5.6-sol ] || fail "chosen.model mismatch: $line"
  [ "$(jq -r '.chosen.effort' <<<"$line")" = high ] || fail "chosen.effort mismatch: $line"
  [ "$(jq -r '.used.harness' <<<"$line")" = codex ] || fail "used.harness mismatch: $line"
  [ "$(jq -r '.used.model' <<<"$line")" = gpt-5.6-sol ] || fail "used.model mismatch: $line"
  [ "$(jq -r '.used.effort' <<<"$line")" = high ] || fail "used.effort mismatch: $line"
  [ -n "$(jq -r '.ts' <<<"$line")" ] && [ "$(jq -r '.ts' <<<"$line")" != null ] || fail "ts missing: $line"
  pass "a clear result records the resolver's rule, chosen profile, and the profile actually used"
}

test_non_clear_result_records_null_chosen_and_false_applied() {
  local data line
  data="$TMP_ROOT/ambiguous/data"
  fm_dispatch_predict_log "$data" task-ambig-1 \
    '{"status":"ambiguous","rule":"rule_1","reason":"confidence below floor"}' \
    not-run false '' '' ''
  line=$(last_line "$data")
  [ "$(jq -r '.resolver_status' <<<"$line")" = ambiguous ] || fail "resolver_status mismatch: $line"
  [ "$(jq -r '.auto_applied' <<<"$line")" = false ] || fail "auto_applied mismatch: $line"
  [ "$(jq -r '.chosen' <<<"$line")" = null ] || fail "chosen must be null on a non-clear result: $line"
  [ "$(jq -r '.used.harness' <<<"$line")" = null ] || fail "used.harness must be null when nothing was launched: $line"
  pass "a non-clear result records a null chosen profile and auto_applied=false"
}

test_empty_or_off_resolver_output_logs_as_off() {
  local data line
  data="$TMP_ROOT/off/data"
  fm_dispatch_predict_log "$data" task-off-1 '' off false '' '' ''
  line=$(last_line "$data")
  [ "$(jq -r '.resolver_status' <<<"$line")" = off ] || fail "empty resolver JSON must log resolver_status=off: $line"
  [ "$(jq -r '.chosen' <<<"$line")" = null ] || fail "chosen must be null when the resolver produced nothing: $line"
  pass "empty resolver output (off, never-send, or an unavailable resolver) logs as status off"
}

test_malformed_resolver_json_does_not_abort_and_logs_as_off() {
  local data line status
  data="$TMP_ROOT/malformed/data"
  ( fm_dispatch_predict_log "$data" task-malformed-1 '{not json' off false harness-x '' '' )
  status=$?
  [ "$status" -eq 0 ] || fail "malformed resolver JSON must not make the logger fail: exit $status"
  line=$(last_line "$data")
  [ "$(jq -r '.resolver_status' <<<"$line")" = off ] || fail "malformed resolver JSON must log resolver_status=off: $line"
  [ "$(jq -r '.used.harness' <<<"$line")" = harness-x ] || fail "used.harness mismatch: $line"
  pass "malformed resolver JSON never aborts the caller and logs as status off"
}

test_log_never_carries_brief_text_or_secrets() {
  local data line
  data="$TMP_ROOT/no-secrets/data"
  fm_dispatch_predict_log "$data" task-secret-1 \
    '{"status":"clear","rule":"rule_1","auto_apply":true,"chosen":{"profile":{"harness":"claude","model":"opus"}}}' \
    not-run true claude opus ''
  line=$(last_line "$data")
  assert_not_contains "$line" "TYPESAFE_API_KEY" "the ledger line must never carry a secret value"
  assert_not_contains "$line" "Captain's intent" "the ledger line must never carry brief text"
  pass "the ledger line carries only the resolver prediction and profile fields, never brief text or secrets"
}

test_missing_jq_skips_logging_without_failing() {
  local data fakebin status
  data="$TMP_ROOT/no-jq/data"
  fakebin="$TMP_ROOT/no-jq/fakebin"
  mkdir -p "$fakebin"
  for tool in bash cat chmod cp dirname mktemp rm mkdir printf; do
    [ -e "/usr/bin/$tool" ] && ln -sf "/usr/bin/$tool" "$fakebin/$tool" 2>/dev/null
    [ -e "/bin/$tool" ] && ln -sf "/bin/$tool" "$fakebin/$tool" 2>/dev/null
  done
  ( PATH="$fakebin" fm_dispatch_predict_log "$data" task-nojq-1 \
      '{"status":"clear","rule":"rule_1","auto_apply":true,"chosen":{"profile":{"harness":"claude"}}}' \
      not-run true claude '' '' )
  status=$?
  [ "$status" -eq 0 ] || fail "a missing jq must not make the logger fail: exit $status"
  [ ! -e "$data/dispatch-predictions.jsonl" ] || fail "a missing jq must not write a ledger line"
  pass "a missing jq skips logging instead of failing the caller"
}

test_no_resolver_output_logs_the_caller_status_and_used_profile() {
  local data line
  data="$TMP_ROOT/not-run/data"
  fm_dispatch_predict_log "$data" task-explicit-1 '' not-run false claude opus ''
  line=$(last_line "$data")
  [ "$(jq -r '.resolver_status' <<<"$line")" = not-run ] || fail "resolver_status must be the caller's fallback status: $line"
  [ "$(jq -r '.rule' <<<"$line")" = null ] || fail "rule must be null when the resolver did not run: $line"
  [ "$(jq -r '.confidence' <<<"$line")" = null ] || fail "confidence must be null when the resolver did not run: $line"
  [ "$(jq -r '.auto_applied' <<<"$line")" = false ] || fail "auto_applied mismatch: $line"
  [ "$(jq -r '.used.harness' <<<"$line")" = claude ] || fail "used.harness mismatch: $line"
  [ "$(jq -r '.used.model' <<<"$line")" = opus ] || fail "used.model mismatch: $line"
  pass "a spawn the resolver did not run for logs the caller's status and the profile actually used"
}

test_repeated_calls_append_one_line_each() {
  local data count
  data="$TMP_ROOT/append/data"
  fm_dispatch_predict_log "$data" task-a '{"status":"escalate"}' not-run false '' '' ''
  fm_dispatch_predict_log "$data" task-b '{"status":"escalate"}' not-run false '' '' ''
  count=$(wc -l < "$data/dispatch-predictions.jsonl" | tr -d ' ')
  [ "$count" = 2 ] || fail "expected 2 appended lines, got $count"
  pass "every call appends exactly one new line, never replacing the ledger"
}

test_clear_result_records_chosen_and_used_profiles
test_non_clear_result_records_null_chosen_and_false_applied
test_empty_or_off_resolver_output_logs_as_off
test_malformed_resolver_json_does_not_abort_and_logs_as_off
test_log_never_carries_brief_text_or_secrets
test_missing_jq_skips_logging_without_failing
test_no_resolver_output_logs_the_caller_status_and_used_profile
test_repeated_calls_append_one_line_each

echo "# all fm-dispatch-predict-lib tests passed"
