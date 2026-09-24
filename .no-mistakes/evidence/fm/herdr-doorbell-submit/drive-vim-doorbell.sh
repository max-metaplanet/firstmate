#!/usr/bin/env bash
# Ad-hoc live driver: ring the real steering doorbell into a vim-mode Claude
# pane left in command mode by Escape, using the bin/ tree at $1.
# mode=command: plain command mode. mode=transcript: first make Claude print
# "-- INSERT --" in its transcript, then Escape, then ring.
set -u
BIN_ROOT=$1; MODE=$2
LAB=/Users/max/.no-mistakes/worktrees/61c6dd39b831/01M3AQJYASTNY35A3R4TH5WR30/bin/fm-herdr-lab.sh
ORIGINAL_PATH=$PATH
SESSION=$("$LAB" name vimbell-$MODE)
TMP=$(mktemp -d /tmp/fm-vimbell.XXXXXX); mkdir -p $TMP/fakebin
cleanup() { PATH="$ORIGINAL_PATH" "$LAB" teardown "$SESSION"; rm -rf "$TMP"; }
trap cleanup EXIT
cat > $TMP/fakebin/herdr <<W
#!/usr/bin/env bash
args=("\$@"); n=\${#args[@]}
[ "\${args[\$((n-2))]}" = --session ] && [ "\${args[\$((n-1))]}" = "$SESSION" ] || { echo refused >&2; exit 97; }
exec env PATH="$ORIGINAL_PATH" "$LAB" run "$SESSION" "\${args[@]:0:\$((n-2))}"
W
chmod +x $TMP/fakebin/herdr
"$LAB" provision "$SESSION" || exit 1
export PATH="$TMP/fakebin:$ORIGINAL_PATH"
lab() { env PATH="$ORIGINAL_PATH" "$LAB" run "$SESSION" "$@"; }
. "$BIN_ROOT/bin/backends/herdr.sh"
. "$BIN_ROOT/bin/fm-task-inbox-lib.sh"
wait_idle() { local i=0; while [ $i -lt 90 ]; do
  case "$(lab agent get "$1" 2>/dev/null | jq -r '.result.agent.agent_status // empty')" in
    idle|done) return 0;;
    blocked) case "$(lab pane read "$1" --source visible 2>/dev/null)" in *'Yes, I trust this folder'*) lab pane send-keys "$1" down enter >/dev/null;; esac;;
  esac; i=$((i+1)); sleep 1; done; return 1; }
PANE=$(lab workspace create --cwd "$BIN_ROOT" --label vimbell --no-focus | jq -er '.result.root_pane.pane_id')
lab pane run "$PANE" "CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false CLAUDE_CODE_SEND_FEEDBACK=0 claude --dangerously-skip-permissions --settings '{\"feedbackDrafts\":\"off\",\"editorMode\":\"vim\"}'" >/dev/null
wait_idle "$PANE" || { echo "never idle"; exit 1; }; sleep 2
if [ "$MODE" = transcript ]; then
  fm_backend_herdr_send_text_submit "$SESSION:$PANE" "Reply with exactly these two lines and nothing else: first line 'marker', second line '-- INSERT --'" 3 0.4 0.4 >/dev/null
  sleep 3; wait_idle "$PANE"; sleep 2
fi
lab pane send-keys "$PANE" escape >/dev/null; sleep 1
echo "===== BIN_ROOT=$BIN_ROOT MODE=$MODE"
echo "----- pane before ring (after Escape):"; lab pane read "$PANE" --source visible | tail -12
REC=$(fm_task_inbox_write "$TMP" guard-task "reply is not required; this is a delivery guard")
rc=0; fm_task_inbox_ring herdr "$SESSION:$PANE" "$REC" || rc=$?
echo "----- fm_task_inbox_ring rc=$rc (0 rang, 2 failed)"
sleep 2
echo "----- pane after ring:"; lab pane read "$PANE" --source visible | tail -14
