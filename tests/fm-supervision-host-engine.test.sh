#!/usr/bin/env bash
# tests/fm-supervision-host-engine.test.sh - the host's away engine turn: the
# wakes it handles without reaching main, the lead seat its next launch moves
# to, the outcomes it relays when the captain returns, and the turns a killed,
# failed, or unacknowledged engine leaves behind.
#
# Fixtures, the stub engine, and the shared assertions live in
# tests/supervision-host-helpers.sh, whose header names the sibling suites
# that carry the rest of these cases.
# shellcheck disable=SC2016 # single-quoted scripts expand inside their own shells
set -u

# shellcheck source=tests/supervision-host-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/supervision-host-helpers.sh"

test_away_wake_is_handled_on_the_engine_and_never_reaches_main() {
  local home lock_pid session first second pid watcher
  home=$(make_home away-handled away)
  echo hold-lease > "$home/stub-mode"
  # Dialog in the mirror that an away wake must neither carry nor mark read.
  printf '{"hook_event_name":"UserPromptSubmit","prompt_id":"p1","prompt":"keep the export worker on low effort"}' > "$home/mirror-seed.1"
  start_host "$home"
  wait_until 150 watcher_live "$home" || fail "away: the host never started a watcher cycle: $(cat "$home/host.out")"
  append_status "$home" 'step one'
  wait_until 250 handled_at_least "$home" 1 || fail "away: the wake was not handled: $(cat "$home/host.out"; cat "$home/state/.supervision-host.log")"
  lock_pid=$(cat "$home/state/.lock")

  first="$home/engine-call.1"
  assert_re '^actor=branch$' "$first" "the engine must run as the branch actor"
  assert_re "^holder=$lock_pid\$" "$first" "the engine's lease holder must be the session-lock holder"
  assert_re '^primary=claude$' "$first" "the engine must carry the primary-harness pin"
  assert_re '^turn=host-' "$first" "the engine must carry its report turn"
  assert_re '^arg=--safe-mode$' "$first" "the engine must load none of the home's hooks"
  assert_re '^arg=dontAsk$' "$first" "the engine must never prompt"
  assert_re '^arg=sonnet$' "$first" "the engine must default to its default model"
  assert_re '^arg=--session-id$' "$first" "the first turn must open a new conversation"
  assert_re '^POSTURE: AWAY\.' "$first" "the wake must carry the away tail"
  assert_grep 'keep the export worker on low effort' "$home/state/.host-mirror.jsonl" "fixture: the captain's dialog was not mirrored"
  assert_no_re 'MAIN DIALOG MIRROR|low effort' "$first" "an away wake must carry no dialog mirror"
  assert_absent "$home/state/.host-mirror-cursor" "a handled away wake must leave the mirror cursor where it was"
  assert_absent "$home/state/.host-mirror-cursor.next" "an away wake must stage no mirror cursor"
  assert_grep '"task":"demo"' "$home/state/branch-outcomes.jsonl" "the engine's report did not reach the outcome store"
  assert_no_grep 'demo.status' "$home/state/.wake-queue" "the engine's acknowledgement did not consume the wake"
  if FM_HOME="$home" "$LEASE" check demo >/dev/null 2>&1; then
    fail "the host did not release the lease the engine left held: $(FM_HOME="$home" "$LEASE" check demo)"
  fi
  [ ! -s "$home/host.rc" ] || fail "a handled away wake reached main: $(cat "$home/host.out")"
  [ "$(grep -cv '^watcher: started pid=' "$home/host.out")" -eq 0 ] \
    || fail "a handled away wake printed more than the first cycle's status to main: $(cat "$home/host.out")"
  watcher_live "$home" || fail "the host is not parked on a live successor cycle"

  echo handle > "$home/stub-mode"
  append_status "$home" 'step two'
  wait_until 250 handled_at_least "$home" 2 || fail "away: the second wake was not handled"
  session=$(sed -n '/^arg=--session-id$/{n;s/^arg=//p;}' "$first")
  second="$home/engine-call.2"
  assert_re '^arg=--resume$' "$second" "a later turn must resume the conversation"
  assert_re "^arg=$session\$" "$second" "a later turn must resume the same conversation"
  [ "$(grep -c '"task":"demo"' "$home/state/branch-outcomes.jsonl")" -eq 2 ] || fail "the second outcome was not recorded"
  assert_re '	handled	turn=[^	]*\.2	.* cost=0\.25 conversation_cost=0\.5 ' "$home/state/.supervision-host.log" \
    "a resumed turn must log its own cost, not the conversation's running total"

  pid=$(awk -F '\t' '$1 == "host" { print $2 }' "$home/state/.supervision-host")
  watcher=$(cat "$home/state/.watch.lock/pid")
  kill -TERM "$pid"
  wait_until 200 host_exited "$home" || fail "the host did not stop on TERM"
  expect_code 143 "$(cat "$home/host.rc")" "a TERMed host must exit 143"
  wait_until 100 sh -c '! kill -0 "$1" 2>/dev/null' _ "$watcher" || fail "a stopped host left its watcher running"
  assert_absent "$home/state/.supervision-host" "a stopped host left its record"
  pass "host: an away wake is handled on the engine through the branch contract and never reaches main"
}

test_away_turn_without_a_report_hands_the_wake_to_main() {
  local home token
  home=$(make_home away-noreport away)
  echo noreport > "$home/stub-mode"
  start_host "$home"
  wait_until 150 watcher_live "$home" || fail "noreport: the host never started a watcher cycle"
  append_status "$home" 'needs a look'
  wait_until 250 host_exited "$home" || fail "noreport: the host did not hand the wake to main"
  expect_code 0 "$(cat "$home/host.rc")" "a handed-back wake must exit 0 for the owner to deliver"
  assert_re '^signal: .*demo.status' "$home/host.out" "the handed-back close must carry the reason line"
  assert_re '^supervision-host: .*recorded no outcome for its wake; this wake is yours$' "$home/host.out" "the handback must say why"
  assert_grep 'demo.status' "$home/state/.wake-queue" "the unhandled wake must stay durable for main"
  watcher_live "$home" && fail "the host left its successor cycle running when it handed the wake to main"
  token=$(cat "$home/state/.watcher-down")
  case "$token" in
    pending:downtime:*|announced:downtime:*) ;;
    *) fail "a handback must leave the recovery marker in downtime for the owner's rewake, got: $token" ;;
  esac
  assert_absent "$home/state/.supervision-host-engine" "a turn that did not handle its wake must not keep its conversation"
  pass "host: an engine turn that records no outcome hands its durable wake to main"
}

