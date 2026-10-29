---
name: validation-supervision
description: Load when a ship starts or already has an active no-mistakes validation run, including a mid-run requirement change or finding, and before deciding or answering any ask-user finding.
user-invocable: false
metadata:
  internal: true
---

# Validation supervision

A no-mistakes ship starts its own validation run after its implementation commit, so firstmate triggers nothing routinely; send the harness invocation owned by `harness-adapters` only to a worker that has stalled without starting one, such as one launched on a brief predating that contract.
The task worker that starts a no-mistakes run drives the pipeline and owns every `no-mistakes axi run` and `no-mistakes axi respond` call through the next gate or outcome.
Firstmate never invokes `no-mistakes axi respond` for a crew-owned run.
`bin/fm-dod-lib.sh` owns the worker-side `--intent` contract.
For an interrupted terminal run that refuses a fresh run or rerun, use [`bin/fm-nm-recover.sh`](../../../bin/fm-nm-recover.sh) with the exact task worktree, branch, `--home`, and `--task`, and follow its action.
Once validation starts, prefer routing new requirements to follow-up work rather than expanding the current task, unless a new requirement completely invalidates the work being validated; however, the smallest downstream changes needed to keep already accepted product or engineering behavior correct, add behavioral tests where an executable contract exists, or keep documentation accurate remain within the current task even when they touch files not named at intake, and corrections required to satisfy already accepted intent are not new requirements.

Only a current, explicit captain instruction that completely invalidates the work being validated keeps the task with the same worker instead of routing it to follow-up work or handing it to a replacement.
That worker cancels the active run through no-mistakes axi's supported abort command and confirms through axi status that the run has stopped before changing any code.
The worker then follows `branch_sync.next_action` from structured axi status: use axi sync's supported guarded recovery only when its code is `recover_custody`, and otherwise proceed only when structured status confirms that branch ownership is already returned and no recovery is required.
Custody recovery settles branch ownership, not content: the worker must replace the obsolete work from the correct pre-invalidation base rather than building on top of the recovered-but-obsolete head, keeping the obsolete run's own pipeline-fix commits out of what gets validated and shipped.
Apart from that single supported abort, do not hand-edit, commit, restart, or start a second validation run while the obsolete run still owns the branch.
Once ownership is settled, validate exactly once against that final head so no obsolete or intermediate head is ever treated as authoritative.

An ask-user finding returns as `needs-decision`; firstmate loads `ask-user-authority` and either decides or escalates per that skill.
Send the same worker one exact decision naming the decision key, step, action, affected finding IDs, instructions where needed, and exact response command, passing `--resolve-key` so the worker's open decision record closes at answer time.
Require the matching `resolved` event, forbid `--yes`, and require the worker to process every synchronous return until completion or a genuinely new escalation.
Resume fleet supervision immediately after the decision lands.

Judge validation by the resolved state line from [`bin/fm-crew-state.sh`](../../../bin/fm-crew-state.sh), whose header owns outcome mappings and CI-monitor/daemon exceptions, never by shell liveness, the last status event, or a raw run record.
Workers parked at approval or fix-review must follow the active gate help.
A worker hand-editing, committing, pushing, aborting, or restarting during an active validation run duplicates pipeline ownership outside the supersession sequence above; steer it back to the gate response flow.
For each CI repair round, require the pipeline to wait for all executing checks on the current head, collect the complete failure set, repair the actionable failures together, validate locally, and publish once for that round.
Keep a CI gate's full actionable failure set together rather than approving separate repair rounds per check.
Cancelled checks, checks held for approval, and unreadable results need their own resolution; never create an empty push to retry them.
The installed no-mistakes version's CI monitor and publication path own this behavior.
If its own auto-fix loop publishes per failure or repairs before the head's checks finish, report its version and round evidence plus the needed configuration or upstream fix; do not fork it or have the worker take over its pushes.
[`bin/fm-dod-lib.sh`](../../../bin/fm-dod-lib.sh)'s generated `CI-round policy` is the single owner of the three-round threshold, lifetime PR counting, local reproduction evidence, heavy-slot use, and the worker's configuration and publication-hold checks; apply that contract when supervising a CI gate.
The existing `auto_fix.ci`, `ci.revalidate_repairs`, and `ci.rerun_transient` settings control per-run repair attempts, revalidation, and cancelled-check reruns respectively, not lifetime PR rounds or push batching.
Firstmate's status integration observes pipeline runs and does not intercept daemon publication, so never claim that the generated contract mechanically caps the installed pipeline.
If a pipeline cannot gate a further repair on the contract's evidence, keep the task blocked and report the required configuration or upstream publication guard rather than approving another speculative round.
The same library retains the stricter single worker push and return-to-firstmate rule for direct-PR tasks.

For pipeline-created GitHub PRs, enable `providers.github.draft_pull_requests: true` in the target repository's `.no-mistakes.yaml` when its workflows skip heavy suites on drafts and run them on `ready_for_review`; leave it off where CI does not skip drafts.
The setting changes PR creation only and does not mark a PR ready automatically.
Before a pipeline refresh for a conflict-only rebase of an existing PR, use the conflict-refresh helper through [ship-landing](../ship-landing/SKILL.md), including when the pipeline monitor itself will rebase and publish.
Its held draft is an explicit wait and overrides ordinary worker readiness; if the installed pipeline cannot preserve that hold, stop and report that limitation before publication.
Follow [ship-landing](../ship-landing/SKILL.md) for the draft-to-ready transition and the unchanged non-draft done gate.
The worker reports the PR when CI first becomes green rather than waiting for merge monitoring to finish.
