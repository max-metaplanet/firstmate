#!/usr/bin/env bash
# Behavior tests for bin/fm-prefer.sh and bin/fm-prefer-lib.sh.
#
# Drives the public argv interface against an isolated FM_HOME. The convergence
# that bin/fm-prefer.sh runs for secondmate homes is bin/fm-config-push.sh, so
# these cases run a disposable script copy beside a stand-in push command,
# and the inheritance declaration itself is asserted against its one owner.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-prefer)
HOME_DIR="$TMP_ROOT/home"
PREFER="$HOME_DIR/config/dispatch-prefer"
RULES="$HOME_DIR/config/crew-dispatch.json"
PUSH_LOG="$TMP_ROOT/push.log"
mkdir -p "$HOME_DIR/config" "$HOME_DIR/state"

PUSH_BIN="$TMP_ROOT/push-bin"
mkdir -p "$PUSH_BIN"
cp "$ROOT/bin/fm-prefer.sh" "$ROOT/bin/fm-prefer-lib.sh" "$ROOT/bin/fm-control-lib.sh" "$PUSH_BIN/"
cat > "$PUSH_BIN/fm-config-push.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "push ${FM_CONFIG_OVERRIDE:-}" >> "${PUSH_LOG:?}"
if [ -n "${PUSH_BOUNDARY_BIN:-}" ]; then
  exec "$PUSH_BOUNDARY_BIN/fm-config-push.sh"
fi
if [ -n "${PUSH_DEST:-}" ]; then
  . "${PUSH_INHERIT_LIB:?}"
  propagate_inheritable_config "$FM_CONFIG_OVERRIDE" "$PUSH_DEST/config" "$FM_HOME"
  exit $?
