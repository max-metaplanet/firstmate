#!/usr/bin/env bash
# Behavioral required-check CI wait tests through the public command.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TASK_TMP=$(fm_test_tmproot fm-pr-checks)
FAKEBIN=$(fm_fakebin "$TASK_TMP")
export CHECK_FIXTURE=$TASK_TMP
cat > "$FAKEBIN/gh" <<'SH'
#!/usr/bin/env bash
case "$*" in
  'pr view '*)
    cat "$CHECK_FIXTURE/view.json"
    if [ -f "$CHECK_FIXTURE/next.json" ]; then
      mv "$CHECK_FIXTURE/next.json" "$CHECK_FIXTURE/view.json"
    fi
    ;;
  *'/rules/branches/main') cat "$CHECK_FIXTURE/rules.json" ;;
  *'/branches/main') cat "$CHECK_FIXTURE/branch.json" ;;
  *'/check-runs') cat "$CHECK_FIXTURE/runs.json" ;;
  *) printf 'unexpected gh call: %s\n' "$*" >&2; exit 91 ;;
esac
SH
chmod +x "$FAKEBIN/gh"
export PATH="$FAKEBIN:$PATH"
HEAD=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
URL=https://github.com/example/repo/pull/9
printf '{"protected":false}\n' > "$TASK_TMP/branch.json"
printf '[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"CI gate"}]}}]\n' > "$TASK_TMP/rules.json"

view() {
  jq -nc --arg head "$HEAD" --arg status "$1" --arg conclusion "$2" \
    --arg advisory "$3" --arg optional "$4" \
    '{headRefOid:$head,baseRefName:"main",statusCheckRollup:[
      {__typename:"CheckRun",name:"CI gate",status:$status,conclusion:$conclusion},
      {__typename:"CheckRun",name:"Mac",status:$advisory,conclusion:$optional},
      {__typename:"StatusContext",context:"optional-status",state:"FAILURE"}]}'
}
expect_result() {
  local expected=$1 rc=0
  shift
  "$ROOT/bin/fm-pr-checks.sh" "$@" "$URL" > "$TASK_TMP/out" 2> "$TASK_TMP/err" || rc=$?
  [ "$rc" = "$expected" ] || fail "expected $expected, got $rc: $(cat "$TASK_TMP/err")"
}

for advisory in pending red; do
  if [ "$advisory" = pending ]; then
    view COMPLETED SUCCESS IN_PROGRESS '' > "$TASK_TMP/view.json"
  else
    view COMPLETED SUCCESS COMPLETED FAILURE > "$TASK_TMP/view.json"
  fi
  expect_result 0 --watch
  [ ! -s "$TASK_TMP/out" ] || fail "advisory $advisory blocked"
done
pass 'advisory pending/red check runs and red status contexts never block'

view IN_PROGRESS '' COMPLETED SUCCESS > "$TASK_TMP/view.json"
expect_result 8
assert_grep 'CI gate (pending)' "$TASK_TMP/out" 'required pending not reported'
view COMPLETED FAILURE COMPLETED SUCCESS > "$TASK_TMP/view.json"
expect_result 1 --watch
assert_grep 'CI gate (red)' "$TASK_TMP/out" 'required failure not reported'
pass 'required pending waits and required red fails'

view COMPLETED SUCCESS IN_PROGRESS '' | jq '.statusCheckRollup |= map(select(.name != "CI gate"))' > "$TASK_TMP/view.json"
expect_result 8
assert_grep 'CI gate (missing)' "$TASK_TMP/out" 'unreported required check not reported'
view COMPLETED SUCCESS IN_PROGRESS '' > "$TASK_TMP/next.json"
FM_PR_CHECKS_POLL=0 expect_result 0 --watch
assert_grep 'CI gate (missing)' "$TASK_TMP/out" 'watch did not wait for missing check'
pass 'watch waits for an unreported required check and finishes while advisory is pending'

view IN_PROGRESS '' COMPLETED SUCCESS > "$TASK_TMP/view.json"
view COMPLETED SUCCESS IN_PROGRESS '' > "$TASK_TMP/next.json"
FM_PR_CHECKS_POLL=0 expect_result 0 --watch
assert_grep 'CI gate (pending)' "$TASK_TMP/out" 'watch skipped required pending'
pass 'watch re-reads pending required checks until they pass'

printf '{"protected":true,"protection":{"required_status_checks":{"contexts":["classic"]}}}\n' > "$TASK_TMP/branch.json"
expect_result 8
assert_grep 'classic (missing)' "$TASK_TMP/out" 'classic requirement lost'
printf 'unreadable\n' > "$TASK_TMP/rules.json"
expect_result 2
pass 'classic and ruleset requirements compose; unreadable requirements fail closed'

printf '{"protected":false}\n' > "$TASK_TMP/branch.json"
printf '[]\n' > "$TASK_TMP/rules.json"
fallback_view() {
  view "$@" | jq '.statusCheckRollup |= map(
    if .name == "Mac" then .name = "Mac (advisory)"
    elif .context == "optional-status" then .context = "status (advisory)"
    else . end)'
}
fallback_view COMPLETED FAILURE COMPLETED SUCCESS > "$TASK_TMP/view.json"
expect_result 1
assert_grep 'CI gate (red)' "$TASK_TMP/out" 'unprotected red check was ignored'
fallback_view IN_PROGRESS '' COMPLETED SUCCESS > "$TASK_TMP/view.json"
expect_result 8
assert_grep 'CI gate (pending)' "$TASK_TMP/out" 'unprotected pending check was ignored'
pass 'without configured requirements, red and pending checks still block'

fallback_view COMPLETED SUCCESS IN_PROGRESS '' > "$TASK_TMP/view.json"
expect_result 0 --watch
fallback_view COMPLETED SUCCESS COMPLETED FAILURE > "$TASK_TMP/view.json"
expect_result 0 --watch
pass 'without configured requirements, explicit advisory runs and statuses do not block'

printf '[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"Mac (advisory)"}]}}]\n' > "$TASK_TMP/rules.json"
expect_result 1
assert_grep 'Mac (advisory) (red)' "$TASK_TMP/out" 'advisory marker overrode a configured requirement'
pass 'configured requirements take precedence over the advisory marker'
