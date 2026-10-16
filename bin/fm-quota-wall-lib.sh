#!/usr/bin/env bash
# shellcheck disable=SC2034 # Recovery outcome globals are read by sourcing callers.
# fm-quota-wall-lib.sh - the VENDOR QUOTA WALL: a worker that is ALREADY RUNNING
# and stops because the vendor seat it launched on ran out of credits or hit a
# usage limit.
#
# WHY THIS EXISTS. Seat selection governs where a NEW worker launches
# (bin/fm-seat.sh, whose automatic switch moves the active seat for the next
# spawn and deliberately never disturbs a running one). A worker already under
# way is outside that reach: it stopped mid-task on a wall its own seat hit and
# - this is the whole difficulty - what stopped it also stopped its ability to
# say so, because appending a status line takes a turn and the wall is precisely
# that it cannot take one. Its supervisor therefore sees only a quiet pane,
# reads that as a possible wedge, and escalates a decision about a condition the
# records could have answered. The one condition that most needs declaring is
# the condition that prevents declaring anything, so the detector has to notice
# it from the pane rather than wait to be told.
#
# WHAT THIS FILE OWNS, in full:
#   1. RECOGNITION. Which vendor banner text means a wall, per vendor and per
#      class, and the one reading of a pane that mints that verdict.
#   2. THE EPISODE. What counts as one quota episode for one task, and the bound
#      of at most one automatic move inside it.
#   3. THE MOVE. Where the work goes, the handoff note it carries, and the
#      guarded relaunch that performs it.
#   4. THE SINGLE REFUSAL OUTCOME, raised once per episode when no seat
#      qualifies, naming every seat that was considered and why.
#
# WHAT THIS FILE DELIBERATELY DOES NOT OWN. Seat candidacy and the quota gate
# stay with bin/fm-seat.sh's `worker-destination`, which is the automatic
# rotation's own candidate set anchored on the worker's seat, so the
# destination minimum, the automatic-rotation exclusion, the quota floor's
# resting record, the proven-empty refusal and the paid extra-usage policy are
# applied here by the same code that applies them to a new launch and cannot
# drift from it. The relaunch transaction stays with bin/fm-control.sh, which
# preserves the worktree, the endpoint and every uncommitted change, refuses a
# destination seat that is not usable before the running agent stops, and
# publishes the new record only once the replacement launched.
#
# HOW A PANE READ CAN BE WRONG, and why that is acceptable. The verdict is a
# vendor string in a captured pane, so a pane that merely DISPLAYS that string
# while idle - this repository's own fixtures, a diff of this library - reads as
# a wall. The match is taken over the whole captured tail rather than a reduced
# non-blank tail on purpose: a boxed vendor banner renders many short border and
# padding lines that are not whitespace-only, and bin/fm-busy-lib.sh already
# records live evidence that such a reduction pushes a box's own heading out of
# view, so reducing here would miss the real wall to avoid a self-reference that
# costs far less. What makes the remaining error acceptable is the bound on the
# ACTION, not confidence in the string: at most one move per task per episode,
# the local copy and every uncommitted change preserved by the relaunch owner, a
# handoff note that states what happened, and one reported outcome line. A
# further guard is structural - a worker whose no-mistakes run is live reads as
# working from its run step, never as walled, so the move never orphans a
# pipeline (bin/fm-crew-state.sh's run-step precedence, and
# fm_quota_wall_line_class below, which is the one reader of that line).
#
# Recognition never rests on silence. An idle pane with no vendor banner is not
# a wall and stays on the existing stale path, unchanged.
#
# Needle provenance, and how it is kept honest: every string below was taken
# from the vendor's own shipped artifact, and
# tests/fm-quota-wall-banners-live-e2e.test.sh re-reads those artifacts and
# fails naming the harness and version when one is gone, because a vendor
# string that quietly disappears in an upgrade turns this whole detector off
# without a single test going red. tests/captures/ owns the recorded fixtures
# and their capture commands.

# Resolved from this file rather than a caller's variable so a test can source
# the library alone, and overridable so a test can stub the two commands this
# library shells out to without a real seat tree or a real agent.
_FM_QUOTA_WALL_LIB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
FM_QUOTA_WALL_SEAT_BIN="${FM_QUOTA_WALL_SEAT_BIN:-$_FM_QUOTA_WALL_LIB_DIR/fm-seat.sh}"
FM_QUOTA_WALL_CONTROL_BIN="${FM_QUOTA_WALL_CONTROL_BIN:-$_FM_QUOTA_WALL_LIB_DIR/fm-control.sh}"

