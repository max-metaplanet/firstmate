#!/usr/bin/env bash
# Choose which Claude account (seat) NEW claude workers launch on.
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
#   fm-seat.sh lead-restart [--to <name>] [--check] [--persisted]
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
#            qualifying seat after the active one, which is what the automatic
#            watch fires. Rotation covers only named seats under the seats root:
#            the default profile is never a rotation target, because it is the
#            owner's own interactive login and can change account under them.
#            Refuses a seat that is not logged in, because a worker launched
#            there fails on its first message; --force overrides that refusal
#            when the probe itself cannot reach a verdict. A seat whose access
#            token has merely lapsed is accepted with no --force, because the
#            worker launched there renews it. After the switch it
#            runs bin/fm-config-push.sh --local-only so this machine's running local
#            secondmate homes take the new seat too, reporting each home, and
#            naming each seat item a declining home skipped and why.
# probe      Report whether a worker can be launched on a seat. Exit 0 usable
#            (`logged-in`, or `expired-renewable` for a signed-in seat whose
#            access token lapsed and which the next launch renews), 1 proven not
#            logged in, 2 undecided.
# add        Create an empty profile directory for a new seat and print the exact
#            login command the account owner runs. It never logs in, never reads
#            or writes any credential, and never touches the Keychain.
# threshold  TRIGGER. Print, set, or clear the percent LEFT on the ACTIVE seat
#            that trips an automatic switch. Absent means no automatic switching.
# destination-min
#            DESTINATION HEADROOM. Print, set, or clear the percent LEFT a seat
#            must EXCEED to be a switch destination. Absent means the rotation
#            gate is login-only, exactly as it was before this setting existed,
#            and no candidate's quota is read at all.
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
#            switch moves only what the next spawn reads, and no running Claude
#            process can change credential store. So the lead is REPLACED -
#            another claude starts on the new seat in the same terminal,
#            resuming the same session, and the current process ends. Running
#            workers get one fire-and-forget notice and are otherwise
#            untouched: their steering, status, and recorded seat are all
#            durable, and supervision is a separate process that is
#            deliberately left alone. `--check`
#            establishes everything and changes nothing. Without `--to` the
#            destination is chosen by the same rotation a switch uses, anchored
#            on the seat the LEAD is on rather than the seat new workers get.
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
  dir=$(fm_seat_config_dir "$name")
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
    seat=$(sed -n 's/^claude_seat=//p' "$meta" | tail -1)
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
    fm_config_inherit_seat_optout "$VALIDATED_HOME/config" || continue
    printf '%s\t%s\t%s\n' "$id" "$(fm_seat_active "$VALIDATED_HOME/config")" "$VALIDATED_HOME"
  done < <(live_secondmate_meta_records "$STATE" "$DATA/secondmates.md")
}

cmd_status() {
  local active profile threshold minimum policy reason rows excluded floor pipeline
  active=$(fm_seat_active)
  printf 'active seat for NEW workers: %s\n' "$active"
  profile=$(fm_seat_config_dir "$active")
  printf 'active profile: %s\n' "${profile:-(ambient default login)}"
  printf 'login state: %s\n' "$(login_state "$active")"
  pipeline=$(fm_seat_pipeline_report)
  printf '%s\n' "$pipeline" | jq -r '
    "pipeline seat for next managed launch: " + .seat
    + (if .override then " (NM_CLAUDE_CONFIG_DIR override)" else " (follows active seat)" end),
    (if .blockedReason == null then empty else "pipeline selection HELD: " + .blockedReason end),
    (if .profileRecorded then empty else "pipeline default-seat profile not recorded for this home'"'"'s lead; launches use the wrapper'"'"'s installed default profile until a lead restart records it" end),
    (.liveAgents[] | "live pipeline agent: pid=" + (.pid | tostring) + " seat=" + .seat
      + (if .override then " (override)" else "" end))'
  # The lead's own seat is a separate fact from the active one: a switch moves
  # what new workers get and leaves the running lead where it launched, so the
  # two drift apart by design and only `lead-restart` closes that gap.
  if profile=$(lead_profile); then
    printf 'firstmate itself is running on: %s\n' "$(fm_seat_name_of_profile "$profile")"
  else
    printf 'firstmate itself is running on: (not recorded for this session)\n'
  fi
  if threshold=$(fm_seat_threshold); then
    printf 'auto-switch trigger: at or below %s%% left on the active seat\n' "$threshold"
  else
    printf 'auto-switch trigger: (unset - no automatic switching)\n'
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
    printf 'extra-usage policy: (unset - nothing holds Claude dispatch)\n'
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
    printf 'new Claude dispatch: allowed\n'
  else
    printf 'new Claude dispatch: HELD (bin/fm-spawn.sh --ignore-seat-hold starts one task anyway)\n'
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
  case "$state" in
    not-logged-in) return 1 ;;
    *) return 2 ;;
  esac
}

