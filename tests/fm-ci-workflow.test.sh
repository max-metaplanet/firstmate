#!/usr/bin/env bash
# Contract tests for .github/workflows/ci.yml's runner-spend safeguards.
#
# Origin: the 2026-09-12 GitHub Actions starvation incident. firstmate CI had no
# concurrency deduplication, so every superseded PR head kept its full job
# fan-out, and four jobs carried no timeout at all. These tests hold both
# safeguards: PR runs supersede within one PR while main pushes are never
# cancelled, and every CI job carries a finite hang tripwire drawn from the
# four-tier timeout policy that docs/fm-test-portable-shards.md "Timeouts"
# owns (fast, normal, serial, heavy), so no job drifts back to a one-off number.
#
# The workflow is parsed as YAML and its concurrency expressions are resolved
# against simulated pull_request and push contexts, so the assertions describe
# what GitHub would do, not how the file happens to be spelled.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CI_WORKFLOW="$ROOT/.github/workflows/ci.yml"
MACOS_ADVISORY_WORKFLOW="$ROOT/.github/workflows/macos-advisory.yml"
MACOS_CHECK="$ROOT/bin/fm-macos-stock-bash-check.sh"

assert_present "$CI_WORKFLOW" ".github/workflows/ci.yml is missing"
assert_present "$MACOS_ADVISORY_WORKFLOW" ".github/workflows/macos-advisory.yml is missing"
assert_present "$MACOS_CHECK" "bin/fm-macos-stock-bash-check.sh is missing"
command -v ruby >/dev/null 2>&1 \
  || fail "ruby is required to parse .github/workflows/ci.yml as YAML"
command -v jq >/dev/null 2>&1 \
  || fail "jq is required to run the CI gate's verdict script"

# Resolve the workflow's concurrency contract under one simulated event and
# print "<group><TAB><cancel-in-progress>". Only the two expression constructs
# this workflow uses are resolved: an `a || b` fallback and an `==` comparison.
resolve_concurrency() {
  local event=$1 pr_number=$2 run_id=$3
  ruby -ryaml -e '
doc = YAML.load_file(ARGV[0])
concurrency = doc.fetch("concurrency")
context = {
  "github.workflow" => doc.fetch("name"),
  "github.event_name" => ARGV[1],
  "github.event.pull_request.number" => ARGV[2],
  "github.run_id" => ARGV[3],
}

value = lambda do |token|
  token = token.strip
  next token[1..-2] if token.start_with?("\x27") && token.end_with?("\x27")
  raise "unresolvable context reference: #{token}" unless context.key?(token)
  context.fetch(token)
end

evaluate = lambda do |expression|
  expression = expression.strip
  if expression.include?("==")
    left, right = expression.split("==", 2)
    next value.call(left) == value.call(right) ? "true" : "false"
  end
  resolved = expression.split("||").map { |token| value.call(token) }.find { |v| !v.empty? }
  resolved.to_s
end

interpolate = lambda do |raw|
  raw.to_s.gsub(/\$\{\{(.+?)\}\}/) { evaluate.call(Regexp.last_match(1)) }
end

puts [interpolate.call(concurrency.fetch("group")),
      interpolate.call(concurrency.fetch("cancel-in-progress"))].join("\t")
' "$CI_WORKFLOW" "$event" "$pr_number" "$run_id"
}

job_timeout() {
  ruby -ryaml -e '
puts YAML.load_file(ARGV[0]).fetch("jobs").fetch(ARGV[1]).fetch("timeout-minutes", "none")
' "$CI_WORKFLOW" "$1"
}

# Tier membership is the executable inventory of the timeout policy: a new job
# must join a tier, and a job-level value outside these tiers is exactly the
# one-off number the policy removed.
FAST_TIER_JOBS='test-coverage invariants tests-timing-aggregate changes docs-guard ci-gate'
NORMAL_TIER_JOBS='lint tests-portable-parallel-1 tests-portable-parallel-2 tests-selected macos-stock-bash'
SERIAL_TIER_JOBS='tests-portable-serial'
HEAVY_TIER_JOBS='tests-herdr'

