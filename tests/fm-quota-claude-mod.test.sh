#!/usr/bin/env bash
# Portable checks for the Claude Code Quota mod (.claude/mods/firstmate-quota) that need
# no Claude Code binary, so CI enforces them wherever Node runs:
#   - the plugin's declared shape: one hooks module and nothing else, reached from the
#     project's .claude/skills auto-load path through the tracked symlink, so nothing of
#     it can load while its own activation flag is off;
#   - the live-seat policy: the engine reports percent USED and every firstmate seat
#     setting counts percent LEFT, so the conversion and its clamps are pinned here, as
#     is the rule that an empty reading draws nothing rather than a zero;
#   - the all-seats policy: which readings are called stale against the board's own cache
#     window, how a seat with no report is described, and that a reading of another
#     schema is refused outright instead of half-understood;
#   - the refresh cadence that keeps the mod away from the rate-limited quota endpoint:
#     its interval floor, its default for an unreadable setting, and the claim that
#     bounds a burst of timer ticks to one refresh.
# The engine-bound behavior runs under tests/fm-quota-claude-mod-plugin.test.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

MOD="$ROOT/.claude/mods/firstmate-quota"
TMP_ROOT=$(fm_test_tmproot fm-quota-claude-mod)

command -v node >/dev/null 2>&1 || { echo "skip: node not found for the Claude Code Quota mod checks"; exit 0; }

run_node() { # <script-file>
  node --input-type=module <"$1"
}

