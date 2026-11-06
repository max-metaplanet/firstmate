#!/usr/bin/env bash
# fm-free-model-sensitivity.sh - public interface for the free OpenCode boundary.
# bin/fm-free-model-sensitivity.py owns the path classes, the free-model mark,
# the token names, the post-classification deny, the launch confine, and the
# mech handoff that returns a diff.
set -euo pipefail
here=$(CDPATH='' cd -- "$(dirname "$0")" && pwd) || exit 1
exec python3 "$here/fm-free-model-sensitivity.py" "$@"
