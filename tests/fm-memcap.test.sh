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

test_explicit_total_overrides_the_machine_budget() {
  local out
  out=$(FM_MEMCAP_BYTES=4294967296 "$MEMCAP" --budget-bytes) \
    || fail "FM_MEMCAP_BYTES did not produce a budget"
  [ "$out" = 4294967296 ] || fail "FM_MEMCAP_BYTES did not override the machine budget: $out"
  out=$(FM_MEMCAP_BYTES=4294967296 "$MEMCAP" --budget-bytes --share 4) \
    || fail "FM_MEMCAP_BYTES with a share did not produce a budget"
  [ "$out" = 1073741824 ] || fail "FM_MEMCAP_BYTES was not divided by the share: $out"
  out=$(FM_MEMCAP_BYTES=1000 "$MEMCAP" --budget-bytes) \
    || fail "a tiny FM_MEMCAP_BYTES did not produce a budget"
  [ "$out" = 268435456 ] || fail "the budget fell below its 256 MiB floor: $out"
  pass "FM_MEMCAP_BYTES replaces the machine budget, still divides, and stays above the floor"
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
  local out rc
  out=$("$MEMCAP" -- /bin/sh -c 'printf to-stdout' 2>/dev/null) \
    || fail "a clean capped command did not exit 0"
  [ "$out" = to-stdout ] || fail "the capped command's stdout did not reach the caller: $out"
  out=$("$MEMCAP" -- /bin/sh -c 'printf to-stderr >&2' 2>&1 >/dev/null)
  [ "$out" = to-stderr ] || fail "the capped command's stderr did not reach the caller: $out"
  out=$(printf 'piped\n' | "$MEMCAP" -- cat) || fail "a capped command lost the caller's stdin"
  [ "$out" = piped ] || fail "the capped command's stdin did not reach it: $out"
  rc=0
  "$MEMCAP" -- /bin/sh -c 'exit 7' || rc=$?
  [ "$rc" -eq 7 ] || fail "a capped command's nonzero status was not passed through: $rc"
  pass "a capped command keeps its stdin, stdout, stderr, and exit status"
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
  [ "$rc" -eq 137 ] || fail "a runaway under a ${KILL_CAP_BYTES}-byte cap exited $rc, expected 137"$'\n'"$out"
  assert_contains "$out" "fm-memcap: perl was killed by its $KILL_CAP_BYTES-byte memory cap" \
    "the cap kill did not print the sentinel bin/fm-lint.sh classifies"
  pass "a runaway dies at its cap and names itself on stderr with status 137"
}

test_mechanism_names_one_supported_bound
test_budget_is_a_positive_byte_count_split_across_shares
test_explicit_total_overrides_the_machine_budget
test_malformed_input_is_refused_rather_than_guessed
test_a_capped_command_keeps_its_own_streams_and_status
test_a_runaway_dies_at_its_cap_and_is_named
