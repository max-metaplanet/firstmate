#!/usr/bin/env bash
# Regression test for the fm-spawn.sh treehouse-get worktree-detection settle
# loop and acquisition safety.
#
# On some tmux/WSL setups a brand-new window's pane_current_path transiently
# reports a stale, unrelated-but-real path on the very first poll, before the
# pane actually settles into the worktree treehouse get moved it to. That stale
# path still passes the loop's "differs from the project" check and
# validate_spawn_worktree's "is a real, distinct worktree" check (it IS a real
# git checkout, just the wrong one), so a naive single-read loop silently
# records the wrong worktree= in state/<id>.meta. This test simulates that
# transient-then-settled pane_current_path sequence with a fake tmux and
# asserts the recorded worktree resolves to the real, settled worktree, never
# the stale first read.
#
# The same loop has a second transient to survive: `treehouse get` reports the
# REPOSITORY's primary checkout as its own cwd while it is still preparing a
# slot. From a linked spawning home that path is not the project, so a poll
# comparing only against the project adopted it and the isolation guard then
# refused the launch. The cases below cover both the transient and the pane
# that never leaves the primary at all.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-worktree-settle)

# make_settle_fakebin <dir> builds a fake tmux whose `#{pane_current_path}`
# query returns FM_FAKE_PANE_STALE for the first FM_FAKE_PANE_STALE_READS
# calls, then FM_FAKE_PANE_PATH forever after - reproducing a pane that
# transiently reports a stale cwd before settling into the real worktree.
make_settle_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
window_file="${FM_FAKE_PANE_COUNTFILE:?FM_FAKE_PANE_COUNTFILE unset}.window"
case "$*" in
  *"#{pane_current_path}"*)
    countfile="${FM_FAKE_PANE_COUNTFILE:?FM_FAKE_PANE_COUNTFILE unset}"
    n=0
    [ -f "$countfile" ] && n=$(cat "$countfile")
    n=$((n + 1))
    printf '%s\n' "$n" > "$countfile"
    if [ "$n" -le "${FM_FAKE_PANE_STALE_READS:-0}" ]; then
      printf '%s\n' "${FM_FAKE_PANE_STALE:-}"
    else
      printf '%s\n' "${FM_FAKE_PANE_PATH:-}"
    fi
    exit 0
    ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) [ ! -s "$window_file" ] || cat "$window_file"; exit 0 ;;
  new-window)
    name=
    previous=
    for arg in "$@"; do
      [ "$previous" = -n ] && name=$arg
      previous=$arg
    done
    printf '%s\n' "$name" > "$window_file"
    exit 0 ;;
  kill-window) : > "$window_file"; exit 0 ;;
  has-session|new-session) exit 0 ;;
  send-keys)
    if [ "${FM_FAKE_EXEC_GET:-0}" = 1 ]; then
      for arg in "$@"; do
        case "$arg" in
          bash\ *get.sh*)
            (/bin/sleep "${FM_FAKE_GET_QUEUE_DELAY:-0}"; /bin/bash -c "$arg") </dev/null >"$FM_FAKE_GET_LOG" 2>&1 &
            ;;
        esac
      done
    fi
    exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

