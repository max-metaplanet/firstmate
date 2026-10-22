#!/usr/bin/env bash
# Drives the real fm-contributions.sh observer and fm-worker-park.sh owner
# through the reported loop: parked worker, permanently red lane, resume,
# re-park, red lane observed again. Only the external boundaries are stubbed:
# gh (forge), tmux, fm-guard, and fm-control (the worker relaunch/exit).
# Usage: park-red-loop-driver.sh <source-tree-with-bin>
set -u
SRC=$1
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-park-lab.XXXXXX")
trap 'rm -rf "$LAB"' EXIT
HEAD_A=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
HEAD_B=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
NOW=2026-09-16T08:00:00Z
URL=https://github.com/o/r/pull/8
H=$LAB/home
mkdir -p "$LAB/bin" "$H/state" "$H/data/delivery" "$H/config" "$H/forge" "$H/fakebin" "$H/root/bin"
for s in "$SRC"/bin/*; do ln -s "$s" "$LAB/bin/${s##*/}"; done
rm "$LAB/bin/fm-control.sh" "$LAB/bin/fm-busy-lib.sh"
cat > "$LAB/bin/fm-control.sh" <<'SH'
#!/usr/bin/env bash
printf '%s %s\n' "$1" "$2" >> "$FM_HOME/control.log"
[ "$2" = exit ] && exit 0
printf 'spawn_gen=relaunched-%s\n' "$(wc -l < "$FM_HOME/control.log" | tr -d ' ')" >> "$FM_HOME/state/$1.meta"
SH
printf 'fm_busy_classify() { printf "idle hook\\n"; }\n' > "$LAB/bin/fm-busy-lib.sh"
chmod +x "$LAB/bin/fm-control.sh"
printf '#!/bin/sh\nexit 1\n' > "$H/fakebin/tmux"
printf '#!/bin/sh\nexit 0\n' > "$H/fakebin/no-mistakes"
printf '#!/bin/sh\nexit 0\n' > "$H/root/bin/fm-guard.sh"
chmod +x "$H/fakebin/"* "$H/root/bin/fm-guard.sh"
git init -q "$H/wt" && git -C "$H/wt" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
printf -- '- [ ] delivery - Contribution delivery %s (repo: sample) (kind: ship)\n' "$URL" > "$H/data/backlog.md"
sed -i '' '1i\
# Backlog\
\
## Queued
' "$H/data/backlog.md"
jq -n --arg url "$URL" --arg head "$HEAD_A" --arg at "$NOW" '
  {schema:"fm-contributions.v1",task:"delivery",records:[{url:$url,kind:"pr",checked_at:$at,error:null,
    pending:[],seen:[],verdict:null,observation:{head:$head,state:"open",draft:false,mergeable:"mergeable",
    review_decision:"APPROVED",can_merge:false,
    checks:[{name:"windows / integration",id:1,status:"completed",conclusion:"success",started_at:$at}],
    reviews:[],events:[]}}]}' > "$H/data/delivery/contributions.json"
printf 'kind=ship\nbackend=tmux\nwindow=test:fm-delivery\nspawn_gen=original\nyolo=off\nmode=direct-PR\npr=%s\nworktree=%s/wt\nharness=codex\n' "$URL" "$H" > "$H/state/delivery.meta"
chmod 600 "$H/state/delivery.meta"
printf '%s\n' "$HEAD_A" > "$H/forge/head"
printf 1 > "$H/forge/id"
for f in comments reviews inline labels events; do printf '[]\n' > "$H/forge/$f.json"; done
cat > "$H/fakebin/gh" <<'SH'
#!/usr/bin/env bash
set -eu
case "$*" in
  'pr view '*headRefOid,reviewDecision*) jq -n --arg head "$(cat "$FORGE/head")" '{headRefOid:$head,reviewDecision:"APPROVED"}' ;;
  'pr view '*headRefOid*) cat "$FORGE/head" ;;
  'pr view '*state*) printf 'OPEN\n' ;;
  'api repos/o/r/pulls/8') jq -n --arg head "$(cat "$FORGE/head")" '{state:"open",user:{login:"author"},head:{sha:$head},draft:false,mergeable:true,merged_at:null}' ;;
  'api repos/o/r/issues/'*'/events?'*) jq -s . "$FORGE/events.json" ;;
  'api repos/o/r/issues/'*'/comments?'*) jq -s . "$FORGE/comments.json" ;;
  'api repos/o/r/pulls/'*'/reviews?'*) jq -s . "$FORGE/reviews.json" ;;
  'api repos/o/r/pulls/'*'/comments?'*) jq -s . "$FORGE/inline.json" ;;
  'api repos/o/r/commits/'*'/check-runs?'*)
    jq -n --arg c "$(cat "$FORGE/conclusion" 2>/dev/null || printf success)" --argjson id "$(cat "$FORGE/id")" \
      --argjson extra "$(cat "$FORGE/extra.json" 2>/dev/null || printf '[]')" '
      [{check_runs:([{name:"windows / integration",id:$id,status:"completed",conclusion:$c,started_at:"2026-09-16T08:00:00Z"}] + $extra)}]' ;;
  'api repos/o/r/commits/'*'/statuses?'*) printf '[[]]\n' ;;
  'api repos/o/r') printf '{"permissions":{"push":false}}\n' ;;
  *) printf 'unexpected gh call: %s\n' "$*" >&2; exit 1 ;;
