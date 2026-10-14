#!/usr/bin/env bash
# Changed-file selection probe: in a throwaway repo built from <ref>, append a
# line to <needle>, commit, and list what `fm-test-run.sh --changed` selects.
set -u
ref=$1 needle=$2 src=$3
d=$(mktemp -d "${TMPDIR:-/tmp}/fm-sel.XXXXXX")
git -C "$src" archive "$ref" | tar -x -C "$d"
cd "$d" || exit 1
git init -q && git add -A
git -c user.email=t@t -c user.name=t commit -qm base
echo '# probe' >> "$needle"
git -c user.email=t@t -c user.name=t commit -qam probe
env -u NO_MISTAKES_GATE bash bin/fm-test-run.sh --list --changed --base HEAD~1 2>&1 | sort
cd / && rm -rf -- "$d"
