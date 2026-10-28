#!/usr/bin/env bash
# Stateful Treehouse stand-in: exercise persistent lease/return semantics only
# inside a test pool. The real CLI and shared pools are never mutated.
fm_test_treehouse_durable_lease() {  # <fakebin> <pool>
  cat > "$1/treehouse" <<'SH'
#!/usr/bin/env bash
set -eu
pool=${FM_TEST_LEASE_POOL:?}
if [ "${1:-}" = --root ]; then
  [ "$2" = "$(dirname "$(dirname "$pool")")" ] || exit 9
  shift 2
fi
case "${1:-}" in
  status)
    if [ "${FM_TEST_LEASE_WRONG_POOL:-0}" = 1 ]; then printf '[]\n'
    else jq '.worktrees' "$pool/treehouse-state.json"; fi
    ;;
  lease)
    [ "${FM_TEST_LEASE_FAIL:-0}" != 1 ] || exit 8
    name=$2
    [ "$3" = --lease-holder ] || exit 9
    jq --arg name "$name" --arg holder "$4" '
      (.worktrees[] | select(.name == $name)) |=
        (.leased = true | .lease_holder = $holder)
    ' "$pool/treehouse-state.json" > "$pool/state.new"
    mv "$pool/state.new" "$pool/treehouse-state.json"
    printf '%s\n' "$name" >> "$pool/lease-calls"
    ;;
  return)
    [ "$2" = --force ] || exit 9
    jq --arg path "$3" '(.worktrees[] | select(.path == $path)) |=
      (del(.leased, .lease_holder))' "$pool/treehouse-state.json" > "$pool/state.new"
    mv "$pool/state.new" "$pool/treehouse-state.json"
    ;;
esac
SH
  chmod +x "$1/treehouse"
  export FM_TEST_LEASE_POOL=$2
}
