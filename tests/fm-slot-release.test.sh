#!/usr/bin/env bash
# bin/fm-slot-release.sh: the supported, non-forced way out of a working copy
# that two task records both name.
#
# bin/fm-teardown.sh refuses to return a copy another record names, and that
# refusal is symmetric, so a collision deadlocks both records and no supported
# command breaks the pair (observed 2026-09-24). This command breaks it by
# removing ONE line from ONE record - and only when the copy is proved to hold
# nothing that releasing could cost, because releasing is what lets the other
# record's cleanup reset that copy.
#
# What these cases pin:
#   1. It refuses when there is no collision at all: an ordinary stale record is
#      cleanup's job, not this command's.
#   2. It refuses on uncommitted changes and on unlanded commits, changing
#      nothing. There is no --force to get past either.
#   3. It accepts commits that are not on a remote but whose content already
#      landed on the default branch - it reuses teardown's landed-work test, not
#      a bare "nothing unpushed" rule.
#   4. On a clean copy it disclaims the copy on exactly the named record -
#      keeping the copy PATH, which endpoint validation still needs - leaves the
#      other record and the copy itself untouched, and clears the collision the
#      two records were deadlocked on.
#   4b. A record that has already released is not a candidate again.
#   5. It refuses to release the record the copy's own slot-owner claim names,
#      because that record is the copy's proven owner, and names the other one.
#   6. It refuses on a second mate's home record.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

RELEASE="$ROOT/bin/fm-slot-release.sh"
TMP_ROOT=$(fm_test_tmproot fm-slot-release)

# make_collision <name> builds a home, a project with a local bare origin and a
# linked worktree standing in for the shared copy, and TWO task records naming
# that copy: `holder` (the record under test) and `other`.
# Echoes case-dir|home|project|worktree|fakebin.
make_collision() {
  local name=$1 case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/slot/repo"
  fakebin=$(fm_fakebin "$case_dir/fake")
  # The landed-work test asks the forge before falling back to the content
  # check; a forge that answers nothing keeps every case hermetic and fast.
  fm_fake_exit1 "$fakebin" gh gh-axi
  mkdir -p "$home/data" "$home/state" "$home/config" "$case_dir/slot"
  fm_git_worktree "$proj" "$wt" "fm-holder"
  write_task_record "$home" holder "$wt" "$proj" ship
  write_task_record "$home" other "$wt" "$proj" scout
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin"
}

fm_fake_exit1() {
  local fakebin=$1 tool
  shift
  for tool in "$@"; do
    printf '#!/usr/bin/env bash\nexit 1\n' > "$fakebin/$tool"
    chmod +x "$fakebin/$tool"
  done
}

write_task_record() {  # <home> <id> <worktree> <project> <kind>
  local home=$1 id=$2 wt=$3 proj=$4 kind=$5
  fm_write_meta "$home/state/$id.meta" \
    "window=fmses:fm-$id" \
    "endpoint_task_id=$id" \
    "worktree=$wt" \
    "project=$proj" \
    "harness=claude" \
    "kind=$kind" \
    "mode=no-mistakes" \
    "yolo=off"
}

# assert_grep is a fixed-string match, so an anchored line check needs a real
# regex rather than a literal that could never match.
assert_record_released() {  # <meta> <msg>
  grep -q '^worktree_claim=released$' "$1" || fail "$2"
  # The copy PATH must survive: bin/fm-backend.sh refuses to validate an
  # endpoint whose record has no worktree=, so dropping it would only move the
  # wedge rather than clear it.
  grep -q '^worktree=' "$1" || fail "$2 (the record lost the copy path it still needs)"
}

assert_record_not_released() {  # <meta> <msg>
  ! grep -q '^worktree_claim=released$' "$1" || fail "$2"
}

read_collision() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<EOF
$1
EOF
}

run_release() {  # <task-id>
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$RELEASE" "$@" 2>&1
}

