#!/usr/bin/env bash
# Merge-queue drop handling, driven end to end through the registered
# contribution check that bin/fm-pr-check.sh arms for a ship's pull request.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-mq-drop)
NOW=2026-09-16T08:00:00Z
HEAD_A=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
HEAD_B=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
QUEUE_HEAD=cccccccccccccccccccccccccccccccccccccccc
MARKER='has been removed from the queue'
LOG_LINE='FAIL: merge-queue draft assertion'

new_home() {
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects/sample" \
    "$home/fakebin" "$home/forge" "$home/root/bin" "$home/wt"
  printf '# Backlog\n\n## Queued\n' > "$home/data/backlog.md"
  printf '#!/bin/sh\nexit 0\n' > "$home/root/bin/fm-guard.sh"
  chmod +x "$home/root/bin/fm-guard.sh"
  printf '%s\n' "$home"
}

# Logs literal typed text to FM_SEND_LOG and lets the doorbell reach a clean
# verdict, so an assertion about delivery reads the durable record and not tmux.
make_tmux_stub() { # <home>
  cat > "$1/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  send-keys)
    shift
    literal=0
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    [ "$literal" = 0 ] || printf '%s\n' "${1:-}" >> "$FM_SEND_LOG"
    exit 0 ;;
  display-message)
    for a in "$@"; do case "$a" in *cursor_y*) printf '1\n'; exit 0 ;; esac; done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane) printf '╭────╮\n│    │\n╰────╯\n'; exit 0 ;;
  list-windows) printf 'fm-delivery\nwin\n'; exit 0 ;;
esac
exit 0
SH
  cat > "$1/fakebin/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$1/fakebin/tmux" "$1/fakebin/sleep"
}

record() { # <home>
  mkdir -p "$1/data/delivery"
  printf -- '- [ ] delivery - Contribution https://github.com/o/r/pull/8 (repo: sample) (kind: ship)\n' \
    >> "$1/data/backlog.md"
  jq -n --arg head "$HEAD_A" --arg at "$NOW" '
    {schema:"fm-contributions.v1",task:"delivery",records:[{
      url:"https://github.com/o/r/pull/8",kind:"pr",checked_at:$at,error:null,
      pending:[],seen:[],verdict:null,
      observation:{head:$head,state:"open",draft:false,mergeable:"mergeable",
        review_decision:"APPROVED",can_merge:false,
        checks:[{name:"test",id:1,status:"completed",conclusion:"success",started_at:$at}],
        reviews:[],events:[]}}]}' > "$1/data/delivery/contributions.json"
}

forge_home() { # <home>
  local home=$1
  printf '%s\n' "$HEAD_A" > "$home/forge/head"
  printf '[]\n' > "$home/forge/comments.json"
  printf '[]\n' > "$home/forge/reviews.json"
  printf '[]\n' > "$home/forge/inline.json"
  jq -n --arg head "$QUEUE_HEAD" '{head:{sha:$head}}' > "$home/forge/queue-pull.json"
  jq -n '[{check_runs:[{name:"queue-draft-tests",id:7001,status:"completed",
    conclusion:"failure",started_at:"2026-09-16T07:50:00Z",
    output:{summary:"queue draft run failed"}}]}]' > "$home/forge/queue-checks.json"
  printf 'setup\n%s\n' "$LOG_LINE" > "$home/forge/job.log"
  cat > "$home/fakebin/gh" <<'SH'
