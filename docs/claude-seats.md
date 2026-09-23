# Claude seats: running workers on a second account

A **seat** is one Claude account that Firstmate's workers can run on.
Switching seats changes which account new workers bill to, without disturbing any worker already running.

Use this when one account's weekly limit is close and a second account is available, or when work should be split across accounts deliberately.
[`docs/configuration.md`](configuration.md) owns the setting schema; `bin/fm-seat.sh --help` owns the exact command surface.

## How it works, in one paragraph

Claude Code reads its profile - settings, session history, and credentials - from the directory named by `CLAUDE_CONFIG_DIR`, defaulting to `~/.claude`.
It derives that profile's macOS Keychain service name from a hash of the directory path, so each profile directory has its own credential store.
A seat is therefore just a directory, and switching seats is just choosing which directory the next worker launches with.
Firstmate never logs in, never copies a credential between profiles, and never touches the Keychain: only the account owner signs a seat in, personally.

## Adding a second seat

Three steps, and only the second one needs the account owner.

**1. Create the seat.**

```
bin/fm-seat.sh add work
```

This creates an empty profile directory (by default `~/.claude-seats/work`) and prints the login command for step 2.
It writes nothing else and reads no credential.

**2. The account owner logs in.**

This step cannot be automated and cannot be done on the owner's behalf.
In a terminal, the owner runs the command step 1 printed:

```
CLAUDE_CONFIG_DIR=~/.claude-seats/work claude
```

then types `/login` in that session and signs in as the account this seat should bill to.
Claude Code stores the resulting credentials under a Keychain entry belonging to that directory, so they never mix with the default login.
The owner can then exit that session; it was only needed to carry out the sign-in.

**3. Confirm the seat is usable.**

```
bin/fm-seat.sh probe work
```

`logged-in` means the seat is ready.
`not-logged-in` means step 2 has not completed for this directory.

## Switching now

```
bin/fm-seat.sh switch work
```

That is the whole manual switch, and it takes effect immediately for the next worker launched.
`bin/fm-seat.sh switch default` returns to the ambient login.

A switch is refused when the target seat has no credentials, because every worker sent there would fail on its first message.

## What a switch does and does not touch

A switch rewrites one setting that only a fresh spawn reads.

- **New workers** launch on the new seat.
- **Running workers** keep the seat they started on. Their seat is recorded in their own task record at launch, and nothing rewrites it.
- **Relaunches and resumes** of an existing task reuse that recorded seat, never the current setting. This matters beyond billing: a task's session history lives under its profile directory, so moving a task between seats would strand it.

`bin/fm-seat.sh status` shows the active seat alongside every task's own recorded seat, which is how to confirm a switch left running work alone.

## Switching automatically at a threshold

The automatic path is the same switch, fired by a condition instead of by hand.
It is off until configured; there is no default that moves accounts on its own.

```
bin/fm-seat.sh threshold 15     # switch when the active seat drops to 15% remaining
bin/fm-seat.sh arm
```

`arm` registers one condition-to-action watch: the condition reads the same quota surface the rest of the fleet reads, and the action is `switch --next`, which rotates to the next logged-in seat.
It runs on the supervision cycle that already exists rather than a daemon of its own, and it fires **at most once**, which is what makes it edge-triggered.
Re-arm after it fires to watch the next crossing.

An unreadable quota is treated as an error, never as a threshold crossing, so a failed read never switches accounts.
A rotation with no other logged-in seat refuses rather than pretending to switch.

`bin/fm-seat.sh threshold off` clears the threshold, and `bin/fm-seat.sh retire` stops the watch.

## Secondmate homes

All three seat settings are inherited into secondmate homes through the primary-authoritative configuration contract, so a secondmate's own Claude crewmates launch on the same seat as the primary's.
The seats themselves live outside any firstmate home - by default under `~/.claude-seats` - so the owner logs into a seat once and every home on the machine reaches the same profile.
A home that needs its own set of seats overrides `config/claude-seats-root`.

## Limits worth knowing

The login probe runs `quota-axi` against the seat's profile and treats an `oauth` source as logged in.
When that read cannot reach a verdict at all, `switch` reports the uncertainty and `--force` is available; `--force` never overrides a seat proven to have no credentials.

Seat switching covers Claude workers only.
Other harnesses have their own credential stores and are unaffected by these settings.
