#!/usr/bin/env bash
# Count program starts and shell children in three warmed, real polling cycles.
# BASH_ENV's DEBUG instrumentation observes execution, never implementation text.
# FM_FORK_BUDGET_ROOT permits the same sampler against a saved pre-change bin/;
# FM_FORK_BUDGET_REPORT_ONLY=1 reports that baseline without enforcing new budgets.
set -u
# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"
. "$ROOT/bin/fm-timeout-lib.sh"
if [ "${BASH_VERSINFO[0]}" -lt 4 ] || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -lt 2 ]; }; then
  printf 'skip: zero-fork sampler needs dynamic descriptors and builtin epoch clock (Bash 4.2+)\n'
  exit 0
fi
TMP_ROOT=$(fm_test_tmproot fm-supervision-fork-budget)
budget_cleanup() {
  local record pid
  for record in "$TMP_ROOT/host/stub-pid" "$TMP_ROOT/autoarm/stub-pid"; do
    [ -f "$record" ] || continue
    IFS= read -r pid < "$record" || continue
    kill -TERM "$pid" 2>/dev/null || true
  done
  fm_test_cleanup
}
trap budget_cleanup EXIT
SUBJECT_ROOT=${FM_FORK_BUDGET_ROOT:-$ROOT}
# Budget for the walk from exec to the first poll, which runs again on every
# wake a watcher delivers.
# The ceiling leaves a little room for the per-platform programs this walk
# differs by: a Linux /proc identity read costs more programs than the portable
# ps fallback. It is still tight enough that one library going back to a
# cd-and-pwd subshell, worth two shell children and a program start, shows up.
# The detached parking tick also runs before the first boundary. Allow its one
# uname and eight shell children here: scheduling can put them on either side
# of that boundary, so startup must accommodate the whole tick.
FORK_BUDGET_WATCH_START_PROGRAMS=${FORK_BUDGET_WATCH_START_PROGRAMS:-23}
FORK_BUDGET_WATCH_START_SHELLS=${FORK_BUDGET_WATCH_START_SHELLS:-30}
mkdir -p "$TMP_ROOT/shims"
EVENTS="$TMP_ROOT/events"
export EVENTS
for tool in cat ps stat grep date sed jq sleep touch awk tr uname mkdir \
  basename dirname readlink ln mktemp rm rmdir wc cut tail mv; do
  real=$(command -v "$tool") || continue
  cat > "$TMP_ROOT/shims/$tool" <<SH
#!/bin/sh
printf 'program $tool\n' >> "\$EVENTS"
exec '$real' "\$@"
SH
  chmod +x "$TMP_ROOT/shims/$tool"
done
# Count subshells too: each child inherits its parent's last pid, so its first
# DEBUG event records exactly one new shell. Instrumented shim execs are counted
# as programs, not shell children. Native BSD stat deliberately bypasses PATH.
cat > "$TMP_ROOT/instrument" <<'SH'
[ "${BASH_VERSINFO[0]}" -ge 4 ] || return 0
if [ -z "${BUDGET_OWNER:-}" ] && [ "$0" = "$BUDGET_TARGET" ]; then
  BUDGET_OWNER=$BASHPID
  export BUDGET_OWNER
