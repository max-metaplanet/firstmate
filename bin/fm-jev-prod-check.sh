#!/usr/bin/env bash
# fm-jev-prod-check.sh - opt-in poll for a project's PRODUCTION Jev browser
# verdicts on PRs that have already merged.
#
# Usage:
#   fm-jev-prod-check.sh [check]
#   fm-jev-prod-check.sh arm
#   fm-jev-prod-check.sh reseed
#   fm-jev-prod-check.sh disarm
#   fm-jev-prod-check.sh --help
#
# WHY THIS EXISTS. core's `jev-check.yml` drives a real browser over a pull
# request twice: once against its Vercel preview before the merge, and once
# against production after the production deployment. The pre-merge verdict
# reaches whoever is still working the PR. The post-merge one does not: by the
# time production has deployed and the check has run, the worker that shipped the
# PR has been torn down, so nobody reads the verdict that describes what users
# actually got. This poll is the reader.
#
# WHAT IT IS. One more member of the watcher's existing check family: `arm`
# writes `state/jev-prod-monitor.check.sh`, `bin/fm-check-register.sh` binds its
# bytes, and the watcher runs it on its own FM_CHECK_INTERVAL cadence and turns
# any line it prints into a `check:` wake. No daemon, no schedule of its own, and
# no second cadence to reason about. It prints a line ONLY when firstmate should
# act, and nothing at all otherwise.
#
# IT DECIDES NOTHING. The routing - the ClickUp note, the follow-up ticket, the
# captain call - is firstmate's, and the `bearings` skill's "Jev production
# verdict follow-up" section owns what firstmate does per class. This script
# reads GitHub, classifies, and wakes. It never writes to a forge, never touches
# ClickUp, and never needs a database credential.
#
# WHERE THE TWO VERDICTS COME FROM, and why it takes two sources. Upstream's
# recorder keeps ONE comment per PR and core's `record.mjs` gives it a section
# per app, which it REPLACES on every write. So the production run overwrites the
# preview section for that app: the live comment yields the current verdict and
# its phase, never both phases at once. The preview verdict for a merged PR
# survives only in the pre-merge run's uploaded `jev-check-records` artifact.
# The comment is read first. Artifacts bind a result to its workflow run and
# attempt when available, and recover preview evidence for nonpassing outcomes.
#
# EVERYTHING IT READS IS UNTRUSTED. A pull request comment can be written by
# anybody who can comment on the pull request, and an artifact is whatever a
# workflow run uploaded. So the marker comment counts only when the RECORDER
# posted it - a comment carrying the marker under any other author is not a
# verdict and is ignored, which is what stops somebody pre-empting the real
# verdict by posting their own - and every field lifted out of a comment or an
# artifact is accepted only as a bounded token. A value outside its shape is
# "not established", never a verdict, and never a line this prints: the wake is
# one line and the record is tab-separated, so an unchecked newline or tab would
# be a way to write extra records through content somebody else controls.
# Decompression is bounded too, because an artifact's compressed size says
# nothing about what it expands to.
#
# THE COMMENT SHAPE IS NOT GUESSED. It is upstream's `render()` plus core's
# section wrapper, both vendored at a pin with their own tests. A section that
# does not parse is `couldnt-check`, never clean - this check's one hard rule is
# that silence always means "nothing to report", never "nothing went wrong".
#
# COST. Absent configuration this does nothing at all: no process is started, no
# forge is contacted, and `arm` refuses rather than registering a check with no
# repository to watch. Configured, one poll spends at most FM_JEV_PROD_BUDGET
# seconds (default 20, cut down to the watcher's own per-check bound) over at
# most FM_JEV_PROD_MAX_PRS pull requests. A pull request the budget did not
# reach, or ran out in the middle of after an earlier one had spent part of it,
# is examined first on the next poll; that is deferral, not a failure, and it
# reports nothing: a read the budget cut short is not evidence about a verdict,
# so it is never queued or recorded as woken. A pull request that exhausts a
# whole fresh budget on its own is couldnt-check instead, and the rotation moves
# past it, so no single slow pull request can hold the monitor in place.
#
# DEDUPE. state/.jev-prod-monitor is the one owner. A verdict is keyed by
# <pr>/<app[:persona]>/<record-id-or-outcome-run>. The recorder digest or a
# verified workflow run and attempt identifies the outcome, so a re-poll of an already-woken PR+run prints nothing. The key
# is deliberately per RUN and not per pull request: production can be deployed
# again - a rollback, a promotion - and that fires a fresh post-merge run with a
# fresh verdict, which has to be able to wake even though the pull request has
# been seen before. So no pull request is ever retired early; a candidate leaves
# the set by ageing out of the lookback, and within the set the keys are what
# keep each verdict to one wake.
#
# RESEED. Explicit `reseed` backs up the current record to a private sibling
# `.jev-prod-monitor.backup.XXXXXX` before reading the current candidate inventory.
# It seeds only known post-merge recorder outcomes on the PR head, without wakes,
# and drops old pending batches and historical keys rather than splitting glued
# rows or claiming they were delivered. Unknown current outcomes remain unseeded.
# Incomplete forge reads or an exhausted budget retain the original state.
# Run it after updating the monitor with FM_HOME set to the intended home.
# It uses the same lookback and single-page inventory as `check`, and must
# finish every candidate in that inventory before replacing the state. A full
# 50-PR page warns that older candidates may be missing; reseed does not paginate.
# Its manual read budget is FM_JEV_PROD_BUDGET (default 120 seconds, capped at
# 300), independent of FM_CHECK_TIMEOUT. Each forge read remains capped at 5s.
# Not-applicable outcomes retain their reason in `outcome` rows and never claim
# a browser pass. When run metadata is unavailable, a recorded digest or section
# fingerprint is the fallback identity; malformed sections also use the comment
# revision. A fallback later enriched with a run ID is not delivered twice.
#
# ROTATION. Because candidates are not retired, a busy repository can hold more
# of them than one poll should read. They are therefore rotated by a cursor in
# the same record: the last pull request a poll actually examined. The next poll
# starts right after it, newest merge first, so a window the budget cut short is
# finished on the very next poll and every candidate is reached within a few
# polls instead of the newest few monopolising the budget forever. A cursor that
# has aged out of the lookback starts the rotation over at the newest merge.
#
# URGENCY. A regression - preview proven, production not - wakes on the poll that
# finds it. `still-flagged` and `couldnt-check` accumulate and go out as one line
# once the oldest has waited FM_JEV_PROD_BATCH_SECS (default 21600, six hours).
# A regression never waits behind a batch, and a batch never delays a regression:
# when both are ready the regression goes first and the batch goes on the next
# poll, so every wake is one coherent line.
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}/jev-prod-monitor"
RECORD="$STATE/.jev-prod-monitor"
RECORD_SCHEMA=fm-jev-prod-monitor-v1
CHECK_ID=jev-prod-monitor
MAX_LINE=1000
WOKEN_KEEP=500

