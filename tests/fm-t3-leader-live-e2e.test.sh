#!/usr/bin/env bash
# Opt-in real Claude terminal -> T3 -> terminal leader handover acceptance.
# Set FM_T3_LEADER_LIVE_E2E=1, FM_T3_BIN, FM_T3_BASE_DIR and an advertised
# FM_T3_LEADER_LIVE_MODEL supported by both the T3 provider and local Claude.
# FM_T3_LEADER_LIVE_CLAUDE_BIN selects the already-authenticated Claude CLI;
# the wrapper adds print/no-session-persistence/project-local settings only.
# No credentials are copied and no global trust, settings or service is changed.
# FM_T3_LEADER_LIVE_EVIDENCE_DIR optionally preserves proof and cleanup receipts.
# Only an independent scratch home and its exact owned T3 project are used.
# Failed or uncertain operations preserve the home for explicit reconciliation;
# they are never retried or cleaned up by guessing a different project/thread.
set -euo pipefail
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
fm_live_gate opt-in FM_T3_LEADER_LIVE_E2E "${FM_T3_BIN:-t3}" "${FM_T3_LEADER_LIVE_CLAUDE_BIN:-claude}" jq
[ -n "${FM_T3_BASE_DIR:-}" ] && [ -d "$FM_T3_BASE_DIR" ] || fail 'FM_T3_BASE_DIR must name the running T3 data directory'
MODEL=${FM_T3_LEADER_LIVE_MODEL:-}
[ -n "$MODEL" ] || fail 'FM_T3_LEADER_LIVE_MODEL must name a Claude model supported by T3 and the local CLI'
FM_T3_BIN=$(command -v "${FM_T3_BIN:-t3}")
FM_T3_BIN=$(cd "$(dirname "$FM_T3_BIN")" && printf '%s/%s' "$(pwd -P)" "$(basename "$FM_T3_BIN")")
LAB=$(fm_test_tmproot fm-t3-handover-live)
finish_handover() {
  local result=$?
  trap - EXIT INT TERM HUP QUIT
  if [ -n "${FM_T3_LEADER_LIVE_EVIDENCE_DIR:-}" ]; then
    mkdir -p "$FM_T3_LEADER_LIVE_EVIDENCE_DIR"
    [ ! -d "$LAB/proof" ] || cp -R "$LAB/proof/." "$FM_T3_LEADER_LIVE_EVIDENCE_DIR/"
    [ ! -d "$LAB/native-record" ] || cp -R "$LAB/native-record" "$FM_T3_LEADER_LIVE_EVIDENCE_DIR/"
  fi
  if [ "$result" -ne 0 ]; then
    printf 'not ok - retain exact handover fixture for reconciliation: %s\n' "$LAB" >&2
  else
    fm_test_cleanup
  fi
  exit "$result"
}
trap finish_handover EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
trap 'exit 131' QUIT
LEADER_HOME="$LAB/home"
PROOF="$LAB/proof"
mkdir -p "$PROOF"
printf '# T3 leader live fixture: %s\n' "$LAB"
fm_git_init_commit "$LEADER_HOME"
git -C "$ROOT" archive HEAD | tar -xf - -C "$LEADER_HOME"
cp -R "$ROOT/bin/." "$LEADER_HOME/bin/"
mkdir -p "$LEADER_HOME/data" "$LEADER_HOME/state" "$LEADER_HOME/config" "$LEADER_HOME/projects"
printf 'manual\n' > "$LEADER_HOME/config/backlog-backend"
touch "$LEADER_HOME/config/supervision-host-off"
cat > "$LEADER_HOME/data/captain.md" <<EOF
This home exists solely for an isolated leader-handover acceptance test.
There is no fleet or work queue to manage.
Do only the explicit handover prepare/confirm operation and finish the turn.
Never create a task, register a check, administer services, repair diagnostics, or inspect another home.
All test state stays inside $LEADER_HOME and $PROOF.
EOF
# shellcheck source=/dev/null
. "$LEADER_HOME/bin/fm-t3-home-lib.sh"
fm_t3_bind_claude_home "$LEADER_HOME"
CLAUDE_REAL=$(command -v "${FM_T3_LEADER_LIVE_CLAUDE_BIN:-claude}")
CLAUDE_REAL=$(cd "$(dirname "$CLAUDE_REAL")" && printf '%s/%s' "$(pwd -P)" "$(basename "$CLAUDE_REAL")")
printf -v CLAUDE_QUOTED '%q' "$CLAUDE_REAL"
cat > "$LAB/claude-print" <<EOF
#!/usr/bin/env bash
exec $CLAUDE_QUOTED --print --no-session-persistence --setting-sources project,local --dangerously-skip-permissions --tools Bash,Read "\$@"
EOF
chmod +x "$LAB/claude-print"
export FM_T3_LEADER_CLAUDE_BIN="$LAB/claude-print" DISABLE_AUTOUPDATER=1
export FM_T3_BIN FM_T3_BASE_DIR
scope_env() {
 env -u CLAUDECODE -u CLAUDE_PID -u CLAUDE_CODE_SESSION_ID -u FM_TASK_ID -u FM_ROOT -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE FM_HOME="$LEADER_HOME" "$@"
}
helper() { scope_env bash "$LEADER_HOME/bin/fm-t3-leader.sh" "$@"; }
wait_phase() {
 local expected=$1 i=0
 while [ "$i" -lt 360 ]; do
  if [ -f "$LEADER_HOME/state/.t3-leader-handover.json" ] && [ "$(jq -r .phase "$LEADER_HOME/state/.t3-leader-handover.json")" = "$expected" ]; then return 0; fi
  sleep 1
  i=$((i + 1))
 done
 printf 'handover timed out waiting for phase %s; retain %s\n' "$expected" "$LAB" >&2
 exit 1
}
wait_departed() {
 local target=$1 i=0
 while [ "$i" -lt 120 ]; do
  if ! kill -0 "$target" 2>/dev/null && ! ps -p "$target" -o pid= >/dev/null 2>&1; then return 0; fi
  sleep 1
  i=$((i + 1))
 done
 printf 'exact outgoing pid %s still exists; retain %s\n' "$target" "$LAB" >&2
 exit 1
}
PROMPT="This is the isolated leader-handover acceptance test in $LEADER_HOME. Native SessionStart must have acquired exactly this home's lock before any work. Do not run another session-start if its digest is present. First run bash bin/fm-t3-leader.sh prepare --to t3 --model $MODEL --dry-run and verify state/.t3-leader-handover.json was not created. Then run bash bin/fm-t3-leader.sh prepare --to t3 --model $MODEL --persisted. There is no open work to persist and no fleet or check to supervise. Finish immediately after successful prepare, without any other work."
(cd "$LEADER_HOME" && scope_env "$LAB/claude-print" --model "$MODEL" "$PROMPT") > "$PROOF/terminal-prepare.txt" 2>&1
wait_phase prepared
cp "$LEADER_HOME/state/.t3-leader-handover.json" "$PROOF/forward-prepared.json"
OUTGOING=$(jq -r .outgoingPid "$PROOF/forward-prepared.json")
wait_departed "$OUTGOING"
helper activate --dry-run > "$PROOF/forward-activate-dry-run.txt"
cmp "$LEADER_HOME/state/.t3-leader-handover.json" "$PROOF/forward-prepared.json"
helper activate > "$PROOF/forward-activate.txt" 2>&1
wait_phase confirmed
cp "$LEADER_HOME/state/.t3-leader-handover.json" "$PROOF/forward-confirmed.json"
for file in .lock .lock-session .lock-runtime; do [ ! -f "$LEADER_HOME/state/$file" ] || cp "$LEADER_HOME/state/$file" "$PROOF/forward$file"; done
THREAD=$(jq -r .threadId "$PROOF/forward-confirmed.json")
mkdir "$LAB/native-record"
jq --arg worktree "$LEADER_HOME" '. + {worktree:$worktree,title:"Firstmate leader",provider:"claudeAgent"}' "$PROOF/forward-confirmed.json" > "$LAB/native-record/thread.json"
cat > "$PROOF/reverse-prompt.txt" <<EOF
Continue only this isolated handover test. First run bash bin/fm-t3-leader.sh prepare --to terminal --model $MODEL --dry-run and verify the existing handover still says confirmed. Then run bash bin/fm-t3-leader.sh prepare --to terminal --model $MODEL --persisted. There is no open work to persist. Finish immediately after prepare. Do not stop any process, create work, register checks, or change any service/configuration.
EOF
"$FM_T3_BIN" thread send "$THREAD" - --base-dir "$FM_T3_BASE_DIR" --json < "$PROOF/reverse-prompt.txt" > "$PROOF/reverse-send.json"
wait_phase prepared
cp "$LEADER_HOME/state/.t3-leader-handover.json" "$PROOF/reverse-prepared.json"
if helper activate --dry-run > "$PROOF/reverse-refuse-live.txt" 2>&1; then printf 'ERROR reverse activation accepted live outgoing leader\n' >&2; exit 1; fi
OUTGOING=$(jq -r .outgoingPid "$PROOF/reverse-prepared.json")
# Only this exact saved project's one recorded thread may be removed.
# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source t3
fm_backend_t3_kill "$LAB/native-record" > "$PROOF/close-t3.txt" 2>&1
wait_departed "$OUTGOING"
printf '{"pid":%s,"exited":true}\n' "$OUTGOING" > "$PROOF/t3-process-exited.json"
helper activate --dry-run > "$PROOF/reverse-activate-dry-run.txt"
cmp "$LEADER_HOME/state/.t3-leader-handover.json" "$PROOF/reverse-prepared.json"
helper activate > "$PROOF/reverse-activate.txt" 2>&1
wait_phase confirmed
cp "$LEADER_HOME/state/.t3-leader-handover.json" "$PROOF/reverse-confirmed.json"
OUTGOING=$(jq -r .successorPid "$PROOF/reverse-confirmed.json")
wait_departed "$OUTGOING"
printf '{"pid":%s,"exited":true}\n' "$OUTGOING" > "$PROOF/terminal-process-exited.json"
jq -e '.phase == "confirmed" and .destination == "t3" and .successorPid != .outgoingPid' "$PROOF/forward-confirmed.json" >/dev/null
jq -e '.phase == "confirmed" and .destination == "terminal" and .successorPid != .outgoingPid' "$PROOF/reverse-confirmed.json" >/dev/null
printf 'ok - real terminal -> T3 -> terminal Claude handover, dry-runs, outgoing-live refusal and exact process exits\n'
