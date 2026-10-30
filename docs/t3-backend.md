# Firstmate in T3

The opt-in `t3` backend makes Firstmate workers visible as ordinary T3 threads while keeping the usual task metadata, steering inbox, status records, and isolated checkouts.
The leader can stay in its terminal or move to a Claude thread through the [attended leader handover](t3-leader-handover.md).
Ordinary T3 projects keep their existing behavior.
There is no global T3 customization, service restart, or provider configuration change.

## Setup

Use a running host-local T3 installation whose CLI supports project add/remove and thread start/show/send/list.
Current version-scoped evidence and refresh commands live in [runtime backend verification](verification/runtime-backends.md#t3-native-threads).
The backend is experimental and off by default; running the leader inside T3 does not automatically select it for workers.

Set `FM_T3_BIN` to the installed `t3` executable when it is outside `PATH`, and set `FM_T3_BASE_DIR` to the running T3 data directory.
Select `t3` explicitly through the [normal backend selection](configuration.md#backend-selection-order).
Choose a model advertised by that T3 environment and pass it explicitly at dispatch.
Claude and Codex can run workers; only Claude can run a secondmate or leader.

[`fm-spawn.sh --help`](../bin/fm-spawn.sh) owns dispatch flags and task contracts.
For example, a prepared scout can be launched through the normal path:

```sh
FM_HOME=/path/to/firstmate FM_T3_BIN=/path/to/t3 FM_T3_BASE_DIR=/path/to/t3-data \
  bin/fm-spawn.sh example /path/to/project --scout --harness claude \
  --backend t3 --model MODEL
```

Workers receive a durable Treehouse lease for their isolated checkout.
A secondmate uses its already provisioned home and charter instead of allocating a worker checkout.
Its normal provisioning and parent routing remain owned by the [secondmate procedure](../.agents/skills/secondmate-provisioning/SKILL.md).
T3 leaders and secondmates currently require an explicit `config/supervision-host-off` in their own home because the native Claude watcher path is the proven supervision path.

## Day to day

Open the dedicated project and thread that dispatch created in T3 to follow a worker's conversation.
Continue steering by task id through `fm-send.sh`; the worker receives the existing durable inbox message and acknowledges it in the usual way.
Use `fm-peek.sh` to read its transcript and `fm-crew-state.sh` to reconcile current state.
The watcher consumes the same status files and T3's native run state, including queued requests.

T3 queues a message behind an active turn.
The backend records each inbox doorbell attempt so watcher re-rings do not queue the same message again.
A failed or uncertain native launch/send preserves its evidence and refuses a blind replay; inspect its exact record and thread before deciding recovery.
[`fm-t3.sh --help`](../bin/fm-t3.sh) and [`bin/backends/t3.sh`](../bin/backends/t3.sh) own these mechanics.

Use another ordinary T3 project for work outside Firstmate.
An existing worker's backend stays in its task metadata when future dispatch defaults change.
Moving the leader does not relocate workers or secondmates.

## Supported limits

The native T3 provider owns credentials, permissions, environment, and attribution defaults.
Firstmate refuses explicit account/seat pins, effort, environment filters, tool exclusions, trace injection, and other launch controls its T3 CLI cannot carry.
It does not apply the terminal launcher's Git-hook environment or heavy-build preload to a native thread.
Worker briefs still carry their build/test instructions.
Native Claude hooks use their checkout's script root as the default home when routing environment variables are unset.
Before launch, Firstmate removes legacy T3 routing variables from Claude's local settings while preserving unrelated keys.
The [handover guide](t3-leader-handover.md) explains why these variables cannot be stored in project-local settings.

The CLI has no interrupt, session-stop, or resume operation.
`fm-control.sh` refuses interrupt, exit, and relaunch for T3 tasks, and raw terminal keys and harness-native slash/skill invocations are also refused.
Use the exact thread controls in T3 when intervention is needed.
No recovery-grade process classifier is claimed, so automatic dead-process recovery and worker parking cannot infer a stop from a thread's completed turn.

After the ordinary landed-work checks pass, teardown removes a project's recorded task thread only when that project contains exactly that ordinary thread.
Its child subagents are removed with it; T3's CLI omits them from the ordinary-thread inventory.
An additional ordinary thread makes cleanup refuse and preserve the records.
Project deletion is committed before the CLI returns, but provider shutdown is asynchronous; the existing process checks still gate checkout release.
Keep user conversations in separate projects so they never fall inside a task's cleanup boundary.

Long idle retention, provider restart recovery, and the default supervision-host path require further live proof before unattended use.
The [handover guide](t3-leader-handover.md) describes the leader-specific limits.
