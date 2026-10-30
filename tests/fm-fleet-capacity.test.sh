#!/usr/bin/env bash
# Behavior tests for fleet capacity admission: a machine that declares how many
# agents its whole local fleet runs at once never gets a fresh ship, scout, or
# secondmate launched beyond that number (bin/fm-fleet-capacity-lib.sh owns the
# contract; bin/fm-spawn.sh runs the check).
#
# The fixture is the project capacity suite's: the real bin/fm-spawn.sh against
# a real project clone, fake tmux and treehouse binaries that log every call,
# and a real markdown backlog when tasks-axi is installed. A holder is live when
# its window is in the fake tmux inventory and dead when it is not.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

unset TASKS_AXI_BACKEND || :

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-fleet-capacity)
DEFER_EXIT=75
TEST_PATH=$PATH
HAVE_TASKS_AXI=0
command -v tasks-axi >/dev/null 2>&1 && HAVE_TASKS_AXI=1

# --- fixture ----------------------------------------------------------------

write_brief() {  # <home> <id> [legacy]
  mkdir -p "$1/data/$2"
  cat > "$1/data/$2/brief.md" <<EOF
# Task
## Captain's intent
Run the project's heavy suite for $2.

## Firstmate spec
Exercise fleet capacity admission.

# Definition of done
Delivery contract: mode=no-mistakes
EOF
  if [ "${3:-}" != legacy ]; then
    printf 'Ship branch: chore/no-ticket-%s\nTicket: no-ticket\nCommit type: chore\n' "$2" >> "$1/data/$2/brief.md"
  fi
}

# A Firstmate home with its own backlog (when tasks-axi is installed) and a
# brief for every named task.
make_home() {  # <home> [task-id...]
  local home=$1 id
  shift
  mkdir -p "$home/state" "$home/config" "$home/data" "$home/projects"
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' codex > "$home/config/crew-harness"
  if [ "$HAVE_TASKS_AXI" = 1 ]; then
    printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' \
      > "$home/data/backlog.md"
    cat > "$home/.tasks.toml" <<'EOF'
backend = "markdown"

[markdown]
path = "data/backlog.md"
EOF
  fi
  for id in "$@"; do
    write_brief "$home" "$id"
    add_item "$home" "$id"
  done
}

# A case: one home, a project clone with an origin, and fake tmux/treehouse
# that record every call so a deferral can be proved to have created nothing.
make_case() {  # <name> [task-id...]
  local name=$1 case_dir fakebin
  shift
  case_dir="$TMP_ROOT/$name"
  mkdir -p "$case_dir"
  fakebin=$(fm_fakebin "$case_dir")
  : > "$case_dir/calls.log"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_FAKE_CALL_LOG"
window_file="$FM_FAKE_CALL_LOG.window"
case "$*" in
  *"#{pane_current_path}"*)
    # A spawn that is told to hold waits here, after its capacity check and
    # while it still holds the project lock, until the test releases it.
    if [ -n "${FM_FAKE_HOLD:-}" ]; then
      : > "$FM_FAKE_HOLD.reached"
      i=0
      while [ ! -f "$FM_FAKE_HOLD.release" ]; do
        i=$((i + 1))
        [ "$i" -lt 400 ] || exit 1
        sleep 0.05
      done
    fi
    printf '%s\n' "${FM_FAKE_PANE_PATH:-}"
    exit 0
    ;;
