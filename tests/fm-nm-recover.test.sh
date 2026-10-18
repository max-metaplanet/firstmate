#!/usr/bin/env bash
# Real repository recovery fixtures, with only the no-mistakes status CLI faked.
# Covers the three reported refusal shapes, preservation, uniqueness refusal,
# branch/run isolation, idempotence, and concurrent gate-ref changes.
set -euo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-nm-recover)
mkdir -p "$TMP_ROOT/fakebin"
cat > "$TMP_ROOT/fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
[ "$*" = 'axi status' ] || exit 99
cat "$FIX/status"
SH
chmod +x "$TMP_ROOT/fakebin/no-mistakes"
export PATH="$TMP_ROOT/fakebin:$PATH"
REAL_GIT=$(command -v git)
export REAL_GIT

fixture() {
  FIX="$TMP_ROOT/$1"
  export FIX NM_HOME="$TMP_ROOT/$1/nm"
  export FM_HOME="$FIX/home" FM_TASK_ID=task FM_STATE_OVERRIDE="$FIX/home/state"
  WT="$FIX/repo"
  GATE="$NM_HOME/repos/0123456789ab.git"
  mkdir -p "$WT" "$NM_HOME/repos" "$FM_HOME/state"
  git init -q -b fm/task "$WT"
  git -C "$WT" config user.name Test
  git -C "$WT" config user.email test@example.test
  printf 'base\n' > "$WT/base"
  git -C "$WT" add .
  git -C "$WT" commit -qm base
  BASE=$(git -C "$WT" rev-parse HEAD)
  printf 'original\n' > "$WT/feature"
  git -C "$WT" add .
  git -C "$WT" commit -qm 'original feature'
  OLD=$(git -C "$WT" rev-parse HEAD)
  git init -q --bare "$GATE"
  git --git-dir="$GATE" fetch -q "$WT" fm/task:refs/heads/fm/task
  git --git-dir="$GATE" update-ref refs/heads/fm/other "$OLD"
  git -C "$WT" remote add no-mistakes "$GATE"
  git -C "$WT" checkout -qb rewrite "$BASE"
  printf 'new base\n' > "$WT/base-advance"
  git -C "$WT" add .
  git -C "$WT" commit -qm 'base advanced'
  git -C "$WT" cherry-pick "$OLD" >/dev/null
  git -C "$WT" branch -f fm/task
  git -C "$WT" checkout -q fm/task
  HEAD_SHA=$(git -C "$WT" rev-parse HEAD)
  python3 - "$NM_HOME/state.sqlite" "$WT" <<'PY'
import sqlite3,sys
with sqlite3.connect(sys.argv[1]) as db:
    db.execute('CREATE TABLE repos (id TEXT, working_path TEXT)')
    db.execute('CREATE TABLE runs (id TEXT, repo_id TEXT, branch TEXT, status TEXT, created_at INTEGER)')
    db.execute('INSERT INTO repos VALUES (?,?)', ('0123456789ab',sys.argv[2]))
    db.execute('INSERT INTO runs VALUES (?,?,?,?,?)', ('run1','0123456789ab','fm/task','cancelled',1))
PY
  write_status custody_returned ahead run_pipeline
}

local_parent() {
  mkdir -p "$FIX/parent/state"
  printf '%s\n' mate > "$FM_HOME/.fm-secondmate-home"
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$FIX/parent" > "$FM_HOME/.fm-secondmate-parent"
}

write_status() {
  cat > "$FIX/status" <<EOF
run:
  id: run1
  branch: fm/task
  status: cancelled
branch_sync:
  state: $1
  changed: false
  local:
    branch: fm/task
    head: $HEAD_SHA
    clean: true
  pipeline:
    run: run1
    submitted_head: $OLD
    current_head: $OLD
  relation: $2
EOF
  if [ -n "${3:-}" ]; then
    printf '  next_action:\n    code: %s\n' "$3" >> "$FIX/status"
  fi
}

recover() {
  RC=0
  OUT=$(bash "$ROOT/bin/fm-nm-recover.sh" "$WT" "${1:-fm/task}" 2>&1) || RC=$?
}

