#!/usr/bin/env bash
# Live: real fm-seat-pipeline.sh launch gate; quota endpoint replaced by a
# disposable local quota-axi that serves scripted documents (good, 429 w/ retryAfter,
# low quota, unreadable) so rate-limit paths can be forced. Real wall-clock aging.
set -u
WT=$1
CLAUDE=$(command -v claude)
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
trap 'rm -rf "$LAB"' EXIT
"$WT/bin/fm-lab-home.sh" create "$LAB" >/dev/null
printf 'stop\n' > "$LAB/config/claude-seat-extra-usage"
mkdir -p "$LAB/shim" "$LAB/pA" "$LAB/pB" "$LAB/pC"
cat > "$LAB/shim/quota-axi" <<SH
#!/usr/bin/env bash
printf '%s %s\n' "\$(date +%T)" "\$CLAUDE_CONFIG_DIR" >> "$LAB/calls"
cat "\$CLAUDE_CONFIG_DIR/doc.json"
SH
chmod +x "$LAB/shim/quota-axi"
export PATH="$LAB/shim:$PATH" FM_SEAT_QUOTA_CACHE_ROOT="$LAB/cache"
unset CLAUDE_CODE_OAUTH_TOKEN CLAUDE_SECURESTORAGE_CONFIG_DIR NM_CLAUDE_CONFIG_DIR
good() { python3 - "$1" <<'PY'
import json,sys,datetime
left=int(sys.argv[1]); now=datetime.datetime.now(datetime.timezone.utc).isoformat()
print(json.dumps({"schemaVersion":5,"providers":[{"provider":"claude","source":"oauth",
 "state":{"status":"fresh","stale":False,"refreshedAt":now},
 "windows":[{"id":"five_hour","kind":"session","percentRemaining":left},{"id":"seven_day","kind":"weekly","percentRemaining":left}],
 "quotaSemantics":{"status":"known","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":left,"boundedBy":["five_hour","seven_day"],"runway":{"status":"through_reset"}}]}}]}))
PY
}
limited() { python3 - "$1" <<'PY'
import json,sys,datetime
st={"status":"rate_limited","error":"429"}
if int(sys.argv[1])>0: st["retryAfter"]=(datetime.datetime.now(datetime.timezone.utc)+datetime.timedelta(seconds=int(sys.argv[1]))).isoformat()
print(json.dumps({"schemaVersion":5,"providers":[{"provider":"claude","source":"unavailable","windows":[],"state":st,"quotaSemantics":{"status":"unknown","effectiveAvailability":[]}}]}))
PY
}
launch() { echo "-- launch on $1"; env -u NO_MISTAKES_GATE "$WT/bin/fm-seat-pipeline.sh" launch --default-profile "$LAB/$1" "$LAB" "$CLAUDE" --version 2>&1 | grep -v 'not recorded for this home'; echo "   exit=${PIPESTATUS[0]}  live calls on $1 so far: $(grep -c "/$1\$" "$LAB/calls" 2>/dev/null || echo 0)"; }
: > "$LAB/calls"
echo "== seed: pA healthy (80%), pB low (25%, floor 15 => boundary 25), pC never read"
printf '15\n' > "$LAB/config/claude-seat-floor"
good 80 > "$LAB/pA/doc.json"; good 25 > "$LAB/pB/doc.json"
launch pA; launch pB
echo "== endpoint now returns 429: pA retryAfter=+400s, pB no retryAfter, pC retryAfter=+400s with no last-good"
limited 400 > "$LAB/pA/doc.json"; limited 0 > "$LAB/pB/doc.json"; limited 400 > "$LAB/pC/doc.json"
echo "== within 2-minute TTL: no live call expected"
launch pA
echo "== S3: unreadable/no last-good holds exactly as before"
launch pC
echo "== S4: retry-after on pC: second launch must not call the endpoint"
launch pC
echo "== sleeping 125s so cached readings pass the 2-minute TTL (real clock)"
sleep 125
echo "== S5: recent comfortable last-good used as fallback after 429"
launch pA
echo "== S6: retry-after honored: next launch inside the window makes no live call, still visible fallback"
launch pA
echo "== S7: low-quota last-good (25% vs boundary 25) must hold, not fall back"
launch pB
echo "== endpoint call log"; cat "$LAB/calls"
