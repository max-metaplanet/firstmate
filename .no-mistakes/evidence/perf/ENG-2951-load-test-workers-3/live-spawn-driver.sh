#!/usr/bin/env bash
# live.sh <allowlist:absent|enabled> <evidence-out>
set -u
ROOT=$PWD
MODE=$1 OUT=$2
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
bash bin/fm-lab-home.sh create "$LAB" >/dev/null || exit 1
TD=$(bash bin/fm-lab-home.sh tmux-dir "$LAB")
export TMUX_TMPDIR=$TD
cleanup() { tmux -L fm-lab kill-server >/dev/null 2>&1; bash "$ROOT/bin/fm-lab-home.sh" teardown "$LAB" >/dev/null 2>&1; chmod -R u+w "$LAB" 2>/dev/null; rm -rf "$LAB"; }
trap cleanup EXIT
touch "$LAB/state/.last-watcher-beat"
# disposable project with origin + a pre-made worktree that the fake treehouse enters
PROJ=$LAB/proj; WT=$LAB/wt
git init -q -b main "$PROJ"; git -C "$PROJ" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git clone -q --bare "$PROJ" "$PROJ.origin.git"; git -C "$PROJ" remote add origin "$PROJ.origin.git"; git -C "$PROJ" fetch -q origin
git -C "$PROJ" worktree add -q -b wt-live "$WT"
FAKE=$LAB/fakebin; mkdir -p "$FAKE"
cat > "$FAKE/treehouse" <<SH
#!/bin/sh
# stand-in for the external pool tool: enter the isolated worktree in a subshell
cd "$WT" && exec bash --norc --noprofile -i
SH
chmod +x "$FAKE/treehouse"
# raw launch command = the "agent": records its environment then idles
ENVF=$LAB/agent-env.txt
RAW="sh -c 'env > $ENVF; sleep 300'"
if [ "$MODE" = enabled ]; then printf 'PATH\n' > "$LAB/config/launch-env-allowlist"; fi
ID=live-$MODE
mkdir -p "$LAB/data/$ID"
cat > "$LAB/data/$ID/brief.md" <<B
# Task
## Captain's intent
live env check

## Firstmate spec
Exercise the spawn launch environment.

# Definition of done
Delivery contract: mode=local-only
Ship branch: chore/no-ticket-$ID
Ticket: no-ticket
Commit type: chore
B
tmux -L fm-lab -f /dev/null new-session -d -s firstmate -c "$PROJ" "bash --norc --noprofile -i"
tmux -L fm-lab set-environment -g PATH "$FAKE:$PATH"
SOCK=$(tmux -L fm-lab display -p '#{socket_path}'); PID=$(tmux -L fm-lab display -p '#{pid}')
{
echo "### allowlist=$MODE  ambient caller env: PREPUSH_TESTS=1 VITEST_MAX_WORKERS=9 PIPELINE_TEST_MAX_WORKERS=9"
env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
  FM_HOME="$LAB" TMUX="$SOCK,$PID,0" PATH="$FAKE:$PATH" FM_SPAWN_NO_GUARD=1 \
  PREPUSH_TESTS=1 VITEST_MAX_WORKERS=9 PIPELINE_TEST_MAX_WORKERS=9 \
  timeout 120 bash bin/fm-spawn.sh "$ID" "$PROJ" --mode local-only --yolo off --ticket no-ticket --commit-type chore --harness "$RAW" 2>&1 | tail -5
echo "spawn exit=${PIPESTATUS[0]}"
for i in $(seq 1 40); do [ -s "$ENVF" ] && break; sleep 0.5; done
echo "--- agent process environment (from real tmux pane):"
grep -E '^(PREPUSH_TESTS|VITEST_MAX_WORKERS|PIPELINE_TEST_MAX_WORKERS|COMPACT_ADVISER_DISABLE|FM_TASK_ID)=' "$ENVF" | sort || echo "(agent env not captured)"
W=$(tmux -L fm-lab list-windows -a -F '#{session_name}:#{window_id} #{window_name}' | grep -v '^firstmate:@0 ' | head -1 | cut -d' ' -f1)
echo "--- worker window: $W ; pane shell exports observed by probing the pane:"
tmux -L fm-lab send-keys -t "$W" C-c; sleep 0.5
tmux -L fm-lab send-keys -t "$W" -l 'echo PANE: PREPUSH_TESTS=$PREPUSH_TESTS VITEST_MAX_WORKERS=$VITEST_MAX_WORKERS PIPELINE_TEST_MAX_WORKERS=$PIPELINE_TEST_MAX_WORKERS'; tmux -L fm-lab send-keys -t "$W" Enter; sleep 1
tmux -L fm-lab capture-pane -p -t "$W" -S -60 | grep -E '^PANE:|^export (PREPUSH|FM_TASK_ID)' | tail -4
echo "--- relaunch: fm-spawn.sh $ID --relaunch (same contrary ambient values)"
rm -f "$ENVF"
env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
  FM_HOME="$LAB" TMUX="$SOCK,$PID,0" PATH="$FAKE:$PATH" FM_SPAWN_NO_GUARD=1 \
  PREPUSH_TESTS=1 VITEST_MAX_WORKERS=9 PIPELINE_TEST_MAX_WORKERS=9 \
  timeout 120 bash bin/fm-spawn.sh "$ID" --relaunch --harness "$RAW" 2>&1 | tail -3
echo "relaunch exit=${PIPESTATUS[0]}"
for i in $(seq 1 40); do [ -s "$ENVF" ] && break; sleep 0.5; done
echo "--- relaunched agent process environment:"
grep -E '^(PREPUSH_TESTS|VITEST_MAX_WORKERS|PIPELINE_TEST_MAX_WORKERS)=' "$ENVF" | sort || echo "(agent env not captured)"
echo "--- treehouse pool check (must be absent):"; ls -d "$HOME"/.treehouse/proj-* 2>/dev/null || echo none
} > "$OUT" 2>&1
cat "$OUT"
