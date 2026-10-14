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

# Classify one change set once and keep its outputs for several assertions:
# a classification runs the real changed-file map, so re-running it per
# question would make this suite minutes longer for no extra coverage.
SCOPE_OUT=
classify() {  # <path>...
  SCOPE_OUT=$(scope_for "$@") || fail "classifying failed for: $*"
}

# Print one output value from the last classification.
scope_value() {  # <key>
  printf '%s\n' "$SCOPE_OUT" | sed -n "s/^$1=//p"
}

# Assert the complete suite runs rather than a change-scoped selection.
assert_full_suite() {  # <why> <path>...
  local why=$1
  shift
  classify "$@"
  assert_contains "$SCOPE_OUT" 'full=true' \
    "must fail open to the complete suite: $why"$'\n'"$SCOPE_OUT"
  assert_contains "$SCOPE_OUT" 'herdr=true' \
    "the complete suite includes the Herdr lane: $why"$'\n'"$SCOPE_OUT"
  [ "$(scope_value selected_matrix)" = '' ] \
    || fail "a complete-suite verdict must emit no selection matrix: $why"
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
  assert_gates true false 'the ignore rules a test checks' .gitignore
  pass "prose and data a test reads keeps the behavior gate on"
}

# One behavior-relevant path in an otherwise prose-only change set must win.
test_one_relevant_path_turns_the_gate_back_on() {
  assert_gates true true 'prose beside a shell change' README.md bin/fm-spawn.sh
  assert_gates true false 'prose beside a skill change' \
    docs/architecture.md .agents/skills/bearings/SKILL.md
  pass "a single relevant path turns its gate back on for the whole change set"
}

