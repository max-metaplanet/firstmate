#!/usr/bin/env bash
# Live proof in a throwaway Herdr lab: real fm-spawn launches REAL claude workers
# on the active seat; a switch moves only the next worker.
set -u
ROOT=/Users/max/.no-mistakes/worktrees/61c6dd39b831/01M37ZTM3S1MSB43MCT4NNZRTF
export FM_GATE_REFUSE_BYPASS=1
unset HERDR_ENV HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_SESSION
LAB=$ROOT/bin/fm-herdr-lab.sh
SESSION=$($LAB name seatlive) || exit 1
export HERDR_SESSION=$SESSION
T=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-seat-lab.XXXXXX")
H=$T/home; S=$T/seats; P=$T/proj
WTS=()
cleanup() {
  echo; echo "### teardown"
  for id in seat-lab-a seat-lab-b; do
    [ -f $H/state/$id.meta ] && FM_HOME=$H FM_ROOT_OVERRIDE=$ROOT FM_SPAWN_NO_GUARD=1 "$ROOT/bin/fm-teardown.sh" $id --force >/dev/null 2>&1
  done
  for wt in ${WTS[@]+"${WTS[@]}"}; do treehouse return --force "$wt" >/dev/null 2>&1; done
  $LAB teardown "$SESSION"; echo "lab teardown exit $?"
  rm -rf "$T"
}
trap cleanup EXIT
echo "lab session: $SESSION"
$LAB provision "$SESSION" || exit 1
mkdir -p $H/{state,config,data,projects} $S/work $S/spare $P
touch $H/state/.last-watcher-beat
printf 'claude\n' > $H/config/crew-harness
printf 'off\n' > $H/config/herdr-presentation-spaces
printf '%s\n' "$S" > $H/config/claude-seats-root
git -C $P init -q; echo '# s' > $P/README.md; git -C $P add README.md
git -C $P -c user.name=t -c user.email=t@e.invalid commit -qm init
git clone -q --bare $P $P.origin.git; git -C $P remote add origin "file://$P.origin.git"
for id in seat-lab-a seat-lab-b; do mkdir -p $H/data/$id; printf '# Task\n## Captain'"'"'s intent\nsay hi\n\n## Firstmate spec\nnothing\n' > $H/data/$id/brief.md; done
seat() { echo "\$ fm-seat.sh $*"; FM_HOME=$H FM_ROOT_OVERRIDE=$ROOT CLAUDE_CONFIG_DIR= "$ROOT/bin/fm-seat.sh" "$@" 2>&1; echo "[exit $?]"; }
spawn() {
  echo "\$ fm-spawn.sh $1 <proj> --backend herdr   (harness claude)"
  env HERDR_SESSION=$SESSION FM_SPAWN_NO_GUARD=1 FM_HOME=$H FM_ROOT_OVERRIDE=$ROOT CLAUDE_CONFIG_DIR= \
    "$ROOT/bin/fm-spawn.sh" "$1" "$P" --backend herdr --mode no-mistakes --yolo off > $T/$1.out 2>&1
  echo "[exit $?]"; tail -4 $T/$1.out
  wt=$(sed -n 's/^worktree=//p' $H/state/$1.meta 2>/dev/null); [ -n "$wt" ] && WTS+=("$wt")
}
claude_env_of() { # print CLAUDE_CONFIG_DIR of live claude processes whose cwd is the task worktree
  local wt=$1 pid
  for pid in $(pgrep -x claude 2>/dev/null) $(pgrep -f 'claude' 2>/dev/null); do
    cwd=$(lsof -a -p $pid -d cwd -Fn 2>/dev/null | sed -n 's/^n//p')
    [ "$cwd" = "$wt" ] || continue
    printf 'pid %s cwd=%s %s\n' $pid "$cwd" "$(ps eww -o command= -p $pid | tr ' ' '\n' | grep '^CLAUDE_CONFIG_DIR=' | head -1)"
  done | sort -u
}
seat switch work --force
spawn seat-lab-a
echo "task A record: $(grep '^claude_seat=\|^harness=' $H/state/seat-lab-a.meta | tr '\n' ' ')"
sleep 8
WTA=$(sed -n 's/^worktree=//p' $H/state/seat-lab-a.meta)
echo "task A live claude process:"; claude_env_of "$WTA"
seat switch spare --force
spawn seat-lab-b
sleep 8
WTB=$(sed -n 's/^worktree=//p' $H/state/seat-lab-b.meta)
echo "task B record: $(grep '^claude_seat=' $H/state/seat-lab-b.meta)"
echo "task B live claude process:"; claude_env_of "$WTB"
echo "task A record AFTER switch: $(grep '^claude_seat=' $H/state/seat-lab-a.meta)"
echo "task A live claude process AFTER switch:"; claude_env_of "$WTA"
seat status
echo "seat profile dirs got trust entries? work: $(ls -A $S/work | tr '\n' ' ') | spare: $(ls -A $S/spare | tr '\n' ' ')"
