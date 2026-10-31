#!/usr/bin/env bash
# Optional ready-hold label lookup shared by ship instructions and GitHub actions.
# docs/configuration.md "Ready-hold labels" owns the declaration format.

fm_ready_hold_label() {  # <config-dir> <project-name>
  local file=$1/project-ready-hold-label
  [ -e "$file" ] || [ -L "$file" ] || return 0
  if [ ! -f "$file" ] || [ ! -r "$file" ]; then
    printf 'error: %s is not a readable regular file\n' "$file" >&2
    return 1
  fi
  awk -F '\t' -v project="$2" '
    /^[[:space:]]*$/ || /^#([[:space:]]|$)/ { next }
    {
      sub(/\r$/, "")
      if (NF != 2 || $1 == "" || seen[$1]++ || $1 ~ /[[:cntrl:]]/ || $2 ~ /[[:cntrl:]]/) {
        printf "error: invalid or duplicate ready-hold entry at %s:%d\n", FILENAME, FNR > "/dev/stderr"
        bad=1
      }
      if ($1 == project) label=$2
    }
    END { if (bad) exit 1; if (label != "") print label }
  ' "$file"
}

fm_ready_hold_verify() {  # <pr-url> <label>
  local json
  json=$(gh pr view "$1" --json labels) || return 1
  printf '%s' "$json" | jq -e --arg label "$2" \
    '.labels | any(.name == $label)' >/dev/null
}

fm_ready_hold_apply() (  # <pr-url> <label>
  # shellcheck source=bin/fm-pr-lib.sh
  . "${BASH_SOURCE[0]%/*}/fm-pr-lib.sh"
  if ! fm_pr_url_parse "$1" || [ "$FM_PR_PROVIDER" != github ]; then
    printf 'error: ready-hold requires a canonical GitHub PR URL\n' >&2
    return 1
  fi
  gh-axi pr edit "$FM_PR_NUMBER" --repo "$FM_PR_PATH" --add-label "$2" || return 1
  fm_ready_hold_verify "$1" "$2" || {
    printf 'error: ready-hold label was not confirmed on %s; do not mark ready\n' "$1" >&2
    return 1
  }
)