# The recorder's own marker and section wrappers. These are upstream's and
# core's literal bytes; they are matched, never composed.
MARKER='<!-- jev-check-browser-v1 -->'
# Who the recorder posts as. core names this identity explicitly rather than
# looking it up (`JEV_CHECK_LOGIN`), because an installation token cannot read
# GET /user; this is the same default, overridable for a project that renamed it.
RECORDER_LOGIN_DEFAULT='github-actions[bot]'
# The verdicts upstream's recorder can publish. Anything else is not a verdict.
VERDICT_SHAPE='^(proven|failed|unproven|skipped|stale|not-applicable|refused|unverified)$'
RESEED=0
RECORD_OUTCOMES=
# An artifact entry is read through a byte cap: a compressed size says nothing
# about what it expands to.
UNZIP_MAX_BYTES=262144

# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-line-cap-lib.sh
. "$SCRIPT_DIR/fm-line-cap-lib.sh"
# shellcheck source=bin/fm-check-lib.sh
. "$SCRIPT_DIR/fm-check-lib.sh"
# shellcheck source=bin/fm-check-shim-lib.sh
. "$SCRIPT_DIR/fm-check-shim-lib.sh"

usage() {
  cat <<'EOF'
Usage:
  fm-jev-prod-check.sh [check]   read this project's merged pull requests once
                                  and print one line only when a production Jev
                                  verdict needs firstmate (silent when
                                  unconfigured, unchanged, or all clean)
  fm-jev-prod-check.sh arm       write and register state/jev-prod-monitor.check.sh
  fm-jev-prod-check.sh reseed    back up the dedupe record, then seed current known
                                  post-merge outcomes without delivering them
  fm-jev-prod-check.sh disarm    remove the check shim, its trust binding, and
                                  the dedupe record
  fm-jev-prod-check.sh --help    print this help

Configuration is opt-in: config/jev-prod-monitor (local, gitignored) names the
repository to watch. An unconfigured home runs no check and spends nothing.
docs/configuration.md owns the schema; the `bearings` skill's "Jev production
verdict follow-up" section owns what firstmate does with each class.
Manual reseed uses FM_JEV_PROD_BUDGET (default 120 seconds, maximum 300),
independent of the watcher timeout, with each forge read bounded to 5 seconds.
EOF
}

die_usage() {
  printf 'fm-jev-prod-check: %s\n' "$1" >&2
  usage >&2
  exit 2
}

NOW=${FM_JEV_PROD_NOW:-$(date +%s)}
case "$NOW" in ''|*[!0-9]*) NOW=$(date +%s) ;; esac

BATCH_SECS=${FM_JEV_PROD_BATCH_SECS:-21600}
case "$BATCH_SECS" in ''|*[!0-9]*) BATCH_SECS=21600 ;; esac

# The grace starts at the successful supported production deployment status,
# never at the merge or a generic commit status.
GRACE_SECS=${FM_JEV_PROD_GRACE_SECS:-3600}
case "$GRACE_SECS" in ''|*[!0-9]*) GRACE_SECS=3600 ;; esac

MAX_PRS=${FM_JEV_PROD_MAX_PRS:-8}
case "$MAX_PRS" in ''|*[!0-9]*|0) MAX_PRS=8 ;; esac

# The watcher's per-check bound, read from this check's own environment because
# the watcher runs it as a direct child. The read budget stays a few seconds
# inside it, the same margin bin/fm-usage-warner.sh and bin/fm-contributions.sh
# keep, so a poll is never killed mid-write.
CHECK_TIMEOUT=${FM_CHECK_TIMEOUT:-30}
case "$CHECK_TIMEOUT" in ''|*[!0-9]*|0) CHECK_TIMEOUT=30 ;; esac
if [ "${1:-check}" = reseed ]; then
  BUDGET=${FM_JEV_PROD_BUDGET:-120}
  case "$BUDGET" in ''|*[!0-9]*|0) BUDGET=120 ;; esac
  [ "$BUDGET" -le 300 ] || BUDGET=300
else
  BUDGET=${FM_JEV_PROD_BUDGET:-20}
  case "$BUDGET" in ''|*[!0-9]*|0) BUDGET=20 ;; esac
  [ "$BUDGET" -le 25 ] || BUDGET=25
  BUDGET_CAP=$((CHECK_TIMEOUT - 3))
  [ "$BUDGET_CAP" -ge 1 ] || BUDGET_CAP=1
  [ "$BUDGET" -le "$BUDGET_CAP" ] || BUDGET=$BUDGET_CAP
fi
# No single forge read may eat the whole budget.
READ_SECS=5
[ "$READ_SECS" -le "$BUDGET" ] || READ_SECS=$BUDGET

TMP=
cleanup() { [ -z "$TMP" ] || rm -rf -- "$TMP"; }
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

# --- config -----------------------------------------------------------------
# Prints "repo<TAB><owner/repo>" and "lookback-hours<TAB><n>" for the valid
# directives in config/jev-prod-monitor, and nothing at all when the file is
# absent or holds no valid directive. That "nothing" is the opt-in gate.
CONFIG_REPO=
CONFIG_LOOKBACK=48
CONFIG_RECORDER_LOGIN=
CONFIG_ERROR=

config_read() {
  local line key value repo_seen=0
  CONFIG_REPO=
  CONFIG_LOOKBACK=48
  CONFIG_RECORDER_LOGIN=$RECORDER_LOGIN_DEFAULT
  CONFIG_ERROR=
  [ -f "$CONFIG" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [ -n "$line" ] || continue
    case "$line" in '#'*) continue ;; esac
    case "$line" in *:*) ;; *) continue ;; esac
    key=${line%%:*}
    value=${line#*:}
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    case "$key" in
      repo)
        repo_seen=$((repo_seen + 1))
        if [ "$repo_seen" -gt 1 ]; then
          CONFIG_ERROR='more than one repo directive'
          return 1
        fi
        fm_jev_repo_valid "$value" || { CONFIG_ERROR="invalid repo: $value"; return 1; }
        CONFIG_REPO=$value
        ;;
      recorder-login)
        # Bounded to a forge login so the value can only ever be compared, never
        # carry a separator into the record or the wake line.
        case "$value" in
          ''|*[!A-Za-z0-9._\[\]-]*) CONFIG_ERROR="invalid recorder-login: $value"; return 1 ;;
        esac
        [ "${#value}" -le 64 ] || { CONFIG_ERROR="recorder-login is too long"; return 1; }
        CONFIG_RECORDER_LOGIN=$value
        ;;
      lookback-hours)
        case "$value" in ''|*[!0-9]*) CONFIG_ERROR="invalid lookback-hours: $value"; return 1 ;; esac
        [ "$value" -ge 1 ] && [ "$value" -le 336 ] \
          || { CONFIG_ERROR="lookback-hours must be 1..336: $value"; return 1; }
        CONFIG_LOOKBACK=$value
        ;;
      *) ;;
    esac
  done < "$CONFIG"
  [ -n "$CONFIG_REPO" ]
}

# An <owner>/<repo> slug and nothing else. The slug is interpolated into every
# API path this script reads, so it is validated here rather than trusted.
fm_jev_repo_valid() {
  local slug=$1 owner repo
  case "$slug" in */*/*|/*|*/) return 1 ;; esac
  case "$slug" in */*) ;; *) return 1 ;; esac
  owner=${slug%%/*}
  repo=${slug#*/}
  [ "${#owner}" -ge 1 ] && [ "${#owner}" -le 39 ] || return 1
  case "$owner" in *[!A-Za-z0-9-]*|-*|*-|*--*) return 1 ;; esac
  [ "${#repo}" -ge 1 ] && [ "${#repo}" -le 100 ] || return 1
  case "$repo" in .|..|*[!A-Za-z0-9._-]*) return 1 ;; esac
  return 0
}