# How long one quota episode lasts for one task. The bound is "one automatic
# move per task per episode", and an episode is the same vendor seat walling out
# again inside this window: a seat whose window has since reset and walled a
# second time a day later is a new episode and gets its own one move, while a
# seat that keeps reporting the same wall minute after minute never gets a
# second one.
FM_QUOTA_WALL_EPISODE_SECS_DEFAULT=86400

# Seconds the guarded relaunch may take before the bound fires. The relaunch
# owner's own waits are an exit wait plus a launch wait (bin/fm-control.sh's
# header owns both), so this sits above their sum rather than cutting a healthy
# transaction short, and it exists only so a supervisor poll stays bounded.
FM_QUOTA_WALL_MOVE_TIMEOUT_DEFAULT=180

# The one spelling of the detail component bin/fm-crew-state.sh mints for this
# state and fm_quota_wall_line_class below reads back. Written once so the
# producer and the consumer cannot drift.
FM_QUOTA_WALL_DETAIL_PREFIX='quota wall: '

# The state word this condition reports. A quota-blocked worker is neither
# stale nor waiting on a decision, and naming it as either is what sent the
# recovery playbook at a worker that nothing could recover.
FM_QUOTA_WALL_STATE=quota-blocked

fm_quota_wall_require_locks() {
  command -v fm_lock_try_acquire >/dev/null 2>&1 && return 0
  # shellcheck source=bin/fm-wake-lib.sh
  . "$_FM_QUOTA_WALL_LIB_DIR/fm-wake-lib.sh"
}

fm_quota_wall_require_timeout() {
  command -v fm_run_timed >/dev/null 2>&1 && return 0
  # shellcheck source=bin/fm-timeout-lib.sh
  . "$_FM_QUOTA_WALL_LIB_DIR/fm-timeout-lib.sh"
}

fm_quota_wall_require_meta() {
  command -v fm_meta_get >/dev/null 2>&1 && return 0
  # shellcheck source=bin/fm-backend.sh
  . "$_FM_QUOTA_WALL_LIB_DIR/fm-backend.sh"
}

# fm_quota_wall_vendor <harness>
# The credential vendor whose wall this library recognizes, or exit 1 for a
# harness it has no recorded banner text for. An unrecognized harness is not a
# guess: its stop stays on the existing stale path.
fm_quota_wall_vendor() {
  case "${1-}" in
    claude) printf 'claude\n' ;;
    codex)  printf 'codex\n' ;;
    *)      return 1 ;;
  esac
}

# fm_quota_wall_normalize <text>
# The same text with the vendors' typographic right single quote folded to the
# ASCII apostrophe. Both vendors mix the two WITHIN one build - Codex 0.162.0
# ships "You<U+2019>ve hit your usage limit" beside "You've reached your usage
# limit" - so folding here is what keeps one needle list from silently missing
# half the banners, and keeps a vendor flipping its apostrophe in an upgrade
# from turning the detector off.
fm_quota_wall_normalize() {
  local text=${1-} rsquo=$'\xe2\x80\x99' ascii="'"
  printf '%s' "${text//$rsquo/$ascii}"
}

# fm_quota_wall_classes <vendor>
# The wall classes of one vendor, MOST SPECIFIC FIRST, because a single pane can
# carry two of them: a Claude stop with paid extra usage exhausted renders its
# spend-limit banner beside the usage-limit one, and a Codex workspace out of
# credits renders the credit banner beside the usage wording. The first class
# that matches names the condition, so this order is the classification.
fm_quota_wall_classes() {
  case "${1-}" in
    codex)  printf '%s\n' out-of-credits usage-limit ;;
    claude) printf '%s\n' extra-usage usage-limit ;;
    *)      return 1 ;;
  esac
}

