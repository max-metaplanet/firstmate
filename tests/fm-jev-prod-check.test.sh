#!/usr/bin/env bash
# Tests for bin/fm-jev-prod-check.sh, the opt-in production Jev verdict poll.
#
# The one invariant every case here defends: SILENCE MEANS "nothing to report",
# never "nothing went wrong". A failed forge read, an unparsable comment section
# and a production run that never reported all have to reach firstmate as
# `couldnt-check`, and none of them may ever be read as clean.
#
# Every forge read is a fixture under the test's own fakebin. No case contacts
# GitHub, and the fixtures are built from the shapes core's pinned recorder
# actually renders: upstream's `render()` body, core's `record.mjs` per-app
# section wrappers, and the `context.json` / `records.jsonl` pair every
# `jev-check-records` artifact carries.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-jev-prod-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-jev-prod-check)
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
REPO=metaplanet-jp/core
PR_URL="https://github.com/$REPO/pull/2214"
HEAD_SHA=00b06ecaca454fdd6b2ac15bdcef3099927deb28
MERGE_SHA=a69b2ee0df835823f036e627c7a7d4124d2e5887
TITLE='fix/ENG-2676(db): complete the portal jev-check robot questionnaire'
# The real separators core renders between the metadata fields, and the real
# dash it puts before the verdict. Hard-coded as bytes on purpose: a parser that
# only works against a prettified copy of the comment is not a parser of this
# comment.
SEP=$'·'
DASH=$'—'
NOW=1760000000

make_home() {
  local name=$1 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/state" "$home/config" "$home/fx"
  printf '%s\n' "$home"
}

configure() {  # <home> [extra-directive...]
  local home=$1
  shift
  {
    printf '# the project whose production verdicts this home follows\n'
    printf 'repo:%s\n' "$REPO"
    [ "$#" -eq 0 ] || printf '%s\n' "$@"
  } > "$home/config/jev-prod-monitor"
}

