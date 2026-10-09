# shellcheck shell=bash
# Shared Claude seat resolution, used by the seat command, spawn and dispatch
# resolver.
# Usage: . bin/fm-seat-lib.sh   (after FM_ROOT, FM_HOME, and CONFIG are set, and
#        after bin/fm-timeout-lib.sh, which bounds every quota read, and
#        bin/fm-quota-axi-lib.sh, which owns the quota row join)
#
# A "seat" is one Claude account, reached through a Claude Code profile
# directory named by CLAUDE_CONFIG_DIR. Claude Code derives that profile's
# Keychain service name from the directory path itself, so two seats never share
# a credential store and a worker pointed at a seat that was never logged in
# fails with "Not logged in" rather than silently spending the default account.
# docs/claude-seats.md owns the operator procedure and the login steps; this
# library owns only the resolution rules the spawn path and the seat command
# must agree on.
#
# The contract that makes a switch safe is that it changes only what the NEXT
# claude worker gets. A live worker keeps the profile it launched with, because
# that profile is recorded in its own task record at spawn time and every later
# launch for that task reads the RECORD unless relaunch explicitly names
# --seat. Separate profiles can hold separate history, so changing the recorded
# seat is a deliberate relaunch input rather than an automatic side effect.
#
# Eleven settings, all optional, all gitignored, and all inherited by LOCAL
# secondmate homes but never by a remote route
# (FM_MACHINE_LOCAL_INHERITABLE_CONFIG in bin/fm-config-inherit-lib.sh):
#   config/claude-seat            active seat NAME for new claude workers
#   config/claude-seats-root      where seat profile directories live
#   config/claude-seat-threshold  percent LEFT on the ACTIVE seat that trips an
#                                 automatic switch
#   config/claude-seat-destination-min
#                                 percent LEFT a seat must exceed to be a switch
#                                 DESTINATION
#   config/claude-seat-extra-usage
#                                 what to do when no seat has headroom: `stop`
#                                 or `allow <usd>`
#   config/claude-seat-auto-exclude
#                                 seat names, one per line, held out of
#                                 AUTOMATIC rotation while `switch <name>` still
#                                 reaches them
#   config/claude-seat-floor      percent LEFT at or below which a seat is
#                                 RESTED out of automatic rotation
#   config/claude-seat-floor-readd
#                                 percent LEFT both windows must regain
#   config/claude-seat-floor-dwell
#                                 seconds a seat must rest before it may wake
#   config/claude-seat-session-share
#                                 assumed percent of a WEEK one session costs
#   config/claude-seat-resting    which seats the floor is resting, written only
#                                 by the watch
# Every percentage counts percent LEFT, the same direction the quota viewer
# reports, so no setting has to be inverted against another, except
# claude-seat-session-share, which is a share of a week and says so where it is
# defined. All of them are off when absent; see the automatic-mode and
# quota-floor sections at the foot of this file.
# A local home declines them all for itself with config/claude-seat-local, so it
# can spend a separate account; bin/fm-config-inherit-lib.sh owns that decline.
# docs/configuration.md "Claude seats" owns their schema.

# The reserved seat name for "the default login", which is the ambient profile
# Claude Code uses with no CLAUDE_CONFIG_DIR set. It is never a directory under
# the seats root, and switching to it clears config/claude-seat.
FM_SEAT_DEFAULT_NAME=default

# The fm_seat_logged_in verdict for a seat whose session is intact but whose
# access token has lapsed and can still be renewed. It is a fourth exit status
# rather than a widened 0 so that every caller has to say what it does with a
# seat that is usable for a launch but has no readable quota.
FM_SEAT_LOGIN_EXPIRED_RENEWABLE=3

# fm_seat_root
# Absolute directory holding one subdirectory per named seat. Seats live outside
# the firstmate home on purpose: the account owner logs into a seat once and
# every home on the machine, primary and secondmate alike, reaches the same
# profile. A home that wants its own set overrides the root.
fm_seat_root() {
  local root=
  if [ -f "$CONFIG/claude-seats-root" ]; then
    root=$(sed -n '1p' "$CONFIG/claude-seats-root" 2>/dev/null | tr -d '[:space:]')
  fi
  [ -n "$root" ] || root="${HOME:-}/.claude-seats"
  printf '%s\n' "$root"
}

# fm_seat_name_valid <name>
# Seat names become a single path component under the seats root, so they are
# restricted to a conservative set rather than sanitized after the fact.
fm_seat_name_valid() {
  local name=${1-}
  local LC_ALL=C
  [ -n "$name" ] || return 1
  [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || return 1
  case "$name" in
    . | .. | *..*) return 1 ;;
  esac
  return 0
}

