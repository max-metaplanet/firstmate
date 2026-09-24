#!/usr/bin/env bash
# Live drive of fm-send.sh --resolve-key and fm-wake-drain.sh OPEN DECISIONS
# against a REAL tmux server (isolated TMUX_TMPDIR, never the operator's
# default server) hosting a real worker pane, in a throwaway FM_HOME.
# Usage: live-drive.sh <bin-dir> <label>
set -u
BIN=$1; LABEL=$2
W=$(mktemp -d /tmp/fm-live-$LABEL.XXXX)
export TMUX_TMPDIR="$W/tmux"; mkdir -p "$TMUX_TMPDIR"
unset TMUX
# Sandbox-only: sanctioned test-harness bypass (bin/fm-gate-refuse-lib.sh header);
# this drive targets only a private tmux server and a throwaway FM_HOME.
export FM_GATE_REFUSE_BYPASS=1
HOME_DIR="$W/home"; mkdir -p "$HOME_DIR/state"
SESS=fmlab$LABEL
tmux new-session -d -s "$SESS" -n fm-t4 -x 200 -y 40 'cat'
tmux new-window -d -t "$SESS" -n fm-t5 'cat'
tmux new-window -d -t "$SESS" -n fm-t6 'cat'
run_send() { env FM_ROOT_OVERRIDE="$HOME_DIR" FM_HOME="$HOME_DIR" FM_SEND_SETTLE=0 "$BIN/fm-send.sh" "$@"; }
drain() { FM_STATE_OVERRIDE="$HOME_DIR/state" "$BIN/fm-wake-drain.sh" 2>&1; }
meta() { printf 'window=%s\nkind=%s\n' "$SESS:fm-$1" "$2" > "$HOME_DIR/state/$1.meta"; }
hdr() { printf '\n########## [%s] %s\n' "$LABEL" "$*"; }

hdr "S1 ship: needs-decision [key=schema] then bare done: line"
meta t4 ship
printf 'needs-decision [key=schema]: split the table or keep one?\nworking: other parts\ndone: the other parts shipped; schema still awaits a ruling\n' > "$HOME_DIR/state/t4.status"
cat "$HOME_DIR/state/t4.status"
hdr "S1 wake drain output"
drain | sed -n '/OPEN DECISIONS/,/^$/p'
drain | grep -c 'key=schema' | sed 's/^/lines mentioning key=schema: /'

hdr "S2 fm-send t4 --resolve-key schema 'split it'"
run_send t4 --resolve-key schema "split it"; echo "exit=$?"
echo "--- inbox:"; ls "$HOME_DIR/state/t4.inbox" 2>/dev/null && cat "$HOME_DIR/state/t4.inbox"/*.msg 2>/dev/null
echo "--- status log now:"; cat "$HOME_DIR/state/t4.status"
echo "--- real worker pane (tmux capture-pane):"; tmux capture-pane -p -t "$SESS:fm-t4" | sed '/^$/d'
hdr "S2 wake drain after answer"
drain | grep 'key=schema' || echo "(no open decision for key=schema)"

hdr "S3 scout: needs-decision [key=scope] then failed: line"
meta t5 scout
printf 'blocked [key=scope]: need access decision\nfailed: could not finish the survey half\n' > "$HOME_DIR/state/t5.status"
drain | grep 'key=scope' || echo "(no open decision for key=scope)"
run_send t5 --resolve-key scope "grant read-only"; echo "exit=$?"
grep 'key=scope' "$HOME_DIR/state/t5.status"

hdr "S4 mistyped key refusal"
meta t6 ship
printf 'needs-decision [key=real-key]: choose\n' > "$HOME_DIR/state/t6.status"
run_send t6 --resolve-key mistyped "the answer"; echo "exit=$?"
ls "$HOME_DIR/state/t6.inbox" 2>/dev/null || echo "(no inbox record: nothing sent)"

hdr "S5 genuinely closed key refusal"
printf 'resolved [key=real-key]: answered: chosen\n' >> "$HOME_DIR/state/t6.status"
run_send t6 --resolve-key real-key "again"; echo "exit=$?"

hdr "S6 captain-held transferred key refusal"
printf 'needs-decision [key=moved]: declare or drop\ncaptain-held [key=moved]: tracked by sample-origins-call\n' >> "$HOME_DIR/state/t6.status"
run_send t6 --resolve-key moved "declare it"; echo "exit=$?"

hdr "S7 mistyped key with tasks-axi absent from PATH"
NP=""; IFS=: read -r -a parts <<<"$PATH"
for p in "${parts[@]}"; do [ -x "$p/tasks-axi" ] && continue; NP="$NP${NP:+:}$p"; done
PATH="$NP" run_send t6 --resolve-key mistyped "the answer"; echo "exit=$?"
ls "$HOME_DIR/state/t6.inbox" 2>/dev/null || echo "(no inbox record: nothing sent)"

tmux kill-server
rm -rf "$W"
echo; echo "[$LABEL] tmux lab torn down"
