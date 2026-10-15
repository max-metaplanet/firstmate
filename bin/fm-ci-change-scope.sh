#!/usr/bin/env bash
# fm-ci-change-scope.sh - classify a CI event's changed paths into job gates.
#
# Single owner of which changed paths .github/workflows/ci.yml may gate a job
# on. It prints GitHub step-output lines, so the workflow reads a verdict
# instead of re-spelling path globs per job:
#
#   behavior=true|false   run the behavior suites at all (lint included)
#   macos=true|false      the stock macOS Bash snapshot job's sources changed
#   full=true|false       run the COMPLETE behavior suite: both portable
#                         parallel lanes and all 16 portable serial shards.
#                         Only a push to main, the nightly schedule, or an
#                         unrecognized event sets it; a pull request never
#                         does, because those two events own the complete
#                         coverage a pull request now trades away for speed.
#   parallel=true|false   run the two portable parallel lanes. True whenever
#                         `full` is, and true on its own for the bounded
#                         pull-request fallback described below.
#   herdr=true|false      run the required real-Herdr lane
#   selected_matrix=<json>|<empty>
#                         a GitHub matrix for the change-scoped behavior job,
#                         one entry per packed bin: {"include":[{"shard":"1",
#                         "scripts":"tests/a.test.sh tests/b.test.sh"}]}
#
# Usage:
#   bin/fm-ci-change-scope.sh            classify and print every gate output
#   bin/fm-ci-change-scope.sh --local    select local no-mistakes Test coverage
#   bin/fm-ci-change-scope.sh --help     print this header
#
# --local keeps the output format but replaces workflow, action, and
# .no-mistakes.yaml paths with their workflow-lint, CI workflow, gate config,
# classifier, and local Test contract suites before asking the runner for a
# selection, which is a far narrower set than the owning family CI selects for
# the same paths. Other changed paths retain their normal mapping. --local also
# keeps the complete-suite fallback in place of the bounded lane fallback
# below, because the lanes it names are CI jobs its consumer cannot run.
#
# Inputs, all optional and read from the environment:
#   FM_CI_EVENT               the GitHub event name (default: pull_request)
#   FM_CI_BASE_SHA            the pull request's base commit
#   FM_CI_HEAD_SHA            the pull request's head commit (default: HEAD)
#   FM_CI_CHANGED_PATHS_FILE  a newline-delimited path list, used instead of git
#
# The selection's own bounds - how many bins, how large, and what counts as a
# broadly shared library - are constants below rather than inputs, so one
# reading of this script tells you what any round will do.
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
#
# Change-scoped selection narrows the behavior gate further on a pull request:
# instead of the complete suite, CI runs only the test scripts that cover the
# changed paths. The map that answers which those are is NOT duplicated here;
# bin/fm-test-run.sh's --changed map stays its single owner and is asked
# directly, with this script supplying the pull request's path set so the diff
# keeps one owner too. bin/fm-test-run.sh --check-changed-map pins that map
# against the paths the tests tree actually names.
#
# A pull request selects for every changed path, including the CI workflow,
# the no-mistakes config, the test runner, its isolation proof, this
# classifier, shared test scaffolding and shared libraries. None of those is
# special-cased here: the runner's map already answers for them with the
# family that owns the touched machinery, and a second hand-written list of
# "the suites that own X" would be a competing selector that drifts from it.
#
# Selection falls back, never toward speed, whenever:
#   - the behavior gate is already off, so there is nothing to select from
#   - the change set could not be determined
#   - a changed path is behavior-relevant prose (outside the inert set) that
#     the map answers nothing for, alone or beside code, so the test reading
#     it cannot be dropped
#   - the runner refuses the change set, which is what it does for a path its
#     map does not know
#   - the selection comes back empty, so no suite would prove the change
#   - the selection cannot be packed into SELECT_MAX_JOBS bins that each
#     stay inside SELECT_BIN_BUDGET_MS of modeled work
#
# What it falls back TO depends on the event, and this is the one place the
# two differ. A push to main, the nightly schedule and an unrecognized event
# run the complete suite: `full` stays true and nothing is narrowed. A pull
# request runs the bounded lane fallback instead - both portable parallel
# lanes and the required Herdr lane, three runners - rather than the complete
# sixteen-shard serial fan-out. The fork holds about twenty concurrent
# runners, so a pull request that fans out to nineteen long-lived jobs spends
# its round queueing behind itself and behind every sibling round; the
# complete coverage it gives up is run on the very next push to main and again
# overnight, which is where a serial-lane regression is caught instead.
# --local keeps the complete-suite fallback, because its consumer runs scripts
# rather than CI jobs and has no lane to fall back to.
#
# The packing is what keeps a one-script change from spending 23 runners: the
# smallest bin count whose worst bin fits the budget wins, so a single-script
# change runs in exactly one job. Weights are bin/fm-test-run.sh's own measured
# hints, the same evidence its shard packing uses.
set -eu

