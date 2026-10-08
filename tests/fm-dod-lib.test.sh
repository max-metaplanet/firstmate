#!/usr/bin/env bash
# Behavior tests for bin/fm-dod-lib.sh's named-head reachability gate on ship
# done: acceptance (issue 4768). The gate must test the commit the worker names,
# not merely that some remote-tracking branch exists or moved.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-dod-lib.sh
. "$ROOT/bin/fm-dod-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-dod-lib)
fm_git_identity fmtest fmtest@example.invalid

accept_done() {  # <kind> <mode> <worktree> <project> <line> [<state> <id> <meta>]
  fm_dod_accept_ship_done "$@"
}

write_merge_marker() {  # <state> <id> <provider> <host> <path> <number>
  printf '%s\n' fm-pr-poll-merge-notified-v1 "$3" "$4" "$5" "$6" > "$1/$2.pr-poll-merge-notified"
  chmod 600 "$1/$2.pr-poll-merge-notified"
}

test_scout_done_is_not_gated() {
  local repo wt
  repo="$TMP_ROOT/scout-repo"
  wt="$TMP_ROOT/scout-wt"
  fm_git_worktree "$repo" "$wt" fm/scout
  git -C "$wt" commit -q --allow-empty -m 'only in the disposable copy'
  accept_done scout no-mistakes "$wt" "$repo" 'done: report written' \
    || fail "scout done: must not require named-head reachability outside the copy"
  pass "scout done: is not gated"
}

test_unpushed_ship_done_is_refused() {
  local repo wt sha reason rc
  repo="$TMP_ROOT/unpushed-repo"
  wt="$TMP_ROOT/unpushed-wt"
  fm_git_worktree "$repo" "$wt" fm/unpushed
  git -C "$wt" commit -q --allow-empty -m 'fix only in the worktree'
  sha=$(git -C "$wt" rev-parse HEAD)
  reason=$(accept_done ship no-mistakes "$wt" "$repo" "done: PR https://example.test/o/r/pull/1 checks green")
  rc=$?
  [ "$rc" -eq 1 ] || fail "unpushed ship done: was accepted (exit $rc)"
  case "$reason" in
    *"named head $sha is unreachable outside the worker copy"*) ;;
    *) fail "unpushed refusal did not name the commit: $reason" ;;
  esac
  pass "unpushed ship done: is refused"
}

test_remote_containing_named_head_is_accepted() {
  local repo wt sha
  repo="$TMP_ROOT/pushed-repo"
  wt="$TMP_ROOT/pushed-wt"
  fm_git_worktree "$repo" "$wt" fm/pushed
  git -C "$wt" commit -q --allow-empty -m 'fix on the branch'
  sha=$(git -C "$wt" rev-parse HEAD)
  git -C "$wt" update-ref refs/remotes/origin/fm/pushed "$sha"
  accept_done ship no-mistakes "$wt" "$repo" "done: PR https://example.test/o/r/pull/2 checks green" \
    || fail "named head on a remote-tracking ref was refused"
  pass "named head on a remote-tracking ref is accepted"
}

test_moved_branch_without_named_head_is_refused() {
  local repo wt main_sha fix_sha reason rc
  repo="$TMP_ROOT/moved-repo"
  wt="$TMP_ROOT/moved-wt"
  fm_git_worktree "$repo" "$wt" fm/moved
  main_sha=$(git -C "$repo" rev-parse main)
  git -C "$wt" commit -q --allow-empty -m 'the actual fix'
  fix_sha=$(git -C "$wt" rev-parse HEAD)
  # The fork branch exists and moved, but only to a merge of the default
  # branch: reachability of that branch is not reachability of the named head.
  git -C "$wt" update-ref refs/remotes/origin/fm/moved "$main_sha"
  reason=$(accept_done ship no-mistakes "$wt" "$repo" "done: PR https://example.test/o/r/pull/3 checks green")
  rc=$?
  [ "$rc" -eq 1 ] || fail "moved remote branch without the named head was accepted"
  case "$reason" in
    *"named head $fix_sha is unreachable outside the worker copy"*) ;;
    *) fail "moved-branch refusal did not name the fix commit: $reason" ;;
  esac
  pass "a moved remote branch that lacks the named head is refused"
}

# A no-mistakes worker runs the pipeline itself, so a done: it appends after
# only committing locally claims a finished task that was never shipped. The
# gate refuses it even when the commit is reachable outside the copy, because
# reachability is not a PR, and the reason must say what to do instead.
test_no_mistakes_done_without_a_pr_is_refused() {
  local repo wt sha reason rc
  repo="$TMP_ROOT/nopr-repo"
  wt="$TMP_ROOT/nopr-wt"
  fm_git_worktree "$repo" "$wt" fm/nopr
  git -C "$wt" commit -q --allow-empty -m 'implementation commit'
  sha=$(git -C "$wt" rev-parse HEAD)
  # Reachable outside the copy: only the missing PR may carry the refusal.
  git -C "$wt" update-ref refs/remotes/origin/fm/nopr "$sha"
  for line in \
    'done: implementation complete' \
    'done [key=fix]: committed on fm/nopr, ready for /no-mistakes' \
    'done: pushed branch, no PR yet'; do
    rc=0
    reason=$(accept_done ship no-mistakes "$wt" "$repo" "$line") || rc=$?
    [ "$rc" -eq 1 ] || fail "no-mistakes done: with no PR was accepted: $line"
    case "$reason" in
      *"reports no PR"*"run /no-mistakes from this copy"*) ;;
      *) fail "no-PR refusal did not name the missing PR and the remedy: $reason" ;;
    esac
  done
  # An unregistered project resolves to the same default mode.
  rc=0
  accept_done ship '' "$wt" "$repo" 'done: implementation complete' >/dev/null || rc=$?
  [ "$rc" -eq 1 ] || fail "an empty mode did not take the no-mistakes refusal"
  pass "a no-mistakes done: naming no PR is refused with the pipeline remedy"
}

