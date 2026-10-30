#!/usr/bin/env bash
# Opt-in real T3 worker and secondmate round trips; never restart or configure T3.
# Set FM_T3_LIVE_E2E=1, FM_T3_BIN, FM_T3_BASE_DIR and the advertised model slugs
# FM_T3_LIVE_CLAUDE_MODEL / FM_T3_LIVE_CODEX_MODEL. This spends provider tokens.
# Fixture Git repositories and a fake allocator never touch the shared pool.
# Cleanup deletes only each recorded dedicated project through the T3 backend.
# An uncertain launch/cleanup preserves its fixture and reports the exact path.
# FM_T3_LIVE_EVIDENCE_DIR optionally retains protocol proof and cleanup receipts.
# FM_T3_LIVE_CASE=all|claude|codex|secondmate selects a bounded rerun (default all).
set -eu
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

fm_live_gate opt-in FM_T3_LIVE_E2E "${FM_T3_BIN:-t3}" jq python3
[ -n "${FM_T3_BASE_DIR:-}" ] && [ -d "$FM_T3_BASE_DIR" ] || fail 'FM_T3_BASE_DIR must name the running T3 data directory'
LIVE_CASE=${FM_T3_LIVE_CASE-all}
case "$LIVE_CASE" in all|claude|codex|secondmate) ;; *) fail 'FM_T3_LIVE_CASE must be all, claude, codex or secondmate' ;; esac
if [ "$LIVE_CASE" != codex ]; then
  [ -n "${FM_T3_LIVE_CLAUDE_MODEL:-}" ] || fail 'FM_T3_LIVE_CLAUDE_MODEL must name an advertised Claude model'
fi
if [ "$LIVE_CASE" = all ] || [ "$LIVE_CASE" = codex ]; then
  [ -n "${FM_T3_LIVE_CODEX_MODEL:-}" ] || fail 'FM_T3_LIVE_CODEX_MODEL must name an advertised Codex model'
fi
unset NO_MISTAKES_GATE

LAB=$(fm_test_tmproot fm-t3-live)
TIMEOUT=${FM_T3_LIVE_TIMEOUT:-360}
case "$TIMEOUT" in ''|*[!0-9]*|0*) fail 'FM_T3_LIVE_TIMEOUT must be a positive integer' ;; esac
T3_REAL=$(command -v "${FM_T3_BIN:-t3}")
export FM_T3_BIN=$T3_REAL
RECORDS=()
UNCONFIRMED=0
CHILD_PID=''
CHECKED=0
# shellcheck source=bin/fm-backend.sh
. "$ROOT/bin/fm-backend.sh"
fm_backend_source t3