local_mode=false
case "${1:-}" in
  --local) local_mode=true ;;
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

# Most bins a selection may be packed into. Six keeps a packed round far under
# the complete suite's twenty-three long-lived jobs while still splitting the
# larger selections; past that, runner start delay eats the gain.
SELECT_MAX_JOBS=6

# Largest modeled bin a selection may pack to: ten minutes of estimated serial
# work, measured by bin/fm-test-run.sh's own hints. A selection no packing
# brings under this is one the complete sharded suite runs faster anyway.
SELECT_BIN_BUDGET_MS=600000

TAB=$(printf '\t')

# Configuration whose complete validation belongs to CI, with local contract
# coverage available through --local. Keep this path classification in one place.
workflow_configuration_path() {
  case "$1" in
    .github/workflows/* | .github/actions/* | .no-mistakes.yaml) return 0 ;;
    *) return 1 ;;
  esac
}

# True when this changed path makes a change-scoped selection untrustworthy.
#
# Only one shape still does. Prose the map's prose arm answers nothing for
# would vanish from a mixed change set: beside code the selection stays
# non-empty, so nothing widens, and the test that reads the prose is silently
# dropped. Every other path - machinery included - is answered by the runner's
# map with the family that owns it, and the packing budget bounds the result.
selection_blocked_by() {
  local path=$1
  case "$path" in
    README.md | LICENSE | assets/* | docs/* | .gitignore)
      ! behavior_inert "$path" || return 1
      [ -z "$(bin/fm-test-run.sh --list-weighted --changed \
        --changed-paths-file <(printf '%s\n' "$path") 2>/dev/null)" ]
      return
      ;;
    *) return 1 ;;
  esac
}

# Pack "<ms>\t<path>" lines from stdin into the fewest bins whose worst bin
# stays inside the budget, printing "<bin>\t<space separated paths>" per bin.
# Prints nothing when no admissible bin count exists. Input must already be
# ordered longest first, which is what longest-processing-time packing needs.
pack_selection() {
  awk -F'\t' -v maxjobs="$SELECT_MAX_JOBS" -v budget="$SELECT_BIN_BUDGET_MS" '
    { ms[NR] = $1 + 0; path[NR] = $2; n = NR }
    END {
      if (n == 0) { exit 0 }
      for (k = 1; k <= maxjobs; k++) {
        worst = 0
        for (b = 1; b <= k; b++) { load[b] = 0; members[b] = "" }
        for (i = 1; i <= n; i++) {
          best = 1
          for (b = 2; b <= k; b++) { if (load[b] < load[best]) { best = b } }
          load[best] += ms[i]
          members[best] = (members[best] == "" ? path[i] : members[best] " " path[i])
          if (load[best] > worst) { worst = load[best] }
        }
        if (worst <= budget) {
          for (b = 1; b <= k; b++) {
            if (members[b] != "") { printf "%d\t%s\n", b, members[b] }
          }
          exit 0
        }
      }
    }
  '
}

full=$behavior
parallel=$behavior
herdr=$behavior
selected_matrix=

# Give up on a pull request's change-scoped selection. The header's fallback
# paragraph owns why a pull request lands on the two portable parallel lanes
# and the required Herdr lane instead of the complete sixteen-shard fan-out,
# and why --local keeps the complete-suite fallback instead.
fall_back() {
  [ "$local_mode" = false ] || return 0
  full=false
  parallel=true
  herdr=true
  selected_matrix=
}

# Narrow the gates above to a change-scoped selection, or fall back. Every
# refusal path below returns before anything is narrowed.
select_tests() {
  local path weighted herdr_members list packed ms script shard scripts selected_herdr first selection_paths

  [ "$behavior" = true ] || return 0
  # Push to main, the nightly schedule and an unrecognized event never select
  # and never fall back: they are what the complete suite runs on.
  [ "${FM_CI_EVENT:-pull_request}" = pull_request ] || return 0
  [ -n "$paths" ] || { fall_back; return 0; }
  [ -x bin/fm-test-run.sh ] || { fall_back; return 0; }

  selection_paths=
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    if selection_blocked_by "$path"; then
      fall_back
      return 0
    fi
    if [ "$local_mode" = true ] && workflow_configuration_path "$path"; then
      selection_paths="${selection_paths}tests/fm-lint-workflows.test.sh
tests/fm-ci-workflow.test.sh
tests/fm-gate-refuse.test.sh
tests/fm-ci-change-scope.test.sh
tests/fm-nm-test-contract.test.sh
"
    else
      selection_paths="${selection_paths}${path}
"
    fi
  done <<EOF
$paths
EOF

  # The runner owns the map; this script owns the diff. It refuses a path set
  # whose mapping it does not know, and that refusal is the fail-open signal.
  weighted=$(bin/fm-test-run.sh --list-weighted --changed \
    --changed-paths-file <(printf '%s\n' "$selection_paths") 2>/dev/null) || weighted=
  [ -n "$weighted" ] || { fall_back; return 0; }

  # A change set holding tracked prose AND code runs the behavior jobs, so the
  # prose-only docs-guard job does not run, while the map answers nothing for
  # prose and the code paths keep the selection non-empty. The prose check
  # would simply vanish. Add it here rather than in the map, because the map's
  # silence on prose is what makes a prose-only behavior-relevant change widen
  # to the complete suite, and attributing prose by reference scan is noisy.
  # The trigger mirrors REQUIRED_TRACKED_PATTERNS in bin/fm-doc-audience-check.sh,
  # which owns the prose set, plus the other files the map's prose arm names.
  if printf '%s\n' "$paths" | grep -qE '(\.(md|mdx|rst|txt)$|^(LICENSE|\.gitignore)$|^(assets|docs)/)'; then
    doc_suite=tests/fm-documentation-audiences.test.sh
    if ! printf '%s\n' "$weighted" | grep -Fq -- "$doc_suite"; then
      weighted="${weighted}
$(bin/fm-test-run.sh --list-weighted "$doc_suite" 2>/dev/null)"
    fi
  fi

  # The required Herdr lane owns its whole family, so a selected member sends
  # the work there rather than into a job with no Herdr installed.
  herdr_members=$(bin/fm-test-run.sh --list --family real-herdr-gated 2>/dev/null) || herdr_members=
  selected_herdr=false
  list=
  while IFS="$TAB" read -r ms script; do
    [ -n "$script" ] || continue
    if printf '%s\n' "$herdr_members" | grep -Fxq -- "$script"; then
      selected_herdr=true
      continue
    fi
    list="${list}${ms}${TAB}${script}
"
  done <<EOF
$weighted
EOF

  packed=
  if [ -n "$list" ]; then
    packed=$(printf '%s' "$list" | pack_selection)
    [ -n "$packed" ] || { fall_back; return 0; }
  fi

  first=1
  selected_matrix='{"include":['
  while IFS="$TAB" read -r shard scripts; do
    [ -n "$shard" ] || continue
    [ "$first" -eq 1 ] || selected_matrix="${selected_matrix},"
    first=0
    selected_matrix="${selected_matrix}{\"shard\":\"${shard}\",\"scripts\":\"${scripts}\"}"
  done <<EOF
$packed
EOF
  selected_matrix="${selected_matrix}]}"
  # A change set whose every selected script is a Herdr-family member packs
  # nothing: the required Herdr lane runs it and no packed job is needed.
  [ "$first" -eq 0 ] || selected_matrix=

  full=false
  parallel=false
  herdr=$selected_herdr
}

select_tests

# The behavior gate also covers the macOS job: a change that reaches no test at
# all cannot reach the stock-Bash job either, and a shell change sets both.
printf 'behavior=%s\n' "$behavior"
printf 'macos=%s\n' "$macos"
printf 'full=%s\n' "$full"
printf 'parallel=%s\n' "$parallel"
printf 'herdr=%s\n' "$herdr"
printf 'selected_matrix=%s\n' "$selected_matrix"
