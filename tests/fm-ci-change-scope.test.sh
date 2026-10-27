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
  FM_CI_EVENT=pull_request FM_CI_CHANGED_PATHS_FILE="$list" bash "$SCOPE" "${SCOPE_MODE:-}"
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
# Only a push to main, the nightly schedule, an unrecognized event, or --local
# can reach this verdict; a pull request falls back to the bounded lanes below.
assert_full_suite() {  # <why> <path>...
  local why=$1
  shift
  classify "$@"
  assert_contains "$SCOPE_OUT" 'full=true' \
    "must fail open to the complete suite: $why"$'\n'"$SCOPE_OUT"
  assert_contains "$SCOPE_OUT" 'parallel=true' \
    "the complete suite includes both parallel lanes: $why"$'\n'"$SCOPE_OUT"
  assert_contains "$SCOPE_OUT" 'herdr=true' \
    "the complete suite includes the Herdr lane: $why"$'\n'"$SCOPE_OUT"
  [ "$(scope_value selected_matrix)" = '' ] \
    || fail "a complete-suite verdict must emit no selection matrix: $why"
}

# Assert the bounded pull-request fallback: both portable parallel lanes and
# the required Herdr lane, and NOT the sixteen-shard serial fan-out. This is
# what every doubt on a pull request lands on, and the thing it must never
# land on is `full`, because nineteen long-lived jobs exceed the runners this
# fork can hold and the round then queues behind itself.
assert_bounded_fallback() {  # <why> <path>...
  local why=$1
  shift
  classify "$@"
  assert_contains "$SCOPE_OUT" 'full=false' \
    "a pull request must never fan out to the serial shards: $why"$'\n'"$SCOPE_OUT"
  assert_contains "$SCOPE_OUT" 'parallel=true' \
    "the bounded fallback runs both parallel lanes: $why"$'\n'"$SCOPE_OUT"
  assert_contains "$SCOPE_OUT" 'herdr=true' \
    "the bounded fallback runs the Herdr lane: $why"$'\n'"$SCOPE_OUT"
  [ "$(scope_value selected_matrix)" = '' ] \
    || fail "the bounded fallback must emit no selection matrix: $why"
}

test_prose_only_changes_turn_both_gates_off() {
  assert_gates false false 'a docs page' docs/architecture.md
  assert_gates false false 'the README' README.md
  assert_gates false false 'a nested docs page' docs/verification/agy.md
  assert_gates false false 'several prose files at once' README.md docs/architecture.md VISION.md
  pass "prose no test reads turns both the behavior and macOS gates off"
}

