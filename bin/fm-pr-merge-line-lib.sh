#!/usr/bin/env bash
# fm-pr-merge-line-lib.sh - the per-repository firstmate merge line (one owner).
#
# WHY. bin/fm-pr-merge.sh updates a BEHIND pull request's branch and waits for
# the re-triggered required lanes before merging it at the new head. That is
# correct for one pull request and self-defeating for several: every merge into
# a base branch puts every other open pull request behind it, so N firstmate
# pull requests ready at once produce N branch updates per merge and each update
# restarts CI on a head the next merge invalidates again. The line makes
# firstmate merge one pull request per repository at a time, oldest-ready first,
# and lets only the pull request at the head of the line update its branch, so
# firstmate's next merge cannot invalidate another of firstmate's own pull
# requests mid-CI.
#
# SCOPE. Merges originate from the main home AND from every secondmate home on
# this machine, each a separate process with its own FM_HOME, so a home-local
# record cannot serialize them. The line is therefore machine-wide per
# repository, for the same reason bin/fm-procevent-lib.sh's claim root is
# machine-wide per source, and lives beside it under the same
# XDG_STATE_HOME/firstmate root. It serializes firstmate's own merges only;
# nothing else merging that repository is visible to it, and nothing here is a
# substitute for the forge's own rules.
#
# PRIMITIVE. The turn is the ordinary lock from bin/fm-wake-lib.sh
# (fm_lock_try_acquire and friends) taken on a machine-wide path, not a new
# mechanism: that lock already records its holder's pid, already elects exactly
# one reaper for a dead holder, and already resolves the steal races a hand-
# rolled lease would have to re-derive. A crashed holder is therefore recovered
# by the primitive's own rules, plus the line's own reclaim of a turn no
# surviving ticket owns (see CONTRACT), and the line cannot wedge on it.
#
# CONTRACT.
#   - Root: $FM_PR_MERGE_LINE_ROOT, else
#     ${XDG_STATE_HOME:-$HOME/.local/state}/firstmate/pr-merge-line, created 0700.
#   - Per repository: <slug>.lock serializes the short line inspections,
#     <slug>.turn is the turn itself, held across the whole update/wait/merge,
#     and <slug>.line/ holds one ticket file per enrolled run. The slug is a
#     readable provider-and-path prefix plus a short hash of the exact
#     provider|host|path identity, so two repositories whose readable forms
#     sanitize alike still get separate lines.
#   - Ticket name: <class><020d-epoch>-<pid>, read as three numbers. Class 0 is
#     a KNOWN ready time and sorts ahead of class 1, an UNKNOWN one; within a
#     class the older epoch wins, and the pid breaks a remaining tie. So the
#     order is oldest-ready first, with runs whose ready time is unknown behind
#     every known one in the order they enrolled. The ticket's first line is
#     the pull request URL, used only to name who is ahead in a refusal; its
#     second is the enrolling process's fm_pid_identity, so a pid the OS has
#     since handed to another process does not keep the ticket alive.
#   - Ready time comes from an existing durable record - the [at=] stamp of the
#     earliest status event naming that pull request, which is the ready report
#     bin/fm-pr-check.sh registered - and is never inferred when that record is
#     missing or malformed, per bin/fm-classify-lib.sh's rule that a missing or
#     malformed time means UNKNOWN. The enrollment clock orders the unknowns
#     among themselves and is not recorded as anyone's ready time.
#   - Only the ticket at the head of the line attempts the turn, so a run
#     waiting its turn changes nothing on the forge: no branch update and no
#     merge.
#   - The wait is bounded per turn, not once: FM_PR_MERGE_LINE_TIMEOUT seconds
#     (polled every FM_PR_MERGE_LINE_POLL seconds, default 20) restart every
#     time the head of the line changes, because a new head is the observable
#     sign that the line moved. A waiter therefore refuses only when the run
#     ahead of it made no progress for one whole bound, however many runs were
#     ahead of it when it joined, and keeps its place for as long as the line
#     keeps moving. The default is one full holder turn: two freshness rounds
#     of FM_PR_GITHUB_FRESHNESS_TIMEOUT each - the cap bin/fm-pr-merge.sh puts
#     on branch updates - plus a third as margin for its mergeable retries and
#     the merge itself. A spent bound refuses in plain words naming the
#     repository and the pull request ahead. A refusal is retryable: nothing
#     was merged and the next run re-enters the line.
#   - Every stale ticket - a dead pid, a live pid whose identity reads back
#     different from the recorded one, or a ticket this library did not write -
#     is pruned under the line lock before the head is read, so a crashed run
#     cannot hold the line any longer than its own process lives. The turn
#     follows the same rule: a turn whose recorded pid belongs to no surviving
#     ticket is reclaimed by the head of the line, so a reused pid cannot keep
#     a dead holder's turn either. A live pid whose identity cannot be read
#     right now keeps its ticket: an unreadable identity is no proof of
#     staleness, as in fm_autoarm_claim_abandoned.
#
# Sourced by bin/fm-pr-merge.sh after bin/fm-wake-lib.sh. Callers must have the
# lock helpers available or let the lazy fallback below source them. No side
# effects on source. set -u / set -e safe.

