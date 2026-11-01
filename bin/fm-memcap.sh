#!/usr/bin/env bash
# fm-memcap.sh - the single owner of running one command under a hard memory cap.
#
# ShellCheck's extended dataflow analysis sizes its heap to the memory it can
# see rather than to a fixed per-root cost, so an analysis that fits a CI runner
# can exhaust a developer desktop and take the whole session down with it. This
# script is the one place that knows how to bound such a command on this host,
# what budget to give it, and how to report that the bound fired. Callers name
# the command and the share; they never restate the mechanism or the formula.
#
# Mechanisms, in preference order:
#   cgroup  a transient systemd user scope with MemoryMax and MemorySwapMax=0.
#           A resident ceiling: the kernel OOM-kills inside the scope instead of
#           letting a runaway swap the machine to a halt, which is what makes a
#           desktop freeze rather than fail. Selected only when a probe scope
#           actually starts, never merely because systemd-run is on PATH.
#   rlimit  ulimit -v. This caps ADDRESS SPACE, not resident memory, so a
#           runtime that reserves lazily still overshoots the figure and a
#           runaway can swap. It is the weaker mechanism and is used only where
#           no systemd user scope is available.
#   none    neither works, for example a macOS home or a container with no
#           session bus. The command then runs uncapped after exactly one
#           warning on stderr, because refusing would turn every such host's
#           lint into a hard failure.
#
# Budget: floor(MemTotal * FM_MEMCAP_PERCENT / 100 / share), with
# FM_MEMCAP_PERCENT defaulting to 45 and share defaulting to 1. FM_MEMCAP_BYTES
# replaces the MemTotal-derived figure and is still divided by share. MemTotal
# comes from /proc/meminfo on Linux and `sysctl -n hw.memsize` on Darwin; when
# neither is readable the budget falls back to 2 GiB and says so on stderr. A
# computed budget is never below 256 MiB. --share divides concurrent workers'
# caps so the AGGREGATE, not the per-process figure, is what bounds the machine.
# --bytes names one cap exactly; it is not a budget, so neither the share
# division nor the floor applies to it, and it cannot be combined with
# --budget-bytes.
#
# When the cgroup cap fires, the command's basename and the cap are named as
#   fm-memcap: <command> was killed by its <bytes>-byte memory cap
# on stderr and the exit status is 137. Callers classify that exact line, so
# keep its wording stable. Any other outcome passes the command's own exit
# status through unchanged. Invalid input exits 2.
#
# The kill verdict comes from the scope's own memory.events oom_kill counter,
# read by a small inner shell after the command exits and reported on a private
# file descriptor so the command's own stdout and stderr stay untouched. That
# shell traps TERM: once the kernel OOM-kills the hog, systemd tears the rest of
# the scope down, and an untrapped shell loses that race about half the time and
# reports a bare SIGTERM with no counter. If the inner shell is killed anyway
# the status alone carries the verdict, which is why a status of 137 with no
# counter still reports the cap.
#
# Usage:
#   fm-memcap.sh --mechanism                 print cgroup, rlimit, or none
#   fm-memcap.sh --budget-bytes [--share N]  print the per-process cap in bytes
#   fm-memcap.sh [--bytes N] [--share N] -- COMMAND [ARGS...]
#   fm-memcap.sh --help                      print this usage
set -u

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SELF="$SELF_DIR/fm-memcap.sh"

DEFAULT_PERCENT=45
FLOOR_BYTES=$((256 * 1024 * 1024))
FALLBACK_TOTAL_BYTES=$((2 * 1024 * 1024 * 1024))
PROBE_LIMIT_KIB=1048576

# Runs the command, then reports the scope's oom_kill count on fd 3. Kept small
# so the kernel's cgroup OOM killer picks the hog rather than this shell.
# shellcheck disable=SC2016 # The inner shell expands these, not this one.
INNER_SHELL='trap : TERM
status=0
"$@" 3>&- || status=$?
cgroup=$(sed -n "s/^0:://p" /proc/self/cgroup 2>/dev/null | head -n 1)
[ -z "$cgroup" ] || sed -n "s/^oom_kill /oom_kill=/p" "/sys/fs/cgroup$cgroup/memory.events" >&3 2>/dev/null
exit "$status"'

fm_memcap_usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$SELF"
}

fm_memcap_die() {  # <message>
  printf 'fm-memcap: %s\n' "$1" >&2
  exit 2
}

fm_memcap_positive() {  # <value>
  case "${1:-}" in
    ''|0*|*[!0-9]*) return 1 ;;
  esac
  return 0
}

fm_memcap_mem_total() {
  local total=
  if [ -r /proc/meminfo ]; then
    total=$(awk '$1 == "MemTotal:" { printf "%.0f\n", $2 * 1024; exit }' /proc/meminfo 2>/dev/null)
  elif [ "$(uname -s 2>/dev/null)" = Darwin ]; then
    total=$(sysctl -n hw.memsize 2>/dev/null)
  fi
  if ! fm_memcap_positive "$total"; then
    printf 'fm-memcap: total memory is not readable on this host; budgeting against %s bytes\n' \
      "$FALLBACK_TOTAL_BYTES" >&2
    total=$FALLBACK_TOTAL_BYTES
  fi
  printf '%s\n' "$total"
}

