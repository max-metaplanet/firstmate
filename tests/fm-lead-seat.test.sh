#!/usr/bin/env bash
# Leader-only selection through fm-seat.sh, with isolated profiles and quota CLI.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TEST_ROOT=$(fm_test_tmproot fm-lead-seat)
mkdir -p "$TEST_ROOT/home/config" "$TEST_ROOT/home/state" "$TEST_ROOT/bin" \
  "$TEST_ROOT/claude/current" "$TEST_ROOT/claude/alternate" "$TEST_ROOT/codex/work"
printf '%s\n' "$TEST_ROOT/claude" > "$TEST_ROOT/home/config/claude-seats-root"
printf '%s\n' "$TEST_ROOT/codex" > "$TEST_ROOT/home/config/codex-seats-root"
printf '%s\n' "$$" > "$TEST_ROOT/home/state/.lock"
printf 'pid=%s\nharness=claude\nprofile=%s\n' "$$" "$TEST_ROOT/claude/current" > "$TEST_ROOT/home/state/.lock-runtime"
printf '{"models":[{"slug":"gpt-6.1-sol"}]}\n' > "$TEST_ROOT/codex/work/models_cache.json"
cat > "$TEST_ROOT/bin/claude" <<'FAKE'
#!/usr/bin/env bash
printf 'Model aliases: opus sonnet\n'
FAKE
cat > "$TEST_ROOT/bin/quota-axi" <<'FAKE'
#!/usr/bin/env bash
provider=claude
json=0
while [ "$#" -gt 0 ]; do
  case "$1" in --provider) provider=$2; shift ;; --json) json=1 ;; esac
  shift
done
profile=${CLAUDE_CONFIG_DIR:-}
[ "$provider" != codex ] || profile=$CODEX_HOME
printf '%s %s %s\n' "$provider" "$profile" "$json" >> "$LEAD_TEST_CALLS"
if [ "$json" -eq 1 ]; then cat "$profile/quota.json"; else cat "$profile/quota.toon"; fi
FAKE
chmod +x "$TEST_ROOT/bin/claude" "$TEST_ROOT/bin/quota-axi"
export LEAD_TEST_CALLS="$TEST_ROOT/calls"
quota() {
  local provider=$1 name=$2 score=$3 runway=${4:-through_reset} seconds=${5:-999} remaining=${6:-60}
  local profile="$TEST_ROOT/$provider/$name"
  cat > "$profile/quota.toon" <<TOON
bin: quota-axi
quota[1]{provider,accountKey,scope,effectivePercentRemaining,spendPriority,runway,confidence,limitedBy,resetsAt}:
  $provider,$([ "$provider" = codex ] && echo codex-home || echo default),all_models,$remaining,$score,$runway,high,weekly,2030-01-01T00:00:00Z
exhaustion[1]{provider,accountKey,scope,usableRunwaySeconds,projectedExhaustedAt,limitingWindowId}:
  $provider,$([ "$provider" = codex ] && echo codex-home || echo default),all_models,$seconds,2030-01-01T00:00:00Z,weekly
attention[0]:
TOON
  jq -cn --arg provider "$provider" --arg score "$score" --arg runway "$runway" \
    --argjson remaining "$remaining" --argjson seconds "$seconds" \
    '{schemaVersion:5,providers:[{provider:$provider,source:"oauth",quotaSemantics:{effectiveAvailability:[{scope:"all_models",status:"known",effectivePercentRemaining:$remaining,selection:{spendPriority:($score|tonumber?)},runway:{status:$runway,usableRunwaySeconds:$seconds}}]}}]}' > "$profile/quota.json"
}
choose() {
  FM_HOME="$TEST_ROOT/home" PATH="$TEST_ROOT/bin:$PATH" bash "$ROOT/bin/fm-seat.sh" leader-destination 2> "$TEST_ROOT/evidence"
}
quota claude alternate 0.2
quota codex work 0.9
out=$(choose)
[ "$out" = 'claude alternate' ] || fail "Codex automatic destinations must default off: $out"
assert_grep 'policy withheld: config/lead-codex-auto is off' "$TEST_ROOT/evidence" 'withheld Codex must be accounted for'
printf 'invalid\n' > "$TEST_ROOT/home/config/lead-codex-auto"
if out=$(choose); then fail 'malformed rollout switch must refuse selection'; fi
printf 'on\n' > "$TEST_ROOT/home/config/lead-codex-auto"
: > "$LEAD_TEST_CALLS"
out=$(choose)
[ "$out" = 'codex work' ] || fail "higher Codex spendPriority must win: $out"
assert_grep 'claude:current' "$TEST_ROOT/evidence" 'current seat must be accounted for'
assert_grep 'spendPriority=0.9' "$TEST_ROOT/evidence" 'scalar must be visible'
[ "$(wc -l < "$LEAD_TEST_CALLS" | tr -d ' ')" = 2 ] || fail 'known TOON must not fetch JSON'
pass 'leader ranks both native providers by spendPriority with TOON only'