FM_PR_MERGE_LINE_LIB_DIR="$(d=${BASH_SOURCE[0]%/*}; [ "$d" != "${BASH_SOURCE[0]}" ] || d=.; cd "${d:-/}" && pwd)"
FM_PR_MERGE_LINE_TICKET=
FM_PR_MERGE_LINE_TURN=
FM_PR_MERGE_LINE_HELD=0

_fm_pr_merge_line_helpers() {
  command -v fm_lock_try_acquire >/dev/null 2>&1 && return 0
  # Same analysis boundary as bin/fm-lease-lib.sh's lazy fallback: every
  # production caller sources fm-wake-lib.sh itself, and traversing it here
  # would duplicate that whole graph for every consumer of this leaf lib.
  # shellcheck source=/dev/null
  . "$FM_PR_MERGE_LINE_LIB_DIR/fm-wake-lib.sh"
}

# The [at=] grammar's owner is loaded on demand, exactly as fm-wake-lib.sh
# loads it, so this leaf never depends on which other library a caller happens
# to have sourced first.
_fm_pr_merge_line_classify() {
  command -v status_line_at_epoch >/dev/null 2>&1 && return 0
  # shellcheck source=bin/fm-classify-lib.sh
  . "$FM_PR_MERGE_LINE_LIB_DIR/fm-classify-lib.sh"
}

fm_pr_merge_line_root() {
  printf '%s\n' "${FM_PR_MERGE_LINE_ROOT:-${XDG_STATE_HOME:-$HOME/.local/state}/firstmate/pr-merge-line}"
}

# fm_pr_merge_line_slug <provider> <host> <path>: the repository's line name.
# The readable prefix keeps a listing legible; the hash of the exact identity
# is what makes the mapping injective, because sanitizing "a-b/c" and "a/b-c"
# would otherwise collide and silently serialize two repositories together.
fm_pr_merge_line_slug() {
  local provider=$1 host=$2 path=$3 readable hash identity
  identity="$provider|$host|$path"
  readable=$(printf '%s-%s' "$provider" "$path" \
    | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9._-' '-') || return 1
  readable=${readable:0:48}
  if command -v shasum >/dev/null 2>&1; then
    hash=$(printf '%s' "$identity" | shasum -a 256 | awk '{print substr($1,1,8)}')
  elif command -v sha256sum >/dev/null 2>&1; then
    hash=$(printf '%s' "$identity" | sha256sum | awk '{print substr($1,1,8)}')
  else
    hash=$(printf '%s' "$identity" | cksum | awk '{printf "%08x", $1}')
  fi
  [ -n "$hash" ] || return 1
  printf '%s-%s\n' "$readable" "$hash"
}

# fm_pr_merge_line_ready_epoch <status-file> <url>: the recorded ready time for
# that pull request, as the earliest [at=] stamp on a status event naming it.
# Returns non-zero - UNKNOWN - when the file, the event, or the stamp is
# missing or malformed; the caller must not substitute a clock for it.
fm_pr_merge_line_ready_epoch() {
  local file=$1 url=$2 line epoch best=''
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  _fm_pr_merge_line_classify
  while IFS= read -r line || [ -n "$line" ]; do
    # A bare substring match would read ".../pull/9" out of ".../pull/90", so
    # the URL has to end the line or be followed by a non-digit.
    case "$line" in
      *"$url") ;;
      *"$url"[!0-9]*) ;;
      *) continue ;;
    esac
    epoch=$(status_line_at_epoch "$line") || continue
    if [ -z "$best" ] || [ "$epoch" -lt "$best" ]; then
      best=$epoch
    fi
  done < "$file"
  [ -n "$best" ] || return 1
  printf '%s\n' "$best"
}

