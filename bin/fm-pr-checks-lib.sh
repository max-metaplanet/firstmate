#!/usr/bin/env bash
# Shared GitHub required-check policy for merge verification and CI waits.
# Source this library; callers set PR_OWNER and PR_REPO from a validated URL.
# github_read_required_contexts <base> reads classic protection and effective
# rulesets, retaining producer bindings and errors in FM_PR_GITHUB_REQUIRED{,_ERROR}.
# github_checks_not_green <pr-json> <requirements-json> emits pending/red TAB name
# for required contexts; github_required_checks_missing also requires the
# current head's producers for app-bound requirements. When no requirements are
# configured, every reported check counts except a name/context containing the
# exact case-sensitive marker "(advisory)". Configured requirements always win.
# Read errors fail closed.
# The forge's required CI gate is treated like any other required context.

github_urlencode_path_segment() {
  local LC_ALL=C input=$1 encoded='' char octet hex
  while [ -n "$input" ]; do
    char=${input%"${input#?}"}
    input=${input#?}
    case "$char" in
      [-._~a-zA-Z0-9]) encoded=$encoded$char ;;
      *)
        printf -v octet '%d' "'$char"
        [ "$octet" -ge 0 ] || octet=$((octet + 256))
        printf -v hex '%02X' "$octet"
        encoded=$encoded%$hex
        ;;
    esac
  done
  printf '%s' "$encoded"
}

# Whether a failed branch-rules read (the gh stderr given) is GitHub's
# plan-gated 403 ("Upgrade to GitHub Pro or make this repository public"),
# which means the repository's plan cannot expose branch rules at all, on
# GitHub or GitHub Enterprise Server - not that this script failed to read
# them, and not that the token lacks a permission. Such a repository has no
# active ruleset rule of any kind. Any other failure (auth, rate limit,
# network, a 404, an unrelated 403) is not this and stays unreadable.
github_branch_rules_unavailable_on_plan() {
  case "$1" in
    *"Upgrade to GitHub Pro or make this repository public"*) return 0 ;;
  esac
  return 1
}

