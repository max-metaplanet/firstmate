#!/usr/bin/env bash
# Tests for bin/fm-pr-ci-validated.sh: the delivery-path step that marks one
# pull request as deliberately validated by this repository's CI instead of the
# local no-mistakes pipeline, so the required check reports that state rather
# than mailing a failure.
#
# The forge is mocked, so no case reaches GitHub. What each case proves is the
# forge calls the script makes and the exit code it reports, because a silent
# failure here brings the failure mail straight back.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

MARKER_TOOL="$ROOT/bin/fm-pr-ci-validated.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-ci-validated)
BASE_PATH=$PATH
PR_URL=https://github.com/example-owner/example-repo/pull/42

assert_present "$MARKER_TOOL" "bin/fm-pr-ci-validated.sh is missing"
MARKER=$("$MARKER_TOOL" --label) || fail "the script could not report its marker label"

# One sandbox per case: a fake gh-axi that logs every call and serves a staged
# label listing. Echoes the case directory.
make_case() {  # <name> [existing-label...]
  local name=$1 case_dir fakebin
  shift
  case_dir="$TMP_ROOT/$name"
  fakebin=$(fm_fakebin "$case_dir")
  : > "$case_dir/gh-axi.log"
  : > "$case_dir/label-list-rc"
  : > "$case_dir/pr-edit-rc"
  : > "$case_dir/label-create-rc"
  {
    printf 'count: %s\n' "$#"
    printf 'labels[%s]{name}:\n' "$#"
    local existing
    for existing in "$@"; do printf '  %s\n' "$existing"; done
    printf 'help[1]:\n'
    printf '  Run gh-axi label create to create a label\n'
  } > "$case_dir/labels.txt"
  cat > "$fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_CASE_DIR/gh-axi.log"
read_rc() { local f="$FM_TEST_CASE_DIR/$1"; [ -s "$f" ] && cat "$f" || printf '0\n'; }
case "${1:-} ${2:-}" in
  "label list")
    rc=$(read_rc label-list-rc)
    [ "$rc" = 0 ] || exit "$rc"
    cat "$FM_TEST_CASE_DIR/labels.txt"
    ;;
  "label create")
    exit "$(read_rc label-create-rc)"
    ;;
  "pr edit")
    exit "$(read_rc pr-edit-rc)"
    ;;
  *)
    exit 9
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/gh-axi"
  printf '%s\n' "$case_dir"
}

# assert_call <case-dir> <extended-regex> <msg>: one logged forge call must match.
assert_call() {
  grep -E -- "$2" "$1/gh-axi.log" >/dev/null \
    || fail "$3"$'\n'"--- forge calls ---"$'\n'"$(cat "$1/gh-axi.log")"
}

run_case() {  # <case-dir> <arg...>
  local case_dir=$1
  shift
  FM_TEST_CASE_DIR="$case_dir" PATH="$case_dir/fakebin:$BASE_PATH" \
    "$MARKER_TOOL" "$@" > "$case_dir/stdout" 2> "$case_dir/stderr"
}

test_reports_the_marker_it_applies() {
  assert_equals "$MARKER" "$(FM_TEST_CASE_DIR=/nonexistent "$MARKER_TOOL" --label)" \
    "--label did not print one stable marker name"
  assert_not_equals "" "$MARKER" "--label printed no marker name"
  pass "the script reports the $MARKER marker it applies"
}

test_creates_the_label_before_adding_it() {
  local case_dir rc=0
  case_dir=$(make_case creates-label bug documentation)
  run_case "$case_dir" "$PR_URL" || rc=$?
  expect_code 0 "$rc" "marking a PR failed"$'\n'"$(cat "$case_dir/stderr")"
  assert_call "$case_dir" "^label create --name $MARKER .*--repo example-owner/example-repo\$" \
    "the missing marker label was not created on the pull request's own repository"
  assert_grep "pr edit 42 --repo example-owner/example-repo --add-label $MARKER" \
    "$case_dir/gh-axi.log" "the marker was not added to the pull request"
  assert_grep "$PR_URL" "$case_dir/stdout" "the result did not name the marked pull request"
  pass "the script creates the marker label when the repository lacks it, then applies it"
}

