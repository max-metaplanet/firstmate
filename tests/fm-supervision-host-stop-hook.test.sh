#!/usr/bin/env bash
# tests/fm-supervision-host-stop-hook.test.sh - the Claude re-arm owner around
# the supervision host: the Stop hook that runs it, the handoff and downtime
# restore a closed successor needs, the cycle a pass-through leaves for the
# next park, and the attended dialog mirror.
#
# Fixtures, the stub engine, and the shared assertions live in
# tests/supervision-host-helpers.sh, whose header names the sibling suites
# that carry the rest of these cases.
# shellcheck disable=SC2016 # single-quoted scripts expand inside their own shells
set -u

# shellcheck source=tests/supervision-host-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/supervision-host-helpers.sh"

# The live failure (2026-09-27): a main-only pass-through confirmed a handling
# handoff before the close reached main's re-arm owner, so the Stop hook's
# rewake commit refused and it exited 0 in silence. An idle primary was never
# woken, and the detached successor's own later close reached no reader.
test_claude_stop_hook_delivers_a_main_only_pass_through() {
  local home
  home=$(make_primary_home hook-main-only)
  start_hook_session "$home"
  turn_end "$home"
  wait_until 150 watcher_live "$home" || fail "hook main-only: the Stop hook never started a watcher cycle: $(cat "$home/hook.err" 2>/dev/null)"
  append_status "$home" 'which export format?' needs-decision
  wait_until 250 hook_exited "$home" || fail "hook main-only: the Stop hook never closed: $(cat "$home/state/.supervision-host.log")"
  assert_re '	pass-through	attended	main-only	signal:' "$home/state/.supervision-host.log" "fixture: the close was not a main-only pass-through"
  assert_rewoke_main "$home" "hook main-only"
  assert_re '^signal: .*demo.status' "$home/hook.err" "the rewake must carry the close"
  watcher_live "$home" || fail "hook main-only: the pass-through left no successor watcher"
  pass "host+hook: an attended main-only pass-through rewakes main and keeps its successor watcher"
}

# Close the confirmed handling watcher after the engine has acknowledged its
# wake but before its captain outcome returns to the host.
test_claude_stop_hook_restores_handoff_when_successor_closed_before_exit_to_main() {
  local home
  home=$(make_primary_home hook-successor-closed-before-return)
  ln -s "$ROOT/.agents" "$home/.agents"
  echo captain-close-before-return > "$home/stub-mode"
  start_hook_session "$home"
  turn_end "$home"
  wait_until 150 watcher_live "$home" || fail "closed successor: the Stop hook never started a watcher cycle"
  append_status "$home" 'first actionable wake'
  wait_until 250 hook_exited "$home" || fail "closed successor: the Stop hook did not finish: $(cat "$home/state/.supervision-host.log")"
  assert_re '^supervision-host: branch-outcome: ' "$home/hook.err" "the host must hand its captain outcome to main"
  expect_code 2 "$(cat "$home/hook.rc")" "the Stop hook must rewake main after the successor closed"
  assert_re '^(pending|announced):downtime:' "$home/state/.watcher-down" \
    "the closed handling successor must leave a deliverable downtime episode"
  pass "host+hook: a successor closed before exit_to_main does not suppress the branch-outcome rewake"
}

test_claude_stop_hook_notifies_when_closed_successor_downtime_restore_fails() {
  assert_claude_stop_hook_notifies_when_closed_successor_downtime_restore_fails pending
  pass "host+hook: a refused hand-back becomes a delivered failure notice"
}

test_claude_stop_hook_notifies_when_closed_announced_successor_downtime_restore_fails() {
  assert_claude_stop_hook_notifies_when_closed_successor_downtime_restore_fails announced
  pass "host+hook: a refused hand-back on an announced handling marker becomes a delivered failure notice"
}

test_claude_stop_hook_restores_handoff_when_successor_closed_mid_engine_turn() {
  local home successor
  home=$(make_primary_home hook-successor-closed-before-outcome)
  ln -s "$ROOT/.agents" "$home/.agents"
  echo captain-held > "$home/stub-mode"
  mkfifo "$home/stub-release"
  start_hook_session "$home"
  turn_end "$home"
  wait_until 150 watcher_live "$home" || fail "closed successor: the Stop hook never started a watcher cycle"
  append_status "$home" 'first actionable wake'
  wait_until 250 test -s "$home/stub-ready" || fail "closed successor: the engine did not reach its hold: hook=$(cat "$home/hook.err" 2>/dev/null) host=$(cat "$home/state/.supervision-host.log" 2>/dev/null) mode=$(cat "$home/stub-mode" 2>/dev/null) engine=$(find "$home" -maxdepth 1 -name 'engine-call.*' -exec sh -c 'cat "$1"' _ {} \; 2>/dev/null) errors=$(cat "$home"/engine-errors.* 2>/dev/null)"
  successor=$(cat "$home/state/.watch.lock/pid")
  append_status "$home" 'wake while the engine is handling'
  wait_until 250 bash -c '! kill -0 "$1" 2>/dev/null' _ "$successor" \
    || fail "closed successor: its watcher did not close during the engine turn"
  FM_HOME="$home" bash -c '. "$1"; fm_recovery_marker_begin_handling "$2"' _ \
    "$ROOT/bin/fm-wake-lib.sh" "$home/state/.watcher-down" \
    || fail "fixture: could not model the queued successor wake entering handling"
  assert_re '^pending:handling:' "$home/state/.watcher-down" \
    "fixture: the closed handling successor must leave the marker in handling before the host hands back"
  printf 'continue\n' > "$home/stub-release"
  wait_until 250 hook_exited "$home" || fail "closed successor: the Stop hook did not finish: $(cat "$home/state/.supervision-host.log")"
  assert_re '^supervision-host: branch-outcome: ' "$home/hook.err" "the host must hand its captain outcome to main"
  expect_code 2 "$(cat "$home/hook.rc")" "the Stop hook must rewake main after the successor closed"
  assert_re '^epoch=[0-9]+ owner_pid=[0-9]+ outcome=rewake ' "$home/state/.claude-autoarm-epoch" \
    "the hand-back must commit the rewake"
  assert_re '^(pending|announced):downtime:' "$home/state/.watcher-down" \
    "the closed handling successor must leave a deliverable downtime episode"
  pass "host+hook: a successor that closes during a held engine turn does not suppress the branch-outcome rewake"
}

