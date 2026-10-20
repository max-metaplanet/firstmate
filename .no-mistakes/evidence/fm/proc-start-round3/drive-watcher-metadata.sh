#!/usr/bin/env bash
# Drives the real fm-watch.sh metadata readers (sourced, no watcher loop) against a
# disposable state dir. Prints behavior lines plus per-call child-shell counts.
set -u
root=$1 fixture=$2
rm -rf "$fixture"; mkdir -p "$fixture/state" "$fixture/config"
export FM_HOME=$fixture FM_STATE_OVERRIDE=$fixture/state FM_CONFIG_OVERRIDE=$fixture/config
. "$root/bin/fm-watch.sh"
count() { # <label> <cmd...> : run cmd in current shell, count distinct child BASHPIDs
  if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then "${@:2}"; return; fi
  : > "$fixture/forks"; exec 9>>"$fixture/forks"; last_pid=$BASHPID; set -T
  trap 'if [ "$last_pid" != "$BASHPID" ]; then last_pid=$BASHPID; printf "%s\n" "$BASHPID" >&9; fi' DEBUG
  "${@:2}"
  trap - DEBUG; set +T; exec 9>&-
  local n=0; while IFS= read -r _; do n=$((n+1)); done < "$fixture/forks"
  printf 'children %s=%s\n' "$1" "$n"
}
S=$STATE
# behavior matrix
printf 'window=s:fm-a\nkind=ship\nkind=secondmate\nbackend=herdr\nharness=claude\nharness=codex\n' > "$S/a.meta"
printf 'window=s:fm-b\n' > "$S/b.meta"
printf 'backend=orca\nwindow=s:fm-c-win\nterminal=orca-term-c\nkind=scout\n' > "$S/c.meta"
printf 'backend=orca\nwindow=s:fm-d\nterminal=\n' > "$S/d.meta"
printf 'window=s:fm-a\n' > "$S/dup.meta"
printf 'window=\nterminal=\n' > "$S/empty.meta"
printf 'window=s:fm-e\nkind=ship' > "$S/e.meta"   # no trailing newline
for w in s:fm-a s:fm-b orca-term-c s:fm-d s:fm-e s:fm-none; do
  window_fields_forget; window_fields "$w"
  printf 'fields %s kind=%s backend=%s harness=%s task=%s\n' "$w" "$FM_WIN_KIND" "$FM_WIN_BACKEND" "$FM_WIN_HARNESS" "$FM_WIN_TASK"
done
recorded_windows out; printf 'recorded=%s\n' "$(printf '%s' "$out" | tr '\n' ',')"
# memo: without forget the memo holds; with forget the fresh value is read
printf 'window=s:fm-b\nkind=secondmate\nbackend=zellij\n' > "$S/b.meta"
window_fields_forget; window_fields s:fm-b; printf 'window=s:fm-b\nkind=scout\n' > "$S/b.meta"
window_fields s:fm-b; printf 'memo-held kind=%s backend=%s\n' "$FM_WIN_KIND" "$FM_WIN_BACKEND"
window_fields_forget; window_fields s:fm-b; printf 'after-forget kind=%s backend=%s\n' "$FM_WIN_KIND" "$FM_WIN_BACKEND"
rm "$S/b.meta"; window_fields_forget; window_fields s:fm-b; printf 'after-delete kind=%s task=%s\n' "$FM_WIN_KIND" "$FM_WIN_TASK"
# child budgets at 31 recorded tasks (the intent's fleet size)
rm -f "$S"/*.meta
for ((i=1;i<=31;i++)); do printf 'window=s:fm-t%s\nkind=ship\nharness=codex\n' "$i" > "$S/t$i.meta"; done
count recorded_windows recorded_windows out
count secondmate_wake_stall_tick secondmate_wake_stall_tick
window_fields_forget; count window_fields_one window_fields s:fm-t31
