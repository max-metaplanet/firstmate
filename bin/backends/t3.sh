#!/usr/bin/env bash
# T3 native thread backend, opt-in only; never auto-detected.
# Targets are absolute, immutable fm-t3.sh record directories, not UI titles.
# FM_T3_BIN and FM_T3_BASE_DIR select the running host-local T3 at launch;
# subsequent reads/sends use the recorded values, never ambient overrides.
# Only Claude/Codex workers and Claude secondmates are supported. T3 owns
# provider credentials, permissions and launch environment. Explicit Firstmate
# controls the CLI cannot carry fail closed. Interrupt, exit and relaunch have
# no verified API and are refused. Agent process identity stays unverified.
# Native run state, rather than a rendered composer, answers busy/idle.
# Accepted inbox rings are sent once. An uncertain send retains its attempt and
# refuses replay, because the CLI has no idempotency key. Reconcile in T3.

FM_BACKEND_T3_HELPER="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/fm-t3.sh"

fm_backend_t3_preflight() { # <harness> <model> <effort> <kind> <config>
  local harness=$1 model=$2 effort=$3 kind=$4 config=$5 key
  case "$harness:$kind" in
    claude:ship|claude:scout|codex:ship|codex:scout|claude:secondmate) ;;
    *) echo "error: backend=t3 supports Claude/Codex workers and Claude secondmates only" >&2; return 1 ;;
  esac
  [ -n "$model" ] && [ "$model" != default ] || {
    echo 'error: backend=t3 requires an advertised explicit --model' >&2; return 1;
  }
  [ -z "$effort" ] || {
    echo 'error: backend=t3 cannot set effort; omit --effort and use T3 provider defaults' >&2; return 1;
  }
  for key in launch-env-allowlist launch-env-tmux-session crew-exclude-tools \
    "$harness-account" "$harness-seat" claude-permission-mode trace-context lavish-axi-host; do
    if [ -e "$config/$key" ] || [ -L "$config/$key" ]; then
      echo "error: backend=t3 cannot honor config/$key; its provider owns credentials, permissions and environment" >&2
      return 1
    fi
  done
  [ -n "${FM_T3_BASE_DIR:-}" ] && [ -d "$FM_T3_BASE_DIR" ] || {
    echo 'error: backend=t3 requires FM_T3_BASE_DIR for the running T3 data directory' >&2; return 1;
  }
  command -v "${FM_T3_BIN:-t3}" >/dev/null 2>&1 || {
    echo 'error: backend=t3 requires the host-local t3 CLI; set FM_T3_BIN' >&2; return 1;
  }
}

fm_backend_t3_launch() { # <record> <worktree/home> <brief> <title> <harness> <model> <kind>
  local record=$1 worktree=$2 brief=$3 title=$4 harness=$5 model=$6 kind=$7 provider id
  case "$harness" in claude) provider=claudeAgent ;; codex) provider=codex ;; *) return 1 ;; esac
  if [ "$kind" = secondmate ]; then
    [ -f "$worktree/config/supervision-host-off" ] && [ ! -L "$worktree/config/supervision-host-off" ] || {
      echo 'error: T3 secondmates require explicit config/supervision-host-off until the supervision-host path is verified' >&2
      return 1
    }
    id=${record##*/}; id=${id%.t3}
    "$FM_BACKEND_T3_HELPER" launch-secondmate "$record" "$worktree" "$brief" "$title" "$provider" "$model" "$id"
  else
    "$FM_BACKEND_T3_HELPER" launch "$record" "$worktree" "$brief" "$title" "$provider" "$model"
  fi
}

fm_backend_t3_read() { # <record>
  local record=$1 result
  result=$("$FM_BACKEND_T3_HELPER" read "$record") || return 1
  printf '%s' "$result" | jq -e --slurpfile saved "$record/thread.json" '
    (.thread.id // .thread.threadId) == $saved[0].threadId and
    .thread.projectId == $saved[0].projectId' >/dev/null || {
    echo 'error: T3 returned an unexpected thread/project identity; refusing' >&2
    return 1
  }
  printf '%s\n' "$result"
}

