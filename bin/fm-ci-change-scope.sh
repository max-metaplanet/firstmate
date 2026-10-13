#!/usr/bin/env bash
# fm-ci-change-scope.sh - classify a CI event's changed paths into job gates.
#
# Single owner of which changed paths .github/workflows/ci.yml may gate a job
# on. It prints GitHub step-output lines, so the workflow reads a verdict
# instead of re-spelling path globs per job:
#
#   behavior=true|false   run the behavior suites (portable lanes, Herdr, lint)
#   macos=true|false      run the stock macOS Bash snapshot job
#
# Usage:
#   bin/fm-ci-change-scope.sh            classify and print both gate outputs
#   bin/fm-ci-change-scope.sh --help     print this header
#
# Inputs, all optional and read from the environment:
#   FM_CI_EVENT               the GitHub event name (default: pull_request)
#   FM_CI_BASE_SHA            the pull request's base commit
#   FM_CI_HEAD_SHA            the pull request's head commit (default: HEAD)
#   FM_CI_CHANGED_PATHS_FILE  a newline-delimited path list, used instead of git
#
# It fails open toward coverage, never toward speed: an unknown event, a missing
# base commit, an unreadable diff, an empty change set, and any path outside the
# inert allowlists below all report true. A gate therefore turns off only when
# every changed path is provably outside the gated jobs' sources, which is why
# the allowlists are expressed as "inert" rather than as "relevant".
#
# The gates must stay job-level `if:` conditions. A workflow-level `paths:`
# filter never creates the workflow, so a check required by branch protection
# stays pending forever, while a job skipped by `if:` reports "skipped" and
# satisfies protection.
#
# macOS inert set: the stock-Bash job reads nothing but shell sources. It runs
# `bin/fm-lint.sh --list-files`, whose CI file set is `bin/*.sh bin/backends/*.sh
# tests/*.sh`, parses every one of those files with /bin/bash 3.2, and then runs
# six scripts under tests/. None of those six reads the repository's prose tree.
# So only bin/, tests/, and this workflow itself can change its verdict.
#
# Behavior inert set: tracked prose that no test reads. Most of docs/ qualifies,
# with named exceptions for the prose a test really does consume:
# docs/supervision-protocols/ (copied by tests/fm-cursor-primary.test.sh),
# docs/arm-pretool-check.md (read by tests/fm-arm-pretool-check.test.sh),
# docs/examples/ (copied by tests/fm-dispatch-resolve.test.sh and
# tests/fm-extension-binding.test.sh), and docs/configuration.md,
# docs/fm-test-portable-shards.md and docs/fm-test-isolation-proof.md (mapped to
# the pure-contract-unit family by bin/fm-test-run.sh's changed-file map).
# Only *.md under docs/ is inert, so every docs/ JSON stays behavior-relevant,
# including docs/documentation-audiences.json and docs/fm-test-isolation-proof.json.
# AGENTS.md, CLAUDE.md, CONTRIBUTING.md, .agents/, skills/ and .github/ are all
# behavior-relevant, matching the same changed-file map. .gitignore is
# behavior-relevant too: tests/fm-gitignore-config.test.sh runs check-ignore
# against the repository and copies its .gitignore into a scratch repo.
#
# The diff runs with --no-renames so a rename reports both its source and its
# destination. With rename detection on, git prints only the destination, and a
# file moved out of a path a test reads would be classified by where it landed.
#
# Adding a test that reads a prose path means adding that path to the exception
# list here. tests/fm-ci-change-scope.test.sh pins both verdicts, and ci.yml's
# docs-guard job keeps tests/fm-documentation-audiences.test.sh running on the
# docs-only path, because adding or removing any tracked prose file changes that
# suite's verdict through bin/fm-doc-audience-check.sh.
set -eu

case "${1:-}" in
  --help | -h)
    awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
    exit 0
    ;;
  '') ;;
  *)
    printf 'fm-ci-change-scope.sh: unknown argument: %s\n' "$1" >&2
    exit 2
    ;;
esac

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# Print the changed paths, or nothing when they cannot be determined.
changed_paths() {
  local base head merge_base
  if [ -n "${FM_CI_CHANGED_PATHS_FILE:-}" ]; then
    [ -r "$FM_CI_CHANGED_PATHS_FILE" ] || return 1
    cat -- "$FM_CI_CHANGED_PATHS_FILE"
    return 0
  fi
  base=${FM_CI_BASE_SHA:-}
  head=${FM_CI_HEAD_SHA:-HEAD}
  [ -n "$base" ] || return 1
  git rev-parse --verify --quiet "$base^{commit}" >/dev/null || return 1
  git rev-parse --verify --quiet "$head^{commit}" >/dev/null || return 1
  # Compare against the merge base so commits that only arrived on the base
  # branch are never counted as this pull request's changes.
  merge_base=$(git merge-base "$base" "$head" 2>/dev/null) || merge_base=$base
  git diff --no-renames --name-only "$merge_base" "$head" 2>/dev/null || return 1
}

# True when the path cannot change the stock macOS Bash job's verdict.
macos_inert() {
  case "$1" in
    bin/* | tests/* | .github/workflows/ci.yml) return 1 ;;
    docs/* | .agents/* | skills/* | assets/* | .github/*) return 0 ;;
    *.md | LICENSE | .gitignore | .greptile*) return 0 ;;
    *) return 1 ;;
  esac
}

# True when the path cannot change any test's verdict.
behavior_inert() {
  case "$1" in
    # Prose a test really reads, checked before the docs/*.md arm below.
    docs/supervision-protocols/* | docs/examples/* | docs/arm-pretool-check.md | \
      docs/configuration.md | docs/fm-test-portable-shards.md | \
      docs/fm-test-isolation-proof.md)
      return 1
      ;;
    # A case glob's * spans /, so this covers nested pages such as
    # docs/verification/agy.md as well as top-level ones.
    docs/*.md) return 0 ;;
    README.md | VISION.md | GROK_BOT.md | LICENSE | .greptile*) return 0 ;;
    assets/*) return 0 ;;
    *) return 1 ;;
  esac
}

paths=$(changed_paths) || paths=

behavior=true
macos=true
case "${FM_CI_EVENT:-pull_request}" in
  pull_request)
    if [ -n "$paths" ]; then
      behavior=false
      macos=false
      while IFS= read -r path; do
        [ -n "$path" ] || continue
        behavior_inert "$path" || behavior=true
        macos_inert "$path" || macos=true
      done <<EOF
$paths
EOF
    fi
    ;;
  *) ;;
esac

# The behavior gate also covers the macOS job: a change that reaches no test at
# all cannot reach the stock-Bash job either, and a shell change sets both.
printf 'behavior=%s\n' "$behavior"
printf 'macos=%s\n' "$macos"