test_plugin_shape() {
  local link resolved autoload
  link="$ROOT/.agents/skills/firstmate-quota"
  [ -L "$link" ] || fail "the Quota mod is not linked into .agents/skills, so Claude Code's project skills-dir scan cannot adopt it"
  resolved=$(cd "$link" && pwd -P) || fail "the .agents/skills/firstmate-quota link does not resolve"
  [ "$resolved" = "$(cd "$MOD" && pwd -P)" ] || fail "the .agents/skills/firstmate-quota link resolves to $resolved, not the mod"
  autoload="$ROOT/.claude/skills/firstmate-quota"
  [ -f "$autoload/.claude-plugin/plugin.json" ] || fail "the project's .claude/skills path does not reach the mod's manifest"
  [ -f "$autoload/hooks/hooks.json" ] || fail "the project's .claude/skills path does not reach the mod's hooks module declaration"
  [ ! -e "$MOD/SKILL.md" ] || fail "the mod carries a SKILL.md and would load as a skill on every harness"
  cat >"$TMP_ROOT/shape.mjs" <<JS
import { readFileSync } from "node:fs";
const mod = ${MOD@Q};
const manifest = JSON.parse(readFileSync(\`\${mod}/.claude-plugin/plugin.json\`, "utf8"));
if (manifest.name !== "firstmate-quota") throw new Error(\`manifest name \${manifest.name}\`);
for (const key of ["commands", "agents", "skills", "hooks", "mcpServers", "lspServers", "outputStyles"]) {
  if (key in manifest) throw new Error(\`manifest declares \${key}, which would load while the flag is off\`);
}
const hooks = JSON.parse(readFileSync(\`\${mod}/hooks/hooks.json\`, "utf8"));
const keys = Object.keys(hooks).sort();
if (JSON.stringify(keys) !== JSON.stringify(["description", "modules"])) {
  throw new Error(\`hooks.json declares \${keys.join(", ")}: a classic hook would run while the flag is off\`);
}
if (JSON.stringify(hooks.modules) !== JSON.stringify(["./register.ts"])) throw new Error("hooks.json names a different module");
JS
  run_node "$TMP_ROOT/shape.mjs" || fail "the Quota mod declares more than one hooks module"
  pass "the Quota mod declares one hooks module, nothing that loads on its own, and is reachable from the project auto-load path"
}

test_live_seat_policy() {
  cat >"$TMP_ROOT/live.mjs" <<JS
import { pathToFileURL } from "node:url";
const live = await import(pathToFileURL(${MOD@Q} + "/lib/fm-quota-live.ts").href);
const check = (condition, message) => { if (!condition) throw new Error(message); };

// The engine reports percent USED; every firstmate seat setting counts percent LEFT.
check(live.percentLeftFromUsed(0) === 100, "a window nothing has used must read as 100% left");
check(live.percentLeftFromUsed(36) === 64, "36% used must read as 64% left");
check(live.percentLeftFromUsed(100) === 0, "a spent window must read as 0% left");
// An exceeded spend limit reports past 100 used, and a negative remainder is nonsense.
check(live.percentLeftFromUsed(140) === 0, "an exceeded limit must read as nothing left, never a negative");
check(live.percentLeftFromUsed(Number.NaN) === 0, "an unreadable figure must not become a number above zero");

// An empty reading is what the engine gives off a subscription or before the first
// response of a session, and it must draw nothing at all rather than a zero.
check(live.liveWindows([], 0).length === 0, "an empty reading must yield no window");
check(live.liveBandSegment("alpha", []) === undefined, "an empty reading must draw no band segment");
const zeroed = live.liveBandSegment("alpha", live.liveWindows([{ kind: "five_hour", percentUsed: 100 }], 0));
check(zeroed === "alpha 5h 0%", \`a genuinely spent window must still be drawn, got \${zeroed}\`);

// A window whose figure is not a number is dropped rather than drawn as a zero.
check(live.liveWindows([{ kind: "five_hour", percentUsed: "40" }], 0).length === 0, "a non-numeric figure must be dropped");

// Unknown window kinds keep their own name rather than disappearing.
check(live.windowLabel("five_hour") === "5h", "the five-hour window must label as 5h");
check(live.windowLabel("seven_day") === "7d", "the seven-day window must label as 7d");
check(live.windowLabel("lunar_month") === "lunar_month", "an unknown window must keep its own name");

// Tension drives the colour, and the thresholds count percent left.
check(live.tensionOf(100) === "calm" && live.tensionOf(41) === "calm", "plenty left must read calm");
check(live.tensionOf(40) === "warn" && live.tensionOf(16) === "warn", "40% left and below must read as a warning");
check(live.tensionOf(15) === "tight" && live.tensionOf(0) === "tight", "15% left and below must read tight");
check(live.worstTension([{ tension: "calm" }, { tension: "tight" }, { tension: "warn" }]) === "tight", "the worst tension must win");

// A reset wait is never guessed.
const now = Date.parse("2026-10-06T00:00:00Z");
check(live.resetsIn(undefined, now) === "", "an absent reset must yield no wait");
check(live.resetsIn("not a date", now) === "", "an unparseable reset must yield no wait");
check(live.resetsIn("2026-10-05T23:00:00Z", now) === "due", "a past reset must read as due");
check(live.resetsIn("2026-10-06T00:14:00Z", now) === "14m", "a wait under an hour must read in minutes");
check(live.resetsIn("2026-10-06T02:30:00Z", now) === "2h 30m", "a wait over an hour must read in hours and minutes");
check(live.resetsIn("2026-10-06T03:00:00Z", now) === "3h", "a whole-hour wait must omit the minutes");
check(live.resetsIn("2026-10-09T00:00:00Z", now) === "3d", "a multi-day wait must read in days");
// No window resets a month out, so a wait past the horizon is a clock or timestamp
// disagreement and must draw nothing rather than a figure like 20732d 9h.
check(live.resetsIn("2026-12-06T00:00:00Z", now) === "", "a wait past the horizon must draw nothing");
check(live.resetsIn("2026-10-06T00:00:00Z", 0) === "", "a reset read against an unset clock must draw nothing");
check(live.resetsIn("2026-11-04T00:00:00Z", now) !== "", "a wait just inside the horizon must still be drawn");

// Only the tightest window carries its reset, so the band stays one line.
const windows = live.liveWindows(
  [
    { kind: "five_hour", percentUsed: 80, resetsAt: "2026-10-06T02:30:00Z" },
    { kind: "seven_day", percentUsed: 10, resetsAt: "2026-10-09T00:00:00Z" },
  ],
  now,
);
const segment = live.liveBandSegment("alpha", windows);
check(segment.includes("5h 20% (2h 30m)"), \`the tightest window must carry its reset, got \${segment}\`);
check(!segment.includes("7d 90% ("), \`a comfortable window must not carry a reset, got \${segment}\`);

// The text fallback says there is no reading rather than printing a figure.
const empty = live.liveTextLines("alpha", []);
check(empty.length === 1 && empty[0].includes("no rate-limit reading yet"), "an empty reading must say so in text");
JS
  run_node "$TMP_ROOT/live.mjs" || fail "the Quota mod's live-seat policy diverged"
  pass "the live-seat policy converts percent used to percent left, clamps nonsense, draws nothing for an empty reading, and never guesses a reset"
}

test_all_seats_policy() {
  cat >"$TMP_ROOT/seats.mjs" <<JS
import { pathToFileURL } from "node:url";
const seats = await import(pathToFileURL(${MOD@Q} + "/lib/fm-quota-seats.ts").href);
const check = (condition, message) => { if (!condition) throw new Error(message); };

const reading = (overrides = {}, seatOverrides = {}) =>
  JSON.stringify({
    schemaVersion: 1,
    generatedAt: "2026-10-06T00:00:00Z",
    cacheSeconds: 60,
    activeSeat: "alpha",
    liveSeat: "alpha",
    seats: [
      {
        name: "alpha",
        configDir: "/seats/alpha",
        active: true,
        autoExcluded: false,
        cacheFile: "/cache/alpha.json",
        hasData: true,
        ageSeconds: 12,
        account: "alpha@example.test",
        attention: null,
        windows: [{ id: "five_hour", label: "session", percentRemaining: 64, resetsAt: null }],
        extraUsage: null,
        ...seatOverrides,
      },
    ],
    ...overrides,
  });

// A reading that cannot be trusted is refused outright: a half-understood one would be
// drawn as fact.
check(seats.parseSeatBoard("") === undefined, "an empty reading must be refused");
check(seats.parseSeatBoard("not json") === undefined, "a non-JSON reading must be refused");
check(seats.parseSeatBoard("[]") === undefined, "a reading that is not an object must be refused");
check(seats.parseSeatBoard(reading({ schemaVersion: 2 })) === undefined, "another schema version must be refused");
check(seats.parseSeatBoard(JSON.stringify({ schemaVersion: 1 })) === undefined, "a reading with no seats must be refused");
const board = seats.parseSeatBoard(reading());
check(board !== undefined && board.seats.length === 1, "a good reading must parse");
check(board.cacheSeconds === 60 && board.liveSeat === "alpha", "the reading's own cache window and live seat must survive");

// Freshness is measured against the BOARD's cache window, so the two owners of what
// "current" means can never disagree.
const seatOf = (text) => seats.parseSeatBoard(text).seats[0];
const freshness = (fields, cacheSeconds) => {
  const record = seatOf(reading({}, fields));
  return seats.seatFreshness(record, record.ageSeconds, cacheSeconds);
};
check(freshness({ ageSeconds: 12 }, 60) === "fresh", "a reading inside the window is fresh");
check(freshness({ ageSeconds: 61 }, 60) === "stale", "a reading past the window is stale");
check(freshness({ ageSeconds: 864000 }, 60) === "stale", "a ten-day-old reading is stale");
check(freshness({ ageSeconds: 12 }, 86400) === "fresh", "a wider window keeps it fresh");
check(freshness({ ageSeconds: null }, 60) === "unknown", "a reading that cannot be dated is unknown");
check(freshness({ hasData: false }, 60) === "none", "no report at all is no reading");

// Each wording carries the age, so no figure is ever presented as current when it is not.
check(seats.freshnessWord("stale", "10d") === "10d old, stale", "a stale reading must say both its age and that it is stale");
check(seats.freshnessWord("fresh", "12s") === "12s old", "a fresh reading must still carry its age");
check(seats.freshnessWord("unknown", "") === "age unknown", "an undatable reading must say so");
check(seats.freshnessWord("none", "") === "no reading", "a seat with no report must say so");

// An age keeps moving after the read: a reading 30s old at read time is stale once the
// board's 60s window has passed, without any second read.
const aging = seats.parseSeatBoard(reading({}, { ageSeconds: 30 }));
check(seats.seatAgeSeconds(aging.seats[0], 1000, 32000) === 61, "an age must add the time since the read");
check(seats.seatAgeSeconds(aging.seats[0], 5000, 1000) === 30, "a clock behind the read must not make a reading younger");
check(seats.seatRows(aging, 1000, 1000)[0].freshness === "fresh", "a reading inside the window at read time is fresh");
const agedRow = seats.seatRows(aging, 1000, 32000)[0];
check(agedRow.freshness === "stale" && agedRow.ageWord === "1m", \`a reading past the window by render time must be stale, got \${agedRow.freshness} \${agedRow.ageWord}\`);
check(seats.seatRows(seats.parseSeatBoard(reading({}, { ageSeconds: null })), 0, 99000)[0].freshness === "unknown", "an undatable reading stays unknown however long it sits");

check(seats.ageWord(0) === "0s" && seats.ageWord(45) === "45s", "seconds read as seconds");
check(seats.ageWord(600) === "10m", "minutes read as minutes");
check(seats.ageWord(7200) === "2h", "hours read as hours");
check(seats.ageWord(864000) === "10d", "ten days read as 10d");
check(seats.ageWord(-1) === "", "a negative age reads as nothing");

// A seat with no figure must never be drawn as a zero.
const missing = seats.seatRows(
  seats.parseSeatBoard(reading({}, { hasData: false, ageSeconds: null, account: null, attention: "not logged in", windows: [] })),
  0,
  0,
)[0];
check(missing.windows.length === 0, "a seat with no report must carry no figure");
check(seats.seatFiguresText(missing) === "not logged in", "a seat with no report must show why, not a number");
check(!seats.seatLine(missing).includes("%"), \`a seat with no report must print no percentage, got \${seats.seatLine(missing)}\`);

// A window the reader could not read is dropped rather than rounded to zero.
const nulled = seats.seatRows(
  seats.parseSeatBoard(reading({}, { windows: [{ id: "five_hour", label: "session", percentRemaining: null, resetsAt: null }] })),
  0,
  0,
)[0];
check(nulled.windows.length === 0, "a null percentage must be dropped, not drawn as 0%");
check(seats.seatFiguresText(nulled) === "no figures", "a seat whose windows are unreadable must say there are no figures");

// The markers a row carries are the three facts the captain acts on.
const rows = seats.seatRows(
  seats.parseSeatBoard(
    JSON.stringify({
      schemaVersion: 1,
      generatedAt: "",
      cacheSeconds: 60,
      activeSeat: "bravo",
      liveSeat: "alpha",
      seats: [
        { name: "alpha", hasData: true, ageSeconds: 5, windows: [{ id: "five_hour", percentRemaining: 80 }] },
        { name: "bravo", active: true, hasData: true, ageSeconds: 5, windows: [{ id: "five_hour", percentRemaining: 50 }] },
        { name: "charlie", autoExcluded: true, hasData: true, ageSeconds: 99999, windows: [{ id: "five_hour", percentRemaining: 22 }] },
      ],
    }),
  ),
  0,
  0,
);
check(rows[0].live === true && rows[0].marks.includes("this session"), "the live seat must be marked");
check(rows[1].marks.includes("new workers"), "the seat new workers launch on must be marked");
check(rows[2].marks.includes("not in rotation"), "a seat held out of automatic rotation must be marked");
check(!rows[1].live, "the seat new workers launch on is not necessarily the one this session is on");

// The band's second half names the tightest OTHER seat with that figure's own age.
const tightest = seats.tightestOtherSeat(rows);
check(tightest.name === "charlie" && tightest.percentLeft === 22, "the tightest other seat must win");
const segment = seats.seatsBandSegment(rows);
check(segment.includes("charlie 22%") && segment.includes("stale"), \`the band must date the other seats' figure, got \${segment}\`);
check(seats.seatsBandSegment([rows[0]]) === undefined, "a machine with one seat must draw no others clause");
const noFigures = seats.seatRows(
  seats.parseSeatBoard(
    JSON.stringify({
      schemaVersion: 1, generatedAt: "", cacheSeconds: 60, activeSeat: "alpha", liveSeat: "alpha",
      seats: [
        { name: "alpha", hasData: true, ageSeconds: 1, windows: [{ id: "five_hour", percentRemaining: 90 }] },
        { name: "bravo", hasData: false, ageSeconds: null, windows: [] },
      ],
    }),
  ),
  0,
  0,
);
check(seats.seatsBandSegment(noFigures) === "1 other seats: no reading", "other seats with no reading must say so, not show a zero");

// The code root is found through every path Claude Code may name the plugin by.
for (const path of [
  "/repo/.claude/mods/firstmate-quota",
  "/repo/.claude/skills/firstmate-quota",
  "/repo/.agents/skills/firstmate-quota",
]) {
  const root = seats.codeRootFromPluginRoot(path);
  check(root === "/repo", \`\${path} must resolve to /repo, got \${root}\`);
}
check(seats.seatBoardCommand("/repo") === "/repo/bin/fm-seat-board.sh", "the reader must be the seat board");
JS
  run_node "$TMP_ROOT/seats.mjs" || fail "the Quota mod's all-seats policy diverged"
  pass "the all-seats policy dates every figure, calls anything past the board's cache window stale, says when a seat has no reading, and refuses a reading of another schema"
}

test_refresh_cadence() {
  cat >"$TMP_ROOT/cadence.mjs" <<JS
import { pathToFileURL } from "node:url";
const cadence = await import(pathToFileURL(${MOD@Q} + "/lib/fm-quota-cadence.ts").href);
const check = (condition, message) => { if (!condition) throw new Error(message); };

// The default is ten minutes, and nothing may drive it into polling: four seats at the
// floor is one call per seat every two minutes, already well under the rate the Claude
// quota endpoint refuses.
check(cadence.refreshIntervalMs(undefined) === 600000, "an unset interval must be ten minutes");
check(cadence.refreshIntervalMs("") === 600000, "an empty interval must be ten minutes");
check(cadence.refreshIntervalMs("   ") === 600000, "a blank interval must be ten minutes");
check(cadence.refreshIntervalMs("soon") === 600000, "an unreadable interval must be ten minutes, never zero");
check(cadence.refreshIntervalMs("1800") === 1800000, "a longer interval must be honoured");
check(cadence.refreshIntervalMs("1") === 120000, "a shorter interval must be held to the floor");
check(cadence.refreshIntervalMs("0") === 120000, "a zero interval must be held to the floor");
check(cadence.refreshIntervalMs("-600") === 120000, "a negative interval must be held to the floor");
check(cadence.QUOTA_REFRESH_SECONDS_MIN >= 120, "the floor must stay at or above two minutes");

check(cadence.nextRefreshWord(0, 120000, 600000) === "next live refresh in 8m", "the pane must say when the next live refresh is allowed");
check(cadence.nextRefreshWord(0, 599500, 600000) === "next live refresh in 1s", "a wait under a second must still read as a wait");
check(cadence.nextRefreshWord(0, 600000, 600000) === "a live refresh is due", "an elapsed interval must say a refresh is due");
check(cadence.nextRefreshWord(undefined, 5, 600000) === "a live refresh is due", "no claim yet must say a refresh is due");

const decide = (state, now, interval = 600000) => cadence.refreshDecision(state, now, interval);

check(decide({ lastClaimedAtMs: undefined, inFlight: false }, 0) === "read", "a first read is due at once");
check(decide({ lastClaimedAtMs: 0, inFlight: false }, 599999) === "wait", "nothing is due inside the interval");
check(decide({ lastClaimedAtMs: 0, inFlight: false }, 600000) === "read", "a read is due once the interval has passed");
check(decide({ lastClaimedAtMs: 0, inFlight: true }, 600000) === "claim-only", "a read already under way is never doubled");
check(decide({ lastClaimedAtMs: 0, inFlight: true }, 100) === "wait", "an in-flight read inside the interval is simply not due");

// The claim is what bounds a burst: many asks arriving together inside one interval
// spend that interval once, however many of them there are.
let claimed = 0;
let state = { lastClaimedAtMs: 0, inFlight: false };
for (let ask = 0; ask < 50; ask += 1) {
  const decision = decide(state, 600000);
  if (decision === "wait") continue;
  claimed += 1;
  state = { lastClaimedAtMs: 600000, inFlight: false };
}
check(claimed === 1, \`fifty asks inside one interval must spend it once, spent \${claimed}\`);

check(cadence.QUOTA_REFRESH_TIMEOUT_MS <= 600000, "a read must return well inside the ten-minute process ceiling");
check(cadence.QUOTA_REFRESH_TIMEOUT_MS > 30000, "a multi-seat read needs more than the thirty-second default");
check(cadence.QUOTA_CACHED_TIMEOUT_MS < cadence.QUOTA_REFRESH_TIMEOUT_MS, "a cached read touches no network and must be held shorter");
JS
  run_node "$TMP_ROOT/cadence.mjs" || fail "the Quota mod's refresh cadence diverged"
  pass "the refresh cadence defaults to ten minutes, cannot be driven below its floor, and spends one interval on one read however often it is asked"
}

test_plugin_shape
test_live_seat_policy
test_all_seats_policy
test_refresh_cadence

echo "# all fm-quota-claude-mod tests passed"