assert_preserved() {
  [ "$RC" -eq 0 ] || fail "recovery: $OUT"
  assert_contains "$OUT" 'changed: true'
  if git --git-dir="$GATE" show-ref --verify --quiet refs/heads/fm/task; then
    fail 'stale gate branch survived'
  fi
  assert_equals "$OLD" "$(git -C "$WT" rev-parse "refs/no-mistakes/recover-local/run1-$OLD")" 'old head anchored'
  assert_equals "$OLD" "$(git --git-dir="$GATE" rev-parse refs/heads/fm/other)" 'other task untouched'
  assert_equals "$HEAD_SHA" "$(git -C "$WT" rev-parse HEAD)" 'local HEAD unchanged'
  assert_equals '' "$(git -C "$WT" status --porcelain)" 'worktree clean'
  assert_grep 'no-mistakes gate ref removed' "$FM_HOME/state/task.status" 'local deletion record'
  assert_grep "\"home\": \"$FM_HOME\"" "$FM_HOME/state/task.status" 'record identifies owning home'
  assert_grep '"task": "task"' "$FM_HOME/state/task.status" 'record identifies task'
  assert_grep '"ref": "refs/heads/fm/task"' "$FM_HOME/state/task.status" 'record identifies removed ref'
  assert_equals 1 "$(wc -l < "$FM_HOME/state/task.status" | tr -d ' ')" 'one local report per deletion'
  recover
  expect_code 0 "$RC" retry
  assert_contains "$OUT" 'changed: false'
  assert_equals 1 "$(wc -l < "$FM_HOME/state/task.status" | tr -d ' ')" 'no duplicate report for a no-op'
}

fixture mirror-loop
local_parent
# The original patch survives in history, followed by an intentional edit.
printf 'superseded\n' > "$WT/feature"
git -C "$WT" commit -qam 'supersede original line'
HEAD_SHA=$(git -C "$WT" rev-parse HEAD)
git -C "$WT" update-ref refs/no-mistakes/recover-local/run1 "$OLD"
write_status custody_returned ahead run_pipeline
recover
assert_contains "$OUT" 'parent_report: delivered'
assert_grep 'no-mistakes gate ref removed' "$FIX/parent/state/mate.status" 'parent receives deletion report'
assert_equals "$(cat "$FM_HOME/state/task.status")" "$(cat "$FIX/parent/state/mate.status")" 'parent receives the complete home, task and ref event'
assert_preserved
assert_equals 1 "$(wc -l < "$FIX/parent/state/mate.status" | tr -d ' ')" 'no parent report on no-op'
git --git-dir="$GATE" update-ref refs/heads/fm/task "$OLD"
recover
expect_code 0 "$RC" 'second actual deletion'
assert_equals 2 "$(wc -l < "$FIX/parent/state/mate.status" | tr -d ' ')" 'each deletion receives its own parent event'
assert_equals 2 "$(wc -l < "$FM_HOME/state/task.status" | tr -d ' ')" 'each deletion receives its own local event'
pass 'cancelled mirror recovery reports the home, task and removed ref through the existing parent channel'

fixture unpublished-rebased
write_status user_owned diverged ''
recover
assert_contains "$OUT" 'parent_report: not_applicable_primary_home'
assert_preserved
pass 'primary-home recovery records the deletion locally and explicitly reports no parent channel'

fixture syncstate-wrong
write_status custody_returned ahead run_pipeline
recover
assert_preserved
pass 'returned custody with stale pre-rebase gate head recovers despite no-op supported sync'

fixture unique
local_parent
git -C "$WT" checkout -qb unique "$OLD"
printf 'gate only\n' > "$WT/unique"
git -C "$WT" add .
git -C "$WT" commit -qm 'unique gate work'
UNIQUE=$(git -C "$WT" rev-parse HEAD)
git --git-dir="$GATE" fetch -q "$WT" unique:refs/heads/fm/task
git -C "$WT" checkout -q fm/task
recover
expect_code 1 "$RC" 'unique refusal'
assert_contains "$OUT" "$UNIQUE unique gate work"
assert_equals "$UNIQUE" "$(git --git-dir="$GATE" rev-parse refs/heads/fm/task)" 'unique ref preserved'
assert_equals '' "$(git -C "$WT" for-each-ref --format='%(refname)' refs/no-mistakes)" 'refusal created no anchor'
assert_absent "$FM_HOME/state/task.status" 'proof refusal emits no local deletion report'
assert_absent "$FIX/parent/state/mate.status" 'proof refusal emits no parent report'
pass 'unique gate work refuses with the exact commit and subject'