fi
exit "${FAKE_PUSH_EXIT:-0}"
SH
chmod +x "$PUSH_BIN/fm-config-push.sh"
TOOL="$PUSH_BIN/fm-prefer.sh"
: > "$PUSH_LOG"

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
  _out=$(FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" PUSH_LOG="$PUSH_LOG" "${FM_TEST_BASH:-bash}" "$TOOL" "$@" 2> "$TMP_ROOT/stderr")
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
run code out err set implementation codex
expect_code 0 "$code" "set exits 0"
assert_equals 'implementation=codex' "$(cat "$PREFER")" "set writes one kind=harness line"
assert_contains "$out" 'prefer codex for implementation' "set states the preference in the operator's own words"
assert_contains "$out" 'rule_1 declares kind=implementation and lists codex' "set names the rule the preference reaches"
assert_equals "push $HOME_DIR/config" "$(cat "$PUSH_LOG")" "the ordinary set command converges through the disposable push stub"

run code out err set investigation codex
expect_code 0 "$code" "set exits 0 for a preference that cannot apply"
assert_contains "$out" 'no rule declaring kind=investigation lists codex' "a preference no matching rule lists says so"

run code out err set deployment codex
assert_contains "$out" 'declares kind=deployment' "a preference for an undeclared kind says so"
assert_contains "$out" 'no-op until one does' "an undeclared kind is reported as a no-op"
pass "set discloses a preference that can only ever be a no-op"

# --- several kinds coexist, and auto removes one ----------------------------
run code out err show
assert_contains "$out" 'prefer codex for implementation' "show lists the first preference"
assert_contains "$out" 'prefer codex for investigation' "show lists the second preference"
run code out err set investigation auto
expect_code 0 "$code" "set auto exits 0"
assert_contains "$out" 'no preference for investigation' "auto states that the kind is unpreferred"
assert_equals "$(printf 'implementation=codex\ndeployment=codex')" "$(cat "$PREFER")" "auto removes only its own kind"
pass "kinds are independent and auto clears exactly one"

# --- replacing a preference is one call -------------------------------------
run code out err set implementation grok
assert_equals "$(printf 'deployment=codex\nimplementation=grok')" "$(cat "$PREFER")" "a second set replaces that kind's line"
pass "changing the preferred runtime is one call"

# --- refusals ----------------------------------------------------------------
run code out err set implementation nosuchharness
expect_code 2 "$code" "an unverified harness is refused"
assert_contains "$err" 'is not a verified harness' "the refusal explains the harness requirement"
run code out err set 'Implementation Work' codex
expect_code 2 "$code" "a malformed kind is refused"
assert_contains "$err" 'invalid kind' "the refusal explains the kind requirement"
run code out err set implementation
expect_code 2 "$code" "a missing harness argument is refused"
run code out err frobnicate
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
run code out err set "$newline_kind" codex
expect_code 2 "$code" "a kind with a trailing newline is refused"
run code out err set implementation grok
expect_code 0 "$code" "a spaced key can be replaced"
assert_equals '{"quick-fix":"grok","implementation":"grok"}' \
  "$(fm_prefer_json "$HOME_DIR/config")" "replacement normalizes the key without duplicating it"
assert_contains "$(cat "$PREFER")" '# comments and blank lines are ignored' "replacement preserves comments"
printf 'implementation = codex\n' > "$PREFER"
run code out err set implementation grok
expect_code 0 "$code" "a single spaced key can be replaced"
assert_equals 'implementation=grok' "$(cat "$PREFER")" "replacement leaves exactly one correct persisted line"
printf '  implementation \t= codex\r\nquick-fix=grok\n' > "$PREFER"
run code out err set implementation auto
expect_code 0 "$code" "a spaced key can be removed"
assert_equals '{"quick-fix":"grok"}' "$(fm_prefer_json "$HOME_DIR/config")" "auto removes the spaced key and preserves its sibling"
printf 'implementation=codez\n' > "$PREFER"
run code out err show
expect_code 2 "$code" "show refuses an unknown harness in persisted configuration"
assert_contains "$err" 'is not a verified harness' "the parser explains the harness refusal"
run code out err set quick-fix codex
expect_code 2 "$code" "set refuses an existing unknown harness"
assert_equals 'implementation=codez' "$(cat "$PREFER")" "refused updates leave the persisted file intact"
if out=$(fm_prefer_for_kind "$HOME_DIR/config" implementation); then
  fail "kind lookup must refuse an unknown harness"
fi
assert_contains "$out" 'is not a verified harness' "kind lookup uses the same validation"
pass "the documented file format parses exactly as documented"

# --- clear removes every preference -----------------------------------------
run code out err clear
expect_code 0 "$code" "clear exits 0"
assert_absent "$PREFER" "clear removes the preference file"
assert_contains "$out" 'no preference declared' "clear states the resulting posture"
run code out err clear
expect_code 0 "$code" "clear is idempotent"
pass "clear removes every preference and repeats safely"

# --- one call converges secondmate homes ------------------------------------
# bin/fm-config-push.sh owns that convergence; this asserts only that set and
# clear actually invoke it, since skipping it is what would leave a second home
# on yesterday's preference.

FAIL_BIN="$TMP_ROOT/fail-bin"
mkdir -p "$FAIL_BIN"
for fail_command in mktemp cat chmod mv; do
  real_command=$(command -v "$fail_command")
  # The placeholders belong to the generated script.
  # shellcheck disable=SC2016
  printf '#!/usr/bin/env bash\n[ "${PREFER_FAIL_COMMAND:-}" != %q ] || exit 1\nexec %q "$@"\n' \
    "$fail_command" "$real_command" > "$FAIL_BIN/$fail_command"
  chmod +x "$FAIL_BIN/$fail_command"
done
for fail_command in mktemp cat chmod mv; do
  printf 'implementation=codex\n' > "$PREFER"
  : > "$PUSH_LOG"
  out=$(PATH="$FAIL_BIN:$PATH" PREFER_FAIL_COMMAND="$fail_command" \
    FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" PUSH_LOG="$PUSH_LOG" \
    "$TOOL" set implementation grok 2> "$TMP_ROOT/stderr")
  code=$?
  expect_code 2 "$code" "$fail_command failure refuses the update"
  assert_equals '' "$out" "$fail_command failure reports no success or convergence"
  assert_contains "$(cat "$TMP_ROOT/stderr")" 'error: cannot' "$fail_command failure explains the refused write"
  assert_equals 'implementation=codex' "$(cat "$PREFER")" "$fail_command failure preserves the old preference"
  assert_equals '' "$(cat "$PUSH_LOG")" "$fail_command failure never propagates the old preference"
done
pass "every write failure stops before success output and propagation"

: > "$PUSH_LOG"
out=$(FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" PUSH_LOG="$PUSH_LOG" \
  "$TOOL" set implementation codex 2>&1)
code=$?
expect_code 0 "$code" "set with convergence exits 0"
assert_contains "$out" 'converging secondmate homes' "set announces the convergence"
assert_contains "$(cat "$PUSH_LOG")" "push $HOME_DIR/config" "set converges through bin/fm-config-push.sh"

: > "$PUSH_LOG"
FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" PUSH_LOG="$PUSH_LOG" \
  "$TOOL" clear >/dev/null 2>&1
assert_contains "$(cat "$PUSH_LOG")" "push $HOME_DIR/config" "clear converges through bin/fm-config-push.sh"

for action in set auto clear; do
  printf 'implementation=grok\n' > "$PREFER"
  : > "$PUSH_LOG"
  case "$action" in
    set) args=(set implementation codex) ;;
    auto) args=(set implementation auto) ;;
    clear) args=(clear) ;;
  esac
  out=$(FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" PUSH_LOG="$PUSH_LOG" FAKE_PUSH_EXIT=1 \
    "$TOOL" "${args[@]}" 2>&1)
  code=$?
  expect_code 1 "$code" "$action reports failed convergence"
  assert_contains "$out" 'warning: the local preference is set, but at least one secondmate home did not take it; run bin/fm-config-push.sh once that host is reachable' "$action names the local state, divergence, and exact retry command"
  assert_equals "push $HOME_DIR/config" "$(cat "$PUSH_LOG")" "$action attempts convergence exactly once"
  case "$action" in
    set) assert_equals 'implementation=codex' "$(cat "$PREFER")" "failed convergence keeps the new local preference" ;;
    auto) assert_equals '' "$(fm_prefer_for_kind "$HOME_DIR/config" implementation)" "failed convergence keeps the local auto selection" ;;
    clear) assert_absent "$PREFER" "failed convergence keeps the local clear" ;;
  esac
