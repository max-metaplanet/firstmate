#!/usr/bin/env bash
# tests/fm-quota-wall.test.sh - the vendor quota wall (bin/fm-quota-wall-lib.sh):
# a worker that is already running and stops because its seat ran out of credits
# or hit a usage limit.
#
# Two properties are protected here, and they pull in opposite directions.
#
# RECOGNITION must fire on the real thing. The frames under
# tests/captures/codex-v0.162.0/ and tests/captures/claude-v2.1.301/ carry
# unchanged vendor banner strings taken from each shipped artifact (their READMEs
# own the provenance and the limits), so these cases prove the classifier against
# the vendors' own text rather than against wording invented here. The companion
# guard tests/fm-quota-wall-banners-live-e2e.test.sh re-reads those artifacts, so
# a vendor string dropped in an upgrade fails loudly instead of quietly turning
# the detector off while every assertion below still passes.
#
# THE ACTION must stay bounded. A pane read can be wrong, so the move is allowed
# once per task per episode, is refused while a no-mistakes run is live, and
# raises exactly one outcome either way. These cases drive the real library
# through its real interfaces, with the two commands it shells out to replaced by
# fakes that record what they were asked for, and never inspect its source.
#
# Seat CANDIDACY is deliberately not re-tested here: it belongs to
# bin/fm-seat.sh's worker-destination, and tests/fm-seat.test.sh covers the
# excluded, resting, signed-out, proven-empty and below-minimum refusals against
# the real chooser.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-quota-wall)
CAPTURES="$ROOT/tests/captures"

# shellcheck source=bin/fm-quota-wall-lib.sh
. "$ROOT/bin/fm-quota-wall-lib.sh"

# --- recognition ------------------------------------------------------------

# detect_frame <harness> <fixture-path>
detect_frame() {
  fm_quota_wall_detect "$1" "$(cat "$2")"
}

test_recorded_vendor_frames_classify() {
  local out
  out=$(detect_frame codex "$CAPTURES/codex-v0.162.0/out-of-credits.pane") \
    || fail 'a recorded Codex out-of-credits frame must be recognized'
  assert_contains "$out" 'codex out-of-credits' 'the credit wall must classify as out-of-credits'

  out=$(detect_frame codex "$CAPTURES/codex-v0.162.0/usage-limit.pane") \
    || fail 'a recorded Codex usage-limit frame must be recognized'
  assert_contains "$out" 'codex usage-limit' 'the Codex usage wall must classify as usage-limit'

  # The vendor mixes apostrophe forms within one build, so the raw multi-byte
  # form must match through the same one needle list.
  out=$(detect_frame codex "$CAPTURES/codex-v0.162.0/usage-limit-typographic.pane") \
    || fail "a Codex banner using the typographic apostrophe must be recognized"
  assert_contains "$out" 'codex usage-limit' 'the typographic variant must classify as usage-limit'

  out=$(detect_frame claude "$CAPTURES/claude-v2.1.301/usage-limit.pane") \
    || fail 'a recorded Claude usage-limit frame must be recognized'
  assert_contains "$out" 'claude usage-limit' 'the Claude usage wall must classify as usage-limit'

  # Both strings are present in this frame; the more specific class must win, or
  # a capped extra-usage stop would be reported as an ordinary limit that will
  # reset on its own.
  out=$(detect_frame claude "$CAPTURES/claude-v2.1.301/extra-usage-stop.pane") \
    || fail 'a recorded Claude extra-usage stop must be recognized'
  assert_contains "$out" 'claude extra-usage' 'a capped extra-usage stop must classify as extra-usage'

  pass 'every recorded vendor frame classifies as its own wall class'
}

test_an_unrecognised_stop_is_not_a_wall() {
  detect_frame claude "$CAPTURES/claude-v2.1.301/idle-no-wall.pane" \
    && fail 'an ordinary idle frame must not be read as a quota wall'
  fm_quota_wall_detect claude '' \
    && fail 'an unreadable capture must not be read as a quota wall'
  fm_quota_wall_detect grok "$(cat "$CAPTURES/claude-v2.1.301/usage-limit.pane")" \
    && fail 'a harness with no recorded banner text must never be classified'
  pass 'an idle pane with no vendor banner, an empty capture, and an unknown harness are not walls'
}

