#!/usr/bin/env bash
# Behavior tests for the pre-ready Boat check declaration reader
# (bin/fm-boat-prepush-lib.sh). Every case drives fm_boat_prepush_lookup
# against a real declaration file and judges it by the fields it published and
# by whether it refused, never by how it parsed.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-boat-prepush-lib.sh
. "$ROOT/bin/fm-boat-prepush-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-boat-prepush-lib)

# A config directory holding the given declaration lines, or none at all.
declare_config() {  # <name> [line...]
  local dir="$TMP_ROOT/$1"
  shift
  mkdir -p "$dir"
  rm -f "$dir/boat-prepush"
  [ "$#" -eq 0 ] || printf '%s\n' "$@" > "$dir/boat-prepush"
  printf '%s\n' "$dir"
}

# The four published fields of one lookup, as a single comparable row.
lookup_row() {  # <config-dir> <project>
  fm_boat_prepush_lookup "$1" "$2" || return 1
  printf 'declared=%s type=%s timeout=%s history-depth=%s\n' \
    "${FM_BOAT_PREPUSH_DECLARED:-no}" "$FM_BOAT_PREPUSH_TYPE" \
    "$FM_BOAT_PREPUSH_TIMEOUT" "${FM_BOAT_PREPUSH_HISTORY_DEPTH:-none}"
}

# Assert that <line> makes the whole declaration unreadable, whichever project
# is looked up, and that the refusal names the file.
assert_refuses() {  # <name> <what> <line>...
  local name=$1 what=$2 dir rc=0 row
  shift 2
  dir=$(declare_config "$name" "$@")
  row=$(lookup_row "$dir" core) || rc=$?
  [ "$rc" -eq 1 ] || fail "$what was accepted: $row"
  fm_boat_prepush_lookup "$dir" core && fail "$what returned success"
  assert_contains "$FM_BOAT_PREPUSH_ERROR" "$dir/boat-prepush" \
    "$what refusal did not name the declaration file"
  [ -z "$FM_BOAT_PREPUSH_DECLARED" ] \
    || fail "$what left a project declared"
}

test_absent_declaration_declares_nothing() {
  local dir
  dir=$(declare_config absent)
  fm_boat_prepush_lookup "$dir" core || fail "an absent declaration was reported as an error"
  assert_equals "declared=no type= timeout= history-depth=none" "$(lookup_row "$dir" core)" \
    "an absent declaration did not leave the project undeclared"
  assert_equals "$dir/boat-prepush" "$FM_BOAT_PREPUSH_FILE" \
    "an absent declaration did not report the path it looked for"
  pass "an absent declaration leaves every project undeclared and succeeds"
}

test_bare_name_takes_the_documented_defaults() {
  local dir
  dir=$(declare_config bare core)
  assert_equals "declared=1 type=default timeout=2700 history-depth=none" "$(lookup_row "$dir" core)" \
    "a bare project line did not take the documented defaults"
  pass "a bare project line declares the check on a default machine, a 2700s timeout, and no history"
}

test_undeclared_project_in_a_valid_file_is_not_declared() {
  local dir
  dir=$(declare_config other core 'satellite type=large')
  assert_equals "declared=no type= timeout= history-depth=none" "$(lookup_row "$dir" unlisted)" \
    "a project absent from a valid declaration was reported as declared"
  pass "a project absent from a valid declaration stays undeclared"
}

test_every_field_parses_in_any_order() {
  local dir
  dir=$(declare_config fields \
    'core history-depth=50 type=large timeout=1' \
    'satellite timeout=2700 history-depth=1000' \
    'tiny type=default')
  assert_equals "declared=1 type=large timeout=1 history-depth=50" "$(lookup_row "$dir" core)" \
    "mixed-order fields did not parse"
  assert_equals "declared=1 type=default timeout=2700 history-depth=1000" "$(lookup_row "$dir" satellite)" \
    "the range bounds did not parse"
  assert_equals "declared=1 type=default timeout=2700 history-depth=none" "$(lookup_row "$dir" tiny)" \
    "an explicit default type did not parse"
  pass "type, timeout, and history depth parse in any order, at their bounds, alongside other projects"
}

