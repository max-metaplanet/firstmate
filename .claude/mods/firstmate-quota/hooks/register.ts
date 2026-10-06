// Firstmate Quota for Claude Code: the hooks module of the `firstmate-quota` mod.
//
// A Claude Code "mod" is a plugin whose behavior lives in one hooks module. Claude Code
// loads hooks modules on its own terms, so this mod carries its own firstmate-owned
// gate: every handler requires `FM_QUOTA_ENABLED` to equal `1`, and loading the module
// without that opt-in is a complete no-op. Firstmate never writes that name into any
// settings file; enabling it is the captain's own explicit opt-in, as for the Calm mod.
// docs/quota-mod.md owns the captain-facing contract.
//
// This file is the only place the engine interface `$` is touched: the live seat's
// reading policy lives in ../lib/fm-quota-live.ts, the all-seats reading in
// ../lib/fm-quota-seats.ts, and the refresh cadence in ../lib/fm-quota-cadence.ts, so
// the policy is testable under Node and the engine glue under `claude plugin test`.
//
// What it shows, and where each figure comes from:
//
//   - This session's own seat is free and exact. `$.session.usage()` carries the
//     account's `rateLimits` and `session.measure` fires when a window moves, so the
//     band's own figures need no process, no quota-axi, and no cache. An empty reading
//     draws nothing: the engine reports no window off a subscription or before the first
//     response, and a missing figure must never draw as a zero.
//   - Every other seat comes from the per-seat reports firstmate already caches.
//     `bin/fm-seat-board.sh json` owns that cache and dates every seat separately, so
//     each row carries its own age, advanced by the engine's clock from the moment it was
//     read, and anything past the cache window says it is stale.
//     The Claude quota endpoint rate-limits frequent polling, so a refreshing read is
//     allowed at most once every ten minutes behind an in-flight guard, and no drawing
//     ever triggers one. The pane's Refresh takes only a cached read.
//
// The mod changes no seat setting and no configuration. The only thing it writes is the
// board's own quota cache, which a refreshing read refills through bin/fm-seat-board.sh.
import type { EngineInterface, Register, RenderElement, RenderInput } from "claude-code";
import {
  liveBandSegment,
  liveTextLines,
  liveWindows,
  worstTension,
  type LiveRateLimit,
  type LiveWindow,
  type QuotaTension,
} from "../lib/fm-quota-live.ts";
import {
  ageWord,
  codeRootFromPluginRoot,
  freshnessWord,
  parseSeatBoard,
  seatBoardCommand,
  seatFiguresText,
  seatLine,
  seatRows,
  seatsBandSegment,
  type SeatBoard,
  type SeatRow,
} from "../lib/fm-quota-seats.ts";
import {
  nextRefreshWord,
  refreshDecision,
  refreshIntervalMs,
  QUOTA_CACHED_TIMEOUT_MS,
  QUOTA_REFRESH_TIMEOUT_MS,
  QUOTA_TICK_MS,
} from "../lib/fm-quota-cadence.ts";

/** The slash command the mod serves, and the pane id it draws under. */
const SEATS_COMMAND = "seats";

// One module environment holds one reading; a hot reload starts a fresh one.
let activation: Promise<boolean> | undefined;
let boardCommand: string | undefined;
let refreshEvery = 0;
let canDraw = false;
let ticker: { cancel(): void } | undefined;
// The live seat's own windows, from the engine. Empty until the first reading.
let live: LiveWindow[] = [];
// The last reading of every seat, and why there is none when there is none.
let board: SeatBoard | undefined;
let boardReadAtMs = 0;
let boardError = "";
let reading: Promise<void> | undefined;
let readingRefreshing = false;
let lastClaimedAtMs: number | undefined;

/**
 * The firstmate-owned activation gate, resolved once per module environment.
 *
 * `FM_QUOTA_ENABLED` must be exactly `1`. Unlike the Calm mod, nothing here reads
 * `CLAUDE_CODE_ENABLE_FUNCTION_HOOKS`: that alias exists only so a session which opted
 * into Calm under the dead platform flag keeps Calm, and this mod has never shipped
 * behind it, so honouring it would turn an old unrelated opt-in into a new drawing. An
 * unreadable name reads as unset and leaves the mod inactive.
 */
function isActivated($: EngineInterface): Promise<boolean> {
  const resolved =
    activation ??
    $.env.get("FM_QUOTA_ENABLED").then(
      (value: string | undefined) => value === "1",
      () => false,
    );
  activation = resolved;
  return resolved;
}

/** The label the live seat draws under, honest even before any seat reading exists. */
function liveSeatLabel(): string {
  return board?.liveSeat === undefined || board.liveSeat === "" ? "this seat" : board.liveSeat;
}

/** The engine's colour for one tension, or none while a figure is comfortable. */
function tensionColor(tension: QuotaTension): string | undefined {
  if (tension === "tight") return "red";
  if (tension === "warn") return "yellow";
  return undefined;
}