test_crew_state_line_is_the_deciding_read() {
  local detail line out
  detail=$(fm_quota_wall_detail codex out-of-credits 'Your workspace is out of credits')
  line="state: quota-blocked · source: pane · $detail · seat profile: /seats/codex-max2"
  out=$(fm_quota_wall_line_class "$line")
  [ "$out" = 'wall codex out-of-credits Your workspace is out of credits' ] \
    || fail "a quota-blocked line must yield its own vendor, class and matched text, got: $out"

  out=$(fm_quota_wall_line_class 'state: working · source: run-step · run: 01ABC · step: fixing')
  [ "$out" = pipeline-live ] || fail "a live run step must read as pipeline-live, got: $out"
  out=$(fm_quota_wall_line_class 'state: parked · source: run-step · run: 01ABC · gate: review')
  [ "$out" = pipeline-live ] || fail "a parked gate must read as pipeline-live, got: $out"

  out=$(fm_quota_wall_line_class 'state: working · source: pane · harness busy (record)')
  [ "$out" = other ] || fail "a busy pane must not read as pipeline-live, got: $out"
  out=$(fm_quota_wall_line_class 'state: unknown · source: none · worktree gone')
  [ "$out" = other ] || fail "an unknown verdict must read as other, got: $out"
  out=$(fm_quota_wall_line_class 'not a state line at all')
  [ "$out" = other ] || fail "an unparseable line must read as other, got: $out"

  # A detail this library cannot recognize is not a verdict it produced, so it
  # must not license a move.
  out=$(fm_quota_wall_line_class 'state: quota-blocked · source: pane · quota wall: acme mystery (matched "x")')
  [ "$out" = other ] || fail "an unknown vendor in the detail must read as other, got: $out"
  out=$(fm_quota_wall_line_class 'state: quota-blocked · source: pane · quota wall: codex out-of-credits')
  [ "$out" = other ] || fail "a detail with no matched text must read as other, got: $out"
  pass 'the authoritative line decides, and only a detail this library minted is acted on'
}

# --- the bounded recovery ---------------------------------------------------

# make_case <name> [destination-seat]
# A home with a task record, plus fakes for the two commands the library shells
# out to. With no destination seat the fake refuses like a real chooser with
# nowhere to go: per-seat reasons on stderr and a nonzero exit.
make_case() {
  local name=$1 destination=${2:-} case_dir home bin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  bin="$case_dir/bin"
  mkdir -p "$home/state" "$home/config" "$bin"
  cat > "$home/state/task.meta" <<'META'
window=default:w1:p1
worktree=/tmp/does-not-matter
harness=codex
kind=ship
codex_seat=/seats/codex-max2
backend=herdr
META
  cat > "$bin/seat" <<SEATFAKE
#!/usr/bin/env bash
set -u
printf '%s\n' "\$*" >> "$case_dir/seat.calls"
cmd=''
for a in "\$@"; do
  case "\$a" in name-of|worker-destination) cmd=\$a ;;
  esac
done
case "\$cmd" in
  name-of) printf 'codex-max2\n' ;;
  worker-destination)
    if [ -n "$destination" ]; then
      printf '%s\n' "$destination"
    else
      printf 'seat codex-max: skipped, its quota is used up; the seat comes back at 2026-10-20T00:00:00Z\n' >&2
      printf 'seat codex-spare: skipped, excluded from automatic rotation\n' >&2
      exit 1
    fi
    ;;
  *) exit 64 ;;
esac
SEATFAKE
  cat > "$bin/control" <<CONTROLFAKE
#!/usr/bin/env bash
set -u
printf '%s\n' "\$*" >> "$case_dir/control.calls"
[ -z "\${QUOTA_WALL_FAKE_CONTROL_FAIL:-}" ] || {
  printf 'error: seat is not logged in\n' >&2
  exit 1
}
CONTROLFAKE
  chmod +x "$bin/seat" "$bin/control"
  printf '%s|%s|%s\n' "$case_dir" "$home" "$bin"
}

# make_case runs in a command substitution, so the overrides are bound here, in
# the caller's own shell, where the library will actually read them.
read_case() {
  IFS='|' read -r CASE_DIR HOME_DIR BIN_DIR <<EOF
$1
EOF
  export FM_QUOTA_WALL_SEAT_BIN="$BIN_DIR/seat"
  export FM_QUOTA_WALL_CONTROL_BIN="$BIN_DIR/control"
}

WALL_LINE=''
set_wall_line() {
  WALL_LINE="state: quota-blocked · source: pane · $(fm_quota_wall_detail codex out-of-credits 'Your workspace is out of credits')"
}

# recover <home> <line>
recover() {
  fm_quota_wall_recover "$1" "$1/state" task codex \
    "$(cat "$CAPTURES/codex-v0.162.0/out-of-credits.pane")" "$2"
}

