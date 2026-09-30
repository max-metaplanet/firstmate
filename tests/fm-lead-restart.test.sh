#!/usr/bin/env bash
# Behavior tests for replacing the lead itself onto another Claude seat:
# bin/fm-lead-restart.sh, its `lead-restart` surface and automatic trigger in
# bin/fm-seat.sh, and the handover reservation half of bin/fm-lock.sh.
#
# No real Claude account and no network. Seats are empty directories and the
# login probe is answered by tests/fixtures.sh's shared fake quota-axi, the same
# one tests/fm-seat.test.sh drives.
#
# Two layers, because they fail for different reasons. The first drives the real
# scripts against real processes named claude (a symlink to bash, the same
# stand-in tests/fm-session-lock-ancestry.test.sh uses) with no terminal at all,
# so every refusal is pinned wherever the suite runs. The second runs the whole
# swap in a REAL tmux on a private socket: the property that matters - one lead
# before, one lead after, in the same pane, on the new profile, resuming the
# same session, with supervision never dropping to zero - can only be observed
# against real processes in a real terminal.
#
# What is NOT proven here, and is not claimed anywhere: that a real signed-in
# `claude --resume <id>` comes back up as that same session. Exercising it needs
# a credential, which this suite deliberately never touches. The stand-in
# reproduces the documented contract instead - a resume keeps the session id,
# which is exactly what --fork-session exists to opt out of - and every other
# step is proven for real.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

