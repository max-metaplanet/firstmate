#!/usr/bin/env bash
# fm-orgs-lib.sh - which organizations this home calls ours, and the commit
# convention that follows from it.
#
# The captain's ticket convention renders `<type>/<ticket>(<scope>): <subject>`
# on every commit subject and pull request title. That format names an internal
# ClickUp workflow, so on a repository outside our own organizations it is noise
# at best: a contribution to a third-party upstream that carries
# `feat/no-ticket(scope): ...` advertises a ticket system that project does not
# have. Such a project gets plain conventional commits, `<type>(<scope>):
# <subject>`, with no ticket segment at all.
#
# "Outside our own organizations" is declared, never guessed. A home that
# declares nothing keeps the unchanged ticket convention everywhere, and no
# remote name, host, or repository owner changes that on its own.
#
# Declaration file: one entry per line in config/our-organizations (blank lines
# and full-line # comments ignored), each `<host>/<owner>` or a deeper
# group-style path, for example
#   github.com/metaplanet-jp
#   gitlab.example.com/our-group/our-subgroup
# An entry matches a repository identity that equals it or lies under it, so
# `github.com/metaplanet-jp` covers every repository that organization owns.
# A full `<host>/<owner>/<repo>` entry declares that one repository ours.
# Comparison is lowercase; bin/fm-role-lib.sh owns identity normalization and
# resolves the project's publication target from its remotes.
#
# The whole declaration fails closed on any malformed entry: one typo must not
# silently reclassify our own repositories as third-party and strip their ticket
# segment, so a file that cannot be trusted end to end is treated as absent and
# every project keeps the unchanged convention. FM_ORGS_DIAG names the reason.
#
# A publication target that does not resolve to a `<host>/<owner>/<repo>`
# identity - no remote, or a local path - is undetermined rather than outside:
# unknown never flips a project onto the plain convention.
#
# Public functions:
#   fm_orgs_file <config-dir>          - the declaration file path
#   fm_orgs_entry_valid <entry>        - 0 when <entry> is a usable declaration
#   fm_orgs_load <config-dir>          - 0 usable, 1 none declared, 2 malformed
#   fm_orgs_owns <config-dir> <identity>
#                                      - 0 ours, 1 not ours, 2 nothing declared
#   fm_orgs_plain_convention <config-dir> <project-dir>
#                                      - 0 plain conventional commits apply,
#                                        1 ours, 2 undetermined
#
# Global outputs: FM_ORGS_LIST (newline-separated normalized entries),
# FM_ORGS_TARGET (the resolved publication target), FM_ORGS_DIAG (why a load or
# decision could not be made).

# shellcheck source=bin/fm-role-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-role-lib.sh"

# fm_orgs_file <config-dir>
fm_orgs_file() {
  printf '%s/our-organizations\n' "${1%/}"
}

# fm_orgs_entry_valid <entry> - 0 when <entry> is <host>/<owner> or a deeper
# path over the same conservative charset bin/fm-role-lib.sh accepts for a
# publication scope.
fm_orgs_entry_valid() {
  case $1 in
  */*) ;;
  *) return 1 ;;
  esac
  case $1 in
  *[!A-Za-z0-9._/-]* | .* | */ | *//* | *..*) return 1 ;;
  esac
  return 0
}

# fm_orgs_load <config-dir> - read the declaration into FM_ORGS_LIST, lowercased
# for comparison. rc 1 when nothing is declared (absent, empty, or comments
# only), rc 2 when the file cannot be trusted; FM_ORGS_DIAG carries the reason
# for either.
fm_orgs_load() {
  local file line entry
  FM_ORGS_LIST=
  FM_ORGS_DIAG=
  file=$(fm_orgs_file "$1")
  if [ -L "$file" ]; then
    FM_ORGS_DIAG="$file is a symlink; the declaration is ignored"
    return 2
  fi
  if [ ! -e "$file" ]; then
    FM_ORGS_DIAG="no organizations are declared in $file"
    return 1
  fi
  if [ ! -f "$file" ] || [ ! -r "$file" ]; then
    FM_ORGS_DIAG="$file is not a readable regular file; the declaration is ignored"
    return 2
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line#"${line%%[![:space:]]*}"}
    line=${line%"${line##*[![:space:]]}"}
    case $line in
    '' | '#'*) continue ;;
    esac
    if ! fm_orgs_entry_valid "$line"; then
      FM_ORGS_LIST=
      FM_ORGS_DIAG="$file declares '$line', which is not a <host>/<owner> path; the whole declaration is ignored"
      return 2
    fi
    entry=$(printf '%s\n' "$line" | tr '[:upper:]' '[:lower:]')
    FM_ORGS_LIST="${FM_ORGS_LIST}${FM_ORGS_LIST:+
}$entry"
  done < "$file"
  if [ -z "$FM_ORGS_LIST" ]; then
    FM_ORGS_DIAG="no organizations are declared in $file"
    return 1
  fi
  return 0
}

# fm_orgs_owns <config-dir> <identity> - 0 when <identity> is one of ours or
# lies under a declared organization, 1 when the declaration does not cover it,
# 2 when there is no usable declaration to decide against.
fm_orgs_owns() {
  local identity entry
  fm_orgs_load "$1" || return 2
  identity=$(printf '%s\n' "$2" | tr '[:upper:]' '[:lower:]')
  [ -n "$identity" ] || return 1
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    case $identity in
    "$entry" | "$entry"/*) return 0 ;;
    esac
  done <<EOF
$FM_ORGS_LIST
EOF
  return 1
}

# fm_orgs_plain_convention <config-dir> <project-dir> - 0 when <project-dir>
# publishes outside the declared organizations and therefore takes plain
# conventional commit subjects and pull request titles. rc 1 when the project is
# one of ours and keeps the ticket convention. rc 2 when the decision cannot be
# made - nothing declared, a malformed declaration, or a publication target that
# is not a <host>/<owner>/<repo> identity - which also keeps the unchanged
# convention. FM_ORGS_TARGET carries the resolved target and FM_ORGS_DIAG the
# reason for rc 2.
fm_orgs_plain_convention() {
  local config=$1 project=$2
  FM_ORGS_TARGET=
  FM_ORGS_DIAG=
  fm_orgs_load "$config" || return 2
  [ -n "$project" ] && [ -d "$project" ] || {
    FM_ORGS_DIAG="no project directory to resolve a publication target from"
    return 2
  }
  FM_ORGS_TARGET=$(fm_role_publication_target "$project")
  case ${FM_ORGS_TARGET:-} in
  '' | path:*)
    # shellcheck disable=SC2034 # Output global, read by the sourcing caller.
    FM_ORGS_DIAG="$project has no remote that resolves to a <host>/<owner>/<repo> publication target"
    return 2
    ;;
  esac
  fm_orgs_owns "$config" "$FM_ORGS_TARGET" && return 1
  return 0
}
