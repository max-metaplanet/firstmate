#!/usr/bin/env bash
# Behavior tests for bin/fm-remote-delta-read.sh, the append-only reply-log
# reader a remote lane runs as its preemptible long poll.
#
# Pins, through the executable interface:
#   * the delta schema: offsets, prefix and payload hashes, and payload bytes
#   * every continuity-break reason: truncated, prefix-changed, missing, and
#     line-exceeds-bound, plus an unsafe symlink or traversal target
#   * a deleted leading emission stamp on an already-consumed line, followed
#     by new lines, delivers those new lines once and does not repeat the
#     consumed line; a real prefix replacement still breaks
#   * one already-mirrored line replaced by a different line, witnessed by
#     that mirrored line, delivers the new tail from the line start, including
#     bytes past the old cursor; the hash alone does not recover it, and any
#     earlier byte that also changed still breaks
#   * a parent relaying to a host whose reader predates the witness argument
#     still captures exactly one well-formed delta, not that reader's usage
#   * an incomplete tail line is withheld until a newline completes it
#   * exit 75 when the wait window closes with nothing appended
#   * the per-poll executable boundary: an unchanged log costs one stat per
#     sample, and the bounded capture/hashing path runs only when the file's
#     stat identity changed - a same-size in-place rewrite still breaks the
#     continuity hash, so statting cheaper never hides a change.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
TMP_ROOT=$(fm_test_tmproot fm-remote-delta-read)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
DELTA_HOME="$TMP_ROOT/home"
DELTA_LOG_REL=state/replies.status
mkdir -p "$DELTA_HOME/state"
READER="$ROOT/bin/fm-remote-delta-read.sh"

EMPTY_SHA=$(: | shasum -a 256 | awk '{print $1}')
sha() { printf '%b' "$1" | shasum -a 256 | awk '{print $1}'; }

