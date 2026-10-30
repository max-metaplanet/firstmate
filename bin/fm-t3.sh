#!/usr/bin/env bash
# fm-t3.sh - durable, opt-in T3 thread identity for the T3 runtime backend.
#
# Usage:
#   fm-t3.sh launch RECORD_DIR WORKTREE BRIEF TITLE PROVIDER MODEL
#   fm-t3.sh launch-secondmate RECORD_DIR HOME BRIEF TITLE PROVIDER MODEL ID
#   fm-t3.sh read RECORD_DIR
#   fm-t3.sh send RECORD_DIR MESSAGE_FILE
#   fm-t3.sh interrupt RECORD_DIR  # unsupported; fails without contacting T3
#
# Requires bash, git, jq and T3 v0.1.5's host-local CLI.
# Set FM_T3_BIN (default: t3) and FM_T3_BASE_DIR (required) at launch.
# The CLI issues/revokes its own local MCP credentials; no token is read here.
# Launch registers the existing linked checkout as a dedicated T3 project and
# starts in its root, with the brief on stdin and the project's permission
# defaults. No worktree is allocated, no service/provider settings are changed.
# Choose an advertised provider/model pair from the running environment. New
# projects may have no default model, so the pair is required. The CLI cannot
# set effort or permission mode. Status/inbox permissions need a live proof.
# RECORD_DIR must not exist. It is reserved BEFORE any T3 mutation and retains
# intent, project output and raw launch JSON, including on failure. Never retry
# an uncertain launch with another record: reconcile in T3 first. CLI launches
# and sends have no exposed idempotency key; sends queue behind a busy turn.
# Read/send use the saved binary and base directory, ignoring ambient overrides.
# Only a successful launch writes thread.json. An incomplete record refuses
# read/send rather than guessing a thread. Do not edit or reuse the record.
# launch-secondmate accepts only a seeded home whose marker matches ID.
# bin/backends/t3.sh owns managed cleanup and backend capabilities; this helper
# never returns a worktree or changes the running service/provider settings.
# Interrupt and exit/relaunch are unsupported by the installed T3 CLI.
set -euo pipefail

usage() { sed -n '2,/^set -/p' "${BASH_SOURCE[0]}" | sed '$d; s/^# \{0,1\}//'; }
die() { printf 'fm-t3: %s\n' "$*" >&2; exit 1; }
[ "$#" -gt 0 ] || { usage >&2; exit 2; }
command=$1
shift
case "$command" in
  -h|--help|help) usage; exit 0 ;;
  interrupt) die 'interrupt is unsupported by the T3 CLI; use the exact thread Stop control in T3' ;;
  launch|launch-secondmate|read|send) ;;
  *) die "unknown command: $command" ;;
esac
command -v jq >/dev/null || die 'jq is required'
# shellcheck source=bin/fm-t3-home-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-t3-home-lib.sh"

