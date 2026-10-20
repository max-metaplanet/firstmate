#!/usr/bin/env bash
# Lifecycle hook behavior through the public incremental status classifier.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-task-event-status)

make_home() {
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/config" "$home/data"
  printf 'ticket=issue-42\n' > "$home/state/task.meta"
  cat > "$home/hook" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "$FM_HOME/events.jsonl"
SH
  chmod +x "$home/hook"
  printf '%s\n' "$home/hook" > "$home/config/task-event-hook"
  printf '%s\n' "$home"
}

fold() {
  FM_HOME=$1 FM_STATE_OVERRIDE=$1/state FM_CONFIG_OVERRIDE=$1/config \
    bash -c '. "$1"; status_open_decisions_incremental "$2"' _ \
    "$ROOT/bin/fm-classify-lib.sh" "$1/state/task.status"
}

await_events() {
  local home=$1 count=$2 i=0
  while [ "$i" -lt 100 ]; do
    if [ -f "$home/events.jsonl" ] && [ "$(wc -l < "$home/events.jsonl" | tr -d ' ')" -ge "$count" ]; then return; fi
    sleep 0.05
    i=$((i + 1))
  done
  fail "expected $count hook events in $home"
}

home=$(make_home transitions)
cat > "$home/state/task.status" <<'STATUS'
blocked [at=100] [key=credential]: service credential expired
blocked [key=credential]: credential still unavailable
needs-decision [key=scope]: choose compatibility scope
resolved [key=credential]: replacement credential installed
STATUS
fold "$home" >/dev/null || fail 'first fold failed'
await_events "$home" 2
jq -se 'length == 2 and all(.[]; .task_id == "task" and .ticket == "issue-42") and
  any(.[]; .event == "blocked" and .key == "credential" and .summary == "service credential expired") and
  any(.[]; .event == "waiting" and .key == "scope" and .summary == "choose compatibility scope")' \
  "$home/events.jsonl" >/dev/null || fail 'keyed blockers lost payload context or resumed before the final blocker cleared'
printf 'resolved [key=scope]: compatibility scope approved\n' >> "$home/state/task.status"
fold "$home" >/dev/null || fail 'resolution fold failed'
await_events "$home" 3
jq -se 'any(.[]; .event == "resumed" and .key == "scope" and .summary == "compatibility scope approved")' \
  "$home/events.jsonl" >/dev/null || fail 'final resolution was not emitted'
fold "$home" >/dev/null || fail 'repeat fold failed'
sleep 0.15
[ "$(wc -l < "$home/events.jsonl" | tr -d ' ')" = 3 ] || fail 'unchanged cursor repeated events'
pass 'keyed blockers retain worker summaries and resume only after every blocker clears'

home=$(make_home paused)
printf 'paused [key=ci]: waiting for build checks\n' > "$home/state/task.status"
fold "$home" >/dev/null
await_events "$home" 1
printf 'resolved [key=ci]: build checks passed\n' >> "$home/state/task.status"
fold "$home" >/dev/null
await_events "$home" 2
jq -se 'map(.event) | sort == ["resumed","waiting"]' "$home/events.jsonl" >/dev/null \
  || fail 'keyed wait did not resume'
pass 'keyed declared waits emit waiting and resume when resolved'
cat >> "$home/state/task.status" <<'STATUS'
resolved [key=ci]: duplicate completed build
resolved [key=unknown]: no matching wait
paused [key=next]: waiting for next build
paused [key=next]: still waiting for next build
STATUS
fold "$home" >/dev/null
await_events "$home" 3
printf 'paused [key=next]: same wait on another drain\n' >> "$home/state/task.status"
fold "$home" >/dev/null
sleep 0.15
jq -se 'length == 3 and (map(select(.event == "waiting" and .key == "next")) | length == 1)' \
  "$home/events.jsonl" >/dev/null || fail 'repeated waits or unsolicited resolution emitted false transitions'
