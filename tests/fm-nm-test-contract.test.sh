#!/usr/bin/env bash
# Contract: commands.test consumes the classifier's bounded local selection,
# reports coverage deferred to CI, and propagates selection/test/deadline failures.
# Stub only final execution when testing the real classifier and runner map.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

NM="$ROOT/.no-mistakes.yaml"
TMP_ROOT=$(fm_test_tmproot nm-test-contract)
command -v ruby >/dev/null 2>&1 || fail "ruby is required to parse .no-mistakes.yaml"
command -v jq >/dev/null 2>&1 || fail "jq is required by the classifier contract"
TEST_CMD=$(ruby -ryaml -e 'print YAML.load_file(ARGV[0]).fetch("commands").fetch("test")' "$NM") \
  || fail "failed to parse .no-mistakes.yaml"
[ -n "$TEST_CMD" ] || fail "commands.test must be configured"

FIX="$TMP_ROOT/repo"
mkdir -p "$FIX/bin"
cp "$ROOT/bin/fm-timeout-lib.sh" "$FIX/bin/"
cat > "$FIX/bin/fm-ci-change-scope.sh" <<'SH'
[ "$#" -eq 1 ] && [ "$1" = --local ] || exit 2
printf '%s\n' "$SCOPE_OUT"
exit "${SCOPE_RC:-0}"
SH
cat > "$FIX/bin/fm-test-run.sh" <<'SH'
printf '%s\n' "$*" > "$RUN_LOG"
[ -z "${RUN_SLEEP:-}" ] || sleep "$RUN_SLEEP"
exit "${RUN_RC:-0}"
SH

# run_cmd <scope-output> [scope-rc] [run-rc]: sets RC, ARGV, and OUT.
run_cmd() {
  local log="$TMP_ROOT/argv" output="$TMP_ROOT/output"
  rm -f "$log"
  RC=0
  (cd "$FIX" && SCOPE_OUT=$1 SCOPE_RC=${2:-0} RUN_RC=${3:-0} RUN_LOG=$log \
    sh -c "$TEST_CMD") >"$output" 2>&1 || RC=$?
  ARGV=$(cat "$log" 2>/dev/null || printf '<not run>')
  OUT=$(cat "$output")
}

run_cmd $'behavior=true\nfull=false\nherdr=false\nlocal_budget_ms=300000\nlocal_scripts=tests/a.test.sh tests/b.test.sh tests/c.test.sh\nlocal_deferred='
expect_code 0 "$RC" "ordinary narrow selection"
assert_equals "--per-script-timeout-secs 1500 tests/a.test.sh tests/b.test.sh tests/c.test.sh" "$ARGV" "narrow scripts reach the runner unchanged"
pass "ordinary narrow selection runs unchanged"

run_cmd $'behavior=false\nlocal_budget_ms=300000\nlocal_scripts=tests/fm-documentation-audiences.test.sh\nlocal_deferred='
expect_code 0 "$RC" "behavior-inert change"
assert_equals "--per-script-timeout-secs 1500 tests/fm-documentation-audiences.test.sh" "$ARGV" "prose runs the documentation suite"
pass "behavior-inert changes run the documentation-audience suite"

run_cmd $'behavior=true\nfull=true\nherdr=true\nlocal_budget_ms=300000\nlocal_scripts=tests/fast.test.sh\nlocal_deferred=tests/slow.test.sh tests/herdr.test.sh'
expect_code 0 "$RC" "full scope"
assert_equals "--per-script-timeout-secs 1500 tests/fast.test.sh" "$ARGV" "full scope runs only its local selection"
assert_contains "$OUT" "Left to CI's required lanes (CI gate): tests/slow.test.sh tests/herdr.test.sh" "deferrals are explicit on one line"
pass "full scope does not expand to --all or a Herdr family"

run_cmd $'behavior=true\nfull=false\nherdr=true\nlocal_budget_ms=300000\nlocal_scripts=tests/fast.test.sh\nlocal_deferred=tests/herdr.test.sh'
expect_code 0 "$RC" "Herdr selection"
assert_equals "--per-script-timeout-secs 1500 tests/fast.test.sh" "$ARGV" "Herdr coverage stays with CI"
pass "Herdr selection runs only fast local coverage"

run_cmd $'local_budget_ms=300000\nlocal_scripts='
expect_code 1 "$RC" "empty selection"
assert_equals "<not run>" "$ARGV" "empty selection must not invoke the runner"
run_cmd "" 3
expect_code 3 "$RC" "selector failure"
assert_equals "<not run>" "$ARGV" "selector failure must not invoke the runner"
run_cmd $'local_budget_ms=0\nlocal_scripts=tests/a.test.sh'
expect_code 1 "$RC" "invalid budget"
assert_equals "<not run>" "$ARGV" "invalid budget must not run unbounded"
run_cmd $'local_budget_ms=300000\nlocal_scripts=tests/a.test.sh' 0 1
expect_code 1 "$RC" "failing selected test"
RUN_SLEEP=2 run_cmd $'local_budget_ms=1000\nlocal_scripts=tests/a.test.sh'
expect_code 0 "$RC" "loaded execution may exceed modeled work"
assert_equals "--per-script-timeout-secs 1500 tests/a.test.sh" "$ARGV" "load allowance preserves selected coverage and per-script bounds"
RUN_SLEEP=5 run_cmd $'local_budget_ms=1000\nlocal_scripts=tests/a.test.sh'
expect_code 124 "$RC" "stale weights hit a hard deadline"
pass "empty/failed selection, failed tests, and a hard deadline cannot pass silently"

# Execute real classification and selection without running any selected suite.
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
  scripts=$(printf '%s\n' "$ARGV" | tr ' ' '\n' | tail -n +3 | LC_ALL=C sort)
  assert_equals $'tests/fm-ci-change-scope.test.sh\ntests/fm-ci-workflow.test.sh\ntests/fm-gate-refuse.test.sh\ntests/fm-lint-workflows.test.sh\ntests/fm-nm-test-contract.test.sh\ntests/fm-quota-choose.test.sh' \
    "$scripts" "local Test runs configuration contracts plus narrow code coverage"
done

# Shared scaffolding forces full scope; the real command must still run fast
# tests and report the long remainder without executing any long suite here.
printf '%s\n' tests/lib.sh > "$TMP_ROOT/changed-paths"
REAL_RUNNER="$ROOT/bin/fm-test-run.sh" FM_CI_CHANGED_PATHS_FILE="$TMP_ROOT/changed-paths" run_cmd ''
expect_code 0 "$RC" "shared-scaffolding full fallback"
assert_contains "$OUT" 'full=true' "scope remains conservative"
assert_contains "$ARGV" 'tests/' "full scope still executes fast tests"
assert_contains "$OUT" "Left to CI's required lanes (CI gate):" "the command reports deferred coverage"
case "$ARGV" in *--all*|*--family*) fail "full scope must not expand locally" ;; esac
pass "configured Test consumes real classification and bounds its full fallback"
