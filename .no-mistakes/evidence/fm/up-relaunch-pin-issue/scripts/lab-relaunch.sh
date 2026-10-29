#!/usr/bin/env bash
# Run real bin/fm-control.sh relaunch for the lab task from a driver window on
# the lab's private tmux socket, so $TMUX names that socket; print its transcript.
# Usage: lab-relaunch.sh <gate-worktree> <lab> <label> <ambient CLAUDE_CONFIG_DIR> <note>
set -u
WT=$1 LAB=$2 LABEL=$3 AMBIENT=$4 NOTE=$5
OUT="$LAB/$LABEL.out"
rm -f "$OUT" "$OUT.done"
TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab new-window -d -t fmses -n "drv-$LABEL" -c "$WT" \
  "env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE FM_HOME='$LAB' CLAUDE_CONFIG_DIR='$AMBIENT' '$WT/bin/fm-control.sh' acct1 relaunch --note '$NOTE' > '$OUT' 2>&1; echo \"exit=\$?\" >> '$OUT'; touch '$OUT.done'"
for _ in $(seq 1 600); do [ -e "$OUT.done" ] && break; sleep 1; done
cat "$OUT"
