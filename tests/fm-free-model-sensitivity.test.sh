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
  "$TREE/work/bin" "$TREE/work/docs" \
  "$TREE/toolchain/site-packages/pip/_internal/network" "$TREE/toolchain/node_modules/pkg/migrations"
printf 'PIP\n' > "$TREE/toolchain/site-packages/pip/_internal/network/auth.py"
printf 'NODE\n' > "$TREE/toolchain/node_modules/pkg/migrations/001.js"
mkdir -p "$TREE/primary"
printf 'PRIMARY\n' > "$TREE/primary/.env.local"
printf 'DOP\n' > "$TREE/primary/doppler.yaml"
ln -s "$TREE/primary/.env.local" "$TREE/work/src/notes.txt"
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
    target = path.replace("@ppid", str(os.getppid()))
    try:
        open(target, "r", encoding="utf-8", errors="replace").read()
        print("read\t" + path)
    except OSError as exc:
        print("deny\t" + path + "\t" + str(exc.errno))
for name in ("DOPPLER_TOKEN", "SUPABASE_URL", "SUPABASE_SERVICE_ROLE_KEY", "AWS_SECRET_ACCESS_KEY", "AWS_REGION", "GH_TOKEN", "GITHUB_TOKEN", "PATH", "HOME"):
    print("env\t" + name + "\t" + ("set" if os.environ.get(name) else "unset"))
PY
# /proc/@ppid is the supervisor, whose kernel environment block still holds
# the tokens it unset. /dev/fd/3 is a routine file and /dev/fd/4 a pipe, both
# opened by the caller as process substitution would. Path classes cover the
# worktree the confine starts in, so toolchain files outside it stay readable.
# Env and Doppler files in another checkout stay blocked, as do symlinks to them.
denied_paths=(
  .env .github/workflows/ci.yml migrations/001.sql infra/main.tf doppler.yaml
  auth/session.ts payments/charge.ts src/link.env
  "$TREE/home/.secrets/token" "$TREE/home/.aws/credentials" "$TREE/home/.config/gh/hosts.yml"
  /proc/self/environ /proc/thread-self/environ /proc/@ppid/environ /proc/self/mem
  "$TREE/primary/.env.local" "$TREE/primary/doppler.yaml" src/notes.txt
)
read_paths=(
  src/app.ts bin/fm-spawn.sh docs/configuration.md src/secrets/helper.ts /dev/fd/3 /dev/fd/4
  "$TREE/toolchain/site-packages/pip/_internal/network/auth.py" "$TREE/toolchain/node_modules/pkg/migrations/001.js"
)
(
  cd "$TREE/work" || exit 1
  export DOPPLER_TOKEN=d SUPABASE_URL=https://db.example SUPABASE_SERVICE_ROLE_KEY=s \
    AWS_SECRET_ACCESS_KEY=a AWS_REGION=us-east-1 GH_TOKEN=g GITHUB_TOKEN=gt
  "$SENS" confine --home "$TREE/home" -- python3 "$TMP_ROOT/probe.py" \
    "${denied_paths[@]}" "${read_paths[@]}" 3<"$TREE/work/src/app.ts" 4< <(printf 'PIPE\n')
) > "$TMP_ROOT/probe.out" || fail "confine probe failed"
probe_line() {
  awk -F'\t' -v p="$1" '$1 != "env" && $2 == p' "$TMP_ROOT/probe.out"
}
for path in "${denied_paths[@]}"; do
  got=$(probe_line "$path")
  [ "$got" = "deny"$'\t'"$path"$'\t'13 ] || fail "confined process should get EACCES for $path, got: ${got:-nothing}"
done
for path in "${read_paths[@]}"; do
  got=$(probe_line "$path")
  [ "$got" = "read"$'\t'"$path" ] || fail "confined process should read routine $path, got: ${got:-nothing}"
