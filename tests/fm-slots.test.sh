#!/usr/bin/env bash
# Exercise the slots command against the real admission library, semantic
# records, local-home discovery, and tasks-axi markdown backlog reader.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-slots)
SLOTS=$ROOT/bin/fm-slots.sh
EV=$ROOT/bin/fm-busy-event.sh
command -v tasks-axi >/dev/null || { echo 'skip - tasks-axi unavailable'; exit 0; }
fakebin=$(fm_fakebin "$TMP_ROOT")
export FM_SLOTS_FORBIDDEN_CALLS=$TMP_ROOT/forbidden-calls
for tool in gh-axi glab no-mistakes ssh curl herdr orca tmux; do
  cat > "$fakebin/$tool" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$0 $*" >> "$FM_SLOTS_FORBIDDEN_CALLS"
exit 1
SH
  chmod +x "$fakebin/$tool"
done
export PATH="$fakebin:$PATH"
MAIN=$TMP_ROOT/main
CHILD=$TMP_ROOT/child
for home in "$MAIN" "$CHILD"; do
  mkdir -p "$home/state" "$home/data" "$home/config"
  fm_test_tasks_toml "$home/.tasks.toml"
  printf '# Backlog\n\n## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
done
printf '12\n' > "$MAIN/config/fleet-capacity"
printf -- '- child - local secondmate (home: %s; scope: fixtures; projects: test; added 2026-10-19)\n' "$CHILD" > "$MAIN/data/secondmates.md"
printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$MAIN" > "$CHILD/.fm-secondmate-parent"

holder() { # <home> <id> <harness> [kind]
  cat > "$1/state/$2.meta" <<EOF
kind=${4:-ship}
project=/fixture/widget
harness=$3
backend=orca
window=$2
yolo=off
EOF
}
holder "$MAIN" busy claude
holder "$MAIN" merge codex
holder "$MAIN" unknown codex
holder "$MAIN" decision claude
holder "$CHILD" idle pi secondmate
holder "$CHILD" resumed claude
holder "$CHILD" unready codex
holder "$CHILD" unreadable claude
mkdir "$CHILD/state/unreadable.status"
printf 'claude_seat=work\n' >> "$MAIN/state/busy.meta"
URL=https://github.com/example/widget/pull/42
printf 'pr=%s\n' "$URL" >> "$MAIN/state/merge.meta"
printf 'done [at=123]: PR %s checks green\n' "$URL" > "$MAIN/state/merge.status"
printf 'working [at=123]: old declaration alone proves no current work\n' > "$MAIN/state/unknown.status"
printf 'needs-decision [at=123] [key=choice]: choose\nworking [at=124]: unrelated event\n' > "$MAIN/state/decision.status"
printf 'working [at=123]: idle hook is authoritative\n' > "$CHILD/state/idle.status"
printf 'done [at=123]: PR %s checks green\n' "$URL" > "$CHILD/state/resumed.status"
printf 'pr=%s\n' "$URL" >> "$CHILD/state/resumed.meta"
printf 'pr=%s\n' "$URL" >> "$CHILD/state/unready.meta"
printf 'paused [at=123]: validating\n' > "$CHILD/state/unready.status"
bash "$EV" arm "$MAIN/state" busy --source claude-hook >/dev/null
bash "$EV" arm "$CHILD/state" idle --state idle --source pi-ext >/dev/null
bash "$EV" arm "$CHILD/state" resumed --source claude-hook >/dev/null

axi() { FM_HOME=$MAIN FM_DATA_OVERRIDE=$MAIN/data bash "$ROOT/bin/fm-tasks-axi.sh" "$@" >/dev/null; }
axi add blocked 'Wait for blocker'
axi add decision-row 'Choose a design'
axi hold decision-row --kind captain --reason 'choice needed'
axi add blocker 'Dependency in flight'
axi start blocker
axi block blocked --by blocker
axi add ready-one 'Quoted, title ENG-123'
axi add ready-two 'A long title that must be truncated because it has far more than sixty characters at the terminal'
axi add in-flight 'Not queued'
axi start in-flight

