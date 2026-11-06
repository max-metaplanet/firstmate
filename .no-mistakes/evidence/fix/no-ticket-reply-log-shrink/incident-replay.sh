#!/usr/bin/env bash
# Replays the telos64 parent-replies.status shrink against disposable homes,
# driving the real bin/fm-remote-delta-read.sh (remote side) and the real
# bin/fm-procevent-remote-reply.sh ingest (parent side).
set -u
REPO=$1; OLD_READER=$2
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-incident.XXXXXX"); trap 'rm -rf "$LAB"' EXIT
REMOTE=$LAB/telos64; PARENT=$LAB/main
mkdir -p "$REMOTE/state" "$PARENT/state" "$PARENT/data"
LOG=$REMOTE/state/parent-replies.status
ID=telos64
sha() { sha256sum "$1" | awk '{print $1}'; }
size() { wc -c < "$1" | tr -d ' '; }
field() { sed -n "s/^$2=//p" "$1" | head -1; }
read_delta() { FM_HOME=$REMOTE FM_REMOTE_DELTA_POLL_SECONDS=0.1 bash "$REPO/bin/fm-remote-delta-read.sh" state/parent-replies.status "$@"; }
ingest() { FM_HOME=$PARENT bash "$REPO/bin/fm-procevent-remote-reply.sh" ingest "$ID" "$1"; }
cursor() { cat "$PARENT/state/remote-replies/$ID.cursor" 2>/dev/null | grep -E '^(offset|prefix)'; }

