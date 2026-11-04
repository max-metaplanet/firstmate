#!/usr/bin/env bash
# fm-boat-test-wrapper.sh - no-mistakes Test wrapper for secret-free remote work.
# Usage: FM_HOME=/absolute/home fm-boat-test-wrapper.sh 'bash scripts/pipeline-test.sh'
# Receives exactly ONE command string, with cwd at the pipeline worktree root.
# Runs that string with bash -c; source transfer, environment isolation, timeout,
# capacity, trial guard and cleanup belong to fm-boat-run.sh (see its --help).
# FM_BOAT_TEST_TIMEOUT optionally forwards --timeout SECONDS to that adapter;
# its validation and default still apply. Use 1500 or less on the trial account.
# FM_BOAT_TEST_HISTORY_DEPTH optionally forwards --history-depth N (1..1000).
# FM_BOAT_TEST_HISTORY_INPUT forwards --history-input FILE instead of depth.
# The adapter owns selected-history screening and refusal; see fm-boat-run.sh --help.
# FM_BOAT_TYPE optionally forwards --type to the adapter; its default is default.
# FM_BOAT_REUSE_ONLY=1 forwards --reuse-only and forbids local fallback.
# The selected account must permit that type in config/boat-keys.
# The command must install its dependencies and have its runtime tools remotely.
# Never pass secrets in the command or use this wrapper for authenticated tests.
#
# By default remote Git is synthetic: an empty origin/main commit followed
# by a snapshot of ALL adapter-filtered source files. Nothing from local .git
# travels, including history, config, remotes, hooks or credentials. Real Git
# queries from Turbo and Vitest see every uploaded file as changed against
# that empty origin/main. The empty commit is NOT a valid contract baseline:
# PIPELINE_TEST_BASE_REF names a deliberately absent ref so core's Test script
# takes its documented full bounded suite fallback, rather than treating old
# contract violations as newly introduced. No local change-scoping parity is
# claimed. Bootstrap failure fails before tests, never yielding an empty diff.
# With either history option, the adapter supplies screened real Git history;
# PIPELINE_TEST_BASE_REF then names refs/remotes/origin/main.
# Selected-history failures stop locally before provider calls or command
# execution, without synthetic bootstrap or local fallback.
#
# Evidence is retained in a fresh ../.fm-test-scratch/fm-boat-test.*/boat* outside
# the worktree; the adapter prints command output and owns command.log/result.json.
# Only exit 69/75 WITH result kind=unavailable permits local execution, through
# fm-build-lock.py, unless FM_BOAT_TEST_LOCAL_FALLBACK=0 selects remote-only mode.
# The adapter tries Boat then optional Upstash before returning unavailable;
# that remote-only setting allows either provider and still forbids local work.
# Unset or any other value preserves local fallback on unavailability unless
# FM_BOAT_REUSE_ONLY=1 applies.
# Remote-only mode retries unavailable results with fresh evidence per attempt.
# FM_BOAT_TEST_UNAVAILABLE_WAIT_SECS bounds elapsed time allowed for retries
# (default 1800, nonnegative integer); an in-flight adapter may exceed the bound.
# FM_BOAT_TEST_UNAVAILABLE_RETRY_SECS sets the backoff (default 60, positive
# integer), capped to the remaining wait. These settings apply only in remote-only
# mode. Exhaustion fails with the last unavailable exit, attempts and result path.
# FM_BOAT_TEST_TIMEOUT still applies per attempt, including the trial limit above.
# Completed remote exits (even 69/75) propagate unchanged and are never retried.
# Every other adapter failure fails loudly with the result.json path; no retry.
#
# Enable ONLY after the no-mistakes fork supports commands.test.wrapper and
# the account upgrade/spending authorization is confirmed. In the machine-local
# no-mistakes global config, under core's canonical repository remote key:
#   repository_overrides:
#     github.com/metaplanet-jp/core:
#       commands:
#         test:
#           wrapper: /absolute/firstmate/bin/fm-boat-test-wrapper.sh
# Keep core's configured Test command as bash scripts/pipeline-test.sh.
# This script neither enables the setting nor changes the adapter's trial guard.
set -euo pipefail

if [[ ${1:-} == --help || ${1:-} == -h ]]; then
  sed -n '2,/^set -euo pipefail/{ /^set -euo pipefail/d; s/^# \{0,1\}//; p; }' "${BASH_SOURCE[0]}"
  exit 0
