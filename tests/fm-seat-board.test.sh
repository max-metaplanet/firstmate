#!/usr/bin/env bash
# Behavior tests for bin/fm-seat-board.sh: the read-only local page that shows
# quota-axi's report for every Claude seat.
#
# Most tests here run against `render`, which prints the generated page once
# and exits with no server and no port. The `serve` tests at the end drive a
# real server process on a kernel-chosen port over a loopback socket, because
# the Host check and the per-run path token are properties of that running
# server. There is no network and no real Claude account: a fake quota-axi on
# PATH supplies each case's report, exactly as tests/fm-seat.test.sh does for
# bin/fm-seat.sh itself.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

BOARD="$ROOT/bin/fm-seat-board.sh"
TMP_ROOT=$(fm_test_tmproot fm-seat-board)

# expect_grep <pattern> <text> <msg>: fixed-string grep must match somewhere in <text>.
expect_grep() {
  printf %s "$2" | grep -F -- "$1" >/dev/null || fail "$3"
}

# make_board_quota_fake <fakebin>
# A fake quota-axi whose verdict per profile directory is driven by files the
# test writes into the fakebin's own directory:
#   oauth        newline-separated CLAUDE_CONFIG_DIR values that are logged in
#   email_map    "<CLAUDE_CONFIG_DIR><TAB><email>" rows for a logged-in profile
#   remaining_map "<CLAUDE_CONFIG_DIR><TAB><percent>" rows for the session window
#   extra_map    "<CLAUDE_CONFIG_DIR><TAB><spentUsd>" rows adding an
#                extra_usage window
# A profile named in neither oauth nor a rate_limited list falls through to an
# "unavailable" report, exactly like a seat that was never logged into.
make_board_quota_fake() {
  local fakebin=$1 spec="$1/quota-spec"
  mkdir -p "$spec"
  cat > "$fakebin/quota-axi" <<SH
#!/usr/bin/env bash
set -u
spec="$spec"
key="\${CLAUDE_CONFIG_DIR:-}"
[ -n "\$key" ] || key='(default)'
email=\$(awk -F'\t' -v k="\$key" '\$1==k{print \$2; exit}' "\$spec/email_map" 2>/dev/null)
remaining=\$(awk -F'\t' -v k="\$key" '\$1==k{print \$2; exit}' "\$spec/remaining_map" 2>/dev/null)
[ -n "\$remaining" ] || remaining=80
windows="[{\\"id\\":\\"five_hour\\",\\"label\\":\\"session\\",\\"percentRemaining\\":\$remaining,\\"resetsAt\\":\\"2026-01-02T00:00:00Z\\"}]"
spent=\$(awk -F'\t' -v k="\$key" '\$1==k{print \$2; exit}' "\$spec/extra_map" 2>/dev/null)
if [ -n "\$spent" ]; then
  windows=\$(printf '%s' "\$windows" | sed 's/]\$/,{"id":"extra_usage","kind":"credits","percentUsed":1,"spentUsd":'"\$spent"',"limitUsd":100}]/')
fi
if [ -f "\$spec/rate_limited" ] && grep -Fxq "\$key" "\$spec/rate_limited"; then
  cat <<JSON
{"generatedAt":"2026-01-01T00:00:00Z","schemaVersion":5,"providers":[{"provider":"claude","label":"Claude","source":"unavailable","windows":[],"state":{"status":"rate_limited","error":"Claude quota endpoint rate limited"},"attempts":[],"quotaSemantics":{"status":"unknown","effectiveAvailability":[]}}]}
JSON
  exit 1
fi
if [ -f "\$spec/oauth" ] && grep -Fxq "\$key" "\$spec/oauth"; then
  cat <<JSON
{"generatedAt":"2026-01-01T00:00:00Z","schemaVersion":5,"providers":[{"provider":"claude","label":"Claude","source":"oauth","account":{"email":"\$email"},"windows":\$windows,"quotaSemantics":{"status":"known","effectiveAvailability":[]}}]}
JSON
  exit 0
fi
cat <<JSON
{"generatedAt":"2026-01-01T00:00:00Z","schemaVersion":5,"providers":[{"provider":"claude","label":"Claude","source":"unavailable","windows":[],"state":{"status":"error","error":"credentials_missing"},"attempts":[],"quotaSemantics":{"status":"unknown","effectiveAvailability":[]}}]}
JSON
exit 1
SH
  chmod +x "$fakebin/quota-axi"
  printf '%s\n' "$spec"
}

# make_board_case <name>
# A home with its own seats root, cache dir, and fake quota-axi. Echoes a
# record: case_dir|home|seats|fakebin|spec
make_board_case() {
  local name=$1 case_dir home seats fakebin spec
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  seats="$case_dir/seats"
  mkdir -p "$home/config" "$home/state" "$home/data" "$seats"
  fakebin=$(fm_fakebin "$case_dir")
  spec=$(make_board_quota_fake "$fakebin")
  printf '%s\n' "$seats" > "$home/config/claude-seats-root"
  printf '%s\n' "$case_dir|$home|$seats|$fakebin|$spec"
}

