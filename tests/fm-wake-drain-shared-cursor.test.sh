#!/usr/bin/env bash
# tests/fm-wake-drain-shared-cursor.test.sh - one drain derives each task's two
# presentation cursor offsets once and shares them across every section, the
# acknowledgement and the commit, instead of each pass re-deriving them.
# This is a portable tests/ regression: the drain and the classify library make
# the whole decision over crafted status logs, so no harness is involved.
#
# What it pins is that sharing those offsets changed only how often they are
# derived. A memo that answers differently from the function it stands in for
# would move what a section prints or when the cursor advances, which is the
# failure this file exists to catch: the offsets feed the unread surface, the
# outcome backstop, and the committed manifest alike.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

DRAIN="$ROOT/bin/fm-wake-drain.sh"
CLASSIFY="$ROOT/bin/fm-classify-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-wake-drain-shared-cursor-tests)

# These regressions present status on a home that does not run the supervision
# host, so BRANCH OUTCOMES stays out of the drain and the sections under test
# are the whole output (bin/fm-supervision-engine-lib.sh owns that gate).
mkdir -p "$TMP_ROOT/config"
: > "$TMP_ROOT/config/supervision-host-off"
export FM_CONFIG_OVERRIDE="$TMP_ROOT/config"

# A multi-task fixture whose tasks differ in the way the sections care about:
# one with an unread informational note, one with an open decision, one with a
# captain-facing terminal event for the outcome backstop, and one routine task
# that must stay silent. Each task's shape exercises a different section, so a
# shared offset that is wrong for one section cannot hide behind another.
seed_fixture() {  # <state> <task-count-multiplier>
  local state=$1 copies=${2:-1} n i
  for n in $(seq 1 "$copies"); do
    i="s$n"
    printf 'working: building the exporter\n' > "$state/${i}-routine.status"
    printf 'working: reading the brief\nnote: captain said use REST not RPC\n' \
      > "$state/${i}-note.status"
    printf 'working: starting\nneeds-decision [key=api-shape]: REST or RPC\n' \
      > "$state/${i}-decision.status"
    printf 'working: implementing\ndone: PR https://example.invalid/pr/1 checks green\n' \
      > "$state/${i}-terminal.status"
  done
}

# Drain once over a bootstrap line so the manifest exists and later appends are
# genuinely new, which is the state every supervision turn after the first sees.
prime_cursor() {  # <state>
  local state=$1
  printf 'note: bootstrap cursor line\n' > "$state/prime.status"
  FM_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null 2>/dev/null \
    || fail "the priming drain failed"
}

# An identity reader that records every derivation before answering exactly as
# the built-in one does. FM_STATUS_IDENTITY_READER is the library's documented
# seam, so counting through it measures the real drain rather than its source.
install_counting_identity_reader() {  # <dir> -> echoes the reader path
  local dir=$1
  cat > "$dir/ident-reader" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$1" >> "${FM_IDENT_READER_LOG:-/dev/null}"
if [ "$(uname -s)" = Darwin ]; then
  ident=$(LC_ALL=C /usr/bin/stat -f '%d:%i' "$1" 2>/dev/null) || exit 1
else
  ident=$(LC_ALL=C stat -c '%d:%i' "$1" 2>/dev/null) || exit 1
fi
printf 'weak:%s' "$ident"
SH
  chmod +x "$dir/ident-reader"
  printf '%s\n' "$dir/ident-reader"
}

