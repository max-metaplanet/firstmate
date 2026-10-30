#!/usr/bin/env bash
# Native T3 adapter behavior through backend/send/peek/control interfaces.
set -euo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
work=$(fm_test_tmproot fm-backend-t3)
mkdir -p "$work/home/state" "$work/home/data" "$work/home/config" "$work/bin" "$work/base" "$work/checkout"
export FM_HOME="$work/home" FM_ROOT_OVERRIDE="$ROOT" FM_T3_BIN="$work/bin/t3" FM_T3_BASE_DIR="$work/base"
export T3_FIXTURE="$work"
unset FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE
record="$FM_HOME/state/worker.t3"
mkdir "$record"
cat > "$work/bin/t3" <<'T3'
#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
root = Path(os.environ['T3_FIXTURE'])
args = sys.argv[1:]
with (root / 'calls').open('a') as f:
    f.write(json.dumps(args) + '\n')
if args[:2] == ['thread', 'show']:
    print((root / 'show.json').read_text())
elif args[:2] == ['thread', 'list']:
    print((root / 'list.json').read_text())
elif args[:2] == ['thread', 'send']:
    (root / 'sent').write_text(sys.stdin.read())
    if (root / 'fail-send').exists():
        sys.exit(1)
    print('{"threadId":"owned-thread","messageId":"next-message","runId":"next-run","status":"queued","delivery":"queued"}')
elif args[:2] == ['project', 'remove']:
    if (root / 'fail-remove').exists():
        sys.exit(1)
    (root / 'removed').write_text(args[2])
    print('Removed project owned-project.')
else:
    sys.exit(3)
T3
chmod +x "$work/bin/t3"
jq -n --arg binary "$FM_T3_BIN" --arg base "$FM_T3_BASE_DIR" --arg wt "$work/checkout" \
  '{version:1,binary:$binary,base:$base,worktree:$wt,threadId:"owned-thread",projectId:"owned-project"}' > "$record/thread.json"
printf '{"thread":{"threadId":"owned-thread","projectId":"owned-project","status":"running","activeRunId":"run-1","pendingRequestCount":0},"messages":[{"role":"assistant","text":"native progress"}]}\n' > "$work/show.json"
printf '[{"threadId":"owned-thread","projectId":"owned-project"}]\n' > "$work/list.json"
cat > "$FM_HOME/state/worker.meta" <<META
window=$record
endpoint_task_id=worker
worktree=$work/checkout
project=$work/primary
harness=codex
kind=scout
backend=t3
META
# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-busy-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-task-inbox-lib.sh"

expect_failure() { if "$@" > "$work/failure" 2>&1; then fail "unexpected success: $*"; fi; }
fm_backend_validate_spawn t3
fm_backend_validate_task_endpoint "$FM_HOME/state/worker.meta" worker
assert_contains "$(bash "$ROOT/bin/fm-peek.sh" worker)" 'native progress' 'peek must render native transcript'
[ "$(fm_busy_classify t3 "$record" codex worker "$FM_HOME/state")" = 'busy t3-native' ] || fail 'Codex native run must be busy'
[ "$(fm_backend_agent_state t3 "$record")" = unverified ] || fail 'native thread must not claim process identity'
pass 'normal task metadata routes native capture and semantic busy state'

cp "$FM_HOME/state/worker.meta" "$work/scout.meta"
sed 's/kind=scout/kind=secondmate/' "$work/scout.meta" > "$FM_HOME/state/worker.meta"
assert_contains "$(bash "$ROOT/bin/fm-crew-state.sh" worker)" 'state: working' 'native secondmate active runs must answer through the normal current-state reader'
cp "$work/scout.meta" "$FM_HOME/state/worker.meta"
pass 'native secondmate current activity is independent of process-recovery support'

jq '.thread.activeRunId=null | .thread.status="completed"' "$work/show.json" > "$work/show.new"
mv "$work/show.new" "$work/show.json"
[ "$(fm_busy_classify t3 "$record" codex worker "$FM_HOME/state")" = 'idle t3-native' ] || fail 'settled native run must be idle'
jq '.thread.pendingRequestCount=1' "$work/show.json" > "$work/show.new"
mv "$work/show.new" "$work/show.json"
[ "$(fm_backend_busy_state t3 "$record")" = busy ] || fail 'queued native requests must remain busy'
pass 'settled and queued native state do not depend on rendered terminal signatures'

