#!/usr/bin/env bash
# Turn a project merge queue's drop of a ship's pull request into one durable
# steer carrying the failing check's own evidence.
#
# Usage:
#   fm-mq-drop.sh handle <task-id> <row-json-file> <comments-json-file>
#
# <row-json-file> is one contribution record row as bin/fm-contributions.sh
# writes it, mutated in place when a drop is handled. <comments-json-file> is
# that pull request's slurped paginated issue-comments payload: an array of
# pages, each page an array of comments. bin/fm-contributions.sh owns both and
# is the only caller; it already holds them from the observation it just made,
# so an ordinary poll spends no extra forge read.
#
# docs/configuration.md "Merge-queue drop handling" owns the declaration file
# and its format. A declaration names one project's queue bot login and the
# literal, case-sensitive substring that bot's drop comment carries.
#
# A DROP EVENT is the highest-id comment by that exact login whose body
# contains that marker, on a pull request whose observation is still open.
#
#   token = "mq-drop:<comment-id>:<observed-head>"
#
# The token is the idempotency key, recorded on the row as .mq_drop={token,at}.
# One steer per token, forever. The observed head is in the token rather than
# the comment's updated_at because a queue bot keeps ONE status comment and
# edits it in place: an edit on the same head must not steer again, while a
# re-drop after the worker pushes a fix must. A requeue that drops again on
# the same head is silent too, because the worker already holds that evidence.
#
# Each of these exits 0 and leaves the row untouched: a row that is not a pull
# request, carries an error, or has no observation; an observation that is
# merged or closed, because a merge produces no drop; absent task metadata; no
# declaration for the task's project; no matching comment; and an
# already-recorded token. A nonzero exit is a genuine failure: an unreadable
# row, comment payload or declaration, or a steer that could not be delivered.
# A failed steer records no token, so the next poll retries it.
#
# EVIDENCE is walked only for a fresh event and never blocks the steer. Each
# forge read goes through gh under a ten-second bound, and a failed or
# timed-out read drops to the next rung.
#   1. A https://github.com/<owner>/<repo>/pull/<n> link in the drop comment,
#      in this pull request's own repository and not this pull request, is the
#      queue's own pull request. Its head's check runs supply the failing
#      checks and their reported output summaries.
#   2. Otherwise the row's own observation supplies the failing checks.
#   3. One failing check is chosen: the newest started_at, ties by name
#      ascending, so the choice is deterministic.
#   4. That check run's GitHub Actions job log supplies the excerpt.
#   5. Otherwise that check run's reported output summary does.
#   6. Otherwise the drop comment body does.
# Every excerpt keeps its last 80 lines, drops control characters other than
# newline and tab, and is capped at 8000 bytes from the front behind a
# [...truncated] line, so the failing tail survives.
#
# Delivery is one bin/fm-send.sh steer, which owns the durable steering inbox
# and a parked worker's resume. No forge writes are performed.
set -eu

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
FM_HOME=${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}
STATE=${FM_STATE_OVERRIDE:-$FM_HOME/state}
CONFIG=${FM_CONFIG_OVERRIDE:-$FM_HOME/config}
export FM_HOME FM_STATE_OVERRIDE="$STATE"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-path-lib.sh
. "$SCRIPT_DIR/fm-path-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

fail() { printf 'fm-mq-drop: %s\n' "$*" >&2; exit 1; }
usage() { sed -n '2,/^set /{ /^#/s/^# \{0,1\}//p; }' "$0"; }
case "${1:-}" in -h | --help) usage; exit 0 ;; esac
command -v jq >/dev/null 2>&1 || fail 'jq is required to read a contribution row'
command -v awk >/dev/null 2>&1 || fail 'awk is required to read the queue declaration'

TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-mq-drop.XXXXXX")
trap 'rm -rf -- "$TMP"' EXIT

# One declaration per project, unlike the repeatable queue-only check lines: a
# project has one queue signal, so a second entry for it is a conflict rather
# than an addition.
mq_declaration() { # <project-name> -> "<bot-login>\t<drop-marker>"
  local file=$CONFIG/project-merge-queue
  [ -e "$file" ] || [ -L "$file" ] || return 0
  if [ ! -f "$file" ] || [ ! -r "$file" ]; then
    printf 'error: %s is not a readable regular file\n' "$file" >&2
    return 1
  fi
  awk -F '\t' -v project="$1" '
    /^[[:space:]]*$/ || /^#([[:space:]]|$)/ { next }
    {
      sub(/\r$/, "")
      if (NF != 3 || $1 == "" || $2 == "" || $3 == "" || seen[$1]++ \
        || $1 ~ /[[:cntrl:]]/ || $2 ~ /[[:cntrl:]]/ || $3 ~ /[[:cntrl:]]/) {
        printf "error: invalid or duplicate merge-queue entry at %s:%d\n", FILENAME, FNR > "/dev/stderr"
        bad=1
      }
      if ($1 == project) { bot=$2; marker=$3 }
    }
    END { if (bad) exit 1; if (bot != "") printf "%s\t%s\n", bot, marker }
  ' "$file"
}