SEAT="$ROOT/bin/fm-seat.sh"
LEAD_RESTART="$ROOT/bin/fm-lead-restart.sh"
LOCK="$ROOT/bin/fm-lock.sh"
# Short root: a tmux socket and the lab paths below both live under it, and a
# long path is not addressable as a unix socket.
TMP_ROOT=$(mktemp -d "/tmp/fm-lead-restart.XXXXXX")
CLEAN_TMUX=()
cleanup() {
  local sock
  for sock in ${CLEAN_TMUX[@]+"${CLEAN_TMUX[@]}"}; do
    tmux -L "$sock" kill-server >/dev/null 2>&1 || true
  done
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

# A real process whose command name says claude, so every ancestry and liveness
# predicate under test reads it exactly as it reads the real harness.
FAKE_CLAUDE_DIR="$TMP_ROOT/harness-bin"
mkdir -p "$FAKE_CLAUDE_DIR"
ln -s /bin/bash "$FAKE_CLAUDE_DIR/claude"
FAKE_CLAUDE="$FAKE_CLAUDE_DIR/claude"
# A simple argv for the stand-in lead, because an inline -c script is full of
# shell metacharacters and is correctly refused as unestablishable - that
# refusal has its own test rather than being the shape every case starts from.
SLEEPER="$TMP_ROOT/sleeper.sh"
printf '#!/usr/bin/env bash\nwhile :; do sleep 1; done\n' > "$SLEEPER"
chmod +x "$SLEEPER"

# make_case <name> [<lead-profile-seat>]
# A home with two seats, both logged in, a live stand-in lead holding the lock,
# and a lock-runtime record naming a pane. Echoes "<dir>|<home>|<seats>|<fakebin>|<spec>|<lead-pid>".
make_case() {  # <name> [<seat-for-lead>] [<backend>] [<target>]
  local name=$1 lead_seat=${2:-alpha} backend=${3-tmux} target=${4-%9}
  local dir home seats fakebin spec pid
  dir="$TMP_ROOT/$name"
  home="$dir/home"
  seats="$dir/seats"
  spec="$dir/quota-spec"
  mkdir -p "$home/config" "$home/state" "$home/data" "$seats/alpha" "$seats/beta"
  fakebin=$(fm_fakebin "$dir/fake")
  fm_test_make_quota_fake "$fakebin" "$spec"
  printf '%s\n' "$seats" > "$home/config/claude-seats-root"
  printf '%s\n%s\n' "$seats/alpha" "$seats/beta" > "$spec/oauth"
  printf '90\n' > "$spec/remaining"

  # Detached from this function's stdout: the caller reads it through a command
  # substitution, which would otherwise wait on the pipe this child keeps open.
  "$FAKE_CLAUDE" "$SLEEPER" >/dev/null 2>&1 </dev/null &
  pid=$!
  printf '%s\n' "$pid" > "$home/state/.lock"
  printf 'lead-session-1\n' > "$home/state/.lock-session"
  {
    printf 'pid=%s\n' "$pid"
    printf 'profile=%s\n' "$seats/$lead_seat"
    [ -z "$backend" ] || printf 'backend=%s\n' "$backend"
    [ -z "$target" ] || printf 'target=%s\n' "$target"
  } > "$home/state/.lock-runtime"
  printf '%s|%s|%s|%s|%s|%s\n' "$dir" "$home" "$seats" "$fakebin" "$spec" "$pid"
}

read_case() {
  IFS='|' read -r CASE_DIR HOME_DIR SEATS_DIR FAKEBIN SPEC_DIR LEAD_PID <<EOF
$1
EOF
}

stop_case() { kill "$LEAD_PID" 2>/dev/null || true; wait "$LEAD_PID" 2>/dev/null || true; }

# run_seat/run_restart: this home's resolution, no ambient profile, and the
# faked toolchain. A `tmux` stub answers the pane-existence probe so the
# no-terminal layer never talks to a real server.
run_home() {  # <bin> [args...]
  local bin=$1
  shift
  FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_CONFIG_OVERRIDE="$HOME_DIR/config" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    CLAUDE_CONFIG_DIR= PATH="$FAKEBIN:$PATH" "$bin" "$@" 2>&1
}

# Run a command AS the session that holds this home: a claude-named process
# carrying the recorded session id, which is the same ownership proof
# bin/fm-session-lock-lib.sh applies to the real primary.
run_as_lead() {  # <bin> [args...]
  local bin=$1 quoted='' a
  shift
  for a in "$@"; do quoted="$quoted $(printf '%q' "$a")"; done
  env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID \
    FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_CONFIG_OVERRIDE="$HOME_DIR/config" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    CLAUDE_CONFIG_DIR= PATH="$FAKEBIN:$PATH" \
    "$FAKE_CLAUDE" -c "
      export CLAUDE_CODE_SESSION_ID=lead-session-1 CLAUDE_PID=\$\$
      $(printf '%q' "$bin")$quoted
    " 2>&1
}

stub_pane_exists() {  # <fakebin>
  cat > "$1/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  list-panes) printf '%s\n' "%9"; exit 0 ;;
esac
exit 0
SH
  chmod +x "$1/tmux"
}

# --- layer 1: establishment and refusals, no terminal ------------------------

test_check_establishes_every_part_of_the_move() {
  local rec out
  rec=$(make_case check-ok); read_case "$rec"
  stub_pane_exists "$FAKEBIN"
  out=$(run_home "$SEAT" lead-restart --check) ||
    fail "check refused an establishable move: $out"
  case "$out" in
    *"lead seat: alpha"*) ;;
    *) fail "check did not name the seat the lead is on: $out" ;;
  esac
  case "$out" in
    *"destination seat: beta"*) ;;
    *) fail "check did not rotate to the other seat: $out" ;;
  esac
  case "$out" in
    *"session resumed: lead-session-1"*) ;;
    *) fail "check did not name the session being resumed: $out" ;;
  esac
  case "$out" in
    *"--resume lead-session-1"*) ;;
    *) fail "the composed command does not resume that session: $out" ;;
  esac
  [ ! -f "$HOME_DIR/state/.lock-handover" ] || fail "--check armed a reservation"
  kill -0 "$LEAD_PID" 2>/dev/null || fail "--check disturbed the running lead"
  stop_case
  pass "a check establishes the lead's seat, its destination, its session, and the replacement command"
}

test_refuses_without_the_persist_gate() {
  local rec out
  rec=$(make_case no-persist); read_case "$rec"
  stub_pane_exists "$FAKEBIN"
  out=$(run_as_lead "$SEAT" lead-restart) && fail "a restart ran with no persist gate: $out"
  case "$out" in
    *'Open-record persistence'*) ;;
    *) fail "the refusal does not name the persist contract: $out" ;;
  esac
  [ ! -f "$HOME_DIR/state/.lock-handover" ] || fail "a refused restart armed a reservation"
  [ ! -f "$HOME_DIR/state/.lead-restart" ] || fail "a refused restart left a plan behind"
  kill -0 "$LEAD_PID" 2>/dev/null || fail "a refused restart disturbed the running lead"
  stop_case
  pass "without the persist gate nothing is armed and the lead keeps running"
}