test_comments_and_blank_lines_are_ignored() {
  local dir
  dir=$(declare_config comments \
    '#' \
    '# the core suite is the only heavy one' \
    '' \
    '   ' \
    '  core type=large  ' \
    '')
  assert_equals "declared=1 type=large timeout=2700 history-depth=none" "$(lookup_row "$dir" core)" \
    "a declaration among comments and blank lines did not parse"
  pass "blank lines, a bare # and a '# ' comment are ignored"
}

test_malformed_declarations_refuse_the_whole_file() {
  assert_refuses xlarge 'type=xlarge' 'core type=xlarge'
  assert_refuses badtype 'an unknown machine type' 'core type=huge'
  assert_refuses zerotimeout 'timeout=0' 'core timeout=0'
  assert_refuses hightimeout 'a timeout above 2700' 'core timeout=2701'
  assert_refuses wordtimeout 'a non-numeric timeout' 'core timeout=soon'
  assert_refuses emptytimeout 'an empty timeout' 'core timeout='
  assert_refuses zerodepth 'history-depth=0' 'core history-depth=0'
  assert_refuses highdepth 'a history depth above 1000' 'core history-depth=1001'
  assert_refuses unknownkey 'an unknown key' 'core swap-gib=2'
  assert_refuses bareword 'a field that is not <key>=<value>' 'core large'
  assert_refuses dupkey 'the same key twice on one line' 'core type=large type=default'
  assert_refuses dupproject 'a project named twice' 'core type=large' 'core timeout=60'
  pass "a bad type, bound, key, shape, repeated key, or repeated project refuses the whole declaration"
}

test_an_unreadable_declaration_refuses() {
  local dir rc=0
  dir=$(declare_config unreadable core)
  chmod 000 "$dir/boat-prepush"
  if [ -r "$dir/boat-prepush" ]; then
    chmod 600 "$dir/boat-prepush"
    pass "skipped: this user reads a mode 000 file"
    return 0
  fi
  fm_boat_prepush_lookup "$dir" core || rc=$?
  chmod 600 "$dir/boat-prepush"
  [ "$rc" -eq 1 ] || fail "an unreadable declaration was accepted"
  assert_contains "$FM_BOAT_PREPUSH_ERROR" "is not a readable regular file" \
    "the unreadable refusal did not say why"
  pass "an unreadable declaration refuses instead of declaring nothing"
}

test_a_directory_in_place_of_the_declaration_refuses() {
  local dir rc=0
  dir=$(declare_config dirfile)
  mkdir -p "$dir/boat-prepush"
  fm_boat_prepush_lookup "$dir" core || rc=$?
  [ "$rc" -eq 1 ] || fail "a directory in place of the declaration was accepted"
  pass "a directory in place of the declaration refuses"
}

test_config_dir_follows_the_home_overrides() {
  local out
  out=$(CONFIG=/explicit FM_CONFIG_OVERRIDE=/override FM_HOME=/home fm_boat_prepush_config_dir)
  assert_equals /explicit "$out" "CONFIG did not win"
  out=$(unset CONFIG; FM_CONFIG_OVERRIDE=/override FM_HOME=/home fm_boat_prepush_config_dir)
  assert_equals /override "$out" "FM_CONFIG_OVERRIDE did not win over FM_HOME"
  out=$(unset CONFIG FM_CONFIG_OVERRIDE; FM_HOME=/home fm_boat_prepush_config_dir)
  assert_equals /home/config "$out" "FM_HOME did not resolve to its config directory"
  pass "the config directory resolves through CONFIG, FM_CONFIG_OVERRIDE, then FM_HOME"
}

test_absent_declaration_declares_nothing
test_bare_name_takes_the_documented_defaults
test_undeclared_project_in_a_valid_file_is_not_declared
test_every_field_parses_in_any_order
test_comments_and_blank_lines_are_ignored
test_malformed_declarations_refuse_the_whole_file
test_an_unreadable_declaration_refuses
test_a_directory_in_place_of_the_declaration_refuses
test_config_dir_follows_the_home_overrides

echo "all fm-boat-prepush-lib tests passed"
