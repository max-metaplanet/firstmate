// Every reading decision the firstmate-fleet mod makes, as plain functions over plain
// data, so the policy is testable under Node and `hooks/register.ts` holds only engine
// glue.
//
// The one authoritative input is `bin/fm-fleet-snapshot.sh --json` (schema
// `fm-fleet-snapshot.v1`), which is the only reader that reconciles the append-only
// status EVENT log against liveness. It is measured at 17.7-21.6s, so it is read on a
// timer and nothing here ever starts it; the drawing functions below see only whatever
// the last run cached.
//
// Two rules the snapshot's own contract imposes on anything that renders it:
//   - `paths.status_log.last_event` is historical wake-event data, never a state. Only
//     `current_state.state` is printed as a state word, and the raw event is shown as
//     an event with its age beside it.
//   - `current_state` distinguishes `unreadable` (the reader's claim about itself) from
//     `unknown`. Collapsing the two would lose the distinction deliberately built into
//     `bin/fm-crew-state.sh`, so both words pass through untouched.
//
// A read that failed must never look like a healthy empty fleet, so freshness is a
// first-class part of every view: `fleetFreshness` is the single owner of that verdict
// and both the band and the pane take their wording from it.

function parentDirectory(path: string): string {
  const trimmed = path.replace(/[\\/]+$/, "");
  const cut = Math.max(trimmed.lastIndexOf("/"), trimmed.lastIndexOf("\\"));
  return cut > 0 ? trimmed.slice(0, cut) : trimmed;
}

/**
 * The tracked Firstmate code root the mod belongs to: three levels above the plugin
 * folder, whether Claude Code names it through `.claude/skills/<name>`,
 * `.agents/skills/<name>`, or its physical `.claude/mods/<name>` home, which all sit at
 * that same depth.
 *
 * The same depth Calm's `calmCodeRootFromPluginRoot` reads, and repeated rather than
 * imported only because Claude Code's static analysis allows a relative import within
 * one plugin alone; if the mods ever move, both move together.
 */
export function fleetCodeRootFromPluginRoot(pluginRoot: string): string {
  return parentDirectory(parentDirectory(parentDirectory(pluginRoot)));
}

/**
 * The reading command, as an argv array.
 *
 * `bin/` belongs to the tracked code root, not to a Firstmate home: `FM_HOME` selects a
 * home's own data, state and config, while the scripts keep coming from the checkout the
 * mod was loaded from. So the command is resolved exactly as Calm resolves its own
 * paths - `FM_ROOT_OVERRIDE` when it names another code root, else the plugin's own -
 * and `FM_HOME` is left to the command, which reads it from the environment every
 * `$.process.run` child inherits.
 */
export function fleetSnapshotCommand(rootOverride: string | undefined, pluginRoot: string): string[] {
  const root = rootOverride !== undefined && rootOverride !== ""
    ? rootOverride
    : fleetCodeRootFromPluginRoot(pluginRoot);
  return [`${root}/bin/fm-fleet-snapshot.sh`, "--json"];
}

/** The snapshot schema this reader understands. */
export const FLEET_SNAPSHOT_SCHEMA = "fm-fleet-snapshot.v1";

/**
 * How old the newest successful reading may be before every surface calls it stale.
 *
 * Three refresh periods: a healthy 60s cycle running a 17.7-21.6s command settles well
 * inside one period, so this only trips when runs are failing, timing out, or queueing.
 */
export const FLEET_STALE_AFTER_MS = 180_000;

/** One task row, reduced to what a fleet surface draws. */
export type FleetRow = {
  id: string;
  kind: string;
  /** `current_state.state`: the only word any surface may print as a state. */
  state: string;
  /** Which evidence `bin/fm-crew-state.sh` resolved that state from. */
  source: string;
  /** The last wake EVENT line, historical by contract. */
  lastEvent: string;
  /** Age of that event, or null when its emission time is unknown. */
  ageSeconds: number | null;
  pendingDecision: boolean;
  openDecisions: number;
  pr: string | null;
  /** `on` when firstmate may merge this task's work itself. */
  yolo: string;
};

/** One captain hold from the backlog that the snapshot classifies as live. */
export type FleetHold = {
  id: string;
  title: string;
  reason: string;
};

/** A parsed snapshot, reduced to the two inventories a fleet surface reads. */
export type FleetSnapshot = {
  rows: FleetRow[];
  /** Backlog rows whose `captain_actionable` classification says they wait now. */
  holds: FleetHold[];
};

/** Why one entry is waiting on the captain. */
export type FleetWaitReason = "decision" | "merge" | "blocker";

/** One thing waiting on the captain, named the way the captain would name it. */
export type FleetWaitingEntry = {
  id: string;
  reasons: FleetWaitReason[];
};

/** The cached reading state every drawing function takes. */
export type FleetView = {
  /** The newest successfully parsed snapshot, or undefined when none has landed. */
  snapshot: FleetSnapshot | undefined;
  /** When that snapshot landed, in epoch milliseconds, or null when none has. */
  snapshotAtMs: number | null;
  /** Now, in epoch milliseconds. */
  nowMs: number;
  /** Why the newest attempt failed, or the empty string when it succeeded. */
  error: string;
};

