#!/usr/bin/env bash
# Contract tests for the optional per-home ticket-sync hook: the events it is
# handed, the task records that reach a hook at all, and the two properties the
# producers depend on - that a hook can neither delay nor fail its caller, and
# that a hook which does fail says so on the task.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SYNC="$ROOT/bin/fm-ticket-sync.sh"
TMP_ROOT=$(fm_test_tmproot fm-ticket-sync)

# A home with a ticketed task record and no hook configured yet.
make_home() {  # <name>
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/config"
  fm_write_meta "$home/state/task-a.meta" \
    "window=firstmate:fm-task-a" \
    "worktree=$home/wt" \
    "kind=ship" \
    "mode=no-mistakes" \
    "ticket=ENG-2653" \
    "commit_type=feat"
  printf '%s\n' "$home"
}

# Record every argument vector the hook is handed, one call per line.
install_hook() {  # <home> [exit-code]
  local home=$1 rc=${2:-0}
  cat > "$home/hook" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$home/calls"
exit $rc
SH
  chmod +x "$home/hook"
  : > "$home/calls"
  printf '%s\n' "$home/hook" > "$home/config/ticket-sync-hook"
}

run_sync() {  # <home> <args...>
  local home=$1
  shift
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_CONFIG_OVERRIDE="$home/config" "$SYNC" "$@"
}

# The hook runs detached, so every assertion about what it did waits for the
# observable effect rather than assuming it has already landed.
wait_for_lines() {  # <file> <count>
  local file=$1 want=$2 i=0 have
  while [ "$i" -lt 600 ]; do
    if [ -f "$file" ]; then
      have=$(wc -l < "$file" 2>/dev/null || echo 0)
      [ "${have:-0}" -ge "$want" ] && return 0
    fi
    sleep 0.05
    i=$((i + 1))
  done
  return 1
}

# Nothing is expected to happen; give a call that should never come time to
# arrive before concluding it did not.
settle() {
  sleep 0.6
}

test_an_unconfigured_home_never_runs_anything() {
  local home
  home=$(make_home unconfigured)
  # The hook exists on disk but no config entry names it: this is every home
  # that has not opted in, and the milestone must cost one file test.
  cat > "$home/hook" <<SH
#!/usr/bin/env bash
printf 'ran\n' >> "$home/calls"
SH
  chmod +x "$home/hook"
  : > "$home/calls"
  run_sync "$home" task-a start || fail "an unconfigured home did not return success"
  settle
  [ ! -s "$home/calls" ] || fail "an unconfigured home ran a hook"
  assert_absent "$home/state/task-a.status" \
    "an unconfigured home wrote a status line"
  pass "a home with no configured hook runs nothing and reports nothing"
}

test_each_event_reaches_the_hook_with_its_ticket() {
  local home
  home=$(make_home events)
  install_hook "$home"
  run_sync "$home" task-a start || fail "the start event was refused"
  wait_for_lines "$home/calls" 1 || fail "the start event never reached the hook"
  assert_grep 'ENG-2653 start' "$home/calls" \
    "start did not reach the hook as '<ticket> start'"

  run_sync "$home" task-a review https://github.com/o/r/pull/7 \
    || fail "the review event was refused"
  wait_for_lines "$home/calls" 2 || fail "the review event never reached the hook"
  assert_grep 'ENG-2653 review https://github.com/o/r/pull/7' "$home/calls" \
    "review did not reach the hook with its pull request URL"

  run_sync "$home" task-a 'done' https://github.com/o/r/pull/7 \
    || fail "the done event was refused"
  wait_for_lines "$home/calls" 3 || fail "the done event never reached the hook"
  assert_grep 'ENG-2653 done https://github.com/o/r/pull/7' "$home/calls" \
    "done did not reach the hook with its pull request URL"

  run_sync "$home" task-a waiting 'captain must pick a rollout' \
    || fail "the waiting event was refused"
  wait_for_lines "$home/calls" 4 || fail "the waiting event never reached the hook"
  assert_grep 'ENG-2653 waiting captain must pick a rollout' "$home/calls" \
    "waiting did not reach the hook with its text"

  assert_absent "$home/state/task-a.status" \
    "a hook that succeeded still reported a failure on the task"
  pass "every event reaches the hook as '<ticket> <event> [args]'"
}