# Every counted GitHub check that is not green in the given live pull-request JSON, one
# name per line. An entry is green when it is a status context whose state is
# SUCCESS, or a check run that completed with SUCCESS, NEUTRAL, or SKIPPED (so
# a pending check is not green either). Exits nonzero when the rollup cannot be
# read, so a malformed answer is a failed read and never an empty red set.
#
# The rollup can hold several runs of one check name at the same head, because
# GitHub cancels a pull request's in-flight run when the base branch advances
# and re-triggers it; the cancelled run stays in the rollup beside the passing
# re-run. A check is therefore judged by its current run rather than by any run
# that a later one superseded, which is what makes this agree with GitHub's own
# CLEAN mergeStateStatus instead of refusing a pull request GitHub considers
# mergeable.
#
# Supersession applies only among check runs with the same reported name. A
# name is dropped from the red set only when every non-green run is COMPLETED,
# has a whole-second UTC startedAt, and started strictly before a green run.
# Status contexts are never grouped or superseded, and every non-green one is
# reported independently. A still-running, queued, undated, or tied check run
# stays red. A name whose runs are all green needs no timestamp, while a name
# with no green run stays red.
#
# The reported name is also what --allow-red matches. An unnamed check run is
# grouped alone and can neither supersede nor be superseded, because unrelated
# unnamed checks must not be treated as one.
#
# Each line is the check's state, a tab, then that reported name. The state is
# "pending" when every non-green run behind the name is one GitHub has not
# finished - a queued or running check run, a PENDING or EXPECTED status context
# - and "red" as soon as one of them has. That distinction is what lets the
# freshness re-verify wait for the lanes the branch update re-triggered without
# a second check evaluator, while a red check refuses either way.
github_checks_not_green() {
  local json=$1 required=$2
  printf '%s' "$json" | jq -r --argjson required "$required" '
    def settled_at:
      if type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")
      then . else null end;
    if (.statusCheckRollup | type) != "array" then error("no check rollup") else . end
    | [ .statusCheckRollup
        | to_entries[]
        | .key as $i
        | .value
        | select(
            (if .__typename == "CheckRun" then .name else .context end) as $name
            | if ($required | length) > 0 then any($required[]; .context == $name)
              else (($name // "") | contains("(advisory)") | not) end
          )
        | if .__typename == "CheckRun" then
            {
              kind: "check_run",
              name: (.name // ""),
              completed: (.status == "COMPLETED"),
              ok: (.status == "COMPLETED" and (.conclusion == "SUCCESS" or .conclusion == "NEUTRAL" or .conclusion == "SKIPPED")),
              at: (.startedAt | settled_at)
            }
            | . + {group: (if .name == "" then ["", $i] else [.name, -1] end)}
          else
            {
              kind: "status_context",
              name: (.context // ""),
              ok: (.state == "SUCCESS"),
              pending: (.state == "PENDING" or .state == "EXPECTED")
            }
          end
      ]
    | . as $entries
    | (
        ($entries[]
          | select(.kind == "status_context" and (.ok | not))
          | {name, pending}
        ),
        ($entries
          | [.[] | select(.kind == "check_run")]
          | group_by(.group)[]
          | {
              name: .[0].name,
              reds: [.[] | select(.ok | not)],
              newest_green: ([.[] | select(.ok) | .at | select(. != null)] | max)
            }
          | select(
              (.reds | length) > 0
              and (
                .newest_green == null
                or any(.reds[]; (.completed | not) or .at == null)
                or ([.reds[] | .at] | max) >= .newest_green
              )
            )
          | {name, pending: all(.reds[]; .completed | not)}
        )
      )
    | (if .pending then "pending" else "red" end)
      + "\t"
      + (if .name == "" then "(unnamed check)" else .name end)
  ' 2>/dev/null || return 1
}

# The live pull-request JSON without the runs of any check run whose latest run
# started before the given whole-second UTC bound (YYYY-MM-DDTHH:MM:SSZ)
# concluded SKIPPED, for a wait after a draft-to-ready transition: a draft-skipped
# check then needs a run at or after the bound, so a required one with no
# replacement is missing, while a replacement counts as usual, even SKIPPED.
# Every other check, including status contexts and completed non-skipped draft
# runs that are never re-triggered, is kept unchanged. Unnamed check runs are
# judged alone. Exits nonzero on an unreadable rollup or bound.
github_rollup_without_skips_before() {
  local json=$1 after=$2
  printf '%s' "$json" | jq -c --arg after "$after" '
    def settled_at:
      if type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")
      then . else null end;
    def earlier_run($i):
      if .__typename == "CheckRun" and ((.startedAt | settled_at) // $after) < $after
      then {key: (if (.name // "") == "" then "#\($i)" else .name end),
            at: .startedAt,
            skipped: (.status == "COMPLETED" and .conclusion == "SKIPPED")}
      else empty end;
    if ($after | settled_at) == null then error("invalid bound") else . end
    | if (.statusCheckRollup | type) != "array" then error("no check rollup") else . end
    | ([.statusCheckRollup | to_entries[] | .key as $i | .value | earlier_run($i)]
      | group_by(.key)
      | map(([.[].at] | max) as $latest | select(any(.[]; .at == $latest and .skipped)) | .[0].key)
      ) as $skipped
    | .statusCheckRollup |= [to_entries[] | .key as $i | .value
        | select([earlier_run($i) | .key] | any(. as $k | $skipped | index([$k])) | not)]
  ' 2>/dev/null || return 1
}

# Counted check names in the full rollup with no run left in the bounded one,
# one per line. Only needed when no requirements are configured; configured
# requirements already report the same gap as missing.
github_checks_without_fresh_run() {
  local json=$1 bounded=$2 required=$3
  [ "$required" = '[]' ] || return 0
  jq -nr --argjson full "$json" --argjson bounded "$bounded" '
    def check_name: (if .__typename == "CheckRun" then .name else .context end) // "";
    [$bounded.statusCheckRollup[] | check_name] as $fresh
    | [$full.statusCheckRollup[] | check_name | select(contains("(advisory)") | not)]
    | unique[] | select(. as $n | any($fresh[]; . == $n) | not)
    | if . == "" then "(unnamed check)" else . end
  ' 2>/dev/null || return 1
}

FM_PR_GITHUB_REQUIRED=
FM_PR_GITHUB_REQUIRED_ERROR=
github_read_required_contexts() {
  local base=$1 branch_path branch_json rules_json classic='' ruleset='' api_err api_err_text
  FM_PR_GITHUB_REQUIRED='[]'
  FM_PR_GITHUB_REQUIRED_ERROR=
  branch_path=$(github_urlencode_path_segment "$base")

  if ! branch_json=$(gh api "repos/$PR_OWNER/$PR_REPO/branches/$branch_path" 2>/dev/null) \
    || [ -z "$branch_json" ] \
    || ! classic=$(printf '%s' "$branch_json" | jq -c '
      if type != "object" or (.protected | type) != "boolean" then
        error("branch payload is unreadable")
      elif .protected == false then
        empty
      elif (.protection.required_status_checks | type) != "object" then
        error("branch protection summary is unreadable")
      else
        .protection.required_status_checks
        | ((.checks // []) | if type == "array" then .[] else error("invalid checks") end
           | {context, app_id}),
          ((.contexts // []) | if type == "array" then .[] else error("invalid contexts") end
           | {context: ., app_id: null})
        | if (.context | type) == "string" and (.context | length) > 0
             and (.app_id == null or (.app_id | type) == "number")
          then . else error("invalid required check") end
        | if .app_id == -1 then .app_id = null else . end
      end' 2>/dev/null); then
    classic=''
    FM_PR_GITHUB_REQUIRED_ERROR="the branch protection summary for base branch $base could not be read"
  fi

  if ! api_err=$(mktemp "${TMPDIR:-/tmp}/fm-pr-merge-required-rules.XXXXXX"); then
    FM_PR_GITHUB_REQUIRED_ERROR="${FM_PR_GITHUB_REQUIRED_ERROR:+$FM_PR_GITHUB_REQUIRED_ERROR
}the branch rules for base branch $base could not be read"
  else
    if ! rules_json=$(gh api --paginate "repos/$PR_OWNER/$PR_REPO/rules/branches/$branch_path" 2>"$api_err"); then
      api_err_text=$(cat "$api_err" 2>/dev/null)
      if ! github_branch_rules_unavailable_on_plan "$api_err_text"; then
        FM_PR_GITHUB_REQUIRED_ERROR="${FM_PR_GITHUB_REQUIRED_ERROR:+$FM_PR_GITHUB_REQUIRED_ERROR
}the branch rules for base branch $base could not be read"
      fi
    elif [ -z "$rules_json" ] || ! ruleset=$(printf '%s' "$rules_json" | jq -c '
        if type != "array" then error("rules payload is unreadable") else .[] end
        | select(type != "object" or .type == "required_status_checks")
        | if type == "object" and (.parameters.required_status_checks | type) == "array"
          then .parameters.required_status_checks[] else error("invalid required check rule") end
        | if type == "object" and (.context | type) == "string" and (.context | length) > 0
             and (.integration_id == null or (.integration_id | type) == "number")
          then {context, app_id: .integration_id} else error("invalid required check rule") end
        | if .app_id == -1 then .app_id = null else . end' 2>/dev/null); then
      ruleset=''
      FM_PR_GITHUB_REQUIRED_ERROR="${FM_PR_GITHUB_REQUIRED_ERROR:+$FM_PR_GITHUB_REQUIRED_ERROR
}the branch rules for base branch $base could not be read"
    fi
    rm -f "$api_err"
  fi

  FM_PR_GITHUB_REQUIRED=$(printf '%s\n%s\n' "$classic" "$ruleset" | jq -sc '
    unique_by([.context, .app_id]) | group_by(.context)
    | map(if any(.[]; .app_id != null) then map(select(.app_id != null)) else . end) | add // []')
  [ -z "$FM_PR_GITHUB_REQUIRED_ERROR" ]
}

# A required context absent from the rollup has not reported. An app-bound
# CheckRun also needs a same-named producer from that app at the verified head;
# a duplicate name-only requirement must not weaken that binding. StatusContext
# entries match by name because they carry no producer app id. Their creator's
# app binding cannot be verified here, so an attended admin merge can bypass
# that protection when a same-named status has reported. Unreadable producer
# evidence still refuses. Requirement reads retain every successful source
# even when another fails, allowing callers to report known missing checks
# alongside all lookup errors.
github_required_checks_missing() {
  local json=$1 required=$2 producers=$3
  printf '%s' "$json" | jq -r --argjson required "$required" --argjson producers "$producers" '
    if (.statusCheckRollup | type) != "array" then error("no check rollup") else . end
    | .statusCheckRollup as $reported
    | $required
    | map(. as $requirement
      | select(any($reported[];
          if $requirement.app_id == null then
            (if .__typename == "CheckRun" then .name else .context end) == $requirement.context
          elif .__typename == "CheckRun" then
            .name == $requirement.context
            and any($producers[]; .name == $requirement.context and .app.id == $requirement.app_id)
          else
            .context == $requirement.context
          end) | not)
      | .context) | unique[]
  ' 2>/dev/null || return 1
}


# Read producer evidence only when a required check is app-bound.
FM_PR_GITHUB_PRODUCERS='[]'
# The result is read by fm-pr-checks.sh and fm-pr-merge.sh.
# shellcheck disable=SC2034
github_read_required_producers() {
  local head=$1 runs
  FM_PR_GITHUB_PRODUCERS='[]'
  if printf '%s' "$FM_PR_GITHUB_REQUIRED" | jq -e 'any(.[]; .app_id != null)' >/dev/null; then
    if ! runs=$(gh api --paginate "repos/$PR_OWNER/$PR_REPO/commits/$head/check-runs" 2>/dev/null) \
      || [ -z "$runs" ] \
      || ! FM_PR_GITHUB_PRODUCERS=$(printf '%s' "$runs" | jq -sc --arg head "$head" '
        [ .[] | if (.check_runs | type) == "array" then .check_runs[] else error("invalid check runs") end
          | if (.name | type) == "string" and (.app.id | type) == "number" and .head_sha == $head
            then . else error("invalid check producer") end ]' 2>/dev/null); then
      FM_PR_GITHUB_PRODUCERS='[]'
      return 1
    fi
  fi
}