echo "== 1. build an incident-scale log: ~554 KB of tagged status lines, last line '1793980552 working [at=1793980552]:' 615 bytes"
perl -e 'my $e=1793900000; my $n=0; my $s=0; while ($s < 554219) { my $l=sprintf("working [at=%d]: progress note %05d %s\n",$e+$n,$n,"x" x (540+($n%50))); $l=substr($l,0,554219-$s-1)."\n" if $s+length($l) > 554219; print $l; $s+=length $l; $n++ }' > "$LOG"
BEFORE=$(size "$LOG")
BODY="working [at=1793980552]: "
PAD=$((615 - 11 - ${#BODY} - 1))
printf '1793980552 %s%s\n' "$BODY" "$(head -c "$PAD" /dev/zero | tr '\0' 'w')" >> "$LOG"
echo "lines=$(wc -l < "$LOG") prefix-before-shift-line=$BEFORE size=$(size "$LOG") last-line-bytes=$(tail -n1 "$LOG" | wc -c)"

echo "== 2. relay the whole log to the parent with the real reader + real ingest"
OFF=0; H=$(printf '' | sha256sum | awk '{print $1}'); n=0
while [ "$OFF" -lt "$(size "$LOG")" ]; do
  read_delta "$OFF" "$H" 2 > "$LAB/r.out"; rc=$?
  [ $rc -eq 0 ] || { echo "reader rc=$rc"; exit 1; }
  ingest "$LAB/r.out" > /dev/null || { echo "ingest failed"; exit 1; }
  OFF=$(field "$LAB/r.out" to_offset); H=$(field "$LAB/r.out" to_prefix_sha256); n=$((n+1))
done
echo "deltas=$n"; cursor
CUR_OFF=$OFF; CUR_H=$H
echo "parent mirrored lines=$(grep -c '' "$PARENT/state/$ID.status")"

echo "== 3. the shrink: delete the leading '1793980552 ' in place, then a mid-write tail 'It is not me'"
perl -i -0pe 's/^1793980552 //m' "$LOG"
printf 'note [at=1793980600]: It is not me' >> "$LOG"
echo "size now=$(size "$LOG") (cursor=$CUR_OFF); first $BEFORE bytes unchanged: $([ "$(head -c "$BEFORE" "$LOG" | sha256sum | awk '{print $1}')" = "$(head -c "$BEFORE" "$LOG" | sha256sum | awk '{print $1}')" ] && echo yes)"

echo "-- base (pre-fix) reader on the same file:"
FM_HOME=$REMOTE bash "$OLD_READER" state/parent-replies.status "$CUR_OFF" "$CUR_H" 1 | sed -n '1,/^$/p' | grep -E 'status|reason|to_offset'

echo "-- fixed reader with the incomplete tail line (expect wait, exit 75, no break):"
t0=$(date +%s.%N); read_delta "$CUR_OFF" "$CUR_H" 1 > "$LAB/w.out"; rc=$?; t1=$(date +%s.%N)
echo "exit=$rc output-bytes=$(size "$LAB/w.out") elapsed=$(echo "$t1 - $t0" | bc)s"

echo "== 4. writer finishes the line and appends more replies"
printf '\ndone [at=1793980700]: second reply after the shift\nblocked [at=1793980800]: third reply after the shift\n' >> "$LOG"
t0=$(date +%s.%N); read_delta "$CUR_OFF" "$CUR_H" 2 > "$LAB/d.out"; rc=$?; t1=$(date +%s.%N)
echo "reader exit=$rc elapsed=$(echo "$t1 - $t0" | bc)s"; sed -n '1,/^$/p' "$LAB/d.out"
echo "-- payload:"; awk 'p{print} $0==""{p=1}' "$LAB/d.out"
echo "file size=$(size "$LOG") file sha=$(sha "$LOG")"
ingest "$LAB/d.out"; cursor
NEW_OFF=$(field "$LAB/d.out" to_offset); NEW_H=$(field "$LAB/d.out" to_prefix_sha256)

echo "== 5. no duplicates on the parent"
echo "parent lines containing [at=1793980552]: $(grep -c 'at=1793980552' "$PARENT/state/$ID.status")"
for k in 'It is not me' 'second reply after the shift' 'third reply after the shift'; do echo "'$k' count=$(grep -c "$k" "$PARENT/state/$ID.status")"; done
echo "-- re-ingesting the same delta (replay):"; ingest "$LAB/d.out"
for k in 'It is not me' 'second reply after the shift'; do echo "'$k' count after replay=$(grep -c "$k" "$PARENT/state/$ID.status")"; done
echo "-- next read from the new cursor (expect exit 75, nothing repeated):"
read_delta "$NEW_OFF" "$NEW_H" 1 > "$LAB/n.out"; echo "exit=$? output-bytes=$(size "$LAB/n.out")"
printf 'info [at=1793980900]: fourth reply\n' >> "$LOG"
read_delta "$NEW_OFF" "$NEW_H" 2 > "$LAB/n2.out"; echo "exit=$? payload:"; awk 'p{print} $0==""{p=1}' "$LAB/n2.out"
ingest "$LAB/n2.out"

echo "== 6. adversarial: a real byte replacement before the cursor still stops the relay"
cp "$LOG" "$LAB/log.bak"
F2_OFF=$(size "$LOG"); F2_H=$(sha "$LOG")
perl -i -0pe 's/progress note 00007/progress NOTE 00007/' "$LOG"
printf 'info [at=1793981000]: must not be delivered\n' >> "$LOG"
read_delta "$F2_OFF" "$F2_H" 1 > "$LAB/b.out"; echo "exit=$?"; grep -E '^(status|reason)=' "$LAB/b.out"; grep -c 'must not be delivered' "$LAB/b.out"
cp "$LAB/log.bak" "$LOG"
echo "-- adversarial: two leading stamps deleted still breaks"
printf '1793990001 working [at=1793990001]: a\n1793990002 working [at=1793990002]: b\n' >> "$LOG"
T_OFF=$(size "$LOG"); T_H=$(sha "$LOG")
perl -i -0pe 's/^1793990001 //m; s/^1793990002 //m' "$LOG"; printf 'x [at=1]: new\n' >> "$LOG"
read_delta "$T_OFF" "$T_H" 1 > "$LAB/b2.out"; echo "exit=$?"; grep -E '^(status|reason)=' "$LAB/b2.out"
echo "-- adversarial: tail chop of 11 bytes (no stamp removed) still breaks as truncated"
cp "$LAB/log.bak" "$LOG"; C_OFF=$(size "$LOG"); C_H=$(sha "$LOG"); truncate -s -11 "$LOG"
read_delta "$C_OFF" "$C_H" 1 > "$LAB/b3.out"; echo "exit=$?"; grep -E '^(status|reason)=' "$LAB/b3.out"
echo "-- ingest of the replacement break records one blocked decision line on the parent:"
ingest "$LAB/b.out"; echo "ingest rc=$?"; grep -c '^blocked.*remote-reply-continuity-telos64' "$PARENT/state/$ID.status"
