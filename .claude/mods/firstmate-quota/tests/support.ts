// Shared fixtures for the firstmate-quota plugin test suites under `claude plugin test`.
//
// Each test mocks the world beneath the plugin noun by noun: the environment that holds
// the activation flag, a clock the test moves itself, the seat reader as a process whose
// every invocation is journalled with its argument vector, the engine's own band drawing,
// and the session measurement that carries this account's rate-limit windows.
//
// The argument vector matters as much as the output: `--cached-only` is what proves a
// read could not have reached the quota endpoint, so the journal keeps every argv rather
// than only a count.
import type { On, SessionRateLimit } from "claude-code";
import { mock, type MockClock } from "claude-code/testing";

export const PLUGIN = "firstmate-quota";

/** The engine's own drawing, as the bottom of every `ui.render` chain. */
export const STOCK_TEXT = "STOCK-BAND";

export type Journal = {
  /** Every `$.command.register` name, in order. */
  commands: string[];
  /** Every `$.process.run` argument vector, in order. */
  runs: string[][];
  /** Every `$.ui.invalidate` event, in order. */
  invalidations: string[];
  /** Every pane id `$.ui.open` was called with, in order. */
  opens: string[];
  /** Which components reached the engine's own drawing, in order. */
  stock: string[];
};

export type World = {
  clock: MockClock;
  journal: Journal;
  /** Replaces what the seat reader prints from now on. */
  setBoard: (stdout: string) => void;
  /** Makes the seat reader exit non-zero from now on. */
  failBoard: (exitCode: number) => void;
  /** Only the reads whose argv asked for a refresh, so a cached read is not counted. */
  refreshingRuns: () => string[][];
};

export type WorldOptions = {
  /** The activation flag's value; omitted options default to the active value `1`. */
  enabled?: string | undefined;
  /** `FM_QUOTA_REFRESH_SECONDS`; omitted leaves it unset, so the default interval holds. */
  refreshSeconds?: string | undefined;
  /** What the seat reader prints; omitted means the fixture reading below. */
  board?: string;
};

/** One seat as the reader prints it, with every field the mod reads. */
export function seat(
  name: string,
  options: {
    active?: boolean;
    autoExcluded?: boolean;
    hasData?: boolean;
    ageSeconds?: number | null;
    account?: string | null;
    attention?: string | null;
    windows?: { id: string; label?: string; percentRemaining: number | null; resetsAt?: string | null }[];
  } = {},
): Record<string, unknown> {
  return {
    name,
    configDir: `/seats/${name}`,
    active: options.active ?? false,
    autoExcluded: options.autoExcluded ?? false,
    cacheFile: `/cache/${name}.json`,
    hasData: options.hasData ?? true,
    ageSeconds: options.ageSeconds === undefined ? 10 : options.ageSeconds,
    account: options.account === undefined ? `${name}@example.test` : options.account,
    attention: options.attention ?? null,
    windows: (options.windows ?? [{ id: "five_hour", label: "session", percentRemaining: 70 }]).map(
      (window) => ({
        id: window.id,
        label: window.label ?? window.id,
        percentRemaining: window.percentRemaining,
        resetsAt: window.resetsAt ?? null,
      }),
    ),
    extraUsage: null,
  };
}

/** One whole reading as `bin/fm-seat-board.sh json` prints it. */
export function boardReading(
  seats: Record<string, unknown>[],
  options: { liveSeat?: string; activeSeat?: string; cacheSeconds?: number; schemaVersion?: number } = {},
): string {
  return JSON.stringify({
    schemaVersion: options.schemaVersion ?? 1,
    generatedAt: "2026-10-06T00:00:00Z",
    cacheSeconds: options.cacheSeconds ?? 60,
    activeSeat: options.activeSeat ?? "alpha",
    liveSeat: options.liveSeat ?? "alpha",
    seats,
  });
}

