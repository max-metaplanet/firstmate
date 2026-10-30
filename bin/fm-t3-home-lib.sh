#!/usr/bin/env bash
# Remove legacy T3 home-routing env from Claude local settings before launch.
# Claude also reads the primary checkout's local settings in linked worktrees,
# so routing here would override other homes. Hooks default to their own code
# root when routing env is unset; never persist a checkout binding in settings.
# Preserve permissions, hooks and unrelated keys. Repeating converges; absent
# settings stay absent, and malformed JSON and symlinks refuse without changes.
# Call only after validating the task checkout or independent primary home.
fm_t3_bind_claude_home() { # <checkout/home> [--dry-run]
  local home=$1 dry=${2:-} directory file temporary input
  home=$(cd "$home" && pwd -P) || return 1
  directory="$home/.claude"
  file="$directory/settings.local.json"
  [ ! -L "$directory" ] && [ ! -L "$file" ] || {
    echo 'error: T3 Claude home binding refuses symlinked settings' >&2; return 1;
  }
  [ -e "$file" ] || return 0
  [ -f "$file" ] && [ -r "$file" ] || return 1
  input=$(cat "$file") || return 1
  input=$(printf '%s' "$input" | jq -e '
    if type != "object" or (.env != null and (.env|type) != "object") then error("invalid Claude local settings")
    else . end |
    del(.env.FM_HOME, .env.FM_ROOT, .env.FM_ROOT_OVERRIDE, .env.FM_STATE_OVERRIDE,
        .env.FM_DATA_OVERRIDE, .env.FM_CONFIG_OVERRIDE, .env.FM_PROJECTS_OVERRIDE)') || {
    echo 'error: cannot migrate native T3 Claude settings; preserve and inspect the local settings file' >&2; return 1;
  }
  [ "$dry" != --dry-run ] || return 0
  mkdir -p "$directory" || return 1
  temporary=$(mktemp "$directory/.t3-settings.XXXXXX") || return 1
  if ! (umask 077; printf '%s\n' "$input" > "$temporary") || ! mv "$temporary" "$file"; then
    rm -f "$temporary"
    return 1
  fi
}
