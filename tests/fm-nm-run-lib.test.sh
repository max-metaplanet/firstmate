#!/usr/bin/env bash
# Behavior tests for bin/fm-nm-run-lib.sh's bounded no-mistakes probe: the
# child runs with lazy promisor fetching and background update checks disabled, a probe that
# hits its bound leaves no descendant behind, and the library's own commit
# lookup answers "absent" instead of fetching. Each probe case runs on every
# bound mechanism bin/fm-timeout-lib.sh can select on this host, because the
# bound is what has to remove the process group and each mechanism does it
# differently.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-nm-run-lib)
WT="$TMP_ROOT/worktree"
mkdir -p "$WT"

# A PATH with no timeout variant on it, so the perl watchdog every stock macOS
# core worktree falls to is exercised even on a host that has GNU timeout.
NO_TIMEOUT_PATH=$(fm_test_base_path_sans "$PATH" timeout gtimeout)

# "<label>|<PATH>|<FM_TIMEOUT_MECHANISM_OVERRIDE>" rows.
mechanisms() {
  printf 'host|%s|\n' "$PATH"
  if command -v perl >/dev/null 2>&1; then
    printf 'perl|%s|\n' "$NO_TIMEOUT_PATH"
  fi
  printf 'bash|%s|bash\n' "$PATH"
}

# run_probe <PATH> <override> <stub-dir> <timeout-secs> <args...>: one real
# fm_nm_run_bounded call, exactly as bin/fm-crew-state.sh and bin/fm-teardown.sh
# make it, with <stub-dir> supplying the no-mistakes the probe resolves.
run_probe() {
  local path=$1 override=$2 stub=$3
  shift 3
  (
    # shellcheck source=bin/fm-nm-run-lib.sh
    . "$ROOT/bin/fm-nm-run-lib.sh"
    PATH="$stub:$path" FM_TIMEOUT_MECHANISM_OVERRIDE="$override" "${NM_PROBE_WRAPPER:-fm_nm_run_bounded}" "$WT" "$@"
  )
}

test_a_probe_runs_no_mistakes_with_lazy_fetching_disabled() {
  local label path override stub out rc record
  while IFS='|' read -r label path override; do
    stub="$TMP_ROOT/env-stub-$label"
    mkdir -p "$stub"
    record="$stub/record"
    cat > "$stub/no-mistakes" <<'STUB'
#!/usr/bin/env bash
{
  printf 'lazy=%s\n' "${GIT_NO_LAZY_FETCH-unset}"
  printf 'pwd=%s\n' "$PWD"
  printf 'args=%s\n' "$*"
} > "$NM_STUB_RECORD"
printf 'run: r1\n'
STUB
    chmod +x "$stub/no-mistakes"
    rc=0
    out=$(NM_STUB_RECORD="$record" run_probe "$path" "$override" "$stub" 10 axi status) || rc=$?
    [ "$rc" -eq 0 ] || fail "$label: the probe did not pass the command's own status through (rc=$rc)"
    assert_contains "$out" "run: r1" "$label: the probe lost the command's stdout"
    assert_grep 'lazy=1' "$record" "$label: the no-mistakes probe ran without GIT_NO_LAZY_FETCH=1, so a run commit this copy lacks would still cost a promisor fetch"
    assert_grep "pwd=$WT" "$record" "$label: the probe did not run in the worktree it was given"
    assert_grep 'args=axi status' "$record" "$label: the probe lost its own arguments"
  done < <(mechanisms)
  # Read the exported environment rather than the shell variable: what must
  # not leak is what a later child would inherit, and nothing here exports it.
  ! env | grep -q '^GIT_NO_LAZY_FETCH=' ||
    fail 'the probe leaked GIT_NO_LAZY_FETCH into the calling environment instead of setting it for the child alone'
  pass 'a no-mistakes probe runs in its worktree with lazy fetching disabled for that child alone'
}

