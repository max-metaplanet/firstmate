#!/usr/bin/env bash
set -euo pipefail
unset TASKS_AXI_BACKEND TASKS_AXI_FILE FM_ROOT_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_STATE_OVERRIDE FM_PROJECTS_OVERRIDE
base=$PWD/.cap-lab
root=$base/root
mate=$base/mate
for home in "$root" "$mate"; do
  bash bin/fm-lab-home.sh create "$home" >/dev/null
  printf 'backend = "markdown"\n[markdown]\npath = "data/backlog.md"\n' > "$home/.tasks.toml"
  printf '# Backlog\n\n## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
done
printf '2\n' > "$root/config/fleet-capacity"
printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$root" > "$mate/.fm-secondmate-parent"
printf -- '- mate - local (home: %s; scope: work; projects: project; added 2026-09-01)\n' "$mate" > "$root/data/secondmates.md"
printf 'kind=secondmate\nbackend=tmux\nwindow=fm-lab-cap:fm-mate\nworktree=%s\nproject=%s\n' "$mate" "$mate" > "$root/state/mate.meta"
export TMUX="$base/s,0,0" FM_BACKEND=tmux
check() {
  local label=$1 expected=$2 output
  output=$(FM_HOME="$root" bash bin/fm-slots.sh)
  printf '\nSCENARIO: %s\n%s\n' "$label" "$output"
  [[ "$output" == "slots $expected/2 "* ]] || exit 1
}
check 'live endpoint with empty secondmate home releases its slot' 0
tasks-axi add orphan 'in-flight work without worker metadata' --kind ship --file "$mate/data/backlog.md" >/dev/null
tasks-axi start orphan --file "$mate/data/backlog.md" >/dev/null
check 'in-flight backlog alone retains secondmate slot' 1
tasks-axi done orphan --file "$mate/data/backlog.md" >/dev/null
printf 'kind=ship\nbackend=tmux\nwindow=fm-lab-cap:fm-mate\nworktree=%s\nproject=%s\n' "$mate" "$mate" > "$mate/state/child.meta"
check 'worker metadata retains supervisor and worker slots even with no in-flight row' 2
rm "$mate/state/child.meta"
check 'clearing work releases secondmate again' 0
mv "$mate/data/backlog.md" "$mate/data/backlog.saved"
mkdir "$mate/data/backlog.md"
check 'unreadable backlog retains secondmate slot' 1
rmdir "$mate/data/backlog.md"
mv "$mate/data/backlog.saved" "$mate/data/backlog.md"
mkdir "$root/state/.spawn-mate.lock"
printf '%s\n' $$ > "$root/state/.spawn-mate.lock/pid"
check 'active launch reservation retains idle secondmate slot' 1
rm -r "$root/state/.spawn-mate.lock"
printf 'kind=scout\nbackend=tmux\nwindow=fm-lab-cap:fm-mate\nworktree=%s\nproject=%s\n' "$root" "$root" > "$root/state/scout.meta"
check 'ordinary scout still holds its own slot while secondmate is idle' 1
