#!/usr/bin/env bash
# Worker park orchestration through its executable API. Lifecycle mechanics
# remain covered by fm-control.test.sh; the control fixture here exposes verified
# success/failure and admission deferral without driving a real worker.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-worker-park)
mkdir -p "$TMP_ROOT/bin"
trap 'rm -rf "$TMP_ROOT"' EXIT
for script in "$ROOT"/bin/*; do ln -s "$script" "$TMP_ROOT/bin/${script##*/}"; done
rm "$TMP_ROOT/bin/fm-control.sh" "$TMP_ROOT/bin/fm-busy-lib.sh"
cat > "$TMP_ROOT/bin/fm-control.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_HOME/control.log"
if [ "$2" = exit ]; then
  [ ! -e "$FM_HOME/exit-fails" ] || exit 1
  if [ -e "$FM_HOME/steer-on-exit" ]; then
    mkdir -p "$FM_HOME/state/$1.inbox"
    printf 'new work\n' > "$FM_HOME/state/$1.inbox/1.msg"
  fi
  printf dead > "$FM_HOME/agent"
else
  # Real relaunch takes the lease-command lock; a held one would block forever.
  if [ -n "${FM_SUPERVISION_ACTOR:-}" ] && [ -d "$FM_HOME/state/.fm-lease-command.lock" ]; then
    printf 'relaunch blocked on held lease lock\n' >> "$FM_HOME/control.log"
    exit 1
  fi
  [ ! -e "$FM_HOME/full" ] || exit 75
  [ ! -e "$FM_HOME/resume-fails" ] || exit 1
  printf alive > "$FM_HOME/agent"
  printf 'spawn_gen=replacement\n' >> "$FM_HOME/state/$1.meta"
