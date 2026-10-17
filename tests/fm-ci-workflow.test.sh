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
# They also hold the fork opt-out: the repository variables FM_CI_SKIP_PUSH and
# FM_CI_SKIP_MACOS let a fork skip the push run and the macOS job through a
# job-level condition, while with neither set every job runs exactly as before.
#
# The workflow is parsed as YAML and its concurrency and job-level `if`
# expressions are resolved against simulated pull_request and push contexts,
# so the assertions describe what GitHub would do, not how the file happens
# to be spelled.
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

# Evaluate the subset of GitHub's expression language that ci.yml uses -
# string literals, context lookups, the status functions, !, ==, !=, &&,
# ||, and parentheses - against a simulated context hash, following the
# documented operator precedence, the case-insensitive string comparison, and
# the `a || b` fallback that returns the first truthy operand rather than a
# boolean. The status functions read the simulated outcome of the needed jobs
# from the context key "needs.status" (success, failure, or cancelled), which
# defaults to success. Each ruby -e below prepends this so every resolver shares one
# evaluator.
# shellcheck disable=SC2016  # the ${{ }} below is Ruby text, not a shell expansion
EXPRESSION_RUBY='
require "strscan"
class Expression
  def self.evaluate(source, context)
    new(source, context).parse
  end

  STATUS_FUNCTIONS = %w[always() success() failure() cancelled()].freeze

  # A job or step `if` is a bare expression or one wrapped in ${{ }}, an
  # absent condition means the job runs, and a condition that calls no status
  # function gets the implicit success() check GitHub documents.
  def self.condition(raw, context)
    source = raw.to_s.strip
    source = Regexp.last_match(1) if source =~ /\A\$\{\{(.*)\}\}\z/m
    source = "success()" if source.empty?
    source = "success() && (#{source})" unless new(source, context).status_check?
    truthy?(evaluate(source, context))
  end

  # A result is truthy unless it is false, nil, or the empty string.
  def self.truthy?(value)
    value != false && !value.nil? && value != ""
  end

  def initialize(source, context)
    @context = context
    @tokens = []
    scanner = StringScanner.new(source)
    until scanner.eos?
      next if scanner.skip(/\s+/)
      if scanner.scan(/\x27([^\x27]*)\x27/) then @tokens << [:string, scanner[1]]
      elsif scanner.scan(/\|\||&&|==|!=|[()!]/) then @tokens << [:operator, scanner.matched]
      elsif scanner.scan(/[A-Za-z_][\w.\-]*(?:\(\))?/) then @tokens << [:name, scanner.matched]
      else raise "unsupported expression syntax at: #{scanner.rest}"
      end
    end
  end

  def status_check?
    @tokens.any? { |kind, value| kind == :name && STATUS_FUNCTIONS.include?(value) }
  end

  def parse
    result = parse_or
    raise "unexpected trailing token: #{@tokens.first.inspect}" unless @tokens.empty?
    result
  end

  private

  def take?(operator)
    return false unless @tokens.first == [:operator, operator]
    @tokens.shift
    true
  end

  def parse_or
    left = parse_and
    while take?("||")
      right = parse_and
      left = Expression.truthy?(left) ? left : right
    end
    left
  end

  def parse_and
    left = parse_comparison
    while take?("&&")
      right = parse_comparison
      left = Expression.truthy?(left) ? right : left
    end
    left
  end

  def parse_comparison
    left = parse_unary
    loop do
      operator = ["==", "!="].find { |candidate| take?(candidate) } or break
      right = parse_unary
      unless left.class == right.class
        raise "the resolver only compares operands of one type: #{left.inspect} #{operator} #{right.inspect}"
      end
      equal = left.is_a?(String) ? left.casecmp?(right) : left == right
      left = operator == "==" ? equal : !equal
    end
    left
  end

  def parse_unary
    return !Expression.truthy?(parse_unary) if take?("!")
    parse_primary
  end

  def parse_primary
    if take?("(")
      inner = parse_or
      raise "missing closing parenthesis" unless take?(")")
      return inner
    end
    kind, value = @tokens.shift
    raise "expected an operand, got #{kind.inspect}" unless kind == :string || kind == :name
    return value if kind == :string
    if STATUS_FUNCTIONS.include?(value)
      status = @context.fetch("needs.status", "success")
      return value == "always()" || value == "#{status}()"
    end
    raise "unresolvable context reference: #{value}" unless @context.key?(value)
    @context.fetch(value)
  end
end
'

