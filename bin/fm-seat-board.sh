#!/usr/bin/env bash
# A very lightweight, read-only local web page showing quota-axi's report for
# every Claude seat: bin/fm-seat.sh manages which seat NEW workers launch on,
# and this script just displays what quota-axi says every seat has left.
#
# Usage:
#   fm-seat-board.sh [serve] [--port <n>]
#   fm-seat-board.sh render
#   fm-seat-board.sh json [--cached-only]
#
# serve   Default action. Regenerates the page into a scratch directory, at
#         most once every FM_SEAT_BOARD_CACHE_SECONDS (60), and serves it on
#         127.0.0.1 only, through bin/fm-seat-board-server.py, until Ctrl-C.
#         Prints the URL to open on start, including the per-run path token
#         that server requires. The port defaults to 4405; --port 0 takes a
#         free port from the kernel and names it in that printed URL.
# render  Prints one generated page to stdout and exits, using the same
#         per-seat cache. Used by the test suite and for a one-shot look
#         without starting a server.
# json    Prints the same reading as one JSON object instead of a page, for a
#         reader that is not a browser. Schema 1:
#           { schemaVersion, generatedAt, cacheSeconds, activeSeat, liveSeat,
#             seats: [ { name, configDir, active, autoExcluded, cacheFile,
#                        hasData, ageSeconds, account, attention,
#                        windows: [ { id, label, percentRemaining, resetsAt } ],
#                        extraUsage } ] }
#         ageSeconds is the age of that seat's own cache file, so a reader can
#         say how old each figure is instead of implying every one is current;
#         it is null when no cache file can be read. hasData false means no
#         report was obtained at all, and every absent figure is null rather
#         than 0, so "unknown" can never be read as "nothing left". liveSeat
#         names the seat of the CLAUDE_CONFIG_DIR this process itself received,
#         through fm_seat_name_of_profile, so a caller does not re-derive it.
#         --cached-only reads only existing cache files and never shells out to
#         quota-axi, so a caller on a fast cadence cannot poll the endpoint.
#
# The page shows, per seat (the default login plus every named seat from
# bin/fm-seat.sh's own listing): the account email, each quota window's
# percent LEFT and reset time, extra-usage spend against its cap, any
# attention line quota-axi reports (not logged in, rate limited, ...) shown
# as-is, and which seat is active for new workers.
#
# Read-only: this script never switches, arms, or edits any seat setting. It
# only reads. Every quota read goes through bin/fm-seat-lib.sh's own
# fm_seat_quota_json, which passes --no-credential-refresh and never
# --allow-keychain-prompt, exactly as every other seat probe in this repo.
#
# Not reachable from a web page: bin/fm-seat-board-server.py is the only thing
# here that serves the page, and its header owns the DNS-rebinding defence
# (Host check and per-run path token).
#
# Caching: the Claude quota endpoint rate-limits frequent polling, so each
# seat's quota-axi report is cached for FM_SEAT_BOARD_CACHE_SECONDS (default
# 60) under FM_SEAT_BOARD_CACHE_DIR (default ~/.cache/fm-seat-board). A page
# reload just re-reads that cache; only the background regeneration loop in
# `serve`, or a `render` call after the cache has expired, ever shells out to
# quota-axi again. No token or credential is ever read or printed here; only
# what quota-axi's own --full --json report already exposes as non-secret.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
# shellcheck disable=SC2034  # read by the sourced fm-seat-lib.sh functions
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-seat-lib.sh
. "$SCRIPT_DIR/fm-seat-lib.sh"
# shellcheck source=bin/fm-quota-axi-lib.sh
. "$SCRIPT_DIR/fm-quota-axi-lib.sh"

FM_SEAT_BOARD_PORT_DEFAULT=4405
FM_SEAT_BOARD_CACHE_SECONDS=${FM_SEAT_BOARD_CACHE_SECONDS:-60}
FM_SEAT_BOARD_CACHE_DIR=${FM_SEAT_BOARD_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/fm-seat-board}

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "${BASH_SOURCE[0]}"
  exit 2
}
die() { printf 'error: %s\n' "$1" >&2; exit 1; }

