#!/usr/bin/env bash
# Choose which Claude or Codex account NEW workers launch on.
# Use --provider codex before the command for Codex (default: claude).
# Codex add <name> --home <absolute-existing-home> registers a directory alias
# without copying authentication. Pipeline, quota floor, session
# share, and paid extra-usage policy commands currently support Claude only.
#
# Usage:
#   fm-seat.sh status
#   fm-seat.sh pipeline-install --claude <absolute-native-path> [--destination <path>]
#   fm-seat.sh pipeline-check --claude <absolute-native-path> [--destination <path>]
#   fm-seat.sh pipeline-move
#   fm-seat.sh list
#   fm-seat.sh switch <name|default> [--force]
#   fm-seat.sh switch --next [--force]
#   fm-seat.sh probe [<name|default>]
#   fm-seat.sh name-of <profile-dir>
#   fm-seat.sh worker-destination --from <name|default> [--skip <name>]...
#   fm-seat.sh launch-destination [--spare-only]
#   fm-seat.sh add <name>
#   fm-seat.sh threshold [<percent-left>|off]
#   fm-seat.sh destination-min [<percent-left>|off]
#   fm-seat.sh extra-usage [stop|allow <usd>|off]
#   fm-seat.sh auto-exclude [<name>]
#   fm-seat.sh auto-include <name>
#   fm-seat.sh floor [<percent-left>|off]
#   fm-seat.sh floor-readd [<percent-left>|off]
#   fm-seat.sh floor-dwell [<seconds>|off]
#   fm-seat.sh session-share [<percent-of-a-week>|off]
#   fm-seat.sh resting [wake <name>]
#   fm-seat.sh leader-destination [--horizon <seconds>]
#   fm-seat.sh lead-restart [--provider claude|codex] [--to <name>] [--check] [--persisted]
#                           [--launch-command <cmd>]
#   fm-seat.sh threshold-reached
#   fm-seat.sh auto
#   fm-seat.sh arm
#   fm-seat.sh retire
#
# status     Print the active seat, every automatic-mode setting, whether
#            the watch is armed, whether new Claude dispatch is held right now
#            and why (the same reason bin/fm-spawn.sh prints when it refuses a
#            spawn), every live task's OWN recorded seat, so
#            a switch can be read against the workers it did not touch, and every
#            local secondmate home that declines inherited seat settings, with
#            the seat that home is actually on, so a decline is never invisible.
# pipeline-install / pipeline-check
#            Install or verify the tracked no-mistakes Claude wrapper template,
#            bound to this home and checkout. bin/fm-seat-pipeline.sh owns the
#            installation and guarded launch mechanics. Use a stable checkout.
# pipeline-move
#            If the active pipeline seat is resting/excluded, rotate it through
#            the existing switch --next path for subsequent launches. Otherwise
#            keep the eligible active seat. Running agents finish untouched;
#            an NM_CLAUDE_CONFIG_DIR override must be cleared in the pipeline's
#            environment to follow that active seat. Never aborts/restarts a run.
# list       Print every seat with its login state and account identity, and
#            mark each seat held out of automatic rotation.
# switch     Point future claude workers at <name>. `default` clears the setting
#            and returns to the ambient login. `--next` rotates to the next
#            usable seat after the active one. It is the operator's own
#            rotation: the automatic watch applies one further rule by hand
#            here, that a destination must have more weekly spare than the seat
#            it leaves (docs/claude-seats.md, "Which seat carries work"), and a
#            rotation typed at the prompt does not.
#            Rotation covers only named seats under the seats root:
#            the default profile is never a rotation target, because it is the
#            owner's own interactive login and can change account under them.
#            Refuses a seat that is not logged in, because a worker launched
#            there fails on its first message; --force overrides that refusal
#            when the probe itself cannot reach a verdict. A seat whose access
#            token has merely lapsed is accepted with no --force, because the
#            worker launched there renews it. It also refuses a seat whose live
#            quota is used up, naming the reset time, and one at or below the
#            destination minimum; --force crosses both. After the switch it
#            runs bin/fm-config-push.sh --local-only so this machine's running local
#            secondmate homes take the new seat too, reporting each home, and
#            naming each seat item a declining home skipped and why.
# probe      Report whether a worker can be launched on a seat. Exit 0 usable
#            (`logged-in`, or `expired-renewable` for a signed-in seat whose
#            access token lapsed and which the next launch renews), 1 proven not
#            logged in, 2 undecided.
# name-of    Print the seat NAME a profile directory belongs to - the inverse of
#            every other lookup here. A task's own record holds the profile it
#            launched with, so this reads that back as the seat it is. An empty
#            profile is the ambient default seat; a profile outside the seats
#            root is reported by its own path rather than labelled with a seat
#            it is not on.
# worker-destination
#            Where an ALREADY RUNNING worker should move when the seat it
#            launched on hits a vendor credit or usage wall. Same candidate set
#            and same quota gate as the automatic rotation, anchored on the seat
#            the WORKER is on rather than the active seat, so the walled seat is
#            never the answer, and neither is any --skip seat (one this worker
#            already walled out on). Prints one seat name; exit 1 with each
#            skipped seat and its reason, then every seat (the walled one and
#            the default profile included) and when it resets, on stderr when
#            none qualifies. It switches,
#            writes and launches nothing - bin/fm-quota-wall-lib.sh owns the
#            mid-task move and bin/fm-control.sh performs it.
# launch-destination
#            The seat a NEW worker launches on. Spare-leader mode first prefers
#            an eligible alternative to the leader. --spare-only returns the
#            active seat if none exists (used by Codex dispatch). Otherwise,
#            the active seat, unless
#            a switch trigger is set and the active seat's five-hour window is
#            proven at or below it; then a seat with five-hour room and more
#            weekly spare, through the same gate as the rotation. Prints one
#            seat name; exit 1 naming the soonest five-hour reset when none
#            qualifies. It switches, writes and launches nothing -
#            bin/fm-spawn.sh points that one launch at the answer.
# add        Create an empty profile directory for a new seat and print the exact
#            login command the account owner runs. It never logs in, never reads
#            or writes any credential, and never touches the Keychain.
# threshold  TRIGGER. Print, set, or clear the percent LEFT on the ACTIVE seat
#            that trips an automatic switch. Absent means no automatic switching.
# destination-min
#            DESTINATION HEADROOM. Print, set, or clear the percent LEFT a seat
#            must EXCEED to be a switch destination. Absent, nothing beyond the
#            used-up refusal below is asked of a candidate's quota.
#            SEPARATELY and with no setting at all, no switch - automatic or by
#            hand, Claude or Codex - lands on a seat whose live quota reads used
#            up, because a worker launched there cannot run; the refusal names
#            the seat and when it comes back, and --force is the override. A
#            seat whose quota gives no verdict is never treated as used up, so
#            an idle seat stays a destination exactly as it always was.
# extra-usage
#            EXTRA-USAGE POLICY, for when no seat has headroom. `stop` holds new
#            Claude dispatch rather than starting workers that would run on paid
#            extra usage; dispatch resolution can offer configured alternatives
#            from the matched rule (fm-dispatch-resolve.sh). `allow <usd>` keeps
#            dispatching until the seat's
#            extra-usage spend reaches that dollar cap and holds after it;
#            `off` clears the policy and holds nothing. Absent means no hold of
#            any kind.
# auto-exclude
#            Hold a seat out of AUTOMATIC rotation: `switch --next`, the armed
#            watch, and the lead-restart destination all skip it, while
#            `switch <name>` still reaches it. With no name, print the seats
#            currently excluded. Idempotent, and it never moves the active seat:
#            excluding the seat in use only stops it being a future automatic
#            destination.
# auto-include
#            Put a seat back into automatic rotation. A seat that was not
#            excluded is already in rotation, so that is a success and no error.
# floor      QUOTA FLOOR. Print, set, or clear the percent LEFT at or below
#            which the armed watch RESTS a seat: every automatic path then skips
#            it until a reading proves it recovered, while `switch <name>` still
#            reaches it with a warning. Absent means no seat is ever rested.
#            Resting is recorded separately from `auto-exclude`, which is the
#            operator's own standing choice and is never lifted automatically.
# floor-readd
#            The percent LEFT BOTH windows must regain before a resting seat
#            comes back. Absent, it is derived from the floor as
#            min(100, max(3 x floor, floor + 10)).
# floor-dwell
#            Seconds a seat must have rested before any reading may wake it. 0
#            means no minimum rest; `off` restores the built-in default.
# session-share
#            The assumed percent of a WEEK one whole session window costs, used
#            until it has been measured on that account. It is the one setting
#            here that is not a percent left. With no argument it also prints
#            the share in force per account and whether it was measured.
# resting    Print which seats the floor is resting and why, or, with
#            `wake <name>`, put one back by hand. A hand wake is temporary by
#            construction: the next pass reads that seat again and rests it
#            again if it is still at or below the floor.
# lead-restart
#            Move FIRSTMATE ITSELF to another seat, which `switch` cannot do: a
#            switch moves only what the next spawn reads. The successor starts
#            in the same terminal on the destination provider and credential
#            profile, and the current process ends. Running
#            workers get one fire-and-forget notice and are otherwise
#            untouched: their steering, status, and recorded seat are all
#            durable, and supervision is a separate process that is
#            deliberately left alone. `--check`
#            establishes everything and changes nothing. Without `--to` the
#            destination is chosen by leader-destination across both providers.
#            Claude successors resume a Claude session when available; Codex
#            successors start a fresh session from durable records.
#            It refuses until `--persisted` says the open work held only in this
#            conversation is written down, because the replacement drops that
#            conversation. bin/fm-lead-restart.sh owns the transaction, its
#            refusals, and what a failure leaves.
# threshold-reached
#            The trigger predicate: exit 0 when the active seat is at or below
#            the configured percent left, 1 when it is not, and 2 when no
#            threshold is configured or the read failed. Exit 2 is an error,
#            never a true, so an unreadable quota never switches accounts.
# auto       One pass of the automatic mode, run by the armed check shim: rest
#            or wake seats against the quota floor, read the active seat, switch
#            when the trigger is met and a seat with headroom exists, and print
#            one line when firstmate should know, including one warning per
#            resting entry with live workers and explicit seat-move commands.
#            When EVERY seat of this vendor reads used up, nothing moves - a
#            switch between two empty seats is the one move worse than staying -
#            and one line reports it, naming each seat's reset time and the
#            other vendor's seat with headroom when there is one.
#            For ships/scouts, fm-dispatch-resolve.sh --codex-alternative also
#            offers an eligible Codex profile from the worker's matched rule
#            when the resolver is on and clear; never from the default.
#            Harness-changing offers use the existing fm-control.sh relaunch
#            flags, never --seat, and nothing moves until a command is run.
#            Optional lookups share the pass's read deadline; off, non-clear
#            or timed-out resolution leaves the Claude offer intact.
#            The floor runs first, so a
#            switch in the same pass can never land on a seat that pass rested.
#            Never run it in a loop of its own; `arm` gives it the watcher's.
# arm        Register `auto` as this home's repeating Claude-seat check through
#            bin/fm-check-register.sh, so it runs on the watcher's existing
#            cadence. It KEEPS watching after a switch rather than firing once:
#            a crossing fires at most once per seat, and the next seat's own
#            crossing fires again with no re-arming by hand.
# retire     Stop that watch and remove its record.
#
# WHAT THE AUTOMATIC MODE CANNOT DO. Firstmate controls which seat a NEW worker
# starts on, and whether new Claude work is dispatched at all. It cannot stop a
# worker that is ALREADY RUNNING from drawing paid extra usage mid-task; that is
# the organisation's Claude admin setting, not something any setting here
# reaches. So `extra-usage stop` means stop STARTING new work, plus a loud
# warning the moment a seat a worker is running on enters extra usage. It is
# never a guarantee of zero spend.
#
# A switch NEVER disturbs a running worker. It rewrites one config file that only
# a fresh spawn reads; every live task keeps the profile recorded in its own task
# record, and its relaunches and resumes keep reading that record.
#
# A switch reaches every local secondmate home by default, so the machine moves
# together. A home that must spend a different account - one home on a personal
# or client account while the rest run on the team account - declines by placing
# config/claude-seat-local in its OWN config dir; it then keeps its own three
# seat files and runs its own switch, threshold, and arm against itself.
# bin/fm-config-inherit-lib.sh owns that decline for every convergence point.
# bin/fm-seat-lib.sh owns the resolution rules; docs/claude-seats.md owns the
# operator procedure, including what the account owner must do to add a seat.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

FM_SEAT_PROVIDER=${FM_SEAT_PROVIDER:-claude}
if [ "${1-}" = --provider ]; then
  FM_SEAT_PROVIDER=${2-}
  [ $# -ge 2 ] || { echo 'error: --provider requires claude or codex' >&2; exit 1; }
  shift 2
fi
case "$FM_SEAT_PROVIDER" in
  claude|codex) ;;
  *) echo "error: unsupported seat provider: $FM_SEAT_PROVIDER" >&2; exit 1 ;;
esac
export FM_SEAT_PROVIDER
if [ "$FM_SEAT_PROVIDER" = codex ]; then
  case "${1-}" in
    pipeline-*|floor|floor-readd|floor-dwell|session-share|resting|extra-usage) echo "error: $1 supports Claude seats only" >&2; exit 1 ;;
  esac
fi

# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-seat-lib.sh
. "$SCRIPT_DIR/fm-seat-lib.sh"
# shellcheck source=bin/fm-quota-axi-lib.sh
. "$SCRIPT_DIR/fm-quota-axi-lib.sh"
# Secondmate-home discovery and validation, shared with bin/fm-config-push.sh so
# status reports the same homes a switch actually pushes to.
# shellcheck source=bin/fm-ff-lib.sh
. "$SCRIPT_DIR/fm-ff-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-config-inherit-lib.sh
. "$SCRIPT_DIR/fm-config-inherit-lib.sh"
# The lead's OWN seat is recorded beside the session lock, not in
# config/claude-seat; this is the one owner of reading that record.
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"
# The persist gate the lead trigger below hands over is the same one a second
# mate's restart applies; this file owns that contract.
# shellcheck source=bin/fm-persist-request-lib.sh
. "$SCRIPT_DIR/fm-persist-request-lib.sh"
# The arm/retire half rides the same registered check shim every other repeating
# firstmate poll uses; bin/fm-check-shim-lib.sh owns its write, binding, and
# rollback, and needs these two sourced first.
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-check-lib.sh
. "$SCRIPT_DIR/fm-check-lib.sh"
# shellcheck source=bin/fm-check-shim-lib.sh
. "$SCRIPT_DIR/fm-check-shim-lib.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "${BASH_SOURCE[0]}"
  exit 2
}
die() { printf 'error: %s\n' "$1" >&2; exit 1; }

# seat_command_memo
# One quota memo for the rest of THIS command, so the login probe and the
# destination quota read of the same profile cost one call rather than two.
# It is the per-pass memo bin/fm-seat-lib.sh owns, scoped to a single short
# command instead of a watch pass. A memo already in the environment belongs to
# the pass that invoked this command as a child and is left exactly as it is,
# so the pass keeps owning both the figures and the cleanup.
seat_command_memo() {
  local memo
  [ -z "${FM_SEAT_READ_MEMO_DIR:-}" ] || return 0
  memo=$(mktemp -d "${TMPDIR:-/tmp}/fm-seat-cmd.XXXXXX" 2>/dev/null) || return 0
  FM_SEAT_READ_MEMO_DIR=$memo
  export FM_SEAT_READ_MEMO_DIR
  # shellcheck disable=SC2064 # the path is fixed now, not when the trap runs.
  trap "rm -rf -- '$memo'" EXIT
}

# login_state <name>
# Print "logged-in", "expired-renewable", "not-logged-in", or "unknown" for a
# seat name. bin/fm-seat-lib.sh's fm_seat_logged_in owns which evidence produces
# which verdict; this only names them.
#
# "expired-renewable" is a seat a worker can be launched on: its session is
# intact and the launch itself renews the lapsed token. It is reported under its
# own name rather than folded into "logged-in" because its quota is unreadable
# until something renews it, which is what keeps it out of a destination-minimum
# comparison it cannot answer.
login_state() {
  local name=$1 dir rc
  if [ "$name" != "$FM_SEAT_DEFAULT_NAME" ]; then
    fm_seat_dir "$name" >/dev/null || { printf 'unknown\n'; return; }
  fi
  dir=$(fm_seat_config_dir "$name") || { printf 'unknown\n'; return; }
  fm_seat_logged_in "$dir"
  rc=$?
  case "$rc" in
    0) printf 'logged-in\n' ;;
    "$FM_SEAT_LOGIN_EXPIRED_RENEWABLE") printf 'expired-renewable\n' ;;
    1) printf 'not-logged-in\n' ;;
    *) printf 'unknown\n' ;;
  esac
}

# seat_usable <state>
# Whether a login_state verdict means a claude worker can be launched on that
# seat. The one owner of that question, so `switch` and rotation can never drift
# apart on which seats are launchable.
seat_usable() {
  case "${1-}" in
    logged-in | expired-renewable) return 0 ;;
  esac
  return 1
}

# all_seats
# Every selectable seat name: the default seat first, then each directory seat.
all_seats() {
  printf '%s\n' "$FM_SEAT_DEFAULT_NAME"
  fm_seat_list
}

cmd_list() {
  local name state account dir active note resting
  active=$(fm_seat_active)
  printf 'seats root: %s\n' "$(fm_seat_root)"
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    dir=$(fm_seat_config_dir "$name")
    if ! python3 "$SCRIPT_DIR/fm-seat-lock.py" available --provider "$FM_SEAT_PROVIDER" \
      --profile "$(fm_seat_config_dir "$name")" >/dev/null 2>&1; then
      printf 'seat %s: skipped, renewing or lock unavailable\n' "$name" >&2
      continue
    fi
    state=$(login_state "$name")
    account=$(fm_seat_account "$dir" 2>/dev/null) || account=
    # The note is appended only for a seat something is withholding, so a home
    # that withholds nothing reads exactly as it did before these settings
    # existed. A seat that is both held out and resting reads as held out: the
    # operator's own choice is the one that is never lifted by a reading.
    note=''
    if fm_seat_auto_excluded "$name"; then
      note=$'\t'"held out of automatic rotation by hand"
    elif resting=$(resting_summary "$name"); then
      if fm_seat_resting "$name"; then
        note=$'\t'"resting below the quota floor: $resting"
      else
        note=$'\t'"back in automatic rotation provisionally after resting below the quota floor: $resting"
      fi
    fi
    printf '%s%s\t%s\t%s\t%s%s\n' \
      "$([ "$name" = "$active" ] && printf '* ' || printf '  ')" \
      "$name" "$state" "${account:--}" "${dir:-(ambient default login)}" "$note"
  done < <(all_seats)
}