# The lead moves onto another Claude seat while the host is parked: the next
# engine launch spends the new seat rather than the one it inherited, and it
# opens a new conversation, because the old conversation lives under the old
# seat's profile.
test_lead_seat_move_moves_the_next_engine_launch() {
  local home seat_a seat_b lock_pid first second first_session second_session
  home=$(make_home seat-move away)
  seat_a="$home/seats/seat-a"
  seat_b="$home/seats/seat-b"
  start_host "$home"
  wait_until 150 watcher_live "$home" || fail "seat-move: the host never started a watcher cycle: $(cat "$home/host.out")"
  append_status "$home" 'step one'
  wait_until 250 handled_at_least "$home" 1 || fail "seat-move: the first wake was not handled: $(cat "$home/state/.supervision-host.log")"
  first="$home/engine-call.1"
  assert_re "^profile=$seat_a\$" "$first" "the first turn must launch on the seat the lead itself runs on"
  assert_re '^arg=--session-id$' "$first" "the first turn must open a new conversation"
  assert_grep "profile=$seat_a" "$home/state/.supervision-host-engine" "the conversation must record the seat it was opened on"

  # The lead restarts onto seat-b: the successor records that seat beside the
  # lock, as bin/fm-lead-restart.sh leaves it. The host process is the one from
  # before the move, and start_host started it with CLAUDE_CONFIG_DIR naming
  # seat-a, so its own environment still names the seat the lead left.
  lock_pid=$(cat "$home/state/.lock")
  printf 'pid=%s\nharness=claude\nprofile=%s\n' "$lock_pid" "$seat_b" > "$home/state/.lock-runtime"
  append_status "$home" 'step two'
  wait_until 250 handled_at_least "$home" 2 || fail "seat-move: the second wake was not handled: $(cat "$home/state/.supervision-host.log")"
  second="$home/engine-call.2"
  assert_re "^profile=$seat_b\$" "$second" "the next launch after a seat move must spend the new seat"
  assert_no_re "^profile=$seat_a\$" "$second" "the next launch must not keep spending the seat the lead left"
  assert_re '^arg=--session-id$' "$second" "a launch on a new seat must open a new conversation"
  assert_no_re '^arg=--resume$' "$second" "a conversation opened on the old seat must not be resumed on the new one"
  first_session=$(sed -n '/^arg=--session-id$/{n;s/^arg=//p;}' "$first")
  second_session=$(sed -n '/^arg=--session-id$/{n;s/^arg=//p;}' "$second")
  [ -n "$second_session" ] && [ "$second_session" != "$first_session" ] \
    || fail "the new conversation reused the old session id ($first_session)"
  assert_grep "profile=$seat_b" "$home/state/.supervision-host-engine" "the conversation must record the new seat"
  pass "host: a lead seat move moves the next engine launch and opens a new conversation"
}

test_codex_lead_retains_a_separate_claude_engine_seat() {
  local home lock_pid codex_profile claude_profile
  home=$(make_home codex-seat away)
  codex_profile="$home/seats/codex"
  claude_profile="$home/seats/seat-b"
  mkdir -p "$codex_profile"
  start_host "$home"
  wait_until 150 watcher_live "$home" || fail "codex-seat: the host never started a watcher cycle"
  lock_pid=$(cat "$home/state/.lock")
  printf 'pid=%s\nharness=codex\nprofile=%s\nclaude_profile=%s\n' \
    "$lock_pid" "$codex_profile" "$claude_profile" > "$home/state/.lock-runtime"
  append_status "$home" 'Codex lead with retained Claude credentials'
  wait_until 250 handled_at_least "$home" 1 || fail "codex-seat: the wake was not handled: $(cat "$home/host.out")"
  assert_re "^profile=$claude_profile\$" "$home/engine-call.1" "the Claude engine must use the retained Claude seat"
  assert_no_re "^profile=$codex_profile\$" "$home/engine-call.1" "the Codex seat must never be passed to Claude"

  printf 'pid=%s\nharness=codex\nprofile=%s\nclaude_profile=\n' \
    "$lock_pid" "$codex_profile" > "$home/state/.lock-runtime"
  append_status "$home" 'Codex lead with ambient Claude credentials'
  wait_until 250 handled_at_least "$home" 2 || fail "codex-seat: the ambient wake was not handled"
  assert_re '^profile=$' "$home/engine-call.2" "an explicitly ambient Claude seat must clear the inherited profile"

  printf 'pid=%s\nharness=codex\nprofile=%s\n' "$lock_pid" "$codex_profile" > "$home/state/.lock-runtime"
  append_status "$home" 'Codex lead without Claude credentials record'
  wait_until 250 host_exited "$home" || fail "codex-seat: the missing Claude profile was not handed back"
  assert_grep 'no retained Claude profile' "$home/host.out" "the handback must name the absent Claude profile"
  [ "$(engine_calls "$home")" -eq 2 ] || fail "the engine launched without a retained Claude profile"
  assert_grep 'demo.status' "$home/state/.wake-queue" "the unhandled wake must stay durable for main"
  pass "host: a Codex lead uses only its retained Claude engine seat and refuses a missing record"
}

# The lead runs on the ambient default login, so its record names no profile,
# while the host process still carries seat-a in its own environment: the
# engine launch clears CLAUDE_CONFIG_DIR rather than spending seat-a.
test_ambient_default_lead_seat_clears_the_hosts_inherited_seat() {
  local home first
  home=$(make_home seat-ambient away)
  : > "$home/lead-profile"
  start_host "$home"
  wait_until 150 watcher_live "$home" || fail "seat-ambient: the host never started a watcher cycle: $(cat "$home/host.out")"
  append_status "$home" 'step one'
  wait_until 250 handled_at_least "$home" 1 || fail "seat-ambient: the wake was not handled: $(cat "$home/state/.supervision-host.log")"
  first="$home/engine-call.1"
  assert_re '^profile=$' "$first" "a lead on the ambient default login must launch the engine with CLAUDE_CONFIG_DIR cleared"
  assert_no_re "^profile=$home/seats/seat-a\$" "$first" "the launch must not inherit the seat in the host's own environment"
  pass "host: a lead on the ambient default login clears the seat the host inherited"
}

