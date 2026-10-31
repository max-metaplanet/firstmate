#!/usr/bin/env bash
# Read or wait for required GitHub checks, using bin/fm-pr-checks-lib.sh's policy.
# Usage: fm-pr-checks.sh [--watch [--settled] [--timeout <seconds>]]
#                        [--after <UTC time>] [--queue-only <name>]... <pr-url>
# Prints REQUIRED CHECK: <name> (pending|red|missing) for each blocker.
# Exit: 0 required checks green, 1 required check red, 8 pending/missing,
# 2 unreadable state or usage. --watch waits through pending/missing only,
# re-reading the head and base requirements every FM_PR_CHECKS_POLL seconds
# (default 20). By default advisory checks never delay success or cause failure.
# --queue-only <name> declares a required check that reports only in the
# project's merge queue, so its absence from this head is not a blocker and is
# printed as QUEUE-ONLY CHECK: <name> (runs in the merge queue) instead. The
# same check still blocks when it reports red or is still running on the head,
# and every other required check must still be green.
# --timeout <seconds> bounds --watch: when the wait is still pending or missing
# at that bound it reports the outstanding checks and exits 8 rather than
# polling forever. 0, the default, keeps the wait unbounded. Raise --timeout
# for a legitimately long CI run.
# --settled requires --watch and waits for every reported check on the head
# to finish, including advisory checks, before returning a red/green verdict.
# It batches CI repair rounds without changing which failures block readiness.
# --after YYYY-MM-DDTHH:MM:SSZ ignores a check whose latest run before that
# bound was SKIPPED, so it is missing until a run at or after the bound reports;
# completed non-skipped earlier results still count. Pass the PR's
# ready_for_review time when its checks were skipped while it was a draft.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-pr-checks-lib.sh
. "$SCRIPT_DIR/fm-pr-checks-lib.sh"

die() { printf 'fm-pr-checks: %s\n' "$*" >&2; exit 2; }
WATCH=false
SETTLED=false
AFTER=
TIMEOUT=0
QUEUE_ONLY=
if [ "${1:-}" = --help ]; then
  sed -n '2,/^set -eu$/s/^# \{0,1\}//p' "$0"
  exit 0
fi
while [ "$#" -gt 0 ]; do
  case "$1" in
    --watch) WATCH=true; shift ;;
    --settled) SETTLED=true; shift ;;
    --after)
      [ "$#" -ge 2 ] || die '--after requires a UTC time'
      [[ $2 =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] \
        || die '--after expects YYYY-MM-DDTHH:MM:SSZ'
      AFTER=$2; shift 2 ;;
    --timeout)
      [ "$#" -ge 2 ] || die '--timeout requires seconds'
      [[ $2 =~ ^[0-9]{1,6}$ ]] || die '--timeout expects whole seconds'
      TIMEOUT=$2; shift 2 ;;
    --queue-only)
      [ "$#" -ge 2 ] && [ -n "$2" ] || die '--queue-only requires a check name'
      case $2 in *[[:cntrl:]]*) die '--queue-only name cannot contain control characters' ;; esac
      QUEUE_ONLY=$QUEUE_ONLY$2$'\n'; shift 2 ;;
    *) break ;;
  esac
done
[ "$SETTLED" = false ] || [ "$WATCH" = true ] || die '--settled requires --watch'
[ "$TIMEOUT" = 0 ] || [ "$WATCH" = true ] || die '--timeout requires --watch'
[ "$#" -eq 1 ] || die 'usage: fm-pr-checks.sh [--watch [--settled] [--timeout <seconds>]] [--after <UTC time>] [--queue-only <name>]... <pr-url>'
URL=$1
fm_pr_url_parse "$URL" && [ "$FM_PR_PROVIDER" = github ] \
  || die 'expected a GitHub pull-request URL'
PR_OWNER=${FM_PR_PATH%%/*}
PR_REPO=${FM_PR_PATH#*/}
if ! command -v gh >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
  die 'gh and jq are required'
fi

DEADLINE=0
if [ "$TIMEOUT" != 0 ]; then
  NOW=$(date +%s) || die 'could not read the current time for --timeout'
  DEADLINE=$((NOW + TIMEOUT))
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
  STALE=
  if [ -n "$AFTER" ]; then
    BOUNDED=$(github_rollup_without_skips_before "$JSON" "$AFTER") || die 'unreadable checks'
    STALE=$(github_checks_without_fresh_run "$JSON" "$BOUNDED" "$FM_PR_GITHUB_REQUIRED") \
      || die 'unreadable checks'
    JSON=$BOUNDED
  fi
  RED=$(github_checks_not_green "$JSON" "$FM_PR_GITHUB_REQUIRED") || die 'unreadable checks'
  MISSING=$(github_required_checks_missing "$JSON" "$FM_PR_GITHUB_REQUIRED" "$FM_PR_GITHUB_PRODUCERS") \
    || die 'unreadable checks'
  github_defer_queue_only "$MISSING" "$QUEUE_ONLY"
  MISSING=$FM_PR_QUEUE_ONLY_BLOCKING
  DEFERRED=$FM_PR_QUEUE_ONLY_DEFERRED
  github_defer_queue_only "$STALE" "$QUEUE_ONLY"
  STALE=$FM_PR_QUEUE_ONLY_BLOCKING
  DEFERRED=$DEFERRED$FM_PR_QUEUE_ONLY_DEFERRED
  BLOCKERS=
  RESULT=0
  while IFS=$'\t' read -r state name; do
    [ -n "$state" ] || continue
    printf 'REQUIRED CHECK: %s (%s)\n' "$name" "$state"
    if [ "$state" = red ]; then
      RESULT=1
    else
      BLOCKERS="${BLOCKERS:+$BLOCKERS, }$name ($state)"
      [ "$RESULT" != 0 ] || RESULT=8
    fi
  done <<EOF
$RED
EOF
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    printf 'REQUIRED CHECK: %s (missing)\n' "$name"
    BLOCKERS="${BLOCKERS:+$BLOCKERS, }$name (missing)"
    [ "$RESULT" != 0 ] || RESULT=8
  done <<EOF
$MISSING
$STALE
EOF
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    printf 'QUEUE-ONLY CHECK: %s (runs in the merge queue)\n' "$name"
  done <<EOF
$DEFERRED
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
  if [ "$DEADLINE" != 0 ]; then
    NOW=$(date +%s) || die 'could not read the current time for --timeout'
    if [ "$NOW" -ge "$DEADLINE" ]; then
      [ "$EXECUTING" = false ] || BLOCKERS="${BLOCKERS:+$BLOCKERS, }head checks still executing"
      printf 'fm-pr-checks: gave up after %ss waiting for %s on %s\n' \
        "$TIMEOUT" "${BLOCKERS:-the required checks}" "$URL" >&2
      printf '%s\n' \
        "fm-pr-checks: a check that only runs in this project's merge queue belongs in --queue-only; otherwise find out why it has not reported, or raise --timeout for a legitimately long CI run" >&2
      exit 8
    fi
  fi
  sleep "${FM_PR_CHECKS_POLL:-20}"
done