# next_seat [<anchor-seat>]
# The seat after the anchor seat, in list order, that a worker can be launched
# on. The anchor defaults to the active seat, which is every existing caller;
# the lead restart passes the seat the LEAD is on instead, because that is the
# seat it is rotating away from. The selection RULES below are identical either
# way - only the starting point differs.
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
# DESTINATION HEADROOM. With config/claude-seat-destination-min set, a candidate
# must also read MORE than that percent left, so a switch can never land on a
# seat that is nearly empty. A candidate whose quota gives no verdict is SKIPPED
# rather than guessed at in either direction: an ambiguous read is not evidence
# of headroom, and switching onto it would be the guess this refuses to make.
# With the setting absent no candidate quota is read at all and the gate is
# login-only, byte for byte the behaviour that predates it.
#
# A seat whose access token has lapsed always falls in that skipped class while
# the setting is set, because its quota genuinely cannot be read until a launch
# renews it. So this setting and idle seats interact: a home that sets a
# destination minimum will rotate only onto seats something has read recently.
#
# Every rejected candidate is reported on stderr with its reason, so a refusal
# to switch always says which seats were considered and why none qualified.
next_seat() {
  local active seats n i idx name minimum='' remaining state resting
  active=${1:-$(fm_seat_active)}
  minimum=$(fm_seat_destination_min) || minimum=''
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
    if [ -z "$minimum" ]; then
      printf '%s\n' "$name"
      return 0
    fi
    if ! remaining=$(fm_seat_remaining "$(fm_seat_config_dir "$name")"); then
      # A renewable seat lands here by construction: nothing can read its quota
      # until something renews it, so it has no headroom figure to compare and
      # is skipped for that reason rather than for its login state. Saying which
      # is what stops an operator reading a merely idle seat as a broken one.
      if [ "$state" = expired-renewable ]; then
        printf 'seat %s: skipped, signed in but its access token has lapsed, so its headroom cannot be read until a worker launched there renews it\n' "$name" >&2
      else
        printf 'seat %s: skipped, its quota could not be read, so its headroom is unknown and this makes no guess\n' "$name" >&2
      fi
      continue
    fi
    if jq -en --arg r "$remaining" --arg m "$minimum" \
      '($r | tonumber) > ($m | tonumber)' >/dev/null 2>&1; then
      printf '%s\n' "$name"
      return 0
    fi
    printf 'seat %s: skipped, %s%% left is not above the %s%% destination minimum\n' \
      "$name" "$remaining" "$minimum" >&2
  done
  return 1
}

# write_active <name>
# Replace config/claude-seat atomically, or remove it for the default seat. This
# is the whole of a switch: one file that only a fresh spawn ever reads.
write_active() {
  local name=$1 tmp
  mkdir -p "$CONFIG" || die "could not create $CONFIG"
  if [ "$name" = "$FM_SEAT_DEFAULT_NAME" ]; then
    rm -f "$CONFIG/claude-seat" || die "could not clear $CONFIG/claude-seat"
    return 0
  fi
  tmp="$CONFIG/.claude-seat.$$"
  printf '%s\n' "$name" > "$tmp" || die "could not write $tmp"
  mv -f "$tmp" "$CONFIG/claude-seat" || die "could not publish $CONFIG/claude-seat"
}