# The record of the seat the lead runs on is gone, so which seat the engine
# would spend is unknown: the wake goes to main with that reason and no engine
# launches at all.
test_unreadable_lead_seat_record_hands_the_wake_to_main() {
  local home
  home=$(make_home seat-unreadable away)
  start_host "$home"
  wait_until 150 watcher_live "$home" || fail "seat-unreadable: the host never started a watcher cycle"
  rm -f "$home/state/.lock-runtime"
  append_status "$home" 'needs a look'
  wait_until 250 host_exited "$home" || fail "seat-unreadable: the host did not hand the wake to main"
  expect_code 0 "$(cat "$home/host.rc")" "a handed-back wake must exit 0 for the owner to deliver"
  assert_re '^signal: .*demo.status' "$home/host.out" "the handed-back close must carry the reason line"
  assert_re '^supervision-host: .*the record of the Claude seat this session runs on' "$home/host.out" \
    "the handback must name the unknown seat as the cause"
  [ "$(engine_calls "$home")" -eq 0 ] \
    || fail "an engine launched although the seat it would spend is unknown"
  assert_grep 'demo.status' "$home/state/.wake-queue" "the unhandled wake must stay durable for main"
  pass "host: an unreadable record of the lead's own seat hands the wake to main instead of guessing a seat"
}

# A record left behind by the lead that has already gone names a pid the lock
# no longer holds, so it is no verdict rather than a stale answer: the wake
# goes to main and the seat that record names is never spent.
test_departed_leads_seat_record_is_never_spent() {
  local home seat_a
  home=$(make_home seat-stale away)
  seat_a="$home/seats/seat-a"
  start_host "$home"
  wait_until 150 watcher_live "$home" || fail "seat-stale: the host never started a watcher cycle"
  printf 'pid=%s\nprofile=%s\n' 999999 "$seat_a" > "$home/state/.lock-runtime"
  append_status "$home" 'needs a look'
  wait_until 250 host_exited "$home" || fail "seat-stale: the host did not hand the wake to main"
  assert_re '^supervision-host: .*the record of the Claude seat this session runs on' "$home/host.out" \
    "the handback must name the unknown seat as the cause"
  [ "$(engine_calls "$home")" -eq 0 ] \
    || fail "an engine launched on the seat a record the lock no longer owns names"
  assert_grep 'demo.status' "$home/state/.wake-queue" "the unhandled wake must stay durable for main"
  pass "host: a record left by a departed lead never decides which seat the engine spends"
}

test_return_during_an_engine_turn_hands_its_outcomes_to_main() {
  local home
  home=$(make_home away-return away)
  echo return > "$home/stub-mode"
  start_host "$home"
  wait_until 150 watcher_live "$home" || fail "return: the host never started a watcher cycle"
  append_status "$home" 'mid-task'
  wait_until 250 host_exited "$home" || fail "return: the host did not hand the late outcome to main: $(cat "$home/state/.supervision-host.log")"
  expect_code 0 "$(cat "$home/host.rc")" "a late-outcome handoff must exit 0 for the owner to deliver"
  assert_absent "$home/state/.afk-contract" "fixture: the stub's return did not archive the record"
  assert_re '^signal: .*demo.status' "$home/host.out" "the handoff must carry the close"
  assert_re '^supervision-host: the captain returned while the away session was handling this wake.*store rows 1[,)]' "$home/host.out" \
    "the handoff must say the captain returned mid-turn and name the store rows"
  assert_re '^supervision-host: outcome 1 for demo \[routine\]: stub handled demo$' "$home/host.out" \
    "the handoff must carry the turn's outcome for main to relay"
  assert_re '	handled	turn=' "$home/state/.supervision-host.log" "the turn itself was handled"
  assert_no_grep 'demo.status' "$home/state/.wake-queue" "the handled wake must stay acknowledged"
  watcher_live "$home" && fail "the host left its successor cycle running when it handed the outcome to main"
  pass "host: a captain return during an engine turn hands that turn's outcomes to main"
}

# Silent outcomes stay stored, but neither captain-return path names or relays
# them when the host decides whether to hand the wake to main.
test_silent_outcomes_are_not_relayed_when_the_captain_returns() {
  local mode home host
  for mode in return-silent return-fail-silent; do
    home=$(make_home "away-$mode" away)
    echo "$mode" > "$home/stub-mode"
    start_host "$home"
    wait_until 150 watcher_live "$home" || fail "$mode: the host never started a watcher cycle"
    append_status "$home" 'no-change result during a captain return'

    if [ "$mode" = return-silent ]; then
      wait_until 250 handled_at_least "$home" 1 || fail "$mode: the wake was not handled: host=$(cat "$home/host.out" 2>/dev/null) log=$(tail -n 8 "$home/state/.supervision-host.log" 2>/dev/null) report=$(cat "$home/engine-report.log" 2>/dev/null)"
      [ ! -s "$home/host.rc" ] || fail "$mode: a silent-only outcome forced a captain handoff: $(cat "$home/host.out")"
      watcher_live "$home" || fail "$mode: the host did not park on its successor"
      host=$(awk -F '\t' '$1 == "host" { print $2 }' "$home/state/.supervision-host")
      kill -TERM "$host"
      wait_until 200 host_exited "$home" || fail "$mode: the host did not stop on TERM"
    else
      wait_until 250 host_exited "$home" || fail "$mode: the failed turn did not hand the wake to main: $(cat "$home/host.out" 2>/dev/null) $(tail -n 8 "$home/state/.supervision-host.log" 2>/dev/null)"
      assert_re '^supervision-host: the away session could not take this wake: the engine turn failed \(exit 3\); this wake is yours$' \
        "$home/host.out" "$mode: the failed turn must still hand its wake to main"
    fi
    assert_no_re 'captain returned|store rows|^supervision-host: outcome ' "$home/host.out" \
      "$mode: a silent outcome was referenced in the captain-return handoff"
    assert_grep '"silent":true' "$home/state/branch-outcomes.jsonl" "$mode: the silent outcome was not retained in the store"
    assert_absent "$home/state/.afk-contract" "$mode: the captain return was not archived"
  done
  pass "host: silent outcomes are excluded from both captain-return handoff paths"
}