# html_escape <text>
html_escape() {
  local s=$1
  # Quoted replacements: bash 5.2+ patsub_replacement treats a bare & as the match.
  s=${s//&/'&amp;'}
  s=${s//</'&lt;'}
  s=${s//>/'&gt;'}
  s=${s//\"/'&quot;'}
  printf '%s' "$s"
}

# cache_key <config-dir>
# A filesystem-safe cache filename for one seat's resolved config directory.
cache_key() {
  printf '%s' "$1" | tr -c 'A-Za-z0-9_-' '_'
}

# file_age_seconds <path>
# Seconds since <path> was last written, or empty when it cannot be read.
file_age_seconds() {
  local path=$1 mtime now
  mtime=$(stat -f '%m' "$path" 2>/dev/null) || mtime=$(stat -c '%Y' "$path" 2>/dev/null) || return 1
  now=$(date +%s)
  printf '%s\n' "$((now - mtime))"
}

# seat_cache_file <config-dir>
# The cache file one seat's report is stored in. Keyed by the resolved config
# directory rather than the seat name, so two homes whose same-named seats point
# at different profiles never share a cached report.
seat_cache_file() {
  printf '%s\n' "$FM_SEAT_BOARD_CACHE_DIR/$(cache_key "${1:-default}").json"
}

# seat_quota_cached <config-dir> [cached-only]
# This seat's quota-axi --full --json report, read at most once every
# FM_SEAT_BOARD_CACHE_SECONDS. Prints the cached or freshly read report, or
# nothing when neither a fresh read nor a usable cache file exists.
#
# With a non-empty <cached-only>, an expired or absent cache is reported as no
# data instead of being refilled: the read makes no quota-axi call at all. That
# is what lets a caller poll far more often than the endpoint tolerates.
seat_quota_cached() {
  local dir=$1 cached_only=${2-} cache_file age out tmp
  (umask 077 && mkdir -p "$FM_SEAT_BOARD_CACHE_DIR") 2>/dev/null || true
  chmod 700 "$FM_SEAT_BOARD_CACHE_DIR" 2>/dev/null || true
  cache_file=$(seat_cache_file "$dir")
  if [ -n "$cached_only" ]; then
    seat_cache_read "$cache_file"
    return 0
  fi
  if [ -f "$cache_file" ]; then
    age=$(file_age_seconds "$cache_file") || age=$((FM_SEAT_BOARD_CACHE_SECONDS + 1))
    if [ "$age" -lt "$FM_SEAT_BOARD_CACHE_SECONDS" ] && seat_cache_read "$cache_file"; then
      return 0
    fi
  fi
  if out=$(fm_seat_quota_json "$dir"); then
    if tmp=$(mktemp "$cache_file.XXXXXX" 2>/dev/null); then
      { printf '%s' "$out" > "$tmp" && mv "$tmp" "$cache_file"; } 2>/dev/null || rm -f "$tmp"
    fi
    printf '%s' "$out"
    return 0
  fi
  seat_cache_read "$cache_file"
}

# seat_cache_read <cache-file>
# Print a cache file only when it holds a whole JSON document, so a torn or
# foreign file reads as no data rather than as a seat with no login.
seat_cache_read() {
  [ -f "$1" ] && jq -e . "$1" >/dev/null 2>&1 && cat "$1"
}

board_css() {
  cat <<'CSS'
body { font-family: -apple-system, system-ui, sans-serif; margin: 2rem; color: #1a1a1a; }
h1 { font-size: 1.4rem; }
.generated { color: #666; font-size: 0.85rem; }
section.seat { border: 1px solid #ccc; border-radius: 6px; padding: 0.75rem 1rem; margin-bottom: 1rem; }
section.seat h2 { font-size: 1.05rem; margin: 0 0 0.35rem; }
.active { color: #0a7a2f; font-weight: bold; font-size: 0.8rem; }
.account { color: #444; margin: 0.1rem 0; }
.attention { color: #b30000; font-weight: bold; }
table.windows { border-collapse: collapse; margin-top: 0.4rem; }
table.windows th, table.windows td { text-align: left; padding: 0.15rem 0.6rem 0.15rem 0; }
.extra { color: #444; }
CSS
}

# seat_section_html <seat-name> <active-seat-name>
seat_section_html() {
  local name=$1 active=$2 dir json marker email src state_err attention extra spent limit
  dir=$(fm_seat_config_dir "$name")
  json=$(seat_quota_cached "$dir")
  marker=
  [ "$name" != "$active" ] || marker=' <span class="active">active for new workers</span>'
  printf '<section class="seat">\n'
  printf '<h2>%s%s</h2>\n' "$(html_escape "$name")" "$marker"
  if [ -z "$json" ]; then
    printf '<p class="attention">no quota data (quota-axi unavailable or the read timed out)</p>\n'
    printf '</section>\n'
    return
  fi
  email=$(printf '%s' "$json" |
    jq -r '(.providers[]? | select(.provider == "claude") | .account.email // empty)' 2>/dev/null)
  src=$(printf '%s' "$json" |
    jq -r '(.providers[]? | select(.provider == "claude") | .source // empty)' 2>/dev/null)
  state_err=$(printf '%s' "$json" |
    jq -r '(.providers[]? | select(.provider == "claude") | .state.error // empty)' 2>/dev/null)
  [ -z "$email" ] || printf '<p class="account">%s</p>\n' "$(html_escape "$email")"
  if [ "$src" != oauth ]; then
    attention=$state_err
    [ -n "$attention" ] || attention='not logged in'
    printf '<p class="attention">%s</p>\n' "$(html_escape "$attention")"
  fi
  printf '<table class="windows">\n<tr><th>window</th><th>left</th><th>resets</th></tr>\n'
  while IFS=$'\t' read -r wid label pct resets; do
    [ -n "$wid" ] || continue
    printf '<tr><td>%s</td><td>%s%%</td><td>%s</td></tr>\n' \
      "$(html_escape "${label:-$wid}")" "$(html_escape "$pct")" "$(html_escape "$resets")"
  done < <(printf '%s' "$json" | jq -r '
    (.providers[]? | select(.provider == "claude") | .windows // [])[] |
    select(.id != "extra_usage") |
    [.id, (.label // .id), ((.percentRemaining // "") | tostring), (.resetsAt // "")] | @tsv
  ' 2>/dev/null)
  printf '</table>\n'
  extra=$(printf '%s' "$json" | jq -r '
    (.providers[]? | select(.provider == "claude") | .windows // [])[] |
    select(.id == "extra_usage") |
    [((.spentUsd // "") | tostring), ((.limitUsd // "") | tostring)] | @tsv
  ' 2>/dev/null | head -1)
  if [ -n "$extra" ]; then
    IFS=$'\t' read -r spent limit <<<"$extra"
    printf '<p class="extra">extra usage: $%s of $%s</p>\n' "$(html_escape "$spent")" "$(html_escape "$limit")"
  fi
  printf '</section>\n'
}

# seat_json <seat-name> <active-seat-name> <cached-only>
# One seat's record for the `json` action, as the schema in this script's header
# states it. The cache file's own age travels with the figures so a reader can
# date them, and a seat with no report prints hasData false with null figures
# rather than zeros a reader could mistake for an empty quota.
seat_json() {
  local name=$1 active=$2 cached_only=$3 dir json cache_file age flags
  dir=$(fm_seat_config_dir "$name")
  cache_file=$(seat_cache_file "$dir")
  json=$(seat_quota_cached "$dir" "$cached_only")
  age=$(file_age_seconds "$cache_file") || age=null
  flags=$(fm_seat_auto_excluded "$name" && printf true || printf false)
  if [ -z "$json" ]; then
    jq -n \
      --arg name "$name" --arg dir "$dir" --arg cache "$cache_file" \
      --argjson active "$([ "$name" = "$active" ] && printf true || printf false)" \
      --argjson excluded "$flags" \
      '{
        name: $name, configDir: $dir, active: $active, autoExcluded: $excluded,
        cacheFile: $cache, hasData: false, ageSeconds: null, account: null,
        attention: "no quota data (quota-axi unavailable or the read timed out)",
        windows: [], extraUsage: null
      }'
    return 0
  fi
  printf '%s' "$json" | jq \
    --arg name "$name" --arg dir "$dir" --arg cache "$cache_file" \
    --argjson active "$([ "$name" = "$active" ] && printf true || printf false)" \
    --argjson excluded "$flags" \
    --argjson age "$age" \
    '
    ([.providers[]? | select(.provider == "claude")] | first) as $p |
    {
      name: $name, configDir: $dir, active: $active, autoExcluded: $excluded,
      cacheFile: $cache, hasData: true, ageSeconds: $age,
      account: ($p.account.email // null),
      attention: (
        if $p == null then "no claude row in the quota report"
        elif ($p.source // "") == "oauth" then null
        else (($p.state.error // "") | if . == "" then "not logged in" else . end)
        end
      ),
      windows: [
        ($p.windows // [])[] | select(.id != "extra_usage") |
        {
          id: .id, label: (.label // .id),
          percentRemaining: (.percentRemaining // null),
          resetsAt: (.resetsAt // null)
        }
      ],
      extraUsage: (
        [($p.windows // [])[] | select(.id == "extra_usage")] |
        if length == 0 then null
        else { spentUsd: (.[0].spentUsd // null), limitUsd: (.[0].limitUsd // null) }
        end
      )
    }'
}

# render_json <cached-only>
# Every seat's record as one JSON object, the default login first and then each
# named seat in fm_seat_list's own order.
render_json() {
  local cached_only=$1 active name
  active=$(fm_seat_active)
  {
    seat_json "$FM_SEAT_DEFAULT_NAME" "$active" "$cached_only"
    while IFS= read -r name; do
      [ -n "$name" ] || continue
      seat_json "$name" "$active" "$cached_only"
    done < <(fm_seat_list)
  } | jq -s \
      --arg generated "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      --arg active "$active" \
      --arg live "$(fm_seat_name_of_profile "${CLAUDE_CONFIG_DIR:-}")" \
      --argjson cacheSeconds "$FM_SEAT_BOARD_CACHE_SECONDS" \
      '{
        schemaVersion: 1, generatedAt: $generated, cacheSeconds: $cacheSeconds,
        activeSeat: $active, liveSeat: $live, seats: .
      }'
}

render_page() {
  local active name
  active=$(fm_seat_active)
  printf '<!DOCTYPE html>\n<html><head><meta charset="utf-8">\n'
  printf '<title>Claude seats</title>\n'
  printf '<meta http-equiv="refresh" content="%s">\n' "$FM_SEAT_BOARD_CACHE_SECONDS"
  printf '<style>%s</style>\n' "$(board_css)"
  printf '</head><body>\n'
  printf '<h1>Claude seats</h1>\n'
  printf '<p class="generated">generated %s</p>\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  seat_section_html "$FM_SEAT_DEFAULT_NAME" "$active"
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    seat_section_html "$name" "$active"
  done < <(fm_seat_list)
  printf '</body></html>\n'
}

cmd_render() {
  render_page
}

cmd_json() {
  local cached_only=
  while [ $# -gt 0 ]; do
    case "$1" in
      --cached-only)
        cached_only=1
        shift
        ;;
      *)
        usage
        ;;
    esac
  done
  command -v jq >/dev/null 2>&1 || die "jq not found"
  render_json "$cached_only"
}

cmd_serve() {
  local port=$FM_SEAT_BOARD_PORT_DEFAULT docroot server gen_pid='' srv_pid=''
  while [ $# -gt 0 ]; do
    case "$1" in
      --port)
        [ $# -ge 2 ] || usage
        case "$2" in '' | *[!0-9]*) usage ;; esac
        port=$2
        shift 2
        ;;
      *)
        usage
        ;;
    esac
  done
  command -v python3 >/dev/null 2>&1 || die "python3 not found"
  command -v jq >/dev/null 2>&1 || die "jq not found"
  command -v quota-axi >/dev/null 2>&1 || die "quota-axi not found"
  server="$SCRIPT_DIR/fm-seat-board-server.py"
  [ -f "$server" ] || die "$server not found"
  docroot=$(mktemp -d "${TMPDIR:-/tmp}/fm-seat-board.XXXXXX") || die "could not create a scratch directory"
  cleanup() {
    [ -z "${srv_pid:-}" ] || kill "$srv_pid" 2>/dev/null || true
    [ -z "${gen_pid:-}" ] || kill "$gen_pid" 2>/dev/null || true
    rm -rf "$docroot"
  }
  trap cleanup EXIT INT TERM
  render_page > "$docroot/index.html"
  (
    while true; do
      sleep "$FM_SEAT_BOARD_CACHE_SECONDS"
      render_page > "$docroot/index.html.tmp" && mv "$docroot/index.html.tmp" "$docroot/index.html"
    done
  ) &
  gen_pid=$!
  # The server prints the URL to open, because only it knows the per-run path
  # token, and the port too once --port 0 let the kernel choose one. Backgrounded
  # so cleanup can reach it: a background job starts with SIGINT ignored, so
  # Ctrl-C is handled by the INT trap, whose cleanup stops the server.
  python3 "$server" "$port" "$docroot/index.html" &
  srv_pid=$!
  wait "$srv_pid"
}

case "${1:-serve}" in
  serve)
    shift || true
    cmd_serve "$@"
    ;;
  --port)
    cmd_serve "$@"
    ;;
  render)
    cmd_render
    ;;
  json)
    shift
    cmd_json "$@"
    ;;
  -h | --help)
    usage
    ;;
  *)
    usage
    ;;
esac
