#!/usr/bin/env bash
# Live: real treehouse binary, disposable repo/pool/home. Simulates reboot by
# letting the interactive get's process lease die, then runs Firstmate restore.
set -u
WT=${1:?worktree}; LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lease-live.XXXXXX")
trap 'rm -rf "$LAB"' EXIT
cd "$LAB"
export GIT_CONFIG_COUNT=0 GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@x GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@x
unset TREEHOUSE_ROOT TREEHOUSE_LEASE_HOLDER
git init -q --bare origin.git
git clone -q origin.git proj 2>/dev/null; git -C proj commit -q --allow-empty -m init; git -C proj push -q origin HEAD:main 2>/dev/null
git -C proj branch -q -M main; git -C proj remote set-head origin main 2>/dev/null
TR="$LAB/troot"
say(){ printf '\n### %s\n' "$*"; }
st(){ (cd "$LAB/proj" && treehouse --root "$TR" status --json) | node -e 'for (const w of JSON.parse(require("fs").readFileSync(0,"utf8"))) console.log(`slot ${w.name}: leased=${w.leased===true} holder=${w.lease_holder||"-"} status=${w.status||w.state||"?"}`)'; }
say "1. interactive treehouse get (process lease), worker exits = reboot"
(cd proj && printf 'pwd > %s/slot1\nexit\n' "$LAB" | SHELL=/bin/bash treehouse --root "$TR" get --no-fetch >/dev/null 2>&1)
S1=$(cat "$LAB/slot1"); echo "task T1 worktree: $S1"; st
say "2. record task T1 (parked) in a disposable FM_HOME with its slot-owner claim"
export FM_HOME="$LAB/home"; mkdir -p "$FM_HOME/state"
. "$WT/bin/fm-backend.sh"; . "$WT/bin/fm-wake-lib.sh"; . "$WT/bin/fm-treehouse-lease-lib.sh"
printf 'project=%s\nworktree=%s\nkind=ship\nworker_park_phase=parked\n' "$LAB/proj" "$S1" > "$FM_HOME/state/T1.meta"
fm_treehouse_slot_owner_claim "$S1" T1 "$FM_HOME"; cat "$(dirname "$S1")/.fm-slot-owner"
say "3. WITHOUT restore (the reported bug): a fresh get on the clean, process-lease-lapsed slot"
(cd proj && printf 'pwd > %s/probe\nexit\n' "$LAB" | SHELL=/bin/bash treehouse --root "$TR" get --no-fetch >/dev/null 2>&1); echo "probe get got: $(cat $LAB/probe)  (same as T1: $([ "$(cat $LAB/probe)" = "$S1" ] && echo YES-BUG || echo no))"
echo dirty > "$S1/wip.txt"; before=$(git -C "$S1" status --porcelain)
st
say "4. Firstmate restore (startup sweep)"
fm_treehouse_leases_restore "$FM_HOME/state" "$FM_HOME"; echo "restore rc=$?"; st
[ "$(git -C "$S1" status --porcelain)" = "$before" ] && echo "worktree contents unchanged: yes" || echo "worktree contents CHANGED"
say "5. restore again (idempotent)"; fm_treehouse_leases_restore "$FM_HOME/state" "$FM_HOME"; echo "rc=$?"; st
say "6. new interactive get after restore must not pick T1's slot (wip.txt removed: slot is clean, only the lease protects it)"
rm -f "$S1/wip.txt"; st
(cd proj && printf 'pwd > %s/slot2\nexit\n' "$LAB" | SHELL=/bin/bash treehouse --root "$TR" get --no-fetch >/dev/null 2>&1); S2=$(cat "$LAB/slot2"); echo "new get got: $S2  (avoids T1: $([ "$S2" != "$S1" ] && echo yes || echo NO-BUG))"
say "7. foreign-claim record is skipped (claim names other task)"
printf 'project=%s\nworktree=%s\n' "$LAB/proj" "$S2" > "$FM_HOME/state/T2.meta"; fm_treehouse_slot_owner_claim "$S2" OTHER "$FM_HOME"
fm_treehouse_leases_restore "$FM_HOME/state" "$FM_HOME"; echo "rc=$?"; st
say "8. teardown-equivalent release: treehouse return --force + claim release"
(cd "$S1" && treehouse --root "$TR" return --force "$S1" >/dev/null 2>&1); echo "return rc=$?"; fm_treehouse_slot_owner_release "$S1" T1; ls -a "$(dirname "$S1")" | grep -c fm-slot-owner; st