#!/usr/bin/env bash
set -eu
sha_of() { local rest=${1#repos/o/r/commits/}; printf '%s' "${rest%%/*}"; }
case "$*" in
  'pr view '*headRefOid,reviewDecision*)
    jq -n --arg head "$(cat "$FORGE/head")" '{headRefOid:$head,reviewDecision:"APPROVED"}' ;;
  'pr view '*headRefOid*) cat "$FORGE/head" ;;
  'pr view '*state*) printf 'OPEN\n' ;;
  'api repos/o/r/pulls/8')
    jq -n --arg head "$(cat "$FORGE/head")" --arg state "$(cat "$FORGE/state" 2>/dev/null || printf open)" '
      {state:(if $state == "open" then "open" else "closed" end),user:{login:"author"},
       head:{sha:$head},draft:false,mergeable:($state == "open"),
       merged_at:(if $state == "merged" then "2026-09-16T07:00:00Z" else null end)}' ;;
  'api repos/o/r/pulls/20')
    [ ! -e "$FORGE/slow-queue-pull" ] || exec command -p sleep 30
    cat "$FORGE/queue-pull.json" ;;
  'api repos/o/r/actions/jobs/7001/logs')
    [ -s "$FORGE/job.log" ] || exit 1
    cat "$FORGE/job.log" ;;
  'api repos/o/r/issues/8/comments?'*) jq -s . "$FORGE/comments.json" ;;
  'api repos/o/r/pulls/8/reviews?'*) jq -s . "$FORGE/reviews.json" ;;
  'api repos/o/r/pulls/8/comments?'*) jq -s . "$FORGE/inline.json" ;;
  'api repos/o/r/commits/'*'/check-runs?'*)
    if [ "$(sha_of "$2")" = "$QUEUE_HEAD" ]; then
      cat "$FORGE/queue-checks.json"
    else
      jq -n --argjson extra "$(cat "$FORGE/extra-checks.json" 2>/dev/null || printf '[]')" '
        [{check_runs:([{name:"test",id:1,status:"completed",conclusion:"success",
          started_at:"2026-09-16T08:00:00Z"}] + $extra)}]'
    fi ;;
  'api repos/o/r/commits/'*'/statuses?'*) printf '[[]]\n' ;;
  'api repos/o/r') printf '{"permissions":{"push":false}}\n' ;;
  *) printf 'unexpected gh fixture call: %s\n' "$*" >&2; exit 1 ;;
esac
SH
  chmod +x "$home/fakebin/gh"
}

with_home() { # <home> <command...>
  local home=$1; shift
  PATH="$home/fakebin:$PATH" FORGE="$home/forge" QUEUE_HEAD="$QUEUE_HEAD" \
    FM_SEND_LOG="$home/send.log" FM_SEND_SETTLE=0 \
    FM_HOME="$home" FM_ROOT_OVERRIDE="$home/root" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
    FM_CONTRIBUTIONS_NOW="$NOW" "$@"
}

# The supervision guard fm-send consults reports this unwatched fixture home on
# every steer, so its stderr is held back and shown only when a check fails.
registered_checks() { # <home>
  local home=$1 check
  for check in "$home/state/"*.check.sh; do
    [ -f "$check" ] || continue
    with_home "$home" bash "$check" 2> "$home/check.err" \
      || fail "registered check failed: $(cat "$home/check.err")"
  done
}

declare_queue() { # <home> <line...>
  local home=$1
  shift
  printf '%s\n' "$@" > "$home/config/project-merge-queue"
}

drop_comment() { # <home> <id> <body> [updated-at]
  jq -n --argjson id "$2" --arg body "$3" --arg updated "${4:-2026-09-16T08:01:00Z}" '[{id:$id,
    user:{login:"mergify[bot]"},author_association:"NONE",body:$body,
    html_url:("https://github.com/o/r/pull/8#issuecomment-" + ($id | tostring)),
    created_at:"2026-09-16T08:01:00Z",updated_at:$updated}]' > "$1/forge/comments.json"
}

armed_home() { # <name> -> a home whose delivery PR is registered and observable
  local home
  home=$(new_home "$1")
  make_tmux_stub "$home"
  forge_home "$home"
  record "$home"
  printf 'worktree=%s/wt\nkind=ship\n' "$home" > "$home/state/delivery.meta"
  chmod 600 "$home/state/delivery.meta"
  with_home "$home" "$ROOT/bin/fm-pr-check.sh" delivery https://github.com/o/r/pull/8 >/dev/null \
    || fail 'could not register the owned delivery'
  printf 'window=test:fm-delivery\nproject=%s/projects/sample\n' "$home" >> "$home/state/delivery.meta"
  printf '%s\n' "$home"
}

inbox_count() { # <home>
  local n=0 record
  for record in "$1/state/delivery.inbox/"*.msg; do
    [ -f "$record" ] && n=$((n + 1))
  done
  printf '%s\n' "$n"
}

