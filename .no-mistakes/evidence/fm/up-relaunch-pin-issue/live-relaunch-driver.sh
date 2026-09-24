#!/usr/bin/env bash
# Live driver: real fm-control.sh / fm-spawn.sh against a real, private tmux
# server (own TMUX_TMPDIR, never the operator's server or any Herdr session).
# FM_GATE_REFUSE_BYPASS=1 is the same sandbox-fleet exemption tests/lib.sh exports.
set -u
W=/Users/max/.no-mistakes/worktrees/b730d76738a7/01M391Y2EADFYF93PSDSXV2YQG
L=$(mktemp -d /tmp/fmlive.XXXX); L=$(cd "$L" && pwd -P)
export TMUX_TMPDIR="$L/tmuxdir"; mkdir -p "$TMUX_TMPDIR" "$L/agentbin" "$L/user-home"
cp /bin/sleep "$L/agentbin/claude"; codesign -f -s - "$L/agentbin/claude" 2>/dev/null   # a process whose name is `claude`
ID=rl-live; SES=fmlive
H="$L/home"; mkdir -p "$H/state" "$H/data/$ID" "$H/config"
git init -q "$L/proj"; git -C "$L/proj" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git -C "$L/proj" worktree add -q -b "task-$ID" "$L/wt"
printf '# Task\n## Captain'"'"'s intent\nlive relaunch check\n\n## Firstmate spec\nnone\n' > "$H/data/$ID/brief.md"
mkdir -p "$L/work" "$L/other"; : > "$L/other/.credentials.json"
cat > "$H/state/$ID.meta" <<M
window=$SES:fm-$ID
endpoint_task_id=$ID
worktree=$L/wt
project=$L/proj
harness=claude
kind=ship
mode=no-mistakes
yolo=off
tasktmp=/tmp/fm-$ID
model=default
effort=default
account=$L/work
M
T() { env -u TMUX tmux "$@"; }
T new-session -d -s $SES -n fm-$ID -c "$L/wt" zsh -f
T send-keys -t $SES:fm-$ID "$L/agentbin/claude 100000" Enter; /bin/sleep 1
pane() { T display-message -p -t $SES:fm-$ID '#{pane_current_command} pid=#{pane_pid}'; }
ctl() { env -u TMUX -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SESSION -u HERDR_SOCKET_PATH -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID -u CLAUDE_CONFIG_DIR \
  FM_BACKEND=tmux FM_HOME="$H" HOME="$L/user-home" FM_SPAWN_NO_GUARD=1 FM_GATE_REFUSE_BYPASS=1 "$@" 2>&1; }
step() { echo; echo "=== $1"; }
echo "lab root: $L   tmux server: $TMUX_TMPDIR (private)"
echo "task record account=: $(grep ^account= "$H/state/$ID.meta")"
echo "pane before: $(pane)"; SUM0=$(shasum "$H/state/$ID.meta" | cut -d' ' -f1)

step "S1 pin moved to another account -> fm-control relaunch"
printf '%s\n' "$L/other" > "$H/config/claude-account"
ctl "$W/bin/fm-control.sh" $ID relaunch --note "pin moved"; echo "exit=$?"
echo "pane after: $(pane)"; echo "record unchanged: $([ "$(shasum "$H/state/$ID.meta" | cut -d' ' -f1)" = "$SUM0" ] && echo yes || echo NO)"

step "S2 pin file removed -> fm-control relaunch"
rm "$H/config/claude-account"
ctl "$W/bin/fm-control.sh" $ID relaunch --note "pin removed"; echo "exit=$?"
echo "pane after: $(pane)"; echo "record unchanged: $([ "$(shasum "$H/state/$ID.meta" | cut -d' ' -f1)" = "$SUM0" ] && echo yes || echo NO)"

step "S3 pin names the recorded account by a symlinked path -> guard passes, reaches the real claude sign-in check"
ln -s "$L/work" "$L/work-link"; printf '%s\n' "$L/work-link" > "$H/config/claude-account"
ctl "$W/bin/fm-control.sh" $ID relaunch --note "same account"; echo "exit=$?"
echo "pane after: $(pane)"; echo "record unchanged: $([ "$(shasum "$H/state/$ID.meta" | cut -d' ' -f1)" = "$SUM0" ] && echo yes || echo NO)"

step "S4 launch owner reached directly: fm-spawn --relaunch with moved pin on an agent-free pane"
printf '%s\n' "$L/other" > "$H/config/claude-account"
T send-keys -t $SES:fm-$ID C-c; /bin/sleep 1; echo "pane now: $(pane)"
ctl "$W/bin/fm-spawn.sh" $ID --relaunch; echo "exit=$?"
echo "pane after: $(pane)"; echo "record unchanged: $([ "$(shasum "$H/state/$ID.meta" | cut -d' ' -f1)" = "$SUM0" ] && echo yes || echo NO)"
echo "pane transcript tail:"; T capture-pane -p -t $SES:fm-$ID | grep -v '^$' | tail -5

T kill-server; rm -rf "$L"; echo; echo "torn down: private tmux server killed, $L removed"
