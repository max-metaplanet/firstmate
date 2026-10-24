# Appended after the fixture helpers of tests/fm-secondmate-restart.test.sh
# (functions only). Reproduces the 2026-10-23 incident in a disposable home:
# parked secondmate + full fleet + fire-and-forget CONFIG_REREAD from a
# config-push caller holding the inheritance lock, while firstmate keeps
# steering another live mate.
sc_bounded() {  # <secs> <cmd...>: run in its own process group; 124 on timeout
  local secs=$1; shift
  python3 - "$secs" "$@" <<'PY'
import os, signal, subprocess, sys, time
secs = float(sys.argv[1]); t0 = time.time()
p = subprocess.Popen(sys.argv[2:], start_new_session=True)
try:
    rc = p.wait(timeout=secs)
except subprocess.TimeoutExpired:
    os.killpg(p.pid, signal.SIGKILL); p.wait(); rc = 124
print("elapsed=%.2fs rc=%d" % (time.time() - t0, rc), file=sys.stderr)
sys.exit(rc)
PY
}
sc_env() { env PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_FAKE_DIR="$dir/fake" FM_SPAWN_NO_GUARD=1 FM_SUPERVISION_ACTOR=main FM_FAKE_CAPTURE_LAUNCH=1 "$@"; }
launches() { grep -c "export FM_TASK_INBOX=.*sm1.inbox" "$dir/fake/literal"; }
log() { printf '%s\n' "$*"; }

dir=$(new_case incident); add_park_mate "$dir"; arm_answer "$dir" sm1
add_local_mate "$dir" sm2
printf '%s\n' "- sm2 - Live mate (home: $dir/sm2-home; scope: tests; projects: none; added 2026-10-09)" >> "$dir/home/data/secondmates.md"
out=$(run_park "$dir" sm1 park); rc=$?
log "## setup: park sm1 -> rc=$rc"; grep '^phase=' "$dir/home/state/.secondmate-park-sm1"
printf '2\n' > "$dir/home/config/fleet-capacity"
printf 'kind=ship\nbackend=tmux\nwindow=fmses:fm-holder\n' > "$dir/home/state/holder.meta"
printf 'fm-holder\n' >> "$dir/fake/windows"
lock="$dir/sm1-home/state/.fm-inherited-config.lock"; mkdir "$lock"; printf '%s\n' "$$" > "$lock/pid"
log "## fleet-capacity=2, held by live ship 'holder' + live mate sm2; config-push caller holds $lock"

log "## S1: fm-send sm1 --fire-and-forget CONFIG_REREAD (observed trigger), concurrently fm-send sm2 'steer'"
( sc_bounded 30 env PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_FAKE_DIR="$dir/fake" FM_SPAWN_NO_GUARD=1 FM_SUPERVISION_ACTOR=main \
    "$ROOT/bin/fm-send.sh" sm1 --fire-and-forget 0123456789abcdef CONFIG_REREAD > "$dir/s1.out" 2>&1; echo $? > "$dir/s1.rc" ) &
s1=$!
sleep 1
sc_bounded 30 env PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_FAKE_DIR="$dir/fake" FM_SPAWN_NO_GUARD=1 FM_SUPERVISION_ACTOR=main \
    "$ROOT/bin/fm-send.sh" sm2 'unrelated steer to a live mate' > "$dir/s2.out" 2>&1; s2rc=$?
wait "$s1"
log "send->sm1 rc=$(cat "$dir/s1.rc") $(grep elapsed "$dir/s1.out")"
grep -v elapsed "$dir/s1.out" | grep -iE 'park|queued|resume|exited|recovery' | sed 's/^/  sm1> /'
log "send->sm2 rc=$s2rc $(grep elapsed "$dir/s2.out")"
log "lease-command lock after sends: $([ -e "$dir/home/state/.fm-lease-command.lock" ] && echo PRESENT || echo released)"
log "sm1 inbox: $(ls "$dir/home/state/sm1.inbox" 2>/dev/null | tr '\n' ' ') ; CONFIG_REREAD queued: $(grep -l CONFIG_REREAD "$dir"~/sm1.inbox/*.msg 2>/dev/null | wc -l | tr -d ' ')"
log "sm2 inbox has steer: $(grep -l 'unrelated steer' "$dir"~/sm2.inbox/*.msg 2>/dev/null | wc -l | tr -d ' ')"
grep '^phase=' "$dir/home/state/.secondmate-park-sm1"
rm "$lock/pid"; rmdir "$lock"

log "## S2: watcher worker-park ticks while the fleet stays full"
before=$(launches)
for i in 1 2 3 4; do
  sc_bounded 30 env PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_FAKE_DIR="$dir/fake" FM_SPAWN_NO_GUARD=1 FM_SUPERVISION_ACTOR=main FM_FAKE_CAPTURE_LAUNCH=1 \
    "$ROOT/bin/fm-worker-park.sh" tick > "$dir/t$i.out" 2>&1; rc=$?
  log "tick $i rc=$rc $(grep elapsed "$dir/t$i.out") phase=$(sed -n 's/^phase=//p' "$dir/home/state/.secondmate-park-sm1" 2>/dev/null)"
done
log "sm1 launch commands while full: $(( $(launches) - before ))"
log "locks left in home state: $(find "$dir/home/state" -maxdepth 1 -name '*.lock' | wc -l | tr -d ' ')"
log "direct unpark while full:"; sc_bounded 30 env PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_FAKE_DIR="$dir/fake" FM_SPAWN_NO_GUARD=1 \
    "$ROOT/bin/fm-secondmate-park.sh" sm1 unpark 2>&1 | sed 's/^/  /'; log "  unpark rc=${PIPESTATUS[0]}"

log "## S3: slot frees (holder exits) -> next tick resumes sm1 exactly once"
printf 'zsh' > "$dir/fake/command.fmses:fm-holder"
# the stub models a single endpoint cwd; sm2 setup pointed it at sm2-home
printf '%s' "$dir/sm1-home" > "$dir/fake/cwd"
for i in 5 6; do
  sc_bounded 30 env PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_FAKE_DIR="$dir/fake" FM_SPAWN_NO_GUARD=1 FM_SUPERVISION_ACTOR=main FM_FAKE_CAPTURE_LAUNCH=1 \
    "$ROOT/bin/fm-worker-park.sh" tick > "$dir/t$i.out" 2>&1; rc=$?
  log "tick $i rc=$rc $(grep elapsed "$dir/t$i.out") park-record=$([ -e "$dir/home/state/.secondmate-park-sm1" ] && echo present || echo cleared)"
done
log "sm1 launch commands total: $(( $(launches) - before )) ; 'unpark complete' reports: $(grep -c 'unpark complete' "$dir/home/state/.wake-queue" 2>/dev/null)"
log "CONFIG_REREAD still in durable inbox: $(grep -l CONFIG_REREAD "$dir"~/sm1.inbox/*.msg 2>/dev/null | wc -l | tr -d ' ')"