# The live repro (2026-09-28): a quiet record live with no daemon flag parked a
# present Claude captain, whose worker's captain outcomes waited for a return.
# Through the real Stop hook the outcome now rewakes main, with no away note.
test_claude_stop_hook_rewakes_a_present_captain_beside_a_quiet_record() {
  local home drained
  home=$(make_primary_home hook-quiet-record)
  # This case runs an engine turn from the primary root, whose prompt reads the skills.
  ln -s "$ROOT/.agents" "$home/.agents"
  FM_HOME="$home" FM_AFK_MODE=quiet "$CONTRACT" enter --words 'keep routine wakes off my main' >/dev/null 2>&1 \
    || fail "fixture: could not record quiet mode"
  echo captain > "$home/stub-mode"
  start_hook_session "$home"
  turn_end "$home"
  wait_until 150 watcher_live "$home" || fail "hook quiet: the Stop hook never started a watcher cycle: $(cat "$home/hook.err" 2>/dev/null)"
  append_status "$home" 'ready for review'
  wait_until 250 hook_exited "$home" || fail "hook quiet: the Stop hook never closed: $(cat "$home/state/.supervision-host.log")"
  assert_re '	handled	turn=[^	]*	posture=attended	' "$home/state/.supervision-host.log" "a quiet record must leave the host's turn attended"
  assert_rewoke_main "$home" "hook quiet"
  assert_re '^supervision-host: branch-outcome: ' "$home/hook.err" "the rewake must carry the captain outcome"
  assert_no_grep 'not a return' "$home/hook.err" "a present captain's rewake must not call itself away-posture supervision"
  drained=$(main_drain "$home")
  assert_contains "$drained" " ago] demo: stub escalated: " "main's drain must present the captain outcome beside a quiet record"
  pass "host+hook: a captain outcome beside a quiet record rewakes the present captain with no away note"
}

# Default-on for Claude (docs/configuration.md "Supervision host"): through the
# real Stop hook and mirror writer, a Claude primary home with no
# config/supervision-host runs the host at the default engine, mirrors the
# captain's dialog, and keeps a routine attended wake off main; a home with
# config/supervision-host-off runs the plain watcher arm, mirrors nothing, and every wake
# reaches main as the arm printed it.
test_claude_stop_hook_runs_the_host_without_the_file_and_off_opts_out() {
  local home first
  home=$(make_primary_home hook-default-on)
  ln -s "$ROOT/.agents" "$home/.agents"
  rm -f "$home/config/supervision-host"
  start_hook_session "$home"
  turn_end "$home"
  wait_until 150 watcher_live "$home" || fail "default-on: the Stop hook never started a watcher cycle: $(cat "$home/hook.err" 2>/dev/null)"
  assert_grep 'watch the fleet for me' "$home/state/.host-mirror.jsonl" "a Claude home without the file must mirror the captain's dialog"
  append_status "$home" 'step one'
  wait_until 250 handled_at_least "$home" 1 \
    || fail "default-on: the wake was not handled on the engine: $(cat "$home/hook.err" 2>/dev/null; cat "$home/state/.supervision-host.log" 2>/dev/null)"
  first="$home/engine-call.1"
  assert_re '^arg=sonnet$' "$first" "a Claude home without the file must run the Claude engine at its default model"
  assert_re '^primary=claude$' "$first" "the engine must carry the Claude primary pin"
  assert_re '	handled	turn=[^	]*	posture=attended	' "$home/state/.supervision-host.log" "the ledger must record the attended turn"
  [ ! -s "$home/hook.rc" ] || fail "a routine attended wake on a Claude home without the file reached main: $(cat "$home/hook.err")"
  watcher_live "$home" || fail "default-on: the host is not parked on a live successor"
  : > "$home/session.stop"
  stop_home_processes "$home"

  home=$(make_primary_home hook-opted-out)
  : > "$home/config/supervision-host-off"
  start_hook_session "$home"
  turn_end "$home"
  wait_until 150 watcher_live "$home" || fail "off: the Stop hook never started a watcher cycle: $(cat "$home/hook.err" 2>/dev/null)"
  append_status "$home" 'step one'
  wait_until 250 hook_exited "$home" || fail "off: the Stop hook never closed"
  assert_rewoke_main "$home" "off"
  assert_re '^signal: .*demo.status' "$home/hook.err" "off: the rewake must carry the arm's close"
  assert_no_re '^supervision-host' "$home/hook.err" "off: the close must reach main exactly as the arm printed it"
  assert_absent "$home/state/.supervision-host.log" "a home opted out by config/supervision-host-off must never run the host"
  assert_absent "$home/state/.host-mirror.jsonl" "a home opted out by config/supervision-host-off must mirror nothing"
  [ "$(engine_calls "$home")" -eq 0 ] || fail "a home opted out by config/supervision-host-off ran an engine turn"
  : > "$home/session.stop"
  stop_home_processes "$home"
  pass "host+hook: a Claude home without config/supervision-host runs the host at the default engine, and an off file restores the plain arm"
}

test_claude_stop_hook_delivers_a_close_that_turns_main_only_at_its_turn() {
  local home
  home=$(make_primary_home hook-turns-main-only)
  turn_main_only_at_second_offer "$home"
  start_hook_session "$home"
  turn_end "$home"
  wait_until 150 watcher_live "$home" || fail "hook turns-main-only: the Stop hook never started a watcher cycle: $(cat "$home/hook.err" 2>/dev/null)"
  append_status "$home" 'step one'
  wait_until 250 hook_exited "$home" || fail "hook turns-main-only: the Stop hook never closed: $(cat "$home/state/.supervision-host.log")"
  [ "$(cat "$home/offer-count" 2>/dev/null)" -ge 2 ] || fail "fixture: the close was not accepted before it turned main-only"
  [ "$(engine_calls "$home")" -eq 0 ] || fail "hook turns-main-only: the engine ran on a stale offer"
  assert_rewoke_main "$home" "hook turns-main-only"
  watcher_live "$home" || fail "hook turns-main-only: the pass-through left no successor watcher"
  pass "host+hook: a close that turns main-only at its turn rewakes main and keeps its successor watcher"
}

