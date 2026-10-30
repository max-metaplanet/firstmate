#!/usr/bin/env bash
# Automatic and attended T3 leader handover through the public CLI, using real lock processes.
set -euo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-t3-home-lib.sh
. "$ROOT/bin/fm-t3-home-lib.sh"
work=$(fm_test_tmproot fm-t3-leader)
helper="$work/home/bin/fm-t3-leader.sh"
mkdir -p "$work/home/state" "$work/home/bin" "$work/home/config" "$work/tools" "$work/base"
git -C "$work/home" init -q
for script in "$ROOT"/bin/*.sh; do ln -s "$script" "$work/home/bin/$(basename "$script")"; done
rm "$work/home/bin/fm-startup-network.sh"
cat > "$work/home/bin/fm-startup-network.sh" <<'NETWORK'
#!/usr/bin/env bash
printf 'network-recovery\n' >> "$TEST_WORK/boot-order"
NETWORK
chmod +x "$work/home/bin/fm-startup-network.sh"
printf 'fixture instructions\n' > "$work/home/AGENTS.md"
ln -s /bin/bash "$work/tools/claude"
export FM_T3_BIN="$work/tools/t3" FM_T3_BASE_DIR="$work/base"
export TEST_ROOT="$ROOT" TEST_HELPER="$helper" TEST_HOME="$work/home" TEST_WORK="$work"
export FM_HOME="$work/home"
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE FM_DATA_OVERRIDE
old_pid='' successor_pid=''
cleanup() {
  [ -z "$old_pid" ] || kill "$old_pid" 2>/dev/null || true
  [ -z "$successor_pid" ] || kill "$successor_pid" 2>/dev/null || true
  [ -z "$old_pid" ] || wait "$old_pid" 2>/dev/null || true
  [ -z "$successor_pid" ] || wait "$successor_pid" 2>/dev/null || true
  fm_test_cleanup
}
trap cleanup EXIT

cat > "$work/driver.sh" <<'DRIVER'
#!/usr/bin/env bash
set -euo pipefail
export CLAUDE_PID=$$ CLAUDE_CODE_SESSION_ID="fixture-$$" CLAUDECODE=1
if [ "$1" = auto-successor ]; then
  export FM_T3_VIEW_ONLY=1
  FM_T3_LEADER_HANDOVER=$(jq -r .nonce "$TEST_HOME/state/.t3-leader-handover.json")
  export FM_T3_LEADER_HANDOVER
fi
if [ "$1" = recovery ]; then
  CLAUDE_CODE_SESSION_ID=$(jq -r .outgoingSession "$TEST_HOME/state/.t3-leader-handover.json")
  export CLAUDE_CODE_SESSION_ID
fi
bash "$TEST_HOME/bin/fm-lock.sh" > "$TEST_WORK/lock-$1"
case "$1" in
  automatic|boot)
    printf 'pid=%s\nharness=claude\nprofile=\nbackend=tmux\ntarget=%%fixture\n' "$$" > "$TEST_HOME/state/.lock-runtime"
    if [ "$1" = boot ]; then
      export FM_T3_LEADER_BOOT=1
      result=0
      bash "$TEST_HELPER" boot > "$TEST_WORK/auto-scheduled" 2>&1 || result=$?
      case "$result" in
        0) printf 'terminal-recovery\n' >> "$TEST_WORK/boot-order" ;;
        10) touch "$TEST_WORK/boot-handover" ;;
        *) exit "$result" ;;
      esac
    else
      bash "$TEST_HELPER" switch --to t3 --model fixture-model --persisted > "$TEST_WORK/auto-scheduled"
    fi
    ;;
  recovery)
    [ "${FM_T3_LEADER_BOOT:-0}" != 1 ] || exit 9
    printf 'restored-terminal-recovery\n' >> "$TEST_WORK/boot-order"
    touch "$TEST_WORK/recovery-ready"
    ;;
  auto-successor)
    FM_HOME="$TEST_HOME" bash "$TEST_HELPER" confirm "$FM_T3_LEADER_HANDOVER"
    ;;
  outgoing)
    bash "$TEST_HELPER" prepare --to t3 --model fixture-model --dry-run > "$TEST_WORK/dry-prepare"
    [ ! -e "$TEST_HOME/state/.t3-leader-handover.json" ]
    if bash "$TEST_HELPER" prepare --to t3 --model fixture-model > "$TEST_WORK/missing-persisted" 2>&1; then exit 9; fi
    [ ! -e "$TEST_HOME/state/.t3-leader-handover.json" ]
    bash "$TEST_HELPER" prepare --to t3 --model fixture-model --persisted > "$TEST_WORK/prepared"
    if bash "$TEST_HELPER" prepare --to terminal --model fixture-model --persisted > "$TEST_WORK/duplicate-prepare" 2>&1; then exit 9; fi
    ;;
  successor)
    nonce=$(jq -r '.nonce' "$TEST_HOME/state/.t3-leader-handover.json")
    if bash "$TEST_HELPER" confirm wrong-nonce > "$TEST_WORK/wrong-confirm" 2>&1; then exit 9; fi
    bash "$TEST_HELPER" confirm "$nonce" > "$TEST_WORK/confirmed"
    bash "$TEST_HELPER" prepare --to terminal --model fixture-model --dry-run > "$TEST_WORK/dry-reverse"
    bash "$TEST_HELPER" prepare --to terminal --model fixture-model --persisted > "$TEST_WORK/reverse-prepared"
    jq -e '.version == 1 and .location == "t3" and .model == "fixture-model"' "$TEST_HOME/config/leader-preference.json" >/dev/null
    ;;
esac
touch "$TEST_WORK/$1-ready"
while :; do sleep 0.1; done
DRIVER
cat > "$work/tools/t3" <<'T3'
#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
work = Path(os.environ['TEST_WORK'])
with (work / 't3-calls').open('a') as file:
    file.write(json.dumps(sys.argv[1:]) + '\n')
if sys.argv[1:3] == ['project', 'add']:
    if (work / 'existing-project').exists():
        print("ProjectAlreadyExistsError: An active project already exists for '" + sys.argv[3] + "'", file=sys.stderr)
        sys.exit(1)
    if (work / 'project-failure').exists():
        print('permission denied', file=sys.stderr)
        sys.exit(1)
    print('Added fixture project')
elif sys.argv[1:3] == ['thread', 'start']:
    (work / 'launch-prompt').write_text(sys.stdin.read())
    if (work / 'auto-confirm').exists():
        import subprocess
        child = subprocess.Popen([str(work / 'tools/claude'), str(work / 'driver.sh'), 'auto-successor'],
                                 stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                 env={k:v for k,v in os.environ.items() if k not in (
                                     'CLAUDE_PID','CLAUDE_CODE_SESSION_ID','FM_HOME','FM_ROOT',
                                     'FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE',
                                     'FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE')})
        (work / 'auto-successor-pid').write_text(str(child.pid))
    print(json.dumps({'threadId':'fixture-thread','projectId':'fixture-project','runId':'fixture-run'}))
else:
    sys.exit(4)
T3
chmod +x "$work/tools/t3"

expect_failure() { if "$@" > "$work/failure" 2>&1; then fail "unexpected success: $*"; fi; }
await_file() {
  local attempts=0
  while [ "$attempts" -lt 200 ]; do
    [ ! -f "$1" ] || return 0
    attempts=$((attempts + 1))
    sleep 0.1
  done
  fail "fixture never published $1"
}

binding_home="$work/binding-home"
mkdir -p "$binding_home"
git -C "$binding_home" init -q
fm_t3_bind_claude_home "$binding_home" --dry-run
[ ! -e "$binding_home/.claude" ] || fail 'home-binding dry-run created settings directory'
fm_t3_bind_claude_home "$binding_home"
[ ! -e "$binding_home/.claude" ] || fail 'native binding created unnecessary local settings'
mkdir "$binding_home/.claude"
settings="$binding_home/.claude/settings.local.json"
cat > "$settings" <<'SETTINGS'
{"permissions":{"allow":["Bash(git status:*)"],"defaultMode":"default"},"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"fixture-command"}]}]},"env":{"CUSTOM_FIXTURE":"keep-me"},"unknown":{"nested":[1,true,"retained"]}}
SETTINGS
cp "$settings" "$work/settings-original"
fm_t3_bind_claude_home "$binding_home" --dry-run
cmp "$settings" "$work/settings-original" || fail 'home-binding dry-run changed existing settings'
fm_t3_bind_claude_home "$binding_home"
jq -e --slurpfile original "$work/settings-original" '. == $original[0]' "$settings" >/dev/null \
  || fail 'native binding added routing keys or changed unrelated settings'
cp "$settings" "$work/settings-bound"
fm_t3_bind_claude_home "$binding_home"
cmp "$settings" "$work/settings-bound" || fail 'repeated native home binding did not converge'
pass 'primary checkout binding leaves no routing env for linked worktrees to inherit'

for route in FM_HOME FM_ROOT FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE; do
  jq --arg route "$route" '.env[$route] = "previous-home"' "$work/settings-original" > "$settings"
  cp "$settings" "$work/settings-legacy"
  fm_t3_bind_claude_home "$binding_home" --dry-run
  cmp "$settings" "$work/settings-legacy" || fail "dry-run changed legacy route $route"
  fm_t3_bind_claude_home "$binding_home"
  jq -e --slurpfile original "$work/settings-original" '. == $original[0]' "$settings" >/dev/null \
    || fail "migration retained route $route or changed unrelated settings"
done
pass 'legacy native routing migrates without changing permissions, hooks, unknown keys or unrelated env'

mkdir -p "$binding_home/bin"
for script in "$ROOT"/bin/*.sh; do ln -s "$script" "$binding_home/bin/$(basename "$script")"; done
env -u FM_HOME -u FM_ROOT -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE \
  -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE bash "$binding_home/bin/fm-lock.sh" status > "$work/default-home-status"
[ -d "$binding_home/state" ] || fail 'native leader without routing env did not resolve its checkout home'
assert_contains "$(cat "$work/default-home-status")" 'lock: free' 'checkout default must inspect its own lock'
pass 'native primary checkout scripts resolve their own home without settings env'

for invalid in '' '{"env":' 'null' '[]' '{"env":[]}' '{"env":"bad"}'; do
  printf '%s\n' "$invalid" > "$settings"
  cp "$settings" "$work/settings-invalid"
  expect_failure fm_t3_bind_claude_home "$binding_home"
  cmp "$settings" "$work/settings-invalid" || fail 'binding replaced malformed settings'
done
pass 'malformed settings refuse without replacing the original file'

mkdir -p "$work/binding-target" "$work/symlink-directory-home" "$work/symlink-file-home/.claude"
printf '{"env":{"CUSTOM_FIXTURE":"untouched"}}\n' > "$work/binding-target/settings.local.json"
cp "$work/binding-target/settings.local.json" "$work/symlink-original"
ln -s "$work/binding-target" "$work/symlink-directory-home/.claude"
ln -s "$work/binding-target/settings.local.json" "$work/symlink-file-home/.claude/settings.local.json"
expect_failure fm_t3_bind_claude_home "$work/symlink-directory-home"
expect_failure fm_t3_bind_claude_home "$work/symlink-file-home"
cmp "$work/binding-target/settings.local.json" "$work/symlink-original" || fail 'binding mutated a symlink target'
[ -L "$work/symlink-directory-home/.claude" ] && [ -L "$work/symlink-file-home/.claude/settings.local.json" ] || fail 'binding replaced a settings symlink'
pass 'symlinked Claude settings directories and files are refused without touching their targets'

expect_failure env -u FM_HOME bash "$helper" status
printf 'parent-owned\n' > "$work/home/.fm-secondmate-home"
expect_failure bash "$helper" status
assert_contains "$(cat "$work/failure")" 'parent-owned' 'secondmate placement must stay with the parent'
rm "$work/home/.fm-secondmate-home"
expect_failure bash "$helper" prepare --to t3 --model fixture-model --dry-run
[ ! -e "$work/home/state/.t3-leader-handover.json" ] || fail 'foreign prepare created a record'
pass 'handover requires explicit home and current lock ownership'

env -u CLAUDE_PID -u CLAUDE_CODE_SESSION_ID "$work/tools/claude" "$work/driver.sh" outgoing > "$work/outgoing-log" 2>&1 &
old_pid=$!
await_file "$work/outgoing-ready"
[ ! -e "$work/home/config/leader-preference.json" ] || fail 'prepare wrote a preference before completed handover'
assert_contains "$(cat "$work/dry-prepare")" dry-run 'prepare dry-run is explicit'
assert_contains "$(cat "$work/missing-persisted")" 'before handover' 'conversation persistence must be acknowledged'
assert_contains "$(cat "$work/duplicate-prepare")" 'unfinished handover' 'pending handover cannot be replaced'
expect_failure bash "$helper" activate --dry-run
assert_contains "$(cat "$work/failure")" 'still exists' 'live outgoing leader must refuse activation'
[ ! -e "$work/t3-calls" ] || fail 'live outgoing leader contacted T3'
expect_failure bash "$helper" prepare --to t3 --model fixture-model --persisted
pass 'prepare dry-run does not mutate, and a live outgoing leader blocks activation'

kill "$old_pid"
wait "$old_pid" 2>/dev/null || true
old_pid=''
expect_failure bash "$helper" activate --dry-run
assert_contains "$(cat "$work/failure")" 'supervision-host-off' 'unverified default supervision host must refuse forward activation'
touch "$work/home/config/supervision-host-off"
mkdir "$work/home/.claude"
jq '.env += {FM_HOME:"previous-home", FM_ROOT:"previous-home", FM_ROOT_OVERRIDE:"previous-code", FM_STATE_OVERRIDE:"previous-state", FM_DATA_OVERRIDE:"previous-data", FM_CONFIG_OVERRIDE:"previous-config", FM_PROJECTS_OVERRIDE:"previous-projects"}' \
  "$work/settings-original" > "$work/home/.claude/settings.local.json"
cp "$work/home/.claude/settings.local.json" "$work/activation-legacy"
bash "$helper" activate --dry-run > "$work/dry-activate"
cmp "$work/home/.claude/settings.local.json" "$work/activation-legacy" || fail 'activation dry-run changed legacy native settings'
[ ! -e "$work/t3-calls" ] || fail 'activation dry-run contacted T3'
[ "$(jq -r .phase "$work/home/state/.t3-leader-handover.json")" = prepared ] || fail 'activation dry-run changed phase'
bash "$helper" activate > "$work/activated"
jq -e --slurpfile original "$work/settings-original" '. == $original[0]' "$work/home/.claude/settings.local.json" >/dev/null \
  || fail 'activation did not remove legacy routing while preserving unrelated settings'
jq -e '.phase == "starting" and .threadId == "fixture-thread" and .projectId == "fixture-project"' "$work/home/state/.t3-leader-handover.json" >/dev/null
expect_failure bash "$helper" activate
[ "$(wc -l < "$work/t3-calls")" -eq 2 ] || fail 'repeat activation launched another thread'
python3 - "$work/t3-calls" "$work/home" <<'PY'
import json, sys
calls = [json.loads(line) for line in open(sys.argv[1])]
assert calls[0][:3] == ['project', 'add', sys.argv[2]]
assert calls[1][:4] == ['thread', 'start', sys.argv[2], '-']
assert calls[1][calls[1].index('--provider') + 1] == 'claudeAgent'
assert calls[1][calls[1].index('--model') + 1] == 'fixture-model'
PY
expect_failure bash "$helper" confirm "$(jq -r .nonce "$work/home/state/.t3-leader-handover.json")"
pass 'activation is one-shot, binds the Firstmate project and Claude model, and needs successor ownership'

env -u CLAUDE_PID -u CLAUDE_CODE_SESSION_ID "$work/tools/claude" "$work/driver.sh" successor > "$work/successor-log" 2>&1 &
successor_pid=$!
await_file "$work/successor-ready"
assert_contains "$(cat "$work/confirmed")" 'handover confirmed' 'successor proves its exclusive lock'
assert_contains "$(cat "$work/wrong-confirm")" 'does not match' 'wrong nonce is refused'
assert_contains "$(cat "$work/dry-reverse")" 'Claude terminal' 'reverse dry-run names terminal'
expect_failure bash "$helper" activate
kill "$successor_pid"
wait "$successor_pid" 2>/dev/null || true
successor_pid=''

mkdir -p "$work/terminal"
cat > "$work/terminal/claude" <<'TERMINAL'
#!/usr/bin/env bash
exec "$TEST_WORK/tools/claude" "$TEST_WORK/terminal-driver.sh" "$@"
TERMINAL
cat > "$work/terminal-driver.sh" <<'TERMINAL'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$PWD" "$@" > "$TEST_WORK/terminal-args"
export CLAUDE_PID=$$ CLAUDE_CODE_SESSION_ID="terminal-$$" CLAUDECODE=1
bash "$TEST_ROOT/bin/fm-lock.sh" > "$TEST_WORK/terminal-lock"
nonce=$(jq -r '.nonce' "$TEST_HOME/state/.t3-leader-handover.json")
bash "$TEST_HELPER" confirm "$nonce" > "$TEST_WORK/terminal-confirmed"
TERMINAL
chmod +x "$work/terminal/claude"
FM_T3_LEADER_CLAUDE_BIN="$work/terminal/claude" bash "$helper" activate > "$work/terminal-output"
jq -e '.phase == "confirmed" and .destination == "terminal" and .successorPid != .outgoingPid' "$work/home/state/.t3-leader-handover.json" >/dev/null
assert_contains "$(cat "$work/terminal-args")" "$work/home" 'terminal launch starts in the Firstmate home'
bash "$helper" status > "$work/status"
if jq -e 'has("nonce")' "$work/status" >/dev/null; then fail 'status exposes private handover nonce'; fi
[ ! -e "$work/home/config/leader-preference.json" ] || fail 'completed reverse handover retained T3 preference'
pass 'reverse handover waits for T3 leader exit and confirms a new terminal Claude lock owner'

printf '999999999\n' > "$work/home/state/.lock"
jq '.phase="prepared" | .outgoingPid=999999999' "$work/home/state/.t3-leader-handover.json" > "$work/staged"
mv "$work/staged" "$work/home/state/.t3-leader-handover.json"
sleep 30 &
competitor=$!
printf '%s\n' "$competitor" > "$work/home/state/.lock"
expect_failure bash "$helper" activate --dry-run
kill "$competitor"
wait "$competitor" 2>/dev/null || true
assert_contains "$(cat "$work/failure")" 'home is not free' 'unknown live lock owner must refuse activation'
[ "$(wc -l < "$work/t3-calls")" -eq 2 ] || fail 'competing owner contacted T3'
pass 'a third live process holding the lock is never replaced or treated as stale'

# No live T3 or tmux operations: the fake rejects duplicate registration but
# accepts a thread start in the same workspace, just as the CLI does.
printf '999999999\n' > "$work/home/state/.lock"
export PATH="$work/tools:$PATH"
cat > "$work/tools/tmux" <<'TMUX'
#!/usr/bin/env bash
set -euo pipefail
case "$1" in
  display-message) printf '%%fixture\n' ;;
  respawn-pane)
    printf '%s\n' "$@" > "$TEST_WORK/tmux-recovery-args"
    bash -c "$5" </dev/null > "$TEST_WORK/recovery-log" 2>&1 &
    echo "$!" > "$TEST_WORK/recovery-pid"
    ;;
  *) exit 4 ;;
esac
TMUX
cat > "$work/tools/recovery-claude" <<'RECOVERY'
#!/usr/bin/env bash
exec "$TEST_WORK/tools/claude" "$TEST_WORK/driver.sh" recovery
RECOVERY
chmod +x "$work/tools/tmux" "$work/tools/recovery-claude"
export FM_T3_LEADER_CLAUDE_BIN="$work/tools/recovery-claude"
export FM_T3_LEADER_DELAY=1 FM_T3_LEADER_EXIT_TIMEOUT=10 FM_T3_LEADER_CONFIRM_TIMEOUT=3

cat > "$work/tools/systemctl" <<'SYSTEMCTL'
#!/usr/bin/env bash
[ "$*" = '--user is-active --quiet t3-lima.service' ] || exit 9
printf 'service-check\n' >> "$TEST_WORK/boot-order"
[ ! -e "$TEST_WORK/service-down" ]
SYSTEMCTL
chmod +x "$work/tools/systemctl"

for scenario in absent service-down switch-failure malformed; do
  rm -f "$work/home/state/.t3-leader-handover.json" "$work/boot-order" "$work/boot-ready" "$work/auto-scheduled" "$work/boot-handover"
  if [ "$scenario" != absent ]; then
    printf '{"version":1,"location":"t3","model":"fixture-model"}\n' > "$work/home/config/leader-preference.json"
  fi
  case "$scenario" in
    service-down) touch "$work/service-down" ;;
    switch-failure) rm "$work/home/config/supervision-host-off" ;;
    malformed) printf 'invalid\n' > "$work/home/config/leader-preference.json" ;;
  esac
  env -u CLAUDE_PID -u CLAUDE_CODE_SESSION_ID "$work/tools/claude" "$work/driver.sh" boot > "$work/boot-log" 2>&1 &
  old_pid=$!
  await_file "$work/boot-ready"
  [ ! -e "$work/boot-handover" ] || fail 'fallback scheduled a handover'
  [ ! -e "$work/home/state/.t3-leader-handover.json" ] || fail 'fallback prepared a handover'
  assert_contains "$(cat "$work/boot-order")" 'network-recovery' 'fallback resumes deferred startup recovery'
  assert_contains "$(cat "$work/boot-order")" 'terminal-recovery' 'fallback continues terminal recovery'
  if [ "$scenario" = absent ]; then
    assert_not_contains "$(cat "$work/boot-order")" 'service-check' 'no preference must not query systemd'
  else
    assert_contains "$(cat "$work/auto-scheduled")" 'preferred leader fallback' 'fallback explains the failure'
  fi
  kill "$old_pid"
  wait "$old_pid" 2>/dev/null || true
  old_pid=''
  rm -f "$work/service-down" "$work/home/config/leader-preference.json"
  touch "$work/home/config/supervision-host-off"
  pass "boot $scenario continues terminal recovery"
done

for scenario in existing-project project-failure unconfirmed; do
  rm -f "$work/home/state/.t3-leader-handover.json" "$work/auto-scheduled" "$work/automatic-ready" "$work/recovery-ready" "$work/t3-calls"
  touch "$work/$scenario"
  printf '{"version":1,"location":"t3","model":"fixture-model"}\n' > "$work/home/config/leader-preference.json"
  rm -f "$work/boot-order" "$work/boot-handover" "$work/boot-ready"
  env -u CLAUDE_PID -u CLAUDE_CODE_SESSION_ID "$work/tools/claude" "$work/driver.sh" boot > "$work/automatic-log" 2>&1 &
  old_pid=$!
  await_file "$work/auto-scheduled"
  if [ "$scenario" = existing-project ]; then
    # This is the counterfactual for the duplicate-registration incident: the
    # thread launches successfully, then an unconfirmed successor times out.
    await_file "$work/launch-prompt"
  fi
  wait "$old_pid" 2>/dev/null || true
  old_pid=''
  await_file "$work/recovery-ready"
  assert_not_contains "$(cat "$work/boot-order")" 'network-recovery' 'boot must defer secondmate recovery until successor selection'
  assert_not_contains "$(cat "$work/boot-order")" $'\nterminal-recovery' 'boot must not recover while handover is scheduled'
  assert_contains "$(cat "$work/boot-order")" 'restored-terminal-recovery' 'failed switch restores terminal recovery'
  successor_pid=$(cat "$work/recovery-pid")
  [ "$(cat "$work/home/state/.lock")" = "$successor_pid" ] || fail 'recovery did not restore the terminal lock owner'
  assert_contains "$(cat "$work/tmux-recovery-args")" '%fixture' 'recovery targets the original tmux pane'
  assert_contains "$(cat "$work/tmux-recovery-args")" '--resume fixture-' 'recovery resumes the recorded Claude session'
  if [ "$scenario" = existing-project ]; then
    assert_contains "$(cat "$work/t3-calls")" 'thread' 'existing project reuse reaches thread launch'
  fi
  # Wait for the detached completion to verify the recovered session and
  # release its lock before stopping this fixture or starting the next case.
  for ((attempt=0; attempt<200; attempt++)); do
    [ ! -d "$work/home/state/.t3-leader-completion.lock" ] && break
    sleep 0.1
  done
  jq -e '.phase == "restored"' "$work/home/state/.t3-leader-handover.json" >/dev/null || fail 'recovery was not confirmed'
  kill "$successor_pid"
  successor_pid=''
  rm -f "$work/$scenario"
  pass "automatic $scenario failure restores the original terminal leader"
done

# The success path claims through the exact nonce, confirms and retains the T3
# successor rather than running recovery.
rm -f "$work/home/state/.t3-leader-handover.json" "$work/auto-scheduled" "$work/tmux-recovery-args"
touch "$work/auto-confirm" "$work/existing-project"
printf '{"version":1,"location":"t3","model":"fixture-model"}\n' > "$work/home/config/leader-preference.json"
rm -f "$work/boot-order" "$work/boot-handover" "$work/boot-ready"
env -u CLAUDE_PID -u CLAUDE_CODE_SESSION_ID "$work/tools/claude" "$work/driver.sh" boot > "$work/automatic-log" 2>&1 &
old_pid=$!
await_file "$work/auto-scheduled"
wait "$old_pid" 2>/dev/null || true
old_pid=''
await_file "$work/auto-successor-ready"
successor_pid=$(cat "$work/auto-successor-pid")
jq -e '.phase == "confirmed"' "$work/home/state/.t3-leader-handover.json" >/dev/null || fail 'automatic handover never confirmed'
[ ! -e "$work/tmux-recovery-args" ] || fail 'confirmed handover ran recovery'
[ "$(cat "$work/boot-order")" = service-check ] || fail 'boot recovered workers before T3 selection'
jq -e '.model == "fixture-model" and .location == "t3"' "$work/home/config/leader-preference.json" >/dev/null
pass 'T3 successor without routing env resolves the primary home and confirms without recovery'
kill "$successor_pid"
successor_pid=''

# A view-only thread cannot take even a vacant lock, run bootstrap, or create
# the runtime-bound startup marker directory. Test both entry points directly.
readonly_home="$work/view-only"
mkdir -p "$readonly_home"
expect_failure env FM_HOME="$readonly_home" FM_T3_VIEW_ONLY=1 bash "$ROOT/bin/fm-lock.sh"
assert_contains "$(cat "$work/failure")" 'view-only' 'view-only lock refusal is explicit'
env FM_HOME="$readonly_home" FM_T3_VIEW_ONLY=1 bash "$ROOT/bin/fm-session-start.sh" > "$work/view-only-start"
assert_contains "$(cat "$work/view-only-start")" 'T3 VIEW-ONLY' 'view-only startup is read-only'
[ ! -e "$readonly_home/state" ] || fail 'view-only startup mutated state'
env FM_HOME="$readonly_home" FM_T3_VIEW_ONLY=1 bash "$ROOT/bin/fm-sessionstart-run.sh" --source startup > "$work/view-only-hook"
assert_contains "$(cat "$work/view-only-hook")" 'T3 VIEW-ONLY' 'view-only native hook is read-only'
[ ! -e "$readonly_home/state" ] || fail 'view-only native hook mutated state'
# Also prove automatic detection with a T3-shaped ancestor and no env marker.
cp "$work/tools/t3" "$work/t3-fake-saved"
rm "$work/tools/t3"
ln -s /bin/bash "$work/tools/t3"
# shellcheck disable=SC2016 # Expanded by the fixture shell.
env -u FM_T3_VIEW_ONLY FM_HOME="$readonly_home" "$work/tools/t3" -c 'bash "$TEST_ROOT/bin/fm-lock.sh"; exit "$?"' > "$work/view-only-ancestry" 2>&1 && fail 'T3 ancestor acquired the lock'
[ ! -e "$readonly_home/state" ] || fail 'T3 ancestor created lock state'
pass 'view-only marker and T3 process ancestry refuse the lock before any startup mutation'

mkdir -p "$readonly_home/bin"
printf 'seeded-secondmate\n' > "$readonly_home/.fm-secondmate-home"
# Keep the fixture shell alive across lock acquisition: a final external
# command in bash -c may replace it and lose the fake Claude ancestor.
# shellcheck disable=SC2016 # Expanded by the fixture shell.
env -u CLAUDE_PID -u CLAUDE_CODE_SESSION_ID FM_HOME="$readonly_home" FM_T3_VIEW_ONLY=1 "$work/tools/claude" -c '
  export CLAUDE_PID=$$ CLAUDE_CODE_SESSION_ID=fixture-secondmate CLAUDECODE=1
  bash "$TEST_ROOT/bin/fm-lock.sh" || exit "$?"
  [ "$(cat "$FM_HOME/state/.lock")" = "$$" ]
' > "$work/secondmate-lock"
assert_contains "$(cat "$work/secondmate-lock")" 'lock acquired' 'seeded secondmate keeps its startup contract'
pass 'seeded secondmates retain their parent-owned startup path'