run_reader() { # <offset> <prefix> <wait> [rel] [mirrored-line]
  local rel=${4:-$DELTA_LOG_REL}
  if [ $# -ge 5 ]; then
    FM_HOME="$DELTA_HOME" FM_REMOTE_DELTA_POLL_SECONDS=0.05 \
      "$READER" "$rel" "$1" "$2" "$3" "$5"
  else
    FM_HOME="$DELTA_HOME" FM_REMOTE_DELTA_POLL_SECONDS=0.05 \
      "$READER" "$rel" "$1" "$2" "$3"
  fi
}

file_sha() { shasum -a 256 "$1" | awk '{print $1}'; }
file_bytes() { wc -c < "$1" | tr -d ' '; }
payload_of() { awk 'p { print } $0 == "" { p = 1 }' "$1"; }

# Delete the first "<epoch> " in the log, the leading stamp the incident lost.
drop_leading_stamp() { # <file> <epoch>
  STAMP="$2 " perl -i -0pe 's/\Q$ENV{STAMP}\E//' "$1"
}

# A growing log returns the complete appended lines with exact boundaries.
: > "$DELTA_HOME/$DELTA_LOG_REL"
run_reader 0 "$EMPTY_SHA" 4 > "$TMP_ROOT/growth.out" &
READER_PID=$!
sleep 0.3
printf 'first line\n' >> "$DELTA_HOME/$DELTA_LOG_REL"
wait "$READER_PID" || fail "a delta on growth did not exit 0"
OUT=$(<"$TMP_ROOT/growth.out")
assert_contains "$OUT" 'status=delta' 'the grown log did not produce a delta'
assert_contains "$OUT" 'from_offset=0' 'the delta did not start at the caller cursor'
assert_contains "$OUT" 'to_offset=11' 'the delta did not stop at the complete line'
assert_contains "$OUT" "from_prefix_sha256=$EMPTY_SHA" 'the delta did not echo the caller prefix hash'
assert_contains "$OUT" 'payload_sha256='"$(sha 'first line\n')" 'the payload hash is not the appended bytes'
assert_contains "$OUT" 'payload_bytes=11' 'the payload byte count is wrong'
[ "$(tail -n 1 "$TMP_ROOT/growth.out")" = 'first line' ] || fail 'the delta did not carry the appended line'
pass 'an appended line produces a delta with exact offsets, hashes, and payload'

# An unchanged log closes the window with 75 and never runs the snapshot path:
# one stat per sample is the whole per-poll cost.
DELTA_SHIM="$TMP_ROOT/delta-shim"
EXEC_LOG="$TMP_ROOT/delta-execs"
mkdir -p "$DELTA_SHIM"
for TOOL in perl shasum sha256sum od tail head wc tr date stat dirname basename; do
  REAL=$(PATH=/usr/bin:/bin command -v "$TOOL" 2>/dev/null || true)
  [ -n "$REAL" ] || continue
  cat > "$DELTA_SHIM/$TOOL" <<SH
#!/bin/sh
printf '%s\n' $TOOL >> "\$FM_TEST_EXEC_LOG"
exec $REAL "\$@"
SH
  chmod +x "$DELTA_SHIM/$TOOL"
done
: > "$EXEC_LOG"
: > "$DELTA_HOME/$DELTA_LOG_REL"
FM_TEST_EXEC_LOG="$EXEC_LOG" PATH="$DELTA_SHIM:/usr/bin:/bin" run_reader 0 "$EMPTY_SHA" 2 > /dev/null && \
  fail "an unchanged log did not exit 75" || RC=$?
[ "${RC:-0}" -eq 75 ] || fail "an unchanged log closed its window with $RC instead of 75"
perl_execs=$(grep -cx perl "$EXEC_LOG" || true)
stat_execs=$(grep -cx stat "$EXEC_LOG" || true)
# The first poll always takes one snapshot: it must validate the caller's
# cursor prefix before waiting. The gate only suppresses the repeats.
[ "$perl_execs" -eq 1 ] || fail "an unchanged log ran the bounded capture $perl_execs times"
for TOOL in od tail head wc date; do
  hits=$(grep -cx "$TOOL" "$EXEC_LOG" || true)
  [ "$hits" -eq 0 ] || fail "an unchanged log ran $TOOL $hits times in the poll loop"
done
[ "$stat_execs" -ge 5 ] || fail "the unchanged window did not keep polling stat ($stat_execs)"
pass 'an unchanged log costs one stat per poll and exits 75 at the window'

# Growth still pays the capture and hashing tools exactly when bytes appear.
: > "$EXEC_LOG"
FM_TEST_EXEC_LOG="$EXEC_LOG" PATH="$DELTA_SHIM:/usr/bin:/bin" run_reader 0 "$EMPTY_SHA" 4 > "$TMP_ROOT/growth2.out" &
READER_PID=$!
sleep 0.3
printf 'counted change\n' >> "$DELTA_HOME/$DELTA_LOG_REL"
wait "$READER_PID" || fail 'the shimmed growth run did not exit 0'
assert_contains "$(<"$TMP_ROOT/growth2.out")" 'status=delta' 'the shimmed run lost the delta'
[ "$(grep -cx perl "$EXEC_LOG" || true)" -ge 1 ] || fail 'growth did not run the bounded capture'
[ "$(grep -cx shasum "$EXEC_LOG" || true)" -ge 2 ] || fail 'growth did not hash prefix and payload'
pass 'the capture and hashing path runs exactly once a real change lands'

# A shrunk file reports the truncation with the hash of what actually remains.
printf 'alpha\nbeta\n' > "$DELTA_HOME/$DELTA_LOG_REL"
PREFIX_SHA=$(sha 'alpha\nbeta\n')
run_reader 11 "$PREFIX_SHA" 4 > "$TMP_ROOT/truncated.out" &
READER_PID=$!
sleep 0.3
printf 'a\n' > "$DELTA_HOME/$DELTA_LOG_REL"
wait "$READER_PID" || fail 'the truncated read did not exit 0'
OUT=$(<"$TMP_ROOT/truncated.out")
assert_contains "$OUT" 'status=continuity-broken' 'truncation did not produce a break'
assert_contains "$OUT" 'reason=truncated' 'truncation was not named'
assert_contains "$OUT" 'to_offset=2' 'the break did not report the shrunk size'
assert_contains "$OUT" "to_prefix_sha256=$(sha 'a\n')" 'the break did not hash the remaining prefix'
pass 'a shrunk log breaks continuity as truncated with the remaining hash'

# A same-size in-place rewrite changes only mtime/ctime: the stat gate must
# still take the snapshot, where the prefix hash catches the changed bytes.
# This rewrite lands in a later epoch second.
printf 'alpha\nbeta\n' > "$DELTA_HOME/$DELTA_LOG_REL"
run_reader 11 "$PREFIX_SHA" 4 > "$TMP_ROOT/rewrite.out" &
READER_PID=$!
sleep 1.1
printf 'OMEGA\nbeta\n' > "$DELTA_HOME/$DELTA_LOG_REL"
wait "$READER_PID" || fail 'the rewritten read did not exit 0'
OUT=$(<"$TMP_ROOT/rewrite.out")
assert_contains "$OUT" 'status=continuity-broken' 'a same-size rewrite did not produce a break'
assert_contains "$OUT" 'reason=prefix-changed' 'the same-size rewrite was not named prefix-changed'
assert_contains "$OUT" 'to_offset=11' 'the break did not report the current size'
pass 'a same-size in-place rewrite breaks continuity as prefix-changed'

# Model a same-second same-size rewrite at the stat executable boundary:
# size, inode, device, and whole-second timestamps stay fixed; only the
# fractions change. Rewrite the real log after the initial snapshot's prefix
# has been hashed, so scheduler load cannot move the test across a second.
SUBSECOND_SHIM="$TMP_ROOT/subsecond-shim"
mkdir -p "$SUBSECOND_SHIM"
cat > "$SUBSECOND_SHIM/stat" <<'SH'
#!/bin/sh
fraction=111111111
[ ! -e "$FM_TEST_REWRITE_DONE" ] || fraction=222222222
printf '11:100.%s:100.%s:123:456\n' "$fraction" "$fraction"
SH
REAL_SHASUM=$(PATH=/usr/bin:/bin command -v shasum)
cat > "$SUBSECOND_SHIM/shasum" <<SH
#!/bin/sh
"$REAL_SHASUM" "\$@" || exit \$?
case "\$3" in
*/prefix)
  if [ ! -e "\$FM_TEST_REWRITE_DONE" ]; then
    if [ "\${FM_TEST_REMOVE_LOG:-0}" = 1 ]; then
      rm -- "\$FM_TEST_REWRITE_LOG"
    else
      printf 'OMEGA\\nbeta\\n' > "\$FM_TEST_REWRITE_LOG"
    fi
    : > "\$FM_TEST_REWRITE_DONE"
  fi
  ;;
