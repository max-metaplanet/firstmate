# shellcheck shell=bash
# Shared "has this copy's committed work actually landed" test.
#
# ONE OWNER for that judgement. bin/fm-teardown.sh asks it before discarding a
# copy, and bin/fm-slot-release.sh asks it before letting one of two colliding
# records stop naming a copy the other record's cleanup will then reset. Both
# need the same answer for the same reason - work that is neither on a remote
# nor landed must never be destroyed - so the test lives here.
#
# The judgement is deliberately conservative in one direction only: every
# inconclusive read (no default ref, a merge conflict, a forge error, a missing
# commit object) returns "not landed", so the caller refuses rather than
# guesses. A diverged copy is not treated as landed: path-set coverage, git
# cherry, and merge-tree containment each fail to prove content landed without
# also accepting unlanded edits to the same paths.
#
# Callers pass the copy, its project, the branch, and any PR URL they already
# hold. The resolved PR URL comes back in FM_UNLANDED_PR_URL, because resolving
# a merged PR from a branch name is worth recording once rather than twice.

# shellcheck disable=SC2034 # Output global, read by the sourcing caller.
FM_UNLANDED_PR_URL=

# The project's default branch: origin/HEAD when the clone records one, else
# whichever of main or master exists locally.
fm_unlanded_default_branch() {  # <project>
  local project=$1 ref branch
  ref=$(git -C "$project" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -n "$ref" ]; then
    echo "${ref#origin/}"
    return 0
  fi
  for branch in main master; do
    if git -C "$project" show-ref --verify --quiet "refs/heads/$branch"; then
      echo "$branch"
      return 0
    fi
  done
  return 1
}

fm_unlanded_pr_number_from_target() {  # <pr-url-or-number>
  local target=$1 n
  case "$target" in
    '' ) return 1 ;;
    *"/pull/"*)
      n=${target##*/pull/}
      n=${n%%[!0-9]*}
      ;;
    [0-9]*)
      n=${target%%[!0-9]*}
      ;;
    *) return 1 ;;
  esac
  [ -n "$n" ] || return 1
  printf '%s' "$n"
}

# Resolve the PR number for a branch via gh-axi. Echoes the number on a single
# match and returns 0; returns non-zero on no match or any lookup failure, so
# the caller treats it as "no PR found" (fail-safe).
fm_unlanded_pr_number_from_branch() {  # <copy> <branch>
  local copy=$1 branch=$2 out n
  [ -n "$branch" ] && [ "$branch" != HEAD ] || return 1
  out=$( cd "$copy" && gh-axi pr list --state all --head "$branch" --limit 1 2>/dev/null ) || return 1
  n=$(printf '%s\n' "$out" | sed -n 's/^[[:space:]]*\([0-9][0-9]*\),.*/\1/p' | head -1)
  [ -n "$n" ] || return 1
  printf '%s' "$n"
}

fm_unlanded_ensure_commit_object() {  # <copy> <pr-target> <commit>
  local copy=$1 target=$2 commit=$3 n
  git -C "$copy" cat-file -e "$commit^{commit}" 2>/dev/null && return 0
  n=$(fm_unlanded_pr_number_from_target "$target") || return 1
  git -C "$copy" remote get-url origin >/dev/null 2>&1 || return 1
  git -C "$copy" fetch --quiet origin "refs/pull/$n/head" >/dev/null 2>&1 || return 1
  git -C "$copy" cat-file -e "$commit^{commit}" 2>/dev/null
}

fm_unlanded_patch_id() {  # <copy> <commit>
  local copy=$1 commit=$2
  git -C "$copy" show --pretty=medium --no-ext-diff "$commit" 2>/dev/null \
    | git patch-id --stable 2>/dev/null \
    | awk 'NR == 1 { print $1 }'
}

# Is every commit the copy holds off its remotes already present, by patch id,
# in the PR head? That is what makes a squash- or rebase-merged PR provable.
fm_unlanded_patches_are_in_pr_head() {  # <copy> <pr-head>
  local copy=$1 pr_head=$2 current base pr_patch_ids commit patch_id unpushed
  current=$(git -C "$copy" rev-parse --verify HEAD 2>/dev/null) || return 1
  base=$(git -C "$copy" merge-base "$current" "$pr_head" 2>/dev/null) || return 1
  pr_patch_ids=$(
    git -C "$copy" log --format=%H "$base..$pr_head" -- 2>/dev/null \
      | while IFS= read -r commit; do
          fm_unlanded_patch_id "$copy" "$commit"
        done \
      | sed '/^$/d' \
      | sort -u
  ) || return 1
  [ -n "$pr_patch_ids" ] || return 1
  unpushed=$(git -C "$copy" log --format=%H HEAD --not --remotes -- 2>/dev/null) || return 1
  [ -n "$unpushed" ] || return 1
  while IFS= read -r commit; do
    [ -n "$commit" ] || continue
    patch_id=$(fm_unlanded_patch_id "$copy" "$commit") || return 1
    [ -n "$patch_id" ] || return 1
    printf '%s\n' "$pr_patch_ids" | grep -qxF "$patch_id" || return 1
  done <<EOF
$unpushed
EOF
}

