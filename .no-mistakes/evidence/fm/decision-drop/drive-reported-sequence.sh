#!/usr/bin/env bash
# Replays the reported incident against a real fm-wake-drain / fm-send, with a
# real isolated tmux server (TMUX_TMPDIR) holding the worker panes.
# usage: drive-reported-sequence.sh <bin-dir> <lab-dir> <label>
set -u
BIN=$1 LAB=$2 LABEL=$3
export TMUX_TMPDIR=$LAB/tmux FM_SEND_SETTLE=0 FM_GATE_REFUSE_BYPASS=1  # sandbox fleet only (tests/lib.sh convention)
home=$LAB/home-$LABEL; rm -rf "$home"; mkdir -p "$home/state"
printf 'window=sess:fm-t1\nkind=ship\n' > "$home/state/t1.meta"
printf 'window=sess:fm-t2\nkind=ship\n' > "$home/state/t2.meta"
# unrelated open item on another task
printf 'needs-decision [key=other-item]: unrelated question\n' > "$home/state/t2.status"
# 1. worker opens keyed decision; 2. later bare done:
printf 'needs-decision [key=eng2403-execsql-drop]: drop the execsql path or keep it?\n' > "$home/state/t1.status"
printf 'working: continuing on the parts not blocked\n' >> "$home/state/t1.status"
printf 'done: the other parts shipped; ruling 2 still awaits approval\n' >> "$home/state/t1.status"
echo "=== [$LABEL] status log t1 ==="; cat "$home/state/t1.status"
echo "=== [$LABEL] fm-wake-drain.sh OPEN DECISIONS ==="
FM_STATE_OVERRIDE="$home/state" "$BIN/fm-wake-drain.sh" 2>&1 | sed -n '/OPEN DECISIONS/,$p'
echo "=== [$LABEL] fm-send.sh t1 --resolve-key eng2403-execsql-drop ==="
FM_ROOT_OVERRIDE="$home" FM_HOME="$home" "$BIN/fm-send.sh" t1 --resolve-key eng2403-execsql-drop "keep it; drop only the legacy shim" 2>&1
echo "exit=$?"
echo "=== [$LABEL] inbox after send ==="; ls "$home/state/t1.inbox" 2>/dev/null && cat "$home/state/t1.inbox"/*.msg 2>/dev/null || echo "(no inbox record - nothing sent)"
echo "=== [$LABEL] status log t1 after send ==="; cat "$home/state/t1.status"
echo "=== [$LABEL] fm-wake-drain.sh OPEN DECISIONS after send ==="
FM_STATE_OVERRIDE="$home/state" "$BIN/fm-wake-drain.sh" 2>&1 | sed -n '/OPEN DECISIONS/,$p'
echo "=== [$LABEL] real pane fm-t1 contents ==="; tmux capture-pane -p -t sess:fm-t1 | grep -v '^$' | tail -5
