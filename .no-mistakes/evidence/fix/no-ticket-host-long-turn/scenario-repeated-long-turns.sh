# Ad-hoc scenario: several consecutive long main turns, each with durable wakes
# appended while the host's pass-through gap successor is live (the 18:12:23,
# 18:12:43, ~18:13 triple). Loaded via FM_TEST_ONLY=multi into
# tests/fm-supervision-host-stop-hook.test.sh so it drives the real Stop hook,
# supervision host, fm-watch-arm.sh and fm-watch.sh against a disposable home.
main_turn() {  # <home>: main drains the queue (via the suite's main_drain helper) and acknowledges
  main_drain "$1" | sed 's/^/  main drain: /' >&2
  main_drain "$1" >/dev/null
  # shellcheck disable=SC2086
  [ -z "$MAIN_ACK" ] || FM_HOME="$1" "$FAKE_CLAUDE" -c '"$0" "$@" 2>&1' "$ROOT/bin/fm-wake-drain.sh" $MAIN_ACK | sed 's/^/  main ack: /' >&2
}
export -f main_turn
multi() {
  local home round last
  home=$(make_primary_home hook-multi)
  trap 'cp "$TMP_ROOT/hook-multi/state/.supervision-host.log" "$CAP_OUT" 2>/dev/null; suite_cleanup' EXIT
  : > "$home/hook.own-group"
  export FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_SIGNAL_GRACE=0
  start_hook_session "$home"
  queue_check "$home" stranded "check: stranded before park" || fail "seed"
  turn_end "$home"
  wait_until 250 hook_exited "$home" || fail "first close never arrived"
  main_turn "$home"
  for round in 1 2 3; do
    watcher_live "$home" || fail "round $round: no live gap successor"
    # several wakes arrive during the long turn
    FM_HOME="$home" bash -c '. "$1"; fm_wake_append heartbeat heartbeat heartbeat' _ "$ROOT/bin/fm-wake-lib.sh"
    queue_check "$home" "seat-$round" "check: long-turn wake round $round" || fail "append $round"
    if [ "$round" = 2 ]; then
      FM_HOME="$home" bash -c '. "$1"; fm_wake_append stale "w2" "stale: worker w2 quiet round 2"' _ "$ROOT/bin/fm-wake-lib.sh"
    fi
    turn_end "$home"
    wait_until 250 hook_exited "$home" || fail "round $round: wake never reached the Stop hook: $(cat "$home/state/.supervision-host.log")"
    last=$(grep 'pass-through' "$home/state/.supervision-host.log" | tail -1 | cut -f5)
    case "$round" in
      2) [ "$last" = "stale: worker w2 quiet round 2" ] || fail "round 2: stale did not outrank check, got '$last'" ;;
      *) [ "$last" = "check: long-turn wake round $round" ] || fail "round $round: got '$last'" ;;
    esac
    printf 'round %s delivered: %s\n' "$round" "$last"
    main_turn "$home"
  done
  [ "$(grep -c 'check: rearm-resurface' "$home/state/.supervision-host.log")" -eq 1 ] \
    || fail "rearm-resurface repeated: $(cat "$home/state/.supervision-host.log")"
  pass "three consecutive long turns with gap appends: each delivered as itself, rearm-resurface handed only once"
}
export -f multi
