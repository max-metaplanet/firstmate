// Every configured Claude seat: how firstmate's own cached per-seat quota reports read.
//
// This module owns the all-seats half of the mod's policy: how the reading that
// `bin/fm-seat-board.sh json` prints is parsed, how old each seat's figures are allowed
// to be before they are called stale, and how a seat with no readable report is
// described. ../hooks/register.ts applies it through `$`; docs/quota-mod.md owns the
// captain-facing contract. Everything here is pure, so the tests run it with no engine.
//
// The one rule the whole module exists to keep: a cached figure is never presented as
// current. `bin/fm-seat-board.sh`'s header owns the cache contract, and the reading it
// prints dates every seat separately, so each row carries its own age and anything past
// the cache window says so. A seat with no report says that too, rather than drawing a
// zero a reader could take for an exhausted account.
//
// Nothing here is a second copy of seat resolution. Which seats exist, where each one's
// profile lives, which is active for new workers, which is held out of automatic
// rotation, and which seat this session itself is on are all answered by
// bin/fm-seat-lib.sh through that reading; this module only displays what it says.

/** One quota window of one seat, as the board's reading carries it. */
export type SeatWindow = {
  readonly id: string;
  readonly label: string;
  readonly percentRemaining: number | null;
  readonly resetsAt: string | null;
};

/** One seat's record in the board's reading. */
export type SeatRecord = {
  readonly name: string;
  readonly configDir: string;
  readonly active: boolean;
  readonly autoExcluded: boolean;
  readonly hasData: boolean;
  readonly ageSeconds: number | null;
  readonly account: string | null;
  readonly attention: string | null;
  readonly windows: readonly SeatWindow[];
  readonly extraUsage: { readonly spentUsd: unknown; readonly limitUsd: unknown } | null;
};

/** The whole reading `bin/fm-seat-board.sh json` prints. */
export type SeatBoard = {
  readonly generatedAt: string;
  readonly cacheSeconds: number;
  readonly activeSeat: string;
  readonly liveSeat: string;
  readonly seats: readonly SeatRecord[];
};

/** The schema version of the reading this mod understands. */
export const SEAT_BOARD_SCHEMA = 1;

/** How fresh one seat's figures are. */
export type SeatFreshness = "fresh" | "stale" | "unknown" | "none";

/** One seat ready to draw. */
export type SeatRow = {
  readonly name: string;
  /** True for the seat this session itself spends, whose figures come from the engine. */
  readonly live: boolean;
  /** True for the seat NEW workers launch on, which a live worker never follows. */
  readonly active: boolean;
  readonly autoExcluded: boolean;
  readonly freshness: SeatFreshness;
  /** The age of this seat's cached reading, drawn beside its figures; empty when none. */
  readonly ageWord: string;
  readonly account: string;
  readonly attention: string;
  readonly windows: readonly { readonly label: string; readonly percentLeft: number }[];
  /** The markers the row carries, already worded for the captain. */
  readonly marks: readonly string[];
};

/** The parent of a path, with either separator; a bare name resolves to itself. */
function parentDirectory(path: string): string {
  const trimmed = path.replace(/[\\/]+$/, "");
  const cut = Math.max(trimmed.lastIndexOf("/"), trimmed.lastIndexOf("\\"));
  return cut > 0 ? trimmed.slice(0, cut) : trimmed;
}

/**
 * The tracked Firstmate code root this mod belongs to, which is where `bin/` is: three
 * levels above the plugin folder, whether Claude Code names it through
 * `.claude/skills/<name>`, `.agents/skills/<name>`, or its physical
 * `.claude/mods/<name>` home, which all sit at that same depth.
 *
 * A mod may only import within itself, so this derivation is the mod's own rather than
 * shared with the Calm mod's identical one.
 */
export function codeRootFromPluginRoot(pluginRoot: string): string {
  return parentDirectory(parentDirectory(parentDirectory(pluginRoot)));
}

