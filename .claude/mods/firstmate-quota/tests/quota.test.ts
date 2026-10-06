// firstmate-quota under `claude plugin test`: the activation gate, the band's two
// halves, the /seats pane and its text fallback, and the cadence that keeps the mod from
// polling a rate-limited quota endpoint.
import { describe, expect, test, type Engine } from "claude-code/testing";
import {
  BAND,
  boardReading,
  FIXTURE_BOARD,
  HEADLESS_START,
  isStock,
  measurement,
  PANE,
  PLUGIN,
  SESSION_START,
  seat,
  seatsCommand,
  textOf,
  world,
} from "./support.ts";

describe("activation", () => {
  async function expectInert($: Engine, on: Parameters<typeof world>[0], enabled: string | undefined) {
    const { clock, journal } = world(on, { enabled });
    await $.session.start(SESSION_START);
    await clock.advance(60_000 * 60);
    expect(journal.commands).toEqual([]);
    // Every drawing reaches the engine untouched, and nothing was ever read.
    expect(isStock(await $.ui.render({ ...BAND, plugin: PLUGIN }))).toBe(true);
    expect(journal.runs).toEqual([]);
    expect(journal.invalidations).toEqual([]);
  }

  test("is fully inert when the firstmate flag is absent", async ($, on) => {
    await expectInert($, on, undefined);
  });

  test("is fully inert when the firstmate flag is not exactly one", async ($, on) => {
    await expectInert($, on, "true");
  });

  test("is fully inert when the firstmate flag is explicitly off", async ($, on) => {
    await expectInert($, on, "0");
  });

  test("registers /seats on the firstmate flag alone", async ($, on) => {
    const { journal } = world(on, { enabled: "1" });
    await $.session.start(SESSION_START);
    expect(journal.commands).toEqual(["seats"]);
  });

  test("never reads the dead platform function-hooks flag", async ($, on) => {
    // The Calm mod honours that name as a deprecated alias because it once shipped
    // behind it; this mod never did, so the old opt-in must not switch it on.
    const { journal } = world(on, { enabled: undefined });
    await $.session.start(SESSION_START);
    expect(journal.commands).toEqual([]);
  });
});

describe("this session's own seat", () => {
  test("draws each window's percent LEFT, not the percent used the engine reports", async ($, on) => {
    world(on);
    await $.session.start(SESSION_START);
    await $.session.measure(measurement([{ kind: "five_hour", percentUsed: 36 }]));
    const band = textOf(await $.ui.render({ ...BAND, plugin: PLUGIN }));
    expect(band).toContain("5h 64%");
    expect(band).not.toContain("36%");
  });

  test("names the seat this session is on, as the seat reading resolved it", async ($, on) => {
    const { clock } = world(on, { board: boardReading([seat("alpha")], { liveSeat: "alpha" }) });
    await $.session.start(SESSION_START);
    await clock.settle();
    await $.session.measure(measurement([{ kind: "five_hour", percentUsed: 10 }]));
    expect(textOf(await $.ui.render({ ...BAND, plugin: PLUGIN }))).toContain("alpha 5h 90%");
  });

  test("draws nothing at all before the first reading, never a zero", async ($, on) => {
    // No measurement and no seat reading: the band must be the engine's own.
    world(on, { board: boardReading([]) });
    await $.session.start(SESSION_START);
    expect(isStock(await $.ui.render({ ...BAND, plugin: PLUGIN }))).toBe(true);
  });

  test("draws nothing for an empty rate-limit reading, as off a subscription", async ($, on) => {
    const { clock } = world(on, { board: boardReading([]) });
    await $.session.start(SESSION_START);
    await clock.settle();
    await $.session.measure(measurement([]));
    const band = await $.ui.render({ ...BAND, plugin: PLUGIN });
    expect(isStock(band)).toBe(true);
    expect(textOf(band)).not.toContain("0%");
  });

  test("shows the reset wait on the tightest window", async ($, on) => {
    const { clock } = world(on);
    await clock.set(Date.parse("2026-10-06T00:00:00Z"));
    await $.session.start(SESSION_START);
    await $.session.measure(
      measurement([
        { kind: "five_hour", percentUsed: 80, resetsAt: "2026-10-06T02:30:00Z" },
        { kind: "seven_day", percentUsed: 10, resetsAt: "2026-10-09T00:00:00Z" },
      ]),
    );
    const band = textOf(await $.ui.render({ ...BAND, plugin: PLUGIN }));
    expect(band).toContain("5h 20% (2h 30m)");
    expect(band).toContain("7d 90%");
  });

  test("keeps another mod's band content rather than replacing it", async ($, on) => {
    world(on);
    await $.session.start(SESSION_START);
    await $.session.measure(measurement([{ kind: "five_hour", percentUsed: 5 }]));
    const band = textOf(await $.ui.render({ ...BAND, plugin: PLUGIN }));
    expect(band).toContain("STOCK-BAND");
    expect(band).toContain("5h 95%");
  });

  test("stays one line, with both halves on it", async ($, on) => {
    const { clock } = world(on);
    await $.session.start(SESSION_START);
    await clock.settle();
    await $.session.measure(measurement([{ kind: "five_hour", percentUsed: 36 }]));
    const band = textOf(await $.ui.render({ ...BAND, plugin: PLUGIN }));
    expect(band).toContain("5h 64%");
    expect(band).toContain("others tightest charlie 22%");
    // One Text of the mod's own, so the band cannot grow a second row.
    expect(band.split("truncate-end").length - 1).toBe(1);
  });
});

