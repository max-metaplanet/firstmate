#!/usr/bin/env bash
# tests/fm-fork-free-helpers.test.sh - the pure-bash stand-ins that the
# watcher, drain, and lock paths use instead of forking small external
# commands every cycle. Each case compares the helper with the command it
# replaces on the same input, under every available Bash (stock macOS
# /bin/bash 3.2 included) and under both the C and a UTF-8 locale, so an edge
# case where the two disagree fails here instead of drifting silently.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-fork-free-helpers)

# Every distinct Bash this host offers: the running one, stock /bin/bash, and
# whatever `bash` resolves to on PATH.
test_interpreters() {
  local seen='' candidate version
  for candidate in "${BASH:-bash}" /bin/bash "$(command -v bash 2>/dev/null || true)"; do
    [ -n "$candidate" ] && [ -x "$candidate" ] || continue
    # shellcheck disable=SC2016 # Expanded by the candidate interpreter.
    version=$("$candidate" -c 'printf "%s" "$BASH_VERSION"' 2>/dev/null) || continue
    case " $seen " in *" $version "*) continue ;; esac
    seen="$seen $version"
    printf '%s\n' "$candidate"
  done
}

test_locales() {
  printf '%s\n' C
  if locale -a 2>/dev/null | grep -qx 'C.UTF-8'; then
    printf '%s\n' C.UTF-8
  elif locale -a 2>/dev/null | grep -qx 'en_US.UTF-8'; then
    printf '%s\n' en_US.UTF-8
  fi
}

# Run <script> under every interpreter and locale; any output is a mismatch
# report and fails the case.
run_everywhere() {  # <label> <script> [args...]
  local label=$1 script=$2 interpreter loc out
  shift 2
  while IFS= read -r interpreter; do
    while IFS= read -r loc; do
      out=$(LC_ALL=$loc FM_STATE_OVERRIDE="$TMP_ROOT/state" "$interpreter" "$script" "$ROOT" "$@" 2>&1) \
        || fail "$label failed under $interpreter ($loc): $out"
      [ -z "$out" ] || fail "$label differs under $interpreter ($loc):"$'\n'"$out"
    done < <(test_locales)
  done < <(test_interpreters)
}

test_path_helpers_match_dirname_and_basename() {
  local script="$TMP_ROOT/paths.sh" cases="$TMP_ROOT/path-cases"
  # NUL-separated so paths may carry newlines.
  printf '%s\0' '' / // /// a a/ a// /a /a/ //a a/b a/b/ a//b //a//b/ . .. ./ ../x \
    'a b/c d' 'a/-x' $'a\n/b' $'a/b\n' $'x\n' $'a/b\n\n' $'a\n' $'\n' $'/\n' $'a/\n/' \
    'state/crew.status' '/abs/state/.seen-x' 'x.y.z/.status' '*/?' 'a/[b]' \
    $'caf\xc3\xa9/\xc3\xbc.status' $'\xff\xfe/\xc3.x' $'a/\xff/' > "$cases"
  cat > "$script" <<'SH'
. "$1/bin/fm-wake-lib.sh"
while IFS= read -r -d '' p; do
  fm_dirname_to got "$p"
  want=$(dirname -- "$p")
  [ "$got" = "$want" ] || printf 'dirname %q: helper %q, command %q\n' "$p" "$got" "$want"
  fm_basename_to got "$p"
  want=$(basename -- "$p")
  [ "$got" = "$want" ] || printf 'basename %q: helper %q, command %q\n' "$p" "$got" "$want"
done < "$2"
SH
  run_everywhere "path helpers" "$script" "$cases"
  pass "fm_dirname_to and fm_basename_to match dirname and basename on every edge case"
}

test_epoch_helper_matches_date_and_never_forks_more() {
  local script="$TMP_ROOT/epoch.sh" shim="$TMP_ROOT/epoch-shim" log="$TMP_ROOT/epoch-date.log"
  mkdir -p "$shim"
  cat > "$shim/date" <<SH
#!/bin/sh
printf 'date\n' >> "$log"
exec $(command -v date) "\$@"
SH
  chmod +x "$shim/date"
  # shellcheck disable=SC2016 # Expanded by the child shell.
  printf '%s\n' '. "$1/bin/fm-wake-lib.sh"' \
    'PATH="$2:$PATH"' \
    ': > "$3"' \
    'before=$(/bin/date +%s)' \
    'fm_epoch_seconds_to now' \
    'after=$(/bin/date +%s)' \
    'case "$now" in ""|*[!0-9]*) printf "not epoch seconds: %q\n" "$now" ;; esac' \
    '[ "$now" -ge "$before" ] && [ "$now" -le "$after" ] || printf "%s outside [%s, %s]\n" "$now" "$before" "$after"' \
    'forks=$(grep -c . "$3" || true)' \
    'if [ "${BASH_VERSINFO[0]}" -gt 4 ] || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -ge 2 ]; }; then' \
    '  [ "$forks" -eq 0 ] || printf "bash %s ran date %s times\n" "$BASH_VERSION" "$forks"' \
    'else' \
    '  [ "$forks" -eq 1 ] || printf "bash %s ran date %s times, not exactly once\n" "$BASH_VERSION" "$forks"' \
    'fi' > "$script"
  run_everywhere "epoch helper" "$script" "$shim" "$log"
  pass "fm_epoch_seconds_to reads the clock like date +%s and forks date at most as often"
}