# make_settle_case <name> <id> <stale_reads> builds a home, a primary project
# with a real worktree (the eventual settled path), and a separate real git
# repo standing in for the stale path (a real checkout of something else
# entirely, distinct from both the project and the worktree - mirroring the
# live incident where the stale read was another real firstmate home).
make_settle_case() {
  local name=$1 id=$2 stale_reads=$3 case_dir home proj wt stale fakebin countfile
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  stale="$case_dir/stale-other-checkout"
  countfile="$case_dir/pane-call-count"
  fakebin=$(make_settle_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  fm_git_init_commit "$stale"
  mkdir -p "$home/data/$id"
  cat > "$home/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Exercise settled-worktree detection for $id.

## Firstmate spec
Record only the pane's stable worktree.
EOF
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$stale|$fakebin|$countfile|$stale_reads"
}

read_settle_record() {
  IFS='|' read -r _ HOME_DIR PROJ_DIR WT_DIR STALE_DIR FAKEBIN_DIR COUNTFILE STALE_READS <<EOF
$1
EOF
}

run_settle_spawn() {
  local id=$1
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    FM_FAKE_PANE_PATH="$WT_DIR" FM_FAKE_PANE_STALE="$STALE_DIR" \
    FM_FAKE_PANE_STALE_READS="$STALE_READS" FM_FAKE_PANE_COUNTFILE="$COUNTFILE" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1
}

# A single stale first read (the exact incident) must not be accepted: the
# loop should keep polling until two consecutive reads agree, landing on the
# real settled worktree instead.
test_single_stale_first_read_is_not_accepted() {
  local rec id out status
  id=settle-single-stale-z1
  rec=$(make_settle_case settle-single "$id" 1)
  read_settle_record "$rec"

  out=$(run_settle_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should succeed once the pane settles"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "meta did not record the settled worktree"
  assert_no_grep "worktree=$STALE_DIR" "$HOME_DIR/state/$id.meta" \
    "meta wrongly recorded the transient stale path as the worktree"
  pass "a single transient stale pane_current_path read is not accepted as the worktree"
}

# A pane that reports the real worktree from the very first read costs exactly
# one confirming read - not a whole extra polling cycle on top of it. Counting
# the pane reads measures the loop itself; wall-clock time would fold in every
# other cost of a spawn (fetch, trust registration) and drift with the machine.
test_already_settled_pane_costs_one_confirm_read() {
  local rec id out status reads
  id=settle-already-settled-z2
  rec=$(make_settle_case settle-already-settled "$id" 0)
  read_settle_record "$rec"

  out=$(run_settle_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should succeed when the pane is already settled"$'\n'"$out"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "meta did not record the already-settled worktree"
  reads=$(cat "$COUNTFILE")
  [ "$reads" -eq 3 ] || fail "already-settled pane took $reads reads to confirm - expected the first read, one confirmation, and the launch-boundary cwd check"
  pass "an already-settled pane confirms on the next read, not a whole extra cycle"
}

# make_primary_case <name> <id> <stale_reads> builds the linked-home shape: the
# spawning project is itself a LINKED worktree of the repository, and the path
# the pane transiently reports is that repository's PRIMARY checkout. `treehouse
# get` reports the repository it is preparing a slot from as its own cwd while
# it is still fetching and checking out, so the pane reads the primary for the
# first seconds. The primary is not the spawning project, so a poll that only
# compares against the project accepts it as the worktree, and the isolation
# guard then refuses the launch even though treehouse went on to enter a real
# slot. The settled path is a second linked worktree of the same repository.
make_primary_case() {
  local name=$1 id=$2 stale_reads=$3 case_dir home primary proj wt fakebin countfile
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  primary="$case_dir/primary"
  proj="$case_dir/mate"
  wt="$case_dir/slot"
  countfile="$case_dir/pane-call-count"
  fakebin=$(make_settle_fakebin "$case_dir/fake")
  fm_test_spawn_home "$home" codex
  fm_git_worktree "$primary" "$proj" "mate-$name"
  git -C "$primary" worktree add --quiet -b "slot-$name" "$wt"
  fm_test_spawn_brief "$home" "$id" "Exercise primary-checkout transient detection for $id."
  printf '%s\n' "$case_dir|$home|$proj|$wt|$primary|$fakebin|$countfile|$stale_reads"
}

# The exact incident: the pane reports the repository primary for the first
# reads, then settles into the slot treehouse actually created. The primary must
# never be adopted as the worktree, so the spawn lands on the settled slot.
test_transient_primary_checkout_is_not_accepted() {
  local rec id out status
  id=settle-primary-transient-z3
  rec=$(make_primary_case settle-primary-transient "$id" 3)
  read_settle_record "$rec"
  fm_test_fake_sleep_noop "$FAKEBIN_DIR"

  out=$(run_settle_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should succeed once the pane leaves the primary checkout"$'\n'"$out"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "meta did not record the settled worktree"
  assert_no_grep "worktree=$STALE_DIR" "$HOME_DIR/state/$id.meta" \
    "meta wrongly recorded the repository primary checkout as the worktree"
  pass "a transient primary-checkout pane read is not accepted as the worktree"
}

# A pane that never leaves the primary checkout must still fail at the deadline
# rather than waiting forever or recording the primary.
test_primary_checkout_that_never_settles_fails_at_the_deadline() {
  local rec id out status
  id=settle-primary-stuck-z4
  rec=$(make_primary_case settle-primary-stuck "$id" 100000)
  read_settle_record "$rec"
  fm_test_fake_sleep_noop "$FAKEBIN_DIR"

  out=$(FM_TREEHOUSE_GET_TIMEOUT=2 run_settle_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn accepted a pane that never left the primary checkout"$'\n'"$out"
  assert_contains "$out" "did not enter an isolated worktree" \
    "spawn did not explain that the pane never reached an isolated worktree"
  assert_contains "$out" "$STALE_DIR" \
    "the refusal did not name the path the pane kept reporting"
  assert_contains "$out" "repository's primary checkout" \
    "the refusal did not say why that path was rejected"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "refused spawn published task metadata"
  pass "a pane stuck on the primary checkout fails loudly at the deadline"
}

test_unborn_head_project_is_refused_at_once() {
  local rec id out status started elapsed
  id=settle-unborn-head-z5
  rec=$(make_settle_case settle-unborn "$id" 0)
  read_settle_record "$rec"
  PROJ_DIR="$TMP_ROOT/settle-unborn/unborn-project"
  git init -q "$PROJ_DIR"

  started=$SECONDS
  out=$(run_settle_spawn "$id")
  status=$?
  elapsed=$((SECONDS - started))
  expect_code 1 "$status" "spawn into a project with no commit should be refused"
  assert_contains "$out" "unborn HEAD" "the refusal did not name the unborn HEAD cause"
  assert_contains "$out" "make one commit" "the refusal did not name the remedy"
  [ "$elapsed" -lt 30 ] || fail "refusal took ${elapsed}s instead of failing before the treehouse wait"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "refused spawn published task metadata"
  [ -z "$(git -C "$PROJ_DIR" rev-list --all 2>/dev/null)" ] || fail "spawn committed into the project"
  pass "a project with an unborn HEAD is refused at once with its cause named"
}

test_slow_acquisition_survives_the_old_poll_limit() {
  local rec id out status
  id=settle-slow-get-z6
  rec=$(make_primary_case settle-slow-get "$id" 65)
  read_settle_record "$rec"
  fm_test_fake_sleep_noop "$FAKEBIN_DIR"
  out=$(run_settle_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn must allow an acquisition beyond 60 polls"$'\n'"$out"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" "slow acquisition recorded the wrong worktree"
  pass "an acquisition past the old 60-poll limit succeeds"
}

test_copied_gitdir_is_refused_before_refresh() {
  local rec id out status before
  id=settle-alias-z7
  rec=$(make_settle_case settle-alias "$id" 0)
  read_settle_record "$rec"
  before=$(git -C "$WT_DIR" rev-parse HEAD)
  mkdir "$WT_DIR-copy"
  cp "$WT_DIR/.git" "$WT_DIR-copy/.git"
  WT_DIR="$WT_DIR-copy"
  out=$(run_settle_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn accepted a copied worktree sharing another worktree's gitdir"
  assert_contains "$out" "gitdir" "alias refusal did not explain the shared gitdir"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "aliased candidate published task metadata"
  [ "$(git -C "$WT_DIR" rev-parse HEAD)" = "$before" ] || fail "alias refusal moved the shared HEAD"
  [ -f "$WT_DIR/.git" ] || fail "alias refusal removed the candidate"
  pass "a copied gitdir is refused without moving HEAD or deleting the copy"
}

test_timeout_stops_get_and_its_copy_process() {
  local rec id out status pid stat file
  id=settle-timeout-z8
  rec=$(make_primary_case settle-timeout "$id" 100000)
  read_settle_record "$rec"
  cat > "$FAKEBIN_DIR/treehouse" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$$" > "$FM_FAKE_GET_LOG.pid"
/bin/bash -c 'printf "%s\n" "$$" > "$FM_FAKE_GET_LOG.child"; /bin/sleep 6; touch "$FM_FAKE_GET_LOG.late-copy"' &
wait
SH
  out=$(FM_TREEHOUSE_GET_TIMEOUT=3 FM_FAKE_EXEC_GET=1 FM_FAKE_GET_LOG="$COUNTFILE.get" run_settle_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn accepted an acquisition that never settled"
  assert_contains "$out" "within 3s" "timeout refusal did not name its configured bound"
  assert_contains "$out" "pending acquisition stopped" "timeout did not confirm cancellation"$'\n'"$out"
  for file in "$COUNTFILE.get.pid" "$COUNTFILE.get.child"; do
    [ -s "$file" ] || fail "timeout test never started its acquisition/copy process"
    pid=$(cat "$file")
    stat=$(ps -p "$pid" -o stat= 2>/dev/null || true)
    case "$stat" in ''|*Z*) ;; *) fail "timeout left process $pid running ($stat)" ;; esac
  done
  /bin/sleep 4
  [ ! -e "$COUNTFILE.get.late-copy" ] || fail "timed-out get left a late physical copy"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "timed-out spawn published task metadata"
  pass "timeout stops get and its pending copy subprocess before a late copy can appear"
}

test_canonical_slot_with_an_aliased_neighbor_is_refused() {
  local rec id out status case_dir before
  id=settle-alias-neighbor-z10
  rec=$(make_settle_case settle-alias-neighbor "$id" 0)
  read_settle_record "$rec"
  case_dir=${COUNTFILE%/*}
  mkdir -p "$case_dir/pool/1" "$case_dir/pool/2/project"
  git -C "$PROJ_DIR" worktree add --quiet --detach "$case_dir/pool/1/project" HEAD
  WT_DIR="$case_dir/pool/1/project"
  cp "$WT_DIR/.git" "$case_dir/pool/2/project/.git"
  printf '{}\n' > "$case_dir/pool/treehouse-state.json"
  before=$(git -C "$WT_DIR" reflog)
  out=$(run_settle_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn accepted a canonical slot whose neighbor shares its gitdir"
  assert_contains "$out" "shares gitdir" "canonical slot refusal did not explain the alias"
  assert_contains "$out" "$case_dir/pool/2/project" "alias refusal did not identify the other copy"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "aliased canonical slot published metadata"
  [ "$(git -C "$WT_DIR" reflog)" = "$before" ] || fail "alias refusal reset the shared HEAD"
  [ -f "$case_dir/pool/2/project/.git" ] || fail "alias refusal deleted the other copy"
  pass "a canonical slot is refused when another physical pool slot aliases its gitdir"
}

test_timeout_prevents_a_queued_get_from_starting() {
  local rec id out status
  id=settle-queued-z9
  rec=$(make_primary_case settle-queued "$id" 100000)
  read_settle_record "$rec"
  cat > "$FAKEBIN_DIR/treehouse" <<'SH'
#!/usr/bin/env bash
touch "$FM_FAKE_GET_LOG.started"
SH
  out=$(FM_TREEHOUSE_GET_TIMEOUT=1 FM_FAKE_EXEC_GET=1 FM_FAKE_GET_QUEUE_DELAY=4 \
    FM_FAKE_GET_LOG="$COUNTFILE.get" run_settle_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn accepted a queued acquisition"
  /bin/sleep 5
  [ ! -e "$COUNTFILE.get.started" ] || fail "queued get began after the timeout refusal"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "queued acquisition published metadata"
  pass "a queued get cannot start after timeout"
}

test_slow_acquisition_survives_the_old_poll_limit
test_copied_gitdir_is_refused_before_refresh
test_timeout_stops_get_and_its_copy_process
test_timeout_prevents_a_queued_get_from_starting
test_canonical_slot_with_an_aliased_neighbor_is_refused
test_single_stale_first_read_is_not_accepted
test_already_settled_pane_costs_one_confirm_read
test_transient_primary_checkout_is_not_accepted
test_primary_checkout_that_never_settles_fails_at_the_deadline
test_unborn_head_project_is_refused_at_once

echo "# all fm-spawn-worktree-settle tests passed"