before=$(wc -l < "$work/calls")
for verb in interrupt exit; do
  expect_failure bash "$ROOT/bin/fm-control.sh" worker "$verb"
  assert_contains "$(cat "$work/failure")" 'T3 does not expose' 'unsupported lifecycle needs a concrete refusal'
done
expect_failure fm_backend_send_key t3 "$record" Enter
[ "$(wc -l < "$work/calls")" -eq "$before" ] || fail 'unsupported lifecycle contacted T3'
pass 'lifecycle and raw keys refuse before contacting T3'

mkdir -p "$FM_HOME/state/worker.inbox/handled"
printf 'steer\n' > "$FM_HOME/state/worker.inbox/1.msg"
fm_task_inbox_ring t3 "$record" "$FM_HOME/state/worker.inbox/1.msg" fm-worker
before=$(wc -l < "$work/calls")
fm_task_inbox_ring t3 "$record" "$FM_HOME/state/worker.inbox/1.msg" fm-worker
[ "$(wc -l < "$work/calls")" -eq "$before" ] || fail 'accepted native ring was queued again'
assert_contains "$(cat "$work/sent")" 'instruction' 'native ring must send the durable inbox doorbell'
assert_contains "$(cat "$work/sent")" "$FM_HOME/state/worker.inbox" 'native ring must carry the exact inbox path without inherited environment'
if [[ $(cat "$work/sent") == *"\$FM_TASK_INBOX"* ]]; then fail 'native ring depended on provider environment'; fi
touch "$work/fail-send"
printf 'next steer\n' > "$FM_HOME/state/worker.inbox/2.msg"
expect_failure fm_task_inbox_ring t3 "$record" "$FM_HOME/state/worker.inbox/2.msg" fm-worker
before=$(wc -l < "$work/calls")
expect_failure fm_task_inbox_ring t3 "$record" "$FM_HOME/state/worker.inbox/2.msg" fm-worker
[ "$(wc -l < "$work/calls")" -eq "$before" ] || fail 'uncertain native ring was blindly retried'
rm "$work/fail-send"
pass 'accepted and uncertain inbox rings are never blindly queued twice'

before=$(wc -l < "$work/calls")
expect_failure fm_backend_send_text_submit t3 "$record" /no-mistakes 1 0 0
[ "$(wc -l < "$work/calls")" -eq "$before" ] || fail 'unsupported parser invocation contacted T3'
[ "$(fm_backend_send_text_submit t3 "$record" 'ordinary native text' 1 0 0)" = empty ] || fail 'native send was not accepted'
[ "$(cat "$work/sent")" = 'ordinary native text' ] || fail 'native text changed in transit'
pass 'native messages use protocol delivery and refuse terminal parser commands'

printf '[{"threadId":"owned-thread","projectId":"owned-project"},{"threadId":"foreign","projectId":"owned-project"}]\n' > "$work/list.json"
expect_failure fm_backend_kill t3 "$record"
[ ! -f "$work/removed" ] || fail 'cleanup removed a project containing another thread'
printf '[{"threadId":"owned-thread","projectId":"owned-project"}]\n' > "$work/list.json"
touch "$work/fail-remove"
expect_failure fm_backend_kill t3 "$record"
[ ! -e "$record/closed" ] || fail 'failed cleanup was reported as closed'
rm "$work/fail-remove"
fm_backend_kill t3 "$record"
[ "$(cat "$work/removed")" = owned-project ] || fail 'cleanup targeted another project'
before=$(wc -l < "$work/calls")
fm_backend_kill t3 "$record"
[ "$(wc -l < "$work/calls")" -eq "$before" ] || fail 'confirmed cleanup was repeated'
pass 'cleanup refuses unrelated threads and records only an accepted exact project removal'

jq '.thread.projectId="foreign-project"' "$work/show.json" > "$work/show.new"
mv "$work/show.new" "$work/show.json"
expect_failure fm_backend_capture t3 "$record" 40
pass 'a mismatched native project cannot masquerade as the recorded worker'

touch "$FM_HOME/config/claude-account"
expect_failure fm_backend_t3_preflight claude test-model '' scout "$FM_HOME/config"
assert_contains "$(cat "$work/failure")" 'cannot honor config/claude-account' 'unsupported pins must fail closed'
rm "$FM_HOME/config/claude-account"
fm_backend_t3_preflight claude test-model '' scout "$FM_HOME/config"
expect_failure fm_backend_t3_preflight codex test-model '' secondmate "$FM_HOME/config"
pass 'native preflight preserves explicit account and supported-role boundaries'