if [ "$command" = launch ] || [ "$command" = launch-secondmate ]; then
  if [ "$command" = launch-secondmate ]; then
    [ "$#" -eq 7 ] || die 'launch-secondmate requires RECORD_DIR HOME BRIEF TITLE PROVIDER MODEL ID'
    [ -f "$2/.fm-secondmate-home" ] && [ ! -L "$2/.fm-secondmate-home" ] \
      && [ "$(cat "$2/.fm-secondmate-home")" = "$7" ] || die 'secondmate home marker must match the exact task id'
  else
    [ "$#" -eq 6 ] || die 'launch requires RECORD_DIR WORKTREE BRIEF TITLE PROVIDER MODEL'
  fi
  record=$1
  worktree=$(cd "$2" && pwd -P) || die 'worktree is unavailable'
  brief=$3 title=$4 provider=$5 model=$6
  [ -s "$brief" ] && [ -r "$brief" ] || die 'brief must be a readable nonempty file'
  [ -n "$title" ] || die 'title is required'
  [ -n "$provider" ] && [ -n "$model" ] || die 'provider and model must both be nonempty'
  [ -n "${FM_T3_BASE_DIR:-}" ] || die 'FM_T3_BASE_DIR must name the running T3 data directory'
  base=$(cd "$FM_T3_BASE_DIR" && pwd -P) || die 'T3 base directory is unavailable'
  binary=$(command -v "${FM_T3_BIN:-t3}") || die 'T3 CLI is unavailable; set FM_T3_BIN'
  # Resolve a PATH hit to an absolute name before recording it.
  binary=$(cd "$(dirname "$binary")" && printf '%s/%s' "$(pwd -P)" "$(basename "$binary")")
  top=$(git -C "$worktree" rev-parse --show-toplevel) || die 'worktree is not a git checkout'
  [ "$(cd "$top" && pwd -P)" = "$worktree" ] || die 'worktree must be the checkout root'
  if [ "$command" = launch ]; then
  [ -f "$worktree/.git" ] || die 'refusing primary checkout; supply an allocated linked worktree'
  git_dir=$(git -C "$worktree" rev-parse --git-dir) || die 'invalid linked worktree'
  common_dir=$(git -C "$worktree" rev-parse --git-common-dir) || die 'missing common git directory'
  git_dir=$(cd "$worktree" && cd "$git_dir" && pwd -P) || die 'invalid git directory'
  common_dir=$(cd "$worktree" && cd "$common_dir" && pwd -P) || die 'invalid common git directory'
  [ "$git_dir" != "$common_dir" ] || die 'refusing primary checkout with a separate git directory'
  fi
  if [ "$provider" = claudeAgent ]; then
    fm_t3_bind_claude_home "$worktree" || die 'could not bind Claude native hooks to the exact checkout'
  fi
  umask 077
  mkdir "$record" || die 'record directory already exists or its parent is unavailable; reconcile before retrying'
  jq -n --arg binary "$binary" --arg base "$base" --arg worktree "$worktree" \
    --arg title "$title" --arg provider "$provider" --arg model "$model" \
    '{version:1,binary:$binary,base:$base,worktree:$worktree,title:$title,provider:$provider,model:$model}' > "$record/intent.json"
  if ! "$binary" project add "$worktree" --title "$title" --base-dir "$base" > "$record/project.txt"; then
    die "project registration failed; inspect $record/project.txt; no thread launch attempted"
  fi
  if ! "$binary" thread start "$worktree" - --title "$title" --provider "$provider" --model "$model" \
    --base-dir "$base" --json < "$brief" > "$record/launch.json"; then
    die "thread launch failed or is uncertain; inspect $record/launch.json and reconcile in T3 before retrying"
  fi
  jq -e '(.threadId | type == "string" and length > 0) and (.projectId | type == "string" and length > 0)' \
    "$record/launch.json" >/dev/null || die 'unexpected launch result; reconcile launch.json in T3 before retrying'
  jq -s '.[0] + {threadId:.[1].threadId,projectId:.[1].projectId,runId:.[1].runId}' \
    "$record/intent.json" "$record/launch.json" > "$record/thread.json.new"
  mv "$record/thread.json.new" "$record/thread.json"
  cat "$record/thread.json"
  exit 0
fi

case "$command" in
  read) [ "$#" -eq 1 ] || die 'read requires RECORD_DIR' ;;
  send) [ "$#" -eq 2 ] || die 'send requires RECORD_DIR MESSAGE_FILE' ;;
esac
record=$1
[ -f "$record/thread.json" ] || die 'no completed launch record; reconcile the recorded intent in T3'
jq -e '.version == 1 and ([.binary,.base,.threadId,.projectId] | all(type == "string" and length > 0))' \
  "$record/thread.json" >/dev/null || die 'invalid thread record'
binary=$(jq -r .binary "$record/thread.json")
base=$(jq -r .base "$record/thread.json")
thread=$(jq -r .threadId "$record/thread.json")
case "$command" in
  read) exec "$binary" thread show "$thread" --base-dir "$base" --messages 10 --json ;;
  send)
    [ -s "$2" ] && [ -r "$2" ] || die 'message must be a readable nonempty file'
    exec "$binary" thread send "$thread" - --base-dir "$base" --json < "$2"
    ;;
esac
