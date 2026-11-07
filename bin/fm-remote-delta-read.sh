#!/usr/bin/env bash
# Blocking, non-destructive delta read for a remote secondmate append-only log.
#
# Usage:
#   fm-remote-delta-read.sh <relative-log> <offset> <prefix-sha256> [wait-seconds] [mirrored-line]
#
# The reader validates continuity by hashing the exact prefix represented by the
# caller's cursor. It then blocks until at least one complete appended line is
# available, returns at most 65536 payload bytes, and never truncates or consumes
# the source. A shortened or changed prefix returns a structured continuity-break
# result instead of silently rebasing the cursor.
# One shortened prefix is not a break: a single leading emission stamp deleted
# from a consumed line starting within FM_REMOTE_DELTA_MAX_BYTES of the cursor.
# The stamp is the `<epoch> ` from that line's one `[at=<epoch>]` tag, and
# putting it back makes the cursor's prefix hash match. The reader then returns
# only the complete lines appended after the shifted line, never the consumed
# line again. Its next offset is a position in the file as it exists now.
# Until those new lines exist it waits, so the relay stays armed.
# One replaced line is not a break either. The caller passes that already-mirrored
# line, without its newline, as the optional final argument. The hash alone does
# not contain it. The proof hashes the live bytes before the line, then the line
# and its newline, and that digest must equal the cursor. The live file must hold
# a different line at that position. The reader then returns every complete line
# from the replaced line's start, including bytes past the old cursor, and its
# next offset is a position in the file as it exists now. Until that different
# line exists it waits. A wait that ends with the line still gone is still a
# continuity break. A deleted stamp is decided first, so that repair is never
# reported as a replaced line. Any other shortened or changed prefix, including
# a real replacement of earlier bytes or a stamp on an older line, is still a
# continuity break. If either proof cannot be run, the reader keeps the break.
#
# The log is sampled every FM_REMOTE_DELTA_POLL_SECONDS (default 0.5 seconds).
# A complete line is visible on the next sample, and the window deadline can
# overshoot by that interval plus snapshot and scheduling work.
# Each sample of an existing log stats it once. The first sample always runs
# the bounded capture and hashing; later samples skip that work only when the
# size, subsecond mtime and ctime, inode, and device key is unchanged. If either
# timestamp lacks a nonzero subsecond fraction, every sample captures the log
# rather than trusting a coarse key that could hide a same-second rewrite.
# The wait remains an ordinary child sleep; signal handling is unchanged.
#
# Exit 75 means the wait window closed with no complete line. SIGTERM exits the
# same way after cleanup. The remote job worker preempts this read-only poll to
# unblock any queued command other than another reply long-poll, then publishes
# that preemption as distinct exit 76. The bin/fm-remote-job-lib.sh header owns
# that contract.
set -eu

FM_HOME=${FM_HOME:?FM_HOME is required}
MAX_BYTES=${FM_REMOTE_DELTA_MAX_BYTES:-65536}
POLL_SECONDS=${FM_REMOTE_DELTA_POLL_SECONDS:-0.5}

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
usage() { sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

sha256_file() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    die "no SHA-256 tool is available"
  fi
}

copy_prefix() { # <file> <bytes> <destination>
  if [ "$2" -eq 0 ]; then
    : > "$3"
  else
    head -c "$2" "$1" > "$3"
  fi
}

