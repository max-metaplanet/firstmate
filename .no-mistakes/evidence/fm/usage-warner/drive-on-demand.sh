#!/usr/bin/env bash
# Live drive of bin/fm-usage-warner.sh against the REAL quota-axi read in a throwaway FM_HOME.
set -u
ROOT=/Users/max/.no-mistakes/worktrees/61c6dd39b831/01M37WQ78FK5ZNWFRM18FZ8GBR
W="$ROOT/bin/fm-usage-warner.sh"
T=$(mktemp -d /tmp/fm-uw-live.XXXXXX); T=$(cd "$T" && pwd -P)
REALQ=$(command -v quota-axi)
mkdir -p "$T/bin" "$T/home"
# argv-logging passthrough to the real quota-axi, and an osascript recorder
cat > "$T/bin/quota-axi" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$T/quota-argv.log"
exec "$REALQ" "\$@"
SH
cat > "$T/bin/osascript" <<SH
#!/usr/bin/env bash
printf 'NOTIFY argv-last=%s\n' "\${@: -1}" >> "$T/notify.log"
SH
chmod +x "$T/bin/"*
H="$T/home"
run() { echo "\$ fm-usage-warner.sh $*"; PATH="$T/bin:$PATH" FM_HOME="$H" "$W" "$@"; echo "[exit=$?]"; }
echo "== live quota-axi windows (real read) =="
"$REALQ" --provider claude --json --full --no-credential-refresh | jq -c '[.. | objects | select(has("windows")) | .windows[] | {id,percentUsed}]'
echo; echo "== S1 unconfigured home: check silent, arm refuses, nothing written =="
run check; FM_CHECK_TIMEOUT=bogus PATH=/usr/bin:/bin FM_HOME="$H" "$W" check; echo "[exit=$? with quota-axi absent from PATH and bogus FM_CHECK_TIMEOUT]"
run arm
echo "state dir: $(ls -A "$H" 2>/dev/null | tr '\n' ' ')(empty means nothing written)"
echo; echo "== S2 configure five_hour:20 (live reads above), seven_day:90, model:fable:50 =="
mkdir -p "$H/config"; printf 'five_hour:20\nseven_day:90\nmodel:fable:50\n' > "$H/config/usage-warner"
run check
echo "notifications so far: $(wc -l < "$T/notify.log" 2>/dev/null || echo 0)"; cat "$T/notify.log" 2>/dev/null
echo "--- de-dupe record ---"; cat "$H/state/.usage-warner"
echo; echo "== S3 repeat on-demand check while still above: stays quiet =="
run check; run check
echo "notifications so far: $(wc -l < "$T/notify.log")"
echo; echo "== S4 window reads below threshold (threshold raised to 99) then crosses again (back to 20) =="
printf 'five_hour:99\nseven_day:90\n' > "$H/config/usage-warner"; run check
echo "--- record after drop ---"; cat "$H/state/.usage-warner"
printf 'five_hour:20\nseven_day:90\n' > "$H/config/usage-warner"; run check
echo "notifications so far: $(wc -l < "$T/notify.log")"; cat "$T/notify.log"
echo; echo "== S5 every quota-axi invocation argv (read-only proof) =="
cat "$T/quota-argv.log"
grep -q -- '--allow-keychain-prompt' "$T/quota-argv.log" && echo "FAIL: credential refresh requested" || echo "no --allow-keychain-prompt in any call"
grep -vc -- '--no-credential-refresh' "$T/quota-argv.log" | sed 's/^/calls missing --no-credential-refresh: /'
rm -rf "$T"
