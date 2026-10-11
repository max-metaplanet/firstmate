#!/usr/bin/env bash
# usage: live.sh <root-checkout> <label> <evidence-dir>
set -u
ROOT_UNDER=$1; LABEL=$2; EV=$3
. "$ROOT_UNDER/tests/fixtures.sh"
ROOT=$ROOT_UNDER
REAL_TMUX=$(command -v tmux)
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fmtp.XXXXXX"); LAB=$(cd "$LAB" && pwd -P)
SOCKET="$LAB/t.sock"
cleanup() { "$REAL_TMUX" -S "$SOCKET" kill-server >/dev/null 2>&1; chmod -R u+w "$LAB"; rm -rf "$LAB"; }
trap cleanup EXIT
H="$LAB/home"; WT="$LAB/wt"; PROJ="$LAB/project"; ID=tp-live-$LABEL
fm_test_spawn_home "$H" claude
fm_git_worktree "$PROJ" "$WT" "$ID"
fm_test_spawn_brief "$H" "$ID" "Runtime verification only: write the word ok into answer.txt. Do nothing else."
fakebin=$(fm_test_make_spawn_fakebin "$LAB/fake")
FM_FAKE_LAUNCH_LOG="$LAB/launch.sh" CLAUDE_CONFIG_DIR= fm_test_run_spawn "$H" "$WT" "$fakebin" "$ID" "$PROJ" --scout --harness claude > "$LAB/spawn.log" 2>&1 \
  || { echo "spawn failed"; cat "$LAB/spawn.log"; exit 1; }
cp "$LAB/launch.sh" "$EV/$LABEL-staged-launch.sh"
# Pane inherits the lead's child-session marker, as a worker spawned from a lead would.
"$REAL_TMUX" -S "$SOCKET" new-session -d -s firstmate -n "fm-$ID" -x 160 -y 50 -c "$WT" \
  "CLAUDE_CODE_CHILD_SESSION=1 /bin/sh '$LAB/launch.sh'; exec /bin/bash --noprofile --norc"
for i in $(seq 1 90); do
  [ -s "$WT/answer.txt" ] && break
  scr=$("$REAL_TMUX" -S "$SOCKET" capture-pane -p -t "firstmate:fm-$ID")
  [ "$i" -le 3 ] && printf '%s\n=====\n' "$scr" >> "$EV/$LABEL-startup-screens.txt"
  if printf '%s' "$scr" | grep -qE "Yes, I (accept|trust this folder)"; then "$REAL_TMUX" -S "$SOCKET" send-keys -t "firstmate:fm-$ID" Down; sleep 0.5; "$REAL_TMUX" -S "$SOCKET" send-keys -t "firstmate:fm-$ID" Enter
  elif printf '%s' "$scr" | grep -qi "trust this folder"; then "$REAL_TMUX" -S "$SOCKET" send-keys -t "firstmate:fm-$ID" Enter; fi
  sleep 2
done
sleep 3
"$REAL_TMUX" -S "$SOCKET" capture-pane -p -t "firstmate:fm-$ID" > "$EV/$LABEL-pane.txt"
pid=$(pgrep -f "claude .*--settings" | while read p; do lsof -a -p "$p" -d cwd -Fn 2>/dev/null | grep -q "^n$WT" && echo $p; done | head -1)
{ echo "claude pid=$pid"; ps eww -p "$pid" 2>/dev/null | tr ' ' '\n' | grep -E '^CLAUDE_CODE_(CHILD_SESSION|FORCE_SESSION_PERSISTENCE)=' || echo "(no CHILD_SESSION / FORCE_SESSION_PERSISTENCE in process env)"; } > "$EV/$LABEL-proc-env.txt"
slug=$(printf '%s' "$WT" | sed 's#[^A-Za-z0-9]#-#g')
cfg=${CLAUDE_CONFIG_DIR:-$HOME/.claude}
{ echo "answer.txt: $(cat "$WT/answer.txt" 2>/dev/null)"; echo "transcript dir: $cfg/projects/$slug"; ls -la "$cfg/projects/$slug" 2>&1; } > "$EV/$LABEL-transcript.txt"
cat "$EV/$LABEL-proc-env.txt" "$EV/$LABEL-transcript.txt"; grep -i "transcript" "$EV/$LABEL-pane.txt"
rm -rf "$cfg/projects/$slug"
