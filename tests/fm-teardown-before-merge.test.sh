#!/usr/bin/env bash
# Pushed PR branches must retain their task record until landing is proved,
# including cleanup attempted by the supervision branch on a stale wake.
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid
TMP_ROOT=$(fm_test_tmproot teardown-before-merge)

make_case() {  # <name> <mode> [record-pr]
  local dir="$TMP_ROOT/$1" mode=$2 record=${3:-yes}
  mkdir -p "$dir/home/state" "$dir/home/config" "$dir/home/data" "$dir/fakebin"
  git init -q --bare "$dir/origin.git"
  git -C "$dir/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$dir/origin.git" "$dir/project" 2>/dev/null
  git -C "$dir/project" commit -q --allow-empty -m baseline
  git -C "$dir/project" push -q origin main
  git -C "$dir/project" remote set-head origin main
  git clone -q "$dir/origin.git" "$dir/copy"
  git -C "$dir/copy" checkout -qb fm/task-x1
  printf 'unmerged change\n' > "$dir/copy/feature"
  git -C "$dir/copy" add feature
  git -C "$dir/copy" commit -qm feature
  git -C "$dir/copy" push -q origin fm/task-x1
  git -C "$dir/project" fetch -q origin
  fm_write_meta "$dir/home/state/task-x1.meta" \
    'kind=ship' "mode=$mode" 'spawn_gen=teardown-regression' \
    'window=fixture:fm-task-x1' 'endpoint_task_id=task-x1' \
    "worktree=$dir/copy" "project=$dir/project"
  if [ "$record" = yes ]; then
    printf 'pr=https://github.com/example/repo/pull/7\n' >> "$dir/home/state/task-x1.meta"
  fi
  printf 'done [at=1792270100]: PR https://github.com/example/repo/pull/7\n' \
    > "$dir/home/state/task-x1.status"
  touch "$dir/home/state/.last-watcher-beat"
  # Every external dependency is hermetic. The forge's state is the only
  # variable changed between the open-PR refusal and merged-PR success.
  cat > "$dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
case "$1 $2" in
  'pr list')
    [ "${FM_TEST_PR_STATE:-OPEN}" != NONE ] || { printf 'pull_requests[]: []\n'; exit 0; }
    printf 'pull_requests[1]{number,state}:\n  7,%s\n' "${FM_TEST_PR_STATE:-OPEN}" ;;
esac
SH
  cat > "$dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
if [ "$1 $2" = 'pr view' ]; then
  case "${FM_TEST_PR_STATE:-OPEN}" in ERROR|NONE) exit 1 ;; esac
  printf '%s\t%s\thttps://github.com/example/repo/pull/7\n' \
    "${FM_TEST_PR_STATE:-OPEN}" "${FM_TEST_PR_HEAD:?}"
  exit 0
fi
exit 1
SH
  cat > "$dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
printf 'return\n' >> "${FM_TEST_RUNTIME_LOG:?}"
SH
  cat > "$dir/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "$1" in
  kill-*) printf 'kill\n' >> "${FM_TEST_RUNTIME_LOG:?}" ;;
esac
exit 0
SH
  cat > "$dir/fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$dir/fakebin/"*
  printf '%s\n' "$dir"
}

run_teardown() {  # <case> <actor> <pr-state> [pr-head]
  local dir=$1 actor=$2 state=$3 head=${4:-}
  [ -n "$head" ] || head=$(git -C "$dir/copy" rev-parse HEAD)
  FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$dir/home/state" FM_DATA_OVERRIDE="$dir/home/data" \
  FM_CONFIG_OVERRIDE="$dir/home/config" FM_SUPERVISION_ACTOR="$actor" \
  FM_TEST_PR_STATE="$state" FM_TEST_PR_HEAD="$head" \
  FM_TEST_RUNTIME_LOG="$dir/runtime.log" PATH="$dir/fakebin:$PATH" \
    bash "$ROOT/bin/fm-teardown.sh" task-x1 > "$dir/output" 2>&1
}