# The refusal is specific to the missing PR: a no-mistakes done that DOES name
# its CI-ready PR still reaches the named-head gate rather than this one.
test_no_mistakes_ci_ready_done_passes_the_pr_check() {
  local repo wt sha
  repo="$TMP_ROOT/ciready-repo"
  wt="$TMP_ROOT/ciready-wt"
  fm_git_worktree "$repo" "$wt" fm/ciready
  git -C "$wt" commit -q --allow-empty -m 'implementation commit'
  sha=$(git -C "$wt" rev-parse HEAD)
  git -C "$wt" update-ref refs/remotes/origin/fm/ciready "$sha"
  accept_done ship no-mistakes "$wt" "$repo" \
    'done: PR https://example.test/o/r/pull/7 checks green' \
    || fail "a CI-ready no-mistakes done: on a reachable head was refused"
  pass "a CI-ready no-mistakes done: is not caught by the no-PR refusal"
}

test_local_only_linked_branch_is_accepted() {
  local repo wt
  repo="$TMP_ROOT/local-repo"
  wt="$TMP_ROOT/local-wt"
  fm_git_worktree "$repo" "$wt" fm/local
  git -C "$wt" commit -q --allow-empty -m 'local-only work'
  accept_done ship local-only "$wt" "$repo" "done: ready in branch fm/local" \
    || fail "local-only named branch in a linked worktree was refused"
  pass "local-only linked named branch is reachable from the project clone"
}

test_local_only_detached_head_is_refused() {
  local repo wt sha rc
  repo="$TMP_ROOT/detach-repo"
  wt="$TMP_ROOT/detach-wt"
  fm_git_worktree "$repo" "$wt" fm/detach
  git -C "$wt" commit -q --allow-empty -m 'detached only'
  sha=$(git -C "$wt" rev-parse HEAD)
  git -C "$wt" checkout -q --detach HEAD
  git -C "$wt" branch -q -D fm/detach
  accept_done ship local-only "$wt" "$repo" "done: ready in branch fm/detach" >/dev/null \
    && fail "detached local-only head whose branch was deleted was accepted"
  rc=0
  accept_done ship local-only "$wt" "$repo" "done: implementation complete" >/dev/null || rc=$?
  [ "$rc" -eq 1 ] || fail "detached local-only HEAD was accepted as done"
  pass "local-only detached HEAD only in the disposable copy is refused"
}

test_standalone_local_only_needs_project_ref() {
  local repo wt sha
  repo="$TMP_ROOT/stand-project"
  wt="$TMP_ROOT/stand-copy"
  fm_git_init_commit "$repo"
  git clone --quiet "$repo" "$wt"
  git -C "$wt" checkout -q -b fm/stand
  git -C "$wt" commit -q --allow-empty -m 'only in the standalone copy'
  sha=$(git -C "$wt" rev-parse HEAD)
  accept_done ship local-only "$wt" "$repo" "done: ready in branch fm/stand" >/dev/null \
    && fail "standalone local-only copy was accepted without the named head in the project clone"
  git -C "$repo" fetch -q "$wt" "fm/stand:fm/stand"
  [ "$(git -C "$repo" rev-parse fm/stand)" = "$sha" ] \
    || fail "project clone did not gain the named head"
  accept_done ship local-only "$wt" "$repo" "done: ready in branch fm/stand" \
    || fail "standalone local-only named head present in the project clone was refused"
  pass "standalone local-only done: requires the named head in the project clone"
}

test_free_text_sha_is_not_the_named_head() {
  local repo wt old new reason rc
  repo="$TMP_ROOT/hex-repo"
  wt="$TMP_ROOT/hex-wt"
  fm_git_worktree "$repo" "$wt" fm/hex
  old=$(git -C "$wt" rev-parse HEAD)
  git -C "$wt" update-ref refs/remotes/origin/main "$old"
  git -C "$wt" commit -q --allow-empty -m 'actual fix'
  new=$(git -C "$wt" rev-parse HEAD)
  reason=$(accept_done ship direct-PR "$wt" "$repo" "done: reverted $old and fixed the retry")
  rc=$?
  [ "$rc" -eq 1 ] || fail "free-text SHA on origin/main made an unpushed HEAD accept"
  case "$reason" in
    *"named head $new is unreachable outside the worker copy"*) ;;
    *) fail "free-text SHA scan still selected the old commit: $reason" ;;
  esac
  pass "a 40-hex token in the note is not the named head"
}

test_recorded_merged_pr_is_landed_after_prune() {
  local repo wt meta state
  repo="$TMP_ROOT/merged-repo"
  wt="$TMP_ROOT/merged-wt"
  state="$TMP_ROOT/merged-state"
  mkdir -p "$state"
  fm_git_worktree "$repo" "$wt" fm/merged
  git -C "$wt" commit -q --allow-empty -m 'fix, squash-merged and branch pruned'
  meta="$state/merged.meta"
  printf 'kind=ship\nmode=direct-PR\nworktree=%s\nproject=%s\npr=https://github.com/o/r/pull/7\n' \
    "$wt" "$repo" > "$meta"
  write_merge_marker "$state" merged github github.com o/r 7
  accept_done ship direct-PR "$wt" "$repo" "done: PR https://github.com/o/r/pull/7" "$state" merged "$meta" \
    || fail "recorded merged PR was refused after its remote-tracking ref was pruned"
  pass "a recorded merged PR satisfies the gate after prune"
}