test_probe_wrappers_suppress_update_checks_without_extra_launches() {
  local label path override stub wrapper record out rc count
  stub="$TMP_ROOT/update-check-stub"
  mkdir -p "$stub"
  record="$stub/calls"
  cat > "$stub/no-mistakes" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "${NO_MISTAKES_NO_UPDATE_CHECK-unset}" >> "$NM_STUB_RECORD"
printf 'run: r1\n'
exit 17
STUB
  chmod +x "$stub/no-mistakes"
  while IFS='|' read -r label path override; do
    for wrapper in fm_nm_run_bounded fm_nm_run_checked fm_nm_run; do
      : > "$record"
      rc=0
      out=$(NO_MISTAKES_NO_UPDATE_CHECK=0 NM_PROBE_WRAPPER="$wrapper" NM_STUB_RECORD="$record" \
        run_probe "$path" "$override" "$stub" 10 axi status) || rc=$?
      if [ "$wrapper" = fm_nm_run ]; then
        assert_equals 0 "$rc" "$label/$wrapper must preserve its fail-open status"
      else
        assert_equals 17 "$rc" "$label/$wrapper must preserve the probe failure"
      fi
      assert_equals 'run: r1' "$out" "$label/$wrapper lost stdout"
      count=$(wc -l < "$record" | tr -d ' ')
      assert_equals 1 "$count" "$label/$wrapper exceeded its one-command probe budget"
      assert_equals 1 "$(cat "$record")" "$label/$wrapper allowed a background update check"
    done
  done < <(mechanisms)
  # Keep this caller-environment assertion isolated from other test cases.
  # shellcheck disable=SC2030,SC2031
  (
    export NO_MISTAKES_NO_UPDATE_CHECK=0
    NM_STUB_RECORD="$record" run_probe "$PATH" '' "$stub" 10 axi status >/dev/null || true
    assert_equals 0 "$NO_MISTAKES_NO_UPDATE_CHECK" 'the probe changed its caller environment'
  )
  pass 'all probe wrappers launch once with update checks disabled, preserving output, status, and caller environment'
}

# Callers such as the run-inventory reader and bin/fm-pipeline-spend.sh feed
# their program on stdin through fm_nm_bounded, and every mechanism starts the
# bounded command asynchronously, where bash would otherwise hand it /dev/null.
# The fake-timeout row stands in for GNU/BSD timeout on a host without one.
test_a_bounded_command_reads_its_callers_stdin() {
  local label path override shim out
  shim="$TMP_ROOT/fake-timeout"
  mkdir -p "$shim"
  cat > "$shim/timeout" <<'STUB'
#!/usr/bin/env bash
shift 3
exec "$@"
STUB
  chmod +x "$shim/timeout"
  while IFS='|' read -r label path override; do
    out=$(
      # shellcheck source=bin/fm-nm-run-lib.sh
      . "$ROOT/bin/fm-nm-run-lib.sh"
      PATH="$path" FM_TIMEOUT_MECHANISM_OVERRIDE="$override" \
        fm_nm_bounded "$WT" 10 bash -s first second <<'SH'
printf 'heredoc %s %s\n' "$1" "$2"
SH
    )
    assert_equals "heredoc first second" "$out" "$label: the bounded command did not receive the caller's heredoc on stdin"
  done < <(mechanisms; printf 'fake-timeout|%s|\n' "$shim:$NO_TIMEOUT_PATH")
  pass "a bounded command reads its caller's stdin on every mechanism"
}

test_a_probe_that_hits_its_bound_leaves_no_descendant_behind() {
  local label path override stub rc self_pid child_pid before after
  while IFS='|' read -r label path override; do
    stub="$TMP_ROOT/bound-stub-$label"
    mkdir -p "$stub"
    # Both halves ignore TERM, so only a bound that escalates to KILL across
    # the whole group ends them: TERM alone is what left a no-mistakes probe
    # reparented to init and still working. The descendant appends to a file
    # so the test can see whether it is still going afterwards. Both give up
    # after about 30 seconds, so a broken bound cannot leak them.
    cat > "$stub/no-mistakes" <<'STUB'
#!/usr/bin/env bash
trap '' TERM
bash -c 'trap "" TERM; i=0; while [ "$i" -lt 300 ]; do printf x >> "$1"; sleep 0.1; i=$((i + 1)); done' _ "$NM_STUB_HEARTBEAT" &
printf '%s\n' "$!" > "$NM_STUB_CHILD_PID"
printf '%s\n' "$$" > "$NM_STUB_SELF_PID"
i=0
while [ "$i" -lt 300 ]; do sleep 0.1; i=$((i + 1)); done
STUB
    chmod +x "$stub/no-mistakes"
    : > "$stub/heartbeat"
    rc=0
    NM_STUB_HEARTBEAT="$stub/heartbeat" NM_STUB_CHILD_PID="$stub/child.pid" NM_STUB_SELF_PID="$stub/self.pid" \
      run_probe "$path" "$override" "$stub" 1 axi status >/dev/null 2>&1 || rc=$?
    [ "$rc" -eq 124 ] || fail "$label: a probe that outran its bound did not report the bound (rc=$rc)"
    sleep 1
    [ -s "$stub/heartbeat" ] || fail "$label: the descendant never ran, so this case proves nothing"
    self_pid=$(cat "$stub/self.pid")
    child_pid=$(cat "$stub/child.pid")
    ! kill -0 "$self_pid" 2>/dev/null || fail "$label: the no-mistakes probe outlived its bound (pid $self_pid)"
    ! kill -0 "$child_pid" 2>/dev/null || fail "$label: the probe's descendant outlived the bound (pid $child_pid)"
    before=$(wc -c < "$stub/heartbeat")
    sleep 1
    after=$(wc -c < "$stub/heartbeat")
    assert_equals "$before" "$after" "$label: the probe's descendant was still working a second after the bound removed its group"
  done < <(mechanisms)
  pass 'a probe that hits its bound takes its whole process group with it'
}

