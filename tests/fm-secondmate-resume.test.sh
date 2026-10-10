#!/usr/bin/env bash
# Session capture and parked-wake validation use durable fixtures and a runtime
# identity stand-in. No harness or Herdr lifecycle commands run here.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-secondmate-resume-lib.sh
. "$ROOT/bin/fm-secondmate-resume-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-secondmate-resume)
mkdir -p "$TMP_ROOT/home/state"
trap 'fm_test_remove_tree "$TMP_ROOT"' EXIT
meta="$TMP_ROOT/mate.meta"
marker="$TMP_ROOT/park"
write_meta() {
  printf 'kind=secondmate\nhome=%s\nharness=%s\nbackend=%s\nwindow=lab:%%7\n' \
    "$TMP_ROOT/home" "$1" "${2:-tmux}" > "$meta"
}
write_marker() {
  printf 'home=%s\nphase=%s\npersisted=%s\nresume_mode=%s\nresume_harness=%s\nresume_ref=%s\n' \
    "$TMP_ROOT/home" "$1" "$2" "$3" "$4" "$5" > "$marker"
}

write_meta claude
printf 'exact-claude-id\n' > "$TMP_ROOT/home/state/.lock-session"
fm_secondmate_resume_capture "$meta"
[ "$FM_SECONDMATE_RESUME_MODE:$FM_SECONDMATE_RESUME_HARNESS:$FM_SECONDMATE_RESUME_REF" = exact:claude:exact-claude-id ] || fail "Claude capture must preserve its recorded session"
rm "$TMP_ROOT/home/state/.lock-session"
fm_secondmate_resume_capture "$meta"
[ "$FM_SECONDMATE_RESUME_MODE:$FM_SECONDMATE_RESUME_REF" = fresh: ] || fail "no session record must select fresh"
write_meta codex
fm_secondmate_resume_capture "$meta"
[ "$FM_SECONDMATE_RESUME_MODE:$FM_SECONDMATE_RESUME_HARNESS" = fresh:codex ] || fail "unsupported exact resume must be declared fresh"
pass "capture preserves Claude's recorded session and declares unavailable continuity"

# Use the real target parser and flag owner with a runtime identity stand-in.
fm_backend_source herdr
fm_backend_herdr_pane_agent_session_ref() {
  [ "$1:$2" = 'lab:%7' ] || return 1
  printf '%s\t%s' "$FAKE_AGENT" "$FAKE_REF"
}
FAKE_AGENT=pi
FAKE_REF="$TMP_ROOT/pi session's log.jsonl"
for harness in pi pi-signed; do
  write_meta "$harness" herdr
  fm_secondmate_resume_capture "$meta"
  [ "$FM_SECONDMATE_RESUME_MODE:$FM_SECONDMATE_RESUME_REF" = "exact:$FAKE_REF" ] || fail "Pi capture lost its exact path"
done
FAKE_AGENT=claude
fm_secondmate_resume_capture "$meta"
[ "$FM_SECONDMATE_RESUME_MODE" = fresh ] || fail "a different registered agent must not be adopted"
pass "Pi capture uses only its own endpoint's registered Pi identity"

write_marker waking 1 exact claude saved-id
fm_secondmate_resume_load "$marker" "$TMP_ROOT/home" claude || fail "persisted exact wake must load"
for phase in parking parked; do
  write_marker "$phase" 1 exact claude saved-id
  if fm_secondmate_resume_load "$marker" "$TMP_ROOT/home" claude; then fail "non-waking marker must refuse"; fi
done
write_marker waking 0 exact claude saved-id
if fm_secondmate_resume_load "$marker" "$TMP_ROOT/home" claude; then fail "unpersisted wake must refuse"; fi
write_marker waking 1 exact claude saved-id
if fm_secondmate_resume_load "$marker" "$TMP_ROOT/other" claude; then fail "foreign home must refuse"; fi
if fm_secondmate_resume_load "$marker" "$TMP_ROOT/home" codex; then fail "changed harness must refuse"; fi
printf 'resume_ref=another-id\n' >> "$marker"
if fm_secondmate_resume_load "$marker" "$TMP_ROOT/home" claude; then fail "duplicate reference must refuse"; fi
write_marker waking 1 exact codex saved-id
if fm_secondmate_resume_load "$marker" "$TMP_ROOT/home" codex; then fail "unsupported exact mode must refuse"; fi
write_marker waking 1 exact claude ''
if fm_secondmate_resume_load "$marker" "$TMP_ROOT/home" claude; then fail "lost exact ref must not fall back"; fi
write_marker waking 1 fresh codex ''
fm_secondmate_resume_load "$marker" "$TMP_ROOT/home" codex || fail "explicit fresh wake must load"
pass "wake validates persistence, identity, mode, and unambiguous exact reference"

mkdir -p "$TMP_ROOT/parent/state" "$TMP_ROOT/home/data"
printf 'mate\n' > "$TMP_ROOT/home/.fm-secondmate-home"
printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' \
  "$TMP_ROOT/parent" > "$TMP_ROOT/home/.fm-secondmate-parent"
printf 'phase=parked\n' > "$TMP_ROOT/parent/state/.secondmate-park-mate"
if out=$(FM_HOME="$TMP_ROOT/home" FM_SPAWN_NO_GUARD=1 bash "$ROOT/bin/fm-spawn.sh" \
  child "$TMP_ROOT/home" --harness claude --backend tmux --mode direct-PR --yolo off 2>&1); then
  fail "a parked home must refuse new children"
fi
assert_contains "$out" 'this secondmate home is parked' "fresh children must be refused under the task-set lock"
pass "a parked secondmate home refuses new task dispatch"