test_signal_seen_path_and_lock_abs_path_are_unchanged() {
  local script="$TMP_ROOT/seen.sh" dir="$TMP_ROOT/lockdir"
  mkdir -p "$dir/sub" "$TMP_ROOT/state"
  cat > "$script" <<'SH'
. "$1/bin/fm-wake-lib.sh"
state=$2
for f in "$state/crew.status" "$state/a.b.c.status" "state/x.status" ".status" \
  "$state/crew.turn-ended" "$state/dir/" "x" "a.b/" "/" "$state/q.status.bak"; do
  got=$(fm_wake_signal_seen_path "$state" "$f")
  case "$f" in
    *.status)
      task=$(basename "$f"); task=${task%.status}
      want=$(printf '%s/.seen-%s' "$state" "$(printf '%s.status' "$task" | tr '.' '_')")
      ;;
    *) want=$(printf '%s/.seen-%s' "$state" "$(basename "$f" | tr '.' '_')") ;;
  esac
  [ "$got" = "$want" ] || printf 'seen path %q: helper %q, commands %q\n' "$f" "$got" "$want"
done
cd "$3" || exit 1
for p in "$3/x.lock" "$3/sub/x.lock" "$3//sub//x.lock" "sub/x.lock" "x.lock" "sub/x.lock/" "./sub/../x.lock"; do
  got=$(fm_lock_abs_path "$p")
  want="$(cd "$(dirname "$p")" && pwd -P)/$(basename "$p")"
  [ "$got" = "$want" ] || printf 'lock path %q: helper %q, commands %q\n' "$p" "$got" "$want"
done
SH
  run_everywhere "seen and lock paths" "$script" "$TMP_ROOT/state" "$dir"
  pass "signal seen paths and absolute lock paths are byte-identical to the dirname/basename/tr forms"
}

test_recovery_marker_read_accepts_exactly_one_newline() {
  local script="$TMP_ROOT/marker.sh" cases="$TMP_ROOT/marker-cases"
  mkdir -p "$cases"
  printf 'pending:handling:g1\n' > "$cases/one"
  printf 'pending:handling:g1' > "$cases/unterminated"
  printf 'pending:handling:g1\npending:handling:g2\n' > "$cases/two"
  printf 'pending:handling:g1\ntrailing-partial' > "$cases/partial-second"
  : > "$cases/empty"
  printf '\n' > "$cases/blank"
  printf 'announced:downtime:g\0x\n' > "$cases/nul"
  printf 'acked:handling:g1\r\n' > "$cases/crlf"
  printf 'pending:handling:g1\n\n' > "$cases/blank-second"
  cat > "$script" <<'SH'
. "$1/bin/fm-wake-lib.sh"
for marker in "$2"/*; do
  # The replaced reference: one newline byte by wc -l, then the same token read.
  want=reject
  if [ "$(wc -l < "$marker" | tr -d '[:space:]')" = 1 ] && IFS= read -r line < "$marker"; then
    case "$line" in
      pending:handling:*|pending:downtime:*|announced:handling:*|announced:downtime:*|acked:handling:*|acked:downtime:*)
        case "${line##*:}" in ''|*[!A-Za-z0-9._-]*) ;; *) want="accept:$line" ;; esac ;;
    esac
  fi
  if fm_recovery_marker_read "$marker"; then got="accept:$FM_RECOVERY_MARKER_TOKEN"; else got=reject; fi
  [ "$got" = "$want" ] || printf 'marker %s: helper %q, reference %q\n' "${marker##*/}" "$got" "$want"
done
SH
  run_everywhere "recovery marker read" "$script" "$cases"
  pass "recovery marker reads accept exactly the one-line records wc -l accepted"
}