# live_task_seats
# One line per task record that still exists, naming the profile that task
# actually launched with. This is the evidence that a switch left running work
# alone, so it reads each task's own record and never re-resolves the config.
live_task_seats() {
  local meta id seat
  [ -d "$STATE" ] || return 0
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    id=${meta##*/}
    id=${id%.meta}
    [ "$(sed -n 's/^harness=//p' "$meta" | tail -1)" = "$FM_SEAT_PROVIDER" ] || continue
    seat=$(sed -n "s/^${FM_SEAT_PROVIDER}_seat=//p" "$meta" | tail -1)
    printf '%s\t%s\n' "$id" "${seat:-(ambient default login)}"
  done
}

# declining_secondmate_homes
# One tab-separated row per LOCAL secondmate home that declines inherited seat
# settings: id, the seat that home is on, and its path. A decline that produced
# no visible row would be a setting that silently does nothing, which is the one
# failure this opt-out exists to avoid.
# Remote routes never receive seat settings at all, so they are not listed.
declining_secondmate_homes() {
  local id home _window meta
  [ -d "$STATE" ] || return 0
  while IFS='|' read -r id home _window meta; do
    [ -n "$id" ] && [ -n "$home" ] || continue
    [ -z "$(fm_meta_get "$meta" remote_host)" ] || continue
    validate_secondmate_home "$id" "$home" || continue
    fm_config_inherit_seat_optout "$VALIDATED_HOME/config" "$FM_SEAT_PROVIDER" || continue
    printf '%s\t%s\t%s\n' "$id" "$(fm_seat_active "$VALIDATED_HOME/config")" "$VALIDATED_HOME"
  done < <(live_secondmate_meta_records "$STATE" "$DATA/secondmates.md")
}

cmd_status() {
  local active profile threshold minimum policy reason rows excluded floor pipeline label
  local headroom lead_provider
  label=Claude; [ "$FM_SEAT_PROVIDER" != codex ] || label=Codex
  active=$(fm_seat_active)
  printf 'active seat for NEW workers: %s\n' "$active"
  profile=$(fm_seat_config_dir "$active")
  printf 'active profile: %s\n' "${profile:-(ambient default login)}"
  printf 'login state: %s\n' "$(login_state "$active")"
  # Every window named, never a bare percentage: the week is what decides which
  # seat carries work and the five-hour window only when, so a reader must be
  # able to tell the two apart at a glance.
  if headroom=$(fm_seat_seat_phrase "$profile"); then
    printf 'headroom: %s\n' "$headroom"
  else
    printf 'headroom: (its quota gave no verdict, so nothing is assumed about it)\n'
  fi
  if [ "$FM_SEAT_PROVIDER" = claude ]; then
  pipeline=$(fm_seat_pipeline_report)
  printf '%s\n' "$pipeline" | jq -r '
    "pipeline seat for next managed launch: " + .seat
    + (if .override then " (NM_CLAUDE_CONFIG_DIR override)" else " (follows active seat)" end),
    (if .blockedReason == null then empty else "pipeline selection HELD: " + .blockedReason end),
    (if .profileRecorded then empty else "pipeline default-seat profile not recorded for this home'"'"'s lead; launches use the wrapper'"'"'s installed default profile until a lead restart records it" end),
    (.liveAgents[] | "live pipeline agent: pid=" + (.pid | tostring) + " seat=" + .seat
      + (if .override then " (override)" else "" end))'
  fi
  # The lead's own seat is a separate fact from the active one: a switch moves
  # what new workers get and leaves the running lead where it launched, so the
  # two drift apart by design and only `lead-restart` closes that gap.
  if profile=$(lead_profile); then
    lead_provider=$(fm_session_lock_runtime_field "$STATE" harness) || lead_provider=claude
    printf 'firstmate itself is running on: %s (%s)\n' "$(FM_SEAT_PROVIDER="$lead_provider" fm_seat_name_of_profile "$profile")" "$lead_provider"
  else
    printf 'firstmate itself is running on: (not recorded for this session)\n'
  fi
  fm_seat_spare_leader_status
  if threshold=$(fm_seat_threshold); then
    printf 'auto-switch trigger: at or below %s%% left on the active seat\n' "$threshold"
  else
    if fm_seat_spare_leader_enabled; then
      printf 'auto-switch trigger: (unset - only spare-leader departures)\n'
    else
      printf 'auto-switch trigger: (unset - no automatic switching)\n'
    fi
  fi
  if minimum=$(fm_seat_destination_min); then
    printf 'destination minimum: only switch to a seat above %s%% left\n' "$minimum"
  else
    printf 'destination minimum: (unset - any logged-in seat is a valid destination)\n'
  fi
  if policy=$(fm_seat_extra_usage_policy); then
    case "$policy" in
      stop) printf 'extra-usage policy: stop - hold new Claude dispatch rather than start work on paid extra usage\n' ;;
      *)    printf 'extra-usage policy: allow up to $%s of paid extra usage, then hold\n' "${policy#allow }" ;;
    esac
  else
    printf 'extra-usage policy: (unset - nothing holds %s dispatch)\n' "$label"
  fi
  excluded=$(fm_seat_auto_exclude_list | tr '\n' ' ')
  excluded=${excluded% }
  if [ -n "$excluded" ]; then
    printf 'held out of automatic rotation by hand: %s (switch <name> still reaches them)\n' "$excluded"
  else
    printf 'held out of automatic rotation by hand: (none - every seat under the root is a rotation candidate)\n'
  fi
  if floor=$(fm_seat_floor); then
    printf 'quota floor: rest a seat at or below %s%% left, back only above %s%% on BOTH windows after %ss and with room for a whole session\n' \
      "$floor" "$(fm_seat_floor_readd)" "$(fm_seat_floor_dwell)"
  else
    printf 'quota floor: (unset - no seat is ever rested out of automatic rotation)\n'
  fi
  printf 'resting below the quota floor:\n'
  print_resting | sed 's/^/  /'
  if fm_check_shim_armed; then
    printf 'auto-switch watch: armed (keeps watching after each switch)\n'
  else
    printf 'auto-switch watch: not armed\n'
  fi
  if reason=$(fm_seat_dispatch_reason "$(fm_seat_dispatch_decision)"); then
    printf 'new %s dispatch: allowed\n' "$label"
  else
    printf 'new %s dispatch: HELD (bin/fm-spawn.sh --ignore-seat-hold starts one task anyway)\n' "$label"
    printf '  resolve the task brief with bin/fm-dispatch-resolve.sh to offer alternatives configured in its matched rule\n'
  fi
  printf '%s\n' "$reason" | sed 's/^/  /'
  printf '\nlive workers keep the seat they launched with:\n'
  rows=$(live_task_seats)
  if [ -z "$rows" ]; then
    printf '  (no task records)\n'
  else
    printf '%s\n' "$rows" | while IFS=$'\t' read -r id seat; do
      printf '  %s\t%s\n' "$id" "$seat"
    done
  fi
  printf '\nlocal secondmate homes declining inherited seats:\n'
  rows=$(declining_secondmate_homes)
  if [ -z "$rows" ]; then
    printf '  (none - every local home takes this seat)\n'
  else
    printf '%s\n' "$rows" | while IFS=$'\t' read -r id seat home; do
      printf '  %s\t%s\t%s\n' "$id" "$seat" "$home"
    done
  fi
}

cmd_probe() {
  local name=${1:-} state
  [ -n "$name" ] || name=$(fm_seat_active)
  if [ "$name" != "$FM_SEAT_DEFAULT_NAME" ]; then
    fm_seat_name_valid "$name" || die "invalid seat name: $name"
  fi
  state=$(login_state "$name")
  printf '%s\t%s\n' "$name" "$state"
  # A renewable seat exits 0 with any caller: it is launchable, which is the
  # question `probe` answers. Its state word is what says the token has lapsed.
  seat_usable "$state" && return 0
  printf 'login command: '; fm_seat_login_command "$(fm_seat_config_dir "$name")"
  case "$state" in
    not-logged-in) return 1 ;;
    *) return 2 ;;
  esac
}

# cmd_name_of <profile-dir>
# The seat NAME a profile directory belongs to, which is the inverse of the
# resolution every other command here makes. A task's own record holds the
# profile it launched with, while an operator, a report and a destination query
# all speak in seat names, so this is where a recorded profile is read back as
# the seat it is. fm_seat_name_of_profile owns the answer, including the empty
# profile (the ambient default seat) and a profile outside the seats root, which
# is reported by its own path rather than labelled with a seat it is not on.
cmd_name_of() {
  fm_seat_name_of_profile "${1-}"
}

# cmd_worker_destination
# Where an ALREADY RUNNING worker should move when the seat it launched on hits
# a vendor credit or usage wall. This is `switch --next`'s candidate set and
# quota gate, anchored on the seat the WORKER is on instead of the active one,
# so the seat it walled out on is never the answer and every rule a new launch
# gets - the automatic-rotation exclusion, the quota floor's resting record, the
# login requirement, the proven-empty refusal, the destination minimum, and the
# paid extra-usage policy's deferral - applies to a mid-task move through the
# same code rather than a second copy of it (next_seat above is the one owner).
# Read-only: it answers where the work COULD go and switches, writes and
# launches nothing. bin/fm-quota-wall-lib.sh owns the move itself.
cmd_worker_destination() {
  local from='' name skip=()
  seat_command_memo
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --from) [ "$#" -ge 2 ] || usage; from=$2; shift 2 ;;
      --from=*) from=${1#--from=}; shift ;;
      --skip) [ "$#" -ge 2 ] || usage; skip+=("$2"); shift 2 ;;
      --skip=*) skip+=("${1#--skip=}"); shift ;;
      *) usage ;;
    esac
  done
  [ -n "$from" ] || usage
  if [ "$from" != "$FM_SEAT_DEFAULT_NAME" ]; then
    fm_seat_name_valid "$from" || die "invalid seat name: $from"
  fi
  name=$(next_seat "$from" ${skip[@]+"${skip[@]}"}) || {
    seat_resets "$from"
    die "no seat under the seats root qualifies to take over work running on '$from' (each skipped seat and its reason is printed above); add and log into another seat, put an excluded seat back with 'fm-seat.sh auto-include <name>', or lower 'fm-seat.sh destination-min' (docs/claude-seats.md)"
  }
  printf '%s\n' "$name"
}

# session_window <name>
# One seat's five-hour window as `<percent-left><TAB><resetsAt>`, from the same
# headroom row the rest of the policy reads, with an unreported reset empty.
# Returns 1 when the seat's quota gave no verdict or reports no five-hour window.
session_window() {
  local dir out row left reset
  dir=$(fm_seat_config_dir "${1-}") || return 1
  out=$(fm_seat_quota_json "$dir") || return 1
  row=$(fm_seat_headroom_from "$out") || return 1
  left=$(fm_seat_headroom_field "$row" 4) || return 1
  reset=$(fm_seat_headroom_field "$row" 5) || reset=''
  printf '%s\t%s\n' "$left" "$reset"
}

# session_room_reason <name> <trigger>
# WHEN, for a new worker's launch: whether the seat's five-hour window has room
# above the switch trigger. Returns 1 when it does, 0 when it is proven not to,
# and 2 when no five-hour reading exists; 0 and 2 print the reason. A five-hour
# dip never rotates the active seat or moves the lead, so this is the one place
# that dip is acted on, and only for work not yet started.
session_room_reason() {
  local name=$1 trigger=$2 left reset
  IFS=$'\t' read -r left reset < <(session_window "$name") || {
    printf 'its 5-hour window could not be read, so it cannot be shown to have room for a new worker\n'
    return 2
  }
  jq -en --arg l "$left" --arg t "$trigger" '($l | tonumber) > ($t | tonumber)' >/dev/null 2>&1 &&
    return 1
  printf '5-hour %s%% left is not above the %s%% switch trigger' "$left" "$trigger"
  ! reset=$(fm_seat_reset_phrase "$reset") || printf ' (resets %s)' "$reset"
  printf '\n'
  return 0
}

# cmd_launch_destination
# The seat a NEW native worker launches on, by name. An enabled spare-leader
# preference first tries an eligible non-leader destination. --spare-only then
# retains the active seat, preserving Codex dispatch's existing session policy.
# Otherwise: With no switch trigger set,
# or when the active seat has five-hour room or no five-hour reading, that is
# the active seat, unchanged. When the active seat is proven to have no
# five-hour room, it is the seat next_seat chooses with --session-room: one with
# room AND more weekly spare than the active seat. Read-only: it writes no seat
# file and moves neither the lead nor a running worker; bin/fm-spawn.sh points
# that one launch at the answer.
#
# When nothing qualifies it refuses, with every skipped seat's reason above the
# soonest five-hour reset that can end the hold: the active seat's own, or that
# of a candidate next_seat refused for five-hour room alone. An active seat with nothing left at all is the exception:
# it answers the active seat, because the spawn's depletion and extra-usage
# gates own an empty seat's refusal, and its paid overflow, in their own words.
cmd_launch_destination() {
  local active trigger name soonest seat at spare_only=0
  local -a waiting=()
  if [ "${1-}" = --spare-only ]; then spare_only=1; shift; fi
  [ "$#" -eq 0 ] || usage
  seat_command_memo
  active=$(fm_seat_active)
  if name=$(spare_leader_destination "$active" 2>/dev/null); then
    printf '%s\n' "$name"
    return 0
  fi
  if [ "$spare_only" -eq 1 ]; then
    printf '%s\n' "$active"
    return 0
  fi
  trigger=$(fm_seat_threshold) || { printf '%s\n' "$active"; return 0; }
  if session_room_reason "$active" "$trigger" >/dev/null; then :; else
    printf '%s\n' "$active"
    return 0
  fi
  if name=$(next_seat --session-room "$active"); then
    printf '%s\n' "$name"
    return 0
  fi
  if [ "$(fm_seat_quota_verdict "$(fm_seat_config_dir "$active")" | cut -f1)" = depleted ]; then
    printf '%s\n' "$active"
    return 0
  fi
  [ -z "$name" ] || mapfile -t waiting <<< "$name"
  if soonest=$(session_soonest_reset "$trigger" "$active" ${waiting[@]+"${waiting[@]}"}); then
    IFS=$'\t' read -r seat at <<< "$soonest"
    die "no seat has 5-hour room for a new worker and more weekly spare than '$active' (each skipped seat and its reason is printed above); the soonest 5-hour reset is $seat at $(fm_seat_reset_phrase "$at")"
  fi
  die "no seat has 5-hour room for a new worker and more weekly spare than '$active' (each skipped seat and its reason is printed above), and no seat's report names when its 5-hour window resets"
}

# session_soonest_reset <trigger> <seat>...
# Among the named seats whose five-hour window is at or below the trigger, the
# one whose window resets first, as `<seat><TAB><resetsAt>`. Returns 1 when none
# of them reports a reset.
session_soonest_reset() {
  local trigger=$1 name left reset at best_at='' best=''
  shift
  for name in "$@"; do
    IFS=$'\t' read -r left reset < <(session_window "$name") || continue
    jq -en --arg l "$left" --arg t "$trigger" '($l | tonumber) <= ($t | tonumber)' >/dev/null 2>&1 ||
      continue
    at=$(fm_seat_iso_to_epoch "$reset") || continue
    if [ -z "$best_at" ] || [ "$at" -lt "$best_at" ]; then
      best_at=$at
      best=$(printf '%s\t%s' "$name" "$reset")
    fi
  done
  [ -n "$best" ] || return 1
  printf '%s\n' "$best"
}

# seat_resets <walled-seat>
# When every seat of this provider comes back, for a refusal that has to say so:
# the walled seat first, then the default profile, then every named seat, each
# from fm_seat_quota_verdict's one read, on stderr beside the skip reasons. A
# seat whose reset cannot be read says so and why rather than being left out.
seat_resets() {
  local from=$1 name dir verdict reset seen=' ' seats
  mapfile -t seats < <(fm_seat_list)
  for name in "$from" "$FM_SEAT_DEFAULT_NAME" ${seats[@]+"${seats[@]}"}; do
    case "$seen" in *" $name "*) continue ;; esac
    seen="$seen$name "
    if ! dir=$(fm_seat_config_dir "$name" 2>/dev/null); then
      printf 'seat %s: reset unknown: its profile could not be resolved\n' "$name" >&2
      continue
    fi
    IFS=$'\t' read -r verdict _ reset <<< "$(fm_seat_quota_verdict "$dir")"
    if [ -n "$reset" ]; then
      printf 'seat %s: resets at %s\n' "$name" "$reset" >&2
    elif [ "$verdict" = unknown ]; then
      printf 'seat %s: reset unknown: its quota could not be read\n' "$name" >&2
    else
      printf 'seat %s: reset unknown: its quota report names no reset time\n' "$name" >&2
    fi
  done
}