esac
SH
chmod +x "$SUBSECOND_SHIM/stat" "$SUBSECOND_SHIM/shasum"
printf 'alpha\nbeta\n' > "$DELTA_HOME/$DELTA_LOG_REL"
FM_TEST_REWRITE_LOG="$DELTA_HOME/$DELTA_LOG_REL" \
  FM_TEST_REWRITE_DONE="$TMP_ROOT/rewrite-done" \
  PATH="$SUBSECOND_SHIM:/usr/bin:/bin" \
  run_reader 11 "$PREFIX_SHA" 10 > "$TMP_ROOT/same-second.out" \
  || fail 'the same-second rewrite read did not exit 0'
[ -e "$TMP_ROOT/rewrite-done" ] || fail 'the initial prefix hash did not trigger the rewrite'
OUT=$(<"$TMP_ROOT/same-second.out")
assert_contains "$OUT" 'status=continuity-broken' 'the subsecond change did not break continuity'
assert_contains "$OUT" 'reason=prefix-changed' 'a same-second same-size rewrite was not detected'
pass 'a same-second same-size rewrite of the same inode breaks continuity'

# A log that disappears mid-wait breaks as missing only for a nonzero cursor.
printf 'alpha\nbeta\n' > "$DELTA_HOME/$DELTA_LOG_REL"
FM_TEST_REWRITE_LOG="$DELTA_HOME/$DELTA_LOG_REL" \
  FM_TEST_REWRITE_DONE="$TMP_ROOT/remove-done" FM_TEST_REMOVE_LOG=1 \
  PATH="$SUBSECOND_SHIM:/usr/bin:/bin" \
  run_reader 11 "$PREFIX_SHA" 10 > "$TMP_ROOT/missing.out" \
  || fail 'the missing-file read did not exit 0'
OUT=$(<"$TMP_ROOT/missing.out")
assert_contains "$OUT" 'status=continuity-broken' 'a removed log did not produce a break'
assert_contains "$OUT" 'reason=missing' 'the removed log was not named missing'
pass 'a removed log breaks continuity as missing'

# A removed log is not a break for a cursor at the origin: it keeps waiting,
# which is what a first poll against a not-yet-created log relies on.
run_reader 0 "$EMPTY_SHA" 1 > /dev/null && fail 'a missing log at offset 0 did not wait' || RC=$?
[ "${RC:-0}" -eq 75 ] || fail "a missing log at offset 0 exited $RC instead of 75"
pass 'a missing log at the origin cursor keeps waiting until the window closes'

# An incomplete tail line is withheld until its newline lands, then delivered
# whole rather than as a fragment.
printf 'whole\n' > "$DELTA_HOME/$DELTA_LOG_REL"
run_reader 6 "$(sha 'whole\n')" 4 > "$TMP_ROOT/partial.out" &
READER_PID=$!
sleep 0.3
printf 'frag' >> "$DELTA_HOME/$DELTA_LOG_REL"
sleep 0.4
printf -- '-ment\n' >> "$DELTA_HOME/$DELTA_LOG_REL"
wait "$READER_PID" || fail 'the completed line did not exit 0'
OUT=$(<"$TMP_ROOT/partial.out")
assert_contains "$OUT" 'status=delta' 'the completed line did not produce a delta'
assert_contains "$OUT" 'to_offset=16' 'the delta did not stop at the completed line'
assert_contains "$OUT" 'payload_bytes=10' 'the payload did not carry the whole line'
[ "$(tail -n 1 "$TMP_ROOT/partial.out")" = 'frag-ment' ] || fail 'the payload did not join the fragment'
pass 'an unterminated tail is withheld until the newline completes it'

# The same continuity rules apply to the schema's other break and refusal
# surfaces, with the wait window never entered.
printf 'past-bound tail' > "$DELTA_HOME/$DELTA_LOG_REL"
FM_HOME="$DELTA_HOME" FM_REMOTE_DELTA_MAX_BYTES=8 \
  run_reader 0 "$EMPTY_SHA" 1 > "$TMP_ROOT/bound.out" || fail 'the bound break did not exit 0'
assert_contains "$(<"$TMP_ROOT/bound.out")" 'reason=line-exceeds-bound' \
  'a tail line longer than the payload bound did not break'
run_reader 0 "$EMPTY_SHA" 1 '../outside' > /dev/null 2>&1 && \
  fail 'a traversing path was accepted' || true
printf 'real\n' > "$DELTA_HOME/state/real.status"
ln -sfn real.status "$DELTA_HOME/state/link.status"
run_reader 0 "$EMPTY_SHA" 1 'state/link.status' > /dev/null 2>&1 && \
  fail 'a symlinked log was accepted' || true
pass 'the reader refuses traversal, symlinks, and oversized tail lines'

