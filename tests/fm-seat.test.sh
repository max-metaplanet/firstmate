#!/usr/bin/env bash
# Behavior tests for Claude seat switching: bin/fm-seat.sh and the seat half of
# bin/fm-spawn.sh.
#
# Every test here runs with no real Claude account and no network. The login
# probe and the quota read both shell out to `quota-axi`, so a fake quota-axi on
# PATH supplies the report each case needs; the scripts under test are driven
# through their real interfaces and never inspected as source.
#
# The property these tests exist to protect is that a switch changes only what
# the NEXT worker gets: a running task keeps the profile recorded in its own
# task record. The other half of that property - that a RELAUNCH reads the
# record rather than the home's current setting - is covered in
# tests/fm-control-relaunch.test.sh, which owns the fake backend that can prove
# a prior agent is gone and so is the only place a relaunch actually launches.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

SEAT="$ROOT/bin/fm-seat.sh"
TMP_ROOT=$(fm_test_tmproot fm-seat)
export FM_SEAT_LOCK_ROOT="$TMP_ROOT/seat-locks"

# The quota fake every seat case runs against lives in tests/fixtures.sh as
# fm_test_make_quota_fake, because tests/fm-lead-restart.test.sh drives the same
# seat surface and must not carry a second copy of it.
make_quota_fake() { fm_test_make_quota_fake "$@"; }

# make_seat_case <name>
# A home with a seats root of its own plus a fake quota-axi. Echoes a record.
make_seat_case() {
  local name=$1 case_dir home seats fakebin spec
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  seats="$case_dir/seats"
  spec="$case_dir/quota-spec"
  mkdir -p "$home/config" "$home/state" "$home/data" "$seats" "$case_dir/codex-seats"
  printf '%s\n' "$case_dir/codex-seats" > "$home/config/codex-seats-root"
  fakebin=$(fm_fakebin "$case_dir/fake")
  make_quota_fake "$fakebin" "$spec"
  printf '%s\n' "$seats" > "$home/config/claude-seats-root"
  printf '%s\n' "$case_dir|$home|$seats|$fakebin|$spec"
}

read_seat_case() {
  IFS='|' read -r CASE_DIR HOME_DIR SEATS_DIR FAKEBIN SPEC_DIR <<EOF
$1
EOF
}

# run_seat <home> <fakebin> [args...]
# firstmate's own CLAUDE_CONFIG_DIR is pinned empty unless a test opts in
# through SEAT_TEST_AMBIENT_CONFIG_DIR.
run_seat() {
  local home=$1 fakebin=$2
  shift 2
  FM_HOME="$home" FM_CONFIG_OVERRIDE="$home/config" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" CLAUDE_CONFIG_DIR="${SEAT_TEST_AMBIENT_CONFIG_DIR:-}" \
    PATH="$fakebin:$PATH" "$SEAT" "$@" 2>&1
}

# seat_logged_in <spec> <value...>
# Declare which profiles the fake reports as logged in.
seat_logged_in() {
  local spec=$1
  shift
  printf '%s\n' "$@" > "$spec/oauth"
}

# seat_proven_empty <spec> <value...>
# Declare which profiles the fake reports as PROVEN to hold no login, as a
# file-backed store that was read and found empty does. Any profile not listed
# here and not logged in falls through to the unreadable-store shape, which
# establishes nothing.
seat_proven_empty() {
  local spec=$1
  shift
  printf '%s\n' "$@" > "$spec/proven_empty"
}

# seat_expired_refreshable <spec> <value...>
# Declare which profiles are signed in with a lapsed but renewable access token.
seat_expired_refreshable() {
  local spec=$1
  shift
  printf '%s\n' "$@" > "$spec/expired_refreshable"
}

# seat_expired_refreshable_confirmed <spec> <value...>
# The same state as seat_expired_refreshable, reported through quota-axi's
# rate-limited-then-confirmed route, whose error text and attempts differ.
seat_expired_refreshable_confirmed() {
  local spec=$1
  shift
  printf '%s\n' "$@" > "$spec/expired_refreshable_confirmed"
}

# seat_signed_out <spec> <value...>
# Declare which profiles are genuinely signed out on a Keychain-backed store.
seat_signed_out() {
  local spec=$1
  shift
  printf '%s\n' "$@" > "$spec/signed_out"
}

# Codex fixtures bind exclusively to CODEX_HOME and insist that every probe is
# profile-only and non-renewing. Their auth files are empty synthetic stores.
make_codex_seat_case() {
  local name=$1
  read_seat_case "$(make_seat_case "$name")"
  printf '%s\n' "$SEATS_DIR" > "$HOME_DIR/config/codex-seats-root"
  cat > "$FAKEBIN/quota-axi" <<'CODEXFAKE'
#!/usr/bin/env bash
set -u
provider='' readonly_probe=0 profile_only=0
while [ $# -gt 0 ]; do
  case "$1" in
    --provider) provider=$2; shift ;;
    --no-credential-refresh) readonly_probe=1 ;;
    --profile-only) profile_only=1 ;;
  esac
  shift
done
[ "$provider" = codex ] && [ "$readonly_probe" = 1 ] && [ "$profile_only" = 1 ] || exit 88
[ -n "${CODEX_HOME:-}" ] || exit 89
[ -f "$CODEX_HOME/quota.json" ] || exit 90
cat "$CODEX_HOME/quota.json"
CODEXFAKE
  chmod +x "$FAKEBIN/quota-axi"
}

# codex_quota_fixture <home> [remaining] [auth] [resetsAt]
# A fourth argument gives the native account a weekly window carrying that reset
# stamp, which is what a refusal naming when an empty home returns reads.
codex_quota_fixture() {
  local home=$1 remaining=${2:-60} auth=${3:-valid} resets=${4:-}
  mkdir -p "$home"
  : > "$home/auth.json"
  jq -n --argjson remaining "$remaining" --arg auth "$auth" --arg resets "$resets" '{schemaVersion:6,providers:[
    {provider:"codex",accountKey:"unrelated",source:"oauth",account:{email:"wrong@example.test"},
     quotaSemantics:{effectiveAvailability:[{scope:"all_models",status:"known",effectivePercentRemaining:99}]}},
    {provider:"codex",accountKey:"codex-home",source:(if $auth == "valid" then "oauth" else "unavailable" end),
     account:{email:"native@example.test"},state:{authStatus:$auth},
     attempts:[{source:"oauth",status:"skipped",error:$auth}],
     windows:(if $resets == "" then [] else
       [{id:"weekly",kind:"weekly",label:"week",percentUsed:(100 - $remaining),
         percentRemaining:$remaining,resetsAt:$resets,windowSeconds:604800}] end),
     quotaSemantics:{effectiveAvailability:[
       ({scope:"all_models",status:"known",effectivePercentRemaining:$remaining}
        + (if $resets == "" then {} else {limitingWindowIds:["weekly"]} end))]}}
  ]}' > "$home/quota.json"
}

test_codex_registration_keeps_one_auth_store_and_quotes_login() {
  local out source_home identity_a identity_b
  make_codex_seat_case codex-register
  source_home="$CASE_DIR/existing home"
  codex_quota_fixture "$source_home"
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" --provider codex add work --home "$source_home")
  expect_code 0 "$?" "registering an existing Codex home must succeed: $out"
  [ -L "$SEATS_DIR/work" ] || fail 'Codex registration must alias the original home'
  [ "$SEATS_DIR/work/auth.json" -ef "$source_home/auth.json" ] || fail 'registered auth must remain the original file'
  assert_contains "$out" 'no authentication copied' 'registration must explain the credential boundary'
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" --provider codex add work --home "$source_home")
  expect_code 0 "$?" "registering the same home twice must converge: $out"
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" --provider codex probe work)
  expect_code 0 "$?" "Codex quota must bind to the selected profile: $out"
  assert_contains "$out" 'logged-in' 'Codex probe must use the native account'
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" --provider codex switch work)
  expect_code 0 "$?" "switching to registered Codex home must succeed: $out"
  assert_grep work "$HOME_DIR/config/codex-seat" 'Codex seat selection must use a separate config key'
  assert_absent "$HOME_DIR/config/claude-seat" 'Codex selection must not select a Claude seat'
  mkdir -p "$SEATS_DIR/alias"
  ln -s "$source_home/auth.json" "$SEATS_DIR/alias/auth.json"
  identity_a=$(FM_SEAT_PROVIDER=codex bash -c '. "$1/bin/fm-seat-lib.sh"; fm_seat_credential_identity "$2"' _ "$ROOT" "$SEATS_DIR/work")
  identity_b=$(FM_SEAT_PROVIDER=codex bash -c '. "$1/bin/fm-seat-lib.sh"; fm_seat_credential_identity "$2"' _ "$ROOT" "$SEATS_DIR/alias")
  [ "$identity_a" = "$identity_b" ] || fail 'auth.json aliases must share a credential identity'
  pass 'Codex registration aliases one credential store and keeps provider settings isolated'
}

test_codex_rotation_skips_aliases_and_uses_native_account_quota() {
  local out
  make_codex_seat_case codex-rotation
  codex_quota_fixture "$SEATS_DIR/a" 5
  mkdir -p "$SEATS_DIR/b"
  ln -s "$SEATS_DIR/a/auth.json" "$SEATS_DIR/b/auth.json"
  codex_quota_fixture "$SEATS_DIR/c" 15
  codex_quota_fixture "$SEATS_DIR/d" 70
  printf 'a\n' > "$HOME_DIR/config/codex-seat"
  printf '20\n' > "$HOME_DIR/config/codex-seat-destination-min"
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" --provider codex switch --next)
  expect_code 0 "$?" "Codex rotation must find the independent eligible store: $out"
  assert_contains "$out" 'shares the active credential store' 'an auth alias is not another account'
  assert_contains "$out" '15% left across its account windows is not above the 20%' 'another schema-6 account cannot supply this seat headroom'
  assert_grep d "$HOME_DIR/config/codex-seat" 'rotation must select genuine native-account headroom'
  printf 'b\n' > "$HOME_DIR/config/codex-seat-auto-exclude"
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" --provider codex switch --next)
  expect_code 1 "$?" "an exclusion must cover every alias of its credential store: $out"
  assert_contains "$out" 'seat a: skipped, excluded' 'aliases must not bypass exclusions'
  pass 'Codex rotation honors auth aliases, native account quota, and alias exclusions'
}

test_codex_invalid_login_and_missing_selected_home_fail_closed() {
  local out rc
  make_codex_seat_case codex-invalid
  codex_quota_fixture "$SEATS_DIR/invalid" 70 credentials_invalid
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" --provider codex switch invalid --force)
  expect_code 1 "$?" "invalid Codex credentials cannot be forced: $out"
  assert_contains "$out" 'codex login' 'invalid credentials need the exact login command'
  assert_absent "$HOME_DIR/config/codex-seat" 'invalid credentials must not select a seat'
  printf 'missing\n' > "$HOME_DIR/config/codex-seat"
  rc=0
  out=$(CONFIG="$HOME_DIR/config" FM_SEAT_PROVIDER=codex bash -c '. "$1/bin/fm-seat-lib.sh"; fm_seat_spawn_config_dir' _ "$ROOT" 2>&1) || rc=$?
  expect_code 1 "$rc" "missing configured home cannot fall through to ambient login: $out"
  printf '../escape\n' > "$HOME_DIR/config/codex-seat"
  rc=0
  out=$(CONFIG="$HOME_DIR/config" FM_SEAT_PROVIDER=codex bash -c '. "$1/bin/fm-seat-lib.sh"; fm_seat_spawn_config_dir' _ "$ROOT" 2>&1) || rc=$?
  expect_code 1 "$rc" "malformed configured home cannot fall through to ambient login: $out"
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" --provider codex pipeline-move)
  expect_code 1 "$?" "Codex pipeline must fail clearly: $out"
  assert_contains "$out" 'supports Claude seats only' 'unsupported vendor operations need an explicit error'
  pass 'invalid Codex logins and missing or malformed selected homes fail closed'
}

test_codex_automatic_switch_propagates_provider_and_watch_binding() {
  local out
  make_codex_seat_case codex-auto
  codex_quota_fixture "$SEATS_DIR/a" 5
  codex_quota_fixture "$SEATS_DIR/b" 70
  printf 'a\n' > "$HOME_DIR/config/codex-seat"
  printf '10\n' > "$HOME_DIR/config/codex-seat-threshold"
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" --provider codex auto)
  expect_code 0 "$?" "Codex auto must keep provider through child switch: $out"
  assert_contains "$out" 'codex-seat: switched from a' 'automatic outcome must identify Codex'
  assert_grep b "$HOME_DIR/config/codex-seat" 'Codex automatic rotation must update its provider key'
  assert_absent "$HOME_DIR/config/claude-seat" 'Codex automatic rotation must not move Claude'
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" --provider codex arm)
  expect_code 0 "$?" "Codex watch must register independently: $out"
  [ -f "$HOME_DIR/state/codex-seat.check.sh" ] || fail 'Codex watch needs its own registration'
  assert_absent "$HOME_DIR/state/claude-seat.check.sh" 'Codex watch must not overwrite Claude registration'
  out=$(FM_HOME="$HOME_DIR" PATH="$FAKEBIN:$PATH" bash "$HOME_DIR/state/codex-seat.check.sh" 2>&1)
  expect_code 0 "$?" "the registered Codex watch must execute its provider scope: $out"
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" --provider codex retire)
  expect_code 0 "$?" "Codex watch retirement must succeed: $out"
  assert_absent "$HOME_DIR/state/codex-seat.check.sh" 'Codex retire must remove its own watch'
  pass 'Codex automatic switching and registered watch preserve provider scope'
}

test_codex_file_alias_resolves_one_authoritative_home() {
  local out home quoted rc
  make_codex_seat_case codex-authoritative-home
  home="$CASE_DIR/authoritative home"
  codex_quota_fixture "$home"
  mkdir -p "$SEATS_DIR/alias" "$SEATS_DIR/broken" "$SEATS_DIR/wrong-name"
  ln -s "$home/auth.json" "$SEATS_DIR/alias/auth.json"
  ln -s "$CASE_DIR/absent/auth.json" "$SEATS_DIR/broken/auth.json"
  : > "$home/other.json"
  ln -s "$home/other.json" "$SEATS_DIR/wrong-name/auth.json"
  printf 'alias\n' > "$HOME_DIR/config/codex-seat"
  out=$(CONFIG="$HOME_DIR/config" FM_SEAT_PROVIDER=codex bash -c '. "$1/bin/fm-seat-lib.sh"; fm_seat_spawn_config_dir' _ "$ROOT")
  assert_equals "$home" "$out" 'file aliases must launch on the single authoritative credential/config home'
  out=$(FM_SEAT_PROVIDER=codex bash -c '. "$1/bin/fm-seat-lib.sh"; fm_seat_login_command "$2"' _ "$ROOT" "$SEATS_DIR/alias")
  printf -v quoted '%q' "$home"
  assert_equals "CODEX_HOME=$quoted codex login" "$out" 'login must resolve the same home with safe shell quoting'
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" --provider codex probe alias)
  expect_code 0 "$?" "probe must read the authoritative home rather than the alias directory: $out"
  [ -L "$SEATS_DIR/alias/auth.json" ] || fail 'resolving/probing cannot rewrite the alias'
  [ "$SEATS_DIR/alias/auth.json" -ef "$home/auth.json" ] || fail 'the original auth file must remain authoritative'
  for home in "$SEATS_DIR/broken" "$SEATS_DIR/wrong-name"; do
    rc=0
    out=$(bash -c '. "$1/bin/fm-seat-lib.sh"; fm_seat_codex_home "$2"' _ "$ROOT" "$home" 2>&1) || rc=$?
    expect_code 1 "$rc" "invalid credential aliases must fail closed: $out"
  done
  # If resolution accidentally falls back to an empty profile, this external
  # quota fixture would approve it. A failure therefore proves no fallback.
  cat > "$FAKEBIN/quota-axi" <<'ALIASQUOTA'
#!/usr/bin/env bash
printf '{"schemaVersion":5,"providers":[{"provider":"codex","source":"oauth"}]}\n'
ALIASQUOTA
  for home in broken wrong-name; do
    rc=0
    out=$(CONFIG="$HOME_DIR/config" FM_SEAT_PROVIDER=codex PATH="$FAKEBIN:$PATH" bash -c '
      . "$1/bin/fm-timeout-lib.sh"
      . "$1/bin/fm-quota-axi-lib.sh"
      . "$1/bin/fm-seat-lib.sh"
      fm_seat_relaunch_destination "$2"
    ' _ "$ROOT" "$home" 2>&1) || rc=$?
    expect_code 1 "$rc" "relaunch must refuse an invalid alias instead of accepting ambient login: $out"
  done
  pass 'Codex file aliases resolve one authoritative login and configuration home without credential writes'
}

test_codex_inheritance_has_provider_scoped_optouts_and_stays_local() {
  local out declining taking
  make_codex_seat_case codex-inheritance
  codex_quota_fixture "$SEATS_DIR/work"
  declining=$(add_local_secondmate "$HOME_DIR" "$FAKEBIN" codexdecline)
  taking=$(add_local_secondmate "$HOME_DIR" "$FAKEBIN" codextaking)
  : > "$declining/config/codex-seat-local"
  : > "$taking/config/claude-seat-local"
  printf 'personal\n' > "$declining/config/codex-seat"
  printf '20\n' > "$HOME_DIR/config/codex-seat-threshold"
  printf '30\n' > "$HOME_DIR/config/codex-seat-destination-min"
  printf 'spare\n' > "$HOME_DIR/config/codex-seat-auto-exclude"
  out=$(TMUX='' run_seat "$HOME_DIR" "$FAKEBIN" --provider codex switch work)
  expect_code 0 "$?" "Codex switch must inherit local configuration: $out"
  assert_equals personal "$(cat "$declining/config/codex-seat")" 'Codex optout must preserve its local active seat'
  assert_equals work "$(cat "$taking/config/codex-seat")" 'Claude optout must not block Codex inheritance'
  assert_equals 20 "$(cat "$taking/config/codex-seat-threshold")" 'Codex threshold must inherit'
  assert_equals 30 "$(cat "$taking/config/codex-seat-destination-min")" 'Codex destination minimum must inherit'
  assert_equals spare "$(cat "$taking/config/codex-seat-auto-exclude")" 'Codex exclusions must inherit'
  assert_absent "$declining/config/codex-seat-threshold" 'Codex optout must preserve an absent local setting'
  assert_contains "$out" 'codex-seat: skipped - home declines inherited seat settings' 'provider-specific decline must be visible'
  out=$(bash -c '. "$1/bin/fm-config-inherit-lib.sh"; fm_config_inherit_items' _ "$ROOT")
  assert_not_contains "$out" 'config/codex-seat' 'Codex settings must never cross a remote route'
  pass 'Codex inheritance follows only its own optout and never crosses machines'
}

test_absent_setting_is_the_default_seat() {
  local rec out
  rec=$(make_seat_case absent-default)
  read_seat_case "$rec"
  seat_logged_in "$SPEC_DIR" '(default)'

  out=$(run_seat "$HOME_DIR" "$FAKEBIN" status)
  assert_contains "$out" "active seat for NEW workers: default" \
    "an absent config/claude-seat must resolve to the default seat"
  assert_contains "$out" "active profile: (ambient default login)" \
    "the default seat must name no profile directory"
  assert_contains "$out" "auto-switch trigger: (unset" \
    "no switch trigger may be configured by default"
  assert_contains "$out" "destination minimum: (unset" \
    "no destination minimum may be configured by default"
  assert_contains "$out" "extra-usage policy: (unset" \
    "no extra-usage policy may be configured by default"
  assert_absent "$HOME_DIR/config/claude-seat" \
    "reading status must not create the seat setting"
  pass "an unset seat setting is the ambient default and configures no automatic switching"
}

test_switch_to_logged_in_seat_updates_only_the_setting() {
  local rec out
  rec=$(make_seat_case switch-ok)
  read_seat_case "$rec"
  mkdir -p "$SEATS_DIR/work"
  seat_logged_in "$SPEC_DIR" '(default)' "$SEATS_DIR/work"

  out=$(run_seat "$HOME_DIR" "$FAKEBIN" switch work)
  expect_code 0 "$?" "switching to a logged-in seat should succeed"
  assert_contains "$out" "switched: default -> work" "switch must report the transition"
  assert_grep "work" "$HOME_DIR/config/claude-seat" "the active seat must be recorded"

  out=$(run_seat "$HOME_DIR" "$FAKEBIN" status)
  assert_contains "$out" "active seat for NEW workers: work" "status must read back the new seat"
  assert_contains "$out" "active profile: $SEATS_DIR/work" "status must name the seat's profile directory"
  pass "a switch to a logged-in seat records the seat and nothing else"
}

test_switch_to_seat_that_is_not_logged_in_is_refused() {
  local rec out status
  rec=$(make_seat_case switch-refuse)
  read_seat_case "$rec"
  mkdir -p "$SEATS_DIR/spare"
  seat_logged_in "$SPEC_DIR" '(default)'
  # Proven empty, not merely unreadable: only that establishes absence.
  seat_proven_empty "$SPEC_DIR" "$SEATS_DIR/spare"

  out=$(run_seat "$HOME_DIR" "$FAKEBIN" switch spare)
  status=$?
  expect_code 1 "$status" "switching to a seat with no credentials must refuse"
  assert_contains "$out" "not logged in" "the refusal must say the seat is not logged in"
  assert_absent "$HOME_DIR/config/claude-seat" \
    "a refused switch must leave the active seat untouched"
  pass "a switch to a profile that is not logged in is refused and changes nothing"
}

test_forced_switch_cannot_override_a_proven_negative() {
  local rec out status
  rec=$(make_seat_case switch-force)
  read_seat_case "$rec"
  mkdir -p "$SEATS_DIR/spare"
  seat_logged_in "$SPEC_DIR" '(default)'
  seat_proven_empty "$SPEC_DIR" "$SEATS_DIR/spare"

  out=$(run_seat "$HOME_DIR" "$FAKEBIN" switch spare --force)
  status=$?
  expect_code 1 "$status" "--force must not override a profile proven to have no credentials"
  assert_contains "$out" "not logged in" "the forced refusal must still name the cause"
  assert_absent "$HOME_DIR/config/claude-seat" "a refused forced switch must change nothing"
  pass "--force does not override a seat proven to be logged out"
}

test_rate_limited_seat_is_undecided_and_forceable() {
  local rec out status
  rec=$(make_seat_case switch-rate-limited)
  read_seat_case "$rec"
  mkdir -p "$SEATS_DIR/busy"
  seat_logged_in "$SPEC_DIR" '(default)'
  printf '%s\n' "$SEATS_DIR/busy" > "$SPEC_DIR/rate_limited"

  out=$(run_seat "$HOME_DIR" "$FAKEBIN" probe busy)
  status=$?
  expect_code 2 "$status" "a rate-limited signed-in seat must probe as undecided, not logged out"
  assert_not_contains "$out" "not-logged-in" "a rate limit must not be reported as a missing login"

  out=$(run_seat "$HOME_DIR" "$FAKEBIN" switch busy)
  expect_code 1 "$?" "an unforced switch onto an undecided seat must still refuse"
  assert_contains "$out" "--force" "the refusal must point at --force"
  assert_absent "$HOME_DIR/config/claude-seat" "a refused switch must change nothing"

  out=$(run_seat "$HOME_DIR" "$FAKEBIN" switch busy --force)
  expect_code 0 "$?" "--force must switch onto a seat whose quota read was rate limited"
  assert_grep "busy" "$HOME_DIR/config/claude-seat" "the forced switch must record the seat"
  pass "a rate-limited signed-in seat is undecided, and --force switches onto it"
}

test_unreadable_store_is_undecided_and_force_may_cross_it() {
  local rec out status
  rec=$(make_seat_case unreadable-store)
  read_seat_case "$rec"
  mkdir -p "$SEATS_DIR/pending"
  seat_logged_in "$SPEC_DIR" '(default)'
  # 'pending' is neither logged in nor proven empty, so the fake returns the
  # unreadable-store shape. On macOS that is what BOTH a never-logged-in seat
  # and a signed-in seat still awaiting its one-time Keychain approval report,
  # so it must establish nothing.

  out=$(run_seat "$HOME_DIR" "$FAKEBIN" probe pending)
  status=$?
  expect_code 2 "$status" "an unreadable credential store must probe as undecided, not as logged out"
  assert_contains "$out" "unknown" "the probe must report the seat as unknown"

  # A plain switch still refuses, because nothing confirmed the seat is usable.
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" switch pending)
  expect_code 1 "$?" "a plain switch must refuse a seat that could not be confirmed"
  assert_absent "$HOME_DIR/config/claude-seat" "a refused switch must change nothing"

  # --force is the owner accepting that uncertainty, and must get through. A
  # forced switch to a seat that turns out to be empty fails safely on the
  # worker's first message rather than spending another account.
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" switch pending --force)
  expect_code 0 "$?" "--force must cross an undecided probe: $out"
  assert_contains "$out" "-> pending" "the forced switch must take effect"
  assert_grep "pending" "$HOME_DIR/config/claude-seat" "the forced switch must record the seat"
  pass "an unreadable credential store reads as undecided and --force may cross it"
}

test_forced_switch_refuses_a_seat_with_no_profile_directory() {
  local rec out
  rec=$(make_seat_case missing-seat-dir)
  read_seat_case "$rec"
  seat_logged_in "$SPEC_DIR" '(default)'
  # No directory named 'nosuch' exists under the seats root: a typo. A missing
  # profile probes as undecided, so without its own check --force would cross
  # it and send every new worker to a profile that was never set up.
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" switch nosuch --force)
  expect_code 1 "$?" "a forced switch must refuse a seat with no profile directory: $out"
  assert_contains "$out" "fm-seat.sh add nosuch" "the refusal must point at how to create the seat"
  assert_absent "$HOME_DIR/config/claude-seat" "a refused switch must change nothing"
  pass "a forced switch refuses a seat whose profile directory does not exist"
}

test_switch_back_to_default_clears_the_setting() {
  local rec out
  rec=$(make_seat_case switch-back)
  read_seat_case "$rec"
  mkdir -p "$SEATS_DIR/work"
  seat_logged_in "$SPEC_DIR" '(default)' "$SEATS_DIR/work"

  run_seat "$HOME_DIR" "$FAKEBIN" switch work >/dev/null
  assert_present "$HOME_DIR/config/claude-seat" "precondition: the seat setting exists"
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" switch default)
  expect_code 0 "$?" "switching back to the default seat should succeed"
  assert_contains "$out" "switched: work -> default" "switch must report the return"
  assert_absent "$HOME_DIR/config/claude-seat" \
    "returning to the default seat must clear the setting, not record a name"
  pass "switching to the default seat clears the setting and restores ambient behaviour"
}

# add_local_secondmate <home> <fakebin> <id> -> echoes a seeded local secondmate
# home the primary <home> records as live. A fake tmux on <fakebin> absorbs the
# config reread nudge so it can never reach a real tmux server.
add_local_secondmate() {
  local home=$1 fakebin=$2 id=$3 sm
  fm_fake_exit0 "$fakebin" tmux
  sm="$(dirname "$home")/sm-$id"
  mkdir -p "$sm/config" "$sm/data" "$sm/state" "$sm/bin"
  printf '%s\n' "$id" > "$sm/.fm-secondmate-home"
  printf 'instructions\n' > "$sm/AGENTS.md"
  {
    printf 'window=firstmate:fm-%s\n' "$id"
    printf 'kind=secondmate\n'
    printf 'home=%s\n' "$sm"
  } > "$home/state/$id.meta"
  printf '%s\n' "$sm"
}

test_switch_reaches_running_local_secondmate_homes() {
  local rec out sm
  rec=$(make_seat_case switch-secondmate)
  read_seat_case "$rec"
  mkdir -p "$SEATS_DIR/work"
  seat_logged_in "$SPEC_DIR" '(default)' "$SEATS_DIR/work"
  sm=$(add_local_secondmate "$HOME_DIR" "$FAKEBIN" smseat)

  out=$(TMUX='' run_seat "$HOME_DIR" "$FAKEBIN" switch work)
  assert_contains "$out" "switched: default -> work" "the primary switch must be reported"
  [ "$(cat "$sm/config/claude-seat" 2>/dev/null)" = work ] \
    || fail "a switch must carry the new seat to a running local secondmate home: $out"
  assert_contains "$out" "secondmate smseat ($sm)" "the switch must name each secondmate home it reached"
  assert_contains "$out" "claude-seat: pushed" "the switch must report the home as updated"

  out=$(TMUX='' run_seat "$HOME_DIR" "$FAKEBIN" switch default)
  assert_absent "$sm/config/claude-seat" "returning to the default seat must clear it in the secondmate home too"
  pass "a seat switch reaches running local secondmate homes and reports each one"
}

test_failed_secondmate_push_does_not_undo_the_switch() {
  local rec out sm
  if [ "$(id -u)" = 0 ]; then
    printf '# skip - an unwritable secondmate config requires a non-root user\n'
    return
  fi
  rec=$(make_seat_case switch-secondmate-fail)
  read_seat_case "$rec"
  mkdir -p "$SEATS_DIR/work"
  seat_logged_in "$SPEC_DIR" '(default)' "$SEATS_DIR/work"
  sm=$(add_local_secondmate "$HOME_DIR" "$FAKEBIN" smfail)
  chmod 500 "$sm/config"

  out=$(TMUX='' run_seat "$HOME_DIR" "$FAKEBIN" switch work)
  expect_code 0 "$?" "a failed secondmate push must not fail the primary switch: $out"
  chmod 700 "$sm/config"
  assert_grep "work" "$HOME_DIR/config/claude-seat" "the primary switch must stand when a secondmate push fails"
  assert_absent "$sm/config/claude-seat" "precondition: the secondmate home was not updated"
  assert_contains "$out" "not every secondmate home was updated" "a failed push must be reported plainly"
  pass "a failed secondmate push is reported and never undoes the primary switch"
}

# decline_inherited_seats <secondmate-home> [content]
# The declining home's own opt-out flag. Presence is the whole setting, so the
# default case writes an empty file exactly as an operator's `touch` would.
decline_inherited_seats() {
  local sm=$1
  mkdir -p "$sm/config"
  printf '%s' "${2-}" > "$sm/config/claude-seat-local"
}

test_a_declining_home_keeps_its_own_seat_through_a_switch() {
  local rec out sm
  rec=$(make_seat_case switch-decline)
  read_seat_case "$rec"
  mkdir -p "$SEATS_DIR/work"
  seat_logged_in "$SPEC_DIR" '(default)' "$SEATS_DIR/work"
  sm=$(add_local_secondmate "$HOME_DIR" "$FAKEBIN" smdecline)
  decline_inherited_seats "$sm"
  printf 'personal\n' > "$sm/config/claude-seat"
  printf '%s\n' "$CASE_DIR/own-seats" > "$sm/config/claude-seats-root"
  printf '40\n' > "$sm/config/claude-seat-threshold"

  out=$(TMUX='' run_seat "$HOME_DIR" "$FAKEBIN" switch work)
  expect_code 0 "$?" "a switch must succeed with a declining home on the machine: $out"
  assert_grep "work" "$HOME_DIR/config/claude-seat" "the primary switch must still land"
  [ "$(cat "$sm/config/claude-seat" 2>/dev/null)" = personal ] \
    || fail "a declining home must keep its own seat through a switch (got '$(cat "$sm/config/claude-seat" 2>/dev/null)')"
  [ "$(cat "$sm/config/claude-seats-root" 2>/dev/null)" = "$CASE_DIR/own-seats" ] \
    || fail "a declining home must keep its own seats root"
  [ "$(cat "$sm/config/claude-seat-threshold" 2>/dev/null)" = 40 ] \
    || fail "a declining home must keep its own auto-switch threshold"
  assert_contains "$out" "claude-seat: skipped - home declines inherited seat settings" \
    "the switch must say which seat item it skipped and why"
  assert_contains "$out" "secondmate smdecline ($sm)" "the skip must be attributed to the home it belongs to"

  # A home that declines while holding NO seat of its own keeps holding none:
  # the primary's value is not pushed in as a "missing" default either.
  rm -f "$sm/config/claude-seat"
  out=$(TMUX='' run_seat "$HOME_DIR" "$FAKEBIN" switch default)
  expect_code 0 "$?" "the second switch must succeed: $out"
  assert_absent "$sm/config/claude-seat" \
    "a declining home with no seat of its own must still be left alone"

  # The decline takes nothing away from the home itself: it runs its own switch
  # against its own seats root, and that switch reaches no other home.
  mkdir -p "$CASE_DIR/own-seats/client"
  seat_logged_in "$SPEC_DIR" '(default)' "$SEATS_DIR/work" "$CASE_DIR/own-seats/client"
  out=$(TMUX='' run_seat "$sm" "$FAKEBIN" switch client)
  expect_code 0 "$?" "a declining home must still run its own switch: $out"
  [ "$(cat "$sm/config/claude-seat" 2>/dev/null)" = client ] \
    || fail "a declining home's own switch must record its own seat: $out"
  assert_absent "$HOME_DIR/config/claude-seat" \
    "a declining home's own switch must not reach back into the primary"
  pass "a local home that declines keeps its own three seat settings through a switch"
}

test_a_switch_still_reaches_every_home_that_did_not_decline() {
  local rec out declining taking
  rec=$(make_seat_case switch-mixed)
  read_seat_case "$rec"
  mkdir -p "$SEATS_DIR/work"
  seat_logged_in "$SPEC_DIR" '(default)' "$SEATS_DIR/work"
  declining=$(add_local_secondmate "$HOME_DIR" "$FAKEBIN" smoptout)
  taking=$(add_local_secondmate "$HOME_DIR" "$FAKEBIN" smfleet)
  # Presence alone is the setting, so text an operator might expect to turn it
  # back off does not: a file saying "off" still declines.
  decline_inherited_seats "$declining" 'off
'
  printf 'personal\n' > "$declining/config/claude-seat"

  out=$(TMUX='' run_seat "$HOME_DIR" "$FAKEBIN" switch work)
  expect_code 0 "$?" "the switch should succeed: $out"
  [ "$(cat "$taking/config/claude-seat" 2>/dev/null)" = work ] \
    || fail "one home's decline must not hold back any other local home: $out"
  [ "$(cat "$declining/config/claude-seat" 2>/dev/null)" = personal ] \
    || fail "the declining home must be the only one left alone, whatever its flag file says"
  pass "one home's decline leaves every other local home taking the switch"
}

test_status_names_every_local_home_that_declined() {
  local rec out declining taking
  rec=$(make_seat_case status-decline)
  read_seat_case "$rec"
  seat_logged_in "$SPEC_DIR" '(default)'

  out=$(run_seat "$HOME_DIR" "$FAKEBIN" status)
  assert_contains "$out" "local secondmate homes declining inherited seats:" \
    "status must always carry the declining-homes section"
  assert_contains "$out" "(none - every local home takes this seat)" \
    "with no decline anywhere status must say so plainly"

  declining=$(add_local_secondmate "$HOME_DIR" "$FAKEBIN" smshown)
  taking=$(add_local_secondmate "$HOME_DIR" "$FAKEBIN" smhidden)
  decline_inherited_seats "$declining"
  printf 'personal\n' > "$declining/config/claude-seat"
  printf 'work\n' > "$taking/config/claude-seat"

  out=$(run_seat "$HOME_DIR" "$FAKEBIN" status |
    sed -n '/^local secondmate homes declining inherited seats:$/,$p')
  assert_contains "$out" "smshown	personal	$declining" \
    "status must name each declining home with the seat it is actually on"
  assert_not_contains "$out" "smhidden" \
    "the declining section must not list a home that takes the fleet's seat"
  pass "status names every local home that declined and the seat it is really on"
}

test_a_non_file_decline_flag_still_declines() {
  local rec out sm_dir sm_link kind
  rec=$(make_seat_case decline-non-file)
  read_seat_case "$rec"
  mkdir -p "$SEATS_DIR/work"
  seat_logged_in "$SPEC_DIR" '(default)' "$SEATS_DIR/work"
  sm_dir=$(add_local_secondmate "$HOME_DIR" "$FAKEBIN" smdirflag)
  sm_link=$(add_local_secondmate "$HOME_DIR" "$FAKEBIN" smlinkflag)
  mkdir -p "$sm_dir/config/claude-seat-local"
  mkdir -p "$sm_link/config"
  ln -s "$CASE_DIR/nowhere" "$sm_link/config/claude-seat-local"
  printf 'personal\n' > "$sm_link/config/claude-seat"

  out=$(TMUX='' run_seat "$HOME_DIR" "$FAKEBIN" switch work 2>&1)
  expect_code 0 "$?" "a switch must succeed with non-file decline flags on the machine: $out"
  assert_grep "work" "$HOME_DIR/config/claude-seat" "the primary switch must still stand"
  assert_absent "$sm_dir/config/claude-seat" \
    "a directory flag must decline, not let the seat through"
  [ "$(cat "$sm_link/config/claude-seat" 2>/dev/null)" = personal ] \
    || fail "a dangling symlink flag must decline and keep the home's own seat"
  assert_not_contains "$out" "not every secondmate home was updated" \
    "a non-file decline flag is a decline, not a push failure"
  for kind in smdirflag smlinkflag; do
    assert_contains "$out" "secondmate $kind" "the switch must report the declining home $kind"
  done
  assert_contains "$out" "claude-seat: skipped - home declines inherited seat settings" \
    "a non-file flag must be reported as a decline"

  out=$(run_seat "$HOME_DIR" "$FAKEBIN" status)
  assert_contains "$out" "smdirflag	default	$sm_dir" \
    "status must list a directory-flag home as declined"
  assert_contains "$out" "smlinkflag	personal	$sm_link" \
    "status must list a dangling-symlink-flag home as declined"
  pass "a decline flag of any type declines and shows in status"
}

# add_unreachable_remote_secondmate <home> <fakebin> <id> -> echoes the path of
# a log that records every SSH attempt to the remote route, which always fails.
add_unreachable_remote_secondmate() {
  local home=$1 fakebin=$2 id=$3 log
  log="$(dirname "$home")/ssh-$id.log"
  : > "$log"
  cat > "$fakebin/unreachable-ssh" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$log"
exit 255
SH
  chmod +x "$fakebin/unreachable-ssh"
  {
    printf 'window=firstmate:fm-%s\n' "$id"
    printf 'kind=secondmate\n'
    printf 'home=/remote/home-%s\n' "$id"
    printf 'remote_host=down-host\n'
  } > "$home/state/$id.meta"
  printf -- '- %s - Remote route (host: down-host; root: /remote/root; home: /remote/home-%s; scope: test; projects: ; added 2026-09-23)\n' \
    "$id" "$id" >> "$home/data/secondmates.md"
  printf '%s\n' "$log"
}

test_switch_never_contacts_remote_routes() {
  local rec out sm log
  rec=$(make_seat_case switch-remote-down)
  read_seat_case "$rec"
  mkdir -p "$SEATS_DIR/work"
  seat_logged_in "$SPEC_DIR" '(default)' "$SEATS_DIR/work"
  sm=$(add_local_secondmate "$HOME_DIR" "$FAKEBIN" smlocal)
  log=$(add_unreachable_remote_secondmate "$HOME_DIR" "$FAKEBIN" smremote)

  out=$(TMUX='' FM_SSH_BIN="$FAKEBIN/unreachable-ssh" run_seat "$HOME_DIR" "$FAKEBIN" switch work)
  expect_code 0 "$?" "a switch with an unreachable remote route should succeed: $out"
  [ "$(cat "$sm/config/claude-seat" 2>/dev/null)" = work ] \
    || fail "the local secondmate home must still take the new seat: $out"
  [ ! -s "$log" ] || fail "a seat switch must never open SSH to a remote route: $(cat "$log")"
  assert_not_contains "$out" "smremote" "a switch must report only this machine's homes"
  assert_not_contains "$out" "not every secondmate home was updated" \
    "an unreachable remote route must not make a switch report a home stuck on its previous seat"
  pass "a seat switch pushes only local secondmate homes and never waits on a remote route"
}

test_config_push_without_local_only_still_reaches_remote_routes() {
  local rec out sm log
  rec=$(make_seat_case push-no-flag)
  read_seat_case "$rec"
  printf 'codex\n' > "$HOME_DIR/config/crew-harness"
  sm=$(add_local_secondmate "$HOME_DIR" "$FAKEBIN" smlocal)
  log=$(add_unreachable_remote_secondmate "$HOME_DIR" "$FAKEBIN" smremote)
  out=$(TMUX='' PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_SSH_BIN="$FAKEBIN/unreachable-ssh" "$ROOT/bin/fm-config-push.sh" 2>&1)
  expect_code 1 "$?" "a plain config push must still report the unreachable remote route: $out"
  [ -s "$log" ] || fail "a plain config push must still attempt the remote route: $out"
  assert_contains "$out" "secondmate smremote (down-host:" "a plain config push must report the remote route"
  [ "$(cat "$sm/config/crew-harness" 2>/dev/null)" = codex ] \
    || fail "a plain config push must still update the local home: $out"

  : > "$log"
  out=$(TMUX='' PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_SSH_BIN="$FAKEBIN/unreachable-ssh" "$ROOT/bin/fm-config-push.sh" --local-only 2>&1)
  expect_code 0 "$?" "a local-only config push must skip the remote route: $out"
  [ ! -s "$log" ] || fail "a local-only config push must not open SSH: $(cat "$log")"
  assert_contains "$out" "secondmate smlocal (" "a local-only config push must still report the local home"
  pass "fm-config-push reaches remote routes by default and skips them only with --local-only"
}

test_remote_route_never_receives_seat_settings() {
  local rec out remote payload hash
  rec=$(make_seat_case remote-inherit)
  read_seat_case "$rec"
  remote="$CASE_DIR/remote-home"
  mkdir -p "$remote/config" "$remote/data" "$remote/state"
  printf 'work\n' > "$HOME_DIR/config/claude-seat"
  printf '15\n' > "$HOME_DIR/config/claude-seat-threshold"
  printf 'codex\n' > "$HOME_DIR/config/crew-harness"
  printf -- '- remsm - Remote route (host: inherit-host; root: %s; home: %s; scope: test; projects: ; added 2026-09-23)\n' \
    "$ROOT" "$remote" > "$HOME_DIR/data/secondmates.md"
  cat > "$FAKEBIN/inherit-ssh" <<'SH'
#!/usr/bin/env bash
set -eu
while [ "$#" -gt 0 ]; do
  case "$1" in -o) shift 2 ;; --) shift; break ;; *) exit 90 ;; esac
