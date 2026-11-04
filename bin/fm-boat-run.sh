#!/usr/bin/env bash
# fm-boat-run.sh - run one secret-free heavy command on Boat, then Upstash Box.
# Usage:
#   FM_HOME=/absolute/home fm-boat-run.sh run --worktree DIR --output DIR
#       [--input RELATIVE_FILE]... [--artifact RELATIVE_PATH]...
#       [--timeout SECONDS] [--swap-gib 0..4]
#       [--history-depth N | --history-input FILE]
#       [--type default|large|xlarge] -- COMMAND [ARGS...]
#   FM_HOME=/absolute/home fm-boat-run.sh reap
#   FM_HOME=/absolute/home fm-boat-run.sh cleanup-task --task ID --generation SPAWN_GEN
#   FM_HOME=/absolute/home fm-boat-run.sh caller-origin --worktree DIR
#   FM_HOME=/absolute/home fm-boat-run.sh check-result --worktree DIR --result FILE --exit CODE
# Caller-origin emits the four-field JSON for no-mistakes --caller-origin-file.
# It requires the spawn producer's frozen FM_TASK_GENERATION. Capture before a
# new run; reattachments omit that flag. Check-result prints completed,
# unavailable or adapter-failure using this same ownership validator.
# Exact worker ownership comes from FM_TASK_ID, frozen FM_TASK_GENERATION,
# and this home's state/ID.meta,
# matching endpoint_task_id, ship/scout kind, spawn_gen and canonical worktree.
# Missing frozen launch context remains create-per-command for legacy callers.
# Explicit stale/foreign context fails closed. Pipeline children use the supported
# no-mistakes axi execution-origin lookup from NO_MISTAKES_EXECUTION_REF and
# NO_MISTAKES_EXECUTION_SOCKET. Protocol 1 must bind a running run's exact
# recorded execution checkout to namespace firstmate and the originating home's
# current task/source/generation. Ambient worker IDs cannot override that binding.
# Revalidate after locking; retained evidence uses this same validator.
# Each home/task
# serializes one durable Boat job slot across worker generations. Compatible
# idle leases reuse the same account, environment, type and swap configuration;
# a changed generation or request requires confirmed deletion before replacement.
# A repointed key file fails closed. Upstash always creates per command.
# Reuse checks remaining compute credit independently of new-start quotas.
# A full minute/hour/day start window does not prevent an owned running lease.
# Each run removes the entire job workspace, uploads screened fresh source,
# and uses fresh HOME/TMPDIR directories. Linux child-subreaper adoption, process
# sessions and an inherited token terminate and reap owned descendants, including
# detached children that clear their environment. Unsupported reset fails before
# user execution and cold-replaces the exact lease with an ephemeral sandbox.
# This is same-task reuse, not a pristine OS. Global packages, files outside the
# job directory and services that clear their process environment can persist.
# Leases expire after 1500 idle seconds, starting only after command completion.
# A per-lease local expiry process uses the same nonblocking lock and confirmed
# deletion owner as reap; it never deletes a locked active command. Host loss
# delays idle deletion until reap. A finite 7200-second provider TTL is the
# absolute lifetime backstop, never extended; calls reserve timeout+1080 seconds
# before reusing it. TTL alone is never evidence of deletion.
# Successful retained commands report cleanup=retained and lease={owner,state,id,
# idle_expires,hard_expires}; only state=idle on an exact owned Boat lease is valid.
# Cleanup=deleted remains actual confirmed deletion. Refused process cleanup
# never permits lease retention. A saved command exit reports kind=completed and
# remote_exit independently of process_cleanup, whose state is confirmed or
# refused. Signal refusals include operation, target PID or PGID, effective_uid
# and errno. A refusal returns adapter exit 74 and requires exact sandbox
# deletion; unconfirmed deletion returns 70. Missing command-result evidence
# remains execution-unknown, even if deletion succeeds. Known completion and
# unknown execution never permit duplicate execution.
# Failed pre-command preparation on a reused
# owned lease permits one replacement only after confirmed deletion, preserving
# exact origin for transfer failures. Unsupported reset forces an ephemeral
# replacement. Boat then optional Upstash admission precedes the caller's
# permitted local fallback. Cleanup-task refuses active holders,
# records a generation-closing tombstone, and deletes only that exact lease.
# Reap preserves valid idle owned leases and recovers expired/abandoned records.
# Requires python3 and Boat CLI 1.0.85+ on PATH (FM_BOAT_BIN may name a binary).
# Optional Upstash fallback requires upstash-box==0.4.0 in that Python and
# ~/.config/upstash/box-api-key, readable only by its owner (mode 0600).
# Reproducible instance-local SDK setup (no global interpreter changes):
#   python3 -m venv "$FM_HOME/state/boat-offload/upstash-sdk-0.4.0"
#   "$FM_HOME/state/boat-offload/upstash-sdk-0.4.0/bin/python3" -m pip install \
#       --index-url https://pypi.org/simple upstash-box==0.4.0
# This entry point automatically uses that interpreter when installed, so
# existing worker commands need no changes. Otherwise it uses python3 on PATH.
# The key file's presence enables fallback after all eligible Boat accounts
# decline before create. Missing key preserves the original Boat refusal.
# Uses the declared free account only: small ephemeral boxes (2 CPU, 4 GB RAM,
# 10 GB disk), no agent, snapshots, keep-alive, paid sizes or plan changes.
# This is reduced capacity versus Boat default. Explicit large/xlarge or swap
# requests cannot fall back to Upstash small. Source archives over 100 MB
# also cannot use Upstash. Smaller archives travel in sequential 8 MiB files
# through the official SDK, then are reassembled before SHA256 verification.
# The service has rejected files below its documented 100 MB per-file limit.
# Each piece and reassembly use the remaining size-aware push budget.
# Account list and environment reads consume no sandbox compute. Nonempty
# account environments fail closed, never get cleared or logged. Published
# free limits are 10 concurrent boxes and 5 CPU core-hours/month. The SDK
# exposes no account plan/remaining-CPU endpoint; these are published defaults,
# not observed account headroom. The provider enforces account-wide limits.
# Under the existing admission lock, this home reserves 2*(TTL+180) CPU seconds
# before each Upstash create, up to 5 hours/UTC month. Confirmed create rejection
# refunds that reservation; early deletion and unknown outcomes do not.
# A run that could cross a UTC month boundary declines until the new month.
# That conservative local reservation is not measured provider usage and does
# not include other homes/clients. It never authorizes paid overage.
# Upstash creates once with TTL=timeout+900, records provider/key-path/name/id,
# and confirms deletion by a complete list; reap recovers only recorded names
# and labels. Unknown creates/execution never trigger another provider/local
# command, even after successful cleanup. Provider rejection HTTP 402/429
# means budget/capacity unavailable; 401/403 means credential unavailable.
# Other create failures are unknown allocations, retained for cleanup/reap.
# Explicit upload rejections (HTTP 400/401/402/403/404/413/415/422/429) return
# unavailable only after a known create and confirmed deletion, before the user
# command is submitted. Unknown upload responses, secret/screening refusals,
# unknown create/execution and unconfirmed deletion never gain this permission.
# Local fallback remains entirely the caller's policy after both remotes
# report unavailable. Result fields are unchanged, with additive provider,
# requested_type, actual_size and Upstash resources evidence.
# SDK reference: https://github.com/upstash/box/tree/main/packages/python-sdk
# Limits: https://upstash.com/pricing/box
# Ephemeral TTL maximum is 259200 seconds; this adapter uses at most 3600.
# Accounts: optional FM_HOME/config/boat-keys, one key-file path per line,
# followed by optional live_cap=N pending_cap=N daily_cap=N environment=NAME
# cleanup_confirmation=deletion|list and types=TYPE[,TYPE...] fields.
# Example (paths only, never key values):
#   ~/.config/boat/api-key
#   /absolute/second-key live_cap=6 pending_cap=6 daily_cap=170 environment=temp-max-dev cleanup_confirmation=list types=default,large,xlarge
# Caps are positive integers, defaulting to 2 live, 2 pending, 75 starts/UTC day.
# types is a comma-separated list of permitted Boat machine types:
# default (4 CPU/8 GB), large (8 CPU/16 GB), xlarge (16 CPU/32 GB).
# Empty, unknown and duplicate types are refused. Absent types means only default.
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
# local .git metadata, dependency caches, working-tree symlinks, or conventional secret files.
# Callers must supply secret-free source, extra inputs, command and artifacts;
# the general path filter is not a secret scanner. No secrets-in-VM support exists.
# Narrow source exceptions: .npmrc, .claude/settings.json,
# .claude/settings.local.json, .claude/settings.example.json,
# .claude/commands/reimage-dev.md, and exactly
# .github/tools/jev/vendor/.claude/agents/security-compliance.md and
# .github/tools/jev/vendor/.claude/agents/release-engineer.md. Each exception
# is scanned as UTF-8 before upload; credential-looking auth/token/password/
# secret keys, credential-like bearer strings, private-key headers, credential URLs, common key
# prefixes and binary content keep the file excluded with a content-free warning.
# The bearer check permits case-insensitive prose "bearer decisions" and
# "bearer shares" when the noun is followed by whitespace or end of text,
# optionally preceded by one period, comma, semicolon or colon.
# .npmrc must also contain no auth/token text. The scanned bytes are the bytes
# archived. All other path exclusions remain; ordinary tracked vendor/ trees
# were already eligible and remain subject to the same secret-path filter.
# Source is HEAD's tracked file set plus staged additions, with current working-tree
# edits/deletions applied, plus individually named --input files (including ignored files if safe).
# No history is sent by default; fm-boat-test-wrapper.sh builds synthetic history.
# --history-depth N (1..1000) opts into real ancestry at Git fetch depth N from
# each of HEAD and refs/remotes/origin/main, counting each tip as depth one.
# Both tips must exist locally.
# Only those two tips, their bounded commits/trees/blobs, shallow boundaries,
# and fresh Git metadata travel. No other refs, stash, reflogs, hooks or local
# Git config travel, and the only remote declared is the promisor marker below.
# Current tracked edits/deletions still apply.
# A commit's bytes are its identity, so it cannot be withheld and its scan is
# the one that cannot afford a false positive: a commit, with its headers and
# message, discards the history attempt when it is not UTF-8,
# contains binary content, a credential-key assignment using =, a screened
# bearer token, or an issued credential (private-key block or provider key).
# Command names such as secrets:scan and quoted example URLs remain prose.
# A blob is exempt from the content scan only when its exact bytes are already
# in the uploaded source archive, after every path, key-file and content rule
# above has decided what that archive carries. Every other blob, including
# HEAD's copy of a file the working tree edits, deletes, excludes or screens
# out, is screened with the full credential scanner and on a hit is withheld.
# An object at an excluded or configured-key path, and a historical submodule
# entry, are withheld the same way.
# Source and history skip tracked relative symlinks that stay lexically inside
# the repository, with one stderr notice per path. Target text must pass the
# UTF-8 credential scanner. History retains that screened blob in its Git pack,
# but no working-tree symlink is uploaded; tests reading through it cannot use it.
# Submodules in uploaded source, absolute or escaping symlink targets, and
# symlink parent components are refused.
# A withheld object keeps its tree entry, so every commit, tree, ancestry, name
# and date stays what the project's own tooling reads and `git fsck` stays
# clean: the pack is marked promisor, as `git clone --filter=blob:none` marks
# its own, and the promisor remote fm-boat-withheld carries no URL, so reading
# a withheld object's content fails loudly rather than silently. That marking
# needs a remote Git supporting the partial-clone extension; an older one
# refuses the repository outright instead of reading it wrong.
# A history screen refusal falls back to the screened current-source snapshot
# with no historical objects. A notice and result evidence name the reason
# and path or commit ID, never content. Missing origin/main and other Git errors
# still fail the run. Current-source screening and refusal behavior is unchanged.
# --history-input FILE instead selects pinned, complete, screened snapshots.
# Its JSON object has exactly these fields (schema is literal; SHAs are full
# lowercase object IDs for this checkout's object format):
#   {"schema":"fm-boat-history.v1","source":"/absolute/complete/repository",
#    "head":"HEAD_SHA","head_ref":"refs/heads/feature",
#    "refs":{"refs/remotes/origin/main":{"ref":"refs/heads/main","oid":"BASE_SHA"}},
#    "depth":2,"objects":[{"commit":"OLD_SHA","path":"file.txt","oid":"BLOB_SHA"}],
#    "templates":[".env.example"]}
# source is a canonical absolute local repository or HTTPS Git URL without
# userinfo, query, fragment or whitespace. Host Git may use its existing auth;
# no credential, URL, manifest or host Git config enters the remote repository.
# The manifest itself is never implicitly selected as a source file. Keep it
# outside the worktree when it is not intended as source.
# head must match this worktree's HEAD. head_ref and each refs entry name a
# source branch; received identities must match the pins, even if an older
# pinned commit remains available. refs must include refs/remotes/origin/main;
# up to 16 origin tracking refs are supported. depth retains the 1..1000 bound.
# Up to 64 exact commit/path/blob pins select historical snapshots at depth one,
# independent of their distance from HEAD. Fresh fm-boat-input-<SHA> branches
# retain these snapshots through a preflight's ordinary shallow clone.
# fm-boat-ref-<SHA> branches likewise retain the pinned base/ref tips, since a
# clone does not copy its source's remote-tracking refs. Whole
# selected trees travel because ordinary Git clones require their full closure;
# unrelated refs and intervening ancestry do not travel.
# Every selected commit and non-source blob passes the existing content screen.
# An excluded, screened, unavailable or unsupported object in ANY selected tree
# refuses the input before allocation, with no synthetic or local fallback.
# Select only required safe snapshots. A true secret must stay local.
# templates explicitly admits up to 64 .env.example or .env.template paths,
# under otherwise permitted directories. Each working/historical version must
# contain only blank lines, screened comments and shell-style KEY= assignments
# with empty values (also '' or ""). Populated values, binary content, credential
# text in comments, other .env names and configured key paths remain refused.
# Template bytes and Git identities are preserved, never rewritten or redacted.
# Host history reads disable Git lazy fetch. A promisor checkout needing objects
# must name an explicit complete source; fetching hydrates only new output
# scratch. Each Git call has a 120-second deadline, does not prompt, and disables
# hooks and automatic maintenance. A changed/unavailable source is an input
# error, never provider-unavailable evidence and never permission to execute locally.
# result.json history_input records the manifest SHA256, source identity, pinned
# head/refs/objects, depth and template paths; source_sha256 binds the archive.
# This provides Git inputs for secret-free queue-preflight --no-fetch commands;
# authenticated guards still need their existing local path. It does not certify
# product guard parity or excuse missing inputs. Use sufficient ancestry for the
# selected tips' merge base. A shallow boundary cannot prove older ancestry.
# Logs name the withheld count and one path, never blob or commit content.
# Run from the worktree root remotely at /home/user/fm-job/source on either
# provider, preserving existing absolute command paths. Install remote
# dependencies explicitly in COMMAND; native local node_modules never travel.
# Upstash prepares writable /home/user and fm-job with root or passwordless
# sudo -n install. Failure to prepare them is a setup error, never unavailable.
# --timeout defaults to 1800, range 1..2700; ephemeral TTL is timeout+900
# (<=3600). Owned Boat leases use the absolute 7200-second TTL above.
# --type defaults to default and passes Boat's machine type names unchanged.
# Only accounts permitting that type are considered; no permitting account is
# invalid input (exit 2), with no create or silent downgrade.
# fm-boat-test-wrapper.sh forwards FM_BOAT_TYPE as this flag when set.
# --swap-gib defaults to 0; an explicit 1..4 adds that much remote swap using
# passwordless sudo on the disposable VM. It never changes the local host.
# Remote GNU timeout and a host deadline bound execution; output is captured
# in OUTPUT/command.log and printed on completion. Artifacts are copied under
# OUTPUT/artifacts even after command failure. Missing/unsafe artifacts fail.
# Boat copies the prepared source.tar.gz with native single-file scp, without
# Git directory selection or another tar stream. Exact size and SHA256 verification
# precedes extraction and execution. Transfer allows 90 seconds plus the archive
# size at 128 KiB/s, with a 300-second minimum and a 600-second maximum
# within the existing VM TTL margin.
# This deadline is independent of --timeout, which bounds the remote command.
# An scp timeout on a current owned Boat lease can proceed only when the same
# bounded verification confirms the complete archive before extraction.
# Fresh lease failures never allocate another sandbox; unknown user-command
# outcomes never retry. Recovery does not extend the transfer deadline or TTL.
# OUTPUT must be a new directory outside the source tree. result.json records
# kind, remote_exit, source_head, source_sha256, vm_id and cleanup state, plus
# history=synthetic|screened|fallback-synthetic and history_reason on fallback.
# upload_bytes and push_timeout_seconds record the transfer budget.
# upload_recovered=true records successful archive verification after scp timeout.
# Unavailable request errors name timeout, OS error or bad response and the exception class,
# without exception messages or output that could contain credentials.
# A remote exit code is returned unchanged; 124 is the remote command timeout.
# Adapter failures: 2 invalid input, 69 remote unavailable before execution,
# 75 capacity/start budget exhausted, 74 transfer/transport/result failure,
# 70 cleanup unconfirmed, 128+signal interruption. Local fallback is safe ONLY
# when result.json kind is unavailable; remote commands can also exit 69/75.
# Never wrap this adapter in fm-build-lock.py: remote work consumes no local
# heavy slot. Only a deliberate local fallback goes through that wrapper.
# Budget guard: only explicitly permitted machine types, no snapshots. Pending reservations
# and local daily attempts are counted per account in this home; live VM count,
# included-cost eligibility and minute/hour/day starts use that account's key.
# Provider limits enforce account-wide races from other homes/clients.
# The home lock serializes admission/create; uncertain creates are never retried.
# State owner: FM_HOME/state/boat-offload/{jobs/<uuid>|task-<hash>.json,daily*.json,*.lock}.
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
python=python3
if [[ ${FM_HOME:-} == /* && -x "$FM_HOME/state/boat-offload/upstash-sdk-0.4.0/bin/python3" ]]; then
  python="$FM_HOME/state/boat-offload/upstash-sdk-0.4.0/bin/python3"
fi
exec "$python" "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-boat-run.py" "$@"
