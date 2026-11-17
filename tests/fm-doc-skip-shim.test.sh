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
axi run --help
axi run -h
axi run --version
axi run --intent x --help
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

test_an_unreadable_config_is_left_untouched() {
  local config out code=0 before
  config="$TMP_ROOT/unreadable.sh"
  # shellcheck disable=SC2016 # The fixture line is literal shell-config text.
  printf 'export PATH="$HOME/.local/bin:$PATH"\n' > "$config"
  before=$(cat "$config")
  # Writable but unreadable: the pre-flight check passes and the read fails.
  chmod 0200 "$config"
  out=$(PATH="$REAL_DIR:$PATH" "$INSTALLER" install --dir "$SHIM_DIR" \
    --shell-config "$config" 2>&1) || code=$?
  chmod 644 "$config"
  expect_code 1 "$code" 'install against an unreadable shell configuration'
  assert_contains "$out" 'left it untouched' 'the refusal did not say the file was left alone'
  assert_equals "$before" "$(cat "$config")" 'a failed read truncated the shell configuration'
  pass 'a shell configuration that cannot be read is refused, not truncated'
}

test_a_divergent_path_spelling_does_not_loop() {
  local out
  out=$(PATH="$SHIM_DIR/:$SHIM_DIR:$REAL_DIR:$PATH" timeout 20 "$SHIM_DIR/no-mistakes" axi run)
  assert_equals '[axi]
[run]
[--skip]
[document]' "$out" 'a trailing-slash PATH entry made the shim resolve itself'
  pass 'a PATH entry that spells the shim directory differently does not loop'
}

test_resolution_agrees_with_the_installer() {
  local second out reported
  second="$TMP_ROOT/real-second"
  mkdir -p "$second"
  cat > "$second/no-mistakes" <<'FAKE'
#!/bin/sh
echo SECOND
FAKE
  chmod 0755 "$second/no-mistakes"
  out=$(PATH="$REAL_DIR:$SHIM_DIR:$second:$PATH" "$SHIM_DIR/no-mistakes" axi run)
  reported=$(PATH="$REAL_DIR:$SHIM_DIR:$second:$PATH" "$INSTALLER" status \
    --dir "$SHIM_DIR" --no-shell-config | sed -n 's/^real binary: //p')
  assert_equals "$REAL_DIR/no-mistakes" "$reported" 'status named an unexpected real binary'
  assert_contains "$out" '[axi]' 'the shim did not exec the binary status names'
  pass 'the shim and the installer resolve the same real binary'
}

test_uninstall_refuses_a_file_it_did_not_generate() {
  local foreign out code=0
  foreign="$TMP_ROOT/not-a-shim"
  mkdir -p "$foreign"
  printf '#!/bin/sh\necho real\n' > "$foreign/no-mistakes"
  chmod 0755 "$foreign/no-mistakes"
  out=$("$INSTALLER" uninstall --dir "$foreign" --no-shell-config 2>&1) || code=$?
  expect_code 1 "$code" 'uninstall against a directory holding a foreign binary'
  assert_contains "$out" 'left it alone' 'the refusal did not say the file was kept'
  assert_present "$foreign/no-mistakes" 'uninstall deleted a binary it did not generate'
  pass 'uninstall only removes a shim it generated'
}

test_install_validates_every_config_before_writing() {
  local good out code=0 before
  good="$TMP_ROOT/good-config.sh"
  # shellcheck disable=SC2016 # The fixture line is literal shell-config text.
  printf 'export PATH="$HOME/.local/bin:$PATH"\n' > "$good"
  before=$(cat "$good")
  out=$(PATH="$REAL_DIR:$PATH" "$INSTALLER" install --dir "$TMP_ROOT/fresh-shim" \
    --shell-config "$good" --shell-config "$TMP_ROOT/absent-config.sh" 2>&1) || code=$?
  expect_code 1 "$code" 'install naming a missing shell configuration'
  assert_contains "$out" 'nothing was installed' 'the refusal did not say nothing was installed'
  assert_equals "$before" "$(cat "$good")" 'a refused install still edited the first file'
  assert_absent "$TMP_ROOT/fresh-shim/no-mistakes" 'a refused install still wrote the shim'
  pass 'install writes nothing when any named shell configuration is unusable'
}

test_a_line_merely_mentioning_the_marker_survives() {
  local config
  config="$TMP_ROOT/mentions.sh"
  printf '%s\n' '# see fm-doc-skip-shim.sh: the # firstmate doc-skip shim is temporary' > "$config"
  PATH="$REAL_DIR:$PATH" "$INSTALLER" install --dir "$SHIM_DIR" --shell-config "$config" >/dev/null
  PATH="$REAL_DIR:$PATH" "$INSTALLER" uninstall --dir "$SHIM_DIR" --shell-config "$config" >/dev/null
  assert_grep 'the # firstmate doc-skip shim is temporary' "$config" \
    'a comment mentioning the marker was deleted'
  pass 'a line that only mentions the marker is not treated as ours'
}

test_a_symlinked_config_stays_a_symlink() {
  local target link
  target="$TMP_ROOT/real-config.sh"
  link="$TMP_ROOT/linked-config.sh"
  # shellcheck disable=SC2016 # The fixture line is literal shell-config text.
  printf 'export PATH="$HOME/.local/bin:$PATH"\n' > "$target"
  ln -sf "$target" "$link"
  PATH="$REAL_DIR:$PATH" "$INSTALLER" install --dir "$SHIM_DIR" --shell-config "$link" >/dev/null
  [ -L "$link" ] || fail 'install replaced the symlinked shell configuration with a file'
  assert_grep 'firstmate doc-skip shim' "$target" 'install did not write through the symlink'
  pass 'a symlinked shell configuration keeps its link'
}

test_the_config_keeps_its_permissions() {
  local config
  config="$TMP_ROOT/moded-config.sh"
  # shellcheck disable=SC2016 # The fixture line is literal shell-config text.
  printf 'export PATH="$HOME/.local/bin:$PATH"\n' > "$config"
  chmod 0644 "$config"
  PATH="$REAL_DIR:$PATH" "$INSTALLER" install --dir "$SHIM_DIR" --shell-config "$config" >/dev/null
  # shellcheck disable=SC2012 # `stat` spells its format differently on BSD and GNU.
  assert_equals 'rw-r--r--' "$(ls -ld "$config" | cut -c2-10)" \
    'install changed the shell configuration permissions'
  pass 'the shell configuration keeps its permissions across a rewrite'
}

test_the_fallback_binary_covers_an_empty_path() {
  local out
  out=$(PATH="$SHIM_DIR" "$SHIM_DIR/no-mistakes" axi run 2>&1)
  assert_equals '[axi]
[run]
[--skip]
[document]' "$out" 'the recorded fallback binary was not used when PATH held only the shim'
  pass 'the install-time binary is used when PATH resolves nothing else'
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
test_an_unreadable_config_is_left_untouched
test_a_divergent_path_spelling_does_not_loop
test_resolution_agrees_with_the_installer
test_uninstall_refuses_a_file_it_did_not_generate
test_install_validates_every_config_before_writing
test_a_line_merely_mentioning_the_marker_survives
test_a_symlinked_config_stays_a_symlink
test_the_config_keeps_its_permissions
test_the_fallback_binary_covers_an_empty_path
