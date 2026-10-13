# shellcheck shell=bash
# Read-only seat renewal decisions, shared by the CLI and quota panel.
# Source after fm-seat-lib.sh; FM_SEAT_PROVIDER selects claude or codex.
# fm_seat_renewal_from <quota-json> <profile> [seat-name] prints JSON containing
# state, reason, loginCommand, command, and supported. command is a read-only
# recheck command, never a renewal command. No function here launches a vendor.
#
# No vendor currently has an enabled renewal adapter. A process snapshot cannot
# exclude an unmanaged session starting immediately afterwards, and a private
# helper lock cannot exclude that session either. Vendor refresh serialization
# alone does not establish that no live session owns the seat. Until ownership
# exclusion is proven, every mutation request refuses without reading tokens,
# invoking a vendor CLI, or attempting a login. Keep this boundary here rather
# than letting individual panel actions decide when credential writes are safe.

fm_seat_renewal_from() {
  local json=${1-} profile=${2-} name=${3-} provider=${FM_SEAT_PROVIDER:-claude}
  local state login='' command='' reason
  case "$provider" in claude|codex) ;; *) return 2 ;; esac
  state=$(printf '%s\n' "$json" | jq -er --arg provider "$provider" '
    (.providers // [] | map(select(.provider == $provider)) | .[0]) as $p
    | if $p == null then "unknown"
      elif ($p.source == "unavailable"
        and (($p.attempts // []) | length > 0
          and all(.status == "skipped"
            and (.error == "credentials_missing" or .error == "credentials_invalid"))))
        or ($p.state.authStatus == "credentials_invalid") then "invalid"
      elif $p.state.authStatus == "expired_refreshable" then "expired_refreshable"
      elif $p.source == "oauth" and $p.state.status == "fresh" then "healthy"
      else "unknown" end
  ' 2>/dev/null) || state=unknown
  case "$state" in
    invalid)
      reason='Credentials are missing or invalid; sign in personally. Automatic renewal never attempts login.'
      login=$(fm_seat_login_command "$profile") || return 2
      ;;
    expired_refreshable)
      reason='Automatic renewal is unavailable: exclusive ownership against live and newly starting vendor sessions has not been proven. A normal vendor session owns its refresh.'
      ;;
    healthy) reason='The read-only quota probe succeeded; renewal is not needed.' ;;
    *) reason='Credential usability is unknown; no renewal or login is attempted.' ;;
  esac
  if [ -n "$name" ]; then
    fm_seat_name_valid "$name" || return 2
    printf -v command 'FM_HOME=%q %q --provider %q --check %q' "${FM_HOME:-${FM_ROOT:-.}}" \
      "${FM_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/bin/fm-seat-renew.sh" "$provider" "$name"
  fi
  jq -cn --arg state "$state" --arg reason "$reason" --arg login "$login" --arg command "$command" \
    '{state:$state,reason:$reason,loginCommand:(if $login == "" then null else $login end),
      command:(if $command == "" then null else $command end),supported:false}'
}