read_board_case() {
  IFS='|' read -r CASE_DIR HOME_DIR SEATS_DIR FAKEBIN SPEC_DIR <<EOF
$1
EOF
}

# run_board <home> <fakebin> <cache-dir> [args...]
# firstmate's own ambient CLAUDE_CONFIG_DIR is pinned empty and every read goes
# through a per-test cache directory so no test shares another's cache. With no
# args the action is `render`, which is what most tests here drive.
run_board() {
  local home=$1 fakebin=$2 cache=$3
  shift 3
  [ $# -gt 0 ] || set -- render
  FM_HOME="$home" FM_CONFIG_OVERRIDE="$home/config" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" CLAUDE_CONFIG_DIR="" \
    FM_SEAT_BOARD_CACHE_DIR="$cache" FM_SEAT_BOARD_CACHE_SECONDS=60 \
    PATH="$fakebin:$PATH" "$BOARD" "$@" 2>&1
}

test_render_shows_the_default_seat_and_marks_it_active() {
  local rec out
  rec=$(make_board_case default-seat)
  read_board_case "$rec"
  printf '(default)\tdefault@example.test\n' > "$SPEC_DIR/email_map"
  printf '(default)\n' > "$SPEC_DIR/oauth"

  out=$(run_board "$HOME_DIR" "$FAKEBIN" "$CASE_DIR/cache")
  expect_grep 'default@example.test' "$out" "the default seat's account email must appear"
  expect_grep 'active for new workers' "$out" "the default seat is active for new workers when no seat is configured"
  expect_grep 'pipeline seat for next managed launch: default' "$out" "the page must name the pipeline selection"
  expect_grep 'no installation receipt' "$out" "an unmanaged installation must never be implied to be verified"
  pass "render shows the default seat and marks it active"
}

test_render_lists_a_named_seat_with_its_windows_and_extra_usage() {
  local rec out
  rec=$(make_board_case named-seat)
  read_board_case "$rec"
  mkdir -p "$SEATS_DIR/alpha"
  printf '%s\talpha@example.test\n' "$SEATS_DIR/alpha" > "$SPEC_DIR/email_map"
  printf '%s\n' "$SEATS_DIR/alpha" > "$SPEC_DIR/oauth"
  printf '%s\t63\n' "$SEATS_DIR/alpha" > "$SPEC_DIR/remaining_map"
  printf '%s\t12.5\n' "$SEATS_DIR/alpha" > "$SPEC_DIR/extra_map"

  out=$(run_board "$HOME_DIR" "$FAKEBIN" "$CASE_DIR/cache")
  expect_grep '<h2>alpha</h2>' "$out" "the named seat's own heading must appear"
  expect_grep 'alpha@example.test' "$out" "the named seat's account email must appear"
  expect_grep '63%' "$out" "the named seat's percent left must appear"
  # shellcheck disable=SC2016 # Literal dollar sign in the expected text.
  expect_grep 'extra usage: $12.5' "$out" "the named seat's extra-usage spend must appear"
  pass "render lists a named seat with its windows and extra-usage spend"
}

test_render_shows_an_attention_line_for_a_seat_that_is_not_logged_in() {
  local rec out
  rec=$(make_board_case not-logged-in)
  read_board_case "$rec"
  mkdir -p "$SEATS_DIR/bravo"

  out=$(run_board "$HOME_DIR" "$FAKEBIN" "$CASE_DIR/cache")
  expect_grep '<h2>bravo</h2>' "$out" "a never-logged-in named seat still gets its own section"
  expect_grep 'class="attention"' "$out" "an unlogged-in seat must show an attention line"
  pass "render shows an attention line for a seat that is not logged in"
}

test_render_shows_a_rate_limited_seats_error_as_is() {
  local rec out
  rec=$(make_board_case rate-limited)
  read_board_case "$rec"
  mkdir -p "$SEATS_DIR/charlie"
  printf '%s\n' "$SEATS_DIR/charlie" > "$SPEC_DIR/rate_limited"

  out=$(run_board "$HOME_DIR" "$FAKEBIN" "$CASE_DIR/cache")
  expect_grep 'Claude quota endpoint rate limited' "$out" \
    "the rate-limit error quota-axi reports must be shown as-is"
  pass "render shows a rate-limited seat's error as-is"
}

test_a_reload_within_the_cache_window_does_not_read_quota_axi_again() {
  local rec out
  rec=$(make_board_case cached-reload)
  read_board_case "$rec"
  printf '(default)\tcached@example.test\n' > "$SPEC_DIR/email_map"
  printf '(default)\n' > "$SPEC_DIR/oauth"

  out=$(run_board "$HOME_DIR" "$FAKEBIN" "$CASE_DIR/cache")
  expect_grep 'cached@example.test' "$out" "the first render must read the seat"

  # A second render within the cache window must reuse the cache file rather
  # than shelling out to quota-axi again: replacing the fake with one that
  # always fails proves no further read was attempted.
  rm -f "$FAKEBIN/quota-axi"
  cat > "$FAKEBIN/quota-axi" <<'SH'
#!/usr/bin/env bash
exit 9
SH
  chmod +x "$FAKEBIN/quota-axi"

  out=$(run_board "$HOME_DIR" "$FAKEBIN" "$CASE_DIR/cache")
  expect_grep 'cached@example.test' "$out" \
    "a reload within the cache window must reuse the cached report, not fail"
  pass "a reload within the cache window does not read quota-axi again"
}

test_render_reads_quota_axi_without_refreshing_or_prompting_for_credentials() {
  local rec out argv_log
  rec=$(make_board_case quota-argv)
  read_board_case "$rec"
  argv_log="$CASE_DIR/quota-argv.log"
  mv "$FAKEBIN/quota-axi" "$FAKEBIN/quota-axi-real"
  cat > "$FAKEBIN/quota-axi" <<SH
#!/usr/bin/env bash
printf '%s\\n' "\$*" >> "$argv_log"
exec "$FAKEBIN/quota-axi-real" "\$@"
SH
  chmod +x "$FAKEBIN/quota-axi"

  out=$(run_board "$HOME_DIR" "$FAKEBIN" "$CASE_DIR/cache")
  [ -s "$argv_log" ] || fail "render must read quota-axi at least once"
  grep -F -- '--no-credential-refresh' "$argv_log" >/dev/null ||
    fail "every quota-axi read must pass --no-credential-refresh"
  if grep -F -- '--allow-keychain-prompt' "$argv_log" >/dev/null; then
    fail "the board must never pass --allow-keychain-prompt to quota-axi"
  fi
  pass "render reads quota-axi without refreshing or prompting for credentials"
}

test_the_cache_is_scoped_to_each_seats_config_dir_not_its_name() {
  local rec_a rec_b home_a fakebin_a home_b fakebin_b out cache
  rec_a=$(make_board_case scope-a)
  read_board_case "$rec_a"
  home_a=$HOME_DIR fakebin_a=$FAKEBIN
  cache="$TMP_ROOT/scope-shared-cache"
  mkdir -p "$SEATS_DIR/delta"
  printf '%s\tfirst@example.test\n' "$SEATS_DIR/delta" > "$SPEC_DIR/email_map"
  printf '%s\n' "$SEATS_DIR/delta" > "$SPEC_DIR/oauth"

  rec_b=$(make_board_case scope-b)
  read_board_case "$rec_b"
  home_b=$HOME_DIR fakebin_b=$FAKEBIN
  mkdir -p "$SEATS_DIR/delta"
  printf '%s\tsecond@example.test\n' "$SEATS_DIR/delta" > "$SPEC_DIR/email_map"
  printf '%s\n' "$SEATS_DIR/delta" > "$SPEC_DIR/oauth"

  out=$(run_board "$home_a" "$fakebin_a" "$cache")
  expect_grep 'first@example.test' "$out" "the first home must show its own seat"
  out=$(run_board "$home_b" "$fakebin_b" "$cache")
  expect_grep 'second@example.test' "$out" \
    "a second home's same-named seat must not reuse the first home's cached report"
  pass "the cache is scoped to each seat's config dir, not its name"
}

test_render_escapes_markup_in_quota_axi_text() {
  local rec out
  rec=$(make_board_case escaping)
  read_board_case "$rec"
  # The email_map value is spliced raw into the fake's JSON, so \" is a JSON
  # escape that quota-axi reports as a literal double quote.
  printf '(default)\tme <b>x</b> & \\"q\n' > "$SPEC_DIR/email_map"
  printf '(default)\n' > "$SPEC_DIR/oauth"

  out=$(run_board "$HOME_DIR" "$FAKEBIN" "$CASE_DIR/cache")
  expect_grep 'me &lt;b&gt;x&lt;/b&gt; &amp; &quot;q' "$out" \
    "markup in quota-axi's text must be HTML-escaped"
  if printf %s "$out" | grep -F -- '<b>x</b>' >/dev/null; then
    fail "raw markup from quota-axi must never reach the page"
  fi
  pass "render escapes markup in quota-axi text"
}

test_serve_rejects_a_missing_or_non_numeric_port() {
  local rc
  "$BOARD" serve --port >/dev/null 2>&1
  rc=$?
  [ "$rc" = 2 ] || fail "serve --port with no value must exit 2 (got $rc)"
  "$BOARD" --port abc >/dev/null 2>&1
  rc=$?
  [ "$rc" = 2 ] || fail "--port with a non-numeric value must exit 2 (got $rc)"
  pass "serve rejects a missing or non-numeric port"
}

# The `json` action: the same reading as the page, for a reader that is not a
# browser. Its one consumer today is the firstmate-quota Claude Code mod, whose
# whole purpose is to date every figure it draws, so what is pinned here is that
# the reading carries each seat's own age and never turns an absent figure into
# a zero.

test_json_reports_every_seat_with_its_own_cache_age() {
  local rec out
  rec=$(make_board_case json-ages)
  read_board_case "$rec"
  mkdir -p "$SEATS_DIR/alpha"
  printf '(default)\tdefault@example.test\n%s\talpha@example.test\n' "$SEATS_DIR/alpha" > "$SPEC_DIR/email_map"
  printf '(default)\n%s\n' "$SEATS_DIR/alpha" > "$SPEC_DIR/oauth"
  printf '%s\t63\n' "$SEATS_DIR/alpha" > "$SPEC_DIR/remaining_map"

  out=$(run_board "$HOME_DIR" "$FAKEBIN" "$CASE_DIR/cache" json)
  printf '%s' "$out" | jq -e '.schemaVersion == 1' >/dev/null ||
    fail "json must print schema 1 (got: $out)"
  printf '%s' "$out" | jq -e '[.seats[].name] == ["default", "alpha"]' >/dev/null ||
    fail "json must list the default login first and then each named seat (got: $out)"
  printf '%s' "$out" | jq -e 'all(.seats[]; .hasData == true and (.ageSeconds | type) == "number")' >/dev/null ||
    fail "json must date every seat it reports figures for (got: $out)"
  printf '%s' "$out" | jq -e 'any(.seats[]; .name == "alpha" and .windows[0].percentRemaining == 63)' >/dev/null ||
    fail "json must carry each seat's percent left (got: $out)"
  printf '%s' "$out" | jq -e '.cacheSeconds == 60' >/dev/null ||
    fail "json must report the cache window its ages are judged against (got: $out)"
  pass "json reports every seat with its own cache age and the window those ages are judged against"
}

test_json_marks_the_active_seat_the_live_seat_and_an_excluded_seat() {
  local rec out
  rec=$(make_board_case json-marks)
  read_board_case "$rec"
  mkdir -p "$SEATS_DIR/alpha" "$SEATS_DIR/bravo"
  printf '%s\n%s\n' "$SEATS_DIR/alpha" "$SEATS_DIR/bravo" > "$SPEC_DIR/oauth"
  printf 'alpha\n' > "$HOME_DIR/config/claude-seat"
  printf 'bravo\n' > "$HOME_DIR/config/claude-seat-auto-exclude"

  out=$(run_board "$HOME_DIR" "$FAKEBIN" "$CASE_DIR/cache" json)
  printf '%s' "$out" | jq -e '.activeSeat == "alpha"' >/dev/null ||
    fail "json must name the seat new workers launch on (got: $out)"
  printf '%s' "$out" | jq -e 'any(.seats[]; .name == "alpha" and .active == true)' >/dev/null ||
    fail "json must mark the active seat's own record (got: $out)"
  printf '%s' "$out" | jq -e 'any(.seats[]; .name == "bravo" and .autoExcluded == true)' >/dev/null ||
    fail "json must mark a seat held out of automatic rotation (got: $out)"
  printf '%s' "$out" | jq -e 'any(.seats[]; .name == "alpha" and .autoExcluded == false)' >/dev/null ||
    fail "json must not mark a seat that is in rotation as excluded (got: $out)"
  # The live seat is resolved from the profile the reader itself received, which
  # run_board pins empty, so it is the default login.
  printf '%s' "$out" | jq -e '.liveSeat == "default"' >/dev/null ||
    fail "json must name the seat of the profile it was run with (got: $out)"
  pass "json marks the active seat, the live seat, and a seat held out of automatic rotation"
}

test_json_reports_a_seat_with_no_report_as_absent_rather_than_zero() {
  local rec out
  rec=$(make_board_case json-missing)
  read_board_case "$rec"
  mkdir -p "$SEATS_DIR/charlie"

  out=$(run_board "$HOME_DIR" "$FAKEBIN" "$CASE_DIR/cache" json)
  printf '%s' "$out" | jq -e 'any(.seats[]; .name == "charlie" and .attention != null)' >/dev/null ||
    fail "a never-logged-in seat must carry an attention line (got: $out)"
  printf '%s' "$out" | jq -e 'any(.seats[]; .name == "charlie" and (.windows | length) == 0)' >/dev/null ||
    fail "a seat with no usable report must carry no window (got: $out)"
  printf '%s' "$out" | jq -e '[.seats[] | select(.windows[]?.percentRemaining == 0)] | length == 0' >/dev/null ||
    fail "an absent figure must never be reported as 0 (got: $out)"
  pass "json reports a seat with no usable report as absent rather than as a zero"
}

test_json_cached_only_never_reads_quota_axi() {
  local rec out
  rec=$(make_board_case json-cached-only)
  read_board_case "$rec"
  mkdir -p "$SEATS_DIR/alpha"
  printf '%s\n' "$SEATS_DIR/alpha" > "$SPEC_DIR/oauth"
  printf '%s\talpha@example.test\n' "$SEATS_DIR/alpha" > "$SPEC_DIR/email_map"

  # Nothing is cached yet, and a cached-only read must not fill it: a reader on a
  # fast cadence must be unable to reach the rate-limited endpoint at all.
  rm -f "$FAKEBIN/quota-axi"
  cat > "$FAKEBIN/quota-axi" <<'SH'
#!/usr/bin/env bash
echo "quota-axi must not be called by a cached-only read" >&2
exit 9
SH
  chmod +x "$FAKEBIN/quota-axi"

  out=$(run_board "$HOME_DIR" "$FAKEBIN" "$CASE_DIR/cache" json --cached-only)
  printf '%s' "$out" | jq -e '.schemaVersion == 1' >/dev/null ||
    fail "a cached-only read must still print a whole reading (got: $out)"
  printf '%s' "$out" | jq -e 'all(.seats[]; .hasData == false and .ageSeconds == null)' >/dev/null ||
    fail "a cached-only read of an empty cache must report no data for every seat (got: $out)"
  case "$out" in
    *"must not be called"*) fail "a cached-only read reached quota-axi (got: $out)" ;;
  esac
  pass "json --cached-only reports an empty cache as no data and never reads quota-axi"
}