printf 'resolved [key=next]: next build passed\nresolved [key=next]: duplicate resolution\n' >> "$home/state/task.status"
fold "$home" >/dev/null
await_events "$home" 4
sleep 0.15
[ "$(wc -l < "$home/events.jsonl" | tr -d ' ')" = 4 ] || fail 'resolution emitted more than once'
pass 'paused keys survive drains and repeated or unsolicited status declarations do not emit'

home=$(make_home custom-wait)
printf 'parked [key=build]: build is queued\n' > "$home/state/task.status"
FM_CLASSIFY_PAUSED_VERB=parked fold "$home" >/dev/null
await_events "$home" 1
printf 'resolved [key=build]: build finished\n' >> "$home/state/task.status"
FM_CLASSIFY_PAUSED_VERB=parked fold "$home" >/dev/null
await_events "$home" 2
jq -se 'map(.event) == ["waiting","resumed"]' "$home/events.jsonl" >/dev/null \
  || fail 'configured wait vocabulary did not emit lifecycle events'
pass 'configured wait vocabulary uses the same lifecycle transitions'

home=$(make_home quiet)
cat > "$home/state/task.status" <<'STATUS'
blocked [key=ordinary]: worker blocker
needs-decision [key=captain-hold-child-1]: captain hold child: choose scope
resolved [key=captain-hold-child-1]: captain hold child: released
STATUS
FM_HOME=$home FM_CONFIG_OVERRIDE=$home/config bash -c '. "$1"; status_open_decisions "$2"' _ \
  "$ROOT/bin/fm-classify-lib.sh" "$home/state/task.status" >/dev/null
[ ! -e "$home/events.jsonl" ] || fail 'pure reader emitted'
fold "$home" >/dev/null
await_events "$home" 1
sleep 0.15
jq -se 'length == 1 and .[0].key == "ordinary"' "$home/events.jsonl" >/dev/null \
  || fail 'parent-channel hold mirror emitted a duplicate lifecycle event'
pass 'pure readers and captain-hold mirror rows never emit lifecycle events'

home=$(make_home rebuilt)
cat > "$home/state/task.status" <<'STATUS'
blocked [key=ci]: checks failing
resolved [key=ci]: checks fixed
STATUS
fold "$home" >/dev/null
await_events "$home" 2
cursor=$(bash -c '. "$1"; _fm_open_decisions_cursor_path "$2"' _ \
  "$ROOT/bin/fm-classify-lib.sh" "$home/state/task.status")
sed -e '1s/.*/version=0/' "$cursor" > "$cursor.old" && mv "$cursor.old" "$cursor"
printf 'blocked [key=review]: awaiting reviewer\n' >> "$home/state/task.status"
fold "$home" >/dev/null
await_events "$home" 3
sleep 0.15
jq -se 'map(.event + ":" + .key) == ["blocked:ci","resumed:ci","blocked:review"]' \
  "$home/events.jsonl" >/dev/null || fail 'discarded cursor replayed emitted history'
pass 'a discarded cursor rebuilds history silently and emits only new bytes'

home=$(make_home disabled)
rm "$home/config/task-event-hook"
printf 'blocked [key=access]: waiting for access\n' > "$home/state/task.status"
out=$(fold "$home") || fail 'disabled fold failed'
assert_contains "$out" 'waiting for access' 'no-op hook changed classification'
[ ! -e "$home/events.jsonl" ] || fail 'absent hook emitted an event'
pass 'absent hook leaves the status classifier unchanged'

