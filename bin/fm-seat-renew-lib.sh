# shellcheck shell=bash
# Renewal authentication classification and panel projection.
# bin/fm-seat-renew.py owns guarded mutation and persisted history.
# This library only reads; neither a panel read nor --check starts a vendor.
#
# Grok is classified but NOT renewable: it reports no refreshable auth state at
# all, and bin/fm-seat-renew.sh refuses the provider outright. Its projection
# therefore carries supported:false with no renewal command, so a Grok seat
# still shows an honest login state and its exact login command on the board
# without offering a renewal that nothing here performs.

fm_seat_renewal_from() {
  local json=${1-} profile=${2-} name=${3-} provider=${FM_SEAT_PROVIDER:-claude}
  local state login='' command='' reason supported=true
  case "$provider" in
    claude|codex) ;;
    grok) supported=false ;;
    *) return 2 ;;
  esac
  state=$(printf '%s\n' "$json" | jq -er --arg provider "$provider" '
    (.providers // [] | map(select(.provider == $provider)) | .[0]) as $p
    | if $p == null then "unknown"
      elif ($p.source == "unavailable"
        and (($p.attempts // []) | length > 0
          and all(.status == "skipped"
            and (.error == "credentials_missing" or .error == "credentials_invalid"))))
        or ($p.state.authStatus == "credentials_invalid") then "invalid"
      elif $p.state.authStatus == "expired_refreshable" then "expired_refreshable"
      elif $provider == "grok" then
        (if $p.source != "unavailable" and (($p.state.authStatus // "") == "usable")
         then "healthy" else "unknown" end)
      elif $p.source == "oauth" and $p.state.status == "fresh" then "healthy"
      else "unknown" end
  ' 2>/dev/null) || state=unknown
  case "$state" in
    invalid)
      reason='Credentials are missing or invalid; sign in personally. Automatic renewal never attempts login.'
      login=$(fm_seat_login_command "$profile") || return 2
      ;;
    expired_refreshable)
      reason='Eligible for guarded renewal when no live owner holds this seat.'
      ;;
    healthy) reason='The read-only quota probe succeeded; renewal is not needed.' ;;
    *) reason='Credential usability is unknown; no renewal or login is attempted.' ;;
  esac
  if [ "$supported" = false ]; then
    case "$state" in
      invalid) ;;
      *) reason="$reason This provider has no guarded renewal; only a personal sign-in restores it." ;;
    esac
  elif [ -n "$name" ]; then
    fm_seat_name_valid "$name" || return 2
    printf -v command 'FM_HOME=%q %q --provider %q %q' "${FM_HOME:-${FM_ROOT:-.}}" \
      "${FM_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/bin/fm-seat-renew.sh" "$provider" "$name"
  fi
  local history='{}'
  if [ "$supported" = true ] && [ "${FM_SEAT_RENEW_NO_HISTORY:-0}" != 1 ]; then
    history=$(python3 "${FM_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/bin/fm-seat-lock.py" state --provider "$provider" --profile "$profile" 2>/dev/null) || history='{}'
  fi
  if [ "$state" != healthy ] && printf '%s' "$history" | jq -e '.invalidLatched == true' >/dev/null 2>&1; then
    reason='Renewal stopped after invalid credentials; a healthy read after login clears the stop.'
    login=$(fm_seat_login_command "$profile") || return 2
  fi
  jq -cn --argjson history "$history" --arg state "$state" --arg reason "$reason" --arg login "$login" \
    --arg command "$command" --argjson supported "$supported" \
    '{state:$state,reason:$reason,loginCommand:(if $login == "" then null else $login end),
      command:(if $command == "" then null else $command end),supported:$supported,lastAttempt:null,lastRenewal:null,outcome:null} + ($history | {lastAttempt,lastRenewal,outcome})'
}