# fm_quota_wall_needles <vendor> <class>
# One recorded vendor banner string per line, ASCII-apostrophe form (the
# normalizer above folds the typographic variant before matching).
#
# Codex strings: extracted from @openai/codex 0.162.0's shipped
# vendor/aarch64-apple-darwin/bin/codex. "Your workspace is out of credits" is
# also the exact text observed on the two stopped workers that occasioned this
# library.
# Claude strings: extracted from the shipped Claude Code 2.1.301 executable.
# tests/captures/ owns the exact extraction commands and the recorded frames.
#
# A class carries several independent strings so no single one is load-bearing:
# any of them carries the verdict, and a release that drops one leaves the
# others answering while the live guard reports the loss.
fm_quota_wall_needles() {
  case "${1-}:${2-}" in
    codex:out-of-credits)
      cat <<'EOF'
Your workspace is out of credits
You're out of credits
You've reached your workspace credit limit
You hit your spend cap set in your workspace
You hit your spend cap set by the owner of your workspace
EOF
      ;;
    codex:usage-limit)
      cat <<'EOF'
You've hit your usage limit
You've reached your usage limit
Usage limit reached
EOF
      ;;
    claude:extra-usage)
      cat <<'EOF'
You've hit your monthly spend limit
You've hit your channel's monthly spend limit
You're out of extra usage
EOF
      ;;
    claude:usage-limit)
      cat <<'EOF'
Usage limit reached
you have reached your weekly usage limit
EOF
      ;;
    *) return 1 ;;
  esac
}

# fm_quota_wall_detect <harness> <pane-text>
# The whole recognition step: `<vendor> <class> <matched needle>` on stdout and
# exit 0 when this pane carries one vendor's recorded wall banner, exit 1
# otherwise. Pure, offline, and side-effect free; the caller owns having
# established that the pane is idle, because a BUSY pane showing a banner has
# already moved on from it.
fm_quota_wall_detect() {
  local vendor class needle text
  vendor=$(fm_quota_wall_vendor "${1-}") || return 1
  text=$(fm_quota_wall_normalize "${2-}")
  [ -n "$text" ] || return 1
  while IFS= read -r class; do
    [ -n "$class" ] || continue
    while IFS= read -r needle; do
      [ -n "$needle" ] || continue
      case "$text" in
        *"$needle"*)
          printf '%s %s %s\n' "$vendor" "$class" "$needle"
          return 0
          ;;
      esac
    done < <(fm_quota_wall_needles "$vendor" "$class")
  done < <(fm_quota_wall_classes "$vendor")
  return 1
}

# fm_quota_wall_detail <vendor> <class> <needle>
# The detail component bin/fm-crew-state.sh emits beside this state. It carries
# the matched text so a supervisor reading the line can see WHICH banner was
# read rather than trusting a bare label.
fm_quota_wall_detail() {
  printf '%s%s %s (matched "%s")\n' "$FM_QUOTA_WALL_DETAIL_PREFIX" "${1-}" "${2-}" "${3-}"
}

# fm_quota_wall_line_class <crew-state-line>
# Read one authoritative current-state line (bin/fm-crew-state.sh's output) and
# say what it means for a recovery decision. Prints one of:
#   wall <vendor> <class> <needle>  this worker is at a vendor quota wall
#   pipeline-live                   a no-mistakes run step answers for it, so a
#                                   relaunch would orphan live pipeline work
#   other                           anything else; ordinary triage owns it
#
# This is the only reader of that line here, so the wall verdict and the
# live-run refusal are both decided from one authoritative read, and the vendor,
# class and matched text the recovery acts on are the ones that read mints
# rather than a second opinion. A `working` or `parked` state sourced from the
# run step IS the live pipeline: that source is minted only by an attributed
# no-mistakes run, which is exactly the work a relaunch would orphan.
#
# A quota-blocked line whose detail cannot be parsed back into a known vendor
# and class reads `other`, not a wall: acting on a detail this library cannot
# recognize would be acting on a verdict nothing here produced.
fm_quota_wall_line_class() {
  local line=${1-} state src detail vendor class needle
  case "$line" in state:*) ;; *) printf 'other\n'; return 0 ;; esac
  state=${line#state: }
  state=${state%% *}
  src=${line#*source: }
  src=${src%% *}

  if [ "$state" = "$FM_QUOTA_WALL_STATE" ]; then
    case "$line" in
      *" $FM_QUOTA_WALL_DETAIL_PREFIX"*) detail=${line#*" $FM_QUOTA_WALL_DETAIL_PREFIX"} ;;
      *) printf 'other\n'; return 0 ;;
    esac
    vendor=${detail%% *}
    class=${detail#* }
    class=${class%% *}
    fm_quota_wall_needles "$vendor" "$class" >/dev/null 2>&1 || { printf 'other\n'; return 0; }
    case "$detail" in
      *'(matched "'*'")'*)
        needle=${detail#*'(matched "'}
        needle=${needle%%'")'*}
        ;;
      *) printf 'other\n'; return 0 ;;
    esac
    [ -n "$needle" ] || { printf 'other\n'; return 0; }
    printf 'wall %s %s %s\n' "$vendor" "$class" "$needle"
    return 0
  fi

  case "$state:$src" in
    working:run-step|parked:run-step) printf 'pipeline-live\n'; return 0 ;;
  esac
  printf 'other\n'
}

