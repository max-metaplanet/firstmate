#!/usr/bin/env bash
# Live driver: real fm-dispatch-resolve.sh, real quota-axi, real api.typesafe.ai.
# curl is a pass-through shim that logs each invocation (URL only) then execs /usr/bin/curl.
set -u
WT=/Users/max/.no-mistakes/worktrees/61c6dd39b831/01M382VW1J68JABBYH04PG3VB6
TOOL=$WT/bin/fm-dispatch-resolve.sh
LAB=$(mktemp -d /tmp/fm-dispatch-live.XXXX)
mkdir -p "$LAB/home/config" "$LAB/bin"
cat > "$LAB/bin/curl" <<EOF
#!/usr/bin/env bash
echo "curl-called: \$*" >> "$LAB/curl.log"
exec /usr/bin/curl "\$@"
EOF
chmod +x "$LAB/bin/curl"
cp "$WT/docs/examples/crew-dispatch.json" "$LAB/home/config/crew-dispatch.json"
export FM_HOME="$LAB/home" PATH="$LAB/bin:$PATH"

run() {  # <label> <brief-text> [rules-file]
  local label=$1 text=$2 rules=${3:-$WT/docs/examples/crew-dispatch.json}
  cp "$rules" "$FM_HOME/config/crew-dispatch.json"
  printf '%s\n' "$text" > "$LAB/brief.md"
  : > "$LAB/curl.log"
  echo "=================================================================="
  echo "## $label"
  echo "--- brief:"; sed 's/^/    /' "$LAB/brief.md"
  echo "--- fm-dispatch-resolve.sh output:"
  bash "$TOOL" "$LAB/brief.md" --project demo 2>&1; echo "    [exit $?]"
  echo "--- outbound calls to Jev: $(grep -c typesafe "$LAB/curl.log")"
}

NOPF=$LAB/nopf.json; jq 'del(.rules[].path_force)' "$WT/docs/examples/crew-dispatch.json" > "$NOPF"
BAD=$LAB/bad.json; jq '.rules[2].path_force="deploy"' "$WT/docs/examples/crew-dispatch.json" > "$BAD"
TWO=$LAB/two.json; jq '.rules[1].path_force="deployment-config"' "$WT/docs/examples/crew-dispatch.json" > "$TWO"
CAPT=$LAB/capt.json; jq '.rules[2].approval="captain"' "$WT/docs/examples/crew-dispatch.json" > "$CAPT"
MOVED=$LAB/moved.json; jq '.rules |= [.[2], .[0], .[1]]' "$WT/docs/examples/crew-dispatch.json" > "$MOVED"

case "${1:-forced}" in
forced)
  for p in vercel.json infra/main.tf env/prod.tfvars template.yaml stack/template.yml app.template infra/api.template.json net.template.yaml cloudformation/stack.json \
           k8s/web.yaml deploy/web-ingress.yaml argocd/app.yaml argo/app.yaml argo-cd/root.yaml charts/web/Chart.yaml helm/web/templates/svc.yaml values-prod.yaml \
           scripts/deploy-prod.sh bin/deploy.ps1 .github/workflows/release.yml; do
    run "forced: Target paths: $p" "# Task
Tidy a typo in the config comment.
Target paths: $p"
  done
  run "forced: bullet + backticks + commas, match on 2nd path" "# Task
Rename a label.
- Target paths: \`src/app.ts\`, \`vercel.json\`"
  run "forced: rule order moved (careful rule now rule_1)" "# Task
Tidy a typo.
Target paths: vercel.json" "$MOVED"
  run "forced onto captain-approval rule keeps the approval gate" "# Task
Tidy a typo.
Target paths: vercel.json" "$CAPT"
  ;;
jev)
  run "fallthrough: prose names vercel.json but no Target paths line" "# Task
Fix a typo in the vercel.json rewrites comment and the ArgoCD application manifest."
  run "fallthrough: near-miss declared paths" "# Task
Fix a typo in the docs.
Target paths: src/application.yaml docs/template-guide.md"
  run "fallthrough: no rule declares path_force (inert)" "# Task
Fix a typo in the rewrites comment.
Target paths: vercel.json" "$NOPF"
  ;;
recheck)
  run "recheck forced: Target paths: vercel.json" "# Task
Tidy a typo.
Target paths: vercel.json"
  run "recheck fallthrough: prose only" "# Task
Fix a typo in the vercel.json rewrites comment."
  ;;
config)
  run "config error: unknown path_force value" "x
Target paths: vercel.json" "$BAD"
  run "config error: two rules declare path_force" "x
Target paths: vercel.json" "$TWO"
  ;;
esac
rm -rf "$LAB"
