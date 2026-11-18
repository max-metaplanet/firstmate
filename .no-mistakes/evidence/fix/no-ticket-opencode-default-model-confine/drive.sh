#!/usr/bin/env bash
# Drives the real classifier CLI (fm-spawn's call shape) and real opencode v2.2.5 against disposable configs.
set -u
REPO=$1 T=$2
WT=$T/wt
classify() { # $1=model
  env -u OPENCODE_CONFIG -u OPENCODE_CONFIG_CONTENT -u OPENCODE_CONFIG_DIR HOME=$T/home XDG_CONFIG_HOME=$T/xdg \
    "$REPO/bin/fm-free-model-sensitivity.sh" free-model --harness opencode --model "$1" --dir "$WT"; rc=$?
  case $rc in 0) echo "classifier: FREE -> confine applied (exit 0)";; 1) echo "classifier: PAID -> no confine (exit 1)";; *) echo "classifier: ERROR exit $rc";; esac
}
oc_model() { (cd "$WT" && env HOME=$T/home XDG_CONFIG_HOME=$T/xdg XDG_DATA_HOME=$T/data XDG_STATE_HOME=$T/state XDG_CACHE_HOME=$T/cache timeout 40 opencode debug config 2>&1 | python3 -c 'import json,sys
d=json.load(sys.stdin); print("opencode debug config layers:", [(x["type"], x["path"].replace(sys.argv[1],"$T"), x.get("info")) for x in d])' "$T"); }
reset() { rm -rf "$T/xdg/opencode"; mkdir -p "$T/xdg/opencode"; rm -f "$WT/opencode.json"; }
scenario() { echo; echo "### $1"; }
echo "WT .opencode contents (tracked plugins + fm-spawn plugin):"; ls "$WT/.opencode/plugins" | sed 's/^/  /'

scenario "S1 telos64: global model=cliproxy/grok-4.7, --model '' in firstmate worktree"
reset; printf '{"model":"cliproxy/grok-4.7"}\n' > $T/xdg/opencode/opencode.json; oc_model; classify ""
scenario "S2 same, --model default"
classify default
scenario "S3 object form {providerID:cliproxy, model:grok-4.7}"
reset; printf '{"model":{"providerID":"cliproxy","model":"grok-4.7"}}\n' > $T/xdg/opencode/opencode.json; classify ""
scenario "S4 free configured default opencode/big-pickle"
reset; printf '{"model":"opencode/big-pickle"}\n' > $T/xdg/opencode/opencode.json; oc_model; classify ""
scenario "S5 no opencode config at all (unresolvable -> today's behaviour)"
reset; classify ""
scenario "S6 config without model key"
reset; printf '{"theme":"x"}\n' > $T/xdg/opencode/opencode.json; classify ""
scenario "S7 adversarial: agent.build.model free beside paid top-level"
reset; printf '{"model":"cliproxy/grok-4.7","agent":{"build":{"model":"opencode/big-pickle"}}}\n' > $T/xdg/opencode/opencode.json; classify ""
(cd "$WT" && env HOME=$T/home XDG_CONFIG_HOME=$T/xdg XDG_DATA_HOME=$T/data XDG_STATE_HOME=$T/state XDG_CACHE_HOME=$T/cache timeout 40 opencode debug agents 2>/dev/null | python3 -c 'import json,sys;[print("opencode debug agents:", a["id"], "model=", a.get("model")) for a in json.load(sys.stdin) if a["id"]=="build"]')
scenario "S8 adversarial: mode key carrying free model"
reset; printf '{"model":"cliproxy/grok-4.7","mode":{"build":{"model":"opencode/big-pickle"}}}\n' > $T/xdg/opencode/opencode.json; classify ""
scenario "S9 adversarial: global mode/build.md override file"
reset; printf '{"model":"cliproxy/grok-4.7"}\n' > $T/xdg/opencode/opencode.json; mkdir -p $T/xdg/opencode/mode; printf -- '---\nmodel: opencode/big-pickle\n---\nbuild\n' > $T/xdg/opencode/mode/build.md; classify ""
scenario "S10 adversarial: project opencode.json in worktree selecting free model"
reset; printf '{"model":"cliproxy/grok-4.7"}\n' > $T/xdg/opencode/opencode.json; printf '{"model":"opencode/big-pickle"}\n' > $WT/opencode.json; oc_model; classify ""
scenario "S11 adversarial: OPENCODE_CONFIG set"
reset; printf '{"model":"cliproxy/grok-4.7"}\n' > $T/xdg/opencode/opencode.json
env HOME=$T/home XDG_CONFIG_HOME=$T/xdg OPENCODE_CONFIG=/dev/null "$REPO/bin/fm-free-model-sensitivity.sh" free-model --harness opencode --model "" --dir "$WT"; echo "classifier exit $? (0=FREE/confine)"
scenario "S12 adversarial: {env:...} placeholder model"
reset; printf '{"model":"{env:OC_MODEL}"}\n' > $T/xdg/opencode/opencode.json; classify ""
scenario "S13 adversarial: global opencode.jsonc layer"
reset; printf '{"model":"cliproxy/grok-4.7"}\n' > $T/xdg/opencode/opencode.json; printf '{"model":"opencode/big-pickle"}\n' > $T/xdg/opencode/opencode.jsonc; classify ""
scenario "S14 regression: explicit free model with paid default still confines"
reset; printf '{"model":"cliproxy/grok-4.7"}\n' > $T/xdg/opencode/opencode.json; classify "opencode/big-pickle"
scenario "S15 regression: explicit paid model"
classify "cliproxy/grok-4.7"
scenario "S16 regression: non-opencode harness"
env HOME=$T/home XDG_CONFIG_HOME=$T/xdg "$REPO/bin/fm-free-model-sensitivity.sh" free-model --harness claude --model "" --dir "$WT"; echo "classifier exit $? (1=PAID)"
reset