esac
case "${1:-}" in
  display-message)
    case "$*" in *pane_current_command*) printf '%s\n' "${FM_FAKE_AGENT_COMMAND:-firstmate}" ;; *) printf 'firstmate\n' ;; esac ;;
  list-windows)
    # With a probe barrier, a listing answers only once every expected probe
    # is waiting at once, so a one-at-a-time occupancy read times out here.
    if [ -n "${FM_FAKE_PROBE_BARRIER:-}" ]; then
      mkdir -p "$FM_FAKE_PROBE_BARRIER"
      : > "$FM_FAKE_PROBE_BARRIER/$$"
      i=0
      while [ "$(find "$FM_FAKE_PROBE_BARRIER" -type f | wc -l)" -lt "$FM_FAKE_PROBE_EXPECT" ]; do
        i=$((i + 1))
        [ "$i" -lt 60 ] || { printf 'probe barrier timed out\n' >> "$FM_FAKE_CALL_LOG"; break; }
        sleep 0.05
      done
    fi
    [ ! -s "$window_file" ] || cat "$window_file"
    ;;
  new-window)
    name=
    previous=
    for arg in "$@"; do
      [ "$previous" = -n ] && name=$arg
      previous=$arg
    done
    grep -Fqx -- "$name" "$window_file" 2>/dev/null || printf '%s\n' "$name" >> "$window_file"
    ;;
  kill-window)
    target=
    previous=
    for arg in "$@"; do
      [ "$previous" = -t ] && target=$arg
      previous=$arg
    done
    target=${target##*:}
    target=${target#=}
    grep -Fvx -- "$target" "$window_file" 2>/dev/null > "$window_file.tmp" || true
    mv "$window_file.tmp" "$window_file"
    ;;
esac
exit 0
SH
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
printf 'treehouse %s\n' "$*" >> "$FM_FAKE_CALL_LOG"
exit 0
SH
  chmod +x "$fakebin/tmux" "$fakebin/treehouse"
  fm_fake_exit0 "$fakebin" gh gh-axi no-mistakes
  fm_git_init_commit "$case_dir/project"
  fm_git_add_origin "$case_dir/project" "$case_dir/project.origin.git"
  fm_git_init_commit "$case_dir/other-project"
  fm_git_add_origin "$case_dir/other-project" "$case_dir/other-project.origin.git"
  make_home "$case_dir/home" "$@"
  printf '%s\n' "$case_dir"
}

add_item() {  # <home> <id>
  [ "$HAVE_TASKS_AXI" = 1 ] || return 0
  tasks-axi add "$2" "item for $2" --kind ship --file "$1/data/backlog.md" >/dev/null
}

row_state() {  # <home> <id>
  tasks-axi show "$2" --file "$1/data/backlog.md" 2>/dev/null |
    sed -n 's/^  state: *//p' | head -1
}

declare_capacity() {  # <home> <line>...
  local home=$1
  shift
  printf '%s\n' "$@" > "$home/config/project-capacity"
}

# A live worker already on a project: the record shape bin/fm-spawn.sh
# publishes, with its backlog item In flight so cleanup can close it.
write_live() {  # <home> <id> <project-dir> [extra-line...]
  local home=$1 id=$2 project=$3
  shift 3
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "endpoint_task_id=$id" \
    "worktree=$home/absent-worktree-$id" \
    "project=$project" \
    "harness=codex" \
    "kind=ship" \
    "mode=no-mistakes" \
    "yolo=off" \
    "spawn_gen=s-$id" \
    "$@"
  if [ "$HAVE_TASKS_AXI" = 1 ]; then
    add_item "$home" "$id"
    tasks-axi start "$id" --file "$home/data/backlog.md" >/dev/null
  fi
}

# One isolated worktree per spawn, so every admitted launch has its own copy.
new_worktree() {  # <case-dir> <name>
  git -C "$1/project" worktree add --quiet -b "wt-$2" "$1/wt-$2"
  printf '%s\n' "$1/wt-$2"
}

run_spawn() {  # <case-dir> <home> <pane-path> <args...>
  local case_dir=$1 home=$2 pane=$3
  shift 3
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' FM_PROJECTS_OVERRIDE='' FM_CONFIG_OVERRIDE='' \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" FM_BACKEND=tmux \
    FM_FAKE_PANE_PATH="$pane" FM_FAKE_CALL_LOG="$case_dir/calls.log" \
    PATH="$case_dir/fakebin:$PATH" \
    "$SPAWN" "$@" 2>&1
}

spawn_ship() {  # <case-dir> <id> [pane-path]
  local case_dir=$1 id=$2 pane=${3:-}
  [ -n "$pane" ] || pane=$(new_worktree "$case_dir" "$id")
  run_spawn "$case_dir" "$case_dir/home" "$pane" "$id" "$case_dir/project" --mode no-mistakes --ticket no-ticket --commit-type chore --yolo off
}

# Everything a deferred spawn must not have created for <id>; <worktrees-before>
# is worktree_list taken before the spawn.
assert_nothing_created() {  # <case-dir> <home> <id> <calls-before> <worktrees-before>
  local case_dir=$1 home=$2 id=$3 before=$4 worktrees=$5 changes
  assert_absent "$home/state/$id.meta" "a deferred spawn published a task record for $id"
  assert_absent "$home/data/$id/launch-brief.md" "a deferred spawn rendered a launch brief for $id"
  # Counting probes each holder's pane read-only; anything else is a launch.
  changes=$(tail -n +"$((before + 1))" "$case_dir/calls.log" | grep -Ev '^(list-windows|display-message -p) ' || true)
  [ -z "$changes" ] ||
    fail "a deferred spawn touched the terminal or worktree pool for $id: $changes"
  assert_equals "$worktrees" "$(worktree_list "$case_dir")" "a deferred spawn left a git worktree for $id"
  if [ "$HAVE_TASKS_AXI" = 1 ]; then
    [ "$(row_state "$home" "$id")" = queued ] ||
      fail "a deferred spawn moved $id's backlog item: $(row_state "$home" "$id")"
  fi
}

call_count() { wc -l < "$1/calls.log" | tr -d ' '; }

worktree_list() { git -C "$1/project" worktree list --porcelain; }

declare_fleet() {  # <home> <line>...
  local home=$1
  shift
  printf '%s\n' "$@" > "$home/config/fleet-capacity"
}

# A holder whose agent is running: its window is in the fake tmux inventory.
write_running() {  # <case-dir> <home> <id> <project-dir> [extra-line...]
  local case_dir=$1
  shift
  write_live "$@"
  printf '%s\n' "fm-$2" >> "$case_dir/calls.log.window"
}

# --- cases ------------------------------------------------------------------

test_undeclared_fleet_stays_uncapped() {
  local case_dir home out rc=0
  case_dir=$(make_case undeclared task-c)
  home="$case_dir/home"
  write_running "$case_dir" "$home" live-a "$case_dir/project"
  write_running "$case_dir" "$home" live-b "$case_dir/project"
  out=$(spawn_ship "$case_dir" task-c) || rc=$?
  expect_code 0 "$rc" "an undeclared fleet refused a spawn: $out"
  assert_present "$home/state/task-c.meta" "an undeclared fleet's spawn published no record"
  pass "a machine with no declared fleet capacity keeps uncapped dispatch"
}

# Running agents of every kind and project count, including ones with a
# recorded PR, and the spawn defers without creating anything.
test_full_fleet_defers_without_leaving_anything_behind() {
  local case_dir home out rc=0 before worktrees pane
  case_dir=$(make_case full task-c)
  home="$case_dir/home"
  declare_fleet "$home" "# whole machine" "3"
  write_running "$case_dir" "$home" live-a "$case_dir/project"
  write_running "$case_dir" "$home" live-b "$case_dir/other-project" "pr=https://github.com/o/r/pull/7"
  fm_write_meta "$home/state/mate-x.meta" "window=firstmate:fm-mate-x" "project=$case_dir/mate-home" "kind=secondmate"
  printf '%s\n' fm-mate-x >> "$case_dir/calls.log.window"
  pane=$(new_worktree "$case_dir" task-c)
  before=$(call_count "$case_dir")
  worktrees=$(worktree_list "$case_dir")
  out=$(spawn_ship "$case_dir" task-c "$pane") || rc=$?
  expect_code "$DEFER_EXIT" "$rc" "a spawn past the fleet capacity was not deferred: $out"
  assert_contains "$out" "runs at most 3 agent(s) at once" "the deferral did not name the fleet capacity"
  assert_contains "$out" "live-a, live-b, mate-x" "the deferral did not name every running holder"
  assert_nothing_created "$case_dir" "$home" task-c "$before" "$worktrees"
  pass "a full fleet defers a fresh spawn and leaves it queued with nothing created"
}

# Another spawn's admission holds the fleet lock only briefly, so a fresh spawn
# waits for it instead of deferring at once.
test_fresh_spawn_waits_for_a_briefly_busy_fleet_lock() {
  local case_dir home out rc=0 lock
  case_dir=$(make_case busy-lock task-c)
  home="$case_dir/home"
  declare_fleet "$home" "2"
  lock="$home/state/.fleet-capacity.lock"
  mkdir "$lock"
  printf '%s\n' "$$" > "$lock/pid"
  ( sleep 1; rm -f "$lock/pid"; rmdir "$lock" ) &
  out=$(spawn_ship "$case_dir" task-c) || rc=$?
  wait
  expect_code 0 "$rc" "a fresh spawn deferred instead of waiting for a released fleet lock: $out"
  assert_present "$home/state/task-c.meta" "the admitted spawn published no record"
  pass "a fresh spawn waits for a briefly busy fleet capacity lock"
}

test_dead_agents_free_their_place() {
  local case_dir home out rc=0
  case_dir=$(make_case dead task-c)
  home="$case_dir/home"
  declare_fleet "$home" "2"
  write_running "$case_dir" "$home" live-a "$case_dir/project"
  write_live "$home" gone-b "$case_dir/project"
  out=$(spawn_ship "$case_dir" task-c) || rc=$?
  expect_code 0 "$rc" "a record whose agent is gone took a fleet place: $out"
  assert_present "$home/state/task-c.meta" "the admitted spawn published no record"
  pass "a task record whose agent is no longer running holds no fleet place"
}

# The cap belongs to the machine: a local secondmate home's running workers
# count against the root home's declaration, and the secondmate's own spawn is
# capped by it too.
test_fleet_is_shared_by_every_local_home() {
  local case_dir root mate mate_project out rc=0
  case_dir=$(make_case machine)
  root="$case_dir/home"
  mate="$case_dir/mate"
  make_home "$mate" task-m
  mate_project="$mate/projects/project"
  git clone -q "$(git -C "$case_dir/project" remote get-url origin)" "$mate_project"
  printf '%s\n' schema=fm-secondmate-parent.v1 route=local "parent_home=$root" > "$mate/.fm-secondmate-parent"
  printf -- '- mate - a local mate (home: %s; scope: project work; projects: project; added 2026-09-01)\n' "$mate" \
    > "$root/data/secondmates.md"
  declare_fleet "$root" "2"
  write_running "$case_dir" "$root" live-a "$case_dir/project"
  write_running "$case_dir" "$mate" live-m "$mate_project"
  git -C "$mate_project" worktree add --quiet -b wt-m "$case_dir/wt-m"
  out=$(run_spawn "$case_dir" "$mate" "$case_dir/wt-m" task-m "$mate_project" --mode no-mistakes --ticket no-ticket --commit-type chore --yolo off) || rc=$?
  expect_code "$DEFER_EXIT" "$rc" "a local secondmate launched past the machine's fleet capacity: $out"
  assert_contains "$out" "($root/config/fleet-capacity) and 2 are running" \
    "the secondmate did not read the root's declaration or count both homes"
  assert_absent "$mate/state/task-m.meta" "the deferred secondmate-home spawn published a record"
  pass "every local home shares the root home's one fleet capacity"
}

test_unreadable_declaration_refuses_every_spawn() {
  local case_dir home out rc=0
  case_dir=$(make_case malformed task-c)
  home="$case_dir/home"
  declare_fleet "$home" "6" "7"
  out=$(spawn_ship "$case_dir" task-c) || rc=$?
  expect_code 1 "$rc" "a spawn under a malformed fleet declaration was not refused: $out"
  assert_contains "$out" "fleet capacity declaration is unreadable" "the refusal did not name the declaration"
  assert_absent "$home/state/task-c.meta" "a refused spawn published a record"
  pass "a malformed fleet declaration refuses spawns rather than guessing the limit"
}

# The admission library's occupancy read for <home>, one result per line: the
# count, the holder labels, then each holder's metadata path.
read_occupants() (  # <case-dir> <home>
  local case_dir=$1 home=$2
  export FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config"
  export FM_FAKE_CALL_LOG="$case_dir/calls.log" FM_FAKE_PROBE_BARRIER="$case_dir/barrier" FM_FAKE_PROBE_EXPECT=5
  export PATH="$case_dir/fakebin:$PATH"
  # shellcheck source=bin/fm-wake-lib.sh
  . "$ROOT/bin/fm-wake-lib.sh"
  # shellcheck source=bin/fm-secondmate-registry-lib.sh
  . "$ROOT/bin/fm-secondmate-registry-lib.sh"
  # shellcheck source=bin/fm-backend.sh
  . "$ROOT/bin/fm-backend.sh"
  # shellcheck source=bin/fm-project-capacity-lib.sh
  . "$ROOT/bin/fm-project-capacity-lib.sh"
  # shellcheck source=bin/fm-fleet-capacity-lib.sh
  . "$ROOT/bin/fm-fleet-capacity-lib.sh"
  fm_fleet_capacity_occupants "$home/state" '' || return 1
  printf '%s\n' "$FM_FLEET_CAPACITY_OCCUPANTS" "$FM_FLEET_CAPACITY_OCCUPANT_IDS" "${FM_FLEET_CAPACITY_OCCUPANT_METAS[@]}"
)

# Every recorded endpoint is probed at once, and the holders are still exactly
# the running agents in record order: the gone ones are dropped and nothing else.
test_endpoint_probes_run_together_with_serial_verdicts() {
  local case_dir home mate out
  case_dir=$(make_case probes)
  home="$case_dir/home"
  mate="$case_dir/mate"
  make_home "$mate"
  printf '%s\n' schema=fm-secondmate-parent.v1 route=local "parent_home=$home" > "$mate/.fm-secondmate-parent"
  printf -- '- mate - a local mate (home: %s; scope: project work; projects: project; added 2026-09-01)\n' "$mate" \
    > "$home/data/secondmates.md"
  write_running "$case_dir" "$home" live-a "$case_dir/project"
  write_live "$home" gone-b "$case_dir/project"
  write_running "$case_dir" "$home" live-c "$case_dir/project"
  write_live "$mate" gone-d "$case_dir/project"
  write_running "$case_dir" "$mate" live-e "$case_dir/project"
  out=$(read_occupants "$case_dir" "$home") || fail "the occupancy read failed: $out"
  assert_equals $'3\nlive-a, live-c, live-e in '"$mate"$'\n'"$home/state/live-a.meta"$'\n'"$home/state/live-c.meta"$'\n'"$mate/state/live-e.meta" \
    "$out" "concurrent probes changed the holder count, set, or order"
  assert_not_contains "$(cat "$case_dir/calls.log")" "probe barrier timed out" "endpoint probes ran one at a time"
  pass "endpoint probes run together and count exactly the running holders in record order"
}

write_park() { # home id phase
  printf 'phase=%s\ngeneration=s-%s\nendpoint=firstmate:fm-%s\nreason=upstream maintainer\nuntil=0\nqueued_at=1\n' "$3" "$2" "$2" > "$1/state/$2.park"
}

test_parked_capacity_and_priority() {
  local case_dir home out rc=0 pane
  case_dir=$(make_case parked task-c)
  home="$case_dir/home"
  declare_fleet "$home" 1
  write_running "$case_dir" "$home" parked-a "$case_dir/project"
  write_park "$home" parked-a parked
  out=$(spawn_ship "$case_dir" task-c) || rc=$?
  expect_code 0 "$rc" "verified parked record did not free capacity: $out"
  assert_present "$home/state/task-c.meta" 'fresh task takes the released slot'

  case_dir=$(make_case pending task-c)
  home="$case_dir/home"
  declare_fleet "$home" 1
  write_live "$home" parked-a "$case_dir/project"
  write_park "$home" parked-a queued
  pane=$(new_worktree "$case_dir" task-c)
  rc=0
  out=$(spawn_ship "$case_dir" task-c "$pane") || rc=$?
  expect_code 75 "$rc" "fresh dispatch overtook queued resume: $out"
  assert_contains "$out" 'resume ahead of task task-c' 'admission enforces resume priority'
  assert_absent "$home/state/task-c.meta" 'priority deferral creates no record'

  write_park "$home" parked-a parking
  declare_fleet "$home" 1
  rc=0
  out=$(spawn_ship "$case_dir" task-c "$pane") || rc=$?
  expect_code 75 "$rc" "an unverified exit freed its slot: $out"
  assert_contains "$out" '1 are running' 'unverified exit keeps capacity even on a dead endpoint'

  case_dir=$(make_case spare task-c)
  home="$case_dir/home"
  declare_fleet "$home" 2
  write_live "$home" parked-a "$case_dir/project"
  write_park "$home" parked-a queued
  rc=0
  out=$(spawn_ship "$case_dir" task-c) || rc=$?
  expect_code 0 "$rc" "a queued resume blocked a spare fleet place: $out"

  case_dir=$(make_case held task-c)
  home="$case_dir/home"
  declare_fleet "$home" 1
  write_live "$home" parked-a "$case_dir/project"
  write_park "$home" parked-a queued
  printf 'resume_error=1\n' >> "$home/state/parked-a.park"
  rc=0
  out=$(spawn_ship "$case_dir" task-c) || rc=$?
  expect_code 0 "$rc" "a resume held for repair blocked fresh dispatch: $out"
  pass 'parked capacity, unverified exit reservation and priority over fresh dispatch'
}

test_parked_resume_has_project_priority() {
  local case_dir home out rc=0
  case_dir=$(make_case project-priority task-c)
  home="$case_dir/home"
  declare_capacity "$home" 'project 1'
  write_running "$case_dir" "$home" parked-a "$case_dir/project"
  write_park "$home" parked-a queued
  pane=$(new_worktree "$case_dir" parked-a)
  write_brief "$home" parked-a legacy
  sed "s|^worktree=.*|worktree=$pane|" "$home/state/parked-a.meta" > "$home/state/parked-a.meta.next"
  mv "$home/state/parked-a.meta.next" "$home/state/parked-a.meta"
  out=$(spawn_ship "$case_dir" task-c) || rc=$?
  expect_code 75 "$rc" "fresh dispatch took the project place a queued resume waits for: $out"
  assert_contains "$out" 'in project project and resume ahead of task task-c' 'project admission enforces resume priority'
  assert_absent "$home/state/task-c.meta" 'project priority deferral creates no record'
  rc=0
  out=$(FM_FAKE_AGENT_COMMAND=bash run_spawn "$case_dir" "$home" "$pane" parked-a --relaunch --harness codex) || rc=$?
  expect_code 0 "$rc" "the queued resume was not admitted to the place it reserved: $out"

  case_dir=$(make_case project-repair task-c)
  home="$case_dir/home"
  declare_capacity "$home" 'project 1'
  write_live "$home" parked-a "$case_dir/project"
  write_park "$home" parked-a queued
  printf 'resume_error=1\n' >> "$home/state/parked-a.park"
  rc=0
  out=$(spawn_ship "$case_dir" task-c) || rc=$?
  expect_code 0 "$rc" "a resume held for repair reserved a project place: $out"

  case_dir=$(make_case project-unrelated task-c)
  home="$case_dir/home"
  fm_git_init_commit "$case_dir/other"
  declare_capacity "$home" 'project 1' 'other 1'
  write_live "$home" parked-a "$case_dir/other"
  write_park "$home" parked-a queued
  rc=0
  out=$(spawn_ship "$case_dir" task-c) || rc=$?
  expect_code 0 "$rc" "a resume queued for another project blocked spare capacity: $out"

  case_dir=$(make_case project-blocked-fleet task-c)
  home="$case_dir/home"
  fm_git_init_commit "$case_dir/other"
  declare_capacity "$home" 'other 1'
  declare_fleet "$home" 2
  write_running "$case_dir" "$home" holder "$case_dir/other"
  write_live "$home" parked-a "$case_dir/other"
  write_park "$home" parked-a queued
  rc=0
  out=$(spawn_ship "$case_dir" task-c) || rc=$?
  expect_code 0 "$rc" "a resume its full project cannot admit held the spare fleet place: $out"
  pass 'queued resumes take priority for their own project cap only'
}

test_parked_relaunch_respects_both_caps() {
  local case_dir home pane out rc=0
  case_dir=$(make_case resume-cap)
  home="$case_dir/home"
  pane=$(new_worktree "$case_dir" parked-a)
  write_brief "$home" parked-a legacy
  write_running "$case_dir" "$home" parked-a "$case_dir/project"
  sed "s|^worktree=.*|worktree=$pane|" "$home/state/parked-a.meta" > "$home/state/parked-a.meta.next"
  mv "$home/state/parked-a.meta.next" "$home/state/parked-a.meta"
  write_park "$home" parked-a queued
  write_running "$case_dir" "$home" occupied "$case_dir/project"
  write_park "$home" occupied parking
  declare_fleet "$home" 1
  out=$(FM_FAKE_AGENT_COMMAND=bash run_spawn "$case_dir" "$home" "$pane" parked-a --relaunch --harness codex) || rc=$?
  expect_code 75 "$rc" "parked relaunch bypassed fleet cap: $out"
  assert_contains "$out" 'runs at most 1 agent(s)' 'resumption uses fleet admission'
  rm "$home/config/fleet-capacity"
  declare_capacity "$home" 'project 1'
  rc=0
  out=$(FM_FAKE_AGENT_COMMAND=bash run_spawn "$case_dir" "$home" "$pane" parked-a --relaunch --harness codex) || rc=$?
  expect_code 75 "$rc" "parked relaunch bypassed project cap: $out"
  assert_contains "$out" 'project project admits 1 worker(s)' 'resumption uses project admission'
  assert_present "$home/state/parked-a.park" 'cap deferral preserves the request'
  pass 'parked relaunch respects fleet and project capacity'
}

# Adaptive policy uses real tick/status/spawn commands with fixture telemetry.
load_policy() { # home mode [floor ceiling start]
  printf '{"mode":"%s","floor":%s,"ceiling":%s,"start":%s}\n' "$2" "${3:-1}" "${4:-3}" "${5:-3}" > "$1/config/fleet-load-policy"
}

load_fixture() { # case epoch pressure load1-centi load5-centi [swapouts] [boot]
  export FM_FLEET_LOAD_CLOCK="$1/clock.json" FM_FLEET_LOAD_TELEMETRY="$1/telemetry.json"
  printf '{"epoch":%s,"monotonic":%s,"boot":"%s"}\n' "$2" "$2" "${7:-fixture-boot}" > "$FM_FLEET_LOAD_CLOCK"
  printf '{"load1":%s,"load5":%s,"cpus":1,"load1_centi":%s,"load5_centi":%s,"pressure":"%s","swapouts":%s,"swapins":0,"page_size":16384,"swap_used_bytes":9999999999}\n' \
    "$4" "$5" "$4" "$5" "$3" "${6:-0}" > "$FM_FLEET_LOAD_TELEMETRY"
}

park_command() { # case home verb
  FM_ROOT_OVERRIDE='' FM_HOME="$2" FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' FM_PROJECTS_OVERRIDE='' FM_CONFIG_OVERRIDE='' \
    FM_FAKE_CALL_LOG="$1/calls.log" FM_BACKEND=tmux PATH="$1/fakebin:$TEST_PATH" bash "$ROOT/bin/fm-worker-park.sh" "$3"
}

load_expect() { # case home jq-expression message
  local observation
  observation=$(park_command "$1" "$2" status) || fail "status failed: $4"
  printf '%s\n' "$observation" | jq -e "$3" >/dev/null || fail "$4: $observation"
}

load_tick() { park_command "$1" "$1/home" tick || fail 'capacity tick failed'; }

# A capacity deferral records a replay the next healthy tick would admit; these
# sensor-policy cases hold the item so their ticks only sample.
hold_deferred() { # home id
  assert_present "$1/state/$2.deferred-spawn.json" 'capacity deferral did not record its replay'
  if [ "$HAVE_TASKS_AXI" = 1 ]; then
    tasks-axi hold "$2" --kind captain --reason 'sensor policy fixture' --file "$1/data/backlog.md" >/dev/null
  else
    rm "$1/state/$2.deferred-spawn.json"
  fi
}

test_adaptive_off_and_observe() {
  local case_dir home out rc=0 state
  case_dir=$(make_case adaptive-off task-a)
  home="$case_dir/home"
  declare_fleet "$home" 3
  printf 'off\n' > "$home/config/fleet-load-policy"
  load_fixture "$case_dir" 1000 critical 200 200
  load_tick "$case_dir"
  assert_absent "$home/state/fleet-load.json" 'off mode did not retain the no-sampling path'
  printf '{"mode":"off"}\n' > "$home/config/fleet-load-policy"
  rm "$home/config/fleet-capacity"
  load_tick "$case_dir"
  load_expect "$case_dir" "$home" '.mode == "invalid" and .hold == "" and .configured == null and (.reason | contains("bare word off"))' 'JSON off is reported as invalid configuration'
  declare_fleet "$home" 3
  load_tick "$case_dir"
  load_expect "$case_dir" "$home" '.mode == "invalid" and .hold == "" and .effective == 3' 'JSON off admits through the static cap'
  assert_absent "$home/state/fleet-load.json" 'JSON off sampled'
  load_policy "$home" observe
  load_tick "$case_dir"
  load_expect "$case_dir" "$home" '.mode == "observe" and .desired == 1 and .effective == 3 and (.hold | contains("critical"))' 'observe projects critical hold without applying it'
  assert_absent "$home/state/.fleet-load-notice" 'observe mode published a capacity wake'
  assert_not_contains "$(cat "$home/state/.wake-queue" 2>/dev/null)" 'fleet-load capacity' 'observe mode queued a capacity wake'
  state=$(cat "$home/state/fleet-load.json")
  out=$(spawn_ship "$case_dir" task-a) || rc=$?
  expect_code 0 "$rc" "observe refused an admission: $out"
  assert_equals "$state" "$(cat "$home/state/fleet-load.json")" 'duplicate tick/admission sampled twice in a minute'
  assert_not_contains "$(cat "$case_dir/calls.log")" 'kill-window' 'adaptive sampling stopped a running worker'
  unset FM_FLEET_LOAD_CLOCK FM_FLEET_LOAD_TELEMETRY
  pass 'off has no sample; observe reports a critical desired cap and never refuses'
}

test_json_off_without_fleet_cap_stays_uncapped() {
  local case_dir home out rc=0
  case_dir=$(make_case adaptive-off-uncapped task-a)
  home="$case_dir/home"
  printf '{"mode":"off"}\n' > "$home/config/fleet-load-policy"
  # An unreadable record would refuse a capped spawn; uncapped admission never counts.
  printf 'kind=ship\n' > "$home/state/stranger.meta"
  chmod 000 "$home/state/stranger.meta"
  out=$(spawn_ship "$case_dir" task-a) || rc=$?
  chmod 600 "$home/state/stranger.meta"
  expect_code 0 "$rc" "JSON off without a fleet cap refused a spawn: $out"
  assert_not_contains "$out" 'integer expression' 'uncapped JSON-off admission compared against an empty cap'
  assert_not_contains "$out" 'cannot all be read' 'uncapped JSON-off admission counted fleet records'
  assert_present "$home/state/task-a.meta" 'uncapped JSON-off spawn did not launch'
  pass 'JSON off without a declared fleet cap admits uncapped without counting'
}

test_adaptive_drop_recover_and_static_clamp() {
  local case_dir home at out rc=0 before worktrees state
  case_dir=$(make_case adaptive-cpu task-a)
  home="$case_dir/home"
  declare_fleet "$home" 3
  load_policy "$home" enforce
  write_running "$case_dir" "$home" live-a "$case_dir/project"
  write_running "$case_dir" "$home" live-b "$case_dir/other-project"
  for at in 1000 1060 1120; do
    load_fixture "$case_dir" "$at" normal 150 140
    load_tick "$case_dir"
  done
  load_expect "$case_dir" "$home" '.effective == 2 and .occupancy == 2 and .state.reason == "sustained CPU load"' 'three CPU samples reduce one slot'
  before=$(call_count "$case_dir"); worktrees=$(worktree_list "$case_dir")
  out=$(spawn_ship "$case_dir" task-a "$case_dir/unused") || rc=$?
  expect_code 75 "$rc" "effective target did not defer: $out"
  assert_nothing_created "$case_dir" "$home" task-a "$before" "$worktrees"
  hold_deferred "$home" task-a
  for at in 1180 1240 1300 1360 1420 1480 1540 1600 1660; do
    load_fixture "$case_dir" "$at" normal 40 40
    load_tick "$case_dir"
  done
  load_expect "$case_dir" "$home" '.effective == 2 and .state.healthy == 9' 'nine healthy minutes cannot recover'
  load_fixture "$case_dir" 1720 normal 40 40
  load_tick "$case_dir"
  load_expect "$case_dir" "$home" '.effective == 3 and .state.healthy == 0' 'ten healthy minutes recover one slot despite residual swap use'
  declare_fleet "$home" 1
  load_tick "$case_dir"
  load_expect "$case_dir" "$home" '.effective == 1 and .floor == 1 and .ceiling == 1' 'manual cap immediately bounds policy'
  declare_fleet "$home" 3
  load_tick "$case_dir"
  load_expect "$case_dir" "$home" '.effective == 1' 'raising the manual cap cannot restore slots without healthy history'
  assert_not_contains "$(cat "$case_dir/calls.log")" 'kill-window' 'lowering effective target stopped existing occupants'
  unset FM_FLEET_LOAD_CLOCK FM_FLEET_LOAD_TELEMETRY
  pass 'enforce drops, recovers slowly, clamps to static cap and never stops occupants'
}

test_adaptive_critical_stale_and_invalid() {
  local case_dir home out rc=0 before worktrees notices
  case_dir=$(make_case adaptive-holds task-a)
  home="$case_dir/home"
  declare_fleet "$home" 3
  load_policy "$home" enforce 2 3 3
  load_fixture "$case_dir" 1000 critical 40 40
  load_tick "$case_dir"
  out=$(spawn_ship "$case_dir" task-a "$case_dir/unused") || rc=$?
  expect_code 75 "$rc" "critical hold admitted below the floor: $out"
  hold_deferred "$home" task-a
  load_expect "$case_dir" "$home" '.occupancy == 0 and .desired == 2 and (.hold | contains("critical"))' 'critical pressure holds even an empty fleet'
  load_fixture "$case_dir" 1060 normal 40 40; load_tick "$case_dir"
  load_expect "$case_dir" "$home" '(.hold | contains("critical"))' 'one normal sample cannot clear critical'
  load_fixture "$case_dir" 1120 normal 40 40; load_tick "$case_dir"
  load_expect "$case_dir" "$home" '.hold == "" and .effective == 2' 'two normal samples clear the hold without recovering capacity'
  load_fixture "$case_dir" 1301 normal 40 40
  printf 'unreadable sensor\n' > "$FM_FLEET_LOAD_TELEMETRY"
  before=$(call_count "$case_dir"); worktrees=$(worktree_list "$case_dir"); rc=0
  out=$(spawn_ship "$case_dir" task-a "$case_dir/unused") || rc=$?
  expect_code 75 "$rc" "stale telemetry admitted new work: $out"
  assert_contains "$out" 'stale sensor' 'stale admission names the observed reason'
  assert_nothing_created "$case_dir" "$home" task-a "$before" "$worktrees"
  notices=$(cat "$home/state/.fleet-load-notice")
  load_tick "$case_dir"
  assert_equals "$notices" "$(cat "$home/state/.fleet-load-notice")" 'identical hold changed its wake fingerprint'
  load_expect "$case_dir" "$home" '.state.healthy == 0 and .desired == 2 and .sample_age_seconds == 181' 'failed sensor retains target and resets healthy history'
  load_fixture "$case_dir" 1361 normal 40 40; load_tick "$case_dir"
  load_expect "$case_dir" "$home" '.hold == "" and .state.healthy == 0' 'gap resets recovery without stranding sensor retry'
  printf '{"version":99}\n' > "$home/state/fleet-load.json"
  rc=0; out=$(spawn_ship "$case_dir" task-a "$case_dir/unused") || rc=$?
  expect_code 75 "$rc" "incompatible state did not defer: $out"
  assert_contains "$out" 'incompatible fleet-load state' 'incompatible state is disclosed'
  printf '{"mode":"enforce","floor":0}\n' > "$home/config/fleet-load-policy"
  rc=0; out=$(spawn_ship "$case_dir" task-a "$case_dir/unused") || rc=$?
  expect_code 75 "$rc" "malformed enabled policy did not defer: $out"
  unset FM_FLEET_LOAD_CLOCK FM_FLEET_LOAD_TELEMETRY
  pass 'critical and stale holds defer below floor; healthy recovery, schema and config failures stay explicit'
}

test_adaptive_queue_priority() {
  local case_dir home out rc=0
  case_dir=$(make_case adaptive-priority task-c)
  home="$case_dir/home"
  declare_fleet "$home" 3
  load_policy "$home" enforce 1 1 1
  load_fixture "$case_dir" 1000 normal 40 40
  write_live "$home" parked-a "$case_dir/project"
  write_park "$home" parked-a queued
  out=$(spawn_ship "$case_dir" task-c "$case_dir/unused") || rc=$?
  expect_code 75 "$rc" "fresh spawn overtook queued resume under effective target: $out"
  assert_contains "$out" 'resume ahead of task task-c' 'adaptive cap retains queued-resume priority'
  load_expect "$case_dir" "$home" '.queued_resumes == 1 and .effective == 1' 'status includes the durable queue'
  unset FM_FLEET_LOAD_CLOCK FM_FLEET_LOAD_TELEMETRY
  pass 'effective capacity preserves queued-resume priority'
}

test_adaptive_concurrent_homes() (  # [command-to-run-after-first-admission]
  local case_dir home mate hold wt i first='' second='' first_rc=0 second_rc=0 owner
  # shellcheck source=bin/fm-timeout-lib.sh
  . "$ROOT/bin/fm-timeout-lib.sh"
  cleanup_concurrent_spawns() {
    local pid
    for pid in "$first" "$second"; do
      [ -z "$pid" ] || kill -TERM "$pid" 2>/dev/null || true
    done
    for pid in "$first" "$second"; do
      [ -z "$pid" ] || wait "$pid" 2>/dev/null || true
    done
  }
  trap cleanup_concurrent_spawns EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
  export -f run_spawn
  export SPAWN
  owner=$(exec sh -c 'printf "%s\n" "$PPID"')
  export FM_EXEC_TIMED_OWNER_PID="$owner"
  case_dir=$(make_case adaptive-concurrent task-a)
  home="$case_dir/home"; mate="$case_dir/mate"
  make_home "$mate" task-b
  printf '%s\n' schema=fm-secondmate-parent.v1 route=local "parent_home=$home" > "$mate/.fm-secondmate-parent"
  printf -- '- mate - local (home: %s; scope: project work; projects: project; added 2026-09-01)\n' "$mate" > "$home/data/secondmates.md"
  declare_fleet "$home" 3
  load_policy "$home" enforce 1 1 1
  load_fixture "$case_dir" 1000 normal 40 40
  hold="$case_dir/hold"; wt=$(new_worktree "$case_dir" task-a)
  ( FM_FAKE_HOLD="$hold" fm_exec_timed 120 2 bash -c 'run_spawn "$@"' _ \
    "$case_dir" "$home" "$wt" task-a "$case_dir/project" \
    --mode no-mistakes --ticket no-ticket --commit-type chore --yolo off ) > "$case_dir/first.out" 2>&1 &
  # shellcheck disable=SC2031 # The background PID is captured immediately in this shell.
  first=$!
  i=0
  while [ ! -f "$hold.reached" ]; do
    i=$((i + 1)); [ "$i" -lt 400 ] || fail "first admission never reached launch: $(cat "$case_dir/first.out")"
    sleep 0.05
  done
  ( fm_exec_timed 120 2 bash -c 'run_spawn "$@"' _ \
    "$case_dir" "$mate" "$case_dir/unused" task-b "$case_dir/other-project" \
    --mode no-mistakes --ticket no-ticket --commit-type chore --yolo off ) > "$case_dir/second.out" 2>&1 &
  # shellcheck disable=SC2031 # The background PID is captured immediately in this shell.
  second=$!
  "${1:-:}"
  : > "$hold.release"
  wait "$first" || first_rc=$?
  first=
  wait "$second" || second_rc=$?
  second=
  expect_code 0 "$first_rc" "first admission failed: $(cat "$case_dir/first.out")"
  expect_code 75 "$second_rc" "concurrent local-home admission exceeded effective target: $(cat "$case_dir/second.out")"
  assert_absent "$mate/state/task-b.meta" 'concurrent root/local-home spawn exceeded effective cap'
  load_expect "$case_dir" "$home" '.effective == 1 and .occupancy == 1' 'shared effective target bounds both homes'
  unset FM_FLEET_LOAD_CLOCK FM_FLEET_LOAD_TELEMETRY
  pass 'concurrent root/local-home admissions cannot both take the effective last place'
)

test_adaptive_memory_paging_and_history() {
  local case_dir home at state
  case_dir=$(make_case adaptive-history)
  home="$case_dir/home"
  declare_fleet "$home" 3
  load_policy "$home" enforce
  for at in 1000 1060; do
    load_fixture "$case_dir" "$at" warning 40 40
    load_tick "$case_dir"
  done
  load_expect "$case_dir" "$home" '.effective == 2 and .state.reason == "memory pressure"' 'two warning samples reduce capacity'
  load_fixture "$case_dir" 1120 normal 40 40 100000; load_tick "$case_dir"
  load_fixture "$case_dir" 1180 normal 40 40 200000; load_tick "$case_dir"
  load_expect "$case_dir" "$home" '.effective == 1 and .state.reason == "swap-out churn" and .state.swap_out_bytes_per_second > 16777216' 'two measured paging intervals reduce capacity using actual page size'
  for at in 1240 1300 1360; do
    load_fixture "$case_dir" "$at" normal 40 40 200000; load_tick "$case_dir"
  done
  load_expect "$case_dir" "$home" '.state.healthy == 3' 'healthy history accumulates'
  load_fixture "$case_dir" 1420 normal 40 40 1; load_tick "$case_dir"
  load_expect "$case_dir" "$home" '.state.healthy == 0 and .state.swap_out_bytes_per_second == null' 'paging counter reset cannot authorize recovery'
  load_fixture "$case_dir" 1600 normal 40 40 1; load_tick "$case_dir"
  load_expect "$case_dir" "$home" '.state.healthy == 0' 'missed sampling intervals cannot count as healthy'
  state=$(cat "$home/state/fleet-load.json")
  park_command "$case_dir" "$home" status >/dev/null
  assert_equals "$state" "$(cat "$home/state/fleet-load.json")" 'status mutated policy state'
  load_fixture "$case_dir" 1000 normal 40 40 1; load_tick "$case_dir"
  load_expect "$case_dir" "$home" '.state.healthy == 0 and .state.sample_epoch == 1000' 'backward clock invalidates history'
  load_fixture "$case_dir" 1060 normal 40 40 1 next-boot; load_tick "$case_dir"
  load_expect "$case_dir" "$home" '.state.healthy == 0 and .state.boot == "next-boot"' 'reboot starts with no healthy history'
  load_policy "$home" observe
  load_fixture "$case_dir" 1120 normal 40 40 1 next-boot; load_tick "$case_dir"
  load_expect "$case_dir" "$home" '.mode == "observe" and .state.healthy == 1' 'a mode change keeps observed history'
  load_policy "$home" observe 1 2 2
  load_tick "$case_dir"
  load_expect "$case_dir" "$home" '.mode == "observe" and .desired == 2 and .state.healthy == 0' 'policy limit changes invalidate history'
  unset FM_FLEET_LOAD_CLOCK FM_FLEET_LOAD_TELEMETRY
  pass 'memory pressure, measured paging and clock/config/boot invalidation govern history'
}

test_adaptive_native_sensor_and_projection() {
  local case_dir home status snapshot summary state
  case_dir=$(make_case adaptive-native)
  home="$case_dir/home"
  declare_fleet "$home" 3
  load_policy "$home" observe
  load_fixture "$case_dir" 1000 normal 40 40
  unset FM_FLEET_LOAD_TELEMETRY
  # Run the production collector using read-only tool fixtures, including XNU
  # dispatch pressure values, rather than injecting its normalized output.
  cat > "$case_dir/fakebin/sysctl" <<'SENSOR'
#!/usr/bin/env bash
case "$*" in
  '-n vm.loadavg') printf '{ 8.00 4.00 2.00 }\n' ;;
  '-n hw.ncpu') printf '4\n' ;;
  '-n kern.memorystatus_vm_pressure_level') cat "$FM_FAKE_CALL_LOG.pressure" ;;
  '-n vm.swapusage') printf 'total = 100M used = 50.0M free = 50M\n' ;;
  *) exit 1 ;;
