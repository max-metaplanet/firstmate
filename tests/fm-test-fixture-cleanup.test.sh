#!/usr/bin/env bash
# Behavior tests for tests/lib.sh's shared fixture-tempdir helper
# (fm_test_tmproot / fm_test_cleanup / fm_test_reap_orphans).
#
# The near-universal call pattern across this suite is
# `TMP_ROOT=$(fm_test_tmproot prefix)`, which forks a subshell to capture the
# function's stdout. These tests spawn real, separate bash processes that use
# that exact pattern and assert the fixture root is actually gone once the
# owning process's guarded teardown has run - on a normal exit and on a
# terminating signal - plus that a stale marked fixture from a killed prior
# run gets reaped on the next source. Nothing here inspects tests/lib.sh's
# source text; it only observes filesystem state around the real helper.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LIB="$ROOT/tests/lib.sh"

test_fixture_root_gone_after_normal_exit() {
  local child_out child_dir
  child_out=$(bash -c '
    # shellcheck source=tests/lib.sh
    . "'"$LIB"'"
    d=$(fm_test_tmproot fm-test-cleanup-exit)
    printf "%s\n" "$d"
    if [ -d "$d" ]; then printf "mid:present\n"; else printf "mid:missing\n"; fi
  ')
  child_dir=$(printf '%s\n' "$child_out" | sed -n '1p')
  assert_contains "$child_out" "mid:present" \
    "the fixture root was not present while its owning process was still alive"
  assert_absent "$child_dir" \
    "fm_test_tmproot's fixture root survived its owning process's normal exit"
  pass "fm_test_tmproot cleans up its fixture root on normal exit"
}

test_fixture_root_gone_after_sigterm() {
  local harness dirfile child_dir pid tries
  harness=$(fm_test_tmproot fm-test-cleanup-sigterm-harness)
  dirfile="$harness/child-dir"
  bash -c '
    # shellcheck source=tests/lib.sh
    . "'"$LIB"'"
    d=$(fm_test_tmproot fm-test-cleanup-term)
    printf "%s\n" "$d" > "'"$dirfile"'"
    while :; do sleep 0.1; done
  ' &
  pid=$!
  tries=0
  while [ "$tries" -lt 100 ]; do
    [ -s "$dirfile" ] && break
    sleep 0.05
    tries=$((tries + 1))
  done
  [ -s "$dirfile" ] || fail "the child never published its fixture root before the wait timed out"
  child_dir=$(cat "$dirfile")
  assert_present "$child_dir" "the child's fixture root did not exist before it was signaled"
  kill -TERM "$pid"
  wait "$pid" 2>/dev/null
  assert_absent "$child_dir" \
    "fm_test_tmproot's fixture root survived SIGTERM to its owning process"
  pass "fm_test_tmproot cleans up its fixture root on SIGTERM"
}

test_cleanup_registry_resists_precreation() {
  local harness shared_tmp victim
  harness=$(fm_test_tmproot fm-test-cleanup-registry-harness)
  shared_tmp="$harness/shared-tmp"
  victim="$harness/victim"
  mkdir -p "$shared_tmp" "$victim"

  TMPDIR="$shared_tmp" bash -c '
    printf "%s\n" "$1" > "$TMPDIR/.fm-test-cleanup.$$"
    . "$2"
  ' _ "$victim" "$LIB"

  assert_present "$victim" \
    "a precreated predictable cleanup registry injected an arbitrary deletion target"
  pass "the cleanup registry cannot be injected through path precreation"
}

test_fixture_registration_failure_rolls_back_root() {
  local harness failure_tmp registry_dir output leaked_root
  harness=$(fm_test_tmproot fm-test-cleanup-registration-harness)
  failure_tmp="$harness/tmp"
  registry_dir="$harness/registry-dir"
  mkdir -p "$failure_tmp" "$registry_dir"

  if output=$(TMPDIR="$failure_tmp" FM_TEST_CLEANUP_REGISTRY="$registry_dir" \
    fm_test_tmproot fm-test-cleanup-registration-failure 2>/dev/null); then
    fail "fm_test_tmproot succeeded after its cleanup registry rejected registration"
  fi
  [ -z "$output" ] || fail "fm_test_tmproot published an unregistered fixture root"
  for leaked_root in "$failure_tmp"/fm-test-cleanup-registration-failure.*; do
    [ ! -e "$leaked_root" ] || fail "fm_test_tmproot leaked a root after registration failed"
  done
  pass "failed fixture registration rolls back the new root"
}

test_orphan_sweep_respects_fixture_ownership() {
  local harness dirfile active_dir stale_dir fresh_dir pid tries
  harness=$(fm_test_tmproot fm-test-cleanup-orphan-harness)
  dirfile="$harness/active-dir"
  bash -c '
    # shellcheck source=tests/lib.sh
    . "'"$LIB"'"
    d=$(fm_test_tmproot fm-test-cleanup-active)
    printf "%s\n" "$d" > "'"$dirfile"'"
    while :; do sleep 0.1; done
  ' &
  pid=$!
  tries=0
  while [ "$tries" -lt 100 ]; do
    [ -s "$dirfile" ] && break
    sleep 0.05
    tries=$((tries + 1))
  done
  [ -s "$dirfile" ] || fail "the active child never published its fixture root before the wait timed out"
  active_dir=$(cat "$dirfile")
  touch -t 202001010000 "$active_dir/.fm-test-fixture"

  stale_dir=$(mktemp -d "$FM_TEST_TMPDIR/fm-test-cleanup-stale.XXXXXX")
  printf '%s\n%s\n' "$$" reused-process-identity > "$stale_dir/.fm-test-fixture"
  touch -t 202001010000 "$stale_dir/.fm-test-fixture"
  fresh_dir=$(mktemp -d "$FM_TEST_TMPDIR/fm-test-cleanup-fresh.XXXXXX")
  : > "$fresh_dir/.fm-test-fixture"

  bash -c '
    # shellcheck source=tests/lib.sh
    . "'"$LIB"'"
  '

  assert_absent "$stale_dir" \
    "a stale fixture root whose PID was reused by another process was not reaped"
  assert_present "$active_dir" \
    "the orphan reaper removed an old fixture root whose owning process was still alive"
  assert_present "$fresh_dir" \
    "the orphan reaper removed a fresh marked fixture root it does not own yet"
  kill -TERM "$pid"
  wait "$pid" 2>/dev/null
  assert_absent "$active_dir" \
    "the active fixture root survived its owning process's teardown"
  rm -rf "$fresh_dir"
  pass "the orphan sweep reaps only old fixtures without a live owner"
}

test_orphan_sweep_reaps_read_only_package_tree() {
  local stale_dir package_dir
  stale_dir=$(mktemp -d "$FM_TEST_TMPDIR/fm-test-cleanup-read-only.XXXXXX")
  package_dir="$stale_dir/packages/extension"
  mkdir -p "$package_dir"
  printf '%s\n%s\n' "$$" reused-process-identity > "$stale_dir/.fm-test-fixture"
  printf 'installed package\n' > "$package_dir/entrypoint.py"
  chmod -R a-w "$stale_dir/packages"
  touch -t 202001010000 "$stale_dir/.fm-test-fixture"

  bash -c '
    # shellcheck source=tests/lib.sh
    . "$1"
  ' _ "$LIB"

  assert_absent "$stale_dir" \
    "the orphan reaper left a stale fixture containing a read-only package tree"
  pass "the orphan sweep reaps read-only package fixtures"
}

test_registries_avoid_git_worktree_root() {
  # A TMPDIR pointed at a repository root used to place live `.fm-test-*`
  # registries beside tracked files. A concurrent git add during a suite then
  # committed them (observed on the claim-walk CI fix round). The helper must
  # keep registries and fixture roots outside that root for the whole run.
  local harness repo dirfile child_dir pid tries entry
  harness=$(fm_test_tmproot fm-test-cleanup-gitroot-harness)
  repo="$harness/repo"
  dirfile="$harness/child-dir"
  mkdir -p "$repo"
  git -C "$repo" init -q
  bash -c '
    export TMPDIR="$1"
    # shellcheck source=tests/lib.sh
    . "$2"
    d=$(fm_test_tmproot fm-test-cleanup-gitroot)
    printf "%s\n" "$d" > "$3"
    # Hold the suite open so a concurrent add would see any root-side leak.
    while :; do sleep 0.1; done
  ' _ "$repo" "$LIB" "$dirfile" &
  pid=$!
  tries=0
  while [ "$tries" -lt 100 ]; do
    [ -s "$dirfile" ] && break
    sleep 0.05
    tries=$((tries + 1))
  done
  [ -s "$dirfile" ] || fail "the git-root TMPDIR child never published its fixture root"
  child_dir=$(cat "$dirfile")
  assert_present "$child_dir" "the git-root TMPDIR child did not create a fixture root"
  case "$child_dir" in
    "$repo"|"$repo"/*)
      fail "fm_test_tmproot placed a fixture root inside the git worktree root: $child_dir"
      ;;
  esac
  for entry in "$repo"/.fm-test-cleanup.* "$repo"/.fm-test-procevent.* "$repo"/.fm-test-watcher.*; do
    [ ! -e "$entry" ] || fail "a live test registry landed in the git worktree root: $entry"
  done
  kill -TERM "$pid"
  wait "$pid" 2>/dev/null || true
  assert_absent "$child_dir" \
    "the git-root TMPDIR child's fixture root survived SIGTERM"
  pass "test registries and fixture roots stay out of a git worktree TMPDIR"
}

test_fixture_roots_land_beside_the_checkout_not_in_the_machine_tmpdir() {
  # Fixture trees used to be created under $TMPDIR, which on macOS is a
  # directory endpoint security scans; a suite walk's churn there was measured
  # at 7-8% of one machine's whole scan load. A suite that runs on its own,
  # with no runner above it, must still place its fixtures beside the checkout.
  # The control TMPDIR is the contrast: it must be empty afterwards.
  local expected harness control child_out child_dir leftovers
  expected="$(dirname "$ROOT")/.fm-test-scratch"
  harness=$(fm_test_tmproot fm-test-scratch-standalone)
  control="$harness/control-tmpdir"
  mkdir -p "$control"
  # shellcheck disable=SC2016  # the child reads its OWN scratch root, not ours.
  child_out=$(env -u FM_TEST_SCRATCH_ROOT TMPDIR="$control" TMP="$control" bash -c '
    # shellcheck source=tests/lib.sh
    . "$1"
    printf "%s\n" "$(fm_test_tmproot fm-test-scratch-standalone-child)"
    printf "%s\n" "$FM_TEST_SCRATCH_ROOT"
  ' _ "$LIB")
  child_dir=$(printf '%s\n' "$child_out" | sed -n '1p')
  case "$child_dir" in
    "$expected"/*) : ;;
    *) fail "a standalone suite placed its fixture root outside $expected: '$child_dir'" ;;
  esac
  [ "$(printf '%s\n' "$child_out" | sed -n '2p')" = "$expected" ] \
    || fail "the standalone suite published the wrong scratch root:"$'\n'"$child_out"
  leftovers=$(find "$control" -mindepth 1 2>/dev/null)
  [ -z "$leftovers" ] \
    || fail "a standalone suite wrote into the machine temp directory it inherited:"$'\n'"$leftovers"
  assert_absent "$child_dir" \
    "the standalone suite's fixture root survived its owning process's exit"
  pass "a standalone suite's fixtures land beside the checkout instead of in the machine temp directory"
}

test_a_fixture_home_beside_the_checkout_is_not_inside_the_repo() {
  # The reason the scratch root is a sibling of the checkout rather than a
  # directory in it: a firstmate home inside the firstmate repo is refused on
  # purpose, so fixtures that build one would all start failing.
  local expected
  expected="$(dirname "$ROOT")/.fm-test-scratch"
  case "$expected" in
    "$ROOT"|"$ROOT"/*)
      fail "the scratch root is inside the firstmate repo, where a fixture home is refused: $expected"
      ;;
  esac
  case "$(fm_test_tmproot fm-test-scratch-home)" in
    "$ROOT"|"$ROOT"/*)
      fail "a fixture root was placed inside the firstmate repo, where a fixture home is refused"
      ;;
  esac
  pass "a fixture root is placed beside the firstmate repo, never inside it"
}

test_an_inherited_scratch_root_is_left_alone() {
  # bin/fm-test-run.sh hands each concurrent worker a private TMPDIR under the
  # scratch root so their mktemp roots cannot collide. Re-pointing TMPDIR here
  # would collapse every worker back onto one directory, so an inherited
  # FM_TEST_SCRATCH_ROOT means the entry point above already decided.
  local harness inherited worker child_tmpdir
  harness=$(fm_test_tmproot fm-test-scratch-inherited)
  inherited="$harness/scratch"
  worker="$inherited/w1/tmp"
  mkdir -p "$worker"
  child_tmpdir=$(FM_TEST_SCRATCH_ROOT="$inherited" TMPDIR="$worker" TMP="$worker" bash -c '
    # shellcheck source=tests/lib.sh
    . "$1"
    printf "%s\n" "$TMPDIR"
  ' _ "$LIB")
  [ "$child_tmpdir" = "$worker" ] \
    || fail "sourcing the library re-pointed a worker's inherited TMPDIR: '$child_tmpdir'"
  pass "a suite under an inherited scratch root keeps the TMPDIR it was handed"
}

test_a_scratch_fixture_is_not_inside_any_repository() {
  # Git's upward search for a .git would hand a fixture that is deliberately
  # NOT a repository whatever repository encloses the scratch root - the exact
  # signal bin/fm-role-lib.sh reads to decide a project IS firstmate.
  local dir out
  dir="$(fm_test_tmproot fm-test-scratch-lineage)/not-a-repo"
  mkdir -p "$dir"
  out=$(git -C "$dir" rev-parse --git-common-dir 2>&1) \
    && fail "a fixture under the scratch root resolved a repository: $out"
  pass "a fixture directory under the scratch root is not inside any git repository"
}

test_fixture_root_gone_after_normal_exit
test_fixture_root_gone_after_sigterm
test_cleanup_registry_resists_precreation
test_fixture_registration_failure_rolls_back_root
test_orphan_sweep_respects_fixture_ownership
test_orphan_sweep_reaps_read_only_package_tree
test_registries_avoid_git_worktree_root
test_fixture_roots_land_beside_the_checkout_not_in_the_machine_tmpdir
test_a_fixture_home_beside_the_checkout_is_not_inside_the_repo
test_an_inherited_scratch_root_is_left_alone
test_a_scratch_fixture_is_not_inside_any_repository