# _fm_pr_merge_line_ticket_fields <name>: split a ticket name into
# FM_PR_MERGE_LINE_F_CLASS, _F_EPOCH and _F_PID. Non-zero for any name this
# library did not write, which the caller prunes rather than ordering by.
_fm_pr_merge_line_ticket_fields() {
  local name=$1 key pid
  key=${name%%-*}
  pid=${name#*-}
  [ "$key" != "$name" ] || return 1
  [ "${#key}" -eq 21 ] || return 1
  case "$key" in [01]*) ;; *) return 1 ;; esac
  case "${key#?}" in ''|*[!0-9]*) return 1 ;; esac
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  FM_PR_MERGE_LINE_F_CLASS=${key:0:1}
  # Base-10 forced: twenty digits are zero-padded, and bash would otherwise
  # read the leading zero as an octal prefix and reject the digits 8 and 9.
  FM_PR_MERGE_LINE_F_EPOCH=$((10#${key:1}))
  FM_PR_MERGE_LINE_F_PID=$pid
}

# _fm_pr_merge_line_head <line-dir>: prune every stale ticket, then set
# FM_PR_MERGE_LINE_HEAD_NAME and FM_PR_MERGE_LINE_HEAD_URL to the oldest-ready
# survivor and FM_PR_MERGE_LINE_PIDS to every survivor's pid, space-delimited.
# Non-zero when the line is empty. Caller holds the line lock.
_fm_pr_merge_line_head() {
  local dir=$1 entry name recorded current
  local best_class='' best_epoch='' best_pid='' better
  FM_PR_MERGE_LINE_HEAD_NAME=
  FM_PR_MERGE_LINE_HEAD_URL=
  FM_PR_MERGE_LINE_PIDS=' '
  for entry in "$dir"/*; do
    [ -f "$entry" ] || continue
    name=${entry##*/}
    if ! _fm_pr_merge_line_ticket_fields "$name"; then
      rm -f -- "$entry"
      continue
    fi
    recorded=$(sed -n '2p' "$entry" 2>/dev/null || true)
    if [ -z "$recorded" ] || ! fm_pid_alive "$FM_PR_MERGE_LINE_F_PID"; then
      rm -f -- "$entry"
      continue
    fi
    current=$(fm_pid_identity "$FM_PR_MERGE_LINE_F_PID" 2>/dev/null || true)
    if [ -n "$current" ] && [ "$current" != "$recorded" ]; then
      rm -f -- "$entry"
      continue
    fi
    FM_PR_MERGE_LINE_PIDS="$FM_PR_MERGE_LINE_PIDS$FM_PR_MERGE_LINE_F_PID "
    better=false
    if [ -z "$best_class" ]; then
      better=true
    elif [ "$FM_PR_MERGE_LINE_F_CLASS" -lt "$best_class" ]; then
      better=true
    elif [ "$FM_PR_MERGE_LINE_F_CLASS" -eq "$best_class" ]; then
      if [ "$FM_PR_MERGE_LINE_F_EPOCH" -lt "$best_epoch" ]; then
        better=true
      elif [ "$FM_PR_MERGE_LINE_F_EPOCH" -eq "$best_epoch" ] \
        && [ "$FM_PR_MERGE_LINE_F_PID" -lt "$best_pid" ]; then
        better=true
      fi
    fi
    if [ "$better" = true ]; then
      best_class=$FM_PR_MERGE_LINE_F_CLASS
      best_epoch=$FM_PR_MERGE_LINE_F_EPOCH
      best_pid=$FM_PR_MERGE_LINE_F_PID
      FM_PR_MERGE_LINE_HEAD_NAME=$name
      FM_PR_MERGE_LINE_HEAD_URL=$(head -n 1 "$entry" 2>/dev/null || true)
    fi
  done
  [ -n "$FM_PR_MERGE_LINE_HEAD_NAME" ]
}