cmd_switch() {
  local name='' force=0 rotate=0 prior state dir resting
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
    name=$(next_seat) || die "no seat under the seats root qualifies as a destination (each skipped seat and its reason is printed above); add and log into a second seat, put an excluded seat back with 'fm-seat.sh auto-include <name>', or lower 'fm-seat.sh destination-min' (docs/claude-seats.md). The default profile is never a rotation target, so switch to it by name if that is what you want"
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
  state=$(login_state "$name")
  case "$state" in
    logged-in) ;;
    expired-renewable)
      # No --force needed. The session is signed in and the next worker launched
      # here renews it; refusing would send the operator to --force for a seat
      # that is simply idle, which is how most seats read after eight hours.
      printf "seat '%s' is signed in but its access token has lapsed; the next claude worker launched there renews it\\n" "$name"
      ;;
    not-logged-in)
      # A hard refusal: this profile has no credentials, so every worker sent
      # there would fail on its first message. --force cannot override a proven
      # negative, only an undecided probe.
      die "seat '$name' is not logged in; run 'fm-seat.sh add $name' for the owner's login steps (docs/claude-seats.md)"
      ;;
    *)
      [ "$force" -eq 1 ] || die "could not confirm seat '$name' is logged in (quota read gave no verdict); re-run with --force to switch anyway"
      ;;
  esac
  write_active "$name"
  printf 'switched: %s -> %s\n' "$prior" "$name"
  printf 'applies to NEW claude workers only; running workers keep their own seat\n'
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
  local name=$1 dir
  [ "$name" != "$FM_SEAT_DEFAULT_NAME" ] ||
    die "'$FM_SEAT_DEFAULT_NAME' names the ambient login, not a seat directory; choose another name"
  fm_seat_name_valid "$name" || die "invalid seat name: $name"
  dir=$(fm_seat_dir "$name") || die "seat '$name' does not resolve to a profile directory"
  mkdir -p "$dir" || die "could not create $dir"
  chmod 700 "$dir" 2>/dev/null || true
  printf 'seat profile directory: %s\n' "$dir"
  printf '\n'
  printf 'This created an empty profile directory and nothing else. No credential\n'
  printf 'was read, copied, or written, and the Keychain was not touched.\n'
  printf '\n'
  printf 'The account owner now logs this seat in, personally, in a terminal:\n'
  printf '\n'
  printf '  CLAUDE_CONFIG_DIR=%s claude\n' "$dir"
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
# The Claude profile the LEAD itself runs under, from the record beside the
# session lock. Empty output with a zero status is the ambient default profile,
# which is a real answer; a nonzero status means this home has not recorded one
# for its current lead, so nothing here may guess.
lead_profile() {
  fm_session_lock_runtime_field "$STATE" profile
}

