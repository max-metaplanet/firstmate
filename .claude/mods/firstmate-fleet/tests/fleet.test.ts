// firstmate-fleet under `claude plugin test`: the activation gate, the single in-flight
// reading behind the 60s clock, the pane, the band's etiquette, the transition notices,
// and the text answer a session that cannot draw gets instead.
import { describe, expect, test, type Engine } from "claude-code/testing";
import {
  band,
  fleetCommand,
  flatten,
  hold,
  isStock,
  pane,
  SESSION_START,
  SESSION_START_HEADLESS,
  snapshotJson,
  SNAPSHOT_ARGV,
  task,
  textsOf,
  world,
} from "./support.ts";

describe("activation", () => {
  async function expectInert($: Engine, on: Parameters<typeof world>[0], enabled: string | undefined) {
    const { clock, journal } = world(on, { enabled });
    await $.session.start(SESSION_START);
    expect(isStock(await $.ui.render(pane()))).toBe(true);
    expect(isStock(await $.ui.render(band()))).toBe(true);
    // The engine's own run is reached, so /fleet is nobody's command here.
    expect((await $.command.run(fleetCommand())).text).toBeUndefined();
    expect(journal.stockCommands).toEqual(["fleet"]);
    await clock.advance(180_000);
    expect(journal.runs).toHaveLength(0);
    expect(journal.commands).toHaveLength(0);
    expect(journal.toasts).toHaveLength(0);
    expect(journal.invalidations).toHaveLength(0);
    expect(journal.opens).toHaveLength(0);
  }

  test("is fully inert when the activation flag is absent", async ($, on) => {
    await expectInert($, on, undefined);
  });

  test("is fully inert when the activation flag is not exactly one", async ($, on) => {
    await expectInert($, on, "true");
  });

  test("registers /fleet and reads the fleet once at session start", async ($, on) => {
    const { journal } = world(on);
    await $.session.start(SESSION_START);
    expect(journal.commands).toEqual(["fleet"]);
    expect(journal.runs).toHaveLength(1);
    expect(journal.runs[0]!.argv).toEqual(SNAPSHOT_ARGV);
    // The command measures 17.7-21.6s against a 30s default, so the timeout is explicit.
    expect(journal.runs[0]!.timeoutMs).toBeGreaterThan(30_000);
  });

  test("reads from the plugin's own code root when no override names another", async ($, on) => {
    const { clock, journal } = world(on, { rootOverride: undefined });
    await $.session.start(SESSION_START);
    await clock.advance(0);
    expect(journal.runs).toHaveLength(1);
    const [program] = journal.runs[0]!.argv;
    // `bin/` belongs to the tracked code root, three levels above the plugin folder,
    // never to the Firstmate home FM_HOME selects.
    expect(program).toMatch(/\/bin\/fm-fleet-snapshot\.sh$/);
    expect(program).not.toContain("/fm/home/");
    expect(program).not.toContain("/mods/");
  });
});

