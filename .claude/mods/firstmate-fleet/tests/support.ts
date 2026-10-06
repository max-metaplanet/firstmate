// Shared fixtures for the firstmate-fleet plugin test suites under `claude plugin test`.
//
// The world beneath the plugin is mocked noun by noun: the environment carrying the
// activation flag and the Firstmate home, a clock the test moves, a fleet reading the
// test hands back from `$.process.run` (optionally held open, so overlapping refreshes
// are observable), the engine's own drawing for every component the mod passes through,
// and a journal of every call the mod makes on `$`.
import type { On } from "claude-code";
import { mock, type MockClock } from "claude-code/testing";

export const HOME = "/fm/home";
/**
 * The code root the test host's `$.plugin.root` resolves to: three levels above the
 * plugin folder, which is where `bin/` lives.
 */
export const CODE_ROOT_OVERRIDE = "/fm/code-root";
export const SNAPSHOT_ARGV = [`${CODE_ROOT_OVERRIDE}/bin/fm-fleet-snapshot.sh`, "--json"];

/** One `$.process.run` the mod made. */
export type Run = {
  argv: readonly string[];
  timeoutMs: number | undefined;
};

export type Journal = {
  /** Every `$.command.register` name, in order. */
  commands: string[];
  /** Every `$.process.run`, in order. */
  runs: Run[];
  /** Every `$.ui.toast` text, in order. */
  toasts: string[];
  /** Every `$.ui.invalidate` event, in order. */
  invalidations: string[];
  /** Every `$.ui.open`, as `{ id, title }`. */
  opens: { id: string; title: string | undefined }[];
  /** Which components reached the engine's own drawing, in order. */
  stock: string[];
  /** Every command that reached the engine's own run, in order. */
  stockCommands: string[];
};

/** One fleet reading the mocked command answers with. */
export type Reading =
  | { exitCode: number; stdout: string; stderr: string }
  | { reject: string };

export type World = {
  clock: MockClock;
  journal: Journal;
  /** Replace what the next reading answers. */
  answer: (reading: Reading) => void;
  /**
   * Hold every reading from now on, so a second refresh can be observed arriving while
   * the first is still running. `release()` lets the held readings answer.
   */
  hold: () => { release: () => Promise<void> };
};

export type WorldOptions = {
  /** The activation flag's value; omitted options default to the active value `1`. */
  enabled?: string | undefined;
  /** The Firstmate home FM_HOME names; undefined leaves FM_HOME unset. */
  home?: string | undefined;
  /**
   * The code root FM_ROOT_OVERRIDE names; omitted pins it so the reading command is
   * predictable, and undefined leaves the mod to derive it from the plugin's own root.
   */
  rootOverride?: string | undefined;
  /** What the first reading answers; defaults to a two-task fleet with nothing waiting. */
  reading?: Reading;
};

/** The engine's own drawing, as the bottom of every `ui.render` chain. */
export const STOCK_TEXT = "STOCK-DRAWING";

/** The engine's own answer, as the bottom of every `command.run` chain. */
export const STOCK_COMMAND_TEXT = "STOCK-COMMAND";

export function world(on: On, options: WorldOptions = {}): World {
  const home = "home" in options ? options.home : HOME;
  const enabled = "enabled" in options ? options.enabled : "1";
  const rootOverride = "rootOverride" in options ? options.rootOverride : CODE_ROOT_OVERRIDE;
  mock.env(on, {
    ...(home === undefined ? {} : { FM_HOME: home }),
    ...(rootOverride === undefined ? {} : { FM_ROOT_OVERRIDE: rootOverride }),
    ...(enabled === undefined ? {} : { FM_FLEET_ENABLED: enabled }),
  });
  const clock = mock.clock(on, { now: 1_000_000 });
  const journal: Journal = {
    commands: [],
    runs: [],
    toasts: [],
    invalidations: [],
    opens: [],
    stock: [],
    stockCommands: [],
  };
  let reading: Reading = options.reading ?? { exitCode: 0, stdout: snapshotJson(), stderr: "" };
  let held: ((value: void) => void)[] | undefined;

  on("process.run", async (_$, e) => {
    journal.runs.push({ argv: e.argv, timeoutMs: e.init?.timeoutMs });
    if (held !== undefined) {
      await new Promise<void>((resolve) => {
        held!.push(resolve);
      });
    }
    const answer = reading;
    if ("reject" in answer) return { deny: answer.reject };
    return { value: answer };
  });
  on("command.register", async (_$, e) => {
    journal.commands.push(e.name);
    return { value: { command: e.name } };
  });
  on("ui.toast", async (_$, e) => {
    journal.toasts.push(e.text);
    return { value: undefined };
  });
  on("ui.invalidate", async (_$, e) => {
    journal.invalidations.push(e.event);
    return { value: undefined };
  });
  on("ui.open", async (_$, e) => {
    journal.opens.push({ id: e.id, title: e.title });
    return { value: undefined };
  });
  on("session.start", async (_$, e) => ({ cwd: e.cwd }));
  on("command.run", async (_$, e) => {
    journal.stockCommands.push(e.command);
    return { value: { text: STOCK_COMMAND_TEXT } };
  });
  on("ui.render", async (_$, e) => {
    journal.stock.push(e.component);
    return { type: "Text", props: {}, children: [STOCK_TEXT] };
  });

  return {
    clock,
    journal,
    answer: (next) => {
      reading = next;
    },
    hold: () => {
      held = [];
      return {
        release: async () => {
          const waiting = held ?? [];
          held = undefined;
          for (const resolve of waiting) resolve();
          // Two turns of the loop: one for the held promise, one for the parse and draw.
          await clock.advance(0);
          await clock.advance(0);
        },
      };
    },
  };
}