assert_retained() {  # <case> <head>
  local dir=$1 head=$2
  assert_present "$dir/home/state/task-x1.meta" 'teardown removed the unmerged task record'
  assert_present "$dir/home/state/task-x1.status" 'teardown removed the ready status'
  [ "$(git -C "$dir/copy" rev-parse HEAD)" = "$head" ] || fail 'teardown changed the unlanded head'
  [ "$(git -C "$dir/copy" branch --show-current)" = fm/task-x1 ] || fail 'teardown removed the task branch'
  [ ! -s "$dir/runtime.log" ] || fail 'teardown returned the copy or killed the endpoint before refusal'
}

test_pushed_open_pr_refuses() {
  local mode actor record dir head rc
  for mode in direct-PR no-mistakes; do
    for actor in branch main; do
      for record in yes no; do
        dir=$(make_case "$mode-$actor-$record" "$mode" "$record")
        head=$(git -C "$dir/copy" rev-parse HEAD)
        # Pin the original bypass condition: every commit is on a remote.
        [ -z "$(git -C "$dir/copy" log HEAD --not --remotes --)" ] || fail 'fixture has unpushed commits'
        rc=0
        run_teardown "$dir" "$actor" OPEN || rc=$?
        if [ "$rc" -eq 0 ]; then
          [ -e "$dir/home/state/task-x1.meta" ] \
            || fail "$mode/$actor/$record: pushed OPEN PR teardown succeeded and removed the task record"
          fail "$mode/$actor/$record: pushed OPEN PR teardown succeeded"
        fi
        assert_contains "$(cat "$dir/output")" REFUSED 'refusal must name the safety gate'
        assert_retained "$dir" "$head"
      done
    done
  done
  pass 'pushed open PRs retain records and endpoints for both actors and PR delivery modes, with or without pr= metadata'
}

test_same_pushed_head_allows_after_merge() {
  local dir
  dir=$(make_case merged direct-PR)
  run_teardown "$dir" branch MERGED || fail "merged pushed PR refused: $(cat "$dir/output")"
  assert_absent "$dir/home/state/task-x1.meta" 'merged PR teardown retained the task record'
  assert_grep return "$dir/runtime.log" 'merged PR never reached cleanup'
  pass 'changing only the forge verdict to merged permits the same pushed head to be cleaned up'
}

test_pushed_unproved_work_refuses() {
  local state dir head rc record
  for state in CLOSED ERROR NONE; do
    record=yes
    [ "$state" != NONE ] || record=no
    dir=$(make_case "unproved-$state" direct-PR "$record")
    head=$(git -C "$dir/copy" rev-parse HEAD)
    rc=0
    run_teardown "$dir" branch "$state" || rc=$?
    [ "$rc" -ne 0 ] || fail "$state: published but unlanded work was accepted"
    assert_retained "$dir" "$head"
  done
  pass 'closed unmerged PRs, forge errors, and absent PRs cannot turn publication into landing'
}

test_open_pr_blocks_default_content_fallback() {
  local dir head rc
  dir=$(make_case open-content direct-PR)
  head=$(git -C "$dir/copy" rev-parse HEAD)
  git -C "$dir/copy" push -q origin HEAD:main
  rc=0
  run_teardown "$dir" branch OPEN || rc=$?
  [ "$rc" -ne 0 ] || fail 'an open PR used equivalent default content to erase its task record'
  assert_retained "$dir" "$head"
  pass 'a known open PR blocks cleanup even when its content is also on the default branch'
}

test_pushed_followup_after_merged_pr_refuses() {
  local dir pr_head head rc
  dir=$(make_case merged-followup direct-PR)
  pr_head=$(git -C "$dir/copy" rev-parse HEAD)
  printf 'later unmerged work\n' > "$dir/copy/later"
  git -C "$dir/copy" add later
  git -C "$dir/copy" commit -qm followup
  git -C "$dir/copy" push -q origin fm/task-x1
  head=$(git -C "$dir/copy" rev-parse HEAD)
  rc=0
  run_teardown "$dir" branch MERGED "$pr_head" || rc=$?
  [ "$rc" -ne 0 ] || fail 'a merged PR accepted a later pushed commit'
  assert_retained "$dir" "$head"
  pass 'a merged PR head cannot authorize cleanup of later published work'
}

