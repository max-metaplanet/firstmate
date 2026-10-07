#!/usr/bin/env bash
# Drive three real bin/fm-pr-merge.sh runs for the same repository concurrently,
# joining youngest-first, and record the real interleaving of forge calls.
cd "$1"
. "$2/defs.sh"
set -u
root="$TMP_ROOT/batch-line"; order="$TMP_ROOT/batch-order.log"; : > "$order"
mk() { # name head url ready behind?
  local c; c=$(make_case "$1"); mkdir -p "$c/wt"
  if [ "$5" = behind ]; then
    add_gh_mocks "$c" "$2"
    write_github_view_state "$c/view-behind" "$2" BEHIND false true "$(check_run ci COMPLETED SUCCESS)"
    write_github_view_state "$c/view-green" "${2%??}ff" CLEAN false true "$(check_run ci COMPLETED SUCCESS)"
    queue_github_views "$c" "$c/view-behind" "$c/view-green"
  else add_gh_mocks "$c" "$2"; fi
  : > "$c/gh.log"; write_ready_status "$c/state/task-x1.status" "$4" "$3"; printf '%s\n' "$c"
}
A=$(mk batch-A 1111111111111111111111111111111111111111 https://github.com/example/repo/pull/901 1700000100 green)
B=$(mk batch-B 2222222222222222222222222222222222222222 https://github.com/example/repo/pull/902 1700000200 behind)
C=$(mk batch-C 3333333333333333333333333333333333333333 https://github.com/example/repo/pull/903 1700000300 behind)
write_line_holder "$TMP_ROOT/h.sh"
hp=$(start_line_holder "$root" "$TMP_ROOT/hs" "$TMP_ROOT/h.sh" github.com example/repo https://github.com/example/repo/pull/900 1700000000 "$TMP_ROOT/hr" "$TMP_ROOT/hx")
echo "holder (pull/900, ready 1700000000) holds the turn"
go() { ( export FM_TEST_PR_MERGE_LINE_ROOT="$root" FM_TEST_GH_ORDER_LOG="$order" FM_TEST_GH_ORDER_LABEL=$2 FM_PR_MERGE_LINE_TIMEOUT=120 FM_PR_MERGE_LINE_POLL=1 FM_PR_GITHUB_FRESHNESS_POLL=0
  run_pr_merge "$1" task-x1 "$3" > "$1/stdout" 2> "$1/stderr" ) & }
go "$C" C https://github.com/example/repo/pull/903; pc=$!; wait_for_line_depth "$root" 2; echo "C (ready 1700000300) joined"
go "$B" B https://github.com/example/repo/pull/902; pb=$!; wait_for_line_depth "$root" 3; echo "B (ready 1700000200) joined"
go "$A" A https://github.com/example/repo/pull/901; pa=$!; wait_for_line_depth "$root" 4; echo "A (ready 1700000100) joined"
echo "--- line tickets while queued:"; for f in "$root"/*.line/*; do echo "  ${f##*/} -> $(head -1 "$f")"; done
echo "--- forge write calls while queued: $(cat "$A/gh.log" "$B/gh.log" "$C/gh.log" | grep -cE '^pr (update-branch|merge) ')"
: > "$TMP_ROOT/hx"; wait $hp; ra=0 rb=0 rc=0; wait $pa || ra=$?; wait $pb || rb=$?; wait $pc || rc=$?
echo "--- exit codes: A=$ra B=$rb C=$rc"
echo "--- ordered forge write calls across all three runs:"; grep -E ' pr (update-branch|merge) ' "$order" | sed 's/^/  /'
echo "--- line dir after: $(ls -A "$root"/*.line | wc -l | tr -d ' ') tickets; turn present: $(ls -d "$root"/*.turn 2>/dev/null | wc -l | tr -d ' ')"
