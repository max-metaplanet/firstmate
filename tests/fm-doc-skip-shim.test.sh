#!/usr/bin/env bash
# Behavioral regressions for the temporary no-mistakes document-skip PATH shim.
# Every case drives the installed shim as an executable and asserts on the
# argument vector a stand-in real binary received, never on the shim's source.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

INSTALLER="$ROOT/bin/fm-doc-skip-shim.sh"
TMP_ROOT=$(fm_test_tmproot fm-doc-skip-shim)

REAL_DIR="$TMP_ROOT/real"
SHIM_DIR="$TMP_ROOT/shim"

setup_world() {
  mkdir -p "$REAL_DIR" "$SHIM_DIR"
  cat > "$REAL_DIR/no-mistakes" <<'FAKE'
#!/bin/sh
for arg in "$@"; do
  printf '[%s]\n' "$arg"
done
FAKE
  chmod 0755 "$REAL_DIR/no-mistakes"
  PATH="$REAL_DIR:$PATH" "$INSTALLER" install --dir "$SHIM_DIR" --no-shell-config >/dev/null
  [ -x "$SHIM_DIR/no-mistakes" ] || fail 'install did not produce an executable shim'
}

# run_shim <args...>: the received argument vector, one [arg] per line.
run_shim() {
  PATH="$SHIM_DIR:$REAL_DIR:$PATH" "$SHIM_DIR/no-mistakes" "$@"
}

test_adds_the_step_to_run_starting_commands() {
  local out
  out=$(run_shim axi run --intent 'ship it')
  assert_equals '[axi]
[run]
[--intent]
[ship it]
[--skip]
[document]' "$out" 'axi run without a skip did not gain --skip document'

  out=$(run_shim)
  assert_equals '[--skip]
[document]' "$out" 'a bare invocation did not gain --skip document'

  out=$(run_shim -y)
  assert_equals '[-y]
[--skip]
[document]' "$out" 'a bare invocation with -y did not gain --skip document'
  pass 'run-starting commands receive --skip document'
}

test_merges_with_a_caller_supplied_skip() {
  local out
  out=$(run_shim axi run --skip push,pr,ci)
  assert_equals '[axi]
[run]
[--skip]
[push,pr,ci,document]' "$out" "the caller's skip list was not unioned with document"

  out=$(run_shim axi run --skip=test --base-branch release)
  assert_equals '[axi]
[run]
[--skip=test,document]
[--base-branch]
[release]' "$out" 'the --skip=value form was not unioned with document'
  pass 'a caller-supplied skip list is unioned, never replaced'
}

test_is_idempotent_when_document_is_already_skipped() {
  local out
  out=$(run_shim axi run --skip document)
  assert_equals '[axi]
[run]
[--skip]
[document]' "$out" 'document was added twice to an existing skip list'

  out=$(run_shim axi run --skip 'push, document , ci')
  assert_equals '[axi]
[run]
[--skip]
[push, document , ci]' "$out" 'a spaced skip list containing document was rewritten'
  pass 'a skip list that already names document is forwarded unchanged'
}