inbox_body() { # <home> <sequence>
  bash -c '. "$1"; fm_task_inbox_body "$2"' _ "$ROOT/bin/fm-task-inbox-lib.sh" \
    "$1/state/delivery.inbox/$2.msg"
}

drop_token() { # <home>
  jq -r '.records[0].mq_drop.token // ""' "$1/data/delivery/contributions.json"
}

test_dequeue_with_failing_queue_check_steers_once() {
  local home body
  home=$(armed_home dequeue)
  declare_queue "$home" "sample	mergify[bot]	$MARKER"
  drop_comment "$home" 101 \
    "Pull request #8 $MARKER because its queue run failed: https://github.com/o/r/pull/20"
  registered_checks "$home" >/dev/null
  assert_equals 1 "$(inbox_count "$home")" 'a merge-queue drop should steer the worker exactly once'
  body=$(inbox_body "$home" 001)
  assert_contains "$body" "$LOG_LINE" 'the steer should carry the failing queue run log'
  assert_contains "$body" 'queue-draft-tests' 'the steer should name the failing check'
  assert_contains "$body" 'Evidence source: https://github.com/o/r/pull/20' \
    'the steer should name the queue pull request as its evidence source'
  assert_contains "$body" 'Fix the cause on this branch in one round' \
    'the steer should instruct one fix round before requeuing'
  assert_equals 'mq-drop:101:2026-09-16T08:01:00Z' "$(drop_token "$home")" \
    'the handled drop should be recorded as that state of the drop comment'
  pass 'a merge-queue dequeue steers once with the failing queue run evidence'
}

test_merged_pull_request_produces_no_steer() {
  local home
  home=$(armed_home merged)
  declare_queue "$home" "sample	mergify[bot]	$MARKER"
  drop_comment "$home" 101 "Pull request #8 $MARKER: https://github.com/o/r/pull/20"
  printf 'merged\n' > "$home/forge/state"
  registered_checks "$home" >/dev/null
  assert_equals 0 "$(inbox_count "$home")" 'a merge must never read as a drop'
  assert_equals '' "$(drop_token "$home")" 'a merged pull request must record no drop'
  pass 'a merged pull request produces no merge-queue drop steer'
}

test_repeated_poll_produces_no_second_steer() {
  local home
  home=$(armed_home repeat)
  declare_queue "$home" "sample	mergify[bot]	$MARKER"
  drop_comment "$home" 101 "Pull request #8 $MARKER: https://github.com/o/r/pull/20"
  registered_checks "$home" >/dev/null
  assert_equals 1 "$(inbox_count "$home")" 'the first poll should steer once'
  registered_checks "$home" >/dev/null
  assert_equals 1 "$(inbox_count "$home")" 'a repeated poll must not steer again'
  assert_equals 'mq-drop:101:2026-09-16T08:01:00Z' "$(drop_token "$home")" 'the recorded token must be unchanged'
  pass 'a repeated poll over the same drop produces no second steer'
}

test_edited_comment_on_the_same_head_produces_no_second_steer() {
  local home
  home=$(armed_home edited)
  declare_queue "$home" "sample	mergify[bot]	$MARKER"
  drop_comment "$home" 101 "Pull request #8 $MARKER: https://github.com/o/r/pull/20"
  registered_checks "$home" >/dev/null
  drop_comment "$home" 101 \
    "Pull request #8 $MARKER, position refreshed: https://github.com/o/r/pull/20" 2026-09-16T08:05:00Z
  registered_checks "$home" >/dev/null
  assert_equals 1 "$(inbox_count "$home")" \
    'an in-place edit of the queue bot comment on the same head must not steer again'
  printf '%s\n' "$HEAD_B" > "$home/forge/head"
  registered_checks "$home" >/dev/null
  assert_equals 1 "$(inbox_count "$home")" \
    'a push after a silent same-head edit must not replay that edit as a re-drop'
  pass 'an edited drop comment on the same head produces no second steer'
}