fi
SH
cat > "$TMP_ROOT/bin/fm-busy-lib.sh" <<'SH'
fm_busy_classify() { printf '%s\n' "${FM_TEST_BUSY:-idle hook}"; }
SH
chmod +x "$TMP_ROOT/bin/fm-control.sh"
PARK=$TMP_ROOT/bin/fm-worker-park.sh
export FM_HOME=$TMP_ROOT/home
mkdir -p "$FM_HOME/state" "$FM_HOME/config" "$FM_HOME/data"
fm_git_init_commit "$FM_HOME/project"
export FM_STATE_OVERRIDE=$FM_HOME/state FM_CONFIG_OVERRIDE=$FM_HOME/config
export FM_TEST_BUSY='idle hook'
URL=https://github.com/example/repo/pull/99
fixture() {
  rm -f "$FM_HOME/state/task.park" "$FM_HOME/control.log" "$FM_HOME/full" "$FM_HOME/exit-fails" "$FM_HOME/resume-fails" "$FM_HOME/steer-on-exit" "$FM_HOME/project/dirty" "$FM_HOME/state/task.turn-ended"
  rm -rf "$FM_HOME/state/task.inbox"
  printf 'kind=ship\nbackend=tmux\nwindow=%%7\nspawn_gen=original\nyolo=off\nmode=direct-PR\npr=%s\nworktree=%s\nharness=codex\n' "$URL" "$FM_HOME/project" > "$FM_HOME/state/task.meta"
  printf 'done: PR %s checks green\n' "$URL" > "$FM_HOME/state/task.status"
}
fixture
bash "$PARK" auto task >/dev/null
assert_grep 'phase=parked' "$FM_HOME/state/task.park" 'ready PR parks after exit'
assert_grep 'task exit' "$FM_HOME/control.log" 'uses lifecycle exit'
assert_equals "$(cat "$FM_HOME/agent")" dead 'agent is gone'
fixture
printf 'done: PR %s\n' "$URL" > "$FM_HOME/state/task.status"
bash "$PARK" auto task >/dev/null
assert_grep 'phase=parked' "$FM_HOME/state/task.park" 'registered direct-PR completion parks'
fixture
bash "$PARK" hint task 'waiting on upstream maintainer'
bash "$PARK" request task 'upstream feedback needs work'
bash "$PARK" auto task
assert_grep 'phase=active' "$FM_HOME/state/task.park" 'feedback cancels an unconsumed parking hint'
fixture
printf 'yolo=on\n' >> "$FM_HOME/state/task.meta"
bash "$PARK" auto task
assert_absent "$FM_HOME/state/task.park" 'yolo does not auto park a green PR'
fixture
printf 'needs-decision [key=choice]: choose\ndone: PR %s checks green\n' "$URL" > "$FM_HOME/state/task.status"
bash "$PARK" auto task
assert_absent "$FM_HOME/state/task.park" 'open decision survives newer done'
fixture
touch "$FM_HOME/project/dirty"
bash "$PARK" auto task
assert_absent "$FM_HOME/state/task.park" 'dirty worktree stays live'
fixture
FM_TEST_BUSY='busy hook' bash "$PARK" auto task
assert_absent "$FM_HOME/state/task.park" 'busy process stays live'
fixture
FM_TEST_BUSY='unknown codex-unverified' bash "$PARK" auto task
assert_absent "$FM_HOME/state/task.park" 'unknown liveness without a fresh turn end stays running'
touch "$FM_HOME/state/task.turn-ended"
FM_TEST_BUSY='unknown codex-unverified' bash "$PARK" auto task >/dev/null
assert_grep 'phase=parked' "$FM_HOME/state/task.park" 'completed turn supports marker-only adapters'
fixture
printf 'mode=no-mistakes\n' >> "$FM_HOME/state/task.meta"
mkdir -p "$TMP_ROOT/fakebin"
cat > "$TMP_ROOT/fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
printf 'status: running\ncurrent_step: review\n'
SH
chmod +x "$TMP_ROOT/fakebin/no-mistakes"
# crew-state must also report work when validation is active.
rm "$TMP_ROOT/bin/fm-crew-state.sh"
printf '#!/usr/bin/env bash\nprintf "state: working source: run-step\\n"\n' > "$TMP_ROOT/bin/fm-crew-state.sh"
chmod +x "$TMP_ROOT/bin/fm-crew-state.sh"
PATH="$TMP_ROOT/fakebin:$PATH" bash "$PARK" auto task
assert_absent "$FM_HOME/state/task.park" 'live validation never parks'
# Interrupted CI is terminal but not green. Its published head and the full
# observer are required independently of the old status-log completion.
cat > "$TMP_ROOT/fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
cat "$FM_HOME/nm-status"
SH
cat > "$TMP_ROOT/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
cat "$FM_HOME/forge-pr.json"
SH
chmod +x "$TMP_ROOT/fakebin/gh-axi"
interrupted_fixture() {
  fixture
  printf 'mode=no-mistakes\n' >> "$FM_HOME/state/task.meta"
  printf 'paused: CI-only monitor interrupted\n' > "$FM_HOME/state/task.status"
  local head branch
  head=$(git -C "$FM_HOME/project" rev-parse HEAD)
  branch=$(git -C "$FM_HOME/project" symbolic-ref --short HEAD)
  cat > "$FM_HOME/nm-status" <<EOF
run:
  id: interrupted
  branch: $branch
  status: ci_monitor_interrupted
  head_sha: $head
  pr: "$URL"
  steps[2]{step,status,findings,duration_ms}:
    push,completed,0,10
    pr,completed,0,10
EOF
  printf '{"state":"open","head":{"sha":"%s"}}\n' "$head" > "$FM_HOME/forge-pr.json"
  mkdir -p "$FM_HOME/data/task"
  jq -n --arg url "$URL" --arg head "$head" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
    {schema:"fm-contributions.v1",task:"task",records:[{url:$url,kind:"pr",checked_at:$at,error:null,
      pending:[],seen:[],observation:{state:"open",head:$head,draft:false,mergeable:"mergeable",
        can_merge:false,review_decision:"",checks:[],reviews:[],events:[]}}]}' > "$FM_HOME/data/task/contributions.json"
  printf '#!/bin/sh\nexit 0\n' > "$FM_HOME/state/contributions.check.sh"
  chmod 700 "$FM_HOME/state/contributions.check.sh"
  bash "$TMP_ROOT/bin/fm-check-register.sh" contributions >/dev/null
}
park_nm() { PATH="$TMP_ROOT/fakebin:$PATH" bash "$PARK" "$@"; }
interrupted_fixture
park_nm auto task >/dev/null
assert_grep 'phase=parked' "$FM_HOME/state/task.park" 'terminal interrupted CI parks with matching publication and full observer'
assert_grep 'paused: CI-only monitor interrupted' "$FM_HOME/state/task.status" 'parking never reports interrupted CI as green'
for refusal in dirty decision fixing pending-ci missing-observer stale-observer wrong-owner wrong-observer-head wrong-pr-head unpublished wrong-branch gate fix-round; do
  interrupted_fixture
  expected=''
  case "$refusal" in
    dirty) touch "$FM_HOME/project/dirty"; expected='worktree is dirty' ;;
    decision) printf 'needs-decision [key=choice]: choose\n' >> "$FM_HOME/state/task.status"; expected='open decision' ;;
    fixing) sed 's/status: ci_monitor_interrupted/status: fixing/' "$FM_HOME/nm-status" > "$FM_HOME/nm-next"; mv "$FM_HOME/nm-next" "$FM_HOME/nm-status"; expected='run is active' ;;
    pending-ci) sed 's/status: ci_monitor_interrupted/status: running/' "$FM_HOME/nm-status" > "$FM_HOME/nm-next"; mv "$FM_HOME/nm-next" "$FM_HOME/nm-status"; printf 'current_step: ci\n' >> "$FM_HOME/nm-status"; expected='has not reached CI-ready' ;;
    missing-observer) rm "$FM_HOME/state/contributions.check-trust"; expected='not authenticated and armed' ;;
    stale-observer) sed 's/"checked_at": ".*"/"checked_at": "2000-01-01T00:00:00Z"/' "$FM_HOME/data/task/contributions.json" > "$FM_HOME/next.json"; mv "$FM_HOME/next.json" "$FM_HOME/data/task/contributions.json"; expected='coverage is stale' ;;
    wrong-owner) jq '.task="another-task"' "$FM_HOME/data/task/contributions.json" > "$FM_HOME/next.json"; mv "$FM_HOME/next.json" "$FM_HOME/data/task/contributions.json"; expected='coverage is stale' ;;
    wrong-observer-head) jq '.records[0].observation.head="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"' "$FM_HOME/data/task/contributions.json" > "$FM_HOME/next.json"; mv "$FM_HOME/next.json" "$FM_HOME/data/task/contributions.json"; expected='coverage is stale' ;;
    wrong-pr-head) printf '{"state":"open","head":{"sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}\n' > "$FM_HOME/forge-pr.json"; expected='published PR head differs' ;;
    unpublished) sed 's/pr,completed/pr,pending/' "$FM_HOME/nm-status" > "$FM_HOME/nm-next"; mv "$FM_HOME/nm-next" "$FM_HOME/nm-status"; expected='publication are not completed' ;;
    wrong-branch) sed 's/branch: .*/branch: another-task/' "$FM_HOME/nm-status" > "$FM_HOME/nm-next"; mv "$FM_HOME/nm-next" "$FM_HOME/nm-status"; expected='does not name the task branch' ;;
    gate) printf 'gate:\n  status: awaiting_approval\n' >> "$FM_HOME/nm-status"; expected='validation gate or fix round' ;;
    fix-round) printf '  active_steps[1]{step,status}:\n    review,fixing,\n' >> "$FM_HOME/nm-status"; expected='validation gate or fix round' ;;
  esac
  if park_nm park task 'CI-only wait' > "$FM_HOME/refusal.out" 2>&1; then fail "$refusal must refuse"; fi
  assert_absent "$FM_HOME/state/task.park" "$refusal retains the worker slot"
  assert_grep "$expected" "$FM_HOME/refusal.out" "$refusal names its exact refusal"
