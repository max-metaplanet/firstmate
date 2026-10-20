#!/usr/bin/env bash
# Live lab: real fm-secondmate-park.sh against a real private tmux server and a
# disposable marked lab FM_HOME. A bare zsh in the mate window = stopped agent.
set -u
WT=${WT:?}
cd "$WT"
LAB=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")" && pwd -P); bin/fm-lab-home.sh create "$LAB" >/dev/null
TD=$(bin/fm-lab-home.sh tmux-dir "$LAB")
MATES=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/fm-lab-mates.XXXXXX")" && pwd -P)
export TMUX_TMPDIR="$TD"; unset TMUX
T() { tmux "$@"; }
cleanup() { tmux kill-server 2>/dev/null; bin/fm-lab-home.sh teardown "$LAB"; rm -rf "$LAB" "$MATES"; }
trap cleanup EXIT
printf 'claude\n' > "$LAB/config/secondmate-harness"
T new-session -d -s fmses -n placeholder -x 160 -y 40 zsh -f
: > "$LAB/data/secondmates.md"
mkmate() {  # <id>
  local id=$1 h="$MATES/$1-home"
  "$WT/bin/fm-lab-home.sh" create "$h" >/dev/null; git init -q "$h"; git -C "$h" -c user.name=t -c user.email=t@e commit -q --allow-empty -m init
  mkdir -p "$h/state" "$h/data" "$h/config" "$LAB/data/$id"
  printf '%s\n' "$id" > "$h/.fm-secondmate-home"
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$LAB" > "$h/.fm-secondmate-parent"
  printf '# charter\n' > "$LAB/data/$id/brief.md"
  printf -- '- %s - Lab mate (home: %s; scope: lab; projects: none; added 2026-10-20)\n' "$id" "$h" >> "$LAB/data/secondmates.md"
  printf 'window=fmses:fm-%s\nendpoint_task_id=%s\nworktree=%s\nproject=%s\nharness=claude\nkind=secondmate\nmode=secondmate\nyolo=off\nmodel=default\neffort=default\nhome=%s\nbackend=tmux\n' \
    "$id" "$id" "$h" "$h" "$h" > "$LAB/state/$id.meta"
  T new-window -d -t fmses -n "fm-$id" -c "$h" zsh -f; sleep 1
}
park() { env -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
  FM_HOME="$LAB" FM_SECONDMATE_PERSIST_WAIT=3 FM_SECONDMATE_PERSIST_POLL=1 bin/fm-secondmate-park.sh "$@" 2>&1; }
show() { echo "\$ $*"; }

echo "== tmux server: $(T -V); NO_MISTAKES_GATE=${NO_MISTAKES_GATE+set}"
echo "== S0: --help names the readiness phrase"
bin/fm-secondmate-park.sh --help | tail -n 1

echo; echo "== S1: stopped mate (bare zsh in its window) + helper-written readiness + home notice -> park"
mkmate jevlab
FM_HOME="$MATES/jevlab-home" bin/fm-secondmate-report.sh done 0123456789abcdef 'ready to park - no conversation-only open work'; echo "report rc=$?"
printf 'spawn notice: auto-relaunch failed; deferred\n' >> "$LAB/state/jevlab.status"
echo "-- parent status file:"; cat "$LAB/state/jevlab.status"
echo "-- pane command before: $(T display-message -p -t fmses:fm-jevlab '#{pane_current_command}')"
T capture-pane -p -t fmses:fm-jevlab > "$LAB/pane-before"
show fm-secondmate-park.sh jevlab park; park jevlab park; echo "rc=$?"
echo "-- park record:"; cat "$LAB/state/.secondmate-park-jevlab" 2>&1
echo "-- inbox (must be absent): $(ls "$LAB/state/jevlab.inbox" 2>&1)"
echo "-- pending-replies (must be absent): $(ls "$LAB/state/pending-replies" 2>&1)"
T capture-pane -p -t fmses:fm-jevlab > "$LAB/pane-after" 2>&1
if T list-windows -t fmses -F '#W' | grep -qx fm-jevlab; then
  if cmp -s "$LAB/pane-before" "$LAB/pane-after"; then echo "-- pane content unchanged: no keystrokes sent"; else echo "-- PANE CHANGED:"; cat "$LAB/pane-after"; fi
