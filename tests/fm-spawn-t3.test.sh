#!/usr/bin/env bash
# Native T3 spawn integration with independent scratch Git fixtures and fake T3.
set -eu
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-t3)

make_t3_case() {
  local name=$1 harness=${2:-codex}
  CASE="$TMP_ROOT/$name"
  TASK="t3-$name"
  HOME_DIR="$CASE/home"
  PROJECT="$CASE/project"
  WORKTREE="$CASE/worktree"
  fm_test_spawn_home "$HOME_DIR" "$harness"
  printf 'manual\n' > "$HOME_DIR/config/backlog-backend"
  fm_test_spawn_ship_brief "$HOME_DIR" "$TASK" 'Exercise native T3 launch.'
  # This fixture owns its independent Git repository; it never allocates a
  # shared Treehouse slot or touches the task checkout's worktree inventory.
  fm_git_worktree "$PROJECT" "$WORKTREE" "slot-$name"
  FAKEBIN=$(fm_test_make_spawn_fakebin "$CASE")
  mkdir -p "$CASE/base"
  cat > "$FAKEBIN/treehouse" <<'TREEHOUSE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_T3_TEST_DIR/treehouse.log"
case "${1:-}" in
  get)
    if [ "${FM_T3_TEST_ALLOC_FAIL:-0}" = 1 ]; then exit 1; fi
    printf '%s\n' "$FM_T3_TEST_WORKTREE"
    ;;
esac
TREEHOUSE
  cat > "$FAKEBIN/t3" <<'T3'
#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
args = sys.argv[1:]
root = Path(os.environ['FM_T3_TEST_DIR'])
with (root / 't3.log').open('a') as f:
    f.write(json.dumps(args) + '\n')
if args == ['--version']:
    print('v0.1.5')
elif args[:2] == ['project', 'add']:
    print('Added project fixture-project.')
elif args[:2] == ['thread', 'start']:
    (root / 'prompt').write_text(sys.stdin.read())
    if os.environ.get('FM_T3_TEST_START_FAIL') == '1':
        sys.exit(1)
    print(json.dumps(dict(threadId='fixture-thread', projectId='fixture-project', runId='fixture-run')))
elif args[:2] == ['thread', 'show']:
    print(json.dumps(dict(thread=dict(id='fixture-thread', threadId='fixture-thread', projectId='fixture-project', status='completed', activeRunId=None), messages=[])))
elif args[:2] == ['thread', 'send']:
    print('{"delivery":"queued"}')
else:
    sys.exit(2)
T3
  chmod +x "$FAKEBIN/treehouse" "$FAKEBIN/t3"
}

spawn_t3() {
  FM_T3_TEST_DIR="$CASE" FM_T3_TEST_WORKTREE="$WORKTREE" \
    FM_T3_BIN="$FAKEBIN/t3" FM_T3_BASE_DIR="$CASE/base" \
    fm_test_run_spawn "$HOME_DIR" "$WORKTREE" "$FAKEBIN" \
      "$TASK" "$PROJECT" --backend t3 --model fixture-model \
      --mode no-mistakes --yolo off --ticket no-ticket --commit-type chore "$@"
}

make_t3_case fresh
out=$(spawn_t3) || fail "T3 worker spawn failed: $out"
assert_contains "$out" "spawned $TASK" 'native worker should be recorded as spawned'
assert_grep 'backend=t3' "$HOME_DIR/state/$TASK.meta" 'native backend must be durable'
assert_grep "window=$HOME_DIR/state/$TASK.t3" "$HOME_DIR/state/$TASK.meta" 'record directory must be the backend target'
assert_grep "worktree=$WORKTREE" "$HOME_DIR/state/$TASK.meta" 'task must record its isolated leased checkout'
assert_grep "get --lease --lease-holder firstmate:$HOME_DIR:$TASK" "$CASE/treehouse.log" 'T3 must lease without a terminal shell'
assert_grep "tasktmp=$HOME_DIR/state/$TASK.tasktmp" "$HOME_DIR/state/$TASK.meta" 'T3 scratch stays home-local'
assert_contains "$(cat "$CASE/prompt")" 'Current worker role contract' 'native prompt must include the worker identity'
[ "$(git -C "$WORKTREE" branch --show-current)" = "slot-fresh" ] || fail 'spawn unexpectedly changed branch before the worker runs'
[ ! -e "$HOME_DIR/state/$TASK.busy-gen" ] || fail 'Codex must use its native T3 state rather than an unconsumed hook'
python3 - "$CASE/t3.log" "$WORKTREE" <<'PY'
import json, sys
calls = [json.loads(line) for line in open(sys.argv[1])]
starts = [c for c in calls if c[:2] == ['thread', 'start']]
assert len(starts) == 1, starts
assert sys.argv[2] in starts[0], starts
PY
pass 'T3 spawn leases one isolated checkout and records the native launch'