test_merge_marker_binds_to_the_named_pr() {
  local repo wt meta state reason rc sha
  repo="$TMP_ROOT/bind-repo"
  wt="$TMP_ROOT/bind-wt"
  state="$TMP_ROOT/bind-state"
  mkdir -p "$state"
  fm_git_worktree "$repo" "$wt" fm/bind
  git -C "$wt" commit -q --allow-empty -m 'second PR head, never pushed'
  sha=$(git -C "$wt" rev-parse HEAD)
  meta="$state/bind.meta"
  printf 'kind=ship\nmode=direct-PR\nworktree=%s\nproject=%s\npr=https://github.com/o/r/pull/7\n' \
    "$wt" "$repo" > "$meta"
  write_merge_marker "$state" bind github github.com o/r 7
  reason=$(accept_done ship direct-PR "$wt" "$repo" "done: PR https://github.com/o/r/pull/9" "$state" bind "$meta")
  rc=$?
  [ "$rc" -eq 1 ] || fail "merge of recorded PR 7 accepted an unpushed done naming PR 9"
  case "$reason" in
    *"named head $sha is unreachable outside the worker copy"*) ;;
    *) fail "PR 9 refusal did not name the unpushed head: $reason" ;;
  esac
  write_merge_marker "$state" bind github github.com other/r 7
  accept_done ship direct-PR "$wt" "$repo" "done: PR https://github.com/o/r/pull/7" "$state" bind "$meta" >/dev/null \
    && fail "merge marker for another repository's PR 7 was accepted"
  pass "the merged-PR short-circuit applies only to the recorded PR the done line names"
}

test_forge_recorded_head_is_accepted_without_local_object() {
  local repo wt meta state forge_head
  repo="$TMP_ROOT/forge-repo"
  wt="$TMP_ROOT/forge-wt"
  state="$TMP_ROOT/forge-state"
  mkdir -p "$state"
  fm_git_worktree "$repo" "$wt" fm/forge
  git -C "$wt" commit -q --allow-empty -m 'worker head, not pushed from this copy'
  # The pipeline's own commit: on the forge and in the gate repo, never
  # fetched into the worker clone.
  forge_head=0123456789abcdef0123456789abcdef01234567
  meta="$state/forge.meta"
  printf 'kind=ship\nmode=no-mistakes\nworktree=%s\nproject=%s\npr=https://github.com/o/r/pull/5\npr_head=%s\n' \
    "$wt" "$repo" "$forge_head" > "$meta"
  accept_done ship no-mistakes "$wt" "$repo" "done: PR https://github.com/o/r/pull/5 checks green" \
    "$state" forge "$meta" \
    || fail "forge-recorded pr_head the worker clone never fetched was refused"
  accept_done ship no-mistakes "$wt" "$repo" "done: PR https://github.com/o/r/pull/6 checks green" \
    "$state" forge "$meta" >/dev/null \
    && fail "pr_head recorded for PR 5 was accepted for a done naming PR 6"
  pass "a forge-recorded head for the named PR is accepted without a local object"
}

# A direct-PR worker pushes from its own copy: a commit made after the PR's
# recorded head, never pushed, is the named head and is refused.
test_direct_pr_recorded_head_does_not_cover_unpushed_commit() {
  local repo wt meta state pushed later reason rc
  repo="$TMP_ROOT/postopen-repo"
  wt="$TMP_ROOT/postopen-wt"
  state="$TMP_ROOT/postopen-state"
  mkdir -p "$state"
  fm_git_worktree "$repo" "$wt" fm/postopen
  git -C "$wt" commit -q --allow-empty -m 'pushed when the PR opened'
  pushed=$(git -C "$wt" rev-parse HEAD)
  git -C "$wt" update-ref refs/remotes/origin/fm/postopen "$pushed"
  git -C "$wt" commit -q --allow-empty -m 'the fix, only in the worktree'
  later=$(git -C "$wt" rev-parse HEAD)
  meta="$state/postopen.meta"
  printf 'kind=ship\nmode=direct-PR\nworktree=%s\nproject=%s\npr=https://github.com/o/r/pull/5\npr_head=%s\n' \
    "$wt" "$repo" "$pushed" > "$meta"
  reason=$(accept_done ship direct-PR "$wt" "$repo" "done: PR https://github.com/o/r/pull/5" "$state" postopen "$meta")
  rc=$?
  [ "$rc" -eq 1 ] || fail "direct-PR recorded pr_head accepted an unpushed later commit"
  case "$reason" in
    *"named head $later is unreachable outside the worker copy"*) ;;
    *) fail "direct-PR refusal did not name the unpushed commit: $reason" ;;
  esac
  pass "a direct-PR recorded head does not cover a later unpushed commit"
}

test_ci_ready_variants_are_gated() {
  local repo wt line rc
  repo="$TMP_ROOT/variant-repo"
  wt="$TMP_ROOT/variant-wt"
  fm_git_worktree "$repo" "$wt" fm/variant
  git -C "$wt" commit -q --allow-empty -m 'only in the disposable copy'
  for line in \
    'done: PR https://github.com/o/r/pull/5 checks green, risk low' \
    'done: PR https://github.com/o/r/pull/5 - checks green' \
    'done: PR https://github.com/o/r/pull/5 checks green.' \
    'done: PR https://github.com/o/r/pull/5 (checks green)'; do
    rc=0
    accept_done ship no-mistakes "$wt" "$repo" "$line" >/dev/null || rc=$?
    [ "$rc" -eq 1 ] || fail "no-mistakes CI-ready variant skipped the gate: $line"
  done
  pass "no-mistakes CI-ready done: with extra text is gated"
}

