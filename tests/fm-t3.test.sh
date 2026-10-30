#!/usr/bin/env bash
# Public CLI regressions for the opt-in T3 companion helper. No real T3 calls.
set -euo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
work=$(mktemp -d "$TMPDIR/fm-t3.XXXXXX")
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/linked" "$work/base" "$work/primary/.git" "$work/gitdir" "$work/common"
printf 'gitdir: fixture\n' > "$work/linked/.git"
printf 'worker brief\n' > "$work/brief"
printf 'inbox doorbell\n' > "$work/message"
export FM_T3_BASE_DIR="$work/base" FM_T3_BIN="$work/bin/t3"
export T3_TEST_LOG="$work/calls" T3_TEST_INPUT="$work/input"
cat > "$work/bin/git" <<'GIT'
#!/usr/bin/env bash
case "$4" in
  --show-toplevel) printf '%s\n' "$2" ;;
  --git-dir) printf '%s/gitdir\n' "$(dirname "$2")" ;;
  --git-common-dir) printf '%s/common\n' "$(dirname "$2")" ;;
  *) exit 1 ;;
esac
GIT
cat > "$work/bin/t3" <<'T3'
#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
args = sys.argv[1:]
with open(os.environ['T3_TEST_LOG'], 'a') as f:
    f.write(json.dumps(args) + '\n')
if args[:2] == ['project', 'add']:
    print('Added project test-project.')
elif args[:2] == ['thread', 'start']:
    Path(os.environ['T3_TEST_INPUT']).write_text(sys.stdin.read())
    if os.environ.get('T3_TEST_FAIL'):
        sys.exit(3)
    if os.environ.get('T3_TEST_BAD'):
        print('{}')
    else:
        print(json.dumps(dict(threadId='test-thread', projectId='test-project', runId='test-run')))
elif args[:2] == ['thread', 'send']:
    Path(os.environ['T3_TEST_INPUT']).write_text(sys.stdin.read())
    print('{"delivery":"queued"}')
elif args[:2] == ['thread', 'show']:
    print('{"thread":{"threadId":"test-thread","status":"idle"}}')
else:
    sys.exit(4)
T3
chmod +x "$work/bin/git" "$work/bin/t3"
export PATH="$work/bin:$PATH"
helper="$ROOT/bin/fm-t3.sh"

expect_failure() {
  if "$@" > "$work/failure" 2>&1; then fail "unexpected success: $*"; fi
}

"$helper" launch "$work/record" "$work/linked" "$work/brief" 'title with spaces' provider model > "$work/result"
jq -e '.threadId == "test-thread" and .projectId == "test-project"' "$work/result" >/dev/null
cmp "$work/brief" "$work/input"
[ "$(wc -l < "$work/calls")" -eq 2 ] || fail 'launch must register then start exactly once'
expect_failure "$helper" launch "$work/record" "$work/linked" "$work/brief" title provider model
[ "$(wc -l < "$work/calls")" -eq 2 ] || fail 'repeat launch contacted T3'
pass 'launch records exact identity, delivers brief on stdin, and refuses duplicates'

FM_T3_BIN=/missing FM_T3_BASE_DIR=/missing "$helper" read "$work/record" > "$work/result"
jq -e '.thread.status == "idle"' "$work/result" >/dev/null
"$helper" send "$work/record" "$work/message" > "$work/result"
cmp "$work/message" "$work/input"
jq -e '.delivery == "queued"' "$work/result" >/dev/null
python3 - "$work/calls" "$work/base" <<'PY'
import json, sys
calls = [json.loads(line) for line in open(sys.argv[1])]
assert calls[1][-2:] == ['--base-dir', sys.argv[2]] or calls[1][-3:] == ['--base-dir', sys.argv[2], '--json']
assert calls[1][calls[1].index('--provider') + 1] == 'provider'
assert calls[1][calls[1].index('--model') + 1] == 'model'
assert calls[2] == ['thread', 'show', 'test-thread', '--base-dir', sys.argv[2], '--messages', '10', '--json']
assert calls[3] == ['thread', 'send', 'test-thread', '-', '--base-dir', sys.argv[2], '--json']
PY
pass 'read/send stay bound to saved server and thread, with queued stdin delivery'

before=$(wc -l < "$work/calls")
expect_failure "$helper" interrupt "$work/record"
assert_contains "$(cat "$work/failure")" 'unsupported' 'interrupt must name the gap'
expect_failure "$helper" launch "$work/refused" "$work/primary" "$work/brief" title provider model
expect_failure "$helper" send "$work/missing" "$work/message"
[ "$(wc -l < "$work/calls")" -eq "$before" ] || fail 'refused operation contacted T3'
[ ! -e "$work/refused" ] || fail 'primary checkout refusal created record'
pass 'unsupported interrupt, primary checkout and missing record fail before T3 mutation'

expect_failure env T3_TEST_FAIL=1 "$helper" launch "$work/failed" "$work/linked" "$work/brief" title provider model
[ -f "$work/failed/intent.json" ] && [ ! -e "$work/failed/thread.json" ] || fail 'failed launch lost intent or published identity'
expect_failure "$helper" read "$work/failed"
expect_failure env T3_TEST_BAD=1 "$helper" launch "$work/bad" "$work/linked" "$work/brief" title provider model
[ -f "$work/bad/launch.json" ] && [ ! -e "$work/bad/thread.json" ] || fail 'malformed launch published identity'
pass 'failed and malformed launches retain reconciliation evidence without a usable identity'

before=$(wc -l < "$work/calls")
expect_failure "$helper" launch "$work/defaults" "$work/linked" "$work/brief" title
[ "$(wc -l < "$work/calls")" -eq "$before" ] || fail 'missing selection contacted T3'
pass 'launch requires an explicit provider/model pair before registering a project'
