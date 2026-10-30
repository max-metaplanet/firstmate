# Moving the Firstmate leader into T3

The Firstmate home can run its leader as a visible Claude thread in T3 while keeping its existing task records and isolated worker checkouts.
The T3 project must point at the independent Firstmate home, where the native Claude project hooks load the startup digest, acquire the existing session lock, and arrange supervision.
Use a separate ordinary T3 project for work that does not need Firstmate.
No global T3 customization is needed.

This workflow is opt-in.
The forward switch completes automatically from the current Claude leader in tmux; keep operation attended within the limits below.
The worker backend and the leader's location are independent choices, so moving the leader does not move existing workers or secondmates.
The handover tool accepts the primary home only; a secondmate's thread placement remains owned by its parent's normal spawn path.
Only Claude is supported as the T3 leader; the installed Codex app-server path does not establish an independent Firstmate lock identity or the required native hook behavior.

## The handover

[`bin/fm-t3-leader.sh --help`](../bin/fm-t3-leader.sh) owns the commands, required environment, durable record, and refusal behavior for both directions.
Persist any open work that exists only in the conversation, then run the tool's `switch --to t3 --model MODEL --persisted` command inside the current leader.
The command records recovery information and schedules detached completion before returning, so the current leader can end its turn.
No separate activation terminal or typed exit is required.
Use the switch dry-run to check ownership, the original tmux pane, recovery prerequisites, and legacy routing migration without scheduling anything.

Completion stops only the recorded outgoing Claude PID, waits for it to exit, launches its replacement, and waits for verified lock ownership and confirmation.
If activation fails or confirmation times out, it resumes the outgoing Claude conversation in its original tmux pane when the lock is free or stale.
The durable handover record and completion log retain the exact recovery command if the pane is unavailable or another live or unknown process owns the lock.
No lock is deleted and no competing owner is displaced.
An uncertain T3 launch is never retried automatically.

The lower-level prepare and activate commands remain available for attended reverse handover.
Exit the outgoing T3 leader through the host's normal process controls before reverse activation; a completed model turn alone does not end that session.
The tool preserves the T3 project and conversation history.

Forward activation opens a Claude leader thread in the Firstmate T3 project.
If the home is already registered, including as “firstmate (view only)”, activation reuses that exact workspace project.
Other registration errors remain fatal.
Before launching it, Firstmate removes legacy `FM_HOME`, `FM_ROOT`, and the Firstmate path override variables from `.claude/settings.local.json`.
Claude also loads the primary checkout's local settings in linked worktrees, where primary values win conflicts, so those settings cannot safely bind one home.
With routing variables unset, native hooks default to the home containing their scripts; the successor prompt also scopes startup and confirmation commands explicitly to the handover home.
Keep the T3 provider process free of Firstmate home-routing variables so it does not pass another home's environment into native threads.
Migration preserves permissions, hooks, and unrelated settings, including unrelated environment variables.
Malformed or symlinked settings still refuse for inspection.
The activation dry-run validates migration without changing the file.
Reverse activation starts Claude in the terminal where the activation command runs.
The replacement starts fresh from durable records rather than resuming the other interface's conversation.
In either direction, it must acquire the normal session lock and confirm that ownership before the persistent handover status reports completion.
Read the tool's status after activation and require the confirmed phase.

An attempted launch that has not confirmed requires inspection of the saved evidence and exact thread before another T3 activation.
The previous leader's records, workers, and worktrees remain available for recovery.

## View-only threads

Primary-home T3 threads default to read-only, including threads in a project whose title says view-only.
The shared access guard recognizes the native `t3` executable in the process ancestry; `FM_T3_VIEW_ONLY=1` is the explicit provider environment marker for installations that launch providers through a separate service without that ancestry.
Both session startup and direct lock acquisition enforce the guard before creating state or running fleet startup mutations.
Project titles are display labels and do not grant leadership.
The intended Claude successor receives a private handover nonce in its launch prompt and explicitly runs startup with that nonce after the initial read-only hook.
Only a matching starting handover or the already-owning successor session passes the guard.
This restriction applies to primary leaders; seeded secondmates retain their parent-owned startup contract.

## Operating limits and verification

T3's CLI queues messages behind a running turn and does not expose an interrupt or a session-stop operation.
Use the exact thread's controls in T3 when a session needs human intervention.
Closing a turn, changing the visible thread, or reading its transcript does not prove the leader process exited.

Native Claude hooks have demonstrated startup, lock ownership, and a worker-status wake in an independent scratch home with the optional supervision host explicitly disabled.
Forward activation requires the home's explicit supervision-host opt-out; the tool does not change that setting for the operator.
That evidence does not establish idle retention beyond T3's expiry, provider restart recovery, or the default supervision-host path.
Keep operation attended until those paths have their own live proof.
The existing watcher scope guard refuses disposable `.treehouse` paths, including nested scratch homes; do not bypass it for a live acceptance run.

[`tests/fm-t3-leader.test.sh`](../tests/fm-t3-leader.test.sh) checks automatic success, existing-project reuse, registration failure and confirmation-timeout recovery, view-only refusal, both attended transitions, dry-runs, exclusive lock ownership, and duplicate-launch refusal through the public interface.
The [runtime backend verification record](verification/runtime-backends.md) owns dated live evidence and current verification entry points.