before=$(wc -l < "$CASE/t3.log")
if out=$(spawn_t3); then fail 'duplicate T3 spawn unexpectedly succeeded'; fi
[ "$(wc -l < "$CASE/t3.log")" -eq "$before" ] || fail 'duplicate contacted T3'
pass 'recorded T3 task refuses duplicate launch before any T3 mutation'

make_t3_case claude claude
out=$(spawn_t3) || fail "Claude T3 spawn failed: $out"
[ -s "$WORKTREE/.claude/settings.local.json" ] || fail 'Claude native thread needs its worktree-loaded busy hooks'
[ -s "$HOME_DIR/state/$TASK.busy-gen" ] || fail 'Claude worktree hooks must carry a busy generation'
[ ! -e "$HOME_DIR/user-home/.claude.json" ] || fail 'T3 spawn mutated the terminal Claude trust store'
pass 'Claude T3 worker keeps project hooks and leaves terminal trust stores alone'

make_t3_case effort
if out=$(spawn_t3 --effort high); then fail 'unsupported T3 effort unexpectedly succeeded'; fi
assert_contains "$out" 'effort' 'unsupported explicit effort must be explained'
[ ! -e "$CASE/treehouse.log" ] || fail 'unsupported control allocated a checkout'
[ ! -e "$CASE/t3.log" ] || fail 'unsupported control contacted T3'
pass 'unsupported native launch controls refuse before allocation'

make_t3_case uncertain
if out=$(FM_T3_TEST_START_FAIL=1 spawn_t3); then fail 'failed T3 start unexpectedly succeeded'; fi
assert_contains "$out" 'uncertain' 'uncertain start must demand reconciliation'
[ -f "$HOME_DIR/state/$TASK.meta" ] || fail 'uncertain native start lost its task identity'
[ -f "$HOME_DIR/state/$TASK.t3/intent.json" ] || fail 'uncertain native start lost its launch evidence'
before=$(wc -l < "$CASE/t3.log")
if out=$(spawn_t3); then fail 'uncertain start was retried'; fi
[ "$(wc -l < "$CASE/t3.log")" -eq "$before" ] || fail 'uncertain start retried the native CLI'
pass 'uncertain native start preserves evidence and refuses a second launch'

make_t3_case allocation
if out=$(FM_T3_TEST_ALLOC_FAIL=1 spawn_t3); then fail 'uncertain Treehouse allocation unexpectedly succeeded'; fi
[ -f "$HOME_DIR/state/$TASK.t3-worktree" ] || fail 'failed durable allocation lost its receipt'
if out=$(spawn_t3); then fail 'uncertain allocation was retried'; fi
[ "$(wc -l < "$CASE/treehouse.log")" -eq 1 ] || fail 'uncertain allocation repeated Treehouse get'
pass 'uncertain durable allocation retains a receipt and cannot blindly retry'

make_t3_case secondmate claude
CHILD_HOME="$CASE/secondmate"
fm_git_init_commit "$CHILD_HOME"
mkdir -p "$CHILD_HOME/bin" "$CHILD_HOME/config" "$CHILD_HOME/state" "$CHILD_HOME/data" "$CHILD_HOME/projects"
printf '%s\n' "$TASK" > "$CHILD_HOME/.fm-secondmate-home"
printf '# Firstmate\n' > "$CHILD_HOME/AGENTS.md"
printf 'Respond only to the parent firstmate.\n' > "$CHILD_HOME/data/charter.md"
touch "$CHILD_HOME/config/supervision-host-off"
out=$(FM_T3_TEST_DIR="$CASE" FM_T3_TEST_WORKTREE="$WORKTREE" \
  FM_T3_BIN="$FAKEBIN/t3" FM_T3_BASE_DIR="$CASE/base" \
  FM_SKIP_SECONDMATE_SYNC=1 FM_SKIP_SECONDMATE_INHERIT=1 \
  fm_test_run_spawn "$HOME_DIR" "$CHILD_HOME" "$FAKEBIN" \
    "$TASK" "$CHILD_HOME" --backend t3 --model fixture-model --harness claude --secondmate) \
  || fail "Claude T3 secondmate failed: $out"
assert_grep "home=$CHILD_HOME" "$HOME_DIR/state/$TASK.meta" 'T3 secondmate must record its owned home'
assert_grep 'kind=secondmate' "$HOME_DIR/state/$TASK.meta" 'T3 secondmate must remain distinguishable from workers'
assert_grep 'mode=secondmate' "$HOME_DIR/state/$TASK.meta" 'T3 secondmate owns its fixed delivery posture'
[ ! -e "$CASE/treehouse.log" ] || fail 'persistent secondmate must not acquire a task worktree'
[ ! -e "$HOME_DIR/state/$TASK.busy-gen" ] || fail 'T3 secondmate cannot use parent hooks passed through a nonexistent --settings flag'
[ ! -e "$CHILD_HOME/.fm-busy-stop" ] || fail 'T3 secondmate must leave native primary Stop ownership intact'
assert_contains "$(cat "$CASE/prompt")" 'Respond only to the parent firstmate.' 'T3 secondmate must receive its own charter'
pass 'Claude T3 secondmate uses its persistent home and native primary hook ownership'