test_a_failing_hook_reports_the_event_and_its_exit_code() {
  local home
  home=$(make_home failing)
  install_hook "$home" 3
  run_sync "$home" task-a review https://github.com/o/r/pull/7 \
    || fail "a failing hook failed its caller"
  wait_for_lines "$home/state/task-a.status" 1 \
    || fail "a failing hook wrote no status line"
  assert_grep 'ticket sync hook failed ticket=ENG-2653 event=review exit=3' \
    "$home/state/task-a.status" \
    "the status line did not name the event and the hook's exit code"
  [ "$(wc -l < "$home/state/task-a.status")" -eq 1 ] \
    || fail "a single failed event wrote more than one status line"
  pass "a failing hook is reported as one status line naming the event and exit code"
}

test_a_hanging_hook_neither_delays_nor_fails_its_caller() {
  local home started elapsed captured
  home=$(make_home hanging)
  cat > "$home/hook" <<'SH'
#!/usr/bin/env bash
sleep 120
SH
  chmod +x "$home/hook"
  printf '%s\n' "$home/hook" > "$home/config/ticket-sync-hook"

  # A producer that captures its own output is the sharper case: a child still
  # holding the caller's stdout would keep the command substitution waiting for
  # the whole bound even though the caller itself had exited.
  started=$(date +%s)
  captured=$(FM_TICKET_SYNC_TIMEOUT=2 run_sync "$home" task-a start; printf 'rc=%s' "$?")
  elapsed=$(( $(date +%s) - started ))
  [ "$captured" = 'rc=0' ] || fail "a hanging hook did not leave its caller successful ($captured)"
  [ "$elapsed" -lt 2 ] || fail "a hanging hook held its caller for ${elapsed}s"

  wait_for_lines "$home/state/task-a.status" 1 \
    || fail "the bounded hook wrote no status line"
  assert_grep 'ticket sync hook failed ticket=ENG-2653 event=start exit=124 bound=2s' \
    "$home/state/task-a.status" \
    "the status line did not report the hook's bound as the reason"
  pass "a hanging hook is bounded without delaying or failing its caller"
}

test_a_hook_that_cannot_be_run_is_reported_rather_than_skipped() {
  local home
  home=$(make_home unrunnable)
  install_hook "$home"
  # A home that configured milestone sync and silently got none is the whole
  # failure this script exists to prevent, so a bad entry is reported.
  printf '%s\n' "$home/not-a-hook" > "$home/config/ticket-sync-hook"
  run_sync "$home" task-a start 2> "$home/err" \
    || fail "an unrunnable hook failed its caller"
  assert_grep 'does not name one absolute path to an executable hook' "$home/err" \
    "an unrunnable hook was not named on stderr"
  wait_for_lines "$home/state/task-a.status" 1 \
    || fail "an unrunnable hook wrote no status line"
  assert_grep 'ticket sync hook failed ticket=ENG-2653 event=start exit=126' \
    "$home/state/task-a.status" \
    "the status line did not report the hook as unrunnable"

  # A relative path names nothing stable from a producer that runs anywhere.
  printf '%s\n' 'hook' > "$home/config/ticket-sync-hook"
  run_sync "$home" task-a start 2>/dev/null \
    || fail "a relative hook path failed its caller"
  settle
  [ ! -s "$home/calls" ] || fail "a relative hook path was run anyway"
  pass "a hook that cannot be run is reported on the task instead of skipped"
}

test_a_task_with_no_ticket_never_reaches_the_hook() {
  local home
  home=$(make_home unticketed)
  install_hook "$home"
  # The explicit ticketless marker, a record with no ticket at all, and no
  # record whatsoever: none of them has a ticket to move.
  fm_write_meta "$home/state/marked.meta" "kind=ship" "ticket=no-ticket"
  fm_write_meta "$home/state/plain.meta" "kind=ship" "mode=no-mistakes"
  run_sync "$home" marked start || fail "the ticketless marker failed its caller"
  run_sync "$home" plain start || fail "a record with no ticket failed its caller"
  run_sync "$home" absent start || fail "an absent record failed its caller"
  settle
  [ ! -s "$home/calls" ] || fail "an unticketed task reached the hook"
  assert_absent "$home/state/marked.status" "the ticketless marker wrote a status line"
  assert_absent "$home/state/plain.status" "a record with no ticket wrote a status line"
  assert_absent "$home/state/absent.status" "an absent record wrote a status line"
  pass "a task with no ticket, or no record, never reaches the hook"
}