# fm_seat_dir <name>
# Absolute profile directory for a seat name. The default seat has no directory
# of its own, so it prints nothing and returns 1: callers treat that as "no
# CLAUDE_CONFIG_DIR", which is exactly the ambient default.
fm_seat_dir() {
  local name=${1-} root
  [ "$name" != "$FM_SEAT_DEFAULT_NAME" ] || return 1
  fm_seat_name_valid "$name" || return 1
  root=$(fm_seat_root)
  case "$root" in
    /*) ;;
    *) return 1 ;;
  esac
  printf '%s/%s\n' "$root" "$name"
}

# fm_seat_active [config-dir]
# The configured active seat NAME, or the default seat name when unset. An
# unreadable or malformed value is reported as the default rather than guessed
# at, because the default is the one seat that always exists.
#
# The optional argument reads ANOTHER home's setting through this same
# resolution, which is how the primary reports the seat a local secondmate home
# that declined inherited seats is actually on. It defaults to this home's own
# config dir, so every existing caller is unchanged.
fm_seat_active() {
  local config_dir=${1:-$CONFIG} name=
  if [ -f "$config_dir/claude-seat" ]; then
    name=$(sed -n '1p' "$config_dir/claude-seat" 2>/dev/null | tr -d '[:space:]')
  fi
  if [ -z "$name" ] || ! fm_seat_name_valid "$name"; then
    printf '%s\n' "$FM_SEAT_DEFAULT_NAME"
    return 0
  fi
  printf '%s\n' "$name"
}

# fm_seat_config_dir <name>
# The CLAUDE_CONFIG_DIR a claude worker launched on seat <name> gets, or empty
# for the ambient default. Resolution order, most specific first:
#   1. the named seat's profile directory, when <name> is not the default seat
#   2. firstmate's OWN ambient CLAUDE_CONFIG_DIR, which predates seats and is
#      how a home running under a non-default profile already hands that same
#      store to its workers. A lead moved by bin/fm-lead-restart.sh runs on
#      its destination seat, so that restart carries the ambient it started
#      from in FM_AMBIENT_CLAUDE_CONFIG_DIR, which wins when set
#   3. empty - the single-store default, which adds no launch prefix at all
# The login probe and the threshold read resolve through this too, so they
# always inspect the same profile a worker on that seat would spend.
fm_seat_config_dir() {
  local name=${1-} dir
  if [ "$name" != "$FM_SEAT_DEFAULT_NAME" ] && dir=$(fm_seat_dir "$name"); then
    printf '%s\n' "$dir"
    return 0
  fi
  printf '%s\n' "${FM_AMBIENT_CLAUDE_CONFIG_DIR-${CLAUDE_CONFIG_DIR:-}}"
}

# fm_seat_relaunch_destination <name> -> profile directory (ambient for default)
# Validate an explicit relaunch destination before the running worker stops.
# Like switch without --force, a renewable login is usable, a proven signed-out
# seat refuses, and an unreadable login refuses rather than guessing.
fm_seat_relaunch_destination() {
  local name=$1 dir rc
  if [ "$name" != "$FM_SEAT_DEFAULT_NAME" ]; then
    fm_seat_name_valid "$name" || { echo "error: invalid seat name: $name" >&2; return 1; }
    dir=$(fm_seat_dir "$name") || return 1
    [ -d "$dir" ] || { echo "error: seat '$name' has no profile directory at $dir" >&2; return 1; }
  fi
  dir=$(fm_seat_config_dir "$name")
  if fm_seat_logged_in "$dir"; then
    rc=0
  else
    rc=$?
  fi
  case "$rc" in
    0|"$FM_SEAT_LOGIN_EXPIRED_RENEWABLE") ;;
    1) echo "error: seat '$name' is not logged in; sign in before relaunching" >&2; return 1 ;;
    *) echo "error: could not confirm seat '$name' is logged in; relaunch refused" >&2; return 1 ;;
  esac
  if fm_seat_resting "$name"; then
    echo "warning: seat '$name' is resting below the quota floor; relaunching there explicitly" >&2
  fi
  printf '%s\n' "$dir"
}

# fm_seat_name_of_profile <profile-dir>
# The inverse of fm_seat_config_dir: the seat NAME a profile directory belongs
# to. The empty profile is the ambient default seat, which is a real answer; a
# profile outside the seats root has no seat name and is reported by its own
# path, so a home running on an unmanaged profile still reads honestly rather
# than being labelled with a seat it is not on.
fm_seat_name_of_profile() {
  local profile=${1-} name
  [ -n "$profile" ] || { printf '%s\n' "$FM_SEAT_DEFAULT_NAME"; return 0; }
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    [ "$(fm_seat_dir "$name")" = "$profile" ] || continue
    printf '%s\n' "$name"
    return 0
  done < <(fm_seat_list)
  printf '%s\n' "$profile"
}

# fm_seat_spawn_config_dir
# The CLAUDE_CONFIG_DIR a NEW claude worker should launch with: the active
# seat's, resolved by fm_seat_config_dir. A fresh spawn or resolver uses this;
# a relaunch reads the task's recorded value.
fm_seat_spawn_config_dir() {
  fm_seat_config_dir "$(fm_seat_active)"
}

# fm_seat_list
# Every seat name that has a profile directory under the root, one per line, in
# a stable order. The set is read from the filesystem on every call, so nothing
# assumes which seats exist.
#
# The default seat is not listed here: it has no directory, and callers that
# present it add it themselves. A directory literally NAMED "default" is skipped
# for the same reason - that name is reserved for the ambient login, so such a
# directory can never be selected, and listing it would show a seat that every
# switch then refuses.
fm_seat_list() {
  local root entry name
  root=$(fm_seat_root)
  [ -d "$root" ] || return 0
  for entry in "$root"/*; do
    [ -d "$entry" ] || continue
    name=${entry##*/}
    [ "$name" != "$FM_SEAT_DEFAULT_NAME" ] || continue
    fm_seat_name_valid "$name" || continue
    printf '%s\n' "$name"
  done
}