test_large_turn_relays_an_early_visible_outcome() {
  local home count
  home=$(make_home away-many-receipts away)
  echo return-many > "$home/stub-mode"
  start_host "$home"
  wait_until 150 watcher_live "$home" || fail "many receipts: the host never started a watcher cycle"
  append_status "$home" 'large turn with a visible first outcome'
  wait_until 2000 host_exited "$home" || fail "many receipts: the captain-return handoff did not finish: host=$(cat "$home/host.out" 2>/dev/null) log=$(tail -n 8 "$home/state/.supervision-host.log" 2>/dev/null) report=$(tail -n 5 "$home/engine-report.log" 2>/dev/null) rows=$(wc -l < "$home/state/branch-outcomes.jsonl" 2>/dev/null)"
  count=$(grep -c '^supervision-host: outcome ' "$home/host.out")
  [ "$count" -eq 1 ] || fail "many receipts: expected one visible outcome, got $count: $(tail -n 5 "$home/host.out")"
  [ "$(wc -l < "$home/state/branch-outcomes.jsonl" | tr -d ' ')" -eq 1001 ] \
    || fail "many receipts: the fixture did not exceed the old 1,000-row window: rows=$(wc -l < "$home/state/branch-outcomes.jsonl") host=$(cat "$home/host.out") report=$(cat "$home/engine-report.log") tail=$(tail -c 300 "$home/state/branch-outcomes.jsonl")"
  assert_re '^supervision-host: outcome 1 for demo \[routine\]: stub handled demo$' "$home/host.out" \
    "many receipts: the early visible outcome was lost behind later silent rows"
  assert_no_grep 'bulk silent fixture' "$home/host.out" "many receipts: silent outcomes were relayed"
  pass "host: an early visible outcome survives more than 1,000 same-turn receipts"
}

test_outcome_lookup_failure_is_not_treated_as_silence() {
  local home
  home=$(make_home away-lookup-failure away)
  echo return-lookup-fail > "$home/stub-mode"
  start_host "$home"
  wait_until 150 watcher_live "$home" || fail "lookup failure: the host never started a watcher cycle"
  append_status "$home" 'outcome lookup failure after a captain return'
  wait_until 2000 host_exited "$home" || fail "lookup failure: the host treated an unreadable store as a silent outcome"
  assert_re '^supervision-host: the captain returned while the away session was handling this wake, but the recorded outcomes could not be verified; main must review them$' \
    "$home/host.out" "lookup failure: the main handoff did not explain the lookup failure"
  assert_re '^supervision-host: outcome lookup failed for turn receipt rows 1; visible outcomes may require manual review$' \
    "$home/host.out" "lookup failure: the missing outcome warning was not emitted"
  pass "host: an outcome lookup failure forces a visible main handoff"
}

# The live failure this guards: a Cursor park superseded by the captain's
# return kills its host as the engine turn ends, so the host's own handoff is
# never printed. The outcome still reaches main: the next host's first cycle
# resurfaces the durable queue and main's drain presents it.
test_outcome_after_the_return_survives_a_host_killed_at_the_turn_end() {
  local home host rc drained
  home=$(make_home away-return-first away)
  echo return-first > "$home/stub-mode"
  start_host "$home"
  wait_until 150 watcher_live "$home" || fail "return-first: the host never started a watcher cycle"
  append_status "$home" 'finishing while the captain comes back'
  wait_until 250 grep -qs 'supervision-host-return:1' "$home/state/.wake-queue" \
    || fail "return-first: the late outcome was never queued: $(cat "$home/engine-report.log" 2>/dev/null)"
  host=$(awk -F '\t' '$1 == "host" { print $2 }' "$home/state/.supervision-host")
  kill -TERM "$host"
  wait_until 250 host_exited "$home" || fail "return-first: the stopped host did not exit"
  rc=$(cat "$home/host.rc")
  [ "$rc" -gt 128 ] || fail "fixture: the host was not stopped mid-turn (rc=$rc): $(cat "$home/host.out")"
  assert_no_re '^supervision-host: ' "$home/host.out" "fixture: the stopped host printed a handoff, so this case proves nothing"
  for f in "$home"/state/.supervision-host-result.* "$home"/state/.supervision-host-errors.*; do
    [ -e "$f" ] && fail "a host stopped mid-turn left its turn file behind: $f"
  done
  assert_grep 'supervision-host-return:1' "$home/state/.wake-queue" "the late outcome must stay queued after its host died"

  rm -f "$home/host.rc"
  start_host "$home"
  wait_until 250 host_exited "$home" || fail "return-first: the next host did not resurface the queued outcome"
  assert_re '^check: rearm-resurface$' "$home/host.out" "the next host's first cycle must resurface the queue"
  assert_re '	pass-through	attended	main-only	check: rearm-resurface' "$home/state/.supervision-host.log" "the attended resurface must reach main"
  drained=$(FM_HOME="$home" "$ROOT/bin/fm-wake-drain.sh" 2>&1)
  assert_contains "$drained" "supervision-host outcome 1 for demo [routine] was recorded after the captain returned" \
    "main's drain must present the outcome the killed host never handed off"
  pass "host: an outcome recorded after the return reaches main even when its host dies at the turn's end"
}

# A host killed outright mid-turn leaves turn files, but the bounded engine's
# watchdog stops the engine when its owner dies. The next host clears the files.
test_next_host_clears_a_turn_its_killed_predecessor_left() {
  local home host engine
  home=$(make_home away-killed-mid-turn away)
  echo return-first > "$home/stub-mode"
  start_host "$home"
  wait_until 150 watcher_live "$home" || fail "killed: the host never started a watcher cycle"
  append_status "$home" 'mid-turn when its host is killed'
  wait_until 250 grep -qs 'supervision-host-return:1' "$home/state/.wake-queue" || fail "killed: the turn never reported"
  host=$(awk -F '\t' '$1 == "host" { print $2 }' "$home/state/.supervision-host")
  engine=$(cut -f1 "$home/state/.supervision-host.engine-pid")
  kill -KILL "$host"
  wait_until 100 host_exited "$home" || fail "killed: the host did not die"
  ls "$home"/state/.supervision-host-result.* >/dev/null 2>&1 || fail "fixture: the killed turn left no result file, so this case proves nothing"
  wait_until 100 sh -c '! kill -0 "$1" 2>/dev/null' _ "$engine" || fail "the bounded engine survived its killed host"

  rm -f "$home/host.rc"
  start_host "$home"
  wait_until 250 host_exited "$home" || fail "killed: the next host did not resurface the queued outcome"
  ! kill -0 "$engine" 2>/dev/null || fail "the next host revived its killed predecessor's engine"
  for f in "$home"/state/.supervision-host-result.* "$home"/state/.supervision-host-errors.* \
    "$home"/state/.supervision-host-descendants.* "$home/state/.supervision-host-turn"; do
    [ -e "$f" ] && fail "the next host left its killed predecessor's turn file behind: $f"
  done
  assert_re '^check: rearm-resurface$' "$home/host.out" "the next host's first cycle must resurface the queue"
  pass "host: a killed predecessor's engine is reaped and the next host removes its turn files"
}

