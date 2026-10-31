---
name: ship-landing
description: Load when a ship reports a PR or ready branch, when deciding or monitoring landing, and before task cleanup.
user-invocable: false
metadata:
  internal: true
---

# Ship landing

PR-based workers open drafts and keep them draft while implementation or local validation is incomplete.
A worker marks the PR ready once local validation has passed and the work is ready for review, before the final CI wait, except for the conflict-refresh hold owned by `bin/fm-pr-refresh.sh`.
Readiness and approved merging also follow the configured [ready-hold label contract](../../../docs/configuration.md#ready-hold-labels-configproject-ready-hold-label).
For no-mistakes, the pipeline's completed local review, test and lint supply that local validation; the worker only changes the PR's readiness and continues driving the pipeline.
The ready transition needs no commit or push.
Draft-skipped checks do not establish that the ready PR's full suites passed: when a head's checks were skipped while draft, require fresh post-ready results on that head; otherwise completed, non-skipped results on the same head stand.
On GitHub, `bin/fm-pr-checks.sh --watch --after <ready time>`, given the PR's `ready_for_review` timeline time, waits for post-ready replacements of the checks skipped while draft and keeps other completed results.
`bin/fm-dod-lib.sh` owns the generated worker commands; [validation-supervision](../validation-supervision/SKILL.md) owns pipeline draft configuration and CI repair rounds.
For PR-based ship tasks, the ready signal depends on mode: `no-mistakes` reports `done [at=<epoch>]: PR <url> checks green` after CI is green, while `direct-PR` reports `done [at=<epoch>]: PR <url>` after local validation and the ready transition, each only for a non-draft PR.
A lane that deliberately holds a draft declares a wait instead, and `bin/fm-pr-check.sh` refuses to arm merge monitoring on a draft.
For a maintainer's conflict-only rebase request, steer the worker to run `FM_HOME=<task home> bin/fm-pr-refresh.sh prepare <id> <pr-url>` before publication, using the script's conflict-only classification and preserving pipeline push ownership.
When firstmate explicitly chooses to run full ready CI again, call or steer `FM_HOME=<task home> bin/fm-pr-refresh.sh ready <id> <pr-url> --ready-ci reruns|unchanged`: `reruns` where the repository re-runs draft-skipped checks on `ready_for_review` (adds the freshness bound), `unchanged` where it does not; the helper owns the ready transition, CI wait, and conflict-refresh hold removal.
Run `bin/fm-pr-check.sh <id> <PR url>` with the URL copied from that ready signal or the resolved checks-green `fm-crew-state.sh` line - it records `pr=` and the forge's `pr_head=` when available in the task's meta and arms the watcher's merge poll.
Verified worker parking and priority resumption are owned by [`bin/fm-worker-park.sh`](../../../bin/fm-worker-park.sh); merge and guarded teardown require no live worker.
`bin/fm-dod-lib.sh` owns the named-head gate on that ready signal: a ship `done:` whose named head exists only in the worker's disposable copy is not ready (`bin/fm-crew-state.sh` reports blocked, `bin/fm-pr-check.sh` refuses to register, and a secondmate does not publish that done upstream).
That blocked reading is the gate working, not a stuck worker, so steer the worker on what the refusal names rather than waiting: usually an unpushed commit, or for direct-PR a PR opened on a repository other than `origin`.
A `forge=external` task reports `done [at=<epoch>]: review <url> uploaded for review` instead: run `bin/fm-review-check.sh <id> <review url>` rather than `bin/fm-pr-check.sh`, which arms no merge watch, then always escalate the review URL to the captain whatever the yolo setting, because firstmate can neither observe nor perform its approval or merge.
A direct-PR worker pushes that commit to its PR branch, and a local-only worker commits it on its ship branch.
A no-mistakes worker runs the pipeline itself from its implementation commit and never pushes from its copy, so it reports no earlier `done:`: a no-mistakes `done:` naming no PR is refused as unshipped work, and the steer for that refusal and for the named-head one alike is to run or re-run /no-mistakes, never to push or to report again.
Tell the captain the PR's full `https://...` URL copied from the worker's ready line, the resolved checks-green crew-state line, or the task's `pr=` metadata, a concise outcome summary, and the no-mistakes risk level when applicable.
A captain instruction to merge is explicit authority; `yolo` is the only standing routine merge authority.
For any custom `state/<id>.check.sh` you write yourself, keep it an ordinary single-link mode-`0700` file, print one line only when firstmate should wake, print nothing otherwise, finish before `FM_CHECK_TIMEOUT`, then bind its current bytes with `bin/fm-check-register.sh <id>` before the watcher may execute it.
Retire a custom check only through `bin/fm-check-unregister.sh <id>` (or `bin/fm-teardown.sh` for a spawned task); never hand-compose an `rm` with `$STATE`/`$ID`.

Tear down a ship task only after landing is confirmed.
A teardown refusal for uncommitted or unlanded work is a stop-and-investigate result, never an obstacle to bypass.
Never force teardown without explicit discard authority.
After successful teardown, record completion, retain only the configured recent Done history, and re-evaluate queued work whose blockers and time gates have cleared.
When source intake is enabled, load [work-intake](../work-intake/SKILL.md) for that reconsideration.

A secondmate is persistent and an empty queue is healthy.
Retire one only on an explicit captain or main-firstmate decision, after loading `secondmate-provisioning`; its home must contain no work under way, and forced discard still requires explicit captain authority.