test_refuses_a_destination_that_is_not_proven_signed_in() {
  local rec out
  rec=$(make_case signed-out); read_case "$rec"
  stub_pane_exists "$FAKEBIN"
  printf '%s\n' "$SEATS_DIR/alpha" > "$SPEC_DIR/oauth"
  printf '%s\n' "$SEATS_DIR/beta" > "$SPEC_DIR/signed_out"
  out=$(run_home "$LEAD_RESTART" --check --to beta) && fail "a signed-out destination was accepted: $out"
  case "$out" in
    *"not logged in"*) ;;
    *) fail "the refusal does not say the destination is not logged in: $out" ;;
  esac
  # An undecided probe is refused too: this never crosses uncertainty the way a
  # worker spawn may, because a lead that cannot start leaves no firstmate.
  rm -f "$SPEC_DIR/signed_out"
  out=$(run_home "$LEAD_RESTART" --check --to beta) && fail "an undecided destination was accepted: $out"
  case "$out" in
    *"could not be confirmed logged in"*) ;;
    *) fail "the refusal does not name the undecided probe: $out" ;;
  esac
  kill -0 "$LEAD_PID" 2>/dev/null || fail "a refusal disturbed the running lead"
  stop_case
  pass "a destination that is not proven signed in is refused, undecided included"
}

test_refuses_when_the_terminal_or_the_lead_profile_is_not_established() {
  local rec out
  rec=$(make_case no-pane alpha tmux ''); read_case "$rec"
  out=$(run_home "$LEAD_RESTART" --check --to beta) && fail "a restart was offered with no established terminal: $out"
  case "$out" in
    *"terminal the lead runs in is not established"*) ;;
    *) fail "the refusal does not name the missing terminal: $out" ;;
  esac
  stop_case

  rec=$(make_case no-profile); read_case "$rec"
  stub_pane_exists "$FAKEBIN"
  grep -v '^profile=' "$HOME_DIR/state/.lock-runtime" > "$HOME_DIR/state/.lock-runtime.new"
  mv "$HOME_DIR/state/.lock-runtime.new" "$HOME_DIR/state/.lock-runtime"
  out=$(run_home "$LEAD_RESTART" --check --to beta) && fail "a restart was offered with no known lead account: $out"
  case "$out" in
    *"account the lead itself runs on is not recorded"*) ;;
    *) fail "the refusal does not name the missing account record: $out" ;;
  esac
  stop_case
  pass "an unestablished terminal or lead account refuses instead of guessing one"
}

test_a_runtime_record_for_another_pid_is_not_evidence() {
  local rec out
  rec=$(make_case stale-runtime); read_case "$rec"
  stub_pane_exists "$FAKEBIN"
  sed 's/^pid=.*/pid=999999/' "$HOME_DIR/state/.lock-runtime" > "$HOME_DIR/state/.rt"
  mv "$HOME_DIR/state/.rt" "$HOME_DIR/state/.lock-runtime"
  out=$(run_home "$LEAD_RESTART" --check --to beta) && fail "a record for another session was used: $out"
  case "$out" in
    *"not recorded for this session"*) ;;
    *) fail "the refusal does not treat the foreign record as absent: $out" ;;
  esac
  stop_case
  pass "a runtime record that does not name the current lock owner is no evidence"
}

test_refuses_the_ambient_default_and_the_seat_already_held() {
  local rec out
  rec=$(make_case bad-destination); read_case "$rec"
  stub_pane_exists "$FAKEBIN"
  out=$(run_home "$LEAD_RESTART" --check --to default) && fail "the ambient default was accepted: $out"
  case "$out" in
    *"never a lead-restart destination"*) ;;
    *) fail "the refusal does not explain the default profile: $out" ;;
  esac
  out=$(run_home "$LEAD_RESTART" --check --to alpha) && fail "the seat already held was accepted: $out"
  case "$out" in
    *"already running on seat 'alpha'"*) ;;
    *) fail "the refusal does not say the lead is already there: $out" ;;
  esac
  stop_case
  pass "the ambient default profile and the seat the lead already holds are both refused"
}

