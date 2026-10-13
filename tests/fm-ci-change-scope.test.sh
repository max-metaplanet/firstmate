#!/usr/bin/env bash
# Behavioral regressions for the CI change-scope gates in bin/fm-ci-change-scope.sh.
#
# The two gates trade CI wall time for the promise that every test still runs on
# every change that could affect it, so these tests hold the promise rather than
# the saving: each case asserts a gate turns OFF only for paths provably outside
# the gated jobs' sources, and that every unknown or unreadable input keeps it on.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCOPE="$ROOT/bin/fm-ci-change-scope.sh"
TMP_ROOT=$(fm_test_tmproot fm-ci-change-scope)

assert_present "$SCOPE" "bin/fm-ci-change-scope.sh is missing"

# Classify one change set and print the gate outputs.
scope_for() {  # <path>...
  local list
  list="$TMP_ROOT/paths.$$"
  printf '%s\n' "$@" >"$list"
  FM_CI_EVENT=pull_request FM_CI_CHANGED_PATHS_FILE="$list" bash "$SCOPE"
}

# Assert both gates for one change set.
assert_gates() {  # <behavior> <macos> <why> <path>...
  local behavior=$1 macos=$2 why=$3 out
  shift 3
  out=$(scope_for "$@") || fail "classifying failed: $why"
  assert_contains "$out" "behavior=$behavior" "behavior gate wrong for $why"$'\n'"$out"
  assert_contains "$out" "macos=$macos" "macOS gate wrong for $why"$'\n'"$out"
}

test_prose_only_changes_turn_both_gates_off() {
  assert_gates false false 'a docs page' docs/architecture.md
  assert_gates false false 'the README' README.md
  assert_gates false false 'a nested docs page' docs/verification/agy.md
  assert_gates false false 'several prose files at once' README.md docs/architecture.md VISION.md
  pass "prose no test reads turns both the behavior and macOS gates off"
}

test_shell_changes_turn_both_gates_on() {
  assert_gates true true 'a bin script' bin/fm-spawn.sh
  assert_gates true true 'a backend adapter' bin/backends/tmux.sh
  assert_gates true true 'a test script' tests/fm-spawn.test.sh
  assert_gates true true 'the CI workflow itself' .github/workflows/ci.yml
  pass "a shell or CI workflow change keeps both gates on"
}

# The stock macOS Bash job reads only shell sources, so a change that reaches
# tests without reaching bin/ or tests/ must not spend a scarce macOS runner.
test_non_shell_test_inputs_run_the_behavior_suites_without_macos() {
  assert_gates true false 'a skill contract' .agents/skills/bearings/SKILL.md
  assert_gates true false 'the supervisor contract' AGENTS.md
  assert_gates true false 'the contributor guide' CONTRIBUTING.md
  assert_gates true false 'a second workflow' .github/workflows/no-mistakes-required.yml
  pass "test-affecting non-shell changes run the behavior suites but skip macOS"
}

# Every prose path a test really consumes must stay behavior-triggering, or the
# docs-only skip would drop that test's coverage.
test_prose_a_test_reads_stays_behavior_triggering() {
  assert_gates true false 'a supervision protocol copied by a test' \
    docs/supervision-protocols/claude.md
  assert_gates true false 'the pretool doc a test greps' docs/arm-pretool-check.md
  assert_gates true false 'a docs example a test copies' \
    docs/examples/process-event-extension/package.json
  assert_gates true false 'the configuration contract' docs/configuration.md
  assert_gates true false 'the shard composition doc' docs/fm-test-portable-shards.md
  assert_gates true false 'the isolation proof evidence' docs/fm-test-isolation-proof.json
  assert_gates true false 'the documentation audience inventory' \
    docs/documentation-audiences.json
  pass "prose and data a test reads keeps the behavior gate on"
}

# One behavior-relevant path in an otherwise prose-only change set must win.
test_one_relevant_path_turns_the_gate_back_on() {
  assert_gates true true 'prose beside a shell change' README.md bin/fm-spawn.sh
  assert_gates true false 'prose beside a skill change' \
    docs/architecture.md .agents/skills/bearings/SKILL.md
  pass "a single relevant path turns its gate back on for the whole change set"
}

# Coverage beats speed: anything the allowlists do not name is relevant.
test_unrecognized_paths_keep_both_gates_on() {
  assert_gates true true 'an unrecognized root file' .tasks.toml
  assert_gates true true 'a new top-level directory' newthing/file.conf
  pass "an unrecognized path keeps both gates on"
}

test_push_events_and_unusable_input_keep_both_gates_on() {
  local out
  out=$(FM_CI_EVENT=push bash "$SCOPE") || fail "push classification failed"
  assert_contains "$out" 'behavior=true' "a push to main must run the behavior suites"
  assert_contains "$out" 'macos=true' "a push to main must run the macOS job"

  out=$(FM_CI_EVENT=pull_request FM_CI_BASE_SHA='' bash "$SCOPE") \
    || fail "classification without a base commit failed"
  assert_contains "$out" 'behavior=true' "a missing base commit must keep the behavior gate on"
  assert_contains "$out" 'macos=true' "a missing base commit must keep the macOS gate on"

  out=$(FM_CI_EVENT=pull_request FM_CI_BASE_SHA=0000000000000000000000000000000000000000 \
    bash "$SCOPE") || fail "classification with an unknown base commit failed"
  assert_contains "$out" 'behavior=true' "an unknown base commit must keep the behavior gate on"

  out=$(FM_CI_EVENT=pull_request FM_CI_CHANGED_PATHS_FILE="$TMP_ROOT/absent" bash "$SCOPE") \
    || fail "classification with an unreadable path list failed"
  assert_contains "$out" 'behavior=true' "an unreadable change set must keep the behavior gate on"

  : >"$TMP_ROOT/empty"
  out=$(FM_CI_EVENT=pull_request FM_CI_CHANGED_PATHS_FILE="$TMP_ROOT/empty" bash "$SCOPE") \
    || fail "classification of an empty change set failed"
  assert_contains "$out" 'behavior=true' "an empty change set must keep the behavior gate on"

  out=$(FM_CI_EVENT=workflow_dispatch bash "$SCOPE") || fail "unknown event classification failed"
  assert_contains "$out" 'behavior=true' "an unknown event must keep the behavior gate on"
  pass "push events, unknown events and unusable change sets keep both gates on"
}

test_unknown_argument_is_refused() {
  local rc=0
  bash "$SCOPE" --nope >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ] || fail "an unknown argument must be refused with status 2, got $rc"
  pass "an unknown argument is refused rather than silently classified"
}

test_prose_only_changes_turn_both_gates_off
test_shell_changes_turn_both_gates_on
test_non_shell_test_inputs_run_the_behavior_suites_without_macos
test_prose_a_test_reads_stays_behavior_triggering
test_one_relevant_path_turns_the_gate_back_on
test_unrecognized_paths_keep_both_gates_on
test_push_events_and_unusable_input_keep_both_gates_on
test_unknown_argument_is_refused
