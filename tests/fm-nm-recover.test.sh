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
  WT="$FIX/repo"
  GATE="$NM_HOME/repos/0123456789ab.git"
  mkdir -p "$WT" "$NM_HOME/repos"
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
  recover
  expect_code 0 "$RC" retry
  assert_contains "$OUT" 'changed: false'
}

fixture mirror-loop
# The original patch survives in history, followed by an intentional edit.
printf 'superseded\n' > "$WT/feature"
git -C "$WT" commit -qam 'supersede original line'
HEAD_SHA=$(git -C "$WT" rev-parse HEAD)
git -C "$WT" update-ref refs/no-mistakes/recover-local/run1 "$OLD"
write_status custody_returned ahead run_pipeline
recover
assert_preserved
pass 'cancelled mirror recovery loop clears with an existing recovery anchor and superseded patch'

fixture unpublished-rebased
write_status user_owned diverged ''
recover
assert_preserved
pass 'unpublished rebased submitted head recovers without resetting local history or an empty merge'

fixture syncstate-wrong
write_status custody_returned ahead run_pipeline
recover
assert_preserved
pass 'returned custody with stale pre-rebase gate head recovers despite no-op supported sync'

fixture unique
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
