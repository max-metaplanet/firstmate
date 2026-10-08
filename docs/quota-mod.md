# Seat quota in Claude Code

The `firstmate-quota` mod under `.claude/mods/firstmate-quota` shows how much Claude quota is left, for the seat this session spends and for every other seat firstmate knows about.
It is a Claude Code plugin whose whole behavior lives in one function-hooks module, the same shape as the Calm mod.
The trusted project auto-loads it through the `.claude/skills/firstmate-quota` entry, a symlink into `.claude/mods`, so no `--plugin-dir` or marketplace install is needed.

[`claude-seats.md`](claude-seats.md) owns the seats themselves: what a seat is, how one is added or logged into, and which seat new workers launch on.
This file owns only the display.

## Activation

Claude Code loads hooks modules on its own terms, so the mod carries its own gate: it requires the environment variable `FM_QUOTA_ENABLED` to equal `1` before doing anything.
Firstmate never sets that variable in any project or user settings; enabling it is each captain's own explicit opt-in.
Without it the mod is a complete no-op even though Claude Code loads the module: there is no `/seats` command, no timer, no seat read, and every drawing stays exactly as Claude Code draws it.
An unreadable value reads as unset, and `FM_QUOTA_ENABLED=0` is an explicit off.

This is the same gate design as Calm's `FM_CALM_ENABLED`, which [`calm.md`](calm.md#claude-code) owns, with one deliberate difference.
Calm also reads the deprecated `CLAUDE_CODE_ENABLE_FUNCTION_HOOKS` as an alias, because Calm once shipped behind that platform flag and a session still carrying only the old name must keep working.
This mod has never shipped behind it, so it does not read that name at all: honouring it would turn an unrelated older opt-in into a new drawing the captain never asked for.

Each mod gates separately, so Calm and Quota are enabled independently.

## What it shows, and where each figure comes from

The two halves of the display have completely different costs and completely different freshness, and the mod never blurs them.

**This session's own seat is exact and free.**
Claude Code's own `$.session.usage()` carries the account's rate-limit windows, and it raises a measurement whenever one of them moves.
No process runs, no quota endpoint is called, and nothing is cached: the figure is as current as the last response.
The engine reports how much of a window is *used*, and every firstmate seat setting counts percent *left*, so the mod converts once and shows percent left throughout.
An exceeded spend limit reports past 100 used and is shown as nothing left rather than as a negative number.

**Every other seat comes from the reports firstmate already caches.**
`bin/fm-seat-board.sh` is the one owner of the per-seat quota read and its cache, because the Claude quota endpoint rate-limits frequent polling.
Its `json` action prints the same reading the seat board's page shows, with every seat dated separately, and the mod displays that.

A reading is never presented as current when it is not:

- every non-live figure carries its own age, taken from that seat's own cache file;
- a figure older than the board's cache window is labelled stale, and the window used is the board's own, so the two can never disagree about what current means;
- a seat whose report could not be read says so, and a seat that is not logged in shows the attention line the quota reader itself gave, rather than a zero that reads like an exhausted account;
- a reading the mod does not understand, including one of another schema version, is refused outright rather than half-drawn.

Ten-day-old cached percentages are a real state of this machine, not a hypothetical, which is why the labelling is a requirement rather than a nicety.

## The band

One line above the prompt, and only when there is something honest to put on it.
It carries this session's seat and each of its windows' percent left, with the reset wait shown on the tightest window alone, then the tightest figure among the other seats with that figure's own age.
A comfortable line is dim, a window at or below 40% left draws as a warning, and one at or below 15% left draws tight.

Before the first measurement there is no reading at all, and off a subscription there never is one, so the band draws nothing rather than a zero.
Another mod's band content survives: the mod takes what the plugins beneath it drew and puts its own line below, rather than replacing it.

## `/seats`

`/seats` opens a pane listing every configured seat: its name, which of them this session is on, which one new workers launch on, which are held out of automatic rotation, the account, the figures, and each reading's age.
The seat this session is on and the seat new workers launch on are shown separately because they are genuinely different facts: switching the active seat never moves a running worker.
A seat the [quota floor](claude-seats.md#resting-a-seat-below-a-quota-floor) is resting carries the same "held out of automatic rotation" mark as one held out by hand, because the mod reads the one flag that answers whether an automatic switch may land there; the seat board's own page and `bin/fm-seat.sh status` are where the two are told apart.

Nothing a mod draws is visible in a `claude -p` run, an SDK session, or the VS Code chat panel, so in a session that cannot draw `/seats` answers with the same content as text instead.

## Cadence

Drawing never reads anything.
Every band and pane draws the reading already in memory, so no redraw can turn into a quota call and no hook spends its time budget on a process.

A session start takes one cached read, which cannot reach the quota endpoint at all.
After that, a refreshing read is allowed at most once every ten minutes, behind a guard that refuses a second read while one is running.
`FM_QUOTA_REFRESH_SECONDS` changes that interval but is held to a floor of two minutes, and an unreadable value keeps the default rather than being read as zero.
Across four seats the default is under one call per seat every ten minutes, against the per-seat-per-minute rate a naive poll would produce.

An expired cache that cannot be refreshed is still shown, with its real age, rather than being dropped.
Each age keeps advancing with the clock between reads, so a figure that was fresh when read is called stale once it passes the board's cache window.

The pane's Refresh (`r`) rereads the cache at once and never reaches the quota endpoint, so it cannot bring the next refreshing read any sooner; the pane says when that next refreshing read is allowed.

## What it never does

- It never changes a seat setting or any configuration.
  The only thing it writes is the board's own quota cache, which a refreshing read refills through `bin/fm-seat-board.sh`.
- It never polls the quota endpoint per seat per render or per minute, and a cached read never reaches it even once.
- It never refuses to start a worker on a low seat.
  That is a real lever and it needs the captain's own explicit say-so first; `bin/fm-seat.sh` already owns automatic seat switching and the extra-usage policy.
- It never switches seats or changes which seat new workers launch on.

## Bounds

- The function-hooks surface the mod draws through states in its own generated declarations that its API may change between releases without notice; the mod is verified on Claude Code 2.1.291, refuses nothing newer, and pins no version.
- A pane the mod opened itself would need 144 terminal columns, so `/seats` opens from the captain's own command, which seats at any width.
- The band's figures for other seats are only ever as fresh as the cache allows, by design; the seat board's page, or `bin/fm-seat.sh status`, is the way to force a current reading of every seat.

Regression entry points:

```sh
tests/fm-quota-claude-mod.test.sh
tests/fm-quota-claude-mod-plugin.test.sh
tests/fm-seat-board.test.sh
```