test_multi_task_fixture_prints_every_section_and_commits_one_row_per_task() {
  local dir state out tasks rows
  dir=$(make_case multi-task-sections)
  state="$dir/state"
  out="$dir/drain.out"
  prime_cursor "$state"
  seed_fixture "$state"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" 2>/dev/null \
    || fail "the drain failed on the multi-task fixture: $(cat "$out")"

  grep -F 's1-note note: captain said use REST not RPC' "$out" >/dev/null \
    || fail "the unread note was not surfaced: $(cat "$out")"
  grep -F 's1-decision [key=api-shape] needs-decision: REST or RPC' "$out" >/dev/null \
    || fail "the open decision was not folded: $(cat "$out")"
  grep -F 's1-terminal done: PR https://example.invalid/pr/1 checks green' "$out" >/dev/null \
    || fail "the captain-facing terminal event missed the outcome backstop: $(cat "$out")"
  grep -F 's1-routine' "$out" >/dev/null \
    && fail "a routine working line was surfaced: $(cat "$out")"

  # Every task the snapshot saw owns exactly one committed manifest row: a
  # shared offset recorded under the wrong task would show up as a lost or
  # duplicated row here.
  tasks=$(find "$state" -maxdepth 1 -name '*.status' | wc -l | tr -d ' ')
  rows=$(wc -l < "$state/.status-presentation-cursor" | tr -d ' ')
  assert_equals "$tasks" "$rows" "committed manifest rows per task"
  assert_equals "$tasks" "$(cut -f1 "$state/.status-presentation-cursor" | sort -u | wc -l | tr -d ' ')" \
    "distinct tasks in the committed manifest"
  pass "a multi-task drain prints every section and commits one cursor row per task"
}

test_presented_lines_are_not_replayed_by_the_next_drain() {
  local dir state first second
  dir=$(make_case no-replay-after-sharing)
  state="$dir/state"
  first="$dir/first.out"
  second="$dir/second.out"
  prime_cursor "$state"
  seed_fixture "$state"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$first" 2>/dev/null || fail "the first drain failed"
  grep -F 'captain said use REST not RPC' "$first" >/dev/null \
    || fail "setup error: the first drain did not surface the note"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$second" 2>/dev/null || fail "the second drain failed"
  grep -F 'captain said use REST not RPC' "$second" >/dev/null \
    && fail "a presented note was replayed, so the shared offset did not advance the cursor: $(cat "$second")"
  # The decision is still open, so it must still be listed: advancing the
  # presentation cursor must not retire the durable fold with it.
  grep -F 's1-decision [key=api-shape] needs-decision: REST or RPC' "$second" >/dev/null \
    || fail "the still-open decision stopped being listed after one presentation: $(cat "$second")"
  pass "a presented line is not replayed while a still-open decision keeps listing"
}

test_shared_offsets_match_what_each_function_derives_alone() {
  local dir state f task shared_presented shared_backstop alone_presented alone_backstop snapshot
  dir=$(make_case shared-matches-alone)
  state="$dir/state"
  prime_cursor "$state"
  seed_fixture "$state"
  # A second presentation so the manifest carries non-zero offsets for some
  # tasks and zero for others; an index that only ever agreed on zero would
  # prove nothing.
  FM_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null 2>/dev/null || fail "the setup drain failed"
  printf 'note: a later answer\n' >> "$state/s1-note.status"

  # For every task, the value read with the index open must equal the value the
  # same function derives with the index closed. That equality is the whole
  # contract the sharing rests on.
  FM_STATE_OVERRIDE="$state" bash -c '
    set -u
    # shellcheck disable=SC1090
    . "$1"
    state=$2
    snapshot=$(status_presentation_snapshot "$state") || exit 3
    while IFS=$(printf "\t") read -r task _size _ident; do
      [ -n "$task" ] || continue
      f="$state/$task.status"
      status_presentation_index_close
      alone_presented=$(status_presentation_cursor_offset "$f") || exit 4
      alone_backstop=$(status_outcome_backstop_cursor_offset "$f") || exit 4
      status_presentation_index_open "$state" "$snapshot"
      [ "$FM_STATUS_CURSOR_INDEX_OPEN" = true ] || exit 5
      shared_presented=$(status_presentation_cursor_offset "$f") || exit 6
      shared_backstop=$(status_outcome_backstop_cursor_offset "$f") || exit 6
      status_presentation_index_close
      [ "$shared_presented" = "$alone_presented" ] \
        || { printf "%s presented %s != %s\n" "$task" "$shared_presented" "$alone_presented"; exit 1; }
      [ "$shared_backstop" = "$alone_backstop" ] \
        || { printf "%s backstop %s != %s\n" "$task" "$shared_backstop" "$alone_backstop"; exit 1; }
    done <<EOF
$snapshot
EOF
  ' _ "$CLASSIFY" "$state" || fail "a shared cursor offset disagreed with the function that derives it alone"
  pass "every shared cursor offset equals what the function derives on its own"
}

