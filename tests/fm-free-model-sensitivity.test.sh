#!/usr/bin/env bash
# Property and model checks for the free OpenCode sensitivity boundary.
# Cases are generated from a fixed seed. A failure prints that seed and the
# shrunk path. Dispatch is driven through fm-dispatch-resolve.sh, the launch
# scrub and read block through fm-free-model-sensitivity.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SENS="$ROOT/bin/fm-free-model-sensitivity.sh"
RESOLVE="$ROOT/bin/fm-dispatch-resolve.sh"
TMP_ROOT=$(fm_test_tmproot fm-free-model-sensitivity)
SEED=20261106
COUNT=4

rand() {
  SEED=$(( (SEED * 1103515245 + 12345) & 2147483647 ))
  echo $(( SEED % $1 ))
}

shrink_path() {
  local path=$1 kind=$2 current segment got
  current=$path
  while [ "$current" != "${current#*/}" ]; do
    segment=${current#*/}
    if [ "$kind" = routine ]; then
      "$SENS" class "$segment" >/dev/null 2>&1 && break
    else
      got=$("$SENS" class "$segment" 2>/dev/null || true)
      [ "$got" = "$kind" ] || break
    fi
    current=$segment
  done
  printf '%s' "$current"
}

expect_class() {
  local path=$1 kind=$2 got
  if [ "$kind" = routine ]; then
    if "$SENS" class "$path" >/dev/null 2>&1; then
      fail "seed=$SEED routine path classified sensitive: $(shrink_path "$path" routine)"
    fi
    return
  fi
  got=$("$SENS" class "$path" 2>/dev/null || true)
  if [ "$got" != "$kind" ]; then
    fail "seed=$SEED expected $kind for $(shrink_path "$path" "$kind") (built as $path, got ${got:-routine})"
  fi
}

# One command of the path model: a constructed path must keep its class.
check_generated_path() {
  local kind=$1 n prefix depth path
  n=$(rand 1000)
  depth=$(rand 3)
  prefix=''
  while [ "$depth" -gt 0 ]; do
    prefix="pkg$(rand 50)/$prefix"
    depth=$((depth - 1))
  done
  case "$kind" in
    ci) path="${prefix}app${n}/.github/workflows/build-${n}.yml" ;;
    migration) path="${prefix}db${n}/migrations/${n}_init.sql" ;;
    infra) path="${prefix}stack${n}/infra/main.tf" ;;
    env) path="${prefix}app${n}/.env" ;;
    doppler) path="${prefix}app${n}/doppler.yaml" ;;
    auth) path="${prefix}app${n}/auth/session.ts" ;;
    payments) path="${prefix}app${n}/payments/charge.ts" ;;
    routine) path="${prefix}src/app-${n}.ts" ;;
    *) fail "unknown class $kind" ;;
  esac
  expect_class "$path" "$kind"
}

echo "free-model sensitivity seed=$SEED count=$COUNT"

for _ in $(seq 1 "$COUNT"); do
  check_generated_path ci
  check_generated_path migration
  check_generated_path infra
  check_generated_path env
  check_generated_path doppler
  check_generated_path auth
  check_generated_path payments
  check_generated_path routine
done

# Fixed shapes that define the boundary, including paths under bin/ and docs/
# that stay routine.
expect_class '.gitlab-ci.yml' ci
expect_class 'azure-pipelines.yml' ci
expect_class 'src/workflows/job.ts' routine
expect_class 'db/001_migration.sql' migration
expect_class 'docs/migration-notes.md' routine
expect_class 'bin/deploy.sh' infra
expect_class 'bin/fm-spawn.sh' routine
expect_class 'vercel.json' infra
expect_class 'docs/configuration.md' routine
expect_class 'config/.env.local' env
expect_class 'src/env.ts' routine
expect_class 'service/.doppler/config.yaml' doppler
expect_class 'src/auth.ts' auth
expect_class 'src/author.ts' routine
expect_class 'src/billing.ts' payments
expect_class 'src/secrets/helper.ts' routine
pass "generated paths keep their sensitive class, and routine bin and docs paths stay eligible"