describe("the reading", () => {
  test("never starts a second reading while one is in flight", async ($, on) => {
    const { clock, journal, hold: holdRuns } = world(on);
    const held = holdRuns();
    void $.session.start(SESSION_START);
    await clock.advance(0);
    expect(journal.runs).toHaveLength(1);
    // Two overlapping runs of this command were measured at 72s where one takes 18s, so
    // every later caller joins the run in flight.
    await clock.advance(60_000);
    await clock.advance(60_000);
    void $.command.run(fleetCommand());
    await clock.advance(0);
    expect(journal.runs).toHaveLength(1);
    await held.release();
    expect(flatten(await $.ui.render(pane()))).toContain("alpha");
  });

  test("a render never starts a reading", async ($, on) => {
    const { clock, journal } = world(on);
    await $.session.start(SESSION_START);
    await clock.advance(0);
    const before = journal.runs.length;
    await $.ui.render(pane());
    await $.ui.render(band());
    await $.ui.render(pane());
    expect(journal.runs).toHaveLength(before);
  });

  test("re-reads on the sixty-second clock", async ($, on) => {
    const { clock, journal } = world(on);
    await $.session.start(SESSION_START);
    await clock.advance(0);
    expect(journal.runs).toHaveLength(1);
    await clock.advance(60_000);
    expect(journal.runs).toHaveLength(2);
    await clock.advance(120_000);
    expect(journal.runs).toHaveLength(4);
  });

  test("re-reads when the pane's refresh is pressed", async ($, on) => {
    const { clock, journal } = world(on);
    await $.session.start(SESSION_START);
    await clock.advance(0);
    const before = journal.runs.length;
    await $.ui.render(pane());
    await $.ui.press({ plugin: "firstmate-fleet", requestId: "fleet", key: "refresh" });
    await clock.advance(0);
    expect(journal.runs.length).toBeGreaterThan(before);
  });
  test("resolves the reading and starts the clock from a hook reached before session start", async ($, on) => {
    const { clock, journal } = world(on);
    // A hot reload can reach a drawing before session.start; the render itself never reads.
    expect(isStock(await $.ui.render(band()))).toBe(true);
    expect(journal.runs).toHaveLength(0);
    await clock.advance(60_000);
    expect(journal.runs).toHaveLength(1);
    expect(journal.runs[0]!.argv).toEqual(SNAPSHOT_ARGV);
    expect(flatten(await $.ui.render(pane()))).toContain("alpha");
  });

  test("answers /fleet as text when no session start has said the session can draw", async ($, on) => {
    const { clock, journal } = world(on);
    const answer = await $.command.run(fleetCommand());
    await clock.advance(0);
    expect(journal.opens).toHaveLength(0);
    expect(answer.text).toContain("fleet (2):");
  });
});

describe("the pane", () => {
  test("draws one row per task, with the state word and the event beneath it", async ($, on) => {
    const { clock } = world(on, {
      reading: {
        exitCode: 0,
        stdout: snapshotJson([
          task({ id: "alpha", state: "working", source: "pane", ageSeconds: 300 }),
          task({ id: "beta", state: "blocked", source: "status-log", lastEvent: "blocked [at=9]: needs a credential" }),
        ]),
        stderr: "",
      },
    });
    await $.session.start(SESSION_START);
    await clock.advance(0);
    const texts = textsOf(await $.ui.render(pane()));
    expect(texts).toContain("alpha");
    expect(texts).toContain("working");
    expect(texts).toContain("beta");
    expect(texts).toContain("blocked");
    expect(texts).toContain("(status-log)");
    expect(texts).toContain("5m");
    // The status log's last line is an EVENT, never a state, and is labeled as one.
    expect(flatten(await $.ui.render(pane()))).toContain("event: blocked [at=9]: needs a credential");
  });

  test("keeps unreadable and unknown apart rather than collapsing them", async ($, on) => {
    const { clock } = world(on, {
      reading: {
        exitCode: 0,
        stdout: snapshotJson([
          task({ id: "alpha", state: "unreadable", source: "none" }),
          task({ id: "beta", state: "unknown", source: "none" }),
        ]),
        stderr: "",
      },
    });
    await $.session.start(SESSION_START);
    await clock.advance(0);
    const texts = textsOf(await $.ui.render(pane()));
    expect(texts).toContain("unreadable");
    expect(texts).toContain("unknown");
  });

  test("passes a pane that is not its own straight through", async ($, on) => {
    const { clock } = world(on);
    await $.session.start(SESSION_START);
    await clock.advance(0);
    expect(isStock(await $.ui.render(pane("someone-elses-pane")))).toBe(true);
  });

  test("shows a failed reading as unavailable and claims no state at all", async ($, on) => {
    const { clock } = world(on, { reading: { exitCode: 2, stdout: "", stderr: "fm-fleet-snapshot: boom" } });
    await $.session.start(SESSION_START);
    await clock.advance(0);
    const drawn = flatten(await $.ui.render(pane()));
    expect(drawn).toMatch(/fleet unavailable: the fleet reading exited 2: fm-fleet-snapshot: boom/);
    expect(drawn).not.toContain("working");
    expect(drawn).not.toMatch(/fleet \(0\)/);
  });

  test("refuses a reading that is not this snapshot's schema", async ($, on) => {
    const { clock } = world(on, { reading: { exitCode: 0, stdout: '{"schema":"something-else","tasks":[]}', stderr: "" } });
    await $.session.start(SESSION_START);
    await clock.advance(0);
    expect(flatten(await $.ui.render(pane()))).toMatch(/fleet unavailable: .*schema something-else/);
  });

  test("keeps the last good rows and marks them stale when a later reading fails", async ($, on) => {
    const { clock, journal, answer } = world(on);
    await $.session.start(SESSION_START);
    await clock.advance(0);
    const redrawsBefore = journal.invalidations.length;
    answer({ reject: "timed out after 90000ms" });
    await clock.advance(60_000);
    // A failed reading redraws too, or the drawing on screen would go on claiming more
    // than the mod still knows.
    expect(journal.invalidations.length).toBeGreaterThan(redrawsBefore);
    const drawn = flatten(await $.ui.render(pane()));
    expect(drawn).toContain("alpha");
    expect(drawn).toMatch(/fleet reading .* old: .*timed out/);
  });
});

