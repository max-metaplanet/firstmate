#!/usr/bin/env bash
# Behavior tests for bin/fm-prefer.sh and bin/fm-prefer-lib.sh.
#
# Drives the public argv interface against an isolated FM_HOME. The convergence
# that bin/fm-prefer.sh runs for secondmate homes is bin/fm-config-push.sh, so
# these cases drive it through a stand-in on PATH rather than reimplementing it,
# and the inheritance declaration itself is asserted against its one owner.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TOOL="$ROOT/bin/fm-prefer.sh"
TMP_ROOT=$(fm_test_tmproot fm-prefer)
HOME_DIR="$TMP_ROOT/home"
PREFER="$HOME_DIR/config/dispatch-prefer"
RULES="$HOME_DIR/config/crew-dispatch.json"
PUSH_LOG="$TMP_ROOT/push.log"
mkdir -p "$HOME_DIR/config" "$HOME_DIR/state"

# shellcheck source=bin/fm-prefer-lib.sh
. "$ROOT/bin/fm-prefer-lib.sh"

cat > "$RULES" <<'JSON'
{
  "rules": [
    { "when": "A large or ambiguous multi-file change.",
      "kind": "implementation",
      "use": [
        { "harness": "claude", "model": "opus", "effort": "high" },
        { "harness": "codex", "model": "gpt-5.6-sol", "effort": "high" }
      ] },
    { "when": "An investigation whose deliverable is a written report.",
      "kind": "investigation",
      "use": [ { "harness": "grok", "model": "grok-4.7", "effort": "high" } ] },
    { "when": "Anything else.",
      "use": [ { "harness": "claude", "model": "opus" } ] }
  ]
}
JSON

code='' out='' err=''
run() {  # <exit-var> <out-var> <err-var> [args...]
  local __exit=$1 __out=$2 __err=$3 _out _code
  shift 3
  _out=$(FM_HOME="$HOME_DIR" "$TOOL" "$@" 2> "$TMP_ROOT/stderr")
  _code=$?
  printf -v "$__exit" '%s' "$_code"
  printf -v "$__out" '%s' "$_out"
  printf -v "$__err" '%s' "$(cat "$TMP_ROOT/stderr")"
}

# --- show with nothing declared ---------------------------------------------
run code out err show
expect_code 0 "$code" "show with no preference exits 0"
assert_contains "$out" 'no preference declared' "show states that nothing is preferred"
assert_contains "$out" 'rule_1: implementation' "show lists each rule's declared kind"
assert_contains "$out" 'rule_3: unclassified' "show names an unclassified rule"
pass "show reports an empty preference and every rule's declared kind"

# --- set writes the preference and discloses whether it can ever apply ------
run code out err set implementation codex --no-push
expect_code 0 "$code" "set exits 0"
assert_equals 'implementation=codex' "$(cat "$PREFER")" "set writes one kind=harness line"
assert_contains "$out" 'prefer codex for implementation' "set states the preference in the operator's own words"
assert_contains "$out" 'rule_1 declares kind=implementation and lists codex' "set names the rule the preference reaches"

run code out err set investigation codex --no-push
expect_code 0 "$code" "set exits 0 for a preference that cannot apply"
assert_contains "$out" 'no rule declaring kind=investigation lists codex' "a preference no matching rule lists says so"

run code out err set deployment codex --no-push
assert_contains "$out" 'declares kind=deployment' "a preference for an undeclared kind says so"
assert_contains "$out" 'no-op until one does' "an undeclared kind is reported as a no-op"
pass "set discloses a preference that can only ever be a no-op"

# --- several kinds coexist, and auto removes one ----------------------------
run code out err show
assert_contains "$out" 'prefer codex for implementation' "show lists the first preference"
assert_contains "$out" 'prefer codex for investigation' "show lists the second preference"
run code out err set investigation auto --no-push
expect_code 0 "$code" "set auto exits 0"
assert_contains "$out" 'no preference for investigation' "auto states that the kind is unpreferred"
assert_equals "$(printf 'implementation=codex\ndeployment=codex')" "$(cat "$PREFER")" "auto removes only its own kind"
pass "kinds are independent and auto clears exactly one"

# --- replacing a preference is one call -------------------------------------
run code out err set implementation grok --no-push
assert_equals "$(printf 'deployment=codex\nimplementation=grok')" "$(cat "$PREFER")" "a second set replaces that kind's line"
pass "changing the preferred runtime is one call"

# --- refusals ----------------------------------------------------------------
run code out err set implementation nosuchharness --no-push
expect_code 2 "$code" "an unverified harness is refused"
assert_contains "$err" 'is not a verified harness' "the refusal explains the harness requirement"
run code out err set 'Implementation Work' codex --no-push
expect_code 2 "$code" "a malformed kind is refused"
assert_contains "$err" 'invalid kind' "the refusal explains the kind requirement"
run code out err set implementation --no-push
expect_code 2 "$code" "a missing harness argument is refused"
run code out err frobnicate --no-push
expect_code 2 "$code" "an unknown command is refused"
assert_contains "$err" 'unknown command' "the refusal names the accepted commands"
pass "set refuses an unverified harness, a malformed kind, and a bad invocation"

