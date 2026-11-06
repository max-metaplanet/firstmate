#!/usr/bin/env bash
# Scratch live driver (not committed): real interactive Claude primary in tmux,
# real tracked Stop hook, real supervision host with the real claude engine, in
# disposable lab copies of this checkout. Never touches a live fleet home.
#   intermediate/live-t3-handoff.sh host-on [base-ref]   # handling handoff race
#   intermediate/live-t3-handoff.sh host-off             # host-off successor checks
# shellcheck disable=SC2016
set -u
. "$(dirname "${BASH_SOURCE[0]}")/../tests/lib.sh"
. "$ROOT/bin/fm-tmux-lib.sh"

MODE=${1:?host-on|host-off}
CONTROL_REF=${2:-}
MODEL=${LIVE_PRIMARY_MODEL:-sonnet}
CLAUDE_VERSION=$(claude --version 2>/dev/null | head -n 1)
LAB=$(fm_test_tmproot fm-live-t3)
LAB=$(cd -P "$LAB" && pwd -P)
SOCKET="fmlt3-$$"
PROJECTS="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects"
TURN_POLLS=1800
unset FM_HOME FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE FM_DATA_OVERRIDE TMUX TMUX_PANE PI_CODING_AGENT NO_MISTAKES_GATE
while IFS= read -r name; do unset "$name"; done < <(env | grep -E '^(CLAUDECODE|CLAUDE_CODE_[A-Z_]+|CLAUDE_PID|CLAUDE_EFFORT)=' | cut -d= -f1 | sort -u)

evidence() { printf '# %s %s\n' "$(date '+%H:%M:%S')" "$*"; }
FM="$LAB/fm"
stop_lab() {
  local pid
  tmux -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  sleep 1
  if [ -f "$FM/state/.supervision-host" ]; then
    pid=$(awk -F '\t' '$1 == "host" { print $2; exit }' "$FM/state/.supervision-host")
    [ -z "$pid" ] || kill -TERM "$pid" 2>/dev/null || true
  fi
  pid=$(cat "$FM/state/.watch.lock/pid" 2>/dev/null || true)
  [ -z "$pid" ] || kill -TERM "$pid" 2>/dev/null || true
  sleep 1
  pkill -TERM -f "$FM/bin/" 2>/dev/null || true
  rm -rf "${PROJECTS:?}/$(printf '%s' "$FM" | sed 's/[^A-Za-z0-9]/-/g')"
}
cleanup() { stop_lab; fm_test_cleanup; }
trap cleanup EXIT
trap 'exit 130' INT; trap 'exit 143' TERM