quota claude alternate 0.95
out=$(choose)
[ "$out" = 'claude alternate' ] || fail "higher Claude spendPriority must win: $out"
pass 'leader selection has no provider preference'

quota claude alternate 0.9
if out=$(choose); then fail 'equal scalars must not route by enumeration order'; fi
assert_grep 'tied spendPriority' "$TEST_ROOT/evidence" 'tie must name its cause'
pass 'leader ties require a decision'

quota claude alternate 0.2
quota codex work 0.99 projected_exhaustion 179
out=$(choose)
[ "$out" = 'claude alternate' ] || fail 'higher score cannot override insufficient runway'
assert_grep 'below 180s' "$TEST_ROOT/evidence" 'horizon failure must be inspectable'
quota codex work 0.99 projected_exhaustion 180
out=$(choose)
[ "$out" = 'codex work' ] || fail 'runway reaching the horizon is feasible'
pass 'runway feasibility gates spendPriority'

quota codex work 0.99 unknown
out=$(choose)
[ "$out" = 'claude alternate' ] || fail 'unknown runway cannot be treated as feasible'
assert_grep "codex $TEST_ROOT/codex/work 1" "$LEAD_TEST_CALLS" 'ambiguity must trigger JSON fallback'
quota claude alternate 0.2 unknown
if out=$(choose); then fail 'no provable runway must hold'; fi
assert_grep 'no candidate with provable runway' "$TEST_ROOT/evidence" 'unmeasurable runway must hold explicitly'
pass 'unknown evidence falls back once and stays unknown'

quota claude alternate 0.2
quota codex work 0.99
printf 'work\n' > "$TEST_ROOT/home/config/codex-seat-auto-exclude"
out=$(choose)
[ "$out" = 'claude alternate' ] || fail 'excluded Codex seat must not win'
rm "$TEST_ROOT/home/config/codex-seat-auto-exclude"
printf '70\n' > "$TEST_ROOT/home/config/codex-seat-destination-min"
out=$(choose)
[ "$out" = 'claude alternate' ] || fail 'configured minimum must gate selection'
rm "$TEST_ROOT/home/config/codex-seat-destination-min"
printf '{"models":[{"slug":"another-model"}]}\n' > "$TEST_ROOT/codex/work/models_cache.json"
out=$(choose)
[ "$out" = 'claude alternate' ] || fail 'catalog omission must gate selection'
assert_grep 'omits gpt-6.1-sol' "$TEST_ROOT/evidence" 'catalog contradiction must be named'
pass 'exclusion, explicit floor, and native model availability are hard gates'

