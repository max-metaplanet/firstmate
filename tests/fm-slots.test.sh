#!/usr/bin/env bash
# Exercise the slots command against the real admission library, semantic
# records, local-home discovery, and tasks-axi markdown backlog reader.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-slots)
SLOTS=${FM_SLOTS_SCRIPT:-$ROOT/bin/fm-slots.sh}
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
holder "$MAIN" eng2765 claude
holder "$MAIN" eng2767 claude
holder "$MAIN" eng2100 claude
holder "$MAIN" finished claude scout
holder "$MAIN" stuck claude
mkdir "$CHILD/state/unreadable.status"
printf 'claude_seat=work\n' >> "$MAIN/state/busy.meta"
URL=https://github.com/example/widget/pull/42
printf 'pr=%s\n' "$URL" >> "$MAIN/state/merge.meta"
printf 'done [at=123]: PR %s checks green\n' "$URL" > "$MAIN/state/merge.status"
printf 'working [at=123]: old declaration alone proves no current work\n' > "$MAIN/state/unknown.status"
printf 'needs-decision [at=123] [key=choice]: choose\nworking [at=124]: unrelated event\n' > "$MAIN/state/decision.status"
printf 'resolved [at=123]: parked without a work declaration\n' > "$CHILD/state/idle.status"
printf 'done [at=123]: PR %s checks green\n' "$URL" > "$CHILD/state/resumed.status"
printf 'pr=%s\n' "$URL" >> "$CHILD/state/resumed.meta"
printf 'pr=%s\n' "$URL" >> "$CHILD/state/unready.meta"
printf 'paused [at=123]: validating\n' > "$CHILD/state/unready.status"
bash "$EV" arm "$MAIN/state" busy --source claude-hook >/dev/null
bash "$EV" arm "$CHILD/state" idle --state idle --source pi-ext >/dev/null
bash "$EV" arm "$CHILD/state" resumed --source claude-hook >/dev/null
printf 'working [at=123]: resolving a rebase conflict\n' > "$MAIN/state/eng2765.status"
printf 'paused [at=123]: no-mistakes fix round, waiting for review\n' > "$MAIN/state/eng2767.status"
printf 'needs-decision [at=123] [key=gate]: authorize fixes\nresolved [at=124] [key=gate]: fixes approved\npaused [at=125]: pipeline fix round, waiting for completion\n' > "$MAIN/state/eng2100.status"
printf 'done [at=123]: report written\n' > "$MAIN/state/finished.status"
printf 'blocked [at=123]: needs firstmate\n' > "$MAIN/state/stuck.status"
for id in eng2765 eng2767 eng2100 finished stuck; do
  bash "$EV" arm "$MAIN/state" "$id" --state idle --source claude-hook >/dev/null