fixture wrong-branch
recover fm/other
expect_code 1 "$RC" 'wrong branch'
assert_equals "$OLD" "$(git --git-dir="$GATE" rev-parse refs/heads/fm/other)" 'other task preserved'
pass 'caller cannot select another task branch'

fixture dirty
printf 'dirty\n' >> "$WT/feature"
recover
expect_code 1 "$RC" 'dirty tree'
assert_contains "$OUT" 'not clean'
pass 'dirty worktree refuses'

fixture active
sed 's/status: cancelled/status: running/' "$FIX/status" > "$FIX/active"
mv "$FIX/active" "$FIX/status"
recover
expect_code 0 "$RC" 'active reattachment'
assert_contains "$OUT" 'action: reattach_active_run'
assert_equals "$OLD" "$(git --git-dir="$GATE" rev-parse refs/heads/fm/task)" 'active ref preserved'
pass 'active run reattaches without ref mutation'

fixture unreturned
write_status pipeline_owned diverged recover_custody
recover
expect_code 1 "$RC" 'unreturned custody'
assert_contains "$OUT" 'custody is not returned'
pass 'terminal status alone cannot authorize custody recovery'

fixture concurrent-run
python3 - "$NM_HOME/state.sqlite" <<'PY'
import sqlite3,sys
with sqlite3.connect(sys.argv[1]) as db:
    db.execute('INSERT INTO runs VALUES (?,?,?,?,?)', ('live','0123456789ab','fm/task','running',2))
PY
recover
expect_code 1 "$RC" 'concurrent run'
assert_contains "$OUT" 'newest registered branch run'
pass 'newer registered run prevents stale-status recovery'

fixture malformed-status
printf 'branch_sync:\n  state: custody_returned\n' >> "$FIX/status"
recover
expect_code 1 "$RC" 'duplicate status'
assert_contains "$OUT" 'duplicate structured status field'
pass 'duplicate structured status refuses'

fixture symbolic-ref
git --git-dir="$GATE" symbolic-ref refs/heads/fm/task refs/heads/fm/other
recover
expect_code 1 "$RC" 'symbolic gate ref'
assert_contains "$OUT" 'task gate ref is symbolic'
assert_equals "$OLD" "$(git --git-dir="$GATE" rev-parse refs/heads/fm/other)" 'symbolic target untouched'
pass 'symbolic task ref cannot redirect recovery into another task'

fixture empty-commit
git -C "$WT" checkout -qb empty "$OLD"
git -C "$WT" commit --allow-empty -qm 'unproven empty commit'
EMPTY=$(git -C "$WT" rev-parse HEAD)
git --git-dir="$GATE" fetch -q "$WT" empty:refs/heads/fm/task
git -C "$WT" checkout -q fm/task
recover
expect_code 1 "$RC" 'empty commit proof'
assert_contains "$OUT" "$EMPTY unproven empty commit"
pass 'empty gate commit cannot silently pass as patch-equivalent'

fixture gate-merge
git -C "$WT" checkout -qb gate-merge "$OLD"
git -C "$WT" merge --no-ff fm/task -m 'unproven gate merge' >/dev/null
MERGE=$(git -C "$WT" rev-parse HEAD)
git --git-dir="$GATE" fetch -q "$WT" gate-merge:refs/heads/fm/task
git -C "$WT" checkout -q fm/task
recover
expect_code 1 "$RC" 'merge commit proof'
assert_contains "$OUT" "$MERGE unproven gate merge"
pass 'gate-only merge commit refuses even when its parents have equivalent patches'

fixture remote-report
printf '%s\n' mate > "$FM_HOME/.fm-secondmate-home"
printf 'schema=fm-secondmate-parent.v1\nroute=remote\nparent_host=remote.example\n' > "$FM_HOME/.fm-secondmate-parent"
recover
assert_contains "$OUT" 'parent_report: delivered'
assert_grep '"ref": "refs/heads/fm/task"' "$FM_HOME/state/parent-replies.status" 'remote parent outbox'
assert_preserved
pass 'remote home reports through the existing parent-channel outbox'

