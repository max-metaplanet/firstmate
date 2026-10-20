#!/usr/bin/env bash
# Compatibility adapter behavior; detached execution and bounds belong to the
# task-event emitter's tests.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
SYNC="$ROOT/bin/fm-ticket-sync.sh"
TMP_ROOT=$(fm_test_tmproot fm-ticket-sync)

make_home() {
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/config"
  printf '%s\n' "$home"
}

install_hook() {  # <home> [exit-code]
  local home=$1 rc=${2:-0}
  cat > "$home/hook" <<SH
#!/usr/bin/env bash
jq -cn --args '\$ARGS.positional' -- "\$@" >> "$home/calls"
exit $rc
SH
  chmod +x "$home/hook"
  : > "$home/calls"
  printf '%s\n' "$home/hook" > "$home/config/ticket-sync-hook"
}

payload() {  # <event> [ticket] [merge] [summary] [pr-url]
  jq -cn --arg event "$1" --arg ticket "${2:-issue/123}" \
    --arg merge "${3:-final}" --arg summary "${4:-Worker status text}" \
    --arg pr "${5:-https://github.com/o/r/pull/7}" --arg scope "${6:-complete}" \
    '{schema:"firstmate.task-event", version:1, event:$event, task_id:"task-a",
      ticket:(if $ticket == "null" then null else $ticket end),
      ticket_scope:$scope, merge:$merge, summary:$summary, pr_url:(if $pr == "null" then null else $pr end)}'
}

run_sync() {
  local home=$1
  shift
  FM_HOME="$home" FM_CONFIG_OVERRIDE="$home/config" "$SYNC" "$@"
}

test_unconfigured_adapter_is_a_noop() {
  local home
  home=$(make_home unconfigured)
  run_sync "$home" "$(payload started)" || fail "unconfigured adapter failed"
  assert_absent "$home/calls" "unconfigured adapter called a hook"
  pass "the unconfigured adapter is a no-op"
}

test_event_mapping_preserves_arguments() {
  local home event summary expected
  home=$(make_home events)
  install_hook "$home"
  summary=$'Waiting for "choice"; $literal\nand a second line'
  run_sync "$home" "$(payload resumed issue/123 final "$summary" null)" \
    || fail "resumed without PR mapping failed"
  for event in started resumed blocked waiting pr-opened pr-merged cancelled; do
    run_sync "$home" "$(payload "$event" issue/123 final "$summary")" \
      || fail "$event mapping failed"
  done
  expected=$(jq -cn --arg summary "$summary" '[
    ["issue/123", "start"], ["issue/123", "start"],
    ["issue/123", "review", "https://github.com/o/r/pull/7"],
    ["issue/123", "waiting", $summary], ["issue/123", "waiting", $summary],
    ["issue/123", "review", "https://github.com/o/r/pull/7"],
    ["issue/123", "done", "https://github.com/o/r/pull/7"], ["issue/123", "done"]]')
  [ "$(jq -cs . "$home/calls")" = "$expected" ] \
    || fail "event mapping changed argument values: $(cat "$home/calls")"
  pass "legacy hook arguments preserve arbitrary tickets, URLs, and worker text"
}

test_nonlegacy_events_and_null_tickets_are_skipped() {
  local home event
  home=$(make_home skipped)
  install_hook "$home"
  for event in decision-answered finished; do
    run_sync "$home" "$(payload "$event")" || fail "$event was not skipped"
  done
  run_sync "$home" "$(payload cancelled issue/123 partial)" || fail "partial cancel failed"
  run_sync "$home" "$(payload cancelled issue/123 null)" || fail "PR-less cancel failed"
  run_sync "$home" "$(payload pr-merged issue/123 partial)" || fail "partial merge failed"
  run_sync "$home" "$(payload started null)" || fail "null ticket failed"
  [ ! -s "$home/calls" ] || fail "an event without a legacy transition reached the hook"
  pass "partial merges, other events, and null tickets do not move a legacy ticket"
}

test_hook_failures_propagate_to_the_emitter() {
  local home rc=0
  home=$(make_home failing)
  install_hook "$home" 7
  run_sync "$home" "$(payload started)" || rc=$?
  [ "$rc" -eq 7 ] || fail "hook failure was lost: $rc"
  [ "$(wc -l < "$home/calls")" -eq 1 ] || fail "failing hook did not run once"
  assert_absent "$home/state/task-a.status" "adapter wrote a worker status"
  pass "hook failure propagates so the emitter can record it"
}