done

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
axi add legacy-decision 'Legacy captain question' --kind captain
axi add released-decision 'Answered captain question' --kind captain --body $'Resolution recorded by fm-captain-hold.\nResolution mode: released\n'
axi add future 'Future dated work'
axi hold future --reason 'date gate' --until 2099-01-01
axi add due 'Date gate has arrived'
axi hold due --reason 'expired gate' --until 2000-01-01
axi add eng2769-dblocal-cleanup 'Next priority zero' --priority 0
axi add eng2772-qa-access 'Second priority zero' --priority 0
axi add eng2773-robots-nonprod 'Next priority one' --priority 1

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
assert_contains "$out" 'eng2765 | widget | ship | working' 'conflict resolution survives an idle hook'
assert_contains "$out" 'eng2767 | widget | ship | working' 'first paused fix round survives an idle hook'
assert_contains "$out" 'eng2100 | widget | ship | working' 'resolved gate followed by another fix round survives an idle hook'
assert_contains "$out" "$MAIN | merge | widget | ship | waiting on merge * | codex | $URL" 'green handoff holds a merge-waiting slot'
assert_contains "$out" 'busy | widget | ship | working | claude seat=work' 'trusted hook supplies work and recorded seat'
assert_contains "$out" 'decision | widget | ship | waiting on decision' 'unresolved question survives unrelated working event'
assert_contains "$out" 'unknown | widget | ship | working' 'working declaration uses the shared crew-state mapping'
assert_contains "$out" 'unreadable | widget | ship | unknown' 'unreadable status remains unknown'
assert_contains "$out" 'finished | widget | scout | idle-parked' 'finished worker on an idle hook is idle-parked'
assert_contains "$out" 'stuck | widget | ship | unknown' 'blocked worker on an idle hook stays unknown'
assert_contains "$out" 'idle | widget | secondmate | idle-parked' 'idle hook without a work declaration is parked'
assert_contains "$out" 'resumed | widget | ship | working' 'current busy evidence outranks old completion'
assert_contains "$out" 'unready | widget | ship | working' 'paused validation is work, not a merge wait'
assert_contains "$out" "QUEUE ($MAIN)" 'child defaults to main queue'
queue=${out#*QUEUE}
assert_contains "$queue" 'ready | ready-one | ENG-123 | Quoted, title ENG-123' 'quoted CSV and ticket render correctly'
assert_contains "$queue" '...' 'long queue titles truncate'
assert_not_contains "$queue" 'in-flight' 'running work is absent from queue'
ready=$(printf '%s\n' "$queue" | sed -n '/^A\./,/^B\./p')
held=$(printf '%s\n' "$queue" | sed -n '/^B\./,/^C\./p')
other=$(printf '%s\n' "$queue" | sed -n '/^C\./,$p')
order=$(printf '%s\n' "$ready" | awk -F ' [|] ' '/^  ready / {print $2}')
assert_equals "$order" $'eng2769-dblocal-cleanup\neng2772-qa-access\neng2773-robots-nonprod\nready-one\nready-two\ndue' 'priority ascending then FIFO, including an expired date gate'
assert_contains "$held" 'decision-row' 'structured captain hold stays in its own section'
assert_contains "$held" 'legacy-decision' 'legacy captain question is never shown ready'
assert_not_contains "$ready" 'decision-row' 'captain hold is not dispatchable'
assert_not_contains "$held" 'released-decision' 'recorded release is no longer an unanswered question'
assert_contains "$other" 'released-decision' 'released question record remains visible for reconciliation'
assert_contains "$other" 'blocked by blocker | blocked' 'dependency blocker is visible'
assert_contains "$other" 'until 2099-01-01 | future' 'future date gate is visible'
pass 'shared occupancy, honest local state, main queue order, and read-only behavior'

out=$(FM_HOME=$MAIN bash "$SLOTS" --home "$CHILD")
assert_contains "$out" "QUEUE ($CHILD)" 'explicit queue home override'
assert_contains "$out" "source: $MAIN/config/fleet-capacity" 'override still uses admission capacity source'

fm_git_init_commit "$MAIN/projects/capped-λ"
fm_git_add_origin "$MAIN/projects/capped-λ" "$TMP_ROOT/capped-origin.git"
git clone -q "$(git -C "$MAIN/projects/capped-λ" remote get-url origin)" "$CHILD/projects/alias"
holder "$MAIN" cap-one codex
printf 'project=%s\n' "$MAIN/projects/capped-λ" >> "$MAIN/state/cap-one.meta"
holder "$CHILD" cap-two codex
printf 'project=%s\n' "$CHILD/projects/alias" >> "$CHILD/state/cap-two.meta"
printf 'capped-λ 2\n' > "$MAIN/config/project-capacity"
axi add capped-next 'Capacity gated work' --repo capped-λ --priority 0
axi add free-next 'Uncapped work' --repo free --priority 0
before=$(snapshot)
out=$(FM_HOME=$MAIN bash "$SLOTS")
after=$(snapshot)
assert_equals "$before" "$after" 'project capacity projection is read-only'
ready=$(printf '%s\n' "$out" | sed -n '/^A\./,/^B\./p')
other=$(printf '%s\n' "$out" | sed -n '/^C\./,$p')
assert_not_contains "$ready" 'capped-next' 'same-origin holders across homes gate the capped project'
assert_contains "$ready" 'free-next' 'a full project does not gate another project'
assert_contains "$other" 'project capacity 2/2 | capped-next' 'exact project occupancy is shown as the blocker'
printf 'ad_hoc_slot=1\n' >> "$MAIN/state/cap-one.meta"
out=$(FM_HOME=$MAIN bash "$SLOTS")
assert_contains "$out" 'plus 1 ad hoc (source:' 'header names the ad hoc holder above the declared cap'
assert_contains "$(printf '%s\n' "$out" | sed -n '/^A\./,/^B\./p')" 'capped-next' 'an ad hoc holder leaves the declared project place free, as admission does'
grep -v '^ad_hoc_slot=' "$MAIN/state/cap-one.meta" > "$TMP_ROOT/cap-one.meta"
mv "$TMP_ROOT/cap-one.meta" "$MAIN/state/cap-one.meta"
printf 'pr=%s\n' "$URL" >> "$CHILD/state/cap-two.meta"
out=$(FM_HOME=$MAIN bash "$SLOTS")
assert_contains "$(printf '%s\n' "$out" | sed -n '/^A\./,/^B\./p')" 'capped-next' 'recorded handoff frees project capacity using admission rules'
[ ! -e "$FM_SLOTS_FORBIDDEN_CALLS" ] || fail 'capacity display called a forbidden external tool'
pass 'project capacity uses admission identity and handoff semantics'

i=1
while [ "$i" -le 60 ]; do axi add "extra-$i" "Queued item $i"; i=$((i+1)); done
i=1
while [ "$i" -le 16 ]; do
  axi add "held-$i" "Captain item $i" --kind captain
  axi add "dated-$i" "Dated item $i"
  axi hold "dated-$i" --reason 'later' --until 2099-01-01
  i=$((i+1))
done
out=$(FM_HOME=$MAIN bash "$SLOTS")
assert_contains "$out" '+53 more' '68 ready rows cap at 15 independently'
assert_equals "$(printf '%s\n' "${out#*QUEUE}" | sed -n '/^  .* | /p' | wc -l | tr -d ' ')" 45 'each section caps at fifteen rows'
assert_contains "$(printf '%s\n' "$out" | sed -n '/^B\./,/^C\./p')" '+3 more' 'captain section has its own remainder'
assert_contains "$(printf '%s\n' "$out" | sed -n '/^C\./,$p')" '+4 more' 'other section has its own remainder'
assert_contains "$out" 'decision-row' 'deep ready queue does not hide captain holds'
assert_contains "$out" 'blocked by blocker | blocked' 'deep ready queue does not hide blockers'
pass 'queue cap and remainder count'

missing=$TMP_ROOT/missing-state
mkdir -p "$missing/data" "$missing/config"
if FM_HOME=$missing bash "$SLOTS" >/dev/null 2>&1; then fail 'missing state must refuse'; fi
[ ! -e "$missing/state" ] || fail 'missing state was created'
printf 'bad\n' > "$MAIN/config/fleet-capacity"
if FM_HOME=$MAIN bash "$SLOTS" >/dev/null 2>&1; then fail 'bad cap must refuse'; fi
pass 'unreadable inputs refuse without creating state'

printf '12\n' > "$MAIN/config/fleet-capacity"
holder "$MAIN" external codex
printf 'phase=parked\ngeneration=legacy\nendpoint=external\nreason=upstream maintainer\nuntil=0\nqueued_at=0\n' > "$MAIN/state/external.park"
out=$(FM_HOME=$MAIN bash "$SLOTS")
assert_contains "$out" 'PARKED/WAITING (no active slot)' 'parked workers have a separate section'
assert_contains "$out" 'external | parked | upstream maintainer' 'parked section states the wait'
slots=${out%%PARKED/WAITING*}
assert_not_contains "$slots" 'external' 'parked worker is not a slot'