done
fixture
touch "$FM_HOME/exit-fails"
if bash "$PARK" auto task; then fail 'unverified exit must fail'; fi
assert_grep 'phase=parking' "$FM_HOME/state/task.park" 'unverified exit never publishes parked'
fixture
printf 'paused: waiting on upstream maintainer\n' > "$FM_HOME/state/task.status"
bash "$PARK" auto task >/dev/null
assert_grep 'phase=parked' "$FM_HOME/state/task.park" 'upstream wait parks without a deadline'
for wait in 'merge bot' 'merge queue' 'captain review' 'CI-only'; do
  fixture
  printf 'paused: awaiting %s\n' "$wait" > "$FM_HOME/state/task.status"
  bash "$PARK" auto task >/dev/null
  assert_grep 'phase=parked' "$FM_HOME/state/task.park" "$wait parks"
done
fixture
printf 'paused: external service until 2099-01-01T00:00Z\n' > "$FM_HOME/state/task.status"
bash "$PARK" auto task >/dev/null
assert_grep 'phase=parked' "$FM_HOME/state/task.park" 'long declared deadline parks'
for reason in 'merge word answered' 'red CI' 'new upstream review' 'decision answered'; do
  fixture
  bash "$PARK" auto task >/dev/null
  touch "$FM_HOME/full"
  rc=0
  bash "$PARK" wake task "$reason" >/dev/null || rc=$?
  assert_equals "$rc" 75 'full capacity defers resume'
  assert_grep 'phase=queued' "$FM_HOME/state/task.park" 'request survives cap deferral'
  rm "$FM_HOME/full"
  bash "$PARK" tick >/dev/null
  assert_grep 'phase=active' "$FM_HOME/state/task.park" 'relaunch releases request only after success'
  assert_grep "$reason" "$FM_HOME/control.log" 'auto-generated note carries wake reason'
  assert_equals "$(cat "$FM_HOME/agent")" alive 'resumed process is alive'