forge_read() { # <output-file> <gh-args...>
  local out=$1
  shift
  fm_run_timed 10 env GH_PROMPT_DISABLED=1 GH_NO_UPDATE_NOTIFIER=1 gh "$@" > "$out" 2>/dev/null
}

cap_tail() { # <max-bytes> ; stdin -> stdout
  local max=$1 text start
  local LC_ALL=C
  text=$(cat)
  if [ "${#text}" -le "$max" ]; then
    printf '%s\n' "$text"
  else
    start=$((${#text} - max))
    printf '[...truncated]\n%s\n' "${text:start}"
  fi
}

excerpt_of() { # <file> -> bounded excerpt on stdout
  tail -n 80 "$1" | tr -d '\000-\010\013-\037\177' | cap_tail 8000
}

queue_pull_number() { # <body-file> <owner> <repo> <this-number>
  local owner_re=${2//./\\.} repo_re=${3//./\\.}
  grep -oE "https://github\.com/$owner_re/$repo_re/pull/[1-9][0-9]*" "$1" 2>/dev/null \
    | sed 's|.*/||' | awk -v n="$4" '$0 != n { print; exit }'
}

failing_from_check_runs() { # <slurped-check-runs-file>
  jq -L "$SCRIPT_DIR" -n --slurpfile pages "$1" 'include "fm-contributions";
    [ ($pages[0] // [])[] | .check_runs[]?
      | {name,id,status,conclusion,started_at,summary:(.output.summary // "")} ]
    | completed_checks | failed_of(.)' 2>/dev/null || printf '[]\n'
}

failing_from_observation() { # <row-file>
  jq -L "$SCRIPT_DIR" 'include "fm-contributions";
    [ (.observation.checks // [])[] | . + {summary:""} ] | completed_checks | failed_of(.)' "$1" \
    2>/dev/null || printf '[]\n'
}

chosen_failing() { # <failing-file>
  jq -c '. as $failing
    | if ($failing | length) == 0 then {}
      else ($failing | map(.started_at // "") | max) as $newest
        | [ $failing[] | select((.started_at // "") == $newest) ] | sort_by(.name) | first end' "$1"
}

# Fills FAILING_NAMES, CHOSEN_NAME, EVIDENCE_SOURCE and EXCERPT for one fresh event.
evidence() { # <row-file> <event-file>
  local row=$1 event=$2 checks_source='' queue_number queue_head chosen id summary
  FAILING_NAMES=''
  CHOSEN_NAME=''
  EVIDENCE_SOURCE='the queue report comment'
  EXCERPT=''
  jq -r '.body' "$event" > "$TMP/body.txt"
  printf '[]\n' > "$TMP/failing.json"
  queue_number=$(queue_pull_number "$TMP/body.txt" "$FM_PR_OWNER" "$FM_PR_REPO" "$FM_PR_NUMBER")
  if [ -n "$queue_number" ] \
    && forge_read "$TMP/queue-pull.json" api "repos/$FM_PR_PATH/pulls/$queue_number" \
    && queue_head=$(jq -r '.head.sha // ""' "$TMP/queue-pull.json" 2>/dev/null) \
    && [ -n "$queue_head" ] \
    && forge_read "$TMP/queue-checks.json" api \
      "repos/$FM_PR_PATH/commits/$queue_head/check-runs?filter=all&per_page=100" --paginate --slurp \
    && failing_from_check_runs "$TMP/queue-checks.json" > "$TMP/queue-failing.json" \
    && jq -e 'length > 0' "$TMP/queue-failing.json" >/dev/null 2>&1; then
    cp "$TMP/queue-failing.json" "$TMP/failing.json"
    checks_source="https://github.com/$FM_PR_PATH/pull/$queue_number"
  else
    failing_from_observation "$row" > "$TMP/failing.json"
    checks_source="this pull request's head"
  fi
  FAILING_NAMES=$(jq -r '[.[].name] | unique | join(", ")' "$TMP/failing.json")
  chosen=$(chosen_failing "$TMP/failing.json")
  CHOSEN_NAME=$(printf '%s' "$chosen" | jq -r '.name // ""')
  if [ -n "$CHOSEN_NAME" ]; then
    id=$(printf '%s' "$chosen" | jq -r '.id // ""')
    if [ -n "$id" ] \
      && forge_read "$TMP/job.log" api "repos/$FM_PR_PATH/actions/jobs/$id/logs" \
      && [ -s "$TMP/job.log" ]; then
      EXCERPT=$(excerpt_of "$TMP/job.log")
    fi
    if [ -z "$EXCERPT" ]; then
      summary=$(printf '%s' "$chosen" | jq -r '.summary // ""')
      if [ -n "$summary" ]; then
        printf '%s\n' "$summary" > "$TMP/summary.txt"
        EXCERPT=$(excerpt_of "$TMP/summary.txt")
      fi
    fi
  fi
  if [ -n "$EXCERPT" ]; then
    EVIDENCE_SOURCE=$checks_source
  else
    EXCERPT=$(excerpt_of "$TMP/body.txt")
  fi
}

steer_text() { # <pr-url> <report-url>
  printf 'Merge-queue drop on %s.\n' "$1"
  printf "The project's merge queue removed this pull request instead of landing it; it did not merge.\n"
  printf 'Queue report: %s\n' "$2"
  printf 'Failing checks: %s\n' "${FAILING_NAMES:-none reported}"
  printf 'Evidence source: %s\n\n' "$EVIDENCE_SOURCE"
  printf -- '--- %s ---\n%s\n--- end ---\n\n' "${CHOSEN_NAME:-queue report}" "$EXCERPT"
  printf 'Fix the cause on this branch in one round, then requeue the pull request once its checks are green.\n'
  printf 'Do not requeue without a fix, and never push an empty or retrigger commit to re-run the queue.\n'
  printf 'If the cause is not in this branch, append a blocked: status line quoting the evidence above instead of requeuing.\n'
}

handle() { # <task-id> <row-json-file> <comments-json-file>
  local task=$1 row=$2 comments=$3 project decl bot marker head url token report staged
  [ -f "$row" ] && [ -r "$row" ] || fail "contribution row $row is unreadable"
  [ -f "$comments" ] && [ -r "$comments" ] || fail "comment payload $comments is unreadable"
  jq -e '.kind == "pr" and .error == null and .observation != null
    and .observation.state == "open"' "$row" >/dev/null 2>&1 || return 0
  [ -f "$STATE/$task.meta" ] && [ -r "$STATE/$task.meta" ] || return 0
  project=$(fm_meta_get "$STATE/$task.meta" project)
  [ -n "$project" ] || return 0
  fm_basename_to project "$project"
  decl=$(mq_declaration "$project") || fail 'the merge-queue declaration could not be read'
  [ -n "$decl" ] || return 0
  bot=${decl%%$'\t'*}
  marker=${decl#*$'\t'}
  head=$(jq -r '.observation.head // ""' "$row")
  url=$(jq -r '.url // ""' "$row")
  [ -n "$head" ] || return 0
  fm_pr_url_parse "$url" || return 0
  [ "$FM_PR_PROVIDER" = github ] || return 0
  jq -n --slurpfile pages "$comments" --arg bot "$bot" --arg marker "$marker" --arg head "$head" '
    [ ($pages[0] // [])[] | .[]?
      | select(((.user.login // "") == $bot) and ((.body // "") | contains($marker))) ]
    | sort_by(.id) | last
    | if . == null then {}
      else {token:("mq-drop:" + (.id | tostring) + ":" + $head),
            report:(.html_url // ""),body:(.body // "")} end' > "$TMP/event.json" \
    || fail 'the comment payload could not be read'
  token=$(jq -r '.token // ""' "$TMP/event.json")
  [ -n "$token" ] || return 0
  [ "$token" != "$(jq -r '.mq_drop.token // ""' "$row")" ] || return 0
  report=$(jq -r '.report' "$TMP/event.json")
  evidence "$row" "$TMP/event.json"
  "$SCRIPT_DIR/fm-send.sh" "$task" "$(steer_text "$url" "$report")" >/dev/null \
    || fail "steer for $task could not be delivered"
  staged=$(mktemp "$row.XXXXXX")
  jq --arg token "$token" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '.mq_drop={token:$token,at:$at}' "$row" > "$staged" \
    || { rm -f -- "$staged"; fail "the drop token for $task could not be recorded"; }
  mv -f -- "$staged" "$row"
  printf 'mq-drop-steer: %s %s %s\n' "$task" "$url" "${CHOSEN_NAME:-(no failing check named)}"
}

case "${1:-}" in
  handle)
    [ "$#" -eq 4 ] || fail 'handle needs a task id, a contribution row and a comment payload'
    handle "$2" "$3" "$4"
    ;;
  *) usage >&2; exit 2 ;;
esac