done
: > "$PUSH_LOG"
run code out err set implementation grok --no-push
expect_code 2 "$code" "the removed local-only option is refused"
assert_contains "$err" 'unknown flag --no-push' "the removed option has no bypass path"
assert_absent "$PREFER" "a refused option changes no preference"
assert_equals '' "$(cat "$PUSH_LOG")" "a refused option starts no convergence"
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

PUSH_DEST="$TMP_ROOT/destination"
mkdir -p "$PUSH_DEST/config"
git -C "$PUSH_DEST" init -q
printf '/config/*\n!/config/dispatch-prefer\n' > "$PUSH_DEST/.gitignore"
for action in set auto clear; do
  printf 'implementation=grok\n' > "$PUSH_DEST/config/dispatch-prefer"
  case "$action" in
    set) args=(set implementation codex) ;;
    auto) args=(set implementation auto) ;;
    clear) args=(clear) ;;
  esac
  out=$(FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" PUSH_LOG="$PUSH_LOG" \
    PUSH_DEST="$PUSH_DEST" PUSH_INHERIT_LIB="$ROOT/bin/fm-config-inherit-lib.sh" \
    "$TOOL" "${args[@]}" 2> "$TMP_ROOT/stderr")
  code=$?
  expect_code 1 "$code" "$action fails when the inheritance consumer skips the preference"
  assert_contains "$(cat "$TMP_ROOT/stderr")" 'warning: the local preference is set, but at least one secondmate home did not take it; run bin/fm-config-push.sh once that host is reachable' "$action reports incomplete convergence"
  assert_equals 'implementation=grok' "$(cat "$PUSH_DEST/config/dispatch-prefer")" "$action preserves the refused destination"
  case "$action" in
    set) assert_equals 'implementation=codex' "$(cat "$PREFER")" "a skipped copy keeps the new local preference" ;;
    auto) assert_equals '' "$(fm_prefer_for_kind "$HOME_DIR/config" implementation)" "a skipped removal keeps local auto" ;;
    clear) assert_absent "$PREFER" "a skipped removal keeps the local clear" ;;
  esac