test_keyed_and_spaced_done_lines_are_gated() {
  local repo wt line mode rc
  repo="$TMP_ROOT/keyed-repo"
  wt="$TMP_ROOT/keyed-wt"
  fm_git_worktree "$repo" "$wt" fm/keyed
  git -C "$wt" commit -q --allow-empty -m 'only in the disposable copy'
  for line in \
    'no-mistakes|done [key=fix]: PR https://github.com/o/r/pull/5 checks green' \
    'no-mistakes|done : PR https://github.com/o/r/pull/5 checks green' \
    'direct-PR|done [key=fix]: PR https://github.com/o/r/pull/5' \
    'direct-PR|done: [key=fix] PR https://github.com/o/r/pull/5'; do
    mode=${line%%|*}
    rc=0
    accept_done ship "$mode" "$wt" "$repo" "${line#*|}" >/dev/null || rc=$?
    [ "$rc" -eq 1 ] || fail "$mode done line skipped the gate: ${line#*|}"
  done
  pass "keyed and spaced ship done: lines are gated"
}

test_non_done_lines_are_not_gated() {
  local repo wt
  repo="$TMP_ROOT/nongate-repo"
  wt="$TMP_ROOT/nongate-wt"
  fm_git_worktree "$repo" "$wt" fm/nongate
  git -C "$wt" commit -q --allow-empty -m 'unpushed'
  accept_done ship no-mistakes "$wt" "$repo" 'working: still implementing' \
    || fail "working: line was gated"
  accept_done ship no-mistakes "$wt" "$repo" 'blocked: waiting on a credential' \
    || fail "blocked: line was gated"
  pass "non-done lines are not gated"
}

# Issue 3608: a legacy `# Task` body's provenance marker must be read the way
# bin/fm-brief-heading-lib.sh reads headings - outside fenced blocks and never
# from an indented example - or a fenced `Captain:` sample becomes the ship
# contract's intent while the real ask is dropped.
test_fenced_and_indented_captain_lines_are_not_intent() {
  local home id meta out status words
  home="$TMP_ROOT/fenced-home"
  mkdir -p "$home/state" "$home/data"
  words=$(fm_brief_marked_captain_words 'Investigate the promotion gate.

```markdown
Captain: This fenced example must not become intent.
[captain] Neither must this one.
```

~~~
Captain: Nor this tilde-fenced one.
~~~

    Captain: An indented example is not the ask either.
	[captain] Nor a tab-indented one.
Keep this Firstmate constraint out of captain intent.')
  assert_equals "" "$words" "fenced or indented Captain lines were extracted as authorized intent"

  words=$(fm_brief_marked_captain_words '```
Captain: fenced example
```
  [captain] Preserve the real ask after the fence closes.
````
Captain: a longer fence that a shorter closer must not end
```
Captain: still fenced
````')
  assert_equals "Preserve the real ask after the fence closes." "$words" \
    "the marker after a closed fence, or inside a longer fence, was misread"

  id=promote-fenced-captain
  meta="$home/state/$id.meta"
  printf 'window=fm-%s\nkind=scout\nworktree=/tmp/wt\n' "$id" > "$meta"
  mkdir -p "$home/data/$id"
  cat > "$home/data/$id/brief.md" <<'EOF'
# Task
Investigate the promotion gate.

```markdown
Captain: This fenced example must not become intent.
```

    Captain: An indented example is not the ask either.

# Setup
This is a SCOUT task: the deliverable is a written report, not a PR.
EOF
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$ROOT/bin/fm-promote.sh" "$id" --mode direct-PR --yolo off 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "promotion whose only Captain lines are fenced or indented examples should fail"
  assert_contains "$out" "has no provenance-marked Captain's intent" \
    "fenced-example promotion did not refuse like an unmarked legacy brief"
  assert_absent "$home/data/$id/ship-instructions.md" \
    "fenced-example promotion published a fenced sample as captain intent"
  assert_grep 'kind=scout' "$meta" "fenced-example promotion changed the task record"
  pass "fenced and indented Captain lines are not authorized intent"
}

# The draft check the DoD hands a worker must be the gh-axi path that rule 3 of
# every ship brief requires for GitHub operations, never raw gh (issue 5325).
test_pr_based_dod_draft_check_uses_gh_axi() {
  local mode out
  for mode in direct-PR no-mistakes; do
    out="$TMP_ROOT/dod-$mode.md"
    fm_dod_block "$mode" dod-draft-task > "$out"
    assert_no_grep 'gh pr view' "$out" "$mode: DoD must not document a raw gh draft check"
    # shellcheck disable=SC2016  # single quotes are deliberate: the backticks must stay literal
    assert_grep 'confirm it is not a draft (`gh-axi pr view <PR URL>` must print `draft: no`' "$out" \
      "$mode: DoD must read the draft state through gh-axi"
  done
  pass "PR-based DoD draft check uses gh-axi"
}

# A scout spawned on a named base keeps that base through promotion: the ship
# instructions start from it and the PR targets it; local-only cannot carry it.
test_promotion_keeps_the_recorded_base_branch() {
  local home id meta out status mode
  home="$TMP_ROOT/promote-base-home"
  for mode in direct-PR local-only; do
    id="promote-base-$mode"
    meta="$home/state/$id.meta"
    mkdir -p "$home/state" "$home/data/$id"
    printf 'window=fm-%s\nkind=scout\nworktree=/tmp/wt\nbase_branch=feature/hub\n' "$id" > "$meta"
    cat > "$home/data/$id/brief.md" <<'EOF'
# Task
## Captain's intent
Fix the hub bug.

## Firstmate spec
Reproduce it first.

# Setup
You are in a disposable git worktree of proj, at a detached HEAD on a clean copy of its base branch.
Base branch: feature/hub
EOF
    out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$ROOT/bin/fm-promote.sh" "$id" --mode "$mode" --yolo off 2>&1)
    status=$?
    if [ "$mode" = direct-PR ]; then
      expect_code 0 "$status" "promoting a scout with a recorded base should succeed"$'\n'"$out"
      # shellcheck disable=SC2016  # literal backticks in rendered prose must stay unexpanded
      assert_grep 'Return to a clean copy of the base branch `feature/hub`' "$home/data/$id/ship-instructions.md" \
        "promotion did not start the ship from the recorded base"
      # shellcheck disable=SC2016
      assert_grep 'against the base branch `feature/hub`' "$home/data/$id/ship-instructions.md" \
        "promotion did not target the PR at the recorded base"
      assert_grep 'base_branch=feature/hub' "$meta" "promotion dropped the recorded base"
    else
      [ "$status" -ne 0 ] || fail "promoting a based scout to local-only should be refused"
      assert_contains "$out" "mode=local-only" "the local-only promotion refusal did not explain itself"
      assert_grep 'kind=scout' "$meta" "a refused promotion changed the task record"
    fi
  done
  pass "promotion keeps a scout's recorded base branch and refuses local-only for it"
}

# --- direct-PR origin binding (fork-target regression) ----------------------
#
# `gh pr create` with no `-R` defaults to a fork's PARENT repository, so a
# direct-PR worker in a fork clone can open its PR on a repository nobody
# authorized. These fixtures give the copy a real, fetchable remote under a
# neutral name - so the named-head reachability test still has something to
# find - and set `origin` (and, for a fork, `upstream`) to the forge URLs that
# decide the target.
fork_layout() {  # <name> <origin-url> [<upstream-url>]
  local name=$1 origin=$2 upstream=${3:-} repo wt
  repo="$TMP_ROOT/$name-repo"
  wt="$TMP_ROOT/$name-wt"
  fm_git_init_commit "$repo"
  fm_git_add_origin "$repo" "$repo.serve.git"
  git -C "$repo" remote rename origin serve
  git -C "$repo" remote add origin "$origin"
  [ -z "$upstream" ] || git -C "$repo" remote add upstream "$upstream"
  git -C "$repo" worktree add --quiet -b "fm/$name" "$wt"
  git -C "$repo" push --quiet serve "fm/$name"
  git -C "$repo" fetch --quiet serve
  printf '%s\n' "$wt"
}

test_direct_pr_on_the_fork_parent_is_refused() {
  local wt reason rc
  wt=$(fork_layout forkparent \
    'git@github.com:forkowner/proj.git' 'git@github.com:parentowner/proj.git')
  reason=$(accept_done ship direct-PR "$wt" "$TMP_ROOT/forkparent-repo" \
    'done: PR https://github.com/parentowner/proj/pull/5')
  rc=$?
  [ "$rc" -eq 1 ] || fail "a direct-PR done on the fork's parent repository was accepted (exit $rc)"
  case "$reason" in
    *"github.com/parentowner/proj"*"github.com/forkowner/proj"*) ;;
    *) fail "the refusal did not name the PR's repository and origin: $reason" ;;
  esac
  case "$reason" in
    *"-R forkowner/proj"*) ;;
    *) fail "the refusal did not name the origin target to open it on: $reason" ;;
  esac
  case "$reason" in
    *"wrong repository"*"renamed or transferred"*"git remote set-url origin"*) ;;
    *) fail "the refusal did not name both causes and the stale-origin remedy: $reason" ;;
  esac
  pass "a direct-PR PR on the fork's parent repository is refused"
}