test_only_the_lead_may_replace_the_lead() {
  local rec out
  rec=$(make_case foreign-caller); read_case "$rec"
  stub_pane_exists "$FAKEBIN"
  # This test process is not inside the stand-in lead's ancestry and carries no
  # matching session id, so it is not that session.
  out=$(env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID FM_HOME="$HOME_DIR" \
    FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_CONFIG_OVERRIDE="$HOME_DIR/config" CLAUDE_CONFIG_DIR= PATH="$FAKEBIN:$PATH" \
    "$LEAD_RESTART" --to beta --persisted 2>&1) && fail "a foreign session replaced the lead: $out"
  case "$out" in
    *"not the firstmate session that holds this home"*) ;;
    *) fail "the refusal does not name the ownership requirement: $out" ;;
  esac
  [ ! -f "$HOME_DIR/state/.lock-handover" ] || fail "a foreign caller armed a reservation"
  kill -0 "$LEAD_PID" 2>/dev/null || fail "a foreign caller disturbed the lead"
  stop_case
  pass "a session that does not hold this home cannot replace its lead"
}

test_launch_command_is_established_only_when_it_round_trips() {
  local rec out dir script
  rec=$(make_case launch-argv); read_case "$rec"
  stub_pane_exists "$FAKEBIN"
  dir=$CASE_DIR

  # A multi-word argument is indistinguishable from two arguments once the
  # argument vector has been flattened, so it must refuse rather than split it.
  stop_case
  "$FAKE_CLAUDE" "$SLEEPER" --append-system-prompt "you are a worker" \
    >/dev/null 2>&1 </dev/null &
  LEAD_PID=$!
  sed "s/^pid=.*/pid=$LEAD_PID/" "$HOME_DIR/state/.lock-runtime" > "$dir/rt"
  mv "$dir/rt" "$HOME_DIR/state/.lock-runtime"
  printf '%s\n' "$LEAD_PID" > "$HOME_DIR/state/.lock"
  if [ ! -r "/proc/$LEAD_PID/cmdline" ]; then
    out=$(run_home "$LEAD_RESTART" --check --to beta) &&
      fail "a launch command that cannot have survived flattening was accepted: $out"
    case "$out" in
      *"launch command could not be established"*) ;;
      *) fail "the refusal does not name the launch command: $out" ;;
    esac
  fi

  # Stated explicitly, it is established, and the composition drops every
  # session-selection flag rather than leaving a second one behind.
  out=$(run_home "$LEAD_RESTART" --check --to beta \
    --launch-command "$FAKE_CLAUDE --continue --fork-session --resume old-id --model opus") ||
    fail "an explicitly stated launch command was refused: $out"
  case "$out" in
    *"--model opus --resume lead-session-1"*) ;;
    *) fail "the composed command did not end with exactly one resume: $out" ;;
  esac
  case "$out" in
    *--continue* | *--fork-session* | *old-id*) fail "a session-selection flag survived composition: $out" ;;
  esac
  case "$out" in
    *"CLAUDE_CONFIG_DIR=$SEATS_DIR/beta"*) ;;
    *) fail "the composed command does not run under the destination profile: $out" ;;
  esac
  stop_case
  pass "a launch command is established only when it provably round-trips, and composition leaves exactly one resume"
}

# --- layer 2: the handover reservation ---------------------------------------

lock_as() {  # <home> <session-id> <handover-token>
  local home=$1 session=$2 token=$3
  env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID -u FM_LEAD_HANDOVER \
    FM_LEAD_HANDOVER="$token" FM_TEST_SESSION="$session" \
    "$FAKE_CLAUDE" -c "
      export CLAUDE_CODE_SESSION_ID='$session' CLAUDE_PID=\$\$
      FM_HOME='$home' FM_STATE_OVERRIDE='$home/state' '$LOCK'
    " 2>&1
}