# Print the one timeout every listed job shares; fail on any disagreement.
tier_timeout() {  # <tier> <job>...
  local tier=$1 job first actual
  shift
  first=
  for job in "$@"; do
    actual=$(job_timeout "$job") || fail "could not read the $job timeout"
    case "$actual" in ''|*[!0-9]*) fail "$job ($tier tier) has no integer timeout, got $actual" ;; esac
    if [ -z "$first" ]; then
      first=$actual
    elif [ "$actual" != "$first" ]; then
      fail "$tier tier jobs must share one timeout, got $first and $actual ($job)"
    fi
  done
  printf '%s\n' "$first"
}

# Print every job id in the workflow, one per line.
workflow_jobs() {
  ruby -ryaml -e 'puts YAML.load_file(ARGV[0]).fetch("jobs").keys' "$CI_WORKFLOW"
}

group_of() { printf '%s\n' "$1" | cut -f1; }
cancel_of() { printf '%s\n' "$1" | cut -f2; }

test_pr_pushes_supersede_within_one_pr() {
  local first second
  first=$(resolve_concurrency pull_request 108 900001) || fail "could not resolve PR concurrency"
  second=$(resolve_concurrency pull_request 108 900002) || fail "could not resolve PR concurrency"
  [ "$(group_of "$first")" = "$(group_of "$second")" ] \
    || fail "two runs of one PR must share a concurrency group, got $(group_of "$first") and $(group_of "$second")"
  [ "$(cancel_of "$first")" = true ] \
    || fail "PR runs must cancel the in-progress run, got $(cancel_of "$first")"
  pass "a newer push to one PR supersedes that PR's in-flight CI"
}

test_separate_prs_do_not_cancel_each_other() {
  local one two
  one=$(resolve_concurrency pull_request 108 900001) || fail "could not resolve PR concurrency"
  two=$(resolve_concurrency pull_request 109 900003) || fail "could not resolve PR concurrency"
  [ "$(group_of "$one")" != "$(group_of "$two")" ] \
    || fail "distinct PRs must not share a concurrency group ($(group_of "$one"))"
  pass "distinct PRs get distinct concurrency groups"
}

test_main_pushes_are_never_cancelled() {
  local first second
  first=$(resolve_concurrency push '' 900010) || fail "could not resolve push concurrency"
  second=$(resolve_concurrency push '' 900011) || fail "could not resolve push concurrency"
  [ "$(group_of "$first")" != "$(group_of "$second")" ] \
    || fail "each main push must get its own concurrency group, got $(group_of "$first") twice"
  [ "$(cancel_of "$first")" = false ] \
    || fail "push runs must never cancel an in-progress run, got $(cancel_of "$first")"
  pass "every main push keeps its own group and is never cancelled"
}