test_window_to_task_matches_the_meta_pipeline() {
  local script="$TMP_ROOT/window.sh" state="$TMP_ROOT/window-state"
  mkdir -p "$state"
  printf 'window=sess:w1\nbackend=tmux\n' > "$state/alpha.meta"
  printf 'window=old\nwindow=sess:w2\n' > "$state/beta.meta"
  printf 'terminal=term-3\nwindow=\n' > "$state/gamma.meta"
  printf 'window=a=b=c' > "$state/delta.meta"
  printf 'window=sess:w5\r\n' > "$state/eps.meta"
  printf ' window=sess:w6\nwindow= sess:w6 \n' > "$state/zeta.meta"
  printf 'terminal=t7\nterminal=\n' > "$state/eta.meta"
  mkdir -p "$state/dir.meta"
  printf 'window=sess:w9\n' > "$state/theta.meta"
  chmod 000 "$state/theta.meta"
  cat > "$script" <<'SH'
. "$1/bin/fm-classify-lib.sh"
state=$2
reference() {  # the replaced grep | tail -1 | cut -d= -f2- lookup
  local w=$1 meta mw mt t
  for meta in "$state"/*.meta; do
    [ -e "$meta" ] || continue
    mw=$(grep '^window=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
    mt=$(grep '^terminal=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
    [ "$mw" = "$w" ] || [ "$mt" = "$w" ] || continue
    t=$(basename "$meta"); printf '%s' "${t%.meta}"; return 0
  done
  t="${w##*:}"; t="${t#fm-}"; printf '%s' "$t"
}
for w in sess:w1 old sess:w2 term-3 '' a=b=c a sess:w5 $'sess:w5\r' ' sess:w6 ' sess:w6 t7 sess:w9 sess:fm-fallback-x unknown; do
  got=$(window_to_task "$w" "$state")
  want=$(reference "$w")
  [ "$got" = "$want" ] || printf 'window %q: helper %q, pipeline %q\n' "$w" "$got" "$want"
done
SH
  run_everywhere "window_to_task" "$script" "$state"
  chmod 600 "$state/theta.meta"
  pass "window_to_task resolves every recorded window exactly as the grep/tail/cut pipeline did"
}

test_classify_stat_helpers_read_the_kernel_name_once() {
  local script="$TMP_ROOT/uname.sh" shim="$TMP_ROOT/uname-shim" log="$TMP_ROOT/uname.log" file="$TMP_ROOT/sized"
  mkdir -p "$shim"
  cat > "$shim/uname" <<SH
#!/bin/sh
printf 'uname\n' >> "$log"
exec $(command -v uname) "\$@"
SH
  chmod +x "$shim/uname"
  printf 'caf\303\251 bytes\n' > "$file"
  cat > "$script" <<'SH'
PATH="$2:$PATH"
: > "$3"
. "$1/bin/fm-classify-lib.sh"
for _ in 1 2 3 4 5; do
  size=$(_fm_status_file_size "$4")
  [ "$size" = "$(LC_ALL=C wc -c < "$4" | tr -d ' ')" ] || printf 'size %q\n' "$size"
  mtime=$(_fm_status_file_mtime "$4")
  case "$mtime" in ''|*[!0-9]*) printf 'mtime %q\n' "$mtime" ;; esac
  _fm_open_decisions_file_ident "$4" >/dev/null || printf 'identity unreadable\n'
done
calls=$(grep -c . "$3" || true)
[ "$calls" -eq 1 ] || printf 'uname ran %s times for 15 stat reads\n' "$calls"
SH
  run_everywhere "classify stat helpers" "$script" "$shim" "$log" "$file"
  pass "classify stat helpers resolve the kernel name once per process"
}

test_file_read_helper_matches_cat() {
  local script="$TMP_ROOT/read.sh" cases="$TMP_ROOT/read-cases"
  mkdir -p "$cases"
  printf 'one line\n' > "$cases/plain"
  printf 'no trailing newline' > "$cases/bare"
  printf 'a\nb\n\n\n' > "$cases/many-newlines"
  printf '\n' > "$cases/only-newline"
  : > "$cases/empty"
  printf 'leading and  inner   spaces \t and tabs\n' > "$cases/spacing"
  printf 'caf\xc3\xa9 \xff\xfe\n' > "$cases/high-bytes"
  printf 'secret\n' > "$cases/unreadable"
  chmod 000 "$cases/unreadable"
  mkdir -p "$cases/a-directory"
  cat > "$script" <<'SH'
. "$1/bin/fm-wake-lib.sh"
for f in "$2"/* "$2/missing"; do
  # The replaced reference, including the status a caller branches on.
  want=$(cat "$f" 2>/dev/null || true)
  if [ -f "$f" ] && [ -r "$f" ]; then want_rc=0; else want_rc=1; fi
  got_rc=0
  fm_read_file_to got "$f" || got_rc=1
  [ "$got" = "$want" ] || printf 'read %s: helper %q, cat %q\n' "${f##*/}" "$got" "$want"
  [ "$got_rc" = "$want_rc" ] || printf 'read %s: helper status %s, expected %s\n' "${f##*/}" "$got_rc" "$want_rc"
done
SH
  run_everywhere "file read helper" "$script" "$cases"
  chmod 600 "$cases/unreadable"
  pass "fm_read_file_to returns what cat returned, including for empty, unreadable, missing and non-regular files"
}