test_the_ticket_comes_only_from_the_record() {
  local home
  home=$(make_home record-only)
  install_hook "$home"
  # A ticket id written into the task's own prose is not a ticket: only the
  # recorded ticket= field selects one.
  fm_write_meta "$home/state/prose.meta" "kind=ship" "mode=no-mistakes"
  printf 'working: picked up ENG-9999 from the request\n' > "$home/state/prose.status"
  run_sync "$home" prose start || fail "a prose-only ticket failed its caller"
  settle
  [ ! -s "$home/calls" ] || fail "a ticket was taken from prose rather than the record"
  pass "the ticket comes from the task's record and never from its prose"
}

test_a_malformed_request_is_refused_without_running_a_hook() {
  local home rc
  home=$(make_home malformed)
  install_hook "$home"
  for args in \
    "task-a" \
    "task-a review" \
    "task-a done" \
    "task-a waiting" \
    "task-a start extra" \
    "task-a bogus" \
    "../escape start"; do
    set +e
    # shellcheck disable=SC2086 # Each case is a deliberate argument vector.
    run_sync "$home" $args 2>/dev/null
    rc=$?
    set -e
    [ "$rc" -eq 2 ] || fail "'$args' was not refused as a usage error (rc=$rc)"
  done
  settle
  [ ! -s "$home/calls" ] || fail "a malformed request still ran the hook"
  pass "a malformed request is refused as a usage error without running a hook"
}

# The `done` event fires from the shared merge-outcome operation rather than
# from the merge entrypoint, so a merge this home never performed still
# completes its ticket. That operation is the single place every confirmed
# merge is recorded, and its own already-notified guard is what makes the
# event once-per-pull-request.
# Record one confirmed merge through the shared merge-outcome operation, the
# way bin/fm-pr-merge.sh (origin self) and bin/fm-watch.sh (origin poll) do.
report_merge() (  # <home> <id> <pr-url> <origin>
  # shellcheck source=bin/fm-merge-outcome-lib.sh
  # shellcheck disable=SC1091
  . "$ROOT/bin/fm-merge-outcome-lib.sh"
  FM_CONFIG_OVERRIDE="$1/config" fm_merge_outcome_report "$1" "$1/state" "$2" "$3" "$4"
)

test_every_recorded_merge_completes_its_ticket_once() {
  local home url
  home=$(make_home merge-origins)
  install_hook "$home"
  url=https://github.com/acme/sample/pull/7
  fm_write_meta "$home/state/polled.meta" \
    "window=firstmate:fm-polled" "worktree=$home/wt" "kind=ship" \
    "mode=no-mistakes" "ticket=ENG-4100" "commit_type=feat"

  # A merge only this home's poll ever saw: a queued merge the forge finished
  # later, or one the captain made on the forge.
  report_merge "$home" polled "$url" poll \
    || fail "the polled merge outcome was not recorded"
  wait_for_lines "$home/calls" 1 \
    || fail "a merge recorded by the poll never completed its ticket"
  assert_grep "ENG-4100 done $url" "$home/calls" \
    "the polled merge did not complete the ticket with its pull request URL"

  # The same merge reported again, the way the entrypoint and a later poll both
  # report one: the guard returns before the hook, so the ticket moves once.
  report_merge "$home" polled "$url" self \
    || fail "the repeated merge outcome failed"
  settle
  [ "$(wc -l < "$home/calls")" -eq 1 ] \
    || fail "a re-reported merge completed the ticket twice: $(cat "$home/calls")"
  assert_absent "$home/state/polled.status" \
    "the succeeding hook reported a failure on the merged task"
  pass "every recorded merge completes its ticket once, whichever origin saw it"
}

test_an_unconfigured_home_never_runs_anything
test_each_event_reaches_the_hook_with_its_ticket
test_a_failing_hook_reports_the_event_and_its_exit_code
test_a_hanging_hook_neither_delays_nor_fails_its_caller
test_a_hook_that_cannot_be_run_is_reported_rather_than_skipped
test_a_task_with_no_ticket_never_reaches_the_hook
test_the_ticket_comes_only_from_the_record
test_a_malformed_request_is_refused_without_running_a_hook
test_every_recorded_merge_completes_its_ticket_once
