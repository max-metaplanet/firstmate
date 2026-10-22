#!/usr/bin/env bash
# Drive real fm-task-event.sh and fm-send.sh against a disposable lab home.
set -u
WT=~/.no-mistakes/worktrees/61c6dd39b831/01M5HCBGBP7GD8ZAFWQK81F41A
EV=~/.no-mistakes/evidence/01M5HCBGBP7GD8ZAFWQK81F41A
cd "$WT"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
bin/fm-lab-home.sh create "$LAB" >/dev/null
LAB=$(cd "$LAB" && pwd -P)
TD=$(bin/fm-lab-home.sh tmux-dir "$LAB")
cleanup() { TMUX_TMPDIR="$TD" tmux -L fm-lab kill-server 2>/dev/null; bin/fm-lab-home.sh teardown "$LAB" >/dev/null 2>&1; rm -rf "$LAB"; }
trap cleanup EXIT
cat > "$LAB/hook" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "$FM_HOME/events.jsonl"
SH
chmod +x "$LAB/hook"; printf '%s\n' "$LAB/hook" > "$LAB/config/task-event-hook"
wait_n() { for i in $(seq 300); do [ -f "$LAB/events.jsonl" ] && [ "$(wc -l < "$LAB/events.jsonl")" -ge "$1" ] && return 0; sleep 0.1; done; echo "TIMEOUT waiting for $1 events"; return 1; }
emit() { env -u FM_ROOT_OVERRIDE FM_HOME="$LAB" FM_STATE_OVERRIDE="$LAB/state" FM_CONFIG_OVERRIDE="$LAB/config" bin/fm-task-event.sh "$@"; }

# Scenario A: ENG-2798-like sequence with raw worker text in the summary.
printf 'ticket=ENG-2798\n' > "$LAB/state/task.meta"
RAW1='published ). Only offered command is git checkout --detach. Need reconciliation guidance before live verification while preserving exact task branch. no reset or branch replacement performed. CI drive18'
RAW2='Decision recorded. run the offered `git checkout --detach `'
PR=https://github.com/example/repo/pull/77
n=0
emit task started --summary 'starting'; n=$((n+1)); wait_n $n
emit task pr-opened --pr "$PR" --summary 'opened pr'; n=$((n+1)); wait_n $n
emit task blocked --key reconcile --summary "$RAW1" --pr "$PR"; n=$((n+1)); wait_n $n
emit task decision-answered --key reconcile --summary "$RAW2" --pr "$PR"; n=$((n+1)); wait_n $n
emit task resumed --key reconcile --summary 'resumed' --pr "$PR"; n=$((n+1)); wait_n $n
emit task waiting --key scope --summary 'needs-decision raw ~/path' --pr "$PR"; n=$((n+1)); wait_n $n
emit task pr-merged --pr "$PR" --summary 'merged'; n=$((n+1)); wait_n $n
emit task finished --pr "$PR" --summary 'done raw'; n=$((n+1)); wait_n $n
emit task cancelled --pr "$PR" --summary 'cancel raw'; n=$((n+1)); wait_n $n
cp "$LAB/events.jsonl" "$EV/scenarioA-task-events.jsonl"
echo "== A: event -> progress =="
jq -c '{event,key,summary:(.summary[0:60]),progress}' "$LAB/events.jsonl"

# Scenario B/C: real fm-send --resolve-key on a real private tmux socket.
mv "$LAB/events.jsonl" "$LAB/eventsA.jsonl"
mkdir -p "$TD"
TMUX_TMPDIR="$TD" tmux -L fm-lab new-session -d -s sess -n fm-t1 'cat' 
TMUX_TMPDIR="$TD" tmux -L fm-lab new-window -d -t sess -n fm-t5 'cat'
. bin/fm-marker-lib.sh 2>/dev/null || true
printf 'window=sess:fm-t1\nkind=ship\nticket=ENG-2798\n' > "$LAB/state/t1.meta"
printf 'needs-decision [key=api-shape]: pick REST or RPC /private/x git checkout --detach\n' > "$LAB/state/t1.status"
printf 'window=sess:fm-t5\nkind=ship\nticket=ENG-2798\n' > "$LAB/state/t5.meta"
printf 'blocked [key=creds]: need the deploy token\n' > "$LAB/state/t5.status"
SOCK=$(TMUX_TMPDIR="$TD" tmux -L fm-lab display -p "#{socket_path}"); echo "lab socket=$SOCK"
send() { env -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_DATA_OVERRIDE -u FM_PROJECTS_OVERRIDE TMUX_TMPDIR="$TD" TMUX="$SOCK,0,0" FM_HOME="$LAB" FM_SEND_SETTLE=0 bin/fm-send.sh "$@"; }
echo "== B: answer needs-decision via --resolve-key =="
send t1 --resolve-key api-shape 'go with REST, run git checkout --detach abc'; echo "fm-send rc=$?"
sed -E 's/ \[at=[0-9]+\]//' "$LAB/state/t1.status"
wait_n 1 && jq -c '{event,task_id,key,summary,progress}' "$LAB/events.jsonl"
cp "$LAB/events.jsonl" "$EV/scenarioB-send-events.jsonl" 2>/dev/null
echo "== C: ordinary blocker steer via --resolve-key (expect no decision receipt) =="
before=$(wc -l < "$LAB/events.jsonl")
send t5 --resolve-key creds 'token is in the vault now'; echo "fm-send rc=$?"
sed -E 's/ \[at=[0-9]+\]//' "$LAB/state/t5.status"
sleep 3; after=$(wc -l < "$LAB/events.jsonl"); echo "events before=$before after=$after"
cat "$LAB/eventsA.jsonl" > "$EV/all-events.jsonl"; cat "$LAB/events.jsonl" >> "$EV/all-events.jsonl"
echo "== D: failed enqueue of a needs-decision answer (expect no close, no receipt) =="
TMUX_TMPDIR="$TD" tmux -L fm-lab new-window -d -t sess -n fm-t9 'cat'
printf 'window=sess:fm-t9\nkind=ship\nticket=ENG-2798\n' > "$LAB/state/t9.meta"
printf 'needs-decision [key=src]: choose the credential source\n' > "$LAB/state/t9.status"
: > "$LAB/state/t9.inbox"
before=$(wc -l < "$LAB/events.jsonl")
send t9 --resolve-key src 'use vault' 2>&1 | grep -v '●' | tail -3; echo "fm-send rc=${PIPESTATUS[0]}"
sed -E 's/ \[at=[0-9]+\]//' "$LAB/state/t9.status"
sleep 3; after=$(wc -l < "$LAB/events.jsonl"); echo "events before=$before after=$after"
echo "lab=$LAB"
