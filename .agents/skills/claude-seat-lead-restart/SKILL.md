---
name: claude-seat-lead-restart
description: >-
  Agent-only procedure for moving firstmate itself onto another Claude seat.
  Load on a `check:` wake whose line begins `claude-seat: firstmate itself`, and on any `check: lead-restart` wake.
  Firstmate carries the move out itself on that wake, with no captain approval; this skill owns that standing authority, the persist step that comes first, and the recovery half when a swap does not complete.
user-invocable: false
metadata:
  internal: true
---

# claude-seat-lead-restart

A seat switch moves only what the next spawn reads, so it has never moved firstmate.
No running Claude Code process can change credential store, so firstmate changes account only by being replaced: another `claude` starts on the new seat in the same terminal, resuming the same session, and the current process ends.
`bin/fm-lead-restart.sh` owns that transaction, every refusal, and what a failure leaves; `docs/claude-seats.md` owns the operator's view of it.
This skill owns only what firstmate does when the watch reports the crossing.

## Standing authority

The move is routine autonomous work, not a captain decision.
When the watch reports that firstmate's own seat crossed the trigger and the move is available, carry it out on that wake, the same as any other actionable `check:` result.
Do not ask the captain first, do not offer it as an option, and do not report the crossing and stop.
The captain set the threshold, so the threshold firing is the instruction.

That authority is scoped to exactly this action and grants nothing else.
It never becomes authority to merge, to answer an ask-user finding, or to take any destructive, irreversible, or security-sensitive action, and it never reaches a seat the captain did not configure, because `bin/fm-seat.sh` chooses the destination by the ordinary rotation.

The away and quiet postures do not change it.
A seat runs out of quota whether or not the captain is present, and the durable records the successor reads are the same ones either way, so an away window is the case this exists for rather than a reason to hold.

## On the wake

The wake line is self-sufficient and carries the exact command; run the steps in this order.

1. **Persist first.**
   The replacement drops this conversation and keeps every durable record, so write down the open work that exists only here: the `/stow` skill's "Open-record persistence" section and nothing else from it.
   File a task for each unfiled open record, including a captain call formed but never registered, and correct any task whose recorded status no longer reflects what you now know.
   Do not run the memory, learnings, or captain-preference sweeps.
2. **Run the command the wake names**, exactly as printed, including `--persisted`.
   It refuses rather than guessing, so a refusal is a real blocker and never something to force, re-run against a different seat, or work around.
   Report a refusal in one line with what it named, stay on the current seat, and carry on.
3. **Say nothing after it arms.**
   The command prints what will happen and the process ends a few seconds later.
   Do not start new work, do not promise the captain a follow-up from this session, and do not wait for the swap: the successor picks up from durable records at its own session start, and anything arriving meanwhile is held by the durable wake queue.

A crossing the move cannot act on is reported as a blocker instead, naming what could not be established.
Treat that as an ordinary blocker: it is captain-facing only when the captain has to act, such as a destination seat that needs their login.

## When a swap does not complete

A `check: lead-restart` wake means the swap ended somewhere other than a clean handover, and `state/.lead-restart.result` holds the outcome.

- `refused` - the previous session would not end, so nothing moved and that session is still in charge.
  Nothing to recover; report that the seat is unchanged.
- `stranded` - the previous session ended and the replacement did not come up in its terminal.
  The result record holds the exact command to run there, which is also staged as a file to source.
  This one is captain-facing, because only someone at that terminal can run it.
- `started` - the replacement is running but had not taken the home's lock yet when the stage stopped watching.
  Confirm with `bin/fm-lock.sh status`; the reservation lapses on its own either way.

Nothing else is ever affected by a failed swap, because the command only ever replaces one process: every task, local copy, PR, and durable record is exactly as it was.
