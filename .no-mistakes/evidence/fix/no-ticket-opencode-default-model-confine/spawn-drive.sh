#!/usr/bin/env bash
# Real bin/fm-spawn.sh: model-less opencode ship spawn into a real git worktree,
# fake tmux/opencode backend (records the launch command), XDG_CONFIG_HOME = a
# disposable opencode config per variant. Usage: spawn-drive.sh <repo-worktree>
cd "$1" || exit 1
REPO=$PWD
# Reuse the suite's harness helpers (header only, no test bodies run).
source <(sed -n '1,163p' tests/fm-spawn-dispatch-profile.test.sh | sed "s|\$(dirname \"\${BASH_SOURCE\[0\]}\")|$REPO/tests|")
for variant in paid-string paid-object free unresolved agent-override; do
  id=oc-default-$variant-z9
  rec=$(make_spawn_case "oc-default-$variant" opencode "$id"); read_case_record "$rec"
  printf '\nTarget paths: src/app.ts\n' >> "$HOME_DIR/data/$id/brief.md"
  XDG="$CASE_DIR/xdg"; mkdir -p "$XDG/opencode"
  case $variant in
    paid-string) printf '{"model":"cliproxy/grok-4.7"}\n' > "$XDG/opencode/opencode.json" ;;
    paid-object) printf '{"model":{"providerID":"cliproxy","model":"grok-4.7"}}\n' > "$XDG/opencode/opencode.json" ;;
    free) printf '{"model":"opencode/big-pickle"}\n' > "$XDG/opencode/opencode.json" ;;
    unresolved) : ;;
    agent-override) printf '{"model":"cliproxy/grok-4.7","agent":{"build":{"model":"opencode/big-pickle"}}}\n' > "$XDG/opencode/opencode.json" ;;
  esac
  out=$(unset OPENCODE_CONFIG OPENCODE_CONFIG_CONTENT OPENCODE_CONFIG_DIR; export XDG_CONFIG_HOME="$XDG"
    run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR"); rc=$?
  launch=$(cat "$LAUNCH_LOG")
  confined=no; case "$launch" in *" confine "*) confined=yes ;; esac
  standalone=no; case "$launch" in *"opencode --standalone"*) standalone=yes ;; esac
  plugins=no; [ -f "$WT_DIR/.opencode/plugins/fm-busy-state.js" ] && plugins=yes
  echo "$variant: spawn_rc=$rc fm-busy-state.js_written=$plugins confine_in_launch=$confined opencode_standalone=$standalone"
  [ "$rc" = 0 ] || printf '  spawn output: %s\n' "$(printf '%s' "$out" | tail -3)"
done
rm -rf "$TMP_ROOT"