/**
 * One reading of every seat.
 *
 * `refreshing` false reads only what is already cached and so can never reach the quota
 * endpoint; true lets the board refill the seats whose cache has expired, and only the
 * cadence policy decides when that is allowed. A failed read keeps the previous reading
 * and records why, so the pane can say it is showing an older answer rather than going
 * blank.
 */
async function read($: EngineInterface, refreshing: boolean): Promise<void> {
  const command = boardCommand;
  if (command === undefined) return;
  const argv = refreshing ? [command, "json"] : [command, "json", "--cached-only"];
  try {
    const result = await $.process.run(argv, {
      timeoutMs: refreshing ? QUOTA_REFRESH_TIMEOUT_MS : QUOTA_CACHED_TIMEOUT_MS,
    });
    if (result.exitCode !== 0) {
      boardError = `the seat reader exited ${result.exitCode}`;
      return;
    }
    const parsed = parseSeatBoard(result.stdout);
    if (parsed === undefined) {
      boardError = "the seat reader printed a reading this mod does not understand";
      return;
    }
    board = parsed;
    boardReadAtMs = await $.clock.now();
    boardError = "";
  } catch (error) {
    boardError = error instanceof Error ? error.message : String(error);
  }
}

/**
 * Start one reading, unless one is already running.
 *
 * The in-flight guard is the whole point: two overlapping reads contend on the same
 * cache files and on the endpoint, so a second is dropped rather than queued.
 */
function startRead($: EngineInterface, refreshing: boolean): void {
  if (reading !== undefined) return;
  readingRefreshing = refreshing;
  reading = read($, refreshing).then(
    () => {
      reading = undefined;
      $.ui.invalidate("ui.render");
    },
    () => {
      reading = undefined;
    },
  );
}

/**
 * One timer tick: refresh the seats only when the cadence allows it.
 *
 * The clock is read first and the interval is claimed before anything can suspend
 * again, so a burst of catch-up ticks after the machine slept cannot each decide a
 * refresh is due and reach the endpoint together.
 */
async function tick($: EngineInterface): Promise<void> {
  const now = await $.clock.now();
  // Every age on screen is derived from the clock, so a redraw is what moves it.
  if (board !== undefined) $.ui.invalidate("ui.render");
  const decision = refreshDecision(
    { lastClaimedAtMs, inFlight: reading !== undefined && readingRefreshing },
    now,
    refreshEvery,
  );
  if (decision === "wait") return;
  lastClaimedAtMs = now;
  if (decision === "claim-only") return;
  // A cached read in flight touches no network, so the refresh waits it out rather
  // than being dropped and slipping a whole interval.
  while (reading !== undefined && !readingRefreshing) await reading;
  startRead($, true);
}

async function load($: EngineInterface, isInteractive: boolean): Promise<void> {
  canDraw = isInteractive;
  boardCommand = seatBoardCommand(codeRootFromPluginRoot($.plugin.root));
  refreshEvery = refreshIntervalMs(await $.env.get("FM_QUOTA_REFRESH_SECONDS").catch(() => undefined));
  live = [];
  board = undefined;
  boardReadAtMs = 0;
  boardError = "";
  reading = undefined;
  readingRefreshing = false;
  // The gate opens one whole interval after the session starts, not on the first tick:
  // a session that has just read the cache has no reason to spend a quota call yet.
  lastClaimedAtMs = await $.clock.now();
  if (ticker === undefined) {
    ticker = $.clock.every(QUOTA_TICK_MS, () => {
      void tick($);
    });
  }
  // The first reading is the cheap one: a session must start instantly and must not
  // spend a quota call just by opening.
  startRead($, false);
}

/** The band's one line, or undefined when there is nothing honest to say. */
function bandLine(nowMs: number): { readonly text: string; readonly tension: QuotaTension } | undefined {
  const rows = board === undefined ? [] : seatRows(board, boardReadAtMs, nowMs);
  const ours = liveBandSegment(liveSeatLabel(), live);
  const theirs = seatsBandSegment(rows);
  const parts = [ours, theirs].filter((part): part is string => part !== undefined);
  if (parts.length === 0) return undefined;
  return { text: parts.join("  │  "), tension: worstTension(live) };
}

/** The pane's rows as plain lines, which is also the text a session that cannot draw gets. */
function seatsText(nowMs: number): string {
  const lines: string[] = [...liveTextLines(liveSeatLabel(), live)];
  if (board === undefined) {
    lines.push(
      boardError === ""
        ? "the other seats have not been read yet"
        : `the other seats could not be read: ${boardError}`,
    );
    return lines.join("\n");
  }
  for (const row of seatRows(board, boardReadAtMs, nowMs)) lines.push(seatLine(row));
  if (boardError !== "") lines.push(`last read failed: ${boardError}`);
  lines.push(
    `cached figures older than ${board.cacheSeconds}s are shown as stale; this session's own figures are live`,
  );
  return lines.join("\n");
}