fi
budget_debug() {
  local command=$1 caller=$2
  if [ "${budget_last_pid:-}" != "$BASHPID" ]; then
    budget_last_pid=$BASHPID
    printf 'shell %s\n' "$BASHPID" >> "$EVENTS"
  fi
  # A native BSD stat is addressed absolutely, so it bypasses the shims, and a
  # caller may prefix it with an assignment. Match the program anywhere in the
  # command so a prefixed call cannot go uncounted.
  case "$command" in /usr/bin/stat\ *|*\ /usr/bin/stat\ *) printf 'program stat\n' >> "$EVENTS" ;; esac
  [ "$BASHPID" = "${BUDGET_OWNER:-}" ] || return 0
  case "$BUDGET_LOOP:$caller:$command" in
    watch:main:event_wait_or_sleep|attach:attach_and_wait:healthy_watcher|host:await_close:boundary_reached|autoarm:start_handling_successor:'sleep 0.2'|autoarm:start_handling_successor:'fm_poll_wait 0.2')
      budget_cycle=$((${budget_cycle:-0} + 1))
      printf 'cycle %s\n' "$budget_cycle" >> "$EVENTS"
      if [ "$budget_cycle" -eq 5 ]; then
        trap - DEBUG
        exit 0
      fi
      ;;
  esac
}
# A timeout status (>128) proves the held descriptor did not deliver EOF or
# data. This checks the actual wait without an elapsed-time assertion.
read() {
  local _budget_timeout='' _budget_arg _budget_next=0 _budget_rc=0
  for _budget_arg in "$@"; do
    if [ "$_budget_next" -eq 1 ]; then _budget_timeout=$_budget_arg; break; fi
    [ "$_budget_arg" != -t ] || _budget_next=1
  done
  builtin read "$@" || _budget_rc=$?
  [ -z "$_budget_timeout" ] || printf 'wait %s %s\n' "$_budget_timeout" "$_budget_rc" >> "$EVENTS"
  return "$_budget_rc"
}
set -T
trap 'budget_debug "$BASH_COMMAND" "${FUNCNAME[0]:-main}"' DEBUG
SH

make_idle_home() {
  local dir=$1 now
  mkdir -p "$dir/state" "$dir/config"
  touch "$dir/state/.last-check" "$dir/state/.last-heartbeat" \
    "$dir/state/home-summary.json" "$dir/state/.secondmate-liveness-tick"
  # The reconcile marker as a scan leaves it, not a bare touch: its recorded
  # epoch is what the watcher reads to find the cadence unelapsed, and a marker
  # without one falls back to an mtime read the sample would then count.
  now=$(date +%s)
  printf 'epoch=%s\ncursor=\n' "$now" > "$dir/state/.inactive-outcome-reconcile"
  fm_test_track_watcher_state "$dir/state"
}

