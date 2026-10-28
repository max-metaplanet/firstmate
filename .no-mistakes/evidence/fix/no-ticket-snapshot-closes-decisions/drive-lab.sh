#!/usr/bin/env bash
# Live lab driver: real fm-fleet-view.sh/fm-fleet-snapshot.sh against a disposable FM_HOME.
set -u
WT=${WT:?}; BIN=${BIN:-$WT/bin}; LAB=${LAB:?}
. "$WT/tests/lib.sh" 2>/dev/null || true
meta() { local f=$1; shift; : > "$f"; for kv in "$@"; do printf '%s\n' "$kv" >> "$f"; done; }
H=$LAB
mkdir -p "$H/projects/done-ship" "$H/projects/failed-ship" "$H/projects/busy-ship" "$H/projects/scout-wt" "$H/data/done-scout"
meta "$H/state/done-ship.meta" "window=firstmate:fm-done-ship" "worktree=$H/projects/done-ship" kind=ship harness=claude mode=ship project=alpha
meta "$H/state/failed-ship.meta" "window=firstmate:fm-failed-ship" "worktree=$H/projects/failed-ship" kind=ship harness=claude mode=ship project=alpha
meta "$H/state/busy-ship.meta" "window=firstmate:fm-busy-ship" "worktree=$H/projects/busy-ship" kind=ship harness=claude mode=ship project=alpha
meta "$H/state/done-scout.meta" "window=firstmate:fm-done-scout" "worktree=$H/projects/scout-wt" kind=scout harness=claude mode=scout project=alpha
printf '# Scout report\n' > "$H/data/done-scout/report.md"
for id in done-ship failed-ship done-scout; do
  g=$("$BIN/fm-busy-event.sh" arm "$H/state" $id); "$BIN/fm-busy-event.sh" apply "$H/state" $id idle --gen "$g" --source claude-hook --event stop
done
g=$("$BIN/fm-busy-event.sh" arm "$H/state" busy-ship); "$BIN/fm-busy-event.sh" apply "$H/state" busy-ship busy --gen "$g" --source claude-hook --event user-prompt-submit
printf 'needs-decision [key=route]: pick REST or gRPC\ndone: PR opened\n' > "$H/state/done-ship.status"
printf 'blocked [key=creds]: need staging creds\nfailed: tests could not run\n' > "$H/state/failed-ship.status"
printf 'needs-decision [key=api]: choose an API shape\n' > "$H/state/busy-ship.status"
printf 'needs-decision [key=scope]: widen scope?\ndone: report ready\n' > "$H/state/done-scout.status"