describe("the band", () => {
  test("draws nothing and leaves the other mods' content alone when nothing waits", async ($, on) => {
    const { clock } = world(on);
    await $.session.start(SESSION_START);
    await clock.advance(0);
    const drawn = await $.ui.render(band());
    expect(isStock(drawn)).toBe(true);
    expect(flatten(drawn)).not.toMatch(/waiting on you/);
  });

  test("names what waits and keeps the other mods' content above its own line", async ($, on) => {
    const { clock } = world(on, {
      reading: {
        exitCode: 0,
        stdout: snapshotJson([
          task({ id: "alpha", state: "working" }),
          task({ id: "beta", state: "blocked" }),
          task({ id: "gamma", state: "working", pendingDecision: true, openDecisions: ["scope"] }),
          task({ id: "delta", state: "done", pr: "https://github.com/o/r/pull/7", yolo: "off" }),
        ]),
        stderr: "",
      },
    });
    await $.session.start(SESSION_START);
    await clock.advance(0);
    const drawn = flatten(await $.ui.render(band()));
    expect(drawn).toContain("3 waiting on you");
    expect(drawn).toContain("beta (blocker)");
    expect(drawn).toContain("gamma (decision)");
    expect(drawn).toContain("delta (merge)");
    expect(drawn).not.toContain("alpha");
    // Returning a tree replaces what later mods draw there, so theirs is nested, not lost.
    expect(isStock(drawn)).toBe(true);
  });

  test("owes no merge ask on work firstmate may merge itself", async ($, on) => {
    const { clock } = world(on, {
      reading: {
        exitCode: 0,
        stdout: snapshotJson([task({ id: "alpha", state: "done", pr: "https://github.com/o/r/pull/8", yolo: "on" })]),
        stderr: "",
      },
    });
    await $.session.start(SESSION_START);
    await clock.advance(0);
    expect(isStock(await $.ui.render(band()))).toBe(true);
  });

  test("counts a live captain hold with no worker of its own", async ($, on) => {
    const { clock } = world(on, {
      reading: {
        exitCode: 0,
        stdout: snapshotJson([task({ id: "alpha" })], [hold("scope-call", true), hold("later-call", false)]),
        stderr: "",
      },
    });
    await $.session.start(SESSION_START);
    await clock.advance(0);
    const drawn = flatten(await $.ui.render(band()));
    expect(drawn).toContain("1 waiting on you");
    expect(drawn).toContain("scope-call (decision)");
    expect(drawn).not.toContain("later-call");
  });

  test("stays silent over an unreadable fleet with nothing waiting, and says so once per outage", async ($, on) => {
    const { clock, journal, answer } = world(on, { reading: { exitCode: 2, stdout: "", stderr: "boom" } });
    await $.session.start(SESSION_START);
    await clock.advance(0);
    const drawn = await $.ui.render(band());
    expect(isStock(drawn)).toBe(true);
    expect(flatten(drawn)).not.toMatch(/fleet unavailable/);
    expect(flatten(await $.ui.render(pane()))).toMatch(/fleet unavailable: the fleet reading exited 2: boom/);
    // A lone failed reading stays quiet.
    expect(journal.toasts).toHaveLength(0);
    await clock.advance(60_000);
    expect(journal.toasts).toEqual(["fleet cannot be read: the fleet reading exited 2: boom"]);
    await clock.advance(60_000);
    expect(journal.toasts).toHaveLength(1);
    answer({ exitCode: 0, stdout: snapshotJson(), stderr: "" });
    await clock.advance(60_000);
    answer({ reject: "timed out after 90000ms" });
    await clock.advance(60_000);
    expect(journal.toasts).toHaveLength(1);
    await clock.advance(60_000);
    expect(journal.toasts).toEqual([
      "fleet cannot be read: the fleet reading exited 2: boom",
      "fleet reading failing; rows shown are 2m old: firstmate-fleet: $.process.run: timed out after 90000ms",
    ]);
    await clock.advance(60_000);
    expect(journal.toasts).toHaveLength(2);
    expect(flatten(await $.ui.render(pane()))).toContain("alpha");
    expect(isStock(await $.ui.render(band()))).toBe(true);
  });
});