done
[ "$#" -eq 6 ] && [ "$1" = inherit-host ] && [ "$2" = fm-remote-entrypoint.sh ] || exit 91
remote_root=$(printf '%s' "$4" | base64 --decode)
remote_home=$(printf '%s' "$5" | base64 --decode)
args=()
while IFS= read -r -d '' arg; do args+=("$arg"); done < <(printf '%s' "$6" | base64 --decode)
FM_HOME="$remote_home" FM_STATE_OVERRIDE="$remote_home/state" \
  exec "$remote_root/bin/${args[0]}" "${args[@]:1}"
SH
  chmod +x "$FAKEBIN/inherit-ssh"

  out=$(FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_DATA_OVERRIDE="$HOME_DIR/data" FM_SSH_BIN="$FAKEBIN/inherit-ssh" \
    "$ROOT/bin/fm-remote-inherit-push.sh" remsm 1 2>&1)
  expect_code 0 "$?" "the remote inheritance push should succeed: $out"
  [ "$(cat "$remote/config/crew-harness" 2>/dev/null)" = codex ] \
    || fail "precondition: the remote push must still carry ordinary inherited config: $out"
  assert_absent "$remote/config/claude-seat" "a remote route must never receive the active seat"
  assert_absent "$remote/config/claude-seat-threshold" "a remote route must never receive the seat threshold"
  assert_not_contains "$out" "claude-seat" "the remote push must not transfer any seat setting"

  payload="$CASE_DIR/seat-payload"
  printf 'work\n' > "$payload"
  hash=$(shasum -a 256 "$payload" 2>/dev/null | awk '{print $1}' || sha256sum "$payload" | awk '{print $1}')
  out=$(FM_HOME="$remote" FM_STATE_OVERRIDE="$remote/state" \
    "$ROOT/bin/fm-remote-inherit.sh" put config/claude-seat 5 "$hash" 2 < "$payload" 2>&1)
  expect_code 1 "$?" "the remote receiver must refuse a seat setting: $out"
  assert_absent "$remote/config/claude-seat" "a refused seat setting must not land in the remote home"
  pass "seat settings reach local secondmate homes only and never cross to a remote route"
}

test_threshold_is_configurable_and_absent_by_default() {
  local rec out
  rec=$(make_seat_case threshold-config)
  read_seat_case "$rec"
  seat_logged_in "$SPEC_DIR" '(default)'

  out=$(run_seat "$HOME_DIR" "$FAKEBIN" threshold)
  assert_contains "$out" "(unset" "an unconfigured threshold must report as unset"

  out=$(run_seat "$HOME_DIR" "$FAKEBIN" threshold 15)
  expect_code 0 "$?" "setting a threshold should succeed"
  assert_contains "$out" "15%" "setting a threshold must echo it"
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" threshold)
  assert_contains "$out" "15" "the threshold must read back"

  out=$(run_seat "$HOME_DIR" "$FAKEBIN" threshold 101)
  expect_code 1 "$?" "an out-of-range threshold must be refused"
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" threshold)
  assert_contains "$out" "15" "a refused threshold must leave the configured one intact"

  out=$(run_seat "$HOME_DIR" "$FAKEBIN" threshold off)
  expect_code 0 "$?" "clearing the threshold should succeed"
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" threshold)
  assert_contains "$out" "(unset" "a cleared threshold must report as unset"
  pass "the auto-switch threshold is configurable, validated, clearable, and unset by default"
}

test_threshold_reached_is_edge_triggered_by_the_configured_percent() {
  local rec status
  rec=$(make_seat_case threshold-edge)
  read_seat_case "$rec"
  seat_logged_in "$SPEC_DIR" '(default)'

  # No threshold configured: the condition must be an error, never a true, so a
  # home that never asked for automatic switching can never switch.
  run_seat "$HOME_DIR" "$FAKEBIN" threshold-reached >/dev/null
  expect_code 2 "$?" "with no threshold configured the condition must report an error"

  run_seat "$HOME_DIR" "$FAKEBIN" threshold 20 >/dev/null

  printf '80\n' > "$SPEC_DIR/remaining"
  run_seat "$HOME_DIR" "$FAKEBIN" threshold-reached >/dev/null
  expect_code 1 "$?" "well above the threshold the condition must be false"

  printf '21\n' > "$SPEC_DIR/remaining"
  run_seat "$HOME_DIR" "$FAKEBIN" threshold-reached >/dev/null
  expect_code 1 "$?" "just above the threshold the condition must still be false"

  printf '20\n' > "$SPEC_DIR/remaining"
  run_seat "$HOME_DIR" "$FAKEBIN" threshold-reached >/dev/null
  status=$?
  expect_code 0 "$status" "at the threshold the condition must be true"

  printf '5\n' > "$SPEC_DIR/remaining"
  run_seat "$HOME_DIR" "$FAKEBIN" threshold-reached >/dev/null
  expect_code 0 "$?" "below the threshold the condition must be true"
  pass "the threshold condition turns true exactly at the configured percent"
}

test_unreadable_quota_never_reports_the_threshold_reached() {
  local rec
  rec=$(make_seat_case threshold-unreadable)
  read_seat_case "$rec"
  seat_logged_in "$SPEC_DIR" '(default)'
  run_seat "$HOME_DIR" "$FAKEBIN" threshold 20 >/dev/null

  # An active seat whose quota cannot be read at all: the report carries no
  # known availability, so the condition must be an error rather than a true.
  : > "$SPEC_DIR/oauth"
  run_seat "$HOME_DIR" "$FAKEBIN" threshold-reached >/dev/null
  expect_code 2 "$?" "an unreadable quota must be an error, never a fired condition"
  pass "an unreadable quota never trips an automatic switch"
}

test_model_scoped_window_alone_does_not_trip_the_threshold() {
  local rec
  rec=$(make_seat_case threshold-scope)
  read_seat_case "$rec"
  seat_logged_in "$SPEC_DIR" '(default)'
  run_seat "$HOME_DIR" "$FAKEBIN" threshold 10 >/dev/null

  # An Opus-only window nearly spent while the account-level window has plenty
  # left: only workers on that model are constrained, so no switch.
  cat > "$SPEC_DIR/availability" <<'JSON'
[{"scope":"all_models","status":"known","effectivePercentRemaining":60,"runway":{"status":"through_reset"}},
 {"scope":"model:opus","status":"known","effectivePercentRemaining":5,"runway":{"status":"through_reset"}}]
JSON
  run_seat "$HOME_DIR" "$FAKEBIN" threshold-reached >/dev/null
  expect_code 1 "$?" "a model-scoped window below the threshold must not trip the account-level condition"

  # A report with no account-level window at all is undecidable, never a true.
  cat > "$SPEC_DIR/availability" <<'JSON'
[{"scope":"model:opus","status":"known","effectivePercentRemaining":5,"runway":{"status":"through_reset"}}]
JSON
  run_seat "$HOME_DIR" "$FAKEBIN" threshold-reached >/dev/null
  expect_code 2 "$?" "a report with no account-level window must be an error, not a fired condition"
  pass "only account-level quota windows count toward the auto-switch threshold"
}

test_default_seat_probes_the_ambient_profile_workers_get() {
  local rec out ambient
  rec=$(make_seat_case default-ambient)
  read_seat_case "$rec"
  ambient="$CASE_DIR/ambient-profile"
  # Only firstmate's own ambient profile is logged in; the bare ~/.claude is not.
  seat_logged_in "$SPEC_DIR" "$ambient"
  run_seat "$HOME_DIR" "$FAKEBIN" threshold 20 >/dev/null
  printf '5\n' > "$SPEC_DIR/remaining"

  out=$(SEAT_TEST_AMBIENT_CONFIG_DIR="$ambient" run_seat "$HOME_DIR" "$FAKEBIN" probe default)
  expect_code 0 "$?" "the default seat must probe the ambient profile a new worker would get: $out"
  out=$(SEAT_TEST_AMBIENT_CONFIG_DIR="$ambient" run_seat "$HOME_DIR" "$FAKEBIN" status)
  assert_contains "$out" "active profile: $ambient" "status must name the ambient profile for the default seat"
  assert_contains "$out" "login state: logged-in" "status must report the ambient profile's login state"
  SEAT_TEST_AMBIENT_CONFIG_DIR="$ambient" run_seat "$HOME_DIR" "$FAKEBIN" threshold-reached >/dev/null
  expect_code 0 "$?" "the threshold must be read against the ambient profile default-seat workers spend"
  pass "the default seat's probe and threshold read the ambient profile new workers launch with"
}

test_rotation_picks_the_next_logged_in_seat() {
  local rec out
  rec=$(make_seat_case rotate)
  read_seat_case "$rec"
  mkdir -p "$SEATS_DIR/work" "$SEATS_DIR/spare" "$SEATS_DIR/third"
  # 'spare' has no credentials, so rotation must skip it.
  seat_logged_in "$SPEC_DIR" '(default)' "$SEATS_DIR/work" "$SEATS_DIR/third"

  out=$(run_seat "$HOME_DIR" "$FAKEBIN" switch --next)
  expect_code 0 "$?" "rotation to a logged-in seat should succeed"
  assert_contains "$out" "-> third" "rotation must skip the seat that is not logged in"

  out=$(run_seat "$HOME_DIR" "$FAKEBIN" switch --next)
  expect_code 0 "$?" "rotation should continue to the other logged-in seat"
  assert_contains "$out" "-> work" "rotation must move on to the remaining logged-in seat"

  # And it wraps, still without ever choosing the default profile.
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" switch --next)
  expect_code 0 "$?" "rotation should wrap"
  assert_contains "$out" "-> third" "rotation must wrap among the seats under the root"
  pass "rotation chooses the next logged-in seat under the root and skips ones with no credentials"
}

test_a_lapsed_seat_reads_as_usable_rather_than_unknown() {
  local rec out
  rec=$(make_seat_case lapsed-usable)
  read_seat_case "$rec"
  mkdir -p "$SEATS_DIR/idle"
  seat_logged_in "$SPEC_DIR" '(default)'
  seat_expired_refreshable "$SPEC_DIR" "$SEATS_DIR/idle"

  out=$(run_seat "$HOME_DIR" "$FAKEBIN" list)
  assert_contains "$out" "expired-renewable" \
    "a signed-in seat whose access token lapsed must read as expired-renewable"
  assert_not_contains "$out" "idle	unknown" \
    "a lapsed seat must not be reported as an unreadable one"

  out=$(run_seat "$HOME_DIR" "$FAKEBIN" probe idle)
  expect_code 0 "$?" "probe must report a lapsed seat as usable, because a launch there renews it"
  assert_contains "$out" "expired-renewable" "probe must name the lapsed state"
  pass "a lapsed but renewable seat reads as usable instead of unknown"
}

test_the_lapsed_verdict_comes_from_the_field_not_the_message() {
  local rec out
  rec=$(make_seat_case lapsed-other-route)
  read_seat_case "$rec"
  mkdir -p "$SEATS_DIR/idle"
  seat_logged_in "$SPEC_DIR" '(default)'
  # Same state, quota-axi's other route: different error text, an extra failed
  # attempt, and a rate-limit message that on its own would read as undecided.
  seat_expired_refreshable_confirmed "$SPEC_DIR" "$SEATS_DIR/idle"

  out=$(run_seat "$HOME_DIR" "$FAKEBIN" probe idle)
  expect_code 0 "$?" \
    "the lapsed verdict must survive a different error message, because only authStatus is stable"
  assert_contains "$out" "expired-renewable" \
    "the second route to the same state must produce the same verdict"
  pass "the lapsed verdict is read from authStatus, not from the error text"
}

test_switching_to_a_lapsed_seat_needs_no_force() {
  local rec out
  rec=$(make_seat_case lapsed-switch)
  read_seat_case "$rec"
  mkdir -p "$SEATS_DIR/idle"
  seat_logged_in "$SPEC_DIR" '(default)'
  seat_expired_refreshable "$SPEC_DIR" "$SEATS_DIR/idle"

  out=$(run_seat "$HOME_DIR" "$FAKEBIN" switch idle)
  expect_code 0 "$?" "a switch to a lapsed seat must not require --force"
  assert_contains "$out" "-> idle" "the switch must land on the lapsed seat"
  assert_contains "$out" "access token has lapsed" \
    "the switch must say the token lapsed and that the next worker renews it"
  assert_equals "idle" "$(cat "$HOME_DIR/config/claude-seat")" \
    "the active seat must be recorded"
  pass "switching to a lapsed seat succeeds without --force"
}

test_a_lapsed_seat_is_a_rotation_destination() {
  local rec out
  rec=$(make_seat_case lapsed-rotate)
  read_seat_case "$rec"
  mkdir -p "$SEATS_DIR/idle"
  seat_logged_in "$SPEC_DIR" '(default)'
  seat_expired_refreshable "$SPEC_DIR" "$SEATS_DIR/idle"

  out=$(run_seat "$HOME_DIR" "$FAKEBIN" switch --next)
  expect_code 0 "$?" \
    "rotation must accept a lapsed seat, because a launch there renews it"
  assert_contains "$out" "-> idle" "rotation must land on the lapsed seat"
  assert_not_contains "$out" "not logged in" \
    "rotation must never describe a signed-in seat as not logged in"
  pass "rotation treats a lapsed seat as a destination when no destination minimum is set"
}

test_a_lapsed_seat_is_skipped_for_unknown_headroom_under_a_destination_minimum() {
  local rec out
  rec=$(make_seat_case lapsed-destination-min)
  read_seat_case "$rec"
  mkdir -p "$SEATS_DIR/idle"
  seat_logged_in "$SPEC_DIR" '(default)'
  seat_expired_refreshable "$SPEC_DIR" "$SEATS_DIR/idle"
  printf '20\n' > "$HOME_DIR/config/claude-seat-destination-min"

  # A lapsed seat has no readable quota until something renews it, so it cannot
  # answer a headroom comparison and must be skipped - but for that reason, not
  # for its login state.
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" switch --next)
  expect_code 1 "$?" "a lapsed seat cannot satisfy a destination minimum it has no number for"
  assert_contains "$out" "headroom cannot be read" \
    "the skip must name the unreadable headroom as the reason"
  assert_not_contains "$out" "not logged in" \
    "the skip must not claim a signed-in seat has no login"
  pass "a destination minimum skips a lapsed seat for unknown headroom, not for its login state"
}

test_a_signed_out_seat_is_refused_and_force_cannot_cross_it() {
  local rec out
  rec=$(make_seat_case signed-out)
  read_seat_case "$rec"
  mkdir -p "$SEATS_DIR/dead"
  seat_logged_in "$SPEC_DIR" '(default)'
  seat_signed_out "$SPEC_DIR" "$SEATS_DIR/dead"

  out=$(run_seat "$HOME_DIR" "$FAKEBIN" probe dead)
  expect_code 1 "$?" "a seat whose store was read and holds no login must be proven not logged in"
  assert_contains "$out" "not-logged-in" "probe must name the signed-out state"

  out=$(run_seat "$HOME_DIR" "$FAKEBIN" switch dead)
  expect_code 1 "$?" "a switch to a signed-out seat must refuse"
  assert_contains "$out" "is not logged in" "the refusal must say the seat holds no login"

  # The point of separating this from an undecided read: --force exists to cross
  # uncertainty, never a proven negative.
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" switch dead --force)
  expect_code 1 "$?" "--force must not cross a proven signed-out seat"
  assert_contains "$out" "is not logged in" "the forced refusal must give the same reason"
  assert_absent "$HOME_DIR/config/claude-seat" "no active seat may be recorded by a refused switch"
  pass "a genuinely signed-out seat is refused and --force cannot cross it"
}

test_a_signed_out_seat_is_never_a_rotation_destination() {
  local rec out
  rec=$(make_seat_case signed-out-rotate)
  read_seat_case "$rec"
  mkdir -p "$SEATS_DIR/dead" "$SEATS_DIR/idle"
  seat_logged_in "$SPEC_DIR" '(default)'
  seat_signed_out "$SPEC_DIR" "$SEATS_DIR/dead"
  seat_expired_refreshable "$SPEC_DIR" "$SEATS_DIR/idle"

  # Both seats read as something other than a clean login, and they must not be
  # treated alike: the lapsed one is launchable and the signed-out one is not.
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" switch --next)
  expect_code 0 "$?" "rotation should still find the lapsed seat"
  assert_contains "$out" "-> idle" "rotation must choose the lapsed seat over the signed-out one"
  assert_contains "$out" "dead: skipped, not logged in" \
    "rotation must report the signed-out seat as skipped for its own reason"
  pass "rotation separates a signed-out seat from a merely lapsed one"
}

test_a_rejected_request_is_not_a_sign_out_and_force_may_cross_it() {
  local rec out
  rec=$(make_seat_case rejected-401)
  read_seat_case "$rec"
  mkdir -p "$SEATS_DIR/revoked"
  seat_logged_in "$SPEC_DIR" '(default)'
  printf '%s\n' "$SEATS_DIR/revoked" > "$SPEC_DIR/rejected_401"

  # auth_required from a 401 says the endpoint refused a presented credential,
  # not that the store is empty, so it must not be the uncrossable refusal.
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" probe revoked)
  expect_code 2 "$?" "a 401 against a stored credential must probe as undecided"
  assert_contains "$out" "unknown" "the probe must report the seat as unknown"
  assert_not_contains "$out" "not-logged-in" "a 401 must not be reported as a sign-out"

  out=$(run_seat "$HOME_DIR" "$FAKEBIN" switch revoked --force)
  expect_code 0 "$?" "--force must cross a 401 read: $out"
  assert_grep "revoked" "$HOME_DIR/config/claude-seat" "the forced switch must record the seat"
  pass "an auth_required read from a rejected request is undecided and --force may cross it"
}

test_rotation_never_targets_the_default_profile() {
  local rec out status
  rec=$(make_seat_case rotate-not-default)
  read_seat_case "$rec"
  mkdir -p "$SEATS_DIR/work"
  # The default profile is logged in and is the only other candidate, but it is
  # the owner's own interactive login and its account can change under them, so
  # an automatic rotation must never land workers on it.
  seat_logged_in "$SPEC_DIR" '(default)' "$SEATS_DIR/work"
  printf 'work\n' > "$HOME_DIR/config/claude-seat"

  out=$(run_seat "$HOME_DIR" "$FAKEBIN" switch --next)
  status=$?
  expect_code 1 "$status" "rotation must refuse rather than fall back to the default profile"
  assert_not_contains "$out" "-> default" "rotation must never choose the default profile"
  assert_grep "work" "$HOME_DIR/config/claude-seat" "a refused rotation must leave the active seat in place"
  pass "rotation never targets the default profile, even when it is the only other logged-in store"
}

test_rotation_refuses_when_there_is_nowhere_to_go() {
  local rec out status
  rec=$(make_seat_case rotate-nowhere)
  read_seat_case "$rec"
  # Two seats rejected for genuinely different reasons: 'spare' falls through to
  # the unreadable-store shape, which establishes nothing, while 'dead' was read
  # and proven to hold no login. Each must be reported as what it actually is.
  mkdir -p "$SEATS_DIR/spare" "$SEATS_DIR/dead"
  seat_logged_in "$SPEC_DIR" '(default)'
  seat_signed_out "$SPEC_DIR" "$SEATS_DIR/dead"

  out=$(run_seat "$HOME_DIR" "$FAKEBIN" switch --next)
  status=$?
  expect_code 1 "$status" "rotation with no other usable seat must refuse"
  assert_contains "$out" "no seat under the seats root qualifies" "the refusal must name the cause"
  assert_contains "$out" "seat spare: skipped, its login state could not be confirmed" \
    "a seat whose store could not be read must not be reported as having no login"
  assert_contains "$out" "seat dead: skipped, not logged in" \
    "only a seat proven to hold no login may be reported as not logged in"
  assert_absent "$HOME_DIR/config/claude-seat" "a refused rotation must change nothing"
  pass "rotation refuses with an accurate reason per seat rather than pretending to switch"
}

test_rotation_reads_the_seat_set_fresh() {
  local rec out
  rec=$(make_seat_case rotate-fresh)
  read_seat_case "$rec"
  mkdir -p "$SEATS_DIR/work"
  seat_logged_in "$SPEC_DIR" "$SEATS_DIR/work"
  printf 'work\n' > "$HOME_DIR/config/claude-seat"

  # Nothing else exists yet, so there is nowhere to rotate.
  run_seat "$HOME_DIR" "$FAKEBIN" switch --next >/dev/null 2>&1
  expect_code 1 "$?" "precondition: a single seat leaves nowhere to rotate"

  # A seat added afterwards must be picked up without anything being re-armed:
  # the seat set is never assumed or cached.
  mkdir -p "$SEATS_DIR/later"
  seat_logged_in "$SPEC_DIR" "$SEATS_DIR/work" "$SEATS_DIR/later"
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" switch --next)
  expect_code 0 "$?" "a seat created after the first attempt should be found"
  assert_contains "$out" "-> later" "rotation must read the seat set fresh each time"
  pass "rotation never assumes which seats exist and picks up seats added later"
}

# --- holding a seat out of automatic rotation --------------------------------
# The property these cover: one shared candidate filter, so every AUTOMATIC path
# skips an excluded seat, while `switch <name>` keeps reaching it. The seat that
# motivated it is a personal account on a work machine - usable deliberately,
# never billed by a rotation nobody watched.

test_auto_exclude_and_include_round_trip() {
  local rec out
  rec=$(make_seat_case auto-exclude-roundtrip)
  read_seat_case "$rec"
  mkdir -p "$SEATS_DIR/work" "$SEATS_DIR/personal"
  seat_logged_in "$SPEC_DIR" "$SEATS_DIR/work" "$SEATS_DIR/personal"

  out=$(run_seat "$HOME_DIR" "$FAKEBIN" auto-exclude)
  assert_contains "$out" "(none" "no seat may be excluded before anything asks for it"
  assert_absent "$HOME_DIR/config/claude-seat-auto-exclude" \
    "an unconfigured home must carry no exclusion file at all"

  out=$(run_seat "$HOME_DIR" "$FAKEBIN" auto-exclude personal)
  expect_code 0 "$?" "excluding an existing seat should succeed"
  assert_contains "$out" "excluded from automatic rotation: personal" "the exclusion must be reported"
  assert_grep "personal" "$HOME_DIR/config/claude-seat-auto-exclude" "the exclusion must be recorded"

  # Idempotent: a second exclusion is a success that changes nothing.
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" auto-exclude personal)
  expect_code 0 "$?" "excluding an already-excluded seat must succeed"
  assert_contains "$out" "already excluded" "a repeat exclusion must say it changed nothing"
  [ "$(grep -c . "$HOME_DIR/config/claude-seat-auto-exclude")" = 1 ] ||
    fail "a repeat exclusion must not record the seat twice"

  # A second seat joins the first rather than replacing it.
  run_seat "$HOME_DIR" "$FAKEBIN" auto-exclude work >/dev/null
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" auto-exclude)
  assert_contains "$out" "personal" "an earlier exclusion must survive a later one"
  assert_contains "$out" "work" "the later exclusion must be recorded beside it"

  # Including a seat that was never excluded is a no-op success, not an error.
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" auto-include never-excluded)
  expect_code 0 "$?" "including a seat that is already in rotation must succeed"
  assert_contains "$out" "not excluded from automatic rotation" \
    "including a seat that was never excluded must say so rather than fail"

  run_seat "$HOME_DIR" "$FAKEBIN" auto-include work >/dev/null
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" auto-include personal)
  expect_code 0 "$?" "including the last excluded seat should succeed"
  assert_contains "$out" "back in automatic rotation: personal" "the return to rotation must be reported"
  assert_absent "$HOME_DIR/config/claude-seat-auto-exclude" \
    "clearing the last exclusion must remove the file rather than leave an empty one"
  pass "auto-exclude and auto-include round trip idempotently and leave no empty record behind"
}

test_auto_exclude_refuses_a_name_that_is_not_a_seat() {
  local rec out status
  rec=$(make_seat_case auto-exclude-unknown)
  read_seat_case "$rec"
  mkdir -p "$SEATS_DIR/work"
  seat_logged_in "$SPEC_DIR" "$SEATS_DIR/work"

  # An exclusion that matches no seat would silently keep rotating onto the seat
  # it was meant to withhold, so a typo must be refused rather than recorded.
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" auto-exclude wrok)
  status=$?
  expect_code 1 "$status" "excluding a name with no seat directory must refuse"
  assert_contains "$out" "has no profile directory" "the refusal must name the cause"
  assert_absent "$HOME_DIR/config/claude-seat-auto-exclude" \
    "a refused exclusion must record nothing"

  # The default login is never an automatic destination, so excluding it would
  # be a setting that does nothing; that is refused too rather than accepted.
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" auto-exclude default)
  status=$?
  expect_code 1 "$status" "excluding the default login must refuse"
  assert_contains "$out" "never an automatic rotation target" "the refusal must say why"
  assert_absent "$HOME_DIR/config/claude-seat-auto-exclude" \
    "refusing the default login must record nothing"
  pass "auto-exclude refuses a name that is not a seat and the default login that is never a target"
}

test_status_and_list_report_an_excluded_seat() {
  local rec out
  rec=$(make_seat_case auto-exclude-reporting)
  read_seat_case "$rec"
  mkdir -p "$SEATS_DIR/work" "$SEATS_DIR/personal"
  seat_logged_in "$SPEC_DIR" "$SEATS_DIR/work" "$SEATS_DIR/personal"
  printf 'work\n' > "$HOME_DIR/config/claude-seat"

  out=$(run_seat "$HOME_DIR" "$FAKEBIN" status)
  assert_contains "$out" "held out of automatic rotation by hand: (none" \
    "status must say when no seat is held out"
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" list)
  assert_not_contains "$out" "held out of automatic rotation by hand" \
    "list must mark nothing while no seat is held out"

  run_seat "$HOME_DIR" "$FAKEBIN" auto-exclude personal >/dev/null

  out=$(run_seat "$HOME_DIR" "$FAKEBIN" status)
  assert_contains "$out" "held out of automatic rotation by hand: personal" \
    "status must name every seat held out by hand"
  assert_contains "$out" "switch <name> still reaches them" \
    "status must say the exclusion is automatic-only"

  out=$(run_seat "$HOME_DIR" "$FAKEBIN" list)
  assert_contains "$out" "held out of automatic rotation by hand" "list must mark the excluded seat"
  printf '%s\n' "$out" | grep -q '^  personal.*held out of automatic rotation by hand$' ||
    fail "list must mark the excluded seat on its own row: $out"
  printf '%s\n' "$out" | grep -q '^\* work' ||
    fail "list must still mark the active seat: $out"
  printf '%s\n' "$out" | grep '^\* work' | grep -q 'excluded' &&
    fail "list must not mark a seat that is still in rotation: $out"
  pass "status and list both report which seats are held out of automatic rotation"
}

test_rotation_skips_an_excluded_seat() {
  local rec out
  rec=$(make_seat_case auto-exclude-rotation)
  read_seat_case "$rec"
  mkdir -p "$SEATS_DIR/alpha" "$SEATS_DIR/beta" "$SEATS_DIR/personal"
  # Every seat is logged in, so the ONLY reason to pass one over is the
  # exclusion: nothing else in the rotation gate can account for the result.
  seat_logged_in "$SPEC_DIR" "$SEATS_DIR/alpha" "$SEATS_DIR/beta" "$SEATS_DIR/personal"
  printf 'alpha\n' > "$HOME_DIR/config/claude-seat"
  run_seat "$HOME_DIR" "$FAKEBIN" auto-exclude personal >/dev/null

  out=$(run_seat "$HOME_DIR" "$FAKEBIN" switch --next)
  expect_code 0 "$?" "rotation past an excluded seat should still succeed"
  assert_contains "$out" "-> beta" "rotation must land on the seat that is still in rotation"

  out=$(run_seat "$HOME_DIR" "$FAKEBIN" switch --next)
  expect_code 0 "$?" "rotation should wrap"
  assert_contains "$out" "-> alpha" "rotation must wrap past the excluded seat rather than onto it"
  assert_contains "$out" "seat personal: skipped, excluded from automatic rotation" \
    "the skipped seat must be reported with the exclusion as its reason"

  # And it comes straight back once the exclusion is lifted.
  run_seat "$HOME_DIR" "$FAKEBIN" auto-include personal >/dev/null
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" switch --next)
  assert_contains "$out" "-> beta" "rotation order must be unchanged once the seat is back"
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" switch --next)
  assert_contains "$out" "-> personal" "an included seat must become a rotation destination again"
  pass "switch --next skips an excluded seat and reaches it again once it is included"
}

test_an_explicit_switch_still_reaches_an_excluded_seat() {
  local rec out
  rec=$(make_seat_case auto-exclude-explicit)
  read_seat_case "$rec"
  mkdir -p "$SEATS_DIR/work" "$SEATS_DIR/personal"
  seat_logged_in "$SPEC_DIR" "$SEATS_DIR/work" "$SEATS_DIR/personal"
  printf 'work\n' > "$HOME_DIR/config/claude-seat"
  run_seat "$HOME_DIR" "$FAKEBIN" auto-exclude personal >/dev/null

  out=$(run_seat "$HOME_DIR" "$FAKEBIN" switch personal)
  expect_code 0 "$?" "an explicit switch to an excluded seat must be allowed"
  assert_contains "$out" "switched: work -> personal" "the explicit switch must take effect"
  assert_grep "personal" "$HOME_DIR/config/claude-seat" "the excluded seat must become active"

  # Still excluded afterwards: being switched to by hand does not re-enter it
  # into rotation, which is the whole point of keeping the two independent.
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" status)
  assert_contains "$out" "active seat for NEW workers: personal" "the manual choice must hold"
  assert_contains "$out" "held out of automatic rotation by hand: personal" \
    "an explicit switch must not put the seat back into automatic rotation"
  pass "an excluded seat stays manually switchable and stays out of automatic rotation"
}

test_excluding_the_active_seat_never_switches_away_from_it() {
  local rec out
  rec=$(make_seat_case auto-exclude-active)
  read_seat_case "$rec"
  mkdir -p "$SEATS_DIR/work" "$SEATS_DIR/spare"
  seat_logged_in "$SPEC_DIR" "$SEATS_DIR/work" "$SEATS_DIR/spare"
  printf 'work\n' > "$HOME_DIR/config/claude-seat"

  out=$(run_seat "$HOME_DIR" "$FAKEBIN" auto-exclude work)
  expect_code 0 "$?" "excluding the active seat must be allowed"
  assert_grep "work" "$HOME_DIR/config/claude-seat" \
    "excluding the active seat must leave it active"
  assert_contains "$out" "stays active" "the report must say the active seat did not move"
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" status)
  assert_contains "$out" "active seat for NEW workers: work" "new workers must keep launching there"
  pass "excluding the active seat withholds it as a future destination and moves nothing"
}

test_excluding_every_candidate_keeps_the_existing_no_destination_refusal() {
  local rec out status
  rec=$(make_seat_case auto-exclude-nowhere)
  read_seat_case "$rec"
  mkdir -p "$SEATS_DIR/work" "$SEATS_DIR/personal"
  seat_logged_in "$SPEC_DIR" '(default)' "$SEATS_DIR/work" "$SEATS_DIR/personal"
  printf 'work\n' > "$HOME_DIR/config/claude-seat"
  run_seat "$HOME_DIR" "$FAKEBIN" auto-exclude personal >/dev/null

  out=$(run_seat "$HOME_DIR" "$FAKEBIN" switch --next)
  status=$?
  expect_code 1 "$status" "rotation with every candidate excluded must refuse"
  assert_contains "$out" "no seat under the seats root qualifies" \
    "the existing no-destination refusal must be the one that fires"
  assert_contains "$out" "seat personal: skipped, excluded from automatic rotation" \
    "the refusal must name the exclusion as the reason"
  assert_not_contains "$out" "-> default" "it must still never fall back to the default profile"
  assert_grep "work" "$HOME_DIR/config/claude-seat" "a refused rotation must change nothing"

  # And arming refuses for the same reason rather than arming a watch with
  # nowhere to go.
  run_seat "$HOME_DIR" "$FAKEBIN" threshold 15 >/dev/null
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" arm)
  status=$?
  expect_code 1 "$status" "arming with every candidate excluded must refuse"
  assert_contains "$out" "nowhere to go" "the arm refusal must name the cause"
  assert_contains "$out" "auto-include" "the arm refusal must point at the way back"
  pass "excluding every candidate falls through to the existing no-destination refusal"
}

test_the_watch_never_switches_onto_an_excluded_seat() {
  local rec out
  rec=$(make_seat_case auto-exclude-watch)
  read_seat_case "$rec"
  mkdir -p "$SEATS_DIR/work" "$SEATS_DIR/personal" "$SEATS_DIR/spare"
  seat_logged_in "$SPEC_DIR" "$SEATS_DIR/work" "$SEATS_DIR/personal" "$SEATS_DIR/spare"
  printf 'work\n' > "$HOME_DIR/config/claude-seat"
  run_seat "$HOME_DIR" "$FAKEBIN" threshold 15 >/dev/null
  run_seat "$HOME_DIR" "$FAKEBIN" auto-exclude personal >/dev/null
  # 'personal' has the most headroom by far, so an automatic pass that ignored
  # the exclusion would land there; 'spare' is the only seat it may take.
  printf '%s\t5\n%s\t100\n%s\t60\n' \
    "$SEATS_DIR/work" "$SEATS_DIR/personal" "$SEATS_DIR/spare" > "$SPEC_DIR/remaining_map"

  out=$(run_seat "$HOME_DIR" "$FAKEBIN" auto)
  assert_contains "$out" "switched from work at 5% left across its account windows to spare" \
    "the armed watch must switch onto the seat that is still in rotation"
  assert_not_contains "$out" "to personal" "the armed watch must never land on an excluded seat"
  assert_grep "spare" "$HOME_DIR/config/claude-seat" "the switch must land on the included seat"
  pass "the armed watch skips an excluded seat even when it has the most headroom"
}

test_the_lead_restart_destination_skips_an_excluded_seat() {
  local rec out status
  rec=$(make_seat_case auto-exclude-lead)
  read_seat_case "$rec"
  mkdir -p "$SEATS_DIR/work" "$SEATS_DIR/personal"
  seat_logged_in "$SPEC_DIR" "$SEATS_DIR/work" "$SEATS_DIR/personal"
  # Firstmate itself is on 'work'. The destination for a lead restart is chosen
  # by the leader-only cross-provider chooser; its exclusion must apply too.
  printf '4242424\n' > "$HOME_DIR/state/.lock"
  { printf 'pid=4242424\n'; printf 'profile=%s\n' "$SEATS_DIR/work"; } > "$HOME_DIR/state/.lock-runtime"

  out=$(run_seat "$HOME_DIR" "$FAKEBIN" status)
  assert_contains "$out" "firstmate itself is running on: work" \
    "precondition: the lead's own seat must be established"

  run_seat "$HOME_DIR" "$FAKEBIN" auto-exclude personal >/dev/null
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" lead-restart --check)
  status=$?
  expect_code 1 "$status" "a lead restart with its only destination excluded must refuse"
  assert_contains "$out" "no seat qualifies as a destination for firstmate itself" \
    "the lead restart must refuse through the ordinary no-destination path"
  assert_contains "$out" "excluded from automatic rotation" \
    "the lead restart must report the exclusion as the reason"
  assert_not_contains "$out" "--to personal" "the lead restart must never choose an excluded seat"
  pass "the lead-restart destination choice skips an excluded seat like every other automatic path"
}