test_direct_pr_on_origin_fork_is_accepted() {
  local wt
  wt=$(fork_layout forkorigin \
    'git@github.com:forkowner/proj.git' 'git@github.com:parentowner/proj.git')
  accept_done ship direct-PR "$wt" "$TMP_ROOT/forkorigin-repo" \
    'done: PR https://github.com/forkowner/proj/pull/5' \
    || fail "a direct-PR done on the fork clone's own origin was refused"
  accept_done ship direct-PR "$wt" "$TMP_ROOT/forkorigin-repo" \
    'done: PR https://github.com/ForkOwner/Proj/pull/5' \
    || fail "a case difference against origin was treated as another repository"
  pass "a direct-PR PR on the fork's own origin is accepted"
}

test_direct_pr_plain_clone_is_bound_to_its_own_repository() {
  local wt reason rc
  wt=$(fork_layout plainclone 'https://github.com/soleowner/proj.git')
  accept_done ship direct-PR "$wt" "$TMP_ROOT/plainclone-repo" \
    'done: PR https://github.com/soleowner/proj/pull/12' \
    || fail "a plain clone's direct-PR done on its own origin was refused"
  reason=$(accept_done ship direct-PR "$wt" "$TMP_ROOT/plainclone-repo" \
    'done: PR https://github.com/someoneelse/proj/pull/12')
  rc=$?
  [ "$rc" -eq 1 ] || fail "a plain clone accepted a PR on another repository (exit $rc)"
  case "$reason" in
    *"github.com/someoneelse/proj"*) ;;
    *) fail "the refusal did not name the foreign repository: $reason" ;;
  esac
  pass "a plain clone's direct-PR PR is bound to its own origin"
}

# An origin reached through an SSH host alias or GitHub's port-443 SSH endpoint
# names a host that never matches github.com in the PR URL; the owner/repository
# path is what identifies the repository, so its own PR is accepted while a PR
# on the fork's parent is still refused.
test_direct_pr_origin_through_an_ssh_alias_is_accepted() {
  local wt reason rc origin name i=0
  for origin in 'git@github-443:forkowner/proj.git' \
    'ssh://git@ssh.github.com:443/forkowner/proj.git'; do
    i=$((i + 1))
    name=sshalias$i
    wt=$(fork_layout "$name" "$origin" 'git@github.com:parentowner/proj.git')
    accept_done ship direct-PR "$wt" "$TMP_ROOT/$name-repo" \
      'done: PR https://github.com/forkowner/proj/pull/5' \
      || fail "a direct-PR done on its own origin via $origin was refused"
    reason=$(accept_done ship direct-PR "$wt" "$TMP_ROOT/$name-repo" \
      'done: PR https://github.com/parentowner/proj/pull/5')
    rc=$?
    [ "$rc" -eq 1 ] || fail "a fork-parent PR was accepted for origin $origin (exit $rc)"
    case "$reason" in
      *"-R forkowner/proj"*) ;;
      *) fail "the refusal for origin $origin did not name the origin target: $reason" ;;
    esac
  done
  pass "a direct-PR origin through an SSH alias accepts its own PR only"
}