# _fm_pr_merge_line_take_turn <turn>: take the turn for the head of the line.
# Every turn is taken under the line lock by a run holding a ticket, and a
# holder drops its ticket only on its way out, so a turn whose recorded pid is
# alive but belongs to no surviving ticket was left by a run that died without
# releasing it and whose pid the OS has since reused. That turn is reclaimed;
# a holder already mid-release loses nothing, since fm_lock_release only
# removes a turn that still records its own pid. Caller holds the line lock
# and has just run _fm_pr_merge_line_head.
_fm_pr_merge_line_take_turn() {
  local turn=$1
  fm_lock_try_acquire "$turn" && return 0
  [ -n "$FM_LOCK_HELD_PID" ] || return 1
  case "$FM_PR_MERGE_LINE_PIDS" in *" $FM_LOCK_HELD_PID "*) return 1 ;; esac
  fm_lock_remove_path "$turn" || return 1
  fm_lock_try_acquire "$turn"
}

# fm_pr_merge_line_enter <provider> <host> <path> <url> <ready-epoch|''>
# Join the repository's line and return once this run holds the turn. Returns
# non-zero after reporting a plain refusal when the bound is spent; nothing has
# been merged or updated at that point, so the caller simply refuses too.
fm_pr_merge_line_enter() {
  local provider=$1 host=$2 path=$3 url=$4 ready=$5
  local root slug dir lock turn pid identity now deadline class key tmp timeout
  local poll ahead head_seen freshness
  _fm_pr_merge_line_helpers

  freshness=${FM_PR_GITHUB_FRESHNESS_TIMEOUT:-480}
  case "$freshness" in
    ''|*[!0-9]*) freshness=480 ;;
    *) [ "${#freshness}" -le 5 ] || freshness=480 ;;
  esac
  timeout=${FM_PR_MERGE_LINE_TIMEOUT:-$((3 * freshness))}
  case "$timeout" in
    ''|*[!0-9]*) timeout=$((3 * freshness)) ;;
    *) [ "${#timeout}" -le 5 ] || timeout=$((3 * freshness)) ;;
  esac
  poll=${FM_PR_MERGE_LINE_POLL:-20}
  case "$poll" in
    ''|*[!0-9]*) poll=20 ;;
    *) [ "${#poll}" -le 4 ] || poll=20 ;;
  esac

  root=$(fm_pr_merge_line_root) || return 1
  slug=$(fm_pr_merge_line_slug "$provider" "$host" "$path") || return 1
  dir="$root/$slug.line"
  lock="$root/$slug.lock"
  turn="$root/$slug.turn"
  if ! (umask 077; mkdir -p "$dir") \
    || [ ! -d "$root" ] || [ -L "$root" ] || [ ! -d "$dir" ] || [ -L "$dir" ]; then
    printf 'error: refusing to merge %s: the firstmate merge line for %s/%s could not be opened at %s; nothing was merged\n' \
      "$url" "$host" "$path" "$root" >&2
    return 1
  fi

  fm_current_pid pid || return 1
  if ! identity=$(fm_pid_identity "$pid") || [ -z "$identity" ]; then
    printf 'error: refusing to merge %s: this run could not record its own process identity for the firstmate merge line for %s/%s; nothing was merged\n' \
      "$url" "$host" "$path" >&2
    return 1
  fi
  fm_epoch_seconds_to now
  if [ -n "$ready" ]; then
    class=0
  else
    class=1
    ready=$now
  fi
  key=$(printf '%s%020d' "$class" "$ready") || return 1
  FM_PR_MERGE_LINE_TURN=$turn
  FM_PR_MERGE_LINE_TICKET="$dir/$key-$pid"
  tmp="$dir/.ticket.$pid"
  if ! printf '%s\n%s\n' "$url" "$identity" > "$tmp" || ! chmod 0600 "$tmp" \
    || ! mv -f -- "$tmp" "$FM_PR_MERGE_LINE_TICKET"; then
    rm -f -- "$tmp"
    FM_PR_MERGE_LINE_TICKET=
    printf 'error: refusing to merge %s: this run could not take its place in the firstmate merge line for %s/%s; nothing was merged\n' \
      "$url" "$host" "$path" >&2
    return 1
  fi

  deadline=$((now + timeout))
  ahead=
  head_seen=
  while :; do
    fm_lock_acquire_wait "$lock"
    if _fm_pr_merge_line_head "$dir" \
      && [ "$FM_PR_MERGE_LINE_HEAD_NAME" = "${FM_PR_MERGE_LINE_TICKET##*/}" ] \
      && _fm_pr_merge_line_take_turn "$turn"; then
      FM_PR_MERGE_LINE_HELD=1
      fm_lock_release "$lock"
      return 0
    fi
    ahead=$FM_PR_MERGE_LINE_HEAD_URL
    fm_lock_release "$lock"
    fm_epoch_seconds_to now
    if [ "$FM_PR_MERGE_LINE_HEAD_NAME" != "$head_seen" ]; then
      head_seen=$FM_PR_MERGE_LINE_HEAD_NAME
      deadline=$((now + timeout))
    fi
    if [ "$now" -ge "$deadline" ] \
      && [ "$FM_PR_MERGE_LINE_HEAD_NAME" = "${FM_PR_MERGE_LINE_TICKET##*/}" ]; then
      printf 'error: refusing to merge %s: it was first in the firstmate merge line for %s/%s, but a merge that started before it kept the turn for %s seconds, so its branch was never updated and nothing was merged; retry once that merge finishes\n' \
        "$url" "$host" "$path" "$timeout" >&2
      fm_pr_merge_line_release
      return 1
    fi
    if [ "$now" -ge "$deadline" ]; then
      printf 'error: refusing to merge %s: another firstmate merge on %s/%s stayed ahead of it for %s seconds without the line moving, so its branch was never updated and nothing was merged; retry once that merge finishes\n' \
        "$url" "$host" "$path" "$timeout" >&2
      if [ -n "$ahead" ] && [ "$ahead" != "$url" ]; then
        printf 'error: the merge ahead of it is %s\n' "$ahead" >&2
      fi
      fm_pr_merge_line_release
      return 1
    fi
    [ "$poll" -eq 0 ] || sleep "$poll"
  done
}

# Leave the line: drop this run's ticket first, so the next waiter becomes the
# head the moment the turn is free, then release the turn. Idempotent, so an
# EXIT cleanup can call it unconditionally.
fm_pr_merge_line_release() {
  if [ -n "$FM_PR_MERGE_LINE_TICKET" ]; then
    rm -f -- "$FM_PR_MERGE_LINE_TICKET"
    FM_PR_MERGE_LINE_TICKET=
  fi
  if [ "$FM_PR_MERGE_LINE_HELD" = 1 ]; then
    FM_PR_MERGE_LINE_HELD=0
    fm_lock_release "$FM_PR_MERGE_LINE_TURN"
  fi
}