# --- dedupe record ----------------------------------------------------------
RECORD_REPORTED=
RECORD_WOKEN=
RECORD_PENDING=
RECORD_CURSOR=

record_read() {
  local line
  RECORD_REPORTED=
  RECORD_WOKEN=
  RECORD_PENDING=
  RECORD_CURSOR=
  RECORD_OUTCOMES=
  [ -f "$RECORD" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "$RECORD_SCHEMA") continue ;;
      reported?*) RECORD_REPORTED=${line#reported	} ;;
      woken?*) RECORD_WOKEN="${RECORD_WOKEN}${line#woken	}
" ;;
      pending?*) RECORD_PENDING="${RECORD_PENDING}${line#pending	}
" ;;
      outcome?*) RECORD_OUTCOMES="${RECORD_OUTCOMES}${line#outcome	}
" ;;
      cursor?*) RECORD_CURSOR=${line#cursor	} ;;
    esac
  done < "$RECORD"
  case "$RECORD_CURSOR" in ''|*[!0-9]*) RECORD_CURSOR= ;; esac
  return 0
}

# Trailing newlines are stripped before writing: the lists are accumulated with
# a trailing separator, and an unstripped one would publish a blank entry that
# reads back as a real record on the next poll.
record_write() {  # <reported> <woken-list> <pending-list> <cursor>
  local reported=$1 woken=$2 pending=$3 cursor=$4 tmp
  woken=${woken%"${woken##*[!$'\n']}"}
  pending=${pending%"${pending##*[!$'\n']}"}
  mkdir -p "$STATE" 2>/dev/null || return 1
  tmp=$(umask 077; mktemp "$STATE/.fm-jev-prod-check.XXXXXX" 2>/dev/null) || return 1
  {
    printf '%s\n' "$RECORD_SCHEMA"
    [ -z "$reported" ] || printf 'reported\t%s\n' "$reported"
    # Bounded: only the most recent keys are kept, which is every key any
    # candidate still inside the lookback can present.
    [ -z "$woken" ] || printf '%s\n' "$woken" | tail -n "$WOKEN_KEEP" | sed 's/^/woken\t/'
    [ -z "$pending" ] || printf '%s\n' "$pending" | sed 's/^/pending\t/'
    [ -z "$RECORD_OUTCOMES" ] || printf '%s' "$RECORD_OUTCOMES" | tail -n "$WOKEN_KEEP" | sed 's/^/outcome\t/'
    [ -z "$cursor" ] || printf 'cursor\t%s\n' "$cursor"
  } > "$tmp" || { rm -f -- "$tmp"; return 1; }
  chmod 0600 "$tmp" 2>/dev/null || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$RECORD" || { rm -f -- "$tmp"; return 1; }
  return 0
}

list_has() {  # <newline-list> <exact-entry>
  [ -n "$2" ] || return 1
  printf '%s\n' "$1" | grep -qxF -- "$2"
}

promote_alias() {  # <fallback-key> <verified-run-key>
  woken="$(printf '%s' "$woken" | awk -v old="$1" -v new="$2" '
    {if ($0 == old) $0=new; print}')"$'\n'
  if [ -n "$RECORD_OUTCOMES" ]; then
    RECORD_OUTCOMES="$(printf '%s' "$RECORD_OUTCOMES" | awk -F '\t' -v old="$1" -v new="$2" '
      {if ($1 == old) $0=new substr($0,index($0,"\t")); print}')"$'\n'
  fi
}

# --- forge reads ------------------------------------------------------------
# Every read is bounded and every failure is visible to the caller as a non-zero
# exit with no output. Nothing here ever treats an unreadable answer as a good
# one.
DEADLINE=$((NOW + BUDGET))

budget_left() {
  local now
  now=$(date +%s)
  [ -n "${FM_JEV_PROD_NOW:-}" ] && now=$NOW
  [ "$now" -lt "$DEADLINE" ]
}

gh_json() {  # <api-path> ; prints the raw body
  local out rc=0
  out=$(fm_run_timed "$READ_SECS" gh api "$1" 2>/dev/null)
  rc=$?
  [ "$rc" -eq 0 ] || return 1
  [ -n "$out" ] || return 1
  printf '%s\n' "$out"
}

gh_json_cached() {
  local cache
  cache="$TMP/get-$(printf '%s' "$1" | cksum | awk '{print $1 "-" $2}')"
  if [ ! -s "$cache" ]; then
    gh_json "$1" > "$cache" || { rm -f "$cache"; return 1; }
  fi
  cat "$cache"
}

artifact_download() {  # <repo> <artifact-id> <zip>
  [ -s "$3" ] && return 0
  fm_run_timed "$READ_SECS" gh api "repos/$1/actions/artifacts/$2/zip" > "$3" 2>/dev/null || {
    rm -f "$3"
    return 1
  }
}

# --- bounded tokens ---------------------------------------------------------
# A last line of defence for anything rendered: the wake is ONE line and the
# record is tab-separated, so no field may carry a separator of its own.
scrub_field() {  # <value>
  printf '%s' "$1" | LC_ALL=C tr -d '\000-\037'
}

# Every value lifted out of a comment or an artifact passes one of these before
# it reaches the record or the printed line. A refusal means "not established".
token_ok() {  # <value> <extended-regex>
  [ -n "$1" ] || return 1
  # A value carrying a control character of its own is never a token, and this
  # test has to come FIRST: grep matches per LINE, so a `^...$` regex would
  # accept a multi-line value on the strength of its first line and ignore the
  # rest - which is exactly how content somebody else controls would get
  # through. Scrubbing is the test: a value the scrubber changes carried one.
  [ "$1" = "$(scrub_field "$1")" ] || return 1
  printf '%s' "$1" | LC_ALL=C grep -Eq "$2"
}

verdict_token_ok() { token_ok "$1" "$VERDICT_SHAPE"; }
app_token_ok() { token_ok "$1" '^[A-Za-z0-9_-]{1,64}$'; }
section_identity() {  # <section-token>; default persona is explicit internally
  SECTION_APP=${1%%:*}
  SECTION_PERSONA=${1#*:}
  app_token_ok "$SECTION_APP" || return 1
  if [ "$SECTION_PERSONA" = "$1" ]; then
    SECTION_PERSONA=default
    return 0
  fi
  [ "$SECTION_APP" = portal ] || return 1
  case "$SECTION_PERSONA" in portal-foreign|portal-previous|portal-unverified) return 0 ;; esac
  return 1
}
phase_token_ok() { token_ok "$1" '^(pre-merge|post-merge)$'; }
record_token_ok() { token_ok "$1" '^[0-9A-Za-z-]{1,64}$'; }
comment_id_ok() { token_ok "$1" '^[0-9]{1,20}$'; }

# A pull request URL this poll is willing to print, reconstructed from the one
# repository it was configured for rather than trusted as the forge sent it.
pr_url_ok() {  # <url> <number>
  [ "$1" = "https://github.com/$CONFIG_REPO/pull/$2" ]
}


