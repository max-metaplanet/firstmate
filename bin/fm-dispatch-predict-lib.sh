#!/usr/bin/env bash
# fm-dispatch-predict-lib.sh - append-only prediction log for fm-spawn.sh's
# dispatch-resolve auto-apply pilot (the investigation/scout rule only;
# docs/configuration.md "Automatic profile application (fm-spawn.sh)").
#
# fm_dispatch_predict_log <data-dir> <task-id> <resolver-json-or-empty> \
#   <fallback-status> <auto_applied: true|false> <harness-used> <model-used> \
#   <effort-used>
#
# Appends one JSON object line to <data-dir>/dispatch-predictions.jsonl:
#   ts              UTC timestamp the line was written
#   task_id         the spawning task id
#   resolver_status the resolver's status field, or <fallback-status> when it
#                   produced no parseable JSON object: "no-config" (no
#                   config/crew-dispatch.json), "not-run" (an explicit
#                   per-spawn choice, a relaunch, or a secondmate), "error"
#                   (the resolver failed, e.g. malformed config), or "off"
#                   (TYPESAFE_API_KEY absent, a never-send match, or no brief)
#   rule            the rule id (or "default") whose profiles the resolver
#                   selected, when present; after a min_confidence fallback
#                   this is the fallback rule, not the model's top pick
#   picked_rule     the resolver's top pick before any fallback, when present
#   confidence      the resolver's answer confidence, when present
#   chosen          the resolver's chosen {harness,model,effort}, or null
#                   unless status is clear
#   auto_applied    true only when the spawn launched on the resolver's own
#                   chosen profile
#   auto_apply_skipped  the resolver's reason an opted-in rule did not
#                   auto-apply (e.g. a floor fall-through to default), or null
#   used            the profile fm-spawn.sh actually launched with
#   requested_model / resolved_model  Jev request alias and provider-reported
#                   model, independently null when no request/identity exists
#   rubric_sha256   SHA-256 of jq compact sorted questions JSON + newline
#                   (no task state)
#   config_sha256   SHA-256 of compact sorted dispatch snapshot + model/base/
#                   timeout/confidence floor; no configuration content logged
#   policy_sha256   SHA-256 of never-send file bytes when available, else null
#   source_revision resolver checkout HEAD, with -dirty for tracked changes,
#                   or null outside a Git checkout
#   probability_summary {rule:{probabilities:{declared option: probability}}}
#                   for a validated answer; null when no valid answer exists
#   decided_by      jev or path-forced when known, otherwise null
# Resolver JSON carries these under provenance; this file owns the log schema.
# Hashes are evidence identifiers, not copies of the rubric or configuration.
# No brief text, captain's intent, or secrets are recorded; <resolver-json>
# itself must already be the resolver's own --json output, never the brief.
#
# Logging never fails the spawn: a missing jq, an unwritable data directory,
# or malformed resolver JSON is reported on stderr and the function still
# returns 0.
# Hash stdin without introducing a mandatory dependency into routing.
fm_dispatch_predict_sha256() {
  local digest=''
  if command -v shasum >/dev/null 2>&1; then
    digest=$(shasum -a 256 2>/dev/null)
  elif command -v sha256sum >/dev/null 2>&1; then
    digest=$(sha256sum 2>/dev/null)
  fi
  digest=${digest%% *}
  [[ "$digest" =~ ^[a-f0-9]{64}$ ]] && printf '%s' "$digest"
  return 0
}

fm_dispatch_predict_provenance() { # <rules-snapshot> <questions-json> <model> <base> <timeout> <floor> <policy-path> <source-root>
  local config_hash rubric_hash policy_hash='' revision='' dirty source_root top
  source_root=$(cd "$8" && pwd -P)
  top=$(git -C "$source_root" rev-parse --show-toplevel 2>/dev/null) || top=''
  rubric_hash=$(printf '%s' "$2" | jq -cS . | fm_dispatch_predict_sha256)
  config_hash=$(jq -cS -n --slurpfile rules "$1" --arg model "$3" --arg base "$4" \
    --arg timeout "$5" --arg floor "$6" \
    '{rules: $rules[0], model: $model, apiBase: $base, timeout: $timeout, confidence_floor: $floor}' | fm_dispatch_predict_sha256)
  if [ -f "$7" ] && [ -r "$7" ]; then
    policy_hash=$(fm_dispatch_predict_sha256 < "$7")
  fi
  if [ "$top" = "$source_root" ] && revision=$(git -C "$source_root" rev-parse HEAD 2>/dev/null); then
    if dirty=$(git -C "$source_root" status --porcelain --untracked-files=no 2>/dev/null); then
      [ -z "$dirty" ] || revision="$revision-dirty"
    else revision=''; fi
  else revision=''; fi
  jq -nc --arg rubric "$rubric_hash" --arg config "$config_hash" \
    --arg policy "$policy_hash" --arg revision "$revision" '
    def known: if . == "" then null else . end;
    {rubric_sha256: ($rubric | known), config_sha256: ($config | known),
     policy_sha256: ($policy | known), source_revision: ($revision | known),
     requested_model: null, resolved_model: null, probability_summary: null}'
}

fm_dispatch_predict_log() {
  local data_dir=$1 task_id=$2 resolver_json=$3 fallback_status=${4:-off}
  local auto_applied=$5 harness=$6 model=$7 effort=$8
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
    --arg resolver_raw "$resolver_json" --arg fallback_status "$fallback_status" '
    (try ($resolver_raw | fromjson) catch null) |
    (if type == "object" then . else null end) as $r |
    (if ($r.provenance | type) == "object" then $r.provenance else {} end) as $p |
    {
      requested_model: ($p.requested_model // null),
      resolved_model: ($p.resolved_model // null),
      rubric_sha256: ($p.rubric_sha256 // null),
      config_sha256: ($p.config_sha256 // null),
      policy_sha256: ($p.policy_sha256 // null),
      source_revision: ($p.source_revision // null),
      probability_summary: (if ($p.probability_summary.rule.probabilities | type) == "object" then
        {rule: {probabilities: ($p.probability_summary.rule.probabilities | with_entries(
          select((.key | test("^(rule_[1-9][0-9]*|default)$")) and
                 (.value | type) == "number" and .value >= 0 and .value <= 1)))}}
        else null end),
      decided_by: (if $r.decided_by == "path-forced" then "path-forced"
                   elif $p.requested_model != null then "jev" else null end),
      ts: $ts,
      task_id: $task_id,
      resolver_status: (if ($r | type) == "object" then ($r.status // $fallback_status) else $fallback_status end),
      rule: (if ($r | type) == "object" then ($r.applied_rule // $r.rule // null) else null end),
      picked_rule: (if ($r | type) == "object" then ($r.rule // null) else null end),
      confidence: (if ($r | type) == "object" then ($r.confidence // null) else null end),
      chosen: (if ($r | type) == "object" then ($r.chosen.profile // null) else null end),
      auto_applied: $auto_applied,
      auto_apply_skipped: (if ($r | type) == "object" then ($r.auto_apply_skipped // null) else null end),
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