# The repository check runs before every acceptance path, so a wrong-repository
# PR cannot be admitted by the recorded pr=/pr_head= short-circuit either - that
# is the path bin/fm-pr-check.sh would otherwise register it through.
test_wrong_repository_is_refused_before_the_recorded_pr_path() {
  local wt state meta head reason rc
  wt=$(fork_layout recordedforeign \
    'git@github.com:forkowner/proj.git' 'git@github.com:parentowner/proj.git')
  state="$TMP_ROOT/recordedforeign-state"
  mkdir -p "$state"
  meta="$state/recordedforeign.meta"
  head=$(git -C "$wt" rev-parse HEAD)
  printf 'kind=ship\nmode=direct-PR\npr=https://github.com/parentowner/proj/pull/5\npr_head=%s\n' \
    "$head" > "$meta"
  reason=$(accept_done ship direct-PR "$wt" "$TMP_ROOT/recordedforeign-repo" \
    'done: PR https://github.com/parentowner/proj/pull/5' "$state" recordedforeign "$meta")
  rc=$?
  [ "$rc" -eq 1 ] || fail "a recorded pr= on another repository was accepted (exit $rc)"
  case "$reason" in
    *"not this copy's origin"*) ;;
    *) fail "the refusal did not report the origin mismatch: $reason" ;;
  esac
  pass "a wrong-repository PR is refused before the recorded-PR path"
}

# origin is checked only where it decides the target. A no-mistakes PR is
# published by the pipeline's own configured push target rather than by this
# copy, and an origin URL that names no forge is no proof either way.
test_origin_binding_is_scoped_to_direct_pr_and_forge_origins() {
  local wt repo
  wt=$(fork_layout scopecheck 'git@github.com:forkowner/proj.git')
  accept_done ship no-mistakes "$wt" "$TMP_ROOT/scopecheck-repo" \
    'done: PR https://github.com/pipelinetarget/proj/pull/3 checks green' \
    || fail "the origin binding refused a no-mistakes PR, whose push target is the pipeline's"
  repo="$TMP_ROOT/localorigin-repo"
  fm_git_worktree "$repo" "$TMP_ROOT/localorigin-wt" fm/localorigin
  git -C "$repo" push --quiet origin fm/localorigin
  git -C "$repo" fetch --quiet origin
  accept_done ship direct-PR "$TMP_ROOT/localorigin-wt" "$repo" \
    'done: PR https://github.com/o/r/pull/7' \
    || fail "a file:// origin, which names no forge, was treated as a mismatch"
  pass "the origin binding covers direct-PR forge origins only"
}

# A pooled-worktree layout exactly as the clones that exposed this gate have it:
# a bare origin, a project clone whose remote.origin.fetch names only the
# default branch, and a worktree sharing that clone's .git/config. No task
# branch ever grows a remote-tracking ref in such a clone, so the local-ref test
# alone cannot see a correctly pushed head. Builds <TMP_ROOT>/<name>-origin.git,
# <TMP_ROOT>/<name>-project and <TMP_ROOT>/<name>-wt on <branch>.
narrowed_layout() {  # <name> <branch>
  local name=$1 branch=$2 origin
  origin="$TMP_ROOT/$name-origin.git"
  fm_git_init_commit "$TMP_ROOT/$name-seed"
  git clone --quiet --bare "$TMP_ROOT/$name-seed" "$origin"
  git clone --quiet "file://$(cd "$origin" && pwd)" "$TMP_ROOT/$name-project"
  git -C "$TMP_ROOT/$name-project" config remote.origin.fetch \
    '+refs/heads/main:refs/remotes/origin/main'
  git -C "$TMP_ROOT/$name-project" worktree add --quiet -b "$branch" "$TMP_ROOT/$name-wt"
}

# An ssh transport that never answers, as a script so git's own argument
# appending cannot turn it back into a fast failure. Prints its path.
stalling_ssh() {  # <name>
  local path="$TMP_ROOT/$1-stall-ssh"
  printf '%s\n' '#!/bin/sh' 'sleep 120' > "$path"
  chmod 700 "$path"
  printf '%s\n' "$path"
}

# The whole observable state of a clone the gate must not touch: its stored
# configuration and every ref it holds.
clone_fingerprint() {  # <repo>
  cat "$1/.git/config"
  git -C "$1" for-each-ref --format='%(refname) %(objectname)'
}

test_narrowed_fetch_refspec_accepts_the_pushed_head() {
  local project wt sha before after
  narrowed_layout narrowed fm/narrowed
  project="$TMP_ROOT/narrowed-project"
  wt="$TMP_ROOT/narrowed-wt"
  git -C "$wt" commit -q --allow-empty -m 'the fix, pushed to origin'
  sha=$(git -C "$wt" rev-parse HEAD)
  git -C "$wt" push --quiet origin fm/narrowed
  git -C "$wt" for-each-ref --format='%(refname)' refs/remotes | grep -q 'fm/narrowed' \
    && fail "fixture is not narrowed: the push left a remote-tracking ref"
  before=$(clone_fingerprint "$project")
  accept_done ship direct-PR "$wt" "$project" 'done: PR https://github.com/o/r/pull/1' \
    || fail "a head pushed to origin was refused because the clone's fetch refspec is narrowed"
  after=$(clone_fingerprint "$project")
  [ "$before" = "$after" ] \
    || fail "the gate changed the shared clone's configuration or refs"
  pass "a pushed head is accepted through a narrowed remote.origin.fetch"
}

