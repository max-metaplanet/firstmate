#!/usr/bin/env bash
# Live herdr-lab drive of claude seat recording on spawn + relaunch.
set -u
ROOT=/Users/max/.no-mistakes/worktrees/61c6dd39b831/01M37V0BXMCRP7HK3XS5G7VH3S
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane
T=$(mktemp -d "$(cd /tmp && pwd -P)/fmseat-live.XXXX")
HELPER="$ROOT/bin/fm-herdr-lab.sh"
S=$("$HELPER" name fmseat) || exit 1
export HERDR_SESSION=$S
echo "lab session: $S   scratch: $T"
# shim claude: prints the profile it launched against, then waits
mkdir -p "$T/bin"
cat > "$T/bin/claude" <<'SH'
#!/bin/sh
echo "SHIM-CLAUDE launched CLAUDE_CONFIG_DIR=${CLAUDE_CONFIG_DIR:-<unset>} args=$*"
sleep 3
echo "SHIM-CLAUDE exiting"
SH
chmod +x "$T/bin/claude"; cp "$T/bin/claude" "$T/bin/codex"
export PATH="$T/bin:$PATH"
WTS=()
cleanup(){ for w in "${WTS[@]:-}"; do [ -n "$w" ] && treehouse return --force "$w" >/dev/null 2>&1; done; "$HELPER" teardown "$S"; echo "teardown rc=$?"; }
trap cleanup EXIT
"$HELPER" provision "$S" || { echo provision failed; exit 1; }
H="$T/home"; P="$T/proj"
mkdir -p "$H/data" "$H/projects" "$H/state" "$H/config"; touch "$H/state/.last-watcher-beat"
echo claude > "$H/config/crew-harness"
echo "$T/seats" > "$H/config/claude-seats-root"
mkdir -p "$T/seats/alpha" "$T/seats/beta" "$T/ambient"
mkdir -p "$P"; git -C "$P" init -q; echo x > "$P/README.md"; git -C "$P" add .; git -C "$P" -c user.name=t -c user.email=t@x commit -qm i
git clone -q --bare "$P" "$P.origin.git"; git -C "$P" remote add origin "file://$P.origin.git"
brief(){ mkdir -p "$H/data/$1"; printf '# Task\n## Captain%ss intent\nseat probe %s\n\n## Firstmate spec\nExercise seats.\n' "'" "$1" > "$H/data/$1/brief.md"; }
E(){ env FM_HOME="$H" FM_ROOT_OVERRIDE="$ROOT" FM_SPAWN_NO_GUARD=1 CLAUDE_CONFIG_DIR="$T/ambient" PATH="$T/bin:$PATH" "$@"; }
seat(){ echo "\$ fm-seat.sh $*"; E env -u PATH PATH="$(echo "$PATH" | tr ':' '\n' | grep -v -e fnm_multishells | paste -sd: -)" "$ROOT/bin/fm-seat.sh" "$@"; echo "exit=$?"; }
spawn(){ echo "\$ fm-spawn.sh $1 <proj> --scout --harness claude --backend herdr"; brief "$1"; E "$ROOT/bin/fm-spawn.sh" "$1" "$P" --scout --harness claude --backend herdr 2>&1 | tail -15; echo "spawn rc=${PIPESTATUS[0]}"; w=$(sed -n 's/^worktree=//p' "$H/state/$1.meta" 2>/dev/null | head -1); WTS+=("$w"); echo "--- $1.meta claude_seat: $(grep '^claude_seat=' "$H/state/$1.meta" || echo '(none)')"; }
pane_text(){ local pid; pid=$(sed -n "s/^window=//p" "$H/state/$1.meta" | head -1); echo "--- $1 pane ($pid) contents:"; "$HELPER" run "$S" pane read "${pid#*:}" --source recent --lines 60 > "$T/pr.$1" 2>&1; grep -a -o -E "SHIM-CLAUDE launched CLAUDE_CONFIG_DIR=[^ ]*|CLAUDE_CONFIG_DIR=[^ ]* [^ ]*claude" "$T/pr.$1" | sort -u | tail -6; [ -s "$T/pr.$1" ] || echo "(empty read)"; grep -q SHIM "$T/pr.$1" || head -c 600 "$T/pr.$1"; }
echo "== 1. switch to alpha (quota-axi hidden from PATH -> undecided probe -> --force)"
seat switch alpha --force
echo "== 2. spawn task t-alpha on active seat alpha"
spawn t-alpha
sleep 5; pane_text t-alpha
echo "== 3. switch now to beta while t-alpha exists"
seat switch beta --force
echo "== 4. spawn task t-beta"
spawn t-beta
sleep 5; pane_text t-beta
echo "== 5. status"
seat status
echo "== 6. relaunch t-alpha after the switch (must stay on alpha)"
grep -E "^(window|backend)=" "$H/state/t-alpha.meta"
pid=$(sed -n "s/^window=//p" "$H/state/t-alpha.meta"); echo "closing the old agent-free pane ${pid#*:} so relaunch must rebind"; "$HELPER" run "$S" pane close "${pid#*:}" >/dev/null 2>&1; echo "pane close rc=$?"; sleep 2
E "$ROOT/bin/fm-spawn.sh" t-alpha --relaunch 2>&1 | tail -15; echo "relaunch rc=${PIPESTATUS[0]}"
echo "--- t-alpha.meta claude_seat after relaunch: $(grep '^claude_seat=' "$H/state/t-alpha.meta")"
sleep 5; pane_text t-alpha
echo "== 7. codex spawn while beta active records no seat"
brief t-codex
E "$ROOT/bin/fm-spawn.sh" t-codex "$P" --scout --harness codex --backend herdr 2>&1 | tail -5; echo "codex spawn rc=${PIPESTATUS[0]}"
w=$(sed -n 's/^worktree=//p' "$H/state/t-codex.meta" 2>/dev/null | head -1); WTS+=("$w")
echo "--- t-codex.meta claude_seat: $(grep '^claude_seat=' "$H/state/t-codex.meta" 2>/dev/null || echo '(none)')"
seat status