esac
SH
chmod +x "$H/fakebin/gh"
run() { PATH="$H/fakebin:$PATH" FORGE="$H/forge" FM_HOME="$H" FM_ROOT_OVERRIDE="$H/root" FM_STATE_OVERRIDE="$H/state" \
  FM_DATA_OVERRIDE="$H/data" FM_CONFIG_OVERRIDE="$H/config" FM_CONTRIBUTIONS_NOW="$NOW" "$@"; }
phase() { sed -n 's/^phase=//p' "$H/state/delivery.park"; }
failing() { sed -n 's/^failing_checks=//p' "$H/state/delivery.park"; }
relaunches() { local n; n=$(grep -c relaunch "$H/control.log" 2>/dev/null); printf %s "${n:-0}"; }
poll() { run "$LAB/bin/fm-contributions.sh" poll >/dev/null 2>"$LAB/poll.err" || { echo "poll rc=$?"; cat "$LAB/poll.err"; }; }
show() { printf '%-58s phase=%-7s relaunches=%s failing_checks=%s\n' "$1" "$(phase)" "$(relaunches)" "$(failing)"; }
resume_and_repark() { # watcher tick relaunches; worker rechecks, reports done, parks again
  run "$LAB/bin/fm-worker-park.sh" tick >/dev/null 2>&1
  show '  watcher tick (resume)'
  printf 'done: PR %s checks green (rechecked %s; red lane is unrelated)\n' "$URL" "$(relaunches)" >> "$H/state/delivery.status"
  run "$LAB/bin/fm-worker-park.sh" auto delivery >/dev/null 2>&1
  show '  worker finds nothing new, parks again'
}
echo "== source: $SRC"
printf 'done: PR %s checks green\n' "$URL" > "$H/state/delivery.status"
run "$LAB/bin/fm-worker-park.sh" auto delivery >/dev/null 2>&1
show 'S0 worker parks on a green PR'
printf failure > "$H/forge/conclusion"
poll; show 'S1 permanent windows lane goes red -> poll'
resume_and_repark
for i in 2 3 4; do
  poll; show "S2 same red lane, same head, observer cycle $i"
  [ "$(phase)" = parked ] || resume_and_repark
done
printf 7 > "$H/forge/id"
poll; show 'S3 lane rerun (new id), still red on same head'
[ "$(phase)" = parked ] || resume_and_repark
printf '[{"name":"lint","id":9,"status":"completed","conclusion":"failure","started_at":"2026-09-16T08:00:01Z"}]\n' > "$H/forge/extra.json"
poll; show 'S4 a second lane (lint) newly fails'
[ "$(phase)" = parked ] || resume_and_repark
printf '%s\n' "$HEAD_B" > "$H/forge/head"
poll; show 'S5 worker pushes new head, same lanes red'
[ "$(phase)" = parked ] || resume_and_repark
printf 'done: PR %s checks green (S6)\n' "$URL" >> "$H/state/delivery.status"
run "$LAB/bin/fm-worker-park.sh" request delivery 'merge word answered' >/dev/null 2>&1
show 'S6 unrelated resume request (no failing set)'
[ "$(phase)" = parked ] || resume_and_repark
out=$(run "$LAB/bin/fm-worker-park.sh" request delivery 'checks failed' $'{"a"}\n{"b"}' 2>&1); rc=$?
show "S7 multi-line failing set via CLI (rc=$rc: $out)"
echo "-- final park record:"; cat "$H/state/delivery.park"
echo "-- total relaunches: $(relaunches)"