test_hex_encoder_matches_od() {
  local script="$TMP_ROOT/hex.sh" cases="$TMP_ROOT/hex-cases"
  # NUL-separated so a case may carry newlines and high bytes.
  printf '%s\0' '' '0' '12345' 'readable' 'symlink' 'size-error' 'identity-error' \
    'weak:16777234:5551' 'strong:16777234:5551:Oct 10 19:25:33 2026' \
    'Regular File:100644' 'Symbolic Link:120755' 'regular file:81a4' \
    'a b/c d.status' "a'b\"c\\\\d" '%s %d %q' $'tab\there' $'line\nbreak' \
    $'caf\xc3\xa9' $'\xff\xfe\x01\x7f' '-' > "$cases"
  cat > "$script" <<'SH'
. "$1/bin/fm-classify-lib.sh"
while IFS= read -r -d '' text; do
  # The replaced reference pipeline.
  want=$(printf '%s' "$text" | LC_ALL=C od -An -v -tx1 | tr -d ' \n')
  _fm_hex_encode_to got "$text"
  [ "$got" = "$want" ] || printf 'hex %q: helper %q, od %q\n' "$text" "$got" "$want"
done < "$2"
SH
  run_everywhere "hex encoder" "$script" "$cases"
  pass "_fm_hex_encode_to produces the bytes od -An -v -tx1 | tr -d ' \\n' produced"
}

test_status_signature_matches_the_per_field_readers() {
  local script="$TMP_ROOT/sig.sh" dir="$TMP_ROOT/sig-files"
  mkdir -p "$dir"
  printf 'working: a\ndone: b\n' > "$dir/plain.status"
  : > "$dir/empty.status"
  ln -sf plain.status "$dir/link.status"
  ln -sf nowhere "$dir/broken.status"
  mkdir -p "$dir/dir.status"
  printf 'x\n' > "$dir/unreadable.status"
  chmod 000 "$dir/unreadable.status"
  printf 'y\n' > "$dir/a spaced name.status"
  cat > "$script" <<'SH'
. "$1/bin/fm-classify-lib.sh"
# The replaced construction: one stat call per field, then the od pipeline.
reference() {
  local f=$1 path_state link_target=- size ident access kind
  path_state=$(_status_observed_path_state "$f") || path_state=stat-error
  if [ -L "$f" ]; then
    link_target=$(readlink "$f" 2>/dev/null) || link_target=readlink-error
    kind=symlink
  elif [ ! -e "$f" ]; then kind=absent
  elif [ ! -f "$f" ]; then kind=nonregular
  elif [ -r "$f" ]; then kind=readable
  else kind=unreadable
  fi
  size=$(_fm_status_file_size "$f") || size='size-error'
  size=${size//[[:space:]]/}
  case "$size" in ''|*[!0-9]*) size='size-error' ;; esac
  ident=$(_fm_open_decisions_file_ident "$f") || ident=identity-error
  [ -n "$ident" ] || ident=identity-error
  if [ -r "$f" ]; then access=readable; else access=unreadable; fi
  printf 'r1:%s' "$(printf '%s\0%s\0%s\0%s\0%s\0%s' \
    "$size" "$ident" "$path_state" "$link_target" "$access" "$kind" \
    | LC_ALL=C od -An -v -tx1 | tr -d ' \n')"
}
for f in "$2"/*.status "$2/missing.status"; do
  want=$(reference "$f")
  got=$(status_observed_signature "$f")
  [ "$got" = "$want" ] || printf 'signature %s: helper %q, per-field form %q\n' "${f##*/}" "$got" "$want"
  # A caller that already knows the size and identity must get the same answer.
  got=$(status_observed_signature "$f" "$(_fm_status_file_size "$f" 2>/dev/null)" "$(_fm_open_decisions_file_ident "$f" 2>/dev/null)")
  [ -n "$got" ] || printf 'signature %s: empty with supplied size and identity\n' "${f##*/}"
done
SH
  run_everywhere "status signature" "$script" "$dir"
  chmod 600 "$dir/unreadable.status"
  pass "status_observed_signature is byte-identical to the four-stat, od-piped form it replaced"
}