export const SESSION_START = { cwd: "/work", surface: "terminal" as const, isInteractive: true };
export const SESSION_START_HEADLESS = { cwd: "/work", surface: "terminal" as const, isInteractive: false };

/** One task row as `bin/fm-fleet-snapshot.sh --json` publishes it. */
export type TaskOptions = {
  id: string;
  kind?: string;
  state?: string;
  source?: string;
  ageSeconds?: number | null;
  lastEvent?: string;
  pendingDecision?: boolean;
  openDecisions?: string[];
  pr?: string | null;
  yolo?: string;
};

export function task(options: TaskOptions): Record<string, unknown> {
  return {
    id: options.id,
    kind: options.kind ?? "ship",
    yolo: options.yolo ?? "off",
    mode: "no-mistakes",
    paths: {
      status_log: {
        path: `${HOME}/state/${options.id}.status`,
        last_event: {
          raw: options.lastEvent ?? `working [at=1]: ${options.id} under way`,
          age_seconds: options.ageSeconds === undefined ? 120 : options.ageSeconds,
        },
      },
    },
    current_state: {
      state: options.state ?? "working",
      source: options.source ?? "pane",
      detail: "",
      raw: `${options.state ?? "working"} (${options.source ?? "pane"})`,
    },
    pr: { url: options.pr ?? null, source: "meta", head: null },
    hints: {
      pending_decision: options.pendingDecision ?? false,
      blocked_event: (options.state ?? "working") === "blocked",
      open_decisions: options.openDecisions ?? [],
      scout_report_present: false,
      last_event_text: options.lastEvent ?? "",
    },
  };
}

/** One structured backlog row as the snapshot publishes it. */
export function hold(id: string, actionable: boolean, reason = "needs a call on scope"): Record<string, unknown> {
  return {
    structured: true,
    state: "in_flight",
    id,
    title: `${id} work`,
    hold_kind: "captain",
    hold_reason: reason,
    hold_bucket: actionable ? "live" : "dated",
    captain_actionable: actionable,
  };
}

/** A whole reading, with the schema the mod requires. */
export function snapshotJson(
  tasks: readonly Record<string, unknown>[] = [task({ id: "alpha" }), task({ id: "beta", state: "done", pr: null })],
  records: readonly Record<string, unknown>[] = [],
): string {
  return JSON.stringify({
    schema: "fm-fleet-snapshot.v1",
    generated: "2026-10-06T00:00:00Z",
    fm_home: HOME,
    backlog: { path: `${HOME}/data/backlog.md`, present: true, records },
    tasks,
  });
}

export const PANE_VIEWPORT = { columns: 120, rows: 40 } as const;

export function pane(requestId = "fleet") {
  return {
    surface: "terminal" as const,
    component: "Pane" as const,
    requestId,
    viewport: PANE_VIEWPORT,
    props: {
      title: "Fleet",
      isFocused: true,
      bodyColumns: 60,
      placement: "dock" as const,
      scroll: { offset: 0, bodyRows: 30, isAtStart: true, isAtEnd: true },
      view: {},
    },
  };
}

export function band(requestId = "band-1") {
  return {
    surface: "terminal" as const,
    component: "AbovePrompt" as const,
    requestId,
    viewport: PANE_VIEWPORT,
    props: {
      isWorking: false,
      maxRows: 10,
      bodyColumns: 120,
      scroll: { offset: 0, bodyRows: 9, isAtStart: true, isAtEnd: true },
      view: {},
    },
  };
}

export function fleetCommand() {
  return {
    command: "fleet",
    args: "",
    origin: { kind: "composer" as const },
    presentation: { layout: "main" as const, isFullscreen: false, columns: 120 },
  };
}

/** Whether a drawing is the engine's own. */
export function isStock(tree: unknown): boolean {
  return JSON.stringify(tree).includes(STOCK_TEXT);
}

/** Every Text string in a drawing, in tree order. */
export function textsOf(tree: unknown): string[] {
  const found: string[] = [];
  const walk = (node: unknown): void => {
    if (typeof node === "string") {
      found.push(node);
      return;
    }
    if (node === null || typeof node !== "object") return;
    if (Array.isArray(node)) {
      for (const child of node) walk(child);
      return;
    }
    const element = node as { children?: unknown; props?: Record<string, unknown> };
    if (element.props !== undefined && "children" in element.props) walk(element.props.children);
    if (element.children !== undefined) walk(element.children);
  };
  walk(tree);
  return found;
}

/** A drawing flattened to one string, for a contains check. */
export function flatten(tree: unknown): string {
  return textsOf(tree).join("\n");
}