measure() { # <loop> <home> <target> [args...]
  local loop=$1 home=$2 target=$3 summary programs shells max_programs max_shells limit interval
  local start_programs start_shells
  shift 3
  EVENTS="$home/events"
  : > "$EVENTS"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_CONFIG_OVERRIDE="$home/config" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_ARM_ATTACH_POLL=0.1 \
    BASH_ENV="$TMP_ROOT/instrument" BUDGET_LOOP="$loop" BUDGET_TARGET="${BUDGET_SCRIPT:-$target}" \
    PATH="$TMP_ROOT/shims:$PATH" fm_run_timed 60 "$target" "$@" > "$home/output" 2>&1
  if [ -n "${FM_FORK_BUDGET_EVIDENCE_DIR:-}" ]; then
    cp "$EVENTS" "$FM_FORK_BUDGET_EVIDENCE_DIR/$loop.events"
  fi
  summary=$(awk '
    $1 == "cycle" { cycle=$2; if (cycle==5) ended=1; next }
    cycle==0 && $1=="program" { sp++ }
    cycle>=2 && cycle<=4 && $1=="program" { programs++; p[cycle]++ }
    $1=="shell" {
      # exec into another instrumented Bash can log the same pid twice.
      if (seen[$2]++) next
      if (cycle==0) ss++
      if (cycle>=2 && cycle<=4) { shells++; s[cycle]++ }
    }
    END { if (!ended) exit 1; for (i=2;i<=4;i++) { if(p[i]>mp)mp=p[i]; if(s[i]>ms)ms=s[i] }; printf "%d %d %d %d %d %d", programs, shells, mp, ms, sp, ss }
  ' "$EVENTS") || fail "$loop did not complete five boundaries: $(cat "$home/output")"
  read -r programs shells max_programs max_shells start_programs start_shells <<< "$summary"
  printf '%s: programs=%s/3 shell-children=%s/3 startup-programs=%s startup-shell-children=%s\n' \
    "$loop" "$programs" "$shells" "$start_programs" "$start_shells"
  [ "${FM_FORK_BUDGET_REPORT_ONLY:-0}" != 1 ] || return 0
  case "$loop" in watch) interval=1 ;; attach) interval=0.1 ;; host) interval=0.5 ;; autoarm) interval=0.2 ;; esac
  awk -v interval="$interval" '
    $1=="cycle" { cycle=$2; next }
    cycle>=2 && cycle<=4 && $1=="wait" {
      waits[cycle]++; if ($2!=interval || $3<=128) bad=1
    }
    END { for(i=2;i<=4;i++) if(!waits[i])bad=1; exit bad }
  ' "$EVENTS" || fail "$loop skipped its full timed wait or changed its interval"
  # A warmed idle watcher poll reads cadence mtimes once and starts the
  # detached parking/admission tick, whose library initialization calls uname.
  # Count that required child work too; the other loops start no programs.
  case "$loop" in watch) limit=2 ;; *) limit=0 ;; esac
  [ "$max_programs" -le "$limit" ] || fail "$loop exceeded $limit programs per cycle"
  # Two cadence-reader shells plus eight parking-tick shells per idle poll.
  case "$loop" in watch) limit=10 ;; *) limit=0 ;; esac
  [ "$max_shells" -le "$limit" ] || fail "$loop exceeded $limit shell children per cycle"
  # Reaching the first poll is the fleet's most repeated cost: a watcher is
  # started again on every wake it delivers. Library directories resolve by
  # parameter expansion and the lock path reads its markers with builtins, so
  # the walk from exec to the first wait stays inside this budget.
  case "$loop" in
    watch)
      [ "$start_programs" -le "$FORK_BUDGET_WATCH_START_PROGRAMS" ] ||
        fail "watch startup exceeded $FORK_BUDGET_WATCH_START_PROGRAMS programs: $start_programs"
      [ "$start_shells" -le "$FORK_BUDGET_WATCH_START_SHELLS" ] ||
        fail "watch startup exceeded $FORK_BUDGET_WATCH_START_SHELLS shell children: $start_shells"
      ;;
  esac
}

# Real watcher, with no tasks or due maintenance. This is also the live Mac
# sampler: every production idle-poll operation runs against an isolated home.
home="$TMP_ROOT/watch"
make_idle_home "$home"
measure watch "$home" "$SUBJECT_ROOT/bin/fm-watch.sh"

# A real watcher holds the lock while a second arm follows it. Keep its next
# beat outside the short attachment sample so a legitimate legacy-mtime fallback
# during beacon truncation cannot make a deterministic budget timing-dependent.
home="$TMP_ROOT/attach"
make_idle_home "$home"
FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_STATE_OVERRIDE="$home/state" \
  FM_POLL=60 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
  "$SUBJECT_ROOT/bin/fm-watch.sh" > "$home/watcher.out" 2>&1 &
seed=$!
i=0
while [ ! -s "$home/state/.watch.lock/pid-identity" ] || [ ! -e "$home/state/.last-watcher-beat" ]; do
  [ "$i" -lt 200 ] || fail 'seed watcher never became ready'
  sleep 0.1
  i=$((i + 1))
done
measure attach "$home" "$SUBJECT_ROOT/bin/fm-watch-arm.sh"
kill -TERM "$seed" 2>/dev/null || true
wait "$seed" 2>/dev/null || true

