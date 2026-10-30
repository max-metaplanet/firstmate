#!/usr/bin/env bash
set -euo pipefail
unset TASKS_AXI_BACKEND TASKS_AXI_FILE FM_ROOT_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_STATE_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS
base=$PWD/.cap-lab
project=$base/project
mate=$base/mate
mkdir -p "$project"
git -C "$project" init -q
git -C "$project" -c user.name=Lab -c user.email=lab@example.invalid commit --allow-empty -qm initial
git -C "$project" remote add origin "$base/origin.git"
printf '1\n' > "$base/root/config/fleet-capacity"
printf 'codex\n' > "$mate/config/crew-harness"
mkdir -p "$mate/data/first-worker"
cat > "$mate/data/first-worker/brief.md" <<'EOF'
# Task
## Captain's intent
Exercise first worker fleet admission.
## Firstmate spec
Exercise first worker fleet admission.
# Definition of done
Delivery contract: mode=no-mistakes
Ship branch: chore/no-ticket-first-worker
Ticket: no-ticket
Commit type: chore
EOF
tasks-axi add first-worker 'first worker' --kind ship --file "$mate/data/backlog.md" >/dev/null
export TMUX="$base/s,0,0" FM_BACKEND=tmux FM_HOME="$mate"
for kind in ship scout; do
  args=(--mode no-mistakes --ticket no-ticket --commit-type chore --yolo off)
  [ "$kind" != scout ] || args=(--scout)
  rc=0
  out=$(bash bin/fm-spawn.sh first-worker "$project" "${args[@]}" 2>&1) || rc=$?
  printf '\nFirst %s with capacity 1: exit=%s\n%s\n' "$kind" "$rc" "$out"
  [ "$rc" = 75 ]
  [[ "$out" == *'1 are running'* ]]
  [ ! -e "$mate/state/first-worker.meta" ]
  tasks-axi show first-worker --file "$mate/data/backlog.md"
done
