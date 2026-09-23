#!/usr/bin/env bash
# Live drive: arm the warner in a throwaway FM_HOME, then run the REAL bin/fm-watch.sh
# so its periodic check sweep dispatches the armed shim (real quota-axi read).
set -u
ROOT=/Users/max/.no-mistakes/worktrees/61c6dd39b831/01M37WQ78FK5ZNWFRM18FZ8GBR
W="$ROOT/bin/fm-usage-warner.sh"; WATCH="$ROOT/bin/fm-watch.sh"
T=$(mktemp -d /tmp/fm-uw-watch.XXXXXX); T=$(cd "$T" && pwd -P)
REALQ=$(command -v quota-axi)
mkdir -p "$T/bin"
printf '#!/usr/bin/env bash\nexit 0\n' > "$T/bin/tmux"
cat > "$T/bin/osascript" <<SH
#!/usr/bin/env bash
printf 'NOTIFY %s\n' "\${@: -1}" >> "$T/notify.log"
SH
cat > "$T/bin/quota-axi" <<SH
#!/usr/bin/env bash
if [ -n "\${HANG_QUOTA:-}" ]; then sleep 60; fi
exec "$REALQ" "\$@"
SH
chmod +x "$T/bin/"*
mk_home() { local h=$1; mkdir -p "$h/state" "$h/data" "$h/config" "$h/projects"; printf '# lab home\n' > "$h/AGENTS.md"; printf 'lab\n' > "$h/.fm-secondmate-home"; printf '## In flight\n\n## Queued\n\n## Done\n' > "$h/data/backlog.md"; }
watch_once() {  # <home> [extra env...]
  local h=$1; shift
  local start=$(date +%s)
  env "$@" PATH="$T/bin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$h" FM_POLL=1 FM_SIGNAL_GRACE=0 \
    FM_CHECK_INTERVAL=0 FM_HEARTBEAT=9999999 "$WATCH" > "$T/w.out" 2> "$T/w.err" &
  local pid=$! i=0
  while kill -0 $pid 2>/dev/null && [ $i -lt 400 ]; do sleep 0.1; i=$((i+1)); done
  kill $pid 2>/dev/null; wait $pid 2>/dev/null
  echo "[watcher ran $(( $(date +%s) - start ))s] stdout:"; sed 's/^/  | /' "$T/w.out"
  grep -i 'usage-warner\|reject\|unauth' "$T/w.err" | head -5 | sed 's/^/  err| /'
}
H="$T/home"; mk_home "$H"
printf 'five_hour:20\nseven_day:90\n' > "$H/config/usage-warner"
echo "== S6 arm in a configured home =="
PATH="$T/bin:$PATH" FM_HOME="$H" "$W" arm; echo "[exit=$?]"
ls -l "$H/state" | grep usage-warner
echo; echo "== S6 real watcher sweep #1 dispatches the armed check (live quota read) =="
watch_once "$H"
echo "notifications: $(cat "$T/notify.log" 2>/dev/null)"
echo; echo "== S6 real watcher sweep #2: already crossed, check silent (edge-triggered) =="
rm -f "$H/state/.last-check"; watch_once "$H" FM_WATCH_MAX_SECS=8
echo "notifications count: $(wc -l < "$T/notify.log")"
echo; echo "== S7 adversarial: FM_CHECK_TIMEOUT=5 and a hanging quota-axi under the real watcher =="
H2="$T/home2"; mk_home "$H2"; printf 'five_hour:20\n' > "$H2/config/usage-warner"
PATH="$T/bin:$PATH" FM_HOME="$H2" "$W" arm
watch_once "$H2" HANG_QUOTA=1 FM_CHECK_TIMEOUT=5
echo "--- record ---"; cat "$H2/state/.usage-warner"
echo; echo "== S7b FM_CHECK_TIMEOUT=2 (no room) with hanging read, on demand =="
s=$(date +%s); HANG_QUOTA=1 FM_CHECK_TIMEOUT=2 PATH="$T/bin:$PATH" FM_HOME="$H2" "$W" check; echo "[exit=$? after $(( $(date +%s)-s ))s]"
cat "$H2/state/.usage-warner"
echo; echo "== S8 disarm =="
PATH="$T/bin:$PATH" FM_HOME="$H" "$W" disarm; echo "[exit=$?]"
ls -A "$H/state" | grep -i usage-warner || echo "no usage-warner shim, trust, or record left in state/"
echo; echo "== S8 real watcher sweep after disarm: no usage-warner dispatch =="
rm -f "$H/state/.last-check"; : > "$T/notify.log"; watch_once "$H" FM_WATCH_MAX_SECS=8
echo "notifications count: $(wc -l < "$T/notify.log")"
pkill -f "$T/" 2>/dev/null; rm -rf "$T"