wait_until() { local limit=$1 i=0; shift; while [ "$i" -lt "$limit" ]; do "$@" && return 0; sleep 0.1; i=$((i + 1)); done; return 1; }
transcript() { find "$PROJECTS/$(printf '%s' "$FM" | sed 's/[^A-Za-z0-9]/-/g')" -maxdepth 1 -name '*.jsonl' -print 2>/dev/null | head -n 1; }
rewakes_since() {
  local t; t=$(transcript); [ -n "$t" ] || return 0
  jq -r --argjson since "$1" '
    select(.type == "queue-operation" and .operation == "enqueue")
    | select((.content // "" | tostring) | contains("firstmate watcher wake"))
    | (.timestamp | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) as $at
    | select($at >= $since) | "\($at) \(.content | tostring | .[0:300])"' "$t" 2>/dev/null
}
commands_since() {
  local t; t=$(transcript); [ -n "$t" ] || return 0
  jq -r --argjson since "$1" '
    select(.type == "assistant")
    | (.timestamp | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) as $at
    | select($at >= $since)
    | .message.content[]? | select(.type == "tool_use") | "\(.name): \(.input.command // "")"' "$t" 2>/dev/null
}
turn_idle() {
  local t; t=$(transcript); [ -n "$t" ] || return 1
  jq -e --argjson since "$1" 'select(.type == "system" and .subtype == "turn_duration")
    | select((.timestamp | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) >= $since)' "$t" >/dev/null 2>&1
}
host_live() { local pid; pid=$(awk -F '\t' '$1 == "host" { print $2; exit }' "$FM/state/.supervision-host" 2>/dev/null); [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; }
watcher_live() { local pid; pid=$(cat "$FM/state/.watch.lock/pid" 2>/dev/null) && [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; }
diagnose() {
  printf -- '--- host log\n%s\n--- checks\n%s\n--- queue\n%s\n--- marker: %s\n--- ledger: %s\n--- screen\n%s\n' \
    "$(cat "$FM/state/.supervision-host.log" 2>/dev/null)" "$(cat "$LAB/check-runs.log" 2>/dev/null)" \
    "$(cat "$FM/state/.wake-queue" 2>/dev/null)" "$(cat "$FM/state/.watcher-down" 2>/dev/null)" \
    "$(cat "$FM/state/.claude-autoarm-epoch" 2>/dev/null)" \
    "$(tmux -L "$SOCKET" capture-pane -p -t primary 2>/dev/null | tail -n 25)"
}
choose() {
  local cursor target moves key
  cursor=$(printf '%s\n' "$1" | grep -n '❯' | head -n 1 | cut -d: -f1)
  target=$(printf '%s\n' "$1" | grep -nF -- "$2" | head -n 1 | cut -d: -f1)
  [ -n "$cursor" ] && [ -n "$target" ] || return 0
  moves=$((target - cursor)); key=Down
  [ "$moves" -ge 0 ] || { key=Up; moves=$((0 - moves)); }
  while [ "$moves" -gt 0 ]; do tmux -L "$SOCKET" send-keys -t primary "$key"; sleep 0.3; moves=$((moves - 1)); done
  tmux -L "$SOCKET" send-keys -t primary Enter; sleep 3
}
ready() {
  local busy composer
  tmux() { command tmux -L "$SOCKET" "$@"; }
  busy=$(fm_pane_busy_state primary claude); composer=$(fm_tmux_composer_state primary)
  unset -f tmux
  [ "$busy" = idle ] && [ "$composer" = empty ]
}
type_prompt() { tmux -L "$SOCKET" send-keys -t primary -l "$1"; sleep 1; tmux -L "$SOCKET" send-keys -t primary Enter; }

# --- lab ----------------------------------------------------------------------
mkdir -p "$FM" "$LAB/bin"
git -C "$ROOT" ls-files -z -co --exclude-standard | grep -zv '^intermediate/' \
  | (cd "$ROOT" && tar --null -T - -cf -) | (cd "$FM" && tar -xf -)
if [ -n "$CONTROL_REF" ]; then
  # Control: the product files at the base ref; HEAD's arm keeps the test seam.
  for f in bin/fm-watch.sh bin/fm-wake-lib.sh bin/fm-supervision-host.sh; do
    git -C "$ROOT" show "$CONTROL_REF:$f" > "$FM/$f" || fail "control: cannot read $f at $CONTROL_REF"
  done
fi
git -C "$FM" init -q -b main
git -C "$FM" add -A >/dev/null
git -C "$FM" -c user.name=fmtest -c user.email=fmtest@example.invalid commit -q -m lab
mkdir -p "$FM/state" "$FM/config" "$FM/data"
case "$MODE" in
  host-on) : > "$FM/config/supervision-host" ;;
  host-off) : > "$FM/config/supervision-host-off" ;;
esac
printf 'project=demo\nwindow=fm-demo\nharness=claude\n' > "$FM/state/demo.meta"
: > "$FM/state/demo.status"
printf '#!/usr/bin/env bash\nexit 1\n' > "$LAB/bin/tmux"; chmod +x "$LAB/bin/tmux"
cat > "$LAB/env" <<ENV
export FM_HOME='$FM'
export FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=0 FM_HEARTBEAT=999999
export FM_TEST_SEAM=1 FM_TEST_HANDLING_CONFIRM_DELAY=1
export FM_GATE_REFUSE_BYPASS=1
export CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false CLAUDE_CODE_SEND_FEEDBACK=0
export PATH='$LAB/bin':"\$PATH"
ENV

# A trusted home check. Every run logs who ran it and the marker it saw. In the
# host-on scenario the handoff successor's run waits for the confirm window
# (the seam's stamp) and then appends one check wake, the live race.
cat > "$LAB/check-body.sh" <<SH
#!/usr/bin/env bash
log='$LAB/check-runs.log'
printf '%s successor=%s confirm=%s gap=%s stamp=%s marker=%s\n' "\$(date +%s.%N)" "\${FM_WATCH_HANDLING_SUCCESSOR:-0}" \
  "\${FM_WATCH_HANDOFF_CONFIRM:-}" "\${FM_WATCH_GAP_SUCCESSOR:-0}" "\$([ -f "\$FM_HOME/state/.fm-test-handling-confirm-wait" ] && echo yes || echo no)" \
  "\$(cat "\$FM_HOME/state/.watcher-down" 2>/dev/null || echo none)" >> "\$log"
[ '$MODE' = host-on ] || exit 0
[ "\${FM_WATCH_HANDLING_SUCCESSOR:-0}" = 1 ] || exit 0
[ ! -e '$LAB/check-appended' ] || exit 0
stamp="\$FM_HOME/state/.fm-test-handling-confirm-wait"
i=0
while [ "\$i" -lt 80 ]; do [ -f "\$stamp" ] && break; sleep 0.05; i=\$((i + 1)); done
[ -f "\$stamp" ] || exit 0
: > '$LAB/check-appended'
printf '%s appended marker-before=%s\n' "\$(date +%s.%N)" "\$(cat "\$FM_HOME/state/.watcher-down" 2>/dev/null || echo none)" >> "\$log"
FM_HOME="\$FM_HOME" bash -c '. "\$1"; fm_wake_append check lab-seat "check: lab-seat during handoff"' _ "\$FM_HOME/bin/fm-wake-lib.sh" || exit 0
sleep 3
exit 0
SH
cp "$LAB/check-body.sh" "$FM/state/lab-seat.check.sh"
chmod 700 "$FM/state/lab-seat.check.sh"
printf 'fm-custom-check-v1\n%s\n' "$(sha256sum "$FM/state/lab-seat.check.sh" | awk '{ print $1 }')" > "$FM/state/lab-seat.check-trust"
chmod 600 "$FM/state/lab-seat.check-trust"

case "$MODE" in
  host-on) WAKE_RULE='whenever a "Stop hook feedback" message wakes you, do exactly this and nothing else: run `bin/fm-wake-drain.sh` once with the Bash tool, then run the exact `bin/fm-wake-drain.sh --ack-through ...` command its WAKE_ACK_REQUIRED line prints, then reply with exactly ACKED.' ;;
  host-off) WAKE_RULE='whenever a "Stop hook feedback" message wakes you, reply with exactly SEEN and use no tools at all (do not drain).' ;;