# destination_quota_check <name> [<anchor-basis> <anchor-spare>]
# The quota half of destination eligibility, applied by EVERY switch - the
# automatic rotation below and an explicit `switch <name>` alike - so a seat a
# rotation would refuse can never be reached by a deliberate switch either.
# Prints the reason and returns 0 to REFUSE the seat, 1 when it qualifies, and 2
# when the read reached no verdict, printing that as the reason too and leaving
# what an unknown means to the caller.
#
# Three rules, in order:
#   - A seat whose live quota PROVES it is empty is refused whatever is
#     configured. This is the one gate that needs no setting, because a worker
#     launched on an empty seat cannot run at all; it fires for a Claude seat and
#     a Codex home alike, and names the reset time so the refusal also says when
#     the seat comes back.
#   - With config/<provider>-seat-destination-min set, a seat at or below that
#     percent is refused as well. Absent, nothing further is asked.
#   - THE ANCHOR RULE. With the anchor seat's own weekly spare supplied, a
#     candidate must also have strictly MORE of it than the seat the work would
#     leave. Without it, two seats both under the trigger and both above the
#     absolute minimum are each a valid destination for the other, which is
#     what moved the lead back and forth between two spent seats on
#     2026-10-15/16. The rule is additive: a candidate below the absolute
#     minimum is still refused for that reason first.
#
# Only an automatic `next_seat` supplies an anchor, so a switch asked for by
# hand - `switch <name>` and `switch --next` alike - stays absolute-only: a
# deliberate choice is not a rotation decided on headroom, and the operator is
# the one making it.
#
# fm_seat_choice_spare owns which figure is compared and names its basis; two
# seats are compared only on the SAME basis, because points of weekly spare and
# a plain percent left are different quantities. An anchor whose spare could not
# be read, or one read on another basis, leaves today's absolute-only behavior
# in place rather than refusing every candidate for a comparison it cannot make.
#
# No verdict is never read as empty: a seat whose access token has merely lapsed
# is signed in, and its headroom is unknown rather than zero.
destination_quota_check() {
  local name=$1 anchor_basis=${2-} anchor_spare=${3-}
  local dir out remaining minimum reset row basis spare
  dir=$(fm_seat_config_dir "$name") || {
    printf 'its profile could not be resolved\n'
    return 2
  }
  minimum=$(fm_seat_destination_min) || minimum=''
  if ! out=$(fm_seat_quota_json "$dir"); then
    printf 'its quota could not be read, so its headroom is unknown and this makes no guess\n'
    return 2
  fi
  fm_seat_depleted_from "$out"
  case "$?" in
    0)
      # An empty plan quota is not the end of it: a configured `allow <usd>`
      # policy deliberately keeps dispatching on paid extra usage, so a seat it
      # still covers remains a destination. Only the depleted rule yields here;
      # the destination minimum below is a separate rule and still applies, with
      # --force as its deliberate manual override.
      if ! fm_seat_extra_usage_covers_from "$out"; then
        reset=$(fm_seat_reset_at_from "$out") || reset=''
        if [ -n "$reset" ]; then
          printf 'its quota is used up; the seat comes back at %s\n' "$reset"
        else
          printf 'its quota is used up and its report names no reset time\n'
        fi
        return 0
      fi
      ;;
    2)
      printf 'its quota could not be read, so its headroom is unknown and this makes no guess\n'
      return 2
      ;;
  esac
  if [ -n "$minimum" ]; then
    remaining=$(fm_seat_remaining_from "$out") || {
      printf 'its quota could not be read, so its headroom is unknown and this makes no guess\n'
      return 2
    }
    jq -en --arg r "$remaining" --arg m "$minimum" \
      '($r | tonumber) > ($m | tonumber)' >/dev/null 2>&1 || {
      printf '%s%% left across its account windows is not above the %s%% destination minimum\n' \
        "$remaining" "$minimum"
      return 0
    }
  fi
  [ -n "$anchor_basis" ] && [ -n "$anchor_spare" ] || return 1
  row=$(fm_seat_headroom_from "$out") || {
    printf 'its quota could not be read, so its headroom is unknown and this makes no guess\n'
    return 2
  }
  IFS=$'\t' read -r basis spare <<< "$(fm_seat_choice_spare "$row")"
  # A candidate measured on another basis cannot be compared with the anchor at
  # all, so the absolute rules above are the whole answer for it, exactly as
  # they were before the anchor rule existed.
  [ -n "$basis" ] && [ "$basis" = "$anchor_basis" ] || return 1
  jq -en --arg c "$spare" --arg a "$anchor_spare" \
    '($c | tonumber) > ($a | tonumber)' >/dev/null 2>&1 && return 1
  printf 'its %s of %s is not more than the %s the seat this would leave has\n' \
    "$(fm_seat_basis_label "$basis")" "$spare" "$anchor_spare"
  return 0
}

# seat_crossing <seat>
# WHEN TO LOOK, for one seat, as `<basis><TAB><percent-left><TAB><phrase>` from
# a single read: the figure a threshold crossing is measured against, and the
# same reading rendered with every window named for the line that reports it.
# fm_seat_trigger_left owns which window that figure comes from - the week when
# the report carries one - so a five-hour dip no longer fires a rotation or a
# lead move on its own. Returns 1 when the seat's quota gave no verdict, which
# every caller treats as "do not act", never as a number.
seat_crossing() {
  local name=${1-} dir out row basis left phrase
  dir=$(fm_seat_config_dir "$name") || return 1
  out=$(fm_seat_quota_json "$dir") || return 1
  row=$(fm_seat_headroom_from "$out") || return 1
  IFS=$'\t' read -r basis left <<< "$(fm_seat_trigger_left "$row")"
  [ -n "$basis" ] && [ -n "$left" ] || return 1
  phrase=$(fm_seat_headroom_phrase "$row") || return 1
  printf '%s\t%s\t%s\n' "$basis" "$left" "$phrase"
}

# anchor_headroom <anchor-seat>
# The anchor's own weekly spare as `<basis><TAB><points>`, for the gate above.
# A caller that has already read the anchor has read its percent LEFT for a
# crossing, which is a different figure from spare, so there is nothing to hand
# down and this reads it here - one quota call, and none at all inside a watch
# pass or a single command, where the seat library's read memo already holds it.
#
# The rule holds whenever the anchor's weekly reading is known. A seat resting
# below the quota floor or held out of automatic rotation by hand is still a
# seat with a known week, and moving off it onto less weekly spare is still a
# move to a worse seat, so neither waives the rule.
#
# It stays silent, and the anchor rule therefore stays off, in exactly two
# cases: the anchor's reading gives no verdict, and the anchor's WEEKLY window
# is proven empty. The second is what keeps the mid-task move off a walled seat
# working: a seat whose week is spent is one the work cannot remain on, and
# every seat with real headroom qualifies as it always did. A spent five-hour
# window alone is not that case, because the week behind it is still there.
anchor_headroom() {
  local name=${1-} dir out row week
  [ -n "$name" ] || return 1
  dir=$(fm_seat_config_dir "$name") || return 1
  out=$(fm_seat_quota_json "$dir") || return 1
  row=$(fm_seat_headroom_from "$out") || return 1
  if week=$(fm_seat_headroom_field "$row" 1) &&
    jq -en --arg w "$week" '($w | tonumber) <= 0' >/dev/null 2>&1; then
    return 1
  fi
  fm_seat_choice_spare "$row"
}

# seat_rank_key <name> <rotation-index>
# One qualifying candidate's place in the use-it-or-lose-it order, as sortable
# fields: `<has-spare><TAB><weekly reset><TAB><weekly spare><TAB><rotation
# index><TAB><name>`, sorted by the first four with the name carried along.
#
# Spare that expires soonest is spent first, because it is the spare that would
# otherwise be lost: among seats that still have weekly spare, the one whose
# week resets first wins, then the one with the most spare, then rotation order
# so the answer is the same every time. A seat with no spare left sorts behind
# every seat that has some, which is what keeps the thinnest seat in reserve.
#
# A seat whose weekly reset is not reported cannot be shown to be the soonest
# to expire, so it sorts after every seat whose reset is known rather than
# ahead of them on a figure nothing supplied.
seat_rank_key() {
  local name=$1 index=$2 dir out row spare reset group=1 at=0
  dir=$(fm_seat_config_dir "$name") || return 1
  out=$(fm_seat_quota_json "$dir") || return 1
  row=$(fm_seat_headroom_from "$out") || return 1
  spare=$(fm_seat_headroom_field "$row" 2) || return 1
  if jq -en --arg s "$spare" '($s | tonumber) > 0' >/dev/null 2>&1; then
    group=0
    reset=$(fm_seat_headroom_field "$row" 3) || reset=''
    at=$(fm_seat_iso_to_epoch "$reset") || at=99999999999
  fi
  printf '%s\t%s\t%s\t%s\t%s\n' "$group" "$at" "$spare" "$index" "$name"
}

# next_seat [--any] [<anchor-seat> [<skip-seat>...]]
# The seat after the anchor seat, in list order, that a worker can be launched
# on. The anchor defaults to the active seat, which is most callers;
# the lead restart passes the seat the LEAD is on instead, because that is the
# seat it is rotating away from. The selection RULES below are identical either
# way - only the starting point differs. A mid-task move also names every seat
# that worker already walled out on, which are never chosen either.
# Rotation wraps, and the anchor seat is never chosen, so a rotation with no
# other usable seat refuses rather than pretending to switch.
#
# `seat_usable` owns which states qualify, so a seat whose access token has
# merely lapsed is a destination like any other: its session is intact and the
# worker launched there renews it. Rotating past every idle seat would leave the
# fleet on its most-spent account for no reason.
#
# AUTOMATIC-ROTATION EXCLUSION. This is the one place a candidate set is built,
# so every automatic path - `switch --next`, the armed watch's switch, the
# watch's instruction to move the lead, the lead-restart destination, and the
# feasibility check `arm` makes - reads the same exclusion here and none of them
# can skip it. An explicit `switch <name>` does not come through this function
# at all, which is exactly why an excluded seat stays manually reachable.
#
# A seat RESTING below the quota floor is withheld the same way and through the
# same two lines, from its own record rather than from the operator's exclusion
# file. The two are deliberately separate: an exclusion is the operator's
# standing choice and is never lifted by a reading, while resting is written and
# lifted only by the watch.
#
# Rotation covers ONLY named seats under the seats root. The default profile is
# deliberately excluded: it is the account owner's own interactive login, it
# changes under them whenever they sign in somewhere else, and nothing here can
# tell which account it currently holds. An automatic switch must not land
# workers on a store whose identity moved without anyone asking. `switch
# default` stays available as an explicit, manual choice.
#
# The seat set is read fresh from the seats root on every call, so this never
# assumes which seats exist or that any particular one is present.
#
# DESTINATION QUOTA. destination_quota_check above owns this half in full and
# is shared with an explicit switch, so the two can never drift: a candidate
# proven EMPTY is refused with no setting at all, and one at or below
# config/claude-seat-destination-min is refused when that setting is present.
# A candidate whose quota gives no verdict is never guessed at in either
# direction. With no minimum set it stays a destination, which keeps the
# login-only outcome this had before any candidate quota was read; with one set
# it is SKIPPED, because an ambiguous read cannot answer a headroom comparison.
#
# THE ANCHOR RULE rides on the same gate and is read ONCE here, for the anchor,
# rather than per candidate: a destination must have strictly more weekly spare
# than the seat the work would leave. Every automatic path reaches it through
# this one call, so the rotation, the lead move and the mid-task move cannot
# drift apart on what counts as somewhere better. anchor_headroom above owns
# when the rule is asked at all.
#
# WHICH qualifying seat is then chosen depends on what the report supports. On
# a report carrying quota-axi's own weekly pace - which is what every current
# account returns - the candidates are ranked by seat_rank_key above and the
# best one is taken. Where that projection is absent the comparison degrades to
# a plainer figure that carries no reset to rank by, and the first qualifying
# seat in rotation order is taken, exactly as it always was.
#
# `--any` asks the absolute question instead - is there a seat a worker could
# be launched on at all - with no improvement required. Two callers need it.
# Arming the watch must succeed on a fleet whose ACTIVE seat is simply the best
# one, because the watch is what catches that seat's own later crossing. And a
# `switch --next` typed at the prompt is the operator's own rotation, not a
# choice this makes on headroom.
#
# `--session-room` adds one more rule for a NEW worker's launch: a candidate
# must also show five-hour room above the switch trigger (session_room_reason
# below). Used for launch routing and proactive spare-leader departures. When it refuses, it prints on
# stdout every candidate that passed every other rule and lacked only that
# room, because those seats' five-hour resets are the ones that can end a hold.
#
# A seat whose access token has lapsed is always in that no-verdict class,
# because its quota genuinely cannot be read until a launch renews it. So the
# minimum and idle seats interact: a home that sets a destination minimum will
# rotate only onto seats something has read recently.
#
# Every rejected candidate is reported on stderr with its reason, so a refusal
# to switch always says which seats were considered and why none qualified.
next_seat() {
  local active seats n i idx name minimum='' reason state resting skip rc
  local anchor_basis='' anchor_spare='' any=0 key session='' room
  local spared='' fallback='' spare_move=0 left phrase
  local -a ranked=() waiting=()
  if [ "${1-}" = --spare-leader ]; then
    spare_move=1
    any=1
    shift
  fi
  if [ "${1-}" = --any ]; then
    any=1
    shift
  fi
  if [ "${1-}" = --session-room ]; then
    session=$(fm_seat_threshold) || return 1
    shift
  fi
  if [ "$any" -eq 0 ] || [ "$spare_move" -eq 1 ]; then
    spared=$(fm_seat_spared_leader) || spared=''
  fi
  active=${1:-$(fm_seat_active)}
  [ "$#" -eq 0 ] || shift
  minimum=$(fm_seat_destination_min) || minimum=''
  [ "$any" -eq 1 ] ||
    IFS=$'\t' read -r anchor_basis anchor_spare < <(anchor_headroom "$active")
  mapfile -t seats < <(fm_seat_list)
  n=${#seats[@]}
  [ "$n" -gt 0 ] || return 1
  idx=-1
  for i in "${!seats[@]}"; do
    [ "${seats[$i]}" = "$active" ] && idx=$i
  done
  for ((i = 1; i <= n; i++)); do
    name=${seats[$(((idx + i) % n))]}
    [ "$name" != "$active" ] || continue
    for skip in "$@"; do
      [ "$name" != "$skip" ] || break
    done
    if [ "$#" -gt 0 ] && [ "$name" = "$skip" ]; then
      printf 'seat %s: skipped, this worker already walled out on it\n' "$name" >&2
      continue
    fi
    if [ "$FM_SEAT_PROVIDER" = codex ] &&
      [ "$(fm_seat_credential_identity "$(fm_seat_config_dir "$name")")" = \
        "$(fm_seat_credential_identity "$(fm_seat_config_dir "$active")")" ]; then
      printf 'seat %s: skipped, shares the active credential store\n' "$name" >&2
      continue
    fi
    # The exclusion is checked before anything is read about the seat, so a seat
    # held out of rotation costs no quota call and is reported as withheld on
    # purpose rather than as a seat that failed a check.
    if fm_seat_auto_excluded "$name"; then
      printf 'seat %s: skipped, excluded from automatic rotation (fm-seat.sh auto-include %s puts it back; switch %s still reaches it)\n' \
        "$name" "$name" "$name" >&2
      continue
    fi
    # Resting is checked second and separately, so a seat held out by hand is
    # always reported as held out and the floor never speaks for the operator's
    # own choice. Like the exclusion it costs no quota call.
    if fm_seat_resting "$name" && resting=$(resting_summary "$name"); then
      printf 'seat %s: skipped, resting below the quota floor (%s; fm-seat.sh resting wake %s returns it early; switch %s still reaches it)\n' \
        "$name" "$resting" "$name" "$name" >&2
      continue
    fi
    if [ "$spare_move" -eq 1 ] && fm_seat_matches_spared "$name" "$spared"; then
      continue
    fi
    state=$(login_state "$name")
    if ! seat_usable "$state"; then
      # Each unusable state gets its own reason. Only a seat proven to hold no
      # login is reported as not logged in; an undecided read says exactly that
      # instead, because claiming a seat has no login when its store could not
      # be read is the same wrong assertion this change removes for a lapsed
      # seat, reached through a different branch.
      case "$state" in
        not-logged-in)
          printf 'seat %s: skipped, not logged in\n' "$name" >&2 ;;
        *)
          printf 'seat %s: skipped, its login state could not be confirmed\n' "$name" >&2 ;;
      esac
      continue
    fi
    if [ "$spare_move" -eq 1 ] && [ -n "$session" ] &&
      IFS=$'\t' read -r _ left phrase < <(seat_crossing "$name") && [ -n "$left" ] &&
      jq -en --arg l "$left" --arg t "$session" '($l | tonumber) <= ($t | tonumber)' >/dev/null 2>&1; then
      printf 'seat %s: skipped, at %s it is not above the %s%% switch trigger\n' "$name" "$phrase" "$session" >&2
      continue
    fi
    reason=$(destination_quota_check "$name" "$anchor_basis" "$anchor_spare")
    rc=$?
    if [ "$rc" -ne 0 ] && [ -n "$session" ]; then
      reason=$(session_room_reason "$name" "$session")
      room=$?
      if [ "$room" -ne 1 ]; then
        printf 'seat %s: skipped, %s\n' "$name" "$reason" >&2
        [ "$room" -ne 0 ] || [ "$rc" -ne 1 ] || waiting+=("$name")
        continue
      fi
    fi
    case "$rc" in
      1)
        if fm_seat_matches_spared "$name" "$spared"; then
          fallback=$name
          continue
        fi
        if [ "$anchor_basis" != week-spare ] || ! key=$(seat_rank_key "$name" "$i"); then
          printf '%s\n' "$name"
          return 0
        fi
        ranked+=("$key")
        continue
        ;;
      0)
        printf 'seat %s: skipped, %s\n' "$name" "$reason" >&2
        continue
        ;;
    esac
    # No verdict. With no destination minimum an idle seat is still a
    # destination, which is the login-only outcome this had before any candidate
    # quota was read; with one set the comparison has no number to make and the
    # seat is skipped for that reason rather than for its login state.
    if [ -z "$minimum" ]; then
      if fm_seat_matches_spared "$name" "$spared"; then
        fallback=$name
        continue
      fi
      if [ "$anchor_basis" != week-spare ]; then
        printf '%s\n' "$name"
        return 0
      fi
      # Ranked last of all: it is still a destination, but a seat whose
      # headroom was actually measured is always the better answer, and this
      # one has no figure to be placed by.
      ranked+=("$(printf '2\t0\t0\t%s\t%s' "$i" "$name")")
      continue
    fi
    # A renewable seat lands here by construction: nothing can read its quota
    # until something renews it, so it has no headroom figure to compare and
    # is skipped for that reason rather than for its login state. Saying which
    # is what stops an operator reading a merely idle seat as a broken one.
    if [ "$state" = expired-renewable ]; then
      printf 'seat %s: skipped, signed in but its access token has lapsed, so its headroom cannot be read until a worker launched there renews it\n' "$name" >&2
    else
      printf 'seat %s: skipped, %s\n' "$name" "$reason" >&2
    fi
  done
  if [ "${#ranked[@]}" -eq 0 ]; then
    if [ -n "$fallback" ]; then
      printf '%s\n' "$fallback"
      return 0
    fi
    [ "${#waiting[@]}" -eq 0 ] || printf '%s\n' "${waiting[@]}"
    return 1
  fi
  LC_ALL=C printf '%s\n' "${ranked[@]}" |
    LC_ALL=C sort -t"$(printf '\t')" -k1,1n -k2,2n -k3,3nr -k4,4n |
    head -1 | cut -f5
}