test_report_without_acknowledgement_hands_the_wake_to_main() {
  local home
  home=$(make_home away-noack away)
  echo noack > "$home/stub-mode"
  start_host "$home"
  wait_until 150 watcher_live "$home" || fail "noack: the host never started a watcher cycle"
  append_status "$home" 'reported, never acknowledged'
  wait_until 250 host_exited "$home" || fail "noack: the host counted an unacknowledged wake handled: $(cat "$home/state/.supervision-host.log")"
  expect_code 0 "$(cat "$home/host.rc")" "a handed-back wake must exit 0 for the owner to deliver"
  assert_grep '"task":"demo"' "$home/state/branch-outcomes.jsonl" "fixture: the stub did not report"
  assert_re '^signal: .*demo.status' "$home/host.out" "the handed-back close must carry the reason line"
  assert_re '^supervision-host: .*the engine turn left its granted wake rows [0-9]+( [0-9]+)* unacknowledged; this wake is yours$' "$home/host.out" \
    "the handback must name the rows the turn left unacknowledged"
  assert_grep 'demo.status' "$home/state/.wake-queue" "the unacknowledged wake must stay durable for main"
  assert_re '	failed	turn=.*	unacked=[0-9]' "$home/state/.supervision-host.log" "the ledger must record the turn as failed"
  assert_absent "$home/state/.supervision-host-engine" "a turn that did not handle its wake must not keep its conversation"
  watcher_live "$home" && fail "the host left its successor cycle running when it handed the wake to main"
  pass "host: a turn that reports but leaves its granted rows queued hands the wake to main"
}

test_return_during_a_failed_turn_still_hands_its_outcomes_to_main() {
  local home
  home=$(make_home away-return-fail away)
  echo return-fail > "$home/stub-mode"
  start_host "$home"
  wait_until 150 watcher_live "$home" || fail "return-fail: the host never started a watcher cycle"
  append_status "$home" 'mid-task, then a crash'
  wait_until 250 host_exited "$home" || fail "return-fail: the host did not hand the wake to main"
  expect_code 0 "$(cat "$home/host.rc")" "a failed turn's handback must exit 0 for the owner to deliver"
  assert_absent "$home/state/.afk-contract" "fixture: the stub's return did not archive the record"
  assert_re '^supervision-host: the away session could not take this wake: the engine turn failed \(exit 3\); .*captain returned during its turn.*store rows 1[,)]' "$home/host.out" \
    "the handback must say the turn failed, that the captain returned, and name the store rows"
  assert_re '^supervision-host: outcome 1 for demo \[routine\]: stub handled demo$' "$home/host.out" \
    "the handback must carry the failed turn's outcome for main to relay"
  assert_re '	failed	turn=' "$home/state/.supervision-host.log" "the turn itself failed"
  pass "host: a captain return during a failed engine turn still hands that turn's outcomes to main"
}

test_incomplete_engine_result_hands_the_wake_to_main() {
  local home
  home=$(make_home away-emptyresult away)
  echo emptyresult > "$home/stub-mode"
  start_host "$home"
  wait_until 150 watcher_live "$home" || fail "emptyresult: the host never started a watcher cycle"
  append_status "$home" 'handled, but the result is empty'
  wait_until 250 host_exited "$home" || fail "emptyresult: the host counted an empty result handled: $(cat "$home/state/.supervision-host.log")"
  expect_code 0 "$(cat "$home/host.rc")" "a handed-back wake must exit 0 for the owner to deliver"
  assert_grep '"task":"demo"' "$home/state/branch-outcomes.jsonl" "fixture: the stub did not report"
  assert_re '^signal: .*demo.status' "$home/host.out" "the handed-back close must carry the reason line"
  assert_re '^supervision-host: .*the engine turn ended with an error or an incomplete result; this wake is yours$' "$home/host.out" \
    "the handback must say the engine's result was incomplete"
  assert_re '	failed	turn=.*	error=1 ' "$home/state/.supervision-host.log" "the ledger must record the turn as failed"
  assert_no_re '	handled	turn=' "$home/state/.supervision-host.log" "an incomplete result must never count as handled"
  assert_absent "$home/state/.supervision-host-engine" "a turn that did not handle its wake must not keep its conversation"
  pass "host: an engine turn whose result is incomplete hands its wake to main"
}

test_engine_turn_is_bounded_and_its_descendants_reaped() {
  local home orphan
  home=$(make_home away-hang away)
  echo hang > "$home/stub-mode"
  FM_SUPERVISION_HOST_TURN_TIMEOUT=3 FM_SUPERVISION_ENGINE_GRACE=1 start_host "$home"
  wait_until 150 watcher_live "$home" || fail "hang: the host never started a watcher cycle"
  append_status "$home" 'slow one'
  wait_until 300 host_exited "$home" || fail "hang: the bounded turn did not end"
  assert_re '^supervision-host: .*the engine turn hit its 3s bound; this wake is yours$' "$home/host.out" "a bounded turn must hand its wake to main"
  orphan=$(cat "$home/orphan-pid")
  wait_until 50 sh -c '! kill -0 "$1" 2>/dev/null' _ "$orphan" \
    || fail "an engine tool process in its own process group outlived the turn: $(ps -p "$orphan" -o pid=,pgid=,command=)"
  pass "host: an engine turn is bounded, and tool processes outside its process group are reaped"
}

