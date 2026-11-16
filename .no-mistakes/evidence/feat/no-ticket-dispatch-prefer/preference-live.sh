#!/usr/bin/env bash
set -euo pipefail
ROOT=$PWD
SCRATCH=$(mktemp -d "$PWD/.prefer-live.XXXXXX")
trap 'rm -rf "$SCRATCH"' EXIT
export FM_HOME="$SCRATCH/primary" FM_ROOT_OVERRIDE="$ROOT"+unset FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE FM_DATA_OVERRIDE FM_PROJECTS_OVERRIDE
mkdir -p "$FM_HOME/config" "$FM_HOME/state" "$FM_HOME/data" "$SCRATCH/second/config" "$SCRATCH/input-bin"
cat > "$FM_HOME/config/crew-dispatch.json" <<'JSON'
{"rules":[{"when":"Implementation","kind":"implementation","path_force":"deployment-config","use":[{"harness":"codex","model":"gpt-5.6-sol"},{"harness":"grok","model":"grok-4.7"}]}]}
JSON
printf 'Target paths: vercel.json\nImplement deployment configuration.\n' > "$SCRATCH/brief.md"
python3 - "$SCRATCH/quota.json" <<'PY'
import json,sys
json.dump({'schemaVersion':5,'providers':[{'provider':p,'state':{'status':'fresh'},'quotaSemantics':{'status':'known','effectiveAvailability':[{'scope':'all_models','status':'known','effectivePercentRemaining':75,'runway':{'status':'through_reset'},'selection':{'spendPriority':score}}]}} for p,score in [('codex',0.2),('grok',0.8)]]},open(sys.argv[1],'w'))
PY
# Only the external quota data source is substituted; resolver and its rule
# selection, preference, gates and ranking are the unchanged product scripts.
printf '#!/usr/bin/env bash\ncat "$LIVE_QUOTA"\n' > "$SCRATCH/input-bin/quota-axi"
chmod +x "$SCRATCH/input-bin/quota-axi"
export LIVE_QUOTA="$SCRATCH/quota.json"
resolve() {
  PATH="$SCRATCH/input-bin:$PATH" TYPESAFE_API_KEY=disposable-path-force-no-network \
    bin/fm-dispatch-resolve.sh "$SCRATCH/brief.md" --json > "$SCRATCH/resolution.json"
  jq '{status,chosen,preference,decided_by}' "$SCRATCH/resolution.json"
  test "$(jq -r '.chosen.profile.harness' "$SCRATCH/resolution.json")" = "$1"
}
choose() {
  local got
  got=$(bin/fm-quota-choose.sh --snapshot "$LIVE_QUOTA" --kind implementation --candidate grok:grok-4.7 --candidate codex:gpt-5.6-sol)
  printf 'worker selection: %s\n' "$got"
  test "${got%% *}" = "$1"
}
printf '\nSCENARIO: one command immediately switches typed and worker dispatch\n'
bin/fm-prefer.sh set implementation codex
bin/fm-prefer.sh show
resolve codex
choose codex
bin/fm-prefer.sh set implementation grok
resolve grok
choose grok
printf '\nSCENARIO: spaced persisted key is replaced without duplication\n'
printf 'implementation = codex\n' > "$FM_HOME/config/dispatch-prefer"
bin/fm-prefer.sh set implementation grok
test "$(cat "$FM_HOME/config/dispatch-prefer")" = implementation=grok
cat "$FM_HOME/config/dispatch-prefer"
printf '\nSCENARIO: preference cannot override exhausted quota or add a candidate\n'
bin/fm-prefer.sh set implementation codex
python3 - "$LIVE_QUOTA" <<'PY'
import json,sys
p=sys.argv[1]; q=json.load(open(p)); row=q['providers'][0]['quotaSemantics']['effectiveAvailability'][0]; row['effectivePercentRemaining']=0; row['runway']['status']='exhausted_now'; json.dump(q,open(p,'w'))
PY
resolve grok
test "$(jq -r '.preference.state' "$SCRATCH/resolution.json")" = not-usable
choose grok
bin/fm-prefer.sh set implementation cursor
resolve grok
test "$(jq -r '.preference.state' "$SCRATCH/resolution.json")" = no-op
printf '\nSCENARIO: auto restores quota ranking and clear removes the preference\n'
bin/fm-prefer.sh set implementation auto
resolve grok
bin/fm-prefer.sh clear
test ! -e "$FM_HOME/config/dispatch-prefer"
printf '\nSCENARIO: malformed preferences and removed local-only option fail closed\n'
printf 'implementation=codex\nimplementation=grok\n' > "$FM_HOME/config/dispatch-prefer"
set +e
bin/fm-prefer.sh show
rc=$?
set -e
test "$rc" = 2
set +e
PATH="$SCRATCH/input-bin:$PATH" TYPESAFE_API_KEY=disposable bin/fm-dispatch-resolve.sh "$SCRATCH/brief.md" --json
rc=$?
set -e
test "$rc" = 2
rm "$FM_HOME/config/dispatch-prefer"
set +e
bin/fm-prefer.sh set implementation codex --no-push
rc=$?
set -e
test "$rc" = 2
test ! -e "$FM_HOME/config/dispatch-prefer"
printf '\nSCENARIO: unresolved home fails set, auto and clear while keeping local changes\n'
printf 'kind=secondmate\nwindow=disposable-missing\n' > "$FM_HOME/state/legacy.meta"
for action in set auto clear; do
  case "$action" in
    set) args=(set implementation codex);;
    auto) args=(set implementation auto);;
    clear) args=(clear);;
  esac
  set +e
  bin/fm-prefer.sh "${args[@]}" > "$SCRATCH/result" 2>&1
  rc=$?
  set -e
  cat "$SCRATCH/result"
  printf 'exit=%s\n' "$rc"
  test "$rc" = 1
  grep -q 'local preference is set, but at least one secondmate home did not take it; run bin/fm-config-push.sh once that host is reachable' "$SCRATCH/result"
  case "$action" in
    set) test "$(cat "$FM_HOME/config/dispatch-prefer")" = implementation=codex;;
    auto) test ! -s "$FM_HOME/config/dispatch-prefer";;
    clear) test ! -e "$FM_HOME/config/dispatch-prefer";;
  esac
