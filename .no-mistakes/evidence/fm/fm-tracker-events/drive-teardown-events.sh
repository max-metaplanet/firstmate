#!/usr/bin/env bash
# Live: real bin/fm-teardown.sh in a disposable home emits finished / cancelled.
set -u
ROOT=$1
LAB=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/fm-td-lab.XXXXXX")" && pwd -P)
trap 'rm -rf "$LAB"' EXIT
FAILS=0
ok(){ printf 'PASS  %s\n' "$1"; }; bad(){ printf 'FAIL  %s\n' "$1"; FAILS=$((FAILS+1)); }
mkcase() {  # <name> <status-text> -> case dir
  local c="$LAB/$1" fb="$LAB/$1/fakebin"
  mkdir -p "$c"; "$ROOT/bin/fm-lab-home.sh" create "$c" >/dev/null || { echo "lab create failed" >&2; return 1; }
  mkdir -p "$fb"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fb/treehouse"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fb/tmux"
  printf '#!/usr/bin/env bash\ncase "$1 $2" in "pr list") printf "count: 0 (showing first 0)\\npull_requests[]: []\\n";; "pr view") exit 1;; esac\nexit 0\n' > "$fb/gh-axi"
  printf '#!/usr/bin/env bash\n[ "$1 $2" = "pr view" ] && exit 1; exit 0\n' > "$fb/gh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fb/no-mistakes"
  chmod +x "$fb"/*
  git init -q --bare "$c/origin.git"; git -C "$c/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$c/origin.git" "$c/seed" 2>/dev/null
  git -C "$c/seed" -c user.email=t@t -c user.name=t commit -q --allow-empty -m base; git -C "$c/seed" push -q origin main; rm -rf "$c/seed"
  git clone -q "$c/origin.git" "$c/project"; git -C "$c/project" remote set-head origin main 2>/dev/null
  git -C "$c/project" worktree add -q -b fm/task-x1 "$c/wt" main
  touch "$c/state/.last-watcher-beat"
  printf 'window=firstmate:fm-task-x1\nendpoint_task_id=task-x1\nworktree=%s/wt\nproject=%s/project\nkind=ship\nmode=no-mistakes\nspawn_gen=lab\nticket=ENG-900\npr=https://github.com/acme/app/pull/90\n' "$c" "$c" > "$c/state/task-x1.meta"
  printf '%s\n' "$2" > "$c/state/task-x1.status"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$1" >> "%s/events"\n' "$c" > "$c/consumer"; chmod +x "$c/consumer"
  printf '%s\n' "$c/consumer" > "$c/config/task-event-hook"
  printf '%s\n' "$c"
}
td() { local c=$1; shift; FM_HOME="$c" FM_ROOT_OVERRIDE="$(cd "$ROOT" && pwd -P)" FM_STATE_OVERRIDE="$c/state" FM_CONFIG_OVERRIDE="$c/config" PATH="$c/fakebin:$PATH" "$ROOT/bin/fm-teardown.sh" task-x1 "$@"; }
waitf(){ local i=0; while [ $i -lt 100 ]; do [ -s "$1" ] && return 0; sleep 0.1; i=$((i+1)); done; return 1; }

echo "== T1 normal teardown of a done task emits finished with worker summary"
c=$(mkcase done 'done: export endpoint shipped, PR merged')
td "$c" > "$c/out" 2>&1; rc=$?; echo "    teardown rc=$rc; last line: $(tail -1 "$c/out")"
waitf "$c/events"; sed 's/^/    consumer: /' "$c/events" 2>/dev/null
jq -e '.event=="finished" and .task_id=="task-x1" and .ticket=="ENG-900" and .pr_url=="https://github.com/acme/app/pull/90" and .summary=="export endpoint shipped, PR merged"' "$c/events" >/dev/null 2>&1 \
  && ok "T1 finished emitted after successful teardown" || { bad "T1"; sed 's/^/    out: /' "$c/out" | tail -15; }

echo "== T2 forced teardown of an unfinished task emits cancelled"
c=$(mkcase force 'working: halfway through migration')
td "$c" --force > "$c/out" 2>&1; rc=$?; echo "    teardown rc=$rc; last line: $(tail -1 "$c/out")"
waitf "$c/events"; sed 's/^/    consumer: /' "$c/events" 2>/dev/null
jq -e '.event=="cancelled" and .ticket=="ENG-900" and .summary=="halfway through migration"' "$c/events" >/dev/null 2>&1 \
  && ok "T2 cancelled emitted for forced removal without done status" || { bad "T2"; sed 's/^/    out: /' "$c/out" | tail -15; }

echo "== T3 adversarial (R3-F1): done status + surfaced hook failure, then --force teardown is still finished"
c=$(mkcase failnote 'done: PR ready for review')
printf 'actionable [at=1]: task event hook failed event=pr-opened exit=124; see state/task-events.log\n' >> "$c/state/task-x1.status"
td "$c" --force > "$c/out" 2>&1; rc=$?; echo "    teardown rc=$rc"
waitf "$c/events"; sed 's/^/    consumer: /' "$c/events" 2>/dev/null
jq -e '.event=="finished" and .summary=="PR ready for review"' "$c/events" >/dev/null 2>&1 \
  && ok "T3 failure notice does not impersonate worker status at teardown" || { bad "T3"; sed 's/^/    out: /' "$c/out" | tail -15; }
echo; echo "TOTAL_FAILS=$FAILS"; exit "$FAILS"
