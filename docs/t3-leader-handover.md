# Moving the Firstmate leader into T3

The Firstmate home can run its leader as a visible Claude thread in T3 while keeping its existing task records and isolated worker checkouts.
The T3 project must point at the independent Firstmate home, where the native Claude project hooks load the startup digest, acquire the existing session lock, and arrange supervision.
Use a separate ordinary T3 project for work that does not need Firstmate.
No global T3 customization is needed.

This workflow is opt-in and attended.
The worker backend and the leader's location are independent choices, so moving the leader does not move existing workers or secondmates.
The handover tool accepts the primary home only; a secondmate's thread placement remains owned by its parent's normal spawn path.
Only Claude is supported as the T3 leader; the installed Codex app-server path does not establish an independent Firstmate lock identity or the required native hook behavior.

## The handover

[`bin/fm-t3-leader.sh --help`](../bin/fm-t3-leader.sh) owns the commands, required environment, durable record, and refusal behavior for both directions.
Begin with its prepare dry-run from the current leader so the tool can prove that session owns the home's lock.
Persist any open work that exists only in the conversation before preparing the actual handover.
The tool records the chosen destination and explicit Claude model, then prints the activation command for a separate shell.

Exit the outgoing leader normally before activating its replacement.
For a T3 leader, use the host's normal process controls from a separate terminal to stop only the outgoing Claude PID recorded by prepare, then verify it has exited; a completed model turn alone does not end that session.
The handover tool preserves the T3 project and conversation history.
The tool never terminates a process or removes a lock to make the transition work.
Activation refuses while the outgoing process still exists or another live or uncertain process owns the lock.
If another leader takes the home during the attended gap, leave it alone and reconcile the handover.

Forward activation opens a Claude leader thread in the Firstmate T3 project.
Before launching it, Firstmate binds Claude's local project environment to that exact home so native hooks cannot inherit a different home's routing from the T3 provider process.
The merge preserves existing permissions, hooks, and unrelated environment settings; conflicting routes, malformed settings, and symlinked settings are refused for inspection.
The activation dry-run checks that binding without writing it.
Reverse activation starts Claude in the terminal where the activation command runs.
The replacement starts fresh from durable records rather than resuming the other interface's conversation.
In either direction, it must acquire the normal session lock and confirm that ownership before the persistent handover status reports completion.
Read the tool's status after activation and require the confirmed phase.

An attempted launch that has not confirmed is an uncertain outcome, not a request to retry.
Inspect the saved launch evidence and the exact thread before taking another action; a repeated activation is deliberately refused.
The previous leader's records, workers, and worktrees remain available for recovery.

## Operating limits and verification

T3's CLI queues messages behind a running turn and does not expose an interrupt or a session-stop operation.
Use the exact thread's controls in T3 when a session needs human intervention.
Closing a turn, changing the visible thread, or reading its transcript does not prove the leader process exited.

Native Claude hooks have demonstrated startup, lock ownership, and a worker-status wake in an independent scratch home with the optional supervision host explicitly disabled.
Forward activation requires the home's explicit supervision-host opt-out; the tool does not change that setting for the operator.
That evidence does not establish idle retention beyond T3's expiry, provider restart recovery, or the default supervision-host path.
Keep operation attended until those paths have their own live proof.
The existing watcher scope guard refuses disposable `.treehouse` paths, including nested scratch homes; do not bypass it for a live acceptance run.

[`tests/fm-t3-leader.test.sh`](../tests/fm-t3-leader.test.sh) checks both transitions, dry-runs, exclusive lock ownership, and duplicate-launch refusal through the public interface.
The [runtime backend verification record](verification/runtime-backends.md) owns dated live evidence and current verification entry points.
