#!/usr/bin/env bash
# Adversarial --resolve-key refusals and kind coverage, real fm-send + drain,
# isolated tmux server, throwaway home. usage: drive-refusals.sh <bin> <lab>
set -u
BIN=$1 LAB=$2
export TMUX_TMPDIR=$LAB/tmux FM_SEND_SETTLE=0 FM_GATE_REFUSE_BYPASS=1  # sandbox fleet only
mk() { home=$LAB/ref-$1; rm -rf "$home"; mkdir -p "$home/state"; printf 'window=sess:fm-t1\nkind=%s\n' "$2" > "$home/state/t1.meta"; }
send() { # <label> <path-mode> <key>
  local p=$PATH
  [ "$2" = no-tasks-axi ] && p=$(printf '%s' "$PATH" | tr ':' '\n' | grep -v fnm_multishells | paste -sd: -)
  echo "--- [$1] fm-send t1 --resolve-key $3  (tasks-axi on PATH: $(PATH=$p command -v tasks-axi >/dev/null && echo yes || echo no))"
  PATH=$p FM_ROOT_OVERRIDE="$home" FM_HOME="$home" "$BIN/fm-send.sh" t1 --resolve-key "$3" "some answer" 2>&1 | grep -v WARNING
  echo "exit=${PIPESTATUS[0]}  inbox-records=$(ls "$home/state/t1.inbox"/*.msg 2>/dev/null | wc -l | tr -d ' ')"
}
echo "### A. mistyped key while the real decision sits open behind a done: line"
mk typo ship
printf 'needs-decision [key=eng2403-execsql-drop]: q\ndone: other parts shipped\n' > "$home/state/t1.status"
send typo with-tasks-axi eng2403-execsql-dorp
send typo no-tasks-axi eng2403-execsql-dorp
echo; echo "### B. key already answered by a resolved line"
mk resolved ship
printf 'needs-decision [key=k1]: q\nresolved [key=k1]: answered: yes\ndone: all done\n' > "$home/state/t1.status"
send resolved with-tasks-axi k1
send resolved no-tasks-axi k1
echo; echo "### C. key transferred to a captain-held task (not settled)"
mk held ship
printf 'needs-decision [key=moved]: q\ncaptain-held [key=moved]: tracked by sample-origins-call\n' > "$home/state/t1.status"
send held with-tasks-axi moved
send held no-tasks-axi moved
echo; echo "### D. failed: terminal and other kinds keep the decision open and answerable"
for kind in ship scout secondmate; do
  for term in done failed; do
    mk "$kind-$term" $kind
    printf 'blocked [key=need-creds]: need prod creds\n%s: gave up on the rest\n' "$term" > "$home/state/t1.status"
    echo "--- kind=$kind terminal=$term: drain lists -> $(FM_STATE_OVERRIDE="$home/state" "$BIN/fm-wake-drain.sh" 2>/dev/null | grep -F '[key=need-creds]' || echo '(NOT LISTED)')"
    PATH=$PATH FM_ROOT_OVERRIDE="$home" FM_HOME="$home" "$BIN/fm-send.sh" t1 --resolve-key need-creds "creds in vault" >/dev/null 2>&1
    echo "    fm-send exit=$?  closing line: $(grep '^resolved' "$home/state/t1.status" | sed -E 's/ \[at=[0-9]+\]//' || echo none)"
  done
done