export type FleetFreshnessKind = "unread" | "fresh" | "stale" | "unavailable";

export type FleetFreshness = {
  kind: FleetFreshnessKind;
  /** How old the newest successful reading is, or null when there is none. */
  ageSeconds: number | null;
  /** What to say about it, or the empty string while it is fresh or unread. */
  note: string;
};

function finiteNumber(value: unknown): number | null {
  return typeof value === "number" && Number.isFinite(value) ? value : null;
}

function text(value: unknown, fallback: string): string {
  return typeof value === "string" ? value : fallback;
}

function record(value: unknown): Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : {};
}

/** A compact age, in the largest unit that still reads as a duration. */
export function fleetAgeWord(seconds: number | null): string {
  if (seconds === null) return "?";
  const whole = Math.max(0, Math.round(seconds));
  if (whole < 90) return `${whole}s`;
  if (whole < 5400) return `${Math.round(whole / 60)}m`;
  return `${Math.round(whole / 3600)}h`;
}

/**
 * Parse one `--json` reading into the two inventories a surface draws.
 *
 * Throws with a captain-readable reason when the text is not this snapshot's JSON, so
 * the caller records a failure rather than a believable empty fleet.
 */
export function parseFleetSnapshot(stdout: string): FleetSnapshot {
  let parsed: unknown;
  try {
    parsed = JSON.parse(stdout);
  } catch {
    parsed = undefined;
  }
  if (parsed === undefined) throw new Error("the fleet reading was not JSON");
  const top = record(parsed);
  const schema = text(top.schema, "");
  if (schema !== FLEET_SNAPSHOT_SCHEMA) {
    throw new Error(
      schema === ""
        ? "the fleet reading declared no schema"
        : `the fleet reading declared schema ${schema}`,
    );
  }
  const tasks = Array.isArray(top.tasks) ? top.tasks : [];
  const rows: FleetRow[] = [];
  for (const task of tasks) {
    const entry = record(task);
    const current = record(entry.current_state);
    const hints = record(entry.hints);
    const event = record(record(record(entry.paths).status_log).last_event);
    const openDecisions = Array.isArray(hints.open_decisions) ? hints.open_decisions.length : 0;
    rows.push({
      id: text(entry.id, "?"),
      kind: text(entry.kind, "?"),
      state: text(current.state, "unknown"),
      source: text(current.source, "none"),
      lastEvent: text(event.raw, ""),
      ageSeconds: finiteNumber(event.age_seconds),
      pendingDecision: hints.pending_decision === true,
      openDecisions,
      pr: typeof entry.pr === "object" && entry.pr !== null
        ? (typeof record(entry.pr).url === "string" ? (record(entry.pr).url as string) : null)
        : null,
      yolo: text(entry.yolo, ""),
    });
  }
  const backlog = record(top.backlog);
  const records = Array.isArray(backlog.records) ? backlog.records : [];
  const holds: FleetHold[] = [];
  for (const row of records) {
    const entry = record(row);
    // captain_actionable is the snapshot's own total classification of "waiting on the
    // captain now"; no hold reason or body prose is matched here or there.
    if (entry.structured !== true || entry.captain_actionable !== true) continue;
    const id = text(entry.id, "");
    if (id === "") continue;
    holds.push({
      id,
      title: text(entry.title, ""),
      reason: text(entry.hold_reason, ""),
    });
  }
  return { rows, holds };
}

/** Why this task row waits on the captain, in the order a captain would read them. */
export function fleetRowWaitReasons(row: FleetRow): FleetWaitReason[] {
  const reasons: FleetWaitReason[] = [];
  if (row.pendingDecision || row.openDecisions > 0) reasons.push("decision");
  // With yolo off the captain approves every merge, so a landed PR on finished work is
  // an ask. With yolo on firstmate merges green work itself and owes no ask.
  if (row.pr !== null && row.state === "done" && row.yolo !== "on") reasons.push("merge");
  if (row.state === "blocked" || row.state === "failed") reasons.push("blocker");
  return reasons;
}

/** Everything waiting on the captain: task rows first, then backlog holds with no row. */
export function fleetWaiting(snapshot: FleetSnapshot | undefined): FleetWaitingEntry[] {
  if (snapshot === undefined) return [];
  const waiting: FleetWaitingEntry[] = [];
  const named = new Set<string>();
  for (const row of snapshot.rows) {
    const reasons = fleetRowWaitReasons(row);
    if (reasons.length === 0) continue;
    named.add(row.id);
    waiting.push({ id: row.id, reasons });
  }
  for (const hold of snapshot.holds) {
    // A held task with a live worker row already counted its decision above.
    if (named.has(hold.id)) continue;
    named.add(hold.id);
    waiting.push({ id: hold.id, reasons: ["decision"] });
  }
  return waiting;
}