test_preserves_every_other_argument_exactly() {
  local out
  out=$(run_shim axi run --intent 'a  b
c' --skip lint --closes 'owner/repo#42')
  assert_equals '[axi]
[run]
[--intent]
[a  b
c]
[--skip]
[lint,document]
[--closes]
[owner/repo#42]' "$out" 'surrounding arguments were reordered or reshaped'
  pass 'surrounding arguments keep their exact bytes and order'
}

test_forwards_unrecognized_invocations_untouched() {
  local out invocation
  while IFS= read -r invocation; do
    [ -n "$invocation" ] || continue
    # shellcheck disable=SC2086 # The fixture list is deliberately word-split.
    out=$(run_shim $invocation)
    # shellcheck disable=SC2086
    assert_not_contains "$out" '[--skip]' "'$invocation' was rewritten with a skip flag"
    # shellcheck disable=SC2086
    assert_not_contains "$out" '[document]' "'$invocation' gained a document argument"
  done <<'CASES'
--help
--version
axi status
axi respond --approve
daemon status
rerun
status
attach --run abc123
init
axi run --
CASES
  pass 'commands that do not start a run reach the real binary untouched'
}

test_bypass_env_forwards_untouched() {
  local out
  out=$(FM_DOC_SKIP_SHIM_BYPASS=1 PATH="$SHIM_DIR:$REAL_DIR:$PATH" "$SHIM_DIR/no-mistakes" axi run)
  assert_equals '[axi]
[run]' "$out" 'the bypass escape hatch still rewrote the arguments'
  pass 'the bypass environment variable forwards every call untouched'
}

test_install_refuses_a_directory_another_tool_owns() {
  local foreign out code=0
  foreign="$TMP_ROOT/foreign"
  mkdir -p "$foreign"
  : > "$foreign/some-other-tool"
  out=$(PATH="$REAL_DIR:$PATH" "$INSTALLER" install --dir "$foreign" --no-shell-config 2>&1) || code=$?
  expect_code 1 "$code" 'install into a populated directory'
  assert_contains "$out" 'another tool may own it' 'the refusal did not name the reason'
  assert_absent "$foreign/no-mistakes" 'install wrote a shim into a populated directory'
  pass 'install refuses a directory that holds anything else'
}

test_shell_config_line_is_idempotent_and_removable() {
  local config profile
  config="$TMP_ROOT/common.sh"
  profile="$TMP_ROOT/profile"
  # shellcheck disable=SC2016 # The fixture line is literal shell-config text.
  printf 'export PATH="$HOME/.local/bin:$PATH"\n' > "$config"
  # shellcheck disable=SC2016 # The fixture line is literal shell-config text.
  printf 'export PATH="$HOME/.local/bin:$PATH"\n' > "$profile"
  PATH="$REAL_DIR:$PATH" "$INSTALLER" install --dir "$SHIM_DIR" \
    --shell-config "$config" --shell-config "$profile" >/dev/null
  PATH="$REAL_DIR:$PATH" "$INSTALLER" install --dir "$SHIM_DIR" \
    --shell-config "$config" --shell-config "$profile" >/dev/null
  assert_equals '1' "$(grep -c -F -- 'firstmate doc-skip shim' "$profile")" \
    'a second install duplicated the PATH entry in the login profile'
  assert_equals '1' "$(grep -c -F -- 'firstmate doc-skip shim' "$config")" \
    'a second install duplicated the PATH entry'
  # shellcheck disable=SC2016 # The fixture line is literal shell-config text.
  assert_grep 'export PATH="$HOME/.local/bin:$PATH"' "$config" \
    'install clobbered an unrelated line of the shell configuration'
  assert_equals "$(tail -n 1 "$config")" \
    "$(grep -F -- 'firstmate doc-skip shim' "$config")" \
    'the shim PATH entry is not the last PATH assignment in the file'

  PATH="$REAL_DIR:$PATH" "$INSTALLER" uninstall --dir "$SHIM_DIR" \
    --shell-config "$config" --shell-config "$profile" >/dev/null
  assert_no_grep 'firstmate doc-skip shim' "$config" 'uninstall left the PATH entry behind'
  assert_no_grep 'firstmate doc-skip shim' "$profile" \
    'uninstall left the PATH entry behind in the login profile'
  # shellcheck disable=SC2016 # The fixture line is literal shell-config text.
  assert_grep 'export PATH="$HOME/.local/bin:$PATH"' "$config" \
    'uninstall removed an unrelated line of the shell configuration'
  assert_absent "$SHIM_DIR/no-mistakes" 'uninstall left the shim executable behind'
  pass 'the shell configuration entry installs once and uninstalls cleanly'
}

setup_world
test_adds_the_step_to_run_starting_commands
test_merges_with_a_caller_supplied_skip
test_is_idempotent_when_document_is_already_skipped
test_preserves_every_other_argument_exactly
test_forwards_unrecognized_invocations_untouched
test_bypass_env_forwards_untouched
test_install_refuses_a_directory_another_tool_owns
test_shell_config_line_is_idempotent_and_removable
