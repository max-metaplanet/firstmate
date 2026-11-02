#!/usr/bin/env bash
# Behavior tests for bin/fm-memcap.sh, the owner of "run one command under a
# hard memory cap": which mechanism a host offers, the per-process budget and
# its share division, exit-status passthrough, and the sentinel line a cap kill
# prints for bin/fm-lint.sh to classify.
# The cap-kill case is the only one that allocates; it runs a perl hog with its
# own 512 MiB ceiling under an explicit 128 MiB cap, so a cap that fails to
# apply ends the allocation itself rather than the machine.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

MEMCAP="$ROOT/bin/fm-memcap.sh"
HOG_CEILING_MIB=512
KILL_CAP_BYTES=134217728

test_mechanism_names_one_supported_bound() {
  local mech
  mech=$("$MEMCAP" --mechanism) || fail "--mechanism failed"
  case "$mech" in
    cgroup|rlimit|none) : ;;
    *) fail "--mechanism named something other than a supported bound: $mech" ;;
  esac
  pass "--mechanism names exactly one of cgroup, rlimit, or none"
}

test_budget_is_a_positive_byte_count_split_across_shares() {
  local one two ratio
  one=$("$MEMCAP" --budget-bytes) || fail "--budget-bytes failed"
  case "$one" in ''|0*|*[!0-9]*) fail "the default budget is not a positive byte count: $one" ;; esac
  two=$("$MEMCAP" --budget-bytes --share 2) || fail "--budget-bytes --share 2 failed"
  case "$two" in ''|0*|*[!0-9]*) fail "the two-share budget is not a positive byte count: $two" ;; esac
  if [ "$one" -eq 268435456 ]; then
    pass "SKIP (this host's budget sits on its 256 MiB floor): share division check"
    return
  fi
  [ "$two" -lt "$one" ] || fail "two shares did not divide the budget: $two vs $one"
  # Permille of the halved figure against the whole, so a share that divides the
  # wrong quantity fails rather than passing on a loose "smaller" check.
  ratio=$((two * 1000 / one))
  [ "$ratio" -ge 495 ] && [ "$ratio" -le 505 ] \
    || fail "two shares were not about half the single-share budget: $two vs $one"
  pass "--budget-bytes reports a positive cap that --share divides"
}

test_linux_budget_uses_the_readable_memory_total() {
  local key value _unit total='' expected out share
  if [ ! -r /proc/meminfo ]; then
    pass "SKIP (/proc/meminfo is unavailable): Linux memory budget check"
    return
  fi
  while read -r key value _unit; do
    if [ "$key" = MemTotal: ]; then
      total=$((value * 1024))
      break
    fi
  done < /proc/meminfo
  [ -n "$total" ] || fail "readable /proc/meminfo has no MemTotal"
  for share in 1 2; do
    expected=$((total * 45 / 100 / share))
    [ "$expected" -ge 268435456 ] || expected=268435456
    out=$("$MEMCAP" --budget-bytes --share "$share") \
      || fail "Linux memory budget failed for share $share"
    [ "$out" = "$expected" ] \
      || fail "Linux budget for share $share was $out, expected $expected from MemTotal"
  done
  pass "Linux budgets use 45 percent of readable MemTotal divided across shares"
}

test_malformed_input_is_refused_rather_than_guessed() {
  local out rc
  for bad in 0 -1 two 1.5 ''; do
    rc=0
    out=$("$MEMCAP" --budget-bytes --share "$bad" 2>&1) || rc=$?
    [ "$rc" -eq 2 ] || fail "--share '$bad' exited $rc, expected 2"
    assert_contains "$out" "--share must be a positive integer" \
      "--share '$bad' was refused without naming the requirement"
  done
  rc=0
  out=$("$MEMCAP" --bytes 0 -- true 2>&1) || rc=$?
  [ "$rc" -eq 2 ] || fail "--bytes 0 exited $rc, expected 2"
  rc=0
  out=$("$MEMCAP" --mechanism -- true 2>&1) || rc=$?
  [ "$rc" -eq 2 ] || fail "--mechanism with a command exited $rc, expected 2"
  rc=0
  out=$("$MEMCAP" -- 2>&1) || rc=$?
  [ "$rc" -eq 2 ] || fail "a missing command exited $rc, expected 2"
  pass "a non-positive share, a zero cap, and a missing command each exit 2 by name"
}

test_a_capped_command_keeps_its_own_streams_and_status() {
  local out rc diagnostics expected
  out=$("$MEMCAP" -- /bin/sh -c 'printf to-stdout' 2>/dev/null) \
    || fail "a clean capped command did not exit 0"
  [ "$out" = to-stdout ] || fail "the capped command's stdout did not reach the caller: $out"
  diagnostics=$("$MEMCAP" -- /bin/sh -c ':' 2>&1 >/dev/null) \
    || fail "a silent command did not exit 0"
  expected="${diagnostics}${diagnostics:+$'\n'}to-stderr"
  out=$("$MEMCAP" -- /bin/sh -c 'printf to-stderr >&2' 2>&1 >/dev/null) \
    || fail "the stderr-writing command did not exit 0"
  [ "$out" = "$expected" ] || fail "the command's stderr changed after wrapper diagnostics: $out"
  out=$(printf 'piped\n' | "$MEMCAP" -- cat) || fail "a capped command lost the caller's stdin"
  [ "$out" = piped ] || fail "the capped command's stdin did not reach it: $out"
  rc=0
  "$MEMCAP" -- /bin/sh -c 'exit 7' || rc=$?
  [ "$rc" -eq 7 ] || fail "a capped command's nonzero status was not passed through: $rc"
  pass "a capped command keeps its stdin, stdout, stderr, and exit status"
}