# The incident: a line the cursor already consumed lost its leading "<epoch> "
# stamp, so the file shrank, and later lines were appended after the shift.
# The consumed line must not be delivered again. The new lines must be
# delivered once. Until those new lines exist the reader keeps waiting, which
# is what lets the relay stay armed.
STAMP_EPOCH=1793980552
STAMP_KEPT='kept before the shifted line'
STAMP_BODY="working [at=${STAMP_EPOCH}]: already mirrored"
STAMP_MIRRORED="${STAMP_EPOCH} ${STAMP_BODY}"
STAMP_NEW_A="working [at=1793980999]: first new reply"
STAMP_NEW_B='done [at=1793981000]: second new reply'
printf '%s\n%s\n' "$STAMP_KEPT" "$STAMP_MIRRORED" > "$DELTA_HOME/$DELTA_LOG_REL"
STAMP_CURSOR=$(file_bytes "$DELTA_HOME/$DELTA_LOG_REL")
STAMP_PREFIX=$(file_sha "$DELTA_HOME/$DELTA_LOG_REL")
drop_leading_stamp "$DELTA_HOME/$DELTA_LOG_REL" "$STAMP_EPOCH"
run_reader "$STAMP_CURSOR" "$STAMP_PREFIX" 1 > "$TMP_ROOT/stamp-wait.out" && \
  fail 'a stamp shrink with nothing new appended did not keep waiting' || RC=$?
[ "${RC:-0}" -eq 75 ] || fail "a stamp shrink with nothing new exited $RC instead of 75"
assert_not_contains "$(<"$TMP_ROOT/stamp-wait.out")" 'continuity-broken' \
  'a deleted leading stamp stopped the relay before any new line existed'
printf '%s' "$STAMP_NEW_A" >> "$DELTA_HOME/$DELTA_LOG_REL"
run_reader "$STAMP_CURSOR" "$STAMP_PREFIX" 1 > "$TMP_ROOT/stamp-partial.out" && \
  fail 'an unfinished line after a stamp shrink was not withheld' || RC=$?
[ "${RC:-0}" -eq 75 ] || fail "an unfinished line after a stamp shrink exited $RC instead of 75"
assert_not_contains "$(<"$TMP_ROOT/stamp-partial.out")" 'continuity-broken' \
  'an unfinished line after a stamp shrink stopped the relay'
assert_not_contains "$(<"$TMP_ROOT/stamp-partial.out")" 'already mirrored' \
  'an unfinished line after a stamp shrink repeated the consumed line'
printf '\n%s\n' "$STAMP_NEW_B" >> "$DELTA_HOME/$DELTA_LOG_REL"
run_reader "$STAMP_CURSOR" "$STAMP_PREFIX" 2 > "$TMP_ROOT/stamp-delta.out" \
  || fail 'new lines after a deleted leading stamp did not produce a delta'
OUT=$(<"$TMP_ROOT/stamp-delta.out")
assert_contains "$OUT" 'status=delta' 'a stamp shrink followed by new lines did not produce a delta'
assert_contains "$OUT" "from_offset=$STAMP_CURSOR" 'the stamp-shrink delta did not start at the committed cursor'
assert_contains "$OUT" "from_prefix_sha256=$STAMP_PREFIX" 'the stamp-shrink delta did not keep the committed prefix hash'
STAMP_TO=$(printf '%s\n' "$OUT" | sed -n 's/^to_offset=//p')
STAMP_TO_HASH=$(printf '%s\n' "$OUT" | sed -n 's/^to_prefix_sha256=//p')
[ "$STAMP_TO" = "$(file_bytes "$DELTA_HOME/$DELTA_LOG_REL")" ] \
  || fail "the stamp-shrink delta did not advance to the repaired file end (got $STAMP_TO)"
[ "$STAMP_TO_HASH" = "$(file_sha "$DELTA_HOME/$DELTA_LOG_REL")" ] \
  || fail 'the stamp-shrink cursor hash is not the repaired file'
PAYLOAD=$(payload_of "$TMP_ROOT/stamp-delta.out")
[ "$PAYLOAD" = "$(printf '%s\n%s\n' "$STAMP_NEW_A" "$STAMP_NEW_B")" ] \
  || fail "the stamp-shrink delta did not deliver only the new lines: $PAYLOAD"
assert_not_contains "$PAYLOAD" 'already mirrored' \
  'the stamp-shrink delta repeated the already-mirrored line'
run_reader "$STAMP_TO" "$STAMP_TO_HASH" 1 > "$TMP_ROOT/stamp-again.out" && \
  fail 'a second read delivered the stamp-shrink lines again' || RC=$?
[ "${RC:-0}" -eq 75 ] || fail "a second read after the stamp shrink exited $RC instead of 75"
assert_not_contains "$(<"$TMP_ROOT/stamp-again.out")" 'already mirrored' \
  'a second read repeated the consumed line'
assert_not_contains "$(<"$TMP_ROOT/stamp-again.out")" 'first new reply' \
  'a second read repeated a new line'
pass 'a deleted leading stamp delivers the new lines once and waits until they exist'