# The successor a close that turns main-only at its turn leaves for main
# outlives the Stop hook's process group teardown, like the pass-through's.
test_successor_left_at_the_turn_survives_the_hook_process_group_teardown() {
  local home watcher
  home=$(make_primary_home hook-turns-main-only-teardown)
  turn_main_only_at_second_offer "$home" quiet
  : > "$home/hook.own-group"
  start_hook_session "$home"
  turn_end "$home"
  wait_until 150 watcher_live "$home" || fail "at-turn teardown: the Stop hook never started a watcher cycle: $(cat "$home/hook.err" 2>/dev/null)"
  append_status "$home" 'step one'
  wait_until 250 hook_exited "$home" || fail "at-turn teardown: the Stop hook never closed: $(cat "$home/state/.supervision-host.log")"
  [ "$(cat "$home/offer-count" 2>/dev/null)" -ge 2 ] || fail "fixture: the close was not accepted before it turned main-only"
  assert_rewoke_main "$home" "at-turn teardown"
  watcher=$(cat "$home/state/.watch.lock/pid")
  kill -TERM -- "-$(cat "$home/hook.pgid")" 2>/dev/null || true
  sleep 2
  kill -0 "$watcher" 2>/dev/null || fail "at-turn teardown: the successor watcher (pid $watcher) did not survive the hook's process group teardown"
  stop_home_processes "$home"
  pass "host+hook: the successor a close that turns main-only at its turn leaves for main survives the hook's process group teardown"
}

# If the at-turn hand-back cannot publish downtime, the healthy successor
# cannot turn that undelivered close into a silent Stop-hook success.
test_claude_stop_hook_notifies_when_at_turn_downtime_write_fails() {
  local home real_mktemp
  home=$(make_primary_home hook-turns-main-only-write-fails)
  turn_main_only_at_second_offer "$home"
  real_mktemp=$(command -v mktemp)
  cat > "$home/fakebin/mktemp" <<SH
#!/usr/bin/env bash
case "\$*" in
  *'/state/.watcher-down.tmp.'*)
    [ "\$(cat "\$FM_HOME/offer-count" 2>/dev/null)" != 2 ] || exit 1 ;;
esac
exec "$real_mktemp" "\$@"
SH
  chmod +x "$home/fakebin/mktemp"
  start_hook_session "$home"
  turn_end "$home"
  wait_until 150 watcher_live "$home" || fail "hook write failure: no watcher started"
  append_status "$home" 'step one'
  wait_until 250 hook_exited "$home" || fail "hook write failure: the Stop hook did not finish"
  [ "$(cat "$home/offer-count" 2>/dev/null)" -ge 2 ] || fail "fixture: the close did not turn main-only at its turn"
  assert_re 'pass-through[[:space:]]+downtime-unrestored' "$home/state/.supervision-host.log" "fixture: downtime publication did not fail"
  assert_re '^(pending|announced):handling:' "$home/state/.watcher-down" "fixture: the marker unexpectedly became downtime"
  expect_code 2 "$(cat "$home/hook.rc")" "the Stop hook must notify main instead of dropping the close"
  assert_grep 'firstmate watcher auto-arm FAILED' "$home/hook.err" "main must receive the failure notification"
  assert_re 'outcome=failed ' "$home/state/.claude-autoarm-epoch" "the failure must be committed"
  pass "host+hook: failed at-turn downtime write notifies main despite a healthy successor"
}

# The successor a pass-through leaves closes while main's rewoken turn is still
# running, so no arm is attached to read it: the next turn end must still
# deliver that close instead of stranding it in the queue.
test_successor_close_during_main_turn_is_delivered_at_the_next_turn_end() {
  local home successor drained
  home=$(make_primary_home hook-successor-close)
  start_hook_session "$home"
  turn_end "$home"
  wait_until 150 watcher_live "$home" || fail "successor close: the Stop hook never started a watcher cycle: $(cat "$home/hook.err" 2>/dev/null)"
  append_status "$home" 'which export format?' needs-decision
  wait_until 250 hook_exited "$home" || fail "successor close: the first close never reached the Stop hook: $(cat "$home/state/.supervision-host.log")"
  assert_rewoke_main "$home" "successor close (first)"
  successor=$(cat "$home/state/.watch.lock/pid")
  main_drain "$home" >/dev/null
  append_status "$home" 'which region?' needs-decision
  wait_until 250 bash -c '! kill -0 "$1" 2>/dev/null' _ "$successor" || fail "fixture: the successor did not close on the later decision"
  # shellcheck disable=SC2086 # the printed acknowledgement arguments
  [ -z "$MAIN_ACK" ] || FM_HOME="$home" "$FAKE_CLAUDE" -c '"$0" "$@" >/dev/null 2>&1' "$ROOT/bin/fm-wake-drain.sh" $MAIN_ACK \
    || fail "successor close: main's acknowledgement failed: $MAIN_ACK"
  turn_end "$home"
  wait_until 250 hook_exited "$home" || fail "successor close: the next turn end never closed: $(cat "$home/state/.supervision-host.log")"
  assert_rewoke_main "$home" "successor close (next turn end)"
  drained=$(main_drain "$home")
  assert_contains "$drained" 'which region?' "the successor's close must reach main's drain"
  watcher_live "$home" || fail "successor close: the next turn end left no watcher"
  pass "host+hook: a successor close that lands during main's turn is delivered at the next turn end"
}

# The live loop (2026-10-07): the successor a main-only pass-through leaves
# for main shared the Stop hook's process group, so Claude's teardown of that
# group after the exit-2 rewake stopped it mid-turn. The stop published
# downtime, and the next park's first cycle announced an empty
# "check: rearm-resurface" that woke main again, over and over. The successor
# must outlive that teardown, so the next park takes it over quietly.
test_pass_through_successor_survives_the_hook_process_group_teardown() {
  local home pgid watcher
  home=$(make_primary_home hook-group-teardown)
  : > "$home/hook.own-group"
  start_hook_session "$home"
  turn_end "$home"
  wait_until 150 watcher_live "$home" || fail "group teardown: the Stop hook never started a watcher cycle: $(cat "$home/hook.err" 2>/dev/null)"
  append_status "$home" 'which export format?' needs-decision
  wait_until 250 hook_exited "$home" || fail "group teardown: the decision close never reached the Stop hook: $(cat "$home/state/.supervision-host.log")"
  assert_re '	pass-through	attended	main-only	signal:' "$home/state/.supervision-host.log" "fixture: the close was not a main-only pass-through"
  assert_rewoke_main "$home" "group teardown (pass-through)"
  watcher=$(cat "$home/state/.watch.lock/pid")
  pgid=$(cat "$home/hook.pgid")
  kill -TERM -- "-$pgid" 2>/dev/null || true
  sleep 2
  kill -0 "$watcher" 2>/dev/null || fail "group teardown: the successor watcher (pid $watcher) did not survive the hook's process group teardown"
  [ "$(cat "$home/state/.watch.lock/pid" 2>/dev/null)" = "$watcher" ] || fail "group teardown: the watcher lock moved"
  stop_home_processes "$home"
  pass "host+hook: the successor a pass-through leaves for main survives the hook's process group teardown"
}