# fm_quota_wall_record_path <state-dir> <task>
fm_quota_wall_record_path() {
  printf '%s/.quota-wall-%s\n' "${1-}" "${2-}"
}

# fm_quota_wall_note_path <state-dir> <task>
# The handoff note the replacement worker was given, kept durable beside the
# episode record so what a worker was told is inspectable afterwards rather
# than only inside a relaunch journal.
fm_quota_wall_note_path() {
  printf '%s/.quota-wall-%s.note\n' "${1-}" "${2-}"
}

fm_quota_wall_record_field() {  # <record> <key>
  local value
  [ -f "${1-}" ] || return 1
  value=$(sed -n "s/^${2-}=//p" "$1" | tail -1) || return 1
  [ -n "$value" ] || return 1
  printf '%s\n' "$value"
}

fm_quota_wall_episode_secs() {
  local value=${FM_QUOTA_WALL_EPISODE_SECS:-}
  case "$value" in ''|*[!0-9]*|0) value=$FM_QUOTA_WALL_EPISODE_SECS_DEFAULT ;; esac
  printf '%s\n' "$value"
}

fm_quota_wall_move_timeout() {
  local value=${FM_QUOTA_WALL_MOVE_TIMEOUT:-}
  case "$value" in ''|*[!0-9]*|0) value=$FM_QUOTA_WALL_MOVE_TIMEOUT_DEFAULT ;; esac
  printf '%s\n' "$value"
}

# fm_quota_wall_episode_key <vendor> <seat>
# One episode is one vendor seat walling out: the seat is part of the identity
# because a worker moved off a walled seat onto a second one that walls out too
# is a genuinely new condition and gets its own single move. Every seat walled
# inside the window stays on the record and is never a destination again, which
# is what bounds the whole recovery at the number of seats rather than letting
# it loop between two of them.
fm_quota_wall_episode_key() {
  printf '%s:%s\n' "${1-}" "${2-}"
}

# 0 when <record> already names <key> and was opened inside the episode window.
fm_quota_wall_episode_current() {  # <record> <key> <now>
  local record=${1-} key=${2-} now=${3-} at
  [ "$(fm_quota_wall_record_field "$record" episode 2>/dev/null || true)" = "$key" ] || return 1
  at=$(fm_quota_wall_record_field "$record" at) || return 1
  case "$at" in ''|*[!0-9]*) return 1 ;; esac
  case "$now" in ''|*[!0-9]*) return 1 ;; esac
  [ "$now" -ge "$at" ] || return 1
  [ $(( now - at )) -lt "$(fm_quota_wall_episode_secs)" ]
}

# Replace the record with a fresh episode, carrying forward every seat a still
# current earlier episode walled on, and adding <seat>. Written whole and moved
# into place so a torn write cannot leave a record that claims a move it never
# made.
fm_quota_wall_episode_begin() {  # <record> <key> <class> <now> <seat>
  local record=${1-} now=${4-} tmp at walled=''
  at=$(fm_quota_wall_record_field "$record" at 2>/dev/null) || at=''
  case "$at:$now" in
    *[!0-9:]*|:*|*:) ;;
    *)
      if [ "$now" -ge "$at" ] \
        && [ $(( now - at )) -lt "$(fm_quota_wall_episode_secs)" ]; then
        walled=$(grep '^walled=' "$record" 2>/dev/null || true)
      fi
      ;;
  esac
  tmp=$(umask 077; mktemp "$record.XXXXXX") || return 1
  if ! { printf 'episode=%s\nclass=%s\nat=%s\n' "${2-}" "${3-}" "$now" \
      && { [ -z "$walled" ] || printf '%s\n' "$walled"; } \
      && printf 'walled=%s\n' "${5-}"; } > "$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi
  mv -f -- "$tmp" "$record"
}