# The operator surface for replacing the lead itself. Seat SELECTION stays here,
# where every other rotation decision lives, and the restart transaction stays
# in bin/fm-lead-restart.sh, which owns every refusal and what a failure leaves.
cmd_lead_restart() {
  local to='' profile anchor forwarded=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --to) [ "$#" -ge 2 ] || usage; to=$2; shift 2 ;;
      --check | --persisted) forwarded+=("$1"); shift ;;
      --launch-command | --grace) [ "$#" -ge 2 ] || usage; forwarded+=("$1" "$2"); shift 2 ;;
      *) usage ;;
    esac
  done
  if [ -z "$to" ]; then
    profile=$(lead_profile) ||
      die "the account firstmate itself runs on is not recorded for this session, so there is no seat to rotate away from; it is recorded at the next session start"
    anchor=$(fm_seat_name_of_profile "$profile")
    to=$(next_seat "$anchor") ||
      die "no seat under the seats root qualifies as a destination for firstmate itself (each skipped seat and its reason is printed above); add and log into another seat, put an excluded seat back with 'fm-seat.sh auto-include <name>', or lower 'fm-seat.sh destination-min' (docs/claude-seats.md)"
  fi
  FM_HOME="$FM_HOME" FM_ROOT_OVERRIDE="$FM_ROOT" FM_STATE_OVERRIDE="$STATE" \
    FM_CONFIG_OVERRIDE="$CONFIG" FM_DATA_OVERRIDE="$DATA" \
    "$SCRIPT_DIR/fm-lead-restart.sh" --to "$to" ${forwarded[@]+"${forwarded[@]}"}
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
  write_percent_setting claude-seat-threshold 'auto-switch threshold' "$v"
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
  write_percent_setting claude-seat-destination-min 'destination minimum' "$v"
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
      rm -f "$CONFIG/claude-seat-extra-usage" || die "could not clear the extra-usage policy"
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
  tmp="$CONFIG/.claude-seat-extra-usage.$$"
  printf '%s\n' "$v" > "$tmp" || die "could not write $tmp"
  mv -f "$tmp" "$CONFIG/claude-seat-extra-usage" || die "could not publish the extra-usage policy"
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
    rm -f "$CONFIG/claude-seat-auto-exclude" ||
      die "could not clear the automatic-rotation exclusions"
    return 0
  fi
  tmp="$CONFIG/.claude-seat-auto-exclude.$$"
  printf '%s\n' "$@" > "$tmp" || die "could not write $tmp"
  mv -f "$tmp" "$CONFIG/claude-seat-auto-exclude" ||
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
  local threshold name dir remaining
  threshold=$(fm_seat_threshold) || return 2
  name=$(fm_seat_active)
  if [ "$name" != "$FM_SEAT_DEFAULT_NAME" ]; then
    fm_seat_dir "$name" >/dev/null || return 2
  fi
  dir=$(fm_seat_config_dir "$name")
  # fm_seat_remaining owns which windows bound a worker with no specific model
  # and returns 1 for anything it could not read, so an ambiguous quota stays an
  # error here and never becomes a true that would switch accounts.
  remaining=$(fm_seat_remaining "$dir") || return 2
  jq -en --arg r "$remaining" --arg t "$threshold" \
    '($r | tonumber) <= ($t | tonumber)' >/dev/null 2>&1
}

# --- automatic mode ----------------------------------------------------------
# The de-dupe record. `fired=<seat>` names the seat a switch last landed on, so
# a destination that itself sits below the trigger is not switched away from
# on the very next poll; a switch rewrites it to the new seat, so that seat's
# OWN later crossing fires again with nothing to re-arm by hand.
# `blocked=<seat>` names the seat whose crossing has already been reported as
# having nowhere to go, or as a switch that failed. It silences only that
# report: every later poll still looks for a destination, so a candidate whose
# window resets is switched to at once. Both clear the moment the active seat
# reads back above the threshold.
# It also carries `extra=<seats>`, the set of seats last seen drawing paid extra
# usage, so that warning fires on ENTRY rather than on every poll for as long as
# the spend lasts, and `lead=<seat>`, the seat whose move instruction was last
# handed to FIRSTMATE ITSELF, so that instruction fires once per seat and not on
# every poll. A crossing that could not move records `lead=blocked:<seat>:<to>`
# instead, which silences only that same blocker: every poll still re-asks, so
# the instruction goes out as soon as the move becomes available.
# `resting_workers=<seat:since ...>` records resting entries already warned
# about, and drops entries once they return to rotation.
# `pipeline=<seat:since ...>` records resting entries with live pipeline agents
# already warned about, preserving the worker-warning record independently.
AUTO_RECORD="$STATE/.claude-seat-auto"

auto_record_get() {
  [ -f "$AUTO_RECORD" ] || return 1
  sed -n "s/^$1=//p" "$AUTO_RECORD" 2>/dev/null | tail -1
}