test_every_job_has_a_finite_timeout() {
  local reported
  reported=$(ruby -ryaml -e '
YAML.load_file(ARGV[0]).fetch("jobs").each do |name, job|
  timeout = job["timeout-minutes"]
  next if timeout.is_a?(Integer) && timeout > 0
  puts "#{name}: #{timeout.inspect}"
end
' "$CI_WORKFLOW") || fail "could not read job timeouts from ci.yml"
  [ -z "$reported" ] || fail "these CI jobs have no finite hang tripwire:"$'\n'"$reported"
  pass "every ci.yml job carries a finite timeout"
}

# Every job sits in exactly one tier, and the workflow carries exactly four
# distinct job-level timeouts: one per tier, no one-off numbers.
test_every_job_belongs_to_exactly_one_timeout_tier() {
  local expected actual distinct
  # shellcheck disable=SC2086
  expected=$(printf '%s\n' $FAST_TIER_JOBS $NORMAL_TIER_JOBS $SERIAL_TIER_JOBS $HEAVY_TIER_JOBS | LC_ALL=C sort)
  [ "$(printf '%s\n' "$expected" | LC_ALL=C sort -u)" = "$expected" ] \
    || fail "a job is listed in more than one timeout tier:"$'\n'"$expected"
  actual=$(workflow_jobs | LC_ALL=C sort) || fail "could not list ci.yml jobs"
  [ "$actual" = "$expected" ] \
    || fail "ci.yml jobs and the timeout tiers disagree; every job must join one tier"$'\n'"workflow: $(printf '%s' "$actual" | tr '\n' ' ')"$'\n'"tiers: $(printf '%s' "$expected" | tr '\n' ' ')"
  distinct=$(for job in $expected; do job_timeout "$job"; done | LC_ALL=C sort -u | wc -l | tr -d ' ')
  [ "$distinct" = 4 ] \
    || fail "ci.yml must carry exactly four distinct job timeouts (fast, normal, serial, heavy), got $distinct"
  pass "every ci.yml job belongs to one of the four timeout tiers"
}

# Fast tier: seconds-long checks share one short tripwire in the 5-10 minute band.
test_fast_tier_shares_one_short_tripwire() {
  local fast
  # shellcheck disable=SC2086
  fast=$(tier_timeout fast $FAST_TIER_JOBS) || exit 1
  [ "$fast" -ge 5 ] && [ "$fast" -le 10 ] \
    || fail "fast tier must be a 5-10 minute hang tripwire, got $fast"
  pass "fast tier jobs share one $fast minute tripwire"
}

# Normal tier: every lint lane, portable parallel shard and the macOS snapshot
# lane share ONE fixed 30-minute budget, above the fast tier. That budget is a
# hang tripwire, not a packing estimate. The portable serial shards left this
# tier for the serial tier below; nothing else may follow them out.
test_normal_tier_shares_one_budget() {
  local fast normal
  # shellcheck disable=SC2086
  fast=$(tier_timeout fast $FAST_TIER_JOBS) || exit 1
  # shellcheck disable=SC2086
  normal=$(tier_timeout normal $NORMAL_TIER_JOBS) || exit 1
  [ "$normal" -gt "$fast" ] \
    || fail "normal tier ($normal) must exceed the fast tier ($fast)"
  [ "$normal" = 30 ] \
    || fail "normal tier must be the single 30-minute shared budget, got $normal"
  pass "normal tier jobs share one $normal minute budget"
}

# Serial tier: the portable serial shards carry their own job bound above the
# normal tier, because one indivisible script sets their floor.
# tests/fm-supervision-host.test.sh measured 16.9-22.6 minutes on healthy
# runners and about 35 minutes on the slow runners that cancelled serial 2 at
# the old 30-minute bound, so no partition of the lane fits the normal tier.
# Like the Herdr lane, the shard-run step owns a tighter tripwire under that
# bound, so a wedged shard fails the step with its captured log output rather
# than cancelling the job. The timing JSON is written only after every script
# finishes, so a timed-out shard still uploads no timing artifact.
test_serial_tier_keeps_a_step_tripwire_under_a_job_backstop() {
  local normal serial step
  # shellcheck disable=SC2086
  normal=$(tier_timeout normal $NORMAL_TIER_JOBS) || exit 1
  # shellcheck disable=SC2086
  serial=$(tier_timeout serial $SERIAL_TIER_JOBS) || exit 1
  [ "$serial" -gt "$normal" ] \
    || fail "serial tier ($serial) must exceed the normal tier ($normal)"
  [ "$serial" = 45 ] \
    || fail "serial tier must be the single 45-minute shared budget, got $serial"
  step=$(ruby -ryaml -e '
steps = YAML.load_file(ARGV[0]).fetch("jobs").fetch(ARGV[1]).fetch("steps")
index = steps.index { |s| s["id"] == "run-portable-serial-shard" }
raise "no run-portable-serial-shard step" unless index
upload = steps.index { |s| s["id"] == "upload-portable-serial-timing" }
raise "no upload-portable-serial-timing step" unless upload
raise "the timing upload must follow the shard-run step" unless upload > index
raise "the timing upload must run under always()" unless steps[upload]["if"].to_s.strip == "always()"
puts steps[index].fetch("timeout-minutes", "none")
' "$CI_WORKFLOW" tests-portable-serial) || fail "could not read the portable serial shard-run step"
  case "$step" in ''|*[!0-9]*) fail "the portable serial shard-run step needs its own timeout-minutes, got $step" ;; esac
  [ "$step" = 40 ] \
    || fail "the portable serial shard-run step must be the 40-minute tripwire, got $step"
  [ "$step" -lt "$serial" ] \
    || fail "the shard-run tripwire ($step) must stay under the serial job bound ($serial)"
  pass "serial tier jobs share one $serial minute bound with a $step minute step tripwire"
}

# Heavy tier: Herdr alone carries a job-level last-resort backstop above the
# normal tier, while its family-run step owns a tighter tripwire so the
# always() cleanup and timing upload still run after a hang.
test_heavy_tier_keeps_a_step_tripwire_under_a_job_backstop() {
  local normal heavy step
  # shellcheck disable=SC2086
  normal=$(tier_timeout normal $NORMAL_TIER_JOBS) || exit 1
  # shellcheck disable=SC2086
  heavy=$(tier_timeout heavy $HEAVY_TIER_JOBS) || exit 1
  [ "$heavy" -gt "$normal" ] \
    || fail "heavy tier backstop ($heavy) must exceed the normal tier ($normal)"
  [ "$heavy" -ge 60 ] && [ "$heavy" -le 75 ] \
    || fail "heavy tier backstop must stay a 60-75 minute last resort, got $heavy"
  step=$(ruby -ryaml -e '
steps = YAML.load_file(ARGV[0]).fetch("jobs").fetch(ARGV[1]).fetch("steps")
index = steps.index { |s| s["id"] == "run-real-herdr-family" }
raise "no run-real-herdr-family step" unless index
teardown = steps.index { |s| s["id"] == "cleanup-herdr-lab-sessions" }
raise "no cleanup-herdr-lab-sessions step" unless teardown
raise "teardown must follow the family-run step" unless teardown > index
raise "teardown must run under always()" unless steps[teardown]["if"].to_s.strip == "always()"
puts steps[index].fetch("timeout-minutes", "none")
' "$CI_WORKFLOW" tests-herdr) || fail "could not read the Herdr family-run step"
  case "$step" in ''|*[!0-9]*) fail "the Herdr family-run step needs its own timeout-minutes, got $step" ;; esac
  [ "$step" = 20 ] \
    || fail "the Herdr family-run step must be the 20-minute tripwire, got $step"
  [ "$step" -lt "$heavy" ] \
    || fail "the Herdr step tripwire ($step) must stay below the job backstop ($heavy)"
  pass "Herdr keeps a $step minute step tripwire under a $heavy minute job backstop"
}

# The change-scope gates must stay job-level conditions fed by one always-run
# detection job. A workflow-level paths: filter never creates the workflow, so a
# check required by branch protection would stay pending forever, while a job
# skipped by `if:` reports "skipped" and satisfies protection. The gated jobs
# must also agree on which output gates them, or a lane could be skipped by a
# verdict that never covered its sources.
test_change_scope_gates_are_job_level_and_consistent() {
  ruby -ryaml - "$CI_WORKFLOW" <<'RUBY' || fail "change-scope gate contract"
workflow = YAML.load_file(ARGV[0])
jobs = workflow.fetch("jobs")

on = workflow.fetch(true) { workflow.fetch("on") }
on.each do |event, spec|
  next unless spec.is_a?(Hash)
  raise "#{event} must not carry a workflow-level paths filter" if spec.key?("paths") || spec.key?("paths-ignore")
end

scope = jobs.fetch("changes")
raise "the change-scope job must not be gated itself" if scope.key?("if")
expected_outputs = %w[behavior full herdr macos selected_matrix]
raise "the change-scope job must publish every gate output" unless scope.fetch("outputs").keys.sort == expected_outputs

# Which verdict gates which lane. The complete sharded suite runs on `full`,
# which the classifier turns off only when it produced a trusted selection, so
# a lane gated on `behavior` would keep running beside that selection and a
# lane gated on `full` can never run beside it.
gated_on = {
  "lint" => "needs.changes.outputs.behavior == 'true'",
  "tests-portable-parallel-1" => "needs.changes.outputs.full == 'true'",
  "tests-portable-parallel-2" => "needs.changes.outputs.full == 'true'",
  "tests-portable-serial" => "needs.changes.outputs.full == 'true'",
  "tests-herdr" => "needs.changes.outputs.herdr == 'true'",
  "tests-selected" => "needs.changes.outputs.selected_matrix != ''",
}
gated_on.each do |id, condition|
  job = jobs.fetch(id)
  raise "#{id} must need the change-scope job" unless Array(job.fetch("needs")).include?("changes")
  raise "#{id} must be gated on #{condition}, got #{job.fetch("if")}" unless job.fetch("if") == condition
end

# The change-scoped lane's matrix comes from the classifier, and a matrix
# expression resolves before the job's own gate does, so it must stay total:
# fromJSON of an empty output would fail the whole run instead of skipping.
selected = jobs.fetch("tests-selected")
matrix = selected.fetch("strategy").fetch("matrix").to_s
raise "the selected lane must build its matrix from the classifier" unless matrix.include?("needs.changes.outputs.selected_matrix")
raise "the selected lane's matrix must have a literal fallback" unless matrix.match?(/\|\|\s*'\{/)
raise "selected failures must not cancel another packed job" unless selected.fetch("strategy").fetch("fail-fast") == false

# Non-blocking on a pull request, blocking everywhere else. The job is gated
# off the pull request path entirely, because the gate below cannot stop
# waiting for a job that runs.
macos = jobs.fetch("macos-stock-bash")
raise "the macOS job must need the change-scope job" unless Array(macos.fetch("needs")).include?("changes")
raise "the macOS job must be gated off pull requests and on its own output" unless macos.fetch("if") == "github.event_name != 'pull_request' && needs.changes.outputs.macos == 'true'"

guard = jobs.fetch("docs-guard")
raise "the docs guard must run exactly when the behavior suites are skipped" unless guard.fetch("if") == "needs.changes.outputs.behavior == 'false'"

%w[test-coverage invariants].each do |id|
  raise "#{id} must stay ungated" if jobs.fetch(id).key?("if")
end
RUBY
  pass "the change-scope gates stay job-level and agree on their verdicts"
}

# One check must always report the whole round, so a gated-off job never looks
# like a missing result to branch protection or to a reviewer.
test_ci_gate_always_reports_every_job() {
  ruby -ryaml - "$CI_WORKFLOW" <<'RUBY' || fail "CI gate contract"
jobs = YAML.load_file(ARGV[0]).fetch("jobs")
gate = jobs.fetch("ci-gate")
raise "the CI gate must run on every event" unless gate.fetch("if") == "always()"
needed = Array(gate.fetch("needs")).sort
expected = (jobs.keys - ["ci-gate"]).sort
raise "the CI gate must need every other job, missing #{(expected - needed).join(" ")}" unless needed == expected
RUBY
  pass "the CI gate always runs and covers every other job"
}

test_ci_matrices_match_executable_partitions() {
  ruby -ryaml -ropen3 - "$CI_WORKFLOW" "$ROOT" <<'RUBY' || fail "CI partition contract"
jobs = YAML.load_file(ARGV[0]).fetch("jobs")
root = ARGV[1]
serial = jobs.fetch("tests-portable-serial").fetch("strategy")
raise "serial failures must not cancel other shards" unless serial.fetch("fail-fast") == false
matrix = serial.fetch("matrix")
raise "unexpected serial dimensions" unless matrix.keys == ["shard"]
shards = matrix.fetch("shard")
lanes, status = Open3.capture2(File.join(root, "bin/fm-test-run.sh"), "--list-lanes")
raise "cannot list runner lanes" unless status.success?
actual = lanes.lines.map(&:strip).select { |l| l.match?(/\Aportable-serial-\d+of\d+\z/) }
expected = shards.map { |s| "portable-serial-#{s}of#{shards.length}" }
raise "CI matrix and runner disagree" unless actual.sort == expected.sort
lint = jobs.fetch("lint").fetch("strategy")
raise "lint failures must not cancel another partition" unless lint.fetch("fail-fast") == false
matrix = lint.fetch("matrix")
raise "unexpected lint dimensions" unless matrix.keys == ["partition"]
parts = matrix.fetch("partition")
roots = parts.flat_map do |p|
  output, result = Open3.capture2(File.join(root, "bin/fm-lint.sh"), "--partition", "#{p}of#{parts.length}", "--list-files")
  raise "unsupported lint partition" unless result.success?
  output.lines.map(&:strip)
end
canonical, result = Open3.capture2({"CI" => "true"}, File.join(root, "bin/fm-lint.sh"), "--list-files")
raise "lint matrix loses or duplicates canonical roots" unless result.success? && roots.sort == canonical.lines.map(&:strip).sort
RUBY
  pass "CI matrices cover every executable serial lane and canonical lint root exactly once"
}

# Run the CI gate's own verdict script against a simulated needs context,
# rather than reading the file for the words it contains. The script is the
# round's single verdict, so what it does with a result is what matters.
run_ci_gate() {  # <event> <needs json>
  local script
  script=$(ruby -ryaml -e '
steps = YAML.load_file(ARGV[0]).fetch("jobs").fetch("ci-gate").fetch("steps")
step = steps.find { |s| s.key?("run") }
raise "the CI gate has no run step" unless step
puts step.fetch("run")
' "$CI_WORKFLOW") || fail "could not read the CI gate verdict script"
  FM_CI_NEEDS=$2 FM_CI_EVENT_NAME=$1 bash -c "$script" >/dev/null 2>&1
}

# Every job green, with the macOS snapshot skipped as it is on a pull request.
GATE_NEEDS_MACOS_SKIPPED='{"changes":{"result":"success"},"tests-selected":{"result":"success"},"macos-stock-bash":{"result":"skipped"}}'
GATE_NEEDS_MACOS_GREEN='{"changes":{"result":"success"},"tests-selected":{"result":"success"},"macos-stock-bash":{"result":"success"}}'
GATE_NEEDS_ONE_FAILED='{"changes":{"result":"success"},"tests-selected":{"result":"failure"},"macos-stock-bash":{"result":"success"}}'

test_ci_gate_fails_the_round_when_any_job_failed() {
  run_ci_gate pull_request "$GATE_NEEDS_ONE_FAILED" \
    && fail "the CI gate must fail the round when a job it needs failed"
  pass "the CI gate fails the round when a job it needs failed"
}

# The macOS snapshot is deliberately off the pull request path, so the round's
# verdict must accept its absence there and require its success everywhere
# else. Without the second half, taking it off pull requests would quietly
# take it out of the project's coverage altogether.
test_macos_snapshot_is_non_blocking_on_prs_and_required_elsewhere() {
  run_ci_gate pull_request "$GATE_NEEDS_MACOS_SKIPPED" \
    || fail "a pull request round must pass with the macOS snapshot skipped"
  run_ci_gate push "$GATE_NEEDS_MACOS_SKIPPED" \
    && fail "a push round must not pass with the macOS snapshot skipped"
  run_ci_gate schedule "$GATE_NEEDS_MACOS_SKIPPED" \
    && fail "a scheduled round must not pass with the macOS snapshot skipped"
  run_ci_gate push "$GATE_NEEDS_MACOS_GREEN" \
    || fail "a push round must pass once the macOS snapshot is green"
  pass "the macOS snapshot is non-blocking on pull requests and required elsewhere"
}

# Change-scoped selection narrows what a pull request runs, so something must
# still run the complete suite on a schedule rather than only when main moves.
test_a_nightly_schedule_runs_the_complete_suite() {
  ruby -ryaml - "$CI_WORKFLOW" <<'RUBY' || fail "nightly schedule contract"
workflow = YAML.load_file(ARGV[0])
on = workflow.fetch(true) { workflow.fetch("on") }
schedule = on["schedule"]
raise "ci.yml must carry a schedule trigger" unless schedule.is_a?(Array) && !schedule.empty?
crons = schedule.map { |entry| entry.fetch("cron") }
raise "every schedule entry needs a cron" if crons.any? { |c| c.to_s.strip.empty? }
raise "the schedule must be daily, got #{crons.inspect}" unless crons.all? { |c| c.split(/\s+/).length == 5 && c.split(/\s+/)[2..4] == %w[* * *] }
RUBY
  pass "a nightly schedule keeps the complete suite running"
}


# The stock-Bash check runs in two places - blocking on push to main, advisory
# on a pull request - and the whole point of the split is that the advisory
# half cannot hold up a pull request round. These hold that shape: the two
# halves must run the same check, the advisory one must live outside the CI
# gate's verdict, and it must still carry a finite bound of its own.
test_macos_advisory_runs_the_same_check_outside_the_prs_verdict() {
  ruby -ryaml - "$CI_WORKFLOW" "$MACOS_ADVISORY_WORKFLOW" <<'RUBY' || fail "macOS advisory contract"
ci = YAML.load_file(ARGV[0])
advisory = YAML.load_file(ARGV[1])

on = advisory.fetch(true) { advisory.fetch("on") }
raise "the advisory workflow must run on pull requests" unless on.key?("pull_request")
raise "the advisory workflow must not run on push" if on.key?("push")

jobs = advisory.fetch("jobs")
job = jobs.fetch("macos-stock-bash-advisory")
timeout = job["timeout-minutes"]
raise "the advisory job needs a finite hang tripwire, got #{timeout.inspect}" unless timeout.is_a?(Integer) && timeout > 0

# Same check, one owner: both halves invoke the same script rather than
# carrying their own copy of the assertions.
run_of = lambda do |j|
  step = j.fetch("steps").find { |s| s.key?("run") }
  raise "no run step" unless step
  step.fetch("run")
end
blocking = run_of.call(ci.fetch("jobs").fetch("macos-stock-bash"))
advisory_run = run_of.call(job)
owner = "bin/fm-macos-stock-bash-check.sh"
raise "the blocking half must run #{owner}" unless blocking.include?(owner)
raise "the advisory half must run the same #{owner}" unless advisory_run.include?(owner)

# The CI gate is ci.yml's verdict and can only wait for ci.yml's own jobs, so
# an advisory job defined in another workflow is structurally outside it.
gate_needs = Array(ci.fetch("jobs").fetch("ci-gate").fetch("needs"))
raise "the advisory job must not be part of the CI gate" if gate_needs.include?("macos-stock-bash-advisory")
RUBY
  pass "the macOS advisory half runs the same check outside the pull request's verdict"
}

# The check only means something under the stock interpreter, so running it
# under anything else must refuse rather than report a pass that proves nothing.
test_macos_check_refuses_a_non_stock_interpreter() {
  local out rc=0
  out=$(bash "$MACOS_CHECK" 2>&1) || rc=$?
  if [ "${BASH_VERSINFO[0]}" -ge 4 ]; then
    [ "$rc" -ne 0 ] \
      || fail "the stock-Bash check must refuse a non-3.2 interpreter"$'\n'"$out"
    assert_contains "$out" 'expected stock macOS Bash 3.2.57' \
      "the refusal must name the interpreter it needed"$'\n'"$out"
  fi

  rc=0
  out=$(bash "$MACOS_CHECK" --nope 2>&1) || rc=$?
  [ "$rc" -eq 2 ] \
    || fail "an unknown argument must be refused with status 2, got $rc"$'\n'"$out"

  rc=0
  out=$(bash "$MACOS_CHECK" --help 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "--help must succeed, got $rc"$'\n'"$out"
  assert_contains "$out" 'stock macOS Bash 3.2 compatibility check' \
    "--help must describe the check"$'\n'"$out"
  pass "the stock-Bash check refuses a non-stock interpreter and an unknown argument"
}

test_ci_matrices_match_executable_partitions
test_macos_advisory_runs_the_same_check_outside_the_prs_verdict
test_macos_check_refuses_a_non_stock_interpreter
test_ci_gate_fails_the_round_when_any_job_failed
test_macos_snapshot_is_non_blocking_on_prs_and_required_elsewhere
test_a_nightly_schedule_runs_the_complete_suite
test_pr_pushes_supersede_within_one_pr
test_separate_prs_do_not_cancel_each_other
test_main_pushes_are_never_cancelled
test_every_job_has_a_finite_timeout
test_every_job_belongs_to_exactly_one_timeout_tier
test_fast_tier_shares_one_short_tripwire
test_normal_tier_shares_one_budget
test_serial_tier_keeps_a_step_tripwire_under_a_job_backstop
test_heavy_tier_keeps_a_step_tripwire_under_a_job_backstop
test_change_scope_gates_are_job_level_and_consistent
test_ci_gate_always_reports_every_job