else echo "-- window fm-jevlab no longer present (fm-control exit cleaned it)"; fi
echo "-- parent status after park:"; tail -n 3 "$LAB/state/jevlab.status"

echo; echo "== S2: liveness probe (full + poll) on parked mate against real tmux"
for mode in full poll; do
  FM_HOME="$LAB" bash -c '. bin/fm-secondmate-liveness-lib.sh; fm_secondmate_liveness_probe "$1/state/jevlab.meta" jevlab "$2"; printf "%s: status=%s state=%s\n" "$2" "$FM_SM_LIVE_STATUS" "$FM_SM_LIVE_STATE"' _ "$LAB" "$mode"
done
echo "== S2b: two real bootstrap network sweeps (FM_BOOTSTRAP_NETWORK=only)"
for cycle in 1 2; do
  out=$(env -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
    FM_HOME="$LAB" FM_BACKEND=tmux FM_BOOTSTRAP_NETWORK=only bin/fm-bootstrap.sh 2>&1)
  echo "cycle $cycle rc=$? SECONDMATE_LIVENESS lines: $(printf '%s\n' "$out" | grep -c 'SECONDMATE_LIVENESS' || true)"
  printf '%s\n' "$out" | grep -i 'jevlab\|liveness\|relaunch' | sed 's/^/   /'
done
echo "-- windows after sweeps: $(T list-windows -t fmses -F '#W' | tr '\n' ' ')"
echo "-- relaunch ledger (must be absent): $(ls "$LAB/state/.secondmate-relaunch-jevlab" 2>&1)"

echo; echo "== S3: adversarial refusals on stopped mates (each must refuse with no record, no inbox, no keystrokes)"
case_refuse() {  # <id> <label>
  local id=$1
  T capture-pane -p -t "fmses:fm-$id" > "$LAB/b-$id" 2>/dev/null
  show fm-secondmate-park.sh "$id" park "($2)"; park "$id" park; echo "rc=$?"
  echo "   record: $(ls "$LAB/state/.secondmate-park-$id" 2>&1 | sed 's/.*: //')"
  echo "   inbox: $(ls "$LAB/state/$id.inbox" 2>&1 | sed 's/.*: //')"
  if T capture-pane -p -t "fmses:fm-$id" > "$LAB/a-$id" 2>/dev/null; then cmp -s "$LAB/b-$id" "$LAB/a-$id" && echo "   pane unchanged" || echo "   PANE CHANGED"; fi
}
mkmate stale; printf 'done: ready to park - no conversation-only open work\nworking: picked up new conversation-only work\n' > "$LAB/state/stale.status"; case_refuse stale 'stale: newer status after readiness'
mkmate negated; printf 'blocked: not ready to park - no conversation-only open work\n' > "$LAB/state/negated.status"; case_refuse negated 'negated phrase'
mkmate child; printf 'done: ready to park - no conversation-only open work\n' > "$LAB/state/child.status"; printf 'kind=ship\n' > "$MATES/child-home/state/task1.meta"; case_refuse child 'child record present'
mkmate inflight; printf 'done: ready to park - no conversation-only open work\n' > "$LAB/state/inflight.status"; printf '# Backlog\n\n## In flight\n\n- [ ] t1 - Work\n' > "$MATES/inflight-home/data/backlog.md"; case_refuse inflight 'in-flight backlog'
mkmate nostatus; case_refuse nostatus 'no status file'
mkmate gone; printf 'done: ready to park - no conversation-only open work\n' > "$LAB/state/gone.status"; T kill-window -t fmses:fm-gone; case_refuse gone 'tmux window missing: absence unprovable on tmux'

echo; echo "== S4: held backlog items do not block a stopped park (F3 decision)"
mkmate held; printf 'done: ready to park - no conversation-only open work\n' > "$LAB/state/held.status"; printf '# Backlog\n\n## Held\n\n- [ ] h1 - Captain decision pending\n' > "$MATES/held-home/data/backlog.md"
park held park; echo "rc=$?"; grep '^phase=' "$LAB/state/.secondmate-park-held" 2>&1
