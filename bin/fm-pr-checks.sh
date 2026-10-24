#!/usr/bin/env bash
# Read or wait for required GitHub checks, using bin/fm-pr-checks-lib.sh's policy.
# Usage: fm-pr-checks.sh [--watch [--settled]] <pr-url>
# Prints REQUIRED CHECK: <name> (pending|red|missing) for each blocker.
# Exit: 0 required checks green, 1 required check red, 8 pending/missing,
# 2 unreadable state or usage. --watch waits through pending/missing only,
# re-reading the head and base requirements every FM_PR_CHECKS_POLL seconds
# (default 20). By default advisory checks never delay success or cause failure.
# --settled requires --watch and waits for every reported check on the head
# to finish, including advisory checks, before returning a red/green verdict.
# It batches CI repair rounds without changing which failures block readiness.
# Apply a caller-owned timeout when a bounded foreground wait is needed.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-pr-checks-lib.sh
. "$SCRIPT_DIR/fm-pr-checks-lib.sh"

die() { printf 'fm-pr-checks: %s\n' "$*" >&2; exit 2; }
WATCH=false
SETTLED=false
if [ "${1:-}" = --help ]; then
  sed -n '2,/^set -eu$/s/^# \{0,1\}//p' "$0"
  exit 0
fi
while [ "$#" -gt 0 ]; do
  case "$1" in
    --watch) WATCH=true; shift ;;
    --settled) SETTLED=true; shift ;;
    *) break ;;
  esac
done
[ "$SETTLED" = false ] || [ "$WATCH" = true ] || die '--settled requires --watch'
[ "$#" -eq 1 ] || die 'usage: fm-pr-checks.sh [--watch [--settled]] <pr-url>'
URL=$1
fm_pr_url_parse "$URL" && [ "$FM_PR_PROVIDER" = github ] \
  || die 'expected a GitHub pull-request URL'
PR_OWNER=${FM_PR_PATH%%/*}
PR_REPO=${FM_PR_PATH#*/}
if ! command -v gh >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
  die 'gh and jq are required'
fi

while :; do
  JSON=$(gh pr view "$URL" --json headRefOid,baseRefName,statusCheckRollup) \
    || die "could not read $URL"
  HEAD=$(printf '%s' "$JSON" | jq -er '.headRefOid') || die 'unreadable head'
  BASE=$(printf '%s' "$JSON" | jq -er '.baseRefName | select(type == "string" and length > 0)') \
    || die 'unreadable base'
  fm_pr_head_valid "$HEAD" || die 'invalid head'
  github_read_required_contexts "$BASE" || die "$FM_PR_GITHUB_REQUIRED_ERROR"
  github_read_required_producers "$HEAD" || die "could not read required check producers at head $HEAD"
  RED=$(github_checks_not_green "$JSON" "$FM_PR_GITHUB_REQUIRED") || die 'unreadable checks'
  MISSING=$(github_required_checks_missing "$JSON" "$FM_PR_GITHUB_REQUIRED" "$FM_PR_GITHUB_PRODUCERS") \
    || die 'unreadable checks'
  RESULT=0
  while IFS=$'\t' read -r state name; do
    [ -n "$state" ] || continue
    printf 'REQUIRED CHECK: %s (%s)\n' "$name" "$state"
    if [ "$state" = red ]; then RESULT=1; elif [ "$RESULT" = 0 ]; then RESULT=8; fi
  done <<EOF
$RED
EOF
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    printf 'REQUIRED CHECK: %s (missing)\n' "$name"
    [ "$RESULT" != 0 ] || RESULT=8
  done <<EOF
$MISSING
EOF
  EXECUTING=false
  if [ "$SETTLED" = true ]; then
    EXECUTING=$(printf '%s' "$JSON" | jq -r '
      [.statusCheckRollup[] | if .__typename == "CheckRun" then
        .status != "COMPLETED"
      elif .__typename == "StatusContext" then
        .state == "PENDING" or .state == "EXPECTED"
      else error("unknown check type") end] | any
    ') || die 'unreadable head check states'
    if [ "$EXECUTING" = true ]; then
      printf 'HEAD CHECKS: still executing at %s\n' "$HEAD"
    fi
  fi
  [ "$WATCH" = true ] && { [ "$RESULT" = 8 ] || [ "$EXECUTING" = true ]; } || exit "$RESULT"
  sleep "${FM_PR_CHECKS_POLL:-20}"
done
