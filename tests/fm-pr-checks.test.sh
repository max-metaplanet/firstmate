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
    printf 'view\n' >> "$CHECK_FIXTURE/reads"
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

view COMPLETED FAILURE IN_PROGRESS '' > "$TASK_TMP/view.json"
view COMPLETED FAILURE COMPLETED FAILURE > "$TASK_TMP/next.json"
: > "$TASK_TMP/reads"
FM_PR_CHECKS_POLL=0 expect_result 1 --watch --settled
[ "$(wc -l < "$TASK_TMP/reads" | tr -d ' ')" = 2 ] || fail 'settled repair wait returned on first failure before the other check completed'
assert_grep 'HEAD CHECKS: still executing' "$TASK_TMP/out" 'settled wait did not report pending head checks'
pass 'settled repair wait collects a later advisory failure before returning required red'

view COMPLETED SUCCESS IN_PROGRESS '' > "$TASK_TMP/view.json"
view COMPLETED SUCCESS COMPLETED FAILURE > "$TASK_TMP/next.json"
: > "$TASK_TMP/reads"
FM_PR_CHECKS_POLL=0 expect_result 0 --settled --watch
[ "$(wc -l < "$TASK_TMP/reads" | tr -d ' ')" = 2 ] || fail 'settled wait did not wait for advisory completion'
pass 'settled wait includes advisory execution without making advisory failures required'

view COMPLETED FAILURE COMPLETED SUCCESS | jq '.statusCheckRollup[-1].state = "PENDING"' > "$TASK_TMP/view.json"
view COMPLETED FAILURE COMPLETED SUCCESS > "$TASK_TMP/next.json"
: > "$TASK_TMP/reads"
FM_PR_CHECKS_POLL=0 expect_result 1 --watch --settled
[ "$(wc -l < "$TASK_TMP/reads" | tr -d ' ')" = 2 ] || fail 'settled wait ignored a pending status context'
expect_result 2 --settled
pass 'settled wait includes pending status contexts and requires watch mode'

view COMPLETED FAILURE IN_PROGRESS '' > "$TASK_TMP/view.json"
view COMPLETED SUCCESS COMPLETED SUCCESS | jq '.headRefOid = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"' > "$TASK_TMP/next.json"
: > "$TASK_TMP/reads"
FM_PR_CHECKS_POLL=0 expect_result 0 --watch --settled
[ "$(wc -l < "$TASK_TMP/reads" | tr -d ' ')" = 2 ] || fail 'settled wait did not re-read the new PR head'
pass 'settled wait follows the current head rather than returning an older failure'

READY=2026-10-20T11:00:00Z
gate_runs() {
  jq -nc --arg head "$HEAD" --argjson runs "$1" \
    '{headRefOid:$head,baseRefName:"main",statusCheckRollup:[
      $runs[] | {__typename:"CheckRun",name:"CI gate",status:"COMPLETED",conclusion:.[0],startedAt:.[1]}]}'
}
gate_runs '[["SKIPPED","2026-10-20T10:00:00Z"]]' > "$TASK_TMP/view.json"
expect_result 0
[ ! -s "$TASK_TMP/out" ] || fail 'a SKIPPED required run without --after stopped counting green'
expect_result 8 --after "$READY"
assert_grep 'CI gate (missing)' "$TASK_TMP/out" 'a draft-skipped run counted after the ready bound'
gate_runs '[["SKIPPED","2026-10-20T10:00:00Z"],["SUCCESS","2026-10-20T11:00:04Z"]]' > "$TASK_TMP/next.json"
: > "$TASK_TMP/reads"
FM_PR_CHECKS_POLL=0 expect_result 0 --watch --after "$READY"
[ "$(wc -l < "$TASK_TMP/reads" | tr -d ' ')" = 2 ] || fail 'bounded watch did not wait for a post-ready run'
gate_runs '[["FAILURE","2026-10-20T10:00:00Z"],["SKIPPED","2026-10-20T11:00:00Z"]]' > "$TASK_TMP/view.json"
expect_result 0 --after "$READY"
pass 'without --after a skip stays green; --after ignores pre-ready runs, waits for a post-ready run, and counts post-ready skips'

printf '[]\n' > "$TASK_TMP/rules.json"
gate_runs '[["SKIPPED","2026-10-20T10:00:00Z"]]' > "$TASK_TMP/view.json"
expect_result 0
expect_result 8 --after "$READY"
assert_grep 'CI gate (missing)' "$TASK_TMP/out" 'an unconfigured repo counted a pre-ready skip after the ready bound'
expect_result 2 --after 2026-10-20
expect_result 2 --after
pass '--after holds back stale checks with no configured requirements and rejects a malformed bound'
printf '[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"CI gate"}]}}]\n' > "$TASK_TMP/rules.json"
view COMPLETED SUCCESS COMPLETED SUCCESS > "$TASK_TMP/view.json"

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
