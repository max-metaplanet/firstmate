#!/usr/bin/env bash
# Exercise conflict-refresh publication and ready holds through the public CLI.
set -eu
# shellcheck source=tests/lib.sh
. "~/.no-mistakes/worktrees/c0c4fcacb05a/01M6A5K9DQXXP84607RZT0AJKF/tests/lib.sh"
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
    [ "$#" = 5 ] && [ "$4 $5" = '--input -' ] || exit 92
    body=$(cat)
    printf '%s\n' "$body" >> "$REFRESH_FIXTURE/log"
    printf '%s' "$body" | jq -e --arg id "${PR_NODE_ID:-PR_fixture}" \
      '(.query | contains("convertPullRequestToDraft")) and .variables.id == $id' >/dev/null || exit 92
    echo true > "$REFRESH_FIXTURE/draft" ;;
  'pr edit 9')
    [ "$#" = 7 ] && [ "$4 $5" = '--repo example/repo' ] \
      && [ "$6" = --add-label ] && [ "$7" = 'hold for approval' ] || exit 92
    [ ! -f "$REFRESH_FIXTURE/label-add-fails" ] || exit 1
    [ -f "$REFRESH_FIXTURE/label-add-ignored" ] || echo '{"labels":[{"name":"hold for approval"}]}' > "$REFRESH_FIXTURE/labels.json"
    ;;
  'pr ready 9')
    if [ -f "$FM_HOME/config/project-ready-hold-label" ] && ! grep -qx 'yolo=on' "$FM_HOME/state/task.meta"; then
      jq -e '.labels | any(.name == "hold for approval")' "$REFRESH_FIXTURE/labels.json" >/dev/null || exit 93
    fi
    [ "$4 $5" = '--repo example/repo' ] || exit 92
    echo false > "$REFRESH_FIXTURE/draft" ;;
  *) exit 92 ;;
esac
SH
cat > "$FAKEBIN/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$REFRESH_FIXTURE/log"
case "$*" in
  'pr view '*--json\ labels) cat "$REFRESH_FIXTURE/labels.json" ;;
  'pr view '*state,isDraft,id)
    jq -nc --arg state "$(cat "$REFRESH_FIXTURE/state")" --argjson draft "$(cat "$REFRESH_FIXTURE/draft")" --arg id "${PR_NODE_ID:-PR_fixture}" '{state:$state,isDraft:$draft,id:$id}' ;;
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
    if [ -f "$REFRESH_FIXTURE/rules.json" ]; then
      cat "$REFRESH_FIXTURE/rules.json"
    else
      echo '[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"CI gate"}]}}]'
    fi ;;
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

refresh prepare task "$URL" -- publish
cp "$FM_HOME/state/task.pr-refresh" "$TASK_TMP/hold"
mkdir -p "$FM_HOME/config"
printf 'project=/projects/repo\nyolo=off\n' >> "$FM_HOME/state/task.meta"
printf 'repo\thold for approval\n' > "$FM_HOME/config/project-ready-hold-label"
echo '{"labels":[]}' > "$TASK_TMP/labels.json"
printf '[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"CI gate"},{"context":"queue-verdict"}]}}]\n' > "$TASK_TMP/rules.json"
printf 'repo\tqueue-verdict\n' > "$FM_HOME/config/project-queue-only-checks"
checks SKIPPED 2026-10-20T10:00:00Z > "$TASK_TMP/checks.json"
checks SUCCESS 2026-10-20T11:00:04Z > "$TASK_TMP/next-checks.json"
refresh ready task "$URL" --ready-ci reruns > "$TASK_TMP/ready-out"
cat "$TASK_TMP/ready-out"
[ ! -e "$FM_HOME/state/task.pr-refresh" ] || fail 'fresh head CI did not clear refresh hold'
jq -e '.labels | any(.name == "hold for approval")' "$TASK_TMP/labels.json" >/dev/null || fail 'ready-hold label was removed'
printf 'Observable state: refresh hold cleared; merge hold label retained\n'