test_add_creates_the_profile_directory_without_touching_credentials() {
  local rec out
  rec=$(make_seat_case add-seat)
  read_seat_case "$rec"

  out=$(run_seat "$HOME_DIR" "$FAKEBIN" add work)
  expect_code 0 "$?" "adding a seat should succeed"
  assert_present "$SEATS_DIR/work" "add must create the seat's profile directory"
  assert_contains "$out" "CLAUDE_CONFIG_DIR=$SEATS_DIR/work claude" \
    "add must print the exact login command the account owner runs"
  assert_contains "$out" "No credential" "add must state that it touched no credential"
  # The directory is empty: nothing was copied into it from any other profile.
  [ -z "$(ls -A "$SEATS_DIR/work")" ] || fail "add must leave the new profile directory empty"
  pass "adding a seat creates an empty profile directory and prints the owner's login steps"
}

test_a_directory_named_default_is_not_offered_as_a_seat() {
  local rec out status
  rec=$(make_seat_case reserved-default)
  read_seat_case "$rec"
  # "default" names the ambient login, so a directory of that name can never be
  # selected. Listing it would offer a seat that every switch then refuses.
  mkdir -p "$SEATS_DIR/default" "$SEATS_DIR/work"
  seat_logged_in "$SPEC_DIR" '(default)' "$SEATS_DIR/work" "$SEATS_DIR/default"

  out=$(run_seat "$HOME_DIR" "$FAKEBIN" list)
  [ "$(printf '%s\n' "$out" | grep -c '[[:space:]]default[[:space:]]')" -eq 1 ] \
    || fail "the reserved default seat must appear exactly once, not also as a directory"$'\n'"$out"
  assert_not_contains "$out" "$SEATS_DIR/default" \
    "a directory named 'default' must not be listed as a seat profile"

  out=$(run_seat "$HOME_DIR" "$FAKEBIN" add default)
  status=$?
  expect_code 1 "$status" "adding a seat named 'default' must be refused"
  assert_contains "$out" "ambient login" "the refusal must say why the name is reserved"

  # Rotation must not offer it either.
  printf 'work\n' > "$HOME_DIR/config/claude-seat"
  run_seat "$HOME_DIR" "$FAKEBIN" switch --next >/dev/null 2>&1
  expect_code 1 "$?" "a directory named 'default' must not become a rotation target"
  pass "a directory named 'default' is never offered, added, or rotated to"
}

test_seat_names_that_escape_the_seats_root_are_refused() {
  local rec name
  rec=$(make_seat_case seat-names)
  read_seat_case "$rec"
  seat_logged_in "$SPEC_DIR" '(default)'

  for name in '../escape' 'a/b' '..' '' '.hidden'; do
    if run_seat "$HOME_DIR" "$FAKEBIN" switch "$name" >/dev/null 2>&1; then
      fail "seat name '$name' must be refused"
    fi
  done
  assert_absent "$HOME_DIR/config/claude-seat" "no invalid name may be recorded as the active seat"
  pass "seat names that are not a single safe path component are refused"
}

# --- spawn integration ------------------------------------------------------
#
# These drive the real bin/fm-spawn.sh with a fake tmux that captures the literal
# launch command, so they assert what firstmate would actually run.

spawn_case() {
  local name=$1 id=$2 case_dir home proj wt fakebin launchlog seats
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  launchlog="$case_dir/launch.log"
  seats="$case_dir/seats"
  mkdir -p "$seats"
  fakebin=$(fm_test_make_spawn_fakebin "$case_dir/fake")
  fm_test_spawn_home "$home" claude
  fm_test_spawn_ship_brief "$home" "$id"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  printf '%s\n' "$seats" > "$home/config/claude-seats-root"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$launchlog|$seats"
}

read_spawn_case() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN LAUNCH_LOG SEATS_DIR <<EOF
$1
EOF
}

run_spawn_here() {
  local home=$1 wt=$2 fakebin=$3 launchlog=$4
  shift 4
  : > "$launchlog"
  CLAUDE_CONFIG_DIR='' FM_FAKE_LAUNCH_LOG="$launchlog" \
    fm_test_run_spawn "$home" "$wt" "$fakebin" "$@" --mode no-mistakes --ticket no-ticket --commit-type chore --yolo off
}

test_spawn_without_a_seat_sets_no_config_dir() {
  local rec id out launch
  id=seat-none-1
  rec=$(spawn_case spawn-no-seat "$id")
  read_spawn_case "$rec"

  out=$(run_spawn_here "$HOME_DIR" "$WT_DIR" "$FAKEBIN" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  expect_code 0 "$?" "a spawn with no seat configured should succeed: $out"
  launch=$(cat "$LAUNCH_LOG")
  assert_not_contains "$launch" "CLAUDE_CONFIG_DIR=" \
    "with no seat configured the launch must carry no config-dir prefix"
  assert_no_grep "claude_seat=" "$HOME_DIR/state/$id.meta" \
    "with no seat configured the task record must not claim a seat"
  pass "an unset seat setting leaves the launch and the task record exactly as before"
}

test_spawn_refuses_a_missing_active_seat_directory() {
  local rec id out rc
  id=seat-missing-dir
  rec=$(spawn_case spawn-missing-seat "$id")
  read_spawn_case "$rec"
  printf 'missing\n' > "$HOME_DIR/config/claude-seat"
  out=$(run_spawn_here "$HOME_DIR" "$WT_DIR" "$FAKEBIN" "$LAUNCH_LOG" "$id" "$PROJ_DIR" 2>&1); rc=$?
  expect_code 1 "$rc" "a missing seat directory must refuse spawn: $out"
  assert_contains "$out" "seat 'missing' has no profile directory at $SEATS_DIR/missing" "refusal must name the seat and directory"
  assert_absent "$SEATS_DIR/missing" "spawn must not create the missing seat"
  assert_absent "$HOME_DIR/state/$id.meta" "refused spawn must not publish a task record"
  assert_no_grep 'claude --dangerously-skip-permissions' "$LAUNCH_LOG" "refused spawn must not launch Claude"
  pass "spawn refuses a missing seat directory without creating it"
}

test_spawn_uses_the_active_seat_and_records_it() {
  local rec id out launch
  id=seat-active-1
  rec=$(spawn_case spawn-active-seat "$id")
  read_spawn_case "$rec"
  mkdir -p "$SEATS_DIR/work"
  printf 'work\n' > "$HOME_DIR/config/claude-seat"

  out=$(run_spawn_here "$HOME_DIR" "$WT_DIR" "$FAKEBIN" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  expect_code 0 "$?" "a spawn on a configured seat should succeed: $out"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "CLAUDE_CONFIG_DIR='$SEATS_DIR/work'" \
    "the launch must point the worker at the active seat's profile"
  assert_grep "claude_seat=$SEATS_DIR/work" "$HOME_DIR/state/$id.meta" \
    "the task record must remember the seat this worker launched on"
  pass "a spawn launches on the active seat and records it in the task's own record"
}

test_switching_seats_does_not_move_a_running_worker() {
  local rec id out before after
  id=seat-running-1
  rec=$(spawn_case spawn-running "$id")
  read_spawn_case "$rec"
  mkdir -p "$SEATS_DIR/work" "$SEATS_DIR/spare"
  printf 'work\n' > "$HOME_DIR/config/claude-seat"

  out=$(run_spawn_here "$HOME_DIR" "$WT_DIR" "$FAKEBIN" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  expect_code 0 "$?" "the first spawn should succeed: $out"
  before=$(sed -n 's/^claude_seat=//p' "$HOME_DIR/state/$id.meta")
  assert_equals "$SEATS_DIR/work" "$before" "precondition: the task launched on the work seat"

  # The switch itself: the running task's record must be untouched by it.
  printf 'spare\n' > "$HOME_DIR/config/claude-seat"
  after=$(sed -n 's/^claude_seat=//p' "$HOME_DIR/state/$id.meta")
  assert_equals "$SEATS_DIR/work" "$after" \
    "a seat switch must not rewrite a running task's recorded seat"
  pass "switching seats leaves a running worker's recorded profile unchanged"
}

test_a_later_spawn_uses_the_new_seat_while_the_old_task_keeps_its_own() {
  local rec id2 out launch case_dir home proj fakebin
  rec=$(spawn_case spawn-two-seats seat-first-1)
  read_spawn_case "$rec"
  mkdir -p "$SEATS_DIR/work" "$SEATS_DIR/spare"
  printf 'work\n' > "$HOME_DIR/config/claude-seat"

  out=$(run_spawn_here "$HOME_DIR" "$WT_DIR" "$FAKEBIN" "$LAUNCH_LOG" seat-first-1 "$PROJ_DIR")
  expect_code 0 "$?" "the first spawn should succeed: $out"

  # Switch, then spawn a second task from a second worktree in the same home.
  printf 'spare\n' > "$HOME_DIR/config/claude-seat"
  id2=seat-second-1
  fm_test_spawn_ship_brief "$HOME_DIR" "$id2"
  git -C "$PROJ_DIR" worktree add --quiet -b wt-two-seats-2 "$CASE_DIR/wt2"
  out=$(run_spawn_here "$HOME_DIR" "$CASE_DIR/wt2" "$FAKEBIN" "$LAUNCH_LOG" "$id2" "$PROJ_DIR")
  expect_code 0 "$?" "the second spawn should succeed: $out"
  launch=$(cat "$LAUNCH_LOG")

  assert_contains "$launch" "CLAUDE_CONFIG_DIR='$SEATS_DIR/spare'" \
    "the new worker must launch on the seat that is active now"
  assert_grep "claude_seat=$SEATS_DIR/spare" "$HOME_DIR/state/$id2.meta" \
    "the new task must record the new seat"
  assert_grep "claude_seat=$SEATS_DIR/work" "$HOME_DIR/state/seat-first-1.meta" \
    "the earlier task must still record the seat it launched on"
  pass "after a switch new workers get the new seat while existing ones keep theirs"
}

test_ambient_config_dir_still_reaches_workers_when_no_seat_is_set() {
  local rec id out launch
  id=seat-ambient-1
  rec=$(spawn_case spawn-ambient "$id")
  read_spawn_case "$rec"
  mkdir -p "$CASE_DIR/ambient-profile"

  # No seat configured, but firstmate itself runs under a non-default profile.
  # That predates seats and must keep working: the worker gets the same store.
  : > "$LAUNCH_LOG"
  out=$(FM_TEST_CLAUDE_CONFIG_DIR="$CASE_DIR/ambient-profile" \
    FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" \
    fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN" "$id" "$PROJ_DIR" --mode no-mistakes --ticket no-ticket --commit-type chore --yolo off 2>&1)
  expect_code 0 "$?" "a spawn under an ambient config dir should succeed: $out"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "CLAUDE_CONFIG_DIR='$CASE_DIR/ambient-profile'" \
    "firstmate's own config dir must still reach the worker when no seat is configured"
  assert_grep "claude_seat=$CASE_DIR/ambient-profile" "$HOME_DIR/state/$id.meta" \
    "the ambient store must be recorded as this task's seat so a relaunch keeps it"
  pass "an ambient CLAUDE_CONFIG_DIR still reaches workers and is recorded per task"
}

test_non_claude_spawn_records_no_seat() {
  local rec id out launch
  id=seat-codex-1
  rec=$(spawn_case spawn-codex-seat "$id")
  read_spawn_case "$rec"
  printf 'codex\n' > "$HOME_DIR/config/crew-harness"
  mkdir -p "$SEATS_DIR/work"
  printf 'work\n' > "$HOME_DIR/config/claude-seat"

  out=$(run_spawn_here "$HOME_DIR" "$WT_DIR" "$FAKEBIN" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  expect_code 0 "$?" "a codex spawn with a named seat active should succeed: $out"
  launch=$(cat "$LAUNCH_LOG")
  assert_not_contains "$launch" "CLAUDE_CONFIG_DIR=" "a non-claude launch must carry no Claude profile"
  assert_no_grep "claude_seat=" "$HOME_DIR/state/$id.meta" \
    "a non-claude task must not record a Claude seat"
  make_quota_fake "$FAKEBIN" "$CASE_DIR/quota-spec"
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" status)
  assert_not_contains "$(printf '%s\n' "$out" | grep "$id")" "$SEATS_DIR/work" \
    "status must not list a non-claude task as running on a seat"
  pass "a non-claude spawn records no Claude seat while a named seat is active"
}

test_active_seat_overrides_the_ambient_config_dir() {
  local rec id out launch
  id=seat-override-1
  rec=$(spawn_case spawn-override "$id")
  read_spawn_case "$rec"
  mkdir -p "$SEATS_DIR/work"
  printf 'work\n' > "$HOME_DIR/config/claude-seat"

  : > "$LAUNCH_LOG"
  out=$(FM_TEST_CLAUDE_CONFIG_DIR="$CASE_DIR/ambient-profile" \
    FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" \
    fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN" "$id" "$PROJ_DIR" --mode no-mistakes --ticket no-ticket --commit-type chore --yolo off 2>&1)
  expect_code 0 "$?" "a spawn with both a seat and an ambient dir should succeed: $out"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "CLAUDE_CONFIG_DIR='$SEATS_DIR/work'" \
    "the configured seat must win over firstmate's ambient config dir"
  assert_not_contains "$launch" "$CASE_DIR/ambient-profile" \
    "the ambient config dir must not also appear in the launch"
  pass "a configured seat takes precedence over firstmate's own ambient config dir"
}

test_a_restarted_lead_spawns_the_default_seat_on_its_original_ambient() {
  local rec id out launch
  id=seat-restarted-lead-1
  rec=$(spawn_case spawn-restarted-lead "$id")
  read_spawn_case "$rec"
  mkdir -p "$SEATS_DIR/beta" "$CASE_DIR/ambient-profile"

  # A lead moved to beta by bin/fm-lead-restart.sh runs with beta as its own
  # CLAUDE_CONFIG_DIR and carries the ambient it started from.
  : > "$LAUNCH_LOG"
  out=$(FM_TEST_CLAUDE_CONFIG_DIR="$SEATS_DIR/beta" \
    FM_AMBIENT_CLAUDE_CONFIG_DIR="$CASE_DIR/ambient-profile" \
    FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" \
    fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN" "$id" "$PROJ_DIR" --mode no-mistakes --ticket no-ticket --commit-type chore --yolo off 2>&1)
  expect_code 0 "$?" "a default-seat spawn from a restarted lead should succeed: $out"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "CLAUDE_CONFIG_DIR='$CASE_DIR/ambient-profile'" \
    "a default-seat worker must launch on the lead's original ambient profile"
  assert_not_contains "$launch" "$SEATS_DIR/beta" \
    "a default-seat worker must not follow the lead onto the seat it was restarted on"
  pass "after a lead restart, default-seat spawns stay on the original ambient profile"
}

# Two mechanisms select a Claude worker's configuration directory: this home's
# seat and the worker account pin (config/claude-account). Composed, the pin's
# `env` launch consumes the seat's assignment and silently wins, while trust is
# pre-registered in the seat's profile - so the worker meets a trust dialog it
# cannot answer. A home configuring both is a configuration conflict, refused
# before any endpoint, local copy, or task record exists.
test_account_pin_and_active_seat_refuse_the_spawn() {
  local rec id out
  id=seat-account-conflict-1
  rec=$(spawn_case spawn-account-conflict "$id")
  read_spawn_case "$rec"
  mkdir -p "$SEATS_DIR/work"
  printf 'work\n' > "$HOME_DIR/config/claude-seat"
  printf 'ordinary\n' > "$HOME_DIR/config/claude-account"

  out=$(run_spawn_here "$HOME_DIR" "$WT_DIR" "$FAKEBIN" "$LAUNCH_LOG" "$id" "$PROJ_DIR" 2>&1)
  expect_code 1 "$?" "configuring both an account pin and an active seat must refuse the spawn: $out"
  assert_contains "$out" "$HOME_DIR/config/claude-account" \
    "the refusal must name the account pin file by path"
  assert_contains "$out" "$HOME_DIR/config/claude-seat" \
    "the refusal must name the seat file by path"
  assert_contains "$out" "remove either file" \
    "the refusal must say that removing either file resolves the conflict"
  assert_absent "$HOME_DIR/state/$id.meta" "a refused spawn must leave no task record"
  [ ! -s "$LAUNCH_LOG" ] || fail "a refused spawn must launch no worker endpoint"
  pass "a home configuring both an account pin and an active seat is refused before anything exists"
}

test_account_pin_and_active_seat_do_not_refuse_another_harness() {
  local rec id out
  id=seat-account-codex-1
  rec=$(spawn_case spawn-account-codex "$id")
  read_spawn_case "$rec"
  printf 'codex\n' > "$HOME_DIR/config/crew-harness"
  mkdir -p "$SEATS_DIR/work"
  printf 'work\n' > "$HOME_DIR/config/claude-seat"
  printf 'ordinary\n' > "$HOME_DIR/config/claude-account"

  out=$(run_spawn_here "$HOME_DIR" "$WT_DIR" "$FAKEBIN" "$LAUNCH_LOG" "$id" "$PROJ_DIR" 2>&1)
  expect_code 0 "$?" "a codex spawn reads no Claude profile, so the pin and seat conflict must not refuse it: $out"
  assert_not_contains "$out" "remove either file" "a non-claude spawn must not report the Claude profile conflict"
  pass "the account pin and seat conflict refuses only a claude spawn"
}

# make_dead_endpoint_tmux <fakebin> <window>
# Wraps the spawn fake tmux so <window> exists and its pane runs a bare shell:
# the positively agent-free endpoint a relaunch requires before it may launch.
make_dead_endpoint_tmux() {
  local fakebin=$1 window=$2
  mv "$fakebin/tmux" "$fakebin/tmux-spawn"
  cat > "$fakebin/tmux" <<SH
#!/usr/bin/env bash
case "\$*" in
  list-windows*) printf '%s\\n' '$window'; exit 0 ;;
  *'#{pane_tty}'*) exit 1 ;;
  *'#{pane_current_command}'*) printf 'zsh\\n'; exit 0 ;;
esac
exec "$fakebin/tmux-spawn" "\$@"
SH
  chmod +x "$fakebin/tmux"
}

test_pin_only_home_still_relaunches_a_claude_task() {
  local rec id out pin
  id=seat-pin-only-relaunch-1
  rec=$(spawn_case spawn-pin-only-relaunch "$id")
  read_spawn_case "$rec"
  fm_fake_exit0 "$FAKEBIN" claude
  pin="$CASE_DIR/pin-root"
  mkdir -p "$pin"
  printf '%s\n' "$pin" > "$HOME_DIR/config/claude-account"
  out=$(run_spawn_here "$HOME_DIR" "$WT_DIR" "$FAKEBIN" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  expect_code 0 "$?" "a spawn under a named-root pin with no seat should succeed: $out"
  make_dead_endpoint_tmux "$FAKEBIN" "fm-$id"
  : > "$LAUNCH_LOG"

  out=$(CLAUDE_CONFIG_DIR='' FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" \
    fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN" "$id" --relaunch)
  expect_code 0 "$?" "a pin-only home must still relaunch its claude task: $out"
  assert_contains "$(cat "$LAUNCH_LOG")" "CLAUDE_CONFIG_DIR='$pin'" \
    "the relaunched worker must launch under the pinned root"
  pass "a pin-only home with no seat file still relaunches a claude task under its pin"
}

test_pin_at_a_seat_directory_still_relaunches_a_claude_task() {
  local rec id out
  id=seat-pin-at-seat-relaunch-1
  rec=$(spawn_case spawn-pin-at-seat-relaunch "$id")
  read_spawn_case "$rec"
  fm_fake_exit0 "$FAKEBIN" claude
  mkdir -p "$SEATS_DIR/work"
  printf '%s\n' "$SEATS_DIR/work" > "$HOME_DIR/config/claude-account"
  out=$(run_spawn_here "$HOME_DIR" "$WT_DIR" "$FAKEBIN" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  expect_code 0 "$?" "a spawn under a pin at a seat directory should succeed: $out"
  assert_grep "claude_seat=$SEATS_DIR/work" "$HOME_DIR/state/$id.meta" \
    "the task record must carry the pinned seat directory it launched on"
  make_dead_endpoint_tmux "$FAKEBIN" "fm-$id"
  : > "$LAUNCH_LOG"

  out=$(CLAUDE_CONFIG_DIR='' FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" \
    fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN" "$id" --relaunch)
  expect_code 0 "$?" "a pin at the task's own seat directory must still relaunch it: $out"
  assert_contains "$(cat "$LAUNCH_LOG")" "CLAUDE_CONFIG_DIR='$SEATS_DIR/work'" \
    "the relaunched worker must launch on the pinned seat directory"
  pass "a pin pointing at a seat directory still relaunches a task recorded on that directory"
}

# --- automatic mode ----------------------------------------------------------
# The three controls are the trigger (the ACTIVE seat's percent left), the
# destination minimum (the percent left a DESTINATION must exceed), and the
# extra-usage policy (what happens when neither can be satisfied). Every one is
# off when absent, which the first case below pins.

# seat_remaining <spec> <profile> <percent>
# Give one profile its own percent remaining.
seat_remaining() {
  printf '%s\t%s\n' "$2" "$3" >> "$1/remaining_map"
}

# seat_quota_unreadable <spec> <profile...>
# Declare profiles that are logged in but whose account-level quota cannot be
# read, so a case can prove an ambiguous read is skipped rather than guessed at.
seat_quota_unreadable() {
  local spec=$1
  shift
  printf '%s\n' "$@" > "$spec/unreadable_quota"
}

# seat_extra_spend <spec> <profile> <usd>
# Give one profile an extra_usage window carrying that much paid spend.
seat_extra_spend() {
  printf '%s\t%s\n' "$2" "$3" >> "$1/extra_map"
}

test_an_unconfigured_home_rotates_on_login_alone_and_holds_nothing() {
  local rec out
  rec=$(make_seat_case auto-off-by-default)
  read_seat_case "$rec"
  mkdir -p "$SEATS_DIR/work" "$SEATS_DIR/spare"
  seat_logged_in "$SPEC_DIR" '(default)' "$SEATS_DIR/work" "$SEATS_DIR/spare"
  printf 'work\n' > "$HOME_DIR/config/claude-seat"
  # The candidate reads as nearly empty but not empty. With no destination
  # minimum set, no headroom level is asked of it and it is a destination
  # exactly as it was before these settings existed; only a seat with nothing
  # left at all is refused, and that refusal needs no setting.
  seat_remaining "$SPEC_DIR" "$SEATS_DIR/spare" 1

  out=$(run_seat "$HOME_DIR" "$FAKEBIN" switch --next)
  expect_code 0 "$?" "with no destination minimum, a seat that still has quota must be a destination"
  assert_contains "$out" "-> spare" "an unconfigured home must rotate on login alone"

  out=$(run_seat "$HOME_DIR" "$FAKEBIN" status)
  assert_contains "$out" "new Claude dispatch: allowed" "with no extra-usage policy, dispatch must never be held"
  assert_contains "$out" "no extra-usage policy is configured" \
    "the gate must say it read nothing rather than implying a quota verdict"
  assert_absent "$HOME_DIR/config/claude-seat-destination-min" \
    "reading the gate must not create a destination minimum"
  assert_absent "$HOME_DIR/config/claude-seat-extra-usage" \
    "reading the gate must not create an extra-usage policy"
  pass "a home that configures none of the automatic settings still rotates on login alone and holds nothing"
}

test_dispatch_gate_needs_no_quota_reader_when_unconfigured() {
  local rec out bare
  rec=$(make_seat_case auto-off-no-reader)
  read_seat_case "$rec"
  # A fakebin with NO quota-axi at all. An unconfigured home must still allow
  # dispatch, which proves the gate reads nothing rather than failing open on a
  # read it attempted and could not make.
  bare=$(fm_fakebin "$CASE_DIR/bare")
  out=$(run_seat "$HOME_DIR" "$bare" status)
  assert_contains "$out" "new Claude dispatch: allowed" \
    "an unconfigured gate must allow dispatch with no quota reader present at all"
  assert_contains "$out" "no extra-usage policy" "the allow must name the unset policy as its reason"
  pass "the dispatch gate reads no quota at all until an extra-usage policy is configured"
}

test_destination_minimum_is_configurable_validated_and_clearable() {
  local rec out
  rec=$(make_seat_case dest-min-config)
  read_seat_case "$rec"
  seat_logged_in "$SPEC_DIR" '(default)'

  out=$(run_seat "$HOME_DIR" "$FAKEBIN" destination-min)
  assert_contains "$out" "(unset" "an unconfigured destination minimum must report as unset"

  out=$(run_seat "$HOME_DIR" "$FAKEBIN" destination-min 30)
  expect_code 0 "$?" "setting a destination minimum should succeed"
  assert_contains "$out" "30% left" "the setter must echo the value in percent LEFT"
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" destination-min)
  assert_contains "$out" "30" "the destination minimum must read back"

  out=$(run_seat "$HOME_DIR" "$FAKEBIN" destination-min 101)
  expect_code 1 "$?" "an out-of-range destination minimum must be refused"
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" destination-min)
  assert_contains "$out" "30" "a refused value must leave the configured one intact"

  out=$(run_seat "$HOME_DIR" "$FAKEBIN" destination-min off)
  expect_code 0 "$?" "clearing the destination minimum should succeed"
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" destination-min)
  assert_contains "$out" "(unset" "a cleared destination minimum must report as unset"
  pass "the destination minimum is settable by command, validated, clearable, and unset by default"
}

test_a_switch_skips_a_seat_below_the_destination_minimum() {
  local rec out
  rec=$(make_seat_case dest-min-skip)
  read_seat_case "$rec"
  # Named so the LEAN seat comes first in rotation order and the roomy one
  # second: a gate that only ever looked at the first candidate would pass a
  # test where the roomy seat happened to be reached first.
  mkdir -p "$SEATS_DIR/alpha" "$SEATS_DIR/beta-lean" "$SEATS_DIR/zulu-roomy"
  seat_logged_in "$SPEC_DIR" "$SEATS_DIR/alpha" "$SEATS_DIR/beta-lean" "$SEATS_DIR/zulu-roomy"
  printf 'alpha\n' > "$HOME_DIR/config/claude-seat"
  seat_remaining "$SPEC_DIR" "$SEATS_DIR/alpha" 5
  seat_remaining "$SPEC_DIR" "$SEATS_DIR/beta-lean" 12
  seat_remaining "$SPEC_DIR" "$SEATS_DIR/zulu-roomy" 70
  run_seat "$HOME_DIR" "$FAKEBIN" destination-min 25 >/dev/null

  out=$(run_seat "$HOME_DIR" "$FAKEBIN" switch --next)
  expect_code 0 "$?" "a rotation with one qualifying seat must succeed: $out"
  assert_contains "$out" "-> zulu-roomy" "rotation must land on the seat with headroom, not the next one in list order"
  assert_contains "$out" "seat beta-lean: skipped, 12% left across its account windows is not above the 25% destination minimum" \
    "the skipped seat and its measured headroom must be reported"
  assert_grep "zulu-roomy" "$HOME_DIR/config/claude-seat" "the qualifying seat must be recorded"
  pass "a switch skips a logged-in seat below the destination minimum and lands on one above it"
}

test_no_switch_happens_when_no_seat_clears_the_destination_minimum() {
  local rec out
  rec=$(make_seat_case dest-min-none)
  read_seat_case "$rec"
  mkdir -p "$SEATS_DIR/alpha" "$SEATS_DIR/beta-lean"
  seat_logged_in "$SPEC_DIR" "$SEATS_DIR/alpha" "$SEATS_DIR/beta-lean"
  printf 'alpha\n' > "$HOME_DIR/config/claude-seat"
  seat_remaining "$SPEC_DIR" "$SEATS_DIR/alpha" 5
  seat_remaining "$SPEC_DIR" "$SEATS_DIR/beta-lean" 12
  run_seat "$HOME_DIR" "$FAKEBIN" destination-min 25 >/dev/null

  out=$(run_seat "$HOME_DIR" "$FAKEBIN" switch --next)
  expect_code 1 "$?" "a rotation with no qualifying seat must refuse rather than switch"
  assert_contains "$out" "no seat under the seats root qualifies" "the refusal must name the cause"
  assert_contains "$out" "seat beta-lean: skipped, 12% left" "the refusal must say which seat was rejected and why"
  assert_grep "alpha" "$HOME_DIR/config/claude-seat" "a refused rotation must leave the active seat in place"
  pass "no switch happens when every candidate is below the destination minimum"
}

test_an_unreadable_candidate_quota_is_skipped_and_never_guessed() {
  local rec out
  rec=$(make_seat_case dest-min-unreadable)
  read_seat_case "$rec"
  mkdir -p "$SEATS_DIR/alpha" "$SEATS_DIR/murky"
  seat_logged_in "$SPEC_DIR" "$SEATS_DIR/alpha" "$SEATS_DIR/murky"
  printf 'alpha\n' > "$HOME_DIR/config/claude-seat"
  # murky is logged in, so the login gate alone would accept it. Its quota gives
  # no verdict, which is not evidence of headroom in either direction.
  seat_quota_unreadable "$SPEC_DIR" "$SEATS_DIR/murky"
  run_seat "$HOME_DIR" "$FAKEBIN" destination-min 25 >/dev/null

  out=$(run_seat "$HOME_DIR" "$FAKEBIN" switch --next)
  expect_code 1 "$?" "an ambiguous candidate quota must never be treated as headroom"
  assert_contains "$out" "seat murky: skipped, its quota could not be read" \
    "the skip must say the quota gave no verdict rather than implying a number"
  assert_contains "$out" "makes no guess" "the refusal must state that nothing was guessed"
  assert_grep "alpha" "$HOME_DIR/config/claude-seat" "nothing may be switched on an unreadable quota"
  pass "a candidate whose quota gives no verdict is skipped, never guessed at as headroom"
}

test_extra_usage_policy_is_configurable_validated_and_clearable() {
  local rec out
  rec=$(make_seat_case extra-usage-config)
  read_seat_case "$rec"
  seat_logged_in "$SPEC_DIR" '(default)'

  out=$(run_seat "$HOME_DIR" "$FAKEBIN" extra-usage)
  assert_contains "$out" "(unset" "an unconfigured extra-usage policy must report as unset"

  out=$(run_seat "$HOME_DIR" "$FAKEBIN" extra-usage stop)
  expect_code 0 "$?" "setting the stop policy should succeed"
  assert_contains "$out" "not a guarantee of zero spend" \
    "setting stop must state plainly that a running worker is not stopped"
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" extra-usage)
  assert_contains "$out" "stop" "the stop policy must read back"

  out=$(run_seat "$HOME_DIR" "$FAKEBIN" extra-usage allow 25)
  expect_code 0 "$?" "setting a dollar cap should succeed"
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" extra-usage)
  assert_contains "$out" "25" "the cap must read back"

  out=$(run_seat "$HOME_DIR" "$FAKEBIN" extra-usage allow)
  expect_code 1 "$?" "allow with no dollar cap must be refused"
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" extra-usage banana)
  expect_code 1 "$?" "an unknown policy word must be refused"
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" extra-usage)
  assert_contains "$out" "25" "a refused policy must leave the configured one intact"

  out=$(run_seat "$HOME_DIR" "$FAKEBIN" extra-usage off)
  expect_code 0 "$?" "clearing the policy should succeed"
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" extra-usage)
  assert_contains "$out" "(unset" "a cleared policy must report as unset"
  pass "the extra-usage policy is settable by command, validated, clearable, and unset by default"
}

test_stop_policy_holds_dispatch_only_once_the_plan_quota_is_gone() {
  local rec out
  rec=$(make_seat_case extra-usage-stop)
  read_seat_case "$rec"
  mkdir -p "$SEATS_DIR/alpha"
  seat_logged_in "$SPEC_DIR" "$SEATS_DIR/alpha"
  printf 'alpha\n' > "$HOME_DIR/config/claude-seat"
  run_seat "$HOME_DIR" "$FAKEBIN" extra-usage stop >/dev/null

  # Plan quota still left: the gate exists to guard paid overflow, not to
  # ration the plan, so this must allow.
  seat_remaining "$SPEC_DIR" "$SEATS_DIR/alpha" 8
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" status)
  assert_contains "$out" "new Claude dispatch: allowed" \
    "plan quota still remaining must never be held by the extra-usage policy"
  assert_contains "$out" "8% of its plan quota left" "the allow must name the remaining plan quota"

  # Plan quota gone: any further work runs on paid extra usage.
  printf '%s\t0\n' "$SEATS_DIR/alpha" > "$SPEC_DIR/remaining_map"
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" status)
  assert_contains "$out" "new Claude dispatch: HELD" \
    "with the plan quota gone and the policy set to stop, dispatch must be held"
  assert_contains "$out" "no new Claude worker is started on paid extra usage" \
    "the hold must say what it is preventing"
  assert_contains "$out" "a worker already running keeps its own seat" \
    "the hold must state plainly that a running worker is not stopped"
  pass "the stop policy holds new dispatch only once the active seat's plan quota is gone"
}

test_allow_policy_proceeds_under_the_cap_and_holds_at_it() {
  local rec out
  rec=$(make_seat_case extra-usage-cap)
  read_seat_case "$rec"
  mkdir -p "$SEATS_DIR/alpha"
  seat_logged_in "$SPEC_DIR" "$SEATS_DIR/alpha"
  printf 'alpha\n' > "$HOME_DIR/config/claude-seat"
  seat_remaining "$SPEC_DIR" "$SEATS_DIR/alpha" 0
  run_seat "$HOME_DIR" "$FAKEBIN" extra-usage allow 25 >/dev/null

  seat_extra_spend "$SPEC_DIR" "$SEATS_DIR/alpha" 10
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" status)
  assert_contains "$out" "new Claude dispatch: allowed" "spend below the cap must keep dispatching: $out"
  # shellcheck disable=SC2016  # literal dollar signs in the expected output, not expansions
  assert_contains "$out" '$10 of extra usage spent on the active Claude seat, under the $25 cap' \
    "the allow must name the spend and the cap it was compared against"

  printf '%s\t25\n' "$SEATS_DIR/alpha" > "$SPEC_DIR/extra_map"
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" status)
  assert_contains "$out" "new Claude dispatch: HELD" \
    "spend at the cap must hold, so the cap is a ceiling and not a target to pass"
  # shellcheck disable=SC2016  # literal dollar signs in the expected output, not expansions
  assert_contains "$out" 'at or over the $25 cap' "the hold must name the cap it reached"
  pass "the allow policy dispatches under its dollar cap and holds once the spend reaches it"
}

test_an_unreadable_quota_holds_dispatch_rather_than_guessing() {
  local rec out
  rec=$(make_seat_case extra-usage-unreadable)
  read_seat_case "$rec"
  mkdir -p "$SEATS_DIR/alpha"
  seat_logged_in "$SPEC_DIR" "$SEATS_DIR/alpha"
  printf 'alpha\n' > "$HOME_DIR/config/claude-seat"
  seat_quota_unreadable "$SPEC_DIR" "$SEATS_DIR/alpha"
  run_seat "$HOME_DIR" "$FAKEBIN" extra-usage stop >/dev/null

  out=$(run_seat "$HOME_DIR" "$FAKEBIN" status)
  assert_contains "$out" "new Claude dispatch: HELD" \
    "a quota that gives no verdict must hold rather than dispatch on a guess"
  assert_contains "$out" "makes no guess" "the hold must say it refused to guess"

  # Once the plan quota can be read again the hold lifts on its own, so this is
  # a condition that clears rather than a state an operator must reset.
  rm -f "$SPEC_DIR/unreadable_quota"
  seat_remaining "$SPEC_DIR" "$SEATS_DIR/alpha" 40
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" status)
  assert_contains "$out" "new Claude dispatch: allowed" \
    "a readable quota with plan headroom must lift the hold with no operator action"
  pass "an unreadable quota holds dispatch instead of guessing, and the hold lifts once it reads again"
}

test_a_lapsed_seat_is_not_held_for_its_unreadable_quota() {
  local rec out
  rec=$(make_seat_case extra-usage-lapsed)
  read_seat_case "$rec"
  mkdir -p "$SEATS_DIR/alpha"
  seat_expired_refreshable "$SPEC_DIR" "$SEATS_DIR/alpha"
  printf 'alpha\n' > "$HOME_DIR/config/claude-seat"
  run_seat "$HOME_DIR" "$FAKEBIN" extra-usage stop >/dev/null

  out=$(run_seat "$HOME_DIR" "$FAKEBIN" status)
  assert_contains "$out" "new Claude dispatch: allowed" \
    "a lapsed token reads no quota until a launch renews it, so holding on it would hold every spawn: $out"
  assert_contains "$out" "access token has lapsed" "the allow must name the lapsed token"
  pass "a lapsed but renewable seat is not held by the extra-usage policy for its unreadable quota"
}

test_the_watch_keeps_firing_across_crossings_and_never_twice_on_one() {
  local rec out
  rec=$(make_seat_case auto-repeats)
  read_seat_case "$rec"
  mkdir -p "$SEATS_DIR/alpha" "$SEATS_DIR/beta" "$SEATS_DIR/gamma"
  seat_logged_in "$SPEC_DIR" "$SEATS_DIR/alpha" "$SEATS_DIR/beta" "$SEATS_DIR/gamma"
  printf 'alpha\n' > "$HOME_DIR/config/claude-seat"
  run_seat "$HOME_DIR" "$FAKEBIN" threshold 15 >/dev/null
  run_seat "$HOME_DIR" "$FAKEBIN" destination-min 25 >/dev/null

  # Above the trigger: silent, and nothing moves.
  seat_remaining "$SPEC_DIR" "$SEATS_DIR/alpha" 60
  seat_remaining "$SPEC_DIR" "$SEATS_DIR/beta" 80
  seat_remaining "$SPEC_DIR" "$SEATS_DIR/gamma" 90
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" auto)
  [ -z "$out" ] || fail "a seat above its trigger must produce no wake: $out"
  assert_grep "alpha" "$HOME_DIR/config/claude-seat" "nothing may move above the trigger"

  # First crossing: switches, and says so once.
  printf '%s\t10\n%s\t80\n%s\t90\n' \
    "$SEATS_DIR/alpha" "$SEATS_DIR/beta" "$SEATS_DIR/gamma" > "$SPEC_DIR/remaining_map"
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" auto)
  assert_contains "$out" "switched from alpha at 10% left across its account windows to beta" "the first crossing must switch and report it"
  assert_grep "beta" "$HOME_DIR/config/claude-seat" "the first crossing must record the new seat"

  # The same seat sitting below its trigger is one crossing, not many: the next
  # poll must be silent even though the condition is still true.
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" auto)
  [ -z "$out" ] || fail "a crossing already acted on must not fire again on the next poll: $out"

  # The seat it moved TO now crosses. This is the property a fire-once watch
  # loses: it must fire again with nothing re-armed by hand.
  printf '%s\t10\n%s\t9\n%s\t90\n' \
    "$SEATS_DIR/alpha" "$SEATS_DIR/beta" "$SEATS_DIR/gamma" > "$SPEC_DIR/remaining_map"
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" auto)
  assert_contains "$out" "switched from beta at 9% left across its account windows to gamma" \
    "the watch must keep watching and fire on the next seat's own crossing"
  assert_grep "gamma" "$HOME_DIR/config/claude-seat" "the second crossing must record the third seat"
  pass "the watch keeps running after a switch, fires once per crossing, and catches the next seat's own"
}

test_the_watch_reports_the_policy_consequence_when_no_seat_qualifies() {
  local rec out
  rec=$(make_seat_case auto-no-destination)
  read_seat_case "$rec"
  mkdir -p "$SEATS_DIR/alpha" "$SEATS_DIR/beta"
  seat_logged_in "$SPEC_DIR" "$SEATS_DIR/alpha" "$SEATS_DIR/beta"
  printf 'alpha\n' > "$HOME_DIR/config/claude-seat"
  run_seat "$HOME_DIR" "$FAKEBIN" threshold 15 >/dev/null
  run_seat "$HOME_DIR" "$FAKEBIN" destination-min 25 >/dev/null
  run_seat "$HOME_DIR" "$FAKEBIN" extra-usage stop >/dev/null
  seat_remaining "$SPEC_DIR" "$SEATS_DIR/alpha" 10
  seat_remaining "$SPEC_DIR" "$SEATS_DIR/beta" 11

  out=$(run_seat "$HOME_DIR" "$FAKEBIN" auto)
  assert_contains "$out" "no seat has enough headroom" "the wake must say why no switch happened"
  assert_contains "$out" "will be held once this seat's plan quota runs out" \
    "the wake must name the policy consequence, not just the failed switch"
  assert_contains "$out" "A worker already running is not stopped" \
    "the wake must state the limit plainly"
  assert_grep "alpha" "$HOME_DIR/config/claude-seat" "no seat qualifying must leave the active seat alone"

  # One crossing, one wake: the same unqualified state must not wake again.
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" auto)
  [ -z "$out" ] || fail "an unchanged unqualified crossing must not wake again: $out"
  pass "with no seat qualifying the watch reports the policy consequence once and switches nothing"
}

test_the_watch_and_status_agree_while_plan_quota_remains() {
  local rec wake st
  rec=$(make_seat_case auto-agrees-with-status)
  read_seat_case "$rec"
  mkdir -p "$SEATS_DIR/alpha" "$SEATS_DIR/beta"
  seat_logged_in "$SPEC_DIR" "$SEATS_DIR/alpha" "$SEATS_DIR/beta"
  printf 'alpha\n' > "$HOME_DIR/config/claude-seat"
  run_seat "$HOME_DIR" "$FAKEBIN" threshold 15 >/dev/null
  run_seat "$HOME_DIR" "$FAKEBIN" destination-min 30 >/dev/null
  run_seat "$HOME_DIR" "$FAKEBIN" extra-usage stop >/dev/null
  seat_remaining "$SPEC_DIR" "$SEATS_DIR/alpha" 11
  seat_remaining "$SPEC_DIR" "$SEATS_DIR/beta" 20

  wake=$(run_seat "$HOME_DIR" "$FAKEBIN" auto)
  st=$(run_seat "$HOME_DIR" "$FAKEBIN" status)
  assert_contains "$wake" "no seat has enough headroom" "precondition: the crossing must find nowhere to go"
  assert_contains "$st" "new Claude dispatch: allowed" \
    "precondition: with plan quota still left, status must report dispatch allowed: $st"
  case "$wake" in
    *"is held"*|*"held rather"*) fail "the wake claims work is already held while status says dispatch is allowed: $wake" ;;
  esac
  assert_contains "$wake" "once this seat's plan quota runs out" \
    "the wake must say when the hold will begin"
  assert_contains "$wake" "A worker already running is not stopped" "the wake must still state the limit"
  pass "the watch's wake line and status agree while the seat still has plan quota"
}

test_the_watch_switches_once_a_candidate_recovers_after_a_crossing_with_nowhere_to_go() {
  local rec out
  rec=$(make_seat_case auto-recovers)
  read_seat_case "$rec"
  mkdir -p "$SEATS_DIR/alpha" "$SEATS_DIR/beta"
  seat_logged_in "$SPEC_DIR" "$SEATS_DIR/alpha" "$SEATS_DIR/beta"
  printf 'alpha\n' > "$HOME_DIR/config/claude-seat"
  run_seat "$HOME_DIR" "$FAKEBIN" threshold 15 >/dev/null
  run_seat "$HOME_DIR" "$FAKEBIN" destination-min 30 >/dev/null
  run_seat "$HOME_DIR" "$FAKEBIN" extra-usage stop >/dev/null
  printf '%s\t5\n%s\t20\n' "$SEATS_DIR/alpha" "$SEATS_DIR/beta" > "$SPEC_DIR/remaining_map"

  out=$(run_seat "$HOME_DIR" "$FAKEBIN" auto)
  assert_contains "$out" "no seat has enough headroom" "precondition: the crossing must find nowhere to go"

  # beta's window resets while alpha is still below its trigger. The watch must
  # look again rather than stay silent until alpha itself recovers.
  printf '%s\t5\n%s\t100\n' "$SEATS_DIR/alpha" "$SEATS_DIR/beta" > "$SPEC_DIR/remaining_map"
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" auto)
  assert_contains "$out" "switched from alpha at 5% left across its account windows to beta" \
    "a candidate that recovers after a crossing with nowhere to go must be switched to"
  assert_grep "beta" "$HOME_DIR/config/claude-seat" "the recovered candidate must become the active seat"

  out=$(run_seat "$HOME_DIR" "$FAKEBIN" auto)
  [ -z "$out" ] || fail "a completed switch must not wake again on the next poll: $out"
  pass "after a crossing with nowhere to go, the watch keeps looking and switches once a seat recovers"
}

test_the_watch_keeps_every_quota_read_inside_the_check_budget() {
  local rec out started elapsed
  rec=$(make_seat_case auto-slow-reads)
  read_seat_case "$rec"
  mkdir -p "$SEATS_DIR/alpha" "$SEATS_DIR/beta"
  seat_logged_in "$SPEC_DIR" "$SEATS_DIR/alpha" "$SEATS_DIR/beta"
  printf 'alpha\n' > "$HOME_DIR/config/claude-seat"
  run_seat "$HOME_DIR" "$FAKEBIN" threshold 15 >/dev/null
  run_seat "$HOME_DIR" "$FAKEBIN" extra-usage stop >/dev/null
  printf '%s\t5\n%s\t90\n' "$SEATS_DIR/alpha" "$SEATS_DIR/beta" > "$SPEC_DIR/remaining_map"
  printf 'task=t1\nharness=claude\nclaude_seat=%s\n' "$SEATS_DIR/alpha" > "$HOME_DIR/state/t1.meta"
  printf '30\n' > "$SPEC_DIR/slow"

  started=$(date +%s)
  out=$(FM_CHECK_TIMEOUT=8 run_seat "$HOME_DIR" "$FAKEBIN" auto)
  elapsed=$(($(date +%s) - started))
  [ "$elapsed" -lt 8 ] || fail "a pass with slow quota reads must finish inside FM_CHECK_TIMEOUT, took ${elapsed}s"
  [ -z "$out" ] || fail "a read cut short must give no verdict and no wake: $out"
  assert_grep "alpha" "$HOME_DIR/config/claude-seat" "a read cut short must never switch accounts"
  pass "every quota read one automatic pass makes stays inside the watcher's per-check budget"
}

test_the_watch_never_switches_on_an_unreadable_active_quota() {
  local rec out
  rec=$(make_seat_case auto-unreadable)
  read_seat_case "$rec"
  mkdir -p "$SEATS_DIR/alpha" "$SEATS_DIR/beta"
  seat_logged_in "$SPEC_DIR" "$SEATS_DIR/alpha" "$SEATS_DIR/beta"
  printf 'alpha\n' > "$HOME_DIR/config/claude-seat"
  run_seat "$HOME_DIR" "$FAKEBIN" threshold 15 >/dev/null
  seat_quota_unreadable "$SPEC_DIR" "$SEATS_DIR/alpha"

  out=$(run_seat "$HOME_DIR" "$FAKEBIN" auto)
  [ -z "$out" ] || fail "an unreadable active quota must not wake firstmate on every poll: $out"
  assert_grep "alpha" "$HOME_DIR/config/claude-seat" "an unreadable active quota must never switch accounts"
  pass "the watch switches nothing when the active seat's quota gives no verdict"
}

test_arm_registers_a_repeating_watch_and_retire_removes_it() {
  local rec out shim
  rec=$(make_seat_case auto-arm)
  read_seat_case "$rec"
  mkdir -p "$SEATS_DIR/alpha" "$SEATS_DIR/beta"
  seat_logged_in "$SPEC_DIR" "$SEATS_DIR/alpha" "$SEATS_DIR/beta"
  printf 'alpha\n' > "$HOME_DIR/config/claude-seat"
  shim="$HOME_DIR/state/claude-seat.check.sh"

  out=$(run_seat "$HOME_DIR" "$FAKEBIN" arm)
  expect_code 1 "$?" "arming with no trigger configured must refuse"
  assert_contains "$out" "no auto-switch threshold or quota floor configured" "the refusal must name the missing settings"
  assert_absent "$shim" "a refused arm must register nothing"

  run_seat "$HOME_DIR" "$FAKEBIN" threshold 15 >/dev/null
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" arm)
  expect_code 0 "$?" "arming with a trigger and a destination should succeed: $out"
  assert_contains "$out" "keeps watching after each switch" \
    "arming must say the watch is repeating rather than one-shot"
  [ -f "$shim" ] || fail "arm must write the check shim"
  [ -f "$HOME_DIR/state/claude-seat.check-trust" ] || fail "arm must bind the shim's bytes"
  assert_grep "auto" "$shim" "the shim must dispatch the automatic pass"

  out=$(run_seat "$HOME_DIR" "$FAKEBIN" status)
  assert_contains "$out" "auto-switch watch: armed" "status must report the armed watch"

  out=$(run_seat "$HOME_DIR" "$FAKEBIN" retire)
  expect_code 0 "$?" "retiring should succeed"
  assert_absent "$shim" "retire must remove the shim"
  assert_absent "$HOME_DIR/state/claude-seat.check-trust" "retire must remove the trust binding"
  assert_absent "$HOME_DIR/state/.claude-seat-auto" "retire must remove the de-dupe record"

  out=$(run_seat "$HOME_DIR" "$FAKEBIN" status)
  assert_contains "$out" "auto-switch watch: not armed" "status must report the retired watch"
  pass "arm registers a repeating watch the watcher can run, and retire removes it cleanly"
}

test_status_reports_every_automatic_setting_in_percent_left() {
  local rec out
  rec=$(make_seat_case auto-status)
  read_seat_case "$rec"
  seat_logged_in "$SPEC_DIR" '(default)'
  run_seat "$HOME_DIR" "$FAKEBIN" threshold 15 >/dev/null
  run_seat "$HOME_DIR" "$FAKEBIN" destination-min 30 >/dev/null
  run_seat "$HOME_DIR" "$FAKEBIN" extra-usage allow 25 >/dev/null

  out=$(run_seat "$HOME_DIR" "$FAKEBIN" status)
  assert_contains "$out" "auto-switch trigger: at or below 15% left on the active seat" \
    "the trigger must be reported in percent left"
  assert_contains "$out" "destination minimum: only switch to a seat above 30% left" \
    "the destination minimum must be reported in percent left"
  # shellcheck disable=SC2016  # literal dollar signs in the expected output, not expansions
  assert_contains "$out" 'extra-usage policy: allow up to $25' \
    "the extra-usage policy must be reported with its dollar cap"
  pass "status reports all three automatic settings, every percentage counting percent left"
}

test_a_stop_policy_holds_a_fresh_claude_spawn_and_the_override_gets_through() {
  local rec id out spec
  id=seat-hold-1
  rec=$(spawn_case spawn-extra-usage-hold "$id")
  read_spawn_case "$rec"
  spec="$CASE_DIR/quota-spec"
  make_quota_fake "$FAKEBIN" "$spec"
  mkdir -p "$SEATS_DIR/alpha"
  printf '%s\n' "$SEATS_DIR/alpha" > "$spec/oauth"
  printf 'alpha\n' > "$HOME_DIR/config/claude-seat"
  # The active seat's plan quota is gone, so any new worker would run on paid
  # extra usage.
  printf '%s\t0\n' "$SEATS_DIR/alpha" > "$spec/remaining_map"
  printf 'stop\n' > "$HOME_DIR/config/claude-seat-extra-usage"

  out=$(run_spawn_here "$HOME_DIR" "$WT_DIR" "$FAKEBIN" "$LAUNCH_LOG" "$id" "$PROJ_DIR" 2>&1)
  expect_code 1 "$?" "a fresh claude spawn must be held once the seat has no plan quota left"
  assert_contains "$out" "holds new Claude work" "the refusal must say the work was held, not that it failed"
  assert_contains "$out" "the extra-usage policy is stop" "the refusal must give the reason the gate held it"
  assert_contains "$out" "--ignore-seat-hold" "the refusal must name the override"
  assert_absent "$HOME_DIR/state/$id.meta" "a held spawn must create no task record"
  [ ! -s "$LAUNCH_LOG" ] || fail "a held spawn must launch nothing: $(cat "$LAUNCH_LOG")"

  out=$(run_spawn_here "$HOME_DIR" "$WT_DIR" "$FAKEBIN" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --ignore-seat-hold 2>&1)
  expect_code 0 "$?" "--ignore-seat-hold must start the task anyway: $out"
  assert_grep "claude_seat=" "$HOME_DIR/state/$id.meta" "the overridden spawn must record its seat as any other does"
  assert_grep "stop" "$HOME_DIR/config/claude-seat-extra-usage" \
    "the override must change no setting, so the next spawn is gated again"
  pass "a stop policy holds a fresh claude spawn, names the override, and changes nothing when overridden"
}

test_the_spawn_gate_holds_at_the_cap_and_on_an_unreadable_quota() {
  local rec id out spec
  id=seat-hold-cap-1
  rec=$(spawn_case spawn-extra-usage-cap "$id")
  read_spawn_case "$rec"
  spec="$CASE_DIR/quota-spec"
  make_quota_fake "$FAKEBIN" "$spec"
  mkdir -p "$SEATS_DIR/alpha"
  printf '%s\n' "$SEATS_DIR/alpha" > "$spec/oauth"
  printf 'alpha\n' > "$HOME_DIR/config/claude-seat"
  printf '%s\t0\n' "$SEATS_DIR/alpha" > "$spec/remaining_map"
  printf '%s\t25\n' "$SEATS_DIR/alpha" > "$spec/extra_map"
  printf 'allow 25\n' > "$HOME_DIR/config/claude-seat-extra-usage"

  out=$(run_spawn_here "$HOME_DIR" "$WT_DIR" "$FAKEBIN" "$LAUNCH_LOG" "$id" "$PROJ_DIR" 2>&1)
  expect_code 1 "$?" "a fresh claude spawn must be held once extra-usage spend reaches the cap"
  # shellcheck disable=SC2016  # literal dollar signs in the expected output, not expansions
  assert_contains "$out" 'at or over the $25 cap' "the spawn refusal must name the cap it reached"
  assert_absent "$HOME_DIR/state/$id.meta" "a held spawn must create no task record"

  printf '%s\n' "$SEATS_DIR/alpha" > "$spec/unreadable_quota"
  out=$(run_spawn_here "$HOME_DIR" "$WT_DIR" "$FAKEBIN" "$LAUNCH_LOG" "$id" "$PROJ_DIR" 2>&1)
  expect_code 1 "$?" "a fresh claude spawn must be held when the quota gives no verdict"
  assert_contains "$out" "makes no guess" "the spawn refusal must say it refused to guess"

  rm -f "$spec/unreadable_quota"
  printf '%s\t10\n' "$SEATS_DIR/alpha" > "$spec/extra_map"
  out=$(run_spawn_here "$HOME_DIR" "$WT_DIR" "$FAKEBIN" "$LAUNCH_LOG" "$id" "$PROJ_DIR" 2>&1)
  expect_code 0 "$?" "spend under the cap must let the spawn through: $out"
  pass "the spawn gate holds at the dollar cap and on an unreadable quota, and dispatches under the cap"
}

test_a_hold_never_blocks_a_relaunch_or_another_harness() {
  local rec id out spec
  id=seat-hold-relaunch-1
  rec=$(spawn_case spawn-extra-usage-relaunch "$id")
  read_spawn_case "$rec"
  spec="$CASE_DIR/quota-spec"
  make_quota_fake "$FAKEBIN" "$spec"
  fm_fake_exit0 "$FAKEBIN" claude
  mkdir -p "$SEATS_DIR/alpha"
  printf '%s\n' "$SEATS_DIR/alpha" > "$spec/oauth"
  printf 'alpha\n' > "$HOME_DIR/config/claude-seat"
  printf '%s\t80\n' "$SEATS_DIR/alpha" > "$spec/remaining_map"

  # Launch the task while the seat is healthy, then exhaust it.
  out=$(run_spawn_here "$HOME_DIR" "$WT_DIR" "$FAKEBIN" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  expect_code 0 "$?" "precondition: a spawn on a healthy seat should succeed: $out"
  printf '%s\t0\n' "$SEATS_DIR/alpha" > "$spec/remaining_map"
  printf 'stop\n' > "$HOME_DIR/config/claude-seat-extra-usage"
  make_dead_endpoint_tmux "$FAKEBIN" "fm-$id"
  : > "$LAUNCH_LOG"

  # A relaunch is recovery of work already under way, not work being started.
  # Holding it would strand a task mid-flight over a decision its own launch
  # already made.
  out=$(CLAUDE_CONFIG_DIR='' FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" \
    fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN" "$id" --relaunch 2>&1)
  expect_code 0 "$?" "a relaunch must never be held by the extra-usage policy: $out"
  [ -s "$LAUNCH_LOG" ] || fail "the relaunch must actually launch"
  pass "the dispatch hold covers fresh claude spawns only and never strands a task already under way"
}

test_a_non_claude_spawn_is_never_held_by_the_claude_policy() {
  local rec id out spec
  id=seat-hold-codex-1
  rec=$(spawn_case spawn-extra-usage-codex "$id")
  read_spawn_case "$rec"
  spec="$CASE_DIR/quota-spec"
  make_quota_fake "$FAKEBIN" "$spec"
  mkdir -p "$SEATS_DIR/alpha"
  printf '%s\n' "$SEATS_DIR/alpha" > "$spec/oauth"
  printf 'alpha\n' > "$HOME_DIR/config/claude-seat"
  printf '%s\t0\n' "$SEATS_DIR/alpha" > "$spec/remaining_map"
  printf 'stop\n' > "$HOME_DIR/config/claude-seat-extra-usage"

  out=$(run_spawn_here "$HOME_DIR" "$WT_DIR" "$FAKEBIN" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --harness codex 2>&1)
  expect_code 0 "$?" "a worker on another harness reads no Claude profile and must never be held: $out"
  assert_no_grep "claude_seat=" "$HOME_DIR/state/$id.meta" "a non-claude spawn must still record no Claude seat"
  pass "the Claude extra-usage hold never reaches a worker on another harness"
}

# --- the quota floor ---------------------------------------------------------
# A seat whose session or weekly window runs down is RESTED out of automatic
# rotation and comes back only on a reading that proves it recovered. The
# property these cases protect is that the floor never guesses: it rests and
# wakes on figures it actually read, it never lifts the operator's own
# exclusion, and a session that refreshes never returns a seat whose remaining
# week a whole session would overrun.

# seat_windows <spec> <profile> <session-left> <session-resets> <week-left> <week-resets>
#              [<session-reserve> <week-reserve>]
# Give one profile the two account-level windows the floor reads. Rows accumulate
# until seat_windows_clear, and the first row for a profile is the one that wins.
# The two optional reserve figures are that window's own
# pace.reservePercentPoints, which is the spare the seat-choice policy ranks on;
# a case that leaves them out reports no pace at all, as a quiet account does.
seat_windows() {
  local spec=$1 row=''
  shift
  row=$(printf '%s\t' "$@")
  printf '%s\n' "${row%$'\t'}" >> "$spec/windows_map"
}

seat_windows_clear() {
  : > "$1/windows_map"
}

# floor_case <name>
# A two-seat home with a floor configured and both seats logged in.
floor_case() {
  local rec
  rec=$(make_seat_case "$1")
  read_seat_case "$rec"
  mkdir -p "$SEATS_DIR/alpha" "$SEATS_DIR/beta"
  seat_logged_in "$SPEC_DIR" "$SEATS_DIR/alpha" "$SEATS_DIR/beta"
  printf 'alpha\n' > "$HOME_DIR/config/claude-seat"
  run_seat "$HOME_DIR" "$FAKEBIN" floor 5 >/dev/null
}

# rest_beta
# Drive one pass with beta's week at 2%, which is what rests it.
rest_beta() {
  seat_windows_clear "$SPEC_DIR"
  seat_windows "$SPEC_DIR" "$SEATS_DIR/alpha" 80 2026-10-08T02:40:00Z 60 2026-10-14T21:00:00Z
  seat_windows "$SPEC_DIR" "$SEATS_DIR/beta" 70 2026-10-08T01:00:00Z 2 2026-10-09T11:00:00Z
  run_seat "$HOME_DIR" "$FAKEBIN" auto
}

make_live_resting_workers() {
  local task
  cat > "$FAKEBIN/tmux" <<'SH'
#!/usr/bin/env bash
case "$1" in
  list-windows) printf '%s\n' fm-live1 fm-live2 fm-stopped fm-other ;;
  display-message)
    case "$*" in
      *pane_current_command*) case "$*" in *fm-stopped*) echo zsh ;; *) echo claude ;; esac ;;
      *) echo fakepane ;;
    esac
    ;;
