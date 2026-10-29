#!/usr/bin/env bash
# Build a disposable lab home holding one ship task whose real claude agent runs
# on the lab's private tmux socket, recorded on the ambient Claude account root.
set -eu
WT_SRC=$1   # gate worktree (firstmate checkout)
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
"$WT_SRC/bin/fm-lab-home.sh" create "$LAB" >/dev/null
mkdir -p "$LAB/tmux"
ID=acct1
git init -q -b main "$LAB/proj"
git -C "$LAB/proj" -c user.name=lab -c user.email=lab@example.invalid commit -q --allow-empty -m init
git -C "$LAB/proj" worktree add -q -b "task-$ID" "$LAB/wt"
mkdir -p "$LAB/data/$ID"
cat > "$LAB/data/$ID/brief.md" <<B
# Task
## Captain's intent
Exercise relaunch account behavior for $ID.

## Firstmate spec
Preserve the task while replacing its agent process.
B
cat > "$LAB/state/$ID.meta" <<M
window=fmses:fm-$ID
endpoint_task_id=$ID
worktree=$LAB/wt
project=$LAB/proj
harness=claude
kind=ship
mode=no-mistakes
yolo=off
tasktmp=/tmp/fm-$ID
model=default
effort=default
account=$CLAUDE_CONFIG_DIR
M
# A keep-alive window holds the private server open; the task pane is a shell
# running claude, as a spawned endpoint is.
TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab new-session -d -s fmses -n keep -x 200 -y 50 "sleep 7200"
TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab new-window -d -t fmses -n "fm-$ID" -c "$LAB/wt" \
  -e CLAUDE_CONFIG_DIR="$CLAUDE_CONFIG_DIR" bash --norc --noprofile
sleep 1
TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab send-keys -t "fmses:fm-$ID" claude Enter
echo "$LAB"
