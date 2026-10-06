#!/usr/bin/env bash
# Portable checks for the Claude Code Fleet mod (.claude/mods/firstmate-fleet) that need
# no Claude Code binary, so CI enforces them wherever Node runs:
#   - the plugin's declared shape: one hooks module and nothing else, reached from the
#     project's .claude/skills auto-load path through the tracked symlink, so no command,
#     skill, agent, or classic hook can load while the activation flag is off;
#   - the activation rule itself: only the exact value 1 activates, and the reader is
#     resolved from the tracked code root rather than from the home FM_HOME selects;
#   - the reading policy over the REAL producer's bytes: bin/fm-fleet-snapshot.sh --json
#     is run against a synthetic Firstmate home and its output is fed through the mod's
#     own parser, so the parser cannot drift from the schema that feeds it;
#   - the pure decisions every surface takes its wording from: what waits on the captain,
#     how a failed or aged reading is described, which transitions earn a notice, and the
#     row parity between the pane and the text answer.
# The engine-bound behavior runs under tests/fm-fleet-mod-plugin.test.sh, which also pins
# the hooks and capabilities Claude Code's own scan reports.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

MOD="$ROOT/.claude/mods/firstmate-fleet"
SNAPSHOT="$ROOT/bin/fm-fleet-snapshot.sh"
TMP_ROOT=$(fm_test_tmproot fm-fleet-mod)

command -v node >/dev/null 2>&1 || { echo "skip: node not found for the Claude Code Fleet mod checks"; exit 0; }

run_node() {  # <script-file>
  node --input-type=module <"$1"
}

