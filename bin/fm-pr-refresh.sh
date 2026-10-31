#!/usr/bin/env bash
# Hold an existing GitHub PR in draft for a conflict-only refresh.
# Usage: FM_HOME=<home> fm-pr-refresh.sh prepare <task-id> <pr-url> [-- <command> [args...]]
#        FM_HOME=<home> fm-pr-refresh.sh ready <task-id> <pr-url> --ready-ci reruns|unchanged
#
# Conflict-only means replaying the already-authorized change onto its base,
# including the minimum conflict resolutions needed to preserve that intent.
# A feature, behavior change, review fix, or opportunistic cleanup is new intent
# and follows ordinary validation instead. Classification is the caller's
# responsibility; a diff cannot prove semantic equivalence after conflicts.
# prepare verifies draft BEFORE running the optional publication command.
# Without a command it prepares a later pipeline-owned push; workers must not
# take over a pipeline's publication. It records state/<id>.pr-refresh and a
# paused status even if publication fails, leaving the draft held for firstmate.
# ready is called only on firstmate's explicit instruction. It marks ready and
# waits through fm-pr-checks.sh --watch before removing the hold; a failed wait
# preserves the hold for retry. --ready-ci states the repository's CI policy:
# reruns when ready_for_review re-runs draft-skipped checks (the wait adds
# --after the ready_for_review timeline time, so draft-era skips never count),
# unchanged when it does not (same-head skips, such as path filters, stand).
# Other forges fail closed before any publication; ask firstmate for their
# equivalent draft/ready procedure. This script never pushes by default.
set -eu
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-ready-hold-lib.sh
. "$SCRIPT_DIR/fm-ready-hold-lib.sh"

die() { printf 'fm-pr-refresh: %s\n' "$*" >&2; exit 1; }
if [ "${1:-}" = --help ]; then
  sed -n '2,/^set -eu$/s/^# \{0,1\}//p' "$0"
  exit 0
fi
[ "$#" -ge 3 ] || die 'expected prepare|ready <task-id> <pr-url>'
ACTION=$1 ID=$2 URL=$3
shift 3
case "$ACTION" in prepare|ready) ;; *) die 'expected prepare or ready' ;; esac
fm_pr_task_id_valid "$ID" || die 'invalid task id'
fm_pr_url_parse "$URL" && [ "$FM_PR_PROVIDER" = github ] || die 'expected a GitHub PR URL; nothing published'
[ -n "${FM_HOME:-}" ] || die 'FM_HOME must be explicit'
STATE=${FM_STATE_OVERRIDE:-$FM_HOME/state}
META=$STATE/$ID.meta
HOLD=$STATE/$ID.pr-refresh
[ -f "$META" ] && [ ! -L "$META" ] && [ "$(fm_pr_file_link_count "$META")" = 1 ] || die 'task metadata unavailable'
if ! fm_pr_regular_destination_or_absent "$HOLD" || ! fm_pr_regular_destination_or_absent "$STATE/$ID.status"; then
  die 'unsafe refresh hold or status destination'
fi
READY_CI=
if [ "$ACTION" = ready ]; then
  [ "$#" = 2 ] && [ "$1" = --ready-ci ] || die 'ready expects --ready-ci reruns|unchanged'
  case "$2" in reruns|unchanged) READY_CI=$2 ;; *) die 'ready expects --ready-ci reruns|unchanged' ;; esac
  shift 2
elif [ "$#" -gt 0 ]; then
  [ "$1" = -- ] && [ "$#" -gt 1 ] || die 'expected -- <publication command>'
  shift
fi
if [ -e "$HOLD" ] || [ -L "$HOLD" ]; then
  [ -f "$HOLD" ] && [ ! -L "$HOLD" ] && [ "$(cat "$HOLD")" = "$URL" ] || die 'refresh hold belongs to another PR or is unreadable'
fi

