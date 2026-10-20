  cmp -s "$case_dir/global-config" "$case_dir/global-before" \
    || fail "auto-maintenance: global config was changed"
  assert_absent "$case_dir/state/task-x1.meta" "auto-maintenance: task record was not cleaned up"
  pass "teardown suppresses real fetch auto-GC and removal-child maintenance without writing config"
}



# ---- live scenario: real detached auto-maintenance (git defaults, no veto hook) ----
live_case() {  # <label>
  local label=$1 case_dir rc i
  case_dir=$(make_case "live-$label")
  write_meta "$case_dir" no-mistakes ship
  mkdir -p "$case_dir/loose"
  for ((i = 0; i < 12000; i++)); do printf 'live %s %s\n' "$label" "$i" > "$case_dir/loose/$i"; printf '%s\n' "$case_dir/loose/$i"; done > "$case_dir/paths"
  git -C "$case_dir/wt" hash-object -w --stdin-paths < "$case_dir/paths" > /dev/null
  # Project-fixture repo makes itself auto-GC eligible; autoDetach stays at Git's default (true).
  git -C "$case_dir/wt" config gc.auto 1
  git -C "$case_dir/wt" config maintenance.auto true
  if [ "${LIVE_TMUX:-0}" = 1 ]; then
    rm -f "$case_dir/fakebin/tmux"; export TMUX_TMPDIR=$(mktemp -d /tmp/fmt.XXXX); unset TMUX TMUX_PANE
    tmux -f /dev/null new-session -d -s firstmate -n fm-task-x1 -c "$case_dir" "sleep 900"
    echo "-- private tmux (TMUX_TMPDIR=$TMUX_TMPDIR) windows before teardown:"; tmux list-windows -a -F "   #{session_name}:#{window_name} pane_pid=#{pane_pid}"
  fi
  : > "$case_dir/trace2.json"
  rc=0
  GIT_TRACE2_EVENT="$case_dir/trace2.json" run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  echo "== [$label] teardown exit=$rc"
  echo "-- stderr (tail):"; tail -8 "$case_dir/stderr"
  echo "-- auto-maintenance children started by teardown's git (trace2 child_start argv):"
  perl -MJSON::PP -ne 'my $e=eval{decode_json($_)} or next; next unless $e->{event} eq "child_start"; my $a=join(" ",@{$e->{argv}||[]}); print "   $a\n" if $a =~ /\b(gc|maintenance|reflog expire)\b/' "$case_dir/trace2.json" | sort | uniq -c
  echo "-- task meta after teardown: $( [ -e "$case_dir/state/task-x1.meta" ] && echo RETAINED || echo removed )"
  sleep 3
  echo "-- live git gc/maintenance/reflog processes for this case after 3s:"
  ps -axo pid=,command= | grep -F "$case_dir" | grep -E 'gc|maintenance|reflog' | grep -v grep || echo "   none"
}
live_case "$1"
echo "-- fm-slots for the case home after teardown:"
for d in "$TMP_ROOT"/live-*; do printf "4\n" > "$d/config/fleet-capacity"; FM_HOME="$d" PATH="$d/fakebin:$PATH" "$ROOT/bin/fm-slots.sh" --home "$d" 2>&1 | head -8; done
if [ "${LIVE_TMUX:-0}" = 1 ]; then echo "-- private tmux windows after:"; tmux list-windows -a -F "   #{session_name}:#{window_name}" 2>&1; tmux kill-server 2>/dev/null; rm -rf "$TMUX_TMPDIR"; fi
