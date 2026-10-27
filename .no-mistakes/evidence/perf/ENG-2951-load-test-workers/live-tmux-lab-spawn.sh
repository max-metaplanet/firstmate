#!/usr/bin/env bash
# Live lab: real bin/fm-spawn.sh on a real tmux server (private fm-lab socket),
# disposable lab FM_HOME, a probe agent that records the env it was started with.
set -u
ROOT=$1; POSTURE=$2   # absent|enabled
LAB=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")" && pwd -P)
"$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null
mkdir -p "$LAB/tmux" "$LAB/fakebin" "$LAB/user-home"
touch "$LAB/state/.last-watcher-beat"
SOCK=fm-lab-$$
T() { TMUX_TMPDIR="$LAB/tmux" command tmux -L "$SOCK" "$@"; }
cleanup() { T kill-server 2>/dev/null; chmod -R u+w "$LAB"; rm -rf "$LAB"; }
trap cleanup EXIT
# project + isolated git worktree
P="$LAB/proj"; WT="$LAB/wt"
git init -q -b main "$P"; git -C "$P" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git init -q --bare "$LAB/origin.git"; git -C "$P" remote add origin "$LAB/origin.git"; git -C "$P" push -q origin main
git -C "$P" worktree add -q -b wt-live "$WT"
WT=$(cd "$WT" && pwd -P)
# fake treehouse: enter the worktree in a child interactive shell (pane cwd moves)
cat > "$LAB/fakebin/treehouse" <<SH
#!/bin/sh
cd "$WT" && exec /bin/sh -i
SH
# probe agent: record the test-control env it actually received
cat > "$LAB/fakebin/probe-agent" <<SH
#!/bin/sh
{ echo "agent PREPUSH_TESTS=\${PREPUSH_TESTS-unset}"; echo "agent VITEST_MAX_WORKERS=\${VITEST_MAX_WORKERS-unset}"; echo "agent PIPELINE_TEST_MAX_WORKERS=\${PIPELINE_TEST_MAX_WORKERS-unset}"; } > "$LAB/agent-env.txt"
sleep 300
SH
cat > "$LAB/fakebin/quota-axi" <<'SH'
#!/bin/sh
exit 1
SH
chmod +x "$LAB/fakebin/"*
[ "$POSTURE" = enabled ] && printf 'PATH\nHOME\n' > "$LAB/config/launch-env-allowlist"
mkdir -p "$LAB/data/live-scout"
printf '# Task\n## Captain%ss intent\nlive lab probe\n\n## Firstmate spec\nExercise spawn env.\n' "'" > "$LAB/data/live-scout/brief.md"
# lab tmux server: contrary ambient values that the launch must override
T -f /dev/null new-session -d -s fm -x 200 -y 50 -c "$P" \
  env PATH="$LAB/fakebin:$PATH" PREPUSH_TESTS=1 VITEST_MAX_WORKERS=9 PIPELINE_TEST_MAX_WORKERS=9 PS1='$ ' /bin/sh -i
T set-option -g default-shell /bin/sh
T set-environment -g PATH "$LAB/fakebin:$PATH"
T set-environment -g PREPUSH_TESTS 1; T set-environment -g VITEST_MAX_WORKERS 9; T set-environment -g PIPELINE_TEST_MAX_WORKERS 9
T set-environment -g PS1 '$ '
SOCKPATH=$(T display-message -p '#{socket_path}')
out=$(env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
  FM_HOME="$LAB" HOME="$LAB/user-home" CLAUDE_CONFIG_DIR= FM_SPAWN_NO_GUARD=1 FM_TREEHOUSE_GET_TIMEOUT=60 \
  TMUX_TMPDIR="$LAB/tmux" TMUX="$SOCKPATH,1,0" PATH="$LAB/fakebin:$PATH" \
  PREPUSH_TESTS=1 VITEST_MAX_WORKERS=9 PIPELINE_TEST_MAX_WORKERS=9 \
  "$ROOT/bin/fm-spawn.sh" live-scout "$P" --scout --harness "probe-agent --live" 2>&1); rc=$?
echo "== posture=$POSTURE fm-spawn exit=$rc"; printf '%s\n' "$out" | tail -5
for i in $(seq 1 60); do [ -s "$LAB/agent-env.txt" ] && break; sleep 1; done
echo "== env seen by the launched agent process:"; cat "$LAB/agent-env.txt" 2>/dev/null || echo "(agent never started)"
W=$(T list-windows -a -F '#{session_name}:#{window_name}' | grep 'live-scout' | head -1)
echo "== pane transcript ($W, export lines):"; T capture-pane -p -S -200 -t "$W" 2>/dev/null | grep -E 'export (PREPUSH|FM_TASK_ID)|probe-agent' | sed 's/FM_TASK_INBOX=[^;]*/FM_TASK_INBOX=…/' | cut -c1-240