# Is the copy's PR merged for local work contained in that PR? Resolves the PR
# from the recorded URL first, then from the branch name, and asks the forge for
# both the PR state and head. Returns non-zero when the PR is not merged, the
# current work is not contained in the PR head, no PR is found, or any gh error
# occurs - the caller then falls back to the content check. On success the
# resolved URL is in FM_UNLANDED_PR_URL.
fm_unlanded_pr_is_merged() {  # <copy> <branch> <pr-url>
  local copy=$1 branch=$2 pr_url=$3
  local target view state remainder head resolved_url current landed=0
  if [ -n "$pr_url" ]; then
    target=$pr_url
  else
    target=$(fm_unlanded_pr_number_from_branch "$copy" "$branch") || return 1
  fi
  [ -n "$target" ] || return 1
  view=$(cd "$copy" && gh pr view "$target" --json state,headRefOid,url -q '.state + "\t" + .headRefOid + "\t" + .url' 2>/dev/null) || return 1
  state=${view%%$'\t'*}
  remainder=${view#*$'\t'}
  [ "$state" != "$view" ] || return 1
  head=${remainder%%$'\t'*}
  resolved_url=${remainder#*$'\t'}
  [ "$head" != "$remainder" ] || return 1
  case "$state" in
    MERGED|merged) ;;
    *) return 1 ;;
  esac
  [ -n "$head" ] || return 1
  fm_unlanded_ensure_commit_object "$copy" "$target" "$head" || return 1
  current=$(git -C "$copy" rev-parse --verify HEAD 2>/dev/null) || return 1
  if git -C "$copy" merge-base --is-ancestor "$current" "$head" 2>/dev/null; then
    landed=1
  elif fm_unlanded_patches_are_in_pr_head "$copy" "$head"; then
    landed=1
  fi
  [ "$landed" = 1 ] || return 1
  if [ -z "$pr_url" ]; then
    [ -n "$resolved_url" ] || return 1
    FM_UNLANDED_PR_URL=$resolved_url
  fi
  return 0
}

# Is the branch's content already present in the up-to-date default branch?
# Fetches first, then 3-way merges the default branch with HEAD: when HEAD
# introduces nothing the default branch does not already contain (e.g. its
# change landed via squash) the merged tree equals the default branch's tree.
# This isolates branch-only changes, so unrelated commits the default branch
# gained past the merge-base do not count as "added". Returns non-zero when
# inconclusive (no default ref, or a merge conflict), so the caller refuses
# rather than guesses.
fm_unlanded_content_in_default() {  # <copy> <project>
  local copy=$1 project=$2 name ref default_tree merged_tree
  name=$(fm_unlanded_default_branch "$project") || return 1
  if git -C "$copy" remote get-url origin >/dev/null 2>&1; then
    git -C "$copy" fetch --quiet origin "+refs/heads/$name:refs/remotes/origin/$name" >/dev/null 2>&1 || return 1
    ref="refs/remotes/origin/$name"
  elif git -C "$copy" rev-parse --quiet --verify "refs/heads/$name" >/dev/null 2>&1; then
    ref="refs/heads/$name"
  else
    return 1
  fi
  default_tree=$(git -C "$copy" rev-parse --quiet --verify "$ref^{tree}" 2>/dev/null) || return 1
  [ -n "$default_tree" ] || return 1
  merged_tree=$(git -C "$copy" merge-tree --write-tree "$ref" HEAD 2>/dev/null) || return 1
  merged_tree=$(printf '%s\n' "$merged_tree" | head -1)
  [ "$merged_tree" = "$default_tree" ]
}

# Has the copy's committed work actually LANDED, though its commits are not
# reachable from any remote-tracking branch? True when a merged PR proves the
# current local work is contained in the PR head, OR the content is already in
# the default branch (fallback, which also covers the no-PR and gh-error paths).
# False only for genuinely unlanded work. FM_UNLANDED_PR_URL carries the PR URL
# the caller passed in, replaced by the resolved one when a branch lookup found
# it.
fm_unlanded_work_is_landed() {  # <copy> <project> <branch> <pr-url>
  local copy=$1 project=$2 branch=$3 pr_url=$4
  FM_UNLANDED_PR_URL=$pr_url
  fm_unlanded_pr_is_merged "$copy" "$branch" "$pr_url" && return 0
  fm_unlanded_content_in_default "$copy" "$project"
}