# Token names are a pure rule: a generated mix of token and ordinary names.
token_cases=(
  'DOPPLER_TOKEN scrub'
  'DOPPLER_SERVICE_TOKEN scrub'
  'DOPPLER_PROJECT keep'
  'SUPABASE_SERVICE_ROLE_KEY scrub'
  'SUPABASE_ANON_KEY scrub'
  'SUPABASE_URL keep'
  'AWS_SECRET_ACCESS_KEY scrub'
  'AWS_ACCESS_KEY_ID scrub'
  'AWS_SESSION_TOKEN scrub'
  'AWS_REGION keep'
  'AWS_PROFILE keep'
  'GOOGLE_APPLICATION_CREDENTIALS scrub'
  'AZURE_CLIENT_SECRET scrub'
  'GH_TOKEN scrub'
  'GITHUB_TOKEN scrub'
  'GITHUB_PAT scrub'
  'GH_HOST keep'
  'GITHUB_ACTOR keep'
  'PATH keep'
  'HOME keep'
)
for item in "${token_cases[@]}"; do
  name=${item%% *}
  want=${item##* }
  if [ "$want" = scrub ]; then
    "$SENS" token-name "$name" || fail "seed=$SEED $name should be scrubbed"
  else
    if "$SENS" token-name "$name"; then
      fail "seed=$SEED $name should stay in the environment"
    fi
  fi
done
pass "token names cover Doppler, Supabase, cloud, and GitHub-write, and ordinary names stay"

# Model: the same ranked rule is offered a path command. A sensitive path never
# resolves to the free OpenCode model. A routine path does, because that model
# has the higher spend priority.
HOME_DIR="$TMP_ROOT/home"
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
LOG="$TMP_ROOT/log"
mkdir -p "$HOME_DIR/config" "$LOG"
cat > "$FAKEBIN/curl" <<'SH'
#!/usr/bin/env bash
set -u
out=''
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out=$2; shift 2 ;;
    *) shift ;;
  esac
done
cat >/dev/null
cat /dev/fd/3 >/dev/null 2>&1 || true
cp "${FAKE_CURL_RESPONSE:?}" "$out"
printf '200'
SH
chmod +x "$FAKEBIN/curl"
cat > "$FAKEBIN/quota-axi" <<'SH'
#!/usr/bin/env bash
set -u
[ "${1:-}" = --json ] || exit 2
cat "${QUOTA_AXI_FIXTURE:?}"
SH
chmod +x "$FAKEBIN/quota-axi"
cat > "$HOME_DIR/config/crew-dispatch.json" <<'JSON'
{
  "rules": [
    {
      "when": "Any coding task.",
      "use": [
        {"harness": "opencode", "model": "opencode/glm-5.3-flash-free", "provider": "codex"},
        {"harness": "claude", "model": "sonnet", "effort": "high"}
      ]
    }
  ],
  "default": {"harness": "claude", "model": "opus"}
}
JSON
cat > "$TMP_ROOT/quota.json" <<'JSON'
{
  "generatedAt": "2030-01-01T00:00:00Z",
  "schemaVersion": 5,
  "providers": [
    { "provider": "claude", "state": { "status": "fresh" }, "quotaSemantics": { "status": "known", "effectiveAvailability": [
      { "scope": "all_models", "status": "known", "effectivePercentRemaining": 70, "runway": { "status": "projected_exhaustion" }, "selection": { "spendPriority": -0.4 } } ] } },
    { "provider": "codex", "state": { "status": "fresh" }, "quotaSemantics": { "status": "known", "effectiveAvailability": [
      { "scope": "all_models", "status": "known", "effectivePercentRemaining": 80, "runway": { "status": "through_reset" }, "selection": { "spendPriority": 0.95 } } ] } }
  ]
}
JSON
cat > "$TMP_ROOT/response.json" <<'JSON'
{ "model": "jev-1.13.0",
  "answers": { "rule": { "type": "choice", "choice": "rule_1", "confidence": 0.93,
    "probabilities": { "rule_1": 0.99, "default": 0.01 } } },
  "usage": { "input_tokens": 12, "output_tokens": 3 } }