# A spared leader ranks behind any eligible worker seat even when it has more
# weekly spare. Session room, the switch trigger and absolute destination gates
# still apply, so a departure never lands on a seat the rotation must leave. Once
# off the leader, ordinary anchor comparison and fired-state hysteresis resume.
spare_leader_destination() {
  local active=$1 spared
  local -a room=()
  spared=$(fm_seat_spared_leader) || return 1
  fm_seat_matches_spared "$active" "$spared" || return 1
  if fm_seat_threshold >/dev/null; then room=(--session-room); fi
  next_seat --spare-leader ${room[@]+"${room[@]}"} "$active"
}

# write_active <name>
# Replace config/claude-seat atomically, or remove it for the default seat. This
# is the whole of a switch: one file that only a fresh spawn ever reads.
write_active_unlocked() {
  local name=$1 tmp
  mkdir -p "$CONFIG" || die "could not create $CONFIG"
  if [ "$name" = "$FM_SEAT_DEFAULT_NAME" ]; then
    rm -f "$CONFIG/${FM_SEAT_PROVIDER}-seat" || die "could not clear $CONFIG/${FM_SEAT_PROVIDER}-seat"
    return 0
  fi
  tmp="$CONFIG/.${FM_SEAT_PROVIDER}-seat.$$"
  printf '%s\n' "$name" > "$tmp" || die "could not write $tmp"
  mv -f "$tmp" "$CONFIG/${FM_SEAT_PROVIDER}-seat" || die "could not publish $CONFIG/${FM_SEAT_PROVIDER}-seat"
}

# The lock covers publication itself, not a racy preflight-only test.
write_active() {
  local profile
  profile=$(fm_seat_config_dir "$1") || return 1
  export CONFIG FM_SEAT_PROVIDER FM_SEAT_DEFAULT_NAME
  export -f write_active_unlocked die
  # shellcheck disable=SC2016  # Expanded by the guarded child shell.
  python3 "$SCRIPT_DIR/fm-seat-lock.py" guard --nonblocking --provider "$FM_SEAT_PROVIDER" \
    --profile "$profile" -- bash -c 'write_active_unlocked "$1"' fm-seat "$1" ||
    die "seat '$1' is renewing or its lock is unavailable; retry after renewal completes"
}

cmd_switch() {
  local name='' force=0 rotate=0 prior state dir resting reason
  seat_command_memo
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --next) rotate=1; shift ;;
      --force) force=1; shift ;;
      -*) usage ;;
      *) [ -z "$name" ] || usage; name=$1; shift ;;
    esac
  done
  if [ "$rotate" -eq 1 ]; then
    [ -z "$name" ] || usage
    # A rotation asked for BY HAND is the operator's own choice of where to put
    # new work, like `switch <name>`, so it asks which seats are usable rather
    # than which one improves on this seat. The automatic watch does not come
    # through here: it chooses its destination itself and then switches to it by
    # name, which is where the improvement rule belongs.
    name=$(next_seat --any) || die "no seat under the seats root qualifies as a destination (each skipped seat and its reason is printed above); add and log into a second seat, put an excluded seat back with 'fm-seat.sh auto-include <name>', or lower 'fm-seat.sh destination-min' (docs/claude-seats.md). The default profile is never a rotation target, so switch to it by name if that is what you want"
  fi
  [ -n "$name" ] || usage
  if [ "$name" != "$FM_SEAT_DEFAULT_NAME" ]; then
    fm_seat_name_valid "$name" || die "invalid seat name: $name"
    dir=$(fm_seat_dir "$name") || die "seat '$name' does not resolve to a profile directory"
    # A missing profile probes as undecided, which --force would cross; refuse
    # it outright so a typo cannot point every new worker at nothing.
    [ -d "$dir" ] || die "seat '$name' has no profile directory at $dir; run 'fm-seat.sh add $name' first"
  fi
  prior=$(fm_seat_active)
  if [ "$name" = "$prior" ]; then
    printf 'seat unchanged: %s\n' "$name"
    return 0
  fi
  # An explicit switch still reaches a resting seat, exactly as it reaches one
  # held out by hand; it only says what it is landing on, because the floor
  # withholds a seat from the AUTOMATIC paths and not from a deliberate choice.
  if fm_seat_resting "$name" && resting=$(resting_summary "$name"); then
    printf 'warning: %s is resting below the quota floor (%s); switching to it anyway\n' \
      "$name" "$resting" >&2
  fi
  fm_seat_config_dir "$name" >/dev/null || die "seat '$name' does not resolve to a safe profile"
  state=$(login_state "$name")
  case "$state" in
    logged-in) ;;
    expired-renewable)
      # No --force needed. The session is signed in and the next worker launched
      # here renews it; refusing would send the operator to --force for a seat
      # that is simply idle, which is how most seats read after eight hours.
      printf "seat '%s' is signed in but its access token has lapsed; the next %s worker launched there renews it\\n" "$name" "$FM_SEAT_PROVIDER"
      ;;
    not-logged-in)
      # A hard refusal: this profile has no credentials, so every worker sent
      # there would fail on its first message. --force cannot override a proven
      # negative, only an undecided probe.
      die "seat '$name' is not logged in; run: $(fm_seat_login_command "$(fm_seat_config_dir "$name")")"
      ;;
    *)
      [ "$force" -eq 1 ] || die "could not confirm seat '$name' is logged in (quota read gave no verdict); re-run with --force to switch anyway"
      ;;
  esac
  # The quota half of the same destination test the automatic rotation applies.
  # A deliberate switch still reaches an excluded or resting seat, because those
  # withhold a seat from the AUTOMATIC paths only; it does not reach a seat whose
  # quota is gone, because no worker launched there could run. --force is the
  # explicit override, exactly as it is for an undecided login probe, and a read
  # that reached no verdict changes nothing.
  if reason=$(destination_quota_check "$name"); then
    [ "$force" -eq 1 ] ||
      die "seat '$name' is not a destination: $reason; re-run with --force to switch anyway"
    printf "warning: switching to seat '%s' anyway: %s\n" "$name" "$reason" >&2
  fi
  write_active "$name" || return 1
  printf 'switched: %s -> %s\n' "$prior" "$name"
  printf 'applies to NEW %s workers only; running workers keep their own seat\n' "$FM_SEAT_PROVIDER"
  propagate_to_secondmates
}

# propagate_to_secondmates [what-changed] [what-stale-homes-keep-doing]
# Carry the switch to this machine's live secondmate homes through the one
# existing convergence, bin/fm-config-push.sh, which reports every home as
# updated, unchanged, skipped, or failed. Remote routes never receive seat
# settings (bin/fm-config-inherit-lib.sh). A failed push never undoes the
# primary's switch; it is reported, and the push can be re-run on its own.
propagate_to_secondmates() {
  local what=${1:-'seat switched'} stale=${2:-'keep spawning on their previous seat'}
  if FM_HOME="$FM_HOME" FM_ROOT_OVERRIDE="$FM_ROOT" FM_STATE_OVERRIDE="$STATE" \
    FM_CONFIG_OVERRIDE="$CONFIG" "$SCRIPT_DIR/fm-config-push.sh" --local-only; then
    return 0
  fi
  printf 'warning: %s here, but not every secondmate home was updated (see above); those homes %s until bin/fm-config-push.sh --local-only succeeds\n' "$what" "$stale" >&2
}

cmd_add() {
  local name=$1 dir source_home=${3-}
  [ "$name" != "$FM_SEAT_DEFAULT_NAME" ] ||
    die "'$FM_SEAT_DEFAULT_NAME' names the ambient login, not a seat directory; choose another name"
  fm_seat_name_valid "$name" || die "invalid seat name: $name"
  dir=$(fm_seat_dir "$name") || die "seat '$name' does not resolve to a profile directory"
  if [ "$FM_SEAT_PROVIDER" = codex ]; then
    [ $# -eq 1 ] || { [ $# -eq 3 ] && [ "${2-}" = --home ]; } ||
      die 'usage: fm-seat.sh --provider codex add <name> [--home <existing-home>]'
    if [ -n "$source_home" ]; then
      case "$source_home" in /*) ;; *) die '--home must be an absolute path' ;; esac
      [ -d "$source_home" ] && [ -f "$source_home/auth.json" ] ||
        die '--home must name an existing Codex home containing auth.json'
      if [ -e "$dir" ] || [ -L "$dir" ]; then
        [ -d "$dir" ] && [ "$(cd "$dir" && pwd -P)" = "$(cd "$source_home" && pwd -P)" ] ||
          die "seat '$name' already exists and points elsewhere"
      else
        mkdir -p "$(fm_seat_root)" || die 'could not create seats root'
        ln -s "$source_home" "$dir" || die 'could not register Codex home'
      fi
      printf 'registered existing Codex home: %s -> %s; no authentication copied\n' "$dir" "$source_home"
    else
      [ ! -L "$dir" ] || [ -d "$dir" ] || die "seat '$name' is a broken alias"
      mkdir -p "$dir" || die "could not create $dir"
      printf 'Codex home: %s; no authentication copied\n' "$dir"
    fi
    printf 'login command: '
    fm_seat_login_command "$dir"
    return 0
  fi
  [ $# -eq 1 ] || die 'Claude add takes one seat name'
  mkdir -p "$dir" || die "could not create $dir"
  chmod 700 "$dir" 2>/dev/null || true
  printf 'seat profile directory: %s\n' "$dir"
  printf '\n'
  printf 'This created an empty profile directory and nothing else. No credential\n'
  printf 'was read, copied, or written, and the Keychain was not touched.\n'
  printf '\n'
  printf 'The account owner now logs this seat in, personally, in a terminal:\n'
  printf '\n'
  printf '  '; fm_seat_login_command "$dir"
  printf '\n'
  printf 'then runs /login inside that session and signs in as the account this\n'
  printf 'seat should bill to. Claude Code stores those credentials under a\n'
  printf 'Keychain entry derived from this directory path, so they never mix with\n'
  printf 'the default login. Confirm with:\n'
  printf '\n'
  printf '  bin/fm-seat.sh probe %s\n' "$name"
  printf '\n'
  printf 'and then make it the active seat with:\n'
  printf '\n'
  printf '  bin/fm-seat.sh switch %s\n' "$name"
}

# lead_profile
# The native profile the LEAD itself runs under, from the record beside the
# session lock. Empty output with a zero status is the ambient default profile,
# which is a real answer; a nonzero status means this home has not recorded one
# for its current lead, so nothing here may guess.
lead_profile() {
  fm_session_lock_runtime_field "$STATE" profile
}

# Single rollout switch for automatic Codex leader destinations. Explicit
# lead-restart --provider codex --to NAME bypasses selection and remains usable.
# config/lead-codex-auto is exactly on|off; absent means off, malformed refuses.
fm_seat_lead_codex_auto() {
  local value=off
  if [ -e "$CONFIG/lead-codex-auto" ]; then
    value=$(cat "$CONFIG/lead-codex-auto") || return 1
  fi
  case "$value" in
    on|off) printf '%s\n' "$value" ;;
    *) echo 'error: config/lead-codex-auto must contain on or off' >&2; return 1 ;;
  esac
}

# Validate the settings selection consumes before considering any destination.
# The generic seat readers intentionally conflate absent and malformed settings;
# the leader must not interpret a malformed gate as permission to route around it.
leader_selection_config() {
  local root setting value entry name
  root=$(fm_seat_root)
  if [ -e "$CONFIG/$FM_SEAT_PROVIDER-seats-root" ]; then
    value=$(cat "$CONFIG/$FM_SEAT_PROVIDER-seats-root") || return 1
    [ "$value" = "$root" ] && [ -d "$root" ] || {
      echo "error: invalid $FM_SEAT_PROVIDER seats root: expected an existing absolute directory without whitespace" >&2
      return 1
    }
  fi
  case "$root" in /*) ;; *) echo "error: invalid $FM_SEAT_PROVIDER seats root: must be absolute" >&2; return 1 ;; esac
  for setting in destination-min threshold floor floor-readd session-share; do
    [ ! -e "$CONFIG/$FM_SEAT_PROVIDER-seat-$setting" ] || {
      value=$(cat "$CONFIG/$FM_SEAT_PROVIDER-seat-$setting") || return 1
      if ! [[ "$value" =~ ^[0-9]+(\.[0-9]+)?$ ]] || ! fm_seat_percent_file "$CONFIG/$FM_SEAT_PROVIDER-seat-$setting" >/dev/null; then
        echo "error: invalid $FM_SEAT_PROVIDER seat $setting" >&2
        return 1
      fi
    }
  done
  if [ -e "$CONFIG/$FM_SEAT_PROVIDER-seat-extra-usage" ]; then
    value=$(cat "$CONFIG/$FM_SEAT_PROVIDER-seat-extra-usage") || return 1
    if [[ "$value" == *$'\n'* ]] || ! fm_seat_extra_usage_policy >/dev/null; then
      echo "error: invalid $FM_SEAT_PROVIDER extra-usage policy" >&2; return 1
    fi
  fi
  if [ -e "$CONFIG/$FM_SEAT_PROVIDER-seat-resting" ] && fm_seat_floor >/dev/null; then
    jq -e 'type == "object" and (.seats | type) == "object"' "$CONFIG/$FM_SEAT_PROVIDER-seat-resting" >/dev/null 2>&1 || {
      echo "error: invalid $FM_SEAT_PROVIDER resting record" >&2; return 1;
    }
  fi
  if [ -e "$CONFIG/$FM_SEAT_PROVIDER-seat-auto-exclude" ]; then
    while IFS= read -r name || [ -n "$name" ]; do
      [ -z "$name" ] || fm_seat_name_valid "$name" || {
        echo "error: invalid $FM_SEAT_PROVIDER excluded seat name" >&2; return 1;
      }
    done < "$CONFIG/$FM_SEAT_PROVIDER-seat-auto-exclude"
  fi
  for entry in "$root"/*; do
    [ -d "$entry" ] || continue
    fm_seat_name_valid "${entry##*/}" || {
      echo "error: invalid $FM_SEAT_PROVIDER seat directory: $entry" >&2; return 1;
    }
  done
}

