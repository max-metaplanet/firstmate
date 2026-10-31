#!/usr/bin/env bash
# fm-boat-run.sh - run one secret-free heavy command on an ephemeral Boat VM.
# Usage:
#   FM_HOME=/absolute/home fm-boat-run.sh run --worktree DIR --output DIR
#       [--input RELATIVE_FILE]... [--artifact RELATIVE_PATH]...
#       [--timeout SECONDS] [--swap-gib 0..4] [--history-depth N] -- COMMAND [ARGS...]
#   FM_HOME=/absolute/home fm-boat-run.sh reap
# Requires python3 and Boat CLI 1.0.85+ on PATH (FM_BOAT_BIN may name a binary).
# Accounts: optional FM_HOME/config/boat-keys, one key-file path per line,
# followed by optional live_cap=N pending_cap=N daily_cap=N environment=NAME
# and cleanup_confirmation=deletion|list fields.
# Example (paths only, never key values):
#   ~/.config/boat/api-key
#   /absolute/second-key live_cap=6 pending_cap=6 daily_cap=170 environment=temp-max-dev cleanup_confirmation=list
# Caps are positive integers, defaulting to 2 live, 2 pending, 75 starts/UTC day.
# environment is an optional nonempty Boat environment name passed to new;
# --no-env remains mandatory. The default leaves environment selection to Boat.
# cleanup_confirmation defaults to deletion (poll the deletion operation).
# Use list for keys that cannot read deletion status: poll a complete VM list
# until the recorded VM disappears, with a 120-second deadline.
# Paths must be absolute or start with ~; shell quoting, blank lines and # comments
# are supported. Relative/duplicate paths, unknown/duplicate fields, invalid caps
# and an empty or unreadable file are refused. No shell expansion is performed
# except leading ~. Without this file, only ~/.config/boat/api-key is used with
# the original 2 live, 2 pending and 75 daily local start caps.
# Tries accounts in order, skipping full/exhausted/unavailable accounts; returns
# 75 when all accounts lack capacity/budget, 69 if an unavailable account remains.
# Reads the selected key file afresh ONLY into each Boat child's environment.
# Does not forward the invoking environment, account environments, credentials,
# local .git metadata, dependency caches, symlinks, or conventional secret files.
# Callers must supply secret-free source, extra inputs, command and artifacts;
# the general path filter is not a secret scanner. No secrets-in-VM support exists.
# Narrow source exceptions: .npmrc, .claude/settings.json,
# .claude/settings.local.json, .claude/settings.example.json, and exactly
# .github/tools/jev/vendor/.claude/agents/security-compliance.md and
# .github/tools/jev/vendor/.claude/agents/release-engineer.md. Each exception
# is scanned as UTF-8 before upload; credential-looking auth/token/password/
# secret keys, bearer strings, private-key headers, credential URLs, common key
# prefixes and binary content keep the file excluded with a content-free warning.
# .npmrc must also contain no auth/token text. The scanned bytes are the bytes
# archived. All other path exclusions remain; ordinary tracked vendor/ trees
# were already eligible and remain subject to the same secret-path filter.
# Source is HEAD's tracked file set with current tracked edits/deletions applied,
# plus individually named --input files (including ignored files if safe).
# No history is sent by default; fm-boat-test-wrapper.sh builds synthetic history.
# --history-depth N (1..1000) opts into real ancestry up to N generations from
# each of HEAD and refs/remotes/origin/main, which must both exist locally.
# Only those two tips, their bounded commits/trees/blobs, shallow boundaries,
# and fresh Git metadata travel. No other refs, stash, reflogs, hooks, local
# remotes or local Git config travel. Current tracked edits/deletions still apply.
# Every historical tree entry must pass the source path filter (including the
# screened exceptions), and every historical blob must pass the same UTF-8
# credential scanner. Excluded paths, configured key paths, symlinks, submodules,
# binary or credential-looking blobs refuse the entire run before any Boat call.
# Refusal logs name the path and reason without printing blob content.
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
# Each job stores its account key-file path and cleanup confirmation mode,
# never its key value. Cleanup/reap
# uses that path even after config changes; legacy records use the default key.
# Keep key files available and do not repoint them until their jobs are deleted.
# Each job is recorded BEFORE create under a unique VM name. IDs and deletion
# operation IDs are persisted as learned. SIGINT/SIGTERM/SIGHUP run cleanup;
# SIGKILL/host loss leave records for reap, and TTL bounds running VM lifetime.
# TTL stops a VM; deletion still needs reap after host loss. Reap touches only
# recorded VMs, skips jobs whose process holds the job lock, and retains failed
# or ambiguous cleanup records. A lost create response is recovered by name
# from a complete --all listing; pagination/incomplete listing fails closed.
# Configured key files are also excluded from source and refused as extra inputs.
# Re-run reap after transient failures; never infer deletion from a stopped VM.
# CLI requests use a mode-700 /tmp/fmb.* HOME, removed in finally, so Boat's
# derived SSH socket path fits the Unix socket limit even in long home paths.
# No login,
# org selection, payment, account configuration or app credentials are changed.
set -euo pipefail
exec python3 "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-boat-run.py" "$@"