JSON
export FAKE_CURL_RESPONSE="$TMP_ROOT/response.json" QUOTA_AXI_FIXTURE="$TMP_ROOT/quota.json"
export TYPESAFE_API_KEY=test-key-sensitivity

resolve_profile() {
  local path=$1 out profile
  cat > "$TMP_ROOT/brief.md" <<MD
# Task
Adjust the pager.

Target paths: $path
MD
  out=$(PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" "$RESOLVE" "$TMP_ROOT/brief.md" --project pager 2>"$TMP_ROOT/resolve.err") || fail "resolve failed for $path: $(cat "$TMP_ROOT/resolve.err")"
  profile=$(printf '%s\n' "$out" | awk '/^  profile:/{print}')
  printf '%s' "$profile"
}

for _ in $(seq 1 "$COUNT"); do
  for kind in ci migration infra env doppler auth payments; do
    n=$(rand 1000)
    case "$kind" in
      ci) path="svc${n}/.github/workflows/ci.yml" ;;
      migration) path="svc${n}/migrations/001.sql" ;;
      infra) path="svc${n}/infra/main.tf" ;;
      env) path="svc${n}/.env.local" ;;
      doppler) path="svc${n}/doppler.yaml" ;;
      auth) path="svc${n}/auth/session.ts" ;;
      payments) path="svc${n}/payments/charge.ts" ;;
    esac
    profile=$(resolve_profile "$path")
    case "$profile" in
      *flash-free*) fail "seed=$SEED sensitive $kind path resolved to a free model: $path" ;;
      *sonnet*) ;;
      *) fail "seed=$SEED sensitive $kind path did not resolve to the paid model: $path profile=$profile" ;;
    esac
  done
  path="src/app-$(rand 1000).ts"
  profile=$(resolve_profile "$path")
  case "$profile" in
    *flash-free*) ;;
    *) fail "seed=$SEED routine path lost the free model: $path profile=$profile" ;;
  esac
done
pass "after classification a sensitive path never resolves to the free OpenCode model"

# The read block and the scrub are one confined process. The same files are
# readable without that process, which is what every other launch keeps.
TREE="$TMP_ROOT/tree"
mkdir -p "$TREE/home/.secrets" "$TREE/home/.aws" "$TREE/home/.config/gh" \
  "$TREE/work/.github/workflows" "$TREE/work/migrations" "$TREE/work/infra" \
  "$TREE/work/auth" "$TREE/work/payments" "$TREE/work/src/secrets" \
  "$TREE/work/bin" "$TREE/work/docs"
printf 'SECRET\n' > "$TREE/home/.secrets/token"
printf 'AWS\n' > "$TREE/home/.aws/credentials"
printf 'GH\n' > "$TREE/home/.config/gh/hosts.yml"
printf 'ENV\n' > "$TREE/work/.env"
printf 'CI\n' > "$TREE/work/.github/workflows/ci.yml"
printf 'SQL\n' > "$TREE/work/migrations/001.sql"
printf 'TF\n' > "$TREE/work/infra/main.tf"
printf 'DOP\n' > "$TREE/work/doppler.yaml"
printf 'AUTH\n' > "$TREE/work/auth/session.ts"
printf 'PAY\n' > "$TREE/work/payments/charge.ts"
printf 'APP\n' > "$TREE/work/src/app.ts"
printf 'BIN\n' > "$TREE/work/bin/fm-spawn.sh"
printf 'DOC\n' > "$TREE/work/docs/configuration.md"
printf 'CODE\n' > "$TREE/work/src/secrets/helper.ts"
ln -s ../.env "$TREE/work/src/link.env"
unconfined=$(python3 -c 'print(open("'"$TREE/work/.env"'", encoding="utf-8").read().strip())')
[ "$unconfined" = ENV ] || fail "the unconfined process could not read .env, so a denial would prove nothing"
cat > "$TMP_ROOT/probe.py" <<'PY'
import os, sys
for path in sys.argv[1:]:
    try:
        open(path, "r", encoding="utf-8").read()
        print("read\t" + path)
    except OSError as exc:
        print("deny\t" + path + "\t" + str(exc.errno))
