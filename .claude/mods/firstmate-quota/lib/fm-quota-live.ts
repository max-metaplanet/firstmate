// This session's own Claude seat: how the engine's native rate-limit readings read.
//
// This module owns the live half of the band's policy and nothing else: which windows
// are worth a label, how a reading becomes a percent LEFT, how tight a figure has to be
// before it is drawn as a warning, and how a reset time reads as a relative wait.
// ../hooks/register.ts applies it through `$`; docs/quota-mod.md owns the captain-facing
// contract. Everything here is pure, so the tests run it with no engine.
//
// The live seat is free and exact: `$.session.usage()` carries `rateLimits` and
// `session.measure` fires when a window moves, so nothing here shells out or polls.
// The cached all-seats half lives in ./fm-quota-seats.ts.

/** One rate-limit window as the engine reports it (`SessionRateLimit`). */
export type LiveRateLimit = {
  readonly kind: string;
  readonly percentUsed: number;
  readonly resetsAt?: string | undefined;
};

/** How tight one figure is, which decides how the band draws it. */
export type QuotaTension = "calm" | "warn" | "tight";

/** One window ready to draw: its short label, its percent LEFT, and its reset wait. */
export type LiveWindow = {
  readonly label: string;
  readonly percentLeft: number;
  readonly tension: QuotaTension;
  /** The relative reset wait, or the empty string when the engine reported none. */
  readonly resetsIn: string;
};

/**
 * Short labels for the windows the engine names.
 *
 * An unknown kind keeps its own name rather than being dropped, so a window a later
 * Claude Code adds still reaches the captain instead of silently disappearing.
 */
const WINDOW_LABELS: Readonly<Record<string, string>> = {
  five_hour: "5h",
  seven_day: "7d",
  spend_limit: "spend",
};

/** Percent LEFT at or below which a figure draws as a warning. */
export const QUOTA_WARN_PERCENT_LEFT = 40;

/** Percent LEFT at or below which a figure draws as tight. */
export const QUOTA_TIGHT_PERCENT_LEFT = 15;

/** The label one window kind draws under. */
export function windowLabel(kind: string): string {
  return WINDOW_LABELS[kind] ?? kind;
}

/**
 * Percent LEFT from the engine's percent USED, which is the direction every firstmate
 * seat setting counts in (bin/fm-seat-lib.sh). Clamped into 0 to 100, because an
 * exceeded spend limit reports past 100 used and a negative remainder reads as nothing
 * left rather than as a number below zero.
 */
export function percentLeftFromUsed(percentUsed: number): number {
  if (!Number.isFinite(percentUsed)) return 0;
  return Math.max(0, Math.min(100, Math.round(100 - percentUsed)));
}

/** How tight a percent LEFT is. */
export function tensionOf(percentLeft: number): QuotaTension {
  if (percentLeft <= QUOTA_TIGHT_PERCENT_LEFT) return "tight";
  if (percentLeft <= QUOTA_WARN_PERCENT_LEFT) return "warn";
  return "calm";
}

/**
 * How long until a reset, as a short relative wait: `2h 10m`, `14m`, or `due`.
 *
 * An absent, unparseable, or already-past timestamp yields the empty string rather than
 * a guess, so the band says nothing instead of inventing a wait.
 */
export function resetsIn(resetsAt: string | undefined, nowMs: number): string {
  if (resetsAt === undefined || resetsAt === "") return "";
  const at = Date.parse(resetsAt);
  if (!Number.isFinite(at)) return "";
  const seconds = Math.round((at - nowMs) / 1000);
  if (seconds <= 0) return "due";
  const minutes = Math.floor(seconds / 60);
  if (minutes < 60) return `${Math.max(1, minutes)}m`;
  const hours = Math.floor(minutes / 60);
  const rest = minutes % 60;
  if (hours < 24) return rest === 0 ? `${hours}h` : `${hours}h ${rest}m`;
  const days = Math.floor(hours / 24);
  const spareHours = hours % 24;
  return spareHours === 0 ? `${days}d` : `${days}d ${spareHours}h`;
}

/**
 * The live windows worth drawing, in the engine's own order.
 *
 * An empty reading stays empty: the engine reports no window off a subscription or
 * before the first response of a session, and a missing figure must draw as nothing
 * rather than as a zero that reads like an exhausted account.
 */
export function liveWindows(rateLimits: readonly LiveRateLimit[], nowMs: number): LiveWindow[] {
  const windows: LiveWindow[] = [];
  for (const limit of rateLimits) {
    if (typeof limit.percentUsed !== "number" || !Number.isFinite(limit.percentUsed)) continue;
    const percentLeft = percentLeftFromUsed(limit.percentUsed);
    windows.push({
      label: windowLabel(limit.kind),
      percentLeft,
      tension: tensionOf(percentLeft),
      resetsIn: resetsIn(limit.resetsAt, nowMs),
    });
  }
  return windows;
}

/** The tightest tension across a set of windows, or `calm` for none. */
export function worstTension(windows: readonly LiveWindow[]): QuotaTension {
  if (windows.some((window) => window.tension === "tight")) return "tight";
  if (windows.some((window) => window.tension === "warn")) return "warn";
  return "calm";
}

/**
 * The live half of one band line: the seat this session spends, then each window's
 * percent left, with the reset wait shown only on the tightest window so one line
 * carries the fact that matters without crowding out the rest.
 *
 * Undefined when there is no reading at all, which is the band's cue to draw nothing.
 */
export function liveBandSegment(
  seatLabel: string,
  windows: readonly LiveWindow[],
): string | undefined {
  if (windows.length === 0) return undefined;
  const tightest = windows.reduce((worst, window) =>
    window.percentLeft < worst.percentLeft ? window : worst,
  );
  const figures = windows.map((window) => {
    const reset = window === tightest && window.resetsIn !== "" ? ` (${window.resetsIn})` : "";
    return `${window.label} ${window.percentLeft}%${reset}`;
  });
  return `${seatLabel} ${figures.join(" · ")}`;
}

/** The live seat's windows as one line per window, for a session that cannot draw. */
export function liveTextLines(seatLabel: string, windows: readonly LiveWindow[]): string[] {
  if (windows.length === 0) {
    return [`${seatLabel} (this session): no rate-limit reading yet`];
  }
  return windows.map((window) => {
    const reset = window.resetsIn === "" ? "" : `, resets in ${window.resetsIn}`;
    return `${seatLabel} (this session): ${window.label} ${window.percentLeft}% left${reset}`;
  });
}
