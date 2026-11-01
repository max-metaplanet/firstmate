#!/usr/bin/env bash
set -euo pipefail
source bin/fm-dod-lib.sh
export FM_HOME="$PWD/.boat-live-test/home"
export CONFIG="$FM_HOME/config"
EVIDENCE=~/.no-mistakes/evidence/01M69MH831RGQM6KVY4NK4309X
printf '%s\n' 'sample timeout=1200 history-depth=50' > "$CONFIG/boat-prepush"
for mode in no-mistakes direct-PR; do
  fm_dod_block "$mode" boat-test fm/boat-test none '' '' '' '' sample > "$EVIDENCE/dod-$mode.txt"
  fm_dod_block "$mode" boat-test fm/boat-test none '' '' '' '' unrelated > ".boat-live-test/undeclared-$mode"
  fm_dod_block "$mode" boat-test fm/boat-test none '' '' '' '' '' > ".boat-live-test/no-project-$mode"
  cmp ".boat-live-test/undeclared-$mode" ".boat-live-test/no-project-$mode"
done
printf '%s\n' 'sample timeout=0' > "$CONFIG/boat-prepush"
if fm_dod_block direct-PR boat-test fm/boat-test none '' '' '' '' sample > .boat-live-test/invalid.out 2> "$EVIDENCE/dod-invalid-config.txt"; then
  exit 1
fi
printf '%s\n' 'Rendered both publishing procedures; undeclared projects unchanged; invalid declaration refused.'