esac
SH
  chmod +x "$FAKEBIN/tmux"
  for task in live1 live2 stopped other remote malformed; do
    printf 'window=fmses:fm-%s\nendpoint_task_id=%s\nharness=claude\nclaude_seat=%s\n' \
      "$task" "$task" "$SEATS_DIR/beta" > "$HOME_DIR/state/$task.meta"
    printf 'project=%s\nworktree=%s\n' "$CASE_DIR/project" "$CASE_DIR/worktree" >> "$HOME_DIR/state/$task.meta"
  done
  printf 'harness=codex\n' >> "$HOME_DIR/state/other.meta"
  printf 'remote_host=elsewhere\n' >> "$HOME_DIR/state/remote.meta"
  printf 'endpoint_task_id=someone-else\n' >> "$HOME_DIR/state/malformed.meta"
}

test_resting_worker_warning_is_once_per_entry() {
  local out
  floor_case floor-workers
  make_live_resting_workers
  : > "$SPEC_DIR/calls"
  out=$(rest_beta)
  [ "$(wc -l < "$SPEC_DIR/calls" | tr -d ' ')" = 2 ] || fail "warning destination must share the watch memo"
  assert_contains "$out" 'beta is resting with running workers: live1 live2' "warning must name only proven live local Claude workers"
  assert_contains "$out" 'live1 relaunch --seat alpha --note' "warning must include the complete command for each worker"
  assert_contains "$out" 'live2 relaunch --seat alpha --note' "warning must include the second worker command"
  assert_contains "$out" "FM_HOME=$HOME_DIR" "command must explicitly target this home"
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" auto)
  assert_not_contains "$out" 'running workers:' "steady resting state must not warn twice"
  # Recovery clears the warning memo, and the next resting entry warns again.
  run_seat "$HOME_DIR" "$FAKEBIN" floor-dwell 0 >/dev/null
  seat_windows_clear "$SPEC_DIR"
  seat_windows "$SPEC_DIR" "$SEATS_DIR/alpha" 80 2026-10-08T02:40:00Z 60 2026-10-14T21:00:00Z
  seat_windows "$SPEC_DIR" "$SEATS_DIR/beta" 90 2026-10-08T06:00:00Z 90 2026-10-16T11:00:00Z
  run_seat "$HOME_DIR" "$FAKEBIN" auto >/dev/null
  out=$(rest_beta)
  assert_contains "$out" 'running workers: live1 live2' "a new resting entry must re-arm the warning"
  # No live task on a resting seat: no worker warning.
  rm -f "$HOME_DIR/state/live1.meta" "$HOME_DIR/state/live2.meta"
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" auto)
  assert_not_contains "$out" 'running workers:' "stopped and other-harness records must not warn"
  pass "resting-worker warnings name each live worker and its move command once per entry"
}

test_resting_warning_offers_only_the_workers_own_codex_candidate() {
  local out before calls
  floor_case floor-codex-offer
  make_live_resting_workers
  mkdir -p "$HOME_DIR/data/live1" "$HOME_DIR/data/live2"
  printf 'kind=ship\n' >> "$HOME_DIR/state/live1.meta"
  printf 'kind=scout\n' >> "$HOME_DIR/state/live2.meta"
  printf "## Captain's intent\nEligible feature work.\n## Firstmate spec\nImplement the feature.\n" > "$HOME_DIR/data/live1/brief.md"
  printf "## Captain's intent\nProtected contract work.\n## Firstmate spec\nCheck the contract.\n" > "$HOME_DIR/data/live2/brief.md"
  printf 'TYPESAFE_API_KEY=fixture-key\n' > "$HOME_DIR/.env"
  cat > "$HOME_DIR/config/crew-dispatch.json" <<'JSON'
{"rules":[
  {"when":"Feature work","use":[{"harness":"claude","model":"opus"},{"harness":"codex","model":"gpt-5.6-sol","effort":"xhigh"}]},
  {"when":"Contract work","use":{"harness":"claude","model":"opus"}}
],"default":{"harness":"codex","model":"default-only-model"}}
JSON
  mv "$FAKEBIN/quota-axi" "$FAKEBIN/quota-seat-fixture"
  cat > "$FAKEBIN/quota-axi" <<'SH'
#!/usr/bin/env bash
case " $* " in
  *' --provider '*) exec "${BASH_SOURCE[0]%/*}/quota-seat-fixture" "$@" ;;
esac
cat <<'JSON'
{"schemaVersion":5,"providers":[
  {"provider":"claude","quotaSemantics":{"status":"known","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":80,"runway":{"status":"through_reset"},"selection":{"spendPriority":0.9}}]}},
  {"provider":"codex","quotaSemantics":{"status":"known","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":60,"runway":{"status":"through_reset"},"selection":{"spendPriority":0.2}}]}}
]}
JSON
SH
  cat > "$FAKEBIN/curl" <<'SH'
#!/usr/bin/env bash
response=''
while [ $# -gt 0 ]; do
  case "$1" in -o) response=$2; shift 2 ;; *) shift ;; esac
done
request=$(cat)
printf 'request\n' >> "${BASH_SOURCE[0]%/*}/dispatch-calls"
choice=rule_1
case "$request" in *'Protected contract'*) choice=rule_2 ;; esac
printf '{"model":"jev","answers":{"rule":{"type":"choice","choice":"%s","confidence":0.95,"probabilities":{"rule_1":0.5,"rule_2":0.5,"default":0}}}}\n' "$choice" > "$response"
printf 200
SH
  chmod +x "$FAKEBIN/quota-axi" "$FAKEBIN/curl"
  before=$(cat "$HOME_DIR/state/live1.meta")
  out=$(rest_beta)
  assert_contains "$out" 'live1 relaunch --seat alpha --note' "Claude seat offer remains available"
  assert_contains "$out" 'Codex alternative for live1:' "mixed rule offers Codex"
  assert_contains "$out" 'live1 relaunch --harness codex --model gpt-5.6-sol --effort xhigh --note' "offer is the complete existing relaunch command with configured axes"
  assert_not_contains "$out" 'Codex alternative for live2:' "Claude-only worker has no Codex offer"
  assert_contains "$out" 'live2 relaunch --seat alpha --note' "Claude-only worker keeps its seat offer"
  assert_not_contains "$out" 'default-only-model' "warning never borrows a default profile"
  assert_equals "$before" "$(cat "$HOME_DIR/state/live1.meta")" "warning does not change a worker's record"
  assert_absent "$HOME_DIR/state/live1.control-relaunch" "warning never starts a move"
  calls=$(wc -l < "$FAKEBIN/dispatch-calls" | tr -d ' ')
  assert_equals 2 "$calls" "each worker is matched using its own stored brief"
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" auto)
  assert_not_contains "$out" 'Codex alternative' "warning remains once per resting entry"
  assert_equals "$calls" "$(wc -l < "$FAKEBIN/dispatch-calls" | tr -d ' ')" "repeat pass never rematches workers"
  # Turning the resolver off leaves the Claude offer and makes no request.
  rm "$HOME_DIR/.env" "$HOME_DIR/state/.claude-seat-auto"
  out=$(TYPESAFE_API_KEY='' run_seat "$HOME_DIR" "$FAKEBIN" auto)
  assert_not_contains "$out" 'Codex alternative' "off resolver leaves only the Claude offers"
  assert_contains "$out" 'live1 relaunch --seat alpha --note' "off resolver retains the move command"
  assert_equals "$calls" "$(wc -l < "$FAKEBIN/dispatch-calls" | tr -d ' ')" "off offer makes no request"
  # Malformed configuration is reported without starting a lifecycle action.
  printf 'TYPESAFE_API_KEY=fixture-key\n' > "$HOME_DIR/.env"
  printf '{broken\n' > "$HOME_DIR/config/crew-dispatch.json"
  rm "$HOME_DIR/state/.claude-seat-auto"
  # The watcher captures stdout and discards stderr, so test that channel.
  out=$(FM_HOME="$HOME_DIR" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    CLAUDE_CONFIG_DIR='' PATH="$FAKEBIN:$PATH" "$SEAT" auto 2> "$CASE_DIR/offer.stderr")
  assert_contains "$out" 'Codex offer for live1 unavailable; dispatch configuration needs attention' "configuration errors remain visible"
  assert_contains "$out" 'live1 relaunch --seat alpha --note' "a resolver error cannot remove the Claude move"
  assert_not_contains "$out" 'Codex alternative' "a resolver error cannot invent a Codex move"
  pass "resting warnings offer a rule-local Codex command without moving workers or borrowing defaults"
}

test_the_floor_is_configurable_validated_and_absent_by_default() {
  local rec out status
  rec=$(make_seat_case floor-setting)
  read_seat_case "$rec"

  out=$(run_seat "$HOME_DIR" "$FAKEBIN" floor)
  assert_contains "$out" "(unset" "no quota floor may be configured by default"
  assert_absent "$HOME_DIR/config/claude-seat-floor" \
    "reading the floor must not create the setting"
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" resting)
  assert_contains "$out" "no quota floor is configured" \
    "with no floor, nothing may be reported as resting"

  out=$(run_seat "$HOME_DIR" "$FAKEBIN" floor 101)
  status=$?
  expect_code 1 "$status" "a floor above 100 percent left must be refused"
  assert_absent "$HOME_DIR/config/claude-seat-floor" "a refused floor must record nothing"
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" floor 0)
  expect_code 1 "$?" "a floor of 0 percent left must be refused rather than meaning off"

  out=$(run_seat "$HOME_DIR" "$FAKEBIN" floor 5)
  expect_code 0 "$?" "setting the floor should succeed"
  assert_grep "5" "$HOME_DIR/config/claude-seat-floor" "the floor must be recorded"
  assert_contains "$out" "15%" "the setter must print the re-add level it derived"

  # The derived re-add level, the rest time, and the assumed session share are
  # all answers a reader can get without configuring them.
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" floor-readd)
  assert_contains "$out" "derived from the floor" "an unset re-add level must say it was derived"
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" floor-dwell)
  assert_contains "$out" "600" "the rest time must default to ten minutes"
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" session-share)
  assert_contains "$out" "20% of a week per session" "the session share must default to 20% of a week"
  assert_contains "$out" "built-in default" "an unconfigured session share must say it is the default"

  run_seat "$HOME_DIR" "$FAKEBIN" floor-readd 30 >/dev/null
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" floor-readd)
  assert_contains "$out" "30" "an explicit re-add level must override the derived one"

  out=$(run_seat "$HOME_DIR" "$FAKEBIN" floor off)
  assert_contains "$out" "cleared" "clearing the floor must say so"
  assert_absent "$HOME_DIR/config/claude-seat-floor" \
    "clearing the floor must remove the file rather than leave an empty one"
  pass "the quota floor and its three companions are absent by default, validated, and clearable"
}

test_a_seat_at_or_below_the_floor_rests_and_rotation_skips_it() {
  local out
  floor_case floor-rests
  out=$(rest_beta)
  assert_contains "$out" "beta is resting" "a seat below the floor must be reported once"
  assert_contains "$out" "2% left on its week window is at or below the 5% floor" \
    "the line must name the figure, the window it came from, and the floor it crossed"
  assert_present "$HOME_DIR/config/claude-seat-resting" "resting must be recorded"

  # One crossing, one line: the same state must not wake firstmate again.
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" auto)
  [ -z "$out" ] || fail "an unchanged resting state must not wake again: $out"

  out=$(run_seat "$HOME_DIR" "$FAKEBIN" switch --next)
  expect_code 1 "$?" "with the only other seat resting, a rotation must refuse rather than land on it"
  assert_contains "$out" "seat beta: skipped, resting below the quota floor" \
    "the refusal must name the resting seat and say why"
  assert_contains "$out" "seven_day 2% left" "the reason must carry the window and the figure"
  assert_grep "alpha" "$HOME_DIR/config/claude-seat" "a resting candidate must never be switched to"
  pass "a seat at or below the floor rests, is reported once, and every automatic switch skips it"
}

test_the_resting_record_names_the_limiting_window_and_the_reset_it_waits_for() {
  local record
  floor_case floor-record
  rest_beta >/dev/null
  record="$HOME_DIR/config/claude-seat-resting"
  [ "$(jq -r '.seats.beta.limitingWindow' "$record")" = seven_day ] ||
    fail "the record must name the window that is holding the seat down: $(cat "$record")"
  [ "$(jq -r '.seats.beta.windows.seven_day.remaining' "$record")" = 2 ] ||
    fail "the record must carry the limiting window's own figure: $(cat "$record")"
  [ "$(jq -r '.seats.beta.windows.five_hour.remaining' "$record")" = 70 ] ||
    fail "the record must carry BOTH windows, because waking needs both: $(cat "$record")"
  [ "$(jq -r '.seats.beta.expectedBack' "$record")" = 2026-10-09T11:00:00Z ] ||
    fail "a seat rested for its week must expect to be back at the week's own reset: $(cat "$record")"
  [ "$(jq -r '.seats.beta.provisional' "$record")" = false ] ||
    fail "a seat rested on a figure it actually read is not provisional: $(cat "$record")"
  pass "the resting record names the limiting window, both windows' figures, and when the seat is due back"
}

test_an_explicit_switch_still_reaches_a_resting_seat_and_warns() {
  local out
  floor_case floor-explicit-switch
  rest_beta >/dev/null

  out=$(run_seat "$HOME_DIR" "$FAKEBIN" switch beta)
  expect_code 0 "$?" "an explicit switch onto a resting seat must still succeed: $out"
  assert_contains "$out" "warning: beta is resting below the quota floor" \
    "the switch must say what it is landing on"
  assert_contains "$out" "switched: alpha -> beta" "the switch itself must happen"
  assert_grep "beta" "$HOME_DIR/config/claude-seat" "the explicit choice must be recorded"
  pass "resting withholds a seat from the automatic paths only; switch <name> still reaches it with a warning"
}

test_a_seat_held_out_by_hand_is_never_rested_or_lifted_by_the_floor() {
  local out
  floor_case floor-manual-precedence
  run_seat "$HOME_DIR" "$FAKEBIN" auto-exclude beta >/dev/null

  out=$(rest_beta)
  [ -z "$out" ] || fail "a seat held out by hand must not be read or rested by the floor: $out"
  assert_absent "$HOME_DIR/config/claude-seat-resting" \
    "the floor must record nothing about a seat the operator already withheld"
  assert_grep "beta" "$HOME_DIR/config/claude-seat-auto-exclude" \
    "the floor must never write the operator's own exclusion file"

  # And the reverse: a reading that would wake a seat never lifts a manual
  # exclusion, because that file is the operator's standing choice.
  seat_windows_clear "$SPEC_DIR"
  seat_windows "$SPEC_DIR" "$SEATS_DIR/beta" 95 2026-10-08T06:00:00Z 95 2026-10-16T11:00:00Z
  run_seat "$HOME_DIR" "$FAKEBIN" auto >/dev/null
  assert_grep "beta" "$HOME_DIR/config/claude-seat-auto-exclude" \
    "a recovered seat must stay held out until the operator includes it again"
  pass "a manual exclusion takes precedence over the floor and is never lifted by a reading"
}

test_a_resting_seat_comes_back_only_above_the_readd_level_and_after_the_rest_time() {
  local out
  floor_case floor-readd
  rest_beta >/dev/null

  # Recovered on both windows, but the rest time has not elapsed.
  run_seat "$HOME_DIR" "$FAKEBIN" floor-dwell 3600 >/dev/null
  seat_windows_clear "$SPEC_DIR"
  seat_windows "$SPEC_DIR" "$SEATS_DIR/alpha" 80 2026-10-08T02:40:00Z 60 2026-10-14T21:00:00Z
  seat_windows "$SPEC_DIR" "$SEATS_DIR/beta" 90 2026-10-08T06:00:00Z 50 2026-10-16T11:00:00Z
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" auto)
  [ -z "$out" ] || fail "a seat that has not rested long enough must not come back yet: $out"
  assert_present "$HOME_DIR/config/claude-seat-resting" "it must still be recorded as resting"

  # Rest time satisfied, but the session window is still below the re-add level.
  run_seat "$HOME_DIR" "$FAKEBIN" floor-dwell 0 >/dev/null
  seat_windows_clear "$SPEC_DIR"
  seat_windows "$SPEC_DIR" "$SEATS_DIR/alpha" 80 2026-10-08T02:40:00Z 60 2026-10-14T21:00:00Z
  seat_windows "$SPEC_DIR" "$SEATS_DIR/beta" 12 2026-10-08T06:00:00Z 50 2026-10-16T11:00:00Z
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" auto)
  [ -z "$out" ] || fail "both windows must clear the re-add level, not only the one that rested it: $out"
  assert_present "$HOME_DIR/config/claude-seat-resting" "a low session must keep the seat resting"

  # Both windows above the re-add level, with room for a whole session.
  seat_windows_clear "$SPEC_DIR"
  seat_windows "$SPEC_DIR" "$SEATS_DIR/alpha" 80 2026-10-08T02:40:00Z 60 2026-10-14T21:00:00Z
  seat_windows "$SPEC_DIR" "$SEATS_DIR/beta" 90 2026-10-08T06:00:00Z 50 2026-10-16T11:00:00Z
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" auto)
  assert_contains "$out" "beta comes back into automatic rotation" "a recovered seat must be reported once"
  assert_absent "$HOME_DIR/config/claude-seat-resting" \
    "the last resting seat leaving must remove the record rather than leave an empty one"

  out=$(run_seat "$HOME_DIR" "$FAKEBIN" switch --next)
  expect_code 0 "$?" "a seat that came back must be a rotation destination again: $out"
  assert_grep "beta" "$HOME_DIR/config/claude-seat" "rotation must reach the recovered seat"
  pass "a resting seat comes back only when both windows clear the re-add level and it has rested long enough"
}