test_next_park_takes_over_the_cycle_a_pass_through_left_for_main() {
  local home left_watcher left_arm
  home=$(make_primary_home hook-takeover)
  leave_a_cycle_for_main_and_restart "$home"
  left_watcher=$LEFT_WATCHER
  left_arm=$LEFT_ARM
  turn_end "$home"
  wait_until 150 host_owns_the_only_cycle "$home" \
    || fail "takeover: the next park did not own the home's only watcher cycle (left arm $left_arm, watcher $left_watcher):"$'\n'"$(home_arms "$home")"$'\n'"$(cat "$home/state/.supervision-host.log")"
  ! kill -0 "$left_arm" 2>/dev/null || fail "takeover: the successor arm a pass-through left still runs (pid $left_arm)"
  ! kill -0 "$left_watcher" 2>/dev/null || fail "takeover: the successor watcher still runs (pid $left_watcher)"
  sleep 2
  ! hook_exited "$home" || fail "takeover: the takeover woke main: $(cat "$home/hook.err")"
  host_owns_the_only_cycle "$home" || fail "takeover: the park did not keep the cycle it took over"
  assert_re '^acked:' "$home/state/.watcher-down" "takeover: the takeover opened a downtime episode"
  assert_no_re 'rearm-resurface' "$home/state/.supervision-host.log" "takeover: the takeover resurfaced a recovery to main"
  append_status "$home" 'which region?' needs-decision
  wait_until 250 hook_exited "$home" || fail "takeover: the owned cycle did not deliver the next close: $(cat "$home/state/.supervision-host.log")"
  assert_rewoke_main "$home" "takeover (next close)"
  assert_re '^signal: .*demo.status' "$home/hook.err" "takeover: the next close must carry the watcher's reason line"
  pass "host+hook: the next park takes over the cycle a main-only pass-through left, so one arm owns it"
}

# A park stopped before its take-over stops the left cycle (here held in the
# take-over's handover snapshot by the recovery-marker lock) must not forget
# that cycle's arm: the park the Stop hook runs next still takes it over rather
# than attaching to it beside the orphan.
test_a_park_stopped_mid_take_over_leaves_the_take_over_to_the_next_park() {
  local home holder host
  home=$(make_primary_home hook-takeover-interrupted)
  leave_a_cycle_for_main_and_restart "$home"
  FM_STATE_OVERRIDE="$home/state" bash -c '
    . "$1"
    fm_lock_acquire_wait "$2" || exit 1
    : > "$3"
    while [ ! -e "$4" ]; do sleep 0.1; done
    fm_lock_release "$2"
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$home/state/.watcher-down.lock" "$home/marker-lock-held" "$home/marker-lock-release" &
  holder=$!
  wait_until 100 test -e "$home/marker-lock-held" || fail "fixture: could not hold the recovery-marker lock"
  turn_end "$home"
  wait_until 150 grep -q "	take-over	arm=$LEFT_ARM\$" "$home/state/.supervision-host.log" \
    || fail "interrupted takeover: the park did not start a take-over of $LEFT_ARM: $(cat "$home/state/.supervision-host.log")"
  host=$(awk -F '\t' '$1 == "host" { print $2; exit }' "$home/state/.supervision-host")
  sleep 1
  kill -0 "$LEFT_WATCHER" 2>/dev/null || fail "fixture: the take-over stopped the left watcher before the park was stopped"
  kill -TERM "$host" 2>/dev/null || fail "fixture: the park host $host was not running"
  wait_until 150 sh -c '! kill -0 "$1" 2>/dev/null' _ "$host" || fail "fixture: the park host did not stop"
  : > "$home/marker-lock-release"
  wait "$holder" 2>/dev/null || true
  # The Stop hook runs the next park in place of the one stopped by a signal.
  wait_until 150 host_owns_the_only_cycle "$home" \
    || fail "interrupted takeover: the next park did not own the home's only watcher cycle (left arm $LEFT_ARM):"$'\n'"$(home_arms "$home")"$'\n'"$(cat "$home/state/.supervision-host.log")"
  ! kill -0 "$LEFT_ARM" 2>/dev/null || fail "interrupted takeover: the left arm still runs (pid $LEFT_ARM)"
  pass "host+hook: a park stopped mid take-over leaves the take-over to the next park"
}

# A successor the host cannot record for the next park's take-over (here the
# record path is a directory the record would land inside) must not be left
# running: the host stops it on exit, the close still reaches main unchanged,
# and main's next turn end owns a fresh cycle with no orphan beside it.
test_unrecorded_successor_is_stopped_rather_than_left_for_main() {
  local home
  home=$(make_primary_home hook-successor-unrecorded)
  mkdir "$home/state/.supervision-host-left"
  start_hook_session "$home"
  turn_end "$home"
  wait_until 150 watcher_live "$home" || fail "unrecorded successor: the Stop hook never started a watcher cycle: $(cat "$home/hook.err" 2>/dev/null)"
  append_status "$home" 'which export format?' needs-decision
  wait_until 250 hook_exited "$home" || fail "unrecorded successor: the decision close never reached the Stop hook: $(cat "$home/state/.supervision-host.log")"
  assert_re '	pass-through	attended	main-only	signal:' "$home/state/.supervision-host.log" "fixture: the close was not a main-only pass-through"
  assert_re '	pass-through	successor-unrecorded	signal:' "$home/state/.supervision-host.log" "unrecorded successor: the failed record was not logged"
  assert_rewoke_main "$home" "unrecorded successor (pass-through)"
  assert_re '^signal: .*demo.status' "$home/hook.err" "unrecorded successor: the close must carry the watcher's reason line"
  wait_until 100 no_home_arms "$home" || fail "unrecorded successor: an arm outlived the host:"$'\n'"$(home_arms "$home")"
  rmdir "$home/state/.supervision-host-left" \
    || fail "unrecorded successor: the record left inside the directory was not removed: $(ls -A "$home/state/.supervision-host-left")"
  main_drain "$home" >/dev/null
  # shellcheck disable=SC2086 # the printed acknowledgement arguments
  [ -z "$MAIN_ACK" ] || FM_HOME="$home" "$FAKE_CLAUDE" -c '"$0" "$@" >/dev/null 2>&1' "$ROOT/bin/fm-wake-drain.sh" $MAIN_ACK \
    || fail "unrecorded successor: main's acknowledgement failed: $MAIN_ACK"
  turn_end "$home"
  wait_until 150 host_owns_the_only_cycle "$home" \
    || fail "unrecorded successor: main's next turn end did not own the home's only watcher cycle:"$'\n'"$(home_arms "$home")"$'\n'"$(cat "$home/state/.supervision-host.log")"
  pass "host+hook: a successor that cannot be recorded is stopped, and main's next turn end arms a fresh cycle"
}