test_watcher_termination_during_wait() {
  # Bash's read timer can unwind native fatal-signal EXIT cleanup. Exercise the
  # real watcher and its recovery cleanup, with TERM late in the poll wait.
  python3 - "$ROOT" "$TMP_ROOT" "$BASH" <<'PYTEST' || fail "watcher wait broke TERM cleanup"
import os
import pathlib
import re
import signal
import subprocess
import sys
import time

root, tmp, interpreter = sys.argv[1:]
for attempt in range(8):
    home = pathlib.Path(tmp) / ("wait-term-%d" % attempt)
    for name in ("state", "config", "shim"):
        (home / name).mkdir(parents=True)
    tmux = home / "shim" / "tmux"
    tmux.write_text("#!/bin/sh\nexit 0\n")
    tmux.chmod(0o755)
    env = {k: v for k, v in os.environ.items() if not k.startswith("FM_")}
    env.update(FM_HOME=str(home), FM_STATE_OVERRIDE=str(home / "state"),
               FM_POLL="1", FM_CHECK_INTERVAL="999999", FM_HEARTBEAT="999999",
               FM_HOME_SUMMARY_INTERVAL="999999",
               PATH=str(home / "shim") + os.pathsep + os.environ["PATH"])
    trace_path = home / "trace"
    with trace_path.open("w") as trace:
        # Trace only synchronizes signal delivery with an executing wait; the
        # assertions below concern exit, diagnostics, and released ownership.
        env.pop("BASH_XTRACEFD", None)
        proc = subprocess.Popen([interpreter, "-x", root + "/bin/fm-watch.sh"],
                                env=env, stdout=subprocess.DEVNULL, stderr=trace,
                                start_new_session=True)
        try:
            deadline = time.monotonic() + 20
            while time.monotonic() < deadline:
                if re.search(r"\+ (?:read -r -t 1 -u |sleep 1\n)", trace_path.read_text(errors="replace")):
                    break
                if proc.poll() is not None:
                    raise AssertionError("watcher exited before its wait")
                time.sleep(0.01)
            else:
                raise AssertionError("watcher never reached its poll wait")
            time.sleep(0.8 + (attempt % 3) * 0.05)
            proc.send_signal(signal.SIGTERM)
            proc.wait(timeout=5)
            assert proc.returncode in (-signal.SIGTERM, 128 + signal.SIGTERM), proc.returncode
            assert "return: can only" not in trace_path.read_text(errors="replace"), "invalid return during cleanup"
            assert not (home / "state" / ".watch.lock").is_symlink(), "watcher retained ownership"
        finally:
            if proc.poll() is None:
                os.killpg(proc.pid, signal.SIGKILL)
                proc.wait()
PYTEST
  pass "watcher exits on TERM during its poll wait and releases ownership"
}

test_window_fields_match_the_meta_pipeline() {
  local script="$TMP_ROOT/fields.sh" state="$TMP_ROOT/fields-state"
  mkdir -p "$state"
  printf 'window=sess:w1\nbackend=herdr\nharness=codex\nkind=secondmate\n' > "$state/alpha.meta"
  printf 'window=sess:w2\n' > "$state/beta.meta"
  printf 'window=sess:w3\nbackend=\nharness=\nkind=\n' > "$state/gamma.meta"
  printf 'terminal=term-4\nbackend=orca\nkind=scout\nharness=claude\n' > "$state/delta.meta"
  cat > "$script" <<'SH'
FM_STATE_OVERRIDE=$2
export FM_STATE_OVERRIDE
# fm-watch.sh returns at its source guard, so this loads its helpers only.
. "$1/bin/fm-watch.sh"
state=$2
# The replaced reference: one grep | cut pipeline per field.
field() {  # <meta> <key> <default>
  local v
  v=$(grep "^$2=" "$1" 2>/dev/null | cut -d= -f2- || true)
  [ -n "$v" ] || v=$3
  printf '%s' "$v"
}
check() {  # <window> <meta-or-empty>
  local w=$1 meta=$2 want_kind want_backend want_harness
  if [ -n "$meta" ]; then
    want_kind=$(field "$meta" kind ship)
    want_backend=$(field "$meta" backend tmux)
    want_harness=$(field "$meta" harness '')
  else
    want_kind=unknown; want_backend=tmux; want_harness=''
  fi
  [ "$(window_kind "$w")" = "$want_kind" ] \
    || printf 'kind %q: helper %q, pipeline %q\n' "$w" "$(window_kind "$w")" "$want_kind"
  [ "$(window_backend "$w")" = "$want_backend" ] \
    || printf 'backend %q: helper %q, pipeline %q\n' "$w" "$(window_backend "$w")" "$want_backend"
  [ "$(window_harness "$w")" = "$want_harness" ] \
    || printf 'harness %q: helper %q, pipeline %q\n' "$w" "$(window_harness "$w")" "$want_harness"
  [ "$(window_key "$w")" = "$(printf '%s' "$w" | tr ':/.' '___')" ] \
    || printf 'key %q: helper %q\n' "$w" "$(window_key "$w")"
}
# Every window, then the same windows again in a different order: a reused
# resolution must never answer for the window it was not taken for.
for pair in "sess:w1 $state/alpha.meta" "sess:w2 $state/beta.meta" \
            "sess:w3 $state/gamma.meta" "term-4 $state/delta.meta" "sess:absent " \
            "sess:w2 $state/beta.meta" "sess:w1 $state/alpha.meta" "sess:absent "; do
  check "${pair%% *}" "${pair#* }"
done
# A window whose metadata changed between polls must read the new value.
printf 'window=sess:w2\nbackend=zellij\nkind=scout\n' > "$state/beta.meta"
window_fields_forget
[ "$(window_backend sess:w2)" = zellij ] \
  || printf 'changed backend: helper %q, expected zellij\n' "$(window_backend sess:w2)"
[ "$(window_kind sess:w2)" = scout ] \
  || printf 'changed kind: helper %q, expected scout\n' "$(window_kind sess:w2)"
# The output-variable form of the key derives the same string without a subshell.
window_key 'sess:fm-a.b/c' got
[ "$got" = "$(window_key 'sess:fm-a.b/c')" ] || printf 'key output form %q\n' "$got"
SH
  run_everywhere "window fields" "$script" "$state"
  pass "window metadata fields match the grep/cut pipeline, never answer for another window, and follow a changed meta"
}