test_a_reservation_holds_the_home_for_its_successor_alone() {
  local rec out home
  rec=$(make_case handover); read_case "$rec"
  home=$HOME_DIR
  # The outgoing lead arms the reservation while it still holds the lock, then
  # dies: the state every other session would otherwise read as reclaimable.
  printf 'session=lead-session-1\nnonce=deadbeef\ndeadline=%s\npid=%s\n' \
    "$(( $(date +%s) + 600 ))" "$LEAD_PID" > "$home/state/.lock-handover"
  stop_case
  out=$(lock_as "$home" other-session '')
  case "$out" in
    *"reserved for a firstmate session that is restarting"*) ;;
    *) fail "an unrelated session was not refused the reserved home: $out" ;;
  esac
  [ "$(cat "$home/state/.lock")" = "$LEAD_PID" ] ||
    fail "an unrelated session rewrote the reserved lock"

  out=$(lock_as "$home" successor-session deadbeef)
  case "$out" in
    *"lock acquired"*) ;;
    *) fail "the successor was refused its own reservation: $out" ;;
  esac
  [ ! -f "$home/state/.lock-handover" ] ||
    fail "the successor's acquisition did not clear the reservation"
  pass "a reservation refuses every session but the one it names, and the successor clears it"
}

test_a_lapsed_reservation_never_wedges_the_home() {
  local rec out home
  rec=$(make_case handover-lapsed); read_case "$rec"
  home=$HOME_DIR
  printf 'session=lead-session-1\nnonce=deadbeef\ndeadline=%s\npid=%s\n' \
    "$(( $(date +%s) - 1 ))" "$LEAD_PID" > "$home/state/.lock-handover"
  stop_case
  out=$(lock_as "$home" other-session '')
  case "$out" in
    *"lock acquired"*) ;;
    *) fail "a lapsed reservation still held the home shut: $out" ;;
  esac
  pass "a reservation that lapsed holds nothing, so a failed handover cannot wedge a home"
}

test_the_outgoing_session_keeps_confirming_its_own_lock() {
  local rec out home
  rec=$(make_case handover-outgoing); read_case "$rec"
  home=$HOME_DIR
  printf 'session=lead-session-1\nnonce=deadbeef\ndeadline=%s\npid=%s\n' \
    "$(( $(date +%s) + 600 ))" "$LEAD_PID" > "$home/state/.lock-handover"
  stop_case
  # Same session id, no token: the outgoing lead's own confirmation, which must
  # pass and must NOT clear the reservation it armed.
  out=$(lock_as "$home" lead-session-1 '')
  case "$out" in
    *"lock acquired"*) ;;
    *) fail "the outgoing session was locked out by its own reservation: $out" ;;
  esac
  [ -f "$home/state/.lock-handover" ] ||
    fail "the outgoing session's confirmation dropped the reservation before the swap"
  pass "the outgoing session still confirms its lock and does not drop its own reservation"
}

test_only_the_lock_holder_may_reserve_the_home() {
  local rec out home
  rec=$(make_case handover-authority); read_case "$rec"
  home=$HOME_DIR
  out=$(env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" "$LOCK" handover some-session abc123 600 2>&1) &&
    fail "a session that does not hold the lock reserved the home: $out"
  case "$out" in
    *"only the session that holds this home's lock"*) ;;
    *) fail "the refusal does not name the ownership requirement: $out" ;;
  esac
  [ ! -f "$home/state/.lock-handover" ] || fail "a refused reservation was still written"
  stop_case
  pass "only the session holding this home's lock may reserve it for a successor"
}