test_refuses_when_no_other_record_names_the_copy() {
  local rec out status
  rec=$(make_collision no-collision)
  read_collision "$rec"
  rm -f "$HOME_DIR/state/other.meta"

  out=$(run_release holder)
  status=$?
  [ "$status" -ne 0 ] || fail "release acted on a record that collides with nothing"$'\n'"$out"
  assert_contains "$out" "no other task record names" \
    "the refusal did not say there was no collision to resolve"
  assert_contains "$out" "bin/fm-teardown.sh holder" \
    "the refusal did not point back at ordinary cleanup"
  assert_record_not_released "$HOME_DIR/state/holder.meta" \
    "a refused release changed the record"
  pass "a record that collides with nothing is refused and sent back to cleanup"
}

test_refuses_an_uncommitted_change_in_the_shared_copy() {
  local rec out status
  rec=$(make_collision dirty-copy)
  read_collision "$rec"
  printf 'work in progress\n' > "$WT_DIR/wip.txt"
  git -C "$WT_DIR" add wip.txt

  out=$(run_release holder)
  status=$?
  [ "$status" -ne 0 ] || fail "release exposed an uncommitted change to the other record's cleanup"$'\n'"$out"
  assert_contains "$out" "has uncommitted changes" \
    "the refusal did not name the uncommitted work"
  assert_contains "$out" "never discards work and has no --force" \
    "the refusal did not say there is no way to force past it"
  assert_record_not_released "$HOME_DIR/state/holder.meta" \
    "a refused release changed the record"
  pass "an uncommitted change in the shared copy refuses the release"
}

test_refuses_a_commit_that_is_neither_pushed_nor_landed() {
  local rec out status
  rec=$(make_collision unlanded-commit)
  read_collision "$rec"
  printf 'only here\n' > "$WT_DIR/unlanded.txt"
  git -C "$WT_DIR" add unlanded.txt
  git -C "$WT_DIR" -c user.name=t -c user.email=t@example.invalid commit -qm 'unlanded work'

  out=$(run_release holder)
  status=$?
  [ "$status" -ne 0 ] || fail "release exposed an unlanded commit to the other record's cleanup"$'\n'"$out"
  assert_contains "$out" "not on any remote and not landed" \
    "the refusal did not name the unlanded commit"
  assert_contains "$out" "unlanded work" \
    "the refusal did not show which commits are at risk"
  assert_record_not_released "$HOME_DIR/state/holder.meta" \
    "a refused release changed the record"
  pass "a commit that is neither pushed nor landed refuses the release"
}

test_accepts_a_commit_whose_content_already_landed() {
  local rec out status
  rec=$(make_collision landed-content)
  read_collision "$rec"
  # The same change on both sides: the branch commit is on no remote, but the
  # default branch already contains its content, which is exactly the case
  # teardown's landed-work test exists to recognise.
  printf 'shipped\n' > "$PROJ_DIR/landed.txt"
  git -C "$PROJ_DIR" add landed.txt
  git -C "$PROJ_DIR" -c user.name=t -c user.email=t@example.invalid commit -qm 'landed work'
  git -C "$PROJ_DIR" push -q origin main
  printf 'shipped\n' > "$WT_DIR/landed.txt"
  git -C "$WT_DIR" add landed.txt
  git -C "$WT_DIR" -c user.name=t -c user.email=t@example.invalid commit -qm 'landed work'

  out=$(run_release holder)
  status=$?
  expect_code 0 "$status" "release refused a commit whose content already landed"$'\n'"$out"
  assert_record_released "$HOME_DIR/state/holder.meta" \
    "the released record still claims the copy"
  pass "a commit that is unpushed but already landed does not block the release"
}