cleanup_live() {
  local result=$? record case_dir destination file attempt=0
  trap - EXIT
  for record in "${RECORDS[@]:-}"; do
    [ -n "$record" ] || continue
    if [ ! -f "$record/thread.json" ]; then
      [ ! -e "$record" ] || UNCONFIRMED=1
      continue
    fi
    if ! fm_backend_t3_kill "$record"; then
      printf 'not ok - T3 cleanup unconfirmed; retain exact record %s\n' "$record" >&2
      UNCONFIRMED=1
    fi
  done
  if [ -n "$CHILD_PID" ]; then
    while kill -0 "$CHILD_PID" 2>/dev/null || ps -p "$CHILD_PID" -o pid= >/dev/null 2>&1; do
      if [ "$attempt" -ge 120 ]; then
        printf 'not ok - exact scratch Claude pid %s still exists after cleanup\n' "$CHILD_PID" >&2
        UNCONFIRMED=1
        break
      fi
      sleep 1
      attempt=$((attempt + 1))
    done
    if [ "$attempt" -lt 120 ]; then
      printf '{"pid":%s,"exited":true,"observedAtUnix":%s}\n' "$CHILD_PID" "$(date +%s)" \
        > "$LAB/secondmate/proof/process-after-cleanup.json"
    fi
  fi
  if [ -n "${FM_T3_LIVE_EVIDENCE_DIR:-}" ]; then
    mkdir -p "$FM_T3_LIVE_EVIDENCE_DIR"
    for case_dir in "$LAB"/*; do
      [ -d "$case_dir/proof" ] || continue
      destination="$FM_T3_LIVE_EVIDENCE_DIR/${case_dir##*/}"
      mkdir -p "$destination/proof" "$destination/state"
      cp -R "$case_dir/proof/." "$destination/proof/"
      for file in "$case_dir"/home/state/*.t3 "$case_dir"/home/state/*.meta; do
        [ ! -e "$file" ] || cp -R "$file" "$destination/state/"
      done
    done
  fi
  if [ "$UNCONFIRMED" = 1 ]; then
    printf 'not ok - retain scratch fixture for reconciliation: %s\n' "$LAB" >&2
    exit 1
  fi
  if [ "$result" -ne 0 ]; then
    printf 'not ok - retain failed test evidence: %s\n' "$LAB" >&2
    exit "$result"
  fi
  fm_test_cleanup
  exit "$result"
}
trap cleanup_live EXIT

wait_for_file() { # <file>
  local i=0
  while [ "$i" -lt "$TIMEOUT" ]; do
    [ ! -s "$1" ] || return 0
    sleep 1
    i=$((i + 1))
  done
  fail "T3 timed out waiting for task proof $1 (fixture $LAB)"
}

home_command() { # <command> [arguments]
  local command=$1
  shift
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_DATA_OVERRIDE="$HOME_DIR/data" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_SPAWN_NO_GUARD=1 \
    FM_CREW_STATE_NO_FORGE=1 PATH="$FAKEBIN:$PATH" \
    bash "$ROOT/bin/$command" "$@"
}

make_live_case() { # <name> <harness>
  CASE="$LAB/$1"
  TASK="fm-t3-live-$1"
  HOME_DIR="$CASE/home"
  PROJECT="$CASE/project"
  WORKTREE="$CASE/worktree"
  fm_test_spawn_home "$HOME_DIR" "$2"
  mkdir -p "$CASE/proof" "$HOME_DIR/data/$TASK"
  printf 'manual\n' > "$HOME_DIR/config/backlog-backend"
  FAKEBIN=$(fm_test_make_spawn_fakebin "$CASE")
  fm_test_fake_no_mistakes "$FAKEBIN"
  cat > "$FAKEBIN/treehouse" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  get) printf '%s\n' "$FM_T3_LIVE_WORKTREE" ;;
esac
SH
  chmod +x "$FAKEBIN/treehouse"
}

write_live_brief() { # <destination> <role>
  cat > "$1" <<EOF
# Task
## Captain's intent
Exercise the scratch T3 $2 protocol round trip through normal Firstmate paths.

## Firstmate spec
You are a test $2 in an isolated fixture, managed only by this test's parent.
Do not contact a human, delegate work, use network tools, run no-mistakes, or repair infrastructure.
The only authorized paths are this checkout, $CASE/proof, $HOME_DIR/state/$TASK.inbox and $HOME_DIR/state/$TASK.status.
Your exact steering inbox is $HOME_DIR/state/$TASK.inbox, even if an inherited environment variable differs.
Do not process the inbox until the separate Firstmate doorbell arrives.
First run a shell command that writes the literal values of FM_HOME and FM_TASK_INBOX, one per line, into $CASE/proof/environment.
Then write READY to $CASE/proof/ready.
In that same shell command, wait for $CASE/proof/release using one-second sleeps, bounded at $((TIMEOUT * 2)) iterations.
When release appears, answer INITIAL_TURN_COMPLETE and finish this turn.
When a later inbox doorbell arrives, read each pending message in numeric order, do its requested action, and move it into the inbox's handled directory.
EOF
}

exercise_round_trip() { # <expected-native-home>
  local expected_home=$1 record="$HOME_DIR/state/$TASK.t3" state ring file before after
  wait_for_file "$CASE/proof/ready"
  if [ "$expected_home" != none ]; then
    [ "$(head -n 1 "$CASE/proof/environment")" = "$expected_home" ] \
      || fail "Claude native settings did not bind FM_HOME to $expected_home"
  fi
  state=$(home_command fm-crew-state.sh "$TASK")
  printf '%s\n' "$state" > "$CASE/proof/busy-state"
  assert_contains "$state" 'state: working' 'native T3 active run must read working'
  home_command fm-peek.sh "$TASK" 20 > "$CASE/proof/peek"
  assert_contains "$(cat "$CASE/proof/peek")" "$CASE/proof/release" 'normal peek must capture the native thread message'
  before=$(date +%s)
  home_command fm-send.sh "$TASK" \
    "For this scratch protocol test, acknowledge this exact inbox message by moving it into handled/. Append working [at=<real current Unix timestamp in digits>]: T3_STEER_ACK to $HOME_DIR/state/$TASK.status, replacing the placeholder with the actual current Unix timestamp. Finally write T3_STEER_ACK to $CASE/proof/acknowledged and finish without any other work." \
    > "$CASE/proof/send"
  ring=
  for file in "$record"/rings/*/result.json; do
    [ -f "$file" ] || continue
    [ -z "$ring" ] || fail 'one durable steer must produce one native ring'
    ring=$file
  done
  [ -n "$ring" ] || fail 'normal send did not record its T3 acceptance'
  jq -e '.delivery == "queued" and (.messageId|type == "string")' "$ring" >/dev/null \
    || fail 'native send must queue behind the deliberately held initial run'
  printf 'release\n' > "$CASE/proof/release"
  wait_for_file "$CASE/proof/acknowledged"
  after=$(date +%s)
  [ "$(cat "$CASE/proof/acknowledged")" = T3_STEER_ACK ] || fail 'steer action was not performed'
  python3 - "$HOME_DIR/state/$TASK.status" "$before" "$after" <<'PY'
