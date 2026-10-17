#!/usr/bin/env bash
# tests/fm-watch-busy-window-fork-budget.test.sh - per-window poll-loop forks.
#
# The whole-cycle sampler in fm-supervision-fork-budget.test.sh only ever runs
# against an idle home with no recorded windows, so it cannot see a cost that
# scales with window count. Two such costs live in the busy-pane path every
# live fleet actually exercises:
#   - hash_pane used to pipe into a second program (`| md5 -q` / `| md5sum |
#     cut`), forking two pipeline subshells plus the hash program itself on
#     every window on every poll.
#   - busy_turn_over_age used to resolve each window's progress-marker mtime
#     through stat_mtime, forking a `stat` on every BUSY window on every poll -
#     the single most common case in a live fleet.
# This measures both directly, at increasing window/task counts, and holds
# each to a fixed per-call or per-poll program budget instead of one that
# grows with the count.
set -u
# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"
trap fm_test_cleanup EXIT

TMP_ROOT=$(fm_test_tmproot fm-watch-busy-window-budget)
export FM_STATE_OVERRIDE="$TMP_ROOT/state"
mkdir -p "$FM_STATE_OVERRIDE"
# fm-watch.sh's source-guard setup (see "Main entry") only runs the lock/loop
# when executed, not sourced, so this loads hash_pane and busy_turn_over_age
# without starting a watcher.
. "$ROOT/bin/fm-watch.sh"

EVENTS="$TMP_ROOT/events"
SHIMS="$TMP_ROOT/shims"
mkdir -p "$SHIMS"
for tool in md5 md5sum touch date; do
  real=$(command -v "$tool") || continue
  cat > "$SHIMS/$tool" <<SH
#!/bin/sh
printf 'program $tool\n' >> "$EVENTS"
exec '$real' "\$@"
SH
  chmod +x "$SHIMS/$tool"
done
PATH="$SHIMS:$PATH"

count_programs() {  # [tool] -> count of programs recorded since last reset
  local line total=0 named=0
  [ -f "$EVENTS" ] || { printf '0\n'; return 0; }
  while IFS= read -r line; do
    total=$((total + 1))
    [ "$line" != "program ${1:-}" ] || named=$((named + 1))
  done < "$EVENTS"
  [ "$#" -eq 0 ] && printf '%s\n' "$total" || printf '%s\n' "$named"
}

# --- hash_pane: one program per call, no pipeline subshells -----------------

: > "$EVENTS"
for i in 1 2 3 4 5; do
  hash_pane "pane content $i" > /dev/null
done
programs=$(count_programs)
[ "$programs" -le 5 ] || fail "hash_pane cost $programs programs for 5 calls, expected at most 5 (one hash program per call, no pipeline)"
[ "$programs" -ge 1 ] || fail "hash_pane recorded no program start; the shim did not observe the real hash tool"
pass "hash_pane costs exactly one program per call, no pipeline subshells"

# Byte-identical to the old `printf '%s' "$x" | { md5 -q || md5sum | cut ...; }`
# pipeline, so the stale-pane hash comparison it feeds is unchanged.
old_pipeline_hash() {
  if command -v md5 > /dev/null 2>&1; then
    printf '%s' "$1" | md5 -q
  else
    printf '%s' "$1" | md5sum | cut -d' ' -f1
  fi
}
for sample in '' 'a' 'pane with spaces and a trailing newline
' "$(printf 'tabs\tand\tcontrol')"; do
  old=$(old_pipeline_hash "$sample")
  new=$(hash_pane "$sample")
  [ "$old" = "$new" ] || fail "hash_pane('$sample') = '$new', expected '$old' to match the pipeline it replaced"
done
pass "hash_pane matches the pipeline-based hash it replaced byte for byte"

# --- busy_turn_over_age: one stat_mtime call per poll, not one per window ---

# stat_mtime itself execs /usr/bin/stat by absolute path on Darwin (deliberately,
# to dodge a PATH-shadowing GNU stat - see its definition above), so a PATH shim
# cannot observe it there. Wrap the seam fm-watch.sh already defines for every
# mtime read instead: this counts calls regardless of platform and proves the
# exact fork this fix removes from the per-window hot path.
eval "$(declare -f stat_mtime | sed '1s/^stat_mtime/_orig_stat_mtime/')"
STAT_MTIME_CALLS=0
stat_mtime() { STAT_MTIME_CALLS=$((STAT_MTIME_CALLS + 1)); _orig_stat_mtime "$@"; }

make_task() {  # <task> <age-seconds>
  local task=$1 age=$2 f
  f="$FM_STATE_OVERRIDE/$task.turn-ended"
  : > "$f"
  touch -t "$(date -v-${age}S '+%Y%m%d%H%M.%S' 2>/dev/null || date -d "-${age} seconds" '+%Y%m%d%H%M.%S')" "$f"
}

for n in 1 5 20; do
  rm -f "$FM_STATE_OVERRIDE"/*.turn-ended "$BUSY_TURN_THRESHOLD"
  for ((i = 1; i <= n; i++)); do
    make_task "task-$i" 10  # well under BUSY_TURN_MAX_SECS (3600 default)
  done
  now=$(date +%s)
  busy_turn_threshold_refresh "$now"  # the one touch a real poll pays, amortized over every window
  STAT_MTIME_CALLS=0
  over=0
  for ((i = 1; i <= n; i++)); do
    busy_turn_over_age "task-$i" && over=$((over + 1))
  done
  [ "$over" -eq 0 ] || fail "busy_turn_over_age reported $over of $n fresh ($n-task poll) windows as over age"
  printf 'busy_turn_over_age at %s windows: stat_mtime calls=%s\n' "$n" "$STAT_MTIME_CALLS"
  [ "$STAT_MTIME_CALLS" -eq 0 ] || fail "busy_turn_over_age called stat_mtime $STAT_MTIME_CALLS times for $n windows once the shared threshold was refreshed, expected 0 (the old path forked stat_mtime once per window)"
done
pass "busy_turn_over_age costs one shared touch per poll and zero further stat_mtime calls per window"

# A window whose progress marker is OLDER than the threshold is still reported
# correctly through the builtin -ot comparison (not just the fresh case above).
rm -f "$FM_STATE_OVERRIDE"/*.turn-ended "$BUSY_TURN_THRESHOLD"
make_task old-task 7200  # past the 3600s default BUSY_TURN_MAX_SECS
now=$(date +%s)
busy_turn_threshold_refresh "$now"
busy_turn_over_age old-task || fail "busy_turn_over_age did not report a 2h-old turn marker as over the 3600s default"
pass "busy_turn_over_age still reports a genuinely over-age turn marker"

# A task with no turn-ended or meta marker at all reads as over age (matching
# age_of's 999999-when-missing fallback via the -ot missing-file semantics).
rm -f "$FM_STATE_OVERRIDE"/*.turn-ended "$FM_STATE_OVERRIDE"/*.meta "$BUSY_TURN_THRESHOLD"
now=$(date +%s)
busy_turn_threshold_refresh "$now"
busy_turn_over_age missing-task || fail "busy_turn_over_age did not treat a missing progress marker as over age"
pass "busy_turn_over_age treats a missing progress marker as over age"