test_a_walled_worker_is_moved_to_a_seat_with_headroom() {
  local rc=0 note
  read_case "$(make_case move codex-max)"
  set_wall_line
  recover "$HOME_DIR" "$WALL_LINE" || rc=$?
  expect_code 0 "$rc" 'a recognized wall with a destination must be handled'
  [ "$FM_QUOTA_WALL_STATUS" = moved ] \
    || fail "the worker must be moved, got status '$FM_QUOTA_WALL_STATUS'"
  assert_contains "$FM_QUOTA_WALL_REPORT" 'codex-max2' 'the outcome must name the seat it came off'
  assert_contains "$FM_QUOTA_WALL_REPORT" 'codex-max' 'the outcome must name the seat it moved to'
  assert_contains "$FM_QUOTA_WALL_REPORT" 'uncommitted work' 'the outcome must say the work was preserved'

  assert_grep 'relaunch --seat codex-max' "$CASE_DIR/control.calls" \
    'the move must go through the relaunch transaction with the chosen seat'
  assert_grep '--note-file' "$CASE_DIR/control.calls" \
    'the replacement worker must be given a handoff note'
  assert_grep 'worker-destination --from codex-max2' "$CASE_DIR/seat.calls" \
    'the destination must be asked for anchored on the seat the worker was on'

  note=$(cat "$(fm_quota_wall_note_path "$HOME_DIR/state" task)")
  assert_contains "$note" 'out-of-credits' 'the note must state the class of wall that stopped the worker'
  assert_contains "$note" 'Your workspace is out of credits' 'the note must quote the vendor text it matched'
  assert_contains "$note" 'codex-max' 'the note must name where the work now runs'
  assert_contains "$note" 'Do not repeat work that is already complete.' \
    'the note must tell the replacement not to redo finished work'
  assert_not_contains "$note" 'captain' 'a generated worker artifact must never address the captain'
  pass 'a walled worker is relaunched on a seat with headroom, with its work preserved and the cause recorded'
}

test_only_one_automatic_move_per_episode() {
  local rc=0 calls
  read_case "$(make_case once codex-max)"
  set_wall_line
  recover "$HOME_DIR" "$WALL_LINE" || fail 'the first poll must move the worker'
  [ "$FM_QUOTA_WALL_STATUS" = moved ] || fail 'the first poll must report the move'
  calls=$(wc -l < "$CASE_DIR/control.calls" | tr -d '[:space:]')

  recover "$HOME_DIR" "$WALL_LINE" || rc=$?
  expect_code 0 "$rc" 'a second sighting of the same wall must still be handled'
  [ "$FM_QUOTA_WALL_STATUS" = spent ] \
    || fail "the same episode must not act twice, got status '$FM_QUOTA_WALL_STATUS'"
  [ -z "$FM_QUOTA_WALL_REPORT" ] \
    || fail "an already-answered wall must be silent, got: $FM_QUOTA_WALL_REPORT"
  [ "$(wc -l < "$CASE_DIR/control.calls" | tr -d '[:space:]')" = "$calls" ] \
    || fail 'the second sighting must not relaunch the worker again'
  pass 'one wall gets one automatic move and then stays silent'
}

test_a_later_episode_gets_its_own_move() {
  local record
  read_case "$(make_case later codex-max)"
  set_wall_line
  recover "$HOME_DIR" "$WALL_LINE" || fail 'the first episode must move the worker'
  record=$(fm_quota_wall_record_path "$HOME_DIR/state" task)
  # Age the record past the episode window: the same seat walling out again
  # after its window reset is a new condition, not the same one re-reported.
  sed 's/^at=.*/at=1000000000/' "$record" > "$record.aged" && mv "$record.aged" "$record"
  recover "$HOME_DIR" "$WALL_LINE" || fail 'a new episode must be handled'
  [ "$FM_QUOTA_WALL_STATUS" = moved ] \
    || fail "a wall outside the episode window must get its own move, got '$FM_QUOTA_WALL_STATUS'"
  [ "$(wc -l < "$CASE_DIR/control.calls" | tr -d '[:space:]')" = 2 ] \
    || fail 'the new episode must drive its own relaunch'
  pass 'a seat that walls out again in a later episode gets its own single move'
}

test_no_seat_with_headroom_raises_one_decision() {
  local rc=0
  read_case "$(make_case nowhere)"
  set_wall_line
  recover "$HOME_DIR" "$WALL_LINE" || rc=$?
  expect_code 0 "$rc" 'a wall with nowhere to go must still be handled'
  [ "$FM_QUOTA_WALL_STATUS" = no-destination ] \
    || fail "no destination must report itself, got '$FM_QUOTA_WALL_STATUS'"
  assert_contains "$FM_QUOTA_WALL_REPORT" 'codex-max2' 'the decision must name the walled seat'
  assert_contains "$FM_QUOTA_WALL_REPORT" 'codex-max' 'the decision must name every seat considered'
  assert_contains "$FM_QUOTA_WALL_REPORT" '2026-10-20T00:00:00Z' \
    'the decision must say when a used-up seat comes back'
  assert_contains "$FM_QUOTA_WALL_REPORT" 'codex-spare' 'the decision must name a withheld seat too'
  [ ! -f "$CASE_DIR/control.calls" ] || fail 'nothing may be relaunched when no seat qualifies'

  recover "$HOME_DIR" "$WALL_LINE" || fail 'a repeat sighting must still be handled'
  [ "$FM_QUOTA_WALL_STATUS" = spent ] \
    || fail "the decision must be raised once per episode, got '$FM_QUOTA_WALL_STATUS'"
  [ -z "$FM_QUOTA_WALL_REPORT" ] || fail 'the decision must not be re-raised on every poll'
  pass 'with no seat left the one decision names every seat and its reset, once per episode'
}

