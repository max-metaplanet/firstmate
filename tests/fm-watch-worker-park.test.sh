#!/usr/bin/env bash
# A deliberate worker park silences endpoint recovery, while the same dead
# endpoint without that record still produces its ordinary actionable wake.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/watch-triage-helpers.sh"
dir=$(wedge_threshold_fixture intentional-park 'working: still compiling' 0 10)
state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"; capture="$dir/pane.txt"
printf 'phase=parked\ngeneration=legacy\nendpoint=test:fm-wedge\nreason=upstream maintainer\nuntil=0\nqueued_at=0\nstatus_line=working: still compiling\n' > "$state/wedge.park"
gone_endpoint_env dead
export FM_TEST_PANE_COMMAND FM_TEST_TMUX_WINDOWS
failed='state: failed · source: run-step · run failed'
wedge_threshold_round "$state" "$fakebin" "$out" "$capture" test:fm-wedge "$failed" absorb || fail 'parked watcher did not stay healthy'
assert_not_contains "$(cat "$out")" 'stale:' 'intentional park never alarms stale'
assert_not_contains "$(cat "$out")" 'agent dead' 'intentional park never alarms dead'
assert_absent "$state/.dead-reported-test_fm-wedge" 'intentional park never enters dead recovery'
rm "$state/wedge.park"
wedge_threshold_round "$state" "$fakebin" "$out" "$capture" test:fm-wedge "$failed" exit || fail 'unparked dead worker was not reported'
assert_contains "$(cat "$out")" 'agent dead' 'unparked death still reports recovery'
pass 'parked endpoints are quiet and ordinary dead endpoints still alarm'