# Resolve the workflow's concurrency contract under one simulated event and
# print "<group><TAB><cancel-in-progress>".
resolve_concurrency() {
  local event=$1 pr_number=$2 run_id=$3
  ruby -ryaml -e "$EXPRESSION_RUBY" -e '
doc = YAML.load_file(ARGV[0])
concurrency = doc.fetch("concurrency")
context = {
  "github.workflow" => doc.fetch("name"),
  "github.event_name" => ARGV[1],
  "github.event.pull_request.number" => ARGV[2],
  "github.run_id" => ARGV[3],
}

interpolate = lambda do |raw|
  raw.to_s.gsub(/\$\{\{(.+?)\}\}/) { Expression.evaluate(Regexp.last_match(1), context).to_s }
end

puts [interpolate.call(concurrency.fetch("group")),
      interpolate.call(concurrency.fetch("cancel-in-progress"))].join("\t")
' "$CI_WORKFLOW" "$event" "$pr_number" "$run_id"
}

# Print, one per line in workflow order, the jobs whose job-level `if`
# resolves true under one simulated event and fork variable setting; an unset
# repository variable reads as the empty string, as GitHub documents.
jobs_running_under() {  # <event> <FM_CI_SKIP_PUSH> <FM_CI_SKIP_MACOS>
  ruby -ryaml -e "$EXPRESSION_RUBY" -e '
# A full round: every change-scope verdict true and a non-empty selection, so
# what this resolves is the fork opt-out rather than the scope classifier,
# which tests above own.
context = {
  "github.event_name" => ARGV[1],
  "vars.FM_CI_SKIP_PUSH" => ARGV[2],
  "vars.FM_CI_SKIP_MACOS" => ARGV[3],
  "needs.changes.outputs.behavior" => "true",
  "needs.changes.outputs.full" => "true",
  "needs.changes.outputs.herdr" => "true",
  "needs.changes.outputs.macos" => "true",
  "needs.changes.outputs.parallel" => "true",
  "needs.changes.outputs.selected_matrix" => "{\"include\":[]}",
}
YAML.load_file(ARGV[0]).fetch("jobs").each do |name, job|
  puts name if Expression.condition(job["if"], context)
end
' "$CI_WORKFLOW" "$1" "$2" "$3"
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
# The detection job carries no scope verdict of its own - it produces them -
# so the fork opt-out is its whole condition.
raise "the change-scope job must be gated on the fork opt-out alone, got #{scope["if"].inspect}" unless scope.fetch("if") == "${{ !(github.event_name == 'push' && vars.FM_CI_SKIP_PUSH == '1') }}"
expected_outputs = %w[behavior full herdr macos parallel selected_matrix]
raise "the change-scope job must publish every gate output" unless scope.fetch("outputs").keys.sort == expected_outputs

# Which verdict gates which lane. The sixteen serial shards run on `full`,
# which only a push to main, the nightly schedule or an unrecognized event
# sets. The two parallel lanes run on the wider `parallel`, because they are
# also the pull request's bounded fallback when no selection can be trusted,
# so gating them on `full` would leave that fallback with no behavior coverage
# at all.
# Every gated lane carries the fork opt-out in the same condition, because a
# job takes exactly one `if:`; the scope verdict and the opt-out must agree
# before the lane runs.
skip_push = "!(github.event_name == 'push' && vars.FM_CI_SKIP_PUSH == '1')"
gated_on = {
  "lint" => "needs.changes.outputs.behavior == 'true'",
  "tests-portable-parallel-1" => "needs.changes.outputs.parallel == 'true'",
  "tests-portable-parallel-2" => "needs.changes.outputs.parallel == 'true'",
  "tests-portable-serial" => "needs.changes.outputs.full == 'true'",
  "tests-herdr" => "needs.changes.outputs.herdr == 'true'",
  "tests-selected" => "needs.changes.outputs.selected_matrix != ''",
}
gated_on.each do |id, condition|
  job = jobs.fetch(id)
  raise "#{id} must need the change-scope job" unless Array(job.fetch("needs")).include?("changes")
  wanted = "${{ #{condition} && #{skip_push} }}"
  raise "#{id} must be gated on #{wanted}, got #{job.fetch("if")}" unless job.fetch("if") == wanted
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
wanted_macos = "${{ github.event_name != 'pull_request' && needs.changes.outputs.macos == 'true' && #{skip_push} && vars.FM_CI_SKIP_MACOS != '1' }}"
raise "the macOS job must be gated off pull requests, on its own output, and on both fork opt-outs" unless macos.fetch("if") == wanted_macos

guard = jobs.fetch("docs-guard")
raise "the docs guard must run exactly when the behavior suites are skipped" unless guard.fetch("if") == "${{ needs.changes.outputs.behavior == 'false' && !(github.event_name == 'push' && vars.FM_CI_SKIP_PUSH == '1') }}"

# These two carry no scope verdict, so the fork opt-out is their whole condition.
%w[test-coverage invariants].each do |id|
  raise "#{id} must be gated on the fork opt-out alone, got #{jobs.fetch(id)["if"].inspect}" unless jobs.fetch(id).fetch("if") == "${{ #{skip_push} }}"
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
raise "the CI gate must run on every event the round runs at all" unless gate.fetch("if") == "${{ always() && !(github.event_name == 'push' && vars.FM_CI_SKIP_PUSH == '1') }}"
needed = Array(gate.fetch("needs")).sort
expected = (jobs.keys - ["ci-gate"]).sort
raise "the CI gate must need every other job, missing #{(expected - needed).join(" ")}" unless needed == expected
RUBY
  pass "the CI gate always runs and covers every other job"
}

