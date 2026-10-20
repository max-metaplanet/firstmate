#!/usr/bin/env bash
# Worker park orchestration through its executable API. Lifecycle mechanics
# remain covered by fm-control.test.sh; the control fixture here exposes verified
# success/failure and admission deferral without driving a real worker.
set -u
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
for reason in 'merge word answered' 'red CI' 'new upstream review' 'decision answered' 'merge completed'; do
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
pass 'verified parking, safety exceptions, external waits and durable resume reasons'