/** The default reading: the live seat, one other that is fresh, one held out of rotation. */
export const FIXTURE_BOARD = boardReading([
  seat("alpha", { active: true, ageSeconds: 12, windows: [{ id: "five_hour", label: "session", percentRemaining: 64 }] }),
  seat("bravo", { ageSeconds: 30, windows: [{ id: "five_hour", label: "session", percentRemaining: 45 }] }),
  seat("charlie", {
    autoExcluded: true,
    ageSeconds: 864_000,
    windows: [{ id: "five_hour", label: "session", percentRemaining: 22 }],
  }),
]);

export function world(on: On, options: WorldOptions = {}): World {
  const enabled = "enabled" in options ? options.enabled : "1";
  mock.env(on, {
    ...(enabled === undefined ? {} : { FM_QUOTA_ENABLED: enabled }),
    ...(options.refreshSeconds === undefined ? {} : { FM_QUOTA_REFRESH_SECONDS: options.refreshSeconds }),
  });
  const clock = mock.clock(on);
  const journal: Journal = { commands: [], runs: [], invalidations: [], opens: [], stock: [] };
  let stdout = options.board ?? FIXTURE_BOARD;
  let exitCode = 0;

  on("process.run", async (_$, e) => {
    journal.runs.push([...e.argv]);
    return { value: { exitCode, stdout: exitCode === 0 ? stdout : "", stderr: "", isStdoutTruncated: false, isStderrTruncated: false } };
  });
  on("command.register", async (_$, e) => {
    journal.commands.push(e.name);
    return { value: { command: e.name } };
  });
  on("ui.invalidate", async (_$, e) => {
    journal.invalidations.push(e.event);
    return { value: undefined };
  });
  on("ui.open", async (_$, e) => {
    journal.opens.push(e.id);
    return { value: { isPlaced: true } };
  });
  on("session.start", async (_$, e) => ({ cwd: e.cwd }));
  on("session.measure", async (_$, e) => ({ changed: [...e.changed] }));
  on("ui.render", async (_$, e) => {
    journal.stock.push(e.component);
    return { type: "Text", props: {}, children: [STOCK_TEXT] };
  });

  return {
    clock,
    journal,
    setBoard: (next) => {
      stdout = next;
      exitCode = 0;
    },
    failBoard: (code) => {
      exitCode = code;
    },
    refreshingRuns: () => journal.runs.filter((argv) => !argv.includes("--cached-only")),
  };
}

export const SESSION_START = { cwd: "/work", surface: "terminal" as const, isInteractive: true };
export const HEADLESS_START = { cwd: "/work", surface: "terminal" as const, isInteractive: false };

/** One measurement of this session's account, as the engine raises it. */
export function measurement(rateLimits: { kind: string; percentUsed: number; resetsAt?: string }[]) {
  return {
    context: { window: 200_000 },
    rateLimits: rateLimits as SessionRateLimit[],
    changed: ["rateLimits" as const],
  };
}

export const BAND = {
  surface: "terminal" as const,
  component: "AbovePrompt" as const,
  props: { maxRows: 4, bodyColumns: 100, scroll: { offset: 0, bodyRows: 4, isAtEnd: true }, view: {} },
} as const;

export const PANE = {
  surface: "terminal" as const,
  component: "Pane" as const,
  requestId: "seats",
  props: {
    title: "Claude seats",
    isFocused: false,
    bodyColumns: 100,
    placement: "inline" as const,
    scroll: { offset: 0, bodyRows: 20, isAtEnd: true },
  },
} as const;

export function seatsCommand() {
  return {
    command: "seats",
    args: "",
    origin: { kind: "composer" as const },
    presentation: { layout: "main" as const, isFullscreen: false, columns: 100 },
  };
}

/** Whether a drawing is the engine's own. */
export function isStock(tree: unknown): boolean {
  return JSON.stringify(tree).includes(STOCK_TEXT);
}

/** Every string a drawing puts on screen, flattened, so a test can assert on the text. */
export function textOf(tree: unknown): string {
  return JSON.stringify(tree);
}