fm_backend_t3_capture() { # <record> <lines>
  local result lines=${2:-40}
  case "$lines" in ''|*[!0-9]*|0) return 1 ;; esac
  result=$(fm_backend_t3_read "$1") || return 1
  printf '%s' "$result" | jq -er '
    .thread as $t | "T3 thread \($t.id // $t.threadId) status=\($t.status) activeRunId=\($t.activeRunId // "none")",
    (.messages[]? | "\(.role // .type // "message"): \(.text // .content // "" | if type == "string" then . else tojson end)")' | tail -n "$lines"
}

fm_backend_t3_busy_state() { # <record>
  local result
  result=$(fm_backend_t3_read "$1") || { printf unknown; return 0; }
  printf '%s' "$result" | jq -r '
    if (.thread.activeRunId | type) == "string" or (.thread.pendingRequestCount // 0) > 0 then "busy"
    elif .thread.activeRunId == null and (.thread.status as $s | ["completed","idle","interrupted","failed","cancelled","rolled_back"] | index($s)) != null then "idle"
    else "unknown" end' 2>/dev/null || printf unknown
}

fm_backend_t3_send_text_submit() { # <record> <text> [unused terminal settings...]
  local record=$1 text=$2 attempt rc=0
  case "$text" in /*|\$*)
    echo 'error: T3 thread messages do not execute harness-native slash/skill commands; send ordinary instructions' >&2
    return 1 ;;
  esac
  attempt=$(mktemp -d "$record/send.XXXXXX") || return 1
  printf '%s\n' "$text" > "$attempt/message"
  fm_backend_t3_send_file "$record" "$attempt/message" "$attempt/result.json" || rc=$?
  [ "$rc" = 0 ] || {
    echo "error: T3 send failed or is uncertain; inspect $attempt before any retry" >&2
    return "$rc"
  }
  printf 'empty'
}

fm_backend_t3_send_file() { # <record> <message-file> <result-file>
  "$FM_BACKEND_T3_HELPER" send "$1" "$2" > "$3" || return 1
  jq -e --slurpfile saved "$1/thread.json" '
    .threadId == $saved[0].threadId and
    ([.messageId,.runId,.status] | all(type == "string" and length > 0)) and
    (.delivery == "started" or .delivery == "queued")' "$3" >/dev/null
}

fm_backend_t3_ring() { # <record> <inbox-record> <doorbell>
  local record=$1 inbox=$2 line=$3 attempt
  # One durable attempt per immutable inbox message. Queueing while busy must
  # not cause the watcher's re-ring ladder to duplicate the same instruction.
  mkdir -p "$record/rings" || return 2
  attempt="$record/rings/${inbox##*/}"
  if ! mkdir "$attempt" 2>/dev/null; then
    [ -f "$attempt/accepted" ] && return 0
    return 2
  fi
  printf '%s\n' "$line" > "$attempt/message"
  fm_backend_t3_send_file "$record" "$attempt/message" "$attempt/result.json" || return 2
  touch "$attempt/accepted"
}

fm_backend_t3_unsupported() {
  echo 'error: the T3 CLI does not support interrupt, exit, relaunch or raw terminal keys; use the exact thread controls in T3' >&2
  return 1
}

fm_backend_t3_kill() { # <record>
  local record=$1 binary base project inventory
  [ -f "$record/closed" ] && return 0
  fm_backend_t3_read "$record" >/dev/null || return 1
  binary=$(jq -r .binary "$record/thread.json")
  base=$(jq -r .base "$record/thread.json")
  project=$(jq -r .projectId "$record/thread.json")
  inventory=$("$binary" thread list --project "$project" --base-dir "$base" --json) || return 1
  # This CLI walks all pages. It omits subagents, which belong to their root
  # thread and are removed together. Refuse every additional ordinary thread.
  printf '%s' "$inventory" | jq -e --slurpfile saved "$record/thread.json" '
    type == "array" and length == 1 and
    (.[0].id // .[0].threadId) == $saved[0].threadId and
    .[0].projectId == $saved[0].projectId' >/dev/null || {
    echo 'error: T3 project does not contain exactly the recorded task thread; preserving the project and task record' >&2
    return 1
  }
  printf '%s\n' "$inventory" > "$record/cleanup-inventory.json"
  # Retain diagnostics after an uncertain removal. A later attempt must read
  # the exact live identity again; a failed read never proves deletion.
  "$binary" project remove "$project" --force --base-dir "$base" > "$record/cleanup.txt" || return 1
  touch "$record/closed"
}
