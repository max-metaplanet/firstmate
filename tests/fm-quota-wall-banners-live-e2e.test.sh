#!/usr/bin/env bash
# tests/fm-quota-wall-banners-live-e2e.test.sh - the live guard behind the vendor
# quota-wall detector (bin/fm-quota-wall-lib.sh).
#
# WHY A LIVE GUARD AT ALL. That detector's verdict comes from vendor-rendered
# text, which is the one class of check a portable test cannot keep honest: the
# fixtures under tests/captures/ and every assertion in
# tests/fm-quota-wall.test.sh keep passing after a vendor renames its banner,
# while the real detector silently stops recognizing the real wall - a check
# that is worse than no check, because it reads as covered. So the needles are
# re-read HERE against whatever vendor artifact is actually installed, and a
# string that is gone fails naming the harness and its version.
#
# It spends no model tokens: it resolves each installed CLI, reads its version,
# and greps its shipped artifact. That is why it is default-on and runs wherever
# those CLIs exist, rather than waiting for someone to opt in after an upgrade.
#
# An absent vendor CLI is reported explicitly and skipped rather than passed
# over in silence. A run that checked no vendor at all skips, like every live
# guard on a host that cannot run it, unless FM_QUOTA_WALL_BANNERS_LIVE=1 or
# FM_LIVE=1 asked for it - then it FAILS, because a requested guard that proved
# nothing must not report success.
#
# When this guard fails, the fix is to re-extract the vendor's current banner
# text, update fm_quota_wall_needles and the affected tests/captures/ frames and
# README together, and record the new artifact version there.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# No tool list: the gate must not skip the whole guard because one of the two
# vendors is missing. Each vendor is reported on its own below.
fm_live_gate default-on FM_QUOTA_WALL_BANNERS_LIVE

# shellcheck source=bin/fm-quota-wall-lib.sh
. "$ROOT/bin/fm-quota-wall-lib.sh"

CHECKED=0

# vendor_version <tool>
vendor_version() {
  "$1" --version 2>/dev/null | sed -n '1p' | tr -d '\r'
}

# vendor_artifact <tool> <sentinel>
# The shipped file that actually carries the vendor's banner text. The resolved
# executable is tried first; when it is only a launcher script (an npm wrapper
# around a platform binary), the largest shipped files in its package tree are
# searched for the sentinel instead. Prints the path, or nothing.
vendor_artifact() {
  local tool=$1 sentinel=$2 resolved real root found
  resolved=$(command -v "$tool" 2>/dev/null) || return 1
  real=$(readlink -f "$resolved" 2>/dev/null) || real=$resolved
  [ -n "$real" ] || real=$resolved
  if LC_ALL=C grep -q -a -F -- "$sentinel" "$real" 2>/dev/null; then
    printf '%s\n' "$real"
    return 0
  fi
  root=$(cd -- "$(dirname -- "$real")/.." 2>/dev/null && pwd -P) || return 1
  while IFS= read -r found; do
    [ -n "$found" ] || continue
    printf '%s\n' "$found"
    return 0
  done < <(find "$root" -type f -size +1M -print0 2>/dev/null \
    | xargs -0 grep -l -a -F -- "$sentinel" 2>/dev/null)
  return 1
}

# check_vendor <tool> <vendor> <sentinel>
# Every needle of every class this library recognizes for <vendor> must still be
# present in that vendor's shipped artifact, in one of the two apostrophe forms
# the library folds between.
check_vendor() {
  local tool=$1 vendor=$2 sentinel=$3
  local version artifact class needle typographic missing=''
  if ! command -v "$tool" >/dev/null 2>&1; then
    printf 'skip: live: %s absent, so %s banner text was not re-read\n' "$tool" "$vendor"
    return 0
  fi
  version=$(vendor_version "$tool")
  [ -n "$version" ] || version='(version unavailable)'
  if ! artifact=$(vendor_artifact "$tool" "$sentinel"); then
    fail "$vendor $version: no shipped artifact reachable from '$tool' carries the sentinel banner text \"$sentinel\"; the quota-wall detector cannot be trusted against this install"
  fi
  while IFS= read -r class; do
    [ -n "$class" ] || continue
    while IFS= read -r needle; do
      [ -n "$needle" ] || continue
      LC_ALL=C grep -q -a -F -- "$needle" "$artifact" 2>/dev/null && continue
      # The vendors mix apostrophe forms within one build, and the library folds
      # U+2019 to ASCII before matching, so either form present is a pass.
      typographic=${needle//\'/$'\xe2\x80\x99'}
      LC_ALL=C grep -q -a -F -- "$typographic" "$artifact" 2>/dev/null && continue
      missing="$missing${missing:+; }$class: \"$needle\""
    done < <(fm_quota_wall_needles "$vendor" "$class")
  done < <(fm_quota_wall_classes "$vendor")
  [ -z "$missing" ] \
    || fail "$tool $version no longer ships quota-wall banner text the detector keys on ($artifact): $missing"
  CHECKED=$((CHECKED + 1))
  pass "$tool $version still ships every quota-wall banner string the detector keys on"
}

check_vendor codex codex 'Your workspace is out of credits'
check_vendor claude claude 'Usage limit reached'

if [ "$CHECKED" -eq 0 ]; then
  if [ "$FM_LIVE_GATE_REQUESTED" -eq 1 ]; then
    fail 'neither vendor CLI was installed, so this guard proved nothing; install codex or claude, or run it where they are'
  fi
  printf 'skip: live: neither codex nor claude is installed, so this guard proved nothing\n'
  exit 0
fi
