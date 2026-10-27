#!/usr/bin/env bash
# Worker parking record owner, shared by fm-worker-park.sh and read-only callers.
# state/<id>.park is an atomic, generation-and-endpoint-bound key=value record.
# phase=hint records an observer candidate; active remembers a consumed wait.
# phase=parking retains a slot until fm-control exit succeeds; parked releases
# it; queued retains the verified exit and adds a FIFO resume request. A new
# spawn_gen invalidates the record. Unknown or malformed records release nothing.
# Fields: phase, generation, endpoint, reason, until (epoch or 0), queued_at
# (epoch or 0), wake_reason, status_line, resume_error (0 or 1), failing_checks,
# event_token (the last explicitly identified observer event, or empty).
# failing_checks is the observer-supplied canonical set of red check identities
# this worker was last told about, retained across resume and re-park; an absent
# or unrecognized value makes a checks-failed resume request queue as before.
# Values are single lines, never sourced.
# Only fm-worker-park.sh writes these records; verified relaunch marks active.
# Guarded teardown removes the record after landing. Teardown remains the sole landed-work cleanup gate.
# Pending resumes sort by queued_at then full metadata path. Under a declared
# fleet or project cap each one reserves a place in that cap ahead of later
# resumes and fresh work (FM_WORKER_PARK_RESERVES); a resume_error hold
# reserves nothing until an explicit wake clears it, and fm-spawn reserves no
# fleet place for a resume its own project cap cannot admit yet.
# Requires fm_meta_get, fm_meta_get_to and fm_backend_target_of_meta_to. No side effects on source.

# <record> defaults to the metadata's own sibling. A caller reading a COPY of
# the metadata (bin/fm-fleet-snapshot.sh's captured generation) must name the
# live state record instead, because no park record sits beside the copy and a
# derived path would miss the park entirely. The generation and endpoint bind
# below still proves the record describes the metadata it is read against.
fm_worker_park_load() { # <meta> [<record>]
  local meta=$1 record=${2:-${1%.meta}.park} generation endpoint recorded_generation recorded_endpoint resume_error
  [ -f "$record" ] && [ ! -L "$record" ] && [ -r "$record" ] || return 1
  fm_meta_get_to FM_WORKER_PARK_PHASE "$record" phase
  case "$FM_WORKER_PARK_PHASE" in parked|queued) ;; *) return 1 ;; esac
  fm_meta_get_to generation "$meta" spawn_gen
  fm_backend_target_of_meta_to endpoint "$meta"
  fm_meta_get_to recorded_generation "$record" generation
  fm_meta_get_to recorded_endpoint "$record" endpoint
  [ "$recorded_generation" = "${generation:-legacy}" ] &&
    [ -n "$endpoint" ] && [ "$recorded_endpoint" = "$endpoint" ] || return 1
  fm_meta_get_to FM_WORKER_PARK_REASON "$record" reason
  fm_meta_get_to FM_WORKER_PARK_UNTIL "$record" until
  fm_meta_get_to FM_WORKER_PARK_QUEUED_AT "$record" queued_at
  case "$FM_WORKER_PARK_UNTIL:$FM_WORKER_PARK_QUEUED_AT" in *[!0-9:]*|:*|*:) return 1 ;; esac
  FM_WORKER_PARK_RESERVES=0
  fm_meta_get_to resume_error "$record" resume_error
  if [ "$FM_WORKER_PARK_PHASE" = queued ] && [ "$resume_error" != 1 ]; then
    FM_WORKER_PARK_RESERVES=1
  fi
  [ -n "$FM_WORKER_PARK_REASON" ]
}

fm_worker_park_rank() { # <own-meta>; reads queued_at<TAB>meta rows, prints how many precede own
  LC_ALL=C sort -t $'\t' -k1,1n -k2,2 |
    awk -F '\t' -v own="$1" '$2 == own { print NR - 1; found = 1; exit } END { if (!found) print NR }'
}