# Read the same library call as admission, not a count mirrored by the test.
expected=$(
  export FM_HOME=$MAIN
  STATE=$MAIN/state
  # shellcheck source=bin/fm-wake-lib.sh
  . "$ROOT/bin/fm-wake-lib.sh"
  # shellcheck source=bin/fm-secondmate-registry-lib.sh
  . "$ROOT/bin/fm-secondmate-registry-lib.sh"
  # shellcheck source=bin/fm-backend.sh
  . "$ROOT/bin/fm-backend.sh"
  # shellcheck source=bin/fm-project-capacity-lib.sh
  . "$ROOT/bin/fm-project-capacity-lib.sh"
  # shellcheck source=bin/fm-fleet-capacity-lib.sh
  . "$ROOT/bin/fm-fleet-capacity-lib.sh"
  fm_fleet_capacity_occupants "$STATE" ''
  printf '%s' "$FM_FLEET_CAPACITY_OCCUPANTS"
)

snapshot() { find "$MAIN" "$CHILD" -type f -exec cksum {} + | sort; find "$MAIN" "$CHILD" -print | sort; }
before=$(snapshot)
out=$(FM_HOME=$CHILD FM_DATA_OVERRIDE=/bad/inherited FM_STATE_OVERRIDE=/bad/inherited bash "$SLOTS")
after=$(snapshot)
assert_equals "$before" "$after" 'view writes no home files or directory entries'
[ ! -e "$FM_SLOTS_FORBIDDEN_CALLS" ] || fail 'display called a forbidden external tool'
assert_contains "$out" "slots $expected/12 (source: $MAIN/config/fleet-capacity)" 'count equals admission across homes'
assert_contains "$out" "$MAIN | merge | widget | ship | waiting on captain merge * | codex | $URL" 'green handoff holds a merge-waiting slot'
assert_contains "$out" 'busy | widget | ship | working | claude seat=work' 'trusted hook supplies work and recorded seat'
assert_contains "$out" 'decision | widget | ship | waiting on decision' 'unresolved question survives unrelated working event'
assert_contains "$out" 'unknown | widget | ship | unknown' 'stale working declaration never guesses current state'
assert_contains "$out" 'unreadable | widget | ship | unknown' 'unreadable status remains unknown'
assert_contains "$out" 'idle | widget | secondmate | idle' 'trusted idle hook is readable'
assert_contains "$out" 'resumed | widget | ship | working' 'current busy evidence outranks old completion'
assert_contains "$out" 'unready | widget | ship | unknown' 'PR URL alone does not prove merge readiness'
assert_contains "$out" "QUEUE ($MAIN)" 'child defaults to main queue'
queue=${out#*QUEUE}
assert_contains "$queue" 'ready | ready-one | ENG-123 | Quoted, title ENG-123' 'quoted CSV and ticket render correctly'
assert_contains "$queue" '...' 'long queue titles truncate'
assert_not_contains "$queue" 'in-flight' 'running work is absent from queue'
order=$(printf '%s\n' "$queue" | awk '/^  / {print $1}')
assert_equals "$order" $'ready\nready\nblocked\ndecision:' 'ready then blocked then captain decisions'
pass 'shared occupancy, honest local state, main queue order, and read-only behavior'

out=$(FM_HOME=$MAIN bash "$SLOTS" --home "$CHILD")
assert_contains "$out" "QUEUE ($CHILD)" 'explicit queue home override'
assert_contains "$out" "source: $MAIN/config/fleet-capacity" 'override still uses admission capacity source'

i=1
while [ "$i" -le 60 ]; do axi add "extra-$i" "Queued item $i"; i=$((i+1)); done
out=$(FM_HOME=$MAIN bash "$SLOTS")
assert_contains "$out" '+49 more' '64 queued rows cap at 15'
assert_equals "$(printf '%s\n' "${out#*QUEUE}" | sed -n '/^  .* | /p' | wc -l | tr -d ' ')" 15 'exactly fifteen queue rows'
pass 'queue cap and remainder count'

missing=$TMP_ROOT/missing-state
mkdir -p "$missing/data" "$missing/config"
if FM_HOME=$missing bash "$SLOTS" >/dev/null 2>&1; then fail 'missing state must refuse'; fi
[ ! -e "$missing/state" ] || fail 'missing state was created'
printf 'bad\n' > "$MAIN/config/fleet-capacity"
if FM_HOME=$MAIN bash "$SLOTS" >/dev/null 2>&1; then fail 'bad cap must refuse'; fi
pass 'unreadable inputs refuse without creating state'