test_malformed_payloads_are_refused() {
  local home bad rc
  home=$(make_home malformed)
  install_hook "$home"
  for bad in '{' '{}' \
    '{"schema":"firstmate.task-event","version":2,"event":"started","ticket":"issue/123","summary":"text"}' \
    '{"schema":"firstmate.task-event","version":1,"event":"started","ticket":[],"summary":"text"}' \
    '{"schema":"firstmate.task-event","version":1,"event":"pr-opened","ticket":"issue/123","summary":"text"}'; do
    rc=0
    run_sync "$home" "$bad" 2>/dev/null || rc=$?
    [ "$rc" -eq 2 ] || fail "invalid payload was not refused: $rc"
  done
  [ ! -s "$home/calls" ] || fail "malformed payload ran the hook"
  pass "invalid payloads are refused before invoking the legacy hook"
}

test_invalid_hook_configuration_is_refused() {
  local home entry rc
  home=$(make_home invalid-hook)
  install_hook "$home"
  for entry in "$home/missing" hook "$home/hook"$'\n'"$home/hook"; do
    printf '%s\n' "$entry" > "$home/config/ticket-sync-hook"
    rc=0
    run_sync "$home" "$(payload started)" 2>/dev/null || rc=$?
    [ "$rc" -eq 126 ] || fail "invalid hook path was not refused: $rc"
  done
  [ ! -s "$home/calls" ] || fail "invalid hook configuration ran a hook"
  printf '# compatibility\n\n%s\n' "$home/hook" > "$home/config/ticket-sync-hook"
  run_sync "$home" "$(payload started)" || fail "comments and blanks prevented execution"
  [ "$(wc -l < "$home/calls")" -eq 1 ] || fail "commented configuration did not run once"
  pass "legacy hook configuration requires one absolute executable path"
}


report_merge() (
  # shellcheck source=bin/fm-merge-outcome-lib.sh
  # shellcheck disable=SC1091
  . "$ROOT/bin/fm-merge-outcome-lib.sh"
  FM_CONFIG_OVERRIDE="$1/config" fm_merge_outcome_report "$1" "$1/state" "$2" "$3" "$4"
)

test_polled_merge_reaches_legacy_hook_once() {
  local home url i
  home=$(make_home merge-origin)
  install_hook "$home"
  printf '%s\n' "$SYNC" > "$home/config/task-event-hook"
  url=https://github.com/acme/sample/pull/7
  fm_write_meta "$home/state/polled.meta" \
    "window=firstmate:fm-polled" "worktree=$home/wt" "kind=ship" \
    "mode=no-mistakes" "ticket=issue/456" "ticket_scope=complete" "commit_type=feat" "pr=$url"
  report_merge "$home" polled "$url" poll || fail "polled merge was not recorded"
  for ((i=0; i<200; i++)); do
    [ -s "$home/calls" ] && break
    sleep 0.05
  done
  jq -e --arg url "$url" '. == ["issue/456", "done", $url]' "$home/calls" >/dev/null \
    || fail "polled merge did not complete its ticket"
  report_merge "$home" polled "$url" self || fail "repeated merge failed"
  sleep 0.3
  [ "$(wc -l < "$home/calls")" -eq 1 ] || fail "repeated merge invoked the hook twice"
  pass "polled and self-reported merge outcomes reach the legacy hook only once"
}

test_unconfigured_adapter_is_a_noop
test_event_mapping_preserves_arguments
test_nonlegacy_events_and_null_tickets_are_skipped
test_hook_failures_propagate_to_the_emitter
test_malformed_payloads_are_refused
test_invalid_hook_configuration_is_refused
test_polled_merge_reaches_legacy_hook_once

home=$(make_home partial-scope)
install_hook "$home"
for event in pr-merged cancelled; do
  for scope in partial null absent; do
    event_payload=$(payload "$event" issue/123 final text https://github.com/o/r/pull/7)
    case "$scope" in
      absent) event_payload=$(printf '%s' "$event_payload" | jq 'del(.ticket_scope)') ;;
      null) event_payload=$(printf '%s' "$event_payload" | jq '.ticket_scope = null') ;;
      *) event_payload=$(printf '%s' "$event_payload" | jq '.ticket_scope = "partial"') ;;
    esac
    run_sync "$home" "$event_payload" || fail "$event with $scope scope failed"
  done
done
jq -se 'length == 6 and all(.[]; . == ["issue/123","review","https://github.com/o/r/pull/7"])' "$home/calls" >/dev/null \
  || fail 'final merge or cancellation completed a partial/unknown ticket'
run_sync "$home" "$(payload cancelled issue/123 final text null partial)" || fail 'PR-less partial cancellation failed'
tail -1 "$home/calls" | jq -e '. == ["issue/123","review"]' >/dev/null \
  || fail 'PR-less partial cancellation did not retain review'
pass 'final merges and cancellations require explicit complete scope to close a ticket'