# Use a blocking arm fixture for the host and Stop hook. The caller owns both
# FIFO ends, so the fixture cannot finish or flood output during the sample.
mkdir -p "$TMP_ROOT/fixture/bin" "$TMP_ROOT/fakebin"
cp -R "$SUBJECT_ROOT/bin/." "$TMP_ROOT/fixture/bin/"
ln -s "$BASH" "$TMP_ROOT/fakebin/claude"
cat > "$TMP_ROOT/fixture/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" != --stop ] || exit 0
if [ "${BUDGET_LOOP:-}" = autoarm ] && [ -z "${FM_WATCH_PREDECESSOR_ARM_PID:-}" ]; then
  printf 'watcher: attached pid=%s (beacon 0s)\nsignal: task.status done: fixture\n' "$$"
  exit 0
fi
printf '%s\n' "$$" > "$FM_HOME/stub-pid"
if [ "${BUDGET_LOOP:-}" != autoarm ]; then
  printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
fi
IFS= read -r _ < "$FM_HOME/hold"
SH
chmod +x "$TMP_ROOT/fixture/bin/fm-watch-arm.sh"
for loop in host autoarm; do
  home="$TMP_ROOT/$loop"
  make_idle_home "$home"
  mkdir -p "$home/bin"
  cp -R "$TMP_ROOT/fixture/bin/." "$home/bin/"
  git init -q "$home"
  : > "$home/AGENTS.md"
  : > "$home/state/task.meta"
  : > "$home/config/supervision-host-off"
  mkfifo "$home/hold"
  exec 9<> "$home/hold"
  case "$loop" in host) script=fm-supervision-host.sh; arg=park ;; autoarm) script=fm-claude-stop-autoarm.sh; arg= ;; esac
  # A real process with the harness name owns the session lock; no bypass of
  # the session-lock or Stop-hook ownership gate is used.
  cat > "$home/run" <<SH
#!/usr/bin/env bash
exec '$TMP_ROOT/fakebin/claude' -c '
  printf "%s\\n" "\$\$" > "\$FM_HOME/state/.lock"
  "\$FM_HOME/bin/$script" $arg
  result=\$?
  exit "\$result"
'
SH
  chmod +x "$home/run"
  BUDGET_SCRIPT="$home/bin/$script" measure "$loop" "$home" "$home/run" < /dev/null
  if [ -f "$home/stub-pid" ]; then
    IFS= read -r pid < "$home/stub-pid"
    kill -TERM "$pid" 2>/dev/null || true
  fi
  exec 9>&-
done
pass 'warmed supervision loops stay within their program and shell-child budgets'

# Check the cached proof through the public health primitive using a real pid.
# All lock fields are read each time, and a failed observation invalidates it.
home="$TMP_ROOT/identity"
make_idle_home "$home"
mkfifo "$home/hold"
exec 9<> "$home/hold"
bash -c 'IFS= read -r _ < "$1"' _ "$home/hold" &
holder=$!
if ! FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" bash -s "$ROOT" "$holder" <<'SH'
set -eu
. "$1/bin/fm-wake-lib.sh"
pid=$2
mkdir -p "$STATE/.watch.lock"
printf '%s\n' "$pid" > "$STATE/.watch.lock/pid"
printf '%s\n' "$FM_HOME" > "$STATE/.watch.lock/fm-home"
printf '%s\n' watcher > "$STATE/.watch.lock/watcher-path"
identity=$(fm_pid_identity "$pid")
printf '%s\n' "$identity" > "$STATE/.watch.lock/pid-identity"
fm_epoch_seconds_to now
printf 'heartbeat_epoch=%s\n' "$now" > "$STATE/.last-watcher-beat"
FM_WATCHER_IDENTITY_CACHE=1
fm_watcher_healthy "$STATE" watcher 300 "$FM_HOME"
# Any second identity lookup without a lock change is a budget regression.
identity_reader=$(declare -f fm_pid_identity)
fm_pid_identity() { return 1; }
fm_watcher_healthy "$STATE" watcher 300 "$FM_HOME"
for field in pid pid-identity fm-home watcher-path; do
  eval "$identity_reader"
  fm_watcher_healthy "$STATE" watcher 300 "$FM_HOME"
  fm_read_file_to original "$STATE/.watch.lock/$field"
  fm_pid_identity() { return 1; }
  replacement=wrong
  # Another live pid, with the old recorded identity, must never inherit proof.
  [ "$field" != pid ] || replacement=$$
  printf '%s\n' "$replacement" > "$STATE/.watch.lock/$field"
  if fm_watcher_healthy "$STATE" watcher 300 "$FM_HOME"; then exit 1; fi
  printf '%s\n' "$original" > "$STATE/.watch.lock/$field"
  # Returning the files to their old values cannot resurrect the old proof.
  if fm_watcher_healthy "$STATE" watcher 300 "$FM_HOME"; then exit 1; fi
