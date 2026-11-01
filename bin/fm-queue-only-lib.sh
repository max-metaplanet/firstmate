#!/usr/bin/env bash
# Optional per-project declaration of required checks that report only in the
# project's merge queue, shared by ship instructions, the ready wait, and the
# merge guard. docs/configuration.md "Queue-only required checks" owns the
# declaration format; bin/fm-pr-checks-lib.sh owns what the declaration does to
# a check verdict.

fm_queue_only_checks() {  # <config-dir> <project-name>
  local file=$1/project-queue-only-checks
  [ -e "$file" ] || [ -L "$file" ] || return 0
  if [ ! -f "$file" ] || [ ! -r "$file" ]; then
    printf 'error: %s is not a readable regular file\n' "$file" >&2
    return 1
  fi
  awk -F '\t' -v project="$2" '
    /^[[:space:]]*$/ || /^#([[:space:]]|$)/ { next }
    {
      sub(/\r$/, "")
      if (NF != 2 || $1 == "" || $2 == "" || seen[$0]++ || $1 ~ /[[:cntrl:]]/ || $2 ~ /[[:cntrl:]]/) {
        printf "error: invalid or duplicate queue-only entry at %s:%d\n", FILENAME, FNR > "/dev/stderr"
        bad=1
      }
      if ($1 == project) names[++n]=$2
    }
    END { if (bad) exit 1; for (i = 1; i <= n; i++) print names[i] }
  ' "$file"
}