esac
SENSOR
  cat > "$case_dir/fakebin/vm_stat" <<'SENSOR'
#!/usr/bin/env bash
printf 'Mach Virtual Memory Statistics: (page size of 16384 bytes)\nSwapins: 10.\nSwapouts: 20.\n'
SENSOR
  # The collector is macOS-only; a sysctl fixture never claims Linux is macOS.
  if [ "$(uname -s)" = Darwin ]; then
    chmod +x "$case_dir/fakebin/sysctl" "$case_dir/fakebin/vm_stat"
    printf '1\n' > "$case_dir/calls.log.pressure"
    load_tick "$case_dir"
    load_expect "$case_dir" "$home" '.state.signals.load1_centi == 200 and .state.signals.load5_centi == 100 and .state.signals.page_size == 16384 and .state.signals.pressure == "normal"' 'native collector normalizes CPU and dispatch pressure'
    printf '2\n' > "$case_dir/calls.log.pressure"
    printf '{"epoch":1060,"monotonic":1060,"boot":"fixture-boot"}\n' > "$FM_FLEET_LOAD_CLOCK"
    load_tick "$case_dir"
    load_expect "$case_dir" "$home" '.state.signals.pressure == "warning"' 'dispatch flag two means warning'
    printf '4\n' > "$case_dir/calls.log.pressure"
    printf '{"epoch":1120,"monotonic":1120,"boot":"fixture-boot"}\n' > "$FM_FLEET_LOAD_CLOCK"
    load_tick "$case_dir"
    load_expect "$case_dir" "$home" '.state.signals.pressure == "critical" and .desired == 1' 'dispatch flag four means critical'
  else
    load_tick "$case_dir"
    load_expect "$case_dir" "$home" '.mode == "observe" and .effective == 3 and (.hold | length > 0)' 'unsupported platform reports a policy hold without refusing observation'
    load_fixture "$case_dir" 1060 normal 40 40
    load_tick "$case_dir"
  fi
  state=$(cat "$home/state/fleet-load.json")
  status=$(park_command "$case_dir" "$home" status)
  snapshot=$(FM_HOME="$home" FM_ROOT_OVERRIDE='' FM_STATE_OVERRIDE='' FM_CONFIG_OVERRIDE='' FM_DATA_OVERRIDE='' FM_PROJECTS_OVERRIDE='' FM_FAKE_CALL_LOG="$case_dir/calls.log" FM_BACKEND=tmux PATH="$case_dir/fakebin:$TEST_PATH" bash "$ROOT/bin/fm-fleet-snapshot.sh" --json) || fail 'fleet snapshot failed'
  assert_equals "$(printf '%s' "$status" | jq -cS .)" "$(printf '%s' "$snapshot" | jq -cS .capacity)" 'snapshot and status disagree on capacity'
  summary=$(FM_HOME="$home" FM_ROOT_OVERRIDE='' FM_STATE_OVERRIDE='' FM_CONFIG_OVERRIDE='' FM_DATA_OVERRIDE='' FM_PROJECTS_OVERRIDE='' FM_FAKE_CALL_LOG="$case_dir/calls.log" FM_BACKEND=tmux PATH="$case_dir/fakebin:$TEST_PATH" bash "$ROOT/bin/fm-fleet-snapshot.sh" --secondmate-home-summary) || fail 'home summary failed'
  assert_equals "$(printf '%s' "$status" | jq -cS .)" "$(printf '%s' "$summary" | jq -cS .capacity)" 'home summary and status disagree on capacity'
  assert_equals "$state" "$(cat "$home/state/fleet-load.json")" 'snapshot or summary refreshed telemetry'
  unset FM_FLEET_LOAD_CLOCK FM_FLEET_LOAD_TELEMETRY
  pass 'native collector and common read-only status/snapshot/home-summary projection'
}

