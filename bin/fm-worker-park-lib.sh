#!/usr/bin/env bash
# Worker parking record owner, shared by fm-worker-park.sh and read-only callers.
# state/<id>.park is an atomic, generation-and-endpoint-bound key=value record.
# phase=hint records an observer candidate; active remembers a consumed wait.
# phase=parking retains a slot until fm-control exit succeeds; parked releases
# it; queued retains the verified exit and adds a FIFO resume request. A new
# spawn_gen invalidates the record. Unknown or malformed records release nothing.
# Fields: phase, generation, endpoint, reason, until (epoch or 0), queued_at
# (epoch or 0), wake_reason, status_line, resume_error (0 or 1). Values are single lines, never sourced.
# Only fm-worker-park.sh writes these records; verified relaunch marks active.
# Guarded teardown removes the record after landing. Teardown remains the sole landed-work cleanup gate.
# Pending resumes sort by queued_at then full metadata path, before fresh work.
# Requires fm_meta_get and fm_backend_target_of_meta. No side effects on source.

fm_worker_park_load() { # <meta>
  local meta=$1 record=${1%.meta}.park generation endpoint
  [ -f "$record" ] && [ ! -L "$record" ] && [ -r "$record" ] || return 1
  FM_WORKER_PARK_PHASE=$(fm_meta_get "$record" phase)
  case "$FM_WORKER_PARK_PHASE" in parked|queued) ;; *) return 1 ;; esac
  generation=$(fm_meta_get "$meta" spawn_gen)
  endpoint=$(fm_backend_target_of_meta "$meta")
  [ "$(fm_meta_get "$record" generation)" = "${generation:-legacy}" ] &&
    [ -n "$endpoint" ] && [ "$(fm_meta_get "$record" endpoint)" = "$endpoint" ] || return 1
  FM_WORKER_PARK_REASON=$(fm_meta_get "$record" reason)
  FM_WORKER_PARK_UNTIL=$(fm_meta_get "$record" until)
  FM_WORKER_PARK_QUEUED_AT=$(fm_meta_get "$record" queued_at)
  case "$FM_WORKER_PARK_UNTIL:$FM_WORKER_PARK_QUEUED_AT" in *[!0-9:]*|:*|*:) return 1 ;; esac
  [ -n "$FM_WORKER_PARK_REASON" ]
}

fm_worker_park_front() { # <state>; prints full metadata path of first resume
  local state meta rows=''
  fm_local_firstmate_state_dirs "$1" || return 1
  for state in "${FM_LOCAL_FIRSTMATE_STATES[@]}"; do
    for meta in "$state"/*.meta; do
      fm_worker_park_load "$meta" || continue
      [ "$FM_WORKER_PARK_PHASE" = queued ] || continue
      rows+="$FM_WORKER_PARK_QUEUED_AT"$'\t'"$meta"$'\n'
    done
  done
  [ -n "$rows" ] || return 0
  printf '%s' "$rows" | LC_ALL=C sort -t $'\t' -k1,1n -k2,2 | head -1 | cut -f2-
}