test_push_alone_produces_no_second_steer() {
  local home
  home=$(armed_home pushed)
  declare_queue "$home" "sample	mergify[bot]	$MARKER"
  drop_comment "$home" 101 "Pull request #8 $MARKER: https://github.com/o/r/pull/20"
  registered_checks "$home" >/dev/null
  assert_equals 1 "$(inbox_count "$home")" 'the first drop should steer once'
  printf '%s\n' "$HEAD_B" > "$home/forge/head"
  registered_checks "$home" >/dev/null
  registered_checks "$home" >/dev/null
  assert_equals 1 "$(inbox_count "$home")" \
    'a fix push or merge-bot rebase under the unchanged drop comment must not replay the stale steer'
  pass 'a push alone under an unchanged drop comment produces no second steer'
}

test_redrop_on_a_new_head_steers_again() {
  local home
  home=$(armed_home redrop)
  declare_queue "$home" "sample	mergify[bot]	$MARKER"
  drop_comment "$home" 101 "Pull request #8 $MARKER: https://github.com/o/r/pull/20"
  registered_checks "$home" >/dev/null
  assert_equals 1 "$(inbox_count "$home")" 'the first drop should steer once'
  printf '%s\n' "$HEAD_B" > "$home/forge/head"
  registered_checks "$home" >/dev/null
  drop_comment "$home" 101 "Pull request #8 $MARKER again: https://github.com/o/r/pull/20" \
    2026-09-16T09:00:00Z
  registered_checks "$home" >/dev/null
  assert_equals 2 "$(inbox_count "$home")" \
    'the queue bot re-dropping the fixed head by editing its comment should steer again'
  pass 'a re-drop on a new head steers again from the edited queue bot comment'
}

test_new_drop_comment_steers_again() {
  local home
  home=$(armed_home newcomment)
  declare_queue "$home" "sample	mergify[bot]	$MARKER"
  drop_comment "$home" 101 "Pull request #8 $MARKER: https://github.com/o/r/pull/20"
  registered_checks "$home" >/dev/null
  printf '%s\n' "$HEAD_B" > "$home/forge/head"
  drop_comment "$home" 102 "Pull request #8 $MARKER: https://github.com/o/r/pull/20"
  registered_checks "$home" >/dev/null
  assert_equals 2 "$(inbox_count "$home")" 'a queue bot posting a new drop comment should steer again'
  pass 'a new drop comment steers again'
}

test_slow_evidence_read_stays_inside_the_poll_budget() {
  local home body start elapsed
  home=$(armed_home slow)
  declare_queue "$home" "sample	mergify[bot]	$MARKER"
  drop_comment "$home" 101 "Pull request #8 $MARKER: https://github.com/o/r/pull/20"
  printf '1\n' > "$home/forge/slow-queue-pull"
  start=$(date +%s)
  FM_CONTRIBUTIONS_BUDGET=3 registered_checks "$home" >/dev/null
  elapsed=$(( $(date +%s) - start ))
  [ "$elapsed" -lt 9 ] || fail "a hung evidence read held the poll for ${elapsed}s past its budget"
  assert_equals 1 "$(inbox_count "$home")" 'a drop must still steer when its evidence read runs out of budget'
  body=$(inbox_body "$home" 001)
  assert_contains "$body" 'Evidence source: the queue report comment' \
    'an evidence read cut by the budget should fall back to the drop comment'
  pass 'a hung evidence read is cut to the poll budget and the steer still lands'
}

test_drop_wakes_a_parked_worker() {
  local home
  home=$(armed_home parked)
  declare_queue "$home" "sample	mergify[bot]	$MARKER"
  printf 'phase=parked\ngeneration=legacy\nendpoint=test:fm-delivery\nreason=merge bot\nuntil=0\nqueued_at=0\n' \
    > "$home/state/delivery.park"
  drop_comment "$home" 101 "Pull request #8 $MARKER: https://github.com/o/r/pull/20"
  registered_checks "$home" >/dev/null
  assert_equals 1 "$(inbox_count "$home")" 'a drop must reach a parked worker as a durable steer'
  assert_grep 'phase=queued' "$home/state/delivery.park" \
    'a drop on a parked worker must queue its resume'
  assert_contains "$(inbox_body "$home" 001)" "$LOG_LINE" \
    'the resumed worker must find the failing check evidence waiting'
  pass 'a drop on a parked worker queues its resume with the evidence already delivered'
}