describe("every other seat", () => {
  test("lists each configured seat with its own age", async ($, on) => {
    const { clock } = world(on);
    await $.session.start(SESSION_START);
    await clock.settle();
    const pane = textOf(await $.ui.render({ ...PANE, plugin: PLUGIN }));
    expect(pane).toContain("alpha");
    expect(pane).toContain("bravo");
    expect(pane).toContain("charlie");
    expect(pane).toContain("30s old");
  });

  test("calls a reading past the cache window stale and says how old it is", async ($, on) => {
    const { clock } = world(on);
    await $.session.start(SESSION_START);
    await clock.settle();
    const pane = textOf(await $.ui.render({ ...PANE, plugin: PLUGIN }));
    expect(pane).toContain("10d old, stale");
  });

  test("ages a reading with the clock, so a figure that was fresh turns stale", async ($, on) => {
    const { clock, journal } = world(on, { refreshSeconds: "3600" });
    await $.session.start(SESSION_START);
    await clock.settle();
    expect(textOf(await $.ui.render({ ...PANE, plugin: PLUGIN }))).toContain("(30s old)");
    await clock.advance(31_000);
    const pane = textOf(await $.ui.render({ ...PANE, plugin: PLUGIN }));
    expect(pane).toContain("(1m old, stale)");
    expect(pane).not.toContain("(30s old)");
    // Nothing was reread: the age moved with the clock alone.
    expect(journal.runs.length).toBe(1);
  });

  test("says a seat has no reading rather than drawing a zero", async ($, on) => {
    const { clock } = world(on, {
      board: boardReading([
        seat("alpha", { ageSeconds: 5, windows: [{ id: "five_hour", label: "session", percentRemaining: 71 }] }),
        seat("bravo", { hasData: false, ageSeconds: null, account: null, attention: "not logged in", windows: [] }),
      ]),
    });
    await $.session.start(SESSION_START);
    await clock.settle();
    const pane = textOf(await $.ui.render({ ...PANE, plugin: PLUGIN }));
    expect(pane).toContain("not logged in");
    expect(pane).toContain("no reading");
    expect(pane).not.toContain("0%");
  });

  test("marks the seat new workers launch on and the seats held out of rotation", async ($, on) => {
    const { clock } = world(on);
    await $.session.start(SESSION_START);
    await clock.settle();
    const pane = textOf(await $.ui.render({ ...PANE, plugin: PLUGIN }));
    expect(pane).toContain("this session");
    expect(pane).toContain("new workers");
    expect(pane).toContain("not in rotation");
  });

  test("says the seats could not be read rather than inventing figures", async ($, on) => {
    const { clock, failBoard } = world(on);
    failBoard(2);
    await $.session.start(SESSION_START);
    await clock.settle();
    const pane = textOf(await $.ui.render({ ...PANE, plugin: PLUGIN }));
    expect(pane).toContain("could not be read");
    expect(pane).toContain("exited 2");
    expect(pane).not.toContain("%");
  });

  test("refuses a reading of another schema rather than half-understanding it", async ($, on) => {
    const { clock } = world(on, { board: boardReading([seat("alpha")], { schemaVersion: 99 }) });
    await $.session.start(SESSION_START);
    await clock.settle();
    expect(textOf(await $.ui.render({ ...PANE, plugin: PLUGIN }))).toContain("does not understand");
  });
});