/** One seat's row in the pane. */
function seatElement($: EngineInterface, e: RenderInput, row: SeatRow): RenderElement {
  const { Box, Text } = $.ui.resolve(e);
  const stale = row.freshness === "stale" || row.freshness === "none" || row.freshness === "unknown";
  const marks =
    row.marks.length === 0 ? [] : [Text({ dimColor: true, children: [`[${row.marks.join(", ")}]`] })];
  return Box({
    flexDirection: "row",
    columnGap: 1,
    children: [
      Text({ bold: row.live, children: [row.name] }),
      ...marks,
      Text({ dimColor: stale, children: [seatFiguresText(row)] }),
      Text({
        color: stale ? "yellow" : undefined,
        dimColor: !stale,
        children: [`(${freshnessWord(row.freshness, row.ageWord)})`],
      }),
    ],
  });
}

export const register: Register = (on) => {
  on("session.start", async ($, e, next) => {
    if (!(await isActivated($))) return next(e);
    await load($, e.isInteractive === true);
    // Registered last: a taken name throws, and that must not take the rest down.
    try {
      await $.command.register({
        name: SEATS_COMMAND,
        description: "Show every configured Claude seat's quota, with each reading's age.",
      });
    } catch {
      // Another plugin owns /seats; the band still draws.
    }
    return next(e);
  });

  // The engine's own measurement of this session's account: free, and exactly when a
  // window moves. Observe only, and never ask for a breakdown, which would cost calls.
  on("session.measure", async ($, e, next) => {
    if (!(await isActivated($))) return next(e);
    const before = live.length;
    live = liveWindows(e.rateLimits as readonly LiveRateLimit[], await $.clock.now());
    if (live.length > 0 || before > 0) $.ui.invalidate("ui.render");
    return next(e);
  });

  on("command.run", { command: SEATS_COMMAND }, async ($, e, next) => {
    if (!(await isActivated($))) return next(e);
    // Nothing a mod draws is seen in a -p run or the SDK, and `$.ui.open` still answers
    // placed there, so the test is `session.start`'s own `isInteractive`.
    if (!canDraw) {
      if (board === undefined && reading === undefined) startRead($, false);
      if (reading !== undefined) await reading;
      return { text: seatsText(await $.clock.now()) };
    }
    await $.ui.open({ id: SEATS_COMMAND, title: "Claude seats", focus: true, closeOnEscape: true });
    return {};
  });

  on("ui.render", { component: "Pane" }, async ($, e, next) => {
    if (!(await isActivated($))) return next(e);
    if (e.requestId !== SEATS_COMMAND) return next(e);
    const { Box, Text, Button } = $.ui.resolve(e);
    const now = await $.clock.now();
    const children: unknown[] = [];
    const ours = liveBandSegment(liveSeatLabel(), live);
    children.push(
      Text({
        bold: true,
        children: [ours === undefined ? `${liveSeatLabel()} (this session): no reading yet` : `${ours}  live`],
      }),
    );
    if (board === undefined) {
      children.push(
        Text({
          dimColor: boardError === "",
          color: boardError === "" ? undefined : "red",
          children: [
            boardError === ""
              ? "reading the other seats..."
              : `the other seats could not be read: ${boardError}`,
          ],
        }),
      );
    } else {
      for (const row of seatRows(board, boardReadAtMs, now)) children.push(seatElement($, e, row));
      if (boardError !== "") {
        children.push(Text({ color: "red", wrap: "truncate-end", children: [`last read failed: ${boardError}`] }));
      }
      children.push(
        Text({
          dimColor: true,
          wrap: "truncate-end",
          children: [
            `cached readings over ${board.cacheSeconds}s old are stale; only this session's own figures are live`,
          ],
        }),
      );
    }
    const lastRead = board === undefined ? "" : `read ${ageWord((now - boardReadAtMs) / 1000)} ago; `;
    children.push(
      Text({
        dimColor: true,
        wrap: "truncate-end",
        children: [`${lastRead}${nextRefreshWord(lastClaimedAtMs, now, refreshEvery)}`],
      }),
    );
    // Refresh rereads only the cache, so pressing it can never reach the quota endpoint
    // or move the live refresh any sooner.
    children.push(
      Button({
        key: "refresh",
        label: "Refresh",
        hotkey: "r",
        plain: true,
        onPress: () => {
          startRead($, false);
        },
      }),
    );
    return Box({ flexDirection: "column", children });
  });

  on("ui.render", { component: "AbovePrompt" }, async ($, e, next) => {
    if (!(await isActivated($))) return next(e);
    const line = bandLine(await $.clock.now());
    if (line === undefined) return next(e);
    const { Box, Text } = $.ui.resolve(e);
    // Another mod's band content survives: take theirs and draw ours beneath it.
    const theirs = await next(e);
    return Box({
      flexDirection: "column",
      children: [
        theirs,
        Text({
          color: tensionColor(line.tension),
          dimColor: line.tension === "calm",
          wrap: "truncate-end",
          children: [line.text],
        }),
      ],
    });
  });
};