esac
PROMPT="This is an isolated Firstmate test lab, not a real fleet. Reply with exactly READY now and use no tools. Later, $WAKE_RULE When I send PING, reply exactly PONG and use no tools. Never run bin/fm-watch-arm.sh or any command not named here."

# --- primary ------------------------------------------------------------------
started=$(date +%s)
tmux -L "$SOCKET" new-session -d -s primary -x 220 -y 50 -c "$FM" \
  "sh -c '. \"$LAB/env\"; printf \"%s\\n\" \"\$\$\" > state/.lock; exec claude --model $MODEL --effort low --dangerously-skip-permissions'" \
  || fail "tmux did not start"
i=0
while [ "$i" -lt 90 ]; do
  screen=$(tmux -L "$SOCKET" capture-pane -p -t primary 2>/dev/null)
  case "$screen" in
    *'Yes, I trust this folder'*) choose "$screen" 'Yes, I trust this folder' ;;
    *'Yes, I accept'*) choose "$screen" 'Yes, I accept' ;;
    *'external CLAUDE.md'*|*'external imports'*) choose "$screen" 'Yes, allow external imports' ;;
    *) ready && break ;;
  esac
  sleep 1; i=$((i + 1))
done
[ "$i" -lt 90 ] || fail "Claude never reached an idle composer"$'\n'"$(diagnose)"
sleep 2
type_prompt "$PROMPT"
if [ "$MODE" = host-on ]; then
  wait_until "$TURN_POLLS" host_live || fail "the setup turn's Stop hook never started the host"$'\n'"$(diagnose)"
fi
wait_until 600 watcher_live || fail "no watcher after the setup turn"$'\n'"$(diagnose)"
wait_until "$TURN_POLLS" turn_idle "$started" || fail "setup turn never ended"$'\n'"$(diagnose)"
sleep 3
evidence "$MODE${CONTROL_REF:+ control@$CONTROL_REF}: primary $CLAUDE_VERSION model $MODEL idle (pid $(cat "$FM/state/.lock")); watcher $(cat "$FM/state/.watch.lock/pid"); host record: $( { tr '\t' ' ' < "$FM/state/.supervision-host" | head -n 1; } 2>/dev/null)"
evidence "config: $(ls "$FM/config" | tr '\n' ' ')"
evidence "setup-phase rewakes:"; rewakes_since "$started" | sed 's/^/#   /'
evidence "setup-phase check runs:"; sed 's/^/#   /' "$LAB/check-runs.log" 2>/dev/null