done
rm "$FM_HOME/state/legacy.meta"
printf '\nSCENARIO: inherited preference is consumed by a second home; unchanged converges\n'
. bin/fm-config-inherit-lib.sh
git -C "$SCRATCH/second" init -q
printf '/config/\n' > "$SCRATCH/second/.gitignore"
bin/fm-prefer.sh set implementation grok
for attempt in copy unchanged; do
  : > "$SCRATCH/report"
  FM_CONFIG_INHERIT_REPORT="$SCRATCH/report" propagate_inheritable_config "$FM_HOME/config" "$SCRATCH/second/config" "$FM_HOME"
  awk -F '\t' '$1 == "dispatch-prefer"' "$SCRATCH/report"
  FM_HOME="$SCRATCH/second" bin/fm-prefer.sh show
  got=$(FM_HOME="$SCRATCH/second" bin/fm-quota-choose.sh --snapshot "$LIVE_QUOTA" --kind implementation codex:gpt-5.6-sol grok:grok-4.7)
  printf 'second-home worker selection: %s\n' "$got"
  test "$got" = 'grok grok-4.7'
done
printf '\nSCENARIO: refused inherited copy/removal fails and preserves destination\n'
printf '/config/*\n!/config/dispatch-prefer\n' > "$SCRATCH/second/.gitignore"
for action in set auto clear; do
  case "$action" in
    set) bin/fm-prefer.sh set implementation codex;;
    auto) bin/fm-prefer.sh set implementation auto;;
    clear) bin/fm-prefer.sh clear;;
  esac
  : > "$SCRATCH/report"
  set +e
  FM_CONFIG_INHERIT_REPORT="$SCRATCH/report" propagate_inheritable_config "$FM_HOME/config" "$SCRATCH/second/config" "$FM_HOME"
  rc=$?
  set -e
  awk -F '\t' '$1 == "dispatch-prefer"' "$SCRATCH/report"
  printf 'inheritance exit=%s; destination=%s\n' "$rc" "$(cat "$SCRATCH/second/config/dispatch-prefer")"
  test "$rc" = 1
  test "$(cat "$SCRATCH/second/config/dispatch-prefer")" = implementation=grok
done
printf '\nSCENARIO: remote receiver publishes, reads back, preserves unchanged and removes preference\n'
mkdir -p "$SCRATCH/remote"
printf 'implementation=grok\n' > "$SCRATCH/payload"
bytes=$(wc -c < "$SCRATCH/payload")
digest=$(sha256sum "$SCRATCH/payload" | cut -d ' ' -f 1)
for generation in 1 2; do
  FM_HOME="$SCRATCH/remote" bin/fm-remote-inherit.sh put config/dispatch-prefer "$bytes" "$digest" "$generation" < "$SCRATCH/payload"
  FM_HOME="$SCRATCH/remote" bin/fm-prefer.sh show
  test "$(cat "$SCRATCH/remote/config/dispatch-prefer")" = implementation=grok
done
empty_digest=$(printf '' | sha256sum | cut -d ' ' -f 1)
FM_HOME="$SCRATCH/remote" bin/fm-remote-inherit.sh absent config/dispatch-prefer 0 "$empty_digest" 3
FM_HOME="$SCRATCH/remote" bin/fm-prefer.sh show
test ! -e "$SCRATCH/remote/config/dispatch-prefer"
printf '\nAll disposable product checks completed.\n'