done
printf '/config/\n' > "$PUSH_DEST/.gitignore"
for attempt in first unchanged; do
  out=$(FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" PUSH_LOG="$PUSH_LOG" \
    PUSH_DEST="$PUSH_DEST" PUSH_INHERIT_LIB="$ROOT/bin/fm-config-inherit-lib.sh" \
    "$TOOL" set implementation codex 2> "$TMP_ROOT/stderr")
  code=$?
  expect_code 0 "$code" "$attempt convergence succeeds when the destination accepts the preference"
  assert_equals 'implementation=codex' "$(cat "$PUSH_DEST/config/dispatch-prefer")" "$attempt convergence leaves the destination correct"
  assert_equals '' "$(cat "$TMP_ROOT/stderr")" "$attempt convergence emits no false warning"
done
pass "skipped preference copies and removals fail while unchanged preferences converge"

PUSH_BOUNDARY_BIN="$TMP_ROOT/boundary-bin"
mkdir -p "$PUSH_BOUNDARY_BIN"
cp "$ROOT/bin/fm-config-push.sh" "$PUSH_BOUNDARY_BIN/"
cat > "$PUSH_BOUNDARY_BIN/fm-ff-lib.sh" <<'SH'
live_secondmate_meta_records() { cat "${PUSH_RECORDS:?}"; }
fm_meta_get() { printf '%s' "${PUSH_REMOTE_HOST:-}"; }
validate_secondmate_home() { VALIDATION_ERROR='not a seeded secondmate home'; return 1; }
SH
for dependency in fm-backend.sh fm-wake-lib.sh fm-config-inherit-lib.sh fm-secondmate-nudge-lib.sh; do
  : > "$PUSH_BOUNDARY_BIN/$dependency"
done
printf '#!/usr/bin/env bash\nexit 0\n' > "$PUSH_BOUNDARY_BIN/fm-guard.sh"
chmod +x "$PUSH_BOUNDARY_BIN/fm-guard.sh"
PUSH_RECORDS="$TMP_ROOT/records"
for home_state in unresolved unsafe; do
  case "$home_state" in
    unresolved) printf 'legacy||fixture|fixture.meta\n' > "$PUSH_RECORDS" ;;
    unsafe) printf 'unsafe|%s|fixture|fixture.meta\n' "$PUSH_DEST" > "$PUSH_RECORDS" ;;
  esac
  for action in set auto clear; do
    case "$action" in
      set) args=(set implementation grok) ;;
      auto) args=(set implementation auto) ;;
      clear) args=(clear) ;;
    esac
    out=$(FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" PUSH_LOG="$PUSH_LOG" \
      PUSH_BOUNDARY_BIN="$PUSH_BOUNDARY_BIN" PUSH_RECORDS="$PUSH_RECORDS" \
      "$TOOL" "${args[@]}" 2> "$TMP_ROOT/stderr")
    code=$?
    expect_code 1 "$code" "$action fails for a $home_state home at the real push boundary"
    assert_contains "$out" 'skipped -' "the push boundary retains its per-home skip report"
    assert_contains "$(cat "$TMP_ROOT/stderr")" 'warning: the local preference is set, but at least one secondmate home did not take it; run bin/fm-config-push.sh once that host is reachable' "$action reports the incomplete $home_state home"
    case "$action" in
      set) assert_equals 'implementation=grok' "$(cat "$PREFER")" "an incomplete home never undoes the local write" ;;
      auto) assert_equals '' "$(fm_prefer_for_kind "$HOME_DIR/config" implementation)" "an incomplete home never undoes local auto" ;;
      clear) assert_absent "$PREFER" "an incomplete home never undoes local clear" ;;
    esac
  done
done
printf 'remote||fixture|fixture.meta\n' > "$PUSH_RECORDS"
out=$(FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" PUSH_REMOTE_HOST=telos64 \
  PUSH_RECORDS="$PUSH_RECORDS" "$PUSH_BOUNDARY_BIN/fm-config-push.sh" --local-only 2> "$TMP_ROOT/stderr")
code=$?
expect_code 0 "$code" "a local-only push excludes remote records before requiring a home"
assert_not_contains "$out" 'skipped - no home=' "an excluded remote is not an incomplete local target"
pass "unresolved and unsafe homes fail through the push boundary for set, auto, and clear"

printf '# all fm-prefer tests passed\n'
