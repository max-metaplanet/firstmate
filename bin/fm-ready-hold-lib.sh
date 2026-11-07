#!/usr/bin/env bash
# Optional ready-hold label lookup shared by ship instructions and GitHub actions.
# docs/configuration.md "Ready-hold labels" owns the declaration format.
# Like every other hold bin/fm-dod-lib.sh allows on a ready PR, apart from the
# firstmate-ordered conflict-refresh hold, this label needs a written reason and
# a named owner posted as a PR comment line `Hold: <reason>; owner <owner>`; the
# label alone never justifies a hold, so fm_ready_hold_apply refuses to add it
# until that comment exists or the caller supplies a reason and owner to post.

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

fm_ready_hold_justified() {  # <pr-url>
  local json
  json=$(gh pr view "$1" --json comments) || return 1
  printf '%s' "$json" | jq -e \
    '.comments | any(.body | split("\n") | any(test("^Hold: \\S.*; owner \\S")))' >/dev/null
}

fm_ready_hold_verify() {  # <pr-url> <label>
  local json
  fm_ready_hold_justified "$1" || return 1
  json=$(gh pr view "$1" --json labels) || return 1
  printf '%s' "$json" | jq -e --arg label "$2" \
    '.labels | any(.name == $label)' >/dev/null
}

fm_ready_hold_apply() (  # <pr-url> <label> [<reason> <owner>]
  # Callers source fm-pr-lib.sh; the subshell isolates parsed PR fields.
  if ! fm_pr_url_parse "$1" || [ "$FM_PR_PROVIDER" != github ]; then
    printf 'error: ready-hold requires a canonical GitHub PR URL\n' >&2
    return 1
  fi
  if [ -n "${3:-}" ] || [ -n "${4:-}" ]; then
    case "${3:-}${4:-}" in *$'\n'*|*$'\r'*) printf 'error: hold reason and owner must be single lines\n' >&2; return 1 ;; esac
    if [ -z "${3:-}" ] || [ -z "${4:-}" ]; then
      printf 'error: a hold needs both a reason and an owner\n' >&2
      return 1
    fi
    gh-axi pr comment "$FM_PR_NUMBER" --repo "$FM_PR_PATH" --body "Hold: $3; owner $4" || return 1
  fi
  fm_ready_hold_justified "$1" || {
    printf 'error: %s has no "Hold: <reason>; owner <owner>" comment; no comment, no hold label\n' "$1" >&2
    return 1
  }
  gh-axi pr edit "$FM_PR_NUMBER" --repo "$FM_PR_PATH" --add-label "$2" || return 1
  fm_ready_hold_verify "$1" "$2" || {
    printf 'error: ready-hold label was not confirmed on %s; do not mark ready\n' "$1" >&2
    return 1
  }
)
