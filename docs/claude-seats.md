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

**Keep every seat under the seats root, and leave the default profile out of the rotation.**
The default profile (`~/.claude`) is the account owner's own interactive login.
It changes whenever they sign in somewhere else, and nothing here can tell which account it currently holds, so an automatic switch must never land workers on it.
`switch --next` and the threshold watch therefore rotate only among named seats under the seats root; `switch default` remains available as an explicit, manual choice.
A named seat can be held out of that rotation the same way, by [excluding it](#keeping-a-seat-out-of-automatic-rotation), while staying reachable by name.
Creating one named seat per account, and leaving the default alone, keeps every account Firstmate uses identifiable and stable.

## Adding a second seat

If your machine is set up from the metaplanet-dev repository, build the seat with that repository's `claude-seats.sh setup`, documented in its `SETUP.md`, and then continue at step 2 below.
That script creates the seat directory and symlinks the shared body into it from your own `~/.claude`, so the seat carries your settings, hooks, skills, and agents while billing to its own account; it also verifies that two seats are not logged into the same account, and can undo itself.

Three steps, and only the second one needs the account owner.

**1. Create the seat.**

```
bin/fm-seat.sh add work
```

This creates an empty profile directory (by default `~/.claude-seats/work`) and prints the login command for step 2.
It writes nothing else and reads no credential.
`add` creates a bare directory and nothing more: a seat built this way has **none** of the owner's settings, hooks, skills, or agents, so it works but starts empty.
Use the `claude-seats.sh setup` route above when the seat should carry the shared body.

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
`expired-renewable` means the seat is signed in but its access token has lapsed; it is still ready, because the next worker launched there renews it.
See [Idle seats and lapsed tokens](#idle-seats-and-lapsed-tokens).
`not-logged-in` means the profile was read and holds no login, so step 2 has not completed.
`unknown` means the probe could not decide; on macOS that is how a seat reads both before step 2 and after it until the one-time Keychain approval described under [Limits worth knowing](#limits-worth-knowing).

`probe` exits 0 for a usable seat, which includes `expired-renewable`, 1 for `not-logged-in`, and 2 for `unknown`.

## Switching now

```
bin/fm-seat.sh switch work
```

That is the whole manual switch, and it takes effect immediately for the next worker launched.
`bin/fm-seat.sh switch default` returns to the ambient login.

A switch is refused when the target seat is not confirmed usable, because every worker sent there would fail on its first message; `--force` crosses only an `unknown` verdict.
A `not-logged-in` seat is refused outright and `--force` cannot cross it.
An `expired-renewable` seat needs no `--force`: the switch says the token lapsed and proceeds.

## What a switch does and does not touch

A switch rewrites one setting that only a fresh spawn reads.

- **New workers** launch on the new seat.
- **Running workers** keep the seat they started on. Their seat is recorded in their own task record at launch, and nothing rewrites it.
- **Relaunches** of an existing task reuse that recorded seat, never the current setting. Relaunch is the one path that starts a replacement agent for a task that already exists, so it is the one place this could have gone wrong. This matters beyond billing: a task's session history lives under its profile directory, so moving a task between seats would strand it.
- **Harness-changing relaunches** follow the harness. A task relaunched from another harness onto Claude has no Claude history yet, so it counts as a new worker and gets the active seat, never the default login. A task relaunched from Claude onto another harness records no seat any more.

`bin/fm-seat.sh status` shows the active seat alongside every task's own recorded seat, which is how to confirm a switch left running work alone.

## Switching automatically

The automatic path is the same switch, fired by a condition instead of by hand.
Every setting below is off until configured; there is no default that moves accounts, or holds work, on a home that never asked for it.
Every percentage counts **percent left**, the same direction the quota viewer reports, so no two settings here have to be mentally inverted against each other.

```
bin/fm-seat.sh threshold 15          # switch when the ACTIVE seat drops to 15% left
bin/fm-seat.sh destination-min 30    # only switch onto a seat with MORE than 30% left
bin/fm-seat.sh extra-usage stop      # when no seat qualifies, hold new work
bin/fm-seat.sh auto-exclude personal # keep one seat out of rotation entirely
bin/fm-seat.sh arm
```

### The four controls

**Trigger** (`threshold`) is when to look for a new seat: the active seat has dropped to or below that percent left.

**Destination headroom** (`destination-min`) is what counts as somewhere to go: a candidate must read **more** than that percent left.
A seat below it is skipped, and the refusal names each skipped seat with its measured headroom.
If no seat qualifies, nothing is switched.
Without this setting the rotation gate is login-only and no candidate's quota is read at all, which is how it behaved before the setting existed.

**Extra-usage policy** (`extra-usage`) is what to do when no seat qualifies and the active seat's plan quota is gone, so further work would run on paid extra usage.

- `stop` holds new Claude dispatch rather than starting workers on paid extra usage.
- `allow <usd>` keeps dispatching while that seat's extra-usage spend is below the dollar cap, and holds once it reaches it.
- `off` clears the policy, and nothing is held.

Spend is read from the `extra_usage` window the account itself reports, and the cap is a firstmate-side figure compared against it - deliberately a smaller, separate number from the account's own extra-usage ceiling.

**Rotation exclusion** (`auto-exclude`) is which seats an automatic switch may not land on at all, whatever their headroom.
It is the subject of [Keeping a seat out of automatic rotation](#keeping-a-seat-out-of-automatic-rotation) below.

`bin/fm-seat.sh status` prints all four settings, whether the watch is armed, and whether new Claude dispatch is held right now, with the same reason `bin/fm-spawn.sh` gives when it refuses a spawn.

### What the automatic mode cannot do

This is worth being exact about, because the setting is easy to read as a spend guarantee and it is not one.

Firstmate controls **which seat a new worker starts on**, and **whether new Claude work is dispatched at all**.
It cannot stop a worker that is *already running* from drawing paid extra usage mid-task.
A running worker keeps the profile recorded in its own task record, by design, and nothing outside the organisation's Claude admin setting can stop that profile spending once its plan quota is gone.

So `stop` means **stop starting new work**, plus a loud warning the moment a seat a worker is already running on enters extra usage.
That warning goes out through this home's one notification path, the same one the usage warner uses.
It is never a guarantee of zero spend, and nothing here should be read as one.

A single spawn can be pushed through a hold with `--ignore-seat-hold`; that changes no setting, so the next spawn is gated again.

### The watch

`arm` registers the automatic pass as this home's repeating Claude-seat check, so it runs on the supervision cycle that already exists rather than a daemon of its own.
It **keeps watching after a switch**: one crossing fires at most once per seat, and when the seat it moved to later crosses its own threshold, that fires again with nothing re-armed by hand.
A crossing with nowhere to go is reported once, but every later poll still looks for a destination, so a seat whose window resets is switched to on the next poll while the active seat stays below its trigger.
Each pass keeps every quota read inside the watcher's per-check timeout (`FM_CHECK_TIMEOUT`), capping one read at 10 seconds, and a read cut short counts as unreadable.
`bin/fm-seat.sh retire` stops it and removes its record.

### What never trips a switch

Only the account-level windows (`all_models` and `all_products`) count toward the trigger, the same scopes the dispatch chooser applies to a worker with no specific model; a model- or product-only window such as an Opus weekly limit does not trip a switch on its own.
For the `default` seat the condition reads the same profile a new worker on it gets, which is firstmate's own `CLAUDE_CONFIG_DIR` when that is set.

An unreadable or ambiguous quota is never guessed at, in either direction:

- The **active** seat's quota unreadable means no switch, and the watch stays silent rather than waking on every poll.
- A **candidate** seat's quota unreadable means that seat is skipped, and the output says the quota could not be read rather than implying a number.
- With an extra-usage policy configured, an unreadable quota **holds** dispatch, because launching anyway would be exactly the guess the policy was set to avoid. The hold lifts on its own once the quota reads again. The one exception is an active seat whose token has [lapsed](#idle-seats-and-lapsed-tokens): only a launch renews it, so holding would hold every spawn for good, and dispatch is allowed instead.

A rotation with no qualifying seat refuses rather than pretending to switch, and never falls back to the default profile or onto a seat held out of rotation.

`bin/fm-seat.sh threshold off`, `destination-min off`, and `extra-usage off` each clear their own setting, and `auto-include <name>` clears one exclusion.

## Keeping a seat out of automatic rotation

The other three controls all turn on *how much is left*.
This one does not: it holds a seat out of every automatic path regardless of headroom, while leaving it available by name.

```
bin/fm-seat.sh auto-exclude personal    # automatic switches may no longer land here
bin/fm-seat.sh auto-include personal    # put it back
bin/fm-seat.sh auto-exclude             # list what is currently held out
```

The case it exists for is a seat that is genuinely usable on this machine but belongs to a different payer - a personal account alongside the team ones.
Such a seat should be reachable deliberately and never be picked up by an automatic switch nobody was present for.
`destination-min` cannot express that, because it is about a seat being nearly empty rather than about whose account it is.

**What an exclusion changes, and what it does not.**

- `switch --next`, the armed watch's switch, the watch's instruction to move firstmate itself, and the `lead-restart` destination all skip an excluded seat. They read one shared candidate list, so none of them can be the one that forgets.
- `switch <name>` still reaches it. That is the point: the seat stays a deliberate choice and stops being an automatic one.
- An excluded seat is listed with its reason whenever a rotation refuses, so a switch that found nowhere to go never leaves you guessing which seats were withheld.
- Nothing moves when you exclude a seat. Excluding the **active** seat keeps it active and keeps new workers launching there; it only stops being a future automatic destination. Nothing moves a worker already running on it either.
- A seat is excluded regardless of how much it has left, so an exclusion is never lifted by a quota reading.

`bin/fm-seat.sh status` names every excluded seat, and `bin/fm-seat.sh list` marks each one on its own row, so an exclusion is never a setting you have to remember you made.

Both commands are idempotent: excluding an already-excluded seat and including one that was never excluded each succeed and say so.
`auto-exclude` refuses a name with no seat directory under the root, because an exclusion that matches nothing would silently keep rotating onto the seat it was meant to withhold; `auto-include` accepts any name, so a stale entry can always be cleared even after its seat is gone.
Excluding the `default` login is refused outright, because it is never an automatic rotation target in the first place.

If you exclude every candidate, nothing new happens: rotation falls through to the ordinary refusal that it has nowhere to go, naming each withheld seat, and `arm` refuses for the same reason rather than arming a watch that could never fire.

## Moving firstmate itself

Everything above moves **workers**.
Firstmate itself is not a worker, and no switch moves it.
It keeps the account its own process launched on, so after a few switches firstmate is commonly on a different seat from the one new workers get; `bin/fm-seat.sh status` prints both.

No running Claude Code process can change credential store, so firstmate changes account only by being replaced:

```
bin/fm-seat.sh lead-restart --check              # establish the move, change nothing
bin/fm-seat.sh lead-restart --persisted          # do it
```

Firstmate tells its crew it is about to restart, another `claude` starts on the new seat in the same terminal, resuming the same session, and the current process ends.
The replacement carries the ambient login the previous process started from, so the `default` seat still names that login for workers launched afterwards rather than the seat firstmate moved to.
A seat is a profile directory whose contents symlink the shared `~/.claude` body, which is what lets any seat resume the same session: the seat is the brain, the sessions and settings are the body.
Without `--to`, the destination is the ordinary rotation, anchored on the seat firstmate is on rather than the seat new workers get, and it skips an excluded seat like every other automatic path.

**Running workers are told, and are otherwise untouched.** Before the current process ends, each live worker gets one short notice that firstmate is restarting onto another seat, that its own work, seat, and steering inbox are unaffected, and that it should carry on without replying.
The notice is cheap because nothing changes for a worker: its steering is a durable inbox, its status is a durable log, and it keeps the seat recorded in its own task record.
So it is sent fire-and-forget, with no acknowledgement expected and no re-ring spanning the swap, and a worker it cannot reach never blocks the restart; that worker is named in `state/.lead-restart.result` instead.
Supervision is a separate process with its own lock and is deliberately not stopped, so the cycle count goes from one to one across the swap.
Its engine still follows the move, at its next turn; see [The engine's seat](supervision-host.md#the-engines-seat).

**`--persisted` is a gate, not a flag.** The replacement drops firstmate's conversation and keeps every durable record, so the open work held only in that conversation has to be written down first - the same persist step a second mate gets before its restart.
The command refuses without it.

**It refuses rather than guesses.** A destination that is not proven signed in, a firstmate that is not a Claude session, a terminal or launch command that cannot be established from the running process, or a caller that is not this home's firstmate each refuse before anything is touched, leaving the current session running and in charge.
For the launch command that means an argument vector this machine can only read back flattened - where a multi-word argument is indistinguishable from two arguments - is reported as not established rather than split; state it exactly with `--launch-command` when that happens.

**Automatically**, the armed watch asks the same threshold question about firstmate's own seat, and firstmate carries that move out itself when the crossing fires.
It needs no approval: you set the threshold, so the threshold firing is the instruction, and the move happens whether or not you are at the terminal.
The watch hands the move to firstmate rather than performing it, because the poll runs in a separate process and cannot write firstmate's conversation down for it - so firstmate persists that open work first, then runs the same command above.
The watch hands over nothing unless the move is actually available, so a crossing with no signed-in destination, or no established terminal, names that blocker instead.

**If it fails after the previous process has ended** there is no going back to it: the outcome is recorded in `state/.lead-restart.result`, the home's reservation is dropped, and firstmate is woken.
Recovery is one command in that same terminal, printed in that record and staged as a file to source.
Nothing else is affected, because the command only ever replaced one process: every task, local copy, PR, and durable record is exactly as it was.

## Idle seats and lapsed tokens

A Claude access token lives eight hours from its last refresh.
A seat nothing has launched on for that long still holds its session, but its access token has lapsed, and it reads as `expired-renewable` rather than `logged-in`.
With two seats and a working day, the seat you are not using is in that state for most of the time it spends as a rotation candidate, so it is the normal reading for an idle seat rather than a fault.

Such a seat is usable.
Launching a claude worker on it makes Claude Code perform the refresh exchange against its own stored refresh token and rewrite the store, which is how the seat recovers; no operator step is needed.
So `probe` reports it usable, `switch` accepts it with no `--force`, and rotation treats it as a destination.

Firstmate never performs that renewal itself.
Every quota read it makes passes `--no-credential-refresh`, which keeps the read from delegating a token renewal to the vendor CLI.
That is deliberate and load-bearing: the refresh token behind a session is single-use, so a second refresher racing the Claude Code session that owns it can leave one holder presenting a spent token and sign the account out.
The worker launch is the only thing that renews a seat.

One consequence is worth planning around.
A lapsed seat has **no readable quota** until something renews it, so it cannot answer a headroom comparison.
With `destination-min` set, a lapsed seat is therefore skipped as a rotation destination - reported as unreadable headroom, not as a login problem - which means a home that sets a destination minimum will rotate only onto seats something has read recently.
If you want rotation to reach idle seats, leave `destination-min` unset so the gate stays login-only.
The extra-usage dispatch gate does not hold on a lapsed active seat for the same reason: the launch it would hold is the only thing that can renew the token.

A seat that is genuinely signed out is a different state and is still refused.
When Anthropic definitively rejects a refresh token, Claude Code clears the session in place, and the seat reads `not-logged-in`; `--force` cannot cross that, and the seat needs the owner's login steps again.

## Secondmate homes

All six seat settings are inherited into this machine's local secondmate homes through the primary-authoritative configuration contract, so a secondmate's own Claude crewmates launch on the same seat as the primary's and no local home automatically rotates onto a seat the primary held out.
Every switch, manual or automatic, runs `bin/fm-config-push.sh --local-only` right after it changes the primary's seat, so running local secondmates pick up the new seat without being stopped, and the switch prints which homes were updated and which were not.
A failed push never undoes the primary's switch: it is reported, those homes keep spawning on their previous seat, and re-running `bin/fm-config-push.sh --local-only` retries them.
The push skips remote routes entirely, so a switch never opens SSH, never waits on another machine, and reports only this machine's homes.
Remote secondmate homes on other machines never receive seat settings, because a seat is a Keychain-backed profile logged in on this machine only; a remote home keeps its own login exactly as before seats existed.
The seats themselves live outside any firstmate home - by default under `~/.claude-seats` - so the owner logs into a seat once and every home on the machine reaches the same profile.
A home that needs its own set of seats overrides `config/claude-seats-root`.

### One home on a separate account

The default above is the whole machine moving together, and it stays the default.
When one local home must spend a different account - a personal or client account while the rest run on the team account - that home declines the inheritance itself:

```
touch <that home>/config/claude-seat-local
```

The file's presence is the whole setting; nothing reads its content.
From then on that home keeps its own `claude-seat`, `claude-seats-root`, `claude-seat-threshold`, `claude-seat-destination-min`, `claude-seat-extra-usage`, and `claude-seat-auto-exclude` untouched, including when it has none, and no local convergence overwrites them: not a switch's push, not the session-start secondmate sweep, and not that home's own launch or relaunch.
When the primary launches or relaunches that home's own firstmate, the launch uses that home's active seat, and the extra-usage dispatch gate reads that home's seat and policy rather than the primary's.
The declining home still runs `bin/fm-seat.sh switch`, `threshold`, `destination-min`, `extra-usage`, `auto-exclude`, and `arm` normally; those act on itself alone.
Only that home is left alone - every other local home still takes each switch, and a machine with no such file anywhere behaves exactly as it did before the flag existed.

The decline is visible from the primary, because a setting that silently does nothing is the failure worth avoiding here.
`bin/fm-seat.sh status` lists every local secondmate home that declined, with the seat that home is actually on, and each switch names the seat items it skipped for that home and why.
Put the flag only in the home it belongs to: it is never inherited, so one home's billing choice is never decided for it elsewhere.
[Configuration](configuration.md#claude-seats-configclaude-seat-configclaude-seats-root-configclaude-seat-threshold-configclaude-seat-destination-min-configclaude-seat-extra-usage-configclaude-seat-auto-exclude-configclaude-seat-local) owns the flag's schema.

## Glancing at every seat at once

`bin/fm-seat-board.sh` serves one read-only local page showing every seat's quota-axi report side by side: account email, each window's percent left and reset time, extra-usage spend against its cap, any attention line quota-axi reports, and which seat is active for new workers.
Run it and open the URL it prints; Ctrl-C stops it.
That URL carries a random path segment generated for that run, so open the printed one rather than a `http://127.0.0.1:<port>/` typed from memory, and `--port 0` takes a free port from the kernel and names it there too.
It never switches, arms, or edits anything, and it caches each seat's read for a minute so a page reload does not hit the quota endpoint again.
`bin/fm-seat-board.sh render` prints one generated page to stdout without starting a server, and `bin/fm-seat-board.sh json` prints the same reading as JSON for a reader that is not a browser.
Inside Claude Code, the same seats appear as a band and a `/seats` pane through the `firstmate-quota` mod, which [`quota-mod.md`](quota-mod.md) owns.

The page is for that machine's own browser and nothing else.
The server answers only a request whose `Host` header is `127.0.0.1` or `localhost` with its own port, and refuses anything else with a 403 and no page content.
Binding loopback on its own would not be enough: under DNS rebinding a hostile page re-points its own domain at 127.0.0.1, which makes it same-origin to the browser, and the account emails and quota figures on this page are exactly what it would then read.
`bin/fm-seat-board-server.py` owns that check and is the only thing that serves the page.

## Limits worth knowing

The login probe runs `quota-axi` against the seat's profile and treats an `oauth` source as logged in.
It also reads an `expired_refreshable` auth status, a machine-readable field that reports credential usability separately from quota freshness, as the lapsed-token state above.
It is read as a field, never as error text, because the same lapsed state is reported with different messages depending on whether the quota endpoint rate limited the read first.
A seat counts as definitively signed out only when every credential source was inspected and found missing or invalid; an `auth_required` status on its own does not count, because quota-axi also reports it for any rejected request against a credential that may still renew.
Note that `quota-axi --profile-only` is **not** a usable probe here: that flag reads only a credential file and never the Keychain, so on macOS it reports "credentials missing" for a perfectly good seat.

A newly logged-in seat gets its own Keychain entry, and reading it from a different tool can require a one-time macOS approval.
Until that approval is given, the Keychain read is refused, and that refusal looks the same whether the seat was never logged into or is signed in but not yet approved.
The probe cannot tell those two apart, so it reports `unknown` for both, and a plain `switch` refuses.
To settle it, the owner runs `quota-axi --allow-keychain-prompt` once with that seat's `CLAUDE_CONFIG_DIR` set and answers the prompt with "Always Allow"; after that a signed-in seat probes as `logged-in`.
In the meantime `switch --force` accepts the uncertainty: if the seat turns out to be empty, the next worker stops on its first message with `Not logged in` rather than spending another account.
`--force` never overrides `not-logged-in`, which the probe reports only when the evidence positively shows no login.
On macOS a seat that was **never** logged into still reads `unknown` rather than `not-logged-in`, because an absent Keychain entry reads as unreadable rather than as read-and-empty.
A seat that was logged in and later signed out is different: Claude Code clears the session in place, leaving an entry that can be read and is empty, and that reads `not-logged-in`.
On a file-backed credential store both cases are reported normally.
`--force` also never switches to a seat with no profile directory under the seats root; create it with `fm-seat.sh add <name>` first.

Two things in the setup flow above are **written from Claude Code's documented behaviour and the isolation this change verified, not from an observed sign-in**, because verifying them would mean logging in, which this work deliberately does not do:

- the exact prompts `/login` shows in a brand-new empty profile, and
- whether signing into a second account affects an already running session on the default profile.

Treat step 2 as the shape of the flow rather than a transcript, and expect the sign-in screens to be whatever the installed Claude Code shows.
What *was* verified directly is the part the mechanism depends on: a profile directory that was never logged into does not fall back to the default account, it stops with `Not logged in`, and each profile gets its own Keychain entry derived from its directory path.

This page is verified on macOS only, and its probe and login behaviour are described in terms of the macOS Keychain: seats are separated because Claude Code derives a Keychain service name from the profile directory's path, and the `unknown` verdict and one-time approval above are Keychain behaviours.
On Linux, where Claude Code keeps credentials in a file inside the profile directory rather than in the Keychain, the same directory separation applies but those Keychain-specific readings do not; that platform is unverified here, and Windows is out of scope.

Seat switching covers Claude workers only.
Other harnesses have their own credential stores and are unaffected by these settings.
