#!/usr/bin/env bash
# The Claude Code Quota mod (.claude/mods/firstmate-quota) under the real installed
# Claude Code: `claude plugin validate --strict` on the physical folder and on the
# `.claude/skills/firstmate-quota` path the project auto-loads it from, then its own
# `claude plugin test` suites (tests/*.test.ts inside the mod), which run the hooks
# module in the engine's own host against a mocked clock, environment, process host, and
# drawing surface. No model turn is submitted and no credential is spent, so the guard
# runs by default wherever `claude` is installed; the portable checks that need no Claude
# Code binary live in tests/fm-quota-claude-mod.test.sh.
#
# The engine's own scan is the point of the first half: this mod draws the captain's
# remaining quota, so what it is allowed to touch matters as much as what it draws. The
# scan is asserted to carry exactly the hooks and calls the mod needs, and to carry none
# of the capabilities it must never use. A mod that quietly grew a network call or an
# environment write would pass its own suites and fail here.
#
# Neither the mod's own FM_QUOTA_ENABLED gate nor any other flag is exported here:
# validation only scans the module, and each plugin test suite mocks its own
# environment, so this guard sets nothing and never writes a name into a settings file.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate default-on FM_CLAUDE_QUOTA_PLUGIN_TEST claude

MOD="$ROOT/.claude/mods/firstmate-quota"
AUTOLOAD_PATH="$ROOT/.claude/skills/firstmate-quota"
CLAUDE_VERSION=$(claude --version 2>/dev/null || true)
[ -n "$CLAUDE_VERSION" ] || fail "claude is installed but reports no version"
TMP_ROOT=$(fm_test_tmproot fm-quota-claude-mod-plugin)

expect_in_report() {
  local report=$1 needle=$2 what=$3
  case "$report" in
    *"$needle"*) : ;;
    *)
      printf '%s\n' "$report" >&2
      fail "Claude Code $CLAUDE_VERSION: $what (missing '$needle')"
      ;;
  esac
}

test_validate_strict() {
  local path report
  for path in "$MOD" "$AUTOLOAD_PATH"; do
    if ! report=$(claude plugin validate --strict "$path" 2>&1); then
      printf '%s\n' "$report" >&2
      fail "Claude Code $CLAUDE_VERSION refused the Quota mod at $path under strict validation"
    fi
    # The scan is the engine's own reading of the module: the events it will hook, the
    # calls it may make, and the environment names it may read.
    expect_in_report "$report" "session.measure" "the scan of $path does not hook the engine's own account measurement"
    expect_in_report "$report" "command.run{command=seats}" "the scan of $path does not serve /seats"
    expect_in_report "$report" "ui.render{component=Pane}" "the scan of $path does not draw the seats pane"
    expect_in_report "$report" "ui.render{component=AbovePrompt}" "the scan of $path does not draw the band"
    expect_in_report "$report" "env reads: FM_QUOTA_ENABLED, FM_QUOTA_REFRESH_SECONDS" "the scan of $path reads a different environment"
    expect_in_report "$report" "env writes: nothing" "the scan of $path writes the environment"
    # The mod reads the seats through one read-only repository script and nothing else.
    expect_in_report "$report" '$.process.run' "the scan of $path does not run the seat reader"
    case "$report" in
      *"http.fetch"*|*"env.set"*|*"fs.write"*|*"model.complete"*|*"prompt.submit"*|*"session.send"*|*"tool.call"*)
        printf '%s\n' "$report" >&2
        fail "Claude Code $CLAUDE_VERSION scanned a capability the Quota mod must not use at $path"
        ;;
    esac
  done
  pass "Claude Code $CLAUDE_VERSION validates the Quota mod strictly at its folder and its auto-load path, hooking exactly the account measurement, the band, the seats pane, and /seats"
}