test_spawn_changes_require_complete_ci() {
  local path
  for path in bin/fm-spawn.sh bin/fm-worker-park.sh bin/fm-worker-park-lib.sh bin/fm-worker-admit.py; do
    assert_full_suite "spawn admission must not drop serial or real-backend suites" "$path"
  done
  pass "spawn admission changes run every CI lane"
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
# do: a selection replaces the behavior lanes, so each case asserts the
# selection is only trusted where it is provably complete, and that every
# doubt lands back on a wider round rather than on a faster one.
# On a pull request "wider" is the bounded parallel and Herdr lanes, never the
# sixteen-shard serial fan-out; the complete suite belongs to push to main and
# the nightly schedule, which is what makes that bound safe to take.

test_a_single_script_change_selects_one_packed_job() {
  local matrix
  classify bin/fm-quota-choose.sh
  matrix=$(scope_value selected_matrix)
  assert_contains "$matrix" 'tests/fm-quota-choose.test.sh' \
    "the selection must name the suite that covers the changed script"$'\n'"$matrix"
  [ "$(printf '%s' "$matrix" | grep -c 'tests/' | tr -d ' ')" = 1 ] \
    || fail "a one-script change must select exactly its own suite"$'\n'"$matrix"
  # Runner start delay is what a short round is made of, so the whole point is
  # that one small change spends one runner.
  [ "$(printf '%s' "$matrix" | grep -c '"shard"' | tr -d ' ')" = 1 ] \
    || fail "a one-script change must pack into exactly one job"$'\n'"$matrix"
  [ "$(scope_value full)" = false ] \
    || fail "a trusted selection must turn the complete sharded suite off"
  pass "a one-script change selects its own suite in a single job"
}

test_a_selection_too_large_to_pack_falls_back_to_the_bounded_lanes() {
  # No single script exceeds the per-job budget any more now that the two
  # longest suites are split, so breadth is what the packing cannot absorb.
  # Each of these paths packs on its own; together their suites need more
  # than the job cap allows, and the round must widen rather than drop the
  # work that does not fit - but only as far as the bounded lanes.
  assert_bounded_fallback 'a change whose suites cannot be packed under the budget' \
    bin/fm-afk-launch.sh bin/fm-session-start.sh bin/fm-pr-merge.sh bin/fm-control.sh
  pass "a selection no packing fits under the budget falls back to the bounded lanes"
}

# The machinery a selection is made of is no longer special-cased: the
# runner's map answers for each of these with the family that owns it, and
# the packing budget is what keeps the answer bounded. A pull request that
# changes CI setup therefore spends a few runners rather than nineteen.
test_the_selection_machinery_selects_the_family_that_owns_it() {
  local path
  for path in .github/workflows/ci.yml .no-mistakes.yaml bin/fm-test-run.sh \
    bin/fm-test-isolation-proof.sh bin/fm-ci-change-scope.sh bin/fm-backend.sh; do
    classify "$path"
    assert_contains "$SCOPE_OUT" 'full=false' \
      "CI setup must not fan out to the serial shards: $path"$'\n'"$SCOPE_OUT"
    assert_contains "$SCOPE_OUT" 'parallel=false' \
      "a trusted selection replaces the parallel lanes too: $path"$'\n'"$SCOPE_OUT"
    [ -n "$(scope_value selected_matrix)" ] \
      || fail "CI setup must select the suites that own it: $path"$'\n'"$SCOPE_OUT"
    # Bounded, and nowhere near the nineteen long-lived jobs the complete
    # suite books. The classifier's own cap is six.
    [ "$(scope_value selected_matrix | grep -c '"shard"' | tr -d ' ')" -le 6 ] \
      || fail "the packed selection must stay inside the job cap: $path"
  done
  # The CI workflow decides which jobs exist, including the required Herdr
  # lane, so its owning families reach that lane as well.
  classify .github/workflows/ci.yml
  assert_contains "$SCOPE_OUT" 'herdr=true' \
    "a CI workflow change must still run the required Herdr lane"$'\n'"$SCOPE_OUT"
  pass "CI setup selects the families that own it instead of the complete suite"
}

# Shared test scaffolding is answered by the map too, but every suite names
# it, so the answer is the whole tree and no packing fits it. That is the
# bounded fallback's case, not the serial fan-out's.
test_shared_scaffolding_falls_back_to_the_bounded_lanes() {
  assert_bounded_fallback 'shared test scaffolding' tests/lib.sh
  assert_bounded_fallback 'the shared fixtures library' tests/fixtures.sh
  assert_bounded_fallback 'a shared helper library' tests/wake-helpers.sh
  assert_bounded_fallback 'a broadly shared library' bin/fm-dod-lib.sh
  assert_bounded_fallback 'one unpackable path beside a selectable one' \
    bin/fm-quota-choose.sh bin/fm-dod-lib.sh
  pass "shared scaffolding and broadly shared libraries run the bounded lanes"
}

test_only_pull_requests_select() {
  local out
  out=$(FM_CI_EVENT=push bash "$SCOPE") || fail "push classification failed"
  assert_contains "$out" 'full=true' "a push to main must run the complete suite"$'\n'"$out"
  assert_contains "$out" 'parallel=true' "a push to main must run both parallel lanes"$'\n'"$out"
  out=$(FM_CI_EVENT=schedule bash "$SCOPE") || fail "schedule classification failed"
  assert_contains "$out" 'full=true' "the nightly schedule must run the complete suite"$'\n'"$out"
  assert_contains "$out" 'herdr=true' "the nightly schedule must run the Herdr lane"$'\n'"$out"
  out=$(FM_CI_EVENT=workflow_dispatch bash "$SCOPE") || fail "unknown event classification failed"
  assert_contains "$out" 'full=true' "an unrecognized event must run the complete suite"$'\n'"$out"
  pass "push to main and the nightly schedule always run the complete suite"
}

# The complete suite is what a push to main and the nightly schedule run, and
# a pull request must never reach it however little the classifier knows.
test_a_pull_request_never_runs_the_complete_suite() {
  local out
  out=$(FM_CI_EVENT=pull_request FM_CI_BASE_SHA='' bash "$SCOPE") \
    || fail "classification without a base commit failed"
  assert_contains "$out" 'full=false' "a missing base commit must stay bounded"$'\n'"$out"
  assert_contains "$out" 'parallel=true' "a missing base commit still runs the lanes"$'\n'"$out"

  : >"$TMP_ROOT/empty"
  out=$(FM_CI_EVENT=pull_request FM_CI_CHANGED_PATHS_FILE="$TMP_ROOT/empty" bash "$SCOPE") \
    || fail "classification of an empty change set failed"
  assert_contains "$out" 'full=false' "an empty change set must stay bounded"$'\n'"$out"
  assert_contains "$out" 'parallel=true' "an empty change set still runs the lanes"$'\n'"$out"
  pass "a pull request never runs the complete sixteen-shard suite"
}

# A path the runner's map refuses is the map saying it does not know what
# proves this change. The round must widen, not guess. A new non-test file
# under tests/ is that shape: the map has no arm for it and says so.
test_a_path_the_map_refuses_falls_back_to_the_bounded_lanes() {
  assert_bounded_fallback 'a path the changed-file map has no arm for' tests/stray-note.txt
  pass "a path the changed-file map refuses falls back to the bounded lanes"
}

# Prose alongside code is the one shape that loses its prose check: the
# behavior jobs run, so the prose-only docs-guard job is skipped, while the
# code paths keep the selection non-empty so nothing widens. The selection
# must carry the documentation-audience suite itself.
test_prose_beside_code_keeps_the_documentation_suite() {
  classify README.md bin/fm-pr-merge.sh
  assert_contains "$SCOPE_OUT" 'full=false' \
    "a mixed prose and code change still narrows"$'\n'"$SCOPE_OUT"
  assert_contains "$(scope_value selected_matrix)" 'fm-documentation-audiences.test.sh' \
    "a mixed change must keep the documentation-audience suite"$'\n'"$SCOPE_OUT"
  assert_contains "$(scope_value selected_matrix)" 'fm-pr-merge.test.sh' \
    "a mixed change must still select the code suite"$'\n'"$SCOPE_OUT"

  # Top-level prose outside docs/ is still in the audience checker's set.
  classify VISION.md bin/fm-quota-choose.sh
  assert_contains "$SCOPE_OUT" 'full=false' \
    "top-level prose beside code still narrows"$'\n'"$SCOPE_OUT"
  assert_contains "$(scope_value selected_matrix)" 'fm-documentation-audiences.test.sh' \
    "top-level prose beside code must keep the documentation-audience suite"$'\n'"$SCOPE_OUT"

  # Prose a test reads that the map answers nothing for must not let the code
  # path's selection drop the reading test.
  assert_bounded_fallback 'the pretool doc beside code' \
    docs/arm-pretool-check.md bin/fm-quota-choose.sh
  assert_bounded_fallback 'the ignore rules beside code' .gitignore bin/fm-quota-choose.sh
  assert_bounded_fallback 'a dispatch example beside code' \
    docs/examples/crew-dispatch.json bin/fm-quota-choose.sh

  # Prose alone never reaches here: with no behavioral change the docs-guard
  # job owns it, so the selection stays empty rather than booking a job.
  classify README.md
  assert_contains "$SCOPE_OUT" 'behavior=false' \
    "prose no test reads leaves the behavior gate off"$'\n'"$SCOPE_OUT"
  [ "$(scope_value selected_matrix)" = '' ] \
    || fail "prose alone must not book a selected job"$'\n'"$SCOPE_OUT"

  pass "prose beside code keeps the documentation-audience suite"
}

# Prose a test really reads keeps the behavior gate on, but the runner's map
# answers nothing for it, so there is no selection to trust and the round must
# widen rather than run nothing.
test_a_behavior_relevant_path_that_maps_to_no_tests_runs_the_bounded_lanes() {
  assert_bounded_fallback 'prose a test reads that maps to no suite' docs/arm-pretool-check.md
  pass "a behavior-relevant path that maps to no tests runs the bounded lanes"
}

# A prose-only change has nothing to select from and keeps running the
# documentation audience guard instead.
test_prose_only_changes_select_nothing_at_all() {
  classify docs/architecture.md
  assert_contains "$SCOPE_OUT" 'behavior=false' \
    "prose must keep the behavior gate off"$'\n'"$SCOPE_OUT"
  assert_contains "$SCOPE_OUT" 'full=false' \
    "prose must not run the complete suite"$'\n'"$SCOPE_OUT"
  assert_contains "$SCOPE_OUT" 'parallel=false' \
    "prose must not run the parallel lanes"$'\n'"$SCOPE_OUT"
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

# Local coverage for configuration stays its own, much narrower thing: CI
# selects the family that owns a changed workflow, while --local selects only
# that configuration's own contract suites, because its consumer runs scripts
# on one machine rather than packed jobs on several.
test_workflow_configuration_has_separate_local_coverage() {
  local path matrix scripts
  for path in .github/workflows/ci.yml .github/workflows/other.yml .github/actions/example/action.yml .no-mistakes.yaml; do
    classify "$path"
    assert_equals false "$(scope_value full)" "CI narrows a configuration change for $path"
    assert_equals false "$(scope_value parallel)" "a trusted CI selection replaces the lanes for $path"
    [ -n "$(scope_value selected_matrix)" ] \
      || fail "CI must select the family that owns $path"$'\n'"$SCOPE_OUT"

    SCOPE_MODE=--local classify "$path"
    assert_equals false "$(scope_value full)" "local configuration coverage narrows for $path"
    assert_equals false "$(scope_value herdr)" "workflow configuration leaves full Herdr coverage to CI"
    matrix=$(scope_value selected_matrix)
    scripts=$(printf '%s' "$matrix" | jq -r '.include[].scripts' | tr ' ' '\n' | LC_ALL=C sort)
    assert_equals $'tests/fm-ci-change-scope.test.sh\ntests/fm-ci-workflow.test.sh\ntests/fm-gate-refuse.test.sh\ntests/fm-lint-workflows.test.sh\ntests/fm-nm-test-contract.test.sh' \
      "$scripts" "local configuration coverage selects exactly its contracts"
  done
  SCOPE_MODE=--local classify .github/workflows/ci.yml .no-mistakes.yaml bin/fm-quota-choose.sh README.md
  assert_equals false "$(scope_value full)" "configuration beside narrow code still narrows"
  matrix=$(scope_value selected_matrix)
  assert_contains "$matrix" tests/fm-quota-choose.test.sh "mixed changes retain normal code selection"
  assert_contains "$matrix" tests/fm-documentation-audiences.test.sh "mixed changes retain prose coverage"
  scripts=$(printf '%s' "$matrix" | jq -r '.include[].scripts' | tr ' ' '\n')
  assert_equals 7 "$(printf '%s\n' "$scripts" | sort -u | wc -l | tr -d ' ')" "mixed selection contains only the expected suites"
  assert_equals 7 "$(printf '%s\n' "$scripts" | wc -l | tr -d ' ')" "multiple configuration paths do not duplicate suites"
  pass "CI selects the owning family while local configuration coverage stays narrow"
}

# Full remains scope information with --local; local_scripts separately
# bounds what its consumer executes, while CI uses the bounded lane fallback.
test_local_mode_preserves_the_full_scope_signal() {
  local path
  for path in tests/lib.sh tests/fixtures.sh tests/wake-helpers.sh \
    bin/fm-dod-lib.sh tests/stray-note.txt docs/arm-pretool-check.md; do
    SCOPE_MODE=--local assert_full_suite "local configuration plus $path" .github/workflows/ci.yml "$path"
    assert_bounded_fallback "CI with configuration plus $path" .github/workflows/ci.yml "$path"
  done
  SCOPE_MODE=--local assert_full_suite 'local configuration plus an oversized selection' \
    .no-mistakes.yaml bin/fm-afk-launch.sh bin/fm-session-start.sh bin/fm-pr-merge.sh bin/fm-spawn.sh
  pass "local mode preserves full scope information where CI uses bounded lanes"
}

test_local_budget_covers_fast_tests_and_defers_long_or_live_work() {
  local selected deferred weighted sum budget
  SCOPE_MODE=--local classify bin/fm-quota-choose.sh
  assert_equals 'tests/fm-quota-choose.test.sh' "$(scope_value local_scripts)" "ordinary narrow coverage is unchanged"
  assert_equals '' "$(scope_value local_deferred)" "ordinary narrow coverage defers nothing"

  SCOPE_MODE=--local classify tests/fm-backend-herdr-smoke.test.sh tests/fm-quota-choose.test.sh
  assert_equals false "$(scope_value full)" "Herdr plus narrow code is not a full fallback"
  assert_equals true "$(scope_value herdr)" "Herdr scope remains visible"
  assert_equals 'tests/fm-quota-choose.test.sh' "$(scope_value local_scripts)" "Herdr selection retains relevant fast tests"
  assert_contains "$(scope_value local_deferred)" 'tests/fm-backend-herdr-smoke.test.sh' "real Herdr is deferred even if installed"

  SCOPE_MODE=--local classify tests/fm-backend-herdr-smoke.test.sh
  assert_equals 'tests/fm-nm-test-contract.test.sh' "$(scope_value local_scripts)" "all-live changes exercise the local Test contract"
  SCOPE_MODE=--local classify tests/fm-supervision-host.test.sh tests/fm-quota-choose.test.sh
  assert_equals false "$(scope_value full)" "a long narrow selection stays narrow"
  assert_equals 'tests/fm-quota-choose.test.sh' "$(scope_value local_scripts)" "a long narrow selection retains its fast portion"
  assert_equals 'tests/fm-supervision-host.test.sh' "$(scope_value local_deferred)" "long serial work is deferred"

  SCOPE_MODE=--local classify tests/lib.sh
  selected=$(scope_value local_scripts)
  deferred=$(scope_value local_deferred)
  budget=$(scope_value local_budget_ms)
  assert_contains "$SCOPE_OUT" 'full=true' "full scope remains conservative"
  [ -n "$selected" ] || fail "full scope cannot pass with zero fast tests"
  assert_contains "$deferred" 'tests/fm-supervision-host.test.sh' "full scope defers long serial work"
  assert_contains "$deferred" 'tests/fm-backend-herdr-smoke.test.sh' "full scope defers Herdr"
  assert_contains "$deferred" 'tests/fm-supervision-host-live-e2e.test.sh' "full scope defers live harnesses"
  # Repository-owned paths contain no whitespace. Ask the runner for weights
  # of the actual admitted scripts, rather than copying its timing hints.
  # shellcheck disable=SC2086
  weighted=$(bash "$ROOT/bin/fm-test-run.sh" --list-weighted $selected) || fail "cannot weigh local selection"
  sum=$(printf '%s\n' "$weighted" | awk '{ total += $1 } END { print total }')
  [ "$sum" -le "$budget" ] || fail "local full selection exceeds its modeled budget: $sum > $budget"
  pass "real local classification retains fast coverage and defers long/live suites"
}

test_local_budget_bounds_aggregate_work() {
  local repo="$TMP_ROOT/local-budget" output
  mkdir -p "$repo/bin"
  cp "$SCOPE" "$repo/bin/fm-ci-change-scope.sh"
  cat > "$repo/bin/fm-test-run.sh" <<'SH'
#!/usr/bin/env bash
case "$1" in
  --list-weighted)
    case "$*" in *--all*) [ "${REFUSE_ALL:-0}" = 0 ] || exit 2 ;; esac
    printf '%s\n' "$TEST_WEIGHTS"
    ;;
  --list) [ "$3" != real-herdr-gated ] || printf '%s\n' tests/herdr.test.sh ;;
  *) exit 2 ;;