test_the_detached_stage_can_drop_the_reservation_it_armed() {
  local rec out home
  rec=$(make_case handover-stage-clear); read_case "$rec"
  home=$HOME_DIR
  printf 'session=lead-session-1\nnonce=deadbeef\ndeadline=%s\npid=%s\n' \
    "$(( $(date +%s) + 600 ))" "$LEAD_PID" > "$home/state/.lock-handover"
  stop_case
  # The stage that armed this reservation runs detached and outlives the process
  # whose ancestry proved ownership, so it has no harness ancestry left at all -
  # exactly this shape. Its authority has to be the nonce it holds.
  out=$(env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID -u FM_LEAD_HANDOVER \
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$LOCK" handover-clear 2>&1) &&
    fail "a process with no claim on this home dropped its reservation: $out"
  [ -f "$home/state/.lock-handover" ] || fail "the reservation was dropped without authority"

  out=$(env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID FM_LEAD_HANDOVER=deadbeef \
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$LOCK" handover-clear 2>&1) ||
    fail "the stage holding the nonce could not drop its own reservation: $out"
  [ ! -f "$home/state/.lock-handover" ] || fail "the reservation survived its own stage clearing it"
  pass "the detached stage drops the reservation it armed with the nonce it holds, and nothing else can"
}

# --- layer 3: the automatic trigger ------------------------------------------

test_the_lead_trigger_fires_once_per_seat_and_hands_over_the_gate() {
  local rec out
  rec=$(make_case auto-lead); read_case "$rec"
  stub_pane_exists "$FAKEBIN"
  printf '%s\t5\n%s\t90\n' "$SEATS_DIR/alpha" "$SEATS_DIR/beta" > "$SPEC_DIR/remaining_map"
  run_home "$SEAT" threshold 15 >/dev/null
  out=$(run_home "$SEAT" auto)
  case "$out" in
    *"firstmate itself is at 5% left on alpha and moves to beta now"*) ;;
    *) fail "the lead's own crossing was not reported: $out" ;;
  esac
  case "$out" in
    *'Open-record persistence'*) ;;
    *) fail "the report does not hand over the persist gate: $out" ;;
  esac
  case "$out" in
    *"lead-restart --to beta --persisted"*) ;;
    *) fail "the report does not name the exact command: $out" ;;
  esac
  # The wake is an INSTRUCTION firstmate acts on, not an option to put to the
  # captain: the captain set the threshold, so the threshold firing is the
  # instruction. It must say so itself, because the line has to be complete with
  # no skill loaded, and it must name the skill that owns the handling.
  case "$out" in
    *"without asking the captain"*) ;;
    *) fail "the wake does not say firstmate acts on it without captain approval: $out" ;;
  esac
  case "$out" in
    *"claude-seat-lead-restart"*) ;;
    *) fail "the wake does not name the skill that owns this handling: $out" ;;
  esac
  case "$out" in
    *"FIRST persist the open work"*"THEN run exactly"*) ;;
    *) fail "the wake does not order the persist step before the command: $out" ;;
  esac
  [ -z "$(run_home "$SEAT" auto)" ] || fail "the same crossing was reported twice"
  # Back above the trigger, the crossing re-arms rather than staying spent.
  printf '%s\t50\n%s\t90\n' "$SEATS_DIR/alpha" "$SEATS_DIR/beta" > "$SPEC_DIR/remaining_map"
  [ -z "$(run_home "$SEAT" auto)" ] || fail "a seat back above the trigger reported something"
  printf '%s\t5\n%s\t90\n' "$SEATS_DIR/alpha" "$SEATS_DIR/beta" > "$SPEC_DIR/remaining_map"
  out=$(run_home "$SEAT" auto)
  case "$out" in
    *"moves to beta now"*) ;;
    *) fail "the crossing did not re-arm after the seat recovered: $out" ;;
  esac
  kill -0 "$LEAD_PID" 2>/dev/null || fail "the automatic pass disturbed the lead"
  stop_case
  pass "the lead's own crossing hands over a binding move once per seat, with the persist gate and the exact command"
}

test_the_lead_trigger_reports_the_blocker_rather_than_an_impossible_move() {
  local rec out
  rec=$(make_case auto-lead-blocked alpha tmux ''); read_case "$rec"
  printf '%s\t5\n%s\t90\n' "$SEATS_DIR/alpha" "$SEATS_DIR/beta" > "$SPEC_DIR/remaining_map"
  run_home "$SEAT" threshold 15 >/dev/null
  out=$(run_home "$SEAT" auto)
  case "$out" in
    *"cannot move to beta"*"terminal the lead runs in is not established"*) ;;
    *) fail "an unavailable move was not reported as one: $out" ;;
  esac
  case "$out" in
    *lead-restart*) fail "a restart command was offered for a move that would refuse: $out" ;;
  esac
  stop_case
  pass "a crossing the lead cannot act on names the blocker instead of offering a restart"
}

# --- layer 4: the real swap, in a real terminal ------------------------------

wait_for() {  # <seconds> <shell-test>
  local limit=$1 expr=$2 i=0
  while [ "$i" -lt "$((limit * 4))" ]; do
    if eval "$expr"; then return 0; fi
    sleep 0.25
    i=$((i + 1))
  done
  return 1
}