done
[ "$(grep -vc '^env' "$TMP_ROOT/probe.out")" = $(( ${#denied_paths[@]} + ${#read_paths[@]} )) ] ||
  fail "confine probe reported unexpected paths: $(cat "$TMP_ROOT/probe.out")"
while IFS=$'\t' read -r action path extra; do
  [ "$action" = env ] || continue
  case "$path:$extra" in
    DOPPLER_TOKEN:unset|SUPABASE_SERVICE_ROLE_KEY:unset|AWS_SECRET_ACCESS_KEY:unset|GH_TOKEN:unset|GITHUB_TOKEN:unset) ;;
    SUPABASE_URL:set|AWS_REGION:set|PATH:set|HOME:set) ;;
    *) fail "confined environment $path is $extra" ;;
  esac
done < "$TMP_ROOT/probe.out"
pass "a free-model process cannot read secrets or sensitive paths, and other launches still can"

# open(2) with O_PATH succeeds on any reachable file, and runtimes such as
# opencode's use it at startup. The supervisor must keep serving after one, so
# a later ordinary read still works, while a sensitive O_PATH open stays denied.
opath_out=$(cd "$TREE/work" && "$SENS" confine --home "$TREE/home" -- python3 -c '
import os
os.close(os.open("src/app.ts", os.O_PATH))
try:
    os.open(".env", os.O_PATH)
    print("env-open")
except OSError as exc:
    print("env-deny", exc.errno)
print(open("src/app.ts").read().strip())
' 2>&1) || fail "an O_PATH open broke the confined process: $opath_out"
[ "$opath_out" = "env-deny 13"$'\n'"APP" ] || fail "O_PATH under confine gave: $opath_out"
pass "an O_PATH open neither ends supervision nor reaches a sensitive path"

# A pipeline whose reader exits early kills its writer with SIGPIPE, which can
# cancel a pending notification. Supervision must outlive that, so the next
# command in the same confined shell can still exec and read files.
for _ in $(seq 1 10); do
  pipe_out=$(cd "$TREE/work" && "$SENS" confine --home "$TREE/home" -- sh -c \
    'yes 2>/dev/null | head -n 1 >/dev/null; env | grep -i path | sort >/dev/null; cat src/app.ts' 2>&1) ||
    fail "a routine pipeline broke the confined shell: $pipe_out"
  [ "$pipe_out" = APP ] || fail "a routine pipeline broke the confined shell: $pipe_out"
done
pass "routine pipelines keep the confined shell supervised"

# POSIX: a writer to a pipe with no reader gets SIGPIPE and dies, so an
# endless producer feeding `head -1` ends as soon as head exits. If the
# confine left SIGPIPE ignored, the producer would loop forever on EPIPE.
sigpipe_rc=0
sigpipe_out=$(cd "$TREE/work" && timeout 10 "$SENS" confine --home "$TREE/home" -- sh -c \
  'while :; do echo x; done | head -1' 2>/dev/null) || sigpipe_rc=$?
[ "$sigpipe_rc" -eq 0 ] && [ "$sigpipe_out" = x ] ||
  fail "an endless producer piped to head did not end under confine (rc=$sigpipe_rc)"
pass "pipelines end on SIGPIPE under the confine as they do outside it"

# The captain's documented free list: OpenCode Zen and OpenRouter free ids,
# big-pickle, and an OpenCode launch that names no model or `default`.
# Paid OpenCode, Grok, Codex, and Claude are not free OpenCode models.
for model in opencode/glm-5.3-flash-free opencode/deepseek-v4-free opencode/big-pickle \
  openrouter/deepseek/deepseek-chat-v3:free openrouter/z-ai/glm-4.5-air:free '' default; do
  "$SENS" free-model --harness opencode --model "$model" || fail "OpenCode model '${model}' should be free"
done
"$SENS" free-model --harness opencode --model anthropic/claude-sonnet-4-5 && fail "a paid OpenCode model was treated as free"
"$SENS" free-model --harness grok --model grok-4-free && fail "a Grok model was treated as a free OpenCode model"
"$SENS" free-model --harness codex --model gpt-5 && fail "Codex was treated as a free OpenCode model"
"$SENS" free-model --harness claude --model claude-sonnet-4-5 && fail "Claude was treated as a free OpenCode model"
pass "documented free OpenCode models and a model-less OpenCode launch are free, and paid ones are not"

# mech is the worker handoff. A paid id or a sensitive path never launches.
# A free id launches under the same scrub and read block, prints a diff, and
# puts the worktree back so the caller can review that diff before applying it.
MECH_BIN="$TMP_ROOT/mech-bin"
MECH_LOG="$TMP_ROOT/mech-launch.log"
MECH_REPO="$TMP_ROOT/mech"
mkdir -p "$MECH_BIN"
cat > "$MECH_BIN/opencode" <<EOF
#!/bin/sh
if [ "\$1" != run ]; then
  printf 'Unrecognized: interactive launch %s\n' "\$*" >&2
  exit 1
fi
for arg in "\$@"; do
  [ "\$arg" = --prompt ] && { printf 'Unrecognized flag: --prompt in command opencode run\n' >&2; exit 1; }
done
{
  printf 'argv=%s\n' "\$*"
  if [ -n "\$DOPPLER_TOKEN" ]; then printf 'token=set\n'; else printf 'token=unset\n'; fi
  if [ -n "\$AWS_REGION" ]; then printf 'region=%s\n' "\$AWS_REGION"; else printf 'region=unset\n'; fi
  printf 'config=%s\n' "\$OPENCODE_CONFIG_CONTENT"
  if cat .env >/dev/null 2>&1; then printf 'env=read\n'; else printf 'env=denied\n'; fi
  if [ -f src/wip.ts ] && grep -q WIP src/wip.ts; then printf 'wip=seen\n'; else printf 'wip=missing\n'; fi
  if ls -a | grep -qx .env.local; then printf 'envlocal=copied\n'; else printf 'envlocal=absent\n'; fi
  if [ -f src/staged.ts ]; then printf 'staged-new=seen\n'; else printf 'staged-new=missing\n'; fi
  if [ -e README.md ]; then printf 'readme=present\n'; else printf 'readme=deleted\n'; fi
  if grep -q CALLER-LINE src/app.ts 2>/dev/null; then printf 'caller-line=seen\n'; else printf 'caller-line=missing\n'; fi
} >> "$MECH_LOG"
case "\$*" in *touch-auth*) rm -f src/auth/session.ts ;; esac
printf 'edited\n' >> src/app.ts
printf 'scaffold\n' > src/new-scaffold.ts
git add src/app.ts
git -c user.email=t@example.invalid -c user.name=t commit -qm 'model commit' || printf 'commit=fail\n' >> "$MECH_LOG"
printf 'commit=done\n' >> "$MECH_LOG"
EOF
chmod +x "$MECH_BIN/opencode"
fm_git_init_commit "$MECH_REPO"
mkdir -p "$MECH_REPO/src"
printf 'APP\n' > "$MECH_REPO/src/app.ts"
printf 'ENV\n' > "$MECH_REPO/.env"
mkdir -p "$MECH_REPO/src/auth"
printf 'SESSION\n' > "$MECH_REPO/src/auth/session.ts"
git -C "$MECH_REPO" add -f src/app.ts .env src/auth/session.ts
git -C "$MECH_REPO" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm seed
MECH_HEAD=$(git -C "$MECH_REPO" rev-parse HEAD)

mech_run() {
  local status=0
  MECH_STATUS=0
  MECH_ERR=$TMP_ROOT/mech-err
  MECH_OUT=$(
    cd "$MECH_REPO/${MECH_CWD:-}" && DOPPLER_TOKEN=secret AWS_REGION=us-east-1 HOME="$TREE/home" PATH="$MECH_BIN:$PATH" \
      "$SENS" "$@" 2>"$MECH_ERR"
  ) || status=$?
  MECH_STATUS=$status
}

for _ in $(seq 1 "$COUNT"); do
  SEED=$(( (SEED * 1103515245 + 12345) & 2147483647 ))
  n=$(( SEED % 1000 ))
  for kind in ci migration infra env doppler auth payments; do
    case "$kind" in
      ci) path="svc${n}/.github/workflows/ci.yml" ;;
      migration) path="svc${n}/migrations/001.sql" ;;
      infra) path="svc${n}/infra/main.tf" ;;
      env) path="svc${n}/.env.local" ;;
      doppler) path="svc${n}/doppler.yaml" ;;
      auth) path="svc${n}/auth/session.ts" ;;
      payments) path="svc${n}/payments/charge.ts" ;;
    esac
    rm -f "$MECH_LOG"
    mech_run mech --model opencode/glm-5.3-flash-free --path "$path" -- "rename the counter"
    [ "$MECH_STATUS" -eq 1 ] || fail "seed=$SEED mech launched on a $kind path: $path status=$MECH_STATUS err=$(cat "$MECH_ERR")"
    [ ! -e "$MECH_LOG" ] || fail "seed=$SEED mech launched on a $kind path: $path"
  done
  rm -f "$MECH_LOG"
  mech_run mech --model "opencode/gpt-$n" --path src/app.ts -- "rename the counter"
  [ "$MECH_STATUS" -eq 1 ] || fail "seed=$SEED mech treated opencode/gpt-$n as free"
  [ ! -e "$MECH_LOG" ] || fail "seed=$SEED a paid OpenCode model launched"
  rm -f "$MECH_LOG"
  mech_run mech --model "anthropic/claude-sonnet-$n" --path src/app.ts -- "rename the counter"
  [ "$MECH_STATUS" -eq 1 ] || fail "seed=$SEED mech launched Claude id anthropic/claude-sonnet-$n"
  [ ! -e "$MECH_LOG" ] || fail "seed=$SEED a Claude id launched"
