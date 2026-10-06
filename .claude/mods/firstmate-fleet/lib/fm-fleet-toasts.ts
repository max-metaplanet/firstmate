// Which state changes earn a transient notice, decided from the words already announced.
//
// The rule that matters is the first one: a mod that announced everything it found on
// the first reading would open every session with a burst of notices about work the
// captain already knows about. So the first reading announces nothing and only records
// the done, blocked, or failed words it found as if they had been announced.
//
// The second rule is the deduplicating one: what is carried per task is the word last
// announced for it, changed only when a notice fires, so a task flapping between
// blocked and working earns one notice rather than one per return. A different
// announced word still earns one (blocked, then done). A re-block after a real
// recovery earns none: the band above the prompt is the persistent signal for that.
// A task that leaves the fleet drops its record.
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
  /** The word last announced per task, to carry into the next reading. */
  announced: Map<string, string>;
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
  const announced = new Map<string, string>();
  const toasts: FleetToast[] = [];
  for (const row of rows) {
    const last = known?.get(row.id);
    if (!ANNOUNCED_STATES.has(row.state) || last === row.state) {
      if (last !== undefined) announced.set(row.id, last);
      continue;
    }
    announced.set(row.id, row.state);
    if (known !== undefined) toasts.push({ id: row.id, text: fleetToastText(row) });
  }
  return { toasts, announced };
}

/** The one notice a reader that has stopped answering earns, until a reading lands again. */
export function fleetOutageText(reason: string): string {
  return `fleet unavailable: ${reason}`;
}

/** What one notice says: the outcome, and the PR when the task has one to review. */
export function fleetToastText(row: FleetRow): string {
  if (row.state === "done") {
    return row.pr === null ? `${row.id}: done` : `${row.id}: done · ${row.pr}`;
  }
  const decision = row.pendingDecision || row.openDecisions > 0 ? " (needs your decision)" : "";
  return `${row.id}: ${row.state}${decision}`;
}