# The deleted stamp can sit on an earlier consumed line. Bytes after it shift
# left, including a later line the cursor already consumed, and only the lines
# appended beyond the old cursor are new.
printf '%s\n%s\n' "$STAMP_MIRRORED" 'note: still mirrored' > "$DELTA_HOME/$DELTA_LOG_REL"
EARLIER_CURSOR=$(file_bytes "$DELTA_HOME/$DELTA_LOG_REL")
EARLIER_PREFIX=$(file_sha "$DELTA_HOME/$DELTA_LOG_REL")
drop_leading_stamp "$DELTA_HOME/$DELTA_LOG_REL" "$STAMP_EPOCH"
printf '%s\n' 'done [at=1793981000]: after the shift' >> "$DELTA_HOME/$DELTA_LOG_REL"
run_reader "$EARLIER_CURSOR" "$EARLIER_PREFIX" 2 > "$TMP_ROOT/stamp-earlier.out" \
  || fail 'a stamp deleted from an earlier line did not produce a delta'
OUT=$(<"$TMP_ROOT/stamp-earlier.out")
assert_contains "$OUT" 'status=delta' 'a stamp deleted from an earlier line did not produce a delta'
PAYLOAD=$(payload_of "$TMP_ROOT/stamp-earlier.out")
[ "$PAYLOAD" = 'done [at=1793981000]: after the shift' ] \
  || fail "a stamp deleted from an earlier line delivered more than the new line: $PAYLOAD"
assert_not_contains "$PAYLOAD" 'still mirrored' \
  'a stamp deleted from an earlier line repeated a consumed later line'
pass 'a stamp deleted from an earlier consumed line delivers only the lines after the cursor'

# The same shape with an earlier byte changed is a real replacement. The new
# line after it must not be delivered, and the relay must stop.
printf '%s\n%s\n' 'alpha' "$STAMP_MIRRORED" > "$DELTA_HOME/$DELTA_LOG_REL"
REPLACED_CURSOR=$(file_bytes "$DELTA_HOME/$DELTA_LOG_REL")
REPLACED_PREFIX=$(file_sha "$DELTA_HOME/$DELTA_LOG_REL")
printf '%s\n%s\n%s\n' 'beta' "$STAMP_BODY" 'brand new reply' > "$DELTA_HOME/$DELTA_LOG_REL"
run_reader "$REPLACED_CURSOR" "$REPLACED_PREFIX" 1 > "$TMP_ROOT/replaced.out" \
  || fail 'a replaced prefix did not exit 0'
OUT=$(<"$TMP_ROOT/replaced.out")
assert_contains "$OUT" 'status=continuity-broken' 'a replaced prefix did not stop the relay'
assert_contains "$OUT" 'reason=prefix-changed' 'a replaced prefix was not named prefix-changed'
assert_not_contains "$OUT" 'status=delta' 'a replaced prefix was delivered as a delta'
assert_not_contains "$OUT" 'brand new reply' 'a replaced prefix delivered the lines appended after it'
pass 'a real prefix replacement still stops the relay'

# Chopping the tail is a shrink, not a deleted leading stamp, even when the
# remaining line still carries an emission tag.
printf '%s\n%s\n' "$STAMP_KEPT" "$STAMP_MIRRORED" > "$DELTA_HOME/$DELTA_LOG_REL"
CHOP_CURSOR=$(file_bytes "$DELTA_HOME/$DELTA_LOG_REL")
CHOP_PREFIX=$(file_sha "$DELTA_HOME/$DELTA_LOG_REL")
perl -e 'open my $fh, "+<", $ARGV[0] or die $!; binmode $fh; seek $fh, -11, 2 or die $!; truncate $fh, tell $fh or die $!' \
  "$DELTA_HOME/$DELTA_LOG_REL"
run_reader "$CHOP_CURSOR" "$CHOP_PREFIX" 1 > "$TMP_ROOT/chop.out" \
  || fail 'a chopped tail did not exit 0'
OUT=$(<"$TMP_ROOT/chop.out")
assert_contains "$OUT" 'status=continuity-broken' 'a chopped tail did not stop the relay'
assert_contains "$OUT" 'reason=truncated' 'a chopped tail was not named truncated'
assert_not_contains "$OUT" 'status=delta' 'a chopped tail was delivered as a delta'
pass 'chopping the tail still breaks continuity as truncated'

# The incident: the cursor sat on the end of one already-mirrored line, and
# that line was replaced. The parent mirror still has the old line. The reader
# must deliver the replacement and every complete line after it, and must not
# do that from the hash alone or when an earlier byte changed too.
REPLACED_KEPT='kept before the replaced line'
REPLACED_OLD='working [corr=5e807b519d0dd703] [at=1794013372]: placeholder (via-helper)'
REPLACED_NEW='working [at=1794013392]: Two changes are under way.'
REPLACED_AFTER='done [at=1794013400]: later line that must not be dropped'
printf '%s\n%s\n' "$REPLACED_KEPT" "$REPLACED_OLD" > "$DELTA_HOME/$DELTA_LOG_REL"
LINE_CURSOR=$(file_bytes "$DELTA_HOME/$DELTA_LOG_REL")
LINE_PREFIX=$(file_sha "$DELTA_HOME/$DELTA_LOG_REL")
printf '%s\n%s\n%s\n' "$REPLACED_KEPT" "$REPLACED_NEW" "$REPLACED_AFTER" > "$DELTA_HOME/$DELTA_LOG_REL"
run_reader "$LINE_CURSOR" "$LINE_PREFIX" 1 > "$TMP_ROOT/line-unwitnessed.out" \
  || fail 'a replaced line with no mirrored witness did not exit 0'