test_unused_ad_hoc_flag_does_not_raise_the_cap() {
  local case_dir home out rc=0
  case_dir=$(make_case adhoc-unused task-c task-d)
  home="$case_dir/home"
  declare_fleet "$home" 3
  write_running "$case_dir" "$home" live-a "$case_dir/project"
  write_running "$case_dir" "$home" live-b "$case_dir/project"
  out=$(run_spawn "$case_dir" "$home" "$(new_worktree "$case_dir" task-c)" \
    task-c "$case_dir/project" --mode no-mistakes --ticket no-ticket \
    --commit-type chore --yolo off --ad-hoc-slot) || rc=$?
  expect_code 0 "$rc" "C could not use the free ordinary place: $out"
  assert_not_contains "$(cat "$home/state/task-c.meta")" 'ad_hoc_' \
    'C recorded a grant despite using an ordinary place'
  rc=0
  out=$(spawn_ship "$case_dir" task-d "$case_dir/unused") || rc=$?
  expect_code 75 "$rc" "the unused flag on C admitted ordinary D: $out"
  pass 'a flagged C uses the third ordinary place and cannot admit D'
}

test_ad_hoc_grants_are_independent_per_cap() {
  local axis case_dir home out rc pane
  for axis in fleet project; do
    case_dir=$(make_case "adhoc-only-$axis" task-b task-c task-d)
    home="$case_dir/home"
    if [ "$axis" = fleet ]; then
      declare_fleet "$home" 1
      printf 'project 2\n' > "$home/config/project-capacity"
      write_running "$case_dir" "$home" live-a "$case_dir/other-project"
    else
      declare_fleet "$home" 3
      printf 'project 1\n' > "$home/config/project-capacity"
      write_running "$case_dir" "$home" live-a "$case_dir/project"
    fi
    pane=$(new_worktree "$case_dir" task-b)
    rc=0
    out=$(run_spawn "$case_dir" "$home" "$pane" task-b "$case_dir/project" \
      --mode no-mistakes --ticket no-ticket --commit-type chore --yolo off --ad-hoc-slot) || rc=$?
    expect_code 0 "$rc" "$axis-only grant was refused: $out"
    assert_contains "$(cat "$home/state/task-b.meta")" "ad_hoc_${axis}_slot=1" 'missing cap-specific grant'
    if [ "$axis" = fleet ]; then
      assert_not_contains "$(cat "$home/state/task-b.meta")" ad_hoc_project_slot 'fleet grant raised project capacity'
    else
      assert_not_contains "$(cat "$home/state/task-b.meta")" ad_hoc_fleet_slot 'project grant raised fleet capacity'
    fi
    rc=0
    out=$(FM_FAKE_AGENT_COMMAND=bash run_spawn "$case_dir" "$home" "$pane" \
      task-b --relaunch --harness codex) || rc=$?
    expect_code 0 "$rc" "live relaunch lost its $axis grant: $out"
    assert_contains "$(cat "$home/state/task-b.meta")" "ad_hoc_${axis}_slot=1" 'relaunch dropped its own grant'
    if [ "$axis" = fleet ]; then
      write_running "$case_dir" "$home" live-c "$case_dir/project"
      rc=0
      out=$(spawn_ship "$case_dir" task-c "$case_dir/unused") || rc=$?
      expect_code 75 "$rc" "fleet grant admitted beyond project capacity: $out"
      assert_contains "$out" 'deferred: project' 'the wrong cap deferred the task'
    else
      rc=0
      out=$(run_spawn "$case_dir" "$home" "$(new_worktree "$case_dir" task-c)" \
        task-c "$case_dir/other-project" --mode no-mistakes --ticket no-ticket --commit-type chore --yolo off) || rc=$?
      expect_code 0 "$rc" "ordinary task could not use the third fleet place: $out"
      rc=0
      out=$(run_spawn "$case_dir" "$home" "$case_dir/unused" task-d "$case_dir/other-project" \
        --mode no-mistakes --ticket no-ticket --commit-type chore --yolo off) || rc=$?
      expect_code 75 "$rc" "project grant raised fleet capacity: $out"
      assert_contains "$out" 'deferred: this machine' 'the wrong cap deferred the task'
    fi
  done
  pass 'grants and live relaunches raise only their own cap'
}