# leader-destination ranks named seats of BOTH native providers for the leader.
# It reads each credential profile's default TOON once; only ambiguous evidence
# permits one JSON fallback. The separate Claude dispatch policy gate is retained.
# Catalogs: Claude's --help native opus alias, Codex's profile models_cache.json.
# Missing discovery stays explicit uncertainty; a catalog omitting the model
# excludes it. Both use the strongest native class (opus / gpt-6.1-sol).
# The 180s default horizon is expected successor startup, not an estimate of
# an indefinitely supervised session. Unknown runway never proves that floor.
# Prints "provider seat", all candidate evidence on stderr. Ties refuse to pick.
# Codex destinations obey the single lead-codex-auto rollout switch above.
cmd_leader_destination() {
  local horizon=180 current_provider current_profile provider seat profile model catalog reason
  local snapshot evidence bound minimum decision candidates='' identity current_identity seen='' tied candidate used_json codex_auto
  local -a quota_args=()
  if [ "${1-}" = --horizon ]; then
    [ "$#" -eq 2 ] || usage
    horizon=$2
  elif [ "$#" -ne 0 ]; then
    usage
  fi
  [[ "$horizon" =~ ^[1-9][0-9]*$ ]] || die 'leader horizon must be positive seconds'
  codex_auto=$(fm_seat_lead_codex_auto) || return 1
  for provider in claude codex; do
    FM_SEAT_PROVIDER=$provider leader_selection_config || return 1
  done
  current_provider=$(fm_session_lock_runtime_field "$STATE" harness) || current_provider=claude
  case "$current_provider" in claude|codex) ;; *) die "unsupported leader harness: $current_provider" ;; esac
  current_profile=$(lead_profile) || die 'leader profile is not recorded'
  current_identity=$(FM_SEAT_PROVIDER="$current_provider" fm_seat_credential_identity "$current_profile") || return 1
  for provider in claude codex; do
    local FM_SEAT_PROVIDER=$provider
    minimum=$(fm_seat_destination_min) || minimum=''
    if [ -f "$CONFIG/$provider-seat-destination-min" ] && [ -z "$minimum" ]; then
      die "invalid $provider destination minimum"
    fi
    while IFS= read -r seat; do
      profile=$(fm_seat_config_dir "$seat") || return 1
      reason='' catalog='unknown' evidence='{}' used_json=false
      model=opus; [ "$provider" != codex ] || model=gpt-6.1-sol
      identity=$(fm_seat_credential_identity "$profile") || return 1
      case "$seen" in
        *"|$provider:$identity|"*) reason='configuration error: duplicate credential profile' ;;
      esac
      seen+="|$provider:$identity|"
      if [ "$provider" = "$current_provider" ] && [ "$identity" = "$current_identity" ]; then
        reason=${reason:-'current leader credential store'}
      elif fm_seat_auto_excluded "$seat"; then
        reason=${reason:-'excluded from automatic rotation'}
      elif fm_seat_resting "$seat"; then
        reason=${reason:-'resting below configured quota floor'}
      elif [ "$provider" = codex ] && [ "$codex_auto" = off ]; then
        reason=${reason:-'policy withheld: config/lead-codex-auto is off'}
      fi
      if [ "$provider" = claude ]; then
        bound=$(fm_seat_read_bound) || bound=1
        snapshot=$(fm_run_timed "$bound" claude --help 2>/dev/null </dev/null) || snapshot=''
        if [[ "$snapshot" == *opus* ]]; then
          catalog='claude --help: opus alias'
        elif [ -n "$snapshot" ]; then
          catalog='claude --help omits opus'; reason=${reason:-'model unsupported by native discovery'}
        fi
      elif [ -f "$profile/models_cache.json" ]; then
        if jq -e --arg model "$model" '.models[]? | select(.slug == $model)' "$profile/models_cache.json" >/dev/null 2>&1; then
          catalog="models_cache.json: $model"
        elif jq -e '.models | type == "array"' "$profile/models_cache.json" >/dev/null 2>&1; then
          catalog="models_cache.json omits $model"; reason=${reason:-'model unsupported by native catalog'}
        fi
      fi
      if [ -z "$reason" ] && [ "$provider" = claude ]; then
        decision=$(fm_seat_dispatch_decision "$profile")
        case "$decision" in hold*) reason="Claude dispatch gate: $decision" ;; esac
      fi
      if [ -z "$reason" ]; then
        quota_args=(--provider "$provider" --no-credential-refresh)
        [ "$provider" != codex ] || quota_args+=(--profile-only)
        bound=$(fm_seat_read_bound) || bound=0
        snapshot=''
        [ "$bound" -gt 0 ] || reason='selection read deadline exhausted'
        if [ "$bound" -gt 0 ]; then
          snapshot=$(fm_run_timed "$bound" env -u CLAUDE_SECURESTORAGE_CONFIG_DIR "$(fm_seat_env_name)=$profile" quota-axi "${quota_args[@]}" 2>/dev/null </dev/null) || :
        fi
        evidence=$(printf '%s\n' "$snapshot" | python3 "$SCRIPT_DIR/fm-lead-seat.py" evidence "$provider" "$model" "$horizon" "$minimum" 2>/dev/null) || evidence='{"fallback":true}'
        if [ "$(jq -r '.fallback' <<< "$evidence")" = true ]; then
          used_json=true
          bound=$(fm_seat_read_bound) || bound=0
          snapshot=''
          [ "$bound" -gt 0 ] || reason='selection read deadline exhausted'
          if [ "$bound" -gt 0 ]; then
            snapshot=$(fm_run_timed "$bound" env -u CLAUDE_SECURESTORAGE_CONFIG_DIR "$(fm_seat_env_name)=$profile" quota-axi "${quota_args[@]}" --json 2>/dev/null </dev/null) || :
          fi
          evidence=$(printf '%s\n' "$snapshot" | python3 "$SCRIPT_DIR/fm-lead-seat.py" evidence "$provider" "$model" "$horizon" "$minimum" 2>/dev/null) || evidence='{"reason":"quota evidence unreadable"}'
        fi
      fi
      candidates+=$(jq -cn --arg provider "$provider" --arg seat "$seat" --arg profile "$profile" \
        --arg model "$model" --arg catalog "$catalog" --arg reason "$reason" --argjson evidence "$evidence" --argjson used_json "$used_json" \
        '{provider:$provider,seat:$seat,profile:$profile,model:$model,catalog:$catalog,reason:$reason,evidence:$evidence,used_json:$used_json}')$'\n'
    done < <(fm_seat_list)
  done
  # A genuine TOON tie permits the same single JSON fallback as unknown quota.
  # Never take another snapshot for a candidate that already used that fallback.
  tied=$(printf '%s' "$candidates" | jq -cs '
    map(select(.reason == "" and .evidence.feasible and (.evidence.spendPriority | type) == "number")) |
    if length == 0 then [] else (map(.evidence.spendPriority) | max) as $best |
      map(select(.evidence.spendPriority == $best)) | if length > 1 then . else [] end end |
    .[] | select(.used_json | not)')
  while IFS= read -r candidate; do
    [ -n "$candidate" ] || continue
    provider=$(jq -r '.provider' <<< "$candidate")
    local FM_SEAT_PROVIDER=$provider
    profile=$(jq -r '.profile' <<< "$candidate")
    model=$(jq -r '.model' <<< "$candidate")
    minimum=$(fm_seat_destination_min) || minimum=''
    quota_args=(--provider "$provider" --no-credential-refresh --json)
    [ "$provider" != codex ] || quota_args+=(--profile-only)
    bound=$(fm_seat_read_bound) || { echo 'leader selection held: read deadline exhausted during tie fallback' >&2; return 1; }
    snapshot=''
    if [ "$bound" -gt 0 ]; then
      snapshot=$(fm_run_timed "$bound" env -u CLAUDE_SECURESTORAGE_CONFIG_DIR "$(fm_seat_env_name)=$profile" quota-axi "${quota_args[@]}" 2>/dev/null </dev/null) || :
    fi
    evidence=$(printf '%s\n' "$snapshot" | python3 "$SCRIPT_DIR/fm-lead-seat.py" evidence "$provider" "$model" "$horizon" "$minimum" 2>/dev/null) || evidence='{"reason":"quota evidence unreadable"}'
    candidates=$(printf '%s' "$candidates" | jq -c --arg provider "$provider" --arg profile "$profile" --argjson evidence "$evidence" '
      if .provider == $provider and .profile == $profile then .evidence=$evidence | .used_json=true else . end')$'\n'
  done <<< "$tied"
  printf '%s' "$candidates" | python3 "$SCRIPT_DIR/fm-lead-seat.py" select
}

# The restart transaction stays in fm-lead-restart.sh; both manual and automatic
# unspecified destinations share the cross-provider leader-only selection.
cmd_lead_restart() {
  local to='' provider=$FM_SEAT_PROVIDER choice forwarded=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --provider) [ "$#" -ge 2 ] || usage; provider=$2; shift 2 ;;
      --to) [ "$#" -ge 2 ] || usage; to=$2; shift 2 ;;
      --check | --persisted) forwarded+=("$1"); shift ;;
      --launch-command | --grace) [ "$#" -ge 2 ] || usage; forwarded+=("$1" "$2"); shift 2 ;;
      *) usage ;;
    esac
  done
  if [ -z "$to" ]; then
    choice=$(cmd_leader_destination) || die 'no seat qualifies as a destination for firstmate itself'
    read -r provider to <<< "$choice"
  fi
  FM_HOME="$FM_HOME" FM_ROOT_OVERRIDE="$FM_ROOT" FM_STATE_OVERRIDE="$STATE" \
    FM_CONFIG_OVERRIDE="$CONFIG" FM_DATA_OVERRIDE="$DATA" \
    "$SCRIPT_DIR/fm-lead-restart.sh" --provider "$provider" --to "$to" ${forwarded[@]+"${forwarded[@]}"}
}

# write_percent_setting <file-name> <label> <value>
# The shared setter behind `threshold` and `destination-min`: both hold one
# percent LEFT, both clear with `off`, and both refuse a value outside 0-100
# rather than clamping it into something the operator did not ask for.
write_percent_setting() {
  local file=$1 label=$2 v=$3 tmp
  mkdir -p "$CONFIG" || die "could not create $CONFIG"
  if [ "$v" = off ]; then
    rm -f "$CONFIG/$file" || die "could not clear the $label"
    printf '%s cleared\n' "$label"
    return 0
  fi
  local LC_ALL=C
  [[ "$v" =~ ^[0-9]+(\.[0-9]+)?$ ]] ||
    die "$label must be a percent left between 0 and 100, or 'off'"
  jq -en --arg v "$v" '($v | tonumber) > 0 and ($v | tonumber) <= 100' >/dev/null 2>&1 ||
    die "$label must be a percent left between 0 and 100, or 'off'"
  tmp="$CONFIG/.$file.$$"
  printf '%s\n' "$v" > "$tmp" || die "could not write $tmp"
  mv -f "$tmp" "$CONFIG/$file" || die "could not publish the $label"
  printf '%s: %s%% left\n' "$label" "$v"
}

cmd_threshold() {
  local v=${1-}
  if [ -z "$v" ]; then
    if v=$(fm_seat_threshold); then
      printf '%s\n' "$v"
      return 0
    fi
    printf '(unset - no automatic switching)\n'
    return 0
  fi
  write_percent_setting "${FM_SEAT_PROVIDER}-seat-threshold" 'auto-switch threshold' "$v"
}

cmd_destination_min() {
  local v=${1-}
  if [ -z "$v" ]; then
    if v=$(fm_seat_destination_min); then
      printf '%s\n' "$v"
      return 0
    fi
    printf '(unset - any logged-in seat is a valid destination)\n'
    return 0
  fi
  write_percent_setting "${FM_SEAT_PROVIDER}-seat-destination-min" 'destination minimum' "$v"
}

# The extra-usage policy is the one seat setting that is not a percentage, so it
# has its own setter rather than being bent into the percent shape.
cmd_extra_usage() {
  local mode=${1-} amount=${2-} v tmp
  if [ -z "$mode" ]; then
    if v=$(fm_seat_extra_usage_policy); then
      case "$v" in
        stop) printf 'stop - hold new Claude dispatch rather than start work on paid extra usage\n' ;;
        *)    printf 'allow up to $%s of paid extra usage, then hold new Claude dispatch\n' "${v#allow }" ;;
      esac
      return 0
    fi
    printf '(unset - no dispatch hold; new workers launch whatever the quota says)\n'
    return 0
  fi
  mkdir -p "$CONFIG" || die "could not create $CONFIG"
  case "$mode" in
    off)
      rm -f "$CONFIG/${FM_SEAT_PROVIDER}-seat-extra-usage" || die "could not clear the extra-usage policy"
      printf 'extra-usage policy cleared; nothing holds Claude dispatch\n'
      return 0
      ;;
    stop) v=stop ;;
    allow)
      local LC_ALL=C
      [[ "$amount" =~ ^[0-9]+(\.[0-9]+)?$ ]] ||
        die "'allow' needs a dollar cap, for example: extra-usage allow 25"
      v="allow $amount"
      ;;
    *) die "extra-usage must be 'stop', 'allow <usd>', or 'off'" ;;
  esac
  tmp="$CONFIG/.${FM_SEAT_PROVIDER}-seat-extra-usage.$$"
  printf '%s\n' "$v" > "$tmp" || die "could not write $tmp"
  mv -f "$tmp" "$CONFIG/${FM_SEAT_PROVIDER}-seat-extra-usage" || die "could not publish the extra-usage policy"
  if [ "$v" = stop ]; then
    printf 'extra-usage policy: stop\n'
    printf 'new Claude workers are held once the active seat has no plan quota left.\n'
    printf 'This stops STARTING new work. It cannot stop a worker already running from\n'
    printf 'drawing extra usage mid-task, so it is not a guarantee of zero spend.\n'
  else
    printf 'extra-usage policy: allow up to $%s, then hold\n' "$amount"
    printf 'Measured against the spend the account itself reports for this seat.\n'
  fi
}

# write_auto_exclude <name...>
# Replace config/claude-seat-auto-exclude atomically with the given names, or
# remove it when none are left, so an empty exclusion is the absent file rather
# than an empty one that reads the same but looks configured.
write_auto_exclude() {
  local tmp
  mkdir -p "$CONFIG" || die "could not create $CONFIG"
  if [ "$#" -eq 0 ]; then
    rm -f "$CONFIG/${FM_SEAT_PROVIDER}-seat-auto-exclude" ||
      die "could not clear the automatic-rotation exclusions"
    return 0
  fi
  tmp="$CONFIG/.${FM_SEAT_PROVIDER}-seat-auto-exclude.$$"
  printf '%s\n' "$@" > "$tmp" || die "could not write $tmp"
  mv -f "$tmp" "$CONFIG/${FM_SEAT_PROVIDER}-seat-auto-exclude" ||
    die "could not publish the automatic-rotation exclusions"
}

# print_auto_exclude
# The current exclusions, or the explicit unset line, so `auto-exclude` with no
# argument answers the same question `status` does without the rest of it.
print_auto_exclude() {
  local rows
  rows=$(fm_seat_auto_exclude_list)
  if [ -z "$rows" ]; then
    printf '(none - every seat under the root is an automatic rotation candidate)\n'
    return 0
  fi
  printf '%s\n' "$rows"
}

# cmd_auto_exclude [<name>]
# Hold one seat out of every automatic path while leaving `switch <name>` alone.
# It refuses a name with no seat directory, because an exclusion that matches
# nothing is a typo that would silently keep rotating onto the seat it meant to
# withhold.
cmd_auto_exclude() {
  local name=${1-} kept=() entry
  if [ -z "$name" ]; then
    print_auto_exclude
    return 0
  fi
  [ "$name" != "$FM_SEAT_DEFAULT_NAME" ] ||
    die "'$FM_SEAT_DEFAULT_NAME' names the ambient login, which is never an automatic rotation target, so there is nothing to exclude"
  fm_seat_name_valid "$name" || die "invalid seat name: $name"
  fm_seat_dir "$name" >/dev/null || die "seat '$name' does not resolve to a profile directory"
  [ -d "$(fm_seat_dir "$name")" ] ||
    die "seat '$name' has no profile directory under $(fm_seat_root); run 'fm-seat.sh add $name' first, or check the name against 'fm-seat.sh list'"
  if fm_seat_auto_excluded "$name"; then
    printf 'already excluded from automatic rotation: %s\n' "$name"
    return 0
  fi
  while IFS= read -r entry; do
    kept+=("$entry")
  done < <(fm_seat_auto_exclude_list)
  kept+=("$name")
  write_auto_exclude ${kept[@]+"${kept[@]}"}
  printf 'excluded from automatic rotation: %s\n' "$name"
  printf "'fm-seat.sh switch %s' still switches to it; only the automatic paths skip it\n" "$name"
  # Excluding the seat in use withholds it as a future DESTINATION and moves
  # nothing, which is worth saying where it is easy to read as a switch away.
  [ "$name" != "$(fm_seat_active)" ] ||
    printf 'it is the active seat and stays active; new workers keep launching there until something switches\n'
}

# cmd_auto_include <name>
# Put a seat back into automatic rotation. A name that is not excluded is
# already in rotation, so this reports that and succeeds; it deliberately does
# not require the seat to still exist, so a stale entry can always be cleared.
cmd_auto_include() {
  local name=${1-} kept=() entry removed=0
  [ -n "$name" ] || usage
  if ! fm_seat_auto_excluded "$name"; then
    printf 'not excluded from automatic rotation: %s\n' "$name"
    return 0
  fi
  while IFS= read -r entry; do
    if [ "$entry" = "$name" ]; then
      removed=1
      continue
    fi
    kept+=("$entry")
  done < <(fm_seat_auto_exclude_list)
  [ "$removed" -eq 1 ] || die "could not remove '$name' from the automatic-rotation exclusions"
  write_auto_exclude ${kept[@]+"${kept[@]}"}
  printf 'back in automatic rotation: %s\n' "$name"
}

# The TRIGGER half of the automatic switch. It reads the SAME quota surface the
# rest of the fleet reads (quota-axi), against the profile a new worker on the
# active seat would get, and never opens a poll loop of its own.
cmd_threshold_reached() {
  local threshold name remaining
  threshold=$(fm_seat_threshold) || return 2
  name=$(fm_seat_active)
  if [ "$name" != "$FM_SEAT_DEFAULT_NAME" ]; then
    fm_seat_dir "$name" >/dev/null || return 2
  fi
  # seat_crossing owns which window a crossing is measured against and returns
  # 1 for anything it could not read, so an ambiguous quota stays an error here
  # and never becomes a true that would switch accounts.
  IFS=$'\t' read -r _ remaining _ < <(seat_crossing "$name") || return 2
  [ -n "$remaining" ] || return 2
  jq -en --arg r "$remaining" --arg t "$threshold" \
    '($r | tonumber) <= ($t | tonumber)' >/dev/null 2>&1
}

# --- automatic mode ----------------------------------------------------------
# The de-dupe record. `fired=<seat>` names the seat a switch last landed on, so
# a destination that itself sits below the trigger is not switched away from
# on the very next poll; a switch rewrites it to the new seat, so that seat's
# OWN later crossing fires again with nothing to re-arm by hand.
# `blocked=<seat>:<outcome>` names the seat whose crossing has already been
# reported as having nowhere to go, or as a switch that failed, together with
# the facts that report stated. It silences only that same report: every later
# poll still looks for a destination, so a candidate whose window resets is
# switched to at once, and a pass whose facts differ - the whole vendor now
# empty, a reset moved, the work routed elsewhere - reports again. Both clear
# the moment the active seat reads back above the threshold.
# It also carries `extra=<seat-tokens>`, the set of seats last seen drawing paid
# extra usage, so that warning fires on each seat's own ENTRY rather than on
# every poll for as long as the spend lasts, and `lead=<seat>`, the seat whose
# move instruction was last handed to FIRSTMATE ITSELF, so that instruction
# fires once per seat and not on every poll. A crossing that could not move records `lead=blocked:<seat>:<to>`
# instead, which silences only that same blocker: every poll still re-asks, so
# the instruction goes out as soon as the move becomes available.
# `resting_workers=<seat:since ...>` records resting entries already warned
# about, and drops entries once they return to rotation.
# `pipeline=<seat:since ...>` records resting entries with live pipeline agents
# already warned about, preserving the worker-warning record independently.
# Optional spare_blocked records a failed proactive departure independently of
# threshold crossings, so a healthy active seat cannot re-announce it each poll.
AUTO_RECORD="$STATE/.${FM_SEAT_PROVIDER}-seat-auto"

auto_record_get() {
  [ -f "$AUTO_RECORD" ] || return 1
  sed -n "s/^$1=//p" "$AUTO_RECORD" 2>/dev/null | tail -1
}