test_plugin_shape() {
  local link resolved autoload out
  link="$ROOT/.agents/skills/firstmate-fleet"
  [ -L "$link" ] || fail "the Fleet mod is not linked into .agents/skills, so Claude Code's project skills-dir scan cannot adopt it"
  resolved=$(cd "$link" && pwd -P) || fail "the .agents/skills/firstmate-fleet link does not resolve"
  [ "$resolved" = "$(cd "$MOD" && pwd -P)" ] || fail "the .agents/skills/firstmate-fleet link resolves to $resolved, not the mod"
  autoload="$ROOT/.claude/skills/firstmate-fleet"
  [ -f "$autoload/.claude-plugin/plugin.json" ] || fail "the project's .claude/skills path does not reach the mod's manifest"
  [ -f "$autoload/hooks/hooks.json" ] || fail "the project's .claude/skills path does not reach the mod's hooks module declaration"
  [ ! -e "$MOD/SKILL.md" ] || fail "the mod carries a SKILL.md and would load as a skill on every harness"
  cat >"$TMP_ROOT/shape.mjs" <<JS
import { readFileSync, readdirSync, existsSync } from "node:fs";
const mod = ${MOD@Q};
const manifest = JSON.parse(readFileSync(\`\${mod}/.claude-plugin/plugin.json\`, "utf8"));
if (manifest.name !== "firstmate-fleet") throw new Error(\`manifest name \${manifest.name}\`);
if (manifest.name.startsWith("claude-")) throw new Error("a claude- prefixed name fails Claude Code's validation");
for (const key of ["commands", "agents", "skills", "hooks", "mcpServers", "lspServers", "outputStyles"]) {
  if (key in manifest) throw new Error(\`manifest declares \${key}, which would load while the flag is off\`);
}
const hooks = JSON.parse(readFileSync(\`\${mod}/hooks/hooks.json\`, "utf8"));
const keys = Object.keys(hooks).sort();
if (JSON.stringify(keys) !== JSON.stringify(["description", "modules"])) {
  throw new Error(\`hooks.json declares \${keys.join(", ")}: a classic hook would run while the flag is off\`);
}
if (JSON.stringify(hooks.modules) !== JSON.stringify(["./register.ts"])) throw new Error("hooks.json names a different module");
if (!existsSync(\`\${mod}/hooks/register.ts\`)) throw new Error("the hooks module is missing");
// claude --plugin-dir writes a tsconfig and type declarations into a mod while it
// hot-reloads; both are gitignored, so a maintainer mid-reload still passes this.
const generated = new Set([".claude-plugin", "tsconfig.json"]);
const entries = readdirSync(mod).filter((name) => !generated.has(name)).sort();
if (JSON.stringify(entries) !== JSON.stringify(["hooks", "lib", "tests"])) {
  throw new Error(\`the mod folder holds \${entries.join(", ")}: only hooks, lib, and tests may exist\`);
}
console.log("shape-ok");
JS
  out=$(run_node "$TMP_ROOT/shape.mjs" 2>&1) || fail "plugin shape: $out"
  assert_contains "$out" "shape-ok" "plugin shape check did not complete"
  pass "the Fleet mod is one hooks module, linked into the project's auto-load path, with no command, skill, agent, or classic hook path that bypasses its activation flag"
}

test_activation_rule() {
  local out
  cat >"$TMP_ROOT/activation.mjs" <<JS
import { pathToFileURL } from "node:url";
const gate = await import(pathToFileURL(${MOD@Q} + "/lib/fm-fleet-activation.ts").href);
const check = (condition, message) => { if (!condition) throw new Error(message); };
check(gate.fleetActivationFromEnv("1") === true, "the exact value 1 does not activate the mod");
for (const value of [undefined, "", "0", "true", "yes", "on", " 1", "1 ", "01", "2"]) {
  check(gate.fleetActivationFromEnv(value) === false, \`\${JSON.stringify(value)} activated the mod\`);
}
// The bin directory belongs to the tracked code root, not to the home FM_HOME selects.
const view = await import(pathToFileURL(${MOD@Q} + "/lib/fm-fleet-view.ts").href);
check(view.fleetCodeRootFromPluginRoot("/repo/.claude/mods/firstmate-fleet") === "/repo", "the physical mod path does not resolve to the code root");
check(view.fleetCodeRootFromPluginRoot("/repo/.claude/skills/firstmate-fleet") === "/repo", "the auto-load path does not resolve to the code root");
check(view.fleetCodeRootFromPluginRoot("/repo/.agents/skills/firstmate-fleet") === "/repo", "the agents-skills path does not resolve to the code root");
check(view.fleetCodeRootFromPluginRoot("/repo/.claude/mods/firstmate-fleet/") === "/repo", "a trailing separator breaks the code root");
check(JSON.stringify(view.fleetSnapshotCommand(undefined, "/repo/.claude/mods/firstmate-fleet")) === JSON.stringify(["/repo/bin/fm-fleet-snapshot.sh", "--json"]), "the reading command is not the code root's own");
check(JSON.stringify(view.fleetSnapshotCommand("", "/repo/.claude/mods/firstmate-fleet")) === JSON.stringify(["/repo/bin/fm-fleet-snapshot.sh", "--json"]), "an empty override is not ignored");
check(JSON.stringify(view.fleetSnapshotCommand("/other", "/repo/.claude/mods/firstmate-fleet")) === JSON.stringify(["/other/bin/fm-fleet-snapshot.sh", "--json"]), "a code-root override is not honored");
console.log("activation-ok");
JS
  out=$(run_node "$TMP_ROOT/activation.mjs" 2>&1) || fail "activation rule: $out"
  assert_contains "$out" "activation-ok" "the activation rule check did not complete"
  pass "the Fleet mod activates on the exact value 1 alone, and on no other value, empty, or unset name, and resolves its reader from the tracked code root rather than from the home FM_HOME selects"
}

# The mod's parser against the real producer, so a schema change is a failing test here
# rather than a silently empty pane in a supervision session.
test_reads_the_real_snapshot() {
  local home out
  home="$TMP_ROOT/home"
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects"
  cat >"$home/data/backlog.md" <<'MD'
# Backlog

## In flight

- [ ] alpha - A ship under way (kind: ship) (since 2026-10-01)
- [ ] scope-call - Decide the scope (kind: ship) (since 2026-10-01) (hold: needs a call on scope) (hold-kind: captain)
- [ ] later-call - Decide this later (kind: ship) (since 2026-10-01) (hold: deferred) (hold-kind: captain) (hold-until: 2099-01-01)

## Queued

## Done
MD
  printf 'id=alpha\nkind=ship\nharness=claude\nmode=no-mistakes\nyolo=off\nbackend=tmux\ntarget=fm-alpha\nworktree=%s\npr=https://github.com/o/r/pull/7\n' "$home" >"$home/state/alpha.meta"
  printf 'working [at=1759700000]: alpha under way\nblocked [at=1759700100] [key=k1]: needs a credential\n' >"$home/state/alpha.status"
  FM_HOME="$home" "$SNAPSHOT" --json >"$TMP_ROOT/real.json" 2>"$TMP_ROOT/real.err" \
    || fail "bin/fm-fleet-snapshot.sh --json failed on a synthetic home: $(cat "$TMP_ROOT/real.err")"
  cat >"$TMP_ROOT/real.mjs" <<JS
import { readFileSync } from "node:fs";
import { pathToFileURL } from "node:url";
const view = await import(pathToFileURL(${MOD@Q} + "/lib/fm-fleet-view.ts").href);
const check = (condition, message) => { if (!condition) throw new Error(message); };
const snapshot = view.parseFleetSnapshot(readFileSync(${TMP_ROOT@Q} + "/real.json", "utf8"));
check(snapshot.rows.length === 1, \`the real reading gave \${snapshot.rows.length} task rows, not 1\`);
const [alpha] = snapshot.rows;
check(alpha.id === "alpha", \`task id \${alpha.id}\`);
check(alpha.kind === "ship", \`task kind \${alpha.kind}\`);
check(alpha.yolo === "off", \`task yolo \${alpha.yolo}\`);
check(alpha.pr === "https://github.com/o/r/pull/7", \`task pr \${alpha.pr}\`);
// The producer publishes an open-decision SET; the mod counts it and never re-derives it.
check(alpha.openDecisions === 1, \`open decisions \${alpha.openDecisions}\`);
// current_state is the only state word; the status log's last line stays an event.
check(typeof alpha.state === "string" && alpha.state !== "", "no state word came through");
check(alpha.lastEvent === "blocked [at=1759700100] [key=k1]: needs a credential", \`last event \${alpha.lastEvent}\`);
check(typeof alpha.ageSeconds === "number", \`event age \${alpha.ageSeconds}\`);
// Only the live captain hold is actionable; the dated one is the producer's own call.
check(snapshot.holds.length === 1, \`the real reading gave \${snapshot.holds.length} live holds, not 1\`);
check(snapshot.holds[0].id === "scope-call", \`live hold \${snapshot.holds[0].id}\`);
check(snapshot.holds[0].reason === "needs a call on scope", \`hold reason \${snapshot.holds[0].reason}\`);
const waiting = view.fleetWaiting(snapshot);
check(waiting.some((entry) => entry.id === "alpha" && entry.reasons.includes("decision")), "the open decision did not reach the waiting set");
check(waiting.some((entry) => entry.id === "scope-call"), "the live captain hold did not reach the waiting set");
check(!waiting.some((entry) => entry.id === "later-call"), "a dated captain hold reached the waiting set");
console.log("real-ok rows=" + snapshot.rows.length + " holds=" + snapshot.holds.length);
JS
  out=$(run_node "$TMP_ROOT/real.mjs" 2>&1) || fail "the mod's parser against the real producer: $out"
  assert_contains "$out" "real-ok rows=1 holds=1" "the real-producer check did not complete"
  pass "the Fleet mod's reader parses bin/fm-fleet-snapshot.sh --json as the producer actually writes it: task state, the last event as an event, the open-decision set, and the producer's own live-versus-dated captain-hold classification"
}

test_reading_policy() {
  local out
  cat >"$TMP_ROOT/policy.mjs" <<JS
import { pathToFileURL } from "node:url";
const view = await import(pathToFileURL(${MOD@Q} + "/lib/fm-fleet-view.ts").href);
const toasts = await import(pathToFileURL(${MOD@Q} + "/lib/fm-fleet-toasts.ts").href);
const check = (condition, message) => { if (!condition) throw new Error(message); };
const row = (over) => ({
  id: "t", kind: "ship", state: "working", source: "pane", lastEvent: "", ageSeconds: 0,
  pendingDecision: false, openDecisions: 0, pr: null, yolo: "off", ...over,
});
const snap = (rows, holds = []) => ({ rows, holds });
const at = (over) => ({ snapshot: undefined, snapshotAtMs: null, nowMs: 1000, error: "", ...over });

// A reading that is not this snapshot refuses rather than answering an empty fleet.
for (const [text, needle] of [["not json", "not JSON"], ["{}", "declared no schema"], ['{"schema":"other"}', "schema other"]]) {
  let message = "";
  try { view.parseFleetSnapshot(text); } catch (error) { message = String(error.message); }
  check(message.includes(needle), \`\${JSON.stringify(text)} gave "\${message}", not "\${needle}"\`);
}

// What waits on the captain, and what does not.
check(JSON.stringify(view.fleetRowWaitReasons(row({}))) === "[]", "ordinary work waits on the captain");
check(view.fleetRowWaitReasons(row({ pendingDecision: true }))[0] === "decision", "a pending decision does not wait");
check(view.fleetRowWaitReasons(row({ openDecisions: 2 }))[0] === "decision", "an open decision does not wait");
check(view.fleetRowWaitReasons(row({ state: "blocked" }))[0] === "blocker", "a blocked task does not wait");
check(view.fleetRowWaitReasons(row({ state: "failed" }))[0] === "blocker", "a failed task does not wait");
check(view.fleetRowWaitReasons(row({ state: "done", pr: "u" }))[0] === "merge", "a finished PR does not ask for a merge");
check(view.fleetRowWaitReasons(row({ state: "done", pr: "u", yolo: "on" })).length === 0, "work firstmate may merge itself still asked");
check(view.fleetRowWaitReasons(row({ state: "done", pr: null })).length === 0, "a finished task with no PR asked for a merge");
check(view.fleetRowWaitReasons(row({ state: "paused" })).length === 0, "a paused task waits on the captain");
check(view.fleetRowWaitReasons(row({ state: "parked" })).length === 0, "a parked task waits on the captain");
// A held task that already has a worker row is one entry, not two.
check(view.fleetWaiting(snap([row({ id: "a", pendingDecision: true })], [{ id: "a", title: "t", reason: "r" }])).length === 1, "one held task counted twice");

// Freshness, and the wording each kind takes.
check(view.fleetFreshness(at({})).kind === "unread", "no reading yet is not unread");
check(view.fleetFreshness(at({ error: "boom" })).kind === "unavailable", "a first failed reading is not unavailable");
check(view.fleetFreshness(at({ snapshot: snap([]), snapshotAtMs: 1000, nowMs: 1000 })).kind === "fresh", "a reading just taken is not fresh");
check(view.fleetFreshness(at({ snapshot: snap([]), snapshotAtMs: 1000, nowMs: 1000, error: "boom" })).kind === "stale", "a failed reading over good rows is not stale");
check(view.fleetFreshness(at({ snapshot: snap([]), snapshotAtMs: 0, nowMs: view.FLEET_STALE_AFTER_MS + 1 })).kind === "stale", "a reading past the stale bound is not stale");
check(view.fleetFreshness(at({ snapshot: snap([]), snapshotAtMs: 0, nowMs: view.FLEET_STALE_AFTER_MS })).kind === "fresh", "a reading at the stale bound is already stale");

// The band: silent only when it can say that nothing waits.
check(view.fleetBand(at({ snapshot: snap([row({})]), snapshotAtMs: 1000, nowMs: 1000 })) === undefined, "the band drew with nothing waiting");
check(view.fleetBand(at({})) === undefined, "the band drew before the first reading landed");
const asking = view.fleetBand(at({ snapshot: snap([row({ id: "a", state: "blocked" })]), snapshotAtMs: 1000, nowMs: 1000 }));
check(asking.tone === "red" && asking.text.includes("1 waiting on you: a (blocker)"), \`band said \${JSON.stringify(asking)}\`);
const unavailable = view.fleetBand(at({ error: "boom" }));
check(unavailable.tone === "yellow" && unavailable.text.includes("fleet unavailable: boom"), \`band said \${JSON.stringify(unavailable)}\`);
const stale = view.fleetBand(at({ snapshot: snap([row({})]), snapshotAtMs: 0, nowMs: 600_000 }));
check(stale.tone === "yellow" && stale.text.includes("old: no fresh reading"), \`band said \${JSON.stringify(stale)}\`);
// A failed reading over a waiting fleet still names the waiting, and says it is stale.
const both = view.fleetBand(at({ snapshot: snap([row({ id: "a", state: "blocked" })]), snapshotAtMs: 1000, nowMs: 1000, error: "boom" }));
check(both.text.includes("a (blocker)") && both.text.includes("boom"), \`band said \${JSON.stringify(both)}\`);

// Ages read as durations, at each boundary.
for (const [seconds, word] of [[null, "?"], [0, "0s"], [89, "89s"], [90, "2m"], [5399, "90m"], [5400, "2h"], [7200, "2h"]]) {
  check(view.fleetAgeWord(seconds) === word, \`\${seconds}s read as \${view.fleetAgeWord(seconds)}, not \${word}\`);
}

// Every row the pane draws is in the text answer, and the text names the freshness.
const full = at({
  snapshot: snap([row({ id: "a", state: "blocked", lastEvent: "blocked [at=1]: why", ageSeconds: 300 })], [{ id: "h", title: "held work", reason: "a call" }]),
  snapshotAtMs: 1000, nowMs: 1000,
});
const lines = view.fleetLines(full);
check(lines.length === 2, \`\${lines.length} drawable rows, not 2\`);
check(lines[1].state === "waiting on you" && lines[1].source === "backlog", "the held row is not drawn as a captain hold");
const report = view.fleetTextReport(full);
for (const line of lines) {
  for (const part of [line.id, line.state, line.source, line.age]) {
    check(report.includes(part), \`the text answer is missing \${JSON.stringify(part)}\`);
  }
}
check(report.startsWith("fleet (2):"), \`the text answer starts \${JSON.stringify(report.slice(0, 20))}\`);
check(report.includes("event: blocked [at=1]: why"), "the text answer does not label the last event as an event");
check(view.fleetTextReport(at({ error: "boom" })) === "fleet: fleet unavailable: boom", "an unavailable reading answered as a fleet");
check(!view.fleetTextReport(at({ error: "boom" })).includes("fleet (0)"), "an unavailable reading answered as an empty fleet");

// Notices: the first reading records, and later readings announce real changes only.
const first = toasts.fleetToasts(undefined, [row({ id: "a", state: "done" }), row({ id: "b", state: "blocked" })]);
check(first.toasts.length === 0, \`the first reading announced \${first.toasts.length} notices\`);
check(first.states.get("a") === "done" && first.states.get("b") === "blocked", "the first reading recorded nothing");
const second = toasts.fleetToasts(first.states, [row({ id: "a", state: "done" }), row({ id: "b", state: "working" })]);
check(second.toasts.length === 0, "an unchanged state or a return to work announced something");
const third = toasts.fleetToasts(second.states, [row({ id: "a", state: "failed" }), row({ id: "b", state: "done", pr: "u" })]);
check(third.toasts.length === 2, \`\${third.toasts.length} notices for two changes\`);
check(third.toasts[0].text === "a: failed", \`notice \${third.toasts[0].text}\`);
check(third.toasts[1].text === "b: done · u", \`notice \${third.toasts[1].text}\`);
const fourth = toasts.fleetToasts(third.states, [row({ id: "a", state: "failed" }), row({ id: "b", state: "done", pr: "u" })]);
check(fourth.toasts.length === 0, "the same states announced twice");
const decided = toasts.fleetToasts(new Map([["a", "working"]]), [row({ id: "a", state: "blocked", pendingDecision: true })]);
check(decided.toasts[0].text === "a: blocked (needs your decision)", \`notice \${decided.toasts[0].text}\`);
console.log("policy-ok");
JS
  out=$(run_node "$TMP_ROOT/policy.mjs" 2>&1) || fail "reading policy: $out"
  assert_contains "$out" "policy-ok" "the reading policy check did not complete"
  pass "the Fleet mod's reading policy holds: a reading that is not this snapshot refuses, only decisions, merge asks and blockers wait on the captain, a failed or aged reading is named rather than drawn as an empty healthy fleet, the text answer carries every row the pane draws, and a notice fires once per real transition"
}

test_plugin_shape
test_activation_rule
test_reads_the_real_snapshot
test_reading_policy