# auto_record_set <key> <value>
# Replace one field, preserving the others. The record is small and rewritten
# whole, so a partial write can never leave a half-updated record behind.
auto_record_set() {
  local key=$1 value=$2 fired blocked extra lead resting_workers pipeline tmp
  fired=$(auto_record_get fired) || fired=''
  blocked=$(auto_record_get blocked) || blocked=''
  extra=$(auto_record_get extra) || extra=''
  lead=$(auto_record_get lead) || lead=''
  resting_workers=$(auto_record_get resting_workers) || resting_workers=''
  pipeline=$(auto_record_get pipeline) || pipeline=''
  case "$key" in
    fired) fired=$value ;;
    blocked) blocked=$value ;;
    extra) extra=$value ;;
    lead) lead=$value ;;
    resting_workers) resting_workers=$value ;;
    pipeline) pipeline=$value ;;
  esac
  mkdir -p "$STATE" 2>/dev/null || return 1
  tmp=$(umask 077; mktemp "$STATE/.fm-seat-auto.XXXXXX" 2>/dev/null) || return 1
  { printf 'fired=%s\n' "$fired"; printf 'blocked=%s\n' "$blocked"; printf 'extra=%s\n' "$extra"; printf 'lead=%s\n' "$lead"; printf 'resting_workers=%s\n' "$resting_workers"; printf 'pipeline=%s\n' "$pipeline"; } > "$tmp" ||
    { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$AUTO_RECORD" || { rm -f -- "$tmp"; return 1; }
}

# warn_extra_usage_entry
# The loud half of the stop policy. Firstmate cannot stop a running worker from
# drawing paid extra usage, so the next best thing is to say so the moment it
# starts: every seat a live task is running on is checked, and one notification
# goes out through the home's single notification path
# (bin/fm-usage-warner.sh notify) naming the seats now spending. Reported on
# stdout too, because that line is what wakes firstmate.
warn_extra_usage_entry() {
  local meta seat label task_seats='' out spending='' summary previous
  [ -d "$STATE" ] || return 0
  # Only a CLAUDE task's recorded profile is a Claude seat. A task on any other
  # harness records no seat and reads no Claude profile, so including it would
  # check the ambient store on that task's behalf and report a seat it never
  # spends. An empty recorded seat on a claude task is the ambient default,
  # which that worker really does spend, so it stays in.
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    [ "$(sed -n 's/^harness=//p' "$meta" | tail -1)" = claude ] || continue
    seat=$(sed -n 's/^claude_seat=//p' "$meta" | tail -1)
    task_seats="${task_seats}${seat}
"
  done
  task_seats=$(printf '%s' "$task_seats" | sort -u)
  [ -n "$task_seats" ] || return 0
  previous=$(auto_record_get extra) || previous=''
  # A seat whose read gave no verdict, including one the pass ran out of time
  # for, keeps its previous state rather than reading as having left extra
  # usage, so a slow read can never re-arm the warning and wake twice.
  while IFS= read -r seat; do
    label=${seat:-default profile}
    if out=$(fm_seat_quota_json "$seat"); then
      fm_seat_in_extra_usage_from "$out" || continue
    else
      case " $previous " in *" $label "*) ;; *) continue ;; esac
    fi
    spending="${spending}${label} "
  done <<< "$task_seats"
  spending=${spending% }
  [ "$spending" != "$previous" ] || return 0
  auto_record_set extra "$spending"
  # Only entry speaks. A seat that leaves extra usage updates the record
  # silently, which is what re-arms the warning for its next entry.
  [ -n "$spending" ] || return 0
  summary="Claude seat in paid extra usage: $spending"
  printf 'claude-seat: %s (a worker already running keeps this seat; only the account admin setting stops it drawing extra usage)\n' "$summary"
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
          printf 'claude-seat: Codex offer for %s unavailable; dispatch configuration needs attention\n' "$id"
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
    printf 'claude-seat: %s is resting with running workers: %s; move each explicitly (Claude destination login is validated; default is the fallback when rotation has no candidate):\n%s\n' \
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
    printf 'claude-seat: %s\n' "$summary"
    "$SCRIPT_DIR/fm-usage-warner.sh" notify "$summary" >/dev/null 2>&1 || true
  done < <(printf '%s' "$live" | jq -r '[.[].seat] | unique[]')
  current=${current% }
  [ "$current" = "$previous" ] || auto_record_set pipeline "$current"
}