# auto_record_set <key> <value>
# Replace one field, preserving the others. The record is small and rewritten
# whole, so a partial write can never leave a half-updated record behind.
auto_record_set() {
  local key=$1 value=$2 fired blocked extra lead resting_workers pipeline tmp spare_blocked
  fired=$(auto_record_get fired) || fired=''
  blocked=$(auto_record_get blocked) || blocked=''
  extra=$(auto_record_get extra) || extra=''
  lead=$(auto_record_get lead) || lead=''
  resting_workers=$(auto_record_get resting_workers) || resting_workers=''
  pipeline=$(auto_record_get pipeline) || pipeline=''
  spare_blocked=$(auto_record_get spare_blocked) || spare_blocked=''
  case "$key" in
    fired) fired=$value ;;
    blocked) blocked=$value ;;
    extra) extra=$value ;;
    lead) lead=$value ;;
    resting_workers) resting_workers=$value ;;
    pipeline) pipeline=$value ;;
    spare_blocked) spare_blocked=$value ;;
  esac
  mkdir -p "$STATE" 2>/dev/null || return 1
  tmp=$(umask 077; mktemp "$STATE/.fm-seat-auto.XXXXXX" 2>/dev/null) || return 1
  { printf 'fired=%s\n' "$fired"; printf 'blocked=%s\n' "$blocked"; printf 'extra=%s\n' "$extra"; printf 'lead=%s\n' "$lead"; printf 'resting_workers=%s\n' "$resting_workers"; printf 'pipeline=%s\n' "$pipeline";
    if [ -n "$spare_blocked" ]; then printf 'spare_blocked=%s\n' "$spare_blocked"; fi; } > "$tmp" ||
    { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$AUTO_RECORD" || { rm -f -- "$tmp"; return 1; }
}

# extra_record_token <seat-name>
# The token the extra-usage record stores for one seat. A managed seat name
# cannot contain whitespace (fm_seat_name_valid) and the ambient default seat is
# `default`, but fm_seat_name_of_profile reports an UNMANAGED profile by its own
# path, which can. The record is one space-separated line, so a token carrying a
# space would be indistinguishable from two tokens; percent-escaping the few
# bytes that would break the line keeps the mapping injective, which is what the
# per-seat membership test below relies on.
extra_record_token() {  # <seat-name>
  local t=${1-}
  t=${t//%/%25}
  t=${t// /%20}
  t=${t//$'\t'/%09}
  t=${t//$'\n'/%0A}
  t=${t//$'\r'/%0D}
  printf '%s' "$t"
}

# extra_record_has <record> <token>
# 0 when the space-separated extra-usage record already holds that seat's token.
extra_record_has() {  # <record> <token>
  case " $1 " in *" $2 "*) return 0 ;; esac
  return 1
}

# warn_extra_usage_entry
# The loud half of the stop policy. Firstmate cannot stop a running worker from
# drawing paid extra usage, so the next best thing is to say so the moment it
# starts: every seat a live task is running on is checked, and one notification
# goes out through the home's single notification path
# (bin/fm-usage-warner.sh notify) naming the seats that have just entered extra
# usage. Reported on stdout too, because that line is what wakes firstmate.
#
# ENTRY IS PER SEAT, NOT PER SET. Only a seat the record does not already hold
# speaks; a seat it holds stays silent however the rest of the set moves, and a
# seat that leaves updates the record silently, which is what re-arms its own
# next entry. Comparing the whole set's STRING instead - what this did before -
# made every change to the set re-alarm each seat in it, so one unrelated task
# finishing was enough to wake firstmate again about a seat whose own state had
# not changed since it was reported, on the watcher cadence, for as long as the
# spend lasted.
warn_extra_usage_entry() {
  local meta seat name token task_seats='' out spending='' entering='' summary previous
  [ -d "$STATE" ] || return 0
  # Only a CLAUDE task's recorded profile is a Claude seat. A task on any other
  # harness records no seat and reads no Claude profile, so including it would
  # check the ambient store on that task's behalf and report a seat it never
  # spends. An empty recorded seat on a claude task is the ambient default,
  # which that worker really does spend, so it stays in.
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    [ "$(sed -n 's/^harness=//p' "$meta" | tail -1)" = claude ] || continue
    [ "$(sed -n 's/^harness=//p' "$meta" | tail -1)" = "$FM_SEAT_PROVIDER" ] || continue
    seat=$(sed -n "s/^${FM_SEAT_PROVIDER}_seat=//p" "$meta" | tail -1)
    task_seats="${task_seats}${seat}
"
  done
  task_seats=$(printf '%s' "$task_seats" | sort -u)
  [ -n "$task_seats" ] || return 0
  previous=$(auto_record_get extra) || previous=''
  while IFS= read -r seat; do
    name=$(fm_seat_name_of_profile "$seat")
    token=$(extra_record_token "$name")
    if out=$(fm_seat_quota_json "$seat"); then
      fm_seat_in_extra_usage_from "$out" || continue
    else
      # A seat whose read gave no verdict, including one the pass ran out of
      # time for, keeps its previous state rather than reading as having left
      # extra usage, so a slow read can never re-arm the warning and wake twice.
      extra_record_has "$previous" "$token" || continue
    fi
    spending="${spending}${token} "
    extra_record_has "$previous" "$token" || entering="${entering}${name} "
  done <<< "$task_seats"
  spending=${spending% }
  entering=${entering% }
  [ "$spending" = "$previous" ] || auto_record_set extra "$spending"
  [ -n "$entering" ] || return 0
  summary="Claude seat in paid extra usage: $entering"
  printf '%s-seat: %s (a worker already running keeps this seat; only the account admin setting stops it drawing extra usage)\n' "$FM_SEAT_PROVIDER" "$summary"
  "$SCRIPT_DIR/fm-usage-warner.sh" notify "$summary" >/dev/null 2>&1 || true
}

# warn_resting_workers: one warning per resting entry, naming only positively
# live local Claude tasks and the complete control command for each. No worker
# is moved by the watch. Profile paths in task records are resolved to names by
# the seat library, and quota reads for a destination share this pass's memo.
warn_resting_workers() {
  local previous current='' name since token meta seat id tasks commands destination active command
  local kind brief result profile model effort codex_command project offer_bound offer_rc
  previous=$(auto_record_get resting_workers) || previous=''
  if ! fm_seat_floor >/dev/null; then
    [ -z "$previous" ] || auto_record_set resting_workers ''
    return 0
  fi
  active=$(fm_seat_active)
  while IFS=$'\t' read -r name since; do
    [ -n "$name" ] || continue
    token="$name:$since"
    case " $previous " in
      *" $token "*) current="$current$token "; continue ;;
    esac
    tasks=''
    for meta in "$STATE"/*.meta; do
      [ -f "$meta" ] || continue
      [ "$(fm_meta_get "$meta" harness)" = claude ] || continue
      [ -z "$(fm_meta_get "$meta" remote_host)" ] || continue
      seat=$(fm_seat_name_of_profile "$(fm_meta_get "$meta" claude_seat)")
      [ "$seat" = "$name" ] || continue
      id=${meta##*/}; id=${id%.meta}
      fm_backend_validate_task_endpoint "$meta" "$id" >/dev/null 2>&1 || continue
      [ "$(fm_backend_agent_state "$FM_BACKEND_VALIDATED_BACKEND" "$FM_BACKEND_VALIDATED_TARGET")" = alive ] || continue
      tasks="$tasks$id "
    done
    [ -n "$tasks" ] || continue
    destination=$active
    if [ "$destination" = "$name" ] || fm_seat_resting "$destination" \
       || ! seat_usable "$(login_state "$destination")"; then
      destination=$(next_seat 2>/dev/null) || destination=$FM_SEAT_DEFAULT_NAME
    fi
    commands=''
    for id in $tasks; do
      printf -v command 'FM_HOME=%q %q %q relaunch --seat %q --note %q' \
        "$FM_HOME" "$SCRIPT_DIR/fm-control.sh" "$id" "$destination" \
        'Seat rested; reconcile the preserved work and instruction inbox before continuing.'
      commands="${commands}${commands:+$'\n'}  Claude move for $id: $command"
      meta="$STATE/$id.meta"
      kind=$(fm_meta_get "$meta" kind)
      case "$kind" in ship|scout) ;; *) continue ;; esac
      brief="$DATA/$id/brief.md"
      [ -r "$brief" ] || continue
      project=$(fm_meta_get "$meta" project)
      # Keep the optional lookup inside this pass's quota-read deadline. An
      # off, uncertain or timed-out resolver leaves the Claude offer intact.
      offer_bound=$(fm_seat_read_bound) || continue
      result=$(FM_HOME="$FM_HOME" FM_CONFIG_OVERRIDE="$CONFIG" \
        fm_run_timed "$offer_bound" "$SCRIPT_DIR/fm-dispatch-resolve.sh" "$brief" \
        --project "${project##*/}" --codex-alternative --json 2>/dev/null)
      offer_rc=$?
      if [ "$offer_rc" != 0 ]; then
        if [ "$offer_rc" = 2 ]; then
          printf '%s-seat: Codex offer for %s unavailable; dispatch configuration needs attention\n' "$FM_SEAT_PROVIDER" "$id"
        fi
        continue
      fi
      profile=$(jq -ce 'select(.status == "clear" and .chosen.profile.harness == "codex") | .chosen.profile' \
        <<< "$result" 2>/dev/null) || continue
      model=$(jq -r '.model // ""' <<< "$profile")
      effort=$(jq -r '.effort // ""' <<< "$profile")
      printf -v codex_command 'FM_HOME=%q %q %q relaunch --harness codex' \
        "$FM_HOME" "$SCRIPT_DIR/fm-control.sh" "$id"
      if [ -n "$model" ]; then
        printf -v command ' --model %q' "$model"; codex_command+=$command
      fi
      if [ -n "$effort" ]; then
        printf -v command ' --effort %q' "$effort"; codex_command+=$command
      fi
      printf -v command ' --note %q' \
        'Seat rested; reconcile the preserved work and instruction inbox before continuing on Codex.'
      commands="$commands"$'\n'"  Codex alternative for $id: $codex_command$command"
    done
    printf '%s-seat: %s is resting with running workers: %s; move each explicitly (Claude destination login is validated; default is the fallback when rotation has no candidate):\n%s\n' "$FM_SEAT_PROVIDER" \
      "$name" "${tasks% }" "$commands"
    current="$current$token "
  done < <(fm_seat_resting_record | jq -r '.seats | to_entries[] | select(.value.provisional != true) | [.key, .value.since] | @tsv')
  current=${current% }
  [ "$current" = "$previous" ] || auto_record_set resting_workers "$current"
}

# warn_pipeline_resting_entry
# Warn once per resting entry about managed pipeline agents already on it.
# Uses launch PID/start stamps, never harness banners or endpoint discovery.
# The move command selects the next launches' seat only: individual running
# agent migration needs no-mistakes support. Even a manual whole-run abort and
# revalidation needs explicit approval because it discards in-flight work.
warn_pipeline_resting_entry() {
  local live name entry token previous current='' summary move
  live=$(fm_seat_pipeline_live)
  previous=$(auto_record_get pipeline) || previous=''
  printf -v move 'env FM_HOME=%q FM_CONFIG_OVERRIDE=%q FM_STATE_OVERRIDE=%q %q pipeline-move' \
    "$FM_HOME" "$CONFIG" "$STATE" "$SCRIPT_DIR/fm-seat.sh"
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    fm_seat_resting "$name" || continue
    entry=$(fm_seat_resting_entry "$name") || continue
    token="$name:$(printf '%s' "$entry" | jq -r '.since')"
    current="${current}${token} "
    case " $previous " in *" $token "*) continue ;; esac
    summary="pipeline agent is still running on resting seat $name; it finishes untouched. Move subsequent launches with: $move. Clear NM_CLAUDE_CONFIG_DIR in the pipeline environment if set. Moving an individual running agent requires no-mistakes support; a manual whole-run abort-and-revalidate needs the captain's approval because it discards in-flight work"
    printf '%s-seat: %s\n' "$FM_SEAT_PROVIDER" "$summary"
    "$SCRIPT_DIR/fm-usage-warner.sh" notify "$summary" >/dev/null 2>&1 || true
  done < <(printf '%s' "$live" | jq -r '[.[].seat] | unique[]')
  current=${current% }
  [ "$current" = "$previous" ] || auto_record_set pipeline "$current"
}

cmd_pipeline_move() {
  local active reason
  seat_command_memo
  # The move follows active-seat rotation, irrespective of an override in the
  # shell issuing it. Overrides belong to the pipeline launch environment.
  active=$(fm_seat_active)
  if fm_seat_auto_excluded "$active" || fm_seat_resting "$active" ||
    { [ "$active" != "$FM_SEAT_DEFAULT_NAME" ] && [ ! -d "$(fm_seat_config_dir "$active")" ]; }; then
    cmd_switch --next || return 1
  fi
  reason=$(NM_CLAUDE_CONFIG_DIR='' fm_seat_pipeline_selection | jq -r '.blockedReason // empty')
  if [ -n "$reason" ]; then
    printf 'pipeline selection HELD on active seat %s: %s; active seat kept\n' "$(fm_seat_active)" "$reason" >&2
    return 1
  fi
  printf 'subsequent managed pipeline launches follow active seat %s; running agents finish untouched (clear NM_CLAUDE_CONFIG_DIR in the pipeline environment if set)\n' "$(fm_seat_active)"
}

# One pass of the automatic mode. Prints a line ONLY when firstmate should know,
# and is otherwise completely silent, because it runs on the watcher's cadence
# and every line it prints becomes a wake.
#
# The watcher kills a check that outlives FM_CHECK_TIMEOUT, so the pass sets a
# read deadline a few seconds inside it (the margin bin/fm-usage-warner.sh
# leaves) that every quota read it makes respects, and runs the trigger and
# switch before the extra-usage scan, so that scan can never spend the switch's
# budget. A read the deadline cuts short gives no verdict, like any other
# unreadable quota.
cmd_auto() {
  local threshold floor policy check_timeout memo
  threshold=$(fm_seat_threshold) || threshold=''
  floor=$(fm_seat_floor) || floor=''
  # A home that configured neither pays nothing: no quota is read at all.
  [ -n "$threshold" ] || [ -n "$floor" ] || fm_seat_spare_leader_enabled || return 0
  check_timeout=${FM_CHECK_TIMEOUT:-30}
  case "$check_timeout" in
    ''|*[!0-9]*|0) check_timeout=30 ;;
  esac
  FM_SEAT_READ_DEADLINE=$(($(date +%s) + check_timeout - 3))
  export FM_SEAT_READ_DEADLINE
  # One read per seat for the whole pass, including the reads the child `switch`
  # makes, so adding the floor costs no extra quota call. The memo lives only as
  # long as the pass: nothing outside it ever reads a figure it did not take.
  if memo=$(mktemp -d "${TMPDIR:-/tmp}/fm-seat-pass.XXXXXX" 2>/dev/null); then
    FM_SEAT_READ_MEMO_DIR=$memo
    export FM_SEAT_READ_MEMO_DIR
    # shellcheck disable=SC2064 # the path is fixed now, not when the trap runs.
    trap "rm -rf -- '$memo'" EXIT
    trap 'exit 143' TERM
    trap 'exit 130' INT
    trap 'exit 129' HUP
  else
    memo=''
  fi
  policy=$(fm_seat_extra_usage_policy) || policy=''
  # The floor runs FIRST, so a switch in this same pass can never land on a seat
  # this pass just rested.
  auto_floor
  [ "$FM_SEAT_PROVIDER" != claude ] || warn_pipeline_resting_entry
  auto_spare_leader
  if [ -n "$threshold" ]; then
    auto_trigger "$threshold" "$policy"
    [ "$FM_SEAT_PROVIDER" != claude ] || auto_lead_trigger "$threshold"
  fi
  [ -z "$policy" ] || warn_extra_usage_entry
  [ "$FM_SEAT_PROVIDER" != claude ] || warn_resting_workers
}

# auto_lead_trigger <threshold>
# The Claude-seat watch is the single leader controller. Its Claude threshold
# applies to the recorded incumbent's native provider, including Codex; the
# Codex-seat watch remains worker-only. A successor needs no second watch.
# The crossing is separate from auto_trigger because the lead keeps its account while
# config/claude-seat moves under it, so the two can be on different seats and
# cross at different times.
#
# This poll hands the move to the LEAD rather than performing it, and that is
# about which process can do it, not about who decides. Replacing the lead drops
# its conversation, so the open work held only there has to be written down first
# - the same persist gate bin/fm-secondmate-restart.sh puts in front of every
# second mate's restart. This poll is a separate process from the lead and cannot
# write that conversation down, so the only correct thing it can do is hand the
# lead the gate and the exact command, which is how a second mate's restart is
# sequenced too.
#
# The line it prints is an INSTRUCTION, not an option to put to the captain. The
# captain set the threshold, so the threshold firing is the instruction, and the
# lead carries the move out on that wake like any other actionable check result.
# The claude-seat-lead-restart skill owns that handling; the line stays
# self-sufficient so it is still complete with no skill loaded.
#
# Nothing is reported unless the move is actually available: the destination is
# chosen across native providers by leader-destination, then put through restart
# preflight, so a crossing with no signed-in destination, no established launch
# command, session, or terminal, says exactly that instead of offering a
# restart that would refuse.
auto_lead_trigger() {  # <threshold>
  local threshold=$1 profile seat remaining phrase target reported out provider choice incumbent selection
  provider=$(fm_session_lock_runtime_field "$STATE" harness) || provider=claude
  case "$provider" in claude|codex) ;; *) return 0 ;; esac
  profile=$(lead_profile) || return 0
  seat=$(FM_SEAT_PROVIDER="$provider" fm_seat_name_of_profile "$profile")
  incumbent="$provider:$seat"
  IFS=$'\t' read -r _ remaining phrase < <(FM_SEAT_PROVIDER="$provider" seat_crossing "$seat") || return 0
  [ -n "$remaining" ] || return 0
  if ! jq -en --arg r "$remaining" --arg t "$threshold" \
    '($r | tonumber) <= ($t | tonumber)' >/dev/null 2>&1; then
    auto_record_set lead ''
    return 0
  fi
  reported=$(auto_record_get lead) || reported=''
  [ "$reported" != "$incumbent" ] || return 0
  if ! selection=$(cmd_leader_destination 2>&1); then
    [ "$reported" != "blocked:$incumbent:" ] || return 0
    auto_record_set lead "blocked:$incumbent:"
    printf '%s\n' "$selection"
    printf '%s-seat: firstmate itself is on %s at %s and no seat qualifies as a destination, so it stays where it is\n' "$FM_SEAT_PROVIDER" \
      "$seat" "$phrase"
    return 0
  fi
  choice=${selection##*$'\n'}
  read -r provider target <<< "$choice"
  if ! out=$(FM_HOME="$FM_HOME" FM_ROOT_OVERRIDE="$FM_ROOT" FM_STATE_OVERRIDE="$STATE" \
    FM_CONFIG_OVERRIDE="$CONFIG" FM_DATA_OVERRIDE="$DATA" \
    "$SCRIPT_DIR/fm-lead-restart.sh" --check --provider "$provider" --to "$target" 2>&1); then
    [ "$reported" != "blocked:$incumbent:$provider:$target" ] || return 0
    auto_record_set lead "blocked:$incumbent:$provider:$target"
    printf '%s\n' "${selection%$'\n'*}"
    printf '%s-seat: firstmate itself is on %s at %s and cannot move to %s: %s\n' "$FM_SEAT_PROVIDER" \
      "$seat" "$phrase" "$provider:$target" "$(printf '%s' "$out" | sed -n '/./{s/^error: //;s/[[:space:]]\{1,\}/ /g;p;q;}')"
    return 0
  fi
  auto_record_set lead "$incumbent"
  printf '%s\n' "${selection%$'\n'*}"
  printf '%s-seat: firstmate itself is on %s at %s and moves to %s now, on this wake, without asking the captain (load the claude-seat-lead-restart skill). Replacing this session drops its conversation and keeps every durable record, so FIRST %s THEN run exactly: %s/bin/fm-seat.sh lead-restart --provider %s --to %s --persisted\n' "$FM_SEAT_PROVIDER" \
    "$seat" "$phrase" "$provider:$target" "$FM_PERSIST_OPEN_RECORDS_CONTRACT" "$FM_ROOT" "$provider" "$target"
}