test_plugin_suites() {
  local report
  if ! report=$(cd "$TMP_ROOT" && claude plugin test "$MOD" 2>&1); then
    printf '%s\n' "$report" >&2
    fail "Claude Code $CLAUDE_VERSION failed the Quota mod's plugin test suites"
  fi
  printf '%s\n' "$report" | grep -Eq '^ *[1-9][0-9]* pass$' || {
    printf '%s\n' "$report" >&2
    fail "Claude Code $CLAUDE_VERSION ran no Quota mod plugin test"
  }
  printf '%s\n' "$report" | grep -Eq '^ *0 fail$' || {
    printf '%s\n' "$report" >&2
    fail "Claude Code $CLAUDE_VERSION reported Quota mod plugin test failures"
  }
  pass "Claude Code $CLAUDE_VERSION runs the Quota mod's plugin test suites clean: the activation gate, the live band, the dated seats pane, its text fallback, and the refresh cadence"
}

test_seat_reader_answers_the_mod() {
  local reading seats
  # The mod's one process call, run for real against this repository's own reader in
  # its cached-only form, which makes no quota-axi call at all. The engine-mocked suites
  # pin how the mod reads this shape; this pins that the shape is what the reader prints.
  command -v jq >/dev/null 2>&1 || { echo "skip: jq not found for the seat reader shape check"; return 0; }
  # One cached report for the default seat, so the dating assertion below has a seat
  # with figures to date rather than passing over a cache that holds nothing. The cache
  # key is the resolved config directory, which an empty CLAUDE_CONFIG_DIR makes
  # `default`; nothing here reaches quota-axi, and the real cache is left alone.
  mkdir -p "$TMP_ROOT/cache"
  cat > "$TMP_ROOT/cache/default.json" <<'JSON'
{"generatedAt":"2026-10-06T00:00:00Z","schemaVersion":5,"providers":[{"provider":"claude","label":"Claude","source":"oauth","account":{"email":"guard@example.test"},"windows":[{"id":"five_hour","label":"session","percentRemaining":64,"resetsAt":"2026-10-06T02:00:00Z"}]}]}
JSON
  reading=$(FM_SEAT_BOARD_CACHE_DIR="$TMP_ROOT/cache" CLAUDE_CONFIG_DIR="" "$ROOT/bin/fm-seat-board.sh" json --cached-only 2>&1) ||
    fail "the seat reader the Quota mod calls failed: $reading"
  printf '%s' "$reading" | jq -e '[.seats[] | select(.hasData == true)] | length >= 1' >/dev/null ||
    fail "the seat reader did not report the seeded cached report at all: $reading"
  printf '%s' "$reading" | jq -e 'any(.seats[]; .account == "guard@example.test" and .windows[0].percentRemaining == 64)' >/dev/null ||
    fail "the seat reader did not carry the cached report's own figures: $reading"
  printf '%s' "$reading" | jq -e '.schemaVersion == 1' >/dev/null ||
    fail "the seat reader prints a schema the Quota mod does not understand: $reading"
  printf '%s' "$reading" | jq -e 'has("cacheSeconds") and has("activeSeat") and has("liveSeat") and (.seats | type == "array")' >/dev/null ||
    fail "the seat reader omits a field the Quota mod reads: $reading"
  seats=$(printf '%s' "$reading" | jq '.seats | length')
  [ "$seats" -ge 1 ] || fail "the seat reader printed no seat at all, so the pane would have nothing to draw"
  # Every seat must be datable or honestly undated; a figure with no age is what the mod
  # exists to prevent.
  printf '%s' "$reading" | jq -e '[.seats[] | select(.hasData == true and .ageSeconds == null)] | length == 0' >/dev/null ||
    fail "the seat reader reported figures it could not date, which the pane would draw without an age: $reading"
  pass "the seat reader prints schema 1 with every seat dated, and its cached-only form makes no quota call"
}

test_validate_strict
test_plugin_suites
test_seat_reader_answers_the_mod
