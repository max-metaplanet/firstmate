#!/usr/bin/env bash
# Regression test for bin/fm-spawn.sh's refusal to launch into a working copy
# that another task record already names (validate_spawn_worktree_unclaimed).
#
# Treehouse hands out a slot by what is RUNNING under it, so a slot whose worker
# exited reads free while a task record still names it. Observed 2026-09-24: a
# paused scout's agent died with a machine restart, the next spawn was handed
# the same slot, and afterwards bin/fm-teardown.sh refused BOTH records through
# its own cross-record check - a deadlock no supported command broke. The launch
# has to ask the same question of the records, and refuse before any work exists
# in the copy.
#
# What these cases pin:
#   1. A fresh launch handed a copy another record in this home names refuses,
#      names that record, and publishes no metadata of its own.
#   2. A fresh launch handed a copy a LOCAL SECONDMATE's record names refuses
#      too, and says which home holds that record: the walk covers every
#      Firstmate home on this machine, not just the launching one, and the
#      commands the refusal recommends resolve their home from FM_HOME.
#   3. A fresh launch handed an unclaimed copy still succeeds. Without this the
#      first two cases would also pass on a guard that refused everything.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-worktree-claimed)

# make_claimed_fakebin <dir>: the settle suite's pane stub, reduced to a pane
# that reports FM_FAKE_PANE_PATH from the first read (this suite is about what
# happens AFTER the worktree is resolved, not about resolving it).
make_claimed_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  fm_test_fake_sleep_noop "$fakebin"
  printf '%s\n' "$fakebin"
}

# make_case <name> <id>: a home, a project with one linked worktree standing in
# for the pool slot the pane lands in, and a filled brief for <id>.
# Echoes case-dir|home|project|worktree|fakebin.
make_case() {
  local name=$1 id=$2 case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/slot"
  fakebin=$(make_claimed_fakebin "$case_dir/fake")
  fm_test_spawn_home "$home" codex
  fm_git_worktree "$proj" "$wt" "slot-$name"
  fm_test_spawn_brief "$home" "$id" "Exercise claimed-worktree refusal for $id."
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin"
}

read_case() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<EOF
$1
EOF
}

run_case_spawn() {  # <id> [extra spawn args...]
  local id=$1
  shift
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" FM_FAKE_PANE_PATH="$WT_DIR" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$ROOT/bin/fm-spawn.sh" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off "$@" 2>&1
}

test_copy_named_by_another_record_in_this_home_is_refused() {
  local rec id out status
  id=claimed-same-home-c1
  rec=$(make_case claimed-same-home "$id")
  read_case "$rec"
  fm_write_meta "$HOME_DIR/state/stale-scout.meta" \
    "window=fmses:fm-stale-scout" \
    "endpoint_task_id=stale-scout" \
    "worktree=$WT_DIR" \
    "project=$PROJ_DIR" \
    "harness=claude" \
    "kind=scout" \
    "mode=no-mistakes" \
    "yolo=off"

  out=$(run_case_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn launched into a copy task stale-scout still records"$'\n'"$out"
  assert_contains "$out" "is already task stale-scout's recorded worktree" \
    "the refusal did not name the record that already holds the copy"
  assert_contains "$out" "bin/fm-slot-release.sh stale-scout" \
    "the refusal did not point at the supported way to resolve the collision"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "refused spawn published task metadata"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/stale-scout.meta" \
    "the refused spawn disturbed the record that holds the copy"
  pass "a launch into a copy another record in this home names is refused"
}

test_copy_named_by_a_local_secondmates_record_is_refused() {
  local rec id sub out status
  id=claimed-secondmate-c2
  rec=$(make_case claimed-secondmate "$id")
  read_case "$rec"
  sub="$CASE_DIR/sub-home"
  mkdir -p "$sub/state" "$sub/data"
  printf '%s\n' "- domain - Slot collision domain (home: $sub; scope: slot collisions; projects: alpha; added 2026-09-24)" \
    > "$HOME_DIR/data/secondmates.md"
  fm_write_meta "$sub/state/child-task.meta" \
    "window=fmses:fm-child-task" \
    "endpoint_task_id=child-task" \
    "worktree=$WT_DIR" \
    "project=$PROJ_DIR" \
    "harness=claude" \
    "kind=ship" \
    "mode=no-mistakes" \
    "yolo=off"

  out=$(run_case_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn launched into a copy a local second mate's record names"$'\n'"$out"
  assert_contains "$out" "is already task child-task's recorded worktree (in Firstmate home $sub)" \
    "the refusal did not reach the local second mate's own records, or did not say which home holds the record the operator must act on"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "refused spawn published task metadata"
  pass "a launch into a copy a local second mate's record names is refused"
}

test_unclaimed_copy_still_launches() {
  local rec id out status
  id=claimed-free-c3
  rec=$(make_case claimed-free "$id")
  read_case "$rec"

  out=$(run_case_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn refused a copy no other record names"$'\n'"$out"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "the launch did not record the copy it was handed"
  pass "a launch into a copy no other record names still succeeds"
}

test_copy_named_by_another_record_in_this_home_is_refused
test_copy_named_by_a_local_secondmates_record_is_refused
test_unclaimed_copy_still_launches

echo "# all fm-spawn-worktree-claimed tests passed"
