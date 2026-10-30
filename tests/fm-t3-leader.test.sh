#!/usr/bin/env bash
# Attended T3 leader handover through the public CLI, using real lock processes.
set -euo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-t3-home-lib.sh
. "$ROOT/bin/fm-t3-home-lib.sh"
work=$(fm_test_tmproot fm-t3-leader)
helper="$ROOT/bin/fm-t3-leader.sh"
mkdir -p "$work/home/state" "$work/home/bin" "$work/home/config" "$work/tools" "$work/base"
git -C "$work/home" init -q
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
bash "$TEST_ROOT/bin/fm-lock.sh" > "$TEST_WORK/lock-$1"
case "$1" in
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
    print('Added fixture project')
elif sys.argv[1:3] == ['thread', 'start']:
    (work / 'launch-prompt').write_text(sys.stdin.read())
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
fm_t3_bind_claude_home "$binding_home" --dry-run
[ ! -e "$binding_home/.claude" ] || fail 'home-binding dry-run created settings directory'
mkdir "$binding_home/.claude"
settings="$binding_home/.claude/settings.local.json"
cat > "$settings" <<'SETTINGS'
{"permissions":{"allow":["Bash(git status:*)"],"defaultMode":"default"},"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"fixture-command"}]}]},"env":{"CUSTOM_FIXTURE":"keep-me"},"unknown":{"nested":[1,true,"retained"]}}
SETTINGS
cp "$settings" "$work/settings-original"
fm_t3_bind_claude_home "$binding_home" --dry-run
cmp "$settings" "$work/settings-original" || fail 'home-binding dry-run changed existing settings'
fm_t3_bind_claude_home "$binding_home"
jq -e --arg home "$binding_home" --slurpfile original "$work/settings-original" '
  .permissions == $original[0].permissions and .hooks == $original[0].hooks and
  .unknown == $original[0].unknown and .env.CUSTOM_FIXTURE == "keep-me" and
  .env.FM_HOME == $home and .env.FM_ROOT == $home and
  .env.FM_ROOT_OVERRIDE == "" and .env.FM_STATE_OVERRIDE == "" and
  .env.FM_DATA_OVERRIDE == "" and .env.FM_CONFIG_OVERRIDE == "" and
  .env.FM_PROJECTS_OVERRIDE == ""
' "$settings" >/dev/null || fail 'native home binding changed unrelated settings or left routing inherited'
cp "$settings" "$work/settings-bound"
fm_t3_bind_claude_home "$binding_home"
cmp "$settings" "$work/settings-bound" || fail 'repeated native home binding did not converge'
pass 'native home binding preserves permissions, hooks, unknown keys and env; dry-run is read-only and repeat converges'

for route in FM_HOME FM_ROOT FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE; do
  jq -n --arg route "$route" '{env:{($route):"conflicting-home"},permissions:{allow:["fixture"]}}' > "$settings"
  cp "$settings" "$work/settings-conflict"
  expect_failure fm_t3_bind_claude_home "$binding_home" --dry-run
  cmp "$settings" "$work/settings-conflict" || fail "dry-run replaced conflicting route $route"
  expect_failure fm_t3_bind_claude_home "$binding_home"
  cmp "$settings" "$work/settings-conflict" || fail "binding replaced conflicting route $route"
done
for invalid in '' '{"env":' 'null' '[]' '{"env":[]}' '{"env":"bad"}'; do
  printf '%s\n' "$invalid" > "$settings"
  cp "$settings" "$work/settings-invalid"
  expect_failure fm_t3_bind_claude_home "$binding_home"
  cmp "$settings" "$work/settings-invalid" || fail 'binding replaced malformed settings'
done
pass 'conflicting home routes and malformed settings refuse without replacing the original file'

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
printf '{"env":{"FM_HOME":"conflicting-home"}}\n' > "$work/home/.claude/settings.local.json"
cp "$work/home/.claude/settings.local.json" "$work/activation-conflict"
expect_failure bash "$helper" activate --dry-run
assert_contains "$(cat "$work/failure")" 'home binding is unsafe' 'activation dry-run must reject conflicting native home routing'
cmp "$work/home/.claude/settings.local.json" "$work/activation-conflict" || fail 'activation dry-run replaced conflicting native settings'
cp "$work/settings-original" "$work/home/.claude/settings.local.json"
bash "$helper" activate --dry-run > "$work/dry-activate"
cmp "$work/home/.claude/settings.local.json" "$work/settings-original" || fail 'activation dry-run changed native home routing'
[ ! -e "$work/t3-calls" ] || fail 'activation dry-run contacted T3'
[ "$(jq -r .phase "$work/home/state/.t3-leader-handover.json")" = prepared ] || fail 'activation dry-run changed phase'
bash "$helper" activate > "$work/activated"
jq -e --arg home "$work/home" '.env.FM_HOME == $home and .env.FM_ROOT == $home and .env.FM_STATE_OVERRIDE == "" and .env.CUSTOM_FIXTURE == "keep-me" and .permissions.allow == ["Bash(git status:*)"]' "$work/home/.claude/settings.local.json" >/dev/null || fail 'activation did not bind the exact native home while preserving settings'
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