OUT=$(<"$TMP_ROOT/line-unwitnessed.out")
assert_contains "$OUT" 'status=continuity-broken' 'the hash alone recovered a replaced line'
assert_not_contains "$OUT" 'status=delta' 'the hash alone delivered a replaced line as a delta'
assert_not_contains "$OUT" 'later line that must not be dropped' \
  'the hash alone delivered bytes from after the replaced line'
run_reader "$LINE_CURSOR" "$LINE_PREFIX" 2 "$DELTA_LOG_REL" "$REPLACED_OLD" \
  > "$TMP_ROOT/line-replaced.out" \
  || fail 'a witnessed line replacement did not produce a delta'
OUT=$(<"$TMP_ROOT/line-replaced.out")
assert_contains "$OUT" 'status=delta' 'a witnessed line replacement did not produce a delta'
assert_contains "$OUT" "from_offset=$LINE_CURSOR" \
  'a witnessed line replacement did not stay anchored at the committed cursor'
assert_contains "$OUT" "from_prefix_sha256=$LINE_PREFIX" \
  'a witnessed line replacement did not keep the committed prefix hash'
LINE_TO=$(printf '%s\n' "$OUT" | sed -n 's/^to_offset=//p')
LINE_TO_HASH=$(printf '%s\n' "$OUT" | sed -n 's/^to_prefix_sha256=//p')
[ "$LINE_TO" = "$(file_bytes "$DELTA_HOME/$DELTA_LOG_REL")" ] \
  || fail "a witnessed line replacement did not advance to the new file end (got $LINE_TO)"
[ "$LINE_TO_HASH" = "$(file_sha "$DELTA_HOME/$DELTA_LOG_REL")" ] \
  || fail 'a witnessed line replacement cursor hash is not the new file'
PAYLOAD=$(payload_of "$TMP_ROOT/line-replaced.out")
[ "$PAYLOAD" = "$(printf '%s\n%s\n' "$REPLACED_NEW" "$REPLACED_AFTER")" ] \
  || fail "a witnessed line replacement dropped or rewrote the new tail: $PAYLOAD"
assert_not_contains "$PAYLOAD" 'placeholder (via-helper)' \
  'a witnessed line replacement repeated the replaced line'
run_reader "$LINE_TO" "$LINE_TO_HASH" 1 > "$TMP_ROOT/line-again.out" && \
  fail 'a second read delivered the replaced-line tail again' || RC=$?
[ "${RC:-0}" -eq 75 ] || fail "a second read after the line replacement exited $RC instead of 75"
pass 'one replaced already-mirrored line delivers the new tail, including bytes past the old cursor'

# A shorten that still shares the prefix before that line is the same replacement
# in progress. The reader waits for the different line instead of stopping.
printf '%s\n' "$REPLACED_KEPT" > "$DELTA_HOME/$DELTA_LOG_REL"
run_reader "$LINE_CURSOR" "$LINE_PREFIX" 3 "$DELTA_LOG_REL" "$REPLACED_OLD" \
  > "$TMP_ROOT/line-inflight.out" &
READER_PID=$!
sleep 0.3
printf '%s\n%s\n' "$REPLACED_NEW" "$REPLACED_AFTER" >> "$DELTA_HOME/$DELTA_LOG_REL"
wait "$READER_PID" || fail 'a line replacement that landed during the wait did not produce a delta'
OUT=$(<"$TMP_ROOT/line-inflight.out")
assert_contains "$OUT" 'status=delta' 'a line replacement in progress stopped the relay'
assert_not_contains "$OUT" 'continuity-broken' 'a line replacement in progress was reported as a break'
PAYLOAD=$(payload_of "$TMP_ROOT/line-inflight.out")
[ "$PAYLOAD" = "$(printf '%s\n%s\n' "$REPLACED_NEW" "$REPLACED_AFTER")" ] \
  || fail "a line replacement in progress dropped the new tail: $PAYLOAD"
pass 'a replaced line that appears during the wait is delivered instead of stopping the relay'

# The same witness must not recover a rewrite that also changes an earlier byte,
# a witness that is not the line the cursor hashed, or a chop that never becomes
# a different line.
printf '%s\n%s\n' "$REPLACED_KEPT" "$REPLACED_OLD" > "$DELTA_HOME/$DELTA_LOG_REL"
BROAD_CURSOR=$(file_bytes "$DELTA_HOME/$DELTA_LOG_REL")
BROAD_PREFIX=$(file_sha "$DELTA_HOME/$DELTA_LOG_REL")
printf '%s\n%s\n%s\n' 'changed earlier byte' "$REPLACED_NEW" "$REPLACED_AFTER" \
  > "$DELTA_HOME/$DELTA_LOG_REL"
run_reader "$BROAD_CURSOR" "$BROAD_PREFIX" 1 "$DELTA_LOG_REL" "$REPLACED_OLD" \
  > "$TMP_ROOT/line-broad.out" || fail 'a broader rewrite did not exit 0'