printf '{"models":[{"slug":"gpt-6.1-sol"}]}\n' > "$TEST_ROOT/codex/work/models_cache.json"
printf 'pid=%s\nharness=codex\nprofile=%s\n' "$$" "$TEST_ROOT/codex/work" > "$TEST_ROOT/home/state/.lock-runtime"
quota claude current 0.8
out=$(choose)
[ "$out" = 'claude current' ] || fail "Codex leader must rank every Claude seat: $out"
assert_grep 'current leader credential store' "$TEST_ROOT/evidence" 'current Codex seat must be excluded'
pass 'Codex runtime identity selects across providers without a Claude fallback rule'

# Select the native account and exact model scope; unrelated accounts/models
# cannot lend headroom or veto this profile's candidate.
printf 'pid=%s\nharness=claude\nprofile=%s\n' "$$" "$TEST_ROOT/claude/current" > "$TEST_ROOT/home/state/.lock-runtime"
quota claude alternate 0.2
quota codex work 0.9
cat > "$TEST_ROOT/codex/work/quota.toon" <<'TOON'
quota[4]{provider,accountKey,scope,effectivePercentRemaining,spendPriority,runway,confidence,limitedBy,resetsAt}:
  codex,unrelated,all_models,0,99,exhausted_now,high,weekly,2030-01-01T00:00:00Z
  codex,codex-home,all_models,80,0.9,through_reset,high,weekly,2030-01-01T00:00:00Z
  codex,codex-home,model:gpt-6.1-sol,0,0.9,exhausted_now,high,weekly,2030-01-01T00:00:00Z
  codex,codex-home,model:another-model,0,99,exhausted_now,high,weekly,2030-01-01T00:00:00Z
exhaustion[0]:
attention[0]:
TOON
out=$(choose)
[ "$out" = 'claude alternate' ] || fail 'exact model exhaustion must veto account room'
sed 's/model:gpt-6.1-sol,0,0.9,exhausted_now/model:gpt-6.1-sol,60,0.9,through_reset/' "$TEST_ROOT/codex/work/quota.toon" > "$TEST_ROOT/quota-next"
mv "$TEST_ROOT/quota-next" "$TEST_ROOT/codex/work/quota.toon"
out=$(choose)
[ "$out" = 'codex work' ] || fail 'unrelated account or model must not veto native candidate'
pass 'selection matches native account and exact model constraints'

sed 's/model:gpt-6.1-sol,60,0.9/model:gpt-6.1-sol,90,-0.8/' "$TEST_ROOT/codex/work/quota.toon" > "$TEST_ROOT/quota-next"
mv "$TEST_ROOT/quota-next" "$TEST_ROOT/codex/work/quota.toon"
out=$(choose)
[ "$out" = 'claude alternate' ] || fail 'higher model headroom must not hide its lower spendPriority'
assert_grep 'spendPriority=-0.8' "$TEST_ROOT/evidence" 'minimum applicable scalar must remain inspectable'
pass 'multi-scope ranking compares spendPriority independently of percentage headroom'

# Ambiguous TOON permits one JSON fallback; renewable credentials are not logout.
quota codex work 0.9 unknown
jq '.providers[0].state.authStatus="expired_refreshable" | .providers[0].quotaSemantics.effectiveAvailability[0].runway.status="through_reset"' \
  "$TEST_ROOT/codex/work/quota.json" > "$TEST_ROOT/quota-next"
mv "$TEST_ROOT/quota-next" "$TEST_ROOT/codex/work/quota.json"
: > "$LEAD_TEST_CALLS"
out=$(choose)
[ "$out" = 'codex work' ] || fail 'renewable expiry must not be classified signed out'
assert_grep 'auth=expired_refreshable' "$TEST_ROOT/evidence" 'selected auth evidence must be visible'
[ "$(rg -c "^codex .* 1$" "$LEAD_TEST_CALLS")" = 1 ] || fail 'one uncertain candidate must have exactly one JSON fallback'
jq '.providers[0].state.authStatus="credentials_invalid"' "$TEST_ROOT/codex/work/quota.json" > "$TEST_ROOT/quota-next"
mv "$TEST_ROOT/quota-next" "$TEST_ROOT/codex/work/quota.json"
out=$(choose)
[ "$out" = 'claude alternate' ] || fail 'contradictory local auth evidence cannot prove a usable destination'
assert_grep 'remains uncertain' "$TEST_ROOT/evidence" 'local auth classification must report uncertainty, not demand login'
pass 'credential uncertainty and renewable expiry stay distinct'