test_a_live_pipeline_run_is_reported_and_never_moved() {
  read_case "$(make_case live codex-max)"
  set_wall_line
  recover "$HOME_DIR" 'state: working · source: run-step · run: 01ABC · step: fixing' \
    || fail 'a wall beside a live run must be handled rather than left to the stale ladder'
  [ "$FM_QUOTA_WALL_STATUS" = pipeline-live ] \
    || fail "a live run must be reported, got '$FM_QUOTA_WALL_STATUS'"
  assert_contains "$FM_QUOTA_WALL_REPORT" 'still live' 'the report must say why nothing moved'
  [ ! -f "$CASE_DIR/control.calls" ] \
    || fail 'a relaunch must never orphan a live validation run'

  recover "$HOME_DIR" 'state: working · source: run-step · run: 01ABC · step: fixing' \
    || fail 'a repeat sighting must still be handled'
  [ "$FM_QUOTA_WALL_STATUS" = spent ] || fail 'the live-run report must be raised once per episode'
  [ -z "$FM_QUOTA_WALL_REPORT" ] || fail 'the live-run report must not repeat every poll'

  # The report does not spend the move: once the run is no longer live, the same
  # episode must still rescue the worker.
  recover "$HOME_DIR" "$WALL_LINE" || fail 'the wall must be handled once the run is gone'
  [ "$FM_QUOTA_WALL_STATUS" = moved ] \
    || fail "reporting a live run must not forfeit the episode's move, got '$FM_QUOTA_WALL_STATUS'"
  assert_grep 'relaunch --seat codex-max' "$CASE_DIR/control.calls" \
    'the deferred move must still happen through the relaunch transaction'
  pass 'a live validation run is reported once and keeps the move for when it ends'
}

test_an_unreadable_verdict_is_left_to_ordinary_triage() {
  local rc=0
  read_case "$(make_case other codex-max)"
  recover "$HOME_DIR" 'state: unknown · source: none · no current-state source available' || rc=$?
  expect_code 1 "$rc" 'a verdict that is neither a wall nor a live run must not be handled here'
  [ ! -f "$CASE_DIR/control.calls" ] || fail 'nothing may be relaunched on an unreadable verdict'

  rc=0
  fm_quota_wall_recover "$HOME_DIR" "$HOME_DIR/state" task codex \
    "$(cat "$CAPTURES/claude-v2.1.301/idle-no-wall.pane")" \
    'state: unknown · source: none · no current-state source available' || rc=$?
  expect_code 1 "$rc" 'an idle pane with no vendor banner must stay on the existing stale path'
  pass 'an unrecognised stop is left to ordinary triage, unchanged'
}

test_a_failed_move_is_reported_and_not_retried() {
  read_case "$(make_case failed codex-max)"
  set_wall_line
  QUOTA_WALL_FAKE_CONTROL_FAIL=1 recover "$HOME_DIR" "$WALL_LINE" \
    || fail 'a failed move must still be handled rather than silently dropped'
  [ "$FM_QUOTA_WALL_STATUS" = refused ] \
    || fail "a failed relaunch must be reported, got '$FM_QUOTA_WALL_STATUS'"
  assert_contains "$FM_QUOTA_WALL_REPORT" 'failed' 'the report must say the move failed'
  assert_contains "$FM_QUOTA_WALL_REPORT" 'not logged in' "the report must carry the transaction's own reason"

  recover "$HOME_DIR" "$WALL_LINE" || fail 'the next sighting must still be handled'
  [ "$FM_QUOTA_WALL_STATUS" = spent ] \
    || fail 'a half-finished move must not be attempted again inside the same episode'
  pass 'a failed move is reported with its reason and never retried inside the episode'
}

test_recorded_vendor_frames_classify
test_an_unrecognised_stop_is_not_a_wall
test_crew_state_line_is_the_deciding_read
test_a_walled_worker_is_moved_to_a_seat_with_headroom
test_only_one_automatic_move_per_episode
test_a_later_episode_gets_its_own_move
test_no_seat_with_headroom_raises_one_decision
test_a_live_pipeline_run_is_reported_and_never_moved
test_an_unreadable_verdict_is_left_to_ordinary_triage
test_a_failed_move_is_reported_and_not_retried