describe("notices", () => {
  test("announces nothing for the states the first reading already found", async ($, on) => {
    const { clock, journal } = world(on, {
      reading: {
        exitCode: 0,
        stdout: snapshotJson([
          task({ id: "alpha", state: "done", pr: "https://github.com/o/r/pull/1" }),
          task({ id: "beta", state: "blocked" }),
          task({ id: "gamma", state: "failed" }),
        ]),
        stderr: "",
      },
    });
    await $.session.start(SESSION_START);
    await clock.advance(0);
    expect(journal.toasts).toHaveLength(0);
  });

  test("announces each transition into done, blocked, or failed exactly once", async ($, on) => {
    const { clock, journal, answer } = world(on, {
      reading: { exitCode: 0, stdout: snapshotJson([task({ id: "alpha" }), task({ id: "beta" })]), stderr: "" },
    });
    await $.session.start(SESSION_START);
    await clock.advance(0);
    expect(journal.toasts).toHaveLength(0);
    answer({
      exitCode: 0,
      stdout: snapshotJson([
        task({ id: "alpha", state: "done", pr: "https://github.com/o/r/pull/4" }),
        task({ id: "beta", state: "blocked", pendingDecision: true }),
      ]),
      stderr: "",
    });
    await clock.advance(60_000);
    expect(journal.toasts).toEqual([
      "alpha: done · https://github.com/o/r/pull/4",
      "beta: blocked (needs your decision)",
    ]);
    await clock.advance(60_000);
    await clock.advance(60_000);
    expect(journal.toasts).toHaveLength(2);
  });

  test("announces a task flapping between blocked and working only once", async ($, on) => {
    const { clock, journal, answer } = world(on, {
      reading: { exitCode: 0, stdout: snapshotJson([task({ id: "alpha" })]), stderr: "" },
    });
    await $.session.start(SESSION_START);
    await clock.advance(0);
    for (const state of ["blocked", "working", "blocked", "working", "blocked"]) {
      answer({ exitCode: 0, stdout: snapshotJson([task({ id: "alpha", state })]), stderr: "" });
      await clock.advance(60_000);
    }
    expect(journal.toasts).toEqual(["alpha: blocked"]);
    answer({ exitCode: 0, stdout: snapshotJson([task({ id: "alpha", state: "done" })]), stderr: "" });
    await clock.advance(60_000);
    expect(journal.toasts).toEqual(["alpha: blocked", "alpha: done"]);
  });

  test("announces again for a task that left the fleet and came back", async ($, on) => {
    const { clock, journal, answer } = world(on, {
      reading: { exitCode: 0, stdout: snapshotJson([task({ id: "alpha", state: "blocked" })]), stderr: "" },
    });
    await $.session.start(SESSION_START);
    await clock.advance(0);
    answer({ exitCode: 0, stdout: snapshotJson([]), stderr: "" });
    await clock.advance(60_000);
    answer({ exitCode: 0, stdout: snapshotJson([task({ id: "alpha", state: "blocked" })]), stderr: "" });
    await clock.advance(60_000);
    expect(journal.toasts).toEqual(["alpha: blocked"]);
  });

  test("announces nothing for a move back to work", async ($, on) => {
    const { clock, journal, answer } = world(on, {
      reading: { exitCode: 0, stdout: snapshotJson([task({ id: "alpha", state: "blocked" })]), stderr: "" },
    });
    await $.session.start(SESSION_START);
    await clock.advance(0);
    answer({ exitCode: 0, stdout: snapshotJson([task({ id: "alpha", state: "working" })]), stderr: "" });
    await clock.advance(60_000);
    expect(journal.toasts).toHaveLength(0);
  });
});

