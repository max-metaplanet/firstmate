#!/usr/bin/env bash
# Live: drive bin/fm-fleet-snapshot.sh (fix vs base) against a disposable lab FM_HOME.
set -u
ROOT=$1 BASE_SHA=$2
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
BASE=$(mktemp -d "${TMPDIR:-/tmp}/fm-base.XXXXXX")
trap 'tmux kill-server 2>/dev/null; rm -rf "$LAB" "$BASE"' EXIT
"$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null
mkdir -p "$LAB/tmux"
git -C "$ROOT" archive "$BASE_SHA" bin | tar -x -C "$BASE"
export TMUX_TMPDIR="$LAB/tmux"; unset TMUX
EVENT=idle
mk() { # id kind status-lines...
  local id=$1 kind=$2; shift 2
  mkdir -p "$LAB/projects/$id"
  printf '%s\n' "window=firstmate:fm-$id" "worktree=$LAB/projects/$id" "kind=$kind" harness=claude > "$LAB/state/$id.meta"
  printf '%s\n' "$@" > "$LAB/state/$id.status"
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$LAB/state" "$id")
  "$ROOT/bin/fm-busy-event.sh" apply "$LAB/state" "$id" "$EVENT" --gen "$gen" --source claude-hook --event stop
  if tmux has-session -t firstmate 2>/dev/null; then tmux new-window -d -t firstmate -n "fm-$id" sleep 600
  else tmux new-session -d -s firstmate -n "fm-$id" sleep 600; fi
}
mk ship-done ship 'needs-decision [key=choice]: choose a route' 'done: PR opened'
mk ship-failed ship 'needs-decision [key=choice]: choose a route' 'failed: tests broke'
mk scout-done scout 'blocked [key=access]: need repo access' 'done: report written'
mkdir -p "$LAB/data/scout-done"; echo '# report' > "$LAB/data/scout-done/report.md"
EVENT=busy
mk ship-busy ship 'needs-decision [key=api]: choose an API shape'
mk scout-busy-done scout 'needs-decision [key=q1]: which repo?' 'done: report written'
mkdir -p "$LAB/data/scout-busy-done"; echo '# report' > "$LAB/data/scout-busy-done/report.md"
EVENT=idle
# run-step: no-mistakes CLI output stubbed at the external boundary (completed run)
mk ship-runstep ship 'needs-decision [key=choice]: choose a route' 'done: PR opened'
echo mode=no-mistakes >> "$LAB/state/ship-runstep.meta"
git -C "$LAB/projects/ship-runstep" init -q -b fm/runstep && git -C "$LAB/projects/ship-runstep" -c user.name=t -c user.email=t@t commit -q --allow-empty -m i
HEAD_SHA=$(git -C "$LAB/projects/ship-runstep" rev-parse HEAD)
mkdir -p "$LAB/fakebin"; printf '#!/usr/bin/env bash\ncat <<EOT\nrun:\n  id: "01RUN"\n  branch: fm/runstep\n  status: completed\n  head: "%s"\n  steps[1]{step,status,findings,duration_ms}:\n    review,completed,0,0\nEOT\n' "$HEAD_SHA" > "$LAB/fakebin/no-mistakes"; chmod +x "$LAB/fakebin/no-mistakes"
export PATH="$LAB/fakebin:$PATH"
mk ship-answered ship 'needs-decision [key=choice]: choose a route' 'done: PR opened' 'resolved [key=choice]: route A'
view() { FM_HOME="$LAB" "$1/bin/fm-fleet-snapshot.sh" --json | jq -c '.tasks[] | {id, state:.current_state.state, pending:.hints.pending_decision, blocked:.hints.blocked_event, src:.current_state.source, keys:[.hints.open_decisions[].key], report:.paths.report.present}'; }
echo "== BASE ($BASE_SHA) fleet snapshot =="; view "$BASE"
echo "== FIX (HEAD) fleet snapshot =="; view "$ROOT"
echo "== authoritative fold (fm-classify-lib status_open_decisions) =="
for f in "$LAB"/state/*.status; do
  keys=$(bash -c '. "$1/bin/fm-classify-lib.sh"; status_open_decisions "$2"' _ "$ROOT" "$f" | cut -f1 | paste -sd, -)
  echo "$(basename "$f" .status): [$keys]"
done
echo "== adversarial: answer ship-done then re-snapshot =="
printf 'resolved [key=choice]: route B\n' >> "$LAB/state/ship-done.status"
view "$ROOT" | grep ship-done