# The library's own commit lookup is the second place a supervision pass can
# make a partial clone fetch: the run head it is asked about is routinely a
# commit the pipeline made in its own copy.
test_resolving_a_missing_commit_answers_absent_without_fetching() {
  local dir origin absent_sha guarded unguarded
  dir="$TMP_ROOT/promisor"
  origin="$dir/origin"
  fm_git_init_commit "$origin"
  git -C "$origin" config uploadpack.allowFilter true
  git -C "$origin" config uploadpack.allowAnySHA1InWant true
  git -C "$origin" checkout -q -b elsewhere
  printf 'later\n' > "$origin/later.txt"
  git -C "$origin" add later.txt
  git -C "$origin" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm later
  absent_sha=$(git -C "$origin" rev-parse HEAD)
  git -C "$origin" checkout -q main

  git clone -q --filter=blob:none --single-branch --branch main "file://$origin" "$dir/guarded"
  git clone -q --filter=blob:none --single-branch --branch main "file://$origin" "$dir/unguarded"

  # Non-vacuity: the same lookup without the guard reaches the promisor and
  # resolves, which is the fetch this clone must not pay for on every pass.
  unguarded=$(git -C "$dir/unguarded" rev-parse --verify --quiet "$absent_sha^{commit}" 2>/dev/null || true)
  [ "$unguarded" = "$absent_sha" ] ||
    fail "the fixture is not a promisor clone that would have fetched the missing commit (got '$unguarded')"

  guarded=$( . "$ROOT/bin/fm-nm-run-lib.sh"; fm_nm_resolve_commit "$dir/guarded" "$absent_sha" )
  [ -z "$guarded" ] ||
    fail "fm_nm_resolve_commit fetched a run commit this copy does not hold instead of answering absent (got '$guarded')"
  pass 'fm_nm_resolve_commit answers absent for a commit only the promisor holds, without fetching it'
}

test_interrupted_monitor_is_terminal() {
  # shellcheck source=bin/fm-nm-run-lib.sh
  . "$ROOT/bin/fm-nm-run-lib.sh"
  local record overview selected
  record=$'run:\n  id: 01INTERRUPTED\n  branch: fm/interrupted\n  head: 12345678\n  status: ci_monitor_interrupted\nbranch_sync:\n  state: pipeline_owned'
  assert_equals terminal "$(fm_nm_run_status_class ci_monitor_interrupted)" 'interrupted monitor is terminal'
  if fm_nm_run_is_active "$record" || fm_nm_run_is_executing "$record" || fm_nm_run_is_pipeline_owned_active "$record"; then
    fail 'interrupted monitor must never retain active custody'
  fi
  assert_equals fm/interrupted "$(fm_nm_field "$record" branch)" 'interruption preserves branch'
  assert_equals 12345678 "$(fm_nm_field "$record" head)" 'interruption preserves head'
  overview=$'count: 1 of 1 total\nruns[1]{id,branch,status,head,pr}:\n  01INTERRUPTED,fm/interrupted,ci_monitor_interrupted,12345678,""'
  selected=$(fm_nm_select_run fm/interrupted "$overview" "$WT" 5)
  assert_equals 'selected|01INTERRUPTED|ci_monitor_interrupted|01INTERRUPTED' "$selected" 'interrupted row is selectable'
  overview=$'count: 2 of 2 total\nruns[2]{id,branch,status,head,pr}:\n  01ACTIVE,fm/interrupted,running,abcdef12,""\n  01INTERRUPTED,fm/interrupted,ci_monitor_interrupted,12345678,""'
  assert_equals 'selected|01ACTIVE|running|01ACTIVE, 01INTERRUPTED' "$(fm_nm_select_run fm/interrupted "$overview" "$WT" 5)" 'new active run outranks interruption'
  pass 'interrupted monitor is terminal and newer active runs retain precedence'
}

test_interrupted_monitor_is_terminal
test_a_probe_runs_no_mistakes_with_lazy_fetching_disabled
test_probe_wrappers_suppress_update_checks_without_extra_launches
test_a_bounded_command_reads_its_callers_stdin
test_a_probe_that_hits_its_bound_leaves_no_descendant_behind
test_resolving_a_missing_commit_answers_absent_without_fetching