printf 'relative-root\n' > "$TEST_ROOT/home/config/codex-seats-root"
if out=$(choose); then fail 'relative root must refuse rather than omit candidates'; fi
printf '%s\n' "$TEST_ROOT/codex" > "$TEST_ROOT/home/config/codex-seats-root"
printf '10\n20\n' > "$TEST_ROOT/home/config/codex-seat-destination-min"
if out=$(choose); then fail 'multiline minimum must not accept its first line'; fi
rm "$TEST_ROOT/home/config/codex-seat-destination-min"
quota codex work 0.9
ln -s "$TEST_ROOT/codex/work" "$TEST_ROOT/codex/duplicate"
if out=$(choose); then fail 'duplicate concrete credential profiles must refuse selection'; fi
assert_grep 'duplicate credential profiles' "$TEST_ROOT/evidence" 'duplicate profiles must be a configuration error'
rm "$TEST_ROOT/codex/duplicate"
pass 'malformed configuration and duplicate profiles fail closed'

# Exercise the real auto controller with a Codex incumbent. Only the transaction
# preflight is stubbed; this test must never replace an agent or touch a backend.
mkdir -p "$TEST_ROOT/code/bin" "$TEST_ROOT/codex/worker"
for entry in "$ROOT"/bin/*; do ln -s "$entry" "$TEST_ROOT/code/bin/${entry##*/}"; done
rm "$TEST_ROOT/code/bin/fm-seat.sh" "$TEST_ROOT/code/bin/fm-lead-restart.sh"
cp "$ROOT/bin/fm-seat.sh" "$TEST_ROOT/code/bin/fm-seat.sh"
cat > "$TEST_ROOT/code/bin/fm-lead-restart.sh" <<'FAKE'
#!/usr/bin/env bash
[[ " $* " == *' --check '* ]] || exit 99
printf '%s\n' "$*" >> "$LEAD_TEST_CHECKS"
FAKE
chmod +x "$TEST_ROOT/code/bin/fm-lead-restart.sh"
export LEAD_TEST_CHECKS="$TEST_ROOT/checks"
quota claude current 0.8
quota claude alternate 0.2
quota codex work 0.01 through_reset 999 1
printf 'alternate\n' > "$TEST_ROOT/home/config/claude-seat"
printf '20\n' > "$TEST_ROOT/home/config/claude-seat-threshold"
printf 'off\n' > "$TEST_ROOT/home/config/lead-codex-auto"
printf 'pid=%s\nharness=codex\nprofile=%s\n' "$$" "$TEST_ROOT/codex/work" > "$TEST_ROOT/home/state/.lock-runtime"
out=$(FM_HOME="$TEST_ROOT/home" PATH="$TEST_ROOT/bin:$PATH" bash "$TEST_ROOT/code/bin/fm-seat.sh" auto 2>&1)
assert_contains "$out" 'lead-restart --provider claude --to current --persisted' 'Claude controller must move a low Codex incumbent without a Codex threshold/watch'
assert_grep '--check --provider claude --to current' "$LEAD_TEST_CHECKS" 'automatic move must preflight the chosen provider'
out=$(FM_HOME="$TEST_ROOT/home" PATH="$TEST_ROOT/bin:$PATH" bash "$TEST_ROOT/code/bin/fm-seat.sh" auto 2>&1)
assert_not_contains "$out" 'THEN run exactly' 'same incumbent crossing must not repeat its instruction'
[ "$(wc -l < "$LEAD_TEST_CHECKS" | tr -d ' ')" = 1 ] || fail 'repeated crossing must not repeat the transaction preflight'
pass 'one Claude watch drives Codex incumbent rotation and deduplicates the crossing'
