#!/usr/bin/env bash
# fm-boat-test-wrapper.sh - no-mistakes Test command wrapper for secret-free Boat work.
# Usage: FM_HOME=/absolute/home fm-boat-test-wrapper.sh 'bash scripts/pipeline-test.sh'
# Receives exactly ONE command string, with cwd at the pipeline worktree root.
# Runs that string with bash -c; source transfer, environment isolation, timeout,
# capacity, trial guard and cleanup belong to fm-boat-run.sh (see its --help).
# FM_BOAT_TEST_TIMEOUT optionally forwards --timeout SECONDS to that adapter;
# its validation and default still apply. Use 1500 or less on the trial account.
# The command must install its dependencies and have its runtime tools on Boat.
# Never pass secrets in the command or use this wrapper for authenticated tests.
#
# Remote Git is deliberately synthetic: an empty origin/main commit followed
# by a snapshot of ALL adapter-filtered source files. Nothing from local .git
# travels, including history, config, remotes, hooks or credentials. Real Git
# queries from Turbo and Vitest see every uploaded file as changed against
# that empty origin/main. The empty commit is NOT a valid contract baseline:
# PIPELINE_TEST_BASE_REF names a deliberately absent ref so core's Test script
# takes its documented full bounded suite fallback, rather than treating old
# contract violations as newly introduced. No local change-scoping parity is
# claimed. Bootstrap failure fails before tests, never yielding an empty diff.
#
# Evidence is retained in a fresh ../.fm-test-scratch/fm-boat-test.*/boat outside
# the worktree; the adapter prints command output and owns command.log/result.json.
# Only exit 69/75 WITH result kind=unavailable permits local execution, through
# fm-build-lock.py. Completed remote exits (even 69/75) propagate unchanged.
# Every other adapter failure fails loudly with the result.json path; no retry.
# No VM size is selected here; future adapter sizing remains independent.
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
output="$job/boat"
result="$output/result.json"
printf 'boat-test-wrapper: result.json: %s\n' "$result" >&2

# Use real, disposable Git history so downstream tools may issue their own Git
# queries without a pretend-git shim. The adapter has already excluded secrets.
remote=$(cat <<'REMOTE'
set -euo pipefail
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
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

rc=0
adapter_args=(run --worktree "$worktree" --output "$output")
if [[ -n ${FM_BOAT_TEST_TIMEOUT:-} ]]; then
  adapter_args+=(--timeout "$FM_BOAT_TEST_TIMEOUT")
fi
"$bin/fm-boat-run.sh" "${adapter_args[@]}" -- \
  bash -c "$remote" boat-test "$1" || rc=$?

# Validate the result before distinguishing remote exits from adapter exits.
# A cleanup/transport failure may still have kind=completed and remote_exit,
# so matching both exit fields and confirmed cleanup is required for success.
kind=$(python3 - "$result" "$rc" <<'PY'
import json
import sys

try:
    with open(sys.argv[1]) as stream:
        result = json.load(stream)
    code = int(sys.argv[2])
    if (result.get('kind') == 'unavailable' and code in (69, 75)
            and result.get('adapter_exit') == code):
        print('unavailable')
    elif (result.get('kind') == 'completed'
          and type(result.get('remote_exit')) is int
          and result['remote_exit'] == code
          and result.get('adapter_exit') == code
          and result.get('cleanup') == 'deleted'
          and not result.get('error')):
        print('completed')
    else:
        print('adapter-failure')
except (OSError, ValueError, TypeError, AttributeError):
    print('invalid-result')
PY
)

case "$kind" in
  completed) exit "$rc" ;;
  unavailable)
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
