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
  jq -n '{workflow_runs:[{id:38887740485,conclusion:"success"}]}' > "$home/fx/runs-$HEAD_SHA.json"
  jq -n '{artifacts:[{id:12040000001,name:"jev-check-records",expired:false}]}' \
    > "$home/fx/artifacts-38887740485.json"
  dir="$home/fx/art-build"
  rm -rf "$dir"; mkdir -p "$dir"
  jq -n --arg app "$app" --arg url "$PR_URL" --arg head "$HEAD_SHA" \
    '{run:true,phase:"pre-merge",app:$app,jevEnv:"qa",
      pr:{url:$url,number:2214,headSha:$head}}' > "$dir/context.json"
  jq -nc --arg v "$verdict" \
    '{event:"check",at:"2026-10-16T09:00:00Z",record:{verdict:$v,phase:"pre-merge"},publish:true}' \
    > "$dir/records.jsonl"
  jq -nc '{event:"delivery",at:"2026-10-16T09:00:01Z",record_id:"x"}' >> "$dir/records.jsonl"
  rm -f "$home/fx/artifact-12040000001.zip"
  (cd "$dir" && zip -q "$home/fx/artifact-12040000001.zip" context.json records.jsonl)
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
  assert_equals 1 "$(printf '%s\n' "$out" | grep -c .)" "a skipped production run must wake as one line"
  assert_contains "$out" "jev-prod: regression" "a skip after a proven preview is a production non-answer, not a pass"
  assert_contains "$out" "production=skipped" "the line must carry the skip as the production verdict"
  pass "fm-jev-prod-check: a skipped production run is never read as a pass"
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
  (cd "$dir" && zip -q "$home/fx/artifact-12040000001.zip" context.json records.jsonl)

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
test_the_read_budget_fits_a_lowered_check_timeout
