#!/usr/bin/env bash
# Codex's generated notify command is positive completion evidence for parking.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-codex-park-idle)
HOME_DIR="$TMP_ROOT/codex home"
PROJECT="$TMP_ROOT/project"
WORKTREE="$TMP_ROOT/worktree"
ID="codex-park-$$"
FAKEBIN=$(fm_test_make_spawn_fakebin "$TMP_ROOT/fake" codex)
LAUNCH_LOG="$TMP_ROOT/launch.log"
fm_test_spawn_home "$HOME_DIR" codex
fm_test_spawn_brief "$HOME_DIR" "$ID"
fm_git_worktree "$PROJECT" "$WORKTREE" task
FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" \
  fm_test_run_spawn "$HOME_DIR" "$WORKTREE" "$FAKEBIN" "$ID" "$PROJECT" --mode direct-PR --yolo off \
  > "$TMP_ROOT/spawn.log" || fail "Codex spawn failed: $(cat "$TMP_ROOT/spawn.log")"

cat > "$FAKEBIN/codex" <<'PY'
#!/usr/bin/env python3
import json
import os
import sys

args = iter(sys.argv[1:])
for arg in args:
    if arg == "-c":
        key, _, value = next(args).partition("=")
        if key == "notify":
            with open(os.environ["FM_TEST_NOTIFY"], "w") as output:
                json.dump(json.loads(value), output)
            sys.exit(0)
sys.exit("Codex launch omitted notify")
PY
chmod +x "$FAKEBIN/codex"
FM_TEST_NOTIFY="$TMP_ROOT/notify.json" FM_SEAT_LOCK_ROOT="$TMP_ROOT/seat-locks" \
  HOME="$HOME_DIR/user-home" PATH="$FAKEBIN:$PATH" \
  bash "$LAUNCH_LOG" || fail 'generated Codex launch did not supply a usable notify array'

mkdir -p "$TMP_ROOT/bin"
for script in "$ROOT"/bin/*; do ln -s "$script" "$TMP_ROOT/bin/${script##*/}"; done
rm "$TMP_ROOT/bin/fm-control.sh"
cat > "$TMP_ROOT/bin/fm-control.sh" <<'SH'
#!/usr/bin/env bash
[ "$2" = exit ] || exit 1
printf '%s\n' "$*" >> "$FM_HOME/control.log"
SH
chmod +x "$TMP_ROOT/bin/fm-control.sh"
export FM_HOME=$HOME_DIR FM_STATE_OVERRIDE=$HOME_DIR/state FM_CONFIG_OVERRIDE=$HOME_DIR/config
STATE="$HOME_DIR/state"
PARK="$TMP_ROOT/bin/fm-worker-park.sh"
printf 'paused: waiting on upstream maintainer\n' > "$STATE/$ID.status"
touch -t 202001010000 "$STATE/$ID.status"

# shellcheck source=bin/fm-busy-lib.sh
. "$ROOT/bin/fm-busy-lib.sh"
assert_equals "$(fm_busy_classify tmux fake:w codex "$ID" "$STATE")" 'unknown codex-unverified' \
  'Codex does not invent semantic idle state'
if bash "$PARK" park "$ID" 'upstream maintainer' > "$TMP_ROOT/park.log" 2>&1; then
  fail 'Codex without completion evidence must refuse parking'
fi
assert_absent "$HOME_DIR/control.log" 'missing completion evidence never exits the worker'
touch -t 201901010000 "$STATE/$ID.turn-ended"
if bash "$PARK" park "$ID" 'upstream maintainer' > "$TMP_ROOT/park.log" 2>&1; then
  fail 'a completion marker older than the wait declaration must refuse parking'
fi
assert_absent "$HOME_DIR/control.log" 'stale completion evidence never exits the worker'

python3 - "$TMP_ROOT/notify.json" <<'PY'
import json
import subprocess
import sys

with open(sys.argv[1]) as source:
    notify = json.load(source)
subprocess.run(notify + ['{"type":"agent-turn-complete"}'], check=True)
PY
[ "$STATE/$ID.turn-ended" -nt "$STATE/$ID.status" ] || fail 'spawn notify did not refresh the exact task marker'
bash "$PARK" park "$ID" 'upstream maintainer' > "$TMP_ROOT/park.log" 2>&1 \
  || fail "fresh Codex completion could not park: $(cat "$TMP_ROOT/park.log")"
assert_grep 'phase=parked' "$STATE/$ID.park" 'fresh Codex notification permits otherwise-safe parking'
assert_grep "$ID exit" "$HOME_DIR/control.log" 'parking uses the verified lifecycle exit interface'
pass 'Codex spawn notification permits parking only after a fresh completion marker'
