#!/usr/bin/env bash
# Bind native Claude project settings to the exact T3 checkout before hooks run.
# The provider cannot receive per-launch environment flags. Merge only these
# home-routing env keys into settings.local.json; preserve permissions, hooks
# and every unrelated key. Existing conflicting routing refuses. Repeating the
# operation converges; malformed JSON and symlinks are refused, never replaced.
# Call only after validating the task checkout or independent primary home.
fm_t3_bind_claude_home() { # <checkout/home> [--dry-run]
  local home=$1 dry=${2:-} directory file temporary input
  home=$(cd "$home" && pwd -P) || return 1
  directory="$home/.claude"
  file="$directory/settings.local.json"
  [ ! -L "$directory" ] && [ ! -L "$file" ] || {
    echo 'error: T3 Claude home binding refuses symlinked settings' >&2; return 1;
  }
  input='{}'
  if [ -e "$file" ]; then
    [ -f "$file" ] && [ -r "$file" ] || return 1
    input=$(cat "$file") || return 1
  fi
  input=$(printf '%s' "$input" | jq -e --arg home "$home" '
    {FM_HOME:$home,FM_ROOT:$home,FM_ROOT_OVERRIDE:"",FM_STATE_OVERRIDE:"",FM_DATA_OVERRIDE:"",FM_CONFIG_OVERRIDE:"",FM_PROJECTS_OVERRIDE:""} as $binding |
    if type != "object" or (.env != null and (.env|type) != "object") then error("invalid Claude local settings")
    elif any((.env // {} | to_entries[]); . as $entry | ($binding | has($entry.key)) and $entry.value != $binding[$entry.key]) then error("conflicting Claude home routing")
    else . end |
    .env = ((.env // {}) + $binding)') || {
    echo 'error: cannot bind native T3 Claude settings; preserve and inspect the local settings file' >&2; return 1;
  }
  [ "$dry" != --dry-run ] || return 0
  mkdir -p "$directory" || return 1
  temporary=$(mktemp "$directory/.t3-settings.XXXXXX") || return 1
  if ! (umask 077; printf '%s\n' "$input" > "$temporary") || ! mv "$temporary" "$file"; then
    rm -f "$temporary"
    return 1
  fi
}
