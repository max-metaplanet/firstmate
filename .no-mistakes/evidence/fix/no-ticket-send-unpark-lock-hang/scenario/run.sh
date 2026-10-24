#!/usr/bin/env bash
# run.sh <source-root>: build the driver from that root's fixture helpers and run it.
set -u
SRC=$1; EV=$(cd "$(dirname "$0")" && pwd)
T=$(mktemp -d "${TMPDIR:-/tmp}/fm-incident.XXXXXX")
last=$(grep -n '^test_park_stopped_with_durable_proof$' "$SRC/tests/fm-secondmate-restart.test.sh" | head -1 | cut -d: -f1)
head -n $((last - 1)) "$SRC/tests/fm-secondmate-restart.test.sh" \
  | grep -v '^test_park_send_defers_under_caller_lock_and_capacity$' \
  | sed "s#^\. \"\$(dirname \"\${BASH_SOURCE\[0\]}\")/lib.sh\"#. \"$SRC/tests/lib.sh\"#" > "$T/driver.sh"
cat "$EV/lease-lock-scenario.sh" >> "$T/driver.sh"
bash "$T/driver.sh"; rc=$?
rm -rf "$T"; exit $rc