test_json_cached_only_serves_an_expired_cache_with_its_real_age() {
  local rec out age
  rec=$(make_board_case json-expired)
  read_board_case "$rec"
  printf '(default)\tcached@example.test\n' > "$SPEC_DIR/email_map"
  printf '(default)\n' > "$SPEC_DIR/oauth"

  # Fill the cache, then age the file well past the cache window and make every
  # further quota read fail. A cached-only read must still answer, and must say
  # how old the answer is rather than presenting it as current.
  run_board "$HOME_DIR" "$FAKEBIN" "$CASE_DIR/cache" json >/dev/null
  touch -t 202001010000 "$CASE_DIR/cache/default.json"
  rm -f "$FAKEBIN/quota-axi"
  cat > "$FAKEBIN/quota-axi" <<'SH'
#!/usr/bin/env bash
exit 9
SH
  chmod +x "$FAKEBIN/quota-axi"

  out=$(run_board "$HOME_DIR" "$FAKEBIN" "$CASE_DIR/cache" json --cached-only)
  printf '%s' "$out" | jq -e 'any(.seats[]; .account == "cached@example.test" and .hasData == true)' >/dev/null ||
    fail "a cached-only read must still serve an expired cached report (got: $out)"
  age=$(printf '%s' "$out" | jq -r '[.seats[] | select(.account == "cached@example.test") | .ageSeconds] | first')
  [ "$age" -gt 60 ] ||
    fail "an expired cached report must carry an age past the cache window, got $age"
  pass "json --cached-only serves an expired cached report with its real age, so a reader can call it stale"
}

