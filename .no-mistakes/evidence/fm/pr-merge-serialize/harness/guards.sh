#!/usr/bin/env bash
cd "$1"; . "$2/defs.sh"; set -u
write_line_holder "$TMP_ROOT/h.sh"
echo "=== 1. waiter whose bound is spent refuses with nothing updated or merged"
root="$TMP_ROOT/r1"
c=$(make_case refuse); mkdir -p "$c/wt"; add_gh_mocks "$c" 4444444444444444444444444444444444444444
write_github_view_state "$c/view-behind" 4444444444444444444444444444444444444444 BEHIND false true "$(check_run ci COMPLETED SUCCESS)"; queue_github_views "$c" "$c/view-behind"; : > "$c/gh.log"
hp=$(start_line_holder "$root" "$TMP_ROOT/hs1" "$TMP_ROOT/h.sh" github.com example/repo https://github.com/example/repo/pull/950 1700000000 "$TMP_ROOT/r1r" "$TMP_ROOT/r1x")
s=$(date +%s); rc=0; FM_TEST_PR_MERGE_LINE_ROOT="$root" FM_PR_MERGE_LINE_TIMEOUT=3 FM_PR_MERGE_LINE_POLL=1 run_pr_merge "$c" task-x1 https://github.com/example/repo/pull/951 >/dev/null 2>"$c/stderr" || rc=$?
echo "exit=$rc after $(( $(date +%s) - s ))s"; grep -E 'merge line|ahead' "$c/stderr"
echo "forge writes by the waiter: $(grep -cE '^pr (update-branch|merge) ' "$c/gh.log")"
: > "$TMP_ROOT/r1x"; sleep 0.5
echo; echo "=== 2. a SIGKILLed holder never wedges the line"
root="$TMP_ROOT/r2"
c=$(make_case crash); mkdir -p "$c/wt"; add_gh_mocks "$c" 5555555555555555555555555555555555555555; : > "$c/gh.log"
hp=$(start_line_holder "$root" "$TMP_ROOT/hs2" "$TMP_ROOT/h.sh" github.com example/repo https://github.com/example/repo/pull/960 1700000000 "$TMP_ROOT/r2r" "$TMP_ROOT/r2x")
kill -9 "$hp"; sleep 0.3; echo "holder $hp SIGKILLed; left behind: $(ls "$root"/*.line) turn=$(ls -d "$root"/*.turn 2>/dev/null | wc -l | tr -d ' ')"
s=$(date +%s); rc=0; FM_TEST_PR_MERGE_LINE_ROOT="$root" FM_PR_MERGE_LINE_TIMEOUT=30 FM_PR_MERGE_LINE_POLL=1 run_pr_merge "$c" task-x1 https://github.com/example/repo/pull/961 >/dev/null 2>"$c/stderr" || rc=$?
echo "next run exit=$rc after $(( $(date +%s) - s ))s; merge call: $(grep -E '^pr merge ' "$c/gh.log")"
echo; echo "=== 3. a merge on another repository never waits behind an occupied line"
root="$TMP_ROOT/r3"
c=$(make_case other); mkdir -p "$c/wt"; add_gh_mocks "$c" 6666666666666666666666666666666666666666; : > "$c/gh.log"
hp=$(start_line_holder "$root" "$TMP_ROOT/hs3" "$TMP_ROOT/h.sh" github.com example/repo https://github.com/example/repo/pull/970 1700000000 "$TMP_ROOT/r3r" "$TMP_ROOT/r3x")
s=$(date +%s); rc=0; FM_TEST_PR_MERGE_LINE_ROOT="$root" FM_PR_MERGE_LINE_TIMEOUT=30 FM_PR_MERGE_LINE_POLL=1 run_pr_merge "$c" task-x1 https://github.com/example/other/pull/5 >/dev/null 2>"$c/stderr" || rc=$?
echo "example/other exit=$rc after $(( $(date +%s) - s ))s while example/repo turn held; merge call: $(grep -E '^pr merge ' "$c/gh.log")"
echo; echo "=== 4. GitLab never enters a line, even with a GitHub turn held on the same path"
hp4=$(start_line_holder "$root" "$TMP_ROOT/hs4" "$TMP_ROOT/h.sh" "$MR_HOST" "$MR_PATH" "https://github.com/$MR_PATH/pull/1" 1700000000 "$TMP_ROOT/r4r" "$TMP_ROOT/r4x")
c=$(make_gitlab_case gl)
s=$(date +%s); rc=0; FM_TEST_PR_MERGE_LINE_ROOT="$root" FM_PR_MERGE_LINE_TIMEOUT=30 run_pr_merge "$c" task-x1 "$MR_URL" >/dev/null 2>"$c/stderr" || rc=$?
echo "gitlab exit=$rc after $(( $(date +%s) - s ))s; merge: $(glab_merge_line "$c/glab.log")"
echo "line root entries (none should be gitlab-*): $(ls "$root" | tr '\n' ' ')"
: > "$TMP_ROOT/r3x"; : > "$TMP_ROOT/r4x"; sleep 0.5
