#!/usr/bin/env bash
# tests/scratch-root.sh - single owner of where this suite's scratch lives.
#
# Source it from a test entry point before its first mktemp:
#   # shellcheck source=tests/scratch-root.sh
#   . "$ROOT/tests/scratch-root.sh"
#   fm_test_scratch_root_init "$ROOT" || exit 1
# tests/lib.sh and bin/fm-test-run.sh already do this, so a suite that sources
# the library, or any suite the runner starts, inherits it with no call of its
# own. Only a suite that sources neither needs the two lines above.
#
# Why it exists: mktemp defaults to $TMPDIR, which on macOS is a per-user
# directory under /private/var/folders. Endpoint security scans that directory,
# and a suite walk fills it with thousands of short-lived fixture trees - churn
# measured at 7-8% of one operator machine's whole scan load. The directory the
# checkout itself sits in is already excluded from that scanning wherever
# firstmate puts a checkout (a worktree pool slot, a validation copy), so the
# scratch moves there instead of into the machine temp directory.
#
# Beside the checkout, not inside it. A fixture firstmate home inside the
# firstmate repo is refused on purpose - "secondmate home cannot be inside the
# firstmate repo" in bin/fm-ff-lib.sh, bin/fm-home-seed.sh and
# bin/fm-backlog-handoff.sh - so an in-checkout scratch root would turn that
# live safety boundary into a failure across every suite that builds one. The
# slot's own claim file is placed the same way and for a related reason
# (fm_treehouse_slot_owner_marker in bin/fm-wake-lib.sh).
#
# Contract:
#   FM_TEST_SCRATCH_ROOT names the scratch root in force for this process tree.
#   The first process to resolve it creates <checkout>/../.fm-test-scratch,
#   points TMPDIR, TMP and GIT_CEILING_DIRECTORIES at it, and exports all four.
#   A process that inherits a live FM_TEST_SCRATCH_ROOT changes nothing, so
#   bin/fm-test-run.sh's per-worker TMPDIR isolation and a nested fixture's
#   inherited scratch both survive. Setting it yourself puts the scratch
#   wherever you point it and takes this file out of the decision.
#   Every fixture under the root is still created and removed by the same
#   mktemp and cleanup that owned it before, so concurrent runs cannot collide
#   and nothing new is left behind; the root itself is removed when the last
#   run leaves it empty. Scope is test scratch only: no non-test command's
#   TMPDIR is touched.

# Set when THIS process created the root, so only its owner tries to remove it.
FM_TEST_SCRATCH_OWNED=${FM_TEST_SCRATCH_OWNED:-0}

fm_test_scratch_root_init() {  # <checkout-root>
  local checkout=${1:-} parent root
  if [ -n "${FM_TEST_SCRATCH_ROOT:-}" ] && [ -d "$FM_TEST_SCRATCH_ROOT" ]; then
    return 0
  fi
  if [ -z "$checkout" ] || [ ! -d "$checkout" ]; then
    printf 'fm_test_scratch_root_init: not a checkout directory: %s\n' "$checkout" >&2
    return 1
  fi
  checkout=$(CDPATH='' cd -- "$checkout" && pwd -P) || return 1
  parent=$(dirname "$checkout")
  root="$parent/.fm-test-scratch"
  if [ "$parent" = "$checkout" ] || ! mkdir -p "$root" 2>/dev/null; then
    # An unwritable parent is not a reason to refuse to run the suite: leave
    # TMPDIR where the machine put it and say so once, rather than failing or
    # quietly moving the scratch inside the checkout.
    printf 'fm_test_scratch_root_init: cannot use %s; leaving scratch in %s\n' \
      "$root" "${TMPDIR:-/tmp}" >&2
    return 0
  fi
  # The machine temp directory this replaces is private to its owner; keep the
  # same reach so a fixture holding fake credentials is no more exposed here.
  chmod 0700 "$root" 2>/dev/null || true
  root=$(CDPATH='' cd -- "$root" && pwd -P) || return 1
  FM_TEST_SCRATCH_ROOT=$root
  FM_TEST_SCRATCH_OWNED=1
  TMPDIR=$root
  TMP=$root
  # A fixture directory that is deliberately NOT a git repository has to stay
  # one. Git's upward search for a .git would otherwise hand it whatever
  # repository encloses the scratch root - and firstmate reads exactly that
  # lineage to decide a project IS firstmate (bin/fm-role-lib.sh). The scratch
  # root holds no .git of its own, so ceiling it and no search started below it
  # can climb past it.
  GIT_CEILING_DIRECTORIES=$root
  export FM_TEST_SCRATCH_ROOT TMPDIR TMP GIT_CEILING_DIRECTORIES
}

# Remove the scratch root once the run that created it has cleaned its fixtures
# out. rmdir refuses a non-empty directory, so a concurrent run still holding
# fixtures keeps it; the next run to finish alone takes it away. That keeps a
# worktree pool slot carrying no leftover from a suite that ran in it.
fm_test_scratch_root_cleanup() {
  [ "${FM_TEST_SCRATCH_OWNED:-0}" = 1 ] || return 0
  [ -n "${FM_TEST_SCRATCH_ROOT:-}" ] || return 0
  rmdir "$FM_TEST_SCRATCH_ROOT" 2>/dev/null || true
}
