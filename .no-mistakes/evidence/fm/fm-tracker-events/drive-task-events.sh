#!/usr/bin/env bash
# Live scenario driver: runs the real firstmate event producers against a
# disposable FM_HOME with a recording consumer. Expectations come from the
# user intent / docs/configuration.md contract, not from the emitter code.
set -u
ROOT=$1
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-ev-lab.XXXXXX")
trap 'rm -rf "$LAB"' EXIT
FAILS=0
ok()   { printf 'PASS  %s\n' "$1"; }
bad()  { printf 'FAIL  %s\n' "$1"; FAILS=$((FAILS+1)); }
home() { # <name> -> home with recording consumer
  local h="$LAB/$1"; mkdir -p "$h/state" "$h/config" "$h/data"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$1" >> "%s/events"\n' "$h" > "$h/consumer"
  chmod +x "$h/consumer"; printf '%s\n' "$h/consumer" > "$h/config/task-event-hook"; printf '%s\n' "$h"; }
emit() { local h=$1; shift; FM_HOME=$h FM_STATE_OVERRIDE=$h/state FM_CONFIG_OVERRIDE=$h/config "$ROOT/bin/fm-task-event.sh" "$@"; }
waitn() { local f=$1 n=$2 i=0; while [ $i -lt 200 ]; do [ -f "$f" ] && [ "$(wc -l < "$f")" -ge "$n" ] && return 0; sleep 0.05; i=$((i+1)); done; return 1; }
show() { echo "    --- consumer received ($1) ---"; jq -c '{sequence,event,task_id,ticket,pr_url,merge,key,summary}' "$1" | sed 's/^/    /'; }

echo "== S1 full lifecycle through the public CLI: ordered, tracker-neutral JSON"
h=$(home s1)
printf 'ticket=ENG-123\n' > "$h/state/t1.meta"
printf 'working: wiring the export endpoint\n' > "$h/state/t1.status"
emit "$h" t1 started
printf 'blocked [key=creds]: staging credential expired\n' >> "$h/state/t1.status"
emit "$h" t1 blocked --key creds
emit "$h" t1 waiting --key captain-hold-t1-1 --summary 'Pick v1 or v2 schema?'
emit "$h" t1 decision-answered --key captain-hold-t1-1
emit "$h" t1 resumed --key captain-hold-t1-1
printf 'done: PR opened, all checks green\n' >> "$h/state/t1.status"
emit "$h" t1 pr-opened --pr https://github.com/acme/app/pull/11
emit "$h" t1 pr-merged --pr https://github.com/acme/app/pull/11
emit "$h" t1 finished --pr https://github.com/acme/app/pull/11
waitn "$h/events" 8 || bad "S1 not all 8 events delivered"
show "$h/events"
jq -se '
  map(.event) == ["started","blocked","waiting","decision-answered","resumed","pr-opened","pr-merged","finished"] and
  (map(.sequence) | . == sort and length == (unique|length)) and
  all(.[]; .schema=="firstmate.task-event" and .version==1 and .task_id=="t1" and .ticket=="ENG-123" and (.home|length>0)) and
  .[0].summary=="wiring the export endpoint" and .[1].summary=="staging credential expired" and .[1].key=="creds" and
  .[2].summary=="Pick v1 or v2 schema?" and
  .[5].pr_url=="https://github.com/acme/app/pull/11" and .[5].summary=="PR opened, all checks green" and
  .[6].merge=="final" and ([.[0,1,2,3,4,5,7].merge]|all(.==null))' "$h/events" >/dev/null \
  && ok "S1 every lifecycle event delivered in order with task id, ticket, PR url, worker summary" || bad "S1 payload contract"
grep -Rqi clickup "$h/events" && bad "S1 payload mentions ClickUp" || ok "S1 payload is tracker-neutral (no ClickUp knowledge)"

