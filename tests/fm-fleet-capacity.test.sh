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
HAVE_TASKS_AXI=0
command -v tasks-axi >/dev/null 2>&1 && HAVE_TASKS_AXI=1

# --- fixture ----------------------------------------------------------------

write_brief() {  # <home> <id>
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
  run_spawn "$case_dir" "$case_dir/home" "$pane" "$id" "$case_dir/project" --mode no-mistakes --yolo off
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
  out=$(run_spawn "$case_dir" "$mate" "$case_dir/wt-m" task-m "$mate_project" --mode no-mistakes --yolo off) || rc=$?
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
  write_live "$home" parked-a "$case_dir/project"
  write_park "$home" parked-a queued
  out=$(spawn_ship "$case_dir" task-c) || rc=$?
  expect_code 75 "$rc" "fresh dispatch took the project place a queued resume waits for: $out"
  assert_contains "$out" 'in project project and resume ahead of task task-c' 'project admission enforces resume priority'
  assert_absent "$home/state/task-c.meta" 'project priority deferral creates no record'

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
  pass 'queued resumes take priority for their own project cap only'
}

test_parked_relaunch_respects_both_caps() {
  local case_dir home pane out rc=0
  case_dir=$(make_case resume-cap)
  home="$case_dir/home"
  pane=$(new_worktree "$case_dir" parked-a)
  write_brief "$home" parked-a
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

test_parked_relaunch_respects_both_caps
test_parked_capacity_and_priority
test_parked_resume_has_project_priority
test_undeclared_fleet_stays_uncapped
test_full_fleet_defers_without_leaving_anything_behind
test_dead_agents_free_their_place
test_fleet_is_shared_by_every_local_home
test_unreadable_declaration_refuses_every_spawn
test_endpoint_probes_run_together_with_serial_verdicts
