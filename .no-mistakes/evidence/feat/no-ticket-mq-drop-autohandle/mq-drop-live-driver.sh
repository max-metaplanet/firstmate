#!/usr/bin/env bash
# Live driver: real firstmate scripts + real isolated tmux worker pane; only gh (forge) is a fixture.
set -u
ROOT=$1; OUT=$2
LAB=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")" && pwd -P)
trap 'TMUX_TMPDIR="$LAB/tmux" tmux kill-server 2>/dev/null; rm -rf "$LAB"' EXIT
HEAD_A=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa; HEAD_B=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
QUEUE_HEAD=cccccccccccccccccccccccccccccccccccccccc; MARKER='has been removed from the queue'
NOW=2026-11-02T08:00:00Z
log(){ printf '%s\n' "$*" | tee -a "$OUT"; }
setup_home(){ # name
  H="$LAB/$1"; "$ROOT/bin/fm-lab-home.sh" create "$H" >/dev/null || log "ERROR: lab home create failed"; mkdir -p "$H"/{data/delivery,state,config,projects/sample,fakebin,forge,root/bin,wt,tmux}
  printf '#!/bin/sh\nexit 0\n' > "$H/root/bin/fm-guard.sh"; chmod +x "$H/root/bin/fm-guard.sh"
  printf '# Backlog\n\n## Queued\n- [ ] delivery - Contribution https://github.com/o/r/pull/8 (repo: sample) (kind: ship)\n' > "$H/data/backlog.md"
  jq -n --arg head "$HEAD_A" --arg at "$NOW" '{schema:"fm-contributions.v1",task:"delivery",records:[{
    url:"https://github.com/o/r/pull/8",kind:"pr",checked_at:$at,error:null,pending:[],seen:[],verdict:null,
    observation:{head:$head,state:"open",draft:false,mergeable:"mergeable",review_decision:"APPROVED",can_merge:false,
    checks:[{name:"test",id:1,status:"completed",conclusion:"success",started_at:$at}],reviews:[],events:[]}}]}' > "$H/data/delivery/contributions.json"
  echo "$HEAD_A" > "$H/forge/head"; echo '[]' > "$H/forge/comments.json"; echo '[]' > "$H/forge/reviews.json"; echo '[]' > "$H/forge/inline.json"
  jq -n --arg h "$QUEUE_HEAD" '{head:{sha:$h}}' > "$H/forge/queue-pull.json"
  jq -n '[{check_runs:[{name:"queue-draft-tests",id:7001,status:"completed",conclusion:"failure",started_at:"2026-11-02T07:50:00Z",output:{summary:"queue draft run failed"}}]}]' > "$H/forge/queue-checks.json"
  printf 'Run tests\n  FAIL: test_merge_queue_draft (expected 2, got 3)\nError: Process completed with exit code 1.\n' > "$H/forge/job.log"
  sed -n '/^  cat > "\$home\/fakebin\/gh" <<.SH.$/,/^SH$/p' "$ROOT/tests/fm-mq-drop.test.sh" | sed '1d;$d' > "$H/fakebin/gh"; chmod +x "$H/fakebin/gh"
  # real tmux server (private TMUX_TMPDIR) hosting the worker pane
  TMUX_TMPDIR="$H/tmux" tmux new-session -d -s lab -n fm-delivery -x 200 -y 50 "cat > '$H/pane-input.log'"
  printf 'worktree=%s/wt\nkind=ship\n' "$H" > "$H/state/delivery.meta"; chmod 600 "$H/state/delivery.meta"
  run "$ROOT/bin/fm-pr-check.sh" delivery https://github.com/o/r/pull/8 >/dev/null || log "ERROR: arm failed"
  printf 'window=lab:fm-delivery\nproject=%s/projects/sample\n' "$H" >> "$H/state/delivery.meta"
}
run(){ env -u TMUX PATH="$H/fakebin:$PATH" TMUX_TMPDIR="$H/tmux" FORGE="$H/forge" QUEUE_HEAD="$QUEUE_HEAD" FM_SEND_SETTLE=0 \
  FM_HOME="$H" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$H/state" FM_CONFIG_OVERRIDE="$H/config" \
  FM_CONTRIBUTIONS_NOW="$NOW" "$@"; }
poll(){ [ -x "$H/state/contributions.check.sh" ] || log "ERROR: contributions check not armed"; run "$ROOT/bin/fm-contributions.sh" poll >>"$H/check.out" 2>>"$H/check.err"; }
inbox(){ ls "$H/state/delivery.inbox/"*.msg 2>/dev/null | wc -l; }
body(){ bash -c '. "$1"; fm_task_inbox_body "$2"' _ "$ROOT/bin/fm-task-inbox-lib.sh" "$H/state/delivery.inbox/$1.msg"; }
token(){ jq -r '.records[0].mq_drop // "none" | tostring' "$H/data/delivery/contributions.json"; }
comment(){ jq -n --argjson id "$1" --arg b "$2" --arg u "${3:-2026-11-02T08:01:00Z}" '[{id:$id,user:{login:"mergify[bot]"},author_association:"NONE",body:$b,html_url:("https://github.com/o/r/pull/8#issuecomment-"+($id|tostring)),created_at:"2026-11-02T08:01:00Z",updated_at:$u}]' > "$H/forge/comments.json"; }
declare_q(){ printf 'sample\tmergify[bot]\t%s\n' "$MARKER" > "$H/config/project-merge-queue"; }

log "=== S1/S2/S3/S4: declared Mergify drop -> steer; repeat; bare push; real re-drop"
setup_home main; declare_q
comment 101 "This pull request $MARKER because the queue run failed: https://github.com/o/r/pull/20"
poll; log "after drop poll: inbox=$(inbox) mq_drop=$(token)"
log "--- steer body delivered to worker inbox (001) ---"; body 001 | tee -a "$OUT"
sleep 1; log "--- worker tmux pane received (doorbell) ---"; cat "$H/pane-input.log" 2>/dev/null | tee -a "$OUT"
poll; log "after repeat poll (same comment, same head): inbox=$(inbox)"
echo "$HEAD_B" > "$H/forge/head"; poll; poll; log "after bare push to HEAD_B x2 polls (comment unchanged): inbox=$(inbox) mq_drop=$(token)"
comment 101 "This pull request $MARKER again: https://github.com/o/r/pull/20" 2026-11-02T09:00:00Z
poll; log "after bot re-drops by editing comment on HEAD_B: inbox=$(inbox) mq_drop=$(token)"
comment 101 "This pull request $MARKER again (position refreshed): https://github.com/o/r/pull/20" 2026-11-02T09:05:00Z
poll; log "after same-head in-place edit: inbox=$(inbox)"
echo "$HEAD_A" > "$H/forge/head"; comment 102 "This pull request $MARKER (serial bot new comment): https://github.com/o/r/pull/20"
poll; log "after new drop comment 102 on new head: inbox=$(inbox) mq_drop=$(token)"
[ -s "$H/check.out" ] && { log "--- poll stdout ---"; cat "$H/check.out" | tee -a "$OUT"; }; grep -v "^●\|fm-gate-refuse: gate agent lifecycle permitted" "$H/check.err" | sed "s/^/stderr: /" | tee -a "$OUT"
TMUX_TMPDIR="$H/tmux" tmux kill-server 2>/dev/null

log "=== S5: merged PR with drop-marker comment"
setup_home merged; declare_q; comment 101 "PR $MARKER: https://github.com/o/r/pull/20"; echo merged > "$H/forge/state"
poll; log "merged: inbox=$(inbox) mq_drop=$(token) state=$(jq -r '.records[0].observation.state' "$H/data/delivery/contributions.json")"
TMUX_TMPDIR="$H/tmux" tmux kill-server 2>/dev/null

log "=== S6: undeclared project"
setup_home undeclared; comment 101 "PR $MARKER: https://github.com/o/r/pull/20"
poll; log "undeclared: inbox=$(inbox) mq_drop=$(token) state=$(jq -r '.records[0].observation.state' "$H/data/delivery/contributions.json")"
TMUX_TMPDIR="$H/tmux" tmux kill-server 2>/dev/null

log "=== S7: hung queue-PR read under 3s poll budget"
setup_home slow; declare_q; comment 101 "PR $MARKER: https://github.com/o/r/pull/20"; touch "$H/forge/slow-queue-pull"
s=$(date +%s); FM_CONTRIBUTIONS_BUDGET=3 poll; e=$(( $(date +%s)-s ))
log "slow: elapsed=${e}s inbox=$(inbox)"; body 001 | grep -E 'Evidence source' | tee -a "$OUT"
TMUX_TMPDIR="$H/tmux" tmux kill-server 2>/dev/null
