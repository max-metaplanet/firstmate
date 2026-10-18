#!/usr/bin/env bash
# Regression for the live foreign session-lock owner and non-owner Stop loop.
# The executable reproduction runs the real auto-arm and turn-end guard paths.
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# Run the real arm path from the layout used by the validation pipeline even
# when this suite was launched from a plain checkout. Copy rather than symlink:
# the Python reproduction resolves its repository's physical path.
TMP_ROOT=$(fm_test_tmproot fm-turnend-foreign-owner-gate)
GATE_ROOT="$TMP_ROOT/.no-mistakes/worktrees/regression"
mkdir -p "$GATE_ROOT/tests" "$TMP_ROOT/home/state"
cp -R "$ROOT/bin" "$GATE_ROOT/bin"
cp "$ROOT/tests/fm-turnend-foreign-owner-repro.py" "$GATE_ROOT/tests/"

# The shared test bypass must not relax an ordinary firstmate's refusal. With
# that bypass removed, even --stop must refuse before publishing watcher state.
status=0
env -u FM_GATE_REFUSE_BYPASS FM_HOME="$TMP_ROOT/home" \
  FM_STATE_OVERRIDE="$TMP_ROOT/home/state" \
  "$GATE_ROOT/bin/fm-watch-arm.sh" --stop > "$TMP_ROOT/refusal.out" 2>&1 || status=$?
expect_code 1 "$status" "validation-checkout arm without the test bypass"
assert_grep 'refusing to arm from a disposable validation checkout' "$TMP_ROOT/refusal.out" \
  "the production arm guard did not refuse the validation checkout"
[ -z "$(ls -A "$TMP_ROOT/home/state")" ] || fail "the refused arm modified watcher state"
pass "a validation checkout still refuses watcher lifecycle calls without the test bypass"

python3 "$GATE_ROOT/tests/fm-turnend-foreign-owner-repro.py"