/** The reader that prints every seat's cached figures, under the code root. */
export function seatBoardCommand(codeRoot: string): string {
  return `${codeRoot}/bin/fm-seat-board.sh`;
}

function asNumberOrNull(value: unknown): number | null {
  return typeof value === "number" && Number.isFinite(value) ? value : null;
}

function asStringOrNull(value: unknown): string | null {
  return typeof value === "string" && value !== "" ? value : null;
}

/**
 * The board's reading, or undefined when it cannot be trusted.
 *
 * A reading that is not JSON, carries another schema version, or has no seats array is
 * refused outright: a half-understood reading would be drawn as fact, and the pane says
 * it could not read the seats instead.
 */
export function parseSeatBoard(stdout: string): SeatBoard | undefined {
  let value: unknown;
  try {
    value = JSON.parse(stdout);
  } catch {
    return undefined;
  }
  if (value === null || typeof value !== "object") return undefined;
  const report = value as Record<string, unknown>;
  if (report.schemaVersion !== SEAT_BOARD_SCHEMA) return undefined;
  if (!Array.isArray(report.seats)) return undefined;
  const seats: SeatRecord[] = [];
  for (const entry of report.seats) {
    if (entry === null || typeof entry !== "object") continue;
    const seat = entry as Record<string, unknown>;
    if (typeof seat.name !== "string" || seat.name === "") continue;
    const windows: SeatWindow[] = [];
    if (Array.isArray(seat.windows)) {
      for (const raw of seat.windows) {
        if (raw === null || typeof raw !== "object") continue;
        const window = raw as Record<string, unknown>;
        const id = typeof window.id === "string" ? window.id : "";
        if (id === "") continue;
        windows.push({
          id,
          label: typeof window.label === "string" && window.label !== "" ? window.label : id,
          percentRemaining: asNumberOrNull(window.percentRemaining),
          resetsAt: asStringOrNull(window.resetsAt),
        });
      }
    }
    seats.push({
      name: seat.name,
      configDir: typeof seat.configDir === "string" ? seat.configDir : "",
      active: seat.active === true,
      autoExcluded: seat.autoExcluded === true,
      hasData: seat.hasData === true,
      ageSeconds: asNumberOrNull(seat.ageSeconds),
      account: asStringOrNull(seat.account),
      attention: asStringOrNull(seat.attention),
      windows,
      extraUsage:
        seat.extraUsage !== null && typeof seat.extraUsage === "object"
          ? (seat.extraUsage as { spentUsd: unknown; limitUsd: unknown })
          : null,
    });
  }
  return {
    generatedAt: typeof report.generatedAt === "string" ? report.generatedAt : "",
    cacheSeconds: asNumberOrNull(report.cacheSeconds) ?? 60,
    activeSeat: typeof report.activeSeat === "string" ? report.activeSeat : "",
    liveSeat: typeof report.liveSeat === "string" ? report.liveSeat : "",
    seats,
  };
}

/** A duration as a short age word: `40s`, `9m`, `3h`, `10d`. */
export function ageWord(seconds: number): string {
  if (!Number.isFinite(seconds) || seconds < 0) return "";
  if (seconds < 60) return `${Math.round(seconds)}s`;
  const minutes = Math.round(seconds / 60);
  if (minutes < 60) return `${minutes}m`;
  const hours = Math.round(minutes / 60);
  if (hours < 48) return `${hours}h`;
  return `${Math.round(hours / 24)}d`;
}

/**
 * How fresh one seat's cached figures are.
 *
 * `none` means no report at all, `unknown` means a report whose cache file could not be
 * dated, and anything older than the board's own cache window is `stale`. The window is
 * the board's, not this mod's: the board is what decides when a cached report has
 * expired, so the two can never disagree about what current means.
 */
export function seatFreshness(seat: SeatRecord, cacheSeconds: number): SeatFreshness {
  if (!seat.hasData) return "none";
  if (seat.ageSeconds === null) return "unknown";
  return seat.ageSeconds > cacheSeconds ? "stale" : "fresh";
}