# --- real server cases ------------------------------------------------------
#
# A board started here keeps running until the test kills it, so every pid is
# tracked and swept on the way out, including on a mid-file failure.

BOARD_SERVER_PIDS=
BOARD_PID=
BOARD_PORT=
BOARD_ROUTE=

board_servers_cleanup() {
  local pid
  for pid in $BOARD_SERVER_PIDS; do
    kill "$pid" 2>/dev/null || true
  done
  fm_test_cleanup
}
trap board_servers_cleanup EXIT
trap 'board_servers_cleanup; exit 130' INT
trap 'board_servers_cleanup; exit 143' TERM

# board_http <port> <path> <host>
# One raw HTTP/1.0 GET against the running board, printed whole: status line,
# headers and body. A test can then assert the refusal code AND that no page
# content was sent with it.
board_http() {
  python3 - "$1" "$2" "$3" <<'PYREQ'
import socket
import sys

port, path, host = int(sys.argv[1]), sys.argv[2], sys.argv[3]
request = "GET %s HTTP/1.0\r\nHost: %s\r\nConnection: close\r\n\r\n" % (path, host)
sock = socket.create_connection(("127.0.0.1", port), 10)
sock.sendall(request.encode("ascii"))
blocks = []
while True:
    block = sock.recv(65536)
    if not block:
        break
    blocks.append(block)
sock.close()
sys.stdout.write(b"".join(blocks).decode("utf-8", "replace"))
PYREQ
}