fm_memcap_budget_bytes() {  # <share>
  local share=$1 percent total bytes
  percent=${FM_MEMCAP_PERCENT:-$DEFAULT_PERCENT}
  fm_memcap_positive "$percent" \
    || fm_memcap_die "FM_MEMCAP_PERCENT must be a positive integer, got $percent"
  if [ -n "${FM_MEMCAP_BYTES:-}" ]; then
    fm_memcap_positive "$FM_MEMCAP_BYTES" \
      || fm_memcap_die "FM_MEMCAP_BYTES must be a positive integer, got $FM_MEMCAP_BYTES"
    bytes=$((FM_MEMCAP_BYTES / share))
  else
    total=$(fm_memcap_mem_total)
    bytes=$((total * percent / 100 / share))
  fi
  [ "$bytes" -ge "$FLOOR_BYTES" ] || bytes=$FLOOR_BYTES
  printf '%s\n' "$bytes"
}

fm_memcap_mechanism() {
  if command -v systemd-run >/dev/null 2>&1 \
    && systemd-run --user --scope --quiet --collect -p MemoryMax=64M -- true >/dev/null 2>&1; then
    printf 'cgroup\n'
    return 0
  fi
  if ( ulimit -v "$PROBE_LIMIT_KIB" ) 2>/dev/null; then
    printf 'rlimit\n'
    return 0
  fi
  printf 'none\n'
}

fm_memcap_report_kill() {  # <command-basename> <bytes>
  printf 'fm-memcap: %s was killed by its %s-byte memory cap\n' "$1" "$2" >&2
}

fm_memcap_run_cgroup() {  # <bytes> <command...>
  local bytes=$1 name report status oom_count
  shift
  name=${1##*/}
  # fd 3 carries the inner shell's counter and the scope's exit status back here
  # while fd 4, bound to this script's real stdout before the capture opens,
  # keeps the command's own output going to the caller.
  { report=$( { systemd-run --user --scope --quiet --collect \
        -p "MemoryMax=$bytes" -p MemorySwapMax=0 \
        -- /bin/sh -c "$INNER_SHELL" fm-memcap "$@" 3>&1 1>&4
      printf 'status=%s\n' "$?"; } ); } 4>&1
  status=$(printf '%s\n' "$report" | sed -n 's/^status=//p' | tail -n 1)
  oom_count=$(printf '%s\n' "$report" | sed -n 's/^oom_kill=//p' | tail -n 1)
  case "$status" in ''|*[!0-9]*) status=0 ;; esac
  if fm_memcap_positive "$oom_count" \
    || { [ -z "$oom_count" ] && [ "$status" -eq 137 ]; }; then
    fm_memcap_report_kill "$name" "$bytes"
    exit 137
  fi
  exit "$status"
}

MODE=run
BYTES=
SHARE=1
while [ "$#" -gt 0 ]; do
  case "$1" in
    --help|-h)
      fm_memcap_usage
      exit 0
      ;;
    --mechanism) MODE=mechanism; shift ;;
    --budget-bytes) MODE=budget; shift ;;
    --bytes)
      [ "$#" -ge 2 ] || fm_memcap_die '--bytes needs a byte count'
      BYTES=$2
      shift 2
      ;;
    --bytes=*) BYTES=${1#--bytes=}; shift ;;
    --share)
      [ "$#" -ge 2 ] || fm_memcap_die '--share needs a worker count'
      SHARE=$2
      shift 2
      ;;
    --share=*) SHARE=${1#--share=}; shift ;;
    --)
      shift
      break
      ;;
    *) fm_memcap_die "unknown argument: $1" ;;
  esac
done

fm_memcap_positive "$SHARE" \
  || fm_memcap_die "--share must be a positive integer, got $SHARE"
if [ -n "$BYTES" ]; then
  fm_memcap_positive "$BYTES" \
    || fm_memcap_die "--bytes must be a positive integer, got $BYTES"
fi

case "$MODE" in
  mechanism)
    [ "$#" -eq 0 ] || fm_memcap_die '--mechanism takes no command'
    fm_memcap_mechanism
    exit 0
    ;;
  budget)
    [ "$#" -eq 0 ] || fm_memcap_die '--budget-bytes takes no command'
    [ -z "$BYTES" ] || fm_memcap_die '--bytes names a cap directly, so it cannot be combined with --budget-bytes'
    fm_memcap_budget_bytes "$SHARE"
    exit 0
    ;;
esac

[ "$#" -gt 0 ] || fm_memcap_die 'no command to run; pass it after --'
[ -n "$BYTES" ] || BYTES=$(fm_memcap_budget_bytes "$SHARE")

case "$(fm_memcap_mechanism)" in
  cgroup)
    fm_memcap_run_cgroup "$BYTES" "$@"
    ;;
  rlimit)
    if ulimit -v "$((BYTES / 1024))" 2>/dev/null; then
      exec "$@"
    fi
    printf 'fm-memcap: this host refused a %s-byte address-space limit; running %s uncapped\n' \
      "$BYTES" "${1##*/}" >&2
    exec "$@"
    ;;
  *)
    printf 'fm-memcap: this host offers no memory-cap mechanism (no usable systemd user scope, no address-space limit); running %s uncapped\n' \
      "${1##*/}" >&2
    exec "$@"
    ;;
esac