# Terminal events must retain their payload even though successful teardown
# removes the task's metadata and status before it emits.
for declaration in "done" working; do
  home=$(make_home "teardown-$declaration")
  mkdir -p "$home/project" "$home/fakebin"
  git init -q "$home/project"
  printf 'manual\n' > "$home/config/backlog-backend"
  fm_fake_exit0 "$home/fakebin" tmux treehouse no-mistakes gh-axi gh
  cat > "$home/fakebin/lsof" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$home/fakebin/lsof"
  fm_write_meta "$home/state/task.meta" \
    'window=isolated:fm-task' 'endpoint_task_id=task' \
    "worktree=$home/gone-worktree" "project=$home/project" \
    'kind=ship' 'mode=local-only' 'spawn_gen=task-event-fixture' 'ticket=issue-42' 'ticket_scope=complete'
  printf '%s: worker terminal summary\n' "$declaration" > "$home/state/task.status"
  printf 'actionable [at=200]: task event hook failed event=pr-opened exit=124; see state/task-events.log\n' \
    >> "$home/state/task.status"
  : > "$home/state/.task.decision-event-1"
  FM_HOME=$home FM_STATE_OVERRIDE=$home/state FM_CONFIG_OVERRIDE=$home/config FM_DATA_OVERRIDE=$home/data \
    FM_ROOT_OVERRIDE=$ROOT PATH="$home/fakebin:$PATH" \
    "$ROOT/bin/fm-teardown.sh" task --force > "$home/teardown.out" 2> "$home/teardown.err" \
    || fail "terminal event teardown failed: $(cat "$home/teardown.err")"
  await_events "$home" 1
  expected=finished expected_scope=complete
  # A cancelled task whose own PR never merged delivered nothing, so its
  # declared complete scope is published as partial.
  [ "$declaration" = "done" ] || { expected=cancelled; expected_scope=partial; }
  jq -se --arg event "$expected" --arg scope "$expected_scope" 'length == 1 and .[0].event == $event and
    .[0].ticket == "issue-42" and .[0].ticket_scope == $scope and .[0].summary == "worker terminal summary"' "$home/events.jsonl" >/dev/null \
    || fail 'teardown lost its terminal payload'
  assert_absent "$home/state/task.meta" 'teardown emitted without retiring the task'
  assert_absent "$home/state/task.status" 'teardown emitted without retiring the status'
  assert_absent "$home/state/.task.decision-event-1" 'teardown kept a decision-event marker'
  pass "successful teardown emits $expected with the retired task context"
done

home=$(make_home scope-status)
rm "$home/config/task-event-hook"
printf 'ticket_scope=partial\n' >> "$home/state/task.meta"
url=https://github.com/o/r/pull/7
printf 'done [at=100]: PR %s checks green ticket-scope=complete\n' "$url" > "$home/state/task.status"
fold "$home" >/dev/null || fail 'scope fold failed'
grep -qx 'ticket_scope=complete' "$home/state/task.meta" || fail 'worker did not upgrade scope'
printf 'done: PR %s checks green ticket-scope=partial\n' "$url" >> "$home/state/task.status"
fold "$home" >/dev/null || fail 'scope downgrade fold failed'
grep -qx 'ticket_scope=partial' "$home/state/task.meta" || fail 'worker did not downgrade scope'
printf 'done: PR %s checks green\nworking: ticket-scope=complete\n' "$url" >> "$home/state/task.status"
fold "$home" >/dev/null || fail 'nondeclaration fold failed'
grep -qx 'ticket_scope=partial' "$home/state/task.meta" || fail 'non-ready status changed scope'
# A registered PR binds later scope reports to that URL.
printf 'pr=%s\n' "$url" >> "$home/state/task.meta"
printf 'done: PR https://github.com/o/r/pull/8 checks green ticket-scope=complete\n' >> "$home/state/task.status"
fold "$home" >/dev/null || fail 'other PR fold failed'
grep -qx 'ticket_scope=partial' "$home/state/task.meta" || fail 'another PR changed scope'
for ticket in no-ticket none ''; do
  printf 'ticket=%s\nticket_scope=partial\n' "$ticket" > "$home/state/task.meta"
  printf 'done: PR %s checks green ticket-scope=complete\n' "$url" >> "$home/state/task.status"
  fold "$home" >/dev/null || fail 'ticketless fold failed'
  grep -qx 'ticket_scope=partial' "$home/state/task.meta" || fail 'ticketless status gained complete scope'
done
pass 'PR-ready status folding records explicit upgrades and downgrades without requiring a hook'
