#!/usr/bin/env bash
# Live scenario driver: real bin/fm-worker-park.sh tick/status, bin/fm-spawn.sh,
# bin/fm-fleet-snapshot.sh against a disposable home, cloned project, fake tmux.
# Fixture helpers are extracted verbatim from tests/fm-fleet-capacity.test.sh.
cd "$1"
. "$2/fixture-extract.sh"
RESULTS=0
say() { printf '\n=== %s ===\n' "$*"; }
check() { # desc condition-rc
  if [ "$2" = 0 ]; then printf 'PASS: %s\n' "$1"; else printf 'FAIL: %s\n' "$1"; RESULTS=1; fi; }
status() { park_command "$1" "$1/home" status; }
jqc() { printf '%s\n' "$1" | jq -e "$2" >/dev/null; echo $?; }

say "S1 pilot observe floor6/ceiling8/start8: sustained CPU decline is reported, not enforced, no wake"
C=$(make_case pilot task-x task-y task-z); H=$C/home
declare_fleet "$H" 8; load_policy "$H" observe 6 8 8
for i in 1 2 3 4 5 6; do write_running "$C" "$H" live-$i "$C/project"; done
for at in 1000 1060 1120; do load_fixture "$C" $at normal 150 140; load_tick "$C"; done
S=$(status "$C"); printf '%s\n' "$S" | jq -c '{mode,configured,desired,effective,hold,reason,occupancy,queued_resumes}'
check "observe desired=7 effective=8 reason=sustained CPU load" $(jqc "$S" '.mode=="observe" and .desired==7 and .effective==8 and .state.reason=="sustained CPU load"')
check "observe queued no capacity wake" $([ ! -e "$H/state/.fleet-load-notice" ] && ! grep -q 'fleet-load' "$H/state/.wake-queue" 2>/dev/null; echo $?)
out=$(spawn_ship "$C" task-x); rc=$?; printf 'spawn task-x rc=%s\n%s\n' $rc "$(printf '%s\n' "$out" | grep -E 'fleet capacity|deferred' )"
check "observe admits 7th worker (static cap 8)" $([ $rc = 0 ] && [ -f "$H/state/task-x.meta" ]; echo $?)

say "S2 switch pilot to enforce: observed history carries over, effective=7 defers 8th, wake sent"
load_policy "$H" enforce 6 8 8
load_fixture "$C" 1180 normal 100 100; load_tick "$C"
S=$(status "$C"); printf '%s\n' "$S" | jq -c '{mode,desired,effective,hold,reason:.state.reason,occupancy}'
check "enforce keeps observed target 7" $(jqc "$S" '.mode=="enforce" and .effective==7 and .occupancy==7')
check "enforce queued a capacity-change wake" $(grep -q 'fleet-load capacity changed' "$H/state/.wake-queue"; echo $?)
before=$(call_count "$C"); wts=$(worktree_list "$C")
out=$(spawn_ship "$C" task-y "$C/unused"); rc=$?; printf 'spawn task-y rc=%s\n%s\n' $rc "$(printf '%s\n' "$out" | grep deferred)"
check "enforce defers 8th worker with exit 75 and names reason" $([ $rc = 75 ] && printf '%s' "$out" | grep -q 'fleet load policy lowers it' ; echo $?)
check "deferred spawn created nothing" $([ ! -e "$H/state/task-y.meta" ] && [ "$wts" = "$(worktree_list "$C")" ]; echo $?)
check "no running worker was stopped" $(! grep -q kill-window "$C/calls.log"; echo $?)

say "S3 slow recovery: 9 healthy minutes stay at 7, the 10th floats back to 8, then admits"
for at in 1240 1300 1360 1420 1480 1540 1600 1660 1720; do load_fixture "$C" $at normal 40 40; load_tick "$C"; done
S=$(status "$C"); printf '%s\n' "$S" | jq -c '{effective,healthy:.state.healthy,reason:.state.reason}'
check "nine healthy minutes do not recover" $(jqc "$S" '.effective==7 and .state.healthy==9')
load_fixture "$C" 1780 normal 40 40; load_tick "$C"
S=$(status "$C"); printf '%s\n' "$S" | jq -c '{effective,healthy:.state.healthy,reason:.state.reason}'
check "tenth healthy minute restores slot 8" $(jqc "$S" '.effective==8 and .state.reason=="ten healthy minutes"')
out=$(spawn_ship "$C" task-y); rc=$?
check "recovered capacity admits 8th worker" $([ $rc = 0 ] && [ -f "$H/state/task-y.meta" ]; echo $?)
out=$(spawn_ship "$C" task-z "$C/unused"); rc=$?; printf 'spawn task-z rc=%s %s\n' $rc "$(printf '%s\n' "$out" | grep deferred)"
check "hand-set cap 8 still bounds (9th defers)" $([ $rc = 75 ]; echo $?)