t0=$(date +%s)
if [ "$MODE" = host-on ]; then
  printf 'working [at=%s]: step one of the demo cleanup\n' "$t0" >> "$FM/state/demo.status"
  evidence "appended routine status; waiting for the host to take or hand back the signal"
  settled() { grep -qE $'\t(handled|to-main)\t' "$FM/state/.supervision-host.log" 2>/dev/null || [ -n "$(rewakes_since "$t0")" ]; }
  wait_until 3000 settled || fail "the signal was neither taken nor handed back"$'\n'"$(diagnose)"
  sleep 30
  # A rewoken primary turn (control) or none (fix) ends before the next park.
  wait_until "$TURN_POLLS" ready || true
  t1=$(date +%s)
  evidence "forcing a fresh primary turn end so the Stop hook parks again"
  type_prompt PING
  wait_until "$TURN_POLLS" turn_idle "$t1" || fail "the PING turn never ended"$'\n'"$(diagnose)"
  sleep 30
  evidence "full host log:"; cat "$FM/state/.supervision-host.log" | sed 's/^/#   /'
  evidence "check runs:"; sed 's/^/#   /' "$LAB/check-runs.log"
  evidence "rewakes delivered to the primary since t0:"; rewakes_since "$t0" | sed 's/^/#   /'
  evidence "primary tool calls since t0:"; commands_since "$t0" | sed 's/^/#   /'
  evidence "marker now: $(cat "$FM/state/.watcher-down" 2>/dev/null || echo none); watcher live: $(watcher_live && echo yes || echo no); host live: $(host_live && echo yes || echo no)"
  [ -e "$LAB/check-appended" ] || fail "the race was not opened: the handoff successor's check never appended"$'\n'"$(diagnose)"
  rc=0
  grep -q 'could not be confirmed' "$FM/state/.supervision-host.log" && { evidence "RESULT: handoff could not be confirmed"; rc=1; }
  grep -q 'check: rearm-resurface' "$FM/state/.supervision-host.log" && { evidence "RESULT: a park handed check: rearm-resurface"; rc=1; }
  grep -qE $'\thandled\t.*signal: ' "$FM/state/.supervision-host.log" || { evidence "RESULT: the host never handled the signal"; rc=1; }
  [ -z "$(rewakes_since "$t0")" ] || { evidence "RESULT: main was rewoken"; rc=1; }
  if [ "$rc" -eq 0 ]; then
    pass "host-on live: the host confirmed the handoff, took the signal, and the next park handed main no check: rearm-resurface"
  else
    printf 'not ok - host-on live%s: the loop reproduced\n' "${CONTROL_REF:+ control@$CONTROL_REF}"
    exit 1
  fi
else
  printf 'needs-attention [at=%s]: please look at the demo\n' "$t0" >> "$FM/state/demo.status"
  evidence "appended a status signal; waiting for the Stop hook rewake and its handling successor"
  succ_check() { awk -v t="$t0" '$1 >= t && / successor=1 /' "$LAB/check-runs.log" 2>/dev/null | grep -q .; }
  rewoken() { [ -n "$(rewakes_since "$t0")" ]; }
  wait_until "$TURN_POLLS" rewoken || fail "the primary was not rewoken"$'\n'"$(diagnose)"
  wait_until 1200 succ_check || fail "the host-off handling successor never ran its check sweep"$'\n'"$(diagnose)"
  wait_until "$TURN_POLLS" turn_idle "$t0" || true
  sleep 10
  evidence "autoarm ledger: $(cat "$FM/state/.claude-autoarm-epoch" 2>/dev/null)"
  evidence "rewakes delivered since t0:"; rewakes_since "$t0" | sed 's/^/#   /'
  evidence "primary tool calls since t0 (expect none: no drain):"; commands_since "$t0" | sed 's/^/#   /'
  evidence "check runs:"; sed 's/^/#   /' "$LAB/check-runs.log"
  evidence "marker now: $(cat "$FM/state/.watcher-down" 2>/dev/null || echo none); watcher $(cat "$FM/state/.watch.lock/pid" 2>/dev/null) live: $(watcher_live && echo yes || echo no)"
  [ -n "$(rewakes_since "$t0")" ] || fail "the primary was not rewoken"
  ! commands_since "$t0" | grep -q 'fm-wake-drain' || fail "the primary drained; the scenario needs no drain"
  first=$(awk -v t="$t0" '$1 >= t && / successor=1 /' "$LAB/check-runs.log" | head -n 1)
  case "$first" in *'confirm= '*) ;; *) fail "the host-off successor carried a confirm signal: $first" ;; esac
  case "$first" in *'marker='*':handling:'*) fail "the successor's first check ran only after handling: $first" ;; esac
  pass "host-off live: the Claude Stop hook's handling successor (no confirm signal) ran its check sweep before any drain ($first)"
fi