test_narrowed_fetch_refspec_still_refuses_an_unpushed_head() {
  local project wt sha reason rc before after
  narrowed_layout unpushed-narrowed fm/unpushed-narrowed
  project="$TMP_ROOT/unpushed-narrowed-project"
  wt="$TMP_ROOT/unpushed-narrowed-wt"
  git -C "$wt" commit -q --allow-empty -m 'pushed'
  git -C "$wt" push --quiet origin fm/unpushed-narrowed
  git -C "$wt" commit -q --allow-empty -m 'the fix, never pushed'
  sha=$(git -C "$wt" rev-parse HEAD)
  before=$(clone_fingerprint "$project")
  reason=$(accept_done ship direct-PR "$wt" "$project" 'done: PR https://github.com/o/r/pull/1')
  rc=$?
  after=$(clone_fingerprint "$project")
  [ "$rc" -eq 1 ] || fail "a head origin never received was accepted (exit $rc)"
  case "$reason" in
    *"named head $sha is unreachable outside the worker copy"*) ;;
    *) fail "the refusal did not name the unpushed commit: $reason" ;;
  esac
  case "$reason" in
    *"never change remote.origin.fetch"*"git fetch origin <branch>:refs/remotes/origin/<branch>"*) ;;
    *) fail "the refusal did not steer the worker off remote.origin.fetch: $reason" ;;
  esac
  [ "$before" = "$after" ] || fail "a refusing gate changed the shared clone"
  pass "a head origin never received is still refused, with safe-ref guidance"
}

test_hostile_remote_ref_name_is_not_executed() {
  local project wt sha marker
  narrowed_layout hostile fm/hostile
  project="$TMP_ROOT/hostile-project"
  wt="$TMP_ROOT/hostile-wt"
  marker="$TMP_ROOT/hostile-marker"
  git -C "$wt" commit -q --allow-empty -m 'the fix, pushed to origin'
  sha=$(git -C "$wt" rev-parse HEAD)
  git -C "$wt" push --quiet origin fm/hostile
  # git accepts a branch name that reads like a command substitution, and the
  # gate reads whatever the remote advertises: that listing must stay data
  # through every step that parses it.
  git -C "$TMP_ROOT/hostile-origin.git" update-ref \
    "refs/heads/x\$(touch\${IFS}$marker)y" "$sha"
  accept_done ship direct-PR "$wt" "$project" 'done: PR https://github.com/o/r/pull/8' \
    || fail "a pushed head was refused because another ref name looked hostile"
  [ ! -e "$marker" ] || fail "a remote ref name was executed by the gate"
  pass "a hostile remote ref name is read as data, not run"
}

test_unreadable_origin_keeps_the_refusal() {
  local project wt sha reason rc
  narrowed_layout unreadable fm/unreadable
  project="$TMP_ROOT/unreadable-project"
  wt="$TMP_ROOT/unreadable-wt"
  git -C "$wt" commit -q --allow-empty -m 'pushed, but origin cannot be read back'
  sha=$(git -C "$wt" rev-parse HEAD)
  git -C "$wt" push --quiet origin fm/unreadable
  git -C "$project" remote set-url origin "file://$TMP_ROOT/unreadable-origin.git.gone"
  reason=$(accept_done ship direct-PR "$wt" "$project" 'done: PR https://github.com/o/r/pull/3')
  rc=$?
  [ "$rc" -eq 1 ] || fail "an unreadable origin accepted a head on no evidence (exit $rc)"
  case "$reason" in
    *"named head $sha is unreachable outside the worker copy"*) ;;
    *) fail "the unreadable-origin refusal did not name the head: $reason" ;;
  esac
  pass "an origin that cannot be read keeps the refusal rather than accepting"
}

test_origin_read_is_bounded() {
  local project wt rc started elapsed prior
  narrowed_layout stalled fm/stalled
  project="$TMP_ROOT/stalled-project"
  wt="$TMP_ROOT/stalled-wt"
  git -C "$wt" commit -q --allow-empty -m 'unreadable because origin never answers'
  # An ssh origin whose transport never returns: the read must be cut off by the
  # gate's own bound, not left to hang the supervisor that called it.
  git -C "$project" remote set-url origin 'ssh://git@stall.invalid/o/r.git'
  prior=$FM_DOD_ORIGIN_READ_SECONDS
  GIT_SSH_COMMAND=$(stalling_ssh stalled)
  export GIT_SSH_COMMAND
  FM_DOD_ORIGIN_READ_SECONDS=3
  started=$SECONDS
  accept_done ship direct-PR "$wt" "$project" 'done: PR https://github.com/o/r/pull/4' >/dev/null
  rc=$?
  elapsed=$((SECONDS - started))
  FM_DOD_ORIGIN_READ_SECONDS=$prior
  unset GIT_SSH_COMMAND
  [ "$rc" -eq 1 ] || fail "a stalled origin read did not refuse (exit $rc)"
  [ "$elapsed" -lt 60 ] || fail "the origin read was not bounded: ${elapsed}s"
  pass "a stalled origin read is cut off by the gate's bound"
}

