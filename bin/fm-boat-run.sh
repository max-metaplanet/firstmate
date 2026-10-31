#!/usr/bin/env bash
# fm-boat-run.sh - run one secret-free heavy command on an ephemeral Boat VM.
# Usage:
#   FM_HOME=/absolute/home fm-boat-run.sh run --worktree DIR --output DIR
#       [--input RELATIVE_FILE]... [--artifact RELATIVE_PATH]...
#       [--timeout SECONDS] [--swap-gib 0..4] -- COMMAND [ARGS...]
#   FM_HOME=/absolute/home fm-boat-run.sh reap
# Requires python3 and Boat CLI 1.0.85+ on PATH (FM_BOAT_BIN may name a binary).
# Accounts: optional FM_HOME/config/boat-keys, one key-file path per line,
# followed by optional live_cap=N pending_cap=N daily_cap=N fields.
# Example (paths only, never key values):
#   ~/.config/boat/api-key
#   /absolute/second-account-key live_cap=6 pending_cap=6 daily_cap=170
# Caps are positive integers, defaulting to 2 live, 2 pending, 75 starts/UTC day.
# Paths must be absolute or start with ~; shell quoting, blank lines and # comments
# are supported. Relative/duplicate paths, unknown/duplicate fields, invalid caps
# and an empty or unreadable file are refused. No shell expansion is performed
# except leading ~. Without this file, only ~/.config/boat/api-key is used with
# the original 2 live, 2 pending and 75 daily local start caps.
# Tries accounts in order, skipping full/exhausted/unavailable accounts; returns
# 75 when all accounts lack capacity/budget, 69 if an unavailable account remains.
# Reads the selected key file afresh ONLY into each Boat child's environment.
# Does not forward the invoking environment, account environments, credentials,
# git history, .git, dependency caches, symlinks, or conventional secret files.
# Callers must supply secret-free source, extra inputs, command and artifacts;
# this path filter is not a secret scanner. No secrets-in-VM support exists.
# Source is HEAD's tracked file set with current tracked edits/deletions applied,
# plus individually named --input files (including ignored files if safe).
# Submodules and symlinks are refused rather than silently changing the source.
# Run from the worktree root remotely at /home/user/fm-job/source. Install remote
# dependencies explicitly in COMMAND; native local node_modules never travel.
# --timeout defaults to 1800, range 1..2700; VM TTL is timeout+900 (<=3600).
# --swap-gib defaults to 0; an explicit 1..4 adds that much remote swap using
# passwordless sudo on the disposable VM. It never changes the local host.
# Remote GNU timeout and a host deadline bound execution; output is captured
# in OUTPUT/command.log and printed on completion. Artifacts are copied under
# OUTPUT/artifacts even after command failure. Missing/unsafe artifacts fail.
# OUTPUT must be a new directory outside the source tree. result.json records
# kind, remote_exit, source_head, source_sha256, vm_id and cleanup state.
# A remote exit code is returned unchanged; 124 is the remote command timeout.
# Adapter failures: 2 invalid input, 69 Boat unavailable before execution,
# 75 capacity/start budget exhausted, 74 transfer/transport/result failure,
# 70 cleanup unconfirmed, 128+signal interruption. Local fallback is safe ONLY
# when result.json kind is unavailable; remote commands can also exit 69/75.
# Never wrap this adapter in fm-build-lock.py: remote work consumes no local
# heavy slot. Only a deliberate local fallback goes through that wrapper.
# Budget guard: default 4 CPU/8 GB VMs only, no snapshots. Pending reservations
# and local daily attempts are counted per account in this home; live VM count,
# included-cost eligibility and minute/hour/day starts use that account's key.
# Provider limits enforce account-wide races from other homes/clients.
# The home lock serializes admission/create; uncertain creates are never retried.
# State owner: FM_HOME/state/boat-offload/{jobs/<uuid>.json,daily*.json,*.lock}.
# The default key retains daily.json; other counters use a hash of the key path.
# Each job stores its account key-file path, never its key value. Cleanup/reap
# uses that path even after config changes; legacy records use the default key.
# Keep key files available and do not repoint them until their jobs are deleted.
# Each job is recorded BEFORE create under a unique VM name. IDs and deletion
# operation IDs are persisted as learned. SIGINT/SIGTERM/SIGHUP run cleanup;
# SIGKILL/host loss leave records for reap, and TTL bounds running VM lifetime.
# TTL stops a VM; deletion still needs reap after host loss. Reap touches only
# recorded VMs, skips jobs whose process holds the job lock, and retains failed
# or ambiguous cleanup records. A lost create response is recovered by name
# from a complete --all listing; pagination/incomplete listing fails closed.
# Re-run reap after transient failures; never infer deletion from a stopped VM.
# CLI requests use a mode-700 /tmp/fmb.* HOME, removed in finally, so Boat's
# derived SSH socket path fits the Unix socket limit even in long home paths.
# No login,
# org selection, payment, account configuration or app credentials are changed.
set -euo pipefail
exec python3 "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-boat-run.py" "$@"