done
fixture
bash "$PARK" auto task >/dev/null
bash "$PARK" tick >/dev/null
assert_grep 'phase=parked' "$FM_HOME/state/task.park" 'unchanged wait stays parked'
printf 'resolved: wait cleared\n' >> "$FM_HOME/state/task.status"
bash "$PARK" tick >/dev/null
assert_grep 'task status changed' "$FM_HOME/control.log" 'cleared pause relaunches with reason'
fixture
bash "$PARK" auto task >/dev/null
mkdir -p "$FM_HOME/state/task.inbox"
printf 'steer\n' > "$FM_HOME/state/task.inbox/1.msg"
bash "$PARK" tick >/dev/null
assert_grep 'phase=active' "$FM_HOME/state/task.park" 'pending inbox steering resumes a parked worker'
assert_grep 'steering waiting in the instruction inbox' "$FM_HOME/control.log" 'inbox resume carries its reason'
fixture
touch "$FM_HOME/steer-on-exit"
bash "$PARK" auto task >/dev/null
assert_grep 'phase=queued' "$FM_HOME/state/task.park" 'steering during exit cannot be overwritten'
assert_present "$FM_HOME/state/task.inbox/1.msg" 'steering survives park'
fixture
bash "$PARK" auto task >/dev/null
touch "$FM_HOME/resume-fails"
rc=0
bash "$PARK" wake task 'new work' >/dev/null || rc=$?
assert_equals "$rc" 1 'lifecycle failure is reported'
assert_grep 'resume_error=1' "$FM_HOME/state/task.park" 'failed resume stays parked for repair'
assert_grep 'could not resume' "$FM_HOME/state/.wake-queue" 'resume failure wakes supervision'
rm "$FM_HOME/resume-fails"
bash "$PARK" wake task 'lifecycle repaired' >/dev/null
assert_grep 'phase=active' "$FM_HOME/state/task.park" 'explicit retry clears the repair hold'
# fm-send holds the lease-command lock across the steer, so it may only queue
# the resume; the watcher tick relaunches once the lock is free.
fixture
bash "$PARK" auto task >/dev/null
rc=0
FM_SUPERVISION_ACTOR=main bash "$TMP_ROOT/bin/fm-send.sh" task 'review feedback: fix the null check' >/dev/null 2>&1 || rc=$?
assert_equals "$rc" 0 'steering a parked worker under the lease guard succeeds'
assert_present "$FM_HOME/state/task.inbox/001.msg" 'steer is durably recorded'
assert_grep 'phase=queued' "$FM_HOME/state/task.park" 'steer queues the parked worker'
if grep -q 'relaunch' "$FM_HOME/control.log"; then fail 'fm-send must not relaunch while it holds the lease lock'; fi
FM_SUPERVISION_ACTOR=main bash "$PARK" tick >/dev/null
assert_grep 'phase=active' "$FM_HOME/state/task.park" 'watcher tick resumes the steered worker'
assert_grep 'steering received' "$FM_HOME/control.log" 'resume note names the steer'
RED='["windows / integration"]'
RED_PLUS='["lint","windows / integration"]'
# Park a worker whose record already names the red checks it was last woken
# for, the state a resumed-and-re-parked worker returns to.
park_with_red() { # <canonical failing set>
  fixture
  bash "$PARK" auto task >/dev/null
  bash "$PARK" request task 'checks failed' "$1" >/dev/null
  bash "$PARK" tick >/dev/null
  printf 'done: PR %s checks green (rechecked)\n' "$URL" >> "$FM_HOME/state/task.status"
  bash "$PARK" auto task >/dev/null
}
park_with_red "$RED"
assert_grep 'phase=parked' "$FM_HOME/state/task.park" 'a resumed worker parks again'
assert_grep "failing_checks=$RED" "$FM_HOME/state/task.park" 'the red set survives the resume and the next park'
bash "$PARK" request task 'checks failed' "$RED"
assert_grep 'phase=parked' "$FM_HOME/state/task.park" 'an unchanged red set never wakes the worker again'
bash "$PARK" request task 'checks failed' "$RED_PLUS"
assert_grep 'phase=queued' "$FM_HOME/state/task.park" 'a newly failing check wakes the worker'
assert_grep "failing_checks=$RED_PLUS" "$FM_HOME/state/task.park" 'the wake records the red set it acted on'
park_with_red "$RED"
bash "$PARK" request task 'merge word answered'
assert_grep 'phase=queued' "$FM_HOME/state/task.park" 'a resume naming no red set is unaffected by the recorded one'
# A record written before the field existed proves nothing about its red set.
fixture
bash "$PARK" auto task >/dev/null
grep -v '^failing_checks=' "$FM_HOME/state/task.park" > "$FM_HOME/legacy.park"
mv "$FM_HOME/legacy.park" "$FM_HOME/state/task.park"
bash "$PARK" request task 'checks failed' "$RED"
assert_grep 'phase=queued' "$FM_HOME/state/task.park" 'a park record with no recorded red set still resumes'
fixture
bash "$PARK" auto task >/dev/null
bash "$PARK" request task 'forge reports merged' '' "$URL|merged"
bash "$PARK" tick >/dev/null
printf 'done: PR %s checks green (rechecked)\n' "$URL" >> "$FM_HOME/state/task.status"
bash "$PARK" auto task >/dev/null
bash "$PARK" request task 'forge reports merged' '' "$URL|merged"
assert_grep 'phase=parked' "$FM_HOME/state/task.park" 'two observers cannot spend a second slot for the same terminal PR event'
pass 'verified parking, safety exceptions, external waits, durable resume reasons and the unchanged-red-set gate'