# An ad hoc grant lets ONE named task start above the declared cap without
# changing the declaration, and every other spawn still sees the declared
# number of places.
test_ad_hoc_slot_admits_one_task_over_the_cap() {
  local case_dir home declared out rc=0 before worktrees pane
  case_dir=$(make_case adhoc task-c task-d task-e)
  home="$case_dir/home"
  declare_fleet "$home" "# whole machine" "2"
  declared=$(cat "$home/config/fleet-capacity")
  write_running "$case_dir" "$home" live-a "$case_dir/project"
  write_running "$case_dir" "$home" live-b "$case_dir/project"

  pane=$(new_worktree "$case_dir" task-c)
  before=$(call_count "$case_dir")
  worktrees=$(worktree_list "$case_dir")
  out=$(spawn_ship "$case_dir" task-c "$pane") || rc=$?
  expect_code "$DEFER_EXIT" "$rc" "a full fleet admitted an ordinary spawn: $out"
  assert_nothing_created "$case_dir" "$home" task-c "$before" "$worktrees"

  rc=0
  out=$(run_spawn "$case_dir" "$home" "$(new_worktree "$case_dir" task-d)" \
    task-d "$case_dir/project" --mode no-mistakes --ticket no-ticket \
    --commit-type chore --yolo off --ad-hoc-slot) || rc=$?
  expect_code 0 "$rc" "an ad hoc slot did not admit its task over the cap: $out"
  assert_contains "$(cat "$home/state/task-d.meta")" "ad_hoc_fleet_slot=1" \
    "the ad hoc grant was not recorded in the task's own record"
  assert_equals "$declared" "$(cat "$home/config/fleet-capacity")" \
    "an ad hoc slot edited the capacity declaration"
  rc=0
  pane=$(new_worktree "$case_dir" task-e)
  before=$(call_count "$case_dir")
  worktrees=$(worktree_list "$case_dir")
  out=$(spawn_ship "$case_dir" task-e "$pane") || rc=$?
  expect_code "$DEFER_EXIT" "$rc" "the ad hoc grant leaked to another task: $out"
  assert_contains "$out" "plus 1 ad hoc" "the deferral did not name the ad hoc occupancy"
  assert_contains "$out" "task-d (ad hoc)" "the deferral did not mark the ad hoc holder"
  assert_nothing_created "$case_dir" "$home" task-e "$before" "$worktrees"
  pass "an ad hoc slot admits exactly its own task over the cap and changes no declaration"
}

