#!/usr/bin/env bash
# usage: fm-measure.sh <repo-root> <label> <evdir>
set -u
REPO=$1; LABEL=$2; EV=$3
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
"$REPO/bin/fm-lab-home.sh" create "$LAB" >/dev/null
SHIM=$(mktemp -d /tmp/fm-shim.XXXXXX); LOG="$SHIM.log"; : > "$LOG"
IFS=: read -ra dirs <<< "$PATH"
for d in "${dirs[@]}"; do
  [ -d "$d" ] || continue
  for f in "$d"/*; do
    n=$(basename "$f"); [ -x "$f" ] && [ ! -d "$f" ] || continue
    [ -e "$SHIM/$n" ] && continue
    printf '#!/bin/sh\nprintf "%%s\\n" "%s" >> "%s"\nexec "%s" "$@"\n' "$n" "$LOG" "$f" > "$SHIM/$n"; chmod +x "$SHIM/$n"
  done
done
run() { env -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
  PATH="$SHIM:$PATH" FM_HOME="$LAB" "$REPO/bin/fm-inactive-reconcile.sh" scan "$@"; }
{
echo "== $LABEL: lab home $LAB, timeout=$(command -v timeout || echo none) gtimeout=$(command -v gtimeout || echo none)"
run; echo "first (due, no marker) poll rc=$?  marker: $(cat "$LAB/state/.inactive-outcome-reconcile" | tr '\n' ' ')"
: > "$LOG"
run; rc=$?
echo "idle not-due poll rc=$rc; external commands via PATH ($(wc -l < "$LOG" | tr -d ' ')):"; sort "$LOG" | uniq -c | sed 's/^/   /'
} | tee "$EV/process-count-$LABEL.txt"
rm -rf "$LAB" "$SHIM" "$LOG"