# The captain returns after the loop accepted a decision close away but before
# its turn starts: the turn meets the attended rule, so the close still reaches
# main exactly as the arm printed it instead of being scoped to nothing.
test_close_accepted_away_that_turns_attended_passes_to_main() {
  local home real_mktemp
  home=$(make_home away-then-attended away)
  printf '{"hook_event_name":"UserPromptSubmit","prompt_id":"p0","prompt":"watch the fleet for me"}' > "$home/mirror-seed.0"
  real_mktemp=$(command -v mktemp)
  # Starting the successor arm is the first step after the loop's away check;
  # once the decision line is queued, the captain returns there.
  cat > "$home/fakebin/mktemp" <<SH
#!/usr/bin/env bash
case "\$*" in
  *.supervision-host-arm.*)
    ! grep -q 'which export format?' "\$FM_HOME/state/demo.status" 2>/dev/null \
      || "\$FM_REPO/bin/fm-afk-contract.sh" archive >> "\$FM_HOME/engine-return.log" 2>&1 ;;
esac
exec "$real_mktemp" "\$@"
SH
  chmod +x "$home/fakebin/mktemp"
  start_host "$home"
  wait_until 150 watcher_live "$home" || fail "away-then-attended: the host never started a watcher cycle"
  append_status "$home" 'which export format?' needs-decision
  wait_until 250 host_exited "$home" || fail "away-then-attended: the decision close did not reach main: $(cat "$home/state/.supervision-host.log")"
  assert_absent "$home/state/.afk-contract" "fixture: the captain did not return before the turn"
  expect_code 0 "$(cat "$home/host.rc")" "the close must exit 0"
  assert_re '^signal: .*demo.status' "$home/host.out" "the close must carry the watcher's reason line"
  assert_no_re '^supervision-host' "$home/host.out" "the close must reach main exactly as the arm printed it"
  [ "$(engine_calls "$home")" -eq 0 ] || fail "away-then-attended: the engine ran for a decision close"
  assert_grep 'demo.status' "$home/state/.wake-queue" "the decision wake must stay queued for main"
  assert_re '	pass-through	attended	main-only	signal:' "$home/state/.supervision-host.log" "the ledger must record why the close went to main"
  assert_no_re '	no-op	' "$home/state/.supervision-host.log" "the close must not be treated as handled"
  watcher_live "$home" || fail "the pass-through left no successor watcher"
  pass "host: a decision close accepted away whose turn starts attended still reaches main unchanged"
}

# Grok and OpenCode have no mirror writer, because they cannot record a
# session's first captain prompt, and neither Codex nor omp has a proven one,
# so none of them has a verified dialog mirror: every attended close reaches
# main as without the host, while the away posture, which needs no mirror,
# still runs on the engine.
test_primary_without_a_verified_mirror_runs_away_only() {
  local home harness
  for harness in grok opencode omp codex; do
    home=$(make_home "attended-$harness" attended claude)
    FM_SUPERVISION_HOST_PRIMARY=$harness start_host "$home"
    wait_until 150 watcher_live "$home" || fail "$harness: the host never started a watcher cycle"
    append_status "$home" 'fixture finished' 'done'
    wait_until 200 host_exited "$home" || fail "$harness: the host did not hand the attended close to main"
    assert_re '^signal: .*demo.status' "$home/host.out" "the close must carry the watcher's reason line"
    assert_no_re '^supervision-host' "$home/host.out" "the close must reach main exactly as the arm printed it"
    [ "$(engine_calls "$home")" -eq 0 ] || fail "$harness: the engine ran an attended wake without a verified dialog mirror"
    assert_re "	pass-through	attended	no verified dialog mirror for $harness	" "$home/state/.supervision-host.log" \
      "the ledger must record that no verified mirror kept the close on main"
  done
  home=$(make_home away-grok away claude)
  FM_SUPERVISION_HOST_PRIMARY=grok start_host "$home"
  wait_until 150 watcher_live "$home" || fail "away grok: the host never started a watcher cycle"
  append_status "$home" 'step one'
  wait_until 250 handled_at_least "$home" 1 \
    || fail "away grok: the wake was not handled on the engine: $(cat "$home/host.out"; cat "$home/state/.supervision-host.log")"
  assert_re '^primary=grok$' "$home/engine-call.1" "the away engine must carry the grok primary pin"
  assert_re '^POSTURE: AWAY\.' "$home/engine-call.1" "the away wake must carry the away tail"
  [ ! -s "$home/host.rc" ] || fail "a handled away wake on grok reached main: $(cat "$home/host.out")"
  kill -TERM "$(awk -F '\t' '$1 == "host" { print $2 }' "$home/state/.supervision-host")"
  wait_until 200 host_exited "$home" || fail "away grok: the host did not stop on TERM"
  pass "host: a primary with no verified dialog mirror keeps every attended close on main, and its away posture still runs"
}

test_attended_wake_carries_the_dialog_mirror() {
  local home first second
  home=$(make_home attended-mirror attended)
  printf '{"hook_event_name":"UserPromptSubmit","prompt_id":"p1","prompt":"keep the export worker on low effort"}' > "$home/mirror-seed.1"
  printf '{"hook_event_name":"Stop","prompt_id":"p1","last_assistant_message":"Understood, low effort it is."}' > "$home/mirror-seed.2"
  printf '{"hook_event_name":"UserPromptSubmit","prompt_id":"p2","prompt":"\342\201\243FIRSTMATE_OP: v1 watcher: signal: demo.status"}' > "$home/mirror-seed.3"
  start_host "$home"
  wait_until 150 watcher_live "$home" || fail "mirror: the host never started a watcher cycle"
  append_status "$home" 'step one'
  wait_until 250 handled_at_least "$home" 1 || fail "mirror: the wake was not handled: $(cat "$home/state/.supervision-host.log")"
  first="$home/engine-call.1"
  assert_re '^arg=MAIN DIALOG MIRROR \(read-only context' "$first" "the wake must open with the dialog mirror"
  assert_re '^\[captain\] keep the export worker on low effort$' "$first" "the mirror must carry the captain's words"
  assert_re '^\[main\] Understood, low effort it is\.$' "$first" "the mirror must carry main's reply"
  assert_no_re 'FIRSTMATE_OP' "$first" "operational input must never be mirrored as dialog"
  append_status "$home" 'step two'
  wait_until 250 handled_at_least "$home" 2 || fail "mirror: the second wake was not handled"
  second="$home/engine-call.2"
  assert_re '^arg=--resume$' "$second" "fixture: the second turn did not resume the conversation"
  assert_no_re 'MAIN DIALOG MIRROR' "$second" "a resumed conversation must not be fed dialog it already has"
  pass "host: each wake carries the captain's dialog since the last wake, without operational input"
}

