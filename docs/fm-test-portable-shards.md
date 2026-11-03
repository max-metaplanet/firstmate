# Firstmate portable test shards

`bin/fm-test-run.sh` owns portable lane composition and execution.
`bin/fm-test-isolation-proof.sh` owns the proven-isolated candidate set.

## Verification inputs

Balance hints come from serial runs of the real lanes on `ubuntu-latest`.
The concurrent isolation proof in [fm-test-isolation-proof.md](fm-test-isolation-proof.md) establishes concurrency safety, not serial CI duration.
Local timings are not interchangeable with CI timings: platform and machine load can affect each script differently and change their relative weights.

Both hint tables were refreshed on 2026-09-30 from five Ubuntu CI runs: [36583881812](https://github.com/kunchenguid/firstmate/actions/runs/36583881812), [36658498535](https://github.com/kunchenguid/firstmate/actions/runs/36658498535), [36663947738](https://github.com/kunchenguid/firstmate/actions/runs/36663947738), [36664663190](https://github.com/kunchenguid/firstmate/actions/runs/36664663190), and [36669175457](https://github.com/kunchenguid/firstmate/actions/runs/36669175457).
Use the slowest successful `duration_ms` per script across their uploaded portable timing artifacts and completed `FM_TEST_END` log markers, with the two version/platform exceptions below.
All artifact records were cross-checked against the corresponding job's markers.
This covers all 24 parallel and 201 serial members; an existing live-capability skip is a portable-runner measurement, not a timing claim for the unavailable live integration.
Observed maxima provide conservative packing weights, not an upper bound on future durations.

Two serial-5 jobs were cancelled at their 30-minute cap and uploaded no artifact.
Their completed log markers supplement the complete runs, but a cancelled job's wall time is only a lower bound and its unfinished or never-started scripts have no completed sample.
A failed script's duration is excluded even when its lane uploaded an artifact.
In particular, run 36664663190's serial 5 finished in 22m15s with an assertion failure, not a timeout; treating that as a healthy whole-lane sample would hide the failure.
Collect successful per-script measurements for every member before calculating a split.

The serial hints were refreshed again on 2026-10-10 from seven green runs of this repository's own CI: 38068758436, 38065011500, 38044860890, 38031183126, 38004058787, 37998134189, and 37997299201.
Those runs measured the serial members this fork's own CI had then, and the upstream merge later added serial scripts they never saw.
The serial table was refreshed again on 2026-11-02 from three green `ci.yml` runs on main: [41406925170](https://github.com/max-metaplanet/firstmate/actions/runs/41406925170), [41362483537](https://github.com/max-metaplanet/firstmate/actions/runs/41362483537), and [41339353445](https://github.com/max-metaplanet/firstmate/actions/runs/41339353445).
Each uploaded all sixteen serial shard artifacts, so that refresh measured every one of the 289 serial members and brought `serial_unhinted` to zero; 43 of them had been packing on `PORTABLE_SERIAL_DEFAULT_WEIGHT_MS`.
It raised 188 hints, left the native-Windows exception below alone, and lowered 11, each one a derived or provisional value this section had already recorded as waiting for a CI measurement.
Read the current count from `bin/fm-test-run.sh --check-coverage` rather than from a number copied here.
Read timing artifacts from the repository the shards actually run in: `gh-axi` resolves to the `upstream` remote when one is configured, and a sibling repository's shard membership and script set are not interchangeable with this one's.

A hint is a high-water mark across the recorded baselines rather than only the newest run's figure.
Refresh it upward whenever a newer run measures a script slower, and lower it only with a stated reason, as the superseded host-runtime-fix entry below did.
A hint that is too low costs a cancelled shard, while one that is too high costs only a slightly under-packed runner, so the asymmetry is deliberate.

`tests/fm-supervision-host.test.sh` and `tests/fm-watch-triage.test.sh` were split on 2026-10-13 into colocated scripts that share a helper library, and their pieces carried their pre-split measurement apportioned by case share until CI measured them.
The 2026-11-02 refresh replaced every one of those derived values with a measured one, which is why it lowered them.
A single low sample on the pre-split host suite is what let serial 2 pack 21 further scripts beside a script that fills a shard by itself; [Portable serial CI shards](#portable-serial-ci-shards) owns that lesson and what the coverage guard does and does not catch.
A cancelled job's unfinished script has no completed sample, so the hint keeps the slowest *completed* one.

`tests/fm-heavy-route.test.sh` arrived after the last refresh, so its 12000 ms hint has no CI sample behind it.
It derives from one local run of 4.55 s scaled against its closest sibling, `tests/fm-boat-run.test.sh`, which runs 54.59 s on the same machine against a 41646 ms measured hint, and then rounded well upward because this table's asymmetry prefers an under-packed runner to a cancelled shard.
Replace it with the slowest measured `duration_ms` at the next refresh.

The native-Windows-only `tests/fm-pi-windows-shell-invocation.test.sh` retains its separate 5121 ms measurement from 2026-09-06T21:02Z instead of a portable capability skip, because the portable shards skip it.
Apart from the new heavy-route hint above, it is the only remaining exception: the 2026-11-02 refresh replaced the provisional local and macOS-host measurements the polytoken adapter, pool-prune, treehouse-lease, orgs-lib and session-start entries had been carrying with Ubuntu CI measurements.

## Parallel lanes

The two parallel lanes use longest-processing-time assignment over those hints.
[`tests/fm-pi-primary-types.test.sh`](../tests/fm-pi-primary-types.test.sh) owns its typecheck dependencies independently of the lane's installed Pi runtime.
[`bin/fm-test-run.sh`](../bin/fm-test-run.sh) holds the duration values in `portable_parallel_weight_hints` and the ordered memberships and lane-specific prerequisite constraints beside `list_portable_parallel_1` and `list_portable_parallel_2`.
Read the derived packing estimates with that runner's `--check-coverage`; its header and `--help` own the output fields and the selection-specific `--list-scheduled` weight rules.
The largest individual hint sets a lower bound on the estimated duration of any split, regardless of how evenly the remaining work is assigned.
The CI cap follows the four-tier timeout policy in [Timeouts](#timeouts) below.

[`tests/fm-test-run.test.sh`](../tests/fm-test-run.test.sh), in `test_portable_parallel_lanes_stay_duration_balanced`, requires every parallel member to have a hint and the lane sums to differ by no more than five percent of the larger sum.
Its scheduling regressions also check stored parallel lane order and preserve serial-weight scheduling for other selections.
These checks do not detect a script outgrowing an existing hint or establish measured job headroom.
Refresh `portable_parallel_weight_hints` with the slowest completed `duration_ms` per script from several green CI runs' `fm-test-timing-portable-parallel-*` artifacts whenever the parallel set gains scripts or a member grows materially.

## Portable serial remainder

`portable-serial` includes every `tests/*.test.sh` that is neither proven-isolated nor `real-herdr-gated`.
It keeps watcher, lock, AFK, real tmux, daemon, secondmate lifecycle, bootstrap, the `live-harness-optin` family, GUI-backend, and other unproven work serial.
Membership is derived rather than enumerated, so a newly added test lands here by default.

## Portable serial CI shards

On green CI run [30725985757](https://github.com/kunchenguid/firstmate/actions/runs/30725985757), that remainder accumulated 19m04s of script time against a 20-minute job timeout.
On [PR 1495](https://github.com/kunchenguid/firstmate/pull/1495), its main step ran about 19m51s before the job was cancelled at that boundary.
`portable-serial-<k>of<n>` splits it across `n` separate CI runners.
Each shard is still strictly serial in itself, and separate runners mean no two of these stateful scripts ever share a machine, so the split needs no concurrency isolation proof.

`bin/fm-test-run.sh` owns `n` and refuses any lane whose `of<n>` disagrees with it.
`.github/workflows/ci.yml` derives the same `n` from `strategy.job-total` rather than a literal, so changing the shard count in either file without the other fails the lane loudly instead of leaving part of the required suite unrun.

Assignment is longest-processing-time bin packing over per-script duration hints embedded in `bin/fm-test-run.sh`.
[Verification inputs](#verification-inputs) owns the measurement provenance and exceptions.
A script with no hint gets the conservative `PORTABLE_SERIAL_DEFAULT_WEIGHT_MS` default.
Hints only affect balance: the coverage guard keeps the partition complete and disjoint whatever they say, so a stale hint costs a slower shard rather than lost coverage.
Balance is still worth keeping current, because enough unmeasured scripts let one shard carry more than twice another shard's real work and reach the job cap while another runner sits idle.
`bin/fm-test-run.sh --check-coverage` reports the unmeasured share as `serial_unhinted=` and refuses past `PORTABLE_SERIAL_MAX_UNHINTED_PERCENT`.
That catches missing hints, not stale existing hints: the host suite still had a 41512 ms hint after growing to over 1000 seconds in CI, so the old split placed it beside another 12 minutes of work while passing the guard.
The same failure recurred on 2026-10-10 with a fresher but still low 789123 ms hint, which kept 21 further scripts packed beside a script that fills a shard by itself and cancelled serial 2 on five runs across main and two PRs.
Refresh the hints whenever a serial member grows materially or the lane gains scripts, rather than waiting for missing-hint coverage to trip.

`bin/fm-test-run.sh` owns the per-shard packing, so its `--check-coverage` output is the current account of lane size and coverage rather than a copied inventory.
Its header and `--help` own the modeled-budget check and output fields; read the current estimates from `--check-coverage` instead of retaining copied lane sums here.
[`tests/fm-test-run.test.sh`](../tests/fm-test-run.test.sh), in `test_portable_serial_packing_budget_boundary`, verifies acceptance exactly at the budget and refusal one millisecond above it through the executable runner.
No single script is the indivisible floor for this layout any more.
The two suites that were, the supervision host and the watch triage, are split across colocated scripts, so no remaining member fills a shard by itself and the modeled maximum shard tracks the lane's total work divided by the shard count instead of one script's duration.
That is what makes the shard count a speed control, against the 1353420 ms single-script floor it had at any count before the split.
Read the modeled maximum for the current count from `--check-coverage`, and compare counts by reading it again after changing `PORTABLE_SERIAL_SHARDS`, rather than from a figure copied here that a hint refresh moves.
A shard holding one script still cannot be rebalanced, so when the modeled-budget check names a single-script shard the answer is a runtime fix or a further split for that script, not a different packing.
The estimates use per-file maxima from different runs, not measured rebalanced jobs or an end-to-end latency guarantee.
The pre-split watch-triage samples range from 944375 to 1074843 ms, while each observed completed portable job adds at most 30 seconds beyond its summed scripts in these runs.
Even so, maxima from these runs do not establish a P95 or guarantee future headroom.
`PORTABLE_SERIAL_MAX_WEIGHT_MS` is derived from the serial step tripwire rather than chosen: hints are measured on healthy runners, the slow runners that cancelled serial 2 ran the same script about 1.6x slower, and 1500000 ms at that factor is the 40-minute step bound in `.github/workflows/ci.yml`, under the 45-minute serial job cap.
Job timeouts remain hang tripwires under the policy in [Timeouts](#timeouts) below; they are not the desired healthy duration.
`tests/fm-ci-workflow.test.sh` compares the parsed CI matrix to the executable runner lanes, and the runner rejects parallel `--jobs` on a serial lane even when that shard has only one member.

Refresh the CI-derived hints by downloading the per-shard timing artifacts from several green CI runs and replacing the `portable_serial_weight_hints` table in `bin/fm-test-run.sh` with the slowest measured `duration_ms` per `path`:

```sh
for run in <run-id> <run-id> <run-id>; do
  gh-axi run download "$run" --repo max-metaplanet/firstmate --dir "/tmp/fm-serial/$run"
done
jq -r '.scripts[] | select(.exit == 0) | [.path, .duration_ms] | @tsv' /tmp/fm-serial/*/fm-test-timing-portable-serial-*/*.json \
  | awk -F'\t' '$2 > m[$1] { m[$1] = $2 } END { for (p in m) print p, m[p] }' \
  | LC_ALL=C sort
bin/fm-test-run.sh --check-coverage
```

A timed-out shard may upload no artifact, so include a complete green run or the slowest scripts go unmeasured in exactly the shard that needs them most.
Completed shards from a partial run can supplement that complete baseline, but never treat missing tail scripts or the timeout duration as successful samples.
Measure native-Windows-only scripts through the focused Git Bash runner and retain that `duration_ms` separately, because the portable CI shards skip them.

## Change-scoped selection

On a pull request the behavior lanes are replaced by the test scripts that cover the changed paths.
`bin/fm-ci-change-scope.sh` is the single owner of that decision: it supplies the pull request's changed path set to `bin/fm-test-run.sh --list-weighted --changed --changed-paths-file`, so the diff and the map each keep one owner, and packs the result into the fewest jobs whose modeled work fits its per-job budget.
A one-script change therefore spends one runner instead of nineteen, which is what a short round's wall clock is actually made of.
A change to CI setup is selected the same way as any other: the workflow, the no-mistakes config, the test runner, its isolation proof, the classifier itself and shared libraries are all answered by the runner's map with the family that owns them, and no second list of owning suites exists to drift from it.
`bin/fm-test-run.sh --check-changed-map` proves the map answers for every source path the tests tree names, because a selection is only as safe as the map behind it.

A pull request never runs the complete sixteen-shard suite, however little the classifier can establish.
Where it cannot produce a packable selection - shared test scaffolding every suite names, a library whose owning families are the whole tree, prose a test reads that the map answers nothing for, or a path the map refuses - it falls back to both portable parallel lanes and the required Herdr lane, three runners rather than nineteen.
That trade is only sound because the complete suite still runs: on the next push to main and again on the nightly schedule, where `full` is set and nothing is narrowed.
A serial-lane regression a pull request's bounded round missed is therefore caught by a failing workflow run on main, which is the signal that layout depends on.
`bin/fm-ci-change-scope.sh`'s header owns the complete list of fallback conditions and the one place CI and `--local` differ: `--local` keeps the complete-suite fallback, because its consumer runs scripts rather than CI jobs.

The stock macOS Bash check runs in two halves, because `needs` is static and a job the `ci-gate` job waits for holds the whole round until it finishes.
Narrowing the Linux work cannot move a job that has queued about 35 minutes for a 7.5-minute run, so the pull request's copy of it has to live outside that verdict rather than inside it.
On push to main and on the nightly schedule it runs as `ci.yml`'s `macos-stock-bash` job, inside the `ci-gate` verdict, which requires its success on every non-pull-request event.
On a pull request it runs from [macos-advisory.yml](../.github/workflows/macos-advisory.yml) instead: a separate workflow reporting its own check, visible and red when stock Bash 3.2 breaks, that the pull request's verdict neither waits for nor fails with.
[`bin/fm-macos-stock-bash-check.sh`](../bin/fm-macos-stock-bash-check.sh) owns what the check is, so the two halves cannot drift apart, and it is runnable locally under `/bin/bash`.

### Local change-scoped budget

`bin/fm-ci-change-scope.sh --local` admits the cheapest suites by timing hint until `LOCAL_BUDGET_MS` of modeled serial work is spent, names the rest as deferred to CI, and [`.no-mistakes.yaml`](../.no-mistakes.yaml)'s `commands.test` bounds the resulting run at six times that budget.
That bound covers execution only, because the command claims its heavy slot before starting the clock.
It has to: the slot pool is machine-wide across every home, worker and the no-mistakes daemon, it is one slot on an ordinary developer machine, and a sibling lane's heavy command holds it for tens of minutes.
A deadline that covered the queue measured the queue, and on 2026-11-02 one such run spent all 998 s of a 900 s bound waiting and was killed having started no test at all, which is the shape of the exit 124 that made a trusted Test step need an approval over failure.
`tests/fm-nm-test-contract.test.sh` holds that boundary by making the command queue behind a private held slot for longer than its own deadline and requiring it to still reach its selection.

Modeled serial work is also not that run's wall clock, which is the measurement the budget is sized from, because the runner schedules a plain script list into concurrent phases plus a serial tail of every script whose family carries no concurrency proof.

The measurement below was taken on 2026-11-02 on a six-CPU Linux host at load average 3, using the change set of [pull request 205](https://github.com/max-metaplanet/firstmate/pull/205) (`bin/fm-seat-lib.sh`, `bin/fm-seat.sh`, `bin/fm-spawn.sh`, `docs/claude-seats.md`, `tests/fm-seat.test.sh`), which maps to 94 candidate suites and is representative of a large change.
Each figure is one `bin/fm-build-lock.py -- bash bin/fm-test-run.sh --per-script-timeout-secs 1500 <selection>` measurement run.
The current `commands.test` instead uses a single execution deadline inside the heavy slot and omits per-script watchdogs, whose separate process groups escape that deadline.

| Budget | Selected | Modeled | Measured wall | Concurrent phase | Serial tail |
|---|---|---|---|---|---|
| 300000 ms | 37 of 94 | 291914 ms | 207.5 s | 45.6 s over 25 scripts | 153.0 s over 12 scripts |
| 150000 ms | 34 of 94 | 137958 ms | 124.4 s | 60.7 s over 26 scripts | 61.4 s over 8 scripts |

At 300000 ms the gate left only 4.34x headroom under its 900 s bound, which a loaded machine can spend by itself.
At 150000 ms the bound stays 900 s, which is 7.2x the measured wall and exceeds the 1.6x slow-host allowance used to derive `PORTABLE_SERIAL_MAX_WEIGHT_MS`.
The serial tail was 77% of the wall at 300000 ms and is 50% of it at 150000 ms, because the 2026-11-02 hint refresh moved the heavy `backend-dispatch` members out of a cheapest-first selection that had been admitting them on understated hints.
Running the configured `commands.test` body end to end against that path set, with both changes in place, selected those 34 suites, named 60 as deferred, and exited 0 in 90 s.
That bound is a hang tripwire under the policy in [Timeouts](#timeouts), not a packing estimate, so a selection that reaches it needs a smaller budget rather than a longer bound.
Remeasure the modeled budget and execution headroom together using the current configured `commands.test` body after any serial hint refresh or any change to the runner's local scheduling.

## Coverage guard

`bin/fm-test-run.sh --check-coverage` verifies that both parallel lanes partition the proven-isolated set.
It also verifies that the parallel lanes, portable serial lane, and real-Herdr family are disjoint and cover every `tests/*.test.sh` script.
It separately verifies that the portable serial CI shards are non-empty, disjoint, and together equal the portable serial lane.
Its hint-coverage and modeled-budget checks are described in [Portable serial CI shards](#portable-serial-ci-shards); neither replaces inspection of actual CI timing artifacts.

## Timing artifacts

Portable shards, each portable serial shard, each packed change-scoped job, and the Herdr lane upload runner-generated timing JSON.
`bin/fm-test-run.sh --aggregate-json` creates the combined summary artifact.
`.github/workflows/ci.yml` owns the exact artifact names and aggregation wiring.

## Lint partitions and end-to-end latency

`bin/fm-lint.sh` owns the canonical CI partitions, each running the same full source-aware ShellCheck analysis with one ShellCheck at a time, pinned versions, workflow validation, and backend-purity checks; the `.github/workflows/ci.yml` lint matrix sets the partition count, and `docs/verification/lint-runner-memory.md` records why a partition does not run concurrent workers.
CI requires its per-root bounds, so an unenforceable deadline or memory cap refuses lint rather than running uncapped; the script header owns the envelope, per-root execution contract, and memory fallback.
Its `--list-files` interface exposes partition membership; `tests/fm-lint.test.sh` verifies complete/disjoint executed roots, initial analysis flags, and fallback reporting.
The workflow uploads each partition's quiet telemetry plus its per-root lifecycle sidecar to distinguish analysis cost, memory use, and host contention.
No fast mode, reduced checks, or paid runner provisioning is part of this layout.
Jobs are gated by changed path, and `bin/fm-ci-change-scope.sh` is the single owner of those path sets: it derives them from what the gated jobs actually read, keeps a gate on for any path it does not prove inert, and its header owns the reasoning for each set.
The gates are job-level `if:` conditions fed by one always-run detection job, never a workflow-level `paths:` filter, because a workflow that is never created leaves a required check pending forever while a job skipped by `if:` reports as skipped and satisfies branch protection.
The always-run `ci-gate` job reports the whole round's result, so a gated-off job never reads as a missing check; require that check rather than the gated jobs if this repository ever configures required checks.

The longer-term performance objective remains a complete green run under fifteen minutes including start delay; the supervision-host floor that alone exceeded that objective is gone.
The immediate packing target is the runner's modeled script budget, and with no script left filling a shard by itself, more shards now lower that model until it reaches the lane's total work divided by the shard count.
The layout uses twenty-two long-lived Linux jobs (sixteen serial, two parallel, Herdr, three lint) on push to main and the nightly schedule, plus short checks and macOS; insufficient shared account capacity can erase the packing gain.
A change-scoped pull request round uses at most six packed jobs plus the three lint partitions instead, and its bounded fallback three lanes plus those partitions, with the macOS check running advisory beside it rather than inside its verdict.
This fork holds about twenty concurrent runners, which is what sets the lint count: at fourteen partitions a pull request's lint matrix alone approached that cap, so partitions and behavior jobs queued behind each other and the round's wall clock became queue wait rather than work.
Replaying the per-root ShellCheck durations measured in run 38635813357 (2240.2 seconds of analysis over 516 roots) through `bin/fm-lint.sh`'s own byte-weight packing projects a slowest partition of 1172.5 seconds at two partitions, 833.0 seconds at three, and 698.9 seconds at four.
Two partitions alone exceed the whole 19.0-minute round they were meant to shorten, so three is the count this layout uses; reproduce the projection by downloading the `fm-lint-telemetry-*` artifacts from a green run and summing each `end` record's duration per `bin/fm-lint.sh --partition <n>of<total> --list-files` membership.
Sixteen serial shards was chosen as the knee of the packing from the aggregate of run 38453818522, when `tests/fm-supervision-host.test.sh` at about 22.6 minutes and `tests/fm-watch-triage.test.sh` at about 17.9 minutes were indivisible scripts that set the lane's floor.
Both suites are now split across colocated scripts, so no single script sets the floor and the modeled maximum shard is the lane's total work divided by the shard count, which `bin/fm-test-run.sh --check-coverage` reports as `serial_max_ms` for the configured count.
Raising the count therefore buys wall time again, at the cost of each extra runner's start delay.
Compare complete before/after runs, preserve cancelled and partial-run evidence, and measure a representative normal-run sample before claiming a P95 improvement.
The workflow retains per-PR supersession without cancelling main pushes or changing the compliance workflow's event semantics.

## Local entry points

[CONTRIBUTING.md](../CONTRIBUTING.md) owns the local test policy and common entry points.
`bin/fm-test-run.sh --help` owns exact lane names, selection flags, and bounded `--jobs` mechanics.

## Timeouts

CI job timeouts follow one four-tier policy, so the workflow reads as a policy rather than as a collection of per-job numbers.
Every tier is a hang tripwire with headroom above the healthy duration, never a packing estimate or a runtime target.
A lane that reaches its tier bound needs investigation and a distribution or runtime fix, not a larger timeout to fit the same work.

| Tier | Jobs | Bound | Rationale |
|---|---|---|---|
| Fast | change scope, coverage guard, repo invariants, timing aggregate, documentation audience guard, CI gate | 5 minutes | Seconds-long local work, so the tripwire only catches a hung runner. |
| Normal | lint partitions, portable parallel shards, change-scoped packed jobs, macOS stock Bash | 30 minutes, one value shared by every job in the tier | One shared hang tripwire keeps these ordinary lanes on the same policy instead of allowing per-lane packing estimates or one-off caps to set the bound. |
| Serial | portable serial shards | shard-run step 40 minutes under a 45-minute job bound | This bound predates the split of the two suites that set the lane's floor: the pre-split `tests/fm-supervision-host.test.sh` measured 16.9-22.6 minutes on healthy runners and about 35 minutes on slow ones, so no partition of the lane fit the normal tier. With no single script filling a shard by itself, a modeled shard now tracks the lane's total work divided by the shard count, and returning this lane to the normal tier is a workflow change owned by [`.github/workflows/ci.yml`](../.github/workflows/ci.yml). The step tripwire bounds a wedged shard below the job cap and fails the step with its captured log output rather than cancelling the job; the timing JSON is written only after every script finishes, so a timed-out shard uploads no timing artifact. |
| Heavy | Herdr | family-run step 20 minutes under a 75-minute job-level last-resort backstop | Healthy runs finish in about 7-10 minutes, so the step tripwire fails a wedged suite while the `always()` cleanup and timing upload still run, and the job cap only catches a hang outside that step. |

[`.github/workflows/ci.yml`](../.github/workflows/ci.yml) holds the executable values and names each job's tier beside its `timeout-minutes`.
[`tests/fm-ci-workflow.test.sh`](../tests/fm-ci-workflow.test.sh) holds the policy against the parsed workflow: every job belongs to exactly one tier, the workflow carries exactly four distinct job-level values, the fast tier stays within 5-10 minutes, the normal jobs share one 30-minute budget, the serial shards share one 45-minute bound with their 40-minute step tripwire and an `always()` timing upload after it, and the Herdr family-run step is the 20-minute tripwire below its job backstop with an `always()` teardown after it.
The serial tier is the one place a bound was raised to fit work rather than to catch a hang, so it carries its measured reason in the table above; the durable fix was splitting that script, which lets the lane return to the normal tier once its modeled maximum shard fits inside that tier.
A passing coverage guard does not establish a healthy job duration; refresh the healthy figures above from the lanes' uploaded timing artifacts.