test_a_session_reset_alone_never_returns_a_seat_whose_week_cannot_carry_a_session() {
  local out
  floor_case floor-week-guard
  run_seat "$HOME_DIR" "$FAKEBIN" floor-dwell 0 >/dev/null
  # Rested for its SESSION, with a week that is healthy enough to read but could
  # not absorb another whole session on top of the re-add level.
  seat_windows_clear "$SPEC_DIR"
  seat_windows "$SPEC_DIR" "$SEATS_DIR/alpha" 80 2026-10-08T02:40:00Z 60 2026-10-14T21:00:00Z
  seat_windows "$SPEC_DIR" "$SEATS_DIR/beta" 2 2026-10-08T01:00:00Z 30 2026-10-14T21:00:00Z
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" auto)
  assert_contains "$out" "beta is resting" "precondition: the seat must rest on its session"
  [ "$(jq -r '.seats.beta.limitingWindow' "$HOME_DIR/config/claude-seat-resting")" = five_hour ] ||
    fail "precondition: the session must be the window holding it down"

  # The session window rolls back to full. The week is 30% left against a 15%
  # re-add level plus a 20% session, so spending one more whole session would
  # take the week below the level it just has to clear.
  seat_windows_clear "$SPEC_DIR"
  seat_windows "$SPEC_DIR" "$SEATS_DIR/alpha" 80 2026-10-08T02:40:00Z 60 2026-10-14T21:00:00Z
  seat_windows "$SPEC_DIR" "$SEATS_DIR/beta" 100 2026-10-08T06:00:00Z 30 2026-10-14T21:00:00Z
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" auto)
  [ -z "$out" ] || fail "a session refresh must not return a seat whose week cannot carry a session: $out"
  assert_present "$HOME_DIR/config/claude-seat-resting" "the seat must stay out of rotation"

  # The week recovers enough to carry one. Now the same session reading wakes it.
  seat_windows_clear "$SPEC_DIR"
  seat_windows "$SPEC_DIR" "$SEATS_DIR/alpha" 80 2026-10-08T02:40:00Z 60 2026-10-14T21:00:00Z
  seat_windows "$SPEC_DIR" "$SEATS_DIR/beta" 100 2026-10-08T06:00:00Z 40 2026-10-21T21:00:00Z
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" auto)
  assert_contains "$out" "beta comes back into automatic rotation" \
    "a week that can carry a whole session must let the seat back"
  pass "a session that refreshes never returns a seat whose remaining week a whole session would overrun"
}

test_a_week_that_resets_returns_a_seat_rested_for_its_week() {
  local out
  floor_case floor-week-reset
  run_seat "$HOME_DIR" "$FAKEBIN" floor-dwell 0 >/dev/null
  rest_beta >/dev/null
  [ "$(jq -r '.seats.beta.limitingWindow' "$HOME_DIR/config/claude-seat-resting")" = seven_day ] ||
    fail "precondition: the week must be the window holding it down"

  seat_windows_clear "$SPEC_DIR"
  seat_windows "$SPEC_DIR" "$SEATS_DIR/alpha" 80 2026-10-08T02:40:00Z 60 2026-10-14T21:00:00Z
  seat_windows "$SPEC_DIR" "$SEATS_DIR/beta" 80 2026-10-08T06:00:00Z 95 2026-10-16T11:00:00Z
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" auto)
  assert_contains "$out" "beta comes back into automatic rotation" \
    "a week that reset must return the seat it was holding down"
  assert_absent "$HOME_DIR/config/claude-seat-resting" "nothing may still be recorded as resting"
  pass "a seat rested for its week comes back when the week itself recovers"
}

test_the_session_share_is_measured_from_co_movement_inside_one_window() {
  local out
  floor_case floor-share-measured
  # Two complete session windows on alpha, each spending 50 points of session
  # against 10 and 15 points of week, so one whole session costs 20% and then
  # 25% of a week. The larger is the one kept.
  seat_windows_clear "$SPEC_DIR"
  seat_windows "$SPEC_DIR" "$SEATS_DIR/alpha" 100 2026-10-08T02:40:00Z 90 2026-10-14T21:00:00Z
  run_seat "$HOME_DIR" "$FAKEBIN" auto >/dev/null
  seat_windows_clear "$SPEC_DIR"
  seat_windows "$SPEC_DIR" "$SEATS_DIR/alpha" 50 2026-10-08T02:40:00Z 80 2026-10-14T21:00:00Z
  run_seat "$HOME_DIR" "$FAKEBIN" auto >/dev/null
  seat_windows_clear "$SPEC_DIR"
  seat_windows "$SPEC_DIR" "$SEATS_DIR/alpha" 100 2026-10-08T07:40:00Z 80 2026-10-14T21:00:00Z
  run_seat "$HOME_DIR" "$FAKEBIN" auto >/dev/null

  out=$(run_seat "$HOME_DIR" "$FAKEBIN" session-share)
  assert_contains "$out" "assumed, 1 sample(s)" \
    "one sample is not enough to call the share measured: $out"

  seat_windows_clear "$SPEC_DIR"
  seat_windows "$SPEC_DIR" "$SEATS_DIR/alpha" 40 2026-10-08T07:40:00Z 65 2026-10-14T21:00:00Z
  run_seat "$HOME_DIR" "$FAKEBIN" auto >/dev/null
  seat_windows_clear "$SPEC_DIR"
  seat_windows "$SPEC_DIR" "$SEATS_DIR/alpha" 100 2026-10-08T12:40:00Z 65 2026-10-14T21:00:00Z
  run_seat "$HOME_DIR" "$FAKEBIN" auto >/dev/null

  out=$(run_seat "$HOME_DIR" "$FAKEBIN" session-share)
  assert_contains "$out" "25% of a week per session (measured, 2 sample(s))" \
    "two whole windows must produce a measured share, taking the larger: $out"
  pass "the session share is measured from how the two windows move together inside one window"
}

test_an_unmeasured_session_share_uses_the_assumed_figure_and_says_so() {
  local out
  floor_case floor-share-assumed
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" session-share)
  assert_contains "$out" "20% of a week per session" "the built-in assumption must be 20% of a week"
  assert_contains "$out" "built-in default" "an unmeasured share must say where the figure came from"

  run_seat "$HOME_DIR" "$FAKEBIN" session-share 35 >/dev/null
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" session-share)
  assert_contains "$out" "35% of a week per session (set by hand)" \
    "an operator may override the assumed share: $out"

  # The override is what the wake guard uses: a week of 45% left clears a 15%
  # re-add level but cannot carry a 35% session on top of it.
  run_seat "$HOME_DIR" "$FAKEBIN" floor-dwell 0 >/dev/null
  rest_beta >/dev/null
  seat_windows_clear "$SPEC_DIR"
  seat_windows "$SPEC_DIR" "$SEATS_DIR/alpha" 80 2026-10-08T02:40:00Z 60 2026-10-14T21:00:00Z
  seat_windows "$SPEC_DIR" "$SEATS_DIR/beta" 90 2026-10-08T06:00:00Z 45 2026-10-16T11:00:00Z
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" auto)
  [ -z "$out" ] || fail "the configured share must bind the wake guard: $out"
  assert_present "$HOME_DIR/config/claude-seat-resting" "the seat must stay resting under the larger share"
  pass "an unmeasured share uses the assumed figure, says so, and the override binds the wake guard"
}

test_an_unreadable_reading_never_rests_a_seat_and_never_wakes_one() {
  local out
  floor_case floor-unreadable
  run_seat "$HOME_DIR" "$FAKEBIN" floor-dwell 0 >/dev/null
  seat_quota_unreadable "$SPEC_DIR" "$SEATS_DIR/beta"
  seat_windows_clear "$SPEC_DIR"
  seat_windows "$SPEC_DIR" "$SEATS_DIR/alpha" 80 2026-10-08T02:40:00Z 60 2026-10-14T21:00:00Z
  seat_windows "$SPEC_DIR" "$SEATS_DIR/beta" 1 2026-10-08T01:00:00Z 1 2026-10-09T11:00:00Z

  out=$(run_seat "$HOME_DIR" "$FAKEBIN" auto)
  [ -z "$out" ] || fail "an unreadable quota must not rest a seat and must not wake firstmate: $out"
  assert_absent "$HOME_DIR/config/claude-seat-resting" \
    "a seat whose quota gives no verdict must never be rested on it"

  # Now it reads, and rests. Then it stops reading again: the state stands.
  : > "$SPEC_DIR/unreadable_quota"
  rest_beta >/dev/null
  assert_present "$HOME_DIR/config/claude-seat-resting" "precondition: the seat must be resting"
  seat_quota_unreadable "$SPEC_DIR" "$SEATS_DIR/beta"
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" auto)
  [ -z "$out" ] || fail "an unreadable quota must not wake a resting seat either: $out"
  assert_present "$HOME_DIR/config/claude-seat-resting" "the resting seat must stay out of rotation"
  [ "$(jq -r '.seats.beta.unreadableSince' "$HOME_DIR/config/claude-seat-resting")" != null ] ||
    fail "the record must say since when the quota could not be read"
  pass "an unreadable reading changes no seat's state in either direction"
}

test_a_lapsed_seat_comes_back_provisionally_only_once_its_recorded_reset_has_passed() {
  local out
  floor_case floor-lapsed
  run_seat "$HOME_DIR" "$FAKEBIN" floor-dwell 0 >/dev/null
  # Rested for a week that does not reset until 2099.
  seat_windows_clear "$SPEC_DIR"
  seat_windows "$SPEC_DIR" "$SEATS_DIR/alpha" 80 2026-10-08T02:40:00Z 60 2026-10-14T21:00:00Z
  seat_windows "$SPEC_DIR" "$SEATS_DIR/beta" 70 2026-10-08T01:00:00Z 2 2099-01-01T00:00:00Z
  run_seat "$HOME_DIR" "$FAKEBIN" auto >/dev/null
  assert_present "$HOME_DIR/config/claude-seat-resting" "precondition: the seat must be resting"

  # Nothing has launched there for eight hours, so its token lapses and its
  # quota becomes unreadable. The reset it is waiting for has not arrived.
  seat_expired_refreshable "$SPEC_DIR" "$SEATS_DIR/beta"
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" auto)
  [ -z "$out" ] || fail "a lapsed seat must not come back before the reset it is waiting for: $out"
  assert_present "$HOME_DIR/config/claude-seat-resting" "it must still be out of rotation"

  # The same seat, rested on a week whose reset has already passed: nothing can
  # read it again until a worker launched there renews the token, so it returns
  # provisionally rather than deadlocking out of rotation for good.
  floor_case floor-lapsed-due
  run_seat "$HOME_DIR" "$FAKEBIN" floor-dwell 0 >/dev/null
  seat_windows_clear "$SPEC_DIR"
  seat_windows "$SPEC_DIR" "$SEATS_DIR/alpha" 80 2026-10-08T02:40:00Z 60 2026-10-14T21:00:00Z
  seat_windows "$SPEC_DIR" "$SEATS_DIR/beta" 70 2020-01-01T00:00:00Z 2 2020-01-02T00:00:00Z
  run_seat "$HOME_DIR" "$FAKEBIN" auto >/dev/null
  assert_present "$HOME_DIR/config/claude-seat-resting" "precondition: the seat must be resting"
  seat_expired_refreshable "$SPEC_DIR" "$SEATS_DIR/beta"
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" auto)
  assert_contains "$out" "beta comes back into automatic rotation provisionally" \
    "a lapsed seat whose reset has passed must come back provisionally: $out"
  [ "$(jq -r '.seats.beta.provisional' "$HOME_DIR/config/claude-seat-resting")" = true ] ||
    fail "a seat back provisionally must keep its entry, marked provisional"
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" auto)
  [ -z "$out" ] || fail "a seat already back provisionally must not be announced again: $out"
  pass "a seat whose token lapsed while resting comes back only once the reset it was waiting for has passed"
}

# rest_beta_then_go_provisional
# Rest beta on a week whose reset has already passed, then lapse its token, so
# the next pass brings it back provisionally.
rest_beta_then_go_provisional() {
  run_seat "$HOME_DIR" "$FAKEBIN" floor-dwell 0 >/dev/null
  seat_windows_clear "$SPEC_DIR"
  seat_windows "$SPEC_DIR" "$SEATS_DIR/alpha" 80 2026-10-08T02:40:00Z 60 2026-10-14T21:00:00Z
  seat_windows "$SPEC_DIR" "$SEATS_DIR/beta" 70 2020-01-01T00:00:00Z 2 2020-01-02T00:00:00Z
  run_seat "$HOME_DIR" "$FAKEBIN" auto >/dev/null
  seat_expired_refreshable "$SPEC_DIR" "$SEATS_DIR/beta"
  run_seat "$HOME_DIR" "$FAKEBIN" auto >/dev/null
}

test_a_provisional_seat_is_a_candidate_and_is_shown_as_provisionally_back() {
  local out
  floor_case floor-provisional-candidate
  rest_beta_then_go_provisional
  [ "$(jq -r '.seats.beta.provisional' "$HOME_DIR/config/claude-seat-resting")" = true ] ||
    fail "precondition: beta must be back provisionally"

  out=$(run_seat "$HOME_DIR" "$FAKEBIN" list)
  printf '%s\n' "$out" | grep -q '^  beta.*back in automatic rotation provisionally' ||
    fail "list must show the seat as provisionally back rather than resting: $out"
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" status)
  assert_contains "$out" "back provisionally" "status must show the seat as provisionally back"

  out=$(run_seat "$HOME_DIR" "$FAKEBIN" switch beta)
  case "$out" in
    *"is resting below the quota floor"*) fail "a provisional seat is not resting and must not warn as one: $out" ;;
  esac
  printf 'alpha\n' > "$HOME_DIR/config/claude-seat"
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" switch --next)
  expect_code 0 "$?" "a seat back provisionally must be a rotation destination: $out"
  assert_grep "beta" "$HOME_DIR/config/claude-seat" "rotation must land on the provisional seat"
  pass "a seat back provisionally is a rotation candidate and every surface shows it as provisionally back"
}

test_the_first_readable_reading_settles_a_provisional_seat() {
  local out
  floor_case floor-provisional-settles
  rest_beta_then_go_provisional

  # Still low on real figures: it rests again, from now.
  rm -f "$SPEC_DIR/expired_refreshable"
  seat_windows_clear "$SPEC_DIR"
  seat_windows "$SPEC_DIR" "$SEATS_DIR/alpha" 80 2026-10-08T02:40:00Z 60 2026-10-14T21:00:00Z
  seat_windows "$SPEC_DIR" "$SEATS_DIR/beta" 70 2099-01-01T00:00:00Z 3 2099-01-02T00:00:00Z
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" auto)
  assert_contains "$out" "beta is resting" "a provisional seat still at the floor must rest again: $out"
  [ "$(jq -r '.seats.beta.provisional' "$HOME_DIR/config/claude-seat-resting")" = false ] ||
    fail "a seat rested again must no longer be provisional"
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" switch --next)
  expect_code 1 "$?" "a seat rested again must leave rotation: $out"

  # Above the floor on real figures: the entry is simply cleared.
  floor_case floor-provisional-clears
  rest_beta_then_go_provisional
  rm -f "$SPEC_DIR/expired_refreshable"
  seat_windows_clear "$SPEC_DIR"
  seat_windows "$SPEC_DIR" "$SEATS_DIR/alpha" 80 2026-10-08T02:40:00Z 60 2026-10-14T21:00:00Z
  seat_windows "$SPEC_DIR" "$SEATS_DIR/beta" 70 2099-01-01T00:00:00Z 60 2099-01-02T00:00:00Z
  run_seat "$HOME_DIR" "$FAKEBIN" auto >/dev/null
  assert_absent "$HOME_DIR/config/claude-seat-resting" \
    "a provisional seat read above the floor must leave the record entirely"
  pass "the first readable reading either rests a provisional seat again or clears its entry"
}

test_a_provisional_seat_whose_week_cannot_absorb_a_session_stays_resting() {
  local out
  floor_case floor-provisional-short-week
  run_seat "$HOME_DIR" "$FAKEBIN" floor-dwell 0 >/dev/null
  # Rested on its session while its week still read 40%, so the passed session
  # reset is enough to bring it back provisionally once its token lapses.
  seat_windows_clear "$SPEC_DIR"
  seat_windows "$SPEC_DIR" "$SEATS_DIR/alpha" 80 2026-10-08T02:40:00Z 60 2026-10-14T21:00:00Z
  seat_windows "$SPEC_DIR" "$SEATS_DIR/beta" 2 2020-01-01T00:00:00Z 40 2099-01-02T00:00:00Z
  run_seat "$HOME_DIR" "$FAKEBIN" auto >/dev/null
  seat_expired_refreshable "$SPEC_DIR" "$SEATS_DIR/beta"
  run_seat "$HOME_DIR" "$FAKEBIN" auto >/dev/null
  [ "$(jq -r '.seats.beta.provisional' "$HOME_DIR/config/claude-seat-resting")" = true ] ||
    fail "precondition: beta must be back provisionally"

  # Its week drained to 10% elsewhere: a fresh session is above the floor, but
  # the week cannot absorb a whole 20% session on top of the 15% re-add level.
  rm -f "$SPEC_DIR/expired_refreshable"
  seat_windows_clear "$SPEC_DIR"
  seat_windows "$SPEC_DIR" "$SEATS_DIR/alpha" 80 2026-10-08T02:40:00Z 60 2026-10-14T21:00:00Z
  seat_windows "$SPEC_DIR" "$SEATS_DIR/beta" 100 2099-01-01T00:00:00Z 10 2099-01-02T00:00:00Z
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" auto)
  assert_contains "$out" "beta is resting again" "a provisional seat that fails the wake test must rest again: $out"
  [ "$(jq -r '.seats.beta.provisional' "$HOME_DIR/config/claude-seat-resting")" = false ] ||
    fail "a provisional seat rested again must no longer be provisional"
  [ "$(jq -r '.seats.beta.windows.seven_day.remaining' "$HOME_DIR/config/claude-seat-resting")" = 10 ] ||
    fail "the record must carry the fresh figures: $(cat "$HOME_DIR/config/claude-seat-resting")"
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" switch --next)
  expect_code 1 "$?" "a seat whose week cannot absorb a session must stay out of rotation: $out"
  pass "a provisional seat is settled by the full wake test, not by clearing the floor alone"
}

test_a_week_reset_inside_a_session_yields_no_share_sample() {
  local out
  floor_case floor-share-week-reset
  seat_windows_clear "$SPEC_DIR"
  seat_windows "$SPEC_DIR" "$SEATS_DIR/alpha" 100 2026-10-08T02:40:00Z 97 2026-10-08T01:00:00Z
  run_seat "$HOME_DIR" "$FAKEBIN" auto >/dev/null
  # The week resets while the same session is still open.
  seat_windows_clear "$SPEC_DIR"
  seat_windows "$SPEC_DIR" "$SEATS_DIR/alpha" 70 2026-10-08T02:40:00Z 100 2026-10-15T01:00:00Z
  run_seat "$HOME_DIR" "$FAKEBIN" auto >/dev/null
  seat_windows_clear "$SPEC_DIR"
  seat_windows "$SPEC_DIR" "$SEATS_DIR/alpha" 60 2026-10-08T02:40:00Z 90 2026-10-15T01:00:00Z
  run_seat "$HOME_DIR" "$FAKEBIN" auto >/dev/null
  seat_windows_clear "$SPEC_DIR"
  seat_windows "$SPEC_DIR" "$SEATS_DIR/alpha" 100 2026-10-08T07:40:00Z 90 2026-10-15T01:00:00Z
  run_seat "$HOME_DIR" "$FAKEBIN" auto >/dev/null

  out=$(run_seat "$HOME_DIR" "$FAKEBIN" session-share)
  case "$out" in
    *"1 sample(s)"*) fail "a session the week reset inside must not produce a share sample: $out" ;;
  esac
  pass "a week reset inside an open session restarts its measurement rather than understating the share"
}

test_a_failed_push_after_a_hand_wake_does_not_claim_a_seat_switched() {
  local out sm
  if [ "$(id -u)" = 0 ]; then
    printf '# skip - an unwritable secondmate config requires a non-root user\n'
    return
  fi
  floor_case floor-wake-push-fails
  sm=$(add_local_secondmate "$HOME_DIR" "$FAKEBIN" smwakefail)
  TMUX='' rest_beta >/dev/null
  chmod 500 "$sm/config"
  out=$(TMUX='' run_seat "$HOME_DIR" "$FAKEBIN" resting wake beta)
  chmod 700 "$sm/config"
  assert_contains "$out" "not every secondmate home was updated" "a failed push must be reported"
  assert_contains "$out" "beta woken here" "the warning must name what actually changed: $out"
  case "$out" in
    *"seat switched"*) fail "a hand wake switched nothing and must not say so: $out" ;;
  esac
  pass "a failed push after a hand wake reports the wake, not a seat switch"
}

test_clearing_the_floor_wakes_every_resting_seat_here_and_in_secondmates() {
  local out sm
  floor_case floor-off-wakes
  sm=$(add_local_secondmate "$HOME_DIR" "$FAKEBIN" smflooroff)
  TMUX='' rest_beta >/dev/null
  assert_present "$sm/config/claude-seat-resting" "precondition: the secondmate must hold the record"

  out=$(TMUX='' run_seat "$HOME_DIR" "$FAKEBIN" floor off)
  assert_contains "$out" "back in automatic rotation" "clearing the floor must say the rested seats are back"
  assert_absent "$HOME_DIR/config/claude-seat-resting" "clearing the floor must clear the resting record"
  assert_absent "$sm/config/claude-seat-resting" "a secondmate's copy of the record must be cleared too"
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" switch --next)
  expect_code 0 "$?" "with the floor cleared, the seat it rested must be a destination again: $out"
  pass "clearing the floor clears the resting record here and in local secondmate homes"
}

test_a_resting_record_withholds_nothing_while_no_floor_is_configured() {
  local out
  floor_case floor-stale-record
  rest_beta >/dev/null
  # A record left behind with the floor file gone, by hand or by an older build.
  rm -f "$HOME_DIR/config/claude-seat-floor"
  assert_present "$HOME_DIR/config/claude-seat-resting" "precondition: a stale record must exist"

  out=$(run_seat "$HOME_DIR" "$FAKEBIN" list)
  case "$out" in
    *resting*) fail "no seat may read as resting while no floor is configured: $out" ;;
  esac
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" switch --next)
  expect_code 0 "$?" "a stale record must never withhold a seat while the floor is off: $out"
  assert_grep "beta" "$HOME_DIR/config/claude-seat" "rotation must reach the seat the stale record names"
  pass "a resting record withholds nothing while no floor is configured"
}

test_a_readd_level_at_or_below_the_floor_is_refused_and_ignored() {
  local out
  floor_case floor-readd-below
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" floor-readd 5)
  expect_code 1 "$?" "a re-add level at the floor must be refused: $out"
  assert_contains "$out" "above the 5% floor" "the refusal must name the floor"
  assert_absent "$HOME_DIR/config/claude-seat-floor-readd" "a refused re-add level must record nothing"

  # Set above the floor, then the floor is raised past it: the derived level applies.
  run_seat "$HOME_DIR" "$FAKEBIN" floor-readd 10 >/dev/null
  run_seat "$HOME_DIR" "$FAKEBIN" floor 12 >/dev/null
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" floor-readd)
  assert_contains "$out" "36 (derived from the floor; the configured 10" \
    "a re-add level the floor overtook must fall back to the derived one: $out"

  # And a seat rested at the raised floor does not wake at the stale level.
  run_seat "$HOME_DIR" "$FAKEBIN" floor-dwell 0 >/dev/null
  rest_beta >/dev/null
  seat_windows_clear "$SPEC_DIR"
  seat_windows "$SPEC_DIR" "$SEATS_DIR/alpha" 80 2026-10-08T02:40:00Z 60 2026-10-14T21:00:00Z
  seat_windows "$SPEC_DIR" "$SEATS_DIR/beta" 11 2026-10-08T06:00:00Z 50 2026-10-16T11:00:00Z
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" auto)
  case "$out" in
    *"comes back"*) fail "a seat still at the floor must not wake on a stale re-add level: $out" ;;
  esac
  assert_present "$HOME_DIR/config/claude-seat-resting" "the seat must stay resting"
  pass "a re-add level at or below the floor is refused, and one the floor overtook is ignored"
}

test_a_hand_wake_during_a_pass_is_not_undone_by_it() {
  local out pid
  floor_case floor-wake-race
  rest_beta >/dev/null
  # A slow pass that will rest alpha, so it has something of its own to write.
  seat_windows_clear "$SPEC_DIR"
  seat_windows "$SPEC_DIR" "$SEATS_DIR/alpha" 80 2026-10-08T02:40:00Z 3 2026-10-14T21:00:00Z
  seat_windows "$SPEC_DIR" "$SEATS_DIR/beta" 70 2026-10-08T01:00:00Z 2 2026-10-09T11:00:00Z
  printf '2\n' > "$SPEC_DIR/slow"
  run_seat "$HOME_DIR" "$FAKEBIN" auto > "$CASE_DIR/pass.out" &
  pid=$!
  sleep 1
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" resting wake beta)
  assert_contains "$out" "back in automatic rotation: beta" "precondition: the hand wake must land mid-pass"
  wait "$pid"
  rm -f "$SPEC_DIR/slow"
  assert_contains "$(cat "$CASE_DIR/pass.out")" "alpha is resting" "precondition: the pass must have rested alpha"
  [ "$(jq -r '.seats | has("beta")' "$HOME_DIR/config/claude-seat-resting")" = false ] ||
    fail "a pass must not restore a seat the operator woke while it ran"
  [ "$(jq -r '.seats | has("alpha")' "$HOME_DIR/config/claude-seat-resting")" = true ] ||
    fail "the pass's own change must still be written"
  pass "a seat woken by hand during a pass stays woken"
}

test_arm_keeps_the_refusal_when_a_candidate_is_withheld_for_another_reason() {
  local out
  floor_case floor-arm-mixed
  mkdir -p "$SEATS_DIR/gamma"
  run_seat "$HOME_DIR" "$FAKEBIN" threshold 15 >/dev/null
  rest_beta >/dev/null
  # gamma has a directory but no login, so the watch will never bring it back.
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" arm)
  expect_code 1 "$?" "arm must refuse when a candidate is out for a reason the watch never lifts: $out"
  case "$out" in
    *"every candidate seat is resting"*) fail "arm must not claim every candidate is resting: $out" ;;
  esac
  pass "arm keeps its refusal unless every rejected candidate is merely resting"
}

test_a_killed_pass_leaves_no_memo_directory_behind() {
  local pid tmp
  floor_case floor-memo-cleanup
  tmp="$CASE_DIR/tmp"
  mkdir -p "$tmp"
  seat_windows_clear "$SPEC_DIR"
  seat_windows "$SPEC_DIR" "$SEATS_DIR/alpha" 80 2026-10-08T02:40:00Z 60 2026-10-14T21:00:00Z
  printf '2\n' > "$SPEC_DIR/slow"
  TMPDIR="$tmp" FM_HOME="$HOME_DIR" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    PATH="$FAKEBIN:$PATH" "$SEAT" auto >/dev/null 2>&1 &
  pid=$!
  sleep 1
  ls -d "$tmp"/fm-seat-pass.* >/dev/null 2>&1 || fail "precondition: the pass must have made its memo directory"
  kill -TERM "$pid"
  wait "$pid" 2>/dev/null
  rm -f "$SPEC_DIR/slow"
  ! ls -d "$tmp"/fm-seat-pass.* >/dev/null 2>&1 ||
    fail "a pass killed at its timeout must not leave its memo directory behind"
  pass "a pass the watcher kills leaves no memo directory behind"
}

test_one_floor_pass_reads_each_seat_once_and_stays_inside_the_check_budget() {
  local out alpha_calls beta_calls started elapsed
  floor_case floor-budget
  run_seat "$HOME_DIR" "$FAKEBIN" threshold 15 >/dev/null
  seat_windows_clear "$SPEC_DIR"
  seat_windows "$SPEC_DIR" "$SEATS_DIR/alpha" 80 2026-10-08T02:40:00Z 60 2026-10-14T21:00:00Z
  seat_windows "$SPEC_DIR" "$SEATS_DIR/beta" 70 2026-10-08T01:00:00Z 2 2026-10-09T11:00:00Z
  : > "$SPEC_DIR/calls"
  run_seat "$HOME_DIR" "$FAKEBIN" auto >/dev/null
  alpha_calls=$(grep -Fxc "$SEATS_DIR/alpha" "$SPEC_DIR/calls" || true)
  beta_calls=$(grep -Fxc "$SEATS_DIR/beta" "$SPEC_DIR/calls" || true)
  [ "$alpha_calls" = 1 ] ||
    fail "one pass must read the active seat exactly once, made $alpha_calls reads"
  [ "$beta_calls" = 1 ] ||
    fail "one pass must read each candidate seat exactly once, made $beta_calls reads"

  # And the floor's own reads respect the watcher's per-check budget: a quota
  # endpoint slower than the budget leaves the pass with no verdict, not with a
  # pass the watcher has to kill.
  printf '30\n' > "$SPEC_DIR/slow"
  started=$(date +%s)
  out=$(FM_CHECK_TIMEOUT=8 run_seat "$HOME_DIR" "$FAKEBIN" auto)
  elapsed=$(($(date +%s) - started))
  [ "$elapsed" -lt 8 ] || fail "a floor pass with slow reads must finish inside FM_CHECK_TIMEOUT, took ${elapsed}s"
  [ -z "$out" ] || fail "a read cut short must give no verdict and no wake: $out"
  pass "one automatic pass makes exactly one quota read per seat and stays inside the watcher's budget"
}

test_the_resting_record_reaches_local_secondmates_and_a_declining_home_keeps_its_own() {
  local sm declining
  floor_case floor-secondmate
  sm=$(add_local_secondmate "$HOME_DIR" "$FAKEBIN" smfloor)
  declining=$(add_local_secondmate "$HOME_DIR" "$FAKEBIN" smdecline)
  decline_inherited_seats "$declining"

  TMUX='' rest_beta >/dev/null
  assert_present "$sm/config/claude-seat-resting" \
    "a local secondmate must receive the resting record, because its own rotation reads it"
  [ "$(jq -r '.seats.beta.limitingWindow' "$sm/config/claude-seat-resting")" = seven_day ] ||
    fail "the secondmate's copy must carry the same reason the primary recorded"
  assert_present "$sm/config/claude-seat-floor" "the floor settings must be inherited too"
  assert_absent "$declining/config/claude-seat-resting" \
    "a home that declines inherited seats must keep its own, including an absent record"
  assert_absent "$declining/config/claude-seat-floor" \
    "a declining home must not receive the floor settings either"
  pass "the resting record and the floor settings reach local secondmate homes and skip a declining one"
}

test_arm_warns_rather_than_refusing_when_every_candidate_is_merely_resting() {
  local out
  floor_case floor-arm
  run_seat "$HOME_DIR" "$FAKEBIN" threshold 15 >/dev/null
  rest_beta >/dev/null

  out=$(run_seat "$HOME_DIR" "$FAKEBIN" arm)
  expect_code 0 "$?" "arming must not be refused when the floor itself is what emptied the candidate list: $out"
  assert_contains "$out" "every candidate seat is resting" "arm must say why there is nowhere to go right now"
  assert_contains "$out" "armed" "the watch must still be armed"
  run_seat "$HOME_DIR" "$FAKEBIN" retire >/dev/null
  pass "arm warns rather than refusing when every candidate is merely resting, because the watch is what brings them back"
}

test_a_floor_may_be_armed_with_no_switch_threshold() {
  local out
  floor_case floor-arm-no-threshold
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" arm)
  expect_code 0 "$?" "a floor alone must be enough to arm the watch: $out"
  assert_contains "$out" "the quota floor only" "arming on a floor alone must say nothing switches on its own"
  run_seat "$HOME_DIR" "$FAKEBIN" retire >/dev/null

  # And one pass with a floor but no threshold still rests, and switches nothing.
  out=$(rest_beta)
  assert_contains "$out" "beta is resting" "the floor must run with no threshold configured"
  assert_grep "alpha" "$HOME_DIR/config/claude-seat" "with no threshold nothing may switch"
  pass "the quota floor can be armed and run on its own, with no auto-switch threshold"
}

test_status_and_list_tell_a_seat_held_out_by_hand_from_a_resting_one() {
  local out
  floor_case floor-reporting
  mkdir -p "$SEATS_DIR/personal"
  seat_logged_in "$SPEC_DIR" "$SEATS_DIR/alpha" "$SEATS_DIR/beta" "$SEATS_DIR/personal"
  run_seat "$HOME_DIR" "$FAKEBIN" auto-exclude personal >/dev/null
  rest_beta >/dev/null

  out=$(run_seat "$HOME_DIR" "$FAKEBIN" status)
  assert_contains "$out" "held out of automatic rotation by hand: personal" \
    "status must name the seat the operator withheld"
  assert_contains "$out" "quota floor: rest a seat at or below 5% left" \
    "status must print the floor's own settings"
  assert_contains "$out" "beta: seven_day 2% left, expected back 2026-10-09T11:00:00Z" \
    "status must name each resting seat, its reason, and when it is due back"

  out=$(run_seat "$HOME_DIR" "$FAKEBIN" list)
  printf '%s\n' "$out" | grep -q '^  personal.*held out of automatic rotation by hand$' ||
    fail "list must mark the hand-held seat as such: $out"
  printf '%s\n' "$out" | grep -q '^  beta.*resting below the quota floor: seven_day 2% left' ||
    fail "list must mark the resting seat with its reason: $out"
  printf '%s\n' "$out" | grep -q '^\* alpha' ||
    fail "list must still mark the active seat: $out"
  printf '%s\n' "$out" | grep '^\* alpha' | grep -q 'resting\|held out' &&
    fail "list must not mark a seat that is still in rotation: $out"
  pass "status and list tell a seat held out by hand from one the quota floor is resting"
}

test_the_floor_setter_warns_when_it_sits_at_or_above_the_switch_trigger() {
  local out
  rec=$(make_seat_case floor-warns)
  read_seat_case "$rec"
  run_seat "$HOME_DIR" "$FAKEBIN" threshold 15 >/dev/null

  out=$(run_seat "$HOME_DIR" "$FAKEBIN" floor 20)
  expect_code 0 "$?" "a floor above the trigger is a tuning choice, not an error: $out"
  assert_contains "$out" "warning: the floor is at or above the auto-switch trigger" \
    "the setter must warn when the active seat would rest before anything switched away from it"
  assert_grep "20" "$HOME_DIR/config/claude-seat-floor" "the warning must not block the setting"

  out=$(run_seat "$HOME_DIR" "$FAKEBIN" floor 5)
  case "$out" in
    *"at or above the auto-switch trigger"*) fail "a floor below the trigger must not warn: $out" ;;
  esac
  pass "the floor setter warns rather than refuses when it sits at or above the switch trigger"
}

test_resting_wake_returns_a_seat_early_and_the_next_pass_may_rest_it_again() {
  local out
  floor_case floor-wake-by-hand
  rest_beta >/dev/null

  out=$(run_seat "$HOME_DIR" "$FAKEBIN" resting wake beta)
  expect_code 0 "$?" "an operator must be able to return a resting seat by hand: $out"
  assert_contains "$out" "back in automatic rotation: beta" "the hand wake must be reported"
  assert_absent "$HOME_DIR/config/claude-seat-resting" "the record must no longer hold the seat"
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" switch --next)
  expect_code 0 "$?" "a seat woken by hand must be a rotation destination again: $out"

  # Temporary by construction: the next pass reads it again and rests it again.
  printf 'alpha\n' > "$HOME_DIR/config/claude-seat"
  out=$(rest_beta)
  assert_contains "$out" "beta is resting" "the next pass must rest a still-empty seat again"

  out=$(run_seat "$HOME_DIR" "$FAKEBIN" resting wake alpha)
  assert_contains "$out" "not resting: alpha" "waking a seat that is not resting must say so rather than fail"
  pass "resting wake returns a seat early and the next pass rests it again if it is still at or below the floor"
}

test_a_stop_policy_holds_dispatch_once_the_active_seat_is_at_the_floor() {
  local out
  floor_case floor-dispatch-hold
  run_seat "$HOME_DIR" "$FAKEBIN" extra-usage stop >/dev/null
  seat_windows_clear "$SPEC_DIR"
  seat_windows "$SPEC_DIR" "$SEATS_DIR/alpha" 60 2026-10-08T02:40:00Z 3 2026-10-14T21:00:00Z

  out=$(run_seat "$HOME_DIR" "$FAKEBIN" status)
  assert_contains "$out" "resolve the task brief with bin/fm-dispatch-resolve.sh" \
    "seat status points to configured task alternatives"
  assert_contains "$out" "new Claude dispatch: HELD" \
    "with a floor set, stop must hold at the floor rather than at nothing left: $out"
  assert_contains "$out" "at or below the 5% quota floor" "the hold must name the floor it is holding at"

  # Without a floor the same reading allows dispatch, because plan quota remains.
  run_seat "$HOME_DIR" "$FAKEBIN" floor off >/dev/null
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" status)
  assert_contains "$out" "new Claude dispatch: allowed" \
    "the floor is what moves the hold; without it the plan quota still allows dispatch: $out"
  pass "with a floor set, the stop policy holds new dispatch once the active seat is at or below it"
}