# fm_seat_logged_in [config-dir]
# Exit 0 when the profile holds usable Claude credentials, 3 when its session is
# signed in but its access token has lapsed and can still be renewed, 1 when it
# plainly holds no login, and 2 when the probe could not reach a verdict.
#
# The probe is `quota-axi --provider claude`, run with the profile's own
# CLAUDE_CONFIG_DIR, and a logged-in profile is the one that reports an oauth
# source. It deliberately does NOT use --profile-only: that flag reads only a
# credential FILE and never the Keychain, and on macOS a logged-in profile keeps
# its credentials in the Keychain, so --profile-only reports "credentials
# missing" for a perfectly good seat. --no-credential-refresh keeps the read
# from delegating a token renewal to the vendor CLI.
#
# FM_SEAT_LOGIN_EXPIRED_RENEWABLE (3) is a USABLE seat, not a degraded one. A
# Claude access token lives eight hours from its last refresh, so a seat that
# nothing has launched on since yesterday reads this way for most of the window
# it spends as a rotation candidate. The session behind it is intact: launching
# a claude worker there makes Claude Code perform the refresh exchange against
# its own stored refresh token and rewrite the store, which is exactly how such
# a seat recovers. Firstmate must never do that renewal itself - the refresh
# token is single-use and a second refresher racing the session that owns it is
# how a holder ends up presenting a spent token - so every read here stays
# non-renewing and the launch remains the only thing that renews.
fm_seat_logged_in() {
  local dir=${1-} out
  command -v quota-axi >/dev/null 2>&1 || return 2
  command -v jq >/dev/null 2>&1 || return 2
  # quota-axi exits non-zero when the provider is unavailable but still prints
  # the report that SAYS so, and that report is exactly the "not logged in"
  # verdict this probe needs. So the exit status is deliberately ignored and the
  # decision comes from the document; only unreadable or invalid output is
  # undecided.
  out=$(fm_seat_quota_read "$dir") || return 2
  [ -n "$out" ] || return 2
  printf '%s\n' "$out" | jq -e . >/dev/null 2>&1 || return 2
  printf '%s\n' "$out" | jq -e '
    (.providers // []) | map(select(.provider == "claude")) | .[0] // empty
    | .source == "oauth"
  ' >/dev/null 2>&1 && return 0
  # Soft expiry, read from the one field quota-axi publishes for it. Its own
  # type declares the contract this relies on: "Machine-readable local auth
  # usability, distinct from quota freshness. Callers must not infer logout from
  # provider status alone when this is set." The surrounding error text is NOT
  # that signal - the same state was measured reporting both "Claude access
  # token expired" and "Claude credential expired", depending on whether the
  # quota endpoint rate limited the read first - so this matches the field and
  # never the message.
  printf '%s\n' "$out" | jq -e '
    (.providers // []) | map(select(.provider == "claude")) | .[0] // empty
    | .state.authStatus == "expired_refreshable"
  ' >/dev/null 2>&1 && return "$FM_SEAT_LOGIN_EXPIRED_RENEWABLE"
  # Tell a clean "not logged in" apart from a probe that could not decide, so a
  # switch refuses on the first and reports uncertainty on the second. Only a
  # report where every credential source was actually consulted and came back
  # empty proves the profile holds no login.
  #
  # `keychain_unreachable` is NOT such a report: it says the store could not be
  # read, not that it is empty. Measured read-only against the installed
  # quota-axi on macOS, a profile that was never logged into and a profile that
  # IS signed in but whose one-time Keychain approval has not been granted yet
  # produce the same shape - every source skipped, the keychain unreachable. So
  # that shape cannot distinguish them and must stay undecided; treating it as
  # proof of absence would refuse a correctly signed-in seat with no way
  # through, exactly the state an owner is in moments after logging a seat in.
  # A signed-in seat whose quota endpoint is rate limited is also "unavailable",
  # and stays undecided for the same reason: its keychain attempt got past the
  # lookup and failed afterwards.
  #
  # An undecided read (2) is what `switch --force` may cross, and crossing it is
  # safe: a forced switch to a genuinely empty seat stops the next worker on its
  # first message with "Not logged in" rather than spending another account.
  # A proven-empty read (1) is never crossable. It is reached only when every
  # credential source was inspected and found missing or invalid: a file-backed
  # store with no profile, or a Keychain item Claude Code emptied in place after
  # Anthropic rejected its refresh token, which reads as `credentials_invalid`.
  # A 401 from the usage endpoint is deliberately NOT accepted as that proof,
  # even though quota-axi reports it as `auth_required`: quota-axi raises that
  # status for any 401, including one against a locally valid credential whose
  # refresh token a launch would still try. Such a read has a `failed` attempt,
  # because a credential was presented and rejected, so it stays undecided.
  printf '%s\n' "$out" | jq -e '
    (.providers // []) | map(select(.provider == "claude")) | .[0] // empty
    | .source == "unavailable"
      and ((.attempts // []) | length > 0
        and all(.status == "skipped"
          and (.error == "credentials_missing" or .error == "credentials_invalid")))
  ' >/dev/null 2>&1 && return 1
  return 2
}

# fm_seat_account [config-dir]
# The account email a profile is logged in as, when the probe can read one.
# Identity only; no token or credential content is ever read or printed.
fm_seat_account() {
  local dir=${1-} out
  command -v quota-axi >/dev/null 2>&1 || return 1
  command -v jq >/dev/null 2>&1 || return 1
  out=$(fm_seat_quota_read "$dir") || return 1
  [ -n "$out" ] || return 1
  printf '%s\n' "$out" | jq -er '
    (.providers // []) | map(select(.provider == "claude")) | .[0] // empty
    | .account.email // empty
  ' 2>/dev/null
}

# fm_seat_threshold
# The percent LEFT on the ACTIVE seat that trips an automatic switch, or empty
# when unset. Empty means no automatic switching at all: there is deliberately
# no default that would move accounts on a home that never asked for it.
# fm_seat_percent_file, in the automatic-mode section below, owns the parse.
fm_seat_threshold() {
  fm_seat_percent_file "$CONFIG/claude-seat-threshold"
}

# --- automatic mode -----------------------------------------------------------
# Readers and predicates for the three settings the file header lists: the
# TRIGGER on the active seat, the DESTINATION HEADROOM a candidate must exceed,
# and the EXTRA-USAGE POLICY for when neither can be satisfied.

# fm_seat_percent_file <path>
# The shared reader for a one-line percent setting: prints a percentage strictly
# above 0 and at most 100, or returns 1 for absent, empty, or malformed. A
# malformed value is never rounded into a usable number, because a setting that
# silently became something else is worse than one that reads as unset.
fm_seat_percent_file() {
  local path=${1-} v=
  [ -f "$path" ] || return 1
  v=$(sed -n '1p' "$path" 2>/dev/null | tr -d '[:space:]')
  [ -n "$v" ] || return 1
  local LC_ALL=C
  [[ "$v" =~ ^[0-9]+(\.[0-9]+)?$ ]] || return 1
  jq -en --arg v "$v" '($v | tonumber) > 0 and ($v | tonumber) <= 100' >/dev/null 2>&1 || return 1
  printf '%s\n' "$v"
}

# fm_seat_destination_min
# The minimum percent LEFT a seat must have to be a switch DESTINATION, or
# empty when unset. Unset means the rotation gate is login-only, exactly as it
# was before this setting existed: any logged-in seat qualifies and no
# candidate's quota is read at all.
fm_seat_destination_min() {
  fm_seat_percent_file "$CONFIG/claude-seat-destination-min"
}

# fm_seat_extra_usage_policy
# The policy for when no seat has headroom, as one line: `stop`, or
# `allow <usd>`. Returns 1 when unset, which means no dispatch hold of any kind
# - the fleet keeps launching Claude workers exactly as it does today.
#
# `stop` holds NEW Claude dispatch rather than starting workers that would run
# on paid extra usage. `allow <usd>` keeps dispatching while the seat's recorded
# extra-usage spend is below that dollar figure and holds once it is not.
fm_seat_extra_usage_policy() {
  local path="$CONFIG/claude-seat-extra-usage" v='' amount=''
  [ -f "$path" ] || return 1
  v=$(sed -n '1p' "$path" 2>/dev/null)
  v=${v#"${v%%[![:space:]]*}"}
  v=${v%"${v##*[![:space:]]}"}
  [ -n "$v" ] || return 1
  local LC_ALL=C
  case "$v" in
    stop)
      printf 'stop\n'
      return 0
      ;;
    allow\ *)
      amount=${v#allow }
      amount=${amount#"${amount%%[![:space:]]*}"}
      [[ "$amount" =~ ^[0-9]+(\.[0-9]+)?$ ]] || return 1
      printf 'allow %s\n' "$amount"
      return 0
      ;;
  esac
  return 1
}

# fm_seat_auto_exclude_list
# Every seat name held out of AUTOMATIC rotation, one per line, in the order the
# file records them. Absent, empty, or whitespace-only means nothing is
# excluded, which is the fleet-wide default.
#
# Lines are compared as plain strings and never validated here. A line that
# names no seat simply matches nothing, so a hand-edited file can hold a stale
# or misspelled name without either excluding a seat it did not name or
# suppressing the exclusions beside it.
fm_seat_auto_exclude_list() {
  local path="$CONFIG/claude-seat-auto-exclude" line
  [ -f "$path" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line#"${line%%[![:space:]]*}"}
    line=${line%"${line##*[![:space:]]}"}
    [ -n "$line" ] || continue
    printf '%s\n' "$line"
  done < "$path"
}

# fm_seat_auto_excluded <name>
# True when <name> is held out of automatic rotation. This is the one owner of
# that question, so the candidate filter, the listing, and the status report can
# never disagree about which seats an automatic switch may land on.
#
# It is deliberately NOT consulted by `switch <name>`: the exclusion withholds a
# seat from the automatic paths only, and naming it explicitly stays a valid
# manual choice (docs/claude-seats.md).
fm_seat_auto_excluded() {
  local name=${1-} excluded
  [ -n "$name" ] || return 1
  while IFS= read -r excluded; do
    [ "$excluded" = "$name" ] && return 0
  done < <(fm_seat_auto_exclude_list)
  return 1
}

# fm_seat_read_bound
# Seconds one quota read may take: 10, or less when FM_SEAT_READ_DEADLINE (an
# epoch second) is set and closer than that. Returns 1 when the deadline leaves
# no whole second, so the read is not made at all. bin/fm-seat.sh auto sets the
# deadline from the watcher's per-check budget, so every read one pass makes,
# including those of a switch it runs as a child, fits inside that budget.
fm_seat_read_bound() {
  local bound=10 deadline=${FM_SEAT_READ_DEADLINE:-} left
  case "$deadline" in
    '') ;;
    *[!0-9]*) return 1 ;;
    *)
      left=$((deadline - $(date +%s)))
      [ "$left" -ge "$bound" ] || bound=$left
      ;;
  esac
  [ "$bound" -ge 1 ] || return 1
  printf '%s\n' "$bound"
}

# fm_seat_memo_key <config-dir>
# A filesystem-safe name for one profile's memo entry, so two seats never share
# one and no profile path can escape the memo directory. The AMBIENT profile is
# the empty string and gets a name of its own rather than an empty one, which
# would name the memo directory itself; every other key is prefixed, so no
# profile path can ever sanitize into that name.
fm_seat_memo_key() {
  local dir=${1-}
  [ -n "$dir" ] || { printf 'ambient'; return 0; }
  printf 'profile-%s' "$(printf '%s' "$dir" | tr -c 'A-Za-z0-9_-' '_')"
}

# fm_seat_quota_read <config-dir>
# The one bounded quota-axi call every seat probe and quota read makes, printed
# raw. Returns 1 when quota-axi is missing, no time is left, or the bound was
# hit, which every caller treats as no verdict.
#
# The exit status of quota-axi is otherwise deliberately ignored: an unavailable
# provider still prints the report that says so, and that report is what
# decides.
#
# THE PER-PASS MEMO. With FM_SEAT_READ_MEMO_DIR set, the first read of a profile
# is stored there and every later read of the SAME profile in that pass reuses
# it, including the reads a `switch` run as a child makes, because the variable
# is exported. One automatic pass therefore makes exactly one quota call per
# seat however many questions it asks about it. A read that gave no verdict is
# memoed as such, so a seat whose store is slow or unreachable cannot spend the
# pass's whole budget twice. Only a pass sets the memo; no long-lived caller
# does, so nothing outside one pass ever reads a figure it did not take itself.
fm_seat_quota_read() {
  local dir=${1-} bound out memo=''
  if [ -n "${FM_SEAT_READ_MEMO_DIR:-}" ] && [ -d "${FM_SEAT_READ_MEMO_DIR:-}" ]; then
    memo="$FM_SEAT_READ_MEMO_DIR/$(fm_seat_memo_key "$dir")"
    [ ! -f "$memo.fail" ] || return 1
    if [ -f "$memo" ]; then
      cat "$memo"
      return 0
    fi
  fi
  command -v quota-axi >/dev/null 2>&1 || return 1
  bound=$(fm_seat_read_bound) || return 1
  out=$(fm_run_timed "$bound" env CLAUDE_CONFIG_DIR="$dir" \
    quota-axi --provider claude --no-credential-refresh --full --json 2>/dev/null </dev/null)
  if fm_timed_out "$?"; then
    [ -z "$memo" ] || : > "$memo.fail" 2>/dev/null || true
    return 1
  fi
  [ -z "$memo" ] || printf '%s\n' "$out" > "$memo" 2>/dev/null || true
  printf '%s\n' "$out"
}

# fm_seat_quota_json <config-dir>
# One quota-axi read against a seat's own profile, printed raw. Returns 1 when
# the read could not be made, ran out of time, or did not parse, which every
# caller must treat as "no verdict" rather than as any particular number.
fm_seat_quota_json() {
  local dir=${1-} out
  command -v jq >/dev/null 2>&1 || return 1
  out=$(fm_seat_quota_read "$dir") || return 1
  [ -n "$out" ] || return 1
  printf '%s\n' "$out" | jq -e . >/dev/null 2>&1 || return 1
  printf '%s\n' "$out"
}

# fm_seat_remaining_from <quota-json>
# The tightest percent LEFT across a seat's ACCOUNT-level scopes
# (all_models/all_products), read through the same quota_effective the dispatch
# chooser uses, so there is one owner of which windows bound a worker with no
# specific model. A model- or product-only window does not count: it constrains
# only workers on that model.
#
# An exhausted runway prints 0, because a seat with no runway left has no
# headroom whatever its percentage says. Anything else unreadable returns 1, so
# an ambiguous quota can never be mistaken for a number.
fm_seat_remaining_from() {
  local out=${1-} remaining
  [ -n "$out" ] || return 1
  remaining=$(printf '%s\n' "$out" | jq -r "$FM_QUOTA_ROW_JQ"'
    quota_effective(quota_row(.; "claude"; ""); "default")
    | if (.runway.status // "") == "exhausted_now" then "0"
      elif .status == "known" and (.effectivePercentRemaining | type) == "number"
      then (.effectivePercentRemaining | tostring)
      else "error"
      end
  ' 2>/dev/null) || return 1
  [ -n "$remaining" ] && [ "$remaining" != error ] || return 1
  printf '%s\n' "$remaining"
}

# fm_seat_remaining <config-dir>
# Percent LEFT for one seat's profile, or 1 when the quota gave no verdict.
fm_seat_remaining() {
  local out
  out=$(fm_seat_quota_json "${1-}") || return 1
  fm_seat_remaining_from "$out"
}

# fm_seat_extra_spent_from <quota-json>
# Dollars already spent on paid extra usage for this seat, read from the
# `extra_usage` window quota-axi reports (kind `credits`, carrying spentUsd and
# limitUsd). Returns 1 when the account returns no such window or its spend is
# not a number; a seat with no extra-usage window has no observable spend, which
# is not the same as a spend of zero and must not be reported as one.
fm_seat_extra_spent_from() {
  local out=${1-} spent
  [ -n "$out" ] || return 1
  spent=$(printf '%s\n' "$out" | jq -r "$FM_QUOTA_ROW_JQ"'
    quota_row(.; "claude"; "") as $row
    | if ($row // null) == null then "error" else
        (($row.windows // []) | map(select(.id == "extra_usage")) | first) as $w
        | if ($w // null) == null or ($w.spentUsd | type) != "number"
          then "error" else ($w.spentUsd | tostring) end
      end
  ' 2>/dev/null) || return 1
  [ -n "$spent" ] && [ "$spent" != error ] || return 1
  printf '%s\n' "$spent"
}

# fm_seat_extra_limit_from <quota-json>
# The account's own extra-usage ceiling in dollars, for reporting only. The
# firstmate-side cap is a separate, smaller figure this fleet enforces itself.
fm_seat_extra_limit_from() {
  local out=${1-} limit
  [ -n "$out" ] || return 1
  limit=$(printf '%s\n' "$out" | jq -r "$FM_QUOTA_ROW_JQ"'
    quota_row(.; "claude"; "") as $row
    | if ($row // null) == null then "error" else
        (($row.windows // []) | map(select(.id == "extra_usage")) | first) as $w
        | if ($w // null) == null or ($w.limitUsd | type) != "number"
          then "error" else ($w.limitUsd | tostring) end
      end
  ' 2>/dev/null) || return 1
  [ -n "$limit" ] && [ "$limit" != error ] || return 1
  printf '%s\n' "$limit"
}

# fm_seat_in_extra_usage_from <quota-json>
# Exit 0 when this seat is drawing on paid extra usage right now: its plan quota
# reads as gone AND the account reports extra-usage spend above zero. Both halves
# are required, because an account can carry historical extra-usage spend from an
# earlier window while its current plan quota is perfectly healthy.
fm_seat_in_extra_usage_from() {
  local out=${1-} remaining spent
  remaining=$(fm_seat_remaining_from "$out") || return 1
  jq -en --arg r "$remaining" '($r | tonumber) <= 0' >/dev/null 2>&1 || return 1
  spent=$(fm_seat_extra_spent_from "$out") || return 1
  jq -en --arg s "$spent" '($s | tonumber) > 0' >/dev/null 2>&1
}

# --- quota floor --------------------------------------------------------------
# The floor takes a seat OUT of automatic rotation when one of its account-level
# windows reads at or below it - the seat is "resting" - and brings it back only
# when a fresh reading proves it recovered. It is a separate record from
# config/claude-seat-auto-exclude on purpose: that file holds the operator's
# standing choice and is never lifted automatically, while this one is written
# only by the watch. docs/claude-seats.md owns the operator procedure and
# docs/configuration.md "Claude seats" owns the five files.
#
#   config/claude-seat-floor        percent LEFT at or below which a seat rests
#   config/claude-seat-floor-readd  percent LEFT both windows must regain
#   config/claude-seat-floor-dwell  seconds a seat must rest before it may wake
#   config/claude-seat-session-share  assumed percent of a WEEK one whole
#                                   session window costs, until it is measured
#   config/claude-seat-resting      the record of which seats are resting

# The assumed share of a week one whole session costs, used until the share has
# been measured on that account twice. Measured co-movement on the live plan
# bounded one session at 15-19% of a week, so 20 is the conservative side of it.
FM_SEAT_SESSION_SHARE_DEFAULT=20
# Seconds a seat must have been resting before any reading may wake it. Two
# watch sweeps at the default FM_CHECK_INTERVAL, so one odd reading cannot
# round-trip a seat inside a single cycle.
FM_SEAT_FLOOR_DWELL_DEFAULT=600
# The allowance applied wherever a LOCAL epoch is compared against a resetsAt
# the service stamped. The service's own clock is not exposed, so skew cannot be
# measured and a fixed margin is the honest substitute for measuring it.
# shellcheck disable=SC2034 # read by bin/fm-seat.sh's floor pass, not here.
FM_SEAT_RESET_MARGIN=300
# The two account-level windows the floor reads, in the id vocabulary quota-axi
# itself publishes. Model- and product-scoped windows and extra_usage are never
# floor inputs: they constrain a different thing from the plan quota a rotation
# destination needs.
FM_SEAT_SESSION_WINDOW=five_hour
FM_SEAT_WEEK_WINDOW=seven_day

# fm_seat_seconds_file <path>
# The reader for a one-line whole-second setting: prints the number, or returns
# 1 for absent, empty, or malformed, so a setting that silently became something
# else reads as unset rather than as some other duration. Zero is a real value -
# for the rest time it means no minimum rest - and is deliberately not folded
# into "unset", which would silently restore the default instead.
fm_seat_seconds_file() {
  local path=${1-} v=
  [ -f "$path" ] || return 1
  v=$(sed -n '1p' "$path" 2>/dev/null | tr -d '[:space:]')
  [ -n "$v" ] || return 1
  local LC_ALL=C
  [[ "$v" =~ ^[0-9]+$ ]] || return 1
  printf '%s\n' "$v"
}

# fm_seat_floor
# The percent LEFT at or below which a seat is taken out of automatic rotation,
# or empty when unset. Absent is off: no seat is ever rested, no extra quota is
# read, and every automatic path behaves exactly as it did before the floor
# existed.
fm_seat_floor() {
  fm_seat_percent_file "$CONFIG/claude-seat-floor"
}

# fm_seat_floor_readd
# The percent LEFT BOTH windows must regain before a resting seat may wake.
# Configured explicitly, or derived as min(100, max(3 x floor, floor + 10)) so a
# floor on its own already carries hysteresis: 15 for a floor of 5. A configured
# level at or below the floor - say the floor was raised after it was set - is
# ignored for the derived one, because waking a seat the next reading rests
# again would flap it every rest period. Returns 1 when no floor is configured,
# because there is then nothing to come back from.
fm_seat_floor_readd() {
  local floor readd
  floor=$(fm_seat_floor) || return 1
  if readd=$(fm_seat_percent_file "$CONFIG/claude-seat-floor-readd") &&
    jq -en --arg r "$readd" --arg f "$floor" '($r | tonumber) > ($f | tonumber)' >/dev/null 2>&1; then
    printf '%s\n' "$readd"
    return 0
  fi
  jq -rn --arg f "$floor" \
    '[100, ([(($f | tonumber) * 3), (($f | tonumber) + 10)] | max)] | min | tostring' 2>/dev/null
}

# fm_seat_floor_dwell
# Seconds a seat must have been resting before any reading may wake it.
fm_seat_floor_dwell() {
  local v
  v=$(fm_seat_seconds_file "$CONFIG/claude-seat-floor-dwell") || v=$FM_SEAT_FLOOR_DWELL_DEFAULT
  printf '%s\n' "$v"
}

# fm_seat_session_share_setting
# The ASSUMED share of a week one whole session costs, as configured or as the
# built-in default. It is used until the share has been measured on an account,
# and it is the one percentage here that does not count percent left.
fm_seat_session_share_setting() {
  local v
  v=$(fm_seat_percent_file "$CONFIG/claude-seat-session-share") || v=$FM_SEAT_SESSION_SHARE_DEFAULT
  printf '%s\n' "$v"
}

# fm_seat_iso_to_epoch <timestamp>
# Epoch seconds for one quota-axi reset time, or 1 for any shape this cannot
# read, so a malformed time is refused rather than read as "now". quota-axi
# stamps them as 2026-10-08T01:00:00.339725+00:00, so the fractional second is
# dropped and the offset is applied arithmetically; a bare Z is accepted too.
#
# The parse lives here rather than reusing bin/fm-classify-lib.sh's reader
# because nothing on the seat path - this library, the spawn gate, or the seat
# board - sources that library, and pulling it in for one date shape would cost
# every one of them the whole wake classifier.
fm_seat_iso_to_epoch() {
  local ts=${1-} sign='' offset='' hh mm base
  [ -n "$ts" ] || return 1
  local LC_ALL=C
  # Take the zone designator off first, then drop any fractional second, so the
  # remaining text is one shape whichever way the service stamped it.
  case "$ts" in
    *Z) ts=${ts%Z} ;;
    *+[0-9][0-9]:[0-9][0-9]) sign=+; offset=${ts##*+}; ts=${ts%+*} ;;
    *-[0-9][0-9]:[0-9][0-9]) sign=-; offset=${ts##*-}; ts=${ts%-*} ;;
    *) return 1 ;;
  esac
  ts=${ts%%.*}
  case "$ts" in
    [0-9][0-9][0-9][0-9]-[0-1][0-9]-[0-3][0-9]T[0-2][0-9]:[0-5][0-9]) ts="$ts:00" ;;
    [0-9][0-9][0-9][0-9]-[0-1][0-9]-[0-3][0-9]T[0-2][0-9]:[0-5][0-9]:[0-5][0-9]) ;;
    *) return 1 ;;
  esac
  base=$(date -u -j -f '%Y-%m-%dT%H:%M:%S' "$ts" +%s 2>/dev/null) \
    || base=$(date -u -d "${ts}Z" +%s 2>/dev/null) \
    || return 1
  if [ -n "$offset" ]; then
    hh=${offset%%:*}
    mm=${offset##*:}
    # An offset says how far the stamped wall clock runs AHEAD of UTC, so
    # reading it as UTC overshoots by exactly that much; the correction inverts.
    if [ "$sign" = + ]; then
      base=$((base - (10#$hh * 3600 + 10#$mm * 60)))
    else
      base=$((base + (10#$hh * 3600 + 10#$mm * 60)))
    fi
  fi
  printf '%s\n' "$base"
}

# fm_seat_windows_from <quota-json>
# The two account-level windows the floor reads, one row each, as
# `id<TAB>percentRemaining<TAB>resetsAt<TAB>windowSeconds`. A window the report
# does not carry prints no row at all, and an absent field prints empty, so a
# caller can tell "not reported" from a number. This is the one owner of that
# extraction, so the watch and the board can never disagree about which windows
# the floor is about.
fm_seat_windows_from() {
  local out=${1-}
  [ -n "$out" ] || return 1
  printf '%s\n' "$out" | jq -r "$FM_QUOTA_ROW_JQ"'
    quota_row(.; "claude"; "") as $row
    | if ($row // null) == null then empty else
        ($row.windows // [])[]
        | select(.id == "five_hour" or .id == "seven_day")
        | [ .id,
            ((.percentRemaining // "") | tostring),
            (.resetsAt // ""),
            ((.windowSeconds // "") | tostring) ]
        | @tsv
      end
  ' 2>/dev/null
}

# fm_seat_window_field <windows-text> <window-id> <column>
# One field of one fm_seat_windows_from row, or 1 when that window or field is
# not reported.
fm_seat_window_field() {
  local rows=${1-} id=${2-} col=${3-} v
  v=$(printf '%s\n' "$rows" | awk -F'\t' -v id="$id" -v c="$col" '$1 == id { print $c; exit }')
  [ -n "$v" ] || return 1
  printf '%s\n' "$v"
}

# fm_seat_limiting_window_from <quota-json>
# Which of the two windows is the one holding the seat down: the id quota-axi
# itself names as limiting when it names one of these two, and otherwise the
# window with less left. Returns 1 when neither window was reported.
fm_seat_limiting_window_from() {
  local out=${1-} named rows session week
  [ -n "$out" ] || return 1
  named=$(printf '%s\n' "$out" | jq -r "$FM_QUOTA_ROW_JQ"'
    quota_effective(quota_row(.; "claude"; ""); "default")
    | (.limitingWindowIds // [])[0] // ""
  ' 2>/dev/null) || named=''
  case "$named" in
    "$FM_SEAT_SESSION_WINDOW" | "$FM_SEAT_WEEK_WINDOW")
      printf '%s\n' "$named"
      return 0
      ;;
  esac
  rows=$(fm_seat_windows_from "$out") || return 1
  session=$(fm_seat_window_field "$rows" "$FM_SEAT_SESSION_WINDOW" 2) || session=''
  week=$(fm_seat_window_field "$rows" "$FM_SEAT_WEEK_WINDOW" 2) || week=''
  if [ -n "$session" ] && [ -n "$week" ]; then
    if jq -en --arg s "$session" --arg w "$week" '($w | tonumber) <= ($s | tonumber)' >/dev/null 2>&1; then
      printf '%s\n' "$FM_SEAT_WEEK_WINDOW"
    else
      printf '%s\n' "$FM_SEAT_SESSION_WINDOW"
    fi
    return 0
  fi
  [ -n "$session" ] && { printf '%s\n' "$FM_SEAT_SESSION_WINDOW"; return 0; }
  [ -n "$week" ] && { printf '%s\n' "$FM_SEAT_WEEK_WINDOW"; return 0; }
  return 1
}

# fm_seat_login_renewable_from <quota-json>
# Exit 0 when the report says this profile's session is signed in and only its
# ACCESS TOKEN has lapsed. The one owner of that test, read from the machine-
# readable field rather than from any message, because the same state is
# reported with different error text depending on which route reached it.
fm_seat_login_renewable_from() {
  local out=${1-}
  [ -n "$out" ] || return 1
  printf '%s\n' "$out" | jq -e '
    (.providers // []) | map(select(.provider == "claude")) | .[0] // empty
    | .state.authStatus == "expired_refreshable"
  ' >/dev/null 2>&1
}

# --- the resting record -------------------------------------------------------
# config/claude-seat-resting, written only by the watch pass and by
# `bin/fm-seat.sh resting wake <name>`. It is CONFIG rather than state for one
# reason: a local secondmate home's own rotation must skip a seat the primary's
# watch rested, and inherited config is the only thing that crosses homes.
# Schema 1:
#   { schemaVersion, updatedAt,
#     seats: { "<name>": { since, account, limitingWindow, provisional,
#                          expectedBack, lastRead, unreadableSince,
#                          windows: { "<id>": { remaining, resetsAt,
#                                               windowSeconds } } } } }
# Absent means nothing is resting, which is also what an unreadable or foreign
# file reads as: a torn record must not strand every seat out of rotation.

# fm_seat_resting_record
# The whole document, always valid JSON.
fm_seat_resting_record() {
  local path="$CONFIG/claude-seat-resting"
  if [ -f "$path" ] && jq -e 'type == "object" and (.seats | type) == "object"' \
    "$path" >/dev/null 2>&1; then
    cat "$path"
    return 0
  fi
  printf '{"schemaVersion":1,"seats":{}}\n'
}

# fm_seat_resting_entry <name>
# One seat's entry, including one back provisionally, or 1 when the record holds
# none. With no floor configured every seat reads as having none, so a stale or
# hand-placed record can never withhold a seat while the feature is off.
fm_seat_resting_entry() {
  local name=${1-} entry
  [ -n "$name" ] || return 1
  fm_seat_floor >/dev/null || return 1
  entry=$(fm_seat_resting_record | jq -c --arg n "$name" '.seats[$n] // empty' 2>/dev/null) || return 1
  [ -n "$entry" ] || return 1
  printf '%s\n' "$entry"
}

# fm_seat_resting <name>
# True when the floor is holding this seat out of automatic rotation. The one
# owner of that question, so the candidate filter, the listing, the status
# report, and the board can never disagree.
#
# A seat back PROVISIONALLY still has an entry but is not resting: it is a
# candidate again, and only the next readable reading clears or re-rests it.
#
# Like the manual exclusion, it is deliberately NOT consulted by
# `switch <name>`: resting withholds a seat from the automatic paths only.
fm_seat_resting() {
  local entry
  entry=$(fm_seat_resting_entry "${1-}" 2>/dev/null) || return 1
  printf '%s\n' "$entry" | jq -e '(.provisional // false) | not' >/dev/null 2>&1
}

# fm_seat_resting_write <record-json>
# Publish a whole record atomically, or remove the file when no seat is resting,
# so "nothing is resting" is the absent file rather than an empty one that reads
# the same but looks configured.
fm_seat_resting_write() {
  local record=${1-} tmp
  printf '%s\n' "$record" | jq -e . >/dev/null 2>&1 || return 1
  mkdir -p "$CONFIG" 2>/dev/null || return 1
  if printf '%s\n' "$record" | jq -e '(.seats | length) == 0' >/dev/null 2>&1; then
    rm -f "$CONFIG/claude-seat-resting" || return 1
    return 0
  fi
  tmp=$(umask 077; mktemp "$CONFIG/.claude-seat-resting.XXXXXX" 2>/dev/null) || return 1
  printf '%s\n' "$record" | jq -S . > "$tmp" 2>/dev/null || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$CONFIG/claude-seat-resting" || { rm -f -- "$tmp"; return 1; }
}

# --- the session share --------------------------------------------------------
# How many weekly percentage points one WHOLE session window costs. quota-axi
# exposes no absolute budget, only a percentage per window, so the ratio can
# only be measured from co-movement: inside one session window on one account,
# every point the session spends also moves the week.
#
# The samples are STATE, not config: only the home running the watch measures
# and only it wakes seats, so a secondmate never needs them.
# state/claude-seat-session-share.json, schema 1:
#   { schemaVersion,
#     accounts: { "<email>": { open: { sessionResetsAt, weekResetsAt,
#                                      firstSessionUsed, firstWeekUsed,
#                                      lastSessionUsed, lastWeekUsed },
#                              samples: [ ... ], updatedAt } } }

# fm_seat_session_share_file
# Where the samples live, or 1 when this caller has no state directory, which
# makes every share assumed rather than measured.
fm_seat_session_share_file() {
  [ -n "${STATE:-}" ] || return 1
  printf '%s\n' "$STATE/claude-seat-session-share.json"
}

# fm_seat_session_share_doc
# The whole samples document, always valid JSON.
fm_seat_session_share_doc() {
  local path
  if path=$(fm_seat_session_share_file) && [ -f "$path" ] &&
    jq -e 'type == "object" and (.accounts | type) == "object"' "$path" >/dev/null 2>&1; then
    cat "$path"
    return 0
  fi
  printf '{"schemaVersion":1,"accounts":{}}\n'
}

# fm_seat_session_share_value [<account>]
# The share to use for one account, as `percent<TAB>source<TAB>samples`, where
# source is `measured` or `assumed`. Two samples are required before a measured
# figure is trusted; with one, the larger of it and the assumed share is used
# and the source still reads assumed. The maximum sample is taken rather than
# the mean, because over-estimating the share only keeps a seat resting longer
# while under-estimating it wakes a seat whose week cannot carry a session.
#
# With no account named, every account's samples count, which gives the most
# conservative figure this machine has evidence for. That is what the settings
# surface and the board report, because neither is asking about one account.
fm_seat_session_share_value() {
  local account=${1-} assumed samples count value source
  assumed=$(fm_seat_session_share_setting)
  samples=$(fm_seat_session_share_doc | jq -c --arg a "$account" '
    if $a == "" then [.accounts[]?.samples[]?] else (.accounts[$a].samples // []) end
  ' 2>/dev/null) || samples='[]'
  [ -n "$samples" ] || samples='[]'
  count=$(printf '%s' "$samples" | jq -r 'length' 2>/dev/null) || count=0
  case "$count" in ''|*[!0-9]*) count=0 ;; esac
  if [ "$count" -ge 2 ]; then
    value=$(printf '%s' "$samples" | jq -r 'max | tostring')
    source=measured
  else
    value=$(printf '%s' "$samples" |
      jq -r --arg d "$assumed" '([(($d | tonumber))] + .) | max | tostring')
    source=assumed
  fi
  printf '%s\t%s\t%s\n' "$value" "$source" "$count"
}

# fm_seat_session_share_observe <account> <session-left> <session-resets> <week-left> <week-resets>
# Record one reading toward the measurement. A sample is produced only when the
# session window has ROLLED while the week's has not, and only when the closed
# window spent at least 20 points, so integer rounding can move the result by at
# most about five points. A week that resets inside an open session restarts
# that session's measurement, since its week figures no longer share a baseline.
# Reset detection is by the reading itself, never by a clock. Silent and best-effort: a home with no state directory simply never
# measures.
fm_seat_session_share_observe() {
  local account=${1-} s_left=${2-} s_reset=${3-} w_left=${4-} w_reset=${5-} path doc tmp
  path=$(fm_seat_session_share_file) || return 0
  [ -n "$account" ] && [ -n "$s_reset" ] && [ -n "$w_reset" ] || return 0
  local LC_ALL=C
  [[ "$s_left" =~ ^[0-9]+(\.[0-9]+)?$ ]] || return 0
  [[ "$w_left" =~ ^[0-9]+(\.[0-9]+)?$ ]] || return 0
  doc=$(fm_seat_session_share_doc | jq -c \
    --arg a "$account" --arg sr "$s_reset" --arg wr "$w_reset" \
    --arg sl "$s_left" --arg wl "$w_left" --argjson now "$(date +%s)" '
    def ceil_: if . == floor then . else floor + 1 end;
    (100 - ($sl | tonumber)) as $su |
    (100 - ($wl | tonumber)) as $wu |
    (.accounts[$a] // null) as $cur |
    ($cur.open // null) as $open |
    {sessionResetsAt: $sr, weekResetsAt: $wr,
     firstSessionUsed: $su, firstWeekUsed: $wu,
     lastSessionUsed: $su, lastWeekUsed: $wu} as $fresh |
    if $open == null or $open.sessionResetsAt != $sr then
      (if $open != null and $open.weekResetsAt == $wr
          and ($open.lastSessionUsed - $open.firstSessionUsed) >= 20
       then ((100 * ($open.lastWeekUsed - $open.firstWeekUsed)
              / ($open.lastSessionUsed - $open.firstSessionUsed)) | ceil_)
       else 0 end) as $sample |
      .accounts[$a] = {
        open: $fresh,
        samples: ((($cur.samples // []) + (if $sample >= 1 then [$sample] else [] end)) | .[-5:]),
        updatedAt: $now}
    elif $open.weekResetsAt != $wr then
      .accounts[$a] = ($cur | .open = $fresh | .updatedAt = $now)
    else
      .accounts[$a] = ($cur
        | .open.lastSessionUsed = $su
        | .open.lastWeekUsed = $wu
        | .updatedAt = $now)
    end' 2>/dev/null) || return 0
  [ -n "$doc" ] || return 0
  mkdir -p "$STATE" 2>/dev/null || return 0
  tmp=$(umask 077; mktemp "$STATE/.claude-seat-session-share.XXXXXX" 2>/dev/null) || return 0
  printf '%s\n' "$doc" > "$tmp" 2>/dev/null || { rm -f -- "$tmp"; return 0; }
  mv -f -- "$tmp" "$path" 2>/dev/null || rm -f -- "$tmp"
  return 0
}

# fm_seat_dispatch_decision
# The dispatch gate, printed as one line: `allow <reason>` or `hold <reason>`.
#
# What this can and cannot do is worth being exact about. Firstmate controls
# which seat a NEW worker starts on and whether new Claude work is dispatched at
# all. It cannot stop a worker already running from drawing extra usage
# mid-task; only the organisation's Claude admin setting can do that. So a
# `stop` policy means stop STARTING new work, never a guarantee of zero spend.
#
# With no policy configured this returns `allow policy-unset` without reading
# any quota at all, so an unconfigured home pays nothing for the feature.
#
# The quota floor layers one branch onto the `stop` policy and nothing onto
# `allow <usd>`: with a floor set, `stop` holds once the active seat is at or
# below it rather than waiting for the plan quota to reach nothing.
fm_seat_dispatch_decision() {
  local policy cap out remaining spent floor
  policy=$(fm_seat_extra_usage_policy) || { printf 'allow policy-unset\n'; return 0; }
  out=$(fm_seat_quota_json "$(fm_seat_spawn_config_dir)") || {
    printf 'hold quota-unreadable\n'
    return 0
  }
  remaining=$(fm_seat_remaining_from "$out") || {
    # A lapsed token reads no quota until a launch renews it, so holding on it
    # would hold every spawn for good. The field is the one fm_seat_logged_in
    # reads for the same state.
    if printf '%s\n' "$out" | jq -e '
      (.providers // []) | map(select(.provider == "claude")) | .[0] // empty
      | .state.authStatus == "expired_refreshable"
    ' >/dev/null 2>&1; then
      printf 'allow login-renewable\n'
    else
      printf 'hold quota-unreadable\n'
    fi
    return 0
  }
  # With a floor configured, the `stop` policy holds at the floor rather than at
  # nothing left. The floor is the operator's own definition of "effectively
  # empty", and an active seat sitting below it with nowhere to go would
  # otherwise keep starting workers until it reached zero and then hold anyway,
  # spending the last few percent that interactive use needs.
  if [ "$policy" = stop ] && floor=$(fm_seat_floor) &&
    jq -en --arg r "$remaining" --arg f "$floor" \
      '($r | tonumber) <= ($f | tonumber)' >/dev/null 2>&1; then
    printf 'hold floor-stop %s %s\n' "$remaining" "$floor"
    return 0
  fi
  # Plan quota still left means no extra usage is in play, whatever the policy
  # says: the gate exists to guard paid overflow, not to ration the plan.
  if jq -en --arg r "$remaining" '($r | tonumber) > 0' >/dev/null 2>&1; then
    printf 'allow plan-quota-remaining %s\n' "$remaining"
    return 0
  fi
  case "$policy" in
    stop)
      printf 'hold extra-usage-stop\n'
      return 0
      ;;
  esac
  cap=${policy#allow }
  spent=$(fm_seat_extra_spent_from "$out") || {
    printf 'hold extra-usage-spend-unreadable %s\n' "$cap"
    return 0
  }
  if jq -en --arg s "$spent" --arg c "$cap" '($s | tonumber) < ($c | tonumber)' >/dev/null 2>&1; then
    printf 'allow extra-usage-under-cap %s %s\n' "$spent" "$cap"
    return 0
  fi
  printf 'hold extra-usage-cap %s %s\n' "$spent" "$cap"
}

# fm_seat_dispatch_reason <decision-line>
# The operator-facing reason for one fm_seat_dispatch_decision line, the single
# place its wording lives. Exit 0 for an allow and 1 for a hold, so the spawn
# gate and `bin/fm-seat.sh status` both render and branch on the same text.
fm_seat_dispatch_reason() {
  local verb reason a b
  read -r verb reason a b <<< "${1-}"
  if [ "$verb" = allow ]; then
    case "$reason" in
      policy-unset)
        printf 'no extra-usage policy is configured, so no quota is read and nothing holds\n' ;;
      plan-quota-remaining)
        printf 'the active Claude seat still has %s%% of its plan quota left\n' "$a" ;;
      extra-usage-under-cap)
        printf '$%s of extra usage spent on the active Claude seat, under the $%s cap\n' "$a" "$b" ;;
      login-renewable)
        printf 'the active Claude seat access token has lapsed, so its quota cannot be read until this launch renews it\n' ;;
      *)
        printf 'the extra-usage policy allows new Claude dispatch\n' ;;
    esac
    return 0
  fi
  case "$reason" in
    quota-unreadable)
      printf 'the active Claude seat quota could not be read, so whether this worker would run on paid extra usage is unknown, and the policy makes no guess\n' ;;
    extra-usage-stop)
      printf 'the active Claude seat has no plan quota left and the extra-usage policy is stop, so no new Claude worker is started on paid extra usage\n' ;;
    floor-stop)
      printf 'the active Claude seat is at %s%% left, at or below the %s%% quota floor, and the extra-usage policy is stop, so no new Claude worker is started on what is left of it\n' "$a" "$b" ;;
    extra-usage-spend-unreadable)
      printf 'the active Claude seat has no plan quota left and its extra-usage spend could not be read, so it cannot be compared against the $%s cap\n' "$a" ;;
    extra-usage-cap)
      printf '$%s of extra usage is already spent on the active Claude seat, at or over the $%s cap\n' "$a" "$b" ;;
    *)
      printf 'the extra-usage policy holds new Claude dispatch\n' ;;
  esac
  printf 'this holds only work not yet started; a worker already running keeps its own seat and can still draw extra usage mid-task\n'
  return 1
}