# A rename out of a path a test reads must be classified by its source as well
# as its destination, so this drives the real git diff rather than a path list.
test_rename_out_of_a_read_path_keeps_the_behavior_gate_on() {
  local repo base out
  repo="$TMP_ROOT/rename-repo"
  mkdir -p "$repo/bin" "$repo/docs/supervision-protocols"
  cp "$SCOPE" "$repo/bin/fm-ci-change-scope.sh"
  printf 'protocol\n' >"$repo/docs/supervision-protocols/a.md"
  git -C "$repo" init -q
  git -C "$repo" add -A
  git -C "$repo" -c user.name=t -c user.email=t@t commit -qm base
  base=$(git -C "$repo" rev-parse HEAD)
  git -C "$repo" mv docs/supervision-protocols/a.md docs/a.md
  git -C "$repo" -c user.name=t -c user.email=t@t commit -qm rename
  out=$(FM_CI_EVENT=pull_request FM_CI_BASE_SHA="$base" FM_CI_HEAD_SHA=HEAD \
    bash "$repo/bin/fm-ci-change-scope.sh") || fail "classifying a rename failed"
  assert_contains "$out" 'behavior=true' \
    "a rename out of a test-read path must keep the behavior gate on"$'\n'"$out"
  pass "a rename out of a test-read path keeps the behavior gate on"
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

# Change-scoped selection. These hold the promise the same way the gates above
# do: a selection replaces the complete suite, so each case asserts the
# selection is only trusted where it is provably complete, and that every
# doubt lands back on the full suite rather than on a faster round.

test_a_single_script_change_selects_one_packed_job() {
  local matrix
  classify bin/fm-quota-choose.sh
  [ "$(scope_value selected_count)" = 1 ] \
    || fail "a one-script change must select exactly its own suite"$'\n'"$SCOPE_OUT"
  matrix=$(scope_value selected_matrix)
  assert_contains "$matrix" 'tests/fm-quota-choose.test.sh' \
    "the selection must name the suite that covers the changed script"$'\n'"$matrix"
  # Runner start delay is what a short round is made of, so the whole point is
  # that one small change spends one runner.
  [ "$(printf '%s' "$matrix" | grep -c '"shard"' | tr -d ' ')" = 1 ] \
    || fail "a one-script change must pack into exactly one job"$'\n'"$matrix"
  [ "$(scope_value full)" = false ] \
    || fail "a trusted selection must turn the complete sharded suite off"
  pass "a one-script change selects its own suite in a single job"
}

test_a_selection_too_large_to_pack_falls_back_to_the_full_suite() {
  # No single script exceeds the per-job budget any more now that the two
  # longest suites are split, so breadth is what the packing cannot absorb.
  # Each of these paths packs on its own; together their suites need more
  # than the job cap allows, and a round that cannot be packed must widen
  # rather than drop the work that does not fit.
  assert_full_suite 'a change whose suites cannot be packed under the budget' \
    bin/fm-afk-launch.sh bin/fm-session-start.sh bin/fm-pr-merge.sh bin/fm-spawn.sh
  pass "a selection no packing fits under the budget falls back to the full suite"
}

test_shared_libraries_and_the_machinery_fall_back_to_the_full_suite() {
  assert_full_suite 'a shared library by name' bin/fm-dod-lib.sh
  assert_full_suite 'a script many others source' bin/fm-backend.sh
  assert_full_suite 'the test runner itself' bin/fm-test-run.sh
  assert_full_suite 'this classifier itself' bin/fm-ci-change-scope.sh
  assert_full_suite 'the CI workflow itself' .github/workflows/ci.yml
  assert_full_suite 'shared test scaffolding' tests/lib.sh
  assert_full_suite 'one blocked path beside a selectable one' \
    bin/fm-quota-choose.sh bin/fm-dod-lib.sh
  pass "shared libraries, test scaffolding and the selection machinery run everything"
}

test_only_pull_requests_select() {
  local out
  out=$(FM_CI_EVENT=push bash "$SCOPE") || fail "push classification failed"
  assert_contains "$out" 'full=true' "a push to main must run the complete suite"$'\n'"$out"
  out=$(FM_CI_EVENT=schedule bash "$SCOPE") || fail "schedule classification failed"
  assert_contains "$out" 'full=true' "the nightly schedule must run the complete suite"$'\n'"$out"
  assert_contains "$out" 'herdr=true' "the nightly schedule must run the Herdr lane"$'\n'"$out"
  pass "push to main and the nightly schedule always run the complete suite"
}

test_an_unusable_change_set_never_selects() {
  local out
  out=$(FM_CI_EVENT=pull_request FM_CI_BASE_SHA='' bash "$SCOPE") \
    || fail "classification without a base commit failed"
  assert_contains "$out" 'full=true' "a missing base commit must run the complete suite"$'\n'"$out"

  : >"$TMP_ROOT/empty"
  out=$(FM_CI_EVENT=pull_request FM_CI_CHANGED_PATHS_FILE="$TMP_ROOT/empty" bash "$SCOPE") \
    || fail "classification of an empty change set failed"
  assert_contains "$out" 'full=true' "an empty change set must run the complete suite"$'\n'"$out"
  pass "an unusable change set never narrows the round"
}

# A path the runner's map refuses is the map saying it does not know what
# proves this change. The round must widen, not guess. A new non-test file
# under tests/ is that shape: the map has no arm for it and says so.
test_a_path_the_map_refuses_falls_back_to_the_full_suite() {
  assert_full_suite 'a path the changed-file map has no arm for' tests/stray-note.txt
  pass "a path the changed-file map refuses falls back to the full suite"
}

# Prose a test really reads keeps the behavior gate on, but the runner's map
# answers nothing for it, so there is no selection to trust and the round must
# widen rather than run nothing.
test_a_behavior_relevant_path_that_maps_to_no_tests_runs_everything() {
  assert_full_suite 'prose a test reads that maps to no suite' docs/arm-pretool-check.md
  pass "a behavior-relevant path that maps to no tests runs the complete suite"
}

# A prose-only change has nothing to select from and keeps running the
# documentation audience guard instead.
test_prose_only_changes_select_nothing_at_all() {
  classify docs/architecture.md
  assert_contains "$SCOPE_OUT" 'behavior=false' \
    "prose must keep the behavior gate off"$'\n'"$SCOPE_OUT"
  assert_contains "$SCOPE_OUT" 'full=false' \
    "prose must not run the complete suite"$'\n'"$SCOPE_OUT"
  assert_contains "$SCOPE_OUT" 'herdr=false' \
    "prose must not run the Herdr lane"$'\n'"$SCOPE_OUT"
  [ "$(scope_value selected_matrix)" = '' ] || fail "prose must select nothing at all"
  pass "a prose-only change selects nothing and keeps the documentation guard"
}

# The required Herdr lane owns its whole family. A selected member must move
# the work there rather than into a job with no Herdr installed.
test_a_selected_herdr_member_runs_the_herdr_lane() {
  local matrix
  classify bin/fm-herdr-session-cleanup.sh
  assert_contains "$SCOPE_OUT" 'herdr=true' \
    "a selection reaching the Herdr family must run that lane"$'\n'"$SCOPE_OUT"
  matrix=$(scope_value selected_matrix)
  if printf '%s' "$matrix" | grep -q 'herdr-smoke'; then
    fail "a Herdr-gated script must not be packed into a job without Herdr"$'\n'"$matrix"
  fi
  pass "a selected Herdr-family member runs the required Herdr lane instead"
}

test_prose_only_changes_turn_both_gates_off
test_shell_changes_turn_both_gates_on
test_non_shell_test_inputs_run_the_behavior_suites_without_macos
test_prose_a_test_reads_stays_behavior_triggering
test_one_relevant_path_turns_the_gate_back_on
test_rename_out_of_a_read_path_keeps_the_behavior_gate_on
test_unrecognized_paths_keep_both_gates_on
test_push_events_and_unusable_input_keep_both_gates_on
test_unknown_argument_is_refused
test_a_single_script_change_selects_one_packed_job
test_a_selection_too_large_to_pack_falls_back_to_the_full_suite
test_shared_libraries_and_the_machinery_fall_back_to_the_full_suite
test_only_pull_requests_select
test_an_unusable_change_set_never_selects
test_a_path_the_map_refuses_falls_back_to_the_full_suite
test_a_behavior_relevant_path_that_maps_to_no_tests_runs_everything
test_prose_only_changes_select_nothing_at_all
test_a_selected_herdr_member_runs_the_herdr_lane