test_restarted_host_stops_what_a_killed_predecessor_left() {
  local home first_host arm watcher
  home=$(make_home away-crash away)
  start_host "$home"
  wait_until 150 watcher_live "$home" || fail "crash: the host never started a watcher cycle"
  first_host=$(awk -F '\t' '$1 == "host" { print $2 }' "$home/state/.supervision-host")
  arm=$(awk -F '\t' '$1 == "arm" { print $2 }' "$home/state/.supervision-host")
  watcher=$(cat "$home/state/.watch.lock/pid")
  kill -KILL "$first_host"
  sleep 1
  kill -0 "$arm" 2>/dev/null || fail "crash: fixture error: the arm died with its host, so this case proves nothing"
  start_host "$home"
  wait_until 200 sh -c '! kill -0 "$1" 2>/dev/null && ! kill -0 "$2" 2>/dev/null' _ "$arm" "$watcher" \
    || fail "a restarted host left its killed predecessor's arm or watcher running"
  wait_until 100 sh -c 'grep -q "	start	gen=host-" "$1" && [ "$(grep -c "	start	" "$1")" -ge 2 ]' _ "$home/state/.supervision-host.log" \
    || fail "the restarted host did not start"
  pass "host: a restarted host stops, by recorded identity, the cycle a killed predecessor left running"
}

# A Grok primary's seat, recorded the way bin/fm-lock.sh writes grok_profile,
# with a dummy login so the turn does not depend on this machine's real one.
arm_grok_seat() {  # <home> <seat-dir>
  local home=$1 seat=$2 lock_pid
  mkdir -p "$seat"
  printf '{}\n' > "$seat/auth.json"
  lock_pid=$(cat "$home/state/.lock")
  printf 'pid=%s\nharness=grok\nprofile=%s\ngrok_profile=%s\n' \
    "$lock_pid" "$home/seats/seat-a" "$seat" > "$home/state/.lock-runtime"
}

test_grok_away_wake_is_handled_and_resumed_on_its_own_contract() {
  local home seat first second session ghome saved
  home=$(make_home grok-away away grok)
  seat="$home/seats/grok"
  saved=$FM_SUPERVISION_HOST_PRIMARY
  FM_SUPERVISION_HOST_PRIMARY=grok start_host "$home"
  FM_SUPERVISION_HOST_PRIMARY=$saved
  wait_until 150 watcher_live "$home" || fail "grok away: the host never started a watcher cycle: $(cat "$home/host.out")"
  arm_grok_seat "$home" "$seat"
  append_status "$home" 'step one'
  wait_until 250 handled_at_least "$home" 1 \
    || fail "grok away: the wake was not handled: $(cat "$home/state/.supervision-host.log"; cat "$home/host.out")"
  first="$home/engine-call.1"
  assert_re '^actor=branch$' "$first" "the Grok engine must run as the branch actor"
  assert_re '^primary=grok$' "$first" "the Grok engine must carry the primary-harness pin"
  assert_re '^profile=$' "$first" "the Grok engine must not inherit the Claude seat"
  assert_re '^arg=--always-approve$' "$first" "the Grok engine must auto-approve tools"
  assert_re '^arg=--prompt-file$' "$first" "the Grok engine must take its prompt from a file"
  assert_re '^arg=--verbatim$' "$first" "the Grok engine must send the wake prompt verbatim"
  assert_re '^arg=grok-4\.7$' "$first" "the Grok engine must default to grok-4.7"
  assert_re '^arg=--session-id$' "$first" "the first Grok turn must open a new conversation"
  assert_re '^arg=--no-subagents$' "$first" "the Grok engine must not spawn subagents"
  assert_re '^arg=--disable-web-search$' "$first" "the Grok engine must not search the web"
  assert_no_re '^arg=--safe-mode$' "$first" "the Grok engine must not be launched with Claude's safe mode"
  assert_no_re '^arg=dontAsk$' "$first" "the Grok engine must not be launched with Claude's permission mode"
  assert_no_re '^arg=-p$' "$first" "the Grok engine must not take a positional prompt beside --prompt-file"
  assert_no_re '^arg=--trust$' "$first" "the Grok engine must not be told to trust the directory"
  ghome=$(sed -n 's/^grok_home=//p' "$first")
  [ "$ghome" = "$(cd "$home/state" && pwd -P)/.supervision-host-grok" ] \
    || fail "the Grok engine must launch from its private home under state, got: ${ghome:-empty}"
  [ ! -e "$ghome/hooks" ] || fail "the Grok engine home must not have a hooks directory"
  [ "$(readlink "$ghome/auth.json")" = "$seat/auth.json" ] \
    || fail "the Grok engine must link the seat login rather than copy it: $(readlink "$ghome/auth.json" 2>/dev/null)"
  assert_grep 'hooks = false' "$ghome/config.toml" "the Grok engine home must disable compat hooks"
  assert_grep "profile=$seat" "$home/state/.supervision-host-engine" \
    "the conversation must record the Grok seat, not the private home"
  [ ! -s "$home/host.rc" ] || fail "a handled Grok away wake reached main: $(cat "$home/host.out")"

  append_status "$home" 'step two'
  wait_until 250 handled_at_least "$home" 2 \
    || fail "grok away: the second wake was not handled: $(cat "$home/state/.supervision-host.log")"
  session=$(sed -n '/^arg=--session-id$/{n;s/^arg=//p;}' "$first")
  second="$home/engine-call.2"
  assert_re '^arg=--resume$' "$second" "a later Grok turn must resume the conversation"
  assert_re "^arg=$session\$" "$second" "a later Grok turn must resume the same conversation"
  assert_no_re '^arg=--session-id$' "$second" "a resumed Grok turn must not also open a session"
  assert_re '	handled	turn=[^	]*\.2	.* cost=0\.25 conversation_cost=0\.5 ' "$home/state/.supervision-host.log" \
    "a resumed Grok turn must add its own cost to the conversation"
  pass "host: a Grok away wake is handled and resumed on Grok's own headless contract"
}

test_grok_engine_without_a_recorded_seat_hands_the_wake_to_main() {
  local home lock_pid saved
  home=$(make_home grok-noseat away grok)
  saved=$FM_SUPERVISION_HOST_PRIMARY
  FM_SUPERVISION_HOST_PRIMARY=grok start_host "$home"
  FM_SUPERVISION_HOST_PRIMARY=$saved
  wait_until 150 watcher_live "$home" || fail "grok noseat: the host never started a watcher cycle"
  lock_pid=$(cat "$home/state/.lock")
  printf 'pid=%s\nharness=grok\nprofile=%s\n' "$lock_pid" "$home/seats/seat-a" > "$home/state/.lock-runtime"
  append_status "$home" 'needs a seat'
  wait_until 250 host_exited "$home" || fail "grok noseat: the host did not hand the wake to main: $(cat "$home/state/.supervision-host.log")"
  assert_grep 'no grok_profile' "$home/host.out" "the handback must name the missing Grok seat"
  [ "$(engine_calls "$home")" -eq 0 ] || fail "the Grok engine launched without a recorded seat"
  assert_grep 'demo.status' "$home/state/.wake-queue" "the unhandled wake must stay durable for main"
  pass "host: a Grok primary with no recorded seat hands the wake to main"
}