echo "== S2 keyed blocker fold (real fm-classify-lib status reader) emits blocked/waiting/resumed"
h=$(home s2); printf 'ticket=ENG-200\n' > "$h/state/t2.meta"
fold() { FM_HOME=$1 FM_STATE_OVERRIDE=$1/state FM_CONFIG_OVERRIDE=$1/config bash -c '. "$1"; status_open_decisions_incremental "$2"' _ "$ROOT/bin/fm-classify-lib.sh" "$1/state/t2.status" >/dev/null; }
printf 'working: building\nblocked [key=ci]: CI runner offline\nneeds-decision [key=api]: keep old endpoint?\n' > "$h/state/t2.status"
fold "$h"; waitn "$h/events" 2
printf 'resolved [key=ci]: runner back\n' >> "$h/state/t2.status"; fold "$h"; sleep 0.4
n_mid=$(wc -l < "$h/events" | tr -d ' ')
printf 'resolved [key=api]: keep it\n' >> "$h/state/t2.status"; fold "$h"; waitn "$h/events" 3
fold "$h"; sleep 0.4
show "$h/events"
jq -se 'map(.event)==["blocked","waiting","resumed"] and .[0].summary=="CI runner offline" and .[1].summary=="keep old endpoint?" and all(.[]; .ticket=="ENG-200")' "$h/events" >/dev/null && [ "$n_mid" = 2 ] \
  && ok "S2 any keyed blocker emits blocked/waiting; resumed only after the last blocker clears; repeat fold silent" || bad "S2 fold events (mid=$n_mid)"

echo "== S3 partial vs final merge across two tasks sharing a ticket (real fm_merge_outcome_report)"
h=$(home s3)
mk() { fm_write_meta_line() { :; }; printf 'ticket=ENG-300\npr=%s\nkind=ship\nmode=no-mistakes\nwindow=firstmate:fm-%s\nworktree=%s/wt\n' "$3" "$2" "$1" > "$1/state/$2.meta"; }
mk "$h" a https://github.com/acme/app/pull/21; mk "$h" b https://github.com/acme/app/pull/22
emit "$h" a pr-opened --pr https://github.com/acme/app/pull/21
emit "$h" b pr-opened --pr https://github.com/acme/app/pull/22
waitn "$h/events" 2
merge() ( . "$ROOT/bin/fm-merge-outcome-lib.sh"; FM_CONFIG_OVERRIDE="$1/config" fm_merge_outcome_report "$1" "$1/state" "$2" "$3" poll >/dev/null 2>&1 )
merge "$h" a https://github.com/acme/app/pull/21; waitn "$h/events" 3
merge "$h" a https://github.com/acme/app/pull/21; sleep 0.4   # repeated poll must not re-emit
merge "$h" b https://github.com/acme/app/pull/22; waitn "$h/events" 4
show "$h/events"
jq -se '[.[]|select(.event=="pr-merged")|[.task_id,.merge]]==[["a","partial"],["b","final"]] and length==4' "$h/events" >/dev/null \
  && ok "S3 first merge partial, last merge final; repeated merge poll emits nothing" || bad "S3 merge completeness"

echo "== S4 adversarial: superseded PR and cancel of last open PR still reach final (R2-F2/F1)"
h=$(home s4); printf 'ticket=ENG-400\n' > "$h/state/a.meta"; printf 'ticket=ENG-400\n' > "$h/state/b.meta"
emit "$h" a pr-opened --pr https://x/pull/1
emit "$h" a pr-opened --pr https://x/pull/2      # replacement PR supersedes #1
emit "$h" b pr-opened --pr https://x/pull/3
emit "$h" a pr-merged --pr https://x/pull/2      # #3 still open -> partial
emit "$h" b cancelled                            # last open PR retired -> final
waitn "$h/events" 5; show "$h/events"
jq -se '[.[]|select(.event=="pr-merged" or .event=="cancelled")|.merge]==["partial","final"]' "$h/events" >/dev/null \
  && ok "S4 superseded PR ignored; cancelling the last open PR yields cancelled merge=final" || bad "S4"

