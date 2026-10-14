#!/usr/bin/env bash
# Regression tests for the pinned shared no-mistakes gate action, and for the
# workflow that decides when to run it.
#
# The workflow half resolves .github/workflows/no-mistakes-required.yml's
# concurrency group and step conditions against simulated pull_request event
# payloads, so the assertions describe what GitHub would do with a given label
# set and event action rather than how the file happens to be spelled. The
# marker label is deliberate delivery state: firstmate applies it with
# bin/fm-pr-ci-validated.sh when it raises a PR outside the pipeline, and an
# unmarked PR must still reach the signature action and still fail there.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ACTION_REF=32d396ac0f29135daf7fcb9964aba9d5f4e796d6
TMP_ROOT=$(fm_test_tmproot fm-no-mistakes-required)
VERIFY="$TMP_ROOT/verify.py"
OLD_SHA=1111111111111111111111111111111111111111
NEW_SHA=2222222222222222222222222222222222222222
SIGNATURE='Updates from [git push no-mistakes](https://github.com/kunchenguid/no-mistakes)'
COMPLETED_STEPS='[{"step":"review","status":"completed"},{"step":"test","status":"completed"},{"step":"document","status":"completed"}]'

WORKFLOW="$ROOT/.github/workflows/no-mistakes-required.yml"
MARKER_TOOL="$ROOT/bin/fm-pr-ci-validated.sh"
RESOLVE="$TMP_ROOT/resolve.rb"

assert_present "$WORKFLOW" ".github/workflows/no-mistakes-required.yml is missing"
assert_present "$MARKER_TOOL" "bin/fm-pr-ci-validated.sh is missing"
command -v ruby >/dev/null 2>&1 \
  || fail "ruby is required to parse .github/workflows/no-mistakes-required.yml as YAML"

# One resolver for the three questions the workflow answers: which event types
# reach it, which group an event lands in, and which steps GitHub would run for
# a given author and label set. Only the expression constructs this workflow
# uses are implemented, so an unresolvable construct fails loudly instead of
# being silently treated as false.
write_resolver() {
  cat > "$RESOLVE" <<'RUBY'
require 'yaml'

def split_top(expr, op)
  parts = []
  depth = 0
  quoted = false
  buf = +''
  i = 0
  while i < expr.length
    c = expr[i]
    if quoted
      quoted = false if c == "'"
      buf << c
      i += 1
      next
    end
    if c == "'"
      quoted = true
      buf << c
      i += 1
    elsif c == '('
      depth += 1
      buf << c
      i += 1
    elsif c == ')'
      depth -= 1
      buf << c
      i += 1
    elsif depth.zero? && expr[i, op.length] == op
      parts << buf
      buf = +''
      i += op.length
    else
      buf << c
      i += 1
    end
  end
  parts << buf
  parts
end

def truthy(value)
  !(value == false || value.nil? || value == '')
end

def evaluate(expr, context)
  e = expr.strip
  parts = split_top(e, '||')
  if parts.length > 1
    values = parts.map { |p| evaluate(p, context) }
    return values.find { |v| truthy(v) } || values.last
  end
  parts = split_top(e, '&&')
  if parts.length > 1
    values = parts.map { |p| evaluate(p, context) }
    falsy = values.find { |v| !truthy(v) }
    return falsy.nil? ? values.last : falsy
  end
  parts = split_top(e, '!=')
  return evaluate(parts[0], context) != evaluate(parts[1], context) if parts.length == 2
  parts = split_top(e, '==')
  return evaluate(parts[0], context) == evaluate(parts[1], context) if parts.length == 2
  return !truthy(evaluate(e[1..], context)) if e.start_with?('!')
  return evaluate(e[1..-2], context) if e.start_with?('(') && e.end_with?(')')
  if (m = /\Acontains\((.+),\s*'([^']*)'\)\z/m.match(e))
    haystack = evaluate(m[1].strip, context)
    raise "contains() needs a list, got #{haystack.inspect}" unless haystack.is_a?(Array)
    return haystack.include?(m[2])
  end
  return e[1..-2] if e.start_with?("'") && e.end_with?("'")
  raise "unresolvable expression: #{e}" unless context.key?(e)
  context.fetch(e)
end

def interpolate(raw, context)
  raw.to_s.gsub(/\$\{\{(.+?)\}\}/) { evaluate(Regexp.last_match(1), context).to_s }
end

# A step or job condition may be written bare or wrapped in ${{ }}; GitHub
# treats both the same, so unwrap before evaluating.
def condition(raw, context)
  return true if raw.nil?
  text = raw.to_s.strip
  m = /\A\$\{\{(.+)\}\}\z/m.match(text)
  text = m[1] if m
  truthy(evaluate(text, context))
end

doc = YAML.load_file(ARGV[0])
mode = ARGV[1]
triggers = doc['on'] || doc[true]
job = doc.fetch('jobs').fetch('check')

context = {
  'github.run_id' => ARGV[2].to_s,
  'github.event.action' => ARGV[3].to_s,
  'github.event.pull_request.number' => ARGV[4].to_s,
  'github.event.pull_request.user.login' => ARGV[5].to_s,
  'github.event.pull_request.labels.*.name' => ARGV[6].to_s.split(',').reject(&:empty?)
}

case mode
when 'types'
  puts triggers.fetch('pull_request').fetch('types').join(',')
when 'branches'
  puts triggers.fetch('pull_request').fetch('branches').join(',')
when 'concurrency'
  concurrency = doc.fetch('concurrency')
  puts [interpolate(concurrency.fetch('group'), context),
        interpolate(concurrency.fetch('cancel-in-progress'), context)].join("\t")
when 'permissions'
  puts doc.fetch('permissions').map { |k, v| "#{k}=#{v}" }.sort.join(',')
when 'steps'
  unless condition(job['if'], context)
    puts "job\tskipped"
    exit 0
  end
  job.fetch('steps').each do |step|
    next unless condition(step['if'], context)
    puts "step\t#{step['name']}"
    puts "uses\t#{step['uses']}" if step['uses']
    puts "run\t#{step['run']}" if step['run']
    (step['with'] || {}).each { |k, v| puts "with\t#{k}=#{v}" }
  end
else
  raise "unknown mode: #{mode}"
end
RUBY
}