for name in ("DOPPLER_TOKEN", "SUPABASE_URL", "SUPABASE_SERVICE_ROLE_KEY", "AWS_SECRET_ACCESS_KEY", "AWS_REGION", "GH_TOKEN", "GITHUB_TOKEN", "PATH", "HOME"):
    print("env\t" + name + "\t" + ("set" if os.environ.get(name) else "unset"))
PY
(
  cd "$TREE/work" || exit 1
  export DOPPLER_TOKEN=d SUPABASE_URL=https://db.example SUPABASE_SERVICE_ROLE_KEY=s \
    AWS_SECRET_ACCESS_KEY=a AWS_REGION=us-east-1 GH_TOKEN=g GITHUB_TOKEN=gt
  "$SENS" confine --home "$TREE/home" -- python3 "$TMP_ROOT/probe.py" \
    .env .github/workflows/ci.yml migrations/001.sql infra/main.tf doppler.yaml \
    auth/session.ts payments/charge.ts src/link.env \
    "$TREE/home/.secrets/token" "$TREE/home/.aws/credentials" "$TREE/home/.config/gh/hosts.yml" \
    src/app.ts bin/fm-spawn.sh docs/configuration.md src/secrets/helper.ts
) > "$TMP_ROOT/probe.out" || fail "confine probe failed"
while IFS=$'\t' read -r action path extra; do
  case "$action" in
    read)
      case "$path" in
        src/app.ts|bin/fm-spawn.sh|docs/configuration.md|src/secrets/helper.ts) ;;
        *) fail "confined process read $path" ;;
      esac
      ;;
    deny)
      [ "$extra" = 13 ] || fail "confined denial of $path was errno $extra, not EACCES"
      ;;
    env)
      case "$path:$extra" in
        DOPPLER_TOKEN:unset|SUPABASE_SERVICE_ROLE_KEY:unset|AWS_SECRET_ACCESS_KEY:unset|GH_TOKEN:unset|GITHUB_TOKEN:unset) ;;
        SUPABASE_URL:set|AWS_REGION:set|PATH:set|HOME:set) ;;
        *) fail "confined environment $path is $extra" ;;
      esac
      ;;
  esac
done < "$TMP_ROOT/probe.out"
pass "a free-model process cannot read secrets or sensitive paths, and other launches still can"

# Paid OpenCode, Grok, Codex, and Claude are not free OpenCode models.
"$SENS" free-model --harness opencode --model opencode/glm-5.3-flash-free
"$SENS" free-model --harness opencode --model opencode/big-pickle && fail "big-pickle is not marked free"
"$SENS" free-model --harness opencode --model anthropic/claude-sonnet-4-5 && fail "a paid OpenCode model was treated as free"
"$SENS" free-model --harness grok --model grok-4-free && fail "a Grok model was treated as a free OpenCode model"
"$SENS" free-model --harness codex --model gpt-5 && fail "Codex was treated as a free OpenCode model"
"$SENS" free-model --harness claude --model claude-sonnet-4-5 && fail "Claude was treated as a free OpenCode model"
pass "only an OpenCode model id marked free is a free OpenCode model"

echo "# all fm-free-model-sensitivity tests passed"