echo "== S5 legacy compat: only config/ticket-sync-hook keeps tracker syncing via adapter"
h="$LAB/s5"; mkdir -p "$h/state" "$h/config"
printf '#!/usr/bin/env bash\njq -cn --args "\\$ARGS.positional" -- "$@" >> "%s/calls"\n' "$h" > "$h/legacy"; chmod +x "$h/legacy"
printf '%s\n' "$h/legacy" > "$h/config/ticket-sync-hook"
printf 'ticket=ENG-500\n' > "$h/state/a.meta"; printf 'ticket=ENG-500\n' > "$h/state/b.meta"
printf 'working: x\n' > "$h/state/a.status"
emit "$h" a started
emit "$h" a waiting --summary 'Need captain sign-off'
emit "$h" a pr-opened --pr https://x/pull/7
emit "$h" b pr-opened --pr https://x/pull/8
emit "$h" a pr-merged --pr https://x/pull/7
emit "$h" b cancelled
emit "$h" a finished
sleep 1.5
echo "    --- legacy hook argv ---"; sed 's/^/    /' "$h/calls"
echo "    --- task-events.log ---"; sed 's/^/    /' "$h/state/task-events.log"
expect='["ENG-500","start"]
["ENG-500","waiting","Need captain sign-off"]
["ENG-500","review","https://x/pull/7"]
["ENG-500","review","https://x/pull/8"]
["ENG-500","done"]'
[ "$(cat "$h/calls")" = "$expect" ] && ok "S5 legacy hook gets start/waiting/review/done; partial merge does not send done; cancel-final sends done" || bad "S5 legacy mapping"
[ "$(grep -c compatibility "$h/state/task-events.log")" = 1 ] && ok "S5 compatibility path logged exactly once naming config/task-event-hook" || bad "S5 compat log"

echo "== S6 consumer failure/hang never blocks the producer; surfaced once; summary not hijacked"
h=$(home s6); printf 'ticket=ENG-600\n' > "$h/state/t.meta"
printf 'done: PR ready for review\n' > "$h/state/t.status"
printf '#!/usr/bin/env bash\n[ "$(printf %%s "$1" | jq -r .event)" = pr-opened ] && { sleep 30; exit 0; }\nprintf "%%s\\n" "$1" >> "%s/events"\n' "$h" > "$h/consumer"
start=$(perl -MTime::HiRes=time -e 'printf "%.3f", time')
FM_TASK_EVENT_TIMEOUT=2 emit "$h" t pr-opened --pr https://x/pull/9; rc=$?
end=$(perl -MTime::HiRes=time -e 'printf "%.3f", time')
el=$(echo "$end - $start" | bc)
echo "    producer returned rc=$rc in ${el}s while consumer hangs 30s"
[ "$rc" = 0 ] && [ "$(echo "$el < 1.5" | bc)" = 1 ] && ok "S6 hung consumer does not block or fail the producer" || bad "S6 producer blocked"
waitn "$h/state/task-events.log" 1; sleep 0.3
FM_TASK_EVENT_TIMEOUT=2 emit "$h" t pr-merged --pr https://x/pull/9
waitn "$h/events" 1
printf '#!/usr/bin/env bash\nexit 9\n' > "$h/consumer"
emit "$h" t finished; sleep 0.8
echo "    --- task-events.log ---"; sed 's/^/    /' "$h/state/task-events.log"
echo "    --- task status ---"; sed 's/^/    /' "$h/state/t.status"
grep -q 'event=pr-opened exit=124' "$h/state/task-events.log" && grep -q 'event=finished exit=9' "$h/state/task-events.log" \
  && ok "S6 timeout (124) and failure (9) logged" || bad "S6 log"
[ "$(grep -c 'actionable.*task event hook failed' "$h/state/t.status")" = 1 ] && ok "S6 one actionable status line, rate-limited" || bad "S6 actionable surfacing"
jq -e '.event=="pr-merged" and .summary=="PR ready for review"' "$h/events" >/dev/null && ok "S6 later summary still the worker's own status text" || bad "S6 summary hijacked"

echo "== S7 disabled home: no hook config -> no events, no state, no process"
h="$LAB/s7"; mkdir -p "$h/state" "$h/config"
emit "$h" t started; emit "$h" t pr-opened --pr https://x/pull/1
[ -z "$(ls -A "$h/state")" ] && ok "S7 unconfigured home produces no side effects" || bad "S7"

echo
echo "TOTAL_FAILS=$FAILS"
exit "$FAILS"