make_t3_case codex-secondmate
if out=$(FM_T3_TEST_DIR="$CASE" FM_T3_BIN="$FAKEBIN/t3" FM_T3_BASE_DIR="$CASE/base" \
  fm_test_run_spawn "$HOME_DIR" "$WORKTREE" "$FAKEBIN" \
    "$TASK" --backend t3 --model fixture-model --harness codex --secondmate); then
  fail 'unverified Codex T3 secondmate unexpectedly launched'
fi
assert_contains "$out" 'Claude secondmates only' 'Codex leader boundary must be explicit'
[ ! -e "$CASE/t3.log" ] || fail 'unsupported secondmate contacted T3'
pass 'Codex T3 secondmate refuses before home provisioning or T3 mutation'

make_t3_case secondmate-host claude
CHILD_HOME="$CASE/secondmate"
fm_git_init_commit "$CHILD_HOME"
mkdir -p "$CHILD_HOME/bin" "$CHILD_HOME/config" "$CHILD_HOME/state" "$CHILD_HOME/data" "$CHILD_HOME/projects"
printf '%s\n' "$TASK" > "$CHILD_HOME/.fm-secondmate-home"
printf '# Firstmate\n' > "$CHILD_HOME/AGENTS.md"
printf 'Respond only to the parent firstmate.\n' > "$CHILD_HOME/data/charter.md"
if out=$(FM_T3_TEST_DIR="$CASE" FM_T3_BIN="$FAKEBIN/t3" FM_T3_BASE_DIR="$CASE/base" \
  FM_SKIP_SECONDMATE_SYNC=1 FM_SKIP_SECONDMATE_INHERIT=1 \
  fm_test_run_spawn "$HOME_DIR" "$CHILD_HOME" "$FAKEBIN" \
    "$TASK" "$CHILD_HOME" --backend t3 --model fixture-model --harness claude --secondmate); then
  fail 'T3 secondmate launched without the explicit proven supervision posture'
fi
assert_contains "$out" 'supervision-host-off' 'unverified default supervision-host path must be refused'
[ ! -e "$HOME_DIR/state/$TASK.meta" ] || fail 'missing supervision opt-out published a task record'
[ ! -e "$CASE/t3.log" ] || fail 'missing supervision opt-out contacted T3'
pass 'T3 secondmate requires the explicit proven supervision posture before provisioning'

make_t3_case secondmate-pin claude
mkdir -p "$HOME_DIR/config/secondmate-accounts/$TASK"
printf 'pinned-account\n' > "$HOME_DIR/config/secondmate-accounts/$TASK/claude-account"
if out=$(FM_T3_TEST_DIR="$CASE" FM_T3_BIN="$FAKEBIN/t3" FM_T3_BASE_DIR="$CASE/base" \
  fm_test_run_spawn "$HOME_DIR" "$WORKTREE" "$FAKEBIN" \
    "$TASK" --backend t3 --model fixture-model --harness claude --secondmate); then
  fail 'T3 secondmate silently ignored its task-specific account pin'
fi
assert_contains "$out" 'claude-account' 'task-specific account pin must be explained'
[ ! -e "$CASE/t3.log" ] || fail 'unsupported task-specific account pin contacted T3'
pass 'T3 secondmate cannot bypass its per-secondmate account pin'

make_t3_case trace
printf '%s\n' "$$" > "$HOME_DIR/state/.lock"
printf '%s on\n' "$$" > "$HOME_DIR/state/.trace-context-effective"
if out=$(spawn_t3); then fail 'T3 spawn silently omitted enabled trace injection'; fi
assert_contains "$out" 'trace context' 'unsupported frozen trace context must be explained'
[ ! -e "$CASE/treehouse.log" ] || fail 'unsupported trace injection allocated a checkout'
[ ! -e "$CASE/t3.log" ] || fail 'unsupported trace injection contacted T3'
pass 'enabled trace context refuses before allocation rather than claiming injection'

make_t3_case claimed
fm_write_meta "$HOME_DIR/state/other-task.meta" \
  'window=fixture:fm-other-task' 'endpoint_task_id=other-task' \
  "worktree=$WORKTREE" "project=$PROJECT" 'harness=codex' 'kind=scout'
if out=$(spawn_t3); then fail 'T3 accepted a checkout another task still owns'; fi
assert_contains "$out" "other-task's recorded worktree" 'T3 must use the shared unclaimed-worktree guard'
[ ! -e "$HOME_DIR/state/$TASK.meta" ] || fail 'refused foreign checkout published duplicate ownership metadata'
[ -f "$HOME_DIR/state/$TASK.t3-worktree" ] || fail 'refused allocation must retain its receipt for reconciliation'
[ ! -e "$CASE/t3.log" ] || fail 'refused foreign checkout contacted T3'
pass 'T3 cannot bypass another task recorded checkout ownership'
