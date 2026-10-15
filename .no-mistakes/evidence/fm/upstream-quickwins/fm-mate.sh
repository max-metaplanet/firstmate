#!/usr/bin/env bash
set -u
REPO=$1
. "$REPO/tests/lib.sh" >/dev/null 2>&1 || true
fm_git_identity fmtest fmtest@example.invalid 2>/dev/null || true
PARENT=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); MATE=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
"$REPO/bin/fm-lab-home.sh" create "$PARENT" >/dev/null; "$REPO/bin/fm-lab-home.sh" create "$MATE" >/dev/null
: > "$MATE/AGENTS.md"
printf 'mate\n' > "$MATE/.fm-secondmate-home"
printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$PARENT" > "$MATE/.fm-secondmate-parent"
fm_write_secondmate_meta "$PARENT/state/mate.meta" "$MATE"
printf 'working: delegated scope\n' > "$PARENT/state/mate.status"
SHIM=$(mktemp -d /tmp/fm-shim.XXXXXX); LOG="$SHIM.log"
printf '#!/bin/sh\necho perl >> "%s"\nexec %s "$@"\n' "$LOG" "$(command -v perl)" > "$SHIM/perl"; chmod +x "$SHIM/perl"
run() { : > "$LOG"; env -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
  PATH="$SHIM:$PATH" FM_HOME="$MATE" FM_INACTIVE_RECONCILE_SECS=900 "$REPO/bin/fm-inactive-reconcile.sh" scan; }
timed() { [ -s "$LOG" ] && echo "timed re-exec: YES" || echo "timed re-exec: no"; }
run; echo "M0 first poll in secondmate home (due): rc=$? $(timed)"
run; echo "M1 second poll (not due): rc=$? $(timed); reported records: $(ls "$MATE/state/terminal-outcomes" 2>/dev/null | grep -c reported)"
id=child; mkdir -p "$MATE/projects/$id"; git -C "$MATE/projects/$id" init -q; git -C "$MATE/projects/$id" commit -q --allow-empty -m init
sha=$(git -C "$MATE/projects/$id" rev-parse HEAD); git -C "$MATE/projects/$id" update-ref refs/remotes/origin/main "$sha"
fm_write_meta "$MATE/state/$id.meta" "window=firstmate:fm-$id" "worktree=$MATE/projects/$id" "project=$MATE/projects/$id" \
  harness=codex kind=ship mode=no-mistakes yolo=off spawn_gen=g1 pr=https://example.test/owner/repo/pull/1 "pr_head=$sha"
printf 'failed: build broke on the lab fixture\n' > "$MATE/state/$id.status"
run; echo "M2 not-due poll after child wrote a terminal 'failed:' ledger line: rc=$? $(timed)"
echo "   mate receipts: $(cd "$MATE/state/terminal-outcomes" && ls)"
echo "   parent channel files containing the child outcome:"; grep -rl "child-outcome-child-failed" "$PARENT/state" 2>/dev/null | sed "s|$PARENT|<parent>|;s/^/     /"
grep -rh "child-outcome-child-failed" "$PARENT/state" 2>/dev/null | head -2 | sed 's/^/     line: /'
rm -rf "$PARENT" "$MATE" "$SHIM" "$LOG"; echo "## labs removed"
