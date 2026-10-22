#!/usr/bin/env bash
# Live CLI drive of bin/fm-work-intake.sh against a disposable home + fake GET-only source hook.
set -u
ROOT=$1
H=$(mktemp -d "${TMPDIR:-/tmp}/fm-intake-live.XXXXXX")
trap 'rm -rf "$H"' EXIT
mkdir -p "$H"/{state,config,data}
printf 'backend="markdown"\n[markdown]\npath="data/backlog.md"\narchive="data/done-archive.md"\ndone_keep=0\n' > "$H/.tasks.toml"
printf '## In flight\n\n## Queued\n\n## Done\n' > "$H/data/backlog.md"
cat > "$H/source" <<'PY'
#!/usr/bin/env python3
import json, pathlib, sys
from datetime import datetime, timezone
p=pathlib.Path(__file__).parent
with (p/'calls').open('a') as s: s.write('GET '+repr(sys.argv[1:])+'\n')
v=json.loads((p/'source.json').read_text())
v['observed_at']=datetime.now(timezone.utc).isoformat()
if '--refresh' in sys.argv:
    ref=sys.argv[sys.argv.index('--refresh')+1]
    v['mode']='refresh'; v['candidates']=[r for r in v['candidates'] if r['source_ref']==ref]
    v['coverage'].update(complete=False,all_pages_read=False,absence_means_withdrawal=False)
    for r in v['candidates']:
        r['source_revision']+='-full'; r['scope']['comments_complete']=True; r['scope']['comments']=[]
v['coverage']['task_count']=len(v['candidates'])
for r in v['candidates']: r['observed_at']=v['observed_at']
print(json.dumps(v))
PY
chmod 755 "$H/source"; echo "$H/source" > "$H/config/work-intake-hook"
export FM_HOME="$H" FM_DATA_OVERRIDE="$H/data" FM_STATE_OVERRIDE="$H/state" FM_CONFIG_OVERRIDE="$H/config"
unset TASKS_AXI_FILE TASKS_AXI_BACKEND FM_TASK_ID
I() { echo "\$ fm-work-intake.sh $*"; bash "$ROOT/bin/fm-work-intake.sh" "$@"; echo "[exit=$?]"; }
T() { bash "$ROOT/bin/fm-tasks-axi.sh" "$@"; }
cand() { # ref ticket title eligible reasons_json status
python3 - "$@" <<'PY'
import json,sys
ref,ticket,title,elig,reasons,status=sys.argv[1:]
print(json.dumps(dict(source_ref=ref,source_revision='r1',ticket=ticket,title=title,url='https://app.clickup.com/t/'+ref,
 eligibility=dict(eligible=elig=='1',exclusion_reasons=json.loads(reasons),proposal='backlog_promotion' if status=='backlog' else None,requires_scope_review=True),
 priority=dict(value='normal',rank=3,provenance='unset',native=None),dates=dict(hard_deadline=None,due_at=None,time_estimate_ms=None),
 scope=dict(description='Acceptance: x',comments_complete=False,comments=None,parent=None),
 source_evidence=dict(ownership='sole',status=status,blocked_tags=[]))))
PY
}
snap() { python3 -c 'import json,sys; c=[json.loads(l) for l in sys.stdin if l.strip()]; print(json.dumps(dict(schema="clickup-axi.queue",version=1,source_namespace="lab",mode="scan",coverage=dict(complete=True,all_pages_read=True,absence_means_withdrawal=True,task_count=len(c),scope="active_nonclosed_tasks"),report=dict(ownership_coverage_gap=False,eligible_count=sum(x["eligibility"]["eligible"] for x in c)),candidates=c)))' > "$H/source.json"; }

echo "=== S1: board with zero Max-assigned Up next tickets (unassigned, other person's, Requests, Max backlog) ==="
{ cand u1 ENG-10 "Unassigned up next" 0 '["unassigned"]' "up next"
  cand o1 ENG-11 "Someone else's up next" 0 '["assigned_to_other"]' "up next"
  cand q1 ENG-12 "Requests list item" 0 '["requests_list"]' "up next"
  cand b1 ENG-13 "Max backlog item" 0 '["status_backlog"]' backlog; } | snap
I preview --json
echo "--- queue after preview (must be empty, no receipt) ---"; T list --state queued; ls "$H/state"
echo "=== S2: poll without activation is a no-op ==="
I poll --json; ls "$H/state"
echo "=== S3: Max Up next ticket appears; captain already has a title-convention row for ENG-21 ==="
T add eng21-rollout "ENG-21 rollout: captain-authored" >/dev/null
{ cand m1 ENG-20 "Implement intake target" 1 '[]' "up next"
  cand m2 ENG-21 "Rollout already queued locally" 1 '[]' "up next"
  cand o1 ENG-11 "Someone else's up next" 0 '["assigned_to_other"]' "up next"; } | snap
I preview --json
echo 1 > "$H/config/work-intake-enabled"
I poll --json
echo "--- queue after first poll ---"; T list --state queued --fields body
echo "=== S4: second poll (cooldown expired) imports nothing new ==="
python3 -c "import json,sys;p=sys.argv[1];s=json.load(open(p));s['next_poll']=0;json.dump(s,open(p,'w'))" "$H/state/work-intake.json"
I poll --json
echo "--- queued row count ---"; T list --state queued | head -3
ID=$(python3 -c "import json,sys;s=json.load(open(sys.argv[1]));print([e['local_id'] for e in s['entries'].values() if e['phase']=='imported'][0])" "$H/state/work-intake.json")
echo "=== S5: dispatch gate — imported $ID refused before review; captain row eng21-rollout not gated ==="
I check "$ID" --json
I check eng21-rollout --json
echo "--- review then check ---"
REV=$(bash "$ROOT/bin/fm-work-intake.sh" refresh "$ID" --json | python3 -c 'import json,sys;print(json.load(sys.stdin)["candidate"]["source_revision"])')
printf '{"authorized":true,"project":"lab","kind":"ship","reason":"scope ok","source_revision":"%s","identity_checked":true}\n' "$REV" > "$H/decision.json"
I review "$ID" --decision-file "$H/decision.json" --json
I check "$ID" --json
echo "=== source calls (GET-only hook) ==="; cat "$H/calls"