test_replayed_patch_does_not_hide_pushed_unmerged_work() {
  local dir pr_head head rc
  dir=$(make_case replayed-plus-pushed direct-PR)
  pr_head=$(git -C "$dir/copy" rev-parse HEAD)
  git -C "$dir/copy" checkout -qb replay origin/main
  printf 'unmerged published work\n' > "$dir/copy/later"
  git -C "$dir/copy" add later
  git -C "$dir/copy" commit -qm 'published extra'
  git -C "$dir/copy" push -q origin replay
  git -C "$dir/copy" cherry-pick "$pr_head" >/dev/null
  head=$(git -C "$dir/copy" rev-parse HEAD)
  rc=0
  run_teardown "$dir" branch MERGED "$pr_head" || rc=$?
  [ "$rc" -ne 0 ] || fail 'patch equivalence ignored a published commit outside the merged PR'
  assert_present "$dir/home/state/task-x1.meta" 'patch equivalence removed the task record'
  [ "$(git -C "$dir/copy" rev-parse HEAD)" = "$head" ] || fail 'patch equivalence discarded work'
  [ ! -s "$dir/runtime.log" ] || fail 'patch equivalence reached destructive cleanup'
  pass 'patch equivalence accounts for published local commits as well as unpushed ones'
}

test_content_fallback_still_proves_landing() {
  local state dir
  for state in NONE ERROR; do
    dir=$(make_case "content-fallback-$state" direct-PR no)
    git -C "$dir/copy" push -q origin HEAD:main
    run_teardown "$dir" branch "$state" \
      || fail "$state: fresh default-branch content no longer proves landing: $(cat "$dir/output")"
    assert_absent "$dir/home/state/task-x1.meta" 'content-proved landing retained the task record'
  done
  pass 'fresh default-branch content still proves landing when no known unmerged PR blocks it'
}

test_merged_pr_does_not_bypass_dirty_refusal() {
  local dir head rc
  dir=$(make_case merged-dirty direct-PR)
  head=$(git -C "$dir/copy" rev-parse HEAD)
  printf 'uncommitted followup\n' >> "$dir/copy/feature"
  rc=0
  run_teardown "$dir" branch MERGED || rc=$?
  [ "$rc" -ne 0 ] || fail 'a merged PR bypassed the dirty-worktree refusal'
  assert_retained "$dir" "$head"
  assert_contains "$(cat "$dir/output")" 'uncommitted changes' 'dirty refusal lost its diagnosis'
  pass 'a merged PR never authorizes discarding uncommitted work'
}

test_replayed_patch_without_extra_work_allows() {
  local dir pr_head
  dir=$(make_case replayed-landed direct-PR)
  pr_head=$(git -C "$dir/copy" rev-parse HEAD)
  git -C "$dir/copy" checkout -qb replay origin/main
  git -C "$dir/copy" cherry-pick --no-commit "$pr_head"
  git -C "$dir/copy" commit -qm 'replay landed feature'
  git -C "$dir/copy" push -q origin replay
  run_teardown "$dir" branch MERGED "$pr_head" \
    || fail "equivalent replayed patch refused: $(cat "$dir/output")"
  assert_absent "$dir/home/state/task-x1.meta" 'equivalent merged patch retained the task record'
  pass 'a published replay containing only patches from the merged PR still permits cleanup'
}

test_pushed_open_pr_refuses
test_same_pushed_head_allows_after_merge
test_pushed_unproved_work_refuses
test_open_pr_blocks_default_content_fallback
test_pushed_followup_after_merged_pr_refuses
test_replayed_patch_does_not_hide_pushed_unmerged_work
test_content_fallback_still_proves_landing
test_merged_pr_does_not_bypass_dirty_refusal
test_replayed_patch_without_extra_work_allows
