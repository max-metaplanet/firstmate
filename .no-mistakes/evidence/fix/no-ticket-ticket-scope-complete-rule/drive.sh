#!/usr/bin/env bash
# Live CLI scenarios for the ticket-scope-complete-rule change, driven in a disposable lab home.
set -u
R=~/.no-mistakes/worktrees/61c6dd39b831/01M5YHR5QDVE79B8MGYQ104CCD
LAB=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")" && pwd -P)
trap 'rm -rf "$LAB"' EXIT
"$R/bin/fm-lab-home.sh" create "$LAB" >/dev/null
mkdir -p "$LAB/fakebin" "$LAB/projects/proj"
git -C "$LAB/projects/proj" init -q; git -c user.name=t -c user.email=t@e -C "$LAB/projects/proj" commit -q --allow-empty -m init
printf '#!/bin/sh\necho "fake-tmux reached: $*" >> %s/tmux.log\nexit 1\n' "$LAB" > "$LAB/fakebin/tmux"; chmod +x "$LAB/fakebin/tmux"
E() { env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE='' FM_HOME="$LAB" FM_STATE_OVERRIDE="$LAB/state" FM_CONFIG_OVERRIDE="$LAB/config" FM_SPAWN_NO_GUARD=1 FM_BACKEND=tmux PATH="$LAB/fakebin:$PATH" "$@" 2>&1; }
hdr() { printf '\n===== %s =====\n' "$*"; }
fill() { python3 - "$1" <<'PY'
import sys;p=sys.argv[1];t=open(p).read();t=t.replace('{TASK}','Add a widget.').replace('{FIRSTMATE_SPEC}','Widget returns 1.');open(p,'w').write(t)
PY
}

hdr "S1 brief with --ticket ENG-123: emitted ticket instructions"
E "$R/bin/fm-brief.sh" t1 proj --mode no-mistakes --ticket ENG-123 --commit-type feat >/dev/null; echo "exit=$?"; fill "$LAB/data/t1/brief.md"
grep -nE 'ticket-scope|synthetic verification|Declare complete|post-merge|Otherwise declare|Ship branch|^Ticket:' "$LAB/data/t1/brief.md"

hdr "S2 ship spawn with no ticket flag (branch-prefix only) is refused"
E "$R/bin/fm-brief.sh" t2 proj --mode no-mistakes --ticket no-ticket --commit-type chore >/dev/null; fill "$LAB/data/t2/brief.md"
out=$(E "$R/bin/fm-spawn.sh" t2 "$LAB/projects/proj" claude --mode no-mistakes --yolo off --branch-prefix fm/); echo "exit=$?"; echo "$out" | head -3
ls "$LAB/state/t2.meta" 2>/dev/null && echo "META LEFT BEHIND" || echo "no meta written"
hdr "S2b ship spawn with no ticket flag at all is refused"
out=$(E "$R/bin/fm-spawn.sh" t2 "$LAB/projects/proj" claude --mode no-mistakes --yolo off); echo "exit=$?"; echo "$out" | head -3

hdr "S3 ship spawn with --ticket no-ticket clears ticket validation (stops only at refusing fake tmux)"
out=$(E "$R/bin/fm-spawn.sh" t2 "$LAB/projects/proj" claude --mode no-mistakes --yolo off --ticket no-ticket --commit-type chore); echo "exit=$?"; echo "$out" | tail -4
echo "--- fake tmux log (reached backend after ticket validation):"; cat "$LAB/tmux.log" 2>/dev/null | head -2; : > "$LAB/tmux.log"
hdr "S3b ship spawn with --ticket ENG-123 clears ticket validation"
out=$(E "$R/bin/fm-spawn.sh" t1 "$LAB/projects/proj" claude --mode no-mistakes --yolo off --ticket ENG-123 --commit-type feat); echo "exit=$?"; echo "$out" | tail -4
echo "--- fake tmux log:"; cat "$LAB/tmux.log" 2>/dev/null | head -2; : > "$LAB/tmux.log"
hdr "S3c ticket + branch-prefix combined is refused"
out=$(E "$R/bin/fm-spawn.sh" t1 "$LAB/projects/proj" claude --mode no-mistakes --yolo off --ticket ENG-123 --commit-type feat --branch-prefix fm/); echo "exit=$?"; echo "$out" | head -2

for b in b1 b2; do E "$R/bin/fm-brief.sh" $b proj --mode no-mistakes --ticket no-ticket --commit-type chore >/dev/null; fill "$LAB/data/$b/brief.md"; done
hdr "S4 batch: real ticket refused, no-ticket shared"
out=$(E "$R/bin/fm-spawn.sh" b1=projects/proj b2=projects/proj --mode no-mistakes --yolo off --ticket ENG-9 --commit-type feat); echo "exit=$?"; echo "$out" | head -2
out=$(E "$R/bin/fm-spawn.sh" b1=projects/proj b2=projects/proj --mode no-mistakes --yolo off --ticket no-ticket --commit-type chore); echo "exit=$?"; echo "$out" | grep -v '^$' | tail -8

echo "--- fake tmux log (batch pairs reached backend):"; cut -c1-120 "$LAB/tmux.log" 2>/dev/null | head -4
hdr "S5 scout promotion: refused without --ticket, accepted with ENG and no-ticket"
for id in s1 s2; do
  E "$R/bin/fm-brief.sh" $id proj --scout >/dev/null; fill "$LAB/data/$id/brief.md"
  printf 'kind=scout\nproject=%s\n' "$LAB/projects/proj" > "$LAB/state/$id.meta"
done
out=$(E "$R/bin/fm-promote.sh" s1 --mode no-mistakes --yolo off --branch-prefix fm/); echo "branch-prefix-only exit=$?"; echo "$out" | head -2; grep '^kind=' "$LAB/state/s1.meta"
out=$(E "$R/bin/fm-promote.sh" s1 --mode no-mistakes --yolo off --ticket ENG-77 --commit-type fix); echo "ENG exit=$?"; grep -E '^(kind|ticket|commit_type|branch)=' "$LAB/state/s1.meta"
out=$(E "$R/bin/fm-promote.sh" s2 --mode direct-PR --yolo on --ticket no-ticket --commit-type chore); echo "no-ticket exit=$?"; grep -E '^(kind|ticket|commit_type|branch)=' "$LAB/state/s2.meta"
grep -nE 'Declare complete|synthetic' "$LAB/data/s1/ship-instructions.md" 2>/dev/null | head -3

hdr "S6 ticket sync: pr-merged final complete -> done; partial -> review"
printf '#!/bin/sh\nprintf "%%s|" "$@" >> %s/hook.log; echo >> %s/hook.log\n' "$LAB" "$LAB" > "$LAB/hook.sh"; chmod +x "$LAB/hook.sh"
echo "$LAB/hook.sh" > "$LAB/config/ticket-sync-hook"
for scope in complete partial; do
  ev=$(jq -nc --arg s $scope '{schema:"firstmate.task-event",version:1,event:"pr-merged",merge:"final",ticket:"ENG-77",ticket_scope:$s,pr_url:"https://example.invalid/pr/1",summary:"merged"}')
  E "$R/bin/fm-ticket-sync.sh" "$ev"; echo "$scope exit=$?"
done
cat "$LAB/hook.log"