done
SH
then
  fail 'identity cache accepted a replaced lock or re-probed a stable one'
fi
kill -TERM "$holder" 2>/dev/null || true
wait "$holder" 2>/dev/null || true
exec 9>&-

if ! FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" bash -s "$ROOT" <<'SH'
set -eu
. "$1/bin/fm-wake-lib.sh"
# Pin the clock and mtime: these are freshness-value assertions, not elapsed
# timing assertions. The old-reader API still reads the new file's mtime.
fm_epoch_seconds_to() { printf -v "$1" '%s' 946685800; }
printf 'heartbeat_epoch=946685700\n' > "$STATE/.last-watcher-beat"
TZ=UTC touch -t 200001010000 "$STATE/.last-watcher-beat"
fm_watcher_beacon_age_to age "$STATE/.last-watcher-beat"
[ "$age" -eq 100 ]
[ "$(fm_path_age "$STATE/.last-watcher-beat")" -eq 1000 ]
: > "$STATE/.last-watcher-beat"
TZ=UTC touch -t 200001010000 "$STATE/.last-watcher-beat"
fm_watcher_beacon_age_to age "$STATE/.last-watcher-beat"
[ "$age" -eq 1000 ]
# A leftover pid cannot be vouched for by a fresh beacon.
printf 'heartbeat_epoch=946685800\n' > "$STATE/.last-watcher-beat"
if fm_watcher_healthy "$STATE" watcher 300 "$FM_HOME"; then exit 1; fi
SH
then
  fail 'beacon compatibility or dead-pid rejection changed'
fi
pass 'identity cache invalidates on replacement; old and new beacon freshness remain compatible'

# An unsupported FIFO must retain the existing sleep cadence without retrying
# allocation on every poll. No real sleep is needed to exercise this fallback.
if ! FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" bash -s "$ROOT" <<'SH'
set -eu
. "$1/bin/fm-wake-lib.sh"
tries=0 fallback=0
mkfifo() { tries=$((tries + 1)); return 1; }
sleep() { [ "$1" = 0.2 ] || exit 1; fallback=$((fallback + 1)); }
fm_poll_wait 0.2
fm_poll_wait 0.2
fm_poll_wait 0.2
[ "$tries" -eq 1 ] && [ "$fallback" -eq 3 ]
SH
then
  fail 'unsupported FIFO setup was retried or changed the fallback interval'
fi
pass 'unsupported FIFO setup falls back once without adding per-poll setup forks'

# One-shot supervision commands, counted the same way: PATH shims observe which
# programs an invocation actually starts, never its implementation text. These
# commands run on the supervision cycle too, and their budget is a FIXED cost,
# not one paid per durable record or per ancestor process.
ONESHOT_ROOT=$TMP_ROOT/oneshot
mkdir -p "$ONESHOT_ROOT/shims"
ONESHOT_EVENTS=$ONESHOT_ROOT/events
export ONESHOT_EVENTS
for tool in jq awk wc cat sed grep cut tail tr basename dirname mktemp mv chmod \
  rm rmdir ln readlink stat date perl shasum ps head touch mkdir uname sort; do
  real=$(command -v "$tool") || continue
  cat > "$ONESHOT_ROOT/shims/$tool" <<SH