test_reuses_an_existing_label() {
  local case_dir rc=0
  case_dir=$(make_case reuses-label bug "$MARKER" wontfix)
  run_case "$case_dir" "$PR_URL" || rc=$?
  expect_code 0 "$rc" "marking a PR with an existing label failed"$'\n'"$(cat "$case_dir/stderr")"
  assert_no_grep "label create" "$case_dir/gh-axi.log" \
    "an existing marker label was created again"
  assert_grep "pr edit 42 --repo example-owner/example-repo --add-label $MARKER" \
    "$case_dir/gh-axi.log" "the existing marker was not added to the pull request"
  pass "the script reuses an existing marker label instead of recreating it"
}

# A label whose name merely contains the marker is a different label, and the
# workflow keys on the exact name.
test_a_near_miss_label_does_not_count_as_the_marker() {
  local case_dir rc=0
  case_dir=$(make_case near-miss-label "$MARKER-draft")
  run_case "$case_dir" "$PR_URL" || rc=$?
  expect_code 0 "$rc" "marking a PR beside a near-miss label failed"
  assert_grep "label create --name $MARKER " "$case_dir/gh-axi.log" \
    "a label that merely resembles the marker was accepted as the marker"
  pass "only the exact marker name counts as the label already existing"
}

test_refuses_a_pull_request_on_another_forge() {
  local case_dir rc=0
  case_dir=$(make_case other-forge)
  run_case "$case_dir" https://gitlab.example/group/project/-/merge_requests/7 || rc=$?
  expect_code 2 "$rc" "a GitLab merge request was not refused"
  assert_grep "GitHub" "$case_dir/stderr" "the refusal did not say the marker is a GitHub label"
  assert_equals "" "$(cat "$case_dir/gh-axi.log")" "the refused request still called the forge"
  pass "the script refuses a pull request on a forge with no such label"
}

test_refuses_a_malformed_url() {
  local case_dir rc=0 argument
  case_dir=$(make_case malformed-url)
  for argument in "" "example-owner/example-repo#42" "https://github.com/example-owner/example-repo/pull/" "42"; do
    rc=0
    run_case "$case_dir" "$argument" || rc=$?
    expect_code 2 "$rc" "'$argument' was not refused as a pull request URL"
  done
  rc=0
  run_case "$case_dir" "$PR_URL" extra || rc=$?
  expect_code 2 "$rc" "a second argument was not refused"
  assert_equals "" "$(cat "$case_dir/gh-axi.log")" "a malformed argument still called the forge"
  pass "the script refuses anything that is not one pull request URL"
}

test_a_refused_forge_write_fails_loudly() {
  local case_dir rc=0
  case_dir=$(make_case edit-refused "$MARKER")
  printf '1\n' > "$case_dir/pr-edit-rc"
  run_case "$case_dir" "$PR_URL" || rc=$?
  expect_code 1 "$rc" "a refused label write reported success"
  assert_grep "$PR_URL" "$case_dir/stderr" "the write failure did not name the pull request"

  case_dir=$(make_case create-refused)
  printf '1\n' > "$case_dir/label-create-rc"
  rc=0
  run_case "$case_dir" "$PR_URL" || rc=$?
  expect_code 1 "$rc" "a refused label creation reported success"
  assert_no_grep "pr edit" "$case_dir/gh-axi.log" \
    "the pull request was edited although the marker label could not be created"

  case_dir=$(make_case list-refused)
  printf '3\n' > "$case_dir/label-list-rc"
  rc=0
  run_case "$case_dir" "$PR_URL" || rc=$?
  expect_code 1 "$rc" "an unreadable label list reported success"
  assert_no_grep "label create" "$case_dir/gh-axi.log" \
    "a label was created although the repository's labels could not be read"
  assert_no_grep "pr edit" "$case_dir/gh-axi.log" \
    "the pull request was edited although the repository's labels could not be read"
  pass "a forge read or write the script could not complete fails loudly and stops"
}

