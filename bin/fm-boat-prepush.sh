#!/usr/bin/env bash
# fm-boat-prepush.sh - run a pull request's heavy test lanes on one disposable
# Boat or fallback Upstash machine before the pull request is marked ready.
# Usage:
#   FM_HOME=/absolute/home fm-boat-prepush.sh [--worktree DIR] [--base REF]
#       [--expected-head SHA] [--timeout SECONDS] [--history-depth N]
#       [--output DIR]
# Exit: 0 every selected lane passed or had only proven missing-history
# failures, 1 a lane failed, the verdict was incomplete, or remote execution failed,
# and 2 invalid input.
#
# WHAT IT CHECKS
# The project's repository planner decides which heavy lanes a change selects.
# This runs the PULL REQUEST HEAD's own planner, never a copy of its rules kept
# here, and then runs the lanes it selected ONE AT A TIME on one machine.
# Sequential execution is the contract: running the same selected lanes together
# exhausted a 16 GB machine and was killed by the kernel, while one at a time
# completed with headroom. Each lane reports pass or fail separately, and any
# real failure returns nonzero.
# --expected-head refuses with exit 2 when the checkout HEAD differs from that
# full commit ID or tracked files have staged or unstaged changes, before planning
# or starting a machine. Untracked files are allowed. Without --expected-head,
# local edits remain allowed. verdict.json records the checked head.
# --base prefers origin's remote-tracking ref for a named branch over a local
# branch of that name; revision expressions resolve locally. Without --base,
# it tries origin/HEAD, then origin/main. --output selects the evidence directory;
# by default a fresh fm-boat-prepush.* directory is created beside the worktree.
#
# MACHINE SIZE
# The default 4 CPU / 8 GB machine is tried first, with the two memory caps the
# capacity measurements established: Turbo workspace concurrency of two for the
# other-packages shard, regardless of its selected filters,
# and a 3072 MiB old-space ceiling on the lane that runs Turbo `build`, which is
# the lowest ceiling measured to complete the admin-center build there. A larger
# 8 CPU / 16 GB machine is bought ONLY when every failing lane proves memory
# exhaustion - a kernel cgroup kill, exit 137, or V8's own heap diagnostic - and
# never for an ordinary assertion failure, a setup failure, or a mixed result.
# The printed verdict always names the machine the verdict came from.
# The adapter may use a free Upstash small box when Boat default is unavailable;
# fm-boat-run.sh owns its lower resources, eligibility and limits. Large retries
# remain Boat-only. Completed remote evidence and confirmed cleanup are required
# before an OOM retry; unknown execution never buys another attempt.
#
# WHAT IT COSTS
# One default-machine run of a sampled application change took roughly 18 to 26
# minutes including dependency installation, and a large-machine run of the
# heaviest sample took about 16 minutes. The per-run compute estimate was around
# two cents. Those are single observations, and the printed dollar figure is an
# estimate from elapsed time and Boat's published rate, never an invoice.
# Upstash results omit the Boat dollar estimate and name the free CPU allowance.
#
# TRANSPORT
# Source transfer, environment isolation, timeout, capacity, account selection
# and cleanup all belong to fm-boat-run.sh, reached through
# fm-boat-test-wrapper.sh, whose headers own those mechanics.
# Local fallback is explicitly disabled for this heavy gate, for both providers.
# Lanes receive only the public dummy values set by the project's workflows.
# --timeout and --history-depth forward to that adapter and keep its bounds.
# Without --history-depth the remote Git history is the wrapper's synthetic
# two-commit base, so a lane whose fixtures query real historical commits cannot
# find them. The changed-file list is therefore computed from real local Git and
# handed to the remote planner as data, so the SELECTION never depends on
# remote history even when the fixtures do.
# Database migration setup gives the ledger an isolated Git view derived from
# that same local changed-file list. Only changed paths appear as additions, so
# unchanged migrations are not replayed and unfingerprinted PR migrations stay
# in fatal tier A. The ledger view does not alter other lanes' Git history.
# Each lane has a ten-minute limit; a timeout is red and retains its output tail
# while the remaining lanes continue within the whole-machine time budget.
# fm-boat-run.sh --help owns --history-depth screening, withheld objects and
# whole-run refusal conditions.
# Each failing TAP or Vitest test is attributed individually. A failure proven
# to require missing history is reported by name and diagnostic as unavailable.
# Other failures, mixed lanes and unattributable failures remain red.
# The forge's required checks remain the authority for unavailable cases;
# green with unavailable tests does not mean full parity.
# Selected database suites run sequentially with digest-pinned services from
# the head's .github/ci-images.json; setup failures also make the check red.
# Native PostgreSQL clients must match the approved server image's major version;
# missing clients are installed from PGDG once on the disposable machine and
# reused across suites. If they cannot be obtained, the lane fails. Client calls
# do not start containers. Runtime test files run with --test-concurrency=1
# because they share one database and can race while creating roles.
# This is a pre-ready gate, not a replacement for the forge's required checks.
#
# WIRING
# bin/fm-boat-prepush-lib.sh owns the per-project declaration that puts this
# command into a ship worker's definition of done, and docs/configuration.md is
# the operator reference for it. bin/fm-boat-prepush.py is the local half and
# bin/fm-boat-prepush-remote.py the half that runs on the machine.
set -euo pipefail

if [[ ${1:-} == --help || ${1:-} == -h ]]; then
  sed -n '2,/^set -euo pipefail/{ /^set -euo pipefail/d; s/^# \{0,1\}//; p; }' "${BASH_SOURCE[0]}"
  exit 0
fi

exec python3 "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-boat-prepush.py" "$@"
