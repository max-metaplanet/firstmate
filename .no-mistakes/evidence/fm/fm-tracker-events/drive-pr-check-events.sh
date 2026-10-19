#!/usr/bin/env bash
# Live: real bin/fm-pr-check.sh records a PR in a marked lab home -> pr-opened once.
set -u
ROOT=$(cd "$1" && pwd -P)
LAB=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/fm-pc-lab.XXXXXX")" && pwd -P)
trap 'rm -rf "$LAB"' EXIT
c="$LAB/home"; mkdir -p "$c"; "$ROOT/bin/fm-lab-home.sh" create "$c" >/dev/null || exit 1
fb="$c/fakebin"; mkdir -p "$fb"
printf '#!/usr/bin/env bash\nexit 0\n' > "$fb/tmux"
printf '#!/usr/bin/env bash\nexit 1\n' > "$fb/gh-axi"; printf '#!/usr/bin/env bash\nexit 1\n' > "$fb/gh"
chmod +x "$fb"/*
git init -q --bare "$c/origin.git"; git -C "$c/origin.git" symbolic-ref HEAD refs/heads/main
git clone -q "$c/origin.git" "$c/seed" 2>/dev/null
git -C "$c/seed" -c user.email=t@t -c user.name=t commit -q --allow-empty -m base; git -C "$c/seed" push -q origin main; rm -rf "$c/seed"
git clone -q "$c/origin.git" "$c/project"; git -C "$c/project" remote set-head origin main 2>/dev/null
git -C "$c/project" worktree add -q -b fm/task-x1 "$c/wt" main
git -C "$c/wt" -c user.email=t@t -c user.name=t commit -q --allow-empty -m work
git -C "$c/wt" push -q origin fm/task-x1
touch "$c/state/.last-watcher-beat"
printf 'window=firstmate:fm-task-x1\nendpoint_task_id=task-x1\nworktree=%s/wt\nproject=%s/project\nkind=ship\nmode=no-mistakes\nspawn_gen=lab\nticket=ENG-700\n' "$c" "$c" > "$c/state/task-x1.meta"
printf 'done: PR opened for the export endpoint\n' > "$c/state/task-x1.status"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$1" >> "%s/events"\n' "$c" > "$c/consumer"; chmod +x "$c/consumer"
printf '%s\n' "$c/consumer" > "$c/config/task-event-hook"
pc() { FM_HOME="$c" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$c/state" FM_CONFIG_OVERRIDE="$c/config" PATH="$fb:$PATH" "$ROOT/bin/fm-pr-check.sh" task-x1 "$1"; }
URL=https://github.com/acme/app/pull/77
pc "$URL" > "$c/out1" 2>&1; echo "first record rc=$?"; tail -3 "$c/out1"
pc "$URL" > "$c/out2" 2>&1; echo "re-arm same URL rc=$?"
sleep 1.5
echo "--- consumer received ---"; cat "$c/events" 2>/dev/null
if [ "$(wc -l < "$c/events" 2>/dev/null | tr -d ' ')" = 1 ] && jq -e --arg u "$URL" '.event=="pr-opened" and .pr_url==$u and .ticket=="ENG-700" and .summary=="PR opened for the export endpoint"' "$c/events" >/dev/null; then
  echo "PASS  P1 PR registration emits pr-opened once; re-arm of same URL emits nothing"; exit 0
fi
echo "FAIL  P1"; cat "$c/out1"; exit 1
