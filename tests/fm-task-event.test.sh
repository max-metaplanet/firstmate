#!/usr/bin/env bash
# Generic lifecycle event payloads, PR aggregation, and detached delivery.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-task-event)
EMIT="$ROOT/bin/fm-task-event.sh"

make_home() {
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/config"
  printf 'ticket=ISSUE/custom-42\n' > "$home/state/task.meta"
  printf 'working [at=100] [key=build]: worker says "ready"\n' > "$home/state/task.status"
  cat > "$home/hook" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "$FM_HOME/events"
SH
  chmod +x "$home/hook"
  printf '%s\n' "$home/hook" > "$home/config/task-event-hook"
  printf '%s' "$home"
}
emit() {
  local home=$1; shift
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" "$EMIT" "$@"
}
wait_lines() {
  local file=$1 count=$2 i
  for ((i=0; i<300; i++)); do
    if [ -f "$file" ] && [ "$(wc -l < "$file")" -ge "$count" ]; then return 0; fi
    sleep 0.1
  done
  fail "waiting for $count lines in $file"
}

home=$(make_home events)
count=0
for event in started blocked waiting resumed decision-answered pr-opened pr-merged finished cancelled; do
  emit "$home" task "$event" --pr https://example.org/repo/pull/1 --key build
  count=$((count + 1))
  wait_lines "$home/events" "$count"
  tail -1 "$home/events" | jq -e --arg event "$event" --arg home "$home" '
    .schema == "firstmate.task-event" and .version == 1 and .event == $event
    and .task_id == "task" and .ticket == "ISSUE/custom-42" and .key == "build"
    and .home == $home and .summary == "worker says \"ready\""
    and .pr_url == "https://example.org/repo/pull/1"
    and (.timestamp | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T"))' >/dev/null \
    || fail "bad $event payload"
done
pass 'all event types preserve opaque ticket, worker summary, key, home and PR'

home=$(make_home unticketed)
emit "$home" absent finished --summary 'completed without metadata'
wait_lines "$home/events" 1
jq -e '.ticket == null and .pr_url == null and .summary == "completed without metadata"' "$home/events" >/dev/null || fail 'unticketed payload'
emit "$home" removed cancelled --ticket OTHER/99 --summary $'first\nsecond' --pr https://example.org/pull/2
wait_lines "$home/events" 2
tail -1 "$home/events" | jq -e '.ticket == "OTHER/99" and .summary == "first second"' >/dev/null || fail 'teardown snapshot'
pass 'unticketed and removed tasks retain lifecycle events'

home=$(make_home disabled)
rm "$home/config/task-event-hook"
emit "$home" task started
[ ! -e "$home/events" ] && [ ! -e "$home/state/task-event-prs.jsonl" ] || fail 'disabled hook had effects'
pass 'absent config is a no-op'

home=$(make_home merges)
printf 'ticket=ISSUE/custom-42\n' > "$home/state/other.meta"
emit "$home" task pr-opened --pr https://example.org/pull/1
emit "$home" other pr-opened --pr https://example.org/pull/2
wait_lines "$home/events" 2
emit "$home" task pr-merged --pr https://example.org/pull/1
wait_lines "$home/events" 3
tail -1 "$home/events" | jq -e '.merge == "partial"' >/dev/null || fail 'first merge should be partial'
rm "$home/state/task.meta"
emit "$home" other pr-merged --pr https://example.org/pull/2
wait_lines "$home/events" 4
tail -1 "$home/events" | jq -e '.merge == "final"' >/dev/null || fail 'last merge should be final'
pass 'all recorded PRs for the ticket determine partial versus final across tasks and cleanup'

home=$(make_home superseded)
printf 'ticket=ISSUE/custom-42\n' > "$home/state/other.meta"
emit "$home" task pr-opened --pr https://example.org/pull/1
emit "$home" task pr-opened --pr https://example.org/pull/2
emit "$home" other pr-opened --pr https://example.org/pull/3
emit "$home" other cancelled
emit "$home" task pr-merged --pr https://example.org/pull/2
wait_lines "$home/events" 5
tail -1 "$home/events" | jq -e '.merge == "final"' >/dev/null || fail 'superseded or cancelled PRs blocked final'
pass 'a replaced PR and a cancelled task PR no longer hold the ticket partial'

home=$(make_home cancel-final)
printf 'ticket=ISSUE/custom-42\n' > "$home/state/other.meta"
emit "$home" task pr-opened --pr https://example.org/pull/1
emit "$home" other pr-opened --pr https://example.org/pull/2
emit "$home" task pr-merged --pr https://example.org/pull/1
emit "$home" other cancelled
printf 'ticket=ISSUE/no-prs\n' > "$home/state/idle.meta"
emit "$home" idle cancelled
wait_lines "$home/events" 5
jq -es '[.[] | select(.event == "pr-merged" or .event == "cancelled") | [.task_id, .merge]]
  == [["task","partial"],["other","final"],["idle",null]]' "$home/events" >/dev/null \
  || fail 'cancelled did not report whether the ticket remaining PRs all merged'
pass 'cancelling the last open PR reports a final merge, and a PR-less cancel reports none'

home=$(make_home failure)
printf '#!/usr/bin/env bash\nexit 7\n' > "$home/hook"
emit "$home" task started
wait_lines "$home/state/task-events.log" 1
assert_grep 'task_id=task event=started exit=7' "$home/state/task-events.log" 'failure was not logged'
printf '%s\n' relative > "$home/config/task-event-hook"
emit "$home" task blocked
wait_lines "$home/state/task-events.log" 2
assert_grep 'event=blocked exit=126' "$home/state/task-events.log" 'invalid hook was not logged'
[ "$(grep -c '^actionable \[at=[0-9]*\]: task event hook failed event=started exit=7; see state/task-events.log$' "$home/state/task.status")" = 1 ] \
  || fail "consumer failure was not surfaced once on the task: $(cat "$home/state/task.status")"
[ "$(grep -c 'task event hook failed' "$home/state/task.status")" = 1 ] || fail 'repeated failures flooded the task status'
emit "$home" absent started
wait_lines "$home/state/task-events.log" 3
assert_absent "$home/state/absent.status" 'failure surfaced into a task without a live status'
pass 'failing or invalid consumers never fail the producer and surface once per task'

home=$(make_home legacy-only)
rm "$home/config/task-event-hook"
cat > "$home/legacy" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_HOME/legacy-calls"
SH
chmod +x "$home/legacy"
printf '%s\n' "$home/legacy" > "$home/config/ticket-sync-hook"
emit "$home" task started
emit "$home" task pr-opened --pr https://example.org/pull/9
wait_lines "$home/legacy-calls" 2
[ "$(cat "$home/legacy-calls")" = $'ISSUE/custom-42 start\nISSUE/custom-42 review https://example.org/pull/9' ] \
  || fail "legacy-only home lost tracker updates: $(cat "$home/legacy-calls")"
[ "$(grep -c 'compatibility: config/ticket-sync-hook .*config/task-event-hook' "$home/state/task-events.log")" = 1 ] \
  || fail 'compatibility path was not logged exactly once'
pass 'a home with only the legacy hook keeps syncing through the adapter and says so once'

home=$(make_home hanging)
printf '#!/usr/bin/env bash\nsleep 60\n' > "$home/hook"
started=$(date +%s)
captured=$(FM_TASK_EVENT_TIMEOUT=3 emit "$home" task started; printf returned)
elapsed=$(( $(date +%s) - started ))
[ "$captured" = returned ] && [ "$elapsed" -lt 3 ] || fail 'hook held caller streams or blocked return'
wait_lines "$home/state/task-events.log" 1
assert_grep 'event=started exit=124' "$home/state/task-events.log" 'hanging hook was not bounded'
pass 'hanging consumer is detached, bounded, and holds no caller stream'

home=$(make_home ordered)
cat > "$home/hook" <<'SH'
#!/usr/bin/env bash
event=$(printf '%s' "$1" | jq -r '.event')
if [ "$event" = blocked ]; then
  : > "$FM_HOME/entered"
  while [ ! -e "$FM_HOME/release" ]; do sleep 0.05; done
fi
printf '%s\n' "$1" >> "$FM_HOME/events"
[ "$event" != waiting ] || exit 7
SH
FM_TASK_EVENT_TIMEOUT=10 emit "$home" task blocked
for ((i=0; i<100; i++)); do
  [ -e "$home/entered" ] && break
  sleep 0.05
done
[ -e "$home/entered" ] || fail 'blocked consumer did not start'
# These calls must all return while the earlier consumer is still held.
emit "$home" task resumed
emit "$home" task waiting
emit "$home" task pr-opened --pr https://example.org/pull/ordered-1
emit "$home" other pr-opened --ticket ISSUE/custom-42 --pr https://example.org/pull/ordered-2
emit "$home" task pr-merged --pr https://example.org/pull/ordered-1
emit "$home" other pr-merged --ticket ISSUE/custom-42 --pr https://example.org/pull/ordered-2
emit "$home" task finished
[ ! -e "$home/events" ] || fail 'a later event overtook the blocked consumer'
: > "$home/release"
wait_lines "$home/events" 8
jq -es '
  map(.event) == ["blocked","resumed","waiting","pr-opened","pr-opened","pr-merged","pr-merged","finished"]
  and ([.[] | select(.event == "pr-merged") | .merge] == ["partial","final"])
  and (map(.sequence) == [1,2,3,4,5,6,7,8])
' "$home/events" >/dev/null || fail 'queued events lost order or publication-time merge state'
assert_grep 'event=waiting exit=7' "$home/state/task-events.log" 'failed queued consumer was not logged'
pass 'delayed and failed consumers preserve event order and publication-time merge outcomes'

home=$(make_home timeout-continues)
cat > "$home/hook" <<'SH'
#!/usr/bin/env bash
[ "$(printf '%s' "$1" | jq -r '.event')" != blocked ] || sleep 60
printf '%s\n' "$1" >> "$FM_HOME/events"
SH
FM_TASK_EVENT_TIMEOUT=2 emit "$home" task blocked
FM_TASK_EVENT_TIMEOUT=2 emit "$home" task resumed
wait_lines "$home/events" 1
jq -e '.event == "resumed"' "$home/events" >/dev/null || fail 'timed-out hook jammed later events'
assert_grep 'event=blocked exit=124' "$home/state/task-events.log" 'queued timeout was not logged'
pass 'a timed-out consumer releases the queue for the next event'

home=$(make_home stale-drainer)
FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" bash -c '
  . "$1/bin/fm-wake-lib.sh"
  fm_lock_try_acquire "$STATE/.task-event-delivery.lock"
' _ "$ROOT" || fail 'could not create abandoned delivery-lock fixture'
emit "$home" task resumed
wait_lines "$home/events" 1
jq -e '.event == "resumed"' "$home/events" >/dev/null || fail 'dead drainer lock blocked delivery'
pass 'the existing lock recovery permits delivery after a drainer dies'