# Every file carrying the captain's dialog is owner-only, even under an open
# umask and when a readable copy was already there. The feed is removed before
# the engine starts, so a node wrapper records its mode as the wake renders.
test_dialog_bearing_files_are_owner_only() {
  local home old
  home=$(make_home attended-private attended)
  {
    printf '#!/usr/bin/env bash\nREAL_NODE=%q\n' "$(command -v node)"
    cat <<'SH'
prev=
for a in "$@"; do
  [ "$prev" != --mirror-file ] || { stat -c %a "$a" 2>/dev/null || stat -f %Lp "$a"; } >> "$FM_HOME/feed-modes"
  prev=$a
done
exec "$REAL_NODE" "$@"
SH
  } > "$home/fakebin/node"
  chmod +x "$home/fakebin/node"
  old=$(umask)
  umask 022
  for f in .host-mirror.jsonl .supervision-host-mirror .supervision-host-wake; do
    : > "$home/state/$f"
    chmod 644 "$home/state/$f"
  done
  start_host "$home"
  umask "$old"
  wait_until 150 watcher_live "$home" || fail "private: the host never started a watcher cycle"
  append_status "$home" 'step one'
  wait_until 250 handled_at_least "$home" 1 || fail "private: the wake was not handled: $(cat "$home/state/.supervision-host.log")"
  assert_re '^\[captain\] watch the fleet for me$' "$home/engine-call.1" "fixture: the wake must carry the captain's words"
  [ "$(mode_of "$home/state/.host-mirror.jsonl")" = 600 ] || fail "the dialog mirror must be owner-only, got $(mode_of "$home/state/.host-mirror.jsonl")"
  [ "$(mode_of "$home/state/.supervision-host-wake")" = 600 ] || fail "the wake file must be owner-only, got $(mode_of "$home/state/.supervision-host-wake")"
  [ "$(cat "$home/feed-modes" 2>/dev/null)" = 600 ] || fail "the mirror feed must be owner-only, got $(cat "$home/feed-modes" 2>/dev/null)"
  pass "host: the dialog mirror, its feed, and the wake file are owner-only"
}

# Dialog counts as delivered only once the turn that carried it is accepted
# with its report. A host that reaches its park boundary after feeding the
# mirror but before the turn, or is stopped mid-turn, leaves the conversation
# resumable without it, so the next turn must still carry it; a turn with no
# report starts a new conversation, which must carry it too.
test_undelivered_dialog_is_fed_again_on_the_next_turn() {
  local home real_node second third fourth
  home=$(make_home mirror-boundary attended)
  real_node=$(command -v node)
  cat > "$home/fakebin/node" <<SH
#!/usr/bin/env bash
if [ "\${2:-}" = wake-prompt ] && [ -e "\$FM_HOME/slow-render" ]; then echo 120 > "\$FM_HOME/park-clock"; fi
exec "$real_node" "\$@"
SH
  chmod +x "$home/fakebin/node"
  printf '{"hook_event_name":"UserPromptSubmit","prompt_id":"p1","prompt":"first ask"}' > "$home/mirror-seed.1"
  echo 0 > "$home/park-clock"
  # The park bound sits past every wall-clock check below, so a host that
  # ignored the test clock could never reach a boundary inside this case.
  FM_TEST_SUPERVISION_HOST_CLOCK="$home/park-clock" FM_SUPERVISION_HOST_PARK_SECONDS=120 FM_SUPERVISION_HOST_TURN_TIMEOUT=20 FM_SUPERVISION_ENGINE_GRACE=1 start_session "$home"
  park_again "$home"
  append_status "$home" 'first'
  wait_until 250 handled_at_least "$home" 1 || fail "mirror boundary: the first wake was not handled: $(cat "$home/state/.supervision-host.log")"
  assert_re '^\[captain\] first ask$' "$home/engine-call.1" "fixture: the first turn did not carry the first dialog"
  kill -TERM "$(awk -F '\t' '$1 == "host" { print $2 }' "$home/state/.supervision-host")"
  wait_until 200 host_exited "$home" || fail "mirror boundary: the first host did not stop on TERM"

  printf '{"hook_event_name":"UserPromptSubmit","prompt_id":"p2","prompt":"second ask, never handed over"}' > "$home/mirror-seed.2"
  : > "$home/slow-render"
  echo 0 > "$home/park-clock"
  park_after_stop "$home"
  append_status "$home" 'reaches the boundary'
  wait_until 400 host_exited "$home" || fail "mirror boundary: the host did not end its park"
  assert_re '^supervision-host: cycle boundary - ' "$home/host.out" "fixture: the second host did not exit at its boundary"
  [ "$(engine_calls "$home")" -eq 1 ] || fail "fixture: an engine turn ran at the boundary"
  main_drain_and_ack "$home"

  rm -f "$home/slow-render"
  echo 0 > "$home/park-clock"
  park_again "$home"
  append_status "$home" 'handled after the boundary'
  wait_until 250 handled_at_least "$home" 2 || fail "mirror boundary: the next wake was not handled: $(cat "$home/state/.supervision-host.log")"
  second="$home/engine-call.2"
  assert_re '^arg=--resume$' "$second" "fixture: the next turn did not resume the conversation"
  assert_re '^\[captain\] second ask, never handed over$' "$second" \
    "dialog fed to a wake that never reached the engine must reach the next turn"
  assert_no_re '^\[captain\] first ask$' "$second" "a resumed conversation must not be fed dialog it already has"

  printf '{"hook_event_name":"UserPromptSubmit","prompt_id":"p3","prompt":"third ask, turn stopped"}' > "$home/mirror-seed.3"
  kill -TERM "$(awk -F '\t' '$1 == "host" { print $2 }' "$home/state/.supervision-host")"
  wait_until 200 host_exited "$home" || fail "mirror boundary: the second handling host did not stop on TERM"
  echo hang > "$home/stub-mode"
  park_after_stop "$home"
  append_status "$home" 'stopped mid-turn'
  wait_until 250 test -e "$home/engine-call.3" || fail "mirror boundary: the stopped turn never started"
  assert_re '^\[captain\] third ask, turn stopped$' "$home/engine-call.3" "fixture: the stopped turn did not carry the third dialog"
  kill -TERM "$(awk -F '\t' '$1 == "host" { print $2 }' "$home/state/.supervision-host")"
  wait_until 200 host_exited "$home" || fail "mirror boundary: the host did not stop mid-turn on TERM"
  echo handle > "$home/stub-mode"
  park_after_stop "$home"
  append_status "$home" 'handled after the stop'
  wait_until 250 handled_at_least "$home" 3 || fail "mirror boundary: the wake after the stop was not handled: $(cat "$home/state/.supervision-host.log")"
  third="$home/engine-call.4"
  assert_re '^arg=--resume$' "$third" "fixture: the turn after the stop did not resume the conversation"
  assert_re '^\[captain\] third ask, turn stopped$' "$third" "dialog of a turn stopped before its report must reach the next turn"
  assert_no_re '^\[captain\] second ask' "$third" "a resumed conversation must not be fed dialog a handled turn delivered"

  printf '{"hook_event_name":"UserPromptSubmit","prompt_id":"p4","prompt":"fourth ask, turn unreported"}' > "$home/mirror-seed.4"
  kill -TERM "$(awk -F '\t' '$1 == "host" { print $2 }' "$home/state/.supervision-host")"
  wait_until 200 host_exited "$home" || fail "mirror boundary: the third handling host did not stop on TERM"
  echo noreport > "$home/stub-mode"
  park_after_stop "$home"
  append_status "$home" 'no report'
  wait_until 250 host_exited "$home" || fail "mirror boundary: the unreported turn did not hand its wake back"
  assert_re '^\[captain\] fourth ask, turn unreported$' "$home/engine-call.5" "fixture: the unreported turn did not carry the fourth dialog"
  main_drain_and_ack "$home"
  echo handle > "$home/stub-mode"
  park_again "$home"
  append_status "$home" 'handled after no report'
  wait_until 250 handled_at_least "$home" 4 || fail "mirror boundary: the wake after the unreported turn was not handled: $(cat "$home/state/.supervision-host.log")"
  fourth="$home/engine-call.6"
  assert_re '^\[captain\] fourth ask, turn unreported$' "$fourth" "dialog of a turn that recorded no report must reach the next turn"
  pass "host: dialog a turn never completed with its report (a park boundary, a stopped turn, no report) reaches the next turn"
}

