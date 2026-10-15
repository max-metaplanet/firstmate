#!/bin/bash
# usage: drive.sh <worktree> <scratch> <evdir>
set -u
WT=$1; S=$2; EV=$3
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
"$WT/bin/fm-lab-home.sh" create "$LAB" >/dev/null
mkdir -p "$LAB/tmux"
export TMUX_TMPDIR="$LAB/tmux"
unset TMUX NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
export FM_HOME="$LAB"
cleanup() { tmux kill-server 2>/dev/null; rm -rf "$LAB"; }
trap cleanup EXIT
tmux new-session -d -s firstmate -n keep 'sleep 3600'
mkd() { id=$1; shift; mkdir -p "$LAB/projects/$id-wt"; git -C "$LAB/projects/$id-wt" init -q -b "fm/$id" 2>/dev/null
  tmux new-window -d -t firstmate -n "fm-$id" 'sleep 3600'
  { echo "window=firstmate:fm-$id"; echo "worktree=$LAB/projects/$id-wt"; echo "project=alpha"; for kv in "$@"; do echo "$kv"; done; } > "$LAB/state/$id.meta"; }
mkd ship-a harness=claude kind=ship mode=ship
g=$("$WT/bin/fm-busy-event.sh" arm "$LAB/state" ship-a); "$WT/bin/fm-busy-event.sh" apply "$LAB/state" ship-a busy --gen "$g" --source claude-hook --event user-prompt-submit
echo 'working: implementing' > "$LAB/state/ship-a.status"
mkd scout-b harness=codex kind=scout mode=scout
echo 'done: report ready' > "$LAB/state/scout-b.status"
mkd idle-c harness=claude kind=ship mode=ship
g=$("$WT/bin/fm-busy-event.sh" arm "$LAB/state" idle-c); "$WT/bin/fm-busy-event.sh" apply "$LAB/state" idle-c busy --gen "$g" --source claude-hook --event user-prompt-submit
echo 'paused: holding for upstream release' > "$LAB/state/idle-c.status"
touch -t 202001010000 "$LAB/state/idle-c.status" "$LAB/state/idle-c.meta"
mkd park-d harness=claude kind=ship mode=ship
g=$("$WT/bin/fm-busy-event.sh" arm "$LAB/state" park-d); "$WT/bin/fm-busy-event.sh" apply "$LAB/state" park-d busy --gen "$g" --source claude-hook --event user-prompt-submit
echo 'needs-decision: pick rollout order' > "$LAB/state/park-d.status"
mkd blk-e harness=claude kind=ship mode=ship
g=$("$WT/bin/fm-busy-event.sh" arm "$LAB/state" blk-e); "$WT/bin/fm-busy-event.sh" apply "$LAB/state" blk-e busy --gen "$g" --source claude-hook --event user-prompt-submit
echo 'blocked: daemon unreachable' > "$LAB/state/blk-e.status"
touch -t 202001010000 "$LAB/state/blk-e.status" "$LAB/state/blk-e.meta"
printf '## In flight\n- [ ] ship-a - Ship A (repo: alpha) (kind: ship) (since 2026-10-01)\n' > "$LAB/data/backlog.md"
echo "== tmux windows (private lab socket) =="; tmux list-windows -t firstmate -F '#{window_name}'
for side in base head; do
  [ $side = base ] && R=$S/base || R=$WT
  : > $S/jq-$side.log
  PATH="$S/shim:$PATH" JQ_COUNT_LOG=$S/jq-$side.log "$R/bin/fm-fleet-snapshot.sh" --json > $S/snap-$side.json
  echo "== $side: jq execs for one snapshot refresh: $(wc -l < $S/jq-$side.log | tr -d ' ')"
done
norm='del(.generated_at,.generated_epoch) | .tasks |= map(del(.current_state)) | .backlog |= (if type=="object" then del(.records) else . end)'
echo "== task rows (excluding current_state) identical base vs head (sorted-key compare):"
diff <(jq -S "$norm" $S/snap-base.json) <(jq -S "$norm" $S/snap-head.json) && echo IDENTICAL
echo "== tasks[] full rows identical except crews whose state changed:"
for id in ship-a scout-b idle-c park-d blk-e; do
  b=$(jq -cS --arg i $id '.tasks[]|select(.id==$i)' $S/snap-base.json); h=$(jq -cS --arg i $id '.tasks[]|select(.id==$i)' $S/snap-head.json)
  [ "$b" = "$h" ] && echo "$id: identical" || { echo "$id: DIFFERS"; echo " base current_state: $(jq -c --arg i $id '.tasks[]|select(.id==$i)|.current_state' $S/snap-base.json)"; echo " head current_state: $(jq -c --arg i $id '.tasks[]|select(.id==$i)|.current_state' $S/snap-head.json)"; }
done
echo "== head crew-state direct (real tmux probe) =="
for id in ship-a idle-c park-d blk-e; do echo "-- $id"; "$WT/bin/fm-crew-state.sh" $id 2>&1 | head -4; done
echo "-- idle-c with threshold raised to 999999999 (must live-probe)"
FM_CREW_STATE_IDLE_SHORT_CIRCUIT_SECONDS=999999999 "$WT/bin/fm-crew-state.sh" idle-c | head -4
echo "-- idle-c with garbage threshold 'abc' (falls back to 86400)"
FM_CREW_STATE_IDLE_SHORT_CIRCUIT_SECONDS=abc "$WT/bin/fm-crew-state.sh" idle-c | head -4
echo "-- idle-c after meta touched now (recent meta disqualifies)"
touch "$LAB/state/idle-c.meta"; "$WT/bin/fm-crew-state.sh" idle-c | head -4
echo "-- base crew-state idle-c (meta stale again) for comparison"
touch -t 202001010000 "$LAB/state/idle-c.meta"; "$S/base/bin/fm-crew-state.sh" idle-c | head -4