fm_worker_park_rows() { # <state>; prints queued_at<TAB>meta for every reserving resume
  local state meta rows=''
  fm_local_firstmate_state_dirs "$1" || return 1
  for state in "${FM_LOCAL_FIRSTMATE_STATES[@]}"; do
    for meta in "$state"/*.meta; do
      fm_worker_park_load "$meta" && [ "$FM_WORKER_PARK_RESERVES" = 1 ] || continue
      rows+="$FM_WORKER_PARK_QUEUED_AT"$'\t'"$meta"$'\n'
    done
  done
  printf '%s' "$rows"
}

# A terminal interrupted monitor has released validation custody, but is not
# CI-ready. Only the full contribution observer covers all its return events.
# Requires the caller's no-mistakes helpers and refuse_park diagnostic.
fm_worker_park_interrupted_ready() { # <meta> <axi-status> <state>
  local meta=$1 probe=$2 state=$3 wt branch pr head observed file now max_age task
  wt=$(fm_meta_get "$meta" worktree)
  branch=$(git -C "$wt" symbolic-ref --quiet --short HEAD) || { refuse_park "task branch could not be read"; return 1; }
  [ "$(fm_nm_strip_quotes "$(fm_nm_field "$probe" branch)")" = "$branch" ] || { refuse_park "interrupted run does not name the task branch"; return 1; }
  pr=$(fm_meta_get "$meta" pr)
  [ -n "$pr" ] && [ "$(fm_nm_strip_quotes "$(fm_nm_field "$probe" pr)")" = "$pr" ] || { refuse_park "interrupted run has no matching published PR"; return 1; }
  head=$(fm_nm_strip_quotes "$(fm_nm_field "$probe" head_sha)")
  if ! [[ "$head" =~ ^[a-fA-F0-9]{40}$ ]] || ! fm_nm_head_matches_worktree "$wt" "$head"; then
    refuse_park "interrupted run head is unconfirmed for this worktree"
    return 1
  fi
  if fm_nm_run_is_parked "$probe" || printf '%s\n' "$probe" | grep -Eq '^[[:space:]]*[^,]+,[[:space:]]*fixing,'; then
    refuse_park "interrupted run still has a validation gate or fix round"
    return 1
  fi
  if ! printf '%s\n' "$probe" | grep -Eq '^[[:space:]]*push,completed,' ||
    ! printf '%s\n' "$probe" | grep -Eq '^[[:space:]]*pr,completed,'; then
    refuse_park "pipeline push and PR publication are not completed"
    return 1
  fi
  # shellcheck source=bin/fm-pr-lib.sh
  . "${BASH_SOURCE[0]%/*}/fm-pr-lib.sh"
  # shellcheck source=bin/fm-check-lib.sh
  . "${BASH_SOURCE[0]%/*}/fm-check-lib.sh"
  fm_pr_url_parse "$pr" && [ "$FM_PR_PROVIDER" = github ] || { refuse_park "PR has no supported full contribution observer"; return 1; }
  fm_custom_check_registered "$state" contributions || { refuse_park "contribution observer is not authenticated and armed"; return 1; }
  task=${meta##*/}; task=${task%.meta}
  file="${FM_DATA_OVERRIDE:-$FM_HOME/data}/$task/contributions.json"
  [ -f "$file" ] && [ ! -L "$file" ] && [ "$(wc -c < "$file")" -le 1048576 ] || { refuse_park "contribution observer record is unavailable"; return 1; }
  now=$(date +%s)
  max_age=${FM_CONTRIBUTIONS_MAX_AGE:-900}
  observed=$(jq -L "${BASH_SOURCE[0]%/*}" -ner --arg task "$task" --arg url "$pr" --arg head "$head" --argjson now "$now" --argjson age "$max_age" --slurpfile saved "$file" '
    include "fm-contributions";
    $saved[0] | select(valid_record and .task == $task) | .records[]
    | select(.url == $url and .retired == null and .error == null and .observation.head == $head)
    | select((.checked_at | fromdateiso8601) as $at | $now >= $at and ($now - $at) <= $age)
    | .observation.head' 2>/dev/null) || { refuse_park "PR observer coverage is stale, unavailable, or on a different head"; return 1; }
  [ "$observed" = "$head" ] || { refuse_park "PR observer head is ambiguous"; return 1; }
  observed=$(fm_nm_bounded "$wt" 10 gh-axi api "repos/$FM_PR_PATH/pulls/$FM_PR_NUMBER" --jq '{head:.head.sha,state:.state}' 2>/dev/null) || { refuse_park "published PR head could not be read"; return 1; }
  [ "$(fm_nm_strip_quotes "$(fm_nm_field "$observed" head)")" = "$head" ] &&
    [ "$(fm_nm_strip_quotes "$(fm_nm_field "$observed" state)")" = open ] || { refuse_park "published PR head differs from pipeline head or PR is terminal"; return 1; }
}
