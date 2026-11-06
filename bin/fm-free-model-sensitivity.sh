#!/usr/bin/env bash
# fm-free-model-sensitivity.sh - public interface for the free OpenCode boundary.
# bin/fm-free-model-sensitivity.py owns the path classes, the free-model mark,
# the token names, the post-classification deny, and the launch confine.
set -euo pipefail
here=$(CDPATH='' cd -- "$(dirname "$0")" && pwd) || exit 1
exec python3 "$here/fm-free-model-sensitivity.py" "$@"