# The stand-in lead: it acquires the home's lock from inside its own process
# tree exactly as the real primary does at session start, reproduces the
# documented resume contract (a --resume keeps the session id; only
# --fork-session mints a new one), and then serves a command file so the manual
# restart command can be run from INSIDE the lead, which is where it runs.
write_stand_in_lead() {  # <path> <lab>
  cat > "$1" <<SH
#!/usr/bin/env bash
set -u
LAB=$2
ROOT=$ROOT
SH
  cat >> "$1" <<'SH'
sess=${FM_TEST_SESSION:-lead-session-1}
while [ "$#" -gt 0 ]; do
  case "$1" in --resume) sess=$2; shift 2 ;; *) shift ;; esac
done
export CLAUDE_CODE_SESSION_ID="$sess"
export CLAUDE_PID=$$
FM_HOME="$LAB/home" FM_STATE_OVERRIDE="$LAB/home/state" "$ROOT/bin/fm-lock.sh" >> "$LAB/lock.out" 2>&1
printf 'lead pid=%s session=%s profile=%s\n' "$$" "$sess" "${CLAUDE_CONFIG_DIR:-none}" >> "$LAB/lead.log"
: > "$LAB/cmd.in"
# Published only once the command file is initialized, so a caller can never
# write a command into the moment before this truncates it.
: > "$LAB/ready"
while :; do
  if [ -s "$LAB/cmd.in" ]; then
    cmd=$(cat "$LAB/cmd.in"); : > "$LAB/cmd.in"
    { eval "$cmd"; printf '[rc=%s]\n' "$?"; } >> "$LAB/cmd.log" 2>&1
  fi
  sleep 0.5
done
SH
  chmod +x "$1"
}

lead_run() {  # <lab> <command>
  wait_for 30 "[ -f '$1/ready' ]" || fail "the stand-in lead never became ready"
  : > "$1/cmd.log"
  printf '%s\n' "$2" > "$1/cmd.in"
  wait_for 30 "[ ! -s '$1/cmd.in' ]" || fail "the stand-in lead never picked up its command"
}

