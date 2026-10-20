#!/usr/bin/env bash
# Live lab: real herdr fm-lab-* session. A secondmate pane is created then closed
# (endpoint missing); park must prove it gone via fm-control's absence proof and park.
set -u
WT=${WT:?}; cd "$WT"
. tests/herdr-test-safety.sh
unset FM_GATE_REFUSE_BYPASS          # drive the real gate guard; lab homes must permit it
herdr_forget_inherited_pane
SESSION="fm-lab-parkgone-$$"
LAB=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")" && pwd -P); bin/fm-lab-home.sh create "$LAB" >/dev/null
MATE=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/fm-lab-mate.XXXXXX")" && pwd -P); bin/fm-lab-home.sh create "$MATE" >/dev/null
PREP=0
cleanup() { [ "$PREP" = 1 ] && { herdr_safe_stop_and_delete "$SESSION" && echo "== teardown: lab session $SESSION removed"; }; rm -rf "$LAB" "$MATE"; }
trap cleanup EXIT
fm_herdr_lab_prepare "$SESSION" || { echo "prepare failed"; exit 1; }; PREP=1
export HERDR_SESSION="$SESSION"
echo "== herdr $(herdr --version 2>&1 | head -1); session=$SESSION; NO_MISTAKES_GATE=${NO_MISTAKES_GATE+set}"
git init -q "$MATE"; git -C "$MATE" -c user.name=t -c user.email=t@e commit -q --allow-empty -m init
printf 'sm1\n' > "$MATE/.fm-secondmate-home"
printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$LAB" > "$MATE/.fm-secondmate-parent"
printf 'claude\n' > "$LAB/config/secondmate-harness"; mkdir -p "$LAB/data/sm1"; printf '# charter\n' > "$LAB/data/sm1/brief.md"
printf -- '- sm1 - Lab mate (home: %s; scope: lab; projects: none; added 2026-10-20)\n' "$MATE" > "$LAB/data/secondmates.md"
. bin/fm-backend.sh; fm_backend_source herdr || exit 1
C=$(fm_backend_herdr_container_ensure "$MATE") || { echo container failed; exit 1; }
CONT=${C%%$'\t'*}; SEED=${C#*$'\t'}; WS=${CONT#*:}
read -r TAB PANE <<<"$(fm_backend_herdr_create_task "$CONT" fm-sm1 "$MATE" "$SEED")"
echo "== created tab=$TAB pane=$PANE"
printf 'window=%s:%s\nendpoint_task_id=sm1\nworktree=%s\nproject=%s\nharness=claude\nkind=secondmate\nmode=secondmate\nyolo=off\nmodel=default\neffort=default\nhome=%s\nbackend=herdr\nherdr_session=%s\nherdr_workspace_id=%s\nherdr_tab_id=%s\nherdr_pane_id=%s\n' \
  "$SESSION" "$PANE" "$MATE" "$MATE" "$MATE" "$SESSION" "$WS" "$TAB" "$PANE" > "$LAB/state/sm1.meta"
echo "-- agent state while pane exists (no agent): $(fm_backend_agent_state herdr "$SESSION:$PANE")"
bin/fm-herdr-lab.sh run "$SESSION" pane close "$PANE" >/dev/null 2>&1; echo "-- closed pane rc=$?"
echo "-- agent state after close: $(fm_backend_agent_state herdr "$SESSION:$PANE")"
FM_HOME="$MATE" bin/fm-secondmate-report.sh done 0123456789abcdef 'ready to park - no conversation-only open work'
echo "-- parent status:"; cat "$LAB/state/sm1.status"
park() { env -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
  FM_HOME="$LAB" HERDR_SESSION="$SESSION" FM_SECONDMATE_PERSIST_WAIT=3 FM_SECONDMATE_PERSIST_POLL=1 bin/fm-secondmate-park.sh "$@" 2>&1; }
echo "\$ fm-secondmate-park.sh sm1 park"; park sm1 park; echo "rc=$?"
echo "-- park record:"; cat "$LAB/state/.secondmate-park-sm1" 2>&1
echo "-- inbox (must be absent): $(ls "$LAB/state/sm1.inbox" 2>&1 | sed 's/.*: //')"
for mode in full poll; do
  FM_HOME="$LAB" bash -c '. bin/fm-secondmate-liveness-lib.sh; fm_secondmate_liveness_probe "$1/state/sm1.meta" sm1 "$2"; printf "liveness %s: status=%s state=%s\n" "$2" "$FM_SM_LIVE_STATUS" "$FM_SM_LIVE_STATE"' _ "$LAB" "$mode"
done