# Pipeline fixtures install only under the suite's scratch directory. No test
# reads or writes the installed machine-local wrapper or a real Claude profile.
install_pipeline_fixture() {
  PIPELINE_WRAPPER="$CASE_DIR/wrapper dir/claude"
  PIPELINE_NATIVE="$CASE_DIR/native claude"
  cat > "$PIPELINE_NATIVE" <<'SH'
#!/usr/bin/env bash
printf 'profile=%s\n' "${CLAUDE_CONFIG_DIR:-}"
printf 'arg=<%s>\n' "$@"
[ -z "${PIPELINE_TEST_STDIN:-}" ] || cat
if [ -n "${PIPELINE_TEST_READY:-}" ]; then
  printf '%s\n' "$$" > "$PIPELINE_TEST_READY"
  deadline=$((SECONDS + ${FM_TEST_STUB_MAX_BLOCK_SECONDS:-120}))
  while [ ! -e "$PIPELINE_TEST_RELEASE" ] && [ "$SECONDS" -lt "$deadline" ]; do sleep 0.1; done
  [ -e "$PIPELINE_TEST_RELEASE" ] || exit 124
fi
exit "${PIPELINE_TEST_EXIT:-0}"
SH
  chmod +x "$PIPELINE_NATIVE"
  run_seat "$HOME_DIR" "$FAKEBIN" pipeline-install --claude "$PIPELINE_NATIVE" \
    --destination "$PIPELINE_WRAPPER" >/dev/null || fail "fixture wrapper installation failed"
}

run_pipeline_fixture() {
  # Path overrides and profile inherited from a worker must not redirect the
  # wrapper's bound home. The explicit NM override remains independently set.
  FM_HOME="$CASE_DIR/wrong-home" FM_CONFIG_OVERRIDE="$CASE_DIR/wrong-config" \
    FM_STATE_OVERRIDE="$CASE_DIR/wrong-state" CLAUDE_CONFIG_DIR=/wrong/worker-seat \
    PATH="$FAKEBIN:$PATH" "$PIPELINE_WRAPPER" "$@"
}

# record_lead_ambient <profile>
# The runtime record bin/fm-lock.sh leaves for this home's lead, naming the
# profile its default-seat workers get.
record_lead_ambient() {
  printf '4242424\n' > "$HOME_DIR/state/.lock"
  printf 'pid=4242424\nprofile=%s\nambient=%s\n' "$SEATS_DIR/lead" "$1" > "$HOME_DIR/state/.lock-runtime"
}

test_pipeline_default_seat_matches_worker_profile() {
  local rec out ambient worker board fallback
  rec=$(make_seat_case pipeline-default); read_seat_case "$rec"
  ambient="$CASE_DIR/lead ambient"
  mkdir -p "$ambient" "$SEATS_DIR/lead"
  fallback="$CASE_DIR/installed default"
  mkdir -p "$fallback"
  SEAT_TEST_AMBIENT_CONFIG_DIR="$fallback" install_pipeline_fixture
  out=$(NM_CLAUDE_CONFIG_DIR='' run_pipeline_fixture 2>&1)
  expect_code 0 "$?" "no live lead must fall back rather than refuse: $out"
  assert_contains "$out" "profile=$fallback" "no live lead must use the installed default profile"
  assert_contains "$out" "using the wrapper's installed default profile $fallback" "the fallback must be named on stderr"
  assert_contains "$out" 'Restarting the lead records it' "the warning must say a lead restart records the profile"
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" status)
  assert_contains "$out" 'pipeline default-seat profile not recorded' "status must show the unrecorded default"
  assert_not_contains "$out" 'pipeline selection HELD' "an unrecorded default must not be held"
  printf '4242424\n' > "$HOME_DIR/state/.lock"
  printf 'pid=4242424\nprofile=%s\n' "$SEATS_DIR/lead" > "$HOME_DIR/state/.lock-runtime"
  out=$(NM_CLAUDE_CONFIG_DIR='' run_pipeline_fixture 2>&1)
  expect_code 0 "$?" "an old-format lead record must fall back rather than refuse: $out"
  assert_contains "$out" "profile=$fallback" "an old-format lead record must use the installed default profile"
  assert_contains "$out" "using the wrapper's installed default profile" "the old-format fallback must warn"
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" pipeline-move)
  expect_code 0 "$?" "move must succeed on a healthy unrecorded default: $out"
  [ ! -s "$HOME_DIR/config/claude-seat" ] || fail "move must not rotate a healthy default seat whose profile is unrecorded"
  printf '5\n' > "$HOME_DIR/config/claude-seat-floor"
  printf '{"schemaVersion":1,"seats":{"default":{"since":1,"provisional":false}}}\n' > "$HOME_DIR/config/claude-seat-resting"
  out=$(NM_CLAUDE_CONFIG_DIR='' run_pipeline_fixture 2>&1)
  expect_code 75 "$?" "a resting default seat must hold on the fallback too"
  assert_not_contains "$out" 'profile=' "a resting fallback must start no agent"
  rm -f "$HOME_DIR/config/claude-seat-resting" "$HOME_DIR/config/claude-seat-floor"
  seat_logged_in "$SPEC_DIR" "$fallback"
  printf '%s\t0\n' "$fallback" > "$SPEC_DIR/remaining_map"
  printf 'stop\n' > "$HOME_DIR/config/claude-seat-extra-usage"
  out=$(NM_CLAUDE_CONFIG_DIR='' run_pipeline_fixture 2>&1)
  expect_code 75 "$?" "stop must gate the fallback profile"
  assert_contains "$out" 'pipeline seat default has no plan quota left' "stop must read the fallback profile"
  rm -f "$HOME_DIR/config/claude-seat-extra-usage" "$SPEC_DIR/remaining_map"
  record_lead_ambient "$ambient"
  worker=$(SEAT_TEST_AMBIENT_CONFIG_DIR="$ambient" run_seat "$HOME_DIR" "$FAKEBIN" status)
  assert_contains "$worker" "active profile: $ambient" "precondition: a default-seat worker spawned by the lead gets its ambient"
  out=$(NM_CLAUDE_CONFIG_DIR='' run_pipeline_fixture 2>&1)
  assert_contains "$out" "profile=$ambient" "a default-seat pipeline agent must land on the worker's profile"
  assert_not_contains "$out" 'installed default profile' "a recorded default must not warn about the fallback"
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" status)
  assert_contains "$out" 'pipeline seat for next managed launch: default (follows active seat)' "status must name the default pipeline seat"
  assert_not_contains "$out" 'pipeline selection HELD' "a recorded default must not be held"
  board=$(FM_HOME="$HOME_DIR" FM_CONFIG_OVERRIDE="$HOME_DIR/config" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    NM_CLAUDE_CONFIG_DIR='' FM_SEAT_BOARD_CACHE_DIR="$CASE_DIR/board-cache" \
    "$ROOT/bin/fm-seat-board.sh" json --cached-only)
  printf '%s' "$board" | jq -e --arg p "$ambient" '.pipeline.seat == "default" and .pipeline.profile == $p and (.pipeline | has("installation") | not)' >/dev/null ||
    fail "board must read the same default profile: $board"
  seat_logged_in "$SPEC_DIR" "$ambient"
  printf '%s\t0\n' "$ambient" > "$SPEC_DIR/remaining_map"
  printf 'stop\n' > "$HOME_DIR/config/claude-seat-extra-usage"
  out=$(NM_CLAUDE_CONFIG_DIR='' run_pipeline_fixture 2>&1)
  expect_code 75 "$?" "stop must read the default seat's recorded profile"
  assert_contains "$out" 'HELD pipeline-agent launch on seat default: pipeline seat default has no plan quota left' "refusal must name the pipeline seat"
  assert_contains "$out" 'no new Claude pipeline agent is started' "refusal must name the pipeline-agent launch"
  printf '%s\t80\n' "$ambient" > "$SPEC_DIR/remaining_map"
  out=$(NM_CLAUDE_CONFIG_DIR='' run_pipeline_fixture)
  expect_code 0 "$?" "quota left on the recorded default profile must launch: $out"
  printf '5\n' > "$HOME_DIR/config/claude-seat-floor"
  printf '{"schemaVersion":1,"seats":{"default":{"since":1,"provisional":false}}}\n' > "$HOME_DIR/config/claude-seat-resting"
  out=$(NM_CLAUDE_CONFIG_DIR='' run_pipeline_fixture 2>&1)
  expect_code 75 "$?" "a resting default seat must never launch"
  assert_contains "$out" 'resting below the quota floor' "rest hold must apply to the default seat"
  pass "a default-seat pipeline agent uses the lead's recorded worker profile, else the installed default, for launch, display, rest and extra usage"
}

test_pipeline_install_check_and_streams() {
  local rec out rc before
  rec=$(make_seat_case pipeline-streams); read_seat_case "$rec"
  mkdir -p "$SEATS_DIR/alpha"
  printf 'alpha\n' > "$HOME_DIR/config/claude-seat"
  install_pipeline_fixture
  before=$(cksum "$PIPELINE_WRAPPER")
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" pipeline-check --claude "$PIPELINE_NATIVE" --destination "$PIPELINE_WRAPPER")
  expect_code 0 "$?" "scratch wrapper must match its template: $out"
  [ "$before" = "$(cksum "$PIPELINE_WRAPPER")" ] || fail "check must not write the wrapper"
  out=$(printf 'stdin payload\n' | NM_CLAUDE_CONFIG_DIR='' PIPELINE_TEST_STDIN=1 PIPELINE_TEST_EXIT=17 \
    run_pipeline_fixture 'two words' "literal \$value" '--print' 2>&1)
  rc=$?
  expect_code 17 "$rc" "native exit status must survive the wrapper"
  assert_contains "$out" "profile=$SEATS_DIR/alpha" "launch must use the bound home, not inherited overrides"
  assert_contains "$out" 'arg=<two words>' "argument boundaries must survive"
  # shellcheck disable=SC2016 # Deliberately literal argument.
  assert_contains "$out" 'arg=<literal $value>' "literal arguments must survive"
  assert_contains "$out" 'stdin payload' "stdin must survive probes and exec"
  assert_absent "$SPEC_DIR/calls" "an unset extra-usage policy must not read quota"
  printf '\n# changed\n' >> "$PIPELINE_WRAPPER"
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" pipeline-check --claude "$PIPELINE_NATIVE" --destination "$PIPELINE_WRAPPER")
  expect_code 75 "$?" "check must refuse a modified wrapper"
  pass "pipeline scratch install/check preserves argv, stdin, and native exit status"
}

test_pipeline_rereads_active_and_validates_override() {
  local rec out
  rec=$(make_seat_case pipeline-switch); read_seat_case "$rec"
  mkdir -p "$SEATS_DIR/alpha" "$SEATS_DIR/beta"
  printf 'alpha\n' > "$HOME_DIR/config/claude-seat"
  install_pipeline_fixture
  out=$(NM_CLAUDE_CONFIG_DIR='' run_pipeline_fixture)
  assert_contains "$out" "profile=$SEATS_DIR/alpha" "first launch must use alpha"
  printf 'beta\n' > "$HOME_DIR/config/claude-seat"
  out=$(NM_CLAUDE_CONFIG_DIR='' run_pipeline_fixture)
  assert_contains "$out" "profile=$SEATS_DIR/beta" "same installed wrapper must re-read active seat"
  out=$(NM_CLAUDE_CONFIG_DIR="$SEATS_DIR/alpha" run_pipeline_fixture)
  assert_contains "$out" "profile=$SEATS_DIR/alpha" "a managed override must still win"
  out=$(NM_CLAUDE_CONFIG_DIR="$CASE_DIR/unmanaged" run_pipeline_fixture 2>&1)
  expect_code 75 "$?" "unmanaged override must refuse instead of bypassing guards"
  assert_not_contains "$out" 'profile=' "a refused launch must not start Claude"
  printf 'missing\n' > "$HOME_DIR/config/claude-seat"
  out=$(NM_CLAUDE_CONFIG_DIR='' run_pipeline_fixture 2>&1)
  expect_code 75 "$?" "missing active directory must refuse instead of falling back"
  assert_contains "$out" 'no fallback' "missing-directory refusal must explain the boundary"
  rm "$HOME_DIR/config/claude-seat"
  record_lead_ambient ''
  out=$(NM_CLAUDE_CONFIG_DIR='' run_pipeline_fixture)
  assert_contains "$out" 'profile=' "default selection must launch"
  assert_not_contains "$out" '/wrong/worker-seat' "default must not inherit the worker's profile"
  pass "pipeline launches follow each switch and guard managed overrides and missing profiles"
}

test_pipeline_never_launches_excluded_or_resting() {
  local rec out mode
  rec=$(make_seat_case pipeline-withheld); read_seat_case "$rec"
  mkdir -p "$SEATS_DIR/alpha" "$SEATS_DIR/beta"
  printf 'alpha\n' > "$HOME_DIR/config/claude-seat"
  printf 'alpha\n' > "$HOME_DIR/config/claude-seat-auto-exclude"
  install_pipeline_fixture
  for mode in active override; do
    if [ "$mode" = override ]; then printf 'beta\n' > "$HOME_DIR/config/claude-seat"; fi
    out=$(NM_CLAUDE_CONFIG_DIR="$([ "$mode" != override ] || printf '%s' "$SEATS_DIR/alpha")" run_pipeline_fixture 2>&1)
    expect_code 75 "$?" "an excluded $mode seat must never launch"
    assert_contains "$out" 'manually excluded' "hold must explain manual exclusion"
    assert_not_contains "$out" 'profile=' "excluded seat must not start Claude"
  done
  rm "$HOME_DIR/config/claude-seat-auto-exclude"
  printf 'alpha\n' > "$HOME_DIR/config/claude-seat"
  printf '5\n' > "$HOME_DIR/config/claude-seat-floor"
  printf '{"schemaVersion":1,"seats":{"alpha":{"since":1,"provisional":false}}}\n' > "$HOME_DIR/config/claude-seat-resting"
  out=$(NM_CLAUDE_CONFIG_DIR='' run_pipeline_fixture 2>&1)
  expect_code 75 "$?" "a resting active seat must never launch"
  assert_contains "$out" 'resting below the quota floor' "rest hold must use the existing record"
  printf 'beta\n' > "$HOME_DIR/config/claude-seat"
  out=$(NM_CLAUDE_CONFIG_DIR="$SEATS_DIR/alpha" run_pipeline_fixture 2>&1)
  expect_code 75 "$?" "an override must not bypass rest"
  # Provisional seats are candidates again under the landed resting contract.
  printf '{"schemaVersion":1,"seats":{"alpha":{"since":1,"provisional":true}}}\n' > "$HOME_DIR/config/claude-seat-resting"
  out=$(NM_CLAUDE_CONFIG_DIR="$SEATS_DIR/alpha" run_pipeline_fixture)
  expect_code 0 "$?" "provisional recovery must use the existing resting verdict: $out"
  pass "pipeline launch guards apply to active and override seats and honor provisional recovery"
}

test_pipeline_extra_usage_reads_selected_profile() {
  local rec out
  rec=$(make_seat_case pipeline-policy); read_seat_case "$rec"
  mkdir -p "$SEATS_DIR/alpha" "$SEATS_DIR/beta"
  printf 'alpha\n' > "$HOME_DIR/config/claude-seat"
  seat_logged_in "$SPEC_DIR" "$SEATS_DIR/alpha" "$SEATS_DIR/beta"
  printf '%s\t80\n%s\t0\n' "$SEATS_DIR/alpha" "$SEATS_DIR/beta" > "$SPEC_DIR/remaining_map"
  printf 'stop\n' > "$HOME_DIR/config/claude-seat-extra-usage"
  install_pipeline_fixture
  out=$(NM_CLAUDE_CONFIG_DIR="$SEATS_DIR/beta" run_pipeline_fixture 2>&1)
  expect_code 75 "$?" "stop must read exhausted override instead of healthy active seat"
  assert_contains "$out" 'no plan quota left' "stop refusal must name exhausted quota"
  assert_not_contains "$out" 'profile=' "stop must start no agent"
  printf '%s\t0\n%s\t0\n' "$SEATS_DIR/alpha" "$SEATS_DIR/beta" > "$SPEC_DIR/remaining_map"
  out=$(NM_CLAUDE_CONFIG_DIR='' run_pipeline_fixture 2>&1)
  expect_code 75 "$?" "stop must refuse when every seat is exhausted"
  printf 'allow 10\n' > "$HOME_DIR/config/claude-seat-extra-usage"
  printf '%s\t5\n' "$SEATS_DIR/beta" > "$SPEC_DIR/extra_map"
  out=$(NM_CLAUDE_CONFIG_DIR="$SEATS_DIR/beta" run_pipeline_fixture)
  expect_code 0 "$?" "allow policy below cap must still work: $out"
  printf '%s\t10\n' "$SEATS_DIR/beta" > "$SPEC_DIR/extra_map"
  out=$(NM_CLAUDE_CONFIG_DIR="$SEATS_DIR/beta" run_pipeline_fixture 2>&1)
  expect_code 75 "$?" "allow policy must hold at cap"
  printf '%s\n' "$SEATS_DIR/beta" > "$SPEC_DIR/unreadable_quota"
  out=$(NM_CLAUDE_CONFIG_DIR="$SEATS_DIR/beta" run_pipeline_fixture 2>&1)
  expect_code 75 "$?" "unreadable quota must fail closed under policy"
  assert_contains "$out" 'could not be read' "unreadable refusal must be clear"
  rm "$SPEC_DIR/unreadable_quota"
  seat_expired_refreshable "$SPEC_DIR" "$SEATS_DIR/beta"
  out=$(NM_CLAUDE_CONFIG_DIR="$SEATS_DIR/beta" run_pipeline_fixture)
  expect_code 0 "$?" "landed renewable-token exception must still permit launch: $out"
  pass "pipeline policy reads the selected profile and shares stop, cap, unreadable, and renewable verdicts"
}

test_pipeline_live_warning_and_move_leave_agent_running() {
  local rec out pid i ready release board record stale warning
  rec=$(make_seat_case pipeline-live); read_seat_case "$rec"
  mkdir -p "$SEATS_DIR/alpha" "$SEATS_DIR/beta"
  seat_logged_in "$SPEC_DIR" "$SEATS_DIR/alpha" "$SEATS_DIR/beta"
  printf 'alpha\n' > "$HOME_DIR/config/claude-seat"
  printf '5\n' > "$HOME_DIR/config/claude-seat-floor"
  install_pipeline_fixture
  ready="$CASE_DIR/ready"; release="$CASE_DIR/release"
  NM_CLAUDE_CONFIG_DIR='' PIPELINE_TEST_READY="$ready" PIPELINE_TEST_RELEASE="$release" \
    run_pipeline_fixture > "$CASE_DIR/agent-output" 2>&1 &
  pid=$!
  for ((i=0; i<200; i++)); do [ -s "$ready" ] && break; sleep 0.1; done
  [ -s "$ready" ] || { touch "$release"; wait "$pid"; fail "live fixture did not launch"; }
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" status)
  assert_contains "$out" 'live pipeline agent: pid=' "status must show the live agent"
  assert_contains "$out" 'seat=alpha' "status must show the launched seat"
  seat_windows "$SPEC_DIR" "$SEATS_DIR/alpha" 3 2026-10-10T00:00:00Z 60 2026-10-14T00:00:00Z
  seat_windows "$SPEC_DIR" "$SEATS_DIR/beta" 80 2026-10-10T00:00:00Z 80 2026-10-14T00:00:00Z
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" auto)
  warning='pipeline agent is still running on resting seat alpha'
  assert_contains "$out" "$warning" "resting a live pipeline seat must warn"
  assert_contains "$out" 'pipeline-move' "warning must offer a one-command move"
  assert_contains "$out" 'approval because it discards in-flight work' "warning must distinguish whole-run cancellation"
  kill -0 "$(cat "$ready")" || fail "rest warning must never kill the live agent"
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" auto)
  assert_not_contains "$out" "$warning" "steady rest must not warn twice"
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" pipeline-move)
  expect_code 0 "$?" "move must find beta through existing rotation: $out"
  assert_contains "$out" 'subsequent managed pipeline launches follow active seat beta' "move must select beta"
  kill -0 "$(cat "$ready")" || fail "move must leave the original agent running"
  out=$(NM_CLAUDE_CONFIG_DIR='' run_pipeline_fixture)
  assert_contains "$out" "profile=$SEATS_DIR/beta" "next launch after move must use beta"
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" pipeline-move)
  assert_grep beta "$HOME_DIR/config/claude-seat" "move must keep an already eligible active seat"
  board=$(FM_HOME="$HOME_DIR" FM_CONFIG_OVERRIDE="$HOME_DIR/config" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    NM_CLAUDE_CONFIG_DIR='' FM_SEAT_BOARD_CACHE_DIR="$CASE_DIR/board-cache" \
    "$ROOT/bin/fm-seat-board.sh" json --cached-only)
  printf '%s' "$board" | jq -e '.pipeline.seat == "beta" and (.pipeline.liveAgents | any(.seat == "alpha"))' >/dev/null ||
    fail "board must distinguish next seat from live pipeline seat: $board"
  # A reused PID with a different kernel start stamp is not the original agent.
  record=$(find "$HOME_DIR/state/claude-pipeline" -name '*.json' | head -1)
  stale="$HOME_DIR/state/claude-pipeline/stale.json"
  jq --argjson pid "$(cat "$ready")" '.pid=$pid | .started="old process" | .seat="stale-seat"' "$record" > "$stale"
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" status)
  assert_not_contains "$out" 'seat=stale-seat' "reused PID must not be reported live"
  # A separate rest entry must warn again even for the same running agent.
  printf '{"schemaVersion":1,"seats":{"alpha":{"since":2,"provisional":false}}}\n' > "$HOME_DIR/config/claude-seat-resting"
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" auto)
  assert_contains "$out" "$warning" "a new resting entry must re-arm the warning"
  touch "$release"
  wait "$pid" || fail "original agent must finish normally"
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" status)
  assert_not_contains "$out" 'live pipeline agent: pid=' "completed agents must not appear live"
  pass "pipeline watch warns once per rest, move affects subsequent launches only, and live PID stamps stay honest"
}

test_pipeline_move_keeps_a_healthy_seat_with_a_malformed_setting() {
  local rec out
  rec=$(make_seat_case pipeline-move-malformed); read_seat_case "$rec"
  mkdir -p "$SEATS_DIR/alpha"
  seat_logged_in "$SPEC_DIR" "$SEATS_DIR/alpha"
  printf 'not a seat!\n' > "$HOME_DIR/config/claude-seat"
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" pipeline-move)
  expect_code 1 "$?" "a malformed setting must be reported as a hold: $out"
  assert_contains "$out" 'configured seat is malformed; active seat kept' "move must name the hold it cannot rotate away"
  assert_grep 'not a seat!' "$HOME_DIR/config/claude-seat" "move must not rotate a healthy seat for a malformed setting"
  printf 'ghost\n' > "$HOME_DIR/config/claude-seat"
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" pipeline-move)
  expect_code 0 "$?" "a missing seat directory must still rotate: $out"
  assert_contains "$out" 'follow active seat alpha' "a missing seat directory must rotate to an eligible seat"
  pass "pipeline-move rotates only a resting, excluded or missing seat and reports any other hold"
}

# Exercise the real dispatch shell API with isolated quota documents and cache
# artifacts; the Python fixture never imports implementation modules.
python3 "$ROOT/tests/fm-seat-quota-cache.py" "$ROOT" "$TMP_ROOT" || fail "shared dispatch quota cache regressions"

test_pipeline_install_check_and_streams
test_pipeline_rereads_active_and_validates_override
test_pipeline_default_seat_matches_worker_profile
test_pipeline_never_launches_excluded_or_resting
test_pipeline_extra_usage_reads_selected_profile
test_pipeline_live_warning_and_move_leave_agent_running
test_pipeline_move_keeps_a_healthy_seat_with_a_malformed_setting

test_codex_file_alias_resolves_one_authoritative_home
test_codex_inheritance_has_provider_scoped_optouts_and_stays_local
test_codex_registration_keeps_one_auth_store_and_quotes_login
test_codex_rotation_skips_aliases_and_uses_native_account_quota
test_codex_invalid_login_and_missing_selected_home_fail_closed
test_codex_automatic_switch_propagates_provider_and_watch_binding

# --- depletion: no switch lands on a seat with no quota left ------------------
# The incident these cover: the automatic Codex switch moved new workers onto a
# home that was already empty, then moved them back, because nothing but the
# optional destination minimum ever read a candidate's quota.

# make_dual_quota_fake <fakebin> <spec>
# One quota-axi answering BOTH vendors, so a case can prove where work is routed
# when a whole vendor is empty. A Claude read is keyed on CLAUDE_CONFIG_DIR and
# a Codex read on CODEX_HOME, each through "<key><TAB><percent><TAB><resetsAt>"
# rows in <spec>/claude_map and <spec>/codex_map. A key with no row reports its
# provider unavailable, which is the no-verdict shape nothing may guess at.
make_dual_quota_fake() {
  local fakebin=$1 spec=$2
  mkdir -p "$spec"
  : > "$spec/claude_map"
  : > "$spec/codex_map"
  cat > "$fakebin/quota-axi" <<SH
#!/usr/bin/env bash
set -u
spec="$spec"
provider=claude
while [ \$# -gt 0 ]; do
  case "\$1" in --provider) provider=\${2-claude}; shift ;; esac
  shift
done
if [ "\$provider" = codex ]; then
  key=\${CODEX_HOME:-}
  map="\$spec/codex_map"
else
  key=\${CLAUDE_CONFIG_DIR:-}
  map="\$spec/claude_map"
fi
printf '%s\t%s\n' "\$provider" "\$key" >> "\$spec/calls"
row=\$(awk -F'\t' -v k="\$key" '\$1 == k { print \$2 "\t" \$3; exit }' "\$map")
if [ -z "\$row" ]; then
  jq -nc --arg p "\$provider" '{generatedAt:"2026-01-01T00:00:00Z",schemaVersion:5,providers:[
    {provider:\$p,label:\$p,source:"unavailable",windows:[],
     state:{status:"error",error:"keychain_unreachable"},
     attempts:[{source:"oauth-file",status:"skipped",error:"credentials_missing"},
               {source:"keychain",status:"skipped",error:"keychain_unreachable"}],
     quotaSemantics:{status:"unknown",effectiveAvailability:[]}}]}'
  exit 1
fi
IFS=\$'\t' read -r pct reset <<< "\$row"
jq -nc --arg p "\$provider" --argjson pct "\$pct" --arg reset "\$reset" '
  {generatedAt:"2026-01-01T00:00:00Z",schemaVersion:5,providers:[
    {provider:\$p,label:\$p,source:"oauth",account:{email:"seat@example.test"},
     state:{authStatus:"valid"},
     windows:[{id:"seven_day",kind:"weekly",label:"week",percentUsed:(100 - \$pct),
               percentRemaining:\$pct,resetsAt:\$reset,windowSeconds:604800}],
     quotaSemantics:{status:"known",effectiveAvailability:[
       {scope:"all_models",status:"known",effectivePercentRemaining:\$pct,
        limitingWindowIds:["seven_day"],runway:{status:"through_reset"}}]}}]}'
exit 0
SH
  chmod +x "$fakebin/quota-axi"
}

# dual_quota <spec> <provider> <key> <percent> <resetsAt>
dual_quota() {
  local spec=$1 provider=$2
  shift 2
  printf '%s\t%s\t%s\n' "$@" >> "$spec/${provider}_map"
}

test_no_switch_lands_on_a_seat_whose_quota_is_used_up() {
  local rec out
  rec=$(make_seat_case used-up-destination)
  read_seat_case "$rec"
  mkdir -p "$SEATS_DIR/alpha" "$SEATS_DIR/beta" "$SEATS_DIR/gamma"
  seat_logged_in "$SPEC_DIR" "$SEATS_DIR/alpha" "$SEATS_DIR/beta" "$SEATS_DIR/gamma"
  printf 'alpha\n' > "$HOME_DIR/config/claude-seat"
  # No destination minimum is configured. That is the home the empty-seat switch
  # happened in: before this gate existed, nothing read a candidate's quota at
  # all unless that optional setting was present.
  seat_windows "$SPEC_DIR" "$SEATS_DIR/alpha" 40 2026-10-15T02:00:00Z 40 2026-10-18T02:00:00Z
  seat_windows "$SPEC_DIR" "$SEATS_DIR/beta" 0 2026-10-15T03:00:00Z 0 2026-10-20T09:00:00Z
  seat_windows "$SPEC_DIR" "$SEATS_DIR/gamma" 55 2026-10-15T04:00:00Z 70 2026-10-19T04:00:00Z

  out=$(run_seat "$HOME_DIR" "$FAKEBIN" switch --next)
  expect_code 0 "$?" "rotation must pass the empty seat and take the one with quota: $out"
  assert_contains "$out" "seat beta: skipped, its quota is used up" \
    "the skip must say the seat is empty rather than that it failed some setting"
  assert_contains "$out" "comes back at 2026-10-20T09:00:00Z" \
    "the skip must name when the empty seat returns"
  assert_grep gamma "$HOME_DIR/config/claude-seat" "rotation must land on the seat with headroom"

  out=$(run_seat "$HOME_DIR" "$FAKEBIN" switch beta)
  expect_code 1 "$?" "a switch by hand must refuse an empty seat too: $out"
  assert_contains "$out" "comes back at 2026-10-20T09:00:00Z" "the refusal must name the reset time"
  assert_contains "$out" "re-run with --force" "the refusal must name the override"
  assert_grep gamma "$HOME_DIR/config/claude-seat" "a refused switch must leave the active seat alone"

  out=$(run_seat "$HOME_DIR" "$FAKEBIN" switch beta --force)
  expect_code 0 "$?" "--force must stay the explicit override: $out"
  assert_grep beta "$HOME_DIR/config/claude-seat" "a forced switch must still move the seat"
  pass "no switch, automatic or by hand, lands on a seat with no quota left, and --force still crosses it"
}

test_a_codex_switch_refuses_an_empty_home_exactly_as_a_claude_switch_does() {
  local out
  make_codex_seat_case codex-used-up
  codex_quota_fixture "$SEATS_DIR/max" 6
  codex_quota_fixture "$SEATS_DIR/max2" 0 valid 2026-10-20T00:00:00Z
  printf 'max\n' > "$HOME_DIR/config/codex-seat"

  out=$(run_seat "$HOME_DIR" "$FAKEBIN" --provider codex switch max2)
  expect_code 1 "$?" "a Codex switch must refuse a home with no quota left: $out"
  assert_contains "$out" "comes back at 2026-10-20T00:00:00Z" \
    "the Codex refusal must name the reset time, as the Claude one does"
  assert_grep max "$HOME_DIR/config/codex-seat" "a refused Codex switch must leave the active home alone"

  out=$(run_seat "$HOME_DIR" "$FAKEBIN" --provider codex switch --next)
  expect_code 1 "$?" "Codex rotation must refuse when its only candidate is empty: $out"
  assert_contains "$out" "seat max2: skipped, its quota is used up" \
    "Codex rotation must give the same reason the Claude one does"
  assert_grep max "$HOME_DIR/config/codex-seat" "a refused Codex rotation must change nothing"
  pass "a Codex switch refuses an empty home and names its reset exactly as a Claude switch does"
}

test_an_empty_seat_returns_to_rotation_on_its_own_once_a_read_shows_headroom() {
  local rec out
  rec=$(make_seat_case empty-seat-returns)
  read_seat_case "$rec"
  mkdir -p "$SEATS_DIR/alpha" "$SEATS_DIR/beta"
  seat_logged_in "$SPEC_DIR" "$SEATS_DIR/alpha" "$SEATS_DIR/beta"
  printf 'alpha\n' > "$HOME_DIR/config/claude-seat"
  seat_windows "$SPEC_DIR" "$SEATS_DIR/alpha" 3 2026-10-15T02:00:00Z 3 2026-10-18T02:00:00Z
  seat_windows "$SPEC_DIR" "$SEATS_DIR/beta" 0 2026-10-15T03:00:00Z 0 2026-10-16T09:00:00Z

  out=$(run_seat "$HOME_DIR" "$FAKEBIN" switch --next)
  expect_code 1 "$?" "the only candidate being empty must refuse rather than switch: $out"
  assert_grep alpha "$HOME_DIR/config/claude-seat" "a refused rotation must leave the active seat alone"
  assert_absent "$HOME_DIR/config/claude-seat-resting" \
    "holding an empty seat back must record nothing that would need a re-add"

  # beta's week resets. Nothing is re-added, re-included, or woken by hand: the
  # next read is the whole of it.
  seat_windows_clear "$SPEC_DIR"
  seat_windows "$SPEC_DIR" "$SEATS_DIR/alpha" 3 2026-10-15T02:00:00Z 3 2026-10-18T02:00:00Z
  seat_windows "$SPEC_DIR" "$SEATS_DIR/beta" 90 2026-10-16T10:00:00Z 90 2026-10-23T09:00:00Z
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" switch --next)
  expect_code 0 "$?" "a seat whose quota came back must be a destination again with nothing re-added: $out"
  assert_grep beta "$HOME_DIR/config/claude-seat" "the recovered seat must become the active seat"
  pass "a seat held back for having no quota returns to rotation on its own, with no re-add"
}

test_the_watch_refuses_to_flip_between_empty_seats_and_says_where_work_goes_once() {
  local rec out case_dir home claude_seats codex_seats fakebin spec
  case_dir="$TMP_ROOT/all-codex-empty"
  home="$case_dir/home"
  claude_seats="$case_dir/claude-seats"
  codex_seats="$case_dir/codex-seats"
  spec="$case_dir/quota-spec"
  mkdir -p "$home/config" "$home/state" "$home/data" \
    "$claude_seats/seat-max" "$codex_seats/codex-max" "$codex_seats/codex-max2"
  : > "$codex_seats/codex-max/auth.json"
  : > "$codex_seats/codex-max2/auth.json"
  fakebin=$(fm_fakebin "$case_dir/fake")
  make_dual_quota_fake "$fakebin" "$spec"
  printf '%s\n' "$claude_seats" > "$home/config/claude-seats-root"
  printf '%s\n' "$codex_seats" > "$home/config/codex-seats-root"
  printf 'codex-max\n' > "$home/config/codex-seat"
  printf 'seat-max\n' > "$home/config/claude-seat"
  printf '10\n' > "$home/config/codex-seat-threshold"
  # Exactly the fleet state that flipped: both Codex homes empty, while the
  # Claude seat's week has replenished.
  dual_quota "$spec" codex "$codex_seats/codex-max" 0 2026-10-19T00:00:00Z
  dual_quota "$spec" codex "$codex_seats/codex-max2" 0 2026-10-20T00:00:00Z
  dual_quota "$spec" claude "$claude_seats/seat-max" 92 2026-10-21T00:00:00Z

  out=$(run_seat "$home" "$fakebin" --provider codex auto)
  expect_code 0 "$?" "a pass with every seat empty must report rather than fail: $out"
  assert_contains "$out" "all Codex seats are out of quota" "the pass must say the whole vendor is empty"
  assert_contains "$out" "codex-max until 2026-10-19T00:00:00Z" "each empty seat's reset must be named"
  assert_contains "$out" "codex-max2 until 2026-10-20T00:00:00Z" "the second seat's reset must be named too"
  assert_contains "$out" "new work routes to Claude seat seat-max" \
    "the pass must name where new work goes instead"
  assert_contains "$out" "92% left" "the routing line must carry the headroom it found"
  assert_grep codex-max "$home/config/codex-seat" "nothing may move while every seat is empty"

  out=$(run_seat "$home" "$fakebin" --provider codex auto)
  [ -z "$out" ] || fail "the same unchanged depletion must not report again on the next poll: $out"
  assert_grep codex-max "$home/config/codex-seat" "a repeat poll must still move nothing"
  pass "with every seat of a vendor empty the watch moves nothing and says where work goes once"
}

test_the_watch_reports_a_vendor_draining_empty_after_its_shortfall_was_reported() {
  local out case_dir home claude_seats codex_seats fakebin spec
  case_dir="$TMP_ROOT/codex-drains-empty"
  home="$case_dir/home"
  claude_seats="$case_dir/claude-seats"
  codex_seats="$case_dir/codex-seats"
  spec="$case_dir/quota-spec"
  mkdir -p "$home/config" "$home/state" "$home/data" \
    "$claude_seats/seat-b" "$claude_seats/seat-max" "$codex_seats/codex-max" "$codex_seats/codex-max2"
  : > "$codex_seats/codex-max/auth.json"
  : > "$codex_seats/codex-max2/auth.json"
  fakebin=$(fm_fakebin "$case_dir/fake")
  make_dual_quota_fake "$fakebin" "$spec"
  printf '%s\n' "$claude_seats" > "$home/config/claude-seats-root"
  printf '%s\n' "$codex_seats" > "$home/config/codex-seats-root"
  printf 'codex-max\n' > "$home/config/codex-seat"
  printf 'seat-b\n' > "$home/config/claude-seat"
  printf '10\n' > "$home/config/codex-seat-threshold"
  # The incident's own order: the active home still has a little left when its
  # only candidate is already empty.
  dual_quota "$spec" codex "$codex_seats/codex-max" 6 2026-10-19T00:00:00Z
  dual_quota "$spec" codex "$codex_seats/codex-max2" 0 2026-10-20T00:00:00Z
  dual_quota "$spec" claude "$claude_seats/seat-b" 0 2026-10-16T00:00:00Z
  dual_quota "$spec" claude "$claude_seats/seat-max" 92 2026-10-21T00:00:00Z

  out=$(run_seat "$home" "$fakebin" --provider codex auto)
  expect_code 0 "$?" "a crossing with nowhere to go must report rather than fail: $out"
  assert_contains "$out" "no seat has enough headroom" "the first pass reports the shortfall"
  assert_grep codex-max "$home/config/codex-seat" "nothing may move onto the empty home"

  : > "$spec/codex_map"
  dual_quota "$spec" codex "$codex_seats/codex-max" 0 2026-10-19T00:00:00Z
  dual_quota "$spec" codex "$codex_seats/codex-max2" 0 2026-10-20T00:00:00Z
  out=$(run_seat "$home" "$fakebin" --provider codex auto)
  expect_code 0 "$?" "the drained pass must report rather than fail: $out"
  assert_contains "$out" "all Codex seats are out of quota" \
    "the active home draining empty must still be reported as the whole vendor empty"
  assert_contains "$out" "codex-max until 2026-10-19T00:00:00Z" "each empty seat's reset must be named"
  assert_contains "$out" "once it moves to seat seat-max" \
    "with the other vendor's active seat empty the line must say a switch is needed"
  assert_contains "$out" "--provider claude switch seat-max" "the line must name the switch that routes the work"
  assert_grep codex-max "$home/config/codex-seat" "nothing may move while every seat is empty"

  out=$(run_seat "$home" "$fakebin" --provider codex auto)
  [ -z "$out" ] || fail "the same unchanged depletion must not report again on the next poll: $out"
  pass "a vendor that drains empty after its shortfall was reported is still reported once, with its routing"
}

