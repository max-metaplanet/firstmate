# Fleet mod

The Fleet mod is Firstmate's fleet view inside a Claude Code supervision session.
It gives that session three things, all of them read-only: a `/fleet` listing of every task, one line above the prompt naming what waits on the captain, and a transient notice the moment a task first reaches done, blocked, or failed.
It is off by default and does nothing at all until the captain sets `FM_FLEET_ENABLED=1`, as the [Activation](#activation) section below describes.

It is the `firstmate-fleet` mod under `.claude/mods/firstmate-fleet`: a Claude Code plugin whose whole behavior lives in one function-hooks module, the same shape as [`calm.md`](calm.md#claude-code)'s Claude Code support.
The trusted project auto-loads it through the `.claude/skills/firstmate-fleet` entry, a symlink into `.claude/mods`, so no `--plugin-dir` or marketplace install is needed.

## Activation

`FM_FLEET_ENABLED=1` is the whole opt-in, and only that exact value activates the mod.
Unset, empty, `0`, `true`, or any other value leaves it a complete no-op even though Claude Code has loaded the module: there is no `/fleet` command, no timer, no reading of a Firstmate home, and every drawing stays exactly as Claude Code draws it.
Firstmate never sets the flag in any project or user settings; enabling it is the captain's own explicit choice, per session or per shell.

The mod reads exactly two environment names and writes none: `FM_FLEET_ENABLED` and `FM_ROOT_OVERRIDE`.
`FM_HOME` selects which home's fleet is read, but the mod never reads it itself: the reader lives at the tracked code root, and it resolves `FM_HOME` from the environment every command it starts inherits.

## What it shows

`/fleet` opens a pane with one row per task: a mark, the id, the kind, the state word, the evidence that state was resolved from, and the age of the task's last wake event, with that raw event on a dimmed line beneath it.
A red row is waiting on the captain and a green row is finished.
`r` re-reads the fleet.

The state word is always `current_state` from the fleet reading, which is the only reader that reconciles the append-only status event log against liveness.
The event line beneath it is labeled as an event, because the status log's last line is history and goes stale exactly when a resolved decision lets a worker resume.
`unreadable` and `unknown` are drawn apart, because they mean different things: `unreadable` is the reader's claim about itself.

The band above the prompt draws one line when something waits on the captain, and nothing whatsoever when nothing does.
Three things count as waiting: an open decision or a pending one on a task, a merge the captain owes on a finished task whose PR is recorded and whose merge posture leaves the merge to the captain, and a blocked or failed task.
A captain hold the fleet reading classifies as live counts too, even when no worker is under way for it; a dated or blocked hold does not, because the reading's own classification already says it is not waiting now.
Work the captain's standing posture lets Firstmate merge itself is not a merge ask.

A notice names a task the first time a reading finds it done, blocked, or failed.
The first reading of a session announces nothing, however much it finds already finished or blocked, so a session does not open with a burst of notices about work the captain already knows about.
Afterwards a notice fires only when a task reaches a word different from the one last announced for it, so a task flapping between blocked and working earns one notice, while blocked then done earns two.
A re-block after a recovery earns no second notice; the line above the prompt is the persistent signal for it.
A task that leaves the fleet drops its record.

Other mods keep their band content: when the Fleet mod draws, it nests their drawing above its own line rather than replacing it.

## Where it draws, and where it does not

Nothing a mod draws is ever seen in a `claude -p` run, the Agent SDK, a Desktop WSL session, or the VS Code extension's chat panel.
In those sessions `/fleet` answers with the same rows as text instead, carrying every row the pane would draw plus the freshness line.
Whether the session can draw is decided from the session start's own `isInteractive`, never from whether a pane reports itself placed, which answers placed even in a `-p` run where nothing can draw.

## How the reading works

The one data source is `bin/fm-fleet-snapshot.sh --json`, measured at 17.7-21.6s against a 10s budget for one hook.
So it runs only from a 60s timer and one un-awaited reading at session start, both behind a single in-flight promise, and a drawing hook never starts it and only ever draws the cached result.
The in-flight promise is not an optimization: two overlapping runs of that command were measured at 72s wall where one run takes 18s.
`/fleet` asked before the first reading has landed joins the reading already under way rather than starting a second.

A reading that fails, times out, or is not this snapshot's schema is never drawn as a healthy fleet with nothing in it:

- With no earlier reading to fall back on, every surface says the fleet is unavailable and why.
- With an earlier reading, its rows stay and are marked stale with their age and the reason.
- A reading more than three refresh periods old is stale even when nothing has failed.
- The band draws in all three cases, because silence there would claim that nothing waits.

## Bounds

- The function-hooks surface is early access, and Claude Code states its API may change between releases without notice; the mod is verified on Claude Code 2.1.291 and refuses nothing newer.
- A notice is up to one refresh period late, because the state change is only seen when the next reading lands.
- A pane a mod opens unasked needs 144 terminal columns, so this one is only ever opened from `/fleet`.
- Nothing in the mod writes: there is no steer, no merge, and no change to any Firstmate record.
  A mod is not sandboxed, so the capabilities the module reaches for are pinned by the strict-validation guard below rather than left to review.

## Owners

`.claude/mods/firstmate-fleet/lib/fm-fleet-view.ts` owns every reading decision - what a state word may claim, what waits on the captain, how a failed or aged reading is described, and the rows both surfaces draw.
`.claude/mods/firstmate-fleet/lib/fm-fleet-toasts.ts` owns which transitions earn a notice.
`.claude/mods/firstmate-fleet/lib/fm-fleet-activation.ts` owns the activation rule.
`.claude/mods/firstmate-fleet/hooks/register.ts` is the only place the engine interface is touched.
`bin/fm-fleet-snapshot.sh`'s own header owns the reading's schema and every field this mod reads.

Regression entry points:

```sh
tests/fm-fleet-mod.test.sh
tests/fm-fleet-mod-plugin.test.sh
```
