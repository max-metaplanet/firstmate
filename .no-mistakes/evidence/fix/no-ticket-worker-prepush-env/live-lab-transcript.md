# Live lab: real bin/fm-spawn.sh on a private tmux socket (fm-lab), marked lab FM_HOME, real treehouse under lab HOME

## Scout spawn (raw probe agent) -> /private/var/folders/1l/gg6b5zsx0qn753wwhcmmq8cr0000gn/T/fm-lab.Ak04ox/scout.env
spawned prepush-scout harness=probe.sh kind=scout window=primary:fm-prepush-scout worktree=/private/var/folders/1l/gg6b5zsx0qn753wwhcmmq8cr0000gn/T/fm-lab.Ak04ox/uhome/.treehouse/proj-028208/1/proj
scout exit=0
PREPUSH_TESTS=0
FM_TASK_ID=prepush-scout
COMPACT_ADVISER_DISABLE=1

## Ship spawn, allowlist absent (raw probe agent)
spawned prepush-ship3 harness=probe.sh kind=ship mode=direct-PR yolo=off window=primary:fm-prepush-ship3 worktree=/private/var/folders/1l/gg6b5zsx0qn753wwhcmmq8cr0000gn/T/fm-lab.Ak04ox/uhome/.treehouse/proj-028208/2/proj
ship exit=0
PREPUSH_TESTS=0
FM_TASK_ID=prepush-ship3
COMPACT_ADVISER_DISABLE=1

## Ship spawn, launch-env-allowlist ENABLED (env -i path); agent runs git push through a husky-style pre-push hook
spawned prepush-ship4 harness=probe-push.sh kind=ship mode=direct-PR yolo=off window=primary:fm-prepush-ship4 worktree=/private/var/folders/1l/gg6b5zsx0qn753wwhcmmq8cr0000gn/T/fm-lab.Ak04ox/uhome/.treehouse/proj-028208/3/proj
ship exit=0
PREPUSH_TESTS=0
cwd=/private/var/folders/1l/gg6b5zsx0qn753wwhcmmq8cr0000gn/T/fm-lab.Ak04ox/uhome/.treehouse/proj-028208/3/proj
hooksPath=/private/var/folders/1l/gg6b5zsx0qn753wwhcmmq8cr0000gn/T/fm-lab.Ak04ox/state/prepush-ship4.git-hooks
pre-push: PREPUSH_TESTS=0 -> skipping full turbo suite
To /var/folders/1l/gg6b5zsx0qn753wwhcmmq8cr0000gn/T/fm-lab.Ak04ox/remote.git
 * [new branch]      HEAD -> probe-push
push exit=0

## Claude-harness ship spawn (claude CLI stand-in on PATH; real quota guard wrapper + launch file)
spawned prepush-claude harness=claude kind=ship mode=direct-PR yolo=off window=primary:fm-prepush-claude worktree=/private/var/folders/1l/gg6b5zsx0qn753wwhcmmq8cr0000gn/T/fm-lab.Ak04ox/uhome/.treehouse/proj-028208/4/proj
spawn exit=0
PREPUSH_TESTS=0 FM_TASK_ID=prepush-claude COMPACT_ADVISER_DISABLE=1

## Pane preamble seen in the Claude ship pane
export GOTMPDIR=/tmp/fm-prepush-claude/gotmp
export COMPACT_ADVISER_DISABLE=1
export FM_TASK_ID=prepush-claude
export PREPUSH_TESTS=0
. '/tmp/fm-prepush-claude+21f51e6798aa380c8c2dc31b7146025888f03d8e25cb16d46a1ec2dca1ea0785/launch.s1793101116.21763.6976.sh'

## Live relaunch attempt (refused: stand-in endpoint classified ambiguous)
== relaunch
fm-gate-refuse: gate agent lifecycle permitted only against lab home /private/var/folders/1l/gg6b5zsx0qn753wwhcmmq8cr0000gn/T/fm-lab.Ak04ox
error: task prepush-claude's endpoint reads 'ambiguous' rather than a positively classified state; refusing to send a lifecycle command into an unattributed endpoint
error: relaunch of prepush-claude failed while stopping the old agent and its state is 'ambiguous', so it was not proven stopped; its original instructions were restored and the durable record was retained for recovery
relaunch exit=1
done