cmd_pipeline_move() {
  local active reason
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
  [ -n "$threshold" ] || [ -n "$floor" ] || return 0
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
  warn_pipeline_resting_entry
  if [ -n "$threshold" ]; then
    auto_trigger "$threshold" "$policy"
    auto_lead_trigger "$threshold"
  fi
  [ -z "$policy" ] || warn_extra_usage_entry
  warn_resting_workers
}

# auto_lead_trigger <threshold>
# The same crossing, asked about FIRSTMATE'S OWN seat. It is a separate question
# from auto_trigger's because the lead keeps the account it launched on while
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
# chosen by the ordinary rotation and then put through the whole restart
# preflight, so a crossing with no signed-in destination, no established launch
# command, session, or terminal, says exactly that instead of offering a
# restart that would refuse.
auto_lead_trigger() {  # <threshold>
  local threshold=$1 profile seat remaining target reported out
  profile=$(lead_profile) || return 0
  seat=$(fm_seat_name_of_profile "$profile")
  remaining=$(fm_seat_remaining "$profile") || return 0
  if ! jq -en --arg r "$remaining" --arg t "$threshold" \
    '($r | tonumber) <= ($t | tonumber)' >/dev/null 2>&1; then
    auto_record_set lead ''
    return 0
  fi
  reported=$(auto_record_get lead) || reported=''
  [ "$reported" != "$seat" ] || return 0
  if ! target=$(next_seat "$seat" 2>/dev/null); then
    [ "$reported" != "blocked:$seat:" ] || return 0
    auto_record_set lead "blocked:$seat:"
    printf 'claude-seat: firstmate itself is at %s%% left on %s and no seat qualifies as a destination, so it stays where it is\n' \
      "$remaining" "$seat"
    return 0
  fi
  if ! out=$(FM_HOME="$FM_HOME" FM_ROOT_OVERRIDE="$FM_ROOT" FM_STATE_OVERRIDE="$STATE" \
    FM_CONFIG_OVERRIDE="$CONFIG" FM_DATA_OVERRIDE="$DATA" \
    "$SCRIPT_DIR/fm-lead-restart.sh" --check --to "$target" 2>&1); then
    [ "$reported" != "blocked:$seat:$target" ] || return 0
    auto_record_set lead "blocked:$seat:$target"
    printf 'claude-seat: firstmate itself is at %s%% left on %s and cannot move to %s: %s\n' \
      "$remaining" "$seat" "$target" "$(printf '%s' "$out" | sed -n '/./{s/^error: //;s/[[:space:]]\{1,\}/ /g;p;q;}')"
    return 0
  fi
  auto_record_set lead "$seat"
  printf 'claude-seat: firstmate itself is at %s%% left on %s and moves to %s now, on this wake, without asking the captain (load the claude-seat-lead-restart skill). Replacing this session drops its conversation and keeps every durable record, so FIRST %s THEN run exactly: %s/bin/fm-seat.sh lead-restart --to %s --persisted\n' \
    "$remaining" "$seat" "$target" "$FM_PERSIST_OPEN_RECORDS_CONTRACT" "$FM_ROOT" "$target"
}