# The attended engine never judges without the captain's words: a mirror that
# is missing, cannot be read, or holds an entry that does not parse hands the
# wake to main before any engine turn and leaves the mirror cursor where it was.
test_attended_wake_with_an_unreadable_mirror_reaches_main() {
  local home mirror cursor
  home=$(make_home attended-bad-mirror attended)
  mirror="$home/state/.host-mirror.jsonl"
  printf '{"hook_event_name":"UserPromptSubmit","prompt_id":"p1","prompt":"keep the export worker on low effort"}' > "$home/mirror-seed.1"
  start_session "$home"
  park_again "$home"
  append_status "$home" 'first'
  wait_until 250 handled_at_least "$home" 1 || fail "bad mirror: the first wake was not handled: $(cat "$home/state/.supervision-host.log")"
  cursor=$(cat "$home/state/.host-mirror-cursor") || fail "fixture: the handled turn committed no mirror cursor"

  rm -f "$mirror"
  append_status "$home" 'missing mirror'
  wait_until 250 host_exited "$home" || fail "bad mirror: a missing mirror did not hand the wake to main"
  assert_re '^signal: .*demo.status' "$home/host.out" "the handed-back close must carry the watcher's reason line"
  assert_re '^supervision-host: the supervision session could not take this wake: the dialog mirror could not be read; this wake is yours$' \
    "$home/host.out" "a missing mirror must hand the wake to main with its reason"
  [ "$(engine_calls "$home")" -eq 1 ] || fail "bad mirror: the engine ran without a mirror"
  [ "$(cat "$home/state/.host-mirror-cursor")" = "$cursor" ] || fail "a missing mirror moved the cursor"
  [ ! -e "$home/state/.host-mirror-cursor.next" ] || fail "a missing mirror staged a cursor"
  main_drain_and_ack "$home"

  park_again "$home"
  [ -f "$mirror" ] || fail "fixture: the next park did not write the mirror again"
  chmod 000 "$mirror"
  append_status "$home" 'unreadable mirror'
  wait_until 250 host_exited "$home" || fail "bad mirror: an unreadable mirror did not hand the wake to main"
  chmod 644 "$mirror"
  assert_re '^signal: .*demo.status' "$home/host.out" "the handed-back close must carry the watcher's reason line"
  assert_re '^supervision-host: the supervision session could not take this wake: the dialog mirror could not be read; this wake is yours$' \
    "$home/host.out" "an unreadable mirror must hand the wake to main with its reason"
  [ "$(engine_calls "$home")" -eq 1 ] || fail "bad mirror: the engine ran without a readable mirror"
  [ "$(cat "$home/state/.host-mirror-cursor")" = "$cursor" ] || fail "an unreadable mirror moved the cursor"
  [ ! -e "$home/state/.host-mirror-cursor.next" ] || fail "an unreadable mirror staged a cursor"
  main_drain_and_ack "$home"

  printf '#!/usr/bin/env bash\nprev=\nfor a in "$@"; do [ "$prev" != --mirror-file ] || chmod 000 "$a"; prev=$a; done\nexec %q "$@"\n' \
    "$(command -v node)" > "$home/fakebin/node"
  chmod +x "$home/fakebin/node"
  park_again "$home"
  append_status "$home" 'mirror lost before the prompt'
  wait_until 250 host_exited "$home" || fail "bad mirror: a feed lost before the prompt did not hand the wake to main"
  rm -f "$home/fakebin/node"
  assert_re '^supervision-host: the supervision session could not take this wake: the dialog mirror could not be read; this wake is yours$' \
    "$home/host.out" "a feed lost before the prompt must hand the wake to main with its reason"
  [ "$(engine_calls "$home")" -eq 1 ] || fail "bad mirror: the engine ran without the feed it was promised"
  [ "$(cat "$home/state/.host-mirror-cursor")" = "$cursor" ] || fail "a feed lost before the prompt moved the cursor"
  main_drain_and_ack "$home"

  printf '{"seq":' >> "$mirror"
  printf '\n' >> "$mirror"
  park_again "$home"
  append_status "$home" 'malformed mirror'
  wait_until 250 host_exited "$home" || fail "bad mirror: a malformed mirror entry did not hand the wake to main"
  assert_re '^supervision-host: the supervision session could not take this wake: the dialog mirror could not be read; this wake is yours$' \
    "$home/host.out" "a malformed mirror entry must hand the wake to main with its reason"
  [ "$(engine_calls "$home")" -eq 1 ] || fail "bad mirror: the engine ran past a malformed mirror entry"
  [ "$(cat "$home/state/.host-mirror-cursor")" = "$cursor" ] || fail "a malformed mirror entry moved the cursor"
  [ ! -e "$home/state/.host-mirror-cursor.next" ] || fail "a malformed mirror entry staged a cursor past it"
  pass "host: an attended wake whose mirror is missing, cannot be read (at the feed or at the prompt), or holds a malformed entry reaches main before any engine turn, and the cursor stays put"
}