/** How a row's age reads: `10d old, stale`, `40s old`, or an honest absence. */
export function freshnessWord(freshness: SeatFreshness, ageWordText: string): string {
  switch (freshness) {
    case "fresh":
      return ageWordText === "" ? "current" : `${ageWordText} old`;
    case "stale":
      return ageWordText === "" ? "stale" : `${ageWordText} old, stale`;
    case "unknown":
      return "age unknown";
    case "none":
      return "no reading";
  }
}

/**
 * Every seat as a row to draw, the board's own order kept.
 *
 * The live seat's row is marked but keeps its cached figures: the engine's exact
 * readings go in the band, and showing both says plainly which number came from where.
 */
export function seatRows(board: SeatBoard): SeatRow[] {
  return board.seats.map((seat) => {
    const freshness = seatFreshness(seat, board.cacheSeconds);
    const live = seat.name === board.liveSeat;
    const marks: string[] = [];
    if (live) marks.push("this session");
    if (seat.active) marks.push("new workers");
    if (seat.autoExcluded) marks.push("not in rotation");
    return {
      name: seat.name,
      live,
      active: seat.active,
      autoExcluded: seat.autoExcluded,
      freshness,
      ageWord: seat.ageSeconds === null ? "" : ageWord(seat.ageSeconds),
      account: seat.account ?? "",
      attention: seat.attention ?? "",
      windows: seat.windows.flatMap((window) =>
        window.percentRemaining === null
          ? []
          : [{ label: window.label, percentLeft: Math.round(window.percentRemaining) }],
      ),
      marks,
    };
  });
}

/** One row's figures as text: each window's percent left, or why there are none. */
export function seatFiguresText(row: SeatRow): string {
  if (row.windows.length === 0) {
    return row.attention === "" ? "no figures" : row.attention;
  }
  return row.windows.map((window) => `${window.label} ${window.percentLeft}%`).join(" · ");
}

/** One row as one line, for the pane's text fallback and for a narrow draw. */
export function seatLine(row: SeatRow): string {
  const marks = row.marks.length === 0 ? "" : ` [${row.marks.join(", ")}]`;
  const age = freshnessWord(row.freshness, row.ageWord);
  const account = row.account === "" ? "" : ` ${row.account}`;
  return `${row.name}${marks}${account}: ${seatFiguresText(row)} (${age})`;
}

/**
 * The tightest percent left among the seats this session is NOT on, with its age, for
 * the band's second half. Undefined when no other seat has a figure to compare.
 */
export function tightestOtherSeat(
  rows: readonly SeatRow[],
): { readonly name: string; readonly percentLeft: number; readonly freshness: SeatFreshness; readonly ageWord: string } | undefined {
  let best: { name: string; percentLeft: number; freshness: SeatFreshness; ageWord: string } | undefined;
  for (const row of rows) {
    if (row.live) continue;
    for (const window of row.windows) {
      if (best === undefined || window.percentLeft < best.percentLeft) {
        best = {
          name: row.name,
          percentLeft: window.percentLeft,
          freshness: row.freshness,
          ageWord: row.ageWord,
        };
      }
    }
  }
  return best;
}

/**
 * The all-seats half of one band line: the tightest other seat and how old that figure
 * is, or a plain statement that the other seats have no reading.
 *
 * Undefined when there are no other seats at all, so a single-seat machine draws only
 * its own figures rather than an empty clause.
 */
export function seatsBandSegment(rows: readonly SeatRow[]): string | undefined {
  const others = rows.filter((row) => !row.live);
  if (others.length === 0) return undefined;
  const tightest = tightestOtherSeat(rows);
  if (tightest === undefined) return `${others.length} other seats: no reading`;
  const age = freshnessWord(tightest.freshness, tightest.ageWord);
  return `others tightest ${tightest.name} ${tightest.percentLeft}% (${age})`;
}