# A live relaunch replaces a worker that already holds a place, so it runs no
# admission. Taking the grant there would raise both caps for a task that was
# never admitted over them, admitting the next ordinary queued task instead.
test_ad_hoc_slot_is_refused_on_a_live_relaunch() {
  local case_dir home pane out rc=0 before worktrees
  case_dir=$(make_case adhoc-relaunch task-d)
  home="$case_dir/home"
  declare_fleet "$home" 3
  pane=$(new_worktree "$case_dir" live-a)
  write_brief "$home" live-a legacy
  write_running "$case_dir" "$home" live-a "$case_dir/project"
  sed "s|^worktree=.*|worktree=$pane|" "$home/state/live-a.meta" > "$home/state/live-a.meta.next"
  mv "$home/state/live-a.meta.next" "$home/state/live-a.meta"
  write_running "$case_dir" "$home" live-b "$case_dir/project"
  write_running "$case_dir" "$home" live-c "$case_dir/project"

  out=$(FM_FAKE_AGENT_COMMAND=bash run_spawn "$case_dir" "$home" "$pane" \
    live-a --relaunch --harness codex --ad-hoc-slot) || rc=$?
  expect_code 1 "$rc" "a live relaunch took an ad hoc grant: $out"
  assert_contains "$out" 'already holds an ordinary place' 'the refusal did not say why'
  assert_not_contains "$(cat "$home/state/live-a.meta")" "ad_hoc_" \
    'a refused relaunch still recorded the grant'

  rc=0
  pane=$(new_worktree "$case_dir" task-d)
  before=$(call_count "$case_dir")
  worktrees=$(worktree_list "$case_dir")
  out=$(spawn_ship "$case_dir" task-d "$pane") || rc=$?
  expect_code "$DEFER_EXIT" "$rc" "the refused grant still admitted another task: $out"
  assert_nothing_created "$case_dir" "$home" task-d "$before" "$worktrees"
  pass "a live relaunch cannot take an ad hoc grant and admits no other task"
}