#!/bin/sh
printf '%s\n' "$tool" >> "\$ONESHOT_EVENTS"
exec '$real' "\$@"
SH
  chmod +x "$ONESHOT_ROOT/shims/$tool"
done

# Count the recorded starts without starting a program to do it.
oneshot_count() {  # [program-name]
  local line total=0 named=0
  while IFS= read -r line; do
    total=$((total + 1))
    [ "$line" != "${1:-}" ] || named=$((named + 1))
  done < "$ONESHOT_EVENTS"
  [ "$#" -eq 0 ] && { printf '%s\n' "$total"; return 0; }
  printf '%s\n' "$named"
}

oneshot_home() {  # <dir>
  rm -rf "$1"
  mkdir -p "$1/state/procevent" "$1/config" "$1/data"
  printf '{"backlog":{"present":true,"rows":[]},"tasks":[]}\n' > "$1/input.json"
}

snapshot_programs() {  # <records>
  local records=$1 home="$ONESHOT_ROOT/snapshot" i
  oneshot_home "$home"
  for ((i = 1; i <= records; i++)); do
    mkdir -p "$home/data/task-$i"
    printf '{"schema":"fm-contributions.v1","task":"task-%s","records":[{"url":"https://github.com/o/r/pull/%s","kind":"pr","checked_at":"2026-10-17T10:00:00Z","error":null,"observation":null,"verdict":null,"seen":[],"pending":[],"notified":[]}]}\n' \
      "$i" "$i" > "$home/data/task-$i/contributions.json"
  done
  : > "$ONESHOT_EVENTS"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
    FM_CONTRIBUTIONS_NOW=2026-10-17T11:00:00Z PATH="$ONESHOT_ROOT/shims:$PATH" \
    "$SUBJECT_ROOT/bin/fm-contributions.sh" snapshot "$home/input.json" > "$home/out" 2>&1 \
    || fail "contribution snapshot over $records records failed: $(cat "$home/out")"
  oneshot_count
}

two=$(snapshot_programs 2)
twenty=$(snapshot_programs 20)
printf 'contributions snapshot: programs=%s at 2 records, %s at 20\n' "$two" "$twenty"
[ "$two" = "$twenty" ] || fail "contribution snapshot starts programs per durable record ($two then $twenty)"
[ "$twenty" -le 8 ] || fail "contribution snapshot exceeded 8 programs ($twenty)"

: > "$ONESHOT_EVENTS"
home=$ONESHOT_ROOT/procevent
oneshot_home "$home"
# The private-root owner and mode checks use absolute BSD stat on macOS.
# PATH shims alone miss those two starts, making this budget OS-dependent.
cat > "$ONESHOT_ROOT/instrument" <<'SH'
set -T
trap 'case "$BASH_COMMAND" in /usr/bin/stat\ *) printf "stat\n" >> "$ONESHOT_EVENTS" ;; esac' DEBUG
SH
FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_STATE_OVERRIDE="$home/state" \
  FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
  BASH_ENV="$ONESHOT_ROOT/instrument" \
  PATH="$ONESHOT_ROOT/shims:$PATH" \
  "$SUBJECT_ROOT/bin/fm-procevent.sh" reconcile > "$home/out" 2>&1 \
  || fail "procevent reconcile failed: $(cat "$home/out")"
programs=$(oneshot_count)
printf 'procevent reconcile: programs=%s\n' "$programs"
# Two uname calls, two private-root stat checks, and perl/mktemp/mv for the
# monotonic owner lease are seven starts on both supported OS families.
[ "$programs" -le 7 ] || fail "procevent reconcile exceeded 7 programs ($programs)"
pass 'one-shot supervision commands pay a fixed program budget, not a per-record one'