# Resolve one workflow question. Args: mode [run_id] [action] [number] [author] [labels]
resolve() {
  local mode=$1 run_id=${2:-7001} action=${3:-opened} number=${4:-3006}
  local author=${5:-contributor} labels=${6:-}
  ruby "$RESOLVE" "$WORKFLOW" "$mode" "$run_id" "$action" "$number" "$author" "$labels"
}

MARKER=$("$MARKER_TOOL" --label) \
  || fail "bin/fm-pr-ci-validated.sh could not report the marker label it applies"

test_label_changes_re_evaluate_the_check() {
  local types
  types=$(resolve types) || fail "could not read the workflow's pull_request trigger types"
  local wanted
  for wanted in opened edited synchronize reopened labeled unlabeled; do
    assert_contains ",$types," ",$wanted," \
      "the check does not re-evaluate on a $wanted event"
  done
  assert_equals main "$(resolve branches)" \
    "the check no longer targets the main branch"
  pass "adding or removing a label re-evaluates the check beside the body and head events"
}

test_marker_label_passes_without_running_the_signature_action() {
  local output
  output=$(resolve steps 7002 labeled 3006 contributor "$MARKER") \
    || fail "could not resolve the workflow's steps for a marked PR"
  assert_not_contains "$output" "uses	" \
    "a marked PR still runs an action instead of passing on the marker alone"
  assert_contains "$output" "::notice::" \
    "a marked PR does not report why the check passed"
  assert_contains "$output" "$MARKER" \
    "the passing notice does not name the $MARKER marker"
  assert_contains "$output" "no-mistakes" \
    "the passing notice does not name the rule it stands in for"
  assert_equals 1 "$(printf '%s\n' "$output" | grep -c '^step	')" \
    "a marked PR runs more than the one marker step"
  pass "the $MARKER marker passes the check with a notice and no signature action"
}

test_unmarked_pr_still_reaches_the_signature_action() {
  local output action
  for action in opened edited synchronize reopened unlabeled; do
    output=$(resolve steps 7003 "$action" 3006 contributor "needs-review,documentation") \
      || fail "could not resolve the workflow's steps for an unmarked $action event"
    assert_contains "$output" \
      "uses	kunchenguid/no-mistakes/.github/actions/require-no-mistakes@f6441c96c352a18b9cadcaef6b6c7017e9ac3970" \
      "an unmarked PR does not reach the pinned signature action on a $action event"
    assert_contains "$output" "with	exempt-authors=kunchenguid" \
      "the signature action lost its exempt author on a $action event"
    assert_not_contains "$output" "::notice::" \
      "an unmarked PR reported the marker notice on a $action event"
  done
  pass "a PR without the marker still reaches the pinned signature action unchanged"
}

# A near-miss label must not be mistaken for the marker, or any unrelated label
# would quietly waive the check.
test_only_the_exact_marker_waives_the_signature_action() {
  local output
  output=$(resolve steps 7004 labeled 3006 contributor "fm-ci-validated-draft,ci-validated") \
    || fail "could not resolve the workflow's steps for a near-miss label set"
  assert_contains "$output" "uses	kunchenguid/no-mistakes" \
    "a label that merely resembles the marker skipped the signature action"
  pass "only the exact $MARKER label waives the signature action"
}

test_bot_authors_stay_exempt() {
  local login
  for login in 'github-actions[bot]' 'dependabot[bot]'; do
    assert_equals "job	skipped" "$(resolve steps 7005 opened 3006 "$login")" \
      "$login is no longer exempt from the check"
  done
  assert_not_equals "job	skipped" "$(resolve steps 7005 opened 3006 contributor)" \
    "an ordinary author is now exempt from the check"
  pass "the GitHub Actions and Dependabot exemptions survive the marker branch"
}