describe("the cadence that protects the quota endpoint", () => {
  test("reads only the cache at session start, so opening a session spends no quota call", async ($, on) => {
    const { clock, journal, refreshingRuns } = world(on);
    await $.session.start(SESSION_START);
    await clock.settle();
    expect(journal.runs.length).toBe(1);
    expect(journal.runs[0]).toEqual([expect.stringContaining("bin/fm-seat-board.sh"), "json", "--cached-only"]);
    expect(refreshingRuns()).toEqual([]);
  });

  test("does not refresh before the interval has passed, however often the timer ticks", async ($, on) => {
    const { clock, refreshingRuns } = world(on, { refreshSeconds: "600" });
    await $.session.start(SESSION_START);
    await clock.advance(599_000);
    expect(refreshingRuns()).toEqual([]);
  });

  test("refreshes once the interval has passed, and only once per interval", async ($, on) => {
    const { clock, refreshingRuns } = world(on, { refreshSeconds: "600" });
    await $.session.start(SESSION_START);
    await clock.settle();
    for (let minute = 0; minute < 10; minute += 1) await clock.advance(60_000);
    expect(refreshingRuns().length).toBe(1);
    expect(refreshingRuns()[0]).toEqual([expect.stringContaining("bin/fm-seat-board.sh"), "json"]);
    // Nine more ticks inside the same interval add nothing; the tenth opens the next.
    for (let minute = 0; minute < 9; minute += 1) await clock.advance(60_000);
    expect(refreshingRuns().length).toBe(1);
    await clock.advance(60_000);
    expect(refreshingRuns().length).toBe(2);
  });

  test("refreshes once when several timer ticks arrive together inside one interval", async ($, on) => {
    // A machine that slept through several ticks asks the question many times at once,
    // and each of those asks resumes after the clock has already moved on.
    const { clock, refreshingRuns } = world(on, { refreshSeconds: "600" });
    await $.session.start(SESSION_START);
    await clock.advance(601_000);
    expect(refreshingRuns().length).toBe(1);
  });

  test("refreshes once per interval over an hour, not once per tick", async ($, on) => {
    // Sixty ticks, six intervals: the rate the quota endpoint sees is the interval's,
    // and across four seats that is well under one call per seat per minute.
    const { clock, refreshingRuns } = world(on, { refreshSeconds: "600" });
    await $.session.start(SESSION_START);
    await clock.settle();
    for (let minute = 0; minute < 60; minute += 1) await clock.advance(60_000);
    expect(refreshingRuns().length).toBe(6);
  });

  test("holds a configured interval to its floor, so it cannot be driven into polling", async ($, on) => {
    const { clock, refreshingRuns } = world(on, { refreshSeconds: "1" });
    await $.session.start(SESSION_START);
    await clock.advance(119_000);
    expect(refreshingRuns()).toEqual([]);
    await clock.advance(2_000);
    expect(refreshingRuns().length).toBe(1);
  });

  test("keeps the default interval for an unreadable configured value", async ($, on) => {
    const { clock, refreshingRuns } = world(on, { refreshSeconds: "soon" });
    await $.session.start(SESSION_START);
    await clock.advance(599_000);
    expect(refreshingRuns()).toEqual([]);
    await clock.advance(2_000);
    expect(refreshingRuns().length).toBe(1);
  });

  test("never reads the seats while drawing, however many times it draws", async ($, on) => {
    const { clock, journal } = world(on);
    await $.session.start(SESSION_START);
    await clock.settle();
    const before = journal.runs.length;
    await $.session.measure(measurement([{ kind: "five_hour", percentUsed: 20 }]));
    for (let draw = 0; draw < 20; draw += 1) {
      await $.ui.render({ ...BAND, plugin: PLUGIN });
      await $.ui.render({ ...PANE, plugin: PLUGIN });
    }
    expect(journal.runs.length).toBe(before);
  });
});