/** How much of this view can be trusted, and what to say when the answer is "less". */
export function fleetFreshness(view: FleetView): FleetFreshness {
  const ageSeconds = view.snapshotAtMs === null
    ? null
    : Math.max(0, (view.nowMs - view.snapshotAtMs) / 1000);
  if (view.snapshot === undefined) {
    return view.error === ""
      ? { kind: "unread", ageSeconds: null, note: "" }
      : { kind: "unavailable", ageSeconds: null, note: view.error };
  }
  if (view.error !== "") return { kind: "stale", ageSeconds, note: view.error };
  if (ageSeconds !== null && ageSeconds * 1000 > FLEET_STALE_AFTER_MS) {
    return { kind: "stale", ageSeconds, note: "no fresh reading" };
  }
  return { kind: "fresh", ageSeconds, note: "" };
}

/** One line naming what the reading cannot vouch for, or the empty string when fresh. */
export function fleetFreshnessLine(freshness: FleetFreshness): string {
  if (freshness.kind === "fresh") return "";
  if (freshness.kind === "unread") return "reading the fleet…";
  if (freshness.kind === "unavailable") return `fleet unavailable: ${freshness.note}`;
  return `fleet reading ${fleetAgeWord(freshness.ageSeconds)} old: ${freshness.note}`;
}

export type FleetBand = {
  tone: "red" | "yellow";
  text: string;
};

/**
 * The band's own line, or undefined when the band must draw nothing at all.
 *
 * Nothing waiting and a fresh reading is the quiet case, and quiet means no row: an
 * always-present band would make the one case that matters invisible. A reading that
 * cannot answer the question still draws, because silence there would be a claim that
 * nothing waits.
 */
export function fleetBand(view: FleetView): FleetBand | undefined {
  const freshness = fleetFreshness(view);
  const waiting = fleetWaiting(view.snapshot);
  if (waiting.length > 0) {
    const named = waiting
      .map((entry) => `${entry.id} (${entry.reasons.join("/")})`)
      .join(", ");
    const suffix = freshness.kind === "fresh" || freshness.kind === "unread"
      ? ""
      : ` · ${fleetFreshnessLine(freshness)}`;
    return { tone: "red", text: `${waiting.length} waiting on you: ${named}${suffix}` };
  }
  if (freshness.kind === "stale" || freshness.kind === "unavailable") {
    return { tone: "yellow", text: fleetFreshnessLine(freshness) };
  }
  return undefined;
}

export type FleetLine = {
  /** `?` waiting on the captain, `>` a worker under way, `·` everything else. */
  mark: string;
  id: string;
  kind: string;
  state: string;
  source: string;
  age: string;
  /** The last wake EVENT, labeled as an event wherever it is drawn. */
  lastEvent: string;
  tone: "red" | "green" | "plain";
  reasons: FleetWaitReason[];
};

/** Every drawable row of this view, in the snapshot's own order. */
export function fleetLines(view: FleetView): FleetLine[] {
  const snapshot = view.snapshot;
  if (snapshot === undefined) return [];
  const lines: FleetLine[] = [];
  for (const row of snapshot.rows) {
    const reasons = fleetRowWaitReasons(row);
    const tone = reasons.length > 0 ? "red" : row.state === "done" ? "green" : "plain";
    lines.push({
      mark: reasons.length > 0 ? "?" : row.state === "working" ? ">" : "·",
      id: row.id,
      kind: row.kind,
      state: row.state,
      source: row.source,
      age: fleetAgeWord(row.ageSeconds),
      lastEvent: row.lastEvent,
      tone,
      reasons,
    });
  }
  const named = new Set(snapshot.rows.map((row) => row.id));
  for (const hold of snapshot.holds) {
    if (named.has(hold.id)) continue;
    lines.push({
      mark: "?",
      id: hold.id,
      kind: "held",
      state: "waiting on you",
      source: "backlog",
      age: "?",
      lastEvent: hold.reason === "" ? hold.title : hold.reason,
      tone: "red",
      reasons: ["decision"],
    });
  }
  return lines;
}

/** One drawable row as the text fallback writes it. */
export function fleetLineText(line: FleetLine): string {
  const head = `${line.mark} ${line.id} ${line.kind} · ${line.state} (${line.source}) · ${line.age}`;
  return line.lastEvent === "" ? head : `${head}\n    event: ${line.lastEvent}`;
}

/**
 * The whole reading as text, for a session where nothing a mod draws is ever seen.
 *
 * It carries the same rows the pane draws plus the freshness line, so a `-p` run or the
 * SDK gets the identical answer rather than a quieter one.
 */
export function fleetTextReport(view: FleetView): string {
  const freshness = fleetFreshness(view);
  const lines = fleetLines(view);
  const head: string[] = [];
  if (freshness.kind === "unavailable" || freshness.kind === "unread") {
    return `fleet: ${fleetFreshnessLine(freshness)}`;
  }
  head.push(`fleet (${lines.length}):`);
  if (freshness.kind === "stale") head.push(fleetFreshnessLine(freshness));
  const waiting = fleetWaiting(view.snapshot);
  if (waiting.length > 0) {
    head.push(
      `${waiting.length} waiting on you: ${waiting
        .map((entry) => `${entry.id} (${entry.reasons.join("/")})`)
        .join(", ")}`,
    );
  }
  return [...head, ...lines.map(fleetLineText)].join("\n");
}