test_grok_engine_without_a_seat_login_does_not_launch() {
  local home seat saved lock_pid
  home=$(make_home grok-nologin away grok)
  seat="$home/seats/grok-empty"
  mkdir -p "$seat"
  saved=$FM_SUPERVISION_HOST_PRIMARY
  FM_SUPERVISION_HOST_PRIMARY=grok start_host "$home"
  FM_SUPERVISION_HOST_PRIMARY=$saved
  wait_until 150 watcher_live "$home" || fail "grok nologin: the host never started a watcher cycle"
  lock_pid=$(cat "$home/state/.lock")
  printf 'pid=%s\nharness=grok\nprofile=\ngrok_profile=%s\n' "$lock_pid" "$seat" > "$home/state/.lock-runtime"
  append_status "$home" 'needs a login'
  wait_until 250 host_exited "$home" \
    || fail "grok nologin: the host launched or hung: $(cat "$home/state/.supervision-host.log")"
  assert_grep 'no auth.json' "$home/state/.supervision-host.log" "the failed turn must name the missing login"
  assert_grep 'could not run' "$home/host.out" "the handback must say the engine could not run"
  [ "$(engine_calls "$home")" -eq 0 ] || fail "the Grok engine launched without a seat login"
  pass "host: a Grok seat with no login is not launched"
}

test_grok_result_adds_each_runs_cost_and_rejects_an_incomplete_one() {
  local home dir out rc
  home=$(make_home grok-result away grok)
  dir="$home/results"
  mkdir -p "$dir"
  printf '%s\n' '{"stopReason":"end_turn","sessionId":"s","num_turns":1,"total_cost_usd":0.25,"usage":{"input_tokens":5,"cache_read_input_tokens":100,"cache_creation_input_tokens":10,"output_tokens":20}}' > "$dir/run.json"
  printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"num_turns":3,"total_cost_usd":0.5,"usage":{"input_tokens":5,"cache_read_input_tokens":100,"cache_creation_input_tokens":10,"output_tokens":20}}' > "$dir/claude.json"
  printf '%s\n' '{}' > "$dir/empty.json"
  printf '%s\n' '{"stopReason":"cancelled","sessionId":"s","num_turns":1,"total_cost_usd":0.011,"usage":{"input_tokens":1,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"output_tokens":1}}' > "$dir/cancelled.json"
  printf '%s\n' '{"stopReason":"end_turn","sessionId":"s","num_turns":1,"usage":{"input_tokens":1,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"output_tokens":1}}' > "$dir/nocost.json"
  printf '%s\n' '{"stopReason":"end_turn","sessionId":"s","num_turns":1,"total_cost_usd":0.25,"usage_is_incomplete":true,"usage":{"input_tokens":5,"cache_read_input_tokens":100,"cache_creation_input_tokens":10,"output_tokens":20}}' > "$dir/partial.json"
  out=$(bash -c '
    . "$1"
    fm_supervision_engine_result grok "$2" 0
    fm_supervision_engine_result grok "$2" 0.25
    fm_supervision_engine_result grok "$3" 0 || true
    fm_supervision_engine_result grok "$4" 0
    fm_supervision_engine_result grok "$5" 0
    fm_supervision_engine_result grok "$6" 0
    fm_supervision_engine_result claude "$7" 0.25
  ' _ "$ROOT/bin/fm-supervision-engine-lib.sh" "$dir/run.json" "$dir/empty.json" \
    "$dir/cancelled.json" "$dir/nocost.json" "$dir/partial.json" "$dir/claude.json") || rc=$?
  [ "${rc:-0}" -eq 0 ] || fail "result: the parser did not run (rc=$rc): $out"
  printf '%s\n' "$out" | grep -qx 'error=0 cost=0.25 conversation_cost=0.25 input=5 cache_read=100 cache_write=10 output=20 turns=1' \
    || fail "result: a Grok run's own cost was not reported: $out"
  printf '%s\n' "$out" | grep -qx 'error=0 cost=0.25 conversation_cost=0.5 input=5 cache_read=100 cache_write=10 output=20 turns=1' \
    || fail "result: a resumed Grok run did not add its cost: $out"
  printf '%s\n' "$out" | grep -qx 'error=1 cost=unreported conversation_cost=unreported input=0 cache_read=0 cache_write=0 output=0 turns=0' \
    || fail "result: an empty Grok result invented a cost: $out"
  printf '%s\n' "$out" | grep -qx 'error=1 cost=0.011 conversation_cost=0.011 input=1 cache_read=0 cache_write=0 output=1 turns=1' \
    || fail "result: a cancelled Grok turn was treated as success or dropped its cost: $out"
  printf '%s\n' "$out" | grep -qx 'error=1 cost=unreported conversation_cost=unreported input=1 cache_read=0 cache_write=0 output=1 turns=1' \
    || fail "result: a Grok result with no cost became zero: $out"
  printf '%s\n' "$out" | grep -q 'error=1 cost=0.25 conversation_cost=0.25 input=5 cache_read=100 cache_write=10 output=20 turns=1' \
    || fail "result: an incomplete Grok usage was accepted: $out"
  printf '%s\n' "$out" | grep -qx 'error=0 cost=0.25 conversation_cost=0.5 input=5 cache_read=100 cache_write=10 output=20 turns=3' \
    || fail "result: Claude's running total was no longer subtracted: $out"
  pass "host: a Grok result adds each run's cost and rejects an incomplete one"
}