import re, sys
from pathlib import Path
matches = [re.fullmatch(r'working \[at=([0-9]+)\]: T3_STEER_ACK', line)
           for line in Path(sys.argv[1]).read_text().splitlines()]
assert any(match and int(sys.argv[2]) <= int(match[1]) <= int(sys.argv[3])
           for match in matches), 'native task must append an actual current numeric status timestamp'
PY
  cp "$HOME_DIR/state/$TASK.status" "$CASE/proof/status"
  file=
  for ring in "$HOME_DIR/state/$TASK.inbox/handled"/*.msg; do
    [ -f "$ring" ] || continue
    file=$ring
  done
  [ -n "$file" ] || fail 'T3 worker did not acknowledge its durable inbox message'
  CHECKED=$((CHECKED + 1))
  pass "real T3 $TASK: native busy, queue, peek, action, numeric status and inbox acknowledgement"
}

printf '# T3 live scope: %s\n' "$LIVE_CASE"
for harness in claude codex; do
  [ "$LIVE_CASE" = all ] || [ "$LIVE_CASE" = "$harness" ] || continue
  make_live_case "$harness" "$harness"
  fm_git_worktree "$PROJECT" "$WORKTREE" "fixture-$harness"
  write_live_brief "$HOME_DIR/data/$TASK/brief.md" scout
  case "$harness" in
    claude) model=$FM_T3_LIVE_CLAUDE_MODEL ;;
    codex) model=$FM_T3_LIVE_CODEX_MODEL ;;
  esac
  RECORDS+=("$HOME_DIR/state/$TASK.t3")
  FM_T3_LIVE_WORKTREE="$WORKTREE" \
    fm_test_run_spawn "$HOME_DIR" "$WORKTREE" "$FAKEBIN" \
      "$TASK" "$PROJECT" --backend t3 --harness "$harness" --model "$model" --scout \
      > "$CASE/proof/spawn" || fail "real T3 $harness scout launch failed; inspect $CASE/proof/spawn"
  if [ "$harness" = claude ]; then expected=$WORKTREE; else expected=none; fi
  exercise_round_trip "$expected"
done

if [ "$LIVE_CASE" = all ] || [ "$LIVE_CASE" = secondmate ]; then
make_live_case secondmate claude
CHILD_HOME="$CASE/secondmate"
fm_git_init_commit "$CHILD_HOME"
git -C "$ROOT" archive HEAD | tar -xf - -C "$CHILD_HOME"
cp -R "$ROOT/bin/." "$CHILD_HOME/bin/"
mkdir -p "$CHILD_HOME/data" "$CHILD_HOME/state" "$CHILD_HOME/config" "$CHILD_HOME/projects"
printf '%s\n' "$TASK" > "$CHILD_HOME/.fm-secondmate-home"
printf 'manual\n' > "$CHILD_HOME/config/backlog-backend"
touch "$CHILD_HOME/config/supervision-host-off"
write_live_brief "$CHILD_HOME/data/charter.md" secondmate
RECORDS+=("$HOME_DIR/state/$TASK.t3")
FM_SKIP_SECONDMATE_SYNC=1 FM_SKIP_SECONDMATE_INHERIT=1 \
  fm_test_run_spawn "$HOME_DIR" "$CHILD_HOME" "$FAKEBIN" \
    "$TASK" "$CHILD_HOME" --backend t3 --harness claude --model "$FM_T3_LIVE_CLAUDE_MODEL" --secondmate \
    > "$CASE/proof/spawn" || fail "real T3 secondmate launch failed; inspect $CASE/proof/spawn"
wait_for_file "$CASE/proof/ready"
[ -s "$CHILD_HOME/state/.lock" ] || fail 'native secondmate SessionStart did not acquire its own home lock'
CHILD_PID=$(cat "$CHILD_HOME/state/.lock")
case "$CHILD_PID" in ''|*[!0-9]*|0|1) fail 'native secondmate lock has an invalid PID' ;; esac
for file in .lock .lock-session .lock-runtime; do
  [ ! -f "$CHILD_HOME/state/$file" ] || cp "$CHILD_HOME/state/$file" "$CASE/proof/native$file"
done
exercise_round_trip "$CHILD_HOME"
[ ! -e "$HOME_DIR/state/.lock" ] || fail 'native secondmate hook claimed the parent scratch home'
pass 'real T3 Claude secondmate: charter, inbox and native SessionStart own the child home'
printf '# This guard does not arm a watcher; refresh handover separately with tests/fm-t3-leader-live-e2e.test.sh.\n'
fi
[ "$CHECKED" -gt 0 ] || fail 'T3 live guard verified no case'