done
rm -f "$MECH_LOG"
mech_run mech --model opencode/big-pickle --path .secrets/token -- "rename the counter"
[ "$MECH_STATUS" -eq 1 ] || fail "mech launched on a secrets path"
[ ! -e "$MECH_LOG" ] || fail "mech launched on a secrets path"
mech_run mech --model opencode/glm-5.3-flash-free -- "rename the counter"
[ "$MECH_STATUS" -eq 2 ] || fail "mech without a path should be a usage error, got $MECH_STATUS"
pass "mech refuses a sensitive path, a paid OpenCode model, and a Claude id without launching"

printf 'DIRTY-MARKER\n' >> "$MECH_REPO/README.md"
git -C "$MECH_REPO" add README.md
rm -f "$MECH_LOG"
MECH_CWD=src mech_run mech --model opencode/glm-5.3-flash-free --path src/app.ts --path src/new-scaffold.ts -- "don't drop the counter"
[ "$MECH_STATUS" -eq 0 ] || fail "mech failed on a free model: status=$MECH_STATUS out=$MECH_OUT err=$(cat "$MECH_ERR")"
[ "$(git -C "$MECH_REPO" diff --cached --name-only)" = README.md ] || fail "mech did not keep the caller's staged edit staged"
[ "$(git -C "$MECH_REPO" worktree list | wc -l)" -eq 1 ] || fail "mech left its scratch worktree registered"
[ "$(git -C "$MECH_REPO" rev-parse HEAD)" = "$MECH_HEAD" ] || fail "mech left the model's commit in place"
grep -q DIRTY-MARKER "$MECH_REPO/README.md" || fail "mech dropped the caller's uncommitted edit"
grep -q edited "$MECH_REPO/src/app.ts" && fail "mech left the model's edit in the worktree"
[ ! -e "$MECH_REPO/src/new-scaffold.ts" ] || fail "mech left the model's new file in the worktree"
assert_contains "$MECH_OUT" "edited" "the printed diff did not contain the model's edit"
assert_not_contains "$MECH_OUT" "DIRTY-MARKER" "the printed diff included the caller's existing edit"
log=$(cat "$MECH_LOG")
assert_contains "$log" "argv=run --standalone" "the free launch was not a non-interactive opencode run"
assert_contains "$log" "--model opencode/glm-5.3-flash-free" "the free launch did not receive its model"
assert_contains "$log" "don't drop the counter" "the free launch did not receive the edit"
assert_contains "$log" "Do not commit" "the free launch did not forbid a commit"
assert_contains "$log" "token=unset" "the free launch kept DOPPLER_TOKEN"
assert_contains "$log" "region=us-east-1" "the free launch stripped an ordinary variable"
assert_contains "$log" "env=denied" "the free launch read .env"
assert_not_contains "$log" "commit=fail" "the stand-in model could not commit, so the restore did not undo one"
assert_contains "$log" 'config={"permission":{"*":"allow"}}' "the free launch did not allow edits"
assert_not_contains "$log" "claude" "the free launch invoked Claude"
(
  cd "$MECH_REPO" && printf '%s\n' "$MECH_OUT" | git apply
) || fail "the caller could not apply the printed diff: $MECH_OUT"
grep -q edited "$MECH_REPO/src/app.ts" || fail "applying the diff did not produce the model's edit"
grep -q scaffold "$MECH_REPO/src/new-scaffold.ts" || fail "applying the diff did not produce the new file"
grep -q DIRTY-MARKER "$MECH_REPO/README.md" || fail "applying the diff disturbed the caller's edit"
pass "mech returns a reviewable diff and leaves the caller's worktree unchanged"