read_pr() {
  local json
  json=$(gh pr view "$URL" --json state,isDraft,id) || die 'could not read PR'
  printf '%s' "$json" | jq -e '.state == "OPEN" and (.isDraft | type == "boolean")' >/dev/null \
    || die 'PR is not open or draft state is unreadable'
  DRAFT=$(printf '%s' "$json" | jq -r '.isDraft')
  NODE_ID=$(printf '%s' "$json" | jq -er '.id | select(type == "string" and length > 0)') || die 'PR node id is unreadable'
}

read_pr
if [ "$ACTION" = prepare ]; then
  if [ "$DRAFT" = false ]; then
    # shellcheck disable=SC2016 # GraphQL expands its own $id variable.
    jq -nc --arg id "$NODE_ID" \
      --arg query 'mutation($id: ID!) { convertPullRequestToDraft(input: {pullRequestId: $id}) { pullRequest { isDraft } } }' \
      '{query:$query,variables:{id:$id}}' | gh-axi api POST /graphql --input - \
      || die 'could not convert PR to draft; nothing published'
  fi
  read_pr
  [ "$DRAFT" = true ] || die 'draft conversion was not confirmed; nothing published'
  hold_tmp=$(mktemp "$STATE/.${ID}.pr-refresh.XXXXXX")
  printf '%s\n' "$URL" > "$hold_tmp"
  mv "$hold_tmp" "$HOLD"
  rc=0
  if [ "$#" -gt 0 ]; then "$@" || rc=$?; fi
  printf 'paused [at=%s]: conflict-only refresh of %s held in draft; publication exit=%s; awaiting firstmate ready call\n' \
    "$(date +%s)" "$URL" "$rc" >> "$STATE/$ID.status"
  printf 'held: %s awaits firstmate ready call (publication exit=%s)\n' "$URL" "$rc"
  exit "$rc"
fi

[ -f "$HOLD" ] || die 'no conflict-refresh hold exists for this task'
READY_HOLD_LABEL=
if [ "$(sed -n 's/^yolo=//p' "$META" | tail -n 1)" != on ]; then
  project=$(sed -n 's/^project=//p' "$META" | tail -n 1)
  READY_HOLD_LABEL=$(fm_ready_hold_label "${FM_CONFIG_OVERRIDE:-$FM_HOME/config}" "$(basename "$project")") \
    || die 'ready-hold declaration is unreadable; hold retained'
fi
if [ -n "$READY_HOLD_LABEL" ]; then
  fm_ready_hold_apply "$URL" "$READY_HOLD_LABEL" || die 'could not apply ready-hold label; hold retained'
fi
if [ "$DRAFT" = true ]; then
  gh-axi pr ready "$FM_PR_NUMBER" --repo "$FM_PR_PATH" || die 'could not mark PR ready'
fi
read_pr
[ "$DRAFT" = false ] || die 'ready transition was not confirmed'
if [ "$READY_CI" = reruns ]; then
  READY_AT=$(gh api --paginate "repos/$FM_PR_PATH/issues/$FM_PR_NUMBER/timeline" \
    --jq '.[] | select(.event == "ready_for_review") | .created_at' | tail -n 1) || die 'could not read ready timeline; hold retained'
  [[ "$READY_AT" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || die 'ready timeline time unavailable; hold retained'
  "$SCRIPT_DIR/fm-pr-checks.sh" --watch --after "$READY_AT" "$URL"
else
  "$SCRIPT_DIR/fm-pr-checks.sh" --watch "$URL"
fi
if [ -n "$READY_HOLD_LABEL" ]; then
  fm_ready_hold_verify "$URL" "$READY_HOLD_LABEL" || die 'ready-hold label missing after CI; hold retained'
fi
rm "$HOLD"
printf 'resolved [at=%s]: conflict-refresh hold cleared for %s after ready CI passed\n' "$(date +%s)" "$URL" >> "$STATE/$ID.status"
printf 'ready: %s checks green (ready CI %s)\n' "$URL" "$READY_CI"
