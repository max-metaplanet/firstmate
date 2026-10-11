#!/usr/bin/env bash
# Live wake-latency + TERM-stop probe for one fm-watch.sh tree.
# Usage: wake-latency-ab.sh <repo-root> <label>
set -u
ROOT=$1; LABEL=$2
D=$(mktemp -d "${TMPDIR:-/tmp}/fm-lat.XXXXXX"); H="$D/home"; S="$H/state"; SH="$D/shim"
mkdir -p "$S" "$SH" "$H/config"
cat > "$SH/tmux" <<'T'
#!/bin/bash
case "${1:-}" in
  list-windows) printf 'fm-t1\nfm-t2\nfm-t3\n' ;;
  capture-pane) printf 'pane %s\n' "$RANDOM" ;;
esac
exit 0
T
printf '#!/bin/bash\nprintf "state: working \\xc2\\xb7 source: run \\xc2\\xb7 fake\\n"\n' > "$SH/fm-crew-state.sh"
chmod +x "$SH/tmux" "$SH/fm-crew-state.sh"
for i in 1 2 3; do
  printf 'window=bench:fm-t%s\nbackend=tmux\nharness=claude\nkind=ship\n' "$i" > "$S/t$i.meta"
  printf 'working: quiet\n' > "$S/t$i.status"
done
FM_STATE_OVERRIDE="$S" bash -c '. "$1/bin/fm-wake-lib.sh"; for f in "$2"/*.status; do fm_wake_status_mark_current "$2" "$f"; done' _ "$ROOT" "$S" >/dev/null 2>&1
PATH="$SH:$PATH" FM_HOME="$H" FM_STATE_OVERRIDE="$S" FM_CONFIG_OVERRIDE="$H/config" \
  FM_CREW_STATE_BIN="$SH/fm-crew-state.sh" FM_POLL=${POLL:-15} FM_SIGNAL_GRACE=1 \
  FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_HOME_SUMMARY_INTERVAL=999999 \
  FM_SECONDMATE_LIVENESS_SECS=99999999 \
  bash "$ROOT/bin/fm-watch.sh" > "$D/watch.out" 2> "$D/watch.err" &
W=$!
sleep 8
t0=$(perl -MTime::HiRes=time -e 'printf "%.2f", time')
printf 'blocked: need a decision on X\n' >> "$S/t1.status"
lat=timeout
for _ in $(seq 1 1200); do
  if [ -s "$D/watch.out" ]; then lat=$(perl -MTime::HiRes=time -e "printf '%.2f', time-$t0"); break; fi
  if ! kill -0 $W 2>/dev/null; then lat=$(perl -MTime::HiRes=time -e "printf '%.2f', time-$t0"); break; fi
  sleep 0.05
done
alive=no; kill -0 $W 2>/dev/null && alive=yes
ts=$(perl -MTime::HiRes=time -e 'printf "%.2f", time'); kill -TERM $W 2>/dev/null
ex=no; for _ in $(seq 1 100); do kill -0 $W 2>/dev/null || { ex=yes; break; }; sleep 0.05; done
te=$(perl -MTime::HiRes=time -e "printf '%.2f', time-$ts")
[ $ex = yes ] || kill -KILL $W 2>/dev/null
wait $W 2>/dev/null; rc=$?
lock=no; [ -e "$S/.watch.lock" ] || [ -d "$S/watch.lock" ] && lock=yes
echo "label=$LABEL poll=${POLL:-15}s wake_latency_s=$lat watcher_alive_after_wake=$alive exited_after_term=$ex term_to_exit_s=$te rc=$rc"
echo "surfaced: $(head -1 "$D/watch.out")"
[ -s "$D/watch.err" ] && { echo "stderr:"; head -5 "$D/watch.err"; }
ls -a "$S" | grep -i lock | sed 's/^/state-lock-entry: /'
rm -rf "$D"