# The fork opt-out is opt-in: with neither variable set the round runs exactly
# the jobs its change-scope verdicts select, FM_CI_SKIP_PUSH=1 empties only the
# push run, and FM_CI_SKIP_MACOS=1 removes only the macOS job. A "-" in the
# table means the variable is unset.
test_fork_skip_variables_are_opt_in() {
  local event skip_push skip_macos expected want actual baseline
  workflow_jobs | grep -qx macos-stock-bash \
    || fail "the macOS job is missing from ci.yml, so the table below would prove nothing"
  while read -r event skip_push skip_macos expected; do
    [ "$skip_push" != - ] || skip_push=
    [ "$skip_macos" != - ] || skip_macos=
    # The baseline is this same event with neither variable set. Which lanes a
    # round runs is the change-scope job's call, so the opt-out is proved
    # against that round rather than against every job in the file.
    baseline=$(jobs_running_under "$event" '' '') \
      || fail "could not resolve the unset-variable baseline for $event"
    case $expected in
      unchanged) want=$baseline ;;
      none) want= ;;
      all-but-macos) want=$(printf '%s\n' "$baseline" | grep -vx macos-stock-bash) ;;
      *) fail "unknown expectation $expected" ;;
    esac
    actual=$(jobs_running_under "$event" "$skip_push" "$skip_macos") \
      || fail "could not resolve the job conditions for $event FM_CI_SKIP_PUSH=$skip_push FM_CI_SKIP_MACOS=$skip_macos"
    [ "$actual" = "$want" ] \
      || fail "$event with FM_CI_SKIP_PUSH=$skip_push FM_CI_SKIP_MACOS=$skip_macos must run $expected jobs"$'\n'"ran: $(printf '%s' "$actual" | tr '\n' ' ')"$'\n'"wanted: $(printf '%s' "$want" | tr '\n' ' ')"
  done <<'TABLE'
push         - - unchanged
pull_request - - unchanged
push         1 - none
pull_request 1 - unchanged
pull_request - 1 all-but-macos
push         - 1 all-but-macos
TABLE
  pass "the fork skip variables change nothing unless set, and each skips only its own run or job"
}

# Print true or false: whether one job's job-level `if` resolves true under
# one simulated event, fork variable setting, and outcome of its needed jobs.
job_runs_under() {  # <job> <event> <FM_CI_SKIP_PUSH> <FM_CI_SKIP_MACOS> <needs status>
  ruby -ryaml -e "$EXPRESSION_RUBY" -e '
context = {
  "github.event_name" => ARGV[2],
  "vars.FM_CI_SKIP_PUSH" => ARGV[3],
  "vars.FM_CI_SKIP_MACOS" => ARGV[4],
  "needs.status" => ARGV[5],
  "needs.changes.outputs.behavior" => "true",
  "needs.changes.outputs.full" => "true",
  "needs.changes.outputs.herdr" => "true",
  "needs.changes.outputs.macos" => "true",
  "needs.changes.outputs.parallel" => "true",
  "needs.changes.outputs.selected_matrix" => "{\"include\":[]}",
}
puts Expression.condition(YAML.load_file(ARGV[0]).fetch("jobs").fetch(ARGV[1])["if"], context)
' "$CI_WORKFLOW" "$@"
}

# The aggregate must keep running after a failed lane so its timing summary
# still lands, while the push skip still removes it from a skipped push run.
test_timing_aggregate_still_runs_after_a_failed_lane() {
  local event skip_push expected actual
  while read -r event skip_push expected; do
    [ "$skip_push" != - ] || skip_push=
    actual=$(job_runs_under tests-timing-aggregate "$event" "$skip_push" '' failure) \
      || fail "could not resolve the aggregate condition for $event FM_CI_SKIP_PUSH=$skip_push"
    [ "$actual" = "$expected" ] \
      || fail "after a failed lane, the aggregate on $event with FM_CI_SKIP_PUSH=$skip_push must resolve $expected, got $actual"
  done <<'TABLE'
pull_request - true
push         - true
push         1 false
TABLE
  pass "the timing aggregate still runs after a failed lane unless the push run is skipped"
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
test_fork_skip_variables_are_opt_in
test_timing_aggregate_still_runs_after_a_failed_lane
test_every_job_has_a_finite_timeout
test_every_job_belongs_to_exactly_one_timeout_tier
test_fast_tier_shares_one_short_tripwire
test_normal_tier_shares_one_budget
test_serial_tier_keeps_a_step_tripwire_under_a_job_backstop
test_heavy_tier_keeps_a_step_tripwire_under_a_job_backstop
test_change_scope_gates_are_job_level_and_consistent
test_ci_gate_always_reports_every_job