snapshot_log() { # <file> <destination> <size-file>
  local file=$1 destination=$2 size_file=$3 parent base actual_parent
  parent=$(dirname "$file")
  base=$(basename "$file")
  (
    CDPATH='' cd -- "$parent" 2>/dev/null || exit 1
    actual_parent=$(pwd -P) || exit 1
    [ "$actual_parent" = "$parent" ] || exit 1
    perl -MFcntl=:DEFAULT -e '
      my ($path, $destination, $size_file, $offset, $max_bytes) = @ARGV;
      sysopen(my $source, $path, O_RDONLY | O_NOFOLLOW) or exit 1;
      my @stat = stat $source or exit 1;
      exit 1 unless -f _;
      my $size = $stat[7];
      exit 1 unless $size =~ /\A\d+\z/;
      my $limit = $size;
      my $bound = $offset + $max_bytes;
      $limit = $bound if $limit > $bound;
      open(my $output, ">", $destination) or exit 1;
      binmode $source;
      binmode $output;
      my $remaining = $limit;
      while ($remaining > 0) {
        my $wanted = $remaining > 65536 ? 65536 : $remaining;
        my $read = read($source, my $buffer, $wanted);
        exit 1 unless defined $read && $read > 0;
        print {$output} $buffer or exit 1;
        $remaining -= $read;
      }
      close $output or exit 1;
      open(my $size_output, ">", $size_file) or exit 1;
      print {$size_output} "$size\n" or exit 1;
      close $size_output or exit 1;
    ' "$base" "$destination" "$size_file" "$OFFSET" "$MAX_BYTES"
  )
}

delta_subsecond() { # <timestamp>: digits, one dot, and a nonzero fraction
  case "$1" in *[!0-9.]* | *.*.*) return 1 ;; esac
  case "$1" in [0-9]*.*[1-9]*) ;; *) return 1 ;; esac
}

