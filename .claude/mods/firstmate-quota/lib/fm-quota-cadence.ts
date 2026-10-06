// When the mod may ask for a fresh per-seat reading, and when it may only read the cache.
//
// This module owns one decision, and it is the reason the mod is safe to run: the Claude
// quota endpoint rate-limits frequent polling, so a per-seat poll on a drawing cadence
// would be dozens of calls a minute. bin/fm-seat-board.sh's header owns the cache
// contract that bounds each reading; this module bounds how often the mod asks for one
// at all, well below one call per seat per minute.
//
// Two kinds of read, and only one of them can reach quota-axi:
//
//   - a cached read, which never shells out to the endpoint and so needs no bound: the
//     mod takes one at session start and whenever it wants the figures again cheaply;
//   - a refreshing read, which lets the board refill the seats whose cache has expired,
//     and which this module allows at most once every FM_QUOTA_REFRESH_SECONDS.
//
// Drawing never triggers either one. Every band and pane draws the reading already in
// memory, so no hook spends its ten-second budget on a process and no redraw can turn
// into a quota call. ../hooks/register.ts applies this through `$`; everything here is
// pure, so the tests run it with no engine.

/** How long the mod waits between refreshing reads, when nothing says otherwise. */
export const QUOTA_REFRESH_SECONDS_DEFAULT = 600;

/** The floor a configured refresh interval is held to, in seconds. */
export const QUOTA_REFRESH_SECONDS_MIN = 120;

/** The timer that asks whether a refresh is due. Cheap: most ticks decline. */
export const QUOTA_TICK_MS = 60_000;

/**
 * The refresh interval this session uses, in milliseconds.
 *
 * `FM_QUOTA_REFRESH_SECONDS` raises or lowers it, but never below
 * `QUOTA_REFRESH_SECONDS_MIN`: a captain who wants fresher seat figures still may not
 * drive the mod into polling the endpoint faster than it tolerates, and an unreadable or
 * nonsense value keeps the default rather than being treated as zero.
 */
export function refreshIntervalMs(configured: string | undefined): number {
  const seconds = Number(configured);
  if (configured === undefined || configured.trim() === "" || !Number.isFinite(seconds)) {
    return QUOTA_REFRESH_SECONDS_DEFAULT * 1000;
  }
  return Math.max(QUOTA_REFRESH_SECONDS_MIN, Math.floor(seconds)) * 1000;
}

/** What the mod knows when it is deciding whether to refresh. */
export type RefreshState = {
  /**
   * When this interval was last CLAIMED, or undefined before any claim.
   *
   * A claim is made when a refresh comes due, whether or not a read follows, so an
   * interval is spent once however many times the question is asked inside it.
   */
  readonly lastClaimedAtMs: number | undefined;
  /** True while a read is still running. */
  readonly inFlight: boolean;
};

/**
 * What to do about refreshing, right now.
 *
 * `wait` means the interval has not elapsed. `read` means it has and nothing is running,
 * so a refreshing read may start. `claim-only` means it has elapsed but a read is
 * already under way: two overlapping reads contend on the same cache files and on the
 * endpoint itself, so the second is refused outright rather than queued, and the
 * interval is still spent so the decision is not simply retaken a moment later.
 *
 * Claiming on `claim-only` as well as on `read` is what makes the bound hold when the
 * question arrives in a burst: a machine that slept through several timer ticks asks it
 * many times at once, and without the claim each of those could decide a refresh was
 * due and the mod would reach the endpoint repeatedly in one moment.
 */
export type RefreshDecision = "wait" | "claim-only" | "read";

export function refreshDecision(
  state: RefreshState,
  nowMs: number,
  intervalMs: number,
): RefreshDecision {
  const due =
    state.lastClaimedAtMs === undefined || nowMs - state.lastClaimedAtMs >= intervalMs;
  if (!due) return "wait";
  return state.inFlight ? "claim-only" : "read";
}

/**
 * How long one reading may take before it is abandoned, in milliseconds.
 *
 * A refreshing read can shell out to quota-axi once per expired seat, each bounded by
 * bin/fm-seat-lib.sh's own ten-second read bound, so this leaves room for a handful of
 * seats in sequence and still returns long before `$.process.run`'s ten-minute ceiling.
 * It is explicit because the default is thirty seconds, which a four-seat refresh can
 * exceed.
 */
export const QUOTA_REFRESH_TIMEOUT_MS = 90_000;

/** How long a cached read may take; it touches no network, so it is held short. */
export const QUOTA_CACHED_TIMEOUT_MS = 15_000;