fi
if [[ $# != 1 || -z ${1//[[:space:]]/} ]]; then
  echo 'boat-test-wrapper: expected exactly one nonempty Test command string' >&2
  exit 2
fi

bin=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
worktree=$(pwd -P)
scratch="$worktree/../.fm-test-scratch"
mkdir -p "$scratch"
scratch=$(cd "$scratch" && pwd -P)
job=$(mktemp -d "$scratch/fm-boat-test.XXXXXX")
unavailable_wait=1800
retry_secs=60
if [[ ${FM_BOAT_TEST_LOCAL_FALLBACK:-} == 0 ]]; then
  unavailable_wait=${FM_BOAT_TEST_UNAVAILABLE_WAIT_SECS:-1800}
  retry_secs=${FM_BOAT_TEST_UNAVAILABLE_RETRY_SECS:-60}
  if [[ ! $unavailable_wait =~ ^(0|[1-9][0-9]*)$ ||
        ! $retry_secs =~ ^[1-9][0-9]*$ ]]; then
    echo 'boat-test-wrapper: unavailable wait must be a nonnegative integer and retry interval a positive integer' >&2
    exit 2
  fi
fi

# Use real, disposable Git history so downstream tools may issue their own Git
# queries without a pretend-git shim. The adapter has already excluded secrets.
remote=$(cat <<'REMOTE'
set -euo pipefail
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
if [ -d .git ]; then
  export PIPELINE_TEST_BASE_REF=refs/remotes/origin/main
  echo 'boat-test-wrapper: screened shallow Git history; using origin/main base' >&2
  exec bash -c "$1"
fi
export GIT_AUTHOR_NAME=Boat-test GIT_COMMITTER_NAME=Boat-test
export GIT_AUTHOR_EMAIL=boat-test@example.invalid GIT_COMMITTER_EMAIL=boat-test@example.invalid
export GIT_AUTHOR_DATE=2000-01-01T00:00:00Z GIT_COMMITTER_DATE=2000-01-01T00:00:00Z
git init --quiet
empty=$(git mktree </dev/null)
base=$(printf 'Empty conservative test base\n' | git commit-tree "$empty")
git add --all --force -- .
tree=$(git write-tree)
head=$(printf 'Adapter-filtered test source\n' | git commit-tree "$tree" -p "$base")
git update-ref refs/heads/fm-boat-test "$head"
git symbolic-ref HEAD refs/heads/fm-boat-test
git update-ref refs/remotes/origin/main "$base"
export PIPELINE_TEST_BASE_REF=refs/fm-boat/no-local-history
unset GIT_AUTHOR_NAME GIT_COMMITTER_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_EMAIL
unset GIT_AUTHOR_DATE GIT_COMMITTER_DATE
echo 'boat-test-wrapper: synthetic empty Git base; real base unavailable, using core full-suite fallback' >&2
exec bash -c "$1"
REMOTE
)

adapter_args=(run --worktree "$worktree")
if [[ ${FM_BOAT_REUSE_ONLY:-} == 1 ]]; then
  adapter_args+=(--reuse-only)
fi
if [[ -n ${FM_BOAT_TEST_TIMEOUT:-} ]]; then
  adapter_args+=(--timeout "$FM_BOAT_TEST_TIMEOUT")
fi
if [[ -n ${FM_BOAT_TEST_HISTORY_DEPTH:-} ]]; then
  adapter_args+=(--history-depth "$FM_BOAT_TEST_HISTORY_DEPTH")
fi
if [[ -n ${FM_BOAT_TEST_HISTORY_INPUT:-} ]]; then
  adapter_args+=(--history-input "$FM_BOAT_TEST_HISTORY_INPUT")
fi
if [[ -n ${FM_BOAT_TYPE:-} ]]; then
  adapter_args+=(--type "$FM_BOAT_TYPE")
fi
attempts=0
deadline=$((SECONDS + unavailable_wait))
while :; do
  attempts=$((attempts + 1))
  output="$job/boat-$attempts"
  result="$output/result.json"
  printf 'boat-test-wrapper: result.json: %s\n' "$result" >&2
  rc=0
  "$bin/fm-boat-run.sh" "${adapter_args[@]}" --output "$output" -- \
    bash -c "$remote" boat-test "$1" || rc=$?

  # Validate the result before distinguishing remote exits from adapter exits.
  # A cleanup/transport failure may still have kind=completed and remote_exit,
  # so matching both exit fields and confirmed cleanup is required for success.
  kind=$("$bin/fm-boat-run.sh" check-result --worktree "$worktree" \
    --result "$result" --exit "$rc") || kind=invalid-result

  case "$kind" in
    completed) exit "$rc" ;;
    unavailable)
      if [[ ${FM_BOAT_REUSE_ONLY:-} == 1 ]]; then
        printf 'boat-test-wrapper: reuse-only forbids local fallback; result.json: %s\n' "$result" >&2
        exit "$rc"
      fi
      if [[ ${FM_BOAT_TEST_LOCAL_FALLBACK:-} == 0 ]]; then
        remaining=$((deadline - SECONDS))
        if (( remaining > 0 )); then
          delay=$retry_secs
          if (( delay > remaining )); then delay=$remaining; fi
          sleep "$delay"
          remaining=$((deadline - SECONDS))
        fi
        if (( remaining <= 0 )); then
          printf 'boat-test-wrapper: Boat unavailable after %s attempts; Test failed; result.json: %s\n' "$attempts" "$result" >&2
          exit "$rc"
        fi
        continue
      fi
      printf 'boat-test-wrapper: Boat unavailable (exit %s); running locally through heavy build lock; result.json: %s\n' "$rc" "$result" >&2
      exec python3 "$bin/fm-build-lock.py" -- bash -c "$1"
      ;;
    *)
      printf 'boat-test-wrapper: adapter failure (exit %s, %s); Test failed; result.json: %s\n' "$rc" "$kind" "$result" >&2
      # Missing/inconsistent success evidence must never become a passing Test.
      if [[ $rc == 0 ]]; then rc=74; fi
      exit "$rc"
      ;;
  esac
done