test_the_lead_is_replaced_in_its_own_terminal_with_supervision_unbroken() {
  local lab sock pane old new watcher out
  command -v tmux >/dev/null 2>&1 || { echo "ok - # skip: tmux not found, the real-terminal swap needs one"; return 0; }
  lab="$TMP_ROOT/swap"
  mkdir -p "$lab/home/state" "$lab/home/config" "$lab/home/data" "$lab/seats/alpha" "$lab/seats/beta" "$lab/fake"
  FAKEBIN=$(fm_fakebin "$lab/fake")
  fm_test_make_quota_fake "$FAKEBIN" "$lab/spec"
  printf '%s\n%s\n' "$lab/seats/alpha" "$lab/seats/beta" > "$lab/spec/oauth"
  printf '90\n' > "$lab/spec/remaining"
  printf '%s\n' "$lab/seats" > "$lab/home/config/claude-seats-root"
  write_stand_in_lead "$lab/lead.sh" "$lab"

  sock="fm-lead-restart-$$"
  CLEAN_TMUX+=("$sock")
  tmux -L "$sock" new-session -d -s lab -x 200 -y 50 || fail "could not start the test tmux server"
  pane=$(tmux -L "$sock" list-panes -a -F '#{pane_id}' | head -1)
  # Every bare `tmux` the backend adapter runs must reach this private server.
  cat > "$FAKEBIN/tmux" <<SH
#!/usr/bin/env bash
exec $(command -v tmux) -L "$sock" "\$@"
SH
  chmod +x "$FAKEBIN/tmux"

  tmux -L "$sock" send-keys -t "$pane" \
    "CLAUDE_CONFIG_DIR='$lab/seats/alpha' '$FAKE_CLAUDE' '$lab/lead.sh'" Enter
  # The lead's readiness marker, not the lock file: the lock's first line lands
  # before the runtime record beside it, so gating on the lock alone races the
  # record this test then reads.
  wait_for 30 "[ -f '$lab/ready' ]" || fail "the stand-in lead never took the home's lock"
  old=$(cat "$lab/home/state/.lock")
  grep -q "^target=$pane\$" "$lab/home/state/.lock-runtime" ||
    fail "the lead did not record its own pane: $(cat "$lab/home/state/.lock-runtime")"

  # A supervision cycle, started where the real one is: inside the lead's own
  # process tree. It must survive the swap, because the cycle count may never
  # drop to zero while work is under way.
  lead_run "$lab" "{ /bin/sh -c 'while :; do date +%s > $lab/beat; sleep 1; done' >/dev/null 2>&1 & echo \$! > $lab/watcher.pid; }"
  wait_for 20 "[ -s '$lab/watcher.pid' ] && [ -s '$lab/beat' ]" || fail "the stand-in supervision cycle never started"
  watcher=$(cat "$lab/watcher.pid")

  lead_run "$lab" "FM_HOME=$lab/home FM_STATE_OVERRIDE=$lab/home/state FM_CONFIG_OVERRIDE=$lab/home/config FM_DATA_OVERRIDE=$lab/home/data PATH=$FAKEBIN:\$PATH $SEAT lead-restart --to beta --persisted"
  wait_for 30 "grep -q 'handover armed' '$lab/cmd.log' 2>/dev/null" ||
    fail "the restart was never armed: $(cat "$lab/cmd.log" 2>/dev/null)"
  [ -f "$lab/home/state/.lock-handover" ] ||
    fail "the home was not reserved while the outgoing lead still held it"

  wait_for 120 "! kill -0 $old 2>/dev/null" || fail "the previous lead never ended"
  wait_for 180 "grep -q '^state=' '$lab/home/state/.lead-restart.result' 2>/dev/null" ||
    fail "the swap never reported an outcome"
  out=$(cat "$lab/home/state/.lead-restart.result")
  case "$out" in
    *"state=done"*) ;;
    *) fail "the swap did not complete: $out" ;;
  esac

  new=$(cat "$lab/home/state/.lock")
  [ "$new" != "$old" ] || fail "the lock still names the process that was replaced"
  kill -0 "$new" 2>/dev/null || fail "the new lead is not running"
  [ "$(ps -o args= -p "$new" | grep -c -- "--resume lead-session-1")" -eq 1 ] ||
    fail "the new lead did not resume the same session: $(ps -o args= -p "$new")"
  grep -q "^profile=$lab/seats/beta\$" "$lab/home/state/.lock-runtime" ||
    fail "the new lead is not on the destination seat: $(cat "$lab/home/state/.lock-runtime")"
  grep -q "^target=$pane\$" "$lab/home/state/.lock-runtime" ||
    fail "the new lead is not in the same terminal: $(cat "$lab/home/state/.lock-runtime")"
  [ ! -f "$lab/home/state/.lock-handover" ] || fail "the reservation outlived the completed handover"
  [ "$(ps -eo pid=,args= | grep -c "[c]laude $lab/lead.sh")" -eq 1 ] ||
    fail "more than one lead is running: $(ps -eo pid=,args= | grep "[c]laude $lab/lead.sh")"
  kill -0 "$watcher" 2>/dev/null || fail "the supervision cycle was killed with the lead"
  [ "$(cat "$lab/beat")" -ge "$(( $(date +%s) - 10 ))" ] ||
    fail "the supervision cycle stopped reporting across the swap"

  kill "$new" "$watcher" 2>/dev/null || true
  pass "the lead is replaced in its own terminal, on the new seat, resuming the same session, with one holder throughout"
}

test_check_establishes_every_part_of_the_move
test_refuses_without_the_persist_gate
test_refuses_a_destination_that_is_not_proven_signed_in
test_refuses_when_the_terminal_or_the_lead_profile_is_not_established
test_a_runtime_record_for_another_pid_is_not_evidence
test_refuses_the_ambient_default_and_the_seat_already_held
test_only_the_lead_may_replace_the_lead
test_launch_command_is_established_only_when_it_round_trips
test_a_reservation_holds_the_home_for_its_successor_alone
test_a_lapsed_reservation_never_wedges_the_home
test_the_outgoing_session_keeps_confirming_its_own_lock
test_only_the_lock_holder_may_reserve_the_home
test_the_detached_stage_can_drop_the_reservation_it_armed
test_the_lead_trigger_fires_once_per_seat_and_hands_over_the_gate
test_the_lead_trigger_reports_the_blocker_rather_than_an_impossible_move
test_the_lead_is_replaced_in_its_own_terminal_with_supervision_unbroken

echo "# all fm-lead-restart tests passed"
