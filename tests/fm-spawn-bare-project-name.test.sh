#!/usr/bin/env bash
# Behavior tests for bin/fm-spawn.sh's project-argument resolution
# (resolve_project_dir_arg). A bare registered project name used to only work
# when the caller happened to already be inside projects/, because every other
# bare name was handed straight to `cd` and failed with a raw
# "No such file or directory" instead of a clear refusal. This file pins:
# a bare registered name resolving to its clone under projects/, an unknown
# bare name refusing before any cd with a clear error, and the pre-existing
# absolute-path and projects/<name> forms staying unchanged.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-bare-project-name)

# A home with one registered project "myproj" cloned under projects/myproj, a
# scratch brief for the given task id, and a fake tmux that exits non-zero so no
# window or worktree is ever created. Echoes "<home>|<projects-dir>|<fakebin>".
make_home() {  # <name> <task-id>
  local name=$1 id=$2 home projects fakebin
  home="$TMP_ROOT/$name/home"
  projects="$TMP_ROOT/$name/projects"
  fakebin="$TMP_ROOT/$name/bin"
  mkdir -p "$home/data/$id" "$home/state" "$home/config" "$projects/myproj" "$fakebin"
  git -C "$projects/myproj" init -q || fail "could not initialize project fixture"
  # A markdown backlog config with no backlog.md file exempts this fixture from
  # the automatic backlog transition gate (fm_backlog_transition_applies),
  # which is unrelated to the project-argument resolution under test here.
  fm_test_tasks_toml "$home/.tasks.toml"
  # Echoes its args to stderr before refusing (the spawn captures tmux's stdout
  # to parse a window id, so a stdout echo would be silently discarded), so a
  # test can tell "resolution succeeded and the spawn reached the backend" apart
  # from "resolution failed first".
  printf '#!/bin/sh\necho TMUX_ARGS "$@" >&2\nexit 1\n' > "$fakebin/tmux"
  chmod +x "$fakebin/tmux"
  printf '%s\n' "- myproj - fixture (added 2026-01-01)" > "$home/data/projects.md"
  printf 'You are a crewmate.\n\n# Task\n## Captain'\''s intent\nExercise bare project resolution.\n\n## Firstmate spec\nVerify project-argument resolution.\n\n# Definition of done\n' \
    > "$home/data/$id/brief.md"
  printf '%s\n' "$home|$projects|$fakebin"
}

run_spawn() {  # <home> <projects-dir> <fakebin> <spawn-args...>
  local home=$1 projects=$2 fakebin=$3
  shift 3
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_BACKEND=tmux PATH="$fakebin:$PATH" \
    "$SPAWN" "$@" 2>&1
}

# A bare name with no slash, not an existing directory relative to the working
# directory, that names a project registered in data/projects.md with a clone at
# projects/<name>, must resolve to that clone: the spawn must get past project
# resolution and reach the backend (the fake tmux), never a raw cd failure.
test_bare_registered_name_resolves_to_its_clone() {
  local rec home projects fakebin out
  rec=$(make_home registered bare-resolve-a1)
  IFS='|' read -r home projects fakebin <<EOF
$rec
EOF
  out=$(run_spawn "$home" "$projects" "$fakebin" bare-resolve-a1 myproj claude --scout)
  assert_not_contains "$out" "No such file or directory" \
    "a bare registered project name still hit a raw cd failure"
  assert_not_contains "$out" "does not resolve to a project" \
    "a bare registered project name was refused as unresolvable"
  assert_contains "$out" "$projects/myproj" \
    "the spawn never reached the resolved clone path"
  pass "fm-spawn: a bare registered project name resolves to its clone under projects/"
}

# An unregistered bare name, or one with no clone under projects/, must refuse
# before any cd with one clear error naming the accepted forms, never a raw
# "No such file or directory".
test_unknown_bare_name_refuses_clearly_before_any_cd() {
  local rec home projects fakebin out status
  rec=$(make_home unregistered bare-refuse-a1)
  IFS='|' read -r home projects fakebin <<EOF
$rec
EOF
  out=$(run_spawn "$home" "$projects" "$fakebin" bare-refuse-a1 nosuchproject claude --scout)
  status=$?
  [ "$status" -ne 0 ] || fail "an unknown bare project name was accepted"
  assert_contains "$out" "\"nosuchproject\" does not resolve to a project" \
    "the refusal did not name the unresolved argument"
  assert_contains "$out" "projects/<name>" "the refusal did not name the accepted forms"
  assert_contains "$out" "registered in data/projects.md" "the refusal did not name the accepted forms"
  assert_not_contains "$out" "No such file or directory" \
    "an unknown bare project name still produced a raw cd failure instead of a clear refusal"
  pass "fm-spawn: an unknown bare project name refuses clearly before any cd"
}

# A registered name with no clone on disk is exactly as unresolvable as an
# unregistered one: resolving it would hand a nonexistent path to cd.
test_registered_name_without_a_clone_refuses_clearly() {
  local rec home projects fakebin out status
  rec=$(make_home no-clone bare-refuse-b1)
  IFS='|' read -r home projects fakebin <<EOF
$rec
EOF
  printf '%s\n' "- ghost - fixture (added 2026-01-01)" >> "$home/data/projects.md"
  out=$(run_spawn "$home" "$projects" "$fakebin" bare-refuse-b1 ghost claude --scout)
  status=$?
  [ "$status" -ne 0 ] || fail "a registered project name with no clone on disk was accepted"
  assert_contains "$out" "\"ghost\" does not resolve to a project" \
    "the refusal did not name the unresolved registered argument"
  assert_not_contains "$out" "No such file or directory" \
    "a registered name with no clone still produced a raw cd failure instead of a clear refusal"
  pass "fm-spawn: a registered project name with no clone on disk refuses clearly"
}

# The absolute-path and projects/<name> forms already resolved correctly and must
# keep doing so unchanged: both reach the same later brief-validation failure as
# the bare-name case above, proving project resolution succeeded in each case.
test_existing_path_forms_are_unchanged() {
  local rec home projects fakebin out
  rec=$(make_home existing-forms bare-unchanged-a1)
  IFS='|' read -r home projects fakebin <<EOF
$rec
EOF
  out=$(run_spawn "$home" "$projects" "$fakebin" bare-unchanged-a1 "$projects/myproj" claude --scout)
  assert_not_contains "$out" "No such file or directory" \
    "an absolute project path regressed to a raw cd failure"
  assert_not_contains "$out" "does not resolve to a project" \
    "an absolute project path was refused as unresolvable"
  assert_contains "$out" "$projects/myproj" "the spawn never reached the resolved clone path"

  rec=$(make_home existing-forms-rel bare-unchanged-a2)
  IFS='|' read -r home projects fakebin <<EOF
$rec
EOF
  out=$(run_spawn "$home" "$projects" "$fakebin" bare-unchanged-a2 "projects/myproj" claude --scout)
  assert_not_contains "$out" "No such file or directory" \
    "a projects/<name> argument regressed to a raw cd failure"
  assert_not_contains "$out" "does not resolve to a project" \
    "a projects/<name> argument was refused as unresolvable"
  assert_contains "$out" "$projects/myproj" "the spawn never reached the resolved clone path"
  pass "fm-spawn: existing absolute-path and projects/<name> forms resolve unchanged"
}

test_bare_registered_name_resolves_to_its_clone
test_unknown_bare_name_refuses_clearly_before_any_cd
test_registered_name_without_a_clone_refuses_clearly
test_existing_path_forms_are_unchanged
echo "# all fm-spawn-bare-project-name tests passed"
