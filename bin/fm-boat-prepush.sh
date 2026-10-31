#!/usr/bin/env bash
# fm-boat-prepush.sh - run a pull request's heavy test lanes on one disposable
# Boat machine before the pull request is marked ready for review.
# Usage:
#   FM_HOME=/absolute/home fm-boat-prepush.sh [--worktree DIR] [--base REF]
#       [--type default|large] [--timeout SECONDS] [--history-depth N]
#       [--output DIR] [--json FILE]
# Exit: 0 every selected lane passed, 1 a lane failed or no verdict was
# produced, 2 invalid input, and the adapter's own codes for a Boat failure.
#
# WHAT IT CHECKS
# The project's repository planner decides which heavy lanes a change selects.
# This runs the PULL REQUEST HEAD's own planner, never a copy of its rules kept
# here, and then runs the lanes it selected ONE AT A TIME on one machine.
# Sequential execution is the contract: running the same selected lanes together
# exhausted a 16 GB machine and was killed by the kernel, while one at a time
# completed with headroom. Each lane reports pass or fail separately, and any
# real failure returns nonzero.
#
# MACHINE SIZE
# The default 4 CPU / 8 GB machine is tried first, with the two memory caps the
# capacity measurements established: Turbo workspace concurrency of two for the
# shard stated as exclusions, which fans out across every remaining workspace,
# and a 3072 MiB old-space ceiling on the lane that runs Turbo `build`, which is
# the lowest ceiling measured to complete the admin-center build there. A larger
# 8 CPU / 16 GB machine is bought ONLY when every failing lane proves memory
# exhaustion - a kernel cgroup kill, exit 137, or V8's own heap diagnostic - and
# never for an ordinary assertion failure, a setup failure, or a mixed result.
# The printed verdict always names the machine the verdict came from.
# --type large starts there instead; this check never uses xlarge.
#
# WHAT IT COSTS
# One default-machine run of a sampled application change took roughly 18 to 26
# minutes including dependency installation, and a large-machine run of the
# heaviest sample took about 16 minutes. The per-run compute estimate was around
# two cents. Those are single observations, and the printed dollar figure is an
# estimate from elapsed time and Boat's published rate, never an invoice.
#
# TRANSPORT
# Source transfer, environment isolation, timeout, capacity, account selection
# and cleanup all belong to fm-boat-run.sh, reached through
# fm-boat-test-wrapper.sh, whose headers own those mechanics. Nothing here adds
# a second transport, and no credential is sent: the lanes run with the public
# dummy values the project's own workflows set.
# --timeout and --history-depth forward to that adapter and keep its bounds.
# Without --history-depth the remote Git history is the wrapper's synthetic
# two-commit base, so a lane whose fixtures query real historical commits cannot
# find them. The changed-file list is therefore computed from real local Git and
# handed to the remote planner as data, so the SELECTION never depends on
# remote history even when the fixtures do.
# --history-depth is available only where the project's own history passes the
# adapter's credential screening, which scans every historical blob and commit
# and refuses the whole run locally before any Boat call. A repository whose
# ordinary source text trips that scanner cannot opt in, and its history-querying
# fixtures stay red on this check.
# A lane that fails while Git reports an object the upload does not carry is
# LABELLED as such in the verdict, using Git's own diagnostics rather than any
# knowledge of which tests those are. It is labelled, never excused: the lane
# still counts as failed and the exit stays nonzero, because a real regression
# can print the same diagnostic. Read that label as the signal to decide whether
# this project is ready to gate on the check at all.
#
# WHAT IT DOES NOT RUN
# The database suites the planner selects are reported and not executed: they
# run on the project's own CI container image, whose PostgreSQL and PostgREST
# toolchain a stock disposable machine does not carry. The verdict names them
# rather than letting a green line stand for work that never happened.
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