# Every reader the per-task snapshot and crew-state paths call now has an
# <out-var> twin beside its printing form. The twin is only safe if it answers
# exactly what the printing form answered through $( ), status included, so
# each pair is compared here on the same inputs rather than spot-checked.
test_out_var_readers_match_their_printing_forms() {
  local script="$TMP_ROOT/outvar.sh" dir="$TMP_ROOT/outvar"
  mkdir -p "$dir"
  printf 'backend=herdr\nwindow=sess:w1\nkind=ship\nspawn_gen=s1\n' > "$dir/alpha.meta"
  printf 'backend=orca\nterminal=term-2\nwindow=sess:w2\n' > "$dir/beta.meta"
  printf 'window=sess:w3\n' > "$dir/gamma.meta"
  printf 'kind=scout\n' > "$dir/delta.meta"
  printf 'window=a=b=c\nwindow=last=wins\n' > "$dir/eps.meta"
  printf '%s\n' \
    'needs-decision [key=api-shape] [at=1700000000]: REST or gRPC?' \
    'working [at=1700000100]: building' \
    'blocked: [key=credential] the token expired' \
    'resolved [key=api-shape]: captain picked REST' \
    'paused [at=17:00]: waiting on CI' \
    'done [at=bad]: shipped' \
    'needs-decision which base branch' \
    'needs-decision [key=bad slug]: malformed' \
    'plain prose with no verb' \
    '' > "$dir/task.status"
  cat > "$script" <<'SH'
. "$1/bin/fm-classify-lib.sh"
. "$1/bin/fm-backend.sh"
. "$1/bin/fm-nm-run-lib.sh"
dir=$2
compare() {  # <label> <printed> <printed-rc> <got> <got-rc>
  [ "$2" = "$4" ] || printf '%s: out-var %q, printing form %q\n' "$1" "$4" "$2"
  [ "$3" = "$5" ] || printf '%s: out-var status %s, printing form %s\n' "$1" "$5" "$3"
}
while IFS= read -r line || [ -n "$line" ]; do
  want=$(status_line_note "$line"); want_rc=$?
  got=''; status_line_note_to got "$line"; got_rc=$?
  compare "note ${line}" "$want" "$want_rc" "$got" "$got_rc"
  want=$(_fm_decision_key "$line"); want_rc=$?
  got=''; _fm_decision_key_to got "$line"; got_rc=$?
  compare "key ${line}" "$want" "$want_rc" "$got" "$got_rc"
  want=$(_fm_key_at_note_head "$line"); want_rc=$?
  got=''; _fm_key_at_note_head_to got "$line"; got_rc=$?
  compare "note-head key ${line}" "$want" "$want_rc" "$got" "$got_rc"
  want=$(status_line_at_epoch "$line"); want_rc=$?
  got=''; status_line_at_epoch_to got "$line"; got_rc=$?
  compare "epoch ${line}" "$want" "$want_rc" "$got" "$got_rc"
  want=$(fm_nm_trim "$line"); got=$line; fm_nm_trim_to got "$got"
  compare "trim ${line}" "$want" 0 "$got" 0
done < "$dir/task.status"
# fm_nm_strip_quotes now trims in place twice, so its own contract is restated
# here against literal expectations rather than against itself.
for pair in '  "a b"  |a b' '"q"|q' 'bare|bare' '  |' '""|' '"|"'; do
  want=${pair#*|}
  got=$(fm_nm_strip_quotes "${pair%%|*}")
  compare "strip-quotes ${pair%%|*}" "$want" 0 "$got" 0
done
# The whole-file fold, and the per-line fold the two fold strategies share.
want=$(status_open_decisions "$dir/task.status")
got=''; status_open_decisions_to got "$dir/task.status"
compare 'open decisions' "$want" 0 "$got" 0
open=''
while IFS= read -r line || [ -n "$line" ]; do
  want=$(_fm_decision_fold_line "$open" "$line" resolved captain-held)
  got=$open; _fm_decision_fold_line_to got "$open" "$line" resolved captain-held
  compare "fold ${line}" "$want" 0 "$got" 0
  open=$got
done < "$dir/task.status"
for key in api-shape credential absent ''; do
  want=$(_fm_decision_drop "$open" "$key")
  got=$open; _fm_decision_drop_to got "$open" "$key"
  compare "drop ${key}" "$want" 0 "$got" 0
done
# Metadata readers, including the absent file and the absent key.
for meta in "$dir"/*.meta "$dir/missing.meta"; do
  for key in backend window terminal kind spawn_gen absent; do
    want=$(fm_meta_get "$meta" "$key"); want_rc=$?
    got=''; fm_meta_get_to got "$meta" "$key"; got_rc=$?
    compare "meta ${meta##*/} ${key}" "$want" "$want_rc" "$got" "$got_rc"
  done
  want=$(fm_backend_of_meta "$meta"); want_rc=$?
  got=''; fm_backend_of_meta_to got "$meta"; got_rc=$?
  compare "backend ${meta##*/}" "$want" "$want_rc" "$got" "$got_rc"
  want=$(fm_backend_target_of_meta "$meta")
  got=''; fm_backend_target_of_meta_to got "$meta"
  compare "target ${meta##*/}" "$want" 0 "$got" 0
done
SH
  run_everywhere "out-var readers" "$script" "$dir"
  pass "every out-var reader returns what its printing form returned, status included"
}

