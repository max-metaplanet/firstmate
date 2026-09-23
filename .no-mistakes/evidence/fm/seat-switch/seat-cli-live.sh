#!/usr/bin/env bash
# Live CLI transcript of bin/fm-seat.sh in a throwaway FM_HOME.
set -u
ROOT=/Users/max/.no-mistakes/worktrees/61c6dd39b831/01M37ZTM3S1MSB43MCT4NNZRTF
T=$(mktemp -d "${TMPDIR:-/tmp}/fm-seat-live.XXXXXX")
H=$T/home; S=$T/seats; mkdir -p $H/config $H/state $H/data $S
printf '%s\n' "$S" > $H/config/claude-seats-root
seat() { echo; echo "\$ fm-seat.sh $*"; FM_HOME=$H FM_ROOT_OVERRIDE=$ROOT CLAUDE_CONFIG_DIR= PATH="${EXTRA_PATH:-}$PATH" "$ROOT/bin/fm-seat.sh" "$@" 2>&1; echo "[exit $?]"; }
echo "### Part A: REAL installed quota-axi ($(command -v quota-axi)), empty profiles, no sign-in"
seat status
seat add work
seat add spare
echo "(profile dirs now: $(ls $S | tr '\n' ' ') ; files inside work: $(ls -A $S/work | wc -l | tr -d ' '))"
seat list
seat probe work
seat switch work
echo "(config/claude-seat after refused switch: $(cat $H/config/claude-seat 2>/dev/null || echo '<absent>'))"
seat switch work --force
echo "(config/claude-seat: $(cat $H/config/claude-seat))"
seat switch nosuch --force
seat switch ../escape --force
echo "(config/claude-seat still: $(cat $H/config/claude-seat))"
seat threshold
seat threshold-reached
seat threshold 15
seat threshold
seat threshold-reached
seat switch default
echo "(config/claude-seat: $(cat $H/config/claude-seat 2>/dev/null || echo '<absent>'))"

echo; echo "### Part B: stub quota-axi reporting work+spare signed in; remaining quota driven by a file"
FB=$T/fakebin; mkdir -p $FB
cat > $FB/quota-axi <<SH
#!/usr/bin/env bash
case "\${CLAUDE_CONFIG_DIR:-}" in
  $S/work|$S/spare) r=\$(cat $T/remaining-\$(basename "\$CLAUDE_CONFIG_DIR") 2>/dev/null || echo 80)
    printf '{"schemaVersion":5,"providers":[{"provider":"claude","source":"oauth","account":{"email":"%s@example.test"},"quotaSemantics":{"status":"known","effectiveAvailability":[{"scope":"model:opus","status":"known","effectivePercentRemaining":1},{"scope":"all_models","status":"known","effectivePercentRemaining":%s}]}}]}\n' "\$(basename "\$CLAUDE_CONFIG_DIR")" "\$r"; exit 0;;
esac
echo '{"schemaVersion":5,"providers":[{"provider":"claude","source":"unavailable","attempts":[{"source":"oauth-file","status":"skipped","error":"credentials_missing"},{"source":"keychain","status":"skipped","error":"keychain_unreachable"}],"quotaSemantics":{"status":"unknown","effectiveAvailability":[]}}]}'; exit 1
SH
chmod +x $FB/quota-axi
export EXTRA_PATH=$FB:
seat list
seat switch work
seat status
echo 50 > $T/remaining-work
echo "(work all_models=50%, model:opus=1%, threshold 15)"; seat threshold-reached
echo 12 > $T/remaining-work
echo "(work all_models=12%, threshold 15)"; seat threshold-reached
seat switch --next
seat switch --next
echo; echo "### Part C: automatic path - arm the watch and run its real blocking child once"
seat switch work
seat arm --interval 1 --stable 1
seat status
SID=$(FM_HOME=$H "$ROOT/bin/fm-procevent-when.sh" source-id claude-seat)
echo "\$ fm-procevent-when.sh run $SID   (the watcher's child, bounded to 30s)"
FM_HOME=$H FM_ROOT_OVERRIDE=$ROOT CLAUDE_CONFIG_DIR= PATH="$FB:$PATH" perl -e "alarm 30; exec @ARGV" "$ROOT/bin/fm-procevent-when.sh" run "$SID" 2>&1 | tail -5; echo "[exit ${PIPESTATUS[0]}]"
echo "(config/claude-seat after the watch fired: $(cat $H/config/claude-seat))"
seat retire
rm -rf "$T"
