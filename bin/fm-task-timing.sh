#!/usr/bin/env bash
# fm-task-timing.sh - record one task's delivery timings in Firstmate's own
# records, so a work-impact report can compute lead time and waiting time
# without re-deriving them from a transcript.
#
# Usage:
#   fm-task-timing.sh record <task-id>
#
# record appends the task's timings as one JSON object on one line of
# data/task-timing.jsonl, at most once per task incarnation (task id plus the
# record's spawn_gen): repeating it for an incarnation already in the ledger
# appends nothing, so a retried cleanup never counts a task twice.
# bin/fm-teardown.sh calls it for every ship task it cleans up, including one that
# released its slot claim, before it removes state/<id>.meta. The ledger is
# private and gitignored with the rest of data/.
#
# Never a gate. Every failure path exits 0 after writing at most a warning,
# because a timing record is a report input and cleanup has already succeeded by
# the time it is written; teardown additionally ignores a non-zero exit. The one
# exception is bad usage, which exits 2.
#
# Fields, each read from the durable record that owns it and written as JSON
# null when that record never carried it:
#   task           the task id
#   kind, mode     kind= and mode= from state/<id>.meta
#   project        the project directory's basename, from project=
#   ticket         ticket= - the ClickUp id, the explicit no-ticket marker, or
#                  null for a task dispatched before any ticket convention
#   commit_type    commit_type=
#   dispatched_at  dispatched_at=, written by the FRESH spawn and preserved
#                  across relaunches, so lead time measures the original
#                  dispatch rather than the latest incarnation
#   pr_opened_at   pr_at=, stamped by bin/fm-pr-check.sh when the pull request
#                  first became known
#   merged_at      state/<id>.merged-at, stamped by bin/fm-merge-outcome-lib.sh
#                  on a confirmed PR merge and by bin/fm-merge-local.sh on a
#                  local-only landing. It is its own record rather than a line
#                  in the task meta because the merge path must leave the
#                  canonical task record byte-identical.
#   pr_url         the last pr= line, which is the task's recorded pull request
#   spawn_gen      the incarnation this record was written for
#   recorded_at    when this line was appended
# A consumer computes lead time as merged_at - dispatched_at and the review wait
# as merged_at - pr_opened_at; a null endpoint means that leg is unmeasurable
# for this task rather than zero.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

[ "${1:-}" = record ] || { usage >&2; exit 2; }
ID=${2:-}
[ -n "$ID" ] || { usage >&2; exit 2; }
[ "$#" -eq 2 ] || { usage >&2; exit 2; }

FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
META="$STATE/$ID.meta"
LEDGER="$DATA/task-timing.jsonl"

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"

[ -f "$META" ] && [ ! -L "$META" ] || {
  echo "warning: no task record for $ID; recorded no timing line" >&2
  exit 0
}
[ -d "$DATA" ] && [ ! -L "$DATA" ] || {
  echo "warning: no data directory at $DATA; recorded no timing line for $ID" >&2
  exit 0
}

json_escape() { # <text> -> escaped JSON string content on stdout
  printf '%s' "$1" | awk '
    BEGIN { ORS = "" }
    {
      if (NR > 1) print "\\n"
      line = $0
      gsub(/\\/, "\\\\", line)
      gsub(/"/, "\\\"", line)
      gsub(/\t/, "\\t", line)
      gsub(/\r/, "\\r", line)
      # Any remaining C0 control character would break the JSON line record.
      gsub(/[\001-\010\013\014\016-\037]/, "", line)
      print line
    }'
}

# A string field, or JSON null when the record never carried it.
json_string_or_null() { # <value>
  if [ -z "$1" ]; then
    printf 'null'
  else
    printf '"%s"' "$(json_escape "$1")"
  fi
}

# An epoch field. A value that is not plain digits records no time at all, so it
# is reported as absent rather than written through as a number a consumer would
# arithmetic on.
json_epoch_or_null() { # <value>
  case "$1" in
    ''|*[!0-9]*) printf 'null' ;;
    *) printf '%s' "$1" ;;
  esac
}

SPAWN_GEN=$(fm_meta_get "$META" spawn_gen) || SPAWN_GEN=
# One line per incarnation. A legacy record with no spawn_gen is keyed by the
# task id alone, which is still at most one line per task.
GUARD="\"task\":\"$(json_escape "$ID")\",\"spawn_gen\":$(json_string_or_null "$SPAWN_GEN")"
if [ -f "$LEDGER" ] && [ ! -L "$LEDGER" ] && grep -qF -- "$GUARD" "$LEDGER" 2>/dev/null; then
  exit 0
fi

PROJECT=$(fm_meta_get "$META" project) || PROJECT=
[ -z "$PROJECT" ] || PROJECT=$(basename "$PROJECT")
# fm_meta_get takes the LAST line for a key, which is the task's current pull
# request exactly as bin/fm-teardown.sh resolves it.
PR_URL=$(fm_meta_get "$META" pr) || PR_URL=
MERGED_AT=
if [ -f "$STATE/$ID.merged-at" ] && [ ! -L "$STATE/$ID.merged-at" ]; then
  IFS= read -r MERGED_AT < "$STATE/$ID.merged-at" || MERGED_AT=
fi

LINE=$(printf '{%s,"kind":%s,"mode":%s,"project":%s,"ticket":%s,"commit_type":%s,"dispatched_at":%s,"pr_opened_at":%s,"merged_at":%s,"pr_url":%s,"recorded_at":%s}' \
  "$GUARD" \
  "$(json_string_or_null "$(fm_meta_get "$META" kind || true)")" \
  "$(json_string_or_null "$(fm_meta_get "$META" mode || true)")" \
  "$(json_string_or_null "$PROJECT")" \
  "$(json_string_or_null "$(fm_meta_get "$META" ticket || true)")" \
  "$(json_string_or_null "$(fm_meta_get "$META" commit_type || true)")" \
  "$(json_epoch_or_null "$(fm_meta_get "$META" dispatched_at || true)")" \
  "$(json_epoch_or_null "$(fm_meta_get "$META" pr_at || true)")" \
  "$(json_epoch_or_null "$MERGED_AT")" \
  "$(json_string_or_null "$PR_URL")" \
  "$(date +%s)") || {
  echo "warning: could not build $ID's timing line; cleanup is unaffected" >&2
  exit 0
}

umask 077
printf '%s\n' "$LINE" >> "$LEDGER" || {
  echo "warning: could not append $ID's timing line to $LEDGER; cleanup is unaffected" >&2
  exit 0
}
exit 0
