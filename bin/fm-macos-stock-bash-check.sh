#!/usr/bin/env bash
# fm-macos-stock-bash-check.sh - the stock macOS Bash 3.2 compatibility check.
#
# Single owner of what that check actually is. Two CI jobs run it: a blocking
# one on push to main and on the nightly schedule, and an advisory one on a
# pull request, which reports its own check and is deliberately outside the CI
# gate's verdict so it can never delay or fail a pull request round
# (.github/workflows/ci.yml and .github/workflows/macos-advisory.yml).
# Keeping the body here rather than inline in either workflow is what stops the
# two copies from drifting, and lets a maintainer run the same check locally.
#
# It must be invoked with the real stock interpreter, /bin/bash, because the
# whole point is what Bash 3.2.57 does with these sources. Running it under a
# newer bash proves nothing and the version assertion below refuses.
#
# Usage:
#   /bin/bash bin/fm-macos-stock-bash-check.sh
#   bin/fm-macos-stock-bash-check.sh --help     print this header
#
# Inputs, read from the environment:
#   RUNNER_TEMP   a writable scratch directory (defaults to a mktemp -d)
#
# It parses every file in bin/fm-lint.sh's canonical CI set with stock Bash,
# then runs the snapshot consumers that have a stock-Bash contract, asserting
# each one's exact passing count so a suite that silently stops running is a
# failure rather than a quiet zero. Diagnostics use GitHub's ::error:: prefix,
# which is inert outside Actions.
set -eu

case "${1:-}" in
  --help | -h)
    awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
    exit 0
    ;;
  '') ;;
  *)
    printf 'fm-macos-stock-bash-check.sh: unknown argument: %s\n' "$1" >&2
    exit 2
    ;;
esac

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

: "${RUNNER_TEMP:=$(mktemp -d "${TMPDIR:-/tmp}/fm-macos-stock-bash.XXXXXX")}"
export RUNNER_TEMP

case "$BASH_VERSION" in
  3.2.57*) ;;
  *) echo "::error::expected stock macOS Bash 3.2.57, got $BASH_VERSION"; exit 1 ;;
esac
/bin/bash --version | head -1
command -v jq >/dev/null || { echo "::error::jq is required"; exit 1; }

shell_inventory="$RUNNER_TEMP/fm-shell-inventory"
bin/fm-lint.sh --list-files > "$shell_inventory"
parse_fail=0
while IFS= read -r f; do
  /bin/bash -n "$f" || { echo "::error::stock macOS Bash 3.2 failed to parse $f"; parse_fail=1; }
done < "$shell_inventory"
[ "$parse_fail" -eq 0 ] || { echo "::error::stock macOS Bash 3.2 parse sweep failed"; exit 1; }

command -v npm >/dev/null || { echo "::error::npm is required to install tasks-axi"; exit 1; }
npm install -g tasks-axi@0.2.6 >/dev/null
PATH="$(npm prefix -g)/bin:$PATH"
export PATH
command -v tasks-axi >/dev/null || { echo "::error::tasks-axi is required for the stock Bash regressions"; exit 1; }

# Derive full-suite expectations from the same manifest that executes them,
# never from their output: a silent skip must still fail the passing-count check.
suite_count() {  # <suite> [known capability-skipped test]
  local selected test_case count=0
  selected=$(/bin/bash "$1" --list-tests) || return 1
  while IFS= read -r test_case; do
    [ -n "$test_case" ] || continue
    [ "$test_case" != "${2:-}" ] || continue
    count=$((count + 1))
  done <<EOF
$selected
EOF
  [ "$count" -gt 0 ] || { echo "::error::empty test selection: $1" >&2; return 1; }
  printf '%s\n' "$count"
}

# Keep failing-suite diagnostics visible even though passing output is captured.
run_suite() {
  local output rc=0
  output=$(/bin/bash "$@") || rc=$?
  if [ "$rc" -ne 0 ]; then
    printf '%s\n' "$output" >&2
    return "$rc"
  fi
  printf '%s\n' "$output"
}

snapshot_expected=$(suite_count tests/fm-fleet-snapshot-view.test.sh)
snapshot_output=$(run_suite tests/fm-fleet-snapshot-view.test.sh)
printf '%s\n' "$snapshot_output"
snapshot_count=$(printf '%s\n' "$snapshot_output" | grep -c '^ok - ' || true)
[ "$snapshot_count" -eq "$snapshot_expected" ] || {
  echo "::error::expected $snapshot_expected snapshot/fleet-view tests, got $snapshot_count"
  exit 1
}

bearings_expected=$(suite_count tests/fm-bearings-snapshot.test.sh)
bearings_output=$(run_suite tests/fm-bearings-snapshot.test.sh)
printf '%s\n' "$bearings_output"
bearings_count=$(printf '%s\n' "$bearings_output" | grep -c '^ok - ' || true)
[ "$bearings_count" -eq "$bearings_expected" ] || {
  echo "::error::expected $bearings_expected Bearings tests, got $bearings_count"
  exit 1
}

# The full public-followup suite is not a stock-bash snapshot; run only
# the empty-lock register regression under real /bin/bash 3.2.
pf_output=$(FM_TEST_ONLY=test_first_register_succeeds_with_empty_lock_list_under_bash32 \
  run_suite tests/fm-public-followup.test.sh)
printf '%s\n' "$pf_output"
pf_count=$(printf '%s\n' "$pf_output" | grep -c '^ok - ' || true)
[ "$pf_count" -eq 1 ] || {
  echo "::error::expected 1 public-followup bash 3.2 register regression, got $pf_count"
  exit 1
}

# Same shape for the watcher's churn-deferral regression: an already-
# marked churn window expands an empty array that only stock Bash
# treats as an unbound variable under set -u.
churn_output=$(FM_TEST_ONLY=test_turn_ended_churn_existing_marker_absorbed \
  run_suite tests/fm-watch-triage.test.sh)
printf '%s\n' "$churn_output"
churn_count=$(printf '%s\n' "$churn_output" | grep -c '^ok - ' || true)
[ "$churn_count" -eq 1 ] || {
  echo "::error::expected 1 watcher churn-deferral bash 3.2 regression, got $churn_count"
  exit 1
}

# The fork-free hot-path helpers must stay byte-identical to the
# commands they replace under stock Bash 3.2, which lacks the
# printf %(...)T clock and falls back to date.
# The fork-budget sampler capability-skips under 3.2 because it needs BASHPID.
helpers_expected=$(suite_count tests/fm-fork-free-helpers.test.sh \
  test_crew_state_and_snapshot_stay_within_their_fork_budget)
helpers_output=$(run_suite tests/fm-fork-free-helpers.test.sh)
printf '%s\n' "$helpers_output"
helpers_count=$(printf '%s\n' "$helpers_output" | grep -c '^ok - ' || true)
[ "$helpers_count" -eq "$helpers_expected" ] || {
  echo "::error::expected $helpers_expected fork-free helper bash 3.2 regressions, got $helpers_count"
  exit 1
}

backend_output=$(FM_TEST_ONLY=test_backend_source_requires_adapter_file \
  FM_TEST_BASH=/bin/bash \
  run_suite tests/fm-backend.test.sh)
printf '%s\n' "$backend_output"
backend_count=$(printf '%s\n' "$backend_output" | grep -c '^ok - ' || true)
[ "$backend_count" -eq 2 ] || {
  echo "::error::expected 2 backend adapter-file bash 3.2 regressions, got $backend_count"
  exit 1
}