# auto_trigger <threshold> <policy>
# The trigger and switch half of one automatic pass.
auto_trigger() {
  local threshold=$1 policy=$2 active dir remaining target fired blocked out
  active=$(fm_seat_active)
  dir=$(fm_seat_config_dir "$active")
  if ! remaining=$(fm_seat_remaining "$dir"); then
    # Silent: an unreadable quota is a transient condition on a poll that runs
    # every cycle, and reporting it on each one would be noise, not a wake.
    # Nothing is switched on it either, which is the part that matters.
    return 0
  fi
  if ! jq -en --arg r "$remaining" --arg t "$threshold" \
    '($r | tonumber) <= ($t | tonumber)' >/dev/null 2>&1; then
    auto_record_set fired ''
    auto_record_set blocked ''
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
      printf 'claude-seat: switched from %s at %s%% left to %s; new workers launch there\n' \
        "$active" "$remaining" "$target"
      return 0
    fi
    auto_record_set fired "$fired"
    [ "$blocked" != "$active" ] || return 0
    auto_record_set blocked "$active"
    printf 'claude-seat: %s is at %s%% left and the switch to %s failed: %s\n' \
      "$active" "$remaining" "$target" "$(printf '%s' "$out" | tail -1)"
    return 0
  fi
  [ "$blocked" != "$active" ] || return 0
  auto_record_set blocked "$active"
  case "$policy" in
    stop)
      printf 'claude-seat: %s is at %s%% left and no seat has enough headroom to switch to; new Claude work will be held once this seat'\''s plan quota runs out, rather than started on paid extra usage. A worker already running is not stopped.\n' \
        "$active" "$remaining" ;;
    allow\ *)
      printf 'claude-seat: %s is at %s%% left and no seat has enough headroom to switch to; once this seat'\''s plan quota runs out, new Claude work continues on paid extra usage up to $%s, then will be held.\n' \
        "$active" "$remaining" "${policy#allow }" ;;
    *)
      printf 'claude-seat: %s is at %s%% left and no seat has enough headroom to switch to; no extra-usage policy is set, so nothing is held.\n' \
        "$active" "$remaining" ;;
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
  write_percent_setting claude-seat-floor 'quota floor' "$v"
  if [ "$v" = off ]; then
    # Clearing the floor wakes every seat it rested: a record nothing will ever
    # lift again must not outlive the floor here or in a secondmate home.
    [ -f "$CONFIG/claude-seat-resting" ] || return 0
    rm -f "$CONFIG/claude-seat-resting" || die "could not clear the resting record"
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
    configured=$(fm_seat_percent_file "$CONFIG/claude-seat-floor-readd") || configured=''
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
  write_percent_setting claude-seat-floor-readd 'quota floor re-add level' "$v"
}

cmd_floor_dwell() {
  local v=${1-} tmp
  if [ -z "$v" ]; then
    if v=$(fm_seat_seconds_file "$CONFIG/claude-seat-floor-dwell"); then
      printf '%s\n' "$v"
      return 0
    fi
    printf '%s (default)\n' "$FM_SEAT_FLOOR_DWELL_DEFAULT"
    return 0
  fi
  mkdir -p "$CONFIG" || die "could not create $CONFIG"
  if [ "$v" = off ]; then
    rm -f "$CONFIG/claude-seat-floor-dwell" || die "could not clear the quota floor rest time"
    printf 'quota floor rest time cleared; the default of %ss applies\n' "$FM_SEAT_FLOOR_DWELL_DEFAULT"
    return 0
  fi
  local LC_ALL=C
  [[ "$v" =~ ^[0-9]+$ ]] ||
    die "the quota floor rest time must be a whole number of seconds, 0 for no minimum rest, or 'off'"
  tmp="$CONFIG/.claude-seat-floor-dwell.$$"
  printf '%s\n' "$v" > "$tmp" || die "could not write $tmp"
  mv -f "$tmp" "$CONFIG/claude-seat-floor-dwell" || die "could not publish the quota floor rest time"
  printf 'quota floor rest time: %ss\n' "$v"
}

