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
. "$FM_WT/tests/lib.sh"

unset TASKS_AXI_BACKEND || :

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-fleet-capacity)
DEFER_EXIT=75
TEST_PATH=$PATH
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

write_park() { # home id phase
  printf 'phase=%s\ngeneration=s-%s\nendpoint=firstmate:fm-%s\nreason=upstream maintainer\nuntil=0\nqueued_at=1\n' "$3" "$2" "$2" > "$1/state/$2.park"
}
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
