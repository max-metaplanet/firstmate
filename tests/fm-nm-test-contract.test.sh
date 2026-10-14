#!/usr/bin/env bash
# Contract: the configured no-mistakes commands.test runs what the CI change-scope
# selector chooses, falls back to the full suite when the mapping is unknown, and
# fails when selection fails. The command is executed against stub selector and
# runner scripts so each branch is checked by the argv it hands the runner.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

NM="$ROOT/.no-mistakes.yaml"
TMP_ROOT=$(fm_test_tmproot nm-test-contract)

command -v ruby >/dev/null 2>&1 \
  || fail "ruby is required to parse .no-mistakes.yaml for this contract"
command -v jq >/dev/null 2>&1 \
  || fail "jq is required by the configured commands.test"

TEST_CMD=$(ruby -ryaml -e '
doc = YAML.load_file(ARGV[0]) || {}
cmds = doc["commands"] || {}
print cmds.is_a?(Hash) ? cmds["test"].to_s : ""
' "$NM") || fail "failed to parse .no-mistakes.yaml as YAML"
[ -n "$TEST_CMD" ] || fail "commands.test must be configured"

# Fixture checkout: bin/fm-ci-change-scope.sh prints $SCOPE_OUT and exits
# $SCOPE_RC; bin/fm-test-run.sh records its argv, answers --list with a fixed
# Herdr family, and exits $RUN_RC.
FIX="$TMP_ROOT/repo"
mkdir -p "$FIX/bin"
cat > "$FIX/bin/fm-ci-change-scope.sh" <<'SH'
[ "$#" -eq 1 ] && [ "$1" = --local ] || exit 2
printf '%s\n' "$SCOPE_OUT"
exit "${SCOPE_RC:-0}"
SH
cat > "$FIX/bin/fm-test-run.sh" <<'SH'
if [ "${1:-}" = "--list" ]; then
  printf '%s\n' tests/h1.test.sh tests/h2.test.sh
  exit 0
fi
printf '%s\n' "$*" > "$RUN_LOG"
exit "${RUN_RC:-0}"
SH

# run_cmd <scope-output> [scope-rc] [run-rc]: sets RC and ARGV.
run_cmd() {
  local log="$TMP_ROOT/argv"
  rm -f "$log"
  RC=0
  (cd "$FIX" && SCOPE_OUT=$1 SCOPE_RC=${2:-0} RUN_RC=${3:-0} RUN_LOG=$log \
    sh -c "$TEST_CMD") >/dev/null 2>&1 || RC=$?
  ARGV=$(cat "$log" 2>/dev/null || printf '<not run>')
}

M='{"include":[{"shard":"0","scripts":"tests/a.test.sh tests/b.test.sh"},{"shard":"1","scripts":"tests/c.test.sh"}]}'

run_cmd $'behavior=true\nfull=false\nherdr=false\nselected_matrix='"$M"
expect_code 0 "$RC" "selected tests"
assert_equals "--per-script-timeout-secs 1500 tests/a.test.sh tests/b.test.sh tests/c.test.sh" "$ARGV" "selected matrix scripts reach the runner"
pass "selected matrix scripts run with the per-script bound"

run_cmd $'behavior=false\nfull=false\nherdr=false\nselected_matrix='
expect_code 0 "$RC" "behavior-inert change"
assert_equals "tests/fm-documentation-audiences.test.sh" "$ARGV" "behavior-inert change runs the documentation suite"
pass "behavior-inert change runs only the documentation-audience suite"

run_cmd $'behavior=true\nfull=true\nherdr=false\nselected_matrix='
expect_code 0 "$RC" "unknown mapping"
assert_equals "--all --per-script-timeout-secs 1500" "$ARGV" "unknown mapping runs the full suite"
pass "unknown mapping falls back to the full suite"

run_cmd $'behavior=true\nfull=false\nherdr=true\nselected_matrix={"include":[{"shard":"0","scripts":"tests/a.test.sh"}]}'
expect_code 0 "$RC" "herdr selection"
assert_equals "--per-script-timeout-secs 1500 tests/a.test.sh tests/h1.test.sh tests/h2.test.sh" "$ARGV" "herdr selection adds the real-herdr-gated family"
pass "herdr selection adds the real-herdr-gated family"

run_cmd $'behavior=true\nfull=false\nherdr=false\nselected_matrix='
expect_code 1 "$RC" "empty selection"
assert_equals "<not run>" "$ARGV" "empty selection must not invoke the runner"
pass "empty selection fails without running tests"

run_cmd "" 3
expect_code 3 "$RC" "selector failure"
assert_equals "<not run>" "$ARGV" "selector failure must not invoke the runner"
pass "selector failure fails the command"

run_cmd $'behavior=true\nfull=false\nherdr=false\nselected_matrix='"$M" 0 1
expect_code 1 "$RC" "failing selected test"
pass "a failing selected test fails the command"

# Execute the configured command with the real classifier and selection map;
# intercept only the final test execution to avoid recursively running this suite.
cp "$ROOT/bin/fm-ci-change-scope.sh" "$FIX/bin/fm-ci-change-scope.sh"
cat > "$FIX/bin/fm-test-run.sh" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  --list-weighted | --list) exec bash "$REAL_RUNNER" "$@" ;;
esac
printf '%s\n' "$*" > "$RUN_LOG"
SH
chmod +x "$FIX/bin/fm-test-run.sh"
for path in .github/workflows/ci.yml .github/actions/example/action.yml .no-mistakes.yaml; do
  printf '%s\n' "$path" bin/fm-quota-choose.sh > "$TMP_ROOT/changed-paths"
  REAL_RUNNER="$ROOT/bin/fm-test-run.sh" FM_CI_CHANGED_PATHS_FILE="$TMP_ROOT/changed-paths" run_cmd ''
  expect_code 0 "$RC" "real local classifier for $path"
  assert_contains "$ARGV" '--per-script-timeout-secs 1500' "the timeout remains unchanged"
  scripts=$(printf '%s\n' "$ARGV" | tr ' ' '\n' | tail -n +3 | LC_ALL=C sort)
  assert_equals $'tests/fm-ci-change-scope.test.sh\ntests/fm-ci-workflow.test.sh\ntests/fm-gate-refuse.test.sh\ntests/fm-lint-workflows.test.sh\ntests/fm-nm-test-contract.test.sh\ntests/fm-quota-choose.test.sh' \
    "$scripts" "configured local Test runs contracts plus normal narrow selection"
done
printf '%s\n' .github/workflows/ci.yml bin/fm-ci-change-scope.sh > "$TMP_ROOT/changed-paths"
REAL_RUNNER="$ROOT/bin/fm-test-run.sh" FM_CI_CHANGED_PATHS_FILE="$TMP_ROOT/changed-paths" run_cmd ''
expect_code 0 "$RC" "real local classifier with selection machinery changed"
assert_equals "--all --per-script-timeout-secs 1500" "$ARGV" "machinery changes retain full local validation"
pass "configured Test uses real local classification and preserves other full-suite fallbacks"
