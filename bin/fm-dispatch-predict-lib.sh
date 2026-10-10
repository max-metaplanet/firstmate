#!/usr/bin/env bash
# fm-dispatch-predict-lib.sh - append-only prediction log for fm-spawn.sh's
# dispatch-resolve auto-apply pilot (the investigation/scout rule only;
# docs/configuration.md "Crew dispatch profiles").
#
# fm_dispatch_predict_log <data-dir> <task-id> <resolver-json-or-empty> \
#   <auto_applied: true|false> <harness-used> <model-used> <effort-used>
#
# Appends one JSON object line to <data-dir>/dispatch-predictions.jsonl:
#   ts              UTC timestamp the line was written
#   task_id         the spawning task id
#   resolver_status the resolver's status field, or "off" when it produced no
#                   parseable JSON object (TYPESAFE_API_KEY absent, a
#                   never-send match, or no brief to resolve)
#   rule            the resolver's matched rule id, when present
#   chosen          the resolver's chosen {harness,model,effort}, or null
#                   unless status is clear
#   auto_applied    true only when the spawn launched on the resolver's own
#                   chosen profile
#   used            the profile fm-spawn.sh actually launched with
# No brief text, captain's intent, or secrets are recorded; <resolver-json>
# itself must already be the resolver's own --json output, never the brief.
#
# Logging never fails the spawn: a missing jq, an unwritable data directory,
# or malformed resolver JSON is reported on stderr and the function still
# returns 0.
fm_dispatch_predict_log() {
  local data_dir=$1 task_id=$2 resolver_json=$3 auto_applied=$4
  local harness=$5 model=$6 effort=$7
  local log="$data_dir/dispatch-predictions.jsonl" line ts
  command -v jq >/dev/null 2>&1 || {
    echo "warning: jq not installed; dispatch-resolve prediction for $task_id not logged" >&2
    return 0
  }
  case "$auto_applied" in
  true | false) ;;
  *) auto_applied=false ;;
  esac
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  line=$(jq -nc --arg ts "$ts" --arg task_id "$task_id" --arg harness "$harness" \
    --arg model "$model" --arg effort "$effort" --argjson auto_applied "$auto_applied" \
    --arg resolver_raw "$resolver_json" '
    (try ($resolver_raw | fromjson) catch null) as $r |
    {
      ts: $ts,
      task_id: $task_id,
      resolver_status: (if ($r | type) == "object" then ($r.status // "off") else "off" end),
      rule: (if ($r | type) == "object" then ($r.rule // null) else null end),
      chosen: (if ($r | type) == "object" then ($r.chosen.profile // null) else null end),
      auto_applied: $auto_applied,
      used: {
        harness: (if $harness == "" then null else $harness end),
        model: (if $model == "" then null else $model end),
        effort: (if $effort == "" then null else $effort end)
      }
    }') || {
    echo "warning: could not build dispatch-resolve prediction line for $task_id" >&2
    return 0
  }
  mkdir -p "$data_dir" 2>/dev/null || {
    echo "warning: could not create $data_dir; dispatch-resolve prediction for $task_id not logged" >&2
    return 0
  }
  printf '%s\n' "$line" >> "$log" 2>/dev/null || echo "warning: could not append $log" >&2
  return 0
}
