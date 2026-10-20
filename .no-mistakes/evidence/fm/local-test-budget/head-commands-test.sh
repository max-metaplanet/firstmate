bash <<'NM_TEST'
set -euf
scope=$(FM_CI_EVENT=pull_request FM_CI_BASE_SHA=origin/main bash bin/fm-ci-change-scope.sh --local)
printf '%s\n' "$scope"
selected=$(printf '%s\n' "$scope" | sed -n 's/^local_scripts=//p')
budget=$(printf '%s\n' "$scope" | sed -n 's/^local_budget_ms=//p')
deferred=$(printf '%s\n' "$scope" | sed -n 's/^local_deferred=//p')
if [ -n "$deferred" ]; then
  printf "Left to CI's required lanes (CI gate): %s\n" "$deferred"
fi
[ -n "$selected" ] || { printf '%s\n' 'selector returned no tests' >&2; exit 1; }
case "$budget" in ''|*[!0-9]*) printf '%s\n' 'selector returned invalid budget' >&2; exit 1 ;; esac
[ "$budget" -ge 1000 ] || exit 1
# The selector emits repository-owned test paths without whitespace.
# Globbing is disabled above; split only its space/newline-delimited path list.
# shellcheck disable=SC2086
set -- $selected
. bin/fm-timeout-lib.sh
# CI duration hints bound coverage; allow loaded local execution more time.
fm_exec_timed "$((budget * 3 / 1000))" 5 bash bin/fm-test-run.sh --per-script-timeout-secs 1500 "$@"
NM_TEST