describe("the pane's Refresh", () => {
  async function pressRefresh($: Engine) {
    await $.ui.render({ ...PANE, plugin: PLUGIN });
    await $.ui.press({ plugin: PLUGIN, key: "refresh", requestId: PANE.requestId });
  }

  test("rereads only the cache at once and says when the next live refresh is allowed", async ($, on) => {
    const { clock, journal, refreshingRuns, setBoard } = world(on, { refreshSeconds: "600" });
    await $.session.start(SESSION_START);
    await clock.settle();
    await clock.advance(120_000);
    setBoard(boardReading([seat("alpha"), seat("bravo", { ageSeconds: 3, windows: [{ id: "five_hour", label: "session", percentRemaining: 41 }] })]));
    await pressRefresh($);
    await clock.settle();
    expect(journal.runs.length).toBe(2);
    expect(refreshingRuns()).toEqual([]);
    const pane = textOf(await $.ui.render({ ...PANE, plugin: PLUGIN }));
    expect(pane).toContain("session 41%");
    expect(pane).toContain("read 0s ago");
    expect(pane).toContain("next live refresh in 8m");
  });

  test("never reaches the quota endpoint, even once the live interval has elapsed", async ($, on) => {
    // A 630s interval elapses between the timer's ticks at 600s and 660s, so a press in
    // that gap meets an elapsed interval with no tick of its own to blame.
    const { clock, journal, refreshingRuns } = world(on, { refreshSeconds: "630" });
    await $.session.start(SESSION_START);
    await clock.settle();
    for (let count = 0; count < 5; count += 1) {
      await pressRefresh($);
      await clock.settle();
    }
    await clock.advance(640_000);
    expect(refreshingRuns()).toEqual([]);
    expect(textOf(await $.ui.render({ ...PANE, plugin: PLUGIN }))).toContain("a live refresh is due");
    const before = journal.runs.length;
    await pressRefresh($);
    await clock.settle();
    expect(journal.runs.length).toBe(before + 1);
    expect(refreshingRuns()).toEqual([]);
    // The timer's own tick is what refreshes, once.
    await clock.advance(20_000);
    expect(refreshingRuns().length).toBe(1);
  });

  test("does not spend the live refresh when the timer fires during its cached read", async ($, on) => {
    const { clock, holdBoard, refreshingRuns } = world(on, { refreshSeconds: "600" });
    await $.session.start(SESSION_START);
    await clock.settle();
    await clock.advance(540_000);
    const release = holdBoard();
    await pressRefresh($);
    // The tick at 600s finds the interval elapsed while the cached read is still running.
    await clock.advance(60_000);
    expect(refreshingRuns()).toEqual([]);
    release();
    await clock.settle();
    expect(refreshingRuns().length).toBe(1);
    // That refresh claimed the interval, so the next one waits its full length.
    await clock.advance(540_000);
    expect(refreshingRuns().length).toBe(1);
    await clock.advance(60_000);
    expect(refreshingRuns().length).toBe(2);
  });
});

describe("/seats", () => {
  test("opens the pane in a session that can draw", async ($, on) => {
    const { clock, journal } = world(on);
    await $.session.start(SESSION_START);
    await clock.settle();
    const result = await $.command.run(seatsCommand());
    expect(journal.opens).toEqual(["seats"]);
    expect(result.text ?? "").toBe("");
  });

  test("answers with text in a session where nothing can be drawn", async ($, on) => {
    const { clock, journal } = world(on);
    await $.session.start(HEADLESS_START);
    await clock.settle();
    const result = await $.command.run(seatsCommand());
    expect(journal.opens).toEqual([]);
    const text = result.text ?? "";
    expect(text).toContain("alpha");
    expect(text).toContain("bravo");
    expect(text).toContain("10d old, stale");
    expect(text).toContain("no rate-limit reading yet");
  });

  test("carries this session's own live figures in the text fallback too", async ($, on) => {
    const { clock } = world(on);
    await $.session.start(HEADLESS_START);
    await clock.settle();
    await $.session.measure(measurement([{ kind: "five_hour", percentUsed: 25 }]));
    const result = await $.command.run(seatsCommand());
    expect(result.text ?? "").toContain("5h 75% left");
  });
});

describe("the reading used for every draw", () => {
  test("is the one in memory, so a failed refresh keeps the last good reading", async ($, on) => {
    const { clock, failBoard } = world(on, { refreshSeconds: "600" });
    await $.session.start(SESSION_START);
    await clock.settle();
    expect(textOf(await $.ui.render({ ...PANE, plugin: PLUGIN }))).toContain("bravo");
    failBoard(1);
    await clock.advance(601_000);
    const pane = textOf(await $.ui.render({ ...PANE, plugin: PLUGIN }));
    expect(pane).toContain("bravo");
    expect(pane).toContain("last read failed");
  });

  test("names FIXTURE_BOARD's seats exactly, so a dropped seat cannot pass unnoticed", async ($, on) => {
    const { clock } = world(on, { board: FIXTURE_BOARD });
    await $.session.start(SESSION_START);
    await clock.settle();
    const pane = textOf(await $.ui.render({ ...PANE, plugin: PLUGIN }));
    for (const name of ["alpha", "bravo", "charlie"]) expect(pane).toContain(name);
  });
});