git -C "$MECH_REPO" reset --hard -q "$MECH_HEAD"
git -C "$MECH_REPO" clean -fd -q
rm -f "$MECH_LOG"
mech_run mech --path src/app.ts -- "scaffold a test"
[ "$MECH_STATUS" -eq 0 ] || fail "a model-less mech launch failed: status=$MECH_STATUS out=$MECH_OUT"
log=$(cat "$MECH_LOG")
assert_contains "$log" "--standalone" "a model-less launch did not pin a private server"
assert_not_contains "$log" "--model" "a model-less launch pinned a model"
assert_contains "$MECH_OUT" "edited" "a model-less launch did not return the edit"
assert_not_contains "$MECH_OUT" "new-scaffold.ts" "the diff carried an edit outside the declared paths"
[ "$(git -C "$MECH_REPO" rev-parse HEAD)" = "$MECH_HEAD" ] || fail "a model-less launch left a commit"
grep -q edited "$MECH_REPO/src/app.ts" && fail "a model-less launch left the edit in the worktree"
pass "an OpenCode launch that names no model is a mech handoff and still returns only a diff"

# The caller's own staged edit to the file the model edits, a staged new file,
# a staged deletion, an untracked work file, and an untracked refused file.
# The model sees every caller change except the refused file, which is never copied, and the diff carries only the model's change,
# so git apply onto the caller's current tree succeeds and keeps both edits.
git -C "$MECH_REPO" reset --hard -q "$MECH_HEAD"
git -C "$MECH_REPO" clean -fd -q
printf 'CALLER-LINE\n' >> "$MECH_REPO/src/app.ts"
printf 'STAGED\n' > "$MECH_REPO/src/staged.ts"
git -C "$MECH_REPO" add src/app.ts src/staged.ts
git -C "$MECH_REPO" rm -q README.md
printf 'WIP\n' > "$MECH_REPO/src/wip.ts"
printf 'LOCAL-SECRET\n' > "$MECH_REPO/.env.local"
rm -f "$MECH_LOG"
mech_run mech --model opencode/big-pickle --path src/app.ts -- "rename the counter"
[ "$MECH_STATUS" -eq 0 ] || fail "mech failed over a dirty same-file edit: status=$MECH_STATUS err=$(cat "$MECH_ERR")"
log=$(cat "$MECH_LOG")
assert_contains "$log" "wip=seen" "the model did not see the caller's untracked file"
assert_contains "$log" "caller-line=seen" "the model did not see the caller's staged edit"
assert_contains "$log" "staged-new=seen" "the model did not see the caller's staged new file"
assert_contains "$log" "readme=deleted" "the model saw a file the caller staged for deletion"
assert_contains "$log" "envlocal=absent" "the scratch copy carried the caller's refused .env.local"
assert_contains "$log" "Edit only these paths: src/app.ts" "the declared path did not reach the model"
assert_contains "$MECH_OUT" "+edited" "the diff did not carry the model's edit"
assert_not_contains "$MECH_OUT" "+CALLER-LINE" "the diff carried the caller's own edit"
assert_not_contains "$MECH_OUT" "wip.ts" "the diff carried the caller's untracked file"
assert_not_contains "$MECH_OUT" "LOCAL-SECRET" "the diff carried the refused file"
grep -q edited "$MECH_REPO/src/app.ts" && fail "mech wrote the model's edit into the caller's tree"
grep -q CALLER-LINE "$MECH_REPO/src/app.ts" || fail "mech lost the caller's edit"
(
  cd "$MECH_REPO" && printf '%s\n' "$MECH_OUT" | git apply
) || fail "the diff did not apply onto the caller's current tree: $MECH_OUT"
[ "$(cat "$MECH_REPO/src/app.ts")" = "$(printf 'APP\nCALLER-LINE\nedited')" ] \
  || fail "applying the diff did not keep the caller's edit and add the model's: $(cat "$MECH_REPO/src/app.ts")"
pass "mech runs on the caller's current tree and returns only the model's change"

# A declared directory that holds a protected file passes the path check, but
# the model deleting that file is a change to a refused path, so mech refuses
# the result and prints no diff that names it.
git -C "$MECH_REPO" reset --hard -q "$MECH_HEAD"
git -C "$MECH_REPO" clean -fd -q
mech_run mech --model opencode/big-pickle --path src -- "touch-auth rename the counter"
[ "$MECH_STATUS" -eq 1 ] || fail "mech returned a result that deleted a protected file: status=$MECH_STATUS out=$MECH_OUT"
assert_not_contains "$MECH_OUT" "session.ts" "the diff carried a change to a protected path"
assert_contains "$(cat "$MECH_ERR")" "src/auth/session.ts" "the refusal did not name the protected path"
[ -f "$MECH_REPO/src/auth/session.ts" ] || fail "mech removed the caller's protected file"
pass "mech refuses a result that changes a protected path inside a declared directory"

echo "# all fm-free-model-sensitivity tests passed"