say "S4 critical memory pressure holds admission below the floor on an empty fleet"
C=$(make_case crit task-a); H=$C/home; declare_fleet "$H" 8; load_policy "$H" enforce 6 8 8
load_fixture "$C" 1000 critical 40 40; load_tick "$C"
out=$(spawn_ship "$C" task-a "$C/unused"); rc=$?; printf 'spawn rc=%s %s\n' $rc "$(printf '%s\n' "$out" | grep deferred | cut -c1-200)"
S=$(status "$C"); printf '%s\n' "$S" | jq -c '{occupancy,desired,hold}'
check "critical hold defers with 0 occupants" $([ $rc = 75 ] && printf '%s' "$S" | jq -e '.occupancy==0 and (.hold|contains("critical"))' >/dev/null; echo $?)

say "S5 adversarial: stale/unreadable sensor in enforce defers instead of guessing"
C=$(make_case stale task-a); H=$C/home; declare_fleet "$H" 8; load_policy "$H" enforce 6 8 8
load_fixture "$C" 1000 normal 40 40; load_tick "$C"
load_fixture "$C" 1300 normal 40 40; printf 'garbage\n' > "$FM_FLEET_LOAD_TELEMETRY"
out=$(spawn_ship "$C" task-a "$C/unused"); rc=$?; printf 'spawn rc=%s %s\n' $rc "$(printf '%s\n' "$out" | grep deferred | cut -c1-240)"
check "stale sensor defers and names stale reason" $([ $rc = 75 ] && printf '%s' "$out" | grep -q 'stale sensor'; echo $?)
check "unreadable sensor cannot authorise recovery (healthy reset)" $(jqc "$(status "$C")" '.state.healthy==0')

say "S6 adversarial: JSON {mode:off} with no fleet cap and an unreadable task record"
C=$(make_case jsonoff task-a); H=$C/home
printf '{"mode":"off"}\n' > "$H/config/fleet-load-policy"
printf 'kind=ship\n' > "$H/state/stranger.meta"; chmod 000 "$H/state/stranger.meta"
out=$(spawn_ship "$C" task-a); rc=$?; chmod 600 "$H/state/stranger.meta"
printf 'spawn rc=%s\n%s\n' $rc "$(printf '%s\n' "$out" | grep -E 'fleet capacity|integer|error' | cut -c1-260)"
check "spawn admitted uncapped" $([ $rc = 0 ] && [ -f "$H/state/task-a.meta" ]; echo $?)
check "no integer-comparison diagnostic, no record counting" $(! printf '%s' "$out" | grep -qE 'integer expression|cannot all be read'; echo $?)
S=$(status "$C"); printf '%s\n' "$S" | jq -c '{mode,hold,reason}'
check "status reports JSON off as actionable invalid config" $(jqc "$S" '.mode=="invalid" and .hold=="" and (.reason|contains("bare word off"))')

say "S7 default off: no policy file means no sampling and static behaviour"
C=$(make_case default task-a); H=$C/home; declare_fleet "$H" 8; load_tick "$C"
S=$(status "$C"); printf '%s\n' "$S" | jq -c '{mode,effective,reason}'
check "absent policy = off, no fleet-load.json" $([ ! -e "$H/state/fleet-load.json" ] && printf '%s' "$S" | jq -e '.mode=="off" and .effective==8' >/dev/null; echo $?)

say "S8 native macOS sensor (no fixture) in observe; snapshot/home-summary project same capacity read-only"
unset FM_FLEET_LOAD_CLOCK FM_FLEET_LOAD_TELEMETRY
C=$(make_case native task-a); H=$C/home; declare_fleet "$H" 8; load_policy "$H" observe 6 8 8
load_tick "$C"; S=$(status "$C")
printf '%s\n' "$S" | jq -c '{mode,desired,effective,hold,sample_age_seconds,signals:.state.signals}'
check "native sample valid with real load/pressure" $(jqc "$S" '.state.sample_valid==true and (.state.signals.cpus>0) and (.state.signals.pressure|type=="string") and .effective==8')
st=$(cat "$H/state/fleet-load.json")
snap=$(FM_HOME="$H" FM_ROOT_OVERRIDE='' FM_STATE_OVERRIDE='' FM_CONFIG_OVERRIDE='' FM_DATA_OVERRIDE='' FM_PROJECTS_OVERRIDE='' FM_FAKE_CALL_LOG="$C/calls.log" FM_BACKEND=tmux PATH="$C/fakebin:$TEST_PATH" bash "$ROOT/bin/fm-fleet-snapshot.sh" --json)
printf 'snapshot.capacity: %s\n' "$(printf '%s' "$snap" | jq -c '.capacity|{mode,desired,effective,occupancy}')"
check "snapshot capacity equals status" $([ "$(printf '%s' "$S" | jq -cS 'del(.sample_age_seconds)')" = "$(printf '%s' "$snap" | jq -cS '.capacity|del(.sample_age_seconds)')" ]; echo $?)
check "snapshot did not refresh telemetry" $([ "$st" = "$(cat "$H/state/fleet-load.json")" ]; echo $?)
printf '\nOVERALL=%s\n' $([ $RESULTS = 0 ] && echo PASS || echo FAIL)
exit $RESULTS