# The grant lives in the task's own record, so the fleet view and snapshot can
# say how many of the held places are ad hoc.
test_ad_hoc_occupancy_is_visible() {
  local case_dir home snapshot view
  case_dir=$(make_case adhoc-view)
  home="$case_dir/home"
  declare_fleet "$home" "3"
  write_running "$case_dir" "$home" live-a "$case_dir/project"
  write_running "$case_dir" "$home" extra-b "$case_dir/project" "ad_hoc_fleet_slot=1"
  snapshot=$(FM_HOME="$home" FM_ROOT_OVERRIDE='' FM_STATE_OVERRIDE='' FM_CONFIG_OVERRIDE='' \
    FM_DATA_OVERRIDE='' FM_PROJECTS_OVERRIDE='' FM_FAKE_CALL_LOG="$case_dir/calls.log" \
    FM_BACKEND=tmux PATH="$case_dir/fakebin:$TEST_PATH" bash "$ROOT/bin/fm-fleet-snapshot.sh" --json) ||
    fail 'fleet snapshot failed'
  assert_equals 1 "$(printf '%s' "$snapshot" | jq -r '.capacity.ad_hoc')" \
    'the snapshot did not count the ad hoc place'
  assert_equals true "$(printf '%s' "$snapshot" | jq -r '.tasks[] | select(.id == "extra-b") | .ad_hoc_slot')" \
    'the snapshot did not mark the ad hoc task'
  assert_equals false "$(printf '%s' "$snapshot" | jq -r '.tasks[] | select(.id == "live-a") | .ad_hoc_slot')" \
    'the snapshot marked an ordinary task as ad hoc'
  view=$(FM_HOME="$home" FM_ROOT_OVERRIDE='' FM_STATE_OVERRIDE='' FM_CONFIG_OVERRIDE='' \
    FM_DATA_OVERRIDE='' FM_PROJECTS_OVERRIDE='' FM_FAKE_CALL_LOG="$case_dir/calls.log" \
    FM_BACKEND=tmux PATH="$case_dir/fakebin:$TEST_PATH" bash "$ROOT/bin/fm-fleet-view.sh") ||
    fail 'fleet view failed'
  assert_contains "$view" "1 of them ad hoc" 'the fleet view did not report ad hoc occupancy'
  assert_contains "$view" "ship (ad hoc)" 'the fleet view did not mark the ad hoc task'
  pass "the fleet view and snapshot report ad hoc occupancy"
}

