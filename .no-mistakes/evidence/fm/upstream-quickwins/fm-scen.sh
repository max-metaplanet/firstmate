#!/usr/bin/env bash
set -u
REPO=$1
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); "$REPO/bin/fm-lab-home.sh" create "$LAB" >/dev/null
M="$LAB/state/.inactive-outcome-reconcile"; L="$LAB/state/.inactive-outcome-reconcile.lock"
SHIM=$(mktemp -d /tmp/fm-shim.XXXXXX); LOG="$SHIM.log"
printf '#!/bin/sh\necho perl >> "%s"\nexec %s "$@"\n' "$LOG" "$(command -v perl)" > "$SHIM/perl"; chmod +x "$SHIM/perl"
run() { : > "$LOG"; env -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
  PATH="$SHIM:$PATH" FM_HOME="$LAB" FM_INACTIVE_RECONCILE_SECS=60 FM_INACTIVE_RECONCILE_BUDGET_SECS=2 "$REPO/bin/fm-inactive-reconcile.sh" scan "$@"; }
mt() { stat -f %m "$M"; }
timed() { [ -s "$LOG" ] && echo "timed re-exec: YES (perl)" || echo "timed re-exec: no"; }
echo "## lab home $LAB (no timeout/gtimeout on host: $(command -v timeout gtimeout || echo none))"
run; echo "S0 first poll, no marker: rc=$? $(timed) marker_mtime=$(mt)"
run; echo "S1 idle not-due poll: rc=$? $(timed) marker_mtime=$(mt) (unchanged = no scan)"
touch -t 202001010000 "$M"; old=$(mt)
run; echo "S2 marker backdated to $old (due): rc=$? $(timed) marker_mtime=$(mt) (rewritten = scan ran)"
before=$(mt); sleep 1
run --startup; echo "S3 --startup with fresh marker $before: rc=$? $(timed) marker_mtime=$(mt) (rewritten = bypass honored)"
# adversarial: live holder of the scan lock
bash -c '. "$1/bin/fm-wake-lib.sh"; fm_lock_acquire_wait "$2"; echo held; sleep 20' _ "$REPO" "$L" & H=$!
sleep 1
s=$SECONDS; run; echo "S4 not-due poll while scan lock is held by live pid $H: rc=$? took=$((SECONDS-s))s $(timed) (returns without waiting on lock)"
touch -t 202001010000 "$M"; old=$(mt)
s=$SECONDS; run; echo "S5 DUE poll while scan lock is held: rc=$? took=$((SECONDS-s))s $(timed) marker_mtime=$(mt) vs $old (blocked on lock, backstop at budget+1, no scan)"
kill $H; wait $H 2>/dev/null
# adversarial: marker replaced by a symlink to a fresh file
rm -f "$M"; : > "$LAB/fresh-target"; ln -s "$LAB/fresh-target" "$M"
run; echo "S6 marker is a symlink to a fresh file: rc=$? $(timed) marker_is_symlink=$([ -L "$M" ] && echo yes || echo no) target_untouched=$([ -s "$LAB/fresh-target" ] && echo NO || echo yes)"
rm -rf "$LAB" "$SHIM" "$LOG"; echo "## lab removed"