fixture failed-parent-report
local_parent
mkdir "$FIX/parent/state/mate.status"
recover
expect_code 3 "$RC" 'parent delivery failure'
assert_contains "$OUT" 'changed: true'
assert_contains "$OUT" 'parent_report: failed'
assert_contains "$OUT" 'deletion already completed'
if git --git-dir="$GATE" show-ref --verify --quiet refs/heads/fm/task; then
  fail 'report failure undid or hid the deletion'
fi
assert_grep 'no-mistakes gate ref removed' "$FM_HOME/state/task.status" 'deletion recorded despite delivery failure'
assert_grep 'parent report failed' "$FM_HOME/state/task.status" 'delivery failure is durable locally'
pass 'parent reporting failure remains visible after deletion and never restores the stale ref'

fixture failed-local-report
local_parent
mkdir "$FM_HOME/state/task.status"
recover
expect_code 3 "$RC" 'local recording failure'
assert_contains "$OUT" 'changed: true'
assert_contains "$OUT" 'local recovery record failed'
assert_contains "$OUT" 'parent_report: delivered'
assert_grep '"ref": "refs/heads/fm/task"' "$FIX/parent/state/mate.status" 'parent still receives deletion despite local failure'
if git --git-dir="$GATE" show-ref --verify --quiet refs/heads/fm/task; then
  fail 'local recording failure restored the stale ref'
fi
pass 'local recording failure is visible and does not suppress parent delivery'

fixture missing-report-identity
unset FM_TASK_ID
recover
expect_code 1 "$RC" 'missing reporting identity'
assert_contains "$OUT" 'deletion reporting requires'
assert_equals "$OLD" "$(git --git-dir="$GATE" rev-parse refs/heads/fm/task)" 'no unattributed deletion'
pass 'missing home or task identity refuses before gate deletion'

fixture race
cat > "$TMP_ROOT/fakebin/git" <<'SH'
#!/usr/bin/env bash
# Move only the fixture branch immediately before the helper's guarded delete.
if [ "$1" = "--git-dir=$NM_HOME/repos/0123456789ab.git" ] && [ "${2:-}" = update-ref ] && [ "${4:-}" = -d ]; then
  "$REAL_GIT" --git-dir="$NM_HOME/repos/0123456789ab.git" update-ref refs/heads/fm/task "$RACE_HEAD"
fi
exec "$REAL_GIT" "$@"
SH
chmod +x "$TMP_ROOT/fakebin/git"
export RACE_HEAD="$BASE"
recover
expect_code 1 "$RC" 'concurrent ref update'
assert_equals "$BASE" "$(git --git-dir="$GATE" rev-parse refs/heads/fm/task)" 'new gate head survives CAS refusal'
assert_equals "$OLD" "$(git -C "$WT" rev-parse "refs/no-mistakes/recover-local/run1-$OLD")" 'old head remains archived'
assert_absent "$FM_HOME/state/task.status" 'failed deletion emits no deletion report'
pass 'expected-old guard preserves a gate ref moved after the proof'
rm "$TMP_ROOT/fakebin/git"

fixture gate-only-object
# The old line need not exist in the task's object database. Remove its sole
# fixture branch, expire fixture reflogs, and prune only this disposable repo.
git -C "$WT" branch -D rewrite >/dev/null
git -C "$WT" reflog expire --expire=now --all
git -C "$WT" gc --prune=now --quiet
if git -C "$WT" cat-file -e "$OLD^{commit}" 2>/dev/null; then
  fail 'gate-only fixture still holds old objects locally'
fi
recover
assert_preserved
pass 'proof reads gate-only objects and transfers them into a durable local anchor'

# Verify the public generated instructions, not implementation source text.
# shellcheck source=bin/fm-dod-lib.sh
. "$ROOT/bin/fm-dod-lib.sh"
instructions=$(fm_dod_block no-mistakes task fm/task)
assert_contains "$instructions" 'fm-nm-recover.sh'
pass 'generated no-mistakes worker contract points to the recovery helper'