# The harness ancestry walk reads each ancestor once. Against a chain that
# reports bash all the way to pid 1 the walk is deterministic: eight levels, one
# process read each, and the pathname split never leaves the shell. Reading a
# level twice, or forking basename per level, shows up as a higher count.
ANCESTRY_BIN=$ONESHOT_ROOT/ancestry
mkdir -p "$ANCESTRY_BIN"
cat > "$ANCESTRY_BIN/ps" <<'SH'
#!/bin/sh
printf 'ps\n' >> "$ONESHOT_EVENTS"
case "$*" in
  '-o ppid=,comm= -p '*) printf '%s %s\n' 1 bash ;;
  '-o comm= -p '*) printf '%s\n' bash ;;
  '-o args= -p '*) printf '%s\n' bash ;;
  '-o ppid= -p '*) printf '%s\n' 1 ;;
  *) exit 1 ;;
esac
SH
real_basename=$(command -v basename)
cat > "$ANCESTRY_BIN/basename" <<SH
#!/bin/sh
printf 'basename\n' >> "\$ONESHOT_EVENTS"
exec '$real_basename' "\$@"
SH
chmod +x "$ANCESTRY_BIN/ps" "$ANCESTRY_BIN/basename"

: > "$ONESHOT_EVENTS"
PATH="$ANCESTRY_BIN:$PATH" "$SUBJECT_ROOT/bin/fm-harness.sh" ancestry > /dev/null 2>&1 \
  || fail 'harness ancestry walk could not run'
ps_starts=$(oneshot_count ps)
basename_starts=$(oneshot_count basename)
printf 'harness ancestry: process-reads=%s basename=%s\n' "$ps_starts" "$basename_starts"
[ "$ps_starts" -le 8 ] || fail "harness ancestry read ancestors more than once ($ps_starts process reads)"
[ "$basename_starts" -eq 0 ] || fail "harness ancestry still forks basename ($basename_starts)"
pass 'the harness ancestry walk reads each ancestor with one program and no basename'

# A drain's total forks - bash subshells (command substitutions, pipelines,
# ( ) groups) and external program starts alike - counted by xtrace's PID over
# source line, not the program-only shim count above: a bare command
# substitution around a pure-builtin helper (fm_lease_actor, a lock's owner-dir
# allocation) forks without ever starting a shimmed program, so a program-only
# count would miss it. Each new $BASHPID that xtrace reports is exactly one
# fork, whatever it ran.
drain_fork_count() {  # <home> <label>
  local home=$1 label=$2 trace pids
  trace="$home/drain.trace"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_CONFIG_OVERRIDE="$home/config" FM_DATA_OVERRIDE="$home/data" \
    PS4='+PID=$BASHPID ' bash -x "$SUBJECT_ROOT/bin/fm-wake-drain.sh" \
    > "$home/drain.out" 2> "$trace" \
    || fail "$label drain failed: $(cat "$home/drain.out")"
  pids=$(grep -oE 'PID=[0-9]+' "$trace" | sort -u | wc -l | tr -d ' ')
  printf 'wake drain forks (%s): %s\n' "$label" "$pids" >&2
  printf '%s' "$pids"
}

drain_home() {  # <dir>
  mkdir -p "$1/state" "$1/config" "$1/data"
  : > "$1/config/supervision-host-off"
}

home=$ONESHOT_ROOT/drain-idle
rm -rf "$home"
drain_home "$home"
: > "$home/state/.wake-queue"
idle_forks=$(drain_fork_count "$home" 'idle, empty queue file present')
[ "$idle_forks" -le 21 ] || fail "wake drain over an idle queue exceeded 21 forks ($idle_forks)"

home=$ONESHOT_ROOT/drain-queued
rm -rf "$home"
drain_home "$home"
printf '%s\t1\tsignal\ttask1\tfoo: bar\n' "$(date +%s)" > "$home/state/.wake-queue"
queued_forks=$(drain_fork_count "$home" 'one queued signal row')
[ "$queued_forks" -le 56 ] || fail "wake drain over one queued row exceeded 56 forks ($queued_forks)"
pass 'wake drain stays within its idle and single-row fork budgets'