# --- parsing ----------------------------------------------------------------
# `<type>/<ENG-n>(<scope>): ...` is core's PR title contract. A title that does
# not match carries NO ticket: a guessed ticket is worse than none, because it
# would put this verdict on somebody else's work.
ticket_from_title() {  # <title>
  printf '%s' "$1" | sed -n 's|^[A-Za-z][A-Za-z0-9_-]*/\(ENG-[0-9][0-9]*\)\((.*)\)\{0,1\}:.*|\1|p' | head -1
}

# One app's section of the marker comment, between core's own wrappers.
section_of() {  # <body-file> <app>
  awk -v app="$2" '
    $0 == "<!-- jev-check-app:" app " -->" { starts++; inside=1; next }
    $0 == "<!-- /jev-check-app:" app " -->" { ends++; inside=0; next }
    inside && /^<!-- \/?jev-check-app:/ { invalid=1 }
    inside { body=body $0 "\n" }
    END {
      if (invalid || starts != 1 || ends != 1 || inside) exit 1
      printf "%s", body
    }
  ' "$1"
}

# Every app this comment holds a section for, in the order it holds them.
apps_in_body() {  # <body-file>
  sed -n 's|^<!-- jev-check-app:\([A-Za-z0-9_:-]\{1,128\}\) -->$|\1|p' "$1"
}

# Parse the complete title, including the one known multiword outcome.
verdict_of() {  # <section-file>
  local title
  title=$(sed -n 's|^\*\*Browser check \(.*\)\*\* (advisory;.*|\1|p' "$1")
  case "$title" in
    '- not applicable in production'|'— not applicable in production') printf 'not-applicable' ;;
    '- '*|'— '*)
      title=${title#* }
      verdict_token_ok "$title" && [ "$title" != not-applicable ] && printf '%s' "$title"
      ;;
  esac
}

head_of() {
  # shellcheck disable=SC2016
  sed -n 's|^Head `\([0-9a-f]\{7,40\}\)` .*|\1|p' "$1"
}

section_fingerprint() {
  cksum < "$1" | awk '{print $1 "-" $2}'
}

# The phase from the metadata line. A published result renders
# `Head `sha` . <phase> . <env> . navigator `nav``; a skip renders only
# `Head `sha` . <phase>`. Both are read by taking the field after the head sha.
phase_of() {  # <section-file>
  # shellcheck disable=SC2016 # The backticks are core's own comment bytes, not a command.
  sed -n 's|^Head `[0-9a-f]\{7,40\}` [^ ]* \([a-z-]\{1,16\}\).*|\1|p' "$1"
}

# The recorder's own identifier for the run that produced this verdict, which is
# what makes the dedupe key "per PR and run" rather than per PR. The id is a
# digest slice, matched as any alphanumeric run rather than as hex, so a change
# to the digest's alphabet cannot quietly stop this from parsing.
record_of() {  # <section-file>
  # shellcheck disable=SC2016 # The backticks are core's own comment bytes, not a command.
  sed -n 's|^Plan `[0-9A-Za-z]\{1,64\}` .* record `\([0-9A-Za-z]\{1,64\}\)`.*|\1|p' "$1"
}

# --- workflow artifacts -----------------------------------------------------
# The uploaded context, plan and check record must describe the same app,
# persona, phase and PR head. Matching production artifacts add workflow run
# identity; matching preview artifacts recover the overwritten preview verdict.
# The artifact reader sets ARTIFACT_VERDICT, ARTIFACT_RUN_URL and ARTIFACT_RUN_KEY.
# A non-zero exit means the evidence was not established.
ARTIFACT_VERDICT=
ARTIFACT_RUN_URL=

# One entry out of an artifact, bounded by the byte cap and by the clock. It
# runs as `bash -c` rather than a function because fm_run_timed EXECS what it is
# given, and an exported function is not something timeout(1) can exec.
unzip_capped() {  # <zip> <entry>
  # shellcheck disable=SC2016 # The inner shell expands these, not this one.
  fm_run_timed "$READ_SECS" bash -c \
    'unzip -p "$1" "$2" 2>/dev/null | head -c "$3"' _ "$1" "$2" "$UNZIP_MAX_BYTES"
}