test_absent_declaration_handles_nothing() {
  local home
  home=$(armed_home undeclared)
  drop_comment "$home" 101 "Pull request #8 $MARKER: https://github.com/o/r/pull/20"
  registered_checks "$home" >/dev/null
  assert_equals 0 "$(inbox_count "$home")" 'an undeclared project must cost no steer'
  assert_equals '' "$(drop_token "$home")" 'an undeclared project must record nothing'
  jq -e '.records[0].observation.state == "open"' "$home/data/delivery/contributions.json" >/dev/null \
    || fail 'the ordinary observation must still be recorded without a declaration'
  pass 'a project with no merge-queue declaration is observed as before'
}

test_malformed_declaration_fails_loudly() {
  local home out
  home=$(armed_home malformed)
  declare_queue "$home" "sample	mergify[bot]	$MARKER" "sample	other-bot	gone"
  drop_comment "$home" 101 "Pull request #8 $MARKER: https://github.com/o/r/pull/20"
  out=$(with_home "$home" bash "$home/state/contributions.check.sh" 2>/dev/null) \
    || fail 'a bad declaration must not fail the whole observation'
  assert_contains "$out" 'merge-queue drop handling failed for delivery' \
    'a duplicate project declaration must be reported, not silently dropped'
  assert_equals 0 "$(inbox_count "$home")" 'a refused declaration must send no steer'
  pass 'a duplicate merge-queue declaration is refused loudly and sends nothing'
}

test_evidence_falls_back_to_the_comment_body() {
  local home body
  home=$(armed_home fallback)
  declare_queue "$home" "sample	mergify[bot]	$MARKER"
  drop_comment "$home" 101 "Pull request #8 $MARKER while the queue was reset."
  registered_checks "$home" >/dev/null
  assert_equals 1 "$(inbox_count "$home")" 'a drop with no failing check must still steer'
  body=$(inbox_body "$home" 001)
  assert_contains "$body" 'Failing checks: none reported' \
    'the steer should say plainly that no failing check was found'
  assert_contains "$body" 'Evidence source: the queue report comment' \
    'the steer should name the comment as the evidence it fell back to'
  assert_contains "$body" 'while the queue was reset' \
    'the steer should carry the queue report body as its evidence'
  pass 'a drop with no failing check steers with the queue report body'
}

test_long_log_is_bounded_to_its_tail() {
  local home body i
  home=$(armed_home bounded)
  declare_queue "$home" "sample	mergify[bot]	$MARKER"
  drop_comment "$home" 101 "Pull request #8 $MARKER: https://github.com/o/r/pull/20"
  : > "$home/forge/job.log"
  for i in $(seq -f '%04g' 1 200); do
    printf 'line-%s %s\n' "$i" "$(printf 'x%.0s' $(seq 1 190))" >> "$home/forge/job.log"
  done
  printf 'line-0201 tail\a marker\n' >> "$home/forge/job.log"
  registered_checks "$home" >/dev/null
  body=$(inbox_body "$home" 001)
  assert_contains "$body" '[...truncated]' 'a long log excerpt should say it was cut'
  assert_contains "$body" 'line-0201 tail' 'the failing tail of the log must survive the cut'
  assert_not_contains "$body" 'line-0001' 'a line outside the 80-line window must not survive'
  assert_not_contains "$body" 'line-0125' 'a line beyond the byte cap must not survive'
  assert_not_contains "$body" $'\a' 'control characters must be dropped from the excerpt'
  pass 'a long failing-check log is cut to its tail and says so'
}

failures=0
for test_name in test_dequeue_with_failing_queue_check_steers_once \
  test_merged_pull_request_produces_no_steer \
  test_repeated_poll_produces_no_second_steer \
  test_edited_comment_on_the_same_head_produces_no_second_steer \
  test_push_alone_produces_no_second_steer \
  test_redrop_on_a_new_head_steers_again \
  test_new_drop_comment_steers_again \
  test_slow_evidence_read_stays_inside_the_poll_budget \
  test_drop_wakes_a_parked_worker \
  test_absent_declaration_handles_nothing \
  test_malformed_declaration_fails_loudly \
  test_evidence_falls_back_to_the_comment_body \
  test_long_log_is_bounded_to_its_tail; do
  ( "$test_name" ) || failures=$((failures + 1))
done
[ "$failures" -eq 0 ] || fail "$failures merge-queue drop regressions"