test_local_only_does_not_read_origin() {
  local project wt started elapsed prior
  narrowed_layout localonly fm/localonly
  project="$TMP_ROOT/localonly-project"
  wt="$TMP_ROOT/localonly-wt"
  git -C "$wt" commit -q --allow-empty -m 'local-only work on a linked branch'
  git -C "$project" remote set-url origin 'ssh://git@stall.invalid/o/r.git'
  prior=$FM_DOD_ORIGIN_READ_SECONDS
  GIT_SSH_COMMAND=$(stalling_ssh localonly)
  export GIT_SSH_COMMAND
  FM_DOD_ORIGIN_READ_SECONDS=120
  started=$SECONDS
  accept_done ship local-only "$wt" "$project" 'done: ready in branch fm/localonly' \
    || fail "local-only lost its project-heads rule"
  elapsed=$((SECONDS - started))
  FM_DOD_ORIGIN_READ_SECONDS=$prior
  unset GIT_SSH_COMMAND
  [ "$elapsed" -lt 30 ] || fail "local-only reached the remote: ${elapsed}s"
  pass "local-only keeps its project-heads rule and reads no remote"
}

test_scout_done_is_not_gated
test_unpushed_ship_done_is_refused
test_no_mistakes_done_without_a_pr_is_refused
test_no_mistakes_ci_ready_done_passes_the_pr_check
test_remote_containing_named_head_is_accepted
test_moved_branch_without_named_head_is_refused
test_free_text_sha_is_not_the_named_head
test_recorded_merged_pr_is_landed_after_prune
test_merge_marker_binds_to_the_named_pr
test_forge_recorded_head_is_accepted_without_local_object
test_direct_pr_recorded_head_does_not_cover_unpushed_commit
test_ci_ready_variants_are_gated
test_keyed_and_spaced_done_lines_are_gated
test_local_only_linked_branch_is_accepted
test_local_only_detached_head_is_refused
test_standalone_local_only_needs_project_ref
test_non_done_lines_are_not_gated
test_fenced_and_indented_captain_lines_are_not_intent
test_pr_based_dod_draft_check_uses_gh_axi
test_promotion_keeps_the_recorded_base_branch

# Four Claude ship workers on 2026-10-07 committed locally and reported done
# without running the pipeline, because the generated contract told them to: it
# called that first done the handoff and had firstmate send /no-mistakes. The
# no-mistakes DoD must now send the worker straight from its implementation
# commit into the pipeline and leave no sentence that invites a done before it.
test_no_mistakes_dod_sends_the_worker_into_the_pipeline_itself() {
  local forge out
  for forge in none gerrit; do
    out="$TMP_ROOT/dod-nm-$forge.md"
    fm_dod_block no-mistakes dod-nm-task fm/dod-nm-task "$forge" > "$out"
    assert_grep 'invoke /no-mistakes yourself and drive the run to its outcome' "$out" \
      "$forge: DoD did not have the worker start the pipeline itself"
    assert_grep 'do not report done first, and do not wait for firstmate to send you the pipeline' "$out" \
      "$forge: DoD did not forbid reporting done before the pipeline"
    assert_no_grep 'Firstmate will then instruct you to run /no-mistakes' "$out" \
      "$forge: DoD still hands the pipeline back to firstmate"
    assert_no_grep 'handoff that starts the pipeline' "$out" \
      "$forge: DoD still describes a pre-pipeline done as a handoff"
    # shellcheck disable=SC2016  # the backticked placeholder must stay literal
    assert_no_grep 'append `done \[at=<epoch>\]: {summary}`' "$out" \
      "$forge: DoD still asks for a summary-only done"
  done
  # shellcheck disable=SC2016  # the backticked ready line must stay literal
  assert_grep 'Your only `done:` is the CI-ready line below' "$TMP_ROOT/dod-nm-none.md" \
    "the PR DoD did not pin the CI-ready line as the only done"
  # shellcheck disable=SC2016  # the backticked ready line must stay literal
  assert_grep 'Your only `done:` is the published-for-review line below' "$TMP_ROOT/dod-nm-gerrit.md" \
    "the Gerrit DoD did not pin the published-for-review line as the only done"
  pass "the no-mistakes DoD runs the pipeline from the implementation commit"
}
test_no_mistakes_dod_sends_the_worker_into_the_pipeline_itself

# The launch role is the generated text a worker receives. It must keep the
# skill name, so a session that registers the skill loads it by name, and must
# name the skill file as the fallback for a session where the name does not
# resolve.
test_worker_role_names_skill_and_fallback_file() {
  local role_file path
  role_file="$TMP_ROOT/worker-role.txt"
  path="$ROOT/.agents/skills/firstmate-coding-guidelines/SKILL.md"
  [ -f "$path" ] || fail "Firstmate skill file is missing at $path"
  fm_brief_worker_role "$TMP_ROOT/state" upstream-4751 "$ROOT" >"$role_file"
  assert_grep "\`CONTRIBUTING.md\` and \`firstmate-coding-guidelines\` for Firstmate changes" "$role_file" \
    "worker role did not name the skill"
  assert_grep "If the \`firstmate-coding-guidelines\` skill name does not resolve in this session, read \`$path\` instead." "$role_file" \
    "worker role did not name the skill file as the fallback"
  assert_no_grep "Skill tool cannot resolve" "$role_file" \
    "worker role claims the Skill tool never resolves the skill"
  pass "worker role names the skill and its fallback skill file"
}

test_worker_role_names_skill_and_fallback_file
test_direct_pr_on_the_fork_parent_is_refused
test_direct_pr_on_origin_fork_is_accepted
test_direct_pr_plain_clone_is_bound_to_its_own_repository
test_wrong_repository_is_refused_before_the_recorded_pr_path
test_direct_pr_origin_through_an_ssh_alias_is_accepted
test_origin_binding_is_scoped_to_direct_pr_and_forge_origins
test_narrowed_fetch_refspec_accepts_the_pushed_head
test_narrowed_fetch_refspec_still_refuses_an_unpushed_head
test_hostile_remote_ref_name_is_not_executed
test_unreadable_origin_keeps_the_refusal
test_origin_read_is_bounded
test_local_only_does_not_read_origin

echo "all fm-dod-lib tests passed"