test_releases_one_record_and_leaves_everything_else_alone() {
  local rec out status before after
  rec=$(make_collision clean-release)
  read_collision "$rec"
  # An untracked .claude/ directory is a worker's own leftover, never work:
  # teardown ignores it and so must this proof.
  mkdir -p "$WT_DIR/.claude"
  printf '{}\n' > "$WT_DIR/.claude/settings.json"
  before=$(git -C "$WT_DIR" rev-parse HEAD)

  out=$(run_release holder)
  status=$?
  expect_code 0 "$status" "release refused a clean copy"$'\n'"$out"
  assert_contains "$out" "no longer claims working copy" \
    "the release did not report what it changed"
  assert_record_released "$HOME_DIR/state/holder.meta" \
    "the released record still claims the copy"
  assert_grep "kind=ship" "$HOME_DIR/state/holder.meta" \
    "the release removed more than the copy claim"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/other.meta" \
    "the release disturbed the other record"
  assert_record_not_released "$HOME_DIR/state/other.meta" \
    "the release disclaimed the wrong record"
  after=$(git -C "$WT_DIR" rev-parse HEAD)
  assert_equals "$before" "$after" "the release moved the copy's HEAD"
  [ -f "$WT_DIR/.claude/settings.json" ] || fail "the release touched the copy's contents"

  # The deadlock is what had to be broken: the other record no longer collides
  # with anything, so its own cleanup is unblocked.
  out=$(run_release other)
  status=$?
  [ "$status" -ne 0 ] || fail "the second record was itself released instead of being freed for cleanup"$'\n'"$out"
  assert_contains "$out" "no other task record names" \
    "the collision survived the release"
  pass "a clean copy releases exactly one record's claim and clears the deadlock"
}

test_a_released_record_is_not_a_candidate_again() {
  local rec out status
  rec=$(make_collision already-released)
  read_collision "$rec"
  run_release holder >/dev/null || fail "setup release should succeed"

  out=$(run_release holder)
  status=$?
  [ "$status" -ne 0 ] || fail "release acted twice on the same record"$'\n'"$out"
  assert_contains "$out" "already released its claim" \
    "the refusal did not say the record had already released"
  pass "a record that already released is refused rather than released twice"
}

test_refuses_to_release_the_copys_proven_owner() {
  local rec out status
  rec=$(make_collision proven-owner)
  read_collision "$rec"
  printf 'task=holder\nhome=%s\n' "$HOME_DIR" > "$CASE_DIR/slot/.fm-slot-owner"

  out=$(run_release holder)
  status=$?
  [ "$status" -ne 0 ] || fail "release stranded the copy by releasing its proven owner"$'\n'"$out"
  assert_contains "$out" "proven owner" \
    "the refusal did not say why this record keeps the copy"
  assert_contains "$out" "bin/fm-slot-release.sh other" \
    "the refusal did not name the record to release instead"
  assert_record_not_released "$HOME_DIR/state/holder.meta" \
    "a refused release changed the record"
  pass "the record a copy's own claim names is refused, and the other one is named instead"
}

test_refuses_a_second_mates_home_record() {
  local rec out status
  rec=$(make_collision secondmate-home)
  read_collision "$rec"
  fm_write_secondmate_meta "$HOME_DIR/state/holder.meta" "$WT_DIR"

  out=$(run_release holder)
  status=$?
  [ "$status" -ne 0 ] || fail "release un-named a second mate's own home"$'\n'"$out"
  assert_contains "$out" "second mate" \
    "the refusal did not say a second mate's home is retired another way"
  assert_record_not_released "$HOME_DIR/state/holder.meta" \
    "a refused release changed the record"
  pass "a second mate's home record is refused and routed to its own retirement path"
}

test_refuses_when_no_other_record_names_the_copy
test_refuses_an_uncommitted_change_in_the_shared_copy
test_refuses_a_commit_that_is_neither_pushed_nor_landed
test_accepts_a_commit_whose_content_already_landed
test_releases_one_record_and_leaves_everything_else_alone
test_a_released_record_is_not_a_candidate_again
test_refuses_to_release_the_copys_proven_owner
test_refuses_a_second_mates_home_record

echo "# all fm-slot-release tests passed"
