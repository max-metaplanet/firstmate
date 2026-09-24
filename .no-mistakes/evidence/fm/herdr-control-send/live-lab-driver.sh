#!/usr/bin/env bash
# Live Herdr lab driver for the fm-control modal-composer fix.
# Usage: live-lab-driver.sh <code-root> <vim|novim> <flow>
#   flows: interrupt-exit | escape-exit | busy-interrupt | relaunch
# Runs a REAL claude in an isolated fm-lab-* Herdr session (bin/fm-herdr-lab.sh)
# and drives <code-root>/bin/fm-control.sh against it. Tears the lab down on exit.
set -u
CODE=$1 MODE=$2 FLOW=$3
LABROOT=/Users/max/.no-mistakes/worktrees/61c6dd39b831/01M396EP9RP6ZBAJXX87NCC9ZK
LAB_HELPER=$LABROOT/bin/fm-herdr-lab.sh
ORIGINAL_PATH=$PATH
unset HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_ENV
SESSION=$("$LAB_HELPER" name "mc-$FLOW")
TMP_ROOT=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-mc-live.XXXXXX")
FAKEBIN="$TMP_ROOT/fakebin"; mkdir -p "$FAKEBIN"
log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
cleanup() {
  local rc=$?
  trap - EXIT
  log "teardown $SESSION"
  PATH="$ORIGINAL_PATH" "$LAB_HELPER" teardown "$SESSION" || rc=1
  rm -rf "$TMP_ROOT"
  exit "$rc"
}
trap cleanup EXIT
cat > "$FAKEBIN/herdr" <<EOF
#!/usr/bin/env bash
set -u
args=("\$@")
n=\${#args[@]}
if [ "\$n" -ge 2 ] && [ "\${args[\$((n-2))]}" = --session ]; then
  [ "\${args[\$((n-1))]}" = "$SESSION" ] || { echo "wrapper refused foreign session" >&2; exit 97; }
  args=("\${args[@]:0:\$((n-2))}")
fi
for ((k=0;k<\${#args[@]};k++)); do
  if [ "\${args[k]}" = --session ]; then
    [ "\${args[k+1]}" = "$SESSION" ] || { echo "wrapper refused foreign session" >&2; exit 97; }
    args=("\${args[@]:0:k}" "\${args[@]:k+2}"); break
  fi
done
case "\${args[0]:-}" in --version|version) exec env PATH="$ORIGINAL_PATH" herdr "\${args[@]}";; esac
exec env PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" "\${args[@]}"
EOF
chmod +x "$FAKEBIN/herdr"
"$LAB_HELPER" provision "$SESSION" || { log "provision failed"; exit 1; }
export PATH="$FAKEBIN:$ORIGINAL_PATH" HERDR_SESSION="$SESSION"
lab() { env PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" "$@"; }

HOME_DIR="$TMP_ROOT/home"; PROJ="$TMP_ROOT/proj"; WT="$TMP_ROOT/wt"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/data/mc1" "$PROJ"
printf '# Task\n## Captain'"'"'s intent\nLab.\n\n## Firstmate spec\nLab.\n' > "$HOME_DIR/data/mc1/brief.md"
git -C "$PROJ" init -q; printf '# proj\n' > "$PROJ/README.md"; git -C "$PROJ" add README.md
git -C "$PROJ" -c user.name=t -c user.email=t@example.invalid commit -qm initial
git -C "$PROJ" worktree add --quiet -b mc1 "$WT"

WS_JSON=$(lab workspace create --cwd "$WT" --label fm-mclive --no-focus) || { log "workspace create failed"; exit 1; }
PANE=$(printf '%s' "$WS_JSON" | jq -er '.result.root_pane.pane_id')
WSID=$(printf '%s' "$WS_JSON" | jq -er '.result.workspace.workspace_id // .result.root_pane.workspace_id')
TABID=$(printf '%s' "$WS_JSON" | jq -er '.result.root_pane.tab_id // .result.tab.tab_id')
{
  echo "window=$SESSION:$PANE"; echo "endpoint_task_id=mc1"; echo "worktree=$WT"; echo "project=$PROJ"
  echo "harness=claude"; echo "kind=ship"; echo "mode=no-mistakes"; echo "yolo=on"
  echo "model=default"; echo "effort=default"; echo "backend=herdr"; echo "herdr_session=$SESSION"
  echo "herdr_workspace_id=$WSID"; echo "herdr_tab_id=$TABID"; echo "herdr_pane_id=$PANE"
} > "$HOME_DIR/state/mc1.meta"
log "lab=$SESSION pane=$PANE code=$CODE mode=$MODE flow=$FLOW herdr=$(PATH=$ORIGINAL_PATH herdr --version) claude=$(claude --version)"

if [ "$MODE" = vim ]; then EDM=vim; else EDM=normal; fi
lab pane run "$PANE" "cd '$WT' && CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false CLAUDE_CODE_SEND_FEEDBACK=0 claude --dangerously-skip-permissions --model haiku --settings '{\"feedbackDrafts\":\"off\",\"editorMode\":\"$EDM\"}'" >/dev/null
screen() { lab pane read "$PANE" --source visible 2>/dev/null; }
footer() { screen | grep -v '^[[:space:]]*$' | tail -4; }
wait_idle() {
  local i=0 st
  while [ $i -lt 60 ]; do
    st=$(lab agent get "$PANE" 2>/dev/null | jq -r '.result.agent.agent_status // empty')
    case "$st" in
      idle|done) return 0 ;;
      blocked) case "$(screen)" in *'Yes, I trust this folder'*) lab pane send-keys "$PANE" down enter >/dev/null ;; esac ;;
    esac
    i=$((i+1)); sleep 1
  done
  return 1
}
wait_idle || { log "claude never idle"; screen; exit 1; }
sleep 2
log "claude ready; footer:"; footer
ctl() {
  env FM_GATE_REFUSE_BYPASS=1 FM_HOME="$HOME_DIR" HERDR_SESSION="$SESSION" FM_SPAWN_NO_GUARD=1 FM_CONTROL_POLL=0.3 FM_CONTROL_EXIT_WAIT=15 \
    "$CODE/bin/fm-control.sh" "$@" 2>&1
}
agentstat() { lab agent get "$PANE" 2>/dev/null | jq -r '.result.agent.agent_status // "none"'; }
procs() { lab pane process-info "$PANE" 2>/dev/null | jq -c '[.. | .name? // empty]' 2>/dev/null; }
RESULT=0
run_exit() {
  log "\$ fm-control.sh mc1 exit"
  OUT=$(ctl mc1 exit); rc=$?
  printf '%s\n' "$OUT"; log "exit rc=$rc"
  sleep 1; log "agent status after exit: $(agentstat)"; log "footer after exit:"; footer
  [ $rc -eq 0 ] || RESULT=1
}
case "$FLOW" in
  probe-proof)
    . "$CODE/bin/fm-backend.sh"; fm_backend_source herdr
    T="$SESSION:$PANE"
    for payload in "/exit" "hello world"; do
      log "send_literal '$payload' (unsubmitted), then read what the Claude payload proof reads"
      fm_backend_herdr_send_literal "$T" "$payload"; sleep 1.2
      lines=$(fm_backend_herdr_proof_lines "$payload")
      content=$(fm_backend_herdr_composer_content "$T" "$lines"); crc=$?
      log "composer_content rc=$crc: [$(printf '%s' "$content" | tr '\n' '|')]"
      if fm_backend_herdr_composer_payload_shown "$payload" "$content"; then log "payload_shown('$payload') = YES"; else log "payload_shown('$payload') = NO -> send_text_submit would refuse with send-failed"; fi
      log "visible screen tail:"; screen | grep -v '^[[:space:]]*$' | tail -12
      for _ in 1 2 3; do lab pane send-keys "$PANE" C-u >/dev/null; done; sleep 0.8
    done ;;
  plain-exit)
    run_exit ;;
  interrupt-exit)
    log "\$ fm-control.sh mc1 interrupt"
    OUT=$(ctl mc1 interrupt); rc=$?; printf '%s\n' "$OUT"; log "interrupt rc=$rc"
    [ $rc -eq 0 ] || RESULT=1
    sleep 1; log "footer after interrupt:"; footer
    run_exit ;;
  escape-exit)
    log "raw Escape via herdr pane send-keys (an earlier Escape outside fm-control)"
    lab pane send-keys "$PANE" escape >/dev/null; sleep 1.5
    log "footer after raw Escape:"; footer
    run_exit ;;
  busy-interrupt)
    log "submitting a long prompt so claude is mid-turn"
    lab pane send-text "$PANE" "Count slowly from 1 to 400, one number per line, no other text." >/dev/null
    sleep 0.5; lab pane send-keys "$PANE" enter >/dev/null
    for _ in $(seq 1 20); do [ "$(agentstat)" = working ] && break; sleep 0.5; done
    log "agent status before interrupt: $(agentstat)"
    log "\$ fm-control.sh mc1 interrupt"
    OUT=$(ctl mc1 interrupt); rc=$?; printf '%s\n' "$OUT"; log "interrupt rc=$rc"
    [ $rc -eq 0 ] || RESULT=1
    sleep 2; log "footer after interrupt:"; footer
    TOKEN="MCTOKEN$RANDOM"
    log "typing '$TOKEN' raw to prove the composer takes text"
    lab pane send-text "$PANE" "$TOKEN" >/dev/null; sleep 1
    if screen | grep -q "$TOKEN"; then log "composer shows $TOKEN verbatim: TEXT ENTRY OK"; else log "composer did NOT show $TOKEN verbatim"; RESULT=1; fi
    footer
    lab pane send-keys "$PANE" C-u >/dev/null; sleep 0.5
    run_exit ;;
  relaunch)
    log "\$ fm-control.sh mc1 interrupt"
    OUT=$(ctl mc1 interrupt); rc=$?; printf '%s\n' "$OUT"; log "interrupt rc=$rc"
    sleep 1; footer
    log "\$ fm-control.sh mc1 relaunch --note 'lab relaunch'"
    OUT=$(ctl mc1 relaunch --note "lab relaunch proof"); rc=$?; printf '%s\n' "$OUT"; log "relaunch rc=$rc"
    [ $rc -eq 0 ] || RESULT=1
    sleep 3; log "agent status after relaunch: $(agentstat)"; log "screen after relaunch:"; screen | grep -v '^[[:space:]]*$' | tail -12
    ;;
esac
log "FLOW RESULT: $([ $RESULT -eq 0 ] && echo PASS || echo FAIL)"
exit $RESULT