test_adaptive_spawn_cleanup() {
  python3 - "$ROOT/tests/fm-fleet-capacity.test.sh" "$TMP_ROOT" <<'PY' || fail 'adaptive spawn cleanup regression'
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

suite, root = sys.argv[1:]
script = r'''
. "$1"
marker=$2
mode=$3
checkpoint() {
  case_pid=$(exec sh -c 'printf "%s" "$PPID"')
  printf '%s\n%s\n' "$case_pid" "$case_dir" > "$marker"
  while [ ! -e "$marker.release" ]; do sleep 0.05; done
  case "$mode" in
    pass) return ;;
    fail) exit 42 ;;
    *) while :; do sleep 0.1; done ;;
  esac
}
test_adaptive_concurrent_homes checkpoint
'''


def spawn_groups(owner, parent_group):
    rows = [list(map(int, row.split())) for row in subprocess.check_output(
        ['ps', '-axo', 'pid=,ppid=,pgid='], text=True, timeout=3).splitlines()]
    descendants = {owner}
    while True:
        found = {pid for pid, parent, _ in rows if parent in descendants}
        if found <= descendants:
            break
        descendants |= found
    return {group for pid, _, group in rows
            if pid in descendants and group != parent_group}


def group_members(pgid):
    rows = subprocess.check_output(
        ['ps', '-axo', 'pid=,pgid=,stat='], text=True, timeout=3)
    return [int(pid) for pid, group, state in map(str.split, rows.splitlines())
            if int(group) == pgid and not state.startswith('Z')]


for mode in ('pass', 'fail', 'TERM', 'INT', 'HUP', 'KILL', 'outer-TERM', 'timeout'):
    marker = Path(root) / ('cleanup-' + mode)
    command = ['bash', '-c', script, '_', suite, str(marker), mode]
    if mode == 'timeout':
        # Exercise the runner's real deadline while the checkpoint stays held.
        command = ['bash', '-c', '. "$1"; shift; fm_exec_timed 45 2 "$@"',
                   '_', str(Path(suite).parent.parent / 'bin/fm-timeout-lib.sh'),
                   *command]
    process = subprocess.Popen(command,
                               start_new_session=True, stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, text=True)
    groups = set()
    try:
        deadline = time.monotonic() + 30
        while not marker.exists() or len(marker.read_text().splitlines()) < 2:
            if process.poll() is not None or time.monotonic() >= deadline:
                raise AssertionError(f'{mode}: admission did not reach checkpoint')
            time.sleep(0.05)
        case_pid, case_dir = marker.read_text().splitlines()
        suite_group = os.getpgid(int(case_pid))
        deadline = time.monotonic() + 10
        while len(groups) < 2 and time.monotonic() < deadline:
            groups |= spawn_groups(int(case_pid), suite_group)
            time.sleep(0.05)
        assert len(groups) == 2, f'{mode}: did not observe both spawn groups: {groups}'
        assert all(group_members(group) for group in groups), f'{mode}: spawn already exited'
        if mode in ('pass', 'fail'):
            Path(str(marker) + '.release').touch()
        elif mode == 'outer-TERM':
            os.killpg(process.pid, signal.SIGTERM)
        elif mode == 'timeout':
            pass  # No release or signal: only the runner's deadline can end it.
        else:
            sig = getattr(signal, 'SIG' + mode)
            os.kill(int(case_pid), sig)
        # Normal admission runs the real spawn path; interruption only reaps it.
        out, err = process.communicate(timeout=60 if mode in ('pass', 'timeout') else 10)
        expected = {'pass': (0,), 'fail': (42,), 'outer-TERM': (-signal.SIGTERM, 143),
                    'timeout': (124,)}.get(mode, (128 + getattr(signal, 'SIG' + mode, 0),))
        assert process.returncode in expected, (mode, process.returncode, out, err)
        deadline = time.monotonic() + 5
        while any(group_members(group) for group in groups) and time.monotonic() < deadline:
            time.sleep(0.05)
        assert not any(group_members(group) for group in groups), f'{mode}: live spawn descendants survived cleanup'
        print(f'ok - {mode}: observed both spawn groups {sorted(groups)}; no running descendants', flush=True)
    finally:
        # Even a regressed fixture cannot leak from its own regression check.
        groups |= spawn_groups(process.pid, process.pid)
        for group in groups:
            try:
                os.killpg(group, signal.SIGKILL)
            except ProcessLookupError:
                pass
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            process.communicate(timeout=5)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.communicate(timeout=5)
print('ok - adaptive admission reaps spawn groups on pass, failure, timeout and signals')
PY
}

test_lock_wait_stops_when_parent_is_gone() {
  python3 - "$ROOT/bin/fm-wake-lib.sh" "$TMP_ROOT" <<'PY' || fail 'lock wait survived a missing parent'
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

lib, root = sys.argv[1:]
for function in ('fm_lock_acquire_wait', 'fm_lock_acquire_wait_max'):
    parent = Path(root) / ('removed-lock-parent-' + function)
    parent.mkdir()
    lock = parent / 'lock'
    lock.mkdir()
    (lock / 'pid').write_text(str(os.getpid()) + '\n')
    process = subprocess.Popen(['bash', '-c', '. "$1"; "$2" "$3" 120',
                                '_', lib, function, str(lock)], start_new_session=True,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    try:
        time.sleep(0.3)
        assert process.poll() is None, 'live lock did not hold the waiter'
        (lock / 'pid').unlink()
        lock.rmdir()
        parent.rmdir()
        out, err = process.communicate(timeout=3)
        assert process.returncode == 1, (process.returncode, out, err)
    finally:
        if process.poll() is None:
            os.killpg(process.pid, signal.SIGKILL)
        process.communicate()
print('ok - lock wait exits when its parent directory disappears')
PY
}

if [ "${BASH_SOURCE[0]}" != "$0" ]; then return 0; fi

test_lock_wait_stops_when_parent_is_gone
test_adaptive_spawn_cleanup
test_unused_ad_hoc_flag_does_not_raise_the_cap
test_ad_hoc_grants_are_independent_per_cap
test_adaptive_memory_paging_and_history
test_adaptive_native_sensor_and_projection
test_adaptive_off_and_observe
test_json_off_without_fleet_cap_stays_uncapped
test_adaptive_drop_recover_and_static_clamp
test_adaptive_critical_stale_and_invalid
test_adaptive_queue_priority
test_adaptive_concurrent_homes
test_parked_relaunch_respects_both_caps
test_parked_capacity_and_priority
test_parked_resume_has_project_priority
test_undeclared_fleet_stays_uncapped
test_full_fleet_defers_without_leaving_anything_behind
test_ad_hoc_slot_admits_one_task_over_the_cap
test_ad_hoc_slot_is_refused_on_a_live_relaunch
test_ad_hoc_occupancy_is_visible
test_dead_agents_free_their_place
test_fresh_spawn_waits_for_a_briefly_busy_fleet_lock
test_fleet_is_shared_by_every_local_home
test_unreadable_declaration_refuses_every_spawn
test_endpoint_probes_run_together_with_serial_verdicts
