# shellcheck shell=bash
# Worker-runtime preference by kind of work.
# This library is the one owner of config/dispatch-prefer's format and parse.
# docs/configuration.md "Worker runtime preference (config/dispatch-prefer)"
# owns the operator contract, and bin/fm-prefer.sh owns the set/show/clear
# mechanics.
#
# Usage: . bin/fm-prefer-lib.sh   (no FM_* setup required)
#
# File format: one `kind=harness` line per kind of work, where `kind` matches a
# `kind` declared on a rule in config/crew-dispatch.json and `harness` names a
# verified harness or the literal `auto`. `auto` means no preference for that
# kind and is equivalent to omitting the line. Blank lines and lines whose
# first non-blank character is `#` are ignored. Surrounding whitespace is
# trimmed from both sides of the `=`. A kind may appear at most once.
#
# What a preference means: it REORDERS the candidates of an already-matched
# crew-dispatch rule so the preferred runtime comes first. It never adds a
# candidate the rule does not list, never relaxes a gate, and never overrides an
# explicit per-task override. Consumers own their own application of that
# reorder; this library only parses.

# shellcheck source=bin/fm-control-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-control-lib.sh"

FM_PREFER_FILE_NAME="dispatch-prefer"

# The token shape shared by a kind and a harness value, matching the provider-id
# shape already used across dispatch configuration. One body, anchored once per
# regex engine, because the two engines spell "end of string" differently and a
# token is rejected for a stray newline only under the right anchor.
FM_PREFER_TOKEN_BODY='[a-z0-9]+(-[a-z0-9]+)*'
FM_PREFER_TOKEN_RE="^$FM_PREFER_TOKEN_BODY\$"
FM_PREFER_TOKEN_RE_JQ="^$FM_PREFER_TOKEN_BODY"'\z'

# fm_prefer_path <config-dir> -> the preference file's path
fm_prefer_path() {
  local config=${1-}
  [ -n "$config" ] || return 1
  printf '%s/%s\n' "${config%/}" "$FM_PREFER_FILE_NAME"
}

# fm_prefer_token_valid <token>
# Matched with bash's own regex rather than grep, because grep reads a line at a
# time and would accept a token carrying a newline, which would then split into
# two lines in the file and corrupt it.
fm_prefer_token_valid() {
  local token=${1-}
  [ -n "$token" ] || return 1
  [[ $token =~ $FM_PREFER_TOKEN_RE ]]
}

# fm_prefer_json <config-dir>
# Success: prints a JSON object of every declared non-auto preference,
#   {"<kind>":"<harness>", ...}, and exits 0. An absent file prints {}.
# Failure: prints ONE human-readable reason on stdout and exits 1, so a caller
#   that must refuse rather than select around a malformed file can use the
#   reason directly. Malformed configuration is an actionable error here, never
#   a preference quietly dropped.
fm_prefer_json() {
  local config=${1-} file line raw kind harness lineno=0 json='{}'
  [ -n "$config" ] || { printf 'config directory required\n'; return 1; }
  file=$(fm_prefer_path "$config") || { printf 'config directory required\n'; return 1; }
  if [ ! -e "$file" ] && [ ! -L "$file" ]; then
    printf '{}\n'
    return 0
  fi
  if [ ! -f "$file" ] || [ ! -r "$file" ]; then
    printf '%s is not a readable regular file\n' "$file"
    return 1
  fi
  command -v jq >/dev/null 2>&1 || { printf 'jq required to read %s\n' "$file"; return 1; }
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    raw=${line%$'\r'}
    # Trim surrounding whitespace before classifying the line.
    raw=${raw#"${raw%%[![:space:]]*}"}
    raw=${raw%"${raw##*[![:space:]]}"}
    case "$raw" in
      ''|'#'*) continue ;;
    esac
    case "$raw" in
      *=*) ;;
      *) printf 'line %s is not a kind=harness line\n' "$lineno"; return 1 ;;
    esac
    kind=${raw%%=*}
    harness=${raw#*=}
    kind=${kind%"${kind##*[![:space:]]}"}
    harness=${harness#"${harness%%[![:space:]]*}"}
    harness=${harness%"${harness##*[![:space:]]}"}
    fm_prefer_token_valid "$kind" ||
      { printf 'line %s: kind must match %s\n' "$lineno" "$FM_PREFER_TOKEN_RE"; return 1; }
    fm_prefer_token_valid "$harness" ||
      { printf 'line %s: harness must match %s, or be auto\n' "$lineno" "$FM_PREFER_TOKEN_RE"; return 1; }
    if [ "$harness" != auto ] && ! fm_control_harness_supported "$harness"; then
      printf 'line %s: %s is not a verified harness\n' "$lineno" "$harness"
      return 1
    fi
    if jq -e --arg kind "$kind" 'has($kind)' <<<"$json" >/dev/null 2>&1; then
      printf 'line %s: kind %s is declared more than once\n' "$lineno" "$kind"
      return 1
    fi
    if [ "$harness" = auto ]; then
      # Recorded as seen so a repeated kind is still caught, then dropped: auto
      # is the absence of a preference, not a preference for a runtime named
      # "auto".
      json=$(jq -c --arg kind "$kind" '. + {($kind): null}' <<<"$json") ||
        { printf 'line %s could not be recorded\n' "$lineno"; return 1; }
      continue
    fi
    json=$(jq -c --arg kind "$kind" --arg harness "$harness" '. + {($kind): $harness}' <<<"$json") ||
      { printf 'line %s could not be recorded\n' "$lineno"; return 1; }
  done < "$file"
  jq -c 'with_entries(select(.value != null))' <<<"$json" ||
    { printf 'could not render the preferences in %s\n' "$file"; return 1; }
}

# fm_prefer_for_kind <config-dir> <kind>
# Prints the preferred harness for <kind>, or nothing when that kind has no
# preference. Exits 1 with the reason on stdout when the file is malformed.
fm_prefer_for_kind() {
  local config=${1-} kind=${2-} json
  json=$(fm_prefer_json "$config") || { printf '%s\n' "$json"; return 1; }
  jq -r --arg kind "$kind" '.[$kind] // empty' <<<"$json"
}