# A PATH carrying only what the script needs before it looks for the forge
# tool: bash for the `/usr/bin/env bash` shebang, and dirname for the script's
# own directory resolution. Linking the whole PATH minus one entry also works
# but costs seconds per case, which is budget the validation agents need more
# than this test does.
test_reports_a_missing_forge_tool() {
  local case_dir minbin rc=0 tool
  case_dir=$(make_case no-gh-axi)
  minbin="$case_dir/minbin"
  mkdir -p "$minbin"
  for tool in bash dirname; do
    ln -s "$(command -v "$tool")" "$minbin/$tool" \
      || fail "could not stage $tool for the missing-forge-tool case"
  done
  FM_TEST_CASE_DIR="$case_dir" PATH="$minbin" \
    "$MARKER_TOOL" "$PR_URL" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 1 "$rc" "a missing forge tool reported success"
  assert_grep "gh-axi" "$case_dir/stderr" "the refusal did not name the missing tool"
  pass "the script reports the forge tool it needs rather than silently doing nothing"
}

# The create path must carry the marker on the create call itself, so the
# opening event already has it instead of gaining it moments later.
test_create_mode_prints_the_label_argument_without_editing_a_pr() {
  local case_dir rc=0
  case_dir=$(make_case create-mode bug)
  run_case "$case_dir" --for-create example-owner/example-repo || rc=$?
  expect_code 0 "$rc" "the create argument could not be produced"$'\n'"$(cat "$case_dir/stderr")"
  assert_equals "--label $MARKER" "$(cat "$case_dir/stdout")" \
    "the create path did not print the argument the create call must carry"
  assert_call "$case_dir" "^label create --name $MARKER .*--repo example-owner/example-repo\$" \
    "the create path did not ensure the marker label exists first"
  assert_no_grep "pr edit" "$case_dir/gh-axi.log" \
    "the create path edited a pull request that does not exist yet"

  case_dir=$(make_case create-mode-existing "$MARKER")
  rc=0
  run_case "$case_dir" --for-create example-owner/example-repo || rc=$?
  expect_code 0 "$rc" "the create argument could not be produced beside an existing label"
  assert_no_grep "label create" "$case_dir/gh-axi.log" \
    "an existing marker label was created again on the create path"
  pass "the create path ensures the label and prints the argument the create call carries"
}

test_create_mode_refuses_anything_but_one_repository() {
  local case_dir rc=0 argument
  case_dir=$(make_case create-mode-refusals)
  for argument in "" "example-owner" "https://github.com/example-owner/example-repo" "a/b/c"; do
    rc=0
    run_case "$case_dir" --for-create "$argument" || rc=$?
    expect_code 2 "$rc" "'--for-create $argument' was not refused"
  done
  rc=0
  run_case "$case_dir" --for-create example-owner/example-repo extra || rc=$?
  expect_code 2 "$rc" "a second --for-create argument was not refused"
  assert_equals "" "$(cat "$case_dir/gh-axi.log")" "a refused create argument still called the forge"
  pass "the create path refuses anything but one owner/repository"
}

test_reports_the_marker_it_applies
test_creates_the_label_before_adding_it
test_reuses_an_existing_label
test_a_near_miss_label_does_not_count_as_the_marker
test_refuses_a_pull_request_on_another_forge
test_refuses_a_malformed_url
test_a_refused_forge_write_fails_loudly
test_reports_a_missing_forge_tool
test_create_mode_prints_the_label_argument_without_editing_a_pr
test_create_mode_refuses_anything_but_one_repository