fm_quota_wall_episode_mark() {  # <record> <key> <value>
  printf '%s=%s\n' "${2-}" "${3-}" >> "${1-}"
}

# 0 when this episode has already had its one automatic move or has already
# raised its one no-destination outcome. Either way nothing further is reported
# for it: the whole point of the bound is that a wall is acted on once and then
# stops being news on every poll.
fm_quota_wall_episode_spent() {  # <record>
  fm_quota_wall_record_field "${1-}" moved >/dev/null 2>&1 && return 0
  fm_quota_wall_record_field "${1-}" decided >/dev/null 2>&1
}

# fm_quota_wall_settled <state-dir> <task>
# 0 when the task's record holds an episode still inside its window that has
# already had its move or its decision - the cheap check a poller makes before
# paying for the authoritative read on a pane it has already seen.
fm_quota_wall_settled() {
  local record key
  record=$(fm_quota_wall_record_path "${1-}" "${2-}")
  key=$(fm_quota_wall_record_field "$record" episode 2>/dev/null) || return 1
  fm_quota_wall_episode_current "$record" "$key" "$(date +%s)" \
    && fm_quota_wall_episode_spent "$record"
}

# fm_quota_wall_seat_name <home> <vendor> <recorded-profile>
# The seat NAME a task's recorded profile directory belongs to. The record holds
# a profile path, while every report, every destination query and the handoff
# note speak in seat names, so this is where the two meet.
fm_quota_wall_seat_name() {
  local home=${1-} vendor=${2-} profile=${3-}
  FM_HOME="$home" "$FM_QUOTA_WALL_SEAT_BIN" --provider "$vendor" name-of "$profile" 2>/dev/null
}

# fm_quota_wall_destination <home> <vendor> <from-seat> <record>
# Where this worker's work can go, from the one owner of seat candidacy, never
# a seat the record says it already walled on. Sets FM_QUOTA_WALL_DEST to the
# destination seat and returns 0, or leaves it empty, sets
# FM_QUOTA_WALL_SKIPPED to every considered seat and its reason, and returns 1.
fm_quota_wall_destination() {
  local home=${1-} vendor=${2-} from=${3-} record=${4-} out rc=0 skipped seat
  local args=()
  FM_QUOTA_WALL_DEST=''
  FM_QUOTA_WALL_SKIPPED=''
  while IFS= read -r seat; do
    [ -z "$seat" ] || [ "$seat" = "$from" ] || args+=(--skip "$seat")
  done < <(sed -n 's/^walled=//p' "$record" 2>/dev/null)
  skipped=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-quota-wall-skipped.XXXXXX") || return 1
  out=$(env FM_HOME="$home" "$FM_QUOTA_WALL_SEAT_BIN" --provider "$vendor" \
    worker-destination --from "$from" ${args[@]+"${args[@]}"} 2>"$skipped") || rc=$?
  # The chooser reports one considered seat and its reason per line. Folded to
  # one line here, so a multi-seat refusal reads as a single reported sentence
  # rather than a block a wake row cannot carry; the final `error:` summary line
  # is dropped because the report states the outcome in its own words.
  FM_QUOTA_WALL_SKIPPED=$(grep -v '^error:' "$skipped" | tr '\n' ';' \
    | sed 's/;$//; s/;/; /g')
  rm -f -- "$skipped"
  [ "$rc" -eq 0 ] || return 1
  out=$(printf '%s\n' "$out" | sed -n '1p')
  [ -n "$out" ] || return 1
  FM_QUOTA_WALL_DEST=$out
}

