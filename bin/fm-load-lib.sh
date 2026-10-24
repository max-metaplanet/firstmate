#!/usr/bin/env bash
# fm-load-lib.sh - the one owner of machine load normalization, with no
# dependencies and no source-time side effects. fm-wake-lib.sh's load-scaled
# watch budget and fm-fleet-load.py's capacity sampler both read it.

# Fixed-point load per CPU in hundredths, so no caller depends on a
# float-capable tool. An unparseable load or CPU count returns 1.
fm_load_normalize_centi() { # <load> <cpus>
  local load=$1 cpus=$2 whole frac
  case "$cpus" in ''|*[!0-9]*|0) return 1 ;; esac
  case "$load" in
    ''|*[!0-9.]*|*.*.*) return 1 ;;
    *.*) whole=${load%%.*}; frac=${load#*.} ;;
    *) whole=$load; frac=0 ;;
  esac
  [ -n "$whole" ] || whole=0
  frac="${frac}00"
  printf '%s\n' $(( (10#$whole * 100 + 10#${frac:0:2}) / cpus ))
}

# Explicit-validity macOS load reading for capacity sampling. No fallback may
# masquerade as health: load1 load5 CPUs normalized-load1 normalized-load5.
fm_machine_load_sample() {
  local load1 load5 cpus one five
  read -r load1 load5 _ < <(sysctl -n vm.loadavg 2>/dev/null | tr -d '{}') || return 1
  case "$load1" in *[0-9]*) ;; *) return 1 ;; esac
  case "$load5" in *[0-9]*) ;; *) return 1 ;; esac
  cpus=$(sysctl -n hw.ncpu 2>/dev/null) || return 1
  one=$(fm_load_normalize_centi "$load1" "$cpus") || return 1
  five=$(fm_load_normalize_centi "$load5" "$cpus") || return 1
  printf '%s %s %s %s %s\n' "$load1" "$load5" "$cpus" "$one" "$five"
}
