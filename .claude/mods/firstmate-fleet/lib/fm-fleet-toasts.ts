// Which state changes earn a transient notice, decided from the previous reading alone.
//
// The rule that matters is the first one: a mod that announced everything it found on
// the first reading would open every session with a burst of notices about work the
// captain already knows about. So the first reading only records what is there, and a
// notice is owed only once the mod has a previous reading to compare against.
//
// The second rule is the deduplicating one: the recorded word is the one last
// announced, so a task that settles and is then re-opened earns one notice per real
// change rather than one per refresh.
import type { FleetRow } from "./fm-fleet-view.ts";

/** The state words worth a notice when a task newly reaches one. */
const ANNOUNCED_STATES = new Set(["done", "blocked", "failed"]);

export type FleetToast = {
  id: string;
  text: string;
};

export type FleetToastRound = {
  /** The notices this reading earned, in the snapshot's own order. */
  toasts: FleetToast[];
  /** The state words to carry into the next reading. */
  states: Map<string, string>;
};

/**
 * Compare one reading against the last.
 *
 * `known` is undefined until a reading has landed; that first round records the fleet
 * and announces nothing, however many tasks are already done or blocked.
 */
export function fleetToasts(
  known: ReadonlyMap<string, string> | undefined,
  rows: readonly FleetRow[],
): FleetToastRound {
  const states = new Map<string, string>();
  const toasts: FleetToast[] = [];
  for (const row of rows) {
    states.set(row.id, row.state);
    if (known === undefined) continue;
    if (known.get(row.id) === row.state) continue;
    if (!ANNOUNCED_STATES.has(row.state)) continue;
    toasts.push({ id: row.id, text: fleetToastText(row) });
  }
  return { toasts, states };
}

/** What one notice says: the outcome, and the PR when the task has one to review. */
export function fleetToastText(row: FleetRow): string {
  if (row.state === "done") {
    return row.pr === null ? `${row.id}: done` : `${row.id}: done · ${row.pr}`;
  }
  const decision = row.pendingDecision || row.openDecisions > 0 ? " (needs your decision)" : "";
  return `${row.id}: ${row.state}${decision}`;
}