# fm_quota_wall_note <task> <vendor> <class> <needle> <from> <to>
# The handoff note the replacement worker reads. It says what was running, that
# the stop was not about the work, where the work now runs, and that nothing was
# landed or discarded - which is the whole of what a worker inheriting a local
# copy but none of the conversation needs in order not to redo finished work.
# The relaunch owner supplies the surrounding "this task was relaunched,
# continue from here" framing and the inbox instruction, so this adds only the
# cause.
fm_quota_wall_note() {
  local task=${1-} vendor=${2-} class=${3-} needle=${4-} from=${5-} to=${6-}
  cat <<EOF
Why this relaunch happened: the $vendor seat this task was running on hit a
vendor wall, not a problem in the work. Its pane reported $class, matching the
vendor's own text "$needle", which stops the agent mid-task and also stops it
appending a status line about the stop.

The work has been moved from the $vendor seat $from to the $vendor seat $to,
which the seat check reports still has headroom. The local copy, the branch and
every uncommitted change are exactly as the previous worker left them: nothing
was committed, pushed, merged or discarded on anyone's behalf.

Re-establish where task $task actually stands from the local copy itself - the
branch's own commits, git status, and this task's status file - and carry on
from there. Do not repeat work that is already complete.
EOF
}

# fm_quota_wall_recover <home> <state-dir> <task> <harness> <pane-tail>
#                       <crew-state-line>
#
# The whole bounded response to one quota-walled worker, decided here so a
# supervisor needs no rule of its own. Sets:
#   FM_QUOTA_WALL_STATUS  moved | no-destination | pipeline-live | spent |
#                         refused
#   FM_QUOTA_WALL_REPORT  one supervisor-ready sentence, empty when the status
#                         is one the supervisor has already been told about
# and returns 0 when this wall was HANDLED here, so the caller's ordinary stale
# triage must not also escalate it, or 1 when it was not handled at all and that
# triage should run unchanged.
#
# The pane tail is the cheap evidence that this is worth a closer look; the
# crew-state line DECIDES, because it is the authoritative read and it applies
# run-step precedence. So:
#   - a line that reports the wall is acted on, using the vendor, class and
#     matched text that read minted rather than a second opinion;
#   - a line that reports a live no-mistakes run step is REPORTED and never
#     moved, because a relaunch would discard that run; the episode keeps its
#     one move for later, when the run is no longer live and the worker's own
#     wall is what remains;
#   - any other line is not handled here at all.
#
# `spent` is the ordinary steady state after the first act: this episode already
# had its one move, already raised its one refusal, or already reported its live
# run, so the wall is handled and silent. That silence is deliberate - it is the
# whole difference between acting once and re-alarming every few minutes for an
# hour.
fm_quota_wall_recover() {
  local home=${1-} state=${2-} task=${3-} harness=${4-} tail=${5-} line=${6-}
  local record note from now key lock rc=0 out verdict vendor class needle
  local meta profile detected
  FM_QUOTA_WALL_STATUS=refused
  FM_QUOTA_WALL_REPORT=''

  fm_quota_wall_require_locks || return 1
  fm_quota_wall_require_timeout || return 1
  fm_quota_wall_require_meta || return 1

  detected=$(fm_quota_wall_detect "$harness" "$tail") || return 1
  verdict=$(fm_quota_wall_line_class "$line")
  case "$verdict" in
    wall\ *)
      read -r _ vendor class needle <<< "$verdict"
      ;;
    pipeline-live)
      # No wall detail on this line to read, so the vendor and class come from
      # the pane evidence that brought us here. Nothing is moved on them.
      read -r vendor class needle <<< "$detected"
      ;;
    *) return 1 ;;
  esac

  record=$(fm_quota_wall_record_path "$state" "$task")
  note=$(fm_quota_wall_note_path "$state" "$task")
  lock="$state/.quota-wall-$task.lock"
  meta="$state/$task.meta"
  profile=$(fm_meta_get "$meta" "${vendor}_seat" 2>/dev/null || true)

  # Nonblocking: another pass is already acting on this exact task, so this one
  # has nothing to add and must not escalate behind its back.
  if ! fm_lock_try_acquire "$lock"; then
    FM_QUOTA_WALL_STATUS=spent
    return 0
  fi

  from=$(fm_quota_wall_seat_name "$home" "$vendor" "$profile")
  if [ -z "$from" ]; then
    fm_lock_release "$lock" 2>/dev/null || true
    FM_QUOTA_WALL_STATUS=refused
    FM_QUOTA_WALL_REPORT="task $task reports a $vendor $class wall, but the seat it launched on could not be resolved from its own record, so nothing was moved"
    return 0
  fi

  now=$(date +%s)
  key=$(fm_quota_wall_episode_key "$vendor" "$from")
  if fm_quota_wall_episode_current "$record" "$key" "$now"; then
    if fm_quota_wall_episode_spent "$record"; then
      fm_lock_release "$lock" 2>/dev/null || true
      FM_QUOTA_WALL_STATUS=spent
      return 0
    fi
    if [ "$verdict" = pipeline-live ] \
      && fm_quota_wall_record_field "$record" pipeline >/dev/null 2>&1; then
      # Already reported for this episode. The move is NOT spent by that
      # report: when the run is no longer live, this episode still has its one
      # move for the worker's own wall.
      fm_lock_release "$lock" 2>/dev/null || true
      FM_QUOTA_WALL_STATUS=spent
      return 0
    fi
  elif ! fm_quota_wall_episode_begin "$record" "$key" "$class" "$now" "$from"; then
    fm_lock_release "$lock" 2>/dev/null || true
    FM_QUOTA_WALL_STATUS=refused
    FM_QUOTA_WALL_REPORT="task $task reports a $vendor $class wall on seat $from, but its episode record at $record could not be written, so nothing was moved"
    return 0
  fi

  if [ "$verdict" = pipeline-live ]; then
    fm_quota_wall_episode_mark "$record" pipeline "$now" || true
    fm_lock_release "$lock" 2>/dev/null || true
    FM_QUOTA_WALL_STATUS=pipeline-live
    FM_QUOTA_WALL_REPORT="task $task shows a $vendor $class wall in its own window while its validation run is still live, so nothing was moved - a move would discard that run; it will be moved off seat $from once the run is no longer live"
    return 0
  fi

  if ! fm_quota_wall_destination "$home" "$vendor" "$from" "$record"; then
    # A marker that cannot be written leaves the outcome to repeat on the next
    # poll rather than to disappear, which is the right direction for something
    # the captain is being asked to decide.
    fm_quota_wall_episode_mark "$record" decided "$now" || true
    fm_lock_release "$lock" 2>/dev/null || true
    FM_QUOTA_WALL_STATUS=no-destination
    FM_QUOTA_WALL_REPORT="task $task stopped on the $vendor seat $from ($class) and no $vendor seat qualifies to take it over: ${FM_QUOTA_WALL_SKIPPED:-no candidate seat was reported}"
    return 0
  fi

  if ! fm_quota_wall_note "$task" "$vendor" "$class" "$needle" "$from" \
    "$FM_QUOTA_WALL_DEST" > "$note"; then
    fm_lock_release "$lock" 2>/dev/null || true
    FM_QUOTA_WALL_STATUS=refused
    FM_QUOTA_WALL_REPORT="task $task reports a $vendor $class wall on seat $from and the seat $FM_QUOTA_WALL_DEST can take it over, but its handoff note at $note could not be written, so nothing was moved"
    return 0
  fi

  # The move is marked BEFORE the relaunch, not after. A relaunch that starts
  # and then cannot be proven leaves a worker this episode must not move a
  # second time, and a marker written only on success would let the next poll
  # try again on top of a transaction already under way.
  fm_quota_wall_episode_mark "$record" moved "$FM_QUOTA_WALL_DEST" || true
  # The home is passed through `env` rather than as an assignment prefixing this
  # function call, because bash keeps such an assignment after a FUNCTION
  # returns and this library is also sourced where FM_HOME must not be rewritten.
  out=$(fm_run_timed "$(fm_quota_wall_move_timeout)" \
    env FM_HOME="$home" "$FM_QUOTA_WALL_CONTROL_BIN" "$task" relaunch \
    --seat "$FM_QUOTA_WALL_DEST" --note-file "$note" 2>&1) || rc=$?
  fm_lock_release "$lock" 2>/dev/null || true

  if [ "$rc" -eq 0 ]; then
    FM_QUOTA_WALL_STATUS=moved
    FM_QUOTA_WALL_REPORT="task $task hit a $vendor $class wall on seat $from and was moved to seat $FM_QUOTA_WALL_DEST; its local copy and uncommitted work are untouched and it was told why it moved"
    return 0
  fi
  FM_QUOTA_WALL_STATUS=refused
  FM_QUOTA_WALL_REPORT="task $task hit a $vendor $class wall on seat $from and the move to seat $FM_QUOTA_WALL_DEST failed: $(printf '%s\n' "$out" | sed -n '1s/[[:space:]]\{1,\}/ /gp')"
  return 0
}
