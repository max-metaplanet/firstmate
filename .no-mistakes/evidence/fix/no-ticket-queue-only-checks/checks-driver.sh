#!/usr/bin/env bash
# Behavioral required-check CI wait tests through the public command.
set -eu
# shellcheck source=tests/lib.sh
. "~/.no-mistakes/worktrees/c0c4fcacb05a/01M6A5K9DQXXP84607RZT0AJKF/tests/lib.sh"
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

printf '[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"CI gate"},{"context":"queue-verdict"}]}}]\n' > "$TASK_TMP/rules.json"
# "queue-verdict" stands for a required check a project runs only in its merge
# queue, so it never reports on an ordinary pull-request head.
queue_head() {  # <CI gate conclusion> [queue-verdict status] [queue-verdict conclusion]
  jq -nc --arg head "$HEAD" --arg gate "$1" --arg status "${2:-}" --arg conclusion "${3:-}" \
    '{headRefOid:$head,baseRefName:"main",statusCheckRollup:([
      {__typename:"CheckRun",name:"CI gate",status:"COMPLETED",conclusion:$gate,startedAt:"2026-10-20T11:00:00Z"}]
      + (if $status == "" then [] else
          [{__typename:"CheckRun",name:"queue-verdict",status:$status,conclusion:$conclusion,startedAt:"2026-10-20T11:00:00Z"}]
        end))}'
}

queue_head SUCCESS > "$TASK_TMP/view.json"
expect_result 8
assert_grep 'queue-verdict (missing)' "$TASK_TMP/out" 'an undeclared unreported required check stopped blocking'
expect_result 0 --queue-only queue-verdict
assert_grep 'QUEUE-ONLY CHECK: queue-verdict (runs in the merge queue)' "$TASK_TMP/out" 'the deferred check was not reported'
assert_no_grep 'queue-verdict (missing)' "$TASK_TMP/out" 'a declared queue-only check still blocked as missing'
: > "$TASK_TMP/reads"
FM_PR_CHECKS_POLL=0 expect_result 0 --watch --queue-only queue-verdict
[ "$(wc -l < "$TASK_TMP/reads" | tr -d ' ')" = 1 ] || fail 'the wait polled again for a declared queue-only check'
pass 'a declared queue-only required check absent from the head passes the wait while an undeclared one still blocks'

queue_head SUCCESS COMPLETED FAILURE > "$TASK_TMP/view.json"
expect_result 1 --queue-only queue-verdict
assert_grep 'queue-verdict (red)' "$TASK_TMP/out" 'a declared check that reported red on the head was ignored'
queue_head SUCCESS IN_PROGRESS > "$TASK_TMP/view.json"
expect_result 8 --queue-only queue-verdict
assert_grep 'queue-verdict (pending)' "$TASK_TMP/out" 'a declared check still running on the head was ignored'
queue_head FAILURE > "$TASK_TMP/view.json"
expect_result 1 --queue-only queue-verdict
assert_grep 'CI gate (red)' "$TASK_TMP/out" 'a queue-only declaration hid another required check'
pass 'a declared queue-only check still counts when it reports red or is running, and other required checks are unaffected'

queue_head SUCCESS > "$TASK_TMP/view.json"
: > "$TASK_TMP/reads"
FM_PR_CHECKS_POLL=1 expect_result 8 --watch --timeout 1
assert_grep '--timeout' "$TASK_TMP/err" 'the bounded wait did not explain how to allow longer CI runs'
assert_grep 'gave up after 1s' "$TASK_TMP/err" 'the bounded wait did not report giving up'
assert_grep 'queue-verdict (missing)' "$TASK_TMP/err" 'the bounded wait did not name the outstanding check'
assert_grep '--queue-only' "$TASK_TMP/err" 'the bounded wait did not say what to do about it'
assert_grep "$URL" "$TASK_TMP/err" 'the bounded wait did not name the pull request'
: > "$TASK_TMP/reads"
FM_PR_CHECKS_POLL=1 expect_result 0 --watch --timeout 1 --queue-only queue-verdict
[ "$(wc -l < "$TASK_TMP/reads" | tr -d ' ')" = 1 ] || fail 'a declared queue-only check still consumed the bound'
expect_result 2 --timeout 1
expect_result 2 --watch --timeout notanumber
expect_result 2 --watch --queue-only
pass 'the watch is bounded by --timeout, reports the outstanding checks, and rejects a bound without watch or a malformed option'

printf '[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"CI gate"}]}}]\n' > "$TASK_TMP/rules.json"