test_a_paid_overflow_seat_still_takes_work_while_a_stop_policy_refuses_it() {
  local rec out
  rec=$(make_seat_case dry-vs-extra-usage)
  read_seat_case "$rec"
  mkdir -p "$SEATS_DIR/alpha" "$SEATS_DIR/beta"
  seat_logged_in "$SPEC_DIR" "$SEATS_DIR/alpha" "$SEATS_DIR/beta"
  printf 'alpha\n' > "$HOME_DIR/config/claude-seat"
  # beta's plan quota is gone, which is exactly the state an `allow <usd>`
  # policy is configured to keep working through.
  seat_remaining "$SPEC_DIR" "$SEATS_DIR/alpha" 40
  seat_remaining "$SPEC_DIR" "$SEATS_DIR/beta" 0
  seat_extra_spend "$SPEC_DIR" "$SEATS_DIR/beta" 10

  # With no policy configured the empty seat is refused, which is the behaviour
  # the depleted rule exists for.
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" switch beta)
  expect_code 1 "$?" "with no extra-usage policy an empty seat must still be refused: $out"
  assert_contains "$out" "quota is used up" "the refusal must say the plan quota is gone"
  assert_grep alpha "$HOME_DIR/config/claude-seat" "a refused switch must move nothing"

  # `allow <usd>` under its cap: docs/configuration.md promises dispatch
  # continues in exactly this state, so the empty-seat rule must yield to it.
  run_seat "$HOME_DIR" "$FAKEBIN" extra-usage allow 25 >/dev/null
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" switch beta)
  expect_code 0 "$?" "paid extra usage under its cap must keep an empty seat usable: $out"
  assert_grep beta "$HOME_DIR/config/claude-seat" "the switch must land on the covered seat"

  # Spend at the cap is no longer covered, so the seat is empty again.
  printf '%s\n' alpha > "$HOME_DIR/config/claude-seat"
  printf '%s\t25\n' "$SEATS_DIR/beta" > "$SPEC_DIR/extra_map"
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" switch beta)
  expect_code 1 "$?" "spend at the cap must stop covering the empty seat: $out"
  assert_contains "$out" "quota is used up" "the refusal must say the plan quota is gone"

  # `stop` never covers anything, so it must refuse exactly as an unset policy did.
  run_seat "$HOME_DIR" "$FAKEBIN" extra-usage stop >/dev/null
  printf '%s\t10\n' "$SEATS_DIR/beta" > "$SPEC_DIR/extra_map"
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" switch beta)
  expect_code 1 "$?" "the stop policy must never keep an empty seat usable: $out"
  assert_contains "$out" "quota is used up" "the refusal must say the plan quota is gone"
  assert_grep alpha "$HOME_DIR/config/claude-seat" "a refused switch must move nothing"
  pass "a seat on paid extra usage still takes work while stop and an unset policy refuse it"
}

# Field evidence: a second mate's home dispatched a worker onto Codex while both
# Codex homes were at 0%; it stalled at the usage limit before doing any work.
# Dispatch itself must refuse an exhausted provider in EVERY home, with no
# per-home seat configuration, whether the harness came from static config or an
# explicit flag.
# Field evidence: seat-max held 100% of its week but its 5-hour window ran out,
# so new workers went onto paid extra usage and had to be moved by hand. A seat
# is only usable if EVERY account-level window it is bound by has something
# left, so an exhausted session window means no headroom whatever the week says.
test_an_exhausted_session_window_is_no_headroom_however_full_the_week_is() {
  local rec out
  rec=$(make_seat_case session-window-dry)
  read_seat_case "$rec"
  mkdir -p "$SEATS_DIR/alpha" "$SEATS_DIR/beta"
  seat_logged_in "$SPEC_DIR" "$SEATS_DIR/alpha" "$SEATS_DIR/beta"
  printf 'alpha\n' > "$HOME_DIR/config/claude-seat"
  printf '10\n' > "$HOME_DIR/config/claude-seat-threshold"
  # alpha: the incident's own shape - a full week behind a spent 5-hour window.
  seat_windows "$SPEC_DIR" "$SEATS_DIR/alpha" 0 2026-10-15T06:00:00Z 100 2026-10-21T00:00:00Z
  # beta: the seat with real headroom in both windows.
  seat_windows "$SPEC_DIR" "$SEATS_DIR/beta" 60 2026-10-15T06:00:00Z 48 2026-10-21T00:00:00Z

  # The spent session window alone must hold new dispatch, even though the
  # weekly figure alone would look perfectly healthy. Under `stop` that is
  # exactly the incident: the seat had a full week and still put new workers
  # onto paid extra usage.
  run_seat "$HOME_DIR" "$FAKEBIN" extra-usage stop >/dev/null
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" status)
  assert_contains "$out" "new Claude dispatch: HELD" \
    "a spent session window must hold new dispatch, not pass as the week's 100%"
  assert_contains "$out" "no new Claude worker is started on paid extra usage" \
    "the hold must name paid extra usage as what it is preventing"
  run_seat "$HOME_DIR" "$FAKEBIN" extra-usage off >/dev/null

  # The automatic switch must not rotate the active seat onto beta, whose WEEK
  # is thinner than alpha's: a spent session window is not a spent week, so the
  # anchor rule still applies. A new worker reaches the seat with session room
  # at launch instead (bin/fm-spawn.sh, covered by the spawn cases below).
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" auto)
  expect_code 0 "$?" "the pass must act rather than fail: $out"
  assert_contains "$out" "no seat has enough headroom to switch to" \
    "a spent session window on a full week must not rotate onto a thinner week"
  assert_grep alpha "$HOME_DIR/config/claude-seat" "the active seat must stay on the fuller week"

  # A deliberate switch back onto the spent seat is refused for the same reason,
  # with --force still the explicit override.
  printf 'beta\n' > "$HOME_DIR/config/claude-seat"
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" switch alpha)
  expect_code 1 "$?" "a spent session window must refuse a destination too: $out"
  assert_contains "$out" "--force" "the refusal must name the deliberate override"
  assert_grep beta "$HOME_DIR/config/claude-seat" "a refused switch must move nothing"
  pass "an exhausted session window is no headroom however full the week is"
}

# The same seat under the two extra-usage policies: `stop` counts paid extra
# usage as no headroom, while `allow <usd>` under its cap is the one case the
# empty-seat rule yields to.
test_paid_extra_usage_is_no_headroom_under_stop_and_headroom_under_allow() {
  local rec out
  rec=$(make_seat_case extra-usage-headroom)
  read_seat_case "$rec"
  mkdir -p "$SEATS_DIR/alpha" "$SEATS_DIR/beta"
  seat_logged_in "$SPEC_DIR" "$SEATS_DIR/alpha" "$SEATS_DIR/beta"
  printf 'beta\n' > "$HOME_DIR/config/claude-seat"
  # alpha's plan quota is gone and it is drawing paid extra usage.
  seat_remaining "$SPEC_DIR" "$SEATS_DIR/alpha" 0
  seat_extra_spend "$SPEC_DIR" "$SEATS_DIR/alpha" 10
  seat_remaining "$SPEC_DIR" "$SEATS_DIR/beta" 30

  run_seat "$HOME_DIR" "$FAKEBIN" extra-usage stop >/dev/null
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" switch alpha)
  expect_code 1 "$?" "under stop a seat on paid extra usage must have no headroom: $out"
  assert_contains "$out" "quota is used up" "the refusal must say the plan quota is gone"
  assert_grep beta "$HOME_DIR/config/claude-seat" "a refused switch must move nothing"

  run_seat "$HOME_DIR" "$FAKEBIN" extra-usage allow 25 >/dev/null
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" switch alpha)
  expect_code 0 "$?" "under allow below the cap the same seat must still take work: $out"
  assert_grep alpha "$HOME_DIR/config/claude-seat" "the switch must land on the covered seat"
  pass "paid extra usage is no headroom under stop and headroom under allow below its cap"
}

test_a_codex_dispatch_is_refused_on_an_exhausted_provider_in_any_home() {
  local rec id out user_home seats
  id=codex-dry-dispatch-1
  rec=$(spawn_case spawn-codex-dry "$id")
  read_spawn_case "$rec"
  make_dual_quota_fake "$FAKEBIN" "$CASE_DIR/quota-spec"
  # No codex-seats-root is written anywhere: this home configures nothing, so
  # the seats root must resolve from the ambient default exactly as an
  # unconfigured second mate home's would.
  user_home="$HOME_DIR/user-home"
  # The fixture points claude-seats-root at an empty directory; drop it so BOTH
  # providers resolve from the ambient default and this home configures no seat
  # roots at all, exactly as an untouched second mate home does.
  rm -f "$HOME_DIR/config/claude-seats-root"
  seats="$user_home/.codex-seats"
  mkdir -p "$seats/codex-max" "$seats/codex-max2"
  : > "$seats/codex-max/auth.json"
  : > "$seats/codex-max2/auth.json"
  printf 'codex-max\n' > "$HOME_DIR/config/codex-seat"
  dual_quota "$CASE_DIR/quota-spec" codex "$seats/codex-max" 0 2026-10-19T00:00:00Z
  dual_quota "$CASE_DIR/quota-spec" codex "$seats/codex-max2" 0 2026-10-20T00:00:00Z

  # An explicit --harness codex must refuse and say which homes are empty and
  # when they return, rather than quietly sending the task somewhere else.
  out=$(run_spawn_here "$HOME_DIR" "$WT_DIR" "$FAKEBIN" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --harness codex 2>&1)
  expect_code 1 "$?" "an explicit Codex dispatch must be refused while every Codex home is empty"
  assert_contains "$out" "all Codex seats are out of quota" "the refusal must name the exhausted provider"
  assert_contains "$out" "codex-max until 2026-10-19T00:00:00Z" "the refusal must name each home's reset"
  assert_contains "$out" "codex-max2 until 2026-10-20T00:00:00Z" "the refusal must name the second home's reset"
  assert_absent "$HOME_DIR/state/$id.meta" "a refused dispatch must create no task record"
  [ ! -s "$LAUNCH_LOG" ] || fail "a refused dispatch must launch nothing: $(cat "$LAUNCH_LOG")"

  # The same refusal when the harness comes from static configuration rather
  # than a flag, because that is how a second mate home picks Codex.
  printf 'codex\n' > "$HOME_DIR/config/crew-harness"
  out=$(run_spawn_here "$HOME_DIR" "$WT_DIR" "$FAKEBIN" "$LAUNCH_LOG" "$id" "$PROJ_DIR" 2>&1)
  expect_code 1 "$?" "a statically configured Codex dispatch must be refused too"
  assert_contains "$out" "all Codex seats are out of quota" "the static-harness refusal must name the provider"
  [ ! -s "$LAUNCH_LOG" ] || fail "a refused dispatch must launch nothing: $(cat "$LAUNCH_LOG")"

  # A Claude seat with headroom is where the work belongs, and the refusal must
  # say so rather than leaving the caller to work it out.
  mkdir -p "$user_home/.claude-seats/seat-max"
  printf 'seat-max\n' > "$HOME_DIR/config/claude-seat"
  dual_quota "$CASE_DIR/quota-spec" claude "$user_home/.claude-seats/seat-max" 92 2026-10-21T00:00:00Z
  out=$(run_spawn_here "$HOME_DIR" "$WT_DIR" "$FAKEBIN" "$LAUNCH_LOG" "$id" "$PROJ_DIR" 2>&1)
  expect_code 1 "$?" "the refusal must stand while every Codex home is empty"
  assert_contains "$out" "Claude" "the refusal must route the work to the provider that has headroom"
  assert_contains "$out" "92% left" "the routing must carry the headroom it found"

  # Once a reset returns one home, dispatch proceeds on its own with nothing
  # re-added by hand.
  : > "$CASE_DIR/quota-spec/codex_map"
  dual_quota "$CASE_DIR/quota-spec" codex "$seats/codex-max" 55 2026-10-26T00:00:00Z
  dual_quota "$CASE_DIR/quota-spec" codex "$seats/codex-max2" 0 2026-10-20T00:00:00Z
  out=$(run_spawn_here "$HOME_DIR" "$WT_DIR" "$FAKEBIN" "$LAUNCH_LOG" "$id" "$PROJ_DIR" 2>&1)
  expect_code 0 "$?" "a replenished Codex home must take work again with no re-add: $out"
  pass "a Codex dispatch is refused on an exhausted provider in a home that configures no seats"
}

test_an_armed_watch_and_a_spawn_report_one_dry_vendor_once_between_them() {
  local rec id out wake
  id=seat-dry-shared-1
  rec=$(spawn_case spawn-seat-dry-shared "$id")
  read_spawn_case "$rec"
  make_quota_fake "$FAKEBIN" "$CASE_DIR/quota-spec"
  mkdir -p "$SEATS_DIR/alpha"
  printf '%s\n' "$SEATS_DIR/alpha" > "$CASE_DIR/quota-spec/oauth"
  printf 'alpha\n' > "$HOME_DIR/config/claude-seat"
  printf '10\n' > "$HOME_DIR/config/claude-seat-threshold"
  printf '%s\t0\t2026-10-20T09:00:00Z\t0\t2026-10-20T09:00:00Z\n' \
    "$SEATS_DIR/alpha" > "$CASE_DIR/quota-spec/windows_map"

  # The watch speaks first and records the notice.
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" auto)
  expect_code 0 "$?" "a pass with every seat empty must report rather than fail: $out"
  assert_contains "$out" "all Claude seats are out of quota" "the pass must say the vendor is empty"
  assert_contains "$out" "2026-10-20T09:00:00Z" "the notice must name when the seat returns"

  # The spawn refuses, and must not say the same thing to the supervisor again:
  # one depletion reaches the captain once, whichever channel saw it first.
  out=$(run_spawn_here "$HOME_DIR" "$WT_DIR" "$FAKEBIN" "$LAUNCH_LOG" "$id" "$PROJ_DIR" 2>&1)
  expect_code 1 "$?" "a spawn onto the empty vendor must still be refused"
  assert_contains "$out" "all Claude seats are out of quota" \
    "the refusal must use the same wording the watch used"
  wake=$(grep -c 'seat-depleted:claude' "$HOME_DIR/state/.wake-queue" 2>/dev/null || true)
  assert_equals 0 "${wake:-0}" \
    "a depletion the watch already reported must not be recorded a second time by the spawn"

  # And the watch stays quiet on its next poll for the same unchanged facts.
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" auto)
  [ -z "$out" ] || fail "the same unchanged depletion must not report again: $out"
  pass "an armed watch and a spawn report one dry vendor once between them"
}

test_one_unreadable_seat_never_re_announces_an_unchanged_dry_vendor() {
  local out case_dir home claude_seats codex_seats fakebin spec
  case_dir="$TMP_ROOT/dry-undecided"
  home="$case_dir/home"
  claude_seats="$case_dir/claude-seats"
  codex_seats="$case_dir/codex-seats"
  spec="$case_dir/quota-spec"
  mkdir -p "$home/config" "$home/state" "$home/data" \
    "$claude_seats/seat-max" "$codex_seats/codex-max" "$codex_seats/codex-max2"
  : > "$codex_seats/codex-max/auth.json"
  : > "$codex_seats/codex-max2/auth.json"
  fakebin=$(fm_fakebin "$case_dir/fake")
  make_dual_quota_fake "$fakebin" "$spec"
  printf '%s\n' "$claude_seats" > "$home/config/claude-seats-root"
  printf '%s\n' "$codex_seats" > "$home/config/codex-seats-root"
  printf 'codex-max\n' > "$home/config/codex-seat"
  printf 'seat-max\n' > "$home/config/claude-seat"
  printf '10\n' > "$home/config/codex-seat-threshold"
  dual_quota "$spec" codex "$codex_seats/codex-max" 0 2026-10-19T00:00:00Z
  dual_quota "$spec" codex "$codex_seats/codex-max2" 0 2026-10-20T00:00:00Z
  dual_quota "$spec" claude "$claude_seats/seat-max" 92 2026-10-21T00:00:00Z

  out=$(run_seat "$home" "$fakebin" --provider codex auto)
  assert_contains "$out" "all Codex seats are out of quota" "the first pass must report the dry vendor"

  # The non-active seat's read fails on this pass only. Nothing about the
  # depletion has changed, so a transient unreadable seat must not make the
  # fleet hear it all over again.
  : > "$spec/codex_map"
  dual_quota "$spec" codex "$codex_seats/codex-max" 0 2026-10-19T00:00:00Z
  out=$(run_seat "$home" "$fakebin" --provider codex auto)
  [ -z "$out" ] || fail "an unreadable seat must not re-announce an unchanged depletion: $out"
  assert_grep codex-max "$home/config/codex-seat" "an undecided pass must move nothing"

  # Once it reads again, still unchanged, it stays quiet.
  dual_quota "$spec" codex "$codex_seats/codex-max2" 0 2026-10-20T00:00:00Z
  out=$(run_seat "$home" "$fakebin" --provider codex auto)
  [ -z "$out" ] || fail "the restored read must not re-announce an unchanged depletion: $out"

  # A reset moving IS a change, so it speaks again.
  : > "$spec/codex_map"
  dual_quota "$spec" codex "$codex_seats/codex-max" 0 2026-10-26T00:00:00Z
  dual_quota "$spec" codex "$codex_seats/codex-max2" 0 2026-10-20T00:00:00Z
  out=$(run_seat "$home" "$fakebin" --provider codex auto)
  assert_contains "$out" "2026-10-26T00:00:00Z" "a reset that moves must be reported again"
  pass "one unreadable seat never re-announces an unchanged dry vendor"
}

test_a_spawn_is_refused_on_an_empty_seat_and_the_routing_line_is_recorded_once() {
  local rec id out spec wake
  id=seat-depleted-1
  rec=$(spawn_case spawn-seat-depleted "$id")
  read_spawn_case "$rec"
  spec="$CASE_DIR/quota-spec"
  make_quota_fake "$FAKEBIN" "$spec"
  mkdir -p "$SEATS_DIR/alpha"
  printf '%s\n' "$SEATS_DIR/alpha" > "$spec/oauth"
  printf 'alpha\n' > "$HOME_DIR/config/claude-seat"
  printf '%s\t0\t2026-10-20T09:00:00Z\t0\t2026-10-20T09:00:00Z\n' \
    "$SEATS_DIR/alpha" > "$spec/windows_map"

  out=$(run_spawn_here "$HOME_DIR" "$WT_DIR" "$FAKEBIN" "$LAUNCH_LOG" "$id" "$PROJ_DIR" 2>&1)
  expect_code 1 "$?" "a fresh spawn must not start on a seat with no quota left"
  assert_contains "$out" "no quota left" "the refusal must say why it refused"
  assert_contains "$out" "2026-10-20T09:00:00Z" "the refusal must name when the seat returns"
  assert_contains "$out" "re-run with --ignore-seat-hold" "the refusal must name the override"
  assert_absent "$HOME_DIR/state/$id.meta" "a refused spawn must create no task record"
  [ ! -s "$LAUNCH_LOG" ] || fail "a refused spawn must launch nothing: $(cat "$LAUNCH_LOG")"
  wake=$(grep -c 'seat-depleted:claude' "$HOME_DIR/state/.wake-queue" 2>/dev/null || true)
  assert_equals 1 "$wake" "the routing line must reach the supervisor record once"

  out=$(run_spawn_here "$HOME_DIR" "$WT_DIR" "$FAKEBIN" "$LAUNCH_LOG" "$id" "$PROJ_DIR" 2>&1)
  expect_code 1 "$?" "an unchanged depletion must still refuse the spawn"
  wake=$(grep -c 'seat-depleted:claude' "$HOME_DIR/state/.wake-queue" 2>/dev/null || true)
  assert_equals 1 "$wake" "an unchanged depletion must not record the routing line a second time"

  # The seat's week resets. Nothing is re-added by hand and the spawn proceeds.
  printf '%s\t80\t2026-10-27T09:00:00Z\t80\t2026-10-27T09:00:00Z\n' \
    "$SEATS_DIR/alpha" > "$spec/windows_map"
  out=$(run_spawn_here "$HOME_DIR" "$WT_DIR" "$FAKEBIN" "$LAUNCH_LOG" "$id" "$PROJ_DIR" 2>&1)
  expect_code 0 "$?" "a seat whose quota returned must start work again with nothing re-added: $out"
  assert_grep "claude_seat=" "$HOME_DIR/state/$id.meta" "the spawn must record its seat as any other does"
  pass "a spawn is refused on an empty seat, records the routing line once, and resumes on its own"
}

test_absent_setting_is_the_default_seat
test_switch_to_logged_in_seat_updates_only_the_setting
test_switch_to_seat_that_is_not_logged_in_is_refused
test_forced_switch_cannot_override_a_proven_negative
test_rate_limited_seat_is_undecided_and_forceable
test_unreadable_store_is_undecided_and_force_may_cross_it
test_forced_switch_refuses_a_seat_with_no_profile_directory
test_switch_back_to_default_clears_the_setting
test_switch_reaches_running_local_secondmate_homes
test_failed_secondmate_push_does_not_undo_the_switch
test_a_declining_home_keeps_its_own_seat_through_a_switch
test_a_switch_still_reaches_every_home_that_did_not_decline
test_status_names_every_local_home_that_declined
test_a_non_file_decline_flag_still_declines
test_remote_route_never_receives_seat_settings
test_switch_never_contacts_remote_routes
test_config_push_without_local_only_still_reaches_remote_routes
test_threshold_is_configurable_and_absent_by_default
test_threshold_reached_is_edge_triggered_by_the_configured_percent
test_unreadable_quota_never_reports_the_threshold_reached
test_model_scoped_window_alone_does_not_trip_the_threshold
test_default_seat_probes_the_ambient_profile_workers_get
test_an_unconfigured_home_rotates_on_login_alone_and_holds_nothing
test_no_switch_lands_on_a_seat_whose_quota_is_used_up
test_a_codex_switch_refuses_an_empty_home_exactly_as_a_claude_switch_does
test_an_empty_seat_returns_to_rotation_on_its_own_once_a_read_shows_headroom
test_the_watch_refuses_to_flip_between_empty_seats_and_says_where_work_goes_once
test_the_watch_reports_a_vendor_draining_empty_after_its_shortfall_was_reported
test_a_spawn_is_refused_on_an_empty_seat_and_the_routing_line_is_recorded_once
test_a_paid_overflow_seat_still_takes_work_while_a_stop_policy_refuses_it
test_an_armed_watch_and_a_spawn_report_one_dry_vendor_once_between_them
test_a_codex_dispatch_is_refused_on_an_exhausted_provider_in_any_home
test_an_exhausted_session_window_is_no_headroom_however_full_the_week_is
test_paid_extra_usage_is_no_headroom_under_stop_and_headroom_under_allow
test_one_unreadable_seat_never_re_announces_an_unchanged_dry_vendor
test_dispatch_gate_needs_no_quota_reader_when_unconfigured
test_destination_minimum_is_configurable_validated_and_clearable
test_a_switch_skips_a_seat_below_the_destination_minimum
test_no_switch_happens_when_no_seat_clears_the_destination_minimum
test_an_unreadable_candidate_quota_is_skipped_and_never_guessed
test_extra_usage_policy_is_configurable_validated_and_clearable
test_stop_policy_holds_dispatch_only_once_the_plan_quota_is_gone
test_allow_policy_proceeds_under_the_cap_and_holds_at_it
test_an_unreadable_quota_holds_dispatch_rather_than_guessing
test_a_lapsed_seat_is_not_held_for_its_unreadable_quota
test_the_watch_keeps_firing_across_crossings_and_never_twice_on_one
test_the_watch_reports_the_policy_consequence_when_no_seat_qualifies
test_the_watch_and_status_agree_while_plan_quota_remains
test_the_watch_switches_once_a_candidate_recovers_after_a_crossing_with_nowhere_to_go
test_the_watch_keeps_every_quota_read_inside_the_check_budget
test_the_watch_never_switches_on_an_unreadable_active_quota
test_arm_registers_a_repeating_watch_and_retire_removes_it
test_status_reports_every_automatic_setting_in_percent_left
test_rotation_picks_the_next_logged_in_seat
test_a_lapsed_seat_reads_as_usable_rather_than_unknown
test_the_lapsed_verdict_comes_from_the_field_not_the_message
test_switching_to_a_lapsed_seat_needs_no_force
test_a_lapsed_seat_is_a_rotation_destination
test_a_lapsed_seat_is_skipped_for_unknown_headroom_under_a_destination_minimum
test_a_signed_out_seat_is_refused_and_force_cannot_cross_it
test_a_signed_out_seat_is_never_a_rotation_destination
test_a_rejected_request_is_not_a_sign_out_and_force_may_cross_it
test_rotation_never_targets_the_default_profile
test_rotation_reads_the_seat_set_fresh
test_rotation_refuses_when_there_is_nowhere_to_go
test_auto_exclude_and_include_round_trip
test_auto_exclude_refuses_a_name_that_is_not_a_seat
test_status_and_list_report_an_excluded_seat
test_rotation_skips_an_excluded_seat
test_an_explicit_switch_still_reaches_an_excluded_seat
test_excluding_the_active_seat_never_switches_away_from_it
test_excluding_every_candidate_keeps_the_existing_no_destination_refusal
test_the_watch_never_switches_onto_an_excluded_seat
test_the_lead_restart_destination_skips_an_excluded_seat
test_add_creates_the_profile_directory_without_touching_credentials
test_a_directory_named_default_is_not_offered_as_a_seat
test_seat_names_that_escape_the_seats_root_are_refused
test_spawn_without_a_seat_sets_no_config_dir
test_spawn_uses_the_active_seat_and_records_it
test_switching_seats_does_not_move_a_running_worker
test_a_later_spawn_uses_the_new_seat_while_the_old_task_keeps_its_own
test_ambient_config_dir_still_reaches_workers_when_no_seat_is_set
test_active_seat_overrides_the_ambient_config_dir
test_a_restarted_lead_spawns_the_default_seat_on_its_original_ambient
test_non_claude_spawn_records_no_seat
test_account_pin_and_active_seat_refuse_the_spawn
test_account_pin_and_active_seat_do_not_refuse_another_harness
test_pin_only_home_still_relaunches_a_claude_task
test_pin_at_a_seat_directory_still_relaunches_a_claude_task
test_a_stop_policy_holds_a_fresh_claude_spawn_and_the_override_gets_through
test_the_spawn_gate_holds_at_the_cap_and_on_an_unreadable_quota
test_a_hold_never_blocks_a_relaunch_or_another_harness
test_a_non_claude_spawn_is_never_held_by_the_claude_policy
test_the_floor_is_configurable_validated_and_absent_by_default
test_a_seat_at_or_below_the_floor_rests_and_rotation_skips_it
test_the_resting_record_names_the_limiting_window_and_the_reset_it_waits_for
test_an_explicit_switch_still_reaches_a_resting_seat_and_warns
test_a_seat_held_out_by_hand_is_never_rested_or_lifted_by_the_floor
test_a_resting_seat_comes_back_only_above_the_readd_level_and_after_the_rest_time
test_a_session_reset_alone_never_returns_a_seat_whose_week_cannot_carry_a_session
test_a_week_that_resets_returns_a_seat_rested_for_its_week
test_the_session_share_is_measured_from_co_movement_inside_one_window
test_an_unmeasured_session_share_uses_the_assumed_figure_and_says_so
test_an_unreadable_reading_never_rests_a_seat_and_never_wakes_one
test_a_lapsed_seat_comes_back_provisionally_only_once_its_recorded_reset_has_passed
test_a_provisional_seat_is_a_candidate_and_is_shown_as_provisionally_back
test_the_first_readable_reading_settles_a_provisional_seat
test_a_provisional_seat_whose_week_cannot_absorb_a_session_stays_resting
test_a_week_reset_inside_a_session_yields_no_share_sample
test_a_failed_push_after_a_hand_wake_does_not_claim_a_seat_switched
test_clearing_the_floor_wakes_every_resting_seat_here_and_in_secondmates
test_a_resting_record_withholds_nothing_while_no_floor_is_configured
test_a_readd_level_at_or_below_the_floor_is_refused_and_ignored
test_a_hand_wake_during_a_pass_is_not_undone_by_it
test_arm_keeps_the_refusal_when_a_candidate_is_withheld_for_another_reason
test_a_killed_pass_leaves_no_memo_directory_behind
test_one_floor_pass_reads_each_seat_once_and_stays_inside_the_check_budget
test_the_resting_record_reaches_local_secondmates_and_a_declining_home_keeps_its_own
test_arm_warns_rather_than_refusing_when_every_candidate_is_merely_resting
test_a_floor_may_be_armed_with_no_switch_threshold
test_status_and_list_tell_a_seat_held_out_by_hand_from_a_resting_one
test_the_floor_setter_warns_when_it_sits_at_or_above_the_switch_trigger
test_resting_wake_returns_a_seat_early_and_the_next_pass_may_rest_it_again
test_a_stop_policy_holds_dispatch_once_the_active_seat_is_at_the_floor

# --- the paid-extra-usage warning fires once per SEAT's own entry ------------
# Observed noise: the same unchanged seat re-alarmed firstmate on the watcher's
# cadence for as long as the spend lasted. The de-dupe record held the whole set
# of spending seats as one string and the warning fired whenever that string
# changed, so a DIFFERENT seat entering or leaving - one task finishing was
# enough - re-reported every seat in the set, including seats whose own state
# had not moved since they were last reported.
# Both directions are pinned: a seat whose state changes still alarms exactly
# once, and a seat already reported stays silent through every later change to
# the set.

# A home whose ACTIVE seat is healthy, so nothing but the extra-usage warning
# can speak: the trigger is configured (otherwise the pass reads no quota at
# all) but the active seat sits far above it, and no floor is configured.
extra_usage_case() {  # <name>
  local rec
  rec=$(make_seat_case "$1")
  read_seat_case "$rec"
  mkdir -p "$SEATS_DIR/alpha" "$SEATS_DIR/beta" "$SEATS_DIR/gamma"
  seat_logged_in "$SPEC_DIR" "$SEATS_DIR/alpha" "$SEATS_DIR/beta" "$SEATS_DIR/gamma"
  printf 'gamma\n' > "$HOME_DIR/config/claude-seat"
  run_seat "$HOME_DIR" "$FAKEBIN" threshold 15 >/dev/null
  run_seat "$HOME_DIR" "$FAKEBIN" extra-usage stop >/dev/null
  seat_remaining "$SPEC_DIR" "$SEATS_DIR/gamma" 80
}

# One claude task recorded as running on <profile>.
extra_usage_task() {  # <task-id> <profile>
  printf 'harness=claude\nkind=ship\nclaude_seat=%s\n' "$2" > "$HOME_DIR/state/$1.meta"
}

# A seat whose plan quota is gone and whose account carries paid spend, which is
# what fm_seat_in_extra_usage_from reads as drawing extra usage.
extra_usage_spending() {  # <profile>
  seat_remaining "$SPEC_DIR" "$1" 0
  seat_extra_spend "$SPEC_DIR" "$1" 7
}

test_extra_usage_warning_is_once_per_seat_entry() {
  local out
  extra_usage_case extra-usage-entry
  extra_usage_task alphatask "$SEATS_DIR/alpha"
  extra_usage_spending "$SEATS_DIR/alpha"

  out=$(run_seat "$HOME_DIR" "$FAKEBIN" auto)
  assert_contains "$out" 'Claude seat in paid extra usage: alpha' \
    "a seat entering paid extra usage must be reported once"

  out=$(run_seat "$HOME_DIR" "$FAKEBIN" auto)
  assert_not_contains "$out" 'paid extra usage' \
    "an unchanged spending seat must not be reported again on the next poll"

  # A SECOND seat enters. Only it is new, so only it is named: the first seat's
  # own state has not changed and it has already been reported.
  extra_usage_task betatask "$SEATS_DIR/beta"
  extra_usage_spending "$SEATS_DIR/beta"
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" auto)
  assert_contains "$out" 'Claude seat in paid extra usage: beta' \
    "a second seat entering paid extra usage must be reported"
  assert_not_contains "$out" 'usage: alpha' \
    "a seat already reported must not be re-reported when another seat enters"

  # The second seat's task ends, which shrinks the set. This is the exact change
  # that used to re-alarm the seat that stayed.
  rm -f "$HOME_DIR/state/betatask.meta"
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" auto)
  assert_not_contains "$out" 'paid extra usage' \
    "a seat leaving the set must not re-report the seat that stayed"

  out=$(run_seat "$HOME_DIR" "$FAKEBIN" auto)
  assert_not_contains "$out" 'paid extra usage' \
    "the poll after a shrinking set must stay silent too"
  pass "the paid-extra-usage warning reports each seat once on its own entry and stays silent for the rest"
}

# The still-waking half, and the one that decides whether the silence above was
# safe: a seat whose own state changes must alarm, including the SAME seat
# entering again after it left, with nothing re-armed by hand.
test_extra_usage_warning_rearms_when_a_seat_leaves_and_returns() {
  local out
  extra_usage_case extra-usage-rearm
  extra_usage_task alphatask "$SEATS_DIR/alpha"
  extra_usage_spending "$SEATS_DIR/alpha"
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" auto)
  assert_contains "$out" 'Claude seat in paid extra usage: alpha' \
    "the first entry must be reported"

  # The plan quota comes back, so the seat is no longer drawing extra usage.
  printf '%s\t60\n%s\t80\n' "$SEATS_DIR/alpha" "$SEATS_DIR/gamma" > "$SPEC_DIR/remaining_map"
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" auto)
  assert_not_contains "$out" 'paid extra usage' "a seat leaving extra usage must update the record silently"

  # And it enters again: the record was re-armed by the silent departure.
  printf '%s\t0\n%s\t80\n' "$SEATS_DIR/alpha" "$SEATS_DIR/gamma" > "$SPEC_DIR/remaining_map"
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" auto)
  assert_contains "$out" 'Claude seat in paid extra usage: alpha' \
    "a seat that left and returned must be reported again"
  pass "a seat that leaves paid extra usage re-arms its own warning and is reported again when it returns"
}


# --- moving an already-running worker off a walled seat ---------------------
# `worker-destination` answers where a worker whose own seat hit a vendor credit
# or usage wall can be moved, and `name-of` reads a task's recorded profile back
# as the seat it is. The property these cases protect is that a MID-TASK move
# gets the same candidate set and the same quota gate as a new launch, through
# next_seat rather than a second chooser - so an excluded, resting, signed-out,
# proven-empty or below-minimum seat is no more a destination for stopped work
# than for fresh work. bin/fm-quota-wall-lib.sh owns the move itself, and
# tests/fm-quota-wall.test.sh covers its bounds.

test_name_of_reads_a_recorded_profile_back_as_its_seat() {
  local rec out
  rec=$(make_seat_case name-of)
  read_seat_case "$rec"
  mkdir -p "$SEATS_DIR/alpha"

  out=$(run_seat "$HOME_DIR" "$FAKEBIN" name-of "$SEATS_DIR/alpha")
  expect_code 0 "$?" "a managed profile must resolve to its seat name: $out"
  assert_equals alpha "$out" "a task's recorded profile must read back as its seat name"

  out=$(run_seat "$HOME_DIR" "$FAKEBIN" name-of '')
  assert_equals default "$out" "an empty recorded profile is the ambient default seat"

  # A profile outside the seats root is reported by its own path rather than
  # labelled with a seat it is not on.
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" name-of "$CASE_DIR/unmanaged")
  assert_equals "$CASE_DIR/unmanaged" "$out" \
    "an unmanaged profile must be reported by its path, never as a seat it is not"
  pass "name-of reads a recorded profile back as its seat, and says so honestly when it is not one"
}

test_worker_destination_never_answers_the_seat_the_worker_is_on() {
  local rec out
  rec=$(make_seat_case worker-destination)
  read_seat_case "$rec"
  mkdir -p "$SEATS_DIR/alpha" "$SEATS_DIR/beta"
  seat_logged_in "$SPEC_DIR" "$SEATS_DIR/alpha" "$SEATS_DIR/beta"
  seat_remaining "$SPEC_DIR" "$SEATS_DIR/alpha" 0
  seat_remaining "$SPEC_DIR" "$SEATS_DIR/beta" 90
  # The home's own active seat is deliberately the walled one, to prove the
  # answer is anchored on the WORKER's seat and not on what new launches get.
  printf 'alpha\n' > "$HOME_DIR/config/claude-seat"

  out=$(run_seat "$HOME_DIR" "$FAKEBIN" worker-destination --from alpha)
  expect_code 0 "$?" "a seat with headroom must be offered as a destination: $out"
  assert_equals beta "$out" "the move must land on the seat that still has headroom"

  out=$(run_seat "$HOME_DIR" "$FAKEBIN" worker-destination --from beta)
  expect_code 1 "$?" "the only other seat is empty, so there is nowhere to move: $out"
  assert_contains "$out" 'quota is used up' "the refusal must name why alpha was skipped"

  # A seat this worker already walled out on is refused however much headroom
  # its quota read reports, so a moved worker cannot be handed straight back.
  seat_remaining "$SPEC_DIR" "$SEATS_DIR/alpha" 90
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" worker-destination --from beta --skip alpha)
  expect_code 1 "$?" "a seat the worker already walled out on must not be offered: $out"
  assert_contains "$out" 'already walled out on it' "the refusal must say why alpha was skipped"

  # Nothing about the home's own seat choice may change: this answers a question.
  assert_grep alpha "$HOME_DIR/config/claude-seat" \
    "asking where a worker could go must never switch the active seat"
  pass "worker-destination is anchored on the worker's own seat and changes nothing"
}

test_worker_destination_honours_the_same_gate_a_new_launch_gets() {
  local rec out
  rec=$(make_seat_case worker-destination-gate)
  read_seat_case "$rec"
  mkdir -p "$SEATS_DIR/alpha" "$SEATS_DIR/beta"
  seat_logged_in "$SPEC_DIR" "$SEATS_DIR/alpha" "$SEATS_DIR/beta"
  seat_remaining "$SPEC_DIR" "$SEATS_DIR/alpha" 0
  seat_remaining "$SPEC_DIR" "$SEATS_DIR/beta" 25

  # Held out of automatic rotation by hand: a stopped worker's move is an
  # automatic path, so it must be withheld here exactly as a switch is.
  run_seat "$HOME_DIR" "$FAKEBIN" auto-exclude beta >/dev/null
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" worker-destination --from alpha)
  expect_code 1 "$?" "an excluded seat must not take over a stopped worker: $out"
  assert_contains "$out" 'excluded from automatic rotation' \
    "the refusal must say the seat was held out by hand"

  # Back in rotation, but under a destination minimum it does not clear.
  run_seat "$HOME_DIR" "$FAKEBIN" auto-include beta >/dev/null
  run_seat "$HOME_DIR" "$FAKEBIN" destination-min 30 >/dev/null
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" worker-destination --from alpha)
  expect_code 1 "$?" "a seat below the destination minimum must not take over a worker: $out"
  assert_contains "$out" 'destination minimum' "the refusal must name the minimum it failed"

  # Clear the minimum and the same seat is a destination again, which is what
  # shows the refusals above came from the gate rather than from the seat.
  run_seat "$HOME_DIR" "$FAKEBIN" destination-min off >/dev/null
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" worker-destination --from alpha)
  expect_code 0 "$?" "with the minimum cleared the seat must be a destination again: $out"
  assert_equals beta "$out" "the eligible seat must be offered once nothing withholds it"
  pass "a stopped worker's move is withheld by the same exclusion and destination minimum a new launch gets"
}