# board_port_closed <port>: succeeds once nothing accepts a connection there.
board_port_closed() {
  python3 - "$1" <<'PYPORT'
import socket
import sys

try:
    socket.create_connection(("127.0.0.1", int(sys.argv[1])), 2).close()
except OSError:
    sys.exit(0)
sys.exit(1)
PYPORT
}

# start_board <home> <fakebin> <cache-dir> <log>
# Starts a real `serve` on a kernel-chosen port and sets BOARD_PID, BOARD_PORT
# and BOARD_ROUTE by reading back the URL that server printed. Nothing here
# assumes the port or the token: the test drives exactly what an operator would
# open.
start_board() {
  local home=$1 fakebin=$2 cache=$3 log=$4 url='' waited=0
  FM_HOME="$home" FM_CONFIG_OVERRIDE="$home/config" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" CLAUDE_CONFIG_DIR="" \
    FM_SEAT_BOARD_CACHE_DIR="$cache" FM_SEAT_BOARD_CACHE_SECONDS=60 \
    PATH="$fakebin:$PATH" "$BOARD" serve --port 0 > "$log" 2>&1 &
  BOARD_PID=$!
  BOARD_SERVER_PIDS="$BOARD_SERVER_PIDS $BOARD_PID"
  while [ "$waited" -lt 200 ]; do
    url=$(sed -n 's|^Seat board: \(http://127\.0\.0\.1:[0-9]*/[^ /]*/\)$|\1|p' "$log" | head -1)
    [ -z "$url" ] || break
    waited=$((waited + 1))
    sleep 0.05
  done
  [ -n "$url" ] || fail "serve printed no board URL within 10s (log: $(cat "$log" 2>/dev/null))"
  BOARD_PORT=${url#http://127.0.0.1:}
  BOARD_PORT=${BOARD_PORT%%/*}
  BOARD_ROUTE=${url#"http://127.0.0.1:$BOARD_PORT"}
}

test_serve_answers_a_loopback_host_and_refuses_a_rebinding_one() {
  local rec out
  rec=$(make_board_case serve-host-check)
  read_board_case "$rec"
  printf '(default)\thost-check@example.test\n' > "$SPEC_DIR/email_map"
  printf '(default)\n' > "$SPEC_DIR/oauth"

  start_board "$HOME_DIR" "$FAKEBIN" "$CASE_DIR/cache" "$CASE_DIR/serve.log"

  out=$(board_http "$BOARD_PORT" "$BOARD_ROUTE" "127.0.0.1:$BOARD_PORT")
  expect_grep '200 OK' "$out" "a Host of 127.0.0.1 with the board's own port must be served"
  expect_grep 'host-check@example.test' "$out" "the served page must be the board itself"

  out=$(board_http "$BOARD_PORT" "$BOARD_ROUTE" "localhost:$BOARD_PORT")
  expect_grep '200 OK' "$out" "a Host of localhost with the board's own port must be served"

  # The rebinding shape: the browser connects to loopback, but what reaches the
  # server as Host is the hostile page's own re-pointed domain.
  out=$(board_http "$BOARD_PORT" "$BOARD_ROUTE" "rebound.example:$BOARD_PORT")
  expect_grep '403 Forbidden' "$out" "a request carrying a foreign Host must be refused"
  case "$out" in
    *host-check@example.test*)
      fail "a refused request was still answered with board content: $out"
      ;;
  esac

  kill "$BOARD_PID" 2>/dev/null || true
  pass "serve answers a loopback Host and refuses a rebinding page's foreign Host"
}

test_serve_serves_the_board_only_under_the_path_token_it_printed() {
  local rec out
  rec=$(make_board_case serve-path-token)
  read_board_case "$rec"
  printf '(default)\ttoken@example.test\n' > "$SPEC_DIR/email_map"
  printf '(default)\n' > "$SPEC_DIR/oauth"

  start_board "$HOME_DIR" "$FAKEBIN" "$CASE_DIR/cache" "$CASE_DIR/serve.log"

  out=$(board_http "$BOARD_PORT" / "127.0.0.1:$BOARD_PORT")
  expect_grep '404 Not Found' "$out" "the server root must not serve the board"
  case "$out" in
    *token@example.test*)
      fail "a request without the printed path token was answered with board content: $out"
      ;;
  esac

  out=$(board_http "$BOARD_PORT" /index.html "127.0.0.1:$BOARD_PORT")
  expect_grep '404 Not Found' "$out" "the page's own filename must not be a second way in"

  out=$(board_http "$BOARD_PORT" "$BOARD_ROUTE" "127.0.0.1:$BOARD_PORT")
  expect_grep 'token@example.test' "$out" "the printed URL's path must serve the board"

  kill "$BOARD_PID" 2>/dev/null || true
  pass "serve serves the board only under the per-run path token it printed"
}

test_stopping_serve_leaves_nothing_listening_on_its_port() {
  local rec waited=0
  rec=$(make_board_case serve-stop)
  read_board_case "$rec"
  printf '(default)\tstop@example.test\n' > "$SPEC_DIR/email_map"
  printf '(default)\n' > "$SPEC_DIR/oauth"

  start_board "$HOME_DIR" "$FAKEBIN" "$CASE_DIR/cache" "$CASE_DIR/serve.log"
  ! board_port_closed "$BOARD_PORT" || fail "the board was not listening after start"

  kill "$BOARD_PID" 2>/dev/null || true
  while [ "$waited" -lt 200 ]; do
    board_port_closed "$BOARD_PORT" && break
    waited=$((waited + 1))
    sleep 0.05
  done
  board_port_closed "$BOARD_PORT" ||
    fail "stopping serve left a server still listening on port $BOARD_PORT"
  pass "stopping serve leaves nothing listening on its port"
}

# rest_seat_on_board <home> <seat> <limiting-window> <remaining> <expected-back>
# The resting record the seat watch writes, as this home's config. The board
# never writes it; it only reports it, so a case states it the way the watch
# would have left it.
rest_seat_on_board() {
  local home=$1 name=$2 window=$3 remaining=$4 expected=$5
  jq -n --arg n "$name" --arg w "$window" --argjson r "$remaining" --arg e "$expected" '
    { schemaVersion: 1, updatedAt: 1791417600,
      seats: { ($n): { since: 1791410000, account: "someone@example.test",
                       limitingWindow: $w, provisional: false, expectedBack: $e,
                       lastRead: 1791417600, unreadableSince: null,
                       windows: { ($w): { remaining: $r, resetsAt: $e,
                                          windowSeconds: 604800 } } } } }' \
    > "$home/config/claude-seat-resting"
}

test_json_tells_a_hand_held_seat_from_a_resting_one_and_reports_the_floor() {
  local rec out
  rec=$(make_board_case json-resting)
  read_board_case "$rec"
  mkdir -p "$SEATS_DIR/alpha" "$SEATS_DIR/bravo" "$SEATS_DIR/charlie"
  printf '%s\n%s\n%s\n' "$SEATS_DIR/alpha" "$SEATS_DIR/bravo" "$SEATS_DIR/charlie" > "$SPEC_DIR/oauth"
  printf 'alpha\n' > "$HOME_DIR/config/claude-seat"
  printf 'bravo\n' > "$HOME_DIR/config/claude-seat-auto-exclude"
  printf '5\n' > "$HOME_DIR/config/claude-seat-floor"
  rest_seat_on_board "$HOME_DIR" charlie seven_day 2 2026-10-09T11:00:00Z

  out=$(run_board "$HOME_DIR" "$FAKEBIN" "$CASE_DIR/cache" json)
  printf '%s' "$out" | jq -e 'any(.seats[]; .name == "charlie" and .autoExcluded == true)' >/dev/null ||
    fail "a resting seat must read as one an automatic switch may not land on (got: $out)"
  printf '%s' "$out" | jq -e 'any(.seats[]; .name == "charlie"
      and .exclusion.manual == false and .exclusion.resting.limitingWindow == "seven_day"
      and .exclusion.resting.remaining == 2
      and .exclusion.resting.expectedBack == "2026-10-09T11:00:00Z"
      and .exclusion.resting.provisional == false)' >/dev/null ||
    fail "the resting detail must say which window holds the seat down and when it is back (got: $out)"
  printf '%s' "$out" | jq -e 'any(.seats[]; .name == "bravo"
      and .exclusion.manual == true and .exclusion.resting == null)' >/dev/null ||
    fail "a seat held out by hand must never read as one the floor rested (got: $out)"
  printf '%s' "$out" | jq -e 'any(.seats[]; .name == "alpha"
      and .autoExcluded == false and .exclusion.manual == false and .exclusion.resting == null)' >/dev/null ||
    fail "a seat in rotation must be marked as neither (got: $out)"
  printf '%s' "$out" | jq -e '.floor.removeAt == 5 and .floor.readdAt == 15
      and .floor.dwellSeconds == 600 and .floor.sessionShare.source == "assumed"' >/dev/null ||
    fail "json must report the floor's own settings and the session share in force (got: $out)"
  pass "json tells a seat held out by hand from one the quota floor rested, and reports the floor itself"
}

test_json_reports_no_floor_when_none_is_configured() {
  local rec out
  rec=$(make_board_case json-no-floor)
  read_board_case "$rec"
  mkdir -p "$SEATS_DIR/alpha"
  printf '%s\n' "$SEATS_DIR/alpha" > "$SPEC_DIR/oauth"

  out=$(run_board "$HOME_DIR" "$FAKEBIN" "$CASE_DIR/cache" json)
  printf '%s' "$out" | jq -e '.floor == null' >/dev/null ||
    fail "an unconfigured floor must read as null rather than as a set of zeros (got: $out)"
  printf '%s' "$out" | jq -e 'all(.seats[]; .exclusion.resting == null)' >/dev/null ||
    fail "no seat may read as resting while no floor is configured (got: $out)"
  pass "json reports no floor at all when none is configured"
}

test_render_shows_a_resting_seat_its_reason_and_the_floor_settings() {
  local rec out
  rec=$(make_board_case render-resting)
  read_board_case "$rec"
  mkdir -p "$SEATS_DIR/alpha" "$SEATS_DIR/bravo"
  printf '%s\n%s\n' "$SEATS_DIR/alpha" "$SEATS_DIR/bravo" > "$SPEC_DIR/oauth"
  printf 'alpha\n' > "$HOME_DIR/config/claude-seat"
  printf '5\n' > "$HOME_DIR/config/claude-seat-floor"
  rest_seat_on_board "$HOME_DIR" bravo seven_day 2 2026-10-09T11:00:00Z

  out=$(run_board "$HOME_DIR" "$FAKEBIN" "$CASE_DIR/cache")
  expect_grep 'resting: seven_day 2% left' "$out" "the page must say which window is holding the seat down"
  expect_grep 'expected back 2026-10-09T11:00:00Z' "$out" "the page must say when the seat is due back"
  expect_grep 'in rotation' "$out" "a seat an automatic switch may land on must say so"
  expect_grep 'quota floor: rest at or below 5% left' "$out" "the page must print the floor in force"
  expect_grep 'of a week, assumed' "$out" "the page must say whether the session share was measured"
  pass "render shows a resting seat with its reason and the floor settings it was judged against"
}

test_a_seat_back_provisionally_reads_as_in_rotation_with_its_marker() {
  local rec out record
  rec=$(make_board_case provisional)
  read_board_case "$rec"
  mkdir -p "$SEATS_DIR/alpha" "$SEATS_DIR/bravo"
  printf '%s\n%s\n' "$SEATS_DIR/alpha" "$SEATS_DIR/bravo" > "$SPEC_DIR/oauth"
  printf 'alpha\n' > "$HOME_DIR/config/claude-seat"
  printf '5\n' > "$HOME_DIR/config/claude-seat-floor"
  rest_seat_on_board "$HOME_DIR" bravo seven_day 2 2026-10-09T11:00:00Z
  record="$HOME_DIR/config/claude-seat-resting"
  jq '.seats.bravo.provisional = true' "$record" > "$record.tmp" && mv "$record.tmp" "$record"

  out=$(run_board "$HOME_DIR" "$FAKEBIN" "$CASE_DIR/cache" json)
  printf '%s' "$out" | jq -e 'any(.seats[]; .name == "bravo" and .autoExcluded == false
      and .exclusion.resting.provisional == true)' >/dev/null ||
    fail "a provisional seat must read as one a switch may land on, with its marker (got: $out)"
  out=$(run_board "$HOME_DIR" "$FAKEBIN" "$CASE_DIR/cache")
  expect_grep 'in rotation provisionally' "$out" "the page must show the seat as provisionally back"
  printf '%s' "$out" | grep -q 'class="rotation resting"' &&
    fail "a provisional seat must not be styled as resting"
  pass "a seat back provisionally reads as in rotation, with the provisional marker"
}

test_json_rejects_an_unknown_flag() {
  local rc
  "$BOARD" json --fresh >/dev/null 2>&1
  rc=$?
  [ "$rc" = 2 ] || fail "json with an unknown flag must exit 2 (got $rc)"
  pass "json rejects an unknown flag"
}

test_render_shows_the_default_seat_and_marks_it_active
test_render_lists_a_named_seat_with_its_windows_and_extra_usage
test_render_shows_an_attention_line_for_a_seat_that_is_not_logged_in
test_render_shows_a_rate_limited_seats_error_as_is
test_a_reload_within_the_cache_window_does_not_read_quota_axi_again
test_render_reads_quota_axi_without_refreshing_or_prompting_for_credentials
test_the_cache_is_scoped_to_each_seats_config_dir_not_its_name
test_render_escapes_markup_in_quota_axi_text
test_serve_rejects_a_missing_or_non_numeric_port
test_json_reports_every_seat_with_its_own_cache_age
test_json_marks_the_active_seat_the_live_seat_and_an_excluded_seat
test_json_reports_a_seat_with_no_report_as_absent_rather_than_zero
test_json_cached_only_never_reads_quota_axi
test_json_cached_only_serves_an_expired_cache_with_its_real_age
test_json_rejects_an_unknown_flag
test_json_tells_a_hand_held_seat_from_a_resting_one_and_reports_the_floor
test_json_reports_no_floor_when_none_is_configured
test_render_shows_a_resting_seat_its_reason_and_the_floor_settings
test_a_seat_back_provisionally_reads_as_in_rotation_with_its_marker
test_serve_answers_a_loopback_host_and_refuses_a_rebinding_one
test_serve_serves_the_board_only_under_the_path_token_it_printed
test_stopping_serve_leaves_nothing_listening_on_its_port

echo "# all fm-seat-board tests passed"