# One app section exactly as core composes it: upstream's rendered body wrapped
# in record.mjs's open/close markers.
section() {  # <app> <verdict> <phase> <environment> <record-id>
  local app=$1 verdict=$2 phase=$3 env=$4 rec=$5
  cat <<EOF
<!-- jev-check-app:$app -->
### $app
**Browser check $DASH $verdict** (advisory; blocks no merge)

$PR_URL
Head \`$HEAD_SHA\` $SEP $phase $SEP $env $SEP navigator \`scripted\`
Plan \`a1b2c3d4e5f6\` by claude:sonnet $SEP record \`$rec\`
Run started 2026-10-16T10:41:58Z, took 42s

| Step | Action | Writes | Outcome | Assertions |
| --- | --- | --- | --- | --- |
| s1 | goto | no | $verdict | reachable $verdict |

Worker action: **none**.
An \`unproven\` step is an observation that could not be read, not a pass.
<!-- /jev-check-app:$app -->
EOF
}

# A skip section, which renders a SHORTER metadata line and no record line.
skip_section() {  # <app> <phase>
  cat <<EOF
<!-- jev-check-app:$1 -->
### $1
**Browser check $DASH skipped** (advisory; blocks no merge)

$PR_URL
Head \`$HEAD_SHA\` $SEP $2

Skipped: the tier could not be established. No plan was generated and no browser opened, so this is not a pass.
<!-- /jev-check-app:$1 -->
EOF
}

# The marker comment carrying the given section text.
write_comments() {  # <home> <pr-number> <comment-id> <section-text>
  local home=$1 number=$2 cid=$3 body
  body=$(printf '<!-- jev-check-browser-v1 -->\n%s\n' "$4")
  jq -n --argjson id "$cid" --arg body "$body" \
    '[{id:$id,user:{login:"github-actions[bot]"},body:$body}]' \
    > "$home/fx/comments-$number.json"
}

# The same comment under a different author, which is what somebody who can
# comment on the pull request is able to write.
write_comments_as() {  # <home> <pr-number> <comment-id> <author> <section-text>
  local home=$1 number=$2 cid=$3 who=$4 body
  body=$(printf '<!-- jev-check-browser-v1 -->\n%s\n' "$5")
  jq -n --argjson id "$cid" --arg who "$who" --arg body "$body" \
    '[{id:$id,user:{login:$who},body:$body}]' \
    > "$home/fx/comments-$number.json"
}

write_no_comments() {  # <home> <pr-number>
  printf '[]\n' > "$1/fx/comments-$2.json"
}

# The merged pull request list, with merged_at placed relative to NOW.
write_pulls() {  # <home> <merged-secs-ago> [title]
  local home=$1 ago=$2 title=${3:-$TITLE} merged
  merged=$(jq -nr --argjson t "$((NOW - ago))" '$t | todateiso8601')
  jq -n --arg url "$PR_URL" --arg head "$HEAD_SHA" --arg merge "$MERGE_SHA" \
    --arg merged "$merged" --arg title "$title" \
    '[{number:2214,html_url:$url,title:$title,merged_at:$merged,
       head:{sha:$head},merge_commit_sha:$merge}]' \
    > "$home/fx/pulls.json"
  jq -n --arg stamp "$merged" '[{id:8001,state:"success",created_at:$stamp}]' > "$home/fx/deployment-statuses.json"
}

# Two merged candidates, so a poll that may read fewer than the whole set has
# something to rotate over.
write_two_pulls() {  # <home>
  local home=$1 merged
  merged=$(jq -nr --argjson t "$((NOW - 7200))" '$t | todateiso8601')
  jq -n --arg base "https://github.com/$REPO/pull" --arg head "$HEAD_SHA" \
    --arg merge "$MERGE_SHA" --arg merged "$merged" --arg title "$TITLE" \
    '[2214,2215] | map({number:.,html_url:"\($base)/\(.)",title:$title,
       merged_at:$merged,head:{sha:$head},merge_commit_sha:$merge})' \
    > "$home/fx/pulls.json"
}

# A pre-merge run plus its jev-check-records artifact, the only place a merged
# PR's preview verdict still exists once production has replaced its section.
write_preview_artifact() {  # <home> <app> <verdict>
  local home=$1 app=$2 verdict=$3 dir
  jq -n --arg head "$HEAD_SHA" '{workflow_runs:[{id:38887740485,head_sha:$head,run_attempt:1,conclusion:"success"}]}' > "$home/fx/runs-$HEAD_SHA.json"
  jq -n '{artifacts:[{id:12040000001,name:"jev-check-records",expired:false}]}' \
    > "$home/fx/artifacts-38887740485.json"
  dir="$home/fx/art-build"
  rm -rf "$dir"; mkdir -p "$dir"
  jq -n --arg app "$app" --arg url "$PR_URL" --arg head "$HEAD_SHA" \
    '{run:true,phase:"pre-merge",app:$app,jevEnv:"qa",
      pr:{url:$url,number:2214,headSha:$head}}' > "$dir/context.json"
  jq -n --arg app "$app" --arg url "$PR_URL" --arg head "$HEAD_SHA" \
    '{app:$app,pr_url:$url,head_sha:$head,input_hash:"fixture-input"}' > "$dir/plan.json"
  mkdir -p "$dir/plan"
  mv "$dir/plan.json" "$dir/plan/plan.json"
  jq -nc --arg v "$verdict" --arg url "$PR_URL" --arg head "$HEAD_SHA" \
    '{event:"check",at:"2026-10-16T09:00:00Z",record:{verdict:$v,phase:"pre-merge",head_sha:$head,pr_url:$url,input_set_hash:"fixture-input"},publish:true}' \
    > "$dir/records.jsonl"
  jq -nc '{event:"delivery",at:"2026-10-16T09:00:01Z",record_id:"x"}' >> "$dir/records.jsonl"
  rm -f "$home/fx/artifact-12040000001.zip"
  (cd "$dir" && zip -q "$home/fx/artifact-12040000001.zip" context.json records.jsonl plan/plan.json)
}

# No pre-merge run at all, so the preview half cannot be established.
write_no_preview_artifact() {  # <home>
  jq -n '{workflow_runs:[]}' > "$1/fx/runs-$HEAD_SHA.json"
}

# A gh that answers only from this home's fixtures, logs its argv, and fails
# exactly where the case asks it to.
fake_gh() {  # <home>
  local home=$1 bin="$1/bin"
  mkdir -p "$bin"
  cat > "$bin/gh" <<EOF
#!/usr/bin/env bash
FX='$home/fx'
printf '%s\n' "\$*" >> "\$FX/gh-argv.log"
[ "\${1:-}" = api ] || exit 1
path=\${2:-}
case "\$path" in
  */pulls\?*)
    [ ! -e "\$FX/fail-pulls" ] || exit 1
    cat "\$FX/pulls.json" ;;
  */issues/*/comments\?*)
    [ ! -e "\$FX/fail-comments" ] || exit 1
    n=\${path#*/issues/}; n=\${n%%/*}
    cat "\$FX/comments-\$n.json" ;;
  */actions/workflows/jev-check.yml/runs\?head_sha=*)
    [ ! -e "\$FX/fail-runs" ] || exit 1
    s=\${path#*head_sha=}; s=\${s%%&*}
    cat "\$FX/runs-\$s.json" ;;
  */actions/runs/*/artifacts)
    r=\${path#*/actions/runs/}; r=\${r%/artifacts}
    cat "\$FX/artifacts-\$r.json" ;;
  */actions/artifacts/*/zip)
    a=\${path#*/actions/artifacts/}; a=\${a%/zip}
    cat "\$FX/artifact-\$a.zip" ;;
  */deployments\?*)
    [ ! -e "\$FX/fail-deployments" ] || exit 1
    if [ -f "\$FX/deployments.json" ]; then cat "\$FX/deployments.json"; else
      printf '[{"id":7001,"sha":"$MERGE_SHA","environment":"Production – core-metaplanet","created_at":"2025-10-09T06:53:20Z"}]'; fi ;;
  */deployments/*/statuses\?*)
    d=\${path#*/deployments/}; d=\${d%%/*}
    if [ -f "\$FX/deployment-statuses-\$d.json" ]; then cat "\$FX/deployment-statuses-\$d.json"; elif [ -f "\$FX/deployment-statuses.json" ]; then cat "\$FX/deployment-statuses.json"; else
      printf '[{"id":8001,"state":"success","created_at":"2025-10-09T06:53:20Z"}]'; fi ;;
  */commits/*/status)
    if [ -f "\$FX/statuses.json" ]; then cat "\$FX/statuses.json"; else printf '{"statuses":[]}'; fi ;;
  *) exit 1 ;;
esac
EOF
  chmod +x "$bin/gh"
  printf '%s\n' "$bin"
}

# One poll of a prepared home.
poll() {  # <home> [env-assignment...]
  local home=$1 bin
  shift
  bin="$home/bin"
  env PATH="$bin:$PATH" FM_HOME="$home" FM_JEV_PROD_NOW="$NOW" "$@" "$CHECK" check 2>&1
}

test_help_and_usage() {
  local out
  out=$("$CHECK" --help)
  expect_code 0 "$?" "--help must succeed"
  assert_contains "$out" "fm-jev-prod-check.sh arm" "help must name arm"
  assert_contains "$out" "config/jev-prod-monitor" "help must name the opt-in config"

  out=$("$CHECK" frobnicate 2>&1)
  expect_code 2 "$?" "an unknown action must be refused"
  pass "fm-jev-prod-check: help prints and an unknown action is refused"
}

test_unconfigured_home_is_silent_and_spends_nothing() {
  local home out
  home=$(make_home unconfigured)
  fake_gh "$home" >/dev/null
  out=$(poll "$home")
  expect_code 0 "$?" "an unconfigured poll must succeed"
  assert_equals "" "$out" "an unconfigured home must print nothing"
  assert_absent "$home/fx/gh-argv.log" "an unconfigured home must not contact the forge at all"
  assert_absent "$home/state/.jev-prod-monitor" "an unconfigured home must not write a dedupe record"
  pass "fm-jev-prod-check: an unconfigured home runs no check and spends nothing"
}

test_config_parsing_and_arm_refusals() {
  local home out
  home=$(make_home config-parse)
  fake_gh "$home" >/dev/null

  printf '%s\n' '# only a comment' '' >> "$home/config/jev-prod-monitor"
  out=$(env FM_HOME="$home" "$CHECK" arm 2>&1)
  expect_code 1 "$?" "arm must refuse a config with no repository"
  assert_contains "$out" "no repository configured" "the refusal must name the missing repository"

  printf 'repo:not a slug\n' > "$home/config/jev-prod-monitor"
  out=$(env FM_HOME="$home" "$CHECK" arm 2>&1)
  expect_code 1 "$?" "arm must refuse an invalid repository slug"
  assert_contains "$out" "invalid repo" "the refusal must name the invalid slug"

  printf 'repo:%s\nrepo:other/thing\n' "$REPO" > "$home/config/jev-prod-monitor"
  out=$(env FM_HOME="$home" "$CHECK" arm 2>&1)
  expect_code 1 "$?" "arm must refuse two repo directives rather than picking one"
  assert_contains "$out" "more than one repo" "the refusal must say which directive is ambiguous"

  configure "$home" 'lookback-hours:0'
  out=$(env FM_HOME="$home" "$CHECK" arm 2>&1)
  expect_code 1 "$?" "arm must refuse an out-of-range lookback"
  assert_contains "$out" "lookback-hours must be 1..336" "the refusal must state the range"

  # A valid config with comments, blank lines and surrounding whitespace parses.
  printf '%s\n' '' '# watched project' "  repo: $REPO  " 'lookback-hours: 72' 'unknown-key:ignored' \
    > "$home/config/jev-prod-monitor"
  write_pulls "$home" 999999999
  out=$(poll "$home")
  expect_code 0 "$?" "a valid config must poll cleanly"
  assert_grep "pulls?state=closed" "$home/fx/gh-argv.log" "a configured home must read the merged pull requests"
  pass "fm-jev-prod-check: the config parses comments and whitespace and refuses every ambiguous directive"
}

test_clean_production_verdict_is_silent_and_settled() {
  local home out
  home=$(make_home clean)
  configure "$home"
  fake_gh "$home" >/dev/null
  write_pulls "$home" 7200
  write_comments "$home" 2214 900001 "$(section portal proven post-merge production 0c1ea0000001)"

  out=$(poll "$home")
  expect_code 0 "$?" "a clean poll must succeed"
  assert_equals "" "$out" "a clean production verdict must wake nobody"
  assert_grep "woken	2214/portal/0c1ea0000001" "$home/state/.jev-prod-monitor" \
    "a clean verdict must be recorded under its own run key"
  assert_equals 1 "$(grep -c '^woken	' "$home/state/.jev-prod-monitor")" \
    "the record must hold exactly one key, with no blank entry beside it"

  # A second poll re-reads the comment - cheaply, and on purpose, so a later
  # production redeploy can still wake - and the key keeps it silent.
  out=$(poll "$home")
  assert_equals "" "$out" "an already-woken verdict must stay silent on a re-poll"
  assert_equals 1 "$(grep -c '^woken	' "$home/state/.jev-prod-monitor")" \
    "a re-poll must not duplicate the key"
  pass "fm-jev-prod-check: a clean production verdict is recorded under its run key and wakes nobody"
}

test_regression_wakes_immediately_with_its_evidence() {
  local home out
  home=$(make_home regression)
  configure "$home"
  fake_gh "$home" >/dev/null
  write_pulls "$home" 7200
  write_comments "$home" 2214 900002 "$(section portal failed post-merge production fa11ed000001)"
  write_preview_artifact "$home" portal proven

  out=$(poll "$home")
  expect_code 0 "$?" "a regression poll must succeed"
  assert_equals 1 "$(printf '%s\n' "$out" | grep -c .)" "a wake must be exactly one line"
  assert_contains "$out" "jev-prod: regression" "the line must carry the class"
  assert_contains "$out" "pr=$PR_URL" "the line must carry the full PR URL"
  assert_contains "$out" "ticket=ENG-2676" "the line must carry the ticket parsed from the title"
  assert_contains "$out" "app=portal" "the line must name the app"
  assert_contains "$out" "production=failed" "the line must carry the production verdict"
  assert_contains "$out" "preview=proven" "the line must carry the paired preview verdict"
  assert_contains "$out" "comment=$PR_URL#issuecomment-900002" "the line must link the verdict comment"
  assert_contains "$out" "checks=https://github.com/$REPO/commit/$MERGE_SHA/checks" \
    "the line must link the production deployment's checks"
  assert_contains "$out" "preview-run=https://github.com/$REPO/actions/runs/38887740485" \
    "the line must link the run the preview verdict came from"
  pass "fm-jev-prod-check: a regression wakes on the poll that finds it, with its class, PR, ticket and evidence"
}

test_still_flagged_batches_until_the_window_elapses() {
  local home out
  home=$(make_home still-flagged)
  configure "$home"
  fake_gh "$home" >/dev/null
  write_pulls "$home" 7200
  write_comments "$home" 2214 900003 "$(section portal failed post-merge production 5111fa000001)"
  write_preview_artifact "$home" portal failed

  out=$(poll "$home")
  assert_equals "" "$out" "a still-flagged verdict must not wake inside the batch window"
  assert_grep "pending	$NOW	still-flagged" "$home/state/.jev-prod-monitor" \
    "the verdict must be held as pending with its first-seen time"

  # A later poll, still inside the window, stays quiet and does not re-queue it.
  out=$(env PATH="$home/bin:$PATH" FM_HOME="$home" FM_JEV_PROD_NOW="$((NOW + 60))" "$CHECK" check 2>&1)
  assert_equals "" "$out" "the batch must stay quiet until its window elapses"
  assert_equals 1 "$(grep -c '^pending	' "$home/state/.jev-prod-monitor")" \
    "a re-poll must not queue the same verdict twice"

  # Past the window it goes out as one line and the batch is cleared.
  out=$(env PATH="$home/bin:$PATH" FM_HOME="$home" FM_JEV_PROD_NOW="$((NOW + 21700))" "$CHECK" check 2>&1)
  assert_equals 1 "$(printf '%s\n' "$out" | grep -c .)" "a due batch must be exactly one line"
  assert_contains "$out" "still-flagged" "the batch must carry the class"
  assert_contains "$out" "pr=$PR_URL" "the batch must carry the full PR URL"
  assert_contains "$out" "preview=failed" "the batch must show the preview was already flagged"
  if grep -q '^pending	' "$home/state/.jev-prod-monitor"; then
    fail "a delivered batch must be cleared"
  fi
  pass "fm-jev-prod-check: a still-flagged verdict batches, stays quiet in the window, and goes out once"
}

test_unestablished_preview_is_couldnt_check_not_clean() {
  local home out
  home=$(make_home no-preview)
  configure "$home"
  fake_gh "$home" >/dev/null
  write_pulls "$home" 7200
  write_comments "$home" 2214 900004 "$(section portal unproven post-merge production 11590e000001)"
  write_no_preview_artifact "$home"

  out=$(env PATH="$home/bin:$PATH" FM_HOME="$home" FM_JEV_PROD_NOW="$((NOW))" "$CHECK" check 2>&1)
  assert_equals "" "$out" "an unpaired verdict batches rather than waking at once"
  assert_grep "couldnt-check" "$home/state/.jev-prod-monitor" \
    "a production problem with no establishable preview must be couldnt-check"
  out=$(env PATH="$home/bin:$PATH" FM_HOME="$home" FM_JEV_PROD_NOW="$((NOW + 21700))" "$CHECK" check 2>&1)
  assert_contains "$out" "production=unproven" "the batch must still carry the production verdict"
  assert_contains "$out" "preview=unknown" "the batch must say the preview could not be established"
  pass "fm-jev-prod-check: a production problem whose preview cannot be read is couldnt-check, never clean"
}

test_a_production_run_that_never_reported_is_couldnt_check() {
  local home out
  home=$(make_home no-production)
  configure "$home"
  fake_gh "$home" >/dev/null
  # Merged well past the grace, and the comment still shows only the preview.
  write_pulls "$home" 7200
  write_comments "$home" 2214 900005 "$(section portal proven pre-merge qa 09e1e0000001)"

  # Past the grace it is queued as a batched class, and goes out once its own
  # window has elapsed.
  out=$(env PATH="$home/bin:$PATH" FM_HOME="$home" FM_JEV_PROD_NOW="$((NOW + 21700))" "$CHECK" check 2>&1)
  assert_equals "" "$out" "a late production verdict batches rather than waking at once"
  out=$(env PATH="$home/bin:$PATH" FM_HOME="$home" FM_JEV_PROD_NOW="$((NOW + 43400))" "$CHECK" check 2>&1)
  assert_contains "$out" "couldnt-check" "a missing production verdict past the grace must be reported"
  assert_contains "$out" "production=none" "the line must say production never reported"
  assert_contains "$out" "preview=proven" "the line must carry the preview verdict that did report"
  assert_no_grep "clean" "$home/state/.jev-prod-monitor" \
    "a pull request with no production verdict must never be recorded as clean"
  pass "fm-jev-prod-check: a production run that never reported is couldnt-check, not a settled pass"
}

test_within_the_grace_a_missing_production_verdict_is_not_late() {
  local home out
  home=$(make_home grace)
  configure "$home"
  fake_gh "$home" >/dev/null
  write_pulls "$home" 60
  write_comments "$home" 2214 900006 "$(section portal proven pre-merge qa 09e1e0000002)"

  out=$(poll "$home")
  assert_equals "" "$out" "a production run still inside its grace is not late"
  pass "fm-jev-prod-check: a production verdict still inside its grace window reports nothing"
}

test_skipped_production_verdict_is_not_a_pass() {
  local home out
  home=$(make_home skipped)
  configure "$home"
  fake_gh "$home" >/dev/null
  write_pulls "$home" 7200
  write_comments "$home" 2214 900007 "$(skip_section portal post-merge)"
  write_preview_artifact "$home" portal proven

  out=$(poll "$home")
  assert_equals "" "$out" "a skipped production run is a non-answer that batches, not a regression that wakes at once"
  assert_grep "woken	2214/portal/" "$home/state/.jev-prod-monitor" \
    "the skip must be recorded so it is never re-queued"
  out=$(env PATH="$home/bin:$PATH" FM_HOME="$home" FM_JEV_PROD_NOW="$((NOW + 21700))" "$CHECK" check 2>&1)
  assert_equals 1 "$(printf '%s\n' "$out" | grep -c .)" "a skipped production run must go out as one line"
  assert_contains "$out" "jev-prod: couldnt-check" "a skip after a proven preview is a production non-answer, never a pass"
  assert_contains "$out" "production=skipped" "the line must carry the skip as the production verdict"
  pass "fm-jev-prod-check: a skipped production run is couldnt-check, never read as a pass"
}

test_a_skipped_preview_never_makes_a_failure_still_flagged() {
  local home out
  home=$(make_home skipped-preview)
  configure "$home"
  fake_gh "$home" >/dev/null
  write_pulls "$home" 7200
  write_comments "$home" 2214 900021 "$(section portal failed post-merge production 5c1a9e000001)"
  write_preview_artifact "$home" portal skipped

  out=$(poll "$home")
  assert_equals "" "$out" "a failure paired with a skipped preview batches rather than waking at once"
  out=$(env PATH="$home/bin:$PATH" FM_HOME="$home" FM_JEV_PROD_NOW="$((NOW + 21700))" "$CHECK" check 2>&1)
  assert_contains "$out" "jev-prod: couldnt-check" "a skipped preview never flagged anything, so the pairing is a non-answer"
  assert_contains "$out" "production=failed" "the line must carry the production failure"
  assert_contains "$out" "preview=skipped" "the line must carry the skipped preview"
  pass "fm-jev-prod-check: a skipped preview paired with a production failure is couldnt-check, never still-flagged"
}

test_unparsable_section_is_couldnt_check() {
  local home out body
  home=$(make_home unparsable)
  configure "$home"
  fake_gh "$home" >/dev/null
  write_pulls "$home" 7200
  body=$(printf '%s\n' '<!-- jev-check-app:portal -->' '### portal' \
    'the recorder rendered something this parser has never seen' \
    '<!-- /jev-check-app:portal -->')
  write_comments "$home" 2214 900008 "$body"

  out=$(env PATH="$home/bin:$PATH" FM_HOME="$home" FM_JEV_PROD_NOW="$NOW" "$CHECK" check 2>&1)
  assert_equals "" "$out" "an unparsable section batches rather than waking at once"
  out=$(env PATH="$home/bin:$PATH" FM_HOME="$home" FM_JEV_PROD_NOW="$((NOW + 21700))" "$CHECK" check 2>&1)
  assert_contains "$out" "couldnt-check" "an unparsable section must reach firstmate"
  assert_grep "2214/portal/unparsed" "$home/state/.jev-prod-monitor" \
    "an unparsable section must be recorded under its own key so it reports once"
  pass "fm-jev-prod-check: a section this parser cannot read is couldnt-check, never clean"
}

test_gh_failure_is_reported_once_and_never_as_clean() {
  local home out
  home=$(make_home gh-fail)
  configure "$home"
  fake_gh "$home" >/dev/null
  write_pulls "$home" 7200
  touch "$home/fx/fail-pulls"

  out=$(poll "$home")
  expect_code 0 "$?" "a failed read must not fail the check"
  assert_equals 1 "$(printf '%s\n' "$out" | grep -c .)" "a failed read must report exactly one line"
  assert_contains "$out" "jev-prod: couldnt-check" "a failed read must be couldnt-check"
  assert_contains "$out" "could not be read" "the line must name what could not be read"

  out=$(poll "$home")
  assert_equals "" "$out" "a standing failure must be reported once, not on every poll"

  # When the read starts working again the episode ends, and a later failure
  # speaks again rather than being swallowed by the old record.
  rm -f "$home/fx/fail-pulls"
  out=$(poll "$home")
  assert_equals "" "$out" "a recovered read with nothing to report must be silent"
  touch "$home/fx/fail-pulls"
  out=$(poll "$home")
  assert_contains "$out" "couldnt-check" "a failure after a recovery must be reported again"
  pass "fm-jev-prod-check: a forge failure is couldnt-check, reported once per episode, and never silence"
}

test_missing_tool_is_reported_and_arm_refuses() {
  local home out bin
  home=$(make_home no-gh)
  configure "$home"
  # A curated PATH that resolves everything this script needs EXCEPT gh. A plain
  # empty fakebin would not do: the host's own gh on BASE_PATH would still
  # resolve and the simulation would quietly not simulate anything.
  bin=$(fm_test_base_path_sans "$BASE_PATH" gh)
  out=$(env PATH="$bin" FM_HOME="$home" FM_JEV_PROD_NOW="$NOW" "$CHECK" check 2>&1)
  expect_code 0 "$?" "a missing tool must not fail the check"
  assert_contains "$out" "couldnt-check" "a missing tool must reach firstmate as couldnt-check"
  assert_contains "$out" "gh is not installed" "the line must name the missing tool"

  out=$(env PATH="$bin" FM_HOME="$home" "$CHECK" arm 2>&1)
  expect_code 1 "$?" "arm must refuse without the tools the poll needs"
  assert_contains "$out" "gh is required" "the refusal must name the tool it needs"
  pass "fm-jev-prod-check: a missing tool is reported as couldnt-check and refuses arming"
}

test_a_title_outside_the_pattern_carries_no_ticket() {
  local home out
  home=$(make_home no-ticket)
  configure "$home"
  fake_gh "$home" >/dev/null
  write_pulls "$home" 7200 'Revert "something that landed badly"'
  write_comments "$home" 2214 900009 "$(section portal failed post-merge production 0acce7000001)"
  write_preview_artifact "$home" portal proven

  out=$(poll "$home")
  assert_contains "$out" "ticket=none" "a title outside the pattern must carry no ticket rather than a guess"
  assert_contains "$out" "jev-prod: regression" "the verdict is still classified without a ticket"
  pass "fm-jev-prod-check: a PR title outside the ticket pattern carries no ticket, never a guessed one"
}

test_each_app_section_is_classified_on_its_own() {
  local home out
  home=$(make_home two-apps)
  configure "$home"
  fake_gh "$home" >/dev/null
  write_pulls "$home" 7200
  write_comments "$home" 2214 900010 "$(printf '%s\n\n%s\n' \
    "$(section portal proven post-merge production 00c1ea000001)" \
    "$(section admin-center failed post-merge production ad1fa1000001)")"
  # Only the admin-center app has a pre-merge run, and it came back proven.
  write_preview_artifact "$home" admin-center proven

  out=$(poll "$home")
  assert_contains "$out" "app=admin-center" "the flagged app must be the one reported"
  assert_contains "$out" "jev-prod: regression" "the flagged app must be classified on its own"
  if printf '%s' "$out" | grep -q 'app=portal'; then
    fail "the clean app must not be reported alongside the flagged one"
  fi
  assert_grep "woken	2214/portal/00c1ea000001" "$home/state/.jev-prod-monitor" \
    "the clean app must still be recorded"
  pass "fm-jev-prod-check: each app section is paired and classified on its own"
}

test_no_marker_comment_is_not_a_verdict_to_chase() {
  local home out
  home=$(make_home no-marker)
  configure "$home"
  fake_gh "$home" >/dev/null
  write_pulls "$home" 7200
  write_no_comments "$home" 2214

  out=$(env PATH="$home/bin:$PATH" FM_HOME="$home" FM_JEV_PROD_NOW="$((NOW + 21700))" "$CHECK" check 2>&1)
  assert_equals "" "$out" "a pull request this lane never ran on is not a verdict to chase"
  pass "fm-jev-prod-check: a pull request with no jev-check comment reports nothing"
}

test_a_marker_comment_from_another_author_is_not_a_verdict() {
  local home out
  home=$(make_home spoofed)
  configure "$home"
  fake_gh "$home" >/dev/null
  write_pulls "$home" 7200
  # Anybody who can comment on the pull request can write the marker, and the
  # EARLIEST marker comment is the one upstream keeps - so a comment posted by
  # somebody else must not be able to stand in for the recorder's verdict.
  write_comments_as "$home" 2214 900020 drive-by \
    "$(section portal proven post-merge production 5900fed00001)"

  out=$(env PATH="$home/bin:$PATH" FM_HOME="$home" FM_JEV_PROD_NOW="$((NOW + 21700))" "$CHECK" check 2>&1)
  assert_equals "" "$out" "a verdict nobody authoritative posted is no verdict at all"
  assert_no_grep "5900fed00001" "$home/state/.jev-prod-monitor" \
    "a spoofed verdict must never be recorded as seen, let alone as clean"
  pass "fm-jev-prod-check: a marker comment from another author is not a verdict"
}

test_the_recorder_identity_is_configurable() {
  local home out
  home=$(make_home recorder-login)
  configure "$home" 'recorder-login:other-bot[bot]'
  fake_gh "$home" >/dev/null
  write_pulls "$home" 7200
  write_comments_as "$home" 2214 900021 'other-bot[bot]' \
    "$(section portal failed post-merge production 0f1e40000001)"
  write_preview_artifact "$home" portal proven

  out=$(poll "$home")
  assert_contains "$out" "jev-prod: regression" "a project that renamed its recorder must still be readable"

  configure "$home" 'recorder-login:not a login'
  out=$(env FM_HOME="$home" "$CHECK" arm 2>&1)
  expect_code 1 "$?" "arm must refuse a recorder login outside a forge login's shape"
  assert_contains "$out" "invalid recorder-login" "the refusal must name the bad directive"
  pass "fm-jev-prod-check: the recorder identity is configurable and bounded"
}

test_an_artifact_verdict_outside_the_vocabulary_is_not_established() {
  local home out dir
  home=$(make_home bad-artifact)
  configure "$home"
  fake_gh "$home" >/dev/null
  write_pulls "$home" 7200
  write_comments "$home" 2214 900022 "$(section portal failed post-merge production 0bad00000001)"
  write_preview_artifact "$home" portal proven
  # An artifact is whatever a run uploaded. Rewrite its verdict to something
  # that is not one of the recorder's words and carries separators of its own:
  # the wake is ONE line and the record is tab-separated.
  dir="$home/fx/art-build"
  jq -nc '{event:"check",at:"2026-10-16T09:00:00Z",
           record:{verdict:"proven\nwoken\t2214/portal/forged",phase:"pre-merge"}}' \
    > "$dir/records.jsonl"
  rm -f "$home/fx/artifact-12040000001.zip"
  (cd "$dir" && zip -q "$home/fx/artifact-12040000001.zip" context.json records.jsonl plan/plan.json)

  out=$(poll "$home")
  assert_equals "" "$out" "it batches rather than waking at once"
  out=$(env PATH="$home/bin:$PATH" FM_HOME="$home" FM_JEV_PROD_NOW="$((NOW + 21700))" "$CHECK" check 2>&1)
  assert_contains "$out" "couldnt-check" "an artifact verdict outside the vocabulary must not be trusted"
  assert_contains "$out" "preview=unknown" "it must read as not established rather than as a preview"
  assert_equals 1 "$(printf '%s\n' "$out" | grep -c .)" "nothing from an artifact may add a second line"
  assert_no_grep "forged" "$home/state/.jev-prod-monitor" \
    "nothing from an artifact may write a record of its own"
  pass "fm-jev-prod-check: an artifact verdict outside the recorder's vocabulary is not established"
}

test_a_comment_verdict_outside_the_vocabulary_is_couldnt_check() {
  local home out
  home=$(make_home bad-verdict)
  configure "$home"
  fake_gh "$home" >/dev/null
  write_pulls "$home" 7200
  write_comments "$home" 2214 900023 "$(section portal excellent post-merge production 0bad00000002)"

  out=$(poll "$home")
  assert_equals "" "$out" "it batches rather than waking at once"
  out=$(env PATH="$home/bin:$PATH" FM_HOME="$home" FM_JEV_PROD_NOW="$((NOW + 21700))" "$CHECK" check 2>&1)
  assert_contains "$out" "couldnt-check" "a word that is not one of the recorder's verdicts must not be read as one"
  pass "fm-jev-prod-check: a comment verdict outside the recorder's vocabulary is couldnt-check"
}

test_a_truncated_comment_inventory_is_couldnt_check() {
  local home out
  home=$(make_home truncated)
  configure "$home"
  fake_gh "$home" >/dev/null
  write_pulls "$home" 7200
  # A full page of comments and no marker on it: the verdict may be sitting on a
  # page this poll never read, so "no comment" is not an answer here.
  jq -n '[range(100) | {id:(6000000 + .),user:{login:"somebody"},body:"chatter"}]' \
    > "$home/fx/comments-2214.json"

  out=$(env PATH="$home/bin:$PATH" FM_HOME="$home" FM_JEV_PROD_NOW="$NOW" "$CHECK" check 2>&1)
  assert_equals "" "$out" "a truncated inventory batches rather than waking at once"
  out=$(env PATH="$home/bin:$PATH" FM_HOME="$home" FM_JEV_PROD_NOW="$((NOW + 21700))" "$CHECK" check 2>&1)
  assert_contains "$out" "couldnt-check" "a possibly truncated comment inventory must reach firstmate"
  assert_contains "$out" "pr=$PR_URL" "the line must carry the pull request it could not read"
  pass "fm-jev-prod-check: a comment inventory that may be truncated is couldnt-check, never silence"
}

test_a_pull_request_outside_the_lookback_is_not_examined() {
  local home out
  home=$(make_home lookback)
  configure "$home" 'lookback-hours:1'
  fake_gh "$home" >/dev/null
  write_pulls "$home" 7200
  write_comments "$home" 2214 900011 "$(section portal failed post-merge production 01dd00000001)"
  write_preview_artifact "$home" portal proven

  out=$(poll "$home")
  assert_equals "" "$out" "a pull request merged outside the lookback must not be examined"
  if grep -q 'issues/2214/comments' "$home/fx/gh-argv.log"; then
    fail "a pull request outside the lookback must cost no forge read"
  fi
  pass "fm-jev-prod-check: the lookback bounds which merged pull requests are examined"
}

test_arm_writes_and_binds_the_check_and_disarm_removes_it() {
  local home out shim
  home=$(make_home arm)
  configure "$home"
  fake_gh "$home" >/dev/null
  shim="$home/state/jev-prod-monitor.check.sh"

  out=$(env PATH="$home/bin:$PATH" FM_HOME="$home" "$CHECK" arm 2>&1)
  expect_code 0 "$?" "arm must succeed for a configured home with its tools"
  assert_contains "$out" "armed: state/jev-prod-monitor.check.sh" "arm must say what it armed"
  assert_present "$shim" "arm must write the shim"
  assert_present "$home/state/jev-prod-monitor.check-trust" "arm must bind the shim's bytes"
  [ "$(stat -c %a "$shim" 2>/dev/null || stat -f %Lp "$shim")" = 700 ] \
    || fail "the shim must be mode 0700"
  assert_grep "fm-jev-prod-check.sh" "$shim" "the shim must dispatch the trusted script"
  assert_grep "export FM_HOME=" "$shim" "the shim must carry its home resolved"

  # The watcher only runs a shim whose bytes still match their binding.
  env FM_HOME="$home" bash -c '
    . "'"$ROOT"'/bin/fm-pr-lib.sh"
    . "'"$ROOT"'/bin/fm-check-lib.sh"
    fm_custom_check_registered "'"$home"'/state" jev-prod-monitor' \
    || fail "the armed shim must read back as registered"

  out=$(env FM_HOME="$home" "$CHECK" disarm 2>&1)
  expect_code 0 "$?" "disarm must succeed"
  assert_absent "$shim" "disarm must remove the shim"
  assert_absent "$home/state/jev-prod-monitor.check-trust" "disarm must remove the trust binding"
  assert_absent "$home/state/.jev-prod-monitor" "disarm must remove the dedupe record"

  out=$(env FM_HOME="$home" "$CHECK" disarm 2>&1)
  expect_code 0 "$?" "disarming something never armed must be a clean no-op"
  pass "fm-jev-prod-check: arm writes and binds the shim and disarm removes every trace"
}

test_armed_shim_runs_a_real_check() {
  local home out
  home=$(make_home armed-run)
  configure "$home"
  fake_gh "$home" >/dev/null
  write_pulls "$home" 7200
  write_comments "$home" 2214 900012 "$(section portal failed post-merge production 5b1a00000001)"
  write_preview_artifact "$home" portal proven

  env PATH="$home/bin:$PATH" FM_HOME="$home" "$CHECK" arm >/dev/null \
    || fail "arm must succeed before the shim can be run"
  out=$(env PATH="$home/bin:$PATH" FM_JEV_PROD_NOW="$NOW" bash "$home/state/jev-prod-monitor.check.sh" 2>&1)
  assert_contains "$out" "jev-prod: regression" "the armed shim must produce the same line the script does"
  pass "fm-jev-prod-check: the armed shim runs the real check against its own home"
}

test_more_candidates_than_one_poll_reads_are_rotated() {
  local home read_a read_b
  home=$(make_home rotation)
  configure "$home"
  fake_gh "$home" >/dev/null
  write_two_pulls "$home"
  write_comments "$home" 2214 900014 "$(section portal proven post-merge production 0c1ea0000014)"
  write_comments "$home" 2215 900015 "$(section portal proven post-merge production 0c1ea0000015)"

  # One pull request per poll, and two waiting: consecutive ten-minute buckets
  # must not keep reading the same one, or the other would never be examined.
  : > "$home/fx/gh-argv.log"
  env PATH="$home/bin:$PATH" FM_HOME="$home" FM_JEV_PROD_NOW="$NOW" \
    FM_JEV_PROD_MAX_PRS=1 "$CHECK" check >/dev/null 2>&1
  read_a=$(grep -c 'issues/2214/comments' "$home/fx/gh-argv.log" || true)

  : > "$home/fx/gh-argv.log"
  env PATH="$home/bin:$PATH" FM_HOME="$home" FM_JEV_PROD_NOW="$((NOW + 600))" \
    FM_JEV_PROD_MAX_PRS=1 "$CHECK" check >/dev/null 2>&1
  read_b=$(grep -c 'issues/2214/comments' "$home/fx/gh-argv.log" || true)

  assert_equals 1 "$(( read_a + read_b ))" \
    "two consecutive buckets must examine two different pull requests, not the same one twice"
  assert_grep "woken	" "$home/state/.jev-prod-monitor" "each examined verdict must be recorded"
  pass "fm-jev-prod-check: more candidates than one poll reads are rotated so none is starved"
}

test_a_rotation_bucket_advances_by_a_whole_window() {
  local home merged read_a read_b overlap
  home=$(make_home rotation-window)
  configure "$home"
  fake_gh "$home" >/dev/null
  merged=$(jq -nr --argjson t "$((NOW - 7200))" '$t | todateiso8601')
  jq -n --arg base "https://github.com/$REPO/pull" --arg head "$HEAD_SHA" \
    --arg merge "$MERGE_SHA" --arg merged "$merged" --arg title "$TITLE" \
    '[2214,2215,2216,2217,2218,2219] | map({number:.,html_url:"\($base)/\(.)",title:$title,
       merged_at:$merged,head:{sha:$head},merge_commit_sha:$merge})' \
    > "$home/fx/pulls.json"

  # Six waiting and two read per poll: the next bucket must read the next two,
  # not slide over by one and re-read half of what the last bucket already read.
  : > "$home/fx/gh-argv.log"
  env PATH="$home/bin:$PATH" FM_HOME="$home" FM_JEV_PROD_NOW="$NOW" \
    FM_JEV_PROD_MAX_PRS=2 "$CHECK" check >/dev/null 2>&1
  read_a=$(sed -n 's|.*issues/\([0-9]*\)/comments.*|\1|p' "$home/fx/gh-argv.log" | sort)

  : > "$home/fx/gh-argv.log"
  env PATH="$home/bin:$PATH" FM_HOME="$home" FM_JEV_PROD_NOW="$((NOW + 600))" \
    FM_JEV_PROD_MAX_PRS=2 "$CHECK" check >/dev/null 2>&1
  read_b=$(sed -n 's|.*issues/\([0-9]*\)/comments.*|\1|p' "$home/fx/gh-argv.log" | sort)

  assert_equals 2 "$(printf '%s\n' "$read_a" | grep -c .)" "the first bucket must read a full window"
  assert_equals 2 "$(printf '%s\n' "$read_b" | grep -c .)" "the next bucket must read a full window"
  overlap=$(printf '%s\n%s\n' "$read_a" "$read_b" | sort | uniq -d)
  assert_equals "" "$overlap" "consecutive buckets must read disjoint windows"
  pass "fm-jev-prod-check: each rotation bucket advances by a whole window of pull requests"
}

test_a_long_batch_carries_every_verdict_uncut() {
  local home out app body=''
  home=$(make_home long-batch)
  configure "$home"
  fake_gh "$home" >/dev/null
  write_pulls "$home" 7200
  for app in portal admin-center investor-hub shareholder-desk treasury-board; do
    body="${body}$(section "$app" failed post-merge production "${app:0:4}00000001")

"
  done
  write_comments "$home" 2214 900020 "$body"
  write_no_preview_artifact "$home"

  out=$(poll "$home")
  assert_equals "" "$out" "unpaired verdicts batch rather than waking at once"
  out=$(env PATH="$home/bin:$PATH" FM_HOME="$home" FM_JEV_PROD_NOW="$((NOW + 21700))" "$CHECK" check 2>&1)
  assert_equals 1 "$(printf '%s\n' "$out" | grep -c .)" "a due batch must be exactly one line"
  assert_contains "$out" "5 verdicts" "the batch must count every verdict"
  for app in portal admin-center investor-hub shareholder-desk treasury-board; do
    assert_contains "$out" "app=$app " "every batched verdict must reach firstmate, including $app"
  done
  if printf '%s' "$out" | grep -q '\[truncated\]'; then
    fail "a batch whose verdicts are already settled must never be cut"
  fi
  pass "fm-jev-prod-check: a long batch carries every verdict it settles, uncut"
}

# Wrap a home's fake gh so a read matching <pattern> logs itself and then hangs
# past the read bound, spending the whole read budget: only the first such read
# with `once`, every one with `always`.
slow_gh() {  # <home> <case-pattern> <once|always>
  local home=$1 bin="$1/bin" consume=
  [ "$3" = always ] || consume="rm -f '$home/fx/slow-read'"
  mv "$bin/gh" "$bin/gh-fixture"
  cat > "$bin/gh" <<EOF
#!/usr/bin/env bash
case "\$*" in
  $2)
    if [ -e '$home/fx/slow-read' ]; then
      $consume
      printf '%s\n' "\$*" >> '$home/fx/gh-argv.log'
      sleep 4
      exit 1
    fi ;;
esac
exec '$bin/gh-fixture' "\$@"
EOF
  chmod +x "$bin/gh"
  : > "$home/fx/slow-read"
}

# Merged pull requests placed on the real wall clock, the only clock the read
# budget runs on, so a budget case never contradicts its own lookback.
write_real_pulls() {  # <home> <json-array-of-numbers>
  local merged
  merged=$(jq -nr --argjson t "$(( $(date +%s) - 7200 ))" '$t | todateiso8601')
  jq -n --arg base "https://github.com/$REPO/pull" --arg head "$HEAD_SHA" \
    --arg merge "$MERGE_SHA" --arg merged "$merged" --arg title "$TITLE" \
    --argjson numbers "$2" \
    '$numbers | map({number:.,html_url:"\($base)/\(.)",title:$title,
       merged_at:$merged,head:{sha:$head},merge_commit_sha:$merge})' \
    > "$1/fx/pulls.json"
}

# One poll on the real wall clock.
budget_poll() {  # <home>
  env PATH="$1/bin:$PATH" FM_HOME="$1" FM_JEV_PROD_BUDGET=3 \
    FM_JEV_PROD_MAX_PRS=3 "$CHECK" check 2>&1
}

comment_reads() {  # <home>
  sed -n 's|.*issues/\([0-9]*\)/comments.*|\1|p' "$1/fx/gh-argv.log" | tr '\n' ' '
}

test_a_window_the_budget_cut_short_is_finished_on_the_next_poll() {
  local home
  home=$(make_home budget-cursor)
  configure "$home"
  fake_gh "$home" >/dev/null
  write_real_pulls "$home" '[2214,2215,2216,2217,2218,2219]'
  write_no_comments "$home" 2214
  # The second pull request's comment read runs the budget out after the first
  # one had already spent part of it.
  slow_gh "$home" '*issues/2215/comments*' once

  : > "$home/fx/gh-argv.log"
  budget_poll "$home" >/dev/null
  assert_equals "2214 2215 " "$(comment_reads "$home")" "the spent budget must stop the poll at the pull request it cut short"

  : > "$home/fx/gh-argv.log"
  budget_poll "$home" >/dev/null
  assert_equals "2215 2216 2217 " "$(comment_reads "$home")" \
    "the next poll must start at the pull request the budget cut short, not skip it"
  pass "fm-jev-prod-check: a window the read budget cut short is finished on the very next poll"
}

test_a_preview_read_the_budget_cut_short_is_deferred_not_couldnt_check() {
  local home out
  home=$(make_home budget-preview)
  configure "$home"
  fake_gh "$home" >/dev/null
  write_real_pulls "$home" '[2213,2214]'
  write_no_comments "$home" 2213
  write_comments "$home" 2214 900022 "$(section portal failed post-merge production b0d9e7000022)"
  write_preview_artifact "$home" portal proven
  # The preview lookup is the read the budget runs out in, after 2213 had
  # already spent part of it.
  slow_gh "$home" '*actions/workflows/jev-check.yml/runs*' once

  out=$(budget_poll "$home")
  assert_equals "" "$out" "a pull request the budget cut short must report nothing"
  if grep -q '^woken	2214/' "$home/state/.jev-prod-monitor" || grep -q '^pending	' "$home/state/.jev-prod-monitor"; then
    fail "a verdict the budget cut short must be neither queued nor recorded as woken"
  fi

  out=$(budget_poll "$home")
  assert_contains "$out" "jev-prod: regression" "the next poll must pair the verdict and wake its regression at once"
  assert_grep "woken	2214/portal/b0d9e7000022" "$home/state/.jev-prod-monitor" \
    "the completed verdict must be recorded"
  pass "fm-jev-prod-check: a preview read the budget cut short is deferred, never filed as couldnt-check"
}

test_a_pull_request_slow_on_every_poll_never_holds_the_monitor() {
  local home
  home=$(make_home budget-stuck)
  configure "$home"
  fake_gh "$home" >/dev/null
  write_real_pulls "$home" '[2214,2215]'
  write_comments "$home" 2214 900023 "$(section portal failed post-merge production 5170c4000023)"
  write_no_comments "$home" 2215
  write_preview_artifact "$home" portal proven
  # 2214's preview lookup outlasts a whole fresh budget on every poll.
  slow_gh "$home" '*actions/workflows/jev-check.yml/runs*' always

  : > "$home/fx/gh-argv.log"
  budget_poll "$home" >/dev/null
  assert_equals "2214 " "$(comment_reads "$home")" "the first poll must spend its whole budget on the slow pull request"
  assert_grep "couldnt-check	couldnt-check pr=https://github.com/$REPO/pull/2214 " \
    "$home/state/.jev-prod-monitor" \
    "a pull request a whole fresh budget could not read must be couldnt-check, not deferred forever"
  assert_grep "woken	2214/portal/5170c4000023" "$home/state/.jev-prod-monitor" \
    "the couldnt-check verdict must be recorded so it is not queued again"

  : > "$home/fx/gh-argv.log"
  budget_poll "$home" >/dev/null
  assert_equals "2215" "$(comment_reads "$home" | cut -d' ' -f1)" \
    "the next poll must move on to the next pull request"
  pass "fm-jev-prod-check: a pull request slow on every poll is couldnt-check and never holds the monitor"
}

test_the_read_budget_fits_a_lowered_check_timeout() {
  local home out
  home=$(make_home budget)
  configure "$home"
  fake_gh "$home" >/dev/null
  write_pulls "$home" 7200
  write_comments "$home" 2214 900013 "$(section portal proven post-merge production b0d9e7000001)"

  # A watcher with a tight per-check bound must still get a complete poll.
  out=$(env PATH="$home/bin:$PATH" FM_HOME="$home" FM_JEV_PROD_NOW="$NOW" \
    FM_CHECK_TIMEOUT=5 "$CHECK" check 2>&1)
  expect_code 0 "$?" "a lowered check timeout must not break the poll"
  assert_equals "" "$out" "a clean verdict stays silent under a tight bound too"
  assert_grep "woken	2214/portal/b0d9e7000001" "$home/state/.jev-prod-monitor" \
    "the poll must still reach and record the verdict under a tight bound"
  pass "fm-jev-prod-check: the read budget stays inside a lowered watcher check timeout"
}

test_saved_lists_survive_full_rotations() {
  local home mode n i out expected actual
  local PR_URL=$PR_URL
  for mode in clean regression pending; do
    home=$(make_home "saved-rotation-$mode")
    configure "$home"
    fake_gh "$home" >/dev/null
    write_two_pulls "$home"
    for n in 2214 2215; do
      if [ "$mode" = clean ]; then
        write_comments "$home" "$n" "$n" "$(section portal proven post-merge production "record$n")"
      else
        write_comments "$home" "$n" "$n" "$(section portal failed post-merge production "record$n")"
      fi
    done
    if [ "$mode" = regression ]; then
      write_preview_artifact "$home" portal proven
    else
      write_no_preview_artifact "$home"
    fi
    for i in 0 1 2 3 4 5; do
      if [ "$mode" = regression ]; then
        if [ $((i % 2)) -eq 0 ]; then
          write_preview_artifact "$home" portal proven
        else
          PR_URL="https://github.com/$REPO/pull/2215"
          write_preview_artifact "$home" portal proven
          PR_URL="https://github.com/$REPO/pull/2214"
        fi
      fi
      out=$(poll "$home" FM_JEV_PROD_MAX_PRS=1 FM_JEV_PROD_NOW="$((NOW + i))")
      if [ "$mode" = regression ] && [ "$i" -lt 2 ]; then
        assert_contains "$out" "jev-prod: regression" "initial regressions wake immediately"
      else
        assert_equals "" "$out" "persisted outcomes must not wake on a second rotation"
      fi
    done
    expected=$(printf '2214/portal/record2214\n2215/portal/record2215')
    actual=$(sed -n 's/^woken	//p' "$home/state/.jev-prod-monitor")
    assert_equals "$expected" "$actual" "saved keys stay exact across three rotations, including clean appends"
    if [ "$mode" = pending ]; then
      actual=$(awk -F '\t' '$1 == "pending" {print $2 "\t" $3}' "$home/state/.jev-prod-monitor")
      expected=$(printf '%s\tcouldnt-check\n%s\tcouldnt-check' "$NOW" "$((NOW + 1))")
      assert_equals "$expected" "$actual" "each pending timestamp and class stays on its own row"
      assert_equals 2 "$(awk -F '\t' '$1 == "pending" && NF == 4 {n++} END {print n+0}' "$home/state/.jev-prod-monitor")" "each pending evidence is one tab-separated field"
      if [ "$mode" = regression ]; then
        if [ $((i % 2)) -eq 0 ]; then
          write_preview_artifact "$home" portal proven
        else
          PR_URL="https://github.com/$REPO/pull/2215"
          write_preview_artifact "$home" portal proven
          PR_URL="https://github.com/$REPO/pull/2214"
        fi
      fi
      out=$(poll "$home" FM_JEV_PROD_MAX_PRS=1 FM_JEV_PROD_NOW="$((NOW + 21601))")
      assert_contains "$out" "2 verdicts" "the batch counts the distinct saved evidence rows"
      assert_contains "$out" "/pull/2214 " "first evidence survives reloads"
      assert_contains "$out" "/pull/2215 " "second evidence survives reloads"
    fi
  done
  pass "fm-jev-prod-check: saved woken and pending lists survive three candidate rotations"
}

REAL_FX="$ROOT/tests/fixtures/jev-prod-monitor"

real_candidate() {  # <home> <pr>
  jq --argjson n "$2" '[.[] | select(.number == $n)]' "$REAL_FX/pulls.json" > "$1/fx/pulls.json"
  cp "$REAL_FX/comments-$2.json" "$1/fx/comments-$2.json"
  cp "$REAL_FX/deployments-$2.json" "$1/fx/deployments.json"
  cp "$REAL_FX/statuses-$2.json" "$1/fx/statuses.json"
  cp "$REAL_FX"/deployment-statuses-*.json "$1/fx/"
}

install_captured_artifact() {  # <home> <fixture-prefix> <id> <name>
  local home=$1 prefix=$2 id=$3 name=$4 dir="$1/fx/captured-$3"
  mkdir -p "$dir/plan"
  cp "$REAL_FX/$prefix-context.json" "$dir/context.json"
  [ ! -f "$REAL_FX/$prefix-plan.json" ] || cp "$REAL_FX/$prefix-plan.json" "$dir/plan/plan.json"
  [ ! -f "$REAL_FX/$prefix-records.jsonl" ] || cp "$REAL_FX/$prefix-records.jsonl" "$dir/records.jsonl"
  (cd "$dir" && zip -qr "$home/fx/artifact-$id.zip" .)
  jq -n --argjson id "$id" --arg name "$name" '{artifacts:[{id:$id,name:$name,expired:false}]}' > "$home/fx/artifacts-39078284927.json"
}

repack_preview() {
  rm -f "$1/fx/artifact-12040000001.zip"
  (cd "$1/fx/art-build" && zip -qr "$1/fx/artifact-12040000001.zip" .)
}

change_json() {  # <file> <jq-filter>
  jq "$2" "$1" > "$1.new" && mv "$1.new" "$1"
}

test_real_completed_outcomes_and_run_attempts() {
  local home out sha n
  local NOW=1792296000
  for n in 2244 2246 2247; do
    home=$(make_home "real-completed-$n")
    configure "$home" 'lookback-hours:336'
    fake_gh "$home" >/dev/null
    real_candidate "$home" "$n"
    if [ "$n" = 2244 ]; then
      sha=$(jq -r '.[0].merge_commit_sha' "$home/fx/pulls.json")
      jq -s '{workflow_runs:.}' "$REAL_FX/run-39065201369.json" > "$home/fx/runs-$sha.json"
      install_captured_artifact "$home" legacy 12097900001 jev-check-records
      mv "$home/fx/artifacts-39078284927.json" "$home/fx/artifacts-39065201369.json"
    fi
    out=$(poll "$home")
    if [ "$n" = 2244 ]; then
      assert_grep 'run-39065201369-attempt-1-proven-eb33ce8736ce' "$home/state/.jev-prod-monitor" "captured legacy context, plan and record bind the published result to its run"
    fi
    assert_equals "" "$out" "captured proven and not-applicable outcomes are silent"
    assert_equals 2 "$(grep -c '^woken	' "$home/state/.jev-prod-monitor")" "both completed app outcomes are deduped"
    assert_no_grep 'pending	' "$home/state/.jev-prod-monitor" "not-applicable never enters the inability batch"
    assert_grep 'not-applicable' "$home/state/.jev-prod-monitor" "not-applicable remains distinct from proven"
    assert_grep 'nothing this pull request changed' "$home/state/.jev-prod-monitor" "the reason survives persistence"
  done
  sha=$(jq -r '.[0].merge_commit_sha' "$home/fx/pulls.json")
  jq -s '{workflow_runs:.}' "$REAL_FX/run-39078284927.json" > "$home/fx/runs-$sha.json"
  install_captured_artifact "$home" not-applicable 12118504083 jev-check-records-portal
  out=$(poll "$home")
  assert_equals "" "$out" "a completed run with verified identity remains silent"
  assert_grep 'run-39078284927-attempt-1-not-applicable' "$home/state/.jev-prod-monitor" "no-plan outcomes use verified workflow run and attempt"
  change_json "$home/fx/runs-$sha.json" '.workflow_runs[0].run_attempt=2'
  out=$(poll "$home")
  assert_equals "" "$out" "a distinct not-applicable attempt stays completed"
  assert_grep 'run-39078284927-attempt-2-not-applicable' "$home/state/.jev-prod-monitor" "a later attempt is independently recorded"
  assert_equals 2 "$(grep -c '^outcome	.*portal/' "$home/state/.jev-prod-monitor")" "each run keeps its reason"
  change_json "$home/fx/comments-2247.json" '.[0].body |= sub("not applicable in production";"unexpected completed title")'
  out=$(poll "$home" FM_JEV_PROD_BATCH_SECS=0)
  assert_contains "$out" 'production=unreadable ' "malformed outcomes never inherit the completed artifact verdict"
  grep -q 'unparsed-.*run-39078284927-attempt-2' "$home/state/.jev-prod-monitor" || fail "an unparsed outcome still has a verified run identity"
  change_json "$home/fx/runs-$sha.json" '.workflow_runs[0].run_attempt=3'
  out=$(poll "$home" FM_JEV_PROD_BATCH_SECS=0)
  assert_contains "$out" 'production=unreadable ' "a later run with the same malformed title is independently reported"
  grep -q 'unparsed-.*run-39078284927-attempt-3' "$home/state/.jev-prod-monitor" || fail "new malformed attempts are not hidden by a static skip key"
  pass "fm-jev-prod-check: real completed outcomes preserve reasons and distinct workflow attempts"
}

test_known_nonpassing_and_unknown_titles() {
  local home out verdict
  for verdict in refused unverified 'looks proven' 'not applicable' 'proven with caveats'; do
    home=$(make_home "known-nonpassing-$(printf '%s' "$verdict" | tr ' ' '-')")
    configure "$home"
    fake_gh "$home" >/dev/null
    write_pulls "$home" 7200
    write_comments "$home" 2214 900101 "$(section portal "$verdict" post-merge production titlecase)"
    write_preview_artifact "$home" portal proven
    out=$(poll "$home" FM_JEV_PROD_BATCH_SECS=0)
    assert_contains "$out" 'jev-prod: couldnt-check' "nonpassing and unknown titles never become a pass or regression"
    case "$verdict" in
      refused|unverified) assert_contains "$out" "production=$verdict " "known explicit nonpassing outcomes retain their names" ;;
      *) assert_contains "$out" 'production=unreadable ' "an unknown complete title is not read from its final word" ;;
    esac
  done
  pass "fm-jev-prod-check: complete titles distinguish known nonpassing outcomes and malformed titles"
}

test_real_skipped_builds_and_unreadable_inventory() {
  local home out
  local NOW=1792296000
  home=$(make_home real-canceled-build)
  configure "$home" 'lookback-hours:336'
  fake_gh "$home" >/dev/null
  real_candidate "$home" 2245
  out=$(poll "$home" FM_JEV_PROD_BATCH_SECS=0)
  assert_contains "$out" 'production=build-skipped ' "captured success statuses describing canceled builds are not deployment proof"
  assert_no_grep '/deployments/' "$home/fx/gh-argv.log" "generic production and protected-secrets environments never count"
  touch "$home/fx/fail-deployments"
  out=$(poll "$home" FM_JEV_PROD_BATCH_SECS=0)
  assert_contains "$out" 'production=deployment-unreadable ' "unreadable deployment inventory has a distinct outcome"
  rm "$home/fx/fail-deployments"
  printf '{"statuses":[{"state":"success","context":"unrelated","description":"ok"}]}' > "$home/fx/statuses.json"
  out=$(poll "$home" FM_JEV_PROD_BATCH_SECS=0)
  assert_contains "$out" 'production=not-deployed ' "generic success never starts the deployment grace"
  pass "fm-jev-prod-check: real canceled builds and unrelated environments are distinct from unreadable deployments"
}

test_deployment_grace_late_result_and_redeploy() {
  local home out stamp
  home=$(make_home deployment-grace)
  configure "$home"
  fake_gh "$home" >/dev/null
  write_pulls "$home" 7200
  write_comments "$home" 2214 900102 "$(section portal proven pre-merge qa previewrec)"
  stamp=$(jq -nr --argjson t "$((NOW - 60))" '$t | todateiso8601')
  jq -n --arg stamp "$stamp" '[{id:1,state:"success",created_at:$stamp}]' > "$home/fx/deployment-statuses.json"
  out=$(poll "$home" FM_JEV_PROD_BATCH_SECS=0)
  assert_equals "" "$out" "an old merge with a recent successful deployment is inside grace"
  if grep -Eq '^(pending|woken)' "$home/state/.jev-prod-monitor"; then fail "grace does not settle a missing result"; fi
  out=$(poll "$home" FM_JEV_PROD_NOW="$((NOW+3601))" FM_JEV_PROD_BATCH_SECS=0)
  assert_contains "$out" 'production=none ' "a deployed app with Jev missing wakes after deployment grace"
  write_comments "$home" 2214 900102 "$(section portal failed post-merge production late-result)"
  write_preview_artifact "$home" portal proven
  out=$(poll "$home" FM_JEV_PROD_NOW="$((NOW+3602))")
  assert_contains "$out" 'jev-prod: regression' "a late result is not suppressed by the missing-result key"
  out=$(poll "$home" FM_JEV_PROD_NOW="$((NOW+3603))")
  assert_equals "" "$out" "the late result is delivered once"
  write_comments "$home" 2214 900102 "$(section portal proven pre-merge qa previewrec)"
  jq -n --arg sha "$MERGE_SHA" '[{id:7002,sha:$sha,environment:"Production – core-metaplanet",created_at:"2025-10-09T00:00:00Z"}]' > "$home/fx/deployments.json"
  out=$(poll "$home" FM_JEV_PROD_NOW="$((NOW+3604))" FM_JEV_PROD_BATCH_SECS=0)
  assert_contains "$out" 'production=none ' "a distinct deployment gets its own missing-result identity"
  change_json "$home/fx/deployments.json" '.[0].sha="ffffffffffffffffffffffffffffffffffffffff"'
  out=$(poll "$home" FM_JEV_PROD_BATCH_SECS=0)
  assert_contains "$out" 'production=not-deployed ' "a supported environment on another SHA is not this app deployment"
  pass "fm-jev-prod-check: deployment grace, late results, and redeploy identities are independent"
}

test_persona_pairing_rejects_mismatches() {
  local home out mismatch
  for mismatch in none context-app context-head context-phase context-persona plan-app plan-head plan-persona plan-input record-head record-phase run-head; do
    home=$(make_home "persona-$mismatch")
    configure "$home"
    fake_gh "$home" >/dev/null
    write_pulls "$home" 7200
    write_comments "$home" 2214 900103 "$(section portal:portal-foreign failed post-merge production foreignrec)"
    write_preview_artifact "$home" portal proven
    change_json "$home/fx/artifacts-38887740485.json" '.artifacts[0].name="jev-check-records-portal-foreign"'
    change_json "$home/fx/art-build/context.json" '.memberPersona="portal-foreign"'
    change_json "$home/fx/art-build/plan/plan.json" '.test_account_role="portal-foreign"'
    case "$mismatch" in
      context-app) change_json "$home/fx/art-build/context.json" '.app="admin-center"' ;;
      context-head) change_json "$home/fx/art-build/context.json" '.pr.headSha="ffffffff"' ;;
      context-phase) change_json "$home/fx/art-build/context.json" '.phase="post-merge"' ;;
      context-persona) change_json "$home/fx/art-build/context.json" '.memberPersona="portal-previous"' ;;
      plan-app) change_json "$home/fx/art-build/plan/plan.json" '.app="admin-center"' ;;
      plan-head) change_json "$home/fx/art-build/plan/plan.json" '.head_sha="ffffffff"' ;;
      plan-persona) change_json "$home/fx/art-build/plan/plan.json" '.test_account_role="portal-unverified"' ;;
      plan-input) change_json "$home/fx/art-build/plan/plan.json" '.input_hash="another-plan"' ;;
      record-head) change_json "$home/fx/art-build/records.jsonl" 'if .event=="check" then .record.head_sha="ffffffff" else . end' ;;
      record-phase) change_json "$home/fx/art-build/records.jsonl" 'if .event=="check" then .record.phase="post-merge" else . end' ;;
      run-head) change_json "$home/fx/runs-$HEAD_SHA.json" '.workflow_runs[0].head_sha="ffffffff"' ;;
    esac
    repack_preview "$home"
    out=$(poll "$home" FM_JEV_PROD_BATCH_SECS=0)
    assert_contains "$out" 'app=portal:portal-foreign ' "persona identity survives into evidence"
    if [ "$mismatch" = none ]; then
      assert_contains "$out" 'jev-prod: regression' "only the matching app, persona, phase, head and plan pair"
    else
      assert_contains "$out" 'jev-prod: couldnt-check' "a $mismatch mismatch cannot establish preview proof"
    fi
  done
  pass "fm-jev-prod-check: persona pairing checks context, plan, record, and workflow identity"
}

test_captured_persona_artifact_context_wins_over_name() {
  local home out sha
  local NOW=1792296000
  home=$(make_home real-persona-wrong-app)
  configure "$home" 'lookback-hours:336'
  fake_gh "$home" >/dev/null
  real_candidate "$home" 2247
  sha=$(jq -r '.[0].head.sha' "$home/fx/pulls.json")
  jq -s '{workflow_runs:.}' "$REAL_FX/run-39077760909.json" > "$home/fx/runs-$sha.json"
  cp "$REAL_FX/artifacts-39077760909.json" "$home/fx/artifacts-39077760909.json"
  install_captured_artifact "$home" foreign 12117397213 jev-check-records-portal-foreign
  change_json "$home/fx/comments-2247.json" '.[0].body |= gsub("portal -->";"portal:portal-foreign -->") | .[0].body |= gsub("not applicable in production";"failed")'
  out=$(poll "$home" FM_JEV_PROD_BATCH_SECS=0)
  assert_contains "$out" 'app=portal:portal-foreign production=failed preview=unknown' "the actual foreign-named artifact has admin-center context and cannot prove portal"
  pass "fm-jev-prod-check: captured persona artifact is rejected when its context names the other app"
}

test_reseed_backs_up_corruption_and_never_seeds_malformed_outcomes() {
  local home out backup before
  home=$(make_home reseed-corruption)
  configure "$home"
  fake_gh "$home" >/dev/null
  write_two_pulls "$home"
  write_comments "$home" 2214 900104 "$(section portal failed post-merge production knownrec)"
  write_comments "$home" 2215 900105 "$(section portal 'looks proven' post-merge production unknownrec)"
  write_preview_artifact "$home" portal proven
  printf 'fm-jev-prod-monitor-v1\nwoken\t2246/portal/unparsed2245/admin-center/no-production-verdict\npending\t%s\tcouldnt-check\tfirst evidence%scouldnt-check glued evidence\n' "$NOW" "$NOW" > "$home/state/.jev-prod-monitor"
  before=$(cat "$home/state/.jev-prod-monitor")
  out=$(env PATH="$home/bin:$PATH" FM_HOME="$home" FM_JEV_PROD_NOW="$NOW" "$CHECK" reseed 2>&1)
  expect_code 0 "$?" "explicit reseed succeeds from current verified recorder outcomes"
  backup=${out##*backup=}
  assert_equals "$before" "$(cat "$backup")" "the backup preserves the entire corrupt state before rebuilding"
  assert_equals 'woken	2214/portal/knownrec' "$(grep '^woken' "$home/state/.jev-prod-monitor")" "only the current known outcome is seeded, never historical glued rows or an unknown title"
  out=$(poll "$home" FM_JEV_PROD_BATCH_SECS=0)
  assert_contains "$out" '/pull/2215 ' "malformed current outcomes remain an inability to check"
  if [[ "$out" == *'/pull/2214 '* ]]; then fail "the known baseline must not redeliver"; fi
  before=$(cat "$home/state/.jev-prod-monitor")
  touch "$home/fx/fail-comments"
  out=$(env PATH="$home/bin:$PATH" FM_HOME="$home" FM_JEV_PROD_NOW="$NOW" "$CHECK" reseed 2>&1)
  expect_code 1 "$?" "an incomplete reseed fails closed"
  assert_equals "$before" "$(cat "$home/state/.jev-prod-monitor")" "failed reseed leaves the original state intact"
  pass "fm-jev-prod-check: explicit reseed backs up corruption and seeds only verified current outcomes"
}

test_recorded_run_identity_survives_read_failures() {
  local home out
  home=$(make_home recorded-attempts)
  configure "$home"
  fake_gh "$home" >/dev/null
  write_pulls "$home" 7200
  write_comments "$home" 2214 900106 "$(section portal proven post-merge production productionrec)"
  write_preview_artifact "$home" portal proven
  change_json "$home/fx/art-build/context.json" '.phase="post-merge"'
  change_json "$home/fx/art-build/records.jsonl" 'if .event=="check" then .record.phase="post-merge" | .record.record_id="productionrec" else . end'
  repack_preview "$home"
  jq -n --arg sha "$MERGE_SHA" '{workflow_runs:[{id:38887740485,head_sha:$sha,event:"deployment_status",conclusion:"success",run_attempt:1}]}' > "$home/fx/runs-$MERGE_SHA.json"
  touch "$home/fx/fail-runs"
  out=$(poll "$home")
  assert_equals "" "$out" "a production pass with no run metadata remains silent"
  assert_grep 'woken	2214/portal/productionrec' "$home/state/.jev-prod-monitor" "the fallback is recorded before enrichment"
  rm "$home/fx/fail-runs"
  out=$(poll "$home")
  assert_equals "" "$out" "a production pass with verified run identity remains silent"
  assert_grep 'run-38887740485-attempt-1-proven-productionrec' "$home/state/.jev-prod-monitor" "the record binds the comment to the same production run"
  touch "$home/fx/fail-runs"
  out=$(poll "$home")
  assert_equals "" "$out" "temporary metadata failure cannot redeliver a recorded result"
  assert_equals 1 "$(grep -c '^woken' "$home/state/.jev-prod-monitor")" "metadata failure cannot create a fallback duplicate key"
  rm "$home/fx/fail-runs"
  change_json "$home/fx/runs-$MERGE_SHA.json" '.workflow_runs[0].run_attempt=2'
  out=$(poll "$home")
  assert_equals "" "$out" "a new proven attempt remains silent"
  assert_grep 'run-38887740485-attempt-2-proven-productionrec' "$home/state/.jev-prod-monitor" "a new verified workflow attempt gets its own key"
  pass "fm-jev-prod-check: recorded run identity survives metadata failure and distinguishes attempts"
}

test_sibling_personas_never_exchange_preview_verdicts() {
  local home out
  home=$(make_home sibling-personas)
  configure "$home"
  fake_gh "$home" >/dev/null
  write_pulls "$home" 7200
  write_comments "$home" 2214 900107 "$(section portal:portal-foreign failed post-merge production foreignfailed)"
  write_preview_artifact "$home" portal proven
  cp "$home/fx/artifact-12040000001.zip" "$home/fx/default.zip"
  change_json "$home/fx/art-build/context.json" '.memberPersona="portal-foreign"'
  change_json "$home/fx/art-build/plan/plan.json" '.test_account_role="portal-foreign"'
  change_json "$home/fx/art-build/records.jsonl" 'if .event=="check" then .record.verdict="failed" else . end'
  repack_preview "$home"
  mv "$home/fx/artifact-12040000001.zip" "$home/fx/artifact-12040000002.zip"
  mv "$home/fx/default.zip" "$home/fx/artifact-12040000001.zip"
  jq -n '{artifacts:[{id:12040000001,name:"jev-check-records-portal",expired:false},{id:12040000002,name:"jev-check-records-portal-foreign",expired:false}]}' > "$home/fx/artifacts-38887740485.json"
  out=$(poll "$home" FM_JEV_PROD_BATCH_SECS=0)
  assert_contains "$out" 'jev-prod: still-flagged' "the foreign failure pairs with its own failed preview, not the proven default preview"
  assert_contains "$out" 'app=portal:portal-foreign production=failed preview=failed' "evidence preserves the matching persona verdicts"
  pass "fm-jev-prod-check: sibling personas never exchange preview verdicts"
}

test_real_older_nonpassing_comments() {
  local home out n
  local NOW=1792296000
  for n in 2216 2230; do
    home=$(make_home "real-older-$n")
    configure "$home" 'lookback-hours:336'
    fake_gh "$home" >/dev/null
    real_candidate "$home" "$n"
    out=$(poll "$home" FM_JEV_PROD_BATCH_SECS=0)
    assert_contains "$out" 'jev-prod:' "captured old nonpassing outcomes remain visible"
    if [ "$n" = 2230 ]; then
      assert_contains "$out" 'production=failed ' "the historical portal failure stays nonpassing"
      assert_contains "$out" 'production=unproven ' "the historical admin-center inability stays nonpassing"
    else
      assert_contains "$out" 'preview=skipped ' "the older pre-merge skip is still recognizable"
    fi
  done
  pass "fm-jev-prod-check: real older skipped and failed comments remain nonpassing"
}

test_malformed_sections_never_settle_as_proven() {
  local home out variant body
  for variant in missing-close nested duplicate-title missing-record; do
    home=$(make_home "malformed-section-$variant")
    configure "$home"
    fake_gh "$home" >/dev/null
    write_pulls "$home" 7200
    body=$(section portal proven post-merge production malformed)
    case "$variant" in
      missing-close) body=$(printf '%s' "$body" | sed '/^<!-- \/jev-check-app:/d') ;;
      nested) body=$(printf '%s' "$body" | sed '/^Head /a\
<!-- jev-check-app:admin-center -->') ;;
      duplicate-title) body=$(printf '%s' "$body" | sed '/^Head /a\
**Browser check - failed** (advisory; blocks no merge)') ;;
      missing-record) body=$(printf '%s' "$body" | sed '/^Plan /d') ;;
    esac
    write_comments "$home" 2214 900108 "$body"
    out=$(poll "$home" FM_JEV_PROD_BATCH_SECS=0)
    assert_contains "$out" 'production=unreadable ' "a $variant malformed section never settles as proven"
  done
  pass "fm-jev-prod-check: malformed section structure and incomplete proven outcomes stay nonpassing"
}

test_recorded_run_identity_survives_read_failures
test_sibling_personas_never_exchange_preview_verdicts
test_real_older_nonpassing_comments
test_malformed_sections_never_settle_as_proven
test_real_completed_outcomes_and_run_attempts
test_known_nonpassing_and_unknown_titles
test_real_skipped_builds_and_unreadable_inventory
test_deployment_grace_late_result_and_redeploy
test_persona_pairing_rejects_mismatches
test_captured_persona_artifact_context_wins_over_name
test_reseed_backs_up_corruption_and_never_seeds_malformed_outcomes
test_saved_lists_survive_full_rotations
test_help_and_usage
test_unconfigured_home_is_silent_and_spends_nothing
test_config_parsing_and_arm_refusals
test_clean_production_verdict_is_silent_and_settled
test_regression_wakes_immediately_with_its_evidence
test_still_flagged_batches_until_the_window_elapses
test_unestablished_preview_is_couldnt_check_not_clean
test_a_production_run_that_never_reported_is_couldnt_check
test_within_the_grace_a_missing_production_verdict_is_not_late
test_skipped_production_verdict_is_not_a_pass
test_a_skipped_preview_never_makes_a_failure_still_flagged
test_unparsable_section_is_couldnt_check
test_gh_failure_is_reported_once_and_never_as_clean
test_missing_tool_is_reported_and_arm_refuses
test_a_title_outside_the_pattern_carries_no_ticket
test_each_app_section_is_classified_on_its_own
test_no_marker_comment_is_not_a_verdict_to_chase
test_a_marker_comment_from_another_author_is_not_a_verdict
test_the_recorder_identity_is_configurable
test_an_artifact_verdict_outside_the_vocabulary_is_not_established
test_a_comment_verdict_outside_the_vocabulary_is_couldnt_check
test_a_truncated_comment_inventory_is_couldnt_check
test_a_pull_request_outside_the_lookback_is_not_examined
test_arm_writes_and_binds_the_check_and_disarm_removes_it
test_armed_shim_runs_a_real_check
test_more_candidates_than_one_poll_reads_are_rotated
test_a_rotation_bucket_advances_by_a_whole_window
test_a_long_batch_carries_every_verdict_uncut
test_a_window_the_budget_cut_short_is_finished_on_the_next_poll
test_a_preview_read_the_budget_cut_short_is_deferred_not_couldnt_check
test_a_pull_request_slow_on_every_poll_never_holds_the_monitor
test_the_read_budget_fits_a_lowered_check_timeout
