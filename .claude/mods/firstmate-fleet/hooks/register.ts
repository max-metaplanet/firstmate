// Firstmate Fleet for Claude Code: the hooks module of the `firstmate-fleet` mod.
//
// A Claude Code "mod" is a plugin whose behavior lives in one hooks module. Claude Code
// loads this module on its own terms, but every handler requires the firstmate-owned
// `FM_FLEET_ENABLED` to equal `1`, so loading alone remains a complete no-op: no
// command, no timer, no reading of a Firstmate home, and every drawing exactly as
// Claude Code draws it. docs/fleet-mod.md owns the captain-facing contract.
//
// What it gives a supervision session, all of it read-only:
//
//   /fleet       one row per task: state, the evidence that state came from, age, and
//                the last wake event beneath it. A pane where the session can draw, the
//                same rows as text where it cannot.
//   the band     one line above the prompt naming what waits on the captain - a
//                decision, a merge, or a blocker - and nothing at all when the set is
//                empty, so the one case that matters stays visible.
//   notices      a transient line the moment a task first reaches done, blocked, or
//                failed, never for a state the session already found on its first read,
//                and one when the reader stops answering.
//
// The one data source is `bin/fm-fleet-snapshot.sh --json`, the only reader that
// reconciles the append-only status EVENT log against liveness. It is measured at
// 17.7-21.6s against a 10s hook budget, and two overlapping runs were measured at 72s
// where one takes 18s. Both facts shape this file: the command runs only from the 60s
// timer, one un-awaited read at the start of a session that can draw, and /fleet's own
// read in one that cannot, all behind a single in-flight promise, and a `ui.render` hook
// never starts it and only ever draws the cache.
//
// This file is the only place the engine interface `$` is touched. Every reading
// decision - what a state word may claim, what waits on the captain, how a failed or
// aged read is described - lives in ../lib/fm-fleet-view.ts, and which transitions earn
// a notice in ../lib/fm-fleet-toasts.ts, so the policy is testable under Node and the
// engine glue under `claude plugin test`.
//
// Loading is lazy and cached within a module environment: a hot reload can reach any
// hook before `session.start`, so every activated hook awaits the load that resolves the
// reading command and starts the clock. Whether the session can draw is the one fact
// only `session.start` knows; it is kept in `$.state`, which a reload leaves alone.
import type { EngineInterface, NextBudget, Register, RenderElement, RenderInput } from "claude-code";
import { fleetActivationFromEnv } from "../lib/fm-fleet-activation.ts";
import {
  fleetBand,
  fleetFreshness,
  fleetFreshnessLine,
  fleetLines,
  fleetSnapshotCommand,
  fleetTextReport,
  parseFleetSnapshot,
  type FleetSnapshot,
  type FleetView,
} from "../lib/fm-fleet-view.ts";
import { FLEET_OUTAGE_AFTER_FAILURES, fleetOutageText, fleetToasts } from "../lib/fm-fleet-toasts.ts";

/** The pane's id, and the slash command that opens it. */
const FLEET_PANE = "fleet";

/** How often the slow authoritative reading is re-run. */
const FLEET_REFRESH_MS = 60_000;

/**
 * The timeout the reading is given.
 *
 * `$.process.run` defaults to 30s and rejects on a timeout, which would turn an ordinary
 * slow reading into a reported failure; the command itself measures 17.7-21.6s.
 */
const FLEET_SNAPSHOT_TIMEOUT_MS = 90_000;

/** How much of its 10s budget the /fleet text answer keeps back to answer in. */
const FLEET_TEXT_MARGIN_MS = 2_000;

// One module environment holds one cached reading; a hot reload starts a fresh one.
let activation: Promise<boolean> | undefined;
let loading: Promise<void> | undefined;
/** The resolved reading command, or an empty array before the load has resolved it. */
let snapshotCommand: string[] = [];
let snapshot: FleetSnapshot | undefined;
let snapshotAtMs: number | null = null;
let readError = "";
/** The one reading in flight, so two never contend for the same home. */
let inFlight: Promise<void> | undefined;
/** The state word last announced per task, or undefined before the first reading. */
let announced: Map<string, string> | undefined;
/** Failed readings since the last good one. */
let failedReadings = 0;
/** session.start's own isInteractive, or undefined before it has run in this module. */
let drawable: boolean | undefined;
let ticker: { cancel(): void } | undefined;

async function readActivation($: EngineInterface): Promise<boolean> {
  // The name is spelled literally because the engine's static analysis lists the
  // variables a module reads only from a literal argument.
  const value = await $.env.get("FM_FLEET_ENABLED").catch(() => undefined);
  return fleetActivationFromEnv(value);
}

