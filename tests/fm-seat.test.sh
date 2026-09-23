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

# make_quota_fake <fakebin> <spec>
# A fake quota-axi whose verdict per profile directory is driven by files the
# test writes. <spec> is a directory holding one file per state:
#   <spec>/oauth        newline-separated CLAUDE_CONFIG_DIR values that are logged in
#   <spec>/remaining    percent remaining reported for a logged-in profile
# An empty CLAUDE_CONFIG_DIR is spelled "(default)" in the oauth list.
# The fake reproduces the real tool's contract that matters here: an unavailable
# provider still prints a valid report AND exits non-zero.
make_quota_fake() {
  local fakebin=$1 spec=$2
  mkdir -p "$spec"
  cat > "$fakebin/quota-axi" <<SH
#!/usr/bin/env bash
set -u
spec="$spec"
key="\${CLAUDE_CONFIG_DIR:-}"
[ -n "\$key" ] || key='(default)'
remaining=\$(cat "\$spec/remaining" 2>/dev/null || printf '80')
if [ -f "\$spec/oauth" ] && grep -Fxq "\$key" "\$spec/oauth"; then
  cat <<JSON
{"generatedAt":"2026-01-01T00:00:00Z","schemaVersion":5,"providers":[{"provider":"claude","label":"Claude","source":"oauth","account":{"email":"seat-\$(printf '%s' "\$key" | tr -c 'a-zA-Z0-9' '-')@example.test"},"quotaSemantics":{"status":"known","effectiveAvailability":[{"status":"known","effectivePercentRemaining":\$remaining,"runway":{"status":"through_reset"}}]}}]}
JSON
  exit 0
fi
cat <<'JSON'
{"generatedAt":"2026-01-01T00:00:00Z","schemaVersion":5,"providers":[{"provider":"claude","label":"Claude","source":"unavailable","windows":[],"state":{"status":"error","error":"keychain_unreachable"},"quotaSemantics":{"status":"unknown","effectiveAvailability":[]}}]}
JSON
exit 1
SH
  chmod +x "$fakebin/quota-axi"
}

# make_seat_case <name>
# A home with a seats root of its own plus a fake quota-axi. Echoes a record.
make_seat_case() {
  local name=$1 case_dir home seats fakebin spec
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  seats="$case_dir/seats"
  spec="$case_dir/quota-spec"
  mkdir -p "$home/config" "$home/state" "$home/data" "$seats"
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
run_seat() {
  local home=$1 fakebin=$2
  shift 2
  FM_HOME="$home" FM_CONFIG_OVERRIDE="$home/config" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" CLAUDE_CONFIG_DIR='' \
    PATH="$fakebin:$PATH" "$SEAT" "$@" 2>&1
}

# seat_logged_in <spec> <value...>
# Declare which profiles the fake reports as logged in.
seat_logged_in() {
  local spec=$1
  shift
  printf '%s\n' "$@" > "$spec/oauth"
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
  assert_contains "$out" "auto-switch threshold: (unset" \
    "no threshold may be configured by default"
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

  out=$(run_seat "$HOME_DIR" "$FAKEBIN" switch spare --force)
  status=$?
  expect_code 1 "$status" "--force must not override a profile proven to have no credentials"
  assert_contains "$out" "not logged in" "the forced refusal must still name the cause"
  assert_absent "$HOME_DIR/config/claude-seat" "a refused forced switch must change nothing"
  pass "--force does not override a seat proven to be logged out"
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
  mkdir -p "$SEATS_DIR/spare"
  seat_logged_in "$SPEC_DIR" '(default)'

  out=$(run_seat "$HOME_DIR" "$FAKEBIN" switch --next)
  status=$?
  expect_code 1 "$status" "rotation with no other logged-in seat must refuse"
  assert_contains "$out" "no other logged-in seat" "the refusal must name the cause"
  assert_absent "$HOME_DIR/config/claude-seat" "a refused rotation must change nothing"
  pass "rotation refuses rather than pretending to switch when no other seat is usable"
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
  fm_test_spawn_brief "$home" "$id"
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
    fm_test_run_spawn "$home" "$wt" "$fakebin" "$@" --mode no-mistakes --yolo off
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
  fm_test_spawn_brief "$HOME_DIR" "$id2"
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

  # No seat configured, but firstmate itself runs under a non-default profile.
  # That predates seats and must keep working: the worker gets the same store.
  : > "$LAUNCH_LOG"
  out=$(FM_TEST_CLAUDE_CONFIG_DIR="$CASE_DIR/ambient-profile" \
    FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" \
    fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1)
  expect_code 0 "$?" "a spawn under an ambient config dir should succeed: $out"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "CLAUDE_CONFIG_DIR='$CASE_DIR/ambient-profile'" \
    "firstmate's own config dir must still reach the worker when no seat is configured"
  assert_grep "claude_seat=$CASE_DIR/ambient-profile" "$HOME_DIR/state/$id.meta" \
    "the ambient store must be recorded as this task's seat so a relaunch keeps it"
  pass "an ambient CLAUDE_CONFIG_DIR still reaches workers and is recorded per task"
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
    fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1)
  expect_code 0 "$?" "a spawn with both a seat and an ambient dir should succeed: $out"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "CLAUDE_CONFIG_DIR='$SEATS_DIR/work'" \
    "the configured seat must win over firstmate's ambient config dir"
  assert_not_contains "$launch" "$CASE_DIR/ambient-profile" \
    "the ambient config dir must not also appear in the launch"
  pass "a configured seat takes precedence over firstmate's own ambient config dir"
}

test_absent_setting_is_the_default_seat
test_switch_to_logged_in_seat_updates_only_the_setting
test_switch_to_seat_that_is_not_logged_in_is_refused
test_forced_switch_cannot_override_a_proven_negative
test_switch_back_to_default_clears_the_setting
test_threshold_is_configurable_and_absent_by_default
test_threshold_reached_is_edge_triggered_by_the_configured_percent
test_unreadable_quota_never_reports_the_threshold_reached
test_rotation_picks_the_next_logged_in_seat
test_rotation_never_targets_the_default_profile
test_rotation_reads_the_seat_set_fresh
test_rotation_refuses_when_there_is_nowhere_to_go
test_add_creates_the_profile_directory_without_touching_credentials
test_a_directory_named_default_is_not_offered_as_a_seat
test_seat_names_that_escape_the_seats_root_are_refused
test_spawn_without_a_seat_sets_no_config_dir
test_spawn_uses_the_active_seat_and_records_it
test_switching_seats_does_not_move_a_running_worker
test_a_later_spawn_uses_the_new_seat_while_the_old_task_keeps_its_own
test_ambient_config_dir_still_reaches_workers_when_no_seat_is_set
test_active_seat_overrides_the_ambient_config_dir

echo "# all fm-seat tests passed"