describe("/fleet", () => {
  test("keeps waiting on the clock's reading across its sleeps and answers with its rows", async ($, on) => {
    const { clock, journal, hold: holdRuns } = world(on);
    await $.session.start(SESSION_START_HEADLESS);
    const held = holdRuns();
    await clock.advance(60_000);
    let answered: string | undefined;
    void $.command.run(fleetCommand()).then((result) => {
      answered = result.text;
    });
    for (let second = 0; second < 6; second += 1) await clock.advance(1_000);
    expect(answered).toBeUndefined();
    await held.release();
    await clock.advance(500);
    await clock.advance(500);
    expect(answered).toContain("fleet (2):");
    expect(journal.runs).toHaveLength(1);
  });

  test("answers that the fleet is still being read before its sleeps outrun the hook budget", async ($, on) => {
    const { clock, journal, hold: holdRuns } = world(on);
    await $.session.start(SESSION_START_HEADLESS);
    holdRuns();
    await clock.advance(60_000);
    let answered: string | undefined;
    void $.command.run(fleetCommand()).then((result) => {
      answered = result.text;
    });
    // The engine cuts the hook at 10s of wall time, sleeps included.
    for (let step = 0; step < 19; step += 1) await clock.advance(500);
    expect(answered).toContain("reading the fleet…");
    expect(answered).not.toContain("fleet (0)");
    expect(journal.runs).toHaveLength(1);
  });

  test("opens the pane and prints no transcript row where the session can draw", async ($, on) => {
    const { clock, journal } = world(on);
    await $.session.start(SESSION_START);
    await clock.advance(0);
    const answer = await $.command.run(fleetCommand());
    expect(answer.text).toBeUndefined();
    expect(journal.opens).toEqual([{ id: "fleet", title: "Fleet" }]);
    // The mod answered: the engine's own run was never reached.
    expect(journal.stockCommands).toHaveLength(0);
  });

  test("answers with the same rows as text where nothing drawn is ever seen", async ($, on) => {
    const { clock, journal } = world(on, {
      reading: {
        exitCode: 0,
        stdout: snapshotJson([
          task({ id: "alpha", state: "working", source: "pane", ageSeconds: 300 }),
          task({ id: "beta", state: "blocked", source: "status-log" }),
        ]),
        stderr: "",
      },
    });
    await $.session.start(SESSION_START_HEADLESS);
    await clock.advance(0);
    const answer = await $.command.run(fleetCommand());
    expect(journal.opens).toHaveLength(0);
    const text = answer.text ?? "";
    expect(text).toContain("fleet (2):");
    expect(text).toContain("1 waiting on you: beta (blocker)");
    expect(text).toContain("alpha ship · working (pane) · 5m");
    expect(text).toContain("beta ship · blocked (status-log)");
    // Every id and state word the pane draws is in the text answer too.
    for (const drawn of textsOf(await $.ui.render(pane()))) {
      if (drawn === "?" || drawn === ">" || drawn === "·" || drawn === "Refresh") continue;
      expect(text).toContain(drawn.trim());
    }
  });

  test("takes the first reading itself where the session cannot draw", async ($, on) => {
    const { clock, journal, hold: holdRuns } = world(on);
    const held = holdRuns();
    await $.session.start(SESSION_START_HEADLESS);
    await clock.advance(0);
    expect(journal.runs).toHaveLength(0);
    let answered: string | undefined;
    void $.command.run(fleetCommand()).then((result) => {
      answered = result.text;
    });
    await clock.advance(0);
    expect(journal.runs).toHaveLength(1);
    expect(answered).toBeUndefined();
    await held.release();
    await clock.advance(0);
    expect(answered).toContain("fleet (2):");
  });

  test("reports an unreadable fleet as unavailable rather than as an empty one", async ($, on) => {
    const { clock } = world(on, { reading: { exitCode: 2, stdout: "", stderr: "boom" } });
    await $.session.start(SESSION_START_HEADLESS);
    await clock.advance(0);
    const answer = await $.command.run(fleetCommand());
    expect(answer.text).toMatch(/fleet: fleet unavailable: the fleet reading exited 2: boom/);
    expect(answer.text).not.toContain("fleet (0)");
  });
});