# The file identity a snapshot was taken against: GNU and BSD stat spell the
# fields differently, so the poll selects the syntax once by capability. The
# mtime and ctime keep their subsecond fraction; a key without one (a stat or
# filesystem with whole-second timestamps) is discarded, because it cannot tell
# a same-second same-size rewrite apart, and that poll takes a full snapshot.
delta_log_key() { # <file>: sets KEY to "size:mtime:ctime:inode:device" or empty
  local rest mtime ctime
  if [ "$DELTA_KEY_GNU_STAT" = 1 ]; then
    KEY=$(stat -c '%s:%.9Y:%.9Z:%i:%d' "$1" 2>/dev/null) || KEY=
  else
    KEY=$(stat -f '%z:%Fm:%Fc:%i:%d' "$1" 2>/dev/null) || KEY=
  fi
  rest=${KEY#*:}
  mtime=${rest%%:*}
  rest=${rest#*:}
  ctime=${rest%%:*}
  delta_subsecond "$mtime" && delta_subsecond "$ctime" || KEY=
}

resolve_log() { # <relative-path>
  local rel=$1 home_real parent_real parent base path
  case "$rel" in ''|/*|*'//'*) die "log must be a nonempty relative path" ;; esac
  case "/$rel/" in */../*|*/./*) die "log traversal is not allowed: $rel" ;; esac
  case "$rel" in *$'\n'*|*$'\r'*|*$'\t'*) die "log path contains control characters" ;; esac
  home_real=$(CDPATH='' cd -- "$FM_HOME" 2>/dev/null && pwd -P) || die "FM_HOME is unavailable"
  parent=$(dirname "$rel")
  base=$(basename "$rel")
  parent_real=$(CDPATH='' cd -- "$FM_HOME/$parent" 2>/dev/null && pwd -P) || die "log parent is unavailable: $rel"
  case "$parent_real" in "$home_real"|"$home_real"/*) ;; *) die "log escapes FM_HOME: $rel" ;; esac
  path="$parent_real/$base"
  if [ -e "$path" ] || [ -L "$path" ]; then
    [ -f "$path" ] && [ ! -L "$path" ] || die "log is not a non-symlink regular file: $rel"
  fi
  printf '%s\n' "$path"
}

emit_break() { # <reason> <size> <actual-prefix>
  printf 'schema=fm-remote-delta.v1\n'
  printf 'status=continuity-broken\n'
  printf 'path=%s\n' "$REL"
  printf 'from_offset=%s\n' "$OFFSET"
  printf 'to_offset=%s\n' "$2"
  printf 'from_prefix_sha256=%s\n' "$PREFIX"
  printf 'to_prefix_sha256=%s\n' "$3"
  printf 'payload_sha256=%s\n' "$EMPTY_HASH"
  printf 'payload_bytes=0\n'
  printf 'reason=%s\n\n' "$1"
}

emit_delta() { # <to-offset> <to-hash> <payload-file>
  local to=$1 to_hash=$2 payload=$3 bytes payload_hash
  bytes=$(LC_ALL=C wc -c < "$payload" | tr -d ' ')
  payload_hash=$(sha256_file "$payload")
  printf 'schema=fm-remote-delta.v1\n'
  printf 'status=delta\n'
  printf 'path=%s\n' "$REL"
  printf 'from_offset=%s\n' "$OFFSET"
  printf 'to_offset=%s\n' "$to"
  printf 'from_prefix_sha256=%s\n' "$PREFIX"
  printf 'to_prefix_sha256=%s\n' "$to_hash"
  printf 'payload_sha256=%s\n' "$payload_hash"
  printf 'payload_bytes=%s\n' "$bytes"
  printf 'reason=\n\n'
  cat "$payload"
}

# Prove the cursor prefix is the current bytes with one leading emission stamp
# put back on a line starting within MAX_BYTES of the cursor, and stage a delta of only the complete lines after that shift.
# Writes $TMP/recover-kind as delta, wait, or bound. Returns 1 when the file
# is not that one deletion, which includes a hasher that cannot be loaded.
recover_leading_stamp() {
  rm -f -- "$TMP/recover-kind" "$TMP/recover-payload" "$TMP/recover-to" \
    "$TMP/recover-to-hash" "$TMP/recover-bound-hash"
  perl -MDigest::SHA - "$TMP/source" "$SIZE" "$OFFSET" "$PREFIX" "$MAX_BYTES" "$TMP" <<'PERL'
use strict;
use warnings;
use Digest::SHA qw(sha256_hex);

my ($path, $size, $offset, $want, $max_bytes, $out_dir) = @ARGV;
$size += 0;
$offset += 0;
$max_bytes += 0;
$want = lc $want;
exit 1 unless $want =~ /\A[0-9a-f]{64}\z/;
exit 1 if $offset < 1 || $size < 0 || $max_bytes < 1;

open my $in, '<:raw', $path or exit 1;
my $data = do { local $/; <$in> };
close $in;
$data = '' unless defined $data;
my $captured = length $data;

my $lo = $offset > $max_bytes ? $offset - $max_bytes : 0;
my $p = 0;
if ($lo > 0) {
  my $prev = index($data, "\n", $lo - 1);
  exit 1 if $prev < 0;
  $p = $prev + 1;
}
my $window = $p;
my @candidates;
START: while ($p < $offset && $p < $captured) {
  my $nl = index($data, "\n", $p);
  last START if $nl < 0;
  my $line_start = $p;
  $p = $nl + 1;
  my $line = substr($data, $line_start, $nl - $line_start);
  my $colon = index($line, ':');
  next START if $colon < 0;
  my $head = substr($line, 0, $colon);
  my @epochs = ($head =~ /\[at=([0-9]{1,12})\]/g);
  next START unless @epochs == 1;
  my $epoch = $epochs[0];
  next START if $epoch =~ /\A0\d/;
  my $tag_at = index($head, "[at=$epoch]");
  next START if $tag_at < 0;
  my $after = substr($head, $tag_at + length("[at=$epoch]"));
  next START if index($after, '[at=') >= 0;
  my $slen = length($epoch) + 1;
  next START if $slen > $offset || $size < $offset - $slen;
  # The original line, including its newline, sat entirely inside the cursor.
  next START if ($nl + 1 + $slen) > $offset;
  my $need = $offset - $slen;
  next START if $need > $captured || $line_start > $need;
  push @candidates, [$line_start, $epoch, $need];
}
exit 1 unless @candidates;

my $base = Digest::SHA->new(256);
$base->add(substr($data, 0, $window));
my $stamp_len = 0;
for my $candidate (reverse @candidates) {
  my ($line_start, $epoch, $need) = @$candidate;
  my $try = $base->clone;
  $try->add(substr($data, $window, $line_start - $window));
  $try->add($epoch . ' ');
  $try->add(substr($data, $line_start, $need - $line_start));
  next unless $try->hexdigest eq $want;
  $stamp_len = length($epoch) + 1;
  last;
}
exit 1 unless $stamp_len;

my $shifted = $offset - $stamp_len;
my $window_end = $shifted + $max_bytes;
$window_end = $captured if $window_end > $captured;
my $region = substr($data, $shifted, $window_end - $shifted);
my $complete = 0;
my $scan = 0;
while (1) {
  my $nl = index($region, "\n", $scan);
  last if $nl < 0;
  $complete = $nl + 1;
  $scan = $complete;
}

sub write_text {
  my ($name, $text) = @_;
  open my $out, '>', "$out_dir/$name" or exit 1;
  print {$out} $text or exit 1;
  close $out or exit 1;
}

if ($complete == 0) {
  if (($size - $shifted) >= $max_bytes) {
    write_text('recover-kind', "bound\n");
    write_text('recover-bound-hash', sha256_hex(substr($data, 0, $shifted)) . "\n");
  } else {
    write_text('recover-kind', "wait\n");
  }
  exit 0;
}

my $payload = substr($region, 0, $complete);
my $to = $shifted + $complete;
write_text('recover-kind', "delta\n");
write_text('recover-to', "$to\n");
write_text('recover-to-hash', sha256_hex(substr($data, 0, $to)) . "\n");
open my $raw, '>:raw', "$out_dir/recover-payload" or exit 1;
print {$raw} $payload or exit 1;
close $raw or exit 1;
exit 0;
PERL
}

# Prove the cursor prefix is the live bytes before one already-mirrored line,
# plus that line, and stage a delta of the different line and the complete
# lines after it. Writes $TMP/recover-kind as delta, replaced-wait, or bound.
# Returns 1 when this sample is not that one replacement.
recover_replaced_line() {
  [ -n "$OLD_LINE" ] || return 1
  case "$OLD_LINE" in *$'\n'*) return 1 ;; esac
  rm -f -- "$TMP/recover-kind" "$TMP/recover-payload" "$TMP/recover-to" \
    "$TMP/recover-to-hash" "$TMP/recover-bound-hash"
  FM_DELTA_OLD_LINE="$OLD_LINE" perl -MDigest::SHA - "$TMP/source" "$SIZE" "$OFFSET" "$PREFIX" "$MAX_BYTES" "$TMP" <<'PERL'
use strict;
use warnings;
use Digest::SHA qw(sha256_hex);

my ($path, $size, $offset, $want, $max_bytes, $out_dir) = @ARGV;
$size += 0;
$offset += 0;
$max_bytes += 0;
$want = lc $want;
exit 1 unless $want =~ /\A[0-9a-f]{64}\z/;
exit 1 if $offset < 1 || $size < 0 || $max_bytes < 1;
my $old_line = $ENV{FM_DELTA_OLD_LINE};
exit 1 unless defined $old_line && length $old_line;
exit 1 if index($old_line, "\n") >= 0;
my $old = $old_line . "\n";
my $old_len = length $old;
exit 1 if $old_len > $offset;
my $line_start = $offset - $old_len;
exit 1 if $size < $line_start;

open my $in, '<:raw', $path or exit 1;
my $data = do { local $/; <$in> };
close $in;
$data = '' unless defined $data;
my $captured = length $data;
exit 1 if $line_start > $captured;
exit 1 unless sha256_hex(substr($data, 0, $line_start) . $old) eq $want;

my $window_end = $line_start + $max_bytes;
$window_end = $captured if $window_end > $captured;
my $region = substr($data, $line_start, $window_end - $line_start);
my $complete = 0;
my $scan = 0;
while (1) {
  my $nl = index($region, "\n", $scan);
  last if $nl < 0;
  $complete = $nl + 1;
  $scan = $complete;
}

sub write_text {
  my ($name, $text) = @_;
  open my $out, '>', "$out_dir/$name" or exit 1;
  print {$out} $text or exit 1;
  close $out or exit 1;
}

if ($complete == 0) {
  if (($size - $line_start) >= $max_bytes) {
    write_text('recover-kind', "bound\n");
    write_text('recover-bound-hash', sha256_hex(substr($data, 0, $line_start)) . "\n");
  } else {
    write_text('recover-kind', "replaced-wait\n");
  }
  exit 0;
}

my $first_nl = index($region, "\n");
exit 1 if $first_nl < 0;
exit 1 if substr($region, 0, $first_nl + 1) eq $old;

my $payload = substr($region, 0, $complete);
my $to = $line_start + $complete;
write_text('recover-kind', "delta\n");
write_text('recover-to', "$to\n");
write_text('recover-to-hash', sha256_hex(substr($data, 0, $to)) . "\n");
open my $raw, '>:raw', "$out_dir/recover-payload" or exit 1;
print {$raw} $payload or exit 1;
close $raw or exit 1;
exit 0;
PERL
}

[ "$#" -ge 3 ] && [ "$#" -le 5 ] || usage
REL=$1
OFFSET=$2
PREFIX=$3
WAIT=${4:-55}
OLD_LINE=${5:-}
case "$OFFSET" in ''|*[!0-9]*) die "offset must be a nonnegative integer" ;; esac
case "$PREFIX" in *[!A-Fa-f0-9]*|'') die "prefix-sha256 must be hexadecimal" ;; esac
[ "${#PREFIX}" -eq 64 ] || die "prefix-sha256 must be 64 hexadecimal characters"
PREFIX=$(printf '%s' "$PREFIX" | tr 'A-F' 'a-f')
case "$WAIT" in ''|*[!0-9]*) die "wait-seconds must be a nonnegative integer" ;; esac
[ "$WAIT" -le 300 ] || die "wait-seconds exceeds the 300-second safety bound"
case "$MAX_BYTES" in ''|*[!0-9]*|0) die "FM_REMOTE_DELTA_MAX_BYTES must be a positive integer" ;; esac
[ "$MAX_BYTES" -le 1048576 ] || die "FM_REMOTE_DELTA_MAX_BYTES exceeds the safety bound"

LOG=$(resolve_log "$REL")
TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-remote-delta.XXXXXX") || die "cannot create delta staging directory"
trap 'rm -rf -- "$TMP"' EXIT
trap 'exit 75' TERM
: > "$TMP/empty"
EMPTY_HASH=$(sha256_file "$TMP/empty")
if stat -c '%s' / >/dev/null 2>&1; then DELTA_KEY_GNU_STAT=1; else DELTA_KEY_GNU_STAT=0; fi
START=$SECONDS
LAST_KEY=
RECOVER=
while :; do
  if [ -e "$LOG" ] || [ -L "$LOG" ]; then
    [ -f "$LOG" ] && [ ! -L "$LOG" ] || die "log changed into an unsafe file: $REL"
    delta_log_key "$LOG"
    if [ -z "$KEY" ] || [ "$KEY" != "$LAST_KEY" ]; then
      RECOVER=
      snapshot_log "$LOG" "$TMP/source" "$TMP/size" \
        || die "log could not be captured safely: $REL"
      # The gate stat precedes the capture, so the snapshot is at least as new
      # as its key: a log that moved in between changes the key and is
      # captured again on the next poll, never mistaken for stable.
      LAST_KEY=$KEY
      IFS= read -r SIZE < "$TMP/size"
      CONTINUITY=ok
      if [ "$SIZE" -lt "$OFFSET" ]; then
        CONTINUITY=short
      else
        copy_prefix "$TMP/source" "$OFFSET" "$TMP/prefix"
        ACTUAL=$(sha256_file "$TMP/prefix")
        if [ "$ACTUAL" != "$PREFIX" ]; then
          CONTINUITY=changed
        fi
      fi
      if [ "$CONTINUITY" != ok ]; then
        RECOVER='break'
        if recover_leading_stamp; then
          IFS= read -r RECOVER < "$TMP/recover-kind"
        fi
        if [ "$RECOVER" != delta ] && [ "$RECOVER" != bound ] && [ "$RECOVER" != wait ] \
          && [ -n "$OLD_LINE" ] && recover_replaced_line; then
          IFS= read -r RECOVER < "$TMP/recover-kind"
        fi
        case "$RECOVER" in
          delta)
            IFS= read -r TO < "$TMP/recover-to"
            IFS= read -r TO_HASH < "$TMP/recover-to-hash"
            emit_delta "$TO" "$TO_HASH" "$TMP/recover-payload"
            exit 0
            ;;
          bound)
            IFS= read -r ACTUAL < "$TMP/recover-bound-hash"
            emit_break line-exceeds-bound "$SIZE" "$ACTUAL"
            exit 0
            ;;
          wait|replaced-wait) ;;
          *)
            if [ "$CONTINUITY" = short ]; then
              copy_prefix "$TMP/source" "$SIZE" "$TMP/prefix"
              ACTUAL=$(sha256_file "$TMP/prefix")
              emit_break truncated "$SIZE" "$ACTUAL"
            else
              emit_break prefix-changed "$SIZE" "$ACTUAL"
            fi
            exit 0
            ;;
        esac
      elif [ "$SIZE" -gt "$OFFSET" ]; then
        tail -c "+$((OFFSET + 1))" "$TMP/source" | head -c "$MAX_BYTES" > "$TMP/chunk" || true
        COMPLETE_BYTES=$(LC_ALL=C od -An -v -tu1 "$TMP/chunk" | awk '
          { for (i = 1; i <= NF; i++) { bytes++; if ($i == 10) complete=bytes } }
          END { print complete + 0 }
        ')
        if [ "$COMPLETE_BYTES" -eq 0 ]; then : > "$TMP/payload"; else head -c "$COMPLETE_BYTES" "$TMP/chunk" > "$TMP/payload"; fi
        BYTES=$(LC_ALL=C wc -c < "$TMP/payload" | tr -d ' ')
        if [ "$BYTES" -gt 0 ]; then
          TO=$((OFFSET + BYTES))
          copy_prefix "$TMP/source" "$TO" "$TMP/to-prefix"
          TO_HASH=$(sha256_file "$TMP/to-prefix")
          emit_delta "$TO" "$TO_HASH" "$TMP/payload"
          exit 0
        fi
        if [ $((SIZE - OFFSET)) -ge "$MAX_BYTES" ]; then
          emit_break line-exceeds-bound "$SIZE" "$ACTUAL"
          exit 0
        fi
      fi
    fi
  elif [ "$OFFSET" -ne 0 ] || [ "$PREFIX" != "$EMPTY_HASH" ]; then
    emit_break missing 0 "$EMPTY_HASH"
    exit 0
  fi
  if [ $((SECONDS - START)) -ge "$WAIT" ]; then
    if [ "$RECOVER" = replaced-wait ]; then
      if [ "$SIZE" -lt "$OFFSET" ]; then
        copy_prefix "$TMP/source" "$SIZE" "$TMP/prefix"
        ACTUAL=$(sha256_file "$TMP/prefix")
        emit_break truncated "$SIZE" "$ACTUAL"
      else
        emit_break prefix-changed "$SIZE" "$ACTUAL"
      fi
      exit 0
    fi
    exit 75
  fi
  sleep "$POLL_SECONDS"
done