# A per-invocation budget for the two readers supervision runs most often. The
# watcher reads one crew's current state per task and the fleet view reads the
# whole snapshot, so whatever one invocation costs is multiplied by every task
# in every home. These counts come from executing the real commands against a
# throwaway home: shell children from the pid each DEBUG event reports, program
# starts from PATH shims that exec the real tool. The budgets are ceilings with
# headroom, not exact counts, because the bounded-call mechanism and the shell
# differ per host; FM_TIMEOUT_MECHANISM_OVERRIDE pins the one choice that would
# otherwise change the shape of the work itself.
fork_budget_home() {  # <dir> <ntasks>
  local dir=$1 count=$2 i=1 status round
  mkdir -p "$dir/state" "$dir/config" "$dir/data" "$dir/projects" "$dir/shim"
  cat > "$dir/shim/tmux" <<'SH'
#!/bin/sh
case "$1" in
  capture-pane) printf 'idle pane\n$ \n' ;;
  list-windows) printf 'fm-t1\nfm-t2\nfm-t3\n' ;;
esac
exit 0
SH
  chmod +x "$dir/shim/tmux"
  printf '# Backlog\n\n## In flight\n\n## Queued\n\n## Done\n' > "$dir/data/backlog.md"
  while [ "$i" -le "$count" ]; do
    mkdir -p "$dir/wt$i"
    printf 'window=sess:w%s\nendpoint_task_id=t%s\nworktree=%s/wt%s\nkind=scout\nharness=claude\nbackend=tmux\nspawn_gen=s1.%s\n' \
      "$i" "$i" "$dir" "$i" "$i" > "$dir/state/t$i.meta"
    status="$dir/state/t$i.status"
    # An ordinary-width event log, not a two-line one: the decision fold runs
    # per line, so a per-line regression has to be visible in the count.
    : > "$status"
    for round in 1 2 3; do
      printf '%s\n' \
        "working [at=170000${round}00]: started round $round" \
        "needs-decision [key=api-shape] [at=170000${round}10]: REST or gRPC?" \
        "working [at=170000${round}20]: continuing" \
        "blocked [key=credential] [at=170000${round}30]: the token expired" \
        "resolved [key=api-shape] [at=170000${round}40]: captain picked REST" \
        "resolved [key=credential] [at=170000${round}50]: rotated" \
        "paused [at=170000${round}60]: waiting on CI" >> "$status"
    done
    printf 'working [at=1700009999]: resumed\n' >> "$status"
    i=$((i + 1))
  done
}