function isActivated($: EngineInterface): Promise<boolean> {
  if (activation === undefined) activation = readActivation($);
  return activation;
}

/** False in a `-p` run or the SDK, where nothing a mod draws is ever seen. */
const canDraw = { plugin: "firstmate-fleet", key: "canDraw" } as const;

async function load($: EngineInterface): Promise<void> {
  snapshotCommand = fleetSnapshotCommand(
    await $.env.get("FM_ROOT_OVERRIDE").catch(() => undefined),
    $.plugin.root,
  );
  ticker ??= $.clock.every(FLEET_REFRESH_MS, () => {
    void refresh($);
  });
}

/**
 * Whether anything drawn is seen. The module's own copy outlives a /clear, which resets
 * `$.state`; the `$.state` copy outlives a hot reload, which resets the module.
 */
async function sessionCanDraw($: EngineInterface): Promise<boolean> {
  if (drawable !== undefined) return drawable;
  const held = await $.state.get(canDraw).catch(() => undefined);
  return held?.value === true;
}

/** Whether the mod is on, with the reading command and the clock in place when it is. */
async function isReady($: EngineInterface): Promise<boolean> {
  if (!(await isActivated($))) return false;
  if (loading === undefined) loading = load($);
  await loading;
  return true;
}

/** The cached reading as the drawing functions take it. */
async function view($: EngineInterface): Promise<FleetView> {
  let nowMs = snapshotAtMs ?? 0;
  try {
    nowMs = await $.clock.now();
  } catch {
    // An unreadable clock only costs the age wording; the rows themselves still draw.
  }
  return { snapshot, snapshotAtMs, nowMs, error: readError };
}

/**
 * One reading, as the cache takes it: the parsed fleet, or a readable reason it did not
 * land. Never rejects, because a swallowed failure would draw as a healthy empty fleet.
 */
async function takeReading($: EngineInterface): Promise<FleetSnapshot | string> {
  if (snapshotCommand.length === 0) return "the fleet reader has not been resolved yet";
  let result;
  try {
    result = await $.process.run(snapshotCommand, { timeoutMs: FLEET_SNAPSHOT_TIMEOUT_MS });
  } catch (error) {
    // `$.process.run` rejects when the program cannot start and when it times out.
    return error instanceof Error ? error.message : String(error);
  }
  if (result.exitCode !== 0) {
    const detail = result.stderr.trim().split("\n")[0] ?? "";
    return detail === ""
      ? `the fleet reading exited ${result.exitCode}`
      : `the fleet reading exited ${result.exitCode}: ${detail}`;
  }
  try {
    return parseFleetSnapshot(result.stdout);
  } catch (error) {
    return error instanceof Error ? error.message : String(error);
  }
}

/** One reading: replace the cache, announce new outcomes, and redraw either way. */
async function readFleet($: EngineInterface): Promise<void> {
  const outcome = await takeReading($);
  if (typeof outcome === "string") {
    // The last good rows stay; the surfaces mark them stale with this reason.
    readError = outcome;
    // The band stays silent when nothing waits, so a reader that keeps failing is said
    // once here; a lone failure stays quiet, and only a good reading re-arms the notice.
    failedReadings += 1;
    if (failedReadings === FLEET_OUTAGE_AFTER_FAILURES) $.ui.toast(fleetOutageText(await view($)));
  } else {
    failedReadings = 0;
    snapshot = outcome;
    readError = "";
    try {
      snapshotAtMs = await $.clock.now();
    } catch {
      snapshotAtMs = null;
    }
    const round = fleetToasts(announced, outcome.rows);
    announced = round.announced;
    for (const toast of round.toasts) $.ui.toast(toast.text);
  }
  // Every reading redraws, a failed one included, so a drawing never goes on claiming
  // more than the mod still knows.
  $.ui.invalidate("ui.render");
}

/**
 * Start a reading unless one is already under way, and resolve when it has landed.
 *
 * Two overlapping runs of this command were measured at 72s wall where one takes 18s, so
 * a second caller joins the run in flight rather than starting its own.
 */
async function refresh($: EngineInterface): Promise<void> {
  const current = inFlight;
  if (current !== undefined) {
    await current;
    return;
  }
  // readFleet never rejects, so this promise is always safe to share and to await.
  const run = readFleet($);
  inFlight = run;
  try {
    await run;
  } finally {
    if (inFlight === run) inFlight = undefined;
  }
}

/**
 * Wait for a reading the text answer can carry, inside this hook's budget.
 *
 * A reading this hook starts is its own `$.process.run`, which the budget does not count.
 * Joining one the clock started is waiting on the module's own promise, which it does,
 * so that wait ends short of the budget and the answer says the reading is under way.
 */