test_attended_latch_keeps_closes_on_main_and_records_recovery_off_main() {
  local home handled
  home=$(make_home attended-latch attended)
  echo fail > "$home/stub-mode"
  start_session "$home"
  park_again "$home"
  append_status "$home" 'first'
  wait_until 250 host_exited "$home" || fail "latch: the first engine error did not hand the wake back"
  assert_re '^supervision-host: the supervision session could not take this wake: the engine turn failed \(exit 3\); this wake is yours$' \
    "$home/host.out" "the first engine error must hand the wake back with its reason"
  assert_no_re 'paused' "$home/host.out" "one engine error must not latch the session"
  main_drain_and_ack "$home"

  park_again "$home"
  append_status "$home" 'second'
  wait_until 250 host_exited "$home" || fail "latch: the second engine error did not hand the wake back"
  assert_re '^supervision-host: the supervision session is paused after repeated engine errors; every wake reaches you for the next 5 minutes' "$home/host.out" \
    "the second consecutive engine error must trip the latch with one line"
  assert_grep 'cooldown=300' "$home/state/.supervision-host-health" "the latch must start with the Pi policy's five-minute cooldown"
  main_drain_and_ack "$home"

  park_again "$home"
  append_status "$home" 'inside the cooldown'
  wait_until 250 host_exited "$home" || fail "latch: a close inside the cooldown did not reach main"
  assert_re '^signal: .*demo.status' "$home/host.out" "a close inside the cooldown must reach main"
  assert_no_re '^supervision-host' "$home/host.out" "a close inside the cooldown must reach main exactly as the arm printed it"
  [ "$(engine_calls "$home")" -eq 2 ] || fail "the engine ran inside the cooldown"
  assert_re '	pass-through	attended	the supervision session is cooling down' "$home/state/.supervision-host.log" \
    "the ledger must record the cooldown"
  main_drain_and_ack "$home"

  end_cooldown "$home"
  park_again "$home"
  append_status "$home" 'the probe fails'
  wait_until 250 host_exited "$home" || fail "latch: the failed probe did not hand the wake back"
  [ "$(engine_calls "$home")" -eq 3 ] || fail "the cooldown's end did not let one wake probe the engine"
  assert_no_re 'paused' "$home/host.out" "a failed probe must not repeat the trip line"
  assert_grep 'cooldown=600' "$home/state/.supervision-host-health" "a failed probe must double the cooldown"
  main_drain_and_ack "$home"

  end_cooldown "$home" 2400
  park_again "$home"
  append_status "$home" 'a later probe fails'
  wait_until 250 host_exited "$home" || fail "latch: the later failed probe did not hand the wake back"
  [ "$(engine_calls "$home")" -eq 4 ] || fail "the grown cooldown's end did not let one wake probe the engine"
  assert_grep 'cooldown=3600' "$home/state/.supervision-host-health" "the doubled cooldown must stop at one hour"
  main_drain_and_ack "$home"

  end_cooldown "$home"
  echo handle > "$home/stub-mode"
  handled=$(handled_count "$home")
  park_again "$home"
  append_status "$home" 'the probe succeeds'
  wait_until 250 handled_at_least "$home" $((handled + 1)) \
    || fail "latch: the successful probe was not handled: $(cat "$home/host.out"; tail -n 5 "$home/state/.supervision-host.log")"
  assert_re '	recovered	after a successful probe$' "$home/state/.supervision-host.log" "the ledger must record the recovery"
  ! wait_until 20 host_exited "$home" || fail "a routine probe's recovery reached main: $(cat "$home/host.out")"
  assert_no_re '^supervision-host' "$home/host.out" "a recovery must stay off main"
  assert_grep 'cooldown=0' "$home/state/.supervision-host-health" "a successful probe must clear the latch"
  assert_grep 'errors=0' "$home/state/.supervision-host-health" "a successful probe must clear the error streak"
  pass "host: attended, two engine errors latch the session, main keeps every close unchanged in the cooldown, a failed probe doubles it up to its cap, and a routine probe's recovery stays in the ledger, off main"
}

# FM_TEST_ONLY runs a single named case, the same entry point the sibling
# suites expose.
if [ -n "${FM_TEST_ONLY:-}" ]; then
  "$FM_TEST_ONLY"
  exit 0
fi

test_claude_stop_hook_restores_handoff_when_successor_closed_before_exit_to_main
test_claude_stop_hook_restores_handoff_when_successor_closed_mid_engine_turn
test_claude_stop_hook_notifies_when_closed_successor_downtime_restore_fails
test_claude_stop_hook_notifies_when_closed_announced_successor_downtime_restore_fails
test_close_accepted_away_that_turns_attended_passes_to_main
test_claude_stop_hook_delivers_a_main_only_pass_through
test_claude_stop_hook_rewakes_a_present_captain_beside_a_quiet_record
test_claude_stop_hook_runs_the_host_without_the_file_and_off_opts_out
test_claude_stop_hook_delivers_a_close_that_turns_main_only_at_its_turn
test_successor_left_at_the_turn_survives_the_hook_process_group_teardown
test_claude_stop_hook_notifies_when_at_turn_downtime_write_fails
test_successor_close_during_main_turn_is_delivered_at_the_next_turn_end
test_pass_through_successor_survives_the_hook_process_group_teardown
test_next_park_takes_over_the_cycle_a_pass_through_left_for_main
test_a_park_stopped_mid_take_over_leaves_the_take_over_to_the_next_park
test_unrecorded_successor_is_stopped_rather_than_left_for_main
test_primary_without_a_verified_mirror_runs_away_only
test_attended_wake_carries_the_dialog_mirror
test_dialog_bearing_files_are_owner_only
test_undelivered_dialog_is_fed_again_on_the_next_turn
test_attended_wake_with_an_unreadable_mirror_reaches_main
test_attended_latch_keeps_closes_on_main_and_records_recovery_off_main
