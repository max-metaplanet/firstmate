#!/usr/bin/env bash
# Live lab: a running claude agent in the mate window with a ready-to-park status
# must NOT take the stopped path; park must ask the persist gate and refuse unanswered.
set -u
WT=${WT:?}; cd "$WT"
LAB=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")" && pwd -P); bin/fm-lab-home.sh create "$LAB" >/dev/null
MATE=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/fm-lab-mate.XXXXXX")" && pwd -P); bin/fm-lab-home.sh create "$MATE" >/dev/null
TD=$(bin/fm-lab-home.sh tmux-dir "$LAB"); export TMUX_TMPDIR="$TD"; unset TMUX
cleanup() { tmux kill-server 2>/dev/null; bin/fm-lab-home.sh teardown "$LAB"; rm -rf "$LAB" "$MATE"; }
trap cleanup EXIT
git init -q "$MATE"; git -C "$MATE" -c user.name=t -c user.email=t@e commit -q --allow-empty -m init
printf 'sm1\n' > "$MATE/.fm-secondmate-home"
printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$LAB" > "$MATE/.fm-secondmate-parent"
printf 'claude\n' > "$LAB/config/secondmate-harness"; mkdir -p "$LAB/data/sm1"; printf '# charter\n' > "$LAB/data/sm1/brief.md"
printf -- '- sm1 - Lab mate (home: %s; scope: lab; projects: none; added 2026-10-20)\n' "$MATE" > "$LAB/data/secondmates.md"
printf 'window=fmses:fm-sm1\nendpoint_task_id=sm1\nworktree=%s\nproject=%s\nharness=claude\nkind=secondmate\nmode=secondmate\nyolo=off\nmodel=default\neffort=default\nhome=%s\nbackend=tmux\n' "$MATE" "$MATE" "$MATE" > "$LAB/state/sm1.meta"
printf 'done: ready to park - no conversation-only open work\n' > "$LAB/state/sm1.status"
tmux new-session -d -s fmses -n fm-sm1 -x 160 -y 40 -c "$MATE" claude
sleep 6
echo "== pane command: $(tmux display-message -p -t fmses:fm-sm1 '#{pane_current_command}')"
. bin/fm-backend.sh; fm_backend_source tmux; echo "== agent state: $(fm_backend_agent_state tmux fmses:fm-sm1)"
echo "\$ fm-secondmate-park.sh sm1 park   (FM_SECONDMATE_PERSIST_WAIT=4)"
env -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
  FM_HOME="$LAB" FM_SECONDMATE_PERSIST_WAIT=4 FM_SECONDMATE_PERSIST_POLL=1 bin/fm-secondmate-park.sh sm1 park 2>&1; echo "rc=$?"
echo "-- park record (must be absent): $(ls "$LAB/state/.secondmate-park-sm1" 2>&1 | sed 's/.*: //')"
echo "-- persist request delivered to inbox: $(ls "$LAB/state/sm1.inbox" 2>&1 | tr '\n' ' ')"
echo "-- pane command after (agent left running): $(tmux display-message -p -t fmses:fm-sm1 '#{pane_current_command}')"
