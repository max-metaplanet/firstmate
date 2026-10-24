#!/usr/bin/env bash
# Exercise conflict-refresh publication and ready holds through the public CLI.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-dod-lib.sh
. "$ROOT/bin/fm-dod-lib.sh"
TASK_TMP=$(fm_test_tmproot fm-pr-refresh)
FAKEBIN=$(fm_fakebin "$TASK_TMP")
export REFRESH_FIXTURE=$TASK_TMP
export FM_HOME=$TASK_TMP/home
export PATH="$FAKEBIN:$PATH"
export FM_PR_CHECKS_POLL=0
mkdir -p "$FM_HOME/state"
printf 'kind=ship\nmode=no-mistakes\n' > "$FM_HOME/state/task.meta"
URL=https://github.com/example/repo/pull/9
printf 'false\n' > "$TASK_TMP/draft"
printf 'OPEN\n' > "$TASK_TMP/state"
cat > "$FAKEBIN/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$REFRESH_FIXTURE/log"
[ ! -f "$REFRESH_FIXTURE/change-fails" ] || exit 1
[ ! -f "$REFRESH_FIXTURE/change-ignored" ] || exit 0
case "$1 $2 $3" in
  'api POST /graphql')
    [[ "$*" == *'convertPullRequestToDraft'* ]] && [[ "$*" == *'id=PR_fixture'* ]] || exit 92
    echo true > "$REFRESH_FIXTURE/draft" ;;
  'pr ready 9')
    [ "$4 $5" = '--repo example/repo' ] || exit 92
    echo false > "$REFRESH_FIXTURE/draft" ;;
  *) exit 92 ;;
esac
SH
cat > "$FAKEBIN/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$REFRESH_FIXTURE/log"
case "$*" in
  'pr view '*state,isDraft,id)
    jq -nc --arg state "$(cat "$REFRESH_FIXTURE/state")" --argjson draft "$(cat "$REFRESH_FIXTURE/draft")" '{state:$state,isDraft:$draft,id:"PR_fixture"}' ;;
  'pr view '*)
    cat "$REFRESH_FIXTURE/checks.json"
    if [ -f "$REFRESH_FIXTURE/next-checks.json" ]; then
      mv "$REFRESH_FIXTURE/next-checks.json" "$REFRESH_FIXTURE/checks.json"
    fi
    ;;
  *'/timeline '*)
    [ ! -f "$REFRESH_FIXTURE/timeline-fails" ] || exit 1
    echo 2026-10-20T11:00:00Z ;;
  *'/rules/branches/main')
    echo '[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"CI gate"}]}}]' ;;
  *'/branches/main') echo '{"protected":false}' ;;
  *'/check-runs') echo '{"check_runs":[]}' ;;
  *) echo "unexpected gh call $*" >&2; exit 91 ;;
esac
SH
cat > "$FAKEBIN/publish" <<'SH'
#!/usr/bin/env bash
[ "$(cat "$REFRESH_FIXTURE/draft")" = true ] || exit 97
[ -f "$FM_HOME/state/task.pr-refresh" ] || exit 98
printf 'published\n' >> "$REFRESH_FIXTURE/log"
exit "${PUBLISH_RC:-0}"
SH
chmod +x "$FAKEBIN/gh" "$FAKEBIN/gh-axi" "$FAKEBIN/publish"
refresh() { "$ROOT/bin/fm-pr-refresh.sh" "$@"; }
expect_refusal() {
  local rc=0
  refresh "$@" > "$TASK_TMP/out" 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail 'expected refresh refusal'
}
checks() {
  jq -nc --arg conclusion "$1" --arg time "$2" '{headRefOid:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",baseRefName:"main",statusCheckRollup:[{__typename:"CheckRun",name:"CI gate",status:"COMPLETED",conclusion:$conclusion,startedAt:$time}]}'
}

for failure in change-fails change-ignored; do
  touch "$TASK_TMP/$failure"
  expect_refusal prepare task "$URL" -- publish
  [ ! -f "$FM_HOME/state/task.pr-refresh" ] || fail 'failed draft conversion created a publication hold'
  ! grep -q '^published$' "$TASK_TMP/log" || fail 'publication ran without a confirmed draft'
  rm "$TASK_TMP/$failure"
done
pass 'a failed or unconfirmed draft conversion prevents publication'

refresh prepare task "$URL" -- publish
[ "$(cat "$TASK_TMP/draft")" = true ] || fail 'publication did not leave draft'
assert_grep 'published' "$TASK_TMP/log" 'publication command did not run'
grep -Eq '^paused \[at=[0-9]+\]: .*awaiting firstmate ready call' "$FM_HOME/state/task.status" || fail 'missing declared wait'
if fm_dod_accept_ship_done ship no-mistakes '' '' "done: PR $URL checks green" "$FM_HOME/state" task "$FM_HOME/state/task.meta"; then
  fail 'a held refresh was accepted as done'
fi
if "$ROOT/bin/fm-pr-check.sh" task "$URL" > "$TASK_TMP/out" 2>&1; then
  fail 'merge monitoring armed while a refresh hold exists'
fi
pass 'draft is confirmed before publication and its hold blocks done and merge registration'

before=$(grep -c 'convertPullRequestToDraft' "$TASK_TMP/log")
refresh prepare task "$URL"
[ "$(grep -c 'convertPullRequestToDraft' "$TASK_TMP/log")" = "$before" ] || fail 'repeated prepare toggled readiness'
rc=0
PUBLISH_RC=7 refresh prepare task "$URL" -- publish || rc=$?
[ "$rc" = 7 ] && [ -f "$FM_HOME/state/task.pr-refresh" ] || fail 'failed push lost exit code or draft hold'
expect_refusal prepare task https://github.com/example/repo/pull/10 -- publish
expect_refusal prepare ../escape "$URL" -- publish
expect_refusal prepare task https://gitlab.example/g/r/-/merge_requests/9 -- publish
pass 'retries preserve draft and failed publication retains the hold'

checks FAILURE 2026-10-20T11:00:04Z > "$TASK_TMP/checks.json"
expect_refusal ready task "$URL"
[ -f "$FM_HOME/state/task.pr-refresh" ] || fail 'red CI removed refresh hold'
pass 'failed ready CI keeps the hold for retry'

checks SKIPPED 2026-10-20T10:00:00Z > "$TASK_TMP/checks.json"
checks SUCCESS 2026-10-20T11:00:04Z > "$TASK_TMP/next-checks.json"
refresh ready task "$URL" > "$TASK_TMP/ready-out"
assert_grep 'CI gate (missing)' "$TASK_TMP/ready-out" 'ready call counted draft-era skipped checks'
[ "$(cat "$TASK_TMP/draft")" = false ] || fail 'ready command left draft'
[ ! -e "$FM_HOME/state/task.pr-refresh" ] || fail 'green fresh CI left hold'
grep -Eq '^resolved \[at=[0-9]+\]:' "$FM_HOME/state/task.status" || fail 'wait was not resolved'
expect_refusal ready task "$URL"
pass 'ready waits past draft-skipped checks and resolves the hold only on fresh green CI'