cmd_session_share() {
  local v=${1-} row
  if [ -z "$v" ]; then
    if v=$(fm_seat_percent_file "$CONFIG/claude-seat-session-share"); then
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
  write_percent_setting claude-seat-session-share 'assumed session share of a week' "$v"
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
        printf 'claude-seat: %s comes back into automatic rotation provisionally - it rested below the %s%% floor, its access token lapsed while it rested, and the reset it was waiting for has passed, so the next worker launched there is what reads its quota again\n' \
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
      printf 'claude-seat: %s is resting - %s%% left is at or below the %s%% floor, so automatic switches skip it until it recovers (expected back %s; fm-seat.sh switch %s still reaches it)\n' \
        "$name" "$remaining" "$floor" "$expected" "$name"
      continue
    fi
    # A seat back provisionally faces the same wake test on its first readable
    # reading: passing clears its entry, failing rests it again on real figures.
    if floor_may_wake "$entry" "$session" "$week" "$readd" "$share" "$dwell" "$now"; then
      record=$(printf '%s\n' "$record" | jq -c --arg n "$name" 'del(.seats[$n])')
      changed=1
      printf 'claude-seat: %s comes back into automatic rotation - %s%% left on its session and %s%% on its week, both above the %s%% re-add level, with room for a whole session\n' \
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
    printf 'claude-seat: %s is resting again - read again after coming back provisionally, it has %s%% left on its session and %s%% on its week, short of the %s%% re-add level with room for a whole session (expected back %s)\n' \
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
FM_CHECK_SHIM_ID=claude-seat
FM_CHECK_SHIM_LABEL=fm-seat

cmd_arm() {
  local threshold floor active name candidates=0 all_resting=1
  # Clear any older one-shot registration first, so a home upgrading from it
  # ends with one watch rather than two firing on the same crossing.
  if "$SCRIPT_DIR/fm-procevent-when.sh" source-id claude-seat >/dev/null 2>&1; then
    "$SCRIPT_DIR/fm-procevent-when.sh" retire claude-seat >/dev/null 2>&1 || true
  fi
  threshold=$(fm_seat_threshold) || threshold=''
  floor=$(fm_seat_floor) || floor=''
  [ -n "$threshold" ] || [ -n "$floor" ] ||
    die "no auto-switch threshold or quota floor configured; set one with 'fm-seat.sh threshold <percent-left>' or 'fm-seat.sh floor <percent-left>' first"
  # stdout only is discarded: each candidate's own skip reason belongs on
  # stderr beside the refusal, the same way every other rotation refusal reads,
  # so arming after an exclusion says which seats were withheld.
  if ! next_seat >/dev/null; then
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
  fm_check_shim_arm "$FM_HOME" "$SCRIPT_DIR/fm-seat.sh" auto || exit 1
  if [ -n "$threshold" ]; then
    printf 'armed: automatic switch at %s%% left on the active seat\n' "$threshold"
    printf 'keeps watching after each switch; one crossing fires at most once per seat\n'
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
  if "$SCRIPT_DIR/fm-procevent-when.sh" source-id claude-seat >/dev/null 2>&1; then
    "$SCRIPT_DIR/fm-procevent-when.sh" retire claude-seat >/dev/null 2>&1 || true
  fi
  printf 'retired: the automatic Claude seat watch\n'
}

case "${1-}" in
  status)            shift; cmd_status "$@" ;;
  pipeline-install)  shift; "$SCRIPT_DIR/fm-seat-pipeline.sh" install "$@" ;;
  pipeline-check)    shift; "$SCRIPT_DIR/fm-seat-pipeline.sh" check "$@" ;;
  pipeline-move)     shift; [ $# -eq 0 ] || usage; cmd_pipeline_move ;;
  list)              shift; cmd_list "$@" ;;
  switch)            shift; cmd_switch "$@" ;;
  probe)             shift; cmd_probe "${1-}" ;;
  add)               shift; [ -n "${1-}" ] || usage; cmd_add "$1" ;;
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
  lead-restart)      shift; cmd_lead_restart "$@" ;;
  threshold-reached) shift; cmd_threshold_reached ;;
  auto)              shift; cmd_auto ;;
  arm)               shift; cmd_arm "$@" ;;
  retire)            shift; cmd_retire "$@" ;;
  ''|-h|--help|help) usage ;;
  *) die "unknown command: $1" ;;
esac