# shellcheck disable=SC2016
test_command_arguments_are_preserved() {
  local mode out expected
  local -a options
  expected=$(printf '<%s>\n' '' 'two words' '${FM_MEMCAP_ARGV_UNSET}' '$HOME' '*' 'a"b')
  for mode in reporting exec; do
    options=()
    [ "$mode" != exec ] || options=(--exec)
    out=$(unset FM_MEMCAP_ARGV_UNSET; "$MEMCAP" "${options[@]}" -- \
      /bin/sh -c 'printf "<%s>\n" "$@"' argv '' 'two words' '${FM_MEMCAP_ARGV_UNSET}' '$HOME' '*' 'a"b') \
      || fail "$mode argument-preservation command failed"
    assert_equals "$expected" "$out" "$mode must preserve literal arguments and their boundaries"
    out=$(unset v; "$MEMCAP" "${options[@]}" -- /bin/sh -c 'v=inner; printf "%s" "${v}"') \
      || fail "$mode shell-program command failed"
    assert_equals inner "$out" "$mode must leave variable expansion to the command"
  done
  pass "reporting and exec modes preserve literal arguments and shell programs"
}

test_unsupported_expansion_flag_disables_cgroup() {
  local tmp fakebin out
  tmp=$(fm_test_tmproot fm-memcap-old-systemd)
  fakebin=$(fm_fakebin "$tmp")
  cat > "$fakebin/systemd-run" <<'SH'
#!/bin/sh
for arg do
  case "$arg" in --expand-environment=*) exit 1 ;; esac
done
exit 0
SH
  chmod +x "$fakebin/systemd-run"
  out=$(PATH="$fakebin:$PATH" "$MEMCAP" --mechanism) || fail "old-systemd mechanism probe failed"
  [ "$out" != cgroup ] || fail "systemd without expansion control was selected"
  out=$(PATH="$fakebin:$PATH" "$MEMCAP" -- /bin/sh -c 'printf fallback') \
    || fail "old-systemd fallback command failed"
  assert_equals fallback "$out" "an unsupported cgroup launcher must not consume the command"
  pass "systemd without expansion control is unavailable and fallback still executes"
}

test_uncapped_warnings_name_the_bounded_route() {
  local tmp fakebin mode expected out rc
  tmp=$(fm_test_tmproot fm-memcap-warnings)
  fakebin=$(fm_fakebin "$tmp")
  printf '#!/bin/sh\nexit 1\n' > "$fakebin/systemd-run"
  chmod +x "$fakebin/systemd-run"
  for mode in none refused; do
    if [ "$mode" = none ]; then
      printf 'ulimit() { return 1; }\n' > "$tmp/env"
      expected='fm-memcap: this host offers no memory-cap mechanism (no usable systemd user scope, no address-space limit); running sh uncapped; use bin/fm-boat-run.sh to run it bounded'
    else
      cat > "$tmp/env" <<'SH'
ulimit() {
  case "$*" in
    '-Hv') printf 'unlimited\n' ;;
    '-v 1048576') return 0 ;;
    *) return 1 ;;
  esac
}
SH
      expected='fm-memcap: this host refused a 67108864-byte address-space limit; running sh uncapped; use bin/fm-boat-run.sh to run it bounded'
    fi
    rc=0
    out=$(BASH_ENV="$tmp/env" PATH="$fakebin:$PATH" "$MEMCAP" --bytes 67108864 -- \
      /bin/sh -c 'printf command-ran; exit 7' 2>"$tmp/stderr") || rc=$?
    [ "$rc" -eq 7 ] || fail "$mode compatibility changed the command status: $rc"
    assert_equals command-ran "$out" "$mode compatibility must execute the command"
    assert_equals "$expected" "$(cat "$tmp/stderr")" "$mode warning must name the bounded Boat route"
  done
  pass "uncapped compatibility preserves execution and points to the bounded Boat route"
}

test_a_runaway_dies_at_its_cap_and_is_named() {
  local mech out rc
  mech=$("$MEMCAP" --mechanism)
  if [ "$mech" = none ]; then
    pass "SKIP (this host offers no memory-cap mechanism): runaway cap-kill check"
    return
  fi
  if ! command -v perl >/dev/null 2>&1; then
    pass "SKIP (perl is not installed): runaway cap-kill check"
    return
  fi
  rc=0
  # shellcheck disable=SC2016 # perl expands $ARGV[0], not the shell.
  out=$("$MEMCAP" --bytes "$KILL_CAP_BYTES" -- \
    perl -e 'my @held; for (1 .. $ARGV[0]) { push @held, "x" x 1048576 }' "$HOG_CEILING_MIB" 2>&1) || rc=$?
  if [ "$mech" = cgroup ]; then
    [ "$rc" -eq 137 ] || fail "a runaway under a ${KILL_CAP_BYTES}-byte cap exited $rc, expected 137"$'\n'"$out"
    assert_contains "$out" "fm-memcap: perl was killed by its $KILL_CAP_BYTES-byte memory cap" \
      "the cap kill did not print the sentinel bin/fm-lint.sh classifies"
    pass "a runaway dies at its cap and names itself on stderr with status 137"
  else
    [ "$rc" -ne 0 ] || fail "a runaway completed allocation despite its address-space cap"
    pass "a runaway cannot complete allocation under its address-space cap"
  fi
}

test_mechanism_names_one_supported_bound
test_budget_is_a_positive_byte_count_split_across_shares
test_linux_budget_uses_the_readable_memory_total
test_malformed_input_is_refused_rather_than_guessed
test_a_capped_command_keeps_its_own_streams_and_status
test_command_arguments_are_preserved
test_unsupported_expansion_flag_disables_cgroup
test_uncapped_warnings_name_the_bounded_route
test_a_runaway_dies_at_its_cap_and_is_named