async function readForText($: EngineInterface, budget: NextBudget): Promise<void> {
  if (inFlight === undefined) return refresh($);
  const spareMs = budget.remainingMs - FLEET_TEXT_MARGIN_MS;
  if (!Number.isFinite(spareMs)) return refresh($);
  await Promise.race([refresh($), $.clock.sleep(Math.max(0, spareMs)).catch(() => undefined)]);
}

function paneTree($: EngineInterface, e: RenderInput, fleet: FleetView): RenderElement {
  const { Box, Text, Button } = $.ui.resolve(e);
  const width = typeof e.props.bodyColumns === "number" ? e.props.bodyColumns : 80;
  const freshness = fleetFreshness(fleet);
  const children: RenderElement[] = [];
  const band = fleetBand(fleet);
  if (band !== undefined) {
    children.push(Text({ color: band.tone, wrap: "truncate-end", children: [band.text] }));
  } else if (freshness.kind === "unread") {
    children.push(Text({ dimColor: true, children: [fleetFreshnessLine(freshness)] }));
  } else if (freshness.kind !== "fresh") {
    children.push(Text({ color: "yellow", wrap: "truncate-end", children: [fleetFreshnessLine(freshness)] }));
  }
  for (const line of fleetLines(fleet)) {
    const color = line.tone === "plain" ? undefined : line.tone;
    children.push(
      Box({
        flexDirection: "row",
        columnGap: 1,
        children: [
          Text({ color, children: [line.mark] }),
          Text({ bold: true, children: [line.id] }),
          Text({ dimColor: true, children: [line.kind] }),
          Text({ color, children: [line.state] }),
          Text({ dimColor: true, children: [`(${line.source})`] }),
          Text({ dimColor: true, children: [line.age] }),
        ],
      }),
    );
    if (line.lastEvent !== "") {
      children.push(
        Text({
          dimColor: true,
          wrap: "truncate-end",
          // Labelled as an event: the status log's last line is history, not a state.
          children: [`    event: ${line.lastEvent.slice(0, Math.max(20, width))}`],
        }),
      );
    }
  }
  children.push(
    Button({
      key: "refresh",
      label: "Refresh",
      hotkey: "r",
      plain: true,
      onPress: () => {
        void refresh($);
      },
    }),
  );
  return Box({ flexDirection: "column", children });
}

export const register: Register = (on) => {
  on("session.start", async ($, e, next) => {
    if (!(await isReady($))) return next(e);
    // `$.ui.open` answers placed even in a `-p` run, where nothing can draw, so the
    // only sound test of "will a person see this" is the session's own isInteractive.
    drawable = e.isInteractive === true;
    await $.state.set(canDraw, drawable).catch(() => undefined);
    // Un-awaited: the session must not wait out a 17.7-21.6s command to start. A session
    // that cannot draw has nothing to show it in, so /fleet takes that reading itself.
    if (drawable) void refresh($);
    // Last, and guarded: a taken name throws and would take the rest of this hook with
    // it, leaving the timer above unstarted.
    try {
      await $.command.register({
        name: FLEET_PANE,
        description: "Show the Firstmate fleet: every task, and what waits on you.",
      });
    } catch {
      // Another plugin owns /fleet; the band and the notices still work.
    }
    return next(e);
  });

  on("command.run", { command: FLEET_PANE }, async ($, e, next) => {
    if (!(await isReady($))) return next(e);
    if (await sessionCanDraw($)) {
      await $.ui.open({ id: FLEET_PANE, title: "Fleet", focus: true, closeOnEscape: true });
      return {};
    }
    // Nothing drawn is seen here, so the same rows go back as text. This is also the
    // one place a reading may be awaited: the captain asked for it and is waiting.
    if (snapshot === undefined && readError === "") await readForText($, next.budget);
    return { text: fleetTextReport(await view($)) };
  });

  on("ui.render", { component: "Pane" }, async ($, e, next) => {
    if (!(await isReady($))) return next(e);
    if (e.requestId !== FLEET_PANE) return next(e);
    // The cache only: the reading behind it is far past this hook's budget.
    return paneTree($, e, await view($));
  });

  on("ui.render", { component: "AbovePrompt" }, async ($, e, next) => {
    if (!(await isReady($))) return next(e);
    const band = fleetBand(await view($));
    // Nothing waiting and a reading that can say so: draw nothing whatsoever.
    if (band === undefined) return next(e);
    const { Box, Text } = $.ui.resolve(e);
    // Returning a tree replaces what later mods draw in the band, so theirs is nested
    // above this line rather than dropped.
    const theirs = await next(e);
    return Box({
      flexDirection: "column",
      children: [
        theirs,
        Text({ color: band.tone, wrap: "truncate-end", children: [band.text] }),
      ],
    });
  });
};