# Bring a fixture to the state every supervision turn after the first sees:
# every task owns a committed manifest row and a backstop receipt, and has new
# bytes since. Counting on an unsettled fleet measures nothing, because the
# sections short-circuit before they reach the derivations being shared.
settle_fleet() {  # <state>
  local state=$1 f
  FM_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null 2>/dev/null || fail "the settling drain failed"
  FM_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null 2>/dev/null || fail "the second settling drain failed"
  for f in "$state"/*-note.status; do
    printf 'note: a later answer\n' >> "$f"
  done
  for f in "$state"/*-terminal.status; do
    printf 'done: PR https://example.invalid/pr/later checks green\n' >> "$f"
  done
}

count_identity_derivations_per_task() {  # <state> <reader> <log> -> per-task count
  local state=$1 reader=$2 log=$3 total tasks
  : > "$log"
  FM_IDENT_READER_LOG="$log" FM_STATUS_IDENTITY_READER="$reader" \
    FM_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null 2>/dev/null \
    || fail "the counted drain failed"
  total=$(wc -l < "$log" | tr -d ' ')
  tasks=$(find "$state" -maxdepth 1 -name '*.status' | wc -l | tr -d ' ')
  [ "$tasks" -gt 0 ] || fail "the counted fixture had no tasks"
  printf '%s\n' "$(( total / tasks ))"
}

test_an_append_after_the_snapshot_does_not_move_a_shared_offset() {
  local dir state
  dir=$(make_case append-after-snapshot)
  state="$dir/state"
  prime_cursor "$state"
  seed_fixture "$state"
  FM_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null 2>/dev/null || fail "the setup drain failed"
  printf 'note: a later answer\n' >> "$state/s1-note.status"

  # The index reuses the identity and size the snapshot captured, while an
  # uncached read stats the file again. A worker appending between the two is
  # the one moment those inputs differ, so pin that it changes no answer: the
  # offsets come from the manifest and a file that only grew cannot push one
  # past its size.
  FM_STATE_OVERRIDE="$state" bash -c '
    set -u
    # shellcheck disable=SC1090
    . "$1"
    state=$2
    snapshot=$(status_presentation_snapshot "$state") || exit 3
    printf "note: appended after the snapshot was captured\n" >> "$state/s1-note.status"
    printf "working: appended after the snapshot was captured\n" >> "$state/s1-terminal.status"
    status_presentation_index_open "$state" "$snapshot"
    [ "$FM_STATUS_CURSOR_INDEX_OPEN" = true ] || exit 5
    while IFS=$(printf "\t") read -r task _size _ident; do
      [ -n "$task" ] || continue
      f="$state/$task.status"
      shared_presented=$(status_presentation_cursor_offset "$f") || exit 6
      shared_backstop=$(status_outcome_backstop_cursor_offset "$f") || exit 6
      status_presentation_index_close
      live_presented=$(status_presentation_cursor_offset "$f") || exit 4
      live_backstop=$(status_outcome_backstop_cursor_offset "$f") || exit 4
      status_presentation_index_open "$state" "$snapshot"
      [ "$shared_presented" = "$live_presented" ] \
        || { printf "%s presented %s != %s after an append\n" "$task" "$shared_presented" "$live_presented"; exit 1; }
      [ "$shared_backstop" = "$live_backstop" ] \
        || { printf "%s backstop %s != %s after an append\n" "$task" "$shared_backstop" "$live_backstop"; exit 1; }
    done <<EOF
$snapshot
EOF
    status_presentation_index_close
  ' _ "$CLASSIFY" "$state" || fail "an append after the snapshot moved a shared cursor offset"
  pass "an append after the snapshot leaves every shared offset equal to a fresh read"
}

test_identity_is_derived_once_per_task_not_once_per_section() {
  local dir state reader small large
  dir=$(make_case identity-once-per-task)
  state="$dir/state"
  reader=$(install_counting_identity_reader "$dir")
  prime_cursor "$state"
  seed_fixture "$state" 1
  settle_fleet "$state"
  small=$(count_identity_derivations_per_task "$state" "$reader" "$dir/ident-small.log")

  # Before the sections shared one derivation, a settled fleet derived each
  # task's identity ten times per drain: once in the snapshot, three times
  # across the presentation offset reads, twice across the backstop reads,
  # twice inside the latest-event check, once in the open-decisions fold and
  # once at the commit. Sharing the two cursor offsets removes five of them.
  # The ceiling catches the old shape with headroom for the derivations that
  # are genuinely once per task, including the deliberate before/after pair
  # that detects a status file changing mid-read.
  [ "$small" -le 7 ] \
    || fail "identity was derived $small times per task; the sections are each re-deriving it instead of sharing one"

  # And it must stay per-task as the fleet grows: twice the tasks may cost
  # twice the derivations, never more per task.
  dir=$(make_case identity-scales-linearly)
  state="$dir/state"
  prime_cursor "$state"
  seed_fixture "$state" 2
  settle_fleet "$state"
  large=$(count_identity_derivations_per_task "$state" "$reader" "$dir/ident-large.log")
  [ "$large" -le "$small" ] \
    || fail "per-task identity derivations grew from $small to $large as the fleet grew"
  pass "a settled fleet derives each task's identity $small times, not once per section"
}

test_first_drain_without_a_manifest_still_presents() {
  local dir state out
  dir=$(make_case no-manifest-yet)
  state="$dir/state"
  out="$dir/drain.out"
  seed_fixture "$state"
  [ ! -e "$state/.status-presentation-cursor" ] \
    || fail "setup error: the fixture already has a cursor manifest"

  # With no manifest the offsets fall back to each task's legacy cursor file,
  # which the shared index deliberately does not carry. The drain must present
  # normally and commit a manifest anyway.
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" 2>/dev/null \
    || fail "the first-ever drain failed: $(cat "$out")"
  grep -F 's1-note note: captain said use REST not RPC' "$out" >/dev/null \
    || fail "the first-ever drain did not surface the unread note: $(cat "$out")"
  [ -s "$state/.status-presentation-cursor" ] \
    || fail "the first-ever drain committed no cursor manifest"
  pass "a first drain with no cursor manifest still presents and commits"
}

test_a_malformed_manifest_leaves_the_index_closed_and_still_fails() {
  local dir state before
  dir=$(make_case malformed-manifest)
  state="$dir/state"
  prime_cursor "$state"
  seed_fixture "$state"
  FM_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null 2>/dev/null || fail "the setup drain failed"
  before=$(cat "$state/.status-presentation-cursor")
  # A row carrying more fields than the format allows. A memo must not answer
  # over it: the index has to stay closed so the refusal still comes from the
  # function that reads the manifest, exactly as it did before the sharing.
  printf 's1-note\tweak:1:2\t0\t0\tstray-extra-field\n' >> "$state/.status-presentation-cursor"

  FM_STATE_OVERRIDE="$state" bash -c '
    set -u
    # shellcheck disable=SC1090
    . "$1"
    state=$2
    snapshot=$(status_presentation_snapshot "$state") || exit 3
    status_presentation_index_open "$state" "$snapshot"
    [ "$FM_STATUS_CURSOR_INDEX_OPEN" = false ] \
      || { echo "the index opened over a malformed manifest"; exit 1; }
    status_presentation_cursor_offset "$state/s1-note.status" >/dev/null \
      && { echo "a malformed manifest still produced a presentation offset"; exit 1; }
    status_presentation_index_close
    exit 0
  ' _ "$CLASSIFY" "$state" || fail "the shared index masked a malformed cursor manifest"

  # And the drain over it must not advance anyone's cursor.
  FM_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null 2>/dev/null
  grep -Fqx "$(printf '%s' "$before" | head -1)" "$state/.status-presentation-cursor" \
    || fail "a drain over a malformed manifest rewrote the committed cursor rows"
  pass "a malformed cursor manifest leaves the index closed and still fails the derivation"
}

test_multi_task_fixture_prints_every_section_and_commits_one_row_per_task
test_presented_lines_are_not_replayed_by_the_next_drain
test_shared_offsets_match_what_each_function_derives_alone
test_an_append_after_the_snapshot_does_not_move_a_shared_offset
test_identity_is_derived_once_per_task_not_once_per_section
test_first_drain_without_a_manifest_still_presents
test_a_malformed_manifest_leaves_the_index_closed_and_still_fails