fork_budget_count() {  # <home> <label> <command...> -> "<shell-children> <programs>"
  local home=$1 label=$2 tool real events
  events="$home/$label.events"
  shift 2
  mkdir -p "$home/shim"
  for tool in cat ps stat grep date sed jq sleep touch awk tr uname mkdir \
    basename dirname head tail wc cp rm mktemp python3 perl; do
    real=$(command -v "$tool") || continue
    case "$real" in "$home/shim/"*) continue ;; esac
    cat > "$home/shim/$tool" <<SH
#!/bin/sh
printf 'program $tool\n' >> "\$FORK_BUDGET_EVENTS"
exec '$real' "\$@"
SH
    chmod +x "$home/shim/$tool"
  done
  cat > "$home/instrument" <<'SH'
[ "${BASH_VERSINFO[0]}" -ge 4 ] || return 0
fork_budget_debug() {
  if [ "${fork_budget_pid:-}" != "$BASHPID" ]; then
    fork_budget_pid=$BASHPID
    printf 'shell %s\n' "$BASHPID" >> "$FORK_BUDGET_EVENTS"
  fi
}
set -T
trap fork_budget_debug DEBUG
SH
  : > "$events"
  FORK_BUDGET_EVENTS="$events" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
    FM_DATA_OVERRIDE="$home/data" FM_PROJECTS_OVERRIDE="$home/projects" \
    FM_CREW_STATE_NO_FORGE=1 FM_TIMEOUT_MECHANISM_OVERRIDE=bash \
    BASH_ENV="$home/instrument" PATH="$home/shim:$PATH" \
    "$@" > "$home/$label.out" 2> "$home/$label.err"
  awk '$1 == "shell" { if (!seen[$2]++) shells++ } $1 == "program" { programs++ }
       END { printf "%d %d", shells - 1, programs }' "$events"
}

test_crew_state_and_snapshot_stay_within_their_fork_budget() {
  local home="$TMP_ROOT/budget" shells programs subject
  # FM_FORK_BUDGET_ROOT points the same sampler at a saved pre-change bin/, the
  # way tests/fm-supervision-fork-budget.test.sh does, so a claimed cut can be
  # read off the two runs rather than asserted.
  subject=${FM_FORK_BUDGET_ROOT:-$ROOT}
  if [ "${BASH_VERSINFO[0]}" -lt 4 ] \
    || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -lt 2 ]; }; then
    printf 'skip: the fork sampler needs BASHPID (Bash 4.2+)\n'
    return 0
  fi
  command -v jq >/dev/null 2>&1 || { printf 'skip: fleet snapshot needs jq\n'; return 0; }
  fork_budget_home "$home" 3

  read -r shells programs <<< "$(fork_budget_count "$home" crew-state "$subject/bin/fm-crew-state.sh" t1)"
  grep -q '^state: ' "$home/crew-state.out" \
    || fail "crew-state produced no verdict to budget: $(cat "$home/crew-state.err")"
  printf 'crew-state: shell-children=%s programs=%s\n' "$shells" "$programs"
  [ "$shells" -le 70 ] || fail "one crew-state read started $shells shell children (budget 70)"
  [ "$programs" -le 20 ] || fail "one crew-state read started $programs programs (budget 20)"

  read -r shells programs <<< "$(fork_budget_count "$home" snapshot "$subject/bin/fm-fleet-snapshot.sh" --json)"
  [ "$(jq -r '.tasks | length' "$home/snapshot.out" 2>/dev/null)" = 3 ] \
    || fail "fleet snapshot did not report its three crews: $(cat "$home/snapshot.err")"
  printf 'fleet-snapshot: shell-children=%s programs=%s\n' "$shells" "$programs"
  # Three crews, so a per-task regression shows up as roughly three times its
  # own size here rather than hiding inside the fixed cost.
  [ "$shells" -le 300 ] || fail "one three-crew snapshot started $shells shell children (budget 300)"
  [ "$programs" -le 135 ] || fail "one three-crew snapshot started $programs programs (budget 135)"
  pass "one crew-state read and one three-crew fleet snapshot stay within their per-invocation fork budgets"
}

if [ -n "${FM_TEST_ONLY:-}" ]; then
  "$FM_TEST_ONLY"
else
  test_path_helpers_match_dirname_and_basename
  test_epoch_helper_matches_date_and_never_forks_more
  test_signal_seen_path_and_lock_abs_path_are_unchanged
  test_recovery_marker_read_accepts_exactly_one_newline
  test_window_to_task_matches_the_meta_pipeline
  test_classify_stat_helpers_read_the_kernel_name_once
  test_file_read_helper_matches_cat
  test_hex_encoder_matches_od
  test_status_signature_matches_the_per_field_readers
  test_watcher_termination_during_wait
  test_window_fields_match_the_meta_pipeline
  test_out_var_readers_match_their_printing_forms
  test_crew_state_and_snapshot_stay_within_their_fork_budget
fi