test_worker_destination_names_when_an_empty_seat_comes_back() {
  local rec out
  rec=$(make_seat_case worker-destination-reset)
  read_seat_case "$rec"
  mkdir -p "$SEATS_DIR/alpha" "$SEATS_DIR/beta"
  seat_logged_in "$SPEC_DIR" "$SEATS_DIR/alpha" "$SEATS_DIR/beta"
  seat_windows "$SPEC_DIR" "$SEATS_DIR/alpha" 0 '2026-10-18T09:00:00Z' 0 '2026-10-20T00:00:00Z'
  # beta is spent on its session window only, so the reset a decision must wait
  # for is that window's - the one actually binding, not the weekly one it still
  # has headroom in.
  seat_windows "$SPEC_DIR" "$SEATS_DIR/beta" 0 '2026-10-16T02:00:00Z' 40 '2026-10-21T00:00:00Z'

  out=$(run_seat "$HOME_DIR" "$FAKEBIN" worker-destination --from alpha)
  expect_code 1 "$?" "every seat is empty, so there is nowhere to move: $out"
  assert_contains "$out" 'seat beta' "the refusal must name the seat it considered"
  assert_contains "$out" 'quota is used up' "the refusal must say why the seat cannot take the work"
  assert_contains "$out" '2026-10-16T02:00:00Z' \
    "the refusal must name the binding window's reset, so a decision can wait for it"
  assert_not_contains "$out" '2026-10-21T00:00:00Z' \
    "a window the seat still has headroom in is not when it comes back"
  assert_contains "$out" 'seat alpha: resets at' \
    "the refusal must say when the walled seat itself comes back"
  assert_contains "$out" 'seat beta: resets at 2026-10-16T02:00:00Z' \
    "every considered seat must be listed with its reset"
  assert_contains "$out" 'seat default: reset unknown:' \
    "the default profile must be listed, saying why its reset is unknown"
  pass "with every seat empty the refusal names each seat and when it comes back"
}


# --- the seat-choice policy ---------------------------------------------------
# Two separate questions, never one number: the WEEKLY window decides which seat
# carries work and the five-hour window decides only when. These cases pin both
# halves against the readings that produced the 2026-10-15/16 ping-pong, and
# each one drives the real commands rather than inspecting any source.

test_a_crossing_never_moves_onto_a_seat_with_no_more_headroom() {
  local rec out
  rec=$(make_seat_case policy-no-better)
  read_seat_case "$rec"
  mkdir -p "$SEATS_DIR/alpha" "$SEATS_DIR/beta"
  seat_logged_in "$SPEC_DIR" "$SEATS_DIR/alpha" "$SEATS_DIR/beta"
  printf 'alpha\n' > "$HOME_DIR/config/claude-seat"
  # Both seats below the trigger and both well above the destination minimum,
  # with the same spare: each one is a valid destination for the other under
  # the absolute floor alone, which is exactly how the lead crossed back and
  # forth between two spent seats.
  seat_windows "$SPEC_DIR" "$SEATS_DIR/alpha" 90 '2026-10-16T05:40:00Z' 18 '2026-10-21T06:00:00Z' 40 -25
  seat_windows "$SPEC_DIR" "$SEATS_DIR/beta" 90 '2026-10-16T05:40:00Z' 18 '2026-10-21T06:00:00Z' 40 -25
  run_seat "$HOME_DIR" "$FAKEBIN" threshold 20 >/dev/null
  run_seat "$HOME_DIR" "$FAKEBIN" destination-min 10 >/dev/null

  out=$(run_seat "$HOME_DIR" "$FAKEBIN" auto)
  assert_contains "$out" "no seat has enough headroom to switch to" \
    "a crossing with no better seat must report the stay-put notice, not switch"
  assert_grep alpha "$HOME_DIR/config/claude-seat" \
    "a crossing with no better seat must leave the active seat exactly where it was"

  # Once per episode, not once per poll: the existing dedup is what the notice
  # relies on, and it only becomes reachable now that no-better seats are
  # refused.
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" auto)
  [ -z "$out" ] || fail "the stay-put notice fired twice for one crossing: $out"

  # The other leg, with the seats swapped by hand. Before this gate the back
  # leg fired too, which is the ping-pong itself.
  printf 'beta\n' > "$HOME_DIR/config/claude-seat"
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" auto)
  assert_contains "$out" "no seat has enough headroom to switch to" \
    "the return leg must refuse for the same reason rather than switching back"
  assert_grep beta "$HOME_DIR/config/claude-seat" "the return leg must not move the seat either"
  pass "a crossing with no seat better than the one it is on stays put and says so once"
}

test_a_crossing_still_moves_onto_a_seat_that_is_genuinely_better() {
  local rec out
  rec=$(make_seat_case policy-genuine-move)
  read_seat_case "$rec"
  mkdir -p "$SEATS_DIR/alpha" "$SEATS_DIR/beta"
  seat_logged_in "$SPEC_DIR" "$SEATS_DIR/alpha" "$SEATS_DIR/beta"
  printf 'alpha\n' > "$HOME_DIR/config/claude-seat"
  # Both under the trigger, as before, but beta really does have more spare.
  # The gate must block moves that do not improve headroom, not every move.
  seat_windows "$SPEC_DIR" "$SEATS_DIR/alpha" 90 '2026-10-16T05:40:00Z' 10 '2026-10-21T06:00:00Z' 40 -30
  seat_windows "$SPEC_DIR" "$SEATS_DIR/beta" 90 '2026-10-16T05:40:00Z' 15 '2026-10-21T06:00:00Z' 40 -20
  run_seat "$HOME_DIR" "$FAKEBIN" threshold 20 >/dev/null

  out=$(run_seat "$HOME_DIR" "$FAKEBIN" auto)
  assert_contains "$out" "switched from alpha" "a genuine improvement must still switch"
  assert_contains "$out" "to beta" "the switch must land on the seat with more weekly spare"
  assert_grep beta "$HOME_DIR/config/claude-seat" "the better seat must become the active one"
  pass "a crossing still moves when another seat genuinely has more weekly spare"
}

test_the_destination_minimum_still_applies_on_top_of_the_anchor_rule() {
  local rec out
  rec=$(make_seat_case policy-minimum-additive)
  read_seat_case "$rec"
  mkdir -p "$SEATS_DIR/alpha" "$SEATS_DIR/beta"
  seat_logged_in "$SPEC_DIR" "$SEATS_DIR/alpha" "$SEATS_DIR/beta"
  printf 'alpha\n' > "$HOME_DIR/config/claude-seat"
  # beta has MORE spare than alpha, so the anchor rule alone would take it, and
  # it is still below the absolute floor. The two rules are additive.
  seat_windows "$SPEC_DIR" "$SEATS_DIR/alpha" 90 '2026-10-16T05:40:00Z' 5 '2026-10-21T06:00:00Z' 40 -40
  seat_windows "$SPEC_DIR" "$SEATS_DIR/beta" 90 '2026-10-16T05:40:00Z' 8 '2026-10-21T06:00:00Z' 40 -30
  run_seat "$HOME_DIR" "$FAKEBIN" destination-min 10 >/dev/null

  # Driven through a path that applies BOTH rules and prints each seat's own
  # reason, so the refusal can be read against the rule that produced it.
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" worker-destination --from alpha)
  expect_code 1 "$?" "a candidate below the absolute minimum must still be refused: $out"
  assert_contains "$out" "8% left across its account windows is not above the 10% destination minimum" \
    "the refusal must name the absolute minimum, not the anchor comparison this candidate would have passed"
  pass "the destination minimum still refuses a candidate the anchor rule alone would accept"
}

test_the_lead_move_requires_measured_spend_priority() {
  local rec out
  rec=$(make_seat_case policy-lead-anchor)
  read_seat_case "$rec"
  mkdir -p "$SEATS_DIR/alpha" "$SEATS_DIR/beta"
  seat_logged_in "$SPEC_DIR" "$SEATS_DIR/alpha" "$SEATS_DIR/beta"
  printf 'beta\n' > "$HOME_DIR/config/claude-seat"
  # The lead runs on alpha while new workers already go to beta, which is how
  # the two sides of the ping-pong were on different seats at the same time.
  printf '4242424\n' > "$HOME_DIR/state/.lock"
  { printf 'pid=4242424\n'; printf 'profile=%s\n' "$SEATS_DIR/alpha"; } > "$HOME_DIR/state/.lock-runtime"
  seat_windows "$SPEC_DIR" "$SEATS_DIR/alpha" 90 '2026-10-16T05:40:00Z' 19 '2026-10-21T06:00:00Z' 40 -24
  seat_windows "$SPEC_DIR" "$SEATS_DIR/beta" 90 '2026-10-16T05:40:00Z' 18 '2026-10-21T06:00:00Z' 40 -25
  run_seat "$HOME_DIR" "$FAKEBIN" threshold 20 >/dev/null

  out=$(run_seat "$HOME_DIR" "$FAKEBIN" auto)
  assert_contains "$out" "firstmate itself is on alpha" "the lead's own crossing must be reported"
  assert_contains "$out" "no seat qualifies as a destination, so it stays where it is" \
    "the lead must stay put when the fixture has no spendPriority evidence"
  assert_not_contains "$out" "THEN run exactly:" \
    "no move instruction may be issued without a measured spendPriority"
  pass "the lead's own move requires measured spendPriority rather than weekly-spare arithmetic"
}

test_an_unreadable_anchor_leaves_the_absolute_rules_in_charge() {
  local rec out
  rec=$(make_seat_case policy-anchor-unreadable)
  read_seat_case "$rec"
  mkdir -p "$SEATS_DIR/alpha" "$SEATS_DIR/beta"
  seat_logged_in "$SPEC_DIR" "$SEATS_DIR/alpha" "$SEATS_DIR/beta"
  printf 'alpha\n' > "$HOME_DIR/config/claude-seat"
  # The anchor's own headroom cannot be read, so there is no comparison to
  # make. Refusing every candidate for a question that cannot be asked would
  # strand the home; today's absolute-only behavior is what must remain.
  # The lead's own move is the path that asks the comparison, so it is the one
  # driven here: the active seat's crossing is read from the lead's profile,
  # which is the same unreadable seat.
  printf '4242424\n' > "$HOME_DIR/state/.lock"
  { printf 'pid=4242424\n'; printf 'profile=%s\n' "$SEATS_DIR/alpha"; } > "$HOME_DIR/state/.lock-runtime"
  seat_remaining "$SPEC_DIR" "$SEATS_DIR/alpha" 5
  seat_remaining "$SPEC_DIR" "$SEATS_DIR/beta" 40
  run_seat "$HOME_DIR" "$FAKEBIN" threshold 20 >/dev/null

  # alpha's crossing is readable, so the move fires; its weekly SPARE is what
  # cannot be read, because this report carries no windows at all. beta is in
  # the same position, so the two are compared on the account figure they both
  # do report, and 40 is more than 5.
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" auto)
  assert_contains "$out" "to beta" "an eligible seat must still be chosen with no weekly window reported"

  # Now the anchor's quota gives no verdict at all. There is no comparison to
  # make, and refusing every candidate for a question that cannot be asked
  # would strand the home, so the absolute rules are the whole answer.
  seat_quota_unreadable "$SPEC_DIR" "$SEATS_DIR/beta"
  printf 'beta\n' > "$HOME_DIR/config/claude-seat"
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" worker-destination --from beta)
  expect_code 0 "$?" "an unreadable anchor must not block an otherwise eligible seat: $out"
  assert_equals alpha "$out" "the eligible seat must still be offered"
  pass "an anchor whose own headroom cannot be read falls back to the absolute rules alone"
}

test_a_walled_worker_moves_off_an_empty_seat_but_not_onto_an_equal_one() {
  local rec out
  rec=$(make_seat_case policy-worker-destination)
  read_seat_case "$rec"
  mkdir -p "$SEATS_DIR/alpha" "$SEATS_DIR/beta"
  seat_logged_in "$SPEC_DIR" "$SEATS_DIR/alpha" "$SEATS_DIR/beta"
  printf 'alpha\n' > "$HOME_DIR/config/claude-seat"
  # The worker's own seat still reads headroom, and beta has no more of it.
  # Moving the work there would buy nothing.
  seat_windows "$SPEC_DIR" "$SEATS_DIR/alpha" 90 '2026-10-16T05:40:00Z' 18 '2026-10-21T06:00:00Z' 40 -25
  seat_windows "$SPEC_DIR" "$SEATS_DIR/beta" 90 '2026-10-16T05:40:00Z' 18 '2026-10-21T06:00:00Z' 40 -25
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" worker-destination --from alpha)
  expect_code 1 "$?" "a seat with no more headroom must not take over a worker: $out"
  assert_contains "$out" "is not more than" "the refusal must name the comparison it failed"

  # The common case: the seat that walled the worker reads empty, so staying is
  # not an option and any seat with real headroom qualifies as it always did.
  seat_windows_clear "$SPEC_DIR"
  seat_windows "$SPEC_DIR" "$SEATS_DIR/alpha" 0 '2026-10-16T05:40:00Z' 0 '2026-10-21T06:00:00Z' -60 -60
  seat_windows "$SPEC_DIR" "$SEATS_DIR/beta" 90 '2026-10-16T05:40:00Z' 18 '2026-10-21T06:00:00Z' 40 -25
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" worker-destination --from alpha)
  expect_code 0 "$?" "an empty seat is one the work cannot stay on, so the move must still be offered: $out"
  assert_equals beta "$out" "the seat with real headroom must take the work"
  pass "a walled worker is never moved onto an equally spent seat, and still moves off an empty one"
}

test_a_five_hour_dip_alone_never_moves_a_seat_or_the_lead() {
  local rec out
  rec=$(make_seat_case policy-five-hour-dip)
  read_seat_case "$rec"
  mkdir -p "$SEATS_DIR/seat-max" "$SEATS_DIR/seat-max-gmail"
  seat_logged_in "$SPEC_DIR" "$SEATS_DIR/seat-max" "$SEATS_DIR/seat-max-gmail"
  printf 'seat-max\n' > "$HOME_DIR/config/claude-seat"
  printf '4242424\n' > "$HOME_DIR/state/.lock"
  { printf 'pid=4242424\n'; printf 'profile=%s\n' "$SEATS_DIR/seat-max"; } > "$HOME_DIR/state/.lock-runtime"
  # The reading that started the incident: seat-max looked like "18%" because
  # of its five-hour window while it held 65% of its week.
  seat_windows "$SPEC_DIR" "$SEATS_DIR/seat-max" 18 '2026-10-16T05:40:00Z' 65 '2026-10-21T06:00:00Z' -30 22
  seat_windows "$SPEC_DIR" "$SEATS_DIR/seat-max-gmail" 90 '2026-10-16T05:40:00Z' 18 '2026-10-21T06:00:00Z' 40 -25
  run_seat "$HOME_DIR" "$FAKEBIN" threshold 20 >/dev/null

  out=$(run_seat "$HOME_DIR" "$FAKEBIN" auto)
  [ -z "$out" ] || fail "a five-hour dip on a healthy week fired a move on its own: $out"
  assert_grep seat-max "$HOME_DIR/config/claude-seat" \
    "a five-hour dip must leave the active seat where it is"

  # The same seat's WEEK crossing is what fires, and it names both windows so
  # the figure can never be read as the wrong one again.
  seat_windows_clear "$SPEC_DIR"
  seat_windows "$SPEC_DIR" "$SEATS_DIR/seat-max" 18 '2026-10-16T05:40:00Z' 15 '2026-10-21T06:00:00Z' -30 -28
  seat_windows "$SPEC_DIR" "$SEATS_DIR/seat-max-gmail" 90 '2026-10-16T05:40:00Z' 60 '2026-10-21T06:00:00Z' 40 25
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" auto)
  assert_contains "$out" "switched from seat-max at week 15% left (resets 2026-10-21 06:00Z), 5-hour 18% left (resets 2026-10-16 05:40Z) to seat-max-gmail" \
    "the wake must name both windows and their resets, never a bare percentage"
  pass "a five-hour dip alone moves nothing, and a weekly crossing names every window it reports"
}

test_the_policy_ranks_the_2026_10_16_seats_without_bouncing() {
  local rec out name week week_reset five five_reset week_spare five_spare
  rec=$(make_seat_case policy-table)
  read_seat_case "$rec"
  mkdir -p "$SEATS_DIR/seat-max" "$SEATS_DIR/seat-max-gmail" "$SEATS_DIR/seat-max2"
  seat_logged_in "$SPEC_DIR" "$SEATS_DIR/seat-max" "$SEATS_DIR/seat-max-gmail" "$SEATS_DIR/seat-max2"
  run_seat "$HOME_DIR" "$FAKEBIN" threshold 20 >/dev/null

  # The real 03:12Z readings, as one table: seat name, five-hour left and its
  # reset, weekly left and its reset, then each window's own spare. seat-max2
  # is spent now and resets to a whole week at 11:00Z, which is the
  # use-it-or-lose-it seat the policy prefers once it is back.
  while IFS='|' read -r name five five_reset week week_reset five_spare week_spare; do
    [ -n "$name" ] || continue
    seat_windows "$SPEC_DIR" "$SEATS_DIR/$name" \
      "$five" "$five_reset" "$week" "$week_reset" "$five_spare" "$week_spare"
  done <<'TABLE'
seat-max|11|2026-10-16T05:40:00Z|65|2026-10-21T06:00:00Z|-30|22
seat-max-gmail|90|2026-10-16T05:40:00Z|18|2026-10-21T06:00:00Z|40|-25
seat-max2|100|2026-10-16T05:40:00Z|0|2026-10-16T11:00:00Z|60|-60
TABLE

  # Work carries on where it is: seat-max's WEEK is the healthiest of the three,
  # so its five-hour dip is a wait rather than a reason to change account.
  printf 'seat-max\n' > "$HOME_DIR/config/claude-seat"
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" auto)
  [ -z "$out" ] || fail "the healthiest week fired a move on a five-hour dip: $out"
  assert_grep seat-max "$HOME_DIR/config/claude-seat" "work must stay on the seat with the most weekly spare"

  # From the reserve seat, the move goes to seat-max and nowhere else:
  # seat-max-gmail is the seat with the least spare, so it is what is kept back.
  printf 'seat-max-gmail\n' > "$HOME_DIR/config/claude-seat"
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" auto)
  assert_contains "$out" "to seat-max" "the reserve seat must hand work to the seat with the most weekly spare"
  assert_grep seat-max "$HOME_DIR/config/claude-seat" "the chosen seat must be recorded"

  # And it stops there: seat-max's own poll finds nothing better, so the pair
  # cannot flip back and forth the way they did on 2026-10-15/16.
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" auto)
  [ -z "$out" ] || fail "the seat just switched to fired a move of its own: $out"

  # seat-max2's week resets to a whole week, which makes it the seat with the
  # most spare and therefore the next destination once seat-max crosses.
  seat_windows_clear "$SPEC_DIR"
  seat_windows "$SPEC_DIR" "$SEATS_DIR/seat-max" 90 '2026-10-16T10:40:00Z' 12 '2026-10-21T06:00:00Z' 40 -30
  seat_windows "$SPEC_DIR" "$SEATS_DIR/seat-max-gmail" 90 '2026-10-16T10:40:00Z' 18 '2026-10-21T06:00:00Z' 40 -25
  seat_windows "$SPEC_DIR" "$SEATS_DIR/seat-max2" 100 '2026-10-16T16:00:00Z' 100 '2026-10-23T11:00:00Z' 60 95
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" auto)
  assert_contains "$out" "to seat-max2" "the seat whose week has just reset must take the work"
  assert_grep seat-max2 "$HOME_DIR/config/claude-seat" "the reset seat must become the active one"
  pass "the 2026-10-16 readings route work by weekly spare, wait out a five-hour dip, and never bounce"
}

test_a_resting_lead_seat_still_requires_measured_spend_priority() {
  local rec out
  rec=$(make_seat_case policy-resting-anchor)
  read_seat_case "$rec"
  mkdir -p "$SEATS_DIR/alpha" "$SEATS_DIR/beta"
  seat_logged_in "$SPEC_DIR" "$SEATS_DIR/alpha" "$SEATS_DIR/beta"
  printf 'alpha\n' > "$HOME_DIR/config/claude-seat"
  printf '4242424\n' > "$HOME_DIR/state/.lock"
  { printf 'pid=4242424\n'; printf 'profile=%s\n' "$SEATS_DIR/alpha"; } > "$HOME_DIR/state/.lock-runtime"
  run_seat "$HOME_DIR" "$FAKEBIN" floor 5 >/dev/null
  run_seat "$HOME_DIR" "$FAKEBIN" threshold 20 >/dev/null
  run_seat "$HOME_DIR" "$FAKEBIN" destination-min 10 >/dev/null

  # alpha's five-hour window dips below the floor while its week is healthy,
  # so the watch rests it and nothing crosses.
  seat_windows "$SPEC_DIR" "$SEATS_DIR/alpha" 3 '2026-10-16T05:40:00Z' 60 '2026-10-21T06:00:00Z' -40 20
  seat_windows "$SPEC_DIR" "$SEATS_DIR/beta" 90 '2026-10-16T05:40:00Z' 12 '2026-10-21T06:00:00Z' 40 -30
  run_seat "$HOME_DIR" "$FAKEBIN" auto >/dev/null
  assert_grep alpha "$HOME_DIR/config/claude-seat-resting" "precondition: alpha must be resting below the floor"

  # Its week then crosses while it is still resting. The legacy fixture has no
  # spendPriority evidence: resting must not authorize an unmeasured leader move.
  # The worker's independent weekly-spare policy also keeps its seat unchanged.
  seat_windows_clear "$SPEC_DIR"
  seat_windows "$SPEC_DIR" "$SEATS_DIR/alpha" 3 '2026-10-16T05:40:00Z' 15 '2026-10-21T06:00:00Z' -40 -20
  seat_windows "$SPEC_DIR" "$SEATS_DIR/beta" 90 '2026-10-16T05:40:00Z' 12 '2026-10-21T06:00:00Z' 40 -30
  out=$(run_seat "$HOME_DIR" "$FAKEBIN" auto)
  assert_grep alpha "$HOME_DIR/config/claude-seat-resting" "precondition: alpha must still be resting at the crossing"
  assert_contains "$out" "no seat qualifies as a destination, so it stays where it is" \
    "a resting lead still needs measured spendPriority for a destination"
  assert_not_contains "$out" "THEN run exactly:" \
    "no leader move instruction may be issued without measured spendPriority"
  assert_grep alpha "$HOME_DIR/config/claude-seat" "the active seat must not rotate onto the worse seat either"
  pass "a resting leader requires measured spendPriority while worker rotation keeps its weekly-spare policy"
}

# spawn_session_case <name> <id>
# A spawn home with two logged-in seats, seat-max active, a 20% switch trigger
# and no quota floor, against the quota fake.
spawn_session_case() {
  local rec
  rec=$(spawn_case "$1" "$2")
  read_spawn_case "$rec"
  make_quota_fake "$FAKEBIN" "$CASE_DIR/quota-spec"
  mkdir -p "$SEATS_DIR/seat-max" "$SEATS_DIR/seat-max-gmail"
  printf '%s\n' "$SEATS_DIR/seat-max" "$SEATS_DIR/seat-max-gmail" > "$CASE_DIR/quota-spec/oauth"
  printf 'seat-max\n' > "$HOME_DIR/config/claude-seat"
  printf '20\n' > "$HOME_DIR/config/claude-seat-threshold"
}

test_a_new_worker_launches_off_a_seat_with_no_five_hour_room() {
  local id out launch
  id=seat-session-route-1
  spawn_session_case spawn-session-route "$id"
  # The reviewer's case: a healthy week, a five-hour window nearly gone, and a
  # second seat with session room and more weekly spare.
  seat_windows "$CASE_DIR/quota-spec" "$SEATS_DIR/seat-max" 3 '2026-10-16T05:40:00Z' 65 '2026-10-21T06:00:00Z' -60 22
  seat_windows "$CASE_DIR/quota-spec" "$SEATS_DIR/seat-max-gmail" 90 '2026-10-16T05:40:00Z' 80 '2026-10-21T06:00:00Z' 40 30

  out=$(run_spawn_here "$HOME_DIR" "$WT_DIR" "$FAKEBIN" "$LAUNCH_LOG" "$id" "$PROJ_DIR" 2>&1)
  expect_code 0 "$?" "a spawn with another seat holding five-hour room must start: $out"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "CLAUDE_CONFIG_DIR='$SEATS_DIR/seat-max-gmail'" \
    "the new worker must launch on the seat with five-hour room"
  assert_grep "claude_seat=$SEATS_DIR/seat-max-gmail" "$HOME_DIR/state/$id.meta" \
    "the task record must carry the seat it actually launched on"
  assert_equals seat-max "$(cat "$HOME_DIR/config/claude-seat")" \
    "routing one launch must not rotate the active seat"
  assert_not_contains "$out" "lead-restart" "routing one launch must not move the lead"

  # A five-hour window spent to nothing is routed the same way rather than held,
  # because another seat can take the work now.
  seat_windows_clear "$CASE_DIR/quota-spec"
  seat_windows "$CASE_DIR/quota-spec" "$SEATS_DIR/seat-max" 0 '2026-10-16T05:40:00Z' 65 '2026-10-21T06:00:00Z' -60 22
  seat_windows "$CASE_DIR/quota-spec" "$SEATS_DIR/seat-max-gmail" 90 '2026-10-16T05:40:00Z' 80 '2026-10-21T06:00:00Z' 40 30
  fm_test_spawn_ship_brief "$HOME_DIR" seat-session-route-2
  git -C "$PROJ_DIR" worktree add --quiet -b wt-session-route-2 "$CASE_DIR/wt2"
  out=$(run_spawn_here "$HOME_DIR" "$CASE_DIR/wt2" "$FAKEBIN" "$LAUNCH_LOG" seat-session-route-2 "$PROJ_DIR" 2>&1)
  expect_code 0 "$?" "a spawn off a spent five-hour window must be routed, not held: $out"
  assert_contains "$(cat "$LAUNCH_LOG")" "CLAUDE_CONFIG_DIR='$SEATS_DIR/seat-max-gmail'" \
    "a spent five-hour window must route the launch to the seat with room"
  assert_equals seat-max "$(cat "$HOME_DIR/config/claude-seat")" \
    "routing off a spent five-hour window must not rotate the active seat"
  pass "a new worker launches on a seat with five-hour room without rotating the active seat"
}

test_a_new_worker_is_held_when_no_seat_has_five_hour_room() {
  local id out
  id=seat-session-hold-1
  spawn_session_case spawn-session-hold "$id"
  seat_windows "$CASE_DIR/quota-spec" "$SEATS_DIR/seat-max" 3 '2026-10-16T05:40:00Z' 65 '2026-10-21T06:00:00Z' -60 22
  seat_windows "$CASE_DIR/quota-spec" "$SEATS_DIR/seat-max-gmail" 10 '2026-10-16T04:00:00Z' 80 '2026-10-21T06:00:00Z' -50 30

  out=$(run_spawn_here "$HOME_DIR" "$WT_DIR" "$FAKEBIN" "$LAUNCH_LOG" "$id" "$PROJ_DIR" 2>&1)
  expect_code 1 "$?" "a spawn with no seat holding five-hour room must be held: $out"
  assert_contains "$out" "the soonest 5-hour reset is seat-max-gmail at 2026-10-16 04:00Z" \
    "the hold must name the soonest five-hour reset to wait for"
  assert_contains "$out" "--ignore-seat-hold" "the hold must name the deliberate override"
  assert_absent "$HOME_DIR/state/$id.meta" "a held spawn must create no task record"
  [ ! -s "$LAUNCH_LOG" ] || fail "a held spawn must launch nothing: $(cat "$LAUNCH_LOG")"
  assert_equals seat-max "$(cat "$HOME_DIR/config/claude-seat")" "a hold must not rotate the active seat"

  # A seat whose five-hour window resets sooner but whose week is thinner than
  # the active seat's can never take the launch, so its reset ends no hold and
  # must not be the one named.
  seat_windows_clear "$CASE_DIR/quota-spec"
  seat_windows "$CASE_DIR/quota-spec" "$SEATS_DIR/seat-max" 3 '2026-10-16T05:40:00Z' 65 '2026-10-21T06:00:00Z' -60 22
  seat_windows "$CASE_DIR/quota-spec" "$SEATS_DIR/seat-max-gmail" 10 '2026-10-16T04:00:00Z' 30 '2026-10-21T06:00:00Z' -50 5
  out=$(run_spawn_here "$HOME_DIR" "$WT_DIR" "$FAKEBIN" "$LAUNCH_LOG" "$id" "$PROJ_DIR" 2>&1)
  expect_code 1 "$?" "a spawn with no qualifying seat must still be held: $out"
  assert_contains "$out" "the soonest 5-hour reset is seat-max at 2026-10-16 05:40Z" \
    "the hold must name the reset that can end it, not a seat that could never qualify"
  pass "a new worker is held, naming the soonest five-hour reset, when no seat has five-hour room"
}

echo "# all fm-seat tests passed"

test_a_resting_lead_seat_still_requires_measured_spend_priority
test_a_new_worker_launches_off_a_seat_with_no_five_hour_room
test_a_new_worker_is_held_when_no_seat_has_five_hour_room
test_a_crossing_never_moves_onto_a_seat_with_no_more_headroom
test_a_crossing_still_moves_onto_a_seat_that_is_genuinely_better
test_the_destination_minimum_still_applies_on_top_of_the_anchor_rule
test_the_lead_move_requires_measured_spend_priority
test_an_unreadable_anchor_leaves_the_absolute_rules_in_charge
test_a_walled_worker_moves_off_an_empty_seat_but_not_onto_an_equal_one
test_a_five_hour_dip_alone_never_moves_a_seat_or_the_lead
test_the_policy_ranks_the_2026_10_16_seats_without_bouncing


test_resting_worker_warning_is_once_per_entry
test_resting_warning_offers_only_the_workers_own_codex_candidate
test_extra_usage_warning_is_once_per_seat_entry
test_extra_usage_warning_rearms_when_a_seat_leaves_and_returns
test_name_of_reads_a_recorded_profile_back_as_its_seat
test_worker_destination_never_answers_the_seat_the_worker_is_on
test_worker_destination_honours_the_same_gate_a_new_launch_gets
test_worker_destination_names_when_an_empty_seat_comes_back

# --- the recorded quota tool directory ------------------------------------
#
# quota-axi can live where only a login shell reaches it, so a launch started
# by a long-lived daemon can read no quota at all and holds every time. These
# cases cover the record that closes that gap: who writes it, what exactly is
# written, and that it is checked on every read rather than trusted.

SEAT_LIB="$ROOT/bin/fm-seat-lib.sh"

# A PATH with every directory that can serve quota-axi removed, so a process
# running under it is as blind to the tool as a daemon started outside a login
# shell.
seat_blind_path() {
  local out='' entry
  local IFS=:
  # shellcheck disable=SC2086  # deliberate colon splitting of PATH
  for entry in $PATH; do
    [ -n "$entry" ] || continue
    [ ! -x "$entry/quota-axi" ] || continue
    out="${out:+$out:}$entry"
  done
  printf '%s\n' "$out"
}

test_a_dispatch_gate_read_records_the_physical_quota_tool_directory() {
  local rec out shim physical recorded
  rec=$(make_seat_case quota-tool-record)
  read_seat_case "$rec"
  mkdir -p "$SEATS_DIR/work"
  seat_logged_in "$SPEC_DIR" "$SEATS_DIR/work"
  printf 'work\n' > "$HOME_DIR/config/claude-seat"
  printf 'stop\n' > "$HOME_DIR/config/claude-seat-extra-usage"
  # A per-shell version manager reaches the installation through a directory
  # that is only a symlink into whichever installation that shell selected, so
  # the physical installation directory is the only one worth recording.
  ln -s "$FAKEBIN" "$CASE_DIR/shell-shim"
  shim="$CASE_DIR/shell-shim"
  physical=$(CDPATH='' cd -- "$FAKEBIN" && pwd -P)

  out=$(FM_HOME="$HOME_DIR" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    CLAUDE_CONFIG_DIR='' PATH="$shim:$(seat_blind_path)" "$SEAT" status 2>&1)
  expect_code 0 "$?" "reading the gate must not fail: $out"

  [ -f "$HOME_DIR/state/.quota-tool-dir" ] \
    || fail "a gate read that found quota-axi recorded no directory for the launches that cannot"
  recorded=$(cat "$HOME_DIR/state/.quota-tool-dir")
  [ "$recorded" != "$shim" ] \
    || fail "the per-shell shim directory was recorded, and it does not outlive this shell"
  [ "$recorded" = "$physical" ] \
    || fail "recorded '$recorded', expected the physical installation directory $physical"
  # Nothing in this case ever held a session lock, which is the whole point: a
  # home upgraded mid-session must not wait for its lead to restart.
  assert_absent "$HOME_DIR/state/.lock" \
    "this case must prove the record is written with no session lock involved"
  pass "seat: a dispatch-gate read records the physical directory its own PATH finds quota-axi in"
}

test_an_unconfigured_gate_records_no_quota_tool_directory() {
  local rec out
  rec=$(make_seat_case quota-tool-record-unconfigured)
  read_seat_case "$rec"
  mkdir -p "$SEATS_DIR/work"
  seat_logged_in "$SPEC_DIR" "$SEATS_DIR/work"
  printf 'work\n' > "$HOME_DIR/config/claude-seat"

  # The gate alone, with no extra-usage policy configured. Other surfaces read
  # quota because they print it; the gate reads none until it is configured,
  # and must pay nothing for the record either.
  out=$(CONFIG="$HOME_DIR/config" STATE="$HOME_DIR/state" PATH="$FAKEBIN:$PATH" \
    bash -c '. "$1/bin/fm-timeout-lib.sh"; . "$1/bin/fm-seat-lib.sh"
             . "$1/bin/fm-quota-axi-lib.sh"; fm_seat_dispatch_decision ""' seat-gate "$ROOT" 2>&1)
  assert_contains "$out" "allow policy-unset" "this case must exercise the unconfigured gate"
  assert_absent "$HOME_DIR/state/.quota-tool-dir" \
    "a gate with no policy reads no quota and must pay nothing for the record either"
  pass "seat: an unconfigured dispatch gate reads no quota and records no quota tool directory"
}

test_a_blind_process_records_nothing_and_keeps_the_existing_record() {
  local rec out kept
  rec=$(make_seat_case quota-tool-record-blind)
  read_seat_case "$rec"
  mkdir -p "$SEATS_DIR/work"
  seat_logged_in "$SPEC_DIR" "$SEATS_DIR/work"
  printf 'work\n' > "$HOME_DIR/config/claude-seat"
  printf 'stop\n' > "$HOME_DIR/config/claude-seat-extra-usage"
  printf '%s\n' "$FAKEBIN" > "$HOME_DIR/state/.quota-tool-dir"

  out=$(FM_HOME="$HOME_DIR" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    CLAUDE_CONFIG_DIR='' PATH="$(seat_blind_path)" "$SEAT" status 2>&1)
  expect_code 0 "$?" "reading the gate must not fail: $out"
  kept=$(cat "$HOME_DIR/state/.quota-tool-dir")
  [ "$kept" = "$FAKEBIN" ] \
    || fail "a process that cannot find the tool overwrote a record it knows nothing better than: '$kept'"
  pass "seat: a process that cannot find quota-axi records nothing and leaves the existing record alone"
}

test_the_recorded_quota_tool_directory_is_checked_rather_than_trusted() {
  local rec state got
  rec=$(make_seat_case quota-tool-record-checked)
  read_seat_case "$rec"
  state="$HOME_DIR/state"

  if bash -c '. "$0"; fm_seat_quota_tool_recorded "$1"' "$SEAT_LIB" "$state" >/dev/null 2>&1; then
    fail "a home with no record at all named a quota tool directory"
  fi

  printf '%s\n' "$FAKEBIN" > "$state/.quota-tool-dir"
  got=$(bash -c '. "$0"; fm_seat_quota_tool_recorded "$1"' "$SEAT_LIB" "$state") \
    || fail "a record naming a directory that holds quota-axi was refused"
  [ "$got" = "$FAKEBIN" ] || fail "read back '$got', expected $FAKEBIN"

  printf '%s\n' "$CASE_DIR/gone" > "$state/.quota-tool-dir"
  if bash -c '. "$0"; fm_seat_quota_tool_recorded "$1"' "$SEAT_LIB" "$state" >/dev/null 2>&1; then
    fail "a record naming a directory with no quota-axi in it was read as usable"
  fi

  printf 'relative/bin\n' > "$state/.quota-tool-dir"
  if bash -c '. "$0"; fm_seat_quota_tool_recorded "$1"' "$SEAT_LIB" "$state" >/dev/null 2>&1; then
    fail "a record naming a relative path was read as usable"
  fi

  # The resolver that produces the record is checked the same way: a directory
  # whose quota-axi cannot be executed, and a shell that finds no tool at all,
  # both name nothing rather than a location a launch would then fail on.
  chmod 600 "$FAKEBIN/quota-axi"
  if PATH="$FAKEBIN:$(seat_blind_path)" \
    bash -c '. "$0"; fm_seat_quota_tool_dir' "$SEAT_LIB" >/dev/null 2>&1; then
    fail "a directory whose quota-axi cannot be executed was resolved as usable"
  fi
  chmod 700 "$FAKEBIN/quota-axi"
  if PATH="$(seat_blind_path)" \
    bash -c '. "$0"; fm_seat_quota_tool_dir' "$SEAT_LIB" >/dev/null 2>&1; then
    fail "a shell that cannot find quota-axi itself must resolve no directory"
  fi
  pass "seat: the recorded quota tool directory is checked on every read rather than trusted"
}

test_a_dispatch_gate_read_records_the_physical_quota_tool_directory
test_an_unconfigured_gate_records_no_quota_tool_directory
test_a_blind_process_records_nothing_and_keeps_the_existing_record
test_the_recorded_quota_tool_directory_is_checked_rather_than_trusted

test_spawn_refuses_a_missing_active_seat_directory