# --- a malformed file is an actionable error, never a dropped preference ----
printf 'implementation codex\n' > "$PREFER"
run code out err show
expect_code 2 "$code" "show refuses a malformed file"
assert_contains "$err" 'not a kind=harness line' "the refusal names the malformed line"
printf 'implementation=codex\nimplementation=grok\n' > "$PREFER"
run code out err show
expect_code 2 "$code" "show refuses a repeated kind"
assert_contains "$err" 'declared more than once' "the refusal names the repeated kind"
pass "a malformed preference file refuses rather than resolving to something"

# --- the documented file format parses exactly as documented ----------------
cat > "$PREFER" <<'TEXT'
# comments and blank lines are ignored

  implementation = codex

investigation=auto
quick-fix=grok
TEXT
assert_equals '{"implementation":"codex","quick-fix":"grok"}' \
  "$(fm_prefer_json "$HOME_DIR/config")" "whitespace, comments, and auto parse as documented"
assert_equals codex "$(fm_prefer_for_kind "$HOME_DIR/config" implementation)" "a declared kind reads back"
assert_equals '' "$(fm_prefer_for_kind "$HOME_DIR/config" investigation)" "auto reads back as no preference"
assert_equals '' "$(fm_prefer_for_kind "$HOME_DIR/config" unknown)" "an undeclared kind reads back as no preference"
assert_equals '{}' "$(fm_prefer_json "$TMP_ROOT/absent-config")" "an absent file is no preference, not an error"

# A token carrying a newline would split into two lines in the file and corrupt
# it, so it has to be rejected by the validator rather than by the next read.
newline_kind=$'implementation\n'
fm_prefer_token_valid "$newline_kind" &&
  fail "a token with a trailing newline must not validate"
run code out err set "$newline_kind" codex --no-push
expect_code 2 "$code" "a kind with a trailing newline is refused"
pass "the documented file format parses exactly as documented"

# --- clear removes every preference -----------------------------------------
run code out err clear --no-push
expect_code 0 "$code" "clear exits 0"
assert_absent "$PREFER" "clear removes the preference file"
assert_contains "$out" 'no preference declared' "clear states the resulting posture"
run code out err clear --no-push
expect_code 0 "$code" "clear is idempotent"
pass "clear removes every preference and repeats safely"

# --- one call converges secondmate homes ------------------------------------
# bin/fm-config-push.sh owns that convergence; this asserts only that set and
# clear actually invoke it, since skipping it is what would leave a second home
# on yesterday's preference.
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
cat > "$FAKEBIN/fm-config-push.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "push ${FM_CONFIG_OVERRIDE:-}" >> "${PUSH_LOG:?}"
exit "${FAKE_PUSH_EXIT:-0}"
SH
chmod +x "$FAKEBIN/fm-config-push.sh"
PUSH_BIN="$TMP_ROOT/push-bin"
mkdir -p "$PUSH_BIN"
cp "$ROOT/bin/fm-prefer.sh" "$ROOT/bin/fm-prefer-lib.sh" "$ROOT/bin/fm-control-lib.sh" "$PUSH_BIN/"
cp "$FAKEBIN/fm-config-push.sh" "$PUSH_BIN/"

: > "$PUSH_LOG"
out=$(FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" PUSH_LOG="$PUSH_LOG" \
  "$PUSH_BIN/fm-prefer.sh" set implementation codex 2>&1)
code=$?
expect_code 0 "$code" "set with convergence exits 0"
assert_contains "$out" 'converging secondmate homes' "set announces the convergence"
assert_contains "$(cat "$PUSH_LOG")" "push $HOME_DIR/config" "set converges through bin/fm-config-push.sh"

: > "$PUSH_LOG"
FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" PUSH_LOG="$PUSH_LOG" \
  "$PUSH_BIN/fm-prefer.sh" clear >/dev/null 2>&1
assert_contains "$(cat "$PUSH_LOG")" "push $HOME_DIR/config" "clear converges through bin/fm-config-push.sh"

: > "$PUSH_LOG"
out=$(FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" PUSH_LOG="$PUSH_LOG" FAKE_PUSH_EXIT=1 \
  "$PUSH_BIN/fm-prefer.sh" set implementation codex 2>&1)
code=$?
expect_code 1 "$code" "a failed convergence is reported, not swallowed"
assert_contains "$out" 'not every secondmate home was updated' "a failed convergence names what is stale"
assert_equals 'implementation=codex' "$(cat "$PREFER")" "a failed convergence never undoes this home's change"
pass "one call writes this home and converges the others"

# --- the preference is declared inheritable, from its one owner -------------
# bin/fm-config-inherit-lib.sh is the single declaration every convergence
# point derives from, so a preference missing there would reach no second home.
# shellcheck source=bin/fm-config-inherit-lib.sh
. "$ROOT/bin/fm-config-inherit-lib.sh"
case " $FM_INHERITABLE_CONFIG " in
  *" dispatch-prefer "*) ;;
  *) fail "config/dispatch-prefer must be in FM_INHERITABLE_CONFIG so every home inherits the preference" ;;
esac
fm_config_inherit_item_machine_local dispatch-prefer &&
  fail "config/dispatch-prefer must not be machine-local, or it would never cross to a remote home"
fm_config_inherit_items | grep -qxF 'config/dispatch-prefer' ||
  fail "config/dispatch-prefer must be in the cross-machine inherited set"
pass "the preference is declared inheritable and crosses to a remote home"

printf '# all fm-prefer tests passed\n'