OUT=$(<"$TMP_ROOT/line-broad.out")
assert_contains "$OUT" 'status=continuity-broken' 'a broader rewrite was recovered'
assert_contains "$OUT" 'reason=prefix-changed' 'a broader rewrite was not named prefix-changed'
assert_not_contains "$OUT" 'status=delta' 'a broader rewrite was delivered as a delta'
assert_not_contains "$OUT" 'later line that must not be dropped' \
  'a broader rewrite delivered the lines appended after it'
run_reader "$BROAD_CURSOR" "$BROAD_PREFIX" 1 "$DELTA_LOG_REL" 'not the mirrored line' \
  > "$TMP_ROOT/line-wrong-witness.out" || fail 'a wrong mirrored line did not exit 0'
assert_contains "$(<"$TMP_ROOT/line-wrong-witness.out")" 'status=continuity-broken' \
  'a wrong mirrored line recovered a prefix break'
printf '%s\n%s\n' "$REPLACED_KEPT" "$REPLACED_OLD" > "$DELTA_HOME/$DELTA_LOG_REL"
CHOP_LINE_CURSOR=$(file_bytes "$DELTA_HOME/$DELTA_LOG_REL")
CHOP_LINE_PREFIX=$(file_sha "$DELTA_HOME/$DELTA_LOG_REL")
perl -e 'open my $fh, "+<", $ARGV[0] or die $!; binmode $fh; seek $fh, -11, 2 or die $!; truncate $fh, tell $fh or die $!' \
  "$DELTA_HOME/$DELTA_LOG_REL"
run_reader "$CHOP_LINE_CURSOR" "$CHOP_LINE_PREFIX" 1 "$DELTA_LOG_REL" "$REPLACED_OLD" \
  > "$TMP_ROOT/line-chop.out" || fail 'a chopped mirrored line did not exit 0'
OUT=$(<"$TMP_ROOT/line-chop.out")
assert_contains "$OUT" 'status=continuity-broken' 'a chopped mirrored line was recovered'
assert_contains "$OUT" 'reason=truncated' 'a chopped mirrored line was not named truncated'
assert_not_contains "$OUT" 'status=delta' 'a chopped mirrored line was delivered as a delta'
pass 'a witnessed line is not recovered when earlier bytes change, the witness is wrong, or the line is only chopped'

# A deleted leading stamp is still that repair when the parent also supplies the
# old line. The consumed line is not delivered again as a replacement.
printf '%s\n%s\n' "$STAMP_KEPT" "$STAMP_MIRRORED" > "$DELTA_HOME/$DELTA_LOG_REL"
STAMP_WITNESS_CURSOR=$(file_bytes "$DELTA_HOME/$DELTA_LOG_REL")
STAMP_WITNESS_PREFIX=$(file_sha "$DELTA_HOME/$DELTA_LOG_REL")
drop_leading_stamp "$DELTA_HOME/$DELTA_LOG_REL" "$STAMP_EPOCH"
printf '%s\n' 'done [at=1793981000]: after the stamp' >> "$DELTA_HOME/$DELTA_LOG_REL"
run_reader "$STAMP_WITNESS_CURSOR" "$STAMP_WITNESS_PREFIX" 2 "$DELTA_LOG_REL" "$STAMP_MIRRORED" \
  > "$TMP_ROOT/stamp-witness.out" \
  || fail 'a deleted stamp with the old line supplied did not produce a delta'
PAYLOAD=$(payload_of "$TMP_ROOT/stamp-witness.out")
[ "$PAYLOAD" = 'done [at=1793981000]: after the stamp' ] \
  || fail "a deleted stamp with the old line supplied repeated or dropped lines: $PAYLOAD"
assert_not_contains "$PAYLOAD" 'already mirrored' \
  'a deleted stamp with the old line supplied was treated as a replaced line'
pass 'a deleted leading stamp still delivers only the new lines when the old line is supplied'

# Property: for a fixed seed, replacing only the cursor's last line yields
# exactly the generated tail, and flipping an earlier byte still breaks.
# The seed and the four lines are the shrunk case a failure prints.
PROPERTY_SEED=20261106
RANDOM=$PROPERTY_SEED
property_token() {
  local count=$1 out='' draw alphabet=abcdefghijklmnopqrstuvwxyz0123456789
  while [ "$count" -gt 0 ]; do
    draw=$((RANDOM % 36))
    out="${out}${alphabet:$draw:1}"
    count=$((count - 1))
  done
  printf '%s' "$out"
}
property_i=0
while [ "$property_i" -lt 16 ]; do
  property_i=$((property_i + 1))
  property_kept=$(property_token 12)
  property_old=$(property_token 18)
  property_new=$(property_token 18)
  property_after=$(property_token 10)
  printf '%s\n%s\n' "$property_kept" "$property_old" > "$DELTA_HOME/$DELTA_LOG_REL"
  property_cursor=$(file_bytes "$DELTA_HOME/$DELTA_LOG_REL")
  property_prefix=$(file_sha "$DELTA_HOME/$DELTA_LOG_REL")
  printf '%s\n%s\n%s\n' "$property_kept" "$property_new" "$property_after" \
    > "$DELTA_HOME/$DELTA_LOG_REL"
  if ! run_reader "$property_cursor" "$property_prefix" 1 "$DELTA_LOG_REL" "$property_old" \
    > "$TMP_ROOT/property-delta.out"; then
    fail "seed $PROPERTY_SEED case $property_i kept=$property_kept old=$property_old new=$property_new after=$property_after did not produce a delta"
  fi
  property_payload=$(payload_of "$TMP_ROOT/property-delta.out")
  [ "$property_payload" = "$(printf '%s\n%s\n' "$property_new" "$property_after")" ] \
    || fail "seed $PROPERTY_SEED case $property_i kept=$property_kept old=$property_old new=$property_new after=$property_after payload=$property_payload"
  printf '%s\n%s\n%s\n' "x$property_kept" "$property_new" "$property_after" \
    > "$DELTA_HOME/$DELTA_LOG_REL"
  run_reader "$property_cursor" "$property_prefix" 1 "$DELTA_LOG_REL" "$property_old" \
    > "$TMP_ROOT/property-break.out" \
    || fail "seed $PROPERTY_SEED case $property_i earlier-byte rewrite did not exit 0"
  assert_contains "$(<"$TMP_ROOT/property-break.out")" 'status=continuity-broken' \
    "seed $PROPERTY_SEED case $property_i kept=$property_kept old=$property_old recovered an earlier-byte change"
