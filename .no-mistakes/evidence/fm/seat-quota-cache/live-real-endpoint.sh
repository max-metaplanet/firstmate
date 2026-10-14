#!/usr/bin/env bash
# Live: real fm-seat-pipeline.sh launch + real quota-axi against the machine's
# real Claude login (read-only, --no-credential-refresh), isolated lab home and
# isolated cache root. A PATH shim only counts calls and execs the real quota-axi.
set -u
WT=$1
REAL=$(command -v quota-axi)
CLAUDE=$(command -v claude)
PROFILE=$HOME/.claude-seats/seat-max-gmail
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
trap 'rm -rf "$LAB"' EXIT
"$WT/bin/fm-lab-home.sh" create "$LAB" >/dev/null
printf 'stop\n' > "$LAB/config/claude-seat-extra-usage"
mkdir -p "$LAB/shim"
cat > "$LAB/shim/quota-axi" <<SH
#!/usr/bin/env bash
printf '%s pid=%s %s\n' "\$(date +%T)" "\$\$" "\$*" >> "$LAB/calls"
exec "$REAL" "\$@"
SH
chmod +x "$LAB/shim/quota-axi"
export PATH="$LAB/shim:$PATH" FM_SEAT_QUOTA_CACHE_ROOT="$LAB/cache"
unset CLAUDE_CODE_OAUTH_TOKEN CLAUDE_SECURESTORAGE_CONFIG_DIR NM_CLAUDE_CONFIG_DIR FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE FM_DATA_OVERRIDE
launch() { env -u NO_MISTAKES_GATE "$WT/bin/fm-seat-pipeline.sh" launch --default-profile "$PROFILE" "$LAB" "$CLAUDE" --version 2>&1 | grep -v 'not recorded for this home'; }
echo "== S1: three sequential pipeline-agent launches (real quota endpoint)"
for i in 1 2 3; do echo "-- launch $i"; launch; done
echo "quota-axi live calls so far: $(wc -l < "$LAB/calls")"
echo "== cache dir perms"; ls -la "$LAB/cache" | sed 1d
echo "== S2: cold cache, 6 concurrent launches"
rm -f "$LAB/cache"/*.json; : > "$LAB/calls"
for i in 1 2 3 4 5 6; do (launch > "$LAB/out.$i") & done; wait
for i in 1 2 3 4 5 6; do echo "-- concurrent $i"; cat "$LAB/out.$i"; done
echo "quota-axi live calls for the burst of 6: $(wc -l < "$LAB/calls")"
cat "$LAB/calls"