# An artifact name is only a search hint. Context, plan, and record identities
# must agree before a preview can establish anything.
artifact_verdict() {  # <repo> <head-sha> <app> <persona> <pr-url> <phase> <lookup-sha> [record-prefix]
  local repo=$1 head=$2 app=$3 persona=$4 pr_url=$5 phase=$6 lookup=$7 rec=${8:-}
  local runs rid attempt artifacts aid zip verdict
  ARTIFACT_VERDICT=
  ARTIFACT_RUN_URL=
  ARTIFACT_RUN_KEY=
  budget_left || return 1
  runs=$(gh_json_cached "repos/$repo/actions/workflows/jev-check.yml/runs?head_sha=$lookup&per_page=100") || return 1
  runs=$(printf '%s' "$runs" | jq -r --arg head "$lookup" '
    .workflow_runs[] | select(.conclusion == "success" and .head_sha == $head)
    | select((.id | type) == "number" and (.run_attempt | type) == "number")
    | [.id,.run_attempt] | @tsv' 2>/dev/null) || return 1
  while IFS=$'\t' read -r rid attempt; do
    comment_id_ok "$rid" || continue
    comment_id_ok "$attempt" || continue
    budget_left || return 1
    artifacts=$(gh_json_cached "repos/$repo/actions/runs/$rid/artifacts") || continue
    artifacts=$(printf '%s' "$artifacts" | jq -r '
      .artifacts[] | select(.expired == false)
      | select(.name == "jev-check-records" or (.name | test("^jev-check-records-portal(-foreign|-previous|-unverified)?$")))
      | .id' 2>/dev/null) || continue
    while IFS= read -r aid; do
      comment_id_ok "$aid" || continue
      budget_left || return 1
      zip="$TMP/artifact-$aid.zip"
      artifact_download "$repo" "$aid" "$zip" || continue
      unzip_capped "$zip" context.json > "$TMP/context.json"
      unzip_capped "$zip" plan/plan.json > "$TMP/plan.json"
      unzip_capped "$zip" records.jsonl > "$TMP/records.jsonl"
      verdict=$(jq -nr --slurpfile ctx "$TMP/context.json" --slurpfile plan "$TMP/plan.json" \
        --slurpfile records "$TMP/records.jsonl" --arg app "$app" --arg persona "$persona" \
        --arg head "$head" --arg url "$pr_url" --arg phase "$phase" --arg rec "$rec" '
        def role($a; $r):
          if $a == "portal" then
            if $r == null or $r == "anonymous" or $r == "portal" then "default" else $r end
          else if $r == null or $r == "anonymous" or $r == "staff" then "default" else $r end end;
        $ctx[0] as $c | $plan[0] as $p
        | select($c.app == $app and $p.app == $app and $c.phase == $phase)
        | select($c.pr.headSha == $head and $p.head_sha == $head)
        | select($p.phase == null or $p.phase == $phase)
        | select($c.pr.url == $url and $p.pr_url == $url)
        | select(role($app; $p.test_account_role) == $persona)
        | select($c.memberPersona == null or role($app; $c.memberPersona) == $persona)
        | [$records[] | select(.event == "check") | .record
           | select(.head_sha == $head and .phase == $phase and .pr_url == $url)
           | select((.input_set_hash | type) == "string" and .input_set_hash == $p.input_hash)
           | select($rec == "" or ((.record_id // "") | startswith($rec)))
           | .verdict] | last // empty' 2>/dev/null) || continue
      verdict_token_ok "$verdict" || continue
      ARTIFACT_VERDICT=$verdict
      ARTIFACT_RUN_URL="https://github.com/$repo/actions/runs/$rid/attempts/$attempt"
      ARTIFACT_RUN_KEY="run-$rid-attempt-$attempt"
      return 0
    done <<EOF
$artifacts
EOF
  done <<EOF
$runs
EOF
  return 1
}

# No-plan comments lack a record ID. A matching production context can still
# bind their outcome to an authoritative workflow run and attempt.
outcome_run() {  # <merge-sha> <app> <persona> <verdict> <reason> <head> <pr-url>
  local merge=$1 app=$2 persona=$3 verdict=$4 reason=$5 head=$6 url=$7
  local runs rid attempt artifacts aid zip matched
  OUTCOME_RUN=
  budget_left || return 1
  runs=$(gh_json_cached "repos/$CONFIG_REPO/actions/workflows/jev-check.yml/runs?head_sha=$merge&per_page=100") || return 1
  runs=$(printf '%s' "$runs" | jq -r --arg sha "$merge" '
    .workflow_runs[] | select(.head_sha == $sha and .event == "deployment_status")
    | select((.id|type) == "number" and (.run_attempt|type) == "number")
    | [.id,.run_attempt] | @tsv' 2>/dev/null) || return 1
  while IFS=$'\t' read -r rid attempt; do
    comment_id_ok "$rid" || continue
    comment_id_ok "$attempt" || continue
    budget_left || return 1
    artifacts=$(gh_json_cached "repos/$CONFIG_REPO/actions/runs/$rid/artifacts") || continue
    artifacts=$(printf '%s' "$artifacts" | jq -r '
      .artifacts[] | select(.expired == false)
      | select(.name == "jev-check-records" or (.name | test("^jev-check-records-portal(-foreign|-previous|-unverified)?$")))
      | .id' 2>/dev/null) || continue
    while IFS= read -r aid; do
      comment_id_ok "$aid" || continue
      budget_left || return 1
      zip="$TMP/artifact-$aid.zip"
      artifact_download "$CONFIG_REPO" "$aid" "$zip" || continue
      matched=$(unzip_capped "$zip" context.json | jq -r --arg app "$app" --arg persona "$persona" \
        --arg verdict "$verdict" --arg reason "$reason" --arg head "$head" --arg url "$url" '
        select(.app == $app and .phase == "post-merge")
        | select(.pr.headSha == $head and .pr.url == $url)
        | select((.memberPersona // "default" | if . == "portal" then "default" else . end) == $persona)
        | select($verdict == "identity-only" or
            (.publishSkip == true and
              (if .notApplicable == true then "not-applicable" else "skipped" end) == $verdict and
              (.reason | type) == "string" and (.reason as $r | $reason | contains($r))))
        | "yes"' 2>/dev/null) || continue
      [ "$matched" = yes ] || continue
      OUTCOME_RUN="run-$rid-attempt-$attempt"
      return 0
    done <<EOF
$artifacts
EOF
  done <<EOF
$runs
EOF
  return 1
}

# A commit status is never deployment proof. Only the latest successful status
# of an exact supported Production environment on this merge SHA starts grace.
# Scope the inventory at GitHub so unrelated deployment environments cannot fill
# the bounded first page and hide this app's production deployment.
deployment_of() {  # <merge-sha> <app>
  local sha=$1 app=$2 project deployments rows did statuses stamp state commit_status
  DEPLOYMENT_OUTCOME=deployment-unreadable
  DEPLOYMENT_ID=
  DEPLOYMENT_AT=
  case "$app" in portal) project=core-metaplanet ;; admin-center) project=core-admin-center ;; *) return 0 ;; esac
  deployments=$(gh_json_cached "repos/$CONFIG_REPO/deployments?sha=$sha&environment=Production%20%E2%80%93%20$project&per_page=100") || return 0
  rows=$(printf '%s' "$deployments" | jq -r --arg sha "$sha" --arg env "Production – $project" '
    if type != "array" or length >= 100 then error("incomplete inventory") else
      [.[] | select(.sha == $sha and .environment == $env)] | sort_by(.created_at) | reverse
      | .[] | .id end' 2>/dev/null)
  printf '%s' "$deployments" | jq -e 'type == "array" and length < 100' >/dev/null 2>&1 || return 0
  DEPLOYMENT_OUTCOME=not-deployed
  while IFS= read -r did; do
    comment_id_ok "$did" || continue
    budget_left || { DEPLOYMENT_OUTCOME=deployment-unreadable; return 0; }
    statuses=$(gh_json "repos/$CONFIG_REPO/deployments/$did/statuses?per_page=100") || { DEPLOYMENT_OUTCOME=deployment-unreadable; return 0; }
    state=$(printf '%s' "$statuses" | jq -er 'if type == "array" and length > 0 then sort_by(.created_at,.id) | last | .state else error("no status") end' 2>/dev/null) || { DEPLOYMENT_OUTCOME=deployment-unreadable; return 0; }
    [ "$state" = success ] || continue
    stamp=$(printf '%s' "$statuses" | jq -er 'sort_by(.created_at,.id) | last | .created_at | fromdateiso8601' 2>/dev/null) || { DEPLOYMENT_OUTCOME=deployment-unreadable; return 0; }
    token_ok "$stamp" '^[0-9]{1,12}$' || { DEPLOYMENT_OUTCOME=deployment-unreadable; return 0; }
    DEPLOYMENT_OUTCOME=deployed
    DEPLOYMENT_ID=$did
    DEPLOYMENT_AT=$stamp
    return 0
  done <<EOF
$rows
EOF
  commit_status=$(gh_json_cached "repos/$CONFIG_REPO/commits/$sha/status") || return 0
  if printf '%s' "$commit_status" | jq -e --arg ctx "Vercel – $project" '
    [.statuses[] | select(.context == $ctx)] | sort_by(.created_at) | last
    | .state == "success" and
      (.description == "Canceled by Ignored Build Step" or .description == "Skipped - Not affected")' >/dev/null 2>&1; then
    DEPLOYMENT_OUTCOME=not-applicable
  fi
}

# --- classification ---------------------------------------------------------
# `proven` is the recorder's only passing verdict, and `failed` and `unproven`
# are its flags. `skipped` and `stale` are non-answers: on either side they are
# neither a pass nor a flag, so a pairing that holds one is couldnt-check.
verdict_is_clean() { [ "$1" = proven ]; }
verdict_is_flagged() {
  case "$1" in failed|unproven) return 0 ;; *) return 1 ;; esac
}

# One rendered item: the class, the full PR URL, the ticket (or none), and the
# evidence a reader needs to see it for themselves.
render_item() {  # <class> <pr-url> <ticket> <app> <prod-verdict> <preview-verdict> <comment-url> <checks-url> [preview-run-url]
  printf '%s pr=%s ticket=%s app=%s production=%s preview=%s comment=%s checks=%s' \
    "$(scrub_field "$1")" "$(scrub_field "$2")" "$(scrub_field "${3:-none}")" \
    "$(scrub_field "$4")" "$(scrub_field "$5")" "$(scrub_field "${6:-unknown}")" \
    "$(scrub_field "${7:-none}")" "$(scrub_field "$8")"
  [ -z "${9:-}" ] || printf ' preview-run=%s' "$(scrub_field "$9")"
}

# --- check ------------------------------------------------------------------
reseed_refuse() {
  printf 'fm-jev-prod-check: reseed refused: %s; original state retained\n' "$(scrub_field "$1")" >&2
  return 1
}

action_check() {
  local prs pr_rows reported='' standing=''
  local woken pending cursor
  local regressions='' regression_count=0
  local examined=0

  if ! config_read; then
    [ "$RESEED" -eq 0 ] && return 0
    reseed_refuse "invalid configuration: ${CONFIG_ERROR:-missing repo directive or config file}"
    return 1
  fi

  mkdir -p "$STATE" || {
    [ "$RESEED" -eq 0 ] || reseed_refuse "cannot create state directory"
    return 1
  }
  TMP=$(mktemp -d "$STATE/.fm-jev-prod.XXXXXX") || {
    [ "$RESEED" -eq 0 ] && return 0
    reseed_refuse "cannot create scratch directory"
    return 1
  }
  if [ "$RESEED" -eq 1 ] && [ -e "$RECORD" ]; then
    RESEED_BACKUP=$(umask 077; mktemp "$RECORD.backup.XXXXXX") || { reseed_refuse "cannot create backup file"; return 1; }
    cp "$RECORD" "$RESEED_BACKUP" || { reseed_refuse "cannot copy original state to backup"; return 1; }
  fi
  if [ "$RESEED" -eq 0 ]; then record_read; else RECORD_WOKEN=; RECORD_PENDING=; RECORD_CURSOR=; RECORD_OUTCOMES=; fi
  woken=$RECORD_WOKEN
  pending=$RECORD_PENDING
  cursor=$RECORD_CURSOR

  # A standing condition - a missing tool, an unreadable pull request list - is
  # reported once and then stays quiet until it changes, so a broken poll says
  # so without saying it every ten minutes. It is never silence.
  if ! command -v gh >/dev/null 2>&1; then
    standing='gh is not installed, so no production verdict can be read'
  elif ! command -v jq >/dev/null 2>&1; then
    standing='jq is not installed, so no production verdict can be read'
  elif ! command -v unzip >/dev/null 2>&1; then
    standing='unzip is not installed, so no preview verdict can be paired'
  fi

  if [ -z "$standing" ]; then
    prs=$(gh_json "repos/$CONFIG_REPO/pulls?state=closed&sort=updated&direction=desc&per_page=50") \
      || standing="the merged pull request list for $CONFIG_REPO could not be read"
  fi

  if [ -n "$standing" ]; then
    [ "$RESEED" -eq 0 ] || { reseed_refuse "$standing"; return 1; }
    reported="jev-prod: couldnt-check $standing"
    if [ "$reported" != "$RECORD_REPORTED" ]; then
      fm_cap_line_var "$reported" "$MAX_LINE"
      printf '%s\n' "$FM_LINE_CAP_LINE"
    fi
    record_write "$reported" "$woken" "$pending" "$cursor"
    return 0
  fi

  if [ "$RESEED" -eq 1 ]; then
    printf '%s' "$prs" | jq -e 'type == "array"' >/dev/null 2>&1 || { reseed_refuse "PR list was not a JSON array"; return 1; }
  fi
  pr_rows=$(printf '%s' "$prs" | jq -r --argjson now "$NOW" --argjson window "$((CONFIG_LOOKBACK * 3600))" '
    if type == "array" then
      .[] | select((.merged_at | type) == "string")
          | select(($now - (.merged_at | fromdateiso8601)) <= $window)
          | select((.number | type) == "number")
          | select((.html_url | type) == "string")
          | [ (.number | tostring), .html_url, (.head.sha // ""), (.merge_commit_sha // ""),
              ((.merged_at | fromdateiso8601) | tostring), (.title // "") ]
          | @tsv
    else empty end' 2>/dev/null) || { [ "$RESEED" -eq 0 ] || { reseed_refuse "PR list candidates could not be parsed"; return 1; }; pr_rows=; }

  # Rotate the candidate set from just after the last pull request examined, so
  # a window the budget cut short is finished first on the next poll.
  local candidates total offset window
  total=$(printf '%s\n' "$pr_rows" | grep -c . || true)
  total=${total:-0}
  if [ "$RESEED" -eq 1 ] && [ "$total" -ge 50 ]; then
    printf 'fm-jev-prod-check: reseed warning: all 50 PRs are inside the lookback; single-page inventory may be truncated\n' >&2
  fi
  candidates=
  if [ "$total" -gt 0 ]; then
    offset=0
    if [ -n "$cursor" ]; then
      offset=$(printf '%s\n' "$pr_rows" | grep . | awk -F'\t' -v c="$cursor" '$1 == c { print NR; exit }')
      offset=$(( ${offset:-0} % total ))
    fi
    window=$MAX_PRS
    [ "$RESEED" -eq 0 ] || window=$total
    [ "$window" -le "$total" ] || window=$total
    candidates=$(printf '%s\n' "$pr_rows" "$pr_rows" | grep . | tail -n +"$((offset + 1))" | head -n "$window")
  fi

  local number url head_sha merge_sha merged_at title
  while IFS=$'\t' read -r number url head_sha merge_sha merged_at title; do
    [ -n "$number" ] || continue
    [ "$RESEED" -eq 1 ] || [ "$examined" -lt "$MAX_PRS" ] || break
    budget_left || break
    examined=$((examined + 1))
    examine_pr "$number" "$url" "$head_sha" "$merge_sha" "$merged_at" "$title" || break
    cursor=$number
  done <<EOF
$candidates
EOF

  if [ "$RESEED" -eq 1 ]; then
    if ! budget_left; then
      reseed_refuse "budget ran out after ${BUDGET}s, examined $examined of $total candidates; raise FM_JEV_PROD_BUDGET (maximum 300)"
      return 1
    fi
    if [ -n "$RESEED_FAILED" ]; then
      reseed_refuse "$RESEED_FAILED"
      return 1
    fi
    [ "$examined" -eq "$total" ] || { reseed_refuse "candidate examination stopped after $examined of $total candidates"; return 1; }
    record_write '' "$woken" '' '' || { reseed_refuse "cannot replace state record"; return 1; }
    printf 'reseeded: %s backup=%s\n' "$RECORD" "${RESEED_BACKUP:-none}"
    return 0
  fi

  # A regression goes out on the poll that found it; a ready batch waits for the
  # next one, so neither wake ever arrives as two mixed lines.
  local line=''
  if [ -n "$regressions" ]; then
    if [ "$regression_count" -eq 1 ]; then
      line="jev-prod: ${regressions%; }"
    else
      line="jev-prod: $regression_count regressions: ${regressions%; }"
    fi
  else
    line=$(due_batch_line)
    if [ -n "$line" ]; then
      pending=
    fi
  fi

  [ -z "$line" ] || printf '%s\n' "$line"
  record_write '' "$woken" "$pending" "$cursor"
  return 0
}

# The budget ran out, and an earlier pull request this poll (the caller's
# `examined`) had already spent part of it.
budget_cut_deferrable() {
  ! budget_left && [ "$examined" -gt 1 ]
}

# Examine one merged pull request. Appends to the caller's regressions, woken
# and pending; those are the caller's locals on purpose, because this is one
# function split out for readability rather than a second owner of the record.
# Returns non-zero only when the budget ran out mid-read after an earlier pull
# request this poll had spent part of it, leaving whatever it had not finished
# unqueued and unrecorded for the next poll. The first pull request of a poll had
# the whole budget, so running out is its honest couldnt-check.
examine_pr() {  # <number> <url> <head-sha> <merge-sha> <merged-at> <title>
  local number=$1 url=$2 head_sha=$3 merge_sha=$4 merged_at=$5 title=$6
  local comments body_file comment_id ticket apps app verdict phase rec
  local comment_revision record_id fallback alias_promoted
  local checks_url key class preview preview_run persona section section_head fingerprint reason identity

  comments=$(gh_json "repos/$CONFIG_REPO/issues/$number/comments?per_page=100") || {
    [ "$RESEED" -eq 0 ] || { RESEED_FAILED="PR $url comment list could not be read"; return 1; }
    budget_cut_deferrable && return 1
    budget_left && return 0
    pr_url_ok "$url" "$number" || return 0
    key="$number/-/read-budget-exhausted"
    list_has "$woken" "$key" && return 0
    queue_item couldnt-check "$key" "$url" "$(ticket_from_title "$title")" - none '' \
      "$url" "https://github.com/$CONFIG_REPO/commit/$merge_sha/checks" ''
    return 0
  }
  if [ "$RESEED" -eq 1 ]; then
    printf '%s' "$comments" | jq -e 'type == "array"' >/dev/null 2>&1 || {
      RESEED_FAILED="PR $url comment list was not a JSON array"; return 1;
    }
    printf '%s' "$comments" | jq -e 'length < 100' >/dev/null 2>&1 || {
      RESEED_FAILED="PR $url has a 100+ comment inventory that cannot be read completely"; return 1;
    }
  fi
  body_file="$TMP/body-$number"
  # ONLY the recorder's own comment is a verdict. Anybody who can comment on the
  # pull request can write the marker, and the earliest marker comment is the one
  # upstream keeps, so without this an outsider could pre-empt the real verdict
  # simply by posting first.
  printf '%s' "$comments" | jq -r --arg marker "$MARKER" --arg who "$CONFIG_RECORDER_LOGIN" '
    if type == "array" then
      [ .[]
        | select((.body | type) == "string")
        | select((.user.login // "") == $who)
        | select(.body | contains($marker)) ]
      | sort_by(.id) | .[0] // empty | "\(.id)"
    else empty end' 2>/dev/null > "$TMP/cid-$number"
  comment_id=$(cat "$TMP/cid-$number" 2>/dev/null)
  comment_id_ok "$comment_id" || comment_id=
  # The URL is reconstructed from the configured repository rather than trusted
  # as sent, so nothing this prints can point at another project.
  pr_url_ok "$url" "$number" || return 0
  if [ -z "$comment_id" ]; then
    # A full page back with no marker on it means the inventory may be
    # truncated and the verdict may be sitting on a page this never read.
    # Upstream's own recorder refuses a truncated inventory for the same
    # reason; here the honest answer is that the check could not be made,
    # never that the pull request had no verdict.
    if [ "$(printf '%s' "$comments" | jq -r 'if type == "array" then length else 0 end' 2>/dev/null)" = 100 ]; then
      key="$number/-/comment-inventory-truncated"
      list_has "$woken" "$key" && return 0
      queue_item couldnt-check "$key" "$url" "$(ticket_from_title "$title")" - none '' \
        "$url" "https://github.com/$CONFIG_REPO/commit/$merge_sha/checks" ''
      return 0
    fi
    # Otherwise this lane simply never ran for this pull request, which is not a
    # verdict to chase. It ages out of the lookback on its own.
    return 0
  fi
  printf '%s' "$comments" | jq -r --arg id "$comment_id" '
    if type == "array" then .[] | select((.id | tostring) == $id) | .body else empty end' \
    2>/dev/null > "$body_file"
  [ -s "$body_file" ] || return 0

  comment_revision=$(printf '%s' "$comments" | jq -r --arg id "$comment_id" '
    .[] | select((.id|tostring) == $id) | .updated_at // "unknown"' 2>/dev/null)
  token_ok "$comment_revision" '^[0-9TZ:-]{1,32}$' || comment_revision=unknown
  ticket=$(ticket_from_title "$title")
  checks_url="https://github.com/$CONFIG_REPO/commit/$merge_sha/checks"
  apps=$(apps_in_body "$body_file")
  [ -n "$apps" ] || return 0

  while IFS= read -r section; do
    [ -n "$section" ] || continue
    section_identity "$section" || continue
    app=$SECTION_APP
    persona=$SECTION_PERSONA
    section_of "$body_file" "$section" > "$TMP/section"
    verdict=$(verdict_of "$TMP/section")
    phase=$(phase_of "$TMP/section")
    section_head=$(head_of "$TMP/section")
    fingerprint=$(section_fingerprint "$TMP/section")
    rec=$(record_of "$TMP/section")
    record_token_ok "$rec" || rec=
    record_id=$rec
    if [ "$verdict" = proven ] && [ -z "$rec" ]; then verdict=; fi
    verdict_token_ok "$verdict" || verdict=
    phase_token_ok "$phase" || phase=
    token_ok "$section_head" '^[0-9a-f]{7,40}$' || section_head=
    if [ -z "$verdict" ] || [ -z "$phase" ] || [ -z "$section_head" ] || { [ "$phase" = post-merge ] && [ "$section_head" != "$head_sha" ]; }; then
      [ "$RESEED" -eq 0 ] || continue
      identity="unparsed-$fingerprint"
      if [ "$phase" = post-merge ] && [ "$section_head" = "$head_sha" ] && \
        outcome_run "$merge_sha" "$app" "$persona" identity-only '' "$head_sha" "$url"; then
        identity="$identity-$OUTCOME_RUN"
      elif budget_cut_deferrable; then
        return 1
      else
        identity="$identity-$comment_revision"
      fi
      key="$number/$section/$identity"
      list_has "$woken" "$key" && continue
      queue_item couldnt-check "$key" "$url" "$ticket" "$section" unreadable '' \
        "$url#issuecomment-$comment_id" "$checks_url" ''
      continue
    fi
    if [ "$phase" != post-merge ]; then
      [ "$RESEED" -eq 0 ] || continue
      deployment_of "$merge_sha" "$app"
      budget_cut_deferrable && return 1
      if [ "$DEPLOYMENT_OUTCOME" = deployed ]; then
        [ $((NOW - DEPLOYMENT_AT)) -gt "$GRACE_SECS" ] || continue
        identity="deployment-$DEPLOYMENT_ID"
        if outcome_run "$merge_sha" "$app" "$persona" identity-only '' "$head_sha" "$url"; then
          identity="$identity-$OUTCOME_RUN"
        elif budget_cut_deferrable; then
          return 1
        fi
        verdict=none
      else
        verdict=$DEPLOYMENT_OUTCOME
        identity=$DEPLOYMENT_OUTCOME
      fi
      key="$number/$section/no-production-verdict-$identity"
      list_has "$woken" "$key" && continue
      if [ "$verdict" = not-applicable ]; then
        woken="${woken}${key}
"
        RECORD_OUTCOMES="${RECORD_OUTCOMES}${key}	${verdict}	build-skipped
"
        continue
      fi
      queue_item couldnt-check "$key" "$url" "$ticket" "$section" "$verdict" "$(verdict_of "$TMP/section")" \
        "$url#issuecomment-$comment_id" "$checks_url" ''
      continue
    fi
    reason=$(sed -n 's/^Not applicable in production: //p; s/^Skipped: //p' "$TMP/section" | head -1)
    if [ "$RESEED" -eq 1 ]; then
      [ -n "$rec" ] || rec="$phase-$verdict-$fingerprint"
    elif [ -n "$rec" ]; then
      if artifact_verdict "$CONFIG_REPO" "$head_sha" "$app" "$persona" "$url" post-merge "$merge_sha" "$rec"; then
        rec="$ARTIFACT_RUN_KEY-$verdict-$rec"
      elif budget_cut_deferrable; then
        return 1
      fi
    else
      rec="$phase-$verdict-$fingerprint"
      if outcome_run "$merge_sha" "$app" "$persona" "$verdict" "$reason" "$head_sha" "$url"; then
        rec="$OUTCOME_RUN-$verdict-$fingerprint"
      elif budget_cut_deferrable; then
        return 1
      fi
    fi
    key="$number/$section/$rec"
    # A read failure must not redeliver a known record under its fallback key.
    # Conversely, enriching a fallback with a run ID does not create a new result.
    if [[ "$rec" == run-* ]]; then
      alias_promoted=0
      for fallback in "$number/$section/$record_id" "$number/$section/$phase-$verdict-$fingerprint"; do
        if list_has "$woken" "$fallback"; then
          promote_alias "$fallback" "$key"
          alias_promoted=1
          break
        fi
      done
      [ "$alias_promoted" -eq 0 ] || continue
    else
      if printf '%s' "$woken" | awk -v prefix="$number/$section/run-" -v suffix="-$rec" '
        index($0,prefix) == 1 && substr($0,length($0)-length(suffix)+1) == suffix {found=1}
        END {exit !found}'; then continue; fi
      if [ -z "$record_id" ] && printf '%s' "$woken" | awk -v prefix="$number/$section/run-" -v suffix="-$verdict-$fingerprint" '
        index($0,prefix) == 1 && substr($0,length($0)-length(suffix)+1) == suffix {found=1}
        END {exit !found}'; then continue; fi
    fi
    list_has "$woken" "$key" && continue
    if [ "$verdict" = not-applicable ] || verdict_is_clean "$verdict" || [ "$RESEED" -eq 1 ]; then
      woken="${woken}${key}
"
      if [ "$verdict" = not-applicable ]; then
        RECORD_OUTCOMES="${RECORD_OUTCOMES}${key}	${verdict}	$(scrub_field "$reason")
"
      fi
      continue
    fi
    preview=
    preview_run=
    if artifact_verdict "$CONFIG_REPO" "$head_sha" "$app" "$persona" "$url" pre-merge "$head_sha"; then
      preview=$ARTIFACT_VERDICT
      preview_run=$ARTIFACT_RUN_URL
    elif budget_cut_deferrable; then
      return 1
    fi
    if [ -z "$preview" ] || ! verdict_is_flagged "$verdict"; then
      class=couldnt-check
    elif verdict_is_clean "$preview"; then
      class=regression
    elif verdict_is_flagged "$preview"; then
      class=still-flagged
    else
      class=couldnt-check
    fi
    queue_item "$class" "$key" "$url" "$ticket" "$section" "$verdict" "$preview" \
      "$url#issuecomment-$comment_id" "$checks_url" "$preview_run"
  done <<EOF
$apps
EOF

  return 0
}

# Route one classified verdict: a regression into this poll's line, anything else
# into the pending batch. Both record the key, so neither ever wakes twice.
queue_item() {  # <class> <key> <pr-url> <ticket> <app> <prod> <preview> <comment-url> <checks-url> <preview-run>
  local class=$1 key=$2 item
  item=$(render_item "$class" "$3" "$4" "$5" "$6" "$7" "$8" "$9" "${10:-}")
  woken="${woken}${key}
"
  if [ "$class" = regression ]; then
    regressions="${regressions}${item}; "
    regression_count=$((regression_count + 1))
  else
    pending="${pending}${NOW}	${class}	${item}
"
  fi
}

# The batched classes go out as one line once the oldest has waited the window.
due_batch_line() {
  local first='' count=0 items='' seen class item
  [ -n "$pending" ] || return 0
  while IFS=$'\t' read -r seen class item; do
    [ -n "$seen" ] || continue
    case "$seen" in ''|*[!0-9]*) continue ;; esac
    [ -z "$first" ] && first=$seen
    [ "$seen" -lt "$first" ] && first=$seen
    count=$((count + 1))
    items="${items}${item}; "
  done <<EOF
$pending
EOF
  [ "$count" -gt 0 ] || return 0
  [ $((NOW - first)) -ge "$BATCH_SECS" ] || return 0
  if [ "$count" -eq 1 ]; then
    printf 'jev-prod: %s\n' "${items%; }"
  else
    printf 'jev-prod: %s verdicts: %s\n' "$count" "${items%; }"
  fi
}

# --- arm / disarm -----------------------------------------------------------
# bin/fm-check-shim-lib.sh owns the shim write, trust binding, rollback and
# removal; this script owns only when arming is refused.
FM_CHECK_SHIM_ID=$CHECK_ID
FM_CHECK_SHIM_LABEL=fm-jev-prod-check

action_arm() {
  local tool
  if ! config_read; then
    if [ -n "$CONFIG_ERROR" ]; then
      printf 'fm-jev-prod-check: %s in %s\n' "$CONFIG_ERROR" "$CONFIG" >&2
    else
      printf 'fm-jev-prod-check: no repository configured at %s\n' "$CONFIG" >&2
    fi
    return 1
  fi
  for tool in gh jq unzip; do
    command -v "$tool" >/dev/null 2>&1 || {
      printf 'fm-jev-prod-check: %s is required to read production verdicts\n' "$tool" >&2
      return 1
    }
  done
  fm_check_shim_arm "$FM_HOME" "$SCRIPT_DIR/fm-jev-prod-check.sh" check || return 1
  printf 'armed: state/%s.check.sh\n' "$CHECK_ID"
  return 0
}

action_disarm() {
  fm_check_shim_disarm "$RECORD"
  printf 'disarmed: state/%s.check.sh\n' "$CHECK_ID"
  return 0
}

case "${1:-check}" in
  check) action_check ;;
  reseed) RESEED=1; RESEED_FAILED=; RESEED_BACKUP=; action_check ;;
  arm) action_arm ;;
  disarm) action_disarm ;;
  -h|--help) usage ;;
  *) die_usage "unknown action: $1" ;;
esac