done
pass "replacing only the cursor line keeps the generated tail across seed $PROPERTY_SEED"

# A parent relaying to a host that still runs the reader without the witness
# argument. That reader prints its usage header to stdout and exits 2 when it
# gets five arguments. The parent's captured source output must be the one
# well-formed result of the retry without the witness, not that header first.
COMPAT="$TMP_ROOT/compat"
COMPAT_REMOTE="$COMPAT/remote"
mkdir -p "$COMPAT/parent/data" "$COMPAT/parent/state/remote-replies" "$COMPAT_REMOTE/state" "$COMPAT/bin"
printf -- '- ios - iOS delivery (host: remote-mac; root: %s; home: %s; scope: iOS work; projects: alpha; added 2026-08-02)\n' \
  "$ROOT" "$COMPAT_REMOTE" > "$COMPAT/parent/data/secondmates.md"
printf 'working: first mirrored line\n' > "$COMPAT_REMOTE/state/parent-replies.status"
{
  printf 'schema=fm-remote-reply-cursor.v1\n'
  printf 'offset=%s\n' "$(file_bytes "$COMPAT_REMOTE/state/parent-replies.status")"
  printf 'prefix_sha256=%s\n' "$(file_sha "$COMPAT_REMOTE/state/parent-replies.status")"
} > "$COMPAT/parent/state/remote-replies/ios.cursor"
printf 'working: first mirrored line\n' > "$COMPAT/parent/state/.remote-reply-mirrored-ios"
printf 'working: second line after the cursor\n' >> "$COMPAT_REMOTE/state/parent-replies.status"
cat > "$COMPAT/bin/fake-ssh" <<'SH'
#!/usr/bin/env bash
while [ "$1" != -- ]; do shift; done
argv=()
while IFS= read -r -d '' arg; do argv+=("$arg"); done < <(printf '%s' "$7" | base64 --decode)
printf '%s\n' "${#argv[@]}" >> "$COMPAT_CALLS"
[ "${argv[0]}" = fm-remote-delta-read.sh ] || exit 93
if [ "${#argv[@]}" -ne 5 ]; then
  printf '# Blocking, non-destructive delta read for a remote secondmate append-only log.\n\nUsage:\n  fm-remote-delta-read.sh <relative-log> <offset> <prefix-sha256> [wait-seconds]\n'
  exit 2
fi
FM_HOME="$COMPAT_REMOTE" FM_REMOTE_DELTA_POLL_SECONDS=0.05 exec "$COMPAT_READER" "${argv[@]:1}"
SH
chmod +x "$COMPAT/bin/fake-ssh"
COMPAT_CALLS="$COMPAT/calls" COMPAT_REMOTE="$COMPAT_REMOTE" COMPAT_READER="$READER" \
  FM_HOME="$COMPAT/parent" FM_ROOT_OVERRIDE="$ROOT" FM_SSH_BIN="$COMPAT/bin/fake-ssh" \
  FM_REMOTE_REPLY_WAIT_SECONDS=1 \
  "$ROOT/bin/fm-procevent-remote-reply.sh" source ios > "$COMPAT/result" \
  || fail 'the relay to a reader without the witness argument did not deliver'
[ "$(cat "$COMPAT/calls")" = "$(printf '6\n5\n')" ] \
  || fail "the relay did not offer the witness and then retry without it: $(tr '\n' ' ' < "$COMPAT/calls")"
[ "$(head -n 1 "$COMPAT/result")" = 'schema=fm-remote-delta.v1' ] \
  || fail "the captured result does not start with the delta schema: $(head -n 3 "$COMPAT/result")"
[ "$("$ROOT/bin/fm-procevent-remote-reply.sh" classify "$COMPAT/result")" = delta ] \
  || fail 'the captured result from a reader without the witness argument is not a delta'
[ "$(payload_of "$COMPAT/result")" = 'working: second line after the cursor' ] \
  || fail "the captured result did not carry the line after the cursor: $(payload_of "$COMPAT/result")"
pass 'a reader without the witness argument still yields one well-formed delta'

printf 'delta-read contract tests complete\n'