# Proactively spare the leader without touching running workers or leader
# replacement. Record the destination before publishing, as auto_trigger does.
auto_spare_leader() {
  local active target fired out blocked
  active=$(fm_seat_active)
  target=$(spare_leader_destination "$active" 2>/dev/null) || return 0
  fired=$(auto_record_get fired) || fired=''
  auto_record_set fired "$target"
  if out=$(FM_HOME="$FM_HOME" FM_ROOT_OVERRIDE="$FM_ROOT" FM_STATE_OVERRIDE="$STATE" \
    FM_CONFIG_OVERRIDE="$CONFIG" FM_DATA_OVERRIDE="$DATA" \
    "$SCRIPT_DIR/fm-seat.sh" switch "$target" 2>&1); then
    auto_record_set blocked ''
    auto_record_set spare_blocked ''
    printf '%s-seat: switched from %s to %s to spare the leader; new workers launch there\n' \
      "$FM_SEAT_PROVIDER" "$active" "$target"
  else
    auto_record_set fired "$fired"
    blocked=$(auto_record_get spare_blocked) || blocked=''
    [ "$blocked" != "spare:$active:failed:$target" ] || return 0
    auto_record_set spare_blocked "spare:$active:failed:$target"
    printf '%s-seat: could not spare leader seat %s: %s\n' \
      "$FM_SEAT_PROVIDER" "$active" "$(printf '%s' "$out" | tail -1)"
  fi
}

# auto_trigger <threshold> <policy>
# The trigger and switch half of one automatic pass.
auto_trigger() {
  local threshold=$1 policy=$2 active dir remaining phrase target fired blocked out
  local depleted alt notice
  active=$(fm_seat_active)
  dir=$(fm_seat_config_dir "$active")
  if ! IFS=$'\t' read -r _ remaining phrase < <(seat_crossing "$active"); then
    # Silent: an unreadable quota is a transient condition on a poll that runs
    # every cycle, and reporting it on each one would be noise, not a wake.
    # Nothing is switched on it either, which is the part that matters.
    return 0
  fi
  [ -n "$remaining" ] || return 0
  if ! jq -en --arg r "$remaining" --arg t "$threshold" \
    '($r | tonumber) <= ($t | tonumber)' >/dev/null 2>&1; then
    auto_record_set fired ''
    auto_record_set blocked ''
    # The vendor is demonstrably not dry, so the standing notice is forgotten
    # and the next depletion announces itself instead of being silenced by it.
    fm_seat_dry_clear "$STATE" "$FM_SEAT_PROVIDER"
    return 0
  fi
  fired=$(auto_record_get fired) || fired=''
  [ "$fired" != "$active" ] || return 0
  blocked=$(auto_record_get blocked) || blocked=''
  if target=$(next_seat 2>/dev/null); then
    # Re-invoked as a subprocess so a refusal inside the switch ends that call
    # rather than this poll, and with this home's own resolution forwarded so
    # the switch lands in the home the watcher is polling for. The destination
    # is recorded as fired BEFORE the switch runs, so a pass the watcher kills
    # after the switch wrote the seat cannot rotate that seat again next pass.
    auto_record_set fired "$target"
    if out=$(FM_HOME="$FM_HOME" FM_ROOT_OVERRIDE="$FM_ROOT" FM_STATE_OVERRIDE="$STATE" \
      FM_CONFIG_OVERRIDE="$CONFIG" FM_DATA_OVERRIDE="$DATA" \
      "$SCRIPT_DIR/fm-seat.sh" switch "$target" 2>&1); then
      auto_record_set blocked ''
      printf '%s-seat: switched from %s at %s to %s; new workers launch there\n' "$FM_SEAT_PROVIDER" \
        "$active" "$phrase" "$target"
      return 0
    fi
    auto_record_set fired "$fired"
    [ "$blocked" != "$active:failed:$target" ] || return 0
    auto_record_set blocked "$active:failed:$target"
    printf '%s-seat: %s is at %s and the switch to %s failed: %s\n' "$FM_SEAT_PROVIDER" \
      "$active" "$phrase" "$target" "$(printf '%s' "$out" | tail -1)"
    return 0
  fi
  # Every seat of this vendor out of quota is its own outcome, not a failure to
  # find headroom: there is nowhere on this vendor to go, so nothing moves -
  # which is what stops a pass flipping between two empty seats - and the notice
  # says where the work goes instead. A seat a paid extra-usage policy still
  # covers is not dry, so that case falls through to the policy line below
  # rather than claiming the vendor is empty.
  if ! fm_seat_extra_usage_covers "$dir"; then
    depleted=$(fm_seat_provider_depletion_summary)
    case "$?" in
      0)
        alt=$(fm_seat_alternative_headroom) || alt=''
        notice=$(fm_seat_dry_notice "$FM_SEAT_PROVIDER" "$depleted" "$alt")
        # Announced through the record the spawn gate shares, so an armed watch
        # and a spawn attempt report one depletion once between them rather than
        # twice in two different wordings.
        fm_seat_dry_announce "$STATE" "$FM_SEAT_PROVIDER" "$notice" || return 0
        printf '%s-seat: %s. No switch was made.\n' "$FM_SEAT_PROVIDER" "$notice"
        return 0
        ;;
      2)
        # One seat gave no verdict, so nothing is proven either way. Saying
        # anything here would let a transient unreadable read re-announce a
        # depletion that has not changed, so this pass stays silent and leaves
        # every record exactly as it found it.
        return 0
        ;;
    esac
  fi
  [ "$blocked" != "$active:short" ] || return 0
  auto_record_set blocked "$active:short"
  case "$policy" in
    stop)
      printf '%s-seat: %s is at %s and no seat has enough headroom to switch to; new Claude work will be held once this seat'\''s plan quota runs out, rather than started on paid extra usage. A worker already running is not stopped.\n' "$FM_SEAT_PROVIDER" \
        "$active" "$phrase" ;;
    allow\ *)
      printf '%s-seat: %s is at %s and no seat has enough headroom to switch to; once this seat'\''s plan quota runs out, new Claude work continues on paid extra usage up to $%s, then will be held.\n' "$FM_SEAT_PROVIDER" \
        "$active" "$phrase" "${policy#allow }" ;;
    *)
      printf '%s-seat: %s is at %s and no seat has enough headroom to switch to; no extra-usage policy is set, so nothing is held.\n' "$FM_SEAT_PROVIDER" \
        "$active" "$phrase" ;;
  esac
}

# --- the quota floor ---------------------------------------------------------
# The floor rests a seat whose session or weekly window has run down, and wakes
# it only on a reading that proves it recovered. bin/fm-seat-lib.sh owns the
# settings, the record, and the session-share measurement; this half owns the
# pass, the operator surface, and every line either of them prints.

cmd_floor() {
  local v=${1-} readd
  if [ -z "$v" ]; then
    if v=$(fm_seat_floor); then
      printf '%s\n' "$v"
      return 0
    fi
    printf '(unset - no seat is ever rested out of automatic rotation)\n'
    return 0
  fi
  write_percent_setting "${FM_SEAT_PROVIDER}-seat-floor" 'quota floor' "$v"
  if [ "$v" = off ]; then
    # Clearing the floor wakes every seat it rested: a record nothing will ever
    # lift again must not outlive the floor here or in a secondmate home.
    [ -f "$CONFIG/${FM_SEAT_PROVIDER}-seat-resting" ] || return 0
    rm -f "$CONFIG/${FM_SEAT_PROVIDER}-seat-resting" || die "could not clear the resting record"
    printf 'every seat the floor was resting is back in automatic rotation\n'
    propagate_to_secondmates 'quota floor cleared' 'keep skipping the seats it was resting'
    return 0
  fi
  readd=$(fm_seat_floor_readd) || return 0
  printf 'a rested seat comes back only above %s%% left on BOTH windows, after at least %ss of rest, and only when its week can still absorb a whole session\n' \
    "$readd" "$(fm_seat_floor_dwell)"
  # Warnings, never refusals: both are judgements about tuning, and an operator
  # who means them should not have to fight the setter.
  local threshold share
  if threshold=$(fm_seat_threshold) &&
    jq -en --arg f "$v" --arg t "$threshold" '($f | tonumber) >= ($t | tonumber)' >/dev/null 2>&1; then
    printf 'warning: the floor is at or above the auto-switch trigger of %s%%, so the active seat will rest before anything switches away from it; a floor BELOW the trigger is the usual order\n' \
      "$threshold" >&2
  fi
  share=$(fm_seat_session_share_value '' | cut -f1)
  if jq -en --arg r "$readd" --arg s "$share" '(($r | tonumber) + ($s | tonumber)) >= 95' >/dev/null 2>&1; then
    printf 'warning: coming back needs %s%% left on the week plus a whole session (%s%%), which a week rarely has, so seats will rest for a long time\n' \
      "$readd" "$share" >&2
  fi
}

cmd_floor_readd() {
  local v=${1-} configured
  if [ -z "$v" ]; then
    configured=$(fm_seat_percent_file "$CONFIG/${FM_SEAT_PROVIDER}-seat-floor-readd") || configured=''
    if v=$(fm_seat_floor_readd); then
      if [ "$v" = "$configured" ]; then
        printf '%s\n' "$v"
      elif [ -n "$configured" ]; then
        printf '%s (derived from the floor; the configured %s is not above the floor, so it is ignored)\n' "$v" "$configured"
      else
        printf '%s (derived from the floor)\n' "$v"
      fi
      return 0
    fi
    if [ -n "$configured" ]; then
      printf '%s\n' "$configured"
      return 0
    fi
    printf '(unset - no floor is configured, so nothing is ever resting)\n'
    return 0
  fi
  local floor
  if [ "$v" != off ] && floor=$(fm_seat_floor) &&
    jq -en --arg v "$v" --arg f "$floor" '($v | tonumber) <= ($f | tonumber)' >/dev/null 2>&1; then
    die "the quota floor re-add level must be above the ${floor}% floor, or a seat it wakes would rest again on the next reading"
  fi
  write_percent_setting "${FM_SEAT_PROVIDER}-seat-floor-readd" 'quota floor re-add level' "$v"
}

cmd_floor_dwell() {
  local v=${1-} tmp
  if [ -z "$v" ]; then
    if v=$(fm_seat_seconds_file "$CONFIG/${FM_SEAT_PROVIDER}-seat-floor-dwell"); then
      printf '%s\n' "$v"
      return 0
    fi
    printf '%s (default)\n' "$FM_SEAT_FLOOR_DWELL_DEFAULT"
    return 0
  fi
  mkdir -p "$CONFIG" || die "could not create $CONFIG"
  if [ "$v" = off ]; then
    rm -f "$CONFIG/${FM_SEAT_PROVIDER}-seat-floor-dwell" || die "could not clear the quota floor rest time"
    printf 'quota floor rest time cleared; the default of %ss applies\n' "$FM_SEAT_FLOOR_DWELL_DEFAULT"
    return 0
  fi
  local LC_ALL=C
  [[ "$v" =~ ^[0-9]+$ ]] ||
    die "the quota floor rest time must be a whole number of seconds, 0 for no minimum rest, or 'off'"
  tmp="$CONFIG/.${FM_SEAT_PROVIDER}-seat-floor-dwell.$$"
  printf '%s\n' "$v" > "$tmp" || die "could not write $tmp"
  mv -f "$tmp" "$CONFIG/${FM_SEAT_PROVIDER}-seat-floor-dwell" || die "could not publish the quota floor rest time"
  printf 'quota floor rest time: %ss\n' "$v"
}

cmd_session_share() {
  local v=${1-} row
  if [ -z "$v" ]; then
    if v=$(fm_seat_percent_file "$CONFIG/${FM_SEAT_PROVIDER}-seat-session-share"); then
      printf '%s%% of a week per session (set by hand)\n' "$v"
    else
      printf '%s%% of a week per session (built-in default)\n' "$FM_SEAT_SESSION_SHARE_DEFAULT"
    fi
    while IFS= read -r row; do
      [ -n "$row" ] || continue
      printf '%s\n' "$row"
    done < <(session_share_rows)
    return 0
  fi
  write_percent_setting "${FM_SEAT_PROVIDER}-seat-session-share" 'assumed session share of a week' "$v"
}

# session_share_rows
# One line per account the samples record knows, naming the share in force for
# it and whether it was measured. This is the only percentage here that is not a
# percent left, so every surface that prints it says what it is.
session_share_rows() {
  local account value source count
  while IFS= read -r account; do
    [ -n "$account" ] || continue
    IFS=$'\t' read -r value source count < <(fm_seat_session_share_value "$account")
    printf '  %s: %s%% of a week per session (%s, %s sample(s))\n' \
      "$account" "$value" "$source" "$count"
  done < <(fm_seat_session_share_doc | jq -r '(.accounts // {}) | keys[]' 2>/dev/null)
}