esac
SH
  chmod +x "$repo/bin/fm-test-run.sh"
  printf '%s\n' tests/a.test.sh > "$repo/paths"
  output=$(TEST_WEIGHTS=$'100001\ttests/c.test.sh\n100000\ttests/b.test.sh\n100000\ttests/a.test.sh\n1\ttests/herdr.test.sh' \
    FM_CI_CHANGED_PATHS_FILE="$repo/paths" bash "$repo/bin/fm-ci-change-scope.sh" --local) \
    || fail "aggregate budget classification failed"
  assert_contains "$output" 'local_scripts=tests/a.test.sh tests/b.test.sh' "the cheapest scripts run in deterministic order"
  assert_contains "$output" 'local_deferred=tests/herdr.test.sh tests/c.test.sh' "aggregate overflow and Herdr go to CI"
  output=$(TEST_WEIGHTS=$'300000\ttests/exact.test.sh\n300001\ttests/over.test.sh' \
    FM_CI_CHANGED_PATHS_FILE="$repo/paths" bash "$repo/bin/fm-ci-change-scope.sh" --local) \
    || fail "boundary classification failed"
  assert_contains "$output" 'local_scripts=tests/exact.test.sh' "a script at the budget is admitted"
  assert_contains "$output" 'local_deferred=tests/over.test.sh' "a script beyond the budget is deferred"
  output=$(TEST_WEIGHTS=$'1000\ttests/relevant.test.sh\n3600001\ttests/long.test.sh' REFUSE_ALL=1 \
    FM_CI_CHANGED_PATHS_FILE="$repo/paths" bash "$repo/bin/fm-ci-change-scope.sh" --local) \
    || fail "oversized mapped selection must not widen to the full inventory"
  assert_contains "$output" 'full=true' "oversized mapped work retains full scope information"
  assert_contains "$output" 'local_scripts=tests/relevant.test.sh' "oversized mapped work retains its relevant fast portion"
  pass "the local budget bounds aggregate work, not just individual scripts"
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
test_a_selection_too_large_to_pack_falls_back_to_the_bounded_lanes
test_the_selection_machinery_selects_the_family_that_owns_it
test_shared_scaffolding_falls_back_to_the_bounded_lanes
test_only_pull_requests_select
test_a_pull_request_never_runs_the_complete_suite
test_a_path_the_map_refuses_falls_back_to_the_bounded_lanes
test_a_behavior_relevant_path_that_maps_to_no_tests_runs_the_bounded_lanes
test_prose_beside_code_keeps_the_documentation_suite
test_prose_only_changes_select_nothing_at_all
test_a_selected_herdr_member_runs_the_herdr_lane

test_workflow_configuration_has_separate_local_coverage
test_local_mode_preserves_the_full_scope_signal

test_local_budget_covers_fast_tests_and_defers_long_or_live_work
test_local_budget_bounds_aggregate_work

test_spawn_changes_require_complete_ci