# The marker events must not share a concurrency group with the body-bearing
# events, whose per-run groups exist so a pending opened/edited check can never
# be replaced. Head changes keep coalescing as before.
test_label_events_cannot_collapse_the_body_check_runs() {
  local opened edited labeled unlabeled synchronize reopened
  opened=$(resolve concurrency 8001 opened)
  edited=$(resolve concurrency 8002 edited)
  labeled=$(resolve concurrency 8003 labeled)
  unlabeled=$(resolve concurrency 8004 unlabeled)
  synchronize=$(resolve concurrency 8005 synchronize)
  reopened=$(resolve concurrency 8006 reopened)

  local group
  for group in "$opened" "$edited" "$labeled" "$unlabeled"; do
    assert_contains "$group" "	true" "a body or label event stopped cancelling in progress"
  done
  assert_not_equals "${opened%%	*}" "${labeled%%	*}" \
    "a labeled event can replace a pending opened check"
  assert_not_equals "${edited%%	*}" "${labeled%%	*}" \
    "a labeled event can replace a pending edited check"
  assert_not_equals "${opened%%	*}" "${unlabeled%%	*}" \
    "an unlabeled event can replace a pending opened check"
  assert_not_equals "${labeled%%	*}" "${unlabeled%%	*}" \
    "a label added and then removed collapses into one check"
  assert_not_equals "${synchronize%%	*}" "${labeled%%	*}" \
    "a labeled event can replace a pending head-change check"
  assert_equals "${synchronize%%	*}" "${reopened%%	*}" \
    "head-change events stopped coalescing into one group"
  assert_not_equals "$(resolve concurrency 8007 labeled 3006)" \
    "$(resolve concurrency 8007 labeled 4242)" \
    "two pull requests share one label-event concurrency group"
  pass "label events get their own groups and cannot collapse the body or head checks"
}

test_check_needs_no_write_permission() {
  assert_equals "contents=read,pull-requests=read" "$(resolve permissions)" \
    "the marker branch changed the workflow's permissions"
  pass "reading the marker needs no new write permission"
}

fetch_shared_verifier() {
  command -v curl >/dev/null 2>&1 || fail "curl is required to exercise the pinned shared action"
  command -v python3 >/dev/null 2>&1 || fail "python3 is required to exercise the pinned shared action"
  curl --fail --silent --show-error --location \
    "https://raw.githubusercontent.com/kunchenguid/no-mistakes/${ACTION_REF}/.github/actions/require-no-mistakes/verify.py" \
    > "$VERIFY" || fail "could not fetch the pinned shared action verifier"
  [ -s "$VERIFY" ] || fail "the pinned shared action verifier was empty"
}

run_verifier() {
  local body=$1 head=$2
  PR_BODY="$body" PR_HEAD_SHA="$head" PR_AUTHOR=regression PR_NUMBER=3006 \
    python3 "$VERIFY" 2>&1
}

test_matching_head_and_completed_steps_pass() {
  local body output rc
  body="$SIGNATURE
<!-- no-mistakes-pipeline-attestation:v1 {\"head_sha\":\"$NEW_SHA\",\"steps\":$COMPLETED_STEPS} -->"
  rc=0
  output=$(run_verifier "$body" "$NEW_SHA") || rc=$?
  expect_code 0 "$rc" "shared action rejected an attestation bound to the current PR head"
  assert_contains "$output" "Found structurally compliant pipeline step attestation." \
    "shared action did not report the matching attestation as compliant"
  pass "shared action accepts a matching head_sha with completed required steps"
}

test_mismatched_head_fails_with_both_shas() {
  local body output rc
  body="$SIGNATURE
<!-- no-mistakes-pipeline-attestation:v1 {\"head_sha\":\"$OLD_SHA\",\"steps\":$COMPLETED_STEPS} -->"
  rc=0
  output=$(run_verifier "$body" "$NEW_SHA") || rc=$?
  [ "$rc" -ne 0 ] || fail "shared action accepted an attestation from a different PR head"
  assert_contains "$output" "$OLD_SHA" \
    "mismatched-head failure did not name the attestation head SHA"
  assert_contains "$output" "$NEW_SHA" \
    "mismatched-head failure did not name the actual PR head SHA"
  pass "shared action rejects a mismatched head_sha and names both SHAs"
}

test_missing_head_fails() {
  local body output rc
  body="$SIGNATURE
<!-- no-mistakes-pipeline-attestation:v1 {\"steps\":$COMPLETED_STEPS} -->"
  rc=0
  output=$(run_verifier "$body" "$NEW_SHA") || rc=$?
  [ "$rc" -ne 0 ] || fail "shared action accepted an attestation without head_sha"
  assert_contains "$output" "structured pipeline step attestation" \
    "missing-head failure did not explain that the attestation is invalid"
  pass "shared action rejects an attestation with no head_sha"
}

write_resolver
test_label_changes_re_evaluate_the_check
test_marker_label_passes_without_running_the_signature_action
test_unmarked_pr_still_reaches_the_signature_action
test_only_the_exact_marker_waives_the_signature_action
test_bot_authors_stay_exempt
test_label_events_cannot_collapse_the_body_check_runs
test_check_needs_no_write_permission

fetch_shared_verifier
test_matching_head_and_completed_steps_pass
test_mismatched_head_fails_with_both_shas
test_missing_head_fails