test_empty_supervision_host_file_on_a_grok_primary_selects_grok() {
  local home out
  home=$(make_home grok-default away '')
  out=$(bash -c '
    . "$1"
    fm_supervision_host_config "$2" grok || exit 1
    printf "engine=%s model=%s problem=%s\n" \
      "$FM_SUPERVISION_ENGINE" "$FM_SUPERVISION_ENGINE_MODEL" "$FM_SUPERVISION_ENGINE_PROBLEM"
    fm_supervision_host_config "$2" cursor || exit 1
    printf "cursor_problem=%s\n" "$FM_SUPERVISION_ENGINE_PROBLEM"
    printf "codex\n" > "$2/supervision-host"
    fm_supervision_host_config "$2" grok || exit 1
    printf "named=%s\n" "$FM_SUPERVISION_ENGINE_PROBLEM"
  ' _ "$ROOT/bin/fm-supervision-engine-lib.sh" "$home/config") || fail "select: config did not resolve: $out"
  printf '%s\n' "$out" | grep -qx 'engine=grok model=grok-4.7 problem=' \
    || fail "select: an empty file on a Grok primary did not select grok-4.7: $out"
  printf '%s\n' "$out" | grep -qx "cursor_problem=the primary harness 'cursor' has no verified supervision engine" \
    || fail "select: an empty file on Cursor gained an engine: $out"
  printf '%s\n' "$out" | grep -q "named=config/supervision-host names 'codex', which is not a verified supervision engine" \
    || fail "select: naming codex became verified: $out"
  pass "host: an empty file on a Grok primary selects grok, and Cursor and Codex stay unverified"
}

test_grok_turn_refuses_a_missing_login_and_launches_an_ambient_one() {
  local home work rc call ghome
  home=$(make_home grok-direct away grok)
  work="$home/direct"
  mkdir -p "$work/empty-home/.grok" "$work/login-home/.grok" "$work/prompt"
  printf 'wake\n' > "$work/prompt/wake.txt"
  printf 'branch prompt for the direct turn\n' > "$work/prompt/prompt.txt"
  printf '{}\n' > "$work/login-home/.grok/auth.json"
  echo fail > "$home/stub-mode"
  rc=$(HOME="$work/empty-home" FM_HOME="$home" FM_ROOT="$ROOT" STATE="$home/state" \
    CLAUDE_CONFIG_DIR="$home/seats/seat-a" bash -c '
      . "$1/bin/fm-wake-lib.sh"
      . "$1/bin/fm-timeout-lib.sh"
      . "$1/bin/fm-supervision-engine-lib.sh"
      fm_supervision_engine_turn grok grok-4.7 "$2" "$3" \
        11111111-1111-1111-1111-111111111111 new 30 "$4/out" "$4/err" ""
      printf "%s\n" "$?"
    ' _ "$ROOT" "$work/prompt/prompt.txt" "$work/prompt/wake.txt" "$work")
  [ "$rc" = 127 ] || fail "direct: a missing ambient login must not launch (rc=$rc): $(cat "$work/err" 2>/dev/null)"
  assert_grep 'no auth.json' "$work/err" "direct: the refusal must name the missing login"
  [ "$(engine_calls "$home")" -eq 0 ] || fail "direct: the engine launched without a login"

  rc=$(HOME="$work/login-home" FM_HOME="$home" FM_ROOT="$ROOT" STATE="$home/state" \
    FM_SUPERVISION_ACTOR=branch CLAUDE_CONFIG_DIR="$home/seats/seat-a" bash -c '
      . "$1/bin/fm-wake-lib.sh"
      . "$1/bin/fm-timeout-lib.sh"
      . "$1/bin/fm-supervision-engine-lib.sh"
      fm_supervision_engine_turn grok grok-4.7 "$2" "$3" \
        11111111-1111-1111-1111-111111111111 new 30 "$4/out" "$4/err" ""
      printf "%s\n" "$?"
    ' _ "$ROOT" "$work/prompt/prompt.txt" "$work/prompt/wake.txt" "$work")
  [ "$rc" = 3 ] || fail "direct: the ambient login did not reach the stub (rc=$rc): $(cat "$work/err" 2>/dev/null)"
  call="$home/engine-call.1"
  assert_re '^actor=branch$' "$call" "direct: the launch must keep the branch actor"
  assert_re '^profile=$' "$call" "direct: the launch must clear the inherited Claude seat"
  assert_re '^arg=--always-approve$' "$call" "direct: the launch must auto-approve"
  assert_re '^arg=--prompt-file$' "$call" "direct: the launch must use the prompt file"
  ghome=$(sed -n 's/^grok_home=//p' "$call")
  [ "$(readlink "$ghome/auth.json")" = "$work/login-home/.grok/auth.json" ] \
    || fail "direct: the private home must link the ambient login: $(readlink "$ghome/auth.json" 2>/dev/null)"
  [ ! -e "$ghome/hooks" ] || fail "direct: the private home grew a hooks directory"
  pass "host: a Grok turn refuses a missing login and launches an ambient one"
}

# FM_TEST_ONLY runs a single named case, the same entry point the sibling
# suites expose.
if [ -n "${FM_TEST_ONLY:-}" ]; then
  "$FM_TEST_ONLY"
  exit 0
fi

test_away_wake_is_handled_on_the_engine_and_never_reaches_main
test_away_turn_without_a_report_hands_the_wake_to_main
test_lead_seat_move_moves_the_next_engine_launch
test_codex_lead_retains_a_separate_claude_engine_seat
test_ambient_default_lead_seat_clears_the_hosts_inherited_seat
test_unreadable_lead_seat_record_hands_the_wake_to_main
test_departed_leads_seat_record_is_never_spent
test_return_during_an_engine_turn_hands_its_outcomes_to_main
test_silent_outcomes_are_not_relayed_when_the_captain_returns
test_large_turn_relays_an_early_visible_outcome
test_outcome_lookup_failure_is_not_treated_as_silence
test_outcome_after_the_return_survives_a_host_killed_at_the_turn_end
test_next_host_clears_a_turn_its_killed_predecessor_left
test_report_without_acknowledgement_hands_the_wake_to_main
test_return_during_a_failed_turn_still_hands_its_outcomes_to_main
test_incomplete_engine_result_hands_the_wake_to_main
test_engine_turn_is_bounded_and_its_descendants_reaped
test_restarted_host_stops_what_a_killed_predecessor_left
test_grok_away_wake_is_handled_and_resumed_on_its_own_contract
test_grok_engine_without_a_recorded_seat_hands_the_wake_to_main
test_grok_engine_without_a_seat_login_does_not_launch
test_grok_result_adds_each_runs_cost_and_rejects_an_incomplete_one
test_empty_supervision_host_file_on_a_grok_primary_selects_grok
test_grok_turn_refuses_a_missing_login_and_launches_an_ambient_one