# resting_summary <name>
# Why a seat is resting and when it is expected back, as one phrase, or 1 when
# it is not resting. The one owner of that wording, so the rotation skip reason,
# `status`, `list`, and the warning an explicit switch prints cannot disagree.
resting_summary() {
  local name=${1-} entry window remaining expected provisional unreadable line
  entry=$(fm_seat_resting_entry "$name") || return 1
  IFS=$'\t' read -r window remaining expected provisional unreadable < <(
    printf '%s\n' "$entry" | jq -r '
      (.limitingWindow // "") as $w |
      [ (if $w == "" then "?" else $w end),
        ((.windows[$w].remaining // "?") | tostring),
        (.expectedBack // "unknown"),
        (if .provisional then "yes" else "" end),
        ((.unreadableSince // "") | tostring) ] | @tsv' 2>/dev/null)
  line="$window $remaining% left, expected back $expected"
  [ "$provisional" != yes ] ||
    line="$line (back provisionally: its access token lapsed while resting, so the next launch there is what reads it again)"
  [ -z "$unreadable" ] || [ "$unreadable" = null ] ||
    line="$line (its quota has been unreadable since $unreadable, which changes nothing by itself)"
  printf '%s\n' "$line"
}

# print_resting
# Every resting seat with its reason, or the explicit unset line.
print_resting() {
  local floor rows='' name summary
  if ! floor=$(fm_seat_floor); then
    printf '(none - no quota floor is configured, so no seat is ever rested)\n'
    return 0
  fi
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    summary=$(resting_summary "$name") || continue
    rows="${rows}${name}: ${summary}
"
  done < <(fm_seat_resting_record | jq -r '(.seats // {}) | keys[]' 2>/dev/null)
  if [ -z "$rows" ]; then
    printf '(none - every seat is above the %s%% floor, or has not been read yet)\n' "$floor"
    return 0
  fi
  printf '%s' "$rows"
}

# cmd_resting [wake <name>]
# Read the record, or put one seat back into rotation by hand. A hand wake is
# deliberately allowed to cross the re-add rules: the next pass reads the seat
# again and rests it again if it is still low, so the override is temporary by
# construction rather than by promise.
cmd_resting() {
  local verb=${1-} name=${2-} record
  case "$verb" in
    '')
      print_resting
      return 0
      ;;
    wake) ;;
    *) usage ;;
  esac
  [ -n "$name" ] || usage
  fm_seat_resting_entry "$name" >/dev/null || {
    printf 'not resting: %s\n' "$name"
    return 0
  }
  record=$(fm_seat_resting_record | jq -c --arg n "$name" 'del(.seats[$n])')
  fm_seat_resting_write "$record" || die "could not update the resting record"
  printf 'back in automatic rotation: %s\n' "$name"
  printf 'the next automatic pass reads it again and rests it again if it is still at or below the floor\n'
  propagate_to_secondmates "$name woken" "keep skipping it"
}

# floor_expected_back <limiting-window> <session-resets> <week-resets> <week-left> <readd> <share>
# When a resting seat can next be expected back: the reset of the window holding
# it down, or the week's reset when a session reset alone could not wake it
# anyway because the week could not then absorb a whole session.
floor_expected_back() {
  local window=$1 session_reset=$2 week_reset=$3 week=$4 readd=$5 share=$6 pick
  if [ "$window" = "$FM_SEAT_WEEK_WINDOW" ]; then
    pick=$week_reset
  elif [ -n "$week" ] && ! jq -en --arg w "$week" --arg r "$readd" --arg s "$share" \
    '($w | tonumber) >= (($r | tonumber) + ($s | tonumber))' >/dev/null 2>&1; then
    pick=$week_reset
  else
    pick=$session_reset
  fi
  printf '%s\n' "${pick:-unknown}"
}

# floor_wake_due <entry> <now> <readd> <share>
# True when a seat whose quota cannot be read because its token lapsed may come
# back PROVISIONALLY: the reset of the window that rested it has passed by more
# than the skew margin, and, when that window was the session, the week it last
# read could still absorb a whole session. A seat rested for its WEEK therefore
# stays down until its weekly reset, whatever its session does, which is exactly
# the constraint a lapsed seat must not be allowed to slip.
floor_wake_due() {
  local entry=$1 now=$2 readd=$3 share=$4 window resets since window_seconds week due
  IFS=$'\t' read -r window resets since window_seconds week < <(
    printf '%s\n' "$entry" | jq -r '
      (.limitingWindow // "") as $w |
      [ $w,
        (.windows[$w].resetsAt // ""),
        ((.since // 0) | tostring),
        ((.windows[$w].windowSeconds // "") | tostring),
        ((.windows["seven_day"].remaining // "") | tostring) ] | @tsv' 2>/dev/null)
  [ -n "$window" ] || return 1
  if [ -n "$resets" ] && due=$(fm_seat_iso_to_epoch "$resets"); then
    :
  else
    # An idle window can carry no reset time at all, so fall back to the rest
    # time plus the window's own length rather than guessing a reset happened.
    case "$window_seconds" in ''|*[!0-9]*) return 1 ;; esac
    due=$((since + window_seconds))
  fi
  [ "$now" -ge $((due + FM_SEAT_RESET_MARGIN)) ] || return 1
  [ "$window" != "$FM_SEAT_SESSION_WINDOW" ] || {
    [ -n "$week" ] || return 1
    jq -en --arg w "$week" --arg r "$readd" --arg s "$share" \
      '($w | tonumber) >= (($r | tonumber) + ($s | tonumber))' >/dev/null 2>&1 || return 1
  }
  return 0
}

# auto_floor
# The floor half of one automatic pass. It runs BEFORE the switch trigger, so a
# switch in this same pass can never land on a seat the pass just rested, and it
# prints one line per seat that rested or woke and nothing at all otherwise.
#
# An unreadable reading never rests and never wakes a seat, in either direction:
# the previous state stands and only the record's own unreadable mark moves,
# which is the same rule the extra-usage warning applies.
auto_floor() {
  local floor readd dwell now record before name dir entry resting out remaining
  local rows session week session_reset week_reset account share expected limiting
  local new_entry provisional changed=0
  floor=$(fm_seat_floor) || return 0
  readd=$(fm_seat_floor_readd) || return 0
  dwell=$(fm_seat_floor_dwell)
  now=$(date +%s)
  record=$(fm_seat_resting_record)
  before=$record
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    # A seat held out by hand can never be an automatic destination, so reading
    # it would spend a quota call on a question no path acts on. The manual
    # exclusion also takes precedence: the floor never writes that file, and a
    # seat that is both is reported as held out.
    ! fm_seat_auto_excluded "$name" || continue
    dir=$(fm_seat_config_dir "$name")
    resting=0
    provisional=0
    entry=''
    if entry=$(fm_seat_resting_entry "$name"); then
      resting=1
      fm_seat_resting "$name" || provisional=1
    else
      entry=''
    fi
    if ! out=$(fm_seat_quota_json "$dir"); then
      [ "$resting" -eq 1 ] || continue
      record=$(floor_mark_unreadable "$record" "$name" "$now")
      continue
    fi
    if ! remaining=$(fm_seat_remaining_from "$out"); then
      [ "$resting" -eq 1 ] || continue
      if [ "$provisional" -eq 1 ]; then
        record=$(floor_mark_unreadable "$record" "$name" "$now")
        continue
      fi
      share=$(fm_seat_session_share_value "$(printf '%s\n' "$entry" | jq -r '.account // ""')" | cut -f1)
      if fm_seat_login_renewable_from "$out" && floor_wake_due "$entry" "$now" "$readd" "$share"; then
        record=$(printf '%s\n' "$record" | jq -c --arg n "$name" '.seats[$n].provisional = true')
        changed=1
        printf '%s-seat: %s comes back into automatic rotation provisionally - it rested below the %s%% floor, its access token lapsed while it rested, and the reset it was waiting for has passed, so the next worker launched there is what reads its quota again\n' "$FM_SEAT_PROVIDER" \
          "$name" "$floor"
        continue
      fi
      record=$(floor_mark_unreadable "$record" "$name" "$now")
      continue
    fi
    rows=$(fm_seat_windows_from "$out") || rows=''
    session=$(fm_seat_window_field "$rows" "$FM_SEAT_SESSION_WINDOW" 2) || session=''
    week=$(fm_seat_window_field "$rows" "$FM_SEAT_WEEK_WINDOW" 2) || week=''
    session_reset=$(fm_seat_window_field "$rows" "$FM_SEAT_SESSION_WINDOW" 3) || session_reset=''
    week_reset=$(fm_seat_window_field "$rows" "$FM_SEAT_WEEK_WINDOW" 3) || week_reset=''
    account=$(fm_seat_account "$dir" 2>/dev/null) || account=''
    [ -z "$account" ] || [ -z "$session" ] || [ -z "$week" ] ||
      fm_seat_session_share_observe "$account" "$session" "$session_reset" "$week" "$week_reset"
    share=$(fm_seat_session_share_value "$account" | cut -f1)
    if [ "$resting" -eq 0 ]; then
      jq -en --arg r "$remaining" --arg f "$floor" \
        '($r | tonumber) <= ($f | tonumber)' >/dev/null 2>&1 || continue
      limiting=$(fm_seat_limiting_window_from "$out") || limiting=''
      expected=$(floor_expected_back "$limiting" "$session_reset" "$week_reset" "$week" "$readd" "$share")
      new_entry=$(floor_entry "$account" "$limiting" "$expected" "$now" "$rows")
      record=$(printf '%s\n' "$record" | jq -c --arg n "$name" --argjson e "$new_entry" '.seats[$n] = $e')
      changed=1
      printf '%s-seat: %s is resting - %s%% left on its %s window is at or below the %s%% floor, so automatic switches skip it until it recovers (expected back %s; fm-seat.sh switch %s still reaches it)\n' "$FM_SEAT_PROVIDER" \
        "$name" "$remaining" "$(fm_quota_window_label "$limiting")" "$floor" "$expected" "$name"
      continue
    fi
    # A seat back provisionally faces the same wake test on its first readable
    # reading: passing clears its entry, failing rests it again on real figures.
    if floor_may_wake "$entry" "$session" "$week" "$readd" "$share" "$dwell" "$now"; then
      record=$(printf '%s\n' "$record" | jq -c --arg n "$name" 'del(.seats[$n])')
      changed=1
      printf '%s-seat: %s comes back into automatic rotation - %s%% left on its session and %s%% on its week, both above the %s%% re-add level, with room for a whole session\n' "$FM_SEAT_PROVIDER" \
        "$name" "$session" "$week" "$readd"
      continue
    fi
    limiting=$(fm_seat_limiting_window_from "$out") || limiting=''
    expected=$(floor_expected_back "$limiting" "$session_reset" "$week_reset" "$week" "$readd" "$share")
    new_entry=$(floor_entry "$account" "$limiting" "$expected" \
      "$(printf '%s\n' "$entry" | jq -r '.since // 0')" "$rows")
    record=$(printf '%s\n' "$record" | jq -c --arg n "$name" --argjson e "$new_entry" '
      if (.seats[$n] | del(.lastRead)) == ($e | del(.lastRead)) then . else .seats[$n] = $e end')
    [ "$provisional" -eq 1 ] || continue
    changed=1
    printf '%s-seat: %s is resting again - read again after coming back provisionally, it has %s%% left on its session and %s%% on its week, short of the %s%% re-add level with room for a whole session (expected back %s)\n' "$FM_SEAT_PROVIDER" \
      "$name" "$session" "$week" "$readd" "$expected"
  done < <(fm_seat_list)
  # A record that did not move is not rewritten and nothing is pushed, so a
  # steady fleet costs one quota read per seat and no config churn at all.
  [ "$(printf '%s\n' "$record" | jq -Sc .)" != "$(printf '%s\n' "$before" | jq -Sc .)" ] || return 0
  # The reads above can take most of the pass, so the pass's own changes are
  # merged onto the record as it stands NOW. A seat someone woke by hand in the
  # meantime stays woken, and a seat this pass did not change keeps whatever the
  # record holds for it.
  record=$(fm_seat_resting_record | jq -c --argjson before "$before" --argjson pass "$record" \
    --argjson now "$now" '
    reduce ((($before.seats | keys) + ($pass.seats | keys)) | unique[]) as $n (.;
      if $before.seats[$n] == $pass.seats[$n] then .
      elif $before.seats[$n] != null and .seats[$n] == null then .
      elif $pass.seats[$n] == null then del(.seats[$n])
      else .seats[$n] = $pass.seats[$n] end)
    | .schemaVersion = 1 | .updatedAt = $now')
  if ! fm_seat_resting_write "$record"; then
    printf 'warning: a Claude seat crossed the quota floor but the resting record could not be written, so automatic switches may still land on it\n' >&2
    return 0
  fi
  # Only a change to WHICH seats are resting has to reach the secondmate homes:
  # that is the half their own rotation reads. A refreshed figure is display.
  [ "$changed" -eq 1 ] || return 0
  propagate_to_secondmates 'resting record updated' 'keep their previous resting record' >/dev/null
}

# floor_entry <account> <limiting-window> <expected-back> <since> <windows-rows>
# One seat's resting record entry, built from the reading that produced it.
floor_entry() {
  local account=$1 limiting=$2 expected=$3 since=$4 rows=$5
  printf '%s' "$rows" | jq -cRs --arg a "$account" --arg l "$limiting" \
    --arg e "$expected" --argjson s "${since:-0}" --argjson now "$(date +%s)" '
    (split("\n") | map(select(length > 0) | split("\t"))
     | map({ key: .[0],
             value: { remaining: (if .[1] == "" then null else (.[1] | tonumber) end),
                      resetsAt: (if .[2] == "" then null else .[2] end),
                      windowSeconds: (if .[3] == "" then null else (.[3] | tonumber) end) } })
     | from_entries) as $w |
    { since: $s, account: (if $a == "" then null else $a end),
      limitingWindow: (if $l == "" then null else $l end),
      provisional: false, expectedBack: $e,
      lastRead: $now, unreadableSince: null, windows: $w }'
}

# floor_mark_unreadable <record> <name> <now>
# Stamp that a resting seat's quota could not be read, changing nothing else.
# The mark is for display: an unreadable reading never wakes a seat and never
# rests one, so the state it describes is unchanged by definition.
floor_mark_unreadable() {
  printf '%s\n' "$1" | jq -c --arg n "$2" --argjson now "$3" '
    if (.seats[$n] // null) == null then .
    elif (.seats[$n].unreadableSince // null) != null then .
    else .seats[$n].unreadableSince = $now end'
}

# floor_may_wake <entry> <session-left> <week-left> <readd> <share> <dwell> <now>
# The whole wake test, on a fresh reading: both windows back above the re-add
# level, the week able to absorb one more whole session on top of it, and the
# minimum rest elapsed. The middle condition is the one that stops a session
# reset from returning a seat whose remaining week a full session would overrun.
floor_may_wake() {
  local entry=$1 session=$2 week=$3 readd=$4 share=$5 dwell=$6 now=$7 since
  [ -n "$session" ] && [ -n "$week" ] || return 1
  since=$(printf '%s\n' "$entry" | jq -r '.since // 0')
  case "$since" in ''|*[!0-9]*) since=0 ;; esac
  [ $((now - since)) -ge "$dwell" ] || return 1
  jq -en --arg s "$session" --arg w "$week" --arg r "$readd" --arg h "$share" '
    ($s | tonumber) >= ($r | tonumber)
    and ($w | tonumber) >= ($r | tonumber)
    and ($w | tonumber) >= (($r | tonumber) + ($h | tonumber))' >/dev/null 2>&1
}

# --- arm / retire ------------------------------------------------------------
# The watch is a registered check shim rather than the one-shot condition-action
# primitive bin/fm-procevent-when.sh provides, because that primitive fires at
# most once by design and this watch must keep running: after a switch, the seat
# it moved to has its own crossing to catch, and an operator should not have to
# re-arm between them. The action it takes is the safe, reversible half of this
# script - it rewrites one config line that only a fresh spawn reads, and never
# touches a running worker - so it is the deterministic subset a repeating poll
# may carry out on its own. bin/fm-check-shim-lib.sh owns the write and binding.
FM_CHECK_SHIM_ID="${FM_SEAT_PROVIDER}-seat"
FM_CHECK_SHIM_LABEL=fm-seat

cmd_arm() {
  local threshold floor active name candidates=0 all_resting=1
  # Clear any older one-shot registration first, so a home upgrading from it
  # ends with one watch rather than two firing on the same crossing.
  if "$SCRIPT_DIR/fm-procevent-when.sh" source-id "$FM_CHECK_SHIM_ID" >/dev/null 2>&1; then
    "$SCRIPT_DIR/fm-procevent-when.sh" retire "$FM_CHECK_SHIM_ID" >/dev/null 2>&1 || true
  fi
  threshold=$(fm_seat_threshold) || threshold=''
  floor=$(fm_seat_floor) || floor=''
  [ -n "$threshold" ] || [ -n "$floor" ] || fm_seat_spare_leader_enabled ||
    die "no auto-switch threshold or quota floor configured; set one with 'fm-seat.sh threshold <percent-left>' or 'fm-seat.sh floor <percent-left>' first"
  # stdout only is discarded: each candidate's own skip reason belongs on
  # stderr beside the refusal, the same way every other rotation refusal reads,
  # so arming after an exclusion says which seats were withheld.
  if ! next_seat --any >/dev/null; then
    # Every candidate merely RESTING is a warning rather than the refusal: the
    # floor itself is what empties the candidate list, the watch is what refills
    # it, and refusing to arm would leave nothing running to do that. Any
    # candidate withheld for another reason keeps the refusal, because the watch
    # never brings that one back.
    active=$(fm_seat_active)
    while IFS= read -r name; do
      [ -n "$name" ] && [ "$name" != "$active" ] || continue
      candidates=$((candidates + 1))
      if fm_seat_auto_excluded "$name" || ! fm_seat_resting "$name"; then
        all_resting=0
        break
      fi
    done < <(fm_seat_list)
    [ "$candidates" -gt 0 ] && [ "$all_resting" -eq 1 ] ||
      die "no seat under the seats root qualifies as a destination right now, so an automatic switch would have nowhere to go (each skipped seat and its reason is printed above); add and log into a second seat, put an excluded seat back with 'fm-seat.sh auto-include <name>', or lower 'fm-seat.sh destination-min' (docs/claude-seats.md). The default profile is never a rotation target"
    printf 'warning: every candidate seat is resting below the quota floor right now, so a switch would have nowhere to go until one of them recovers; the watch is what brings them back\n' >&2
  fi
  fm_check_shim_arm "$FM_HOME" "$SCRIPT_DIR/fm-seat.sh" --provider "$FM_SEAT_PROVIDER" auto || exit 1
  "$SCRIPT_DIR/fm-seat-renew.sh" arm || exit 1
  if [ -n "$threshold" ]; then
    printf 'armed: automatic switch at %s%% left on the active seat\n' "$threshold"
    printf 'keeps watching after each switch; one crossing fires at most once per seat\n'
  elif fm_seat_spare_leader_enabled; then
    printf 'armed: spare the leader when another eligible worker seat exists\n'
  else
    printf 'armed: the quota floor only - no auto-switch threshold is set, so nothing switches on its own\n'
  fi
  [ -z "$floor" ] ||
    printf 'rests a seat at or below %s%% left and brings it back when a reading proves it recovered\n' "$floor"
}

cmd_retire() {
  fm_check_shim_disarm "$AUTO_RECORD"
  # A home armed before the watch became a repeating check still carries the
  # older one-shot condition-action registration, which nothing else would ever
  # clear. Retiring both is what makes `retire` mean "stop watching" on any home
  # rather than only on a freshly armed one. It is a no-op when none exists.
  if "$SCRIPT_DIR/fm-procevent-when.sh" source-id "$FM_CHECK_SHIM_ID" >/dev/null 2>&1; then
    "$SCRIPT_DIR/fm-procevent-when.sh" retire "$FM_CHECK_SHIM_ID" >/dev/null 2>&1 || true
  fi
  if [ "$FM_SEAT_PROVIDER" = codex ]; then
    printf 'retired: the automatic Codex seat watch\n'
  else
    printf 'retired: the automatic Claude seat watch\n'
  fi
}

case "${1-}" in
  status)            shift; cmd_status "$@" ;;
  pipeline-install)  shift; "$SCRIPT_DIR/fm-seat-pipeline.sh" install "$@" ;;
  pipeline-check)    shift; "$SCRIPT_DIR/fm-seat-pipeline.sh" check "$@" ;;
  pipeline-move)     shift; [ $# -eq 0 ] || usage; cmd_pipeline_move ;;
  list)              shift; cmd_list "$@" ;;
  switch)            shift; cmd_switch "$@" ;;
  probe)             shift; cmd_probe "${1-}" ;;
  name-of)           shift; cmd_name_of "${1-}" ;;
  worker-destination) shift; cmd_worker_destination "$@" ;;
  launch-destination) shift; cmd_launch_destination "$@" ;;
  add)               shift; [ -n "${1-}" ] || usage; cmd_add "$@" ;;
  threshold)         shift; cmd_threshold "${1-}" ;;
  destination-min)   shift; cmd_destination_min "${1-}" ;;
  extra-usage)       shift; cmd_extra_usage "${1-}" "${2-}" ;;
  auto-exclude)      shift; cmd_auto_exclude "${1-}" ;;
  auto-include)      shift; cmd_auto_include "${1-}" ;;
  floor)             shift; cmd_floor "${1-}" ;;
  floor-readd)       shift; cmd_floor_readd "${1-}" ;;
  floor-dwell)       shift; cmd_floor_dwell "${1-}" ;;
  session-share)     shift; cmd_session_share "${1-}" ;;
  resting)           shift; cmd_resting "${1-}" "${2-}" ;;
  leader-destination) shift; cmd_leader_destination "$@" ;;
  lead-restart)      shift; cmd_lead_restart "$@" ;;
  threshold-reached) shift; cmd_threshold_reached ;;
  auto)              shift; cmd_auto ;;
  arm)               shift; cmd_arm "$@" ;;
  retire)            shift; cmd_retire "$@" ;;
  ''|-h|--help|help) usage ;;
  *) die "unknown command: $1" ;;
esac
