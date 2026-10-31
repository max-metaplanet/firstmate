Your scout task has been promoted to a ship task, mode=no-mistakes. Your window, worktree, and context stay as they are; only the contract below changes.

# Task
## Captain's intent
Investigate the upstream bug.

## Firstmate spec
If these promotion steps were already completed before a relaunch, preserve the existing `fix/no-ticket-scenario-promote-third-party` branch and continue from its current state; do not repeat them destructively.
1. **Verify isolation before anything else.** Run `pwd -P` and `git rev-parse --show-toplevel`; both must resolve to the disposable task worktree you were launched in, such as a treehouse pool path or an Orca-managed worktree, not the primary checkout firstmate operates from. If either does not resolve to the worktree you were launched in, stop and escalate to firstmate.
2. Inventory this worktree's scratch state with `git status` and `git log` before changing anything.
3. Return to a clean default-branch base, then create your branch: `git checkout -b fix/no-ticket-scenario-promote-third-party --`.
4. Carry over only the intended fix changes. Leave scratch commits, debug edits, and experiment files behind.
5. If you reproduced a bug, turn that reproduction into a regression test.
6. Treat the scout-time Firstmate spec and any unmarked legacy `# Task` text as investigation context, not captain intent or current ship-time instructions.
7. Everything else in your original instructions carries over unchanged: the status protocol; the instruction inbox and its acknowledgement; the escalation rules, including ask-user; and every safety rule, except where the current delivery contract below explicitly replaces scout-only delivery rules.


# Current delivery mode contract
This task is now kind=ship with mode=no-mistakes.
This section supersedes every earlier brief instruction about delivery mode.
These current ship instructions supersede the scout delivery rules and report-based Definition of done.
Any earlier "Never push" or scout-only delivery language in this file is superseded.
This replaces the scout rule limiting outside-worktree writes to the report and status file.
Keep project edits inside this worktree; put ad-hoc test and debug output in the scratch directory beside it, `<worktree>/../.fm-test-scratch/`, and durable proof under `~/.no-mistakes/worktrees/c0c4fcacb05a/01M69MFQ8X8XAHRAZ9PNXNTDR2/.test-conventions-thvp7fco/promote-third-party/data/scenario-promote-third-party/` - never `/tmp` or `$TMPDIR`.
Outside the worktree, write only that task material and the status and steering-inbox records authorized below.
Leave the worktree clean before reporting done.
The mode-specific Definition of done below is the current delivery contract.

# Current ship safety rule
1. Never push to the default branch. Never merge a PR.

The no-mistakes ask-user escalation below supersedes the scout rule 6 escalation shape.
   For a no-mistakes ask-user gate specifically, escalate all ask-user findings as one event plus one snapshot file, using that same shape even when the gate holds only a single ask-user finding: write only the ask-user findings, verbatim and unparaphrased (id, severity, file, line, description, authority), to `~/.no-mistakes/worktrees/c0c4fcacb05a/01M69MFQ8X8XAHRAZ9PNXNTDR2/.test-conventions-thvp7fco/promote-third-party/data/scenario-promote-third-party/nm-<run>-findings.txt`, then report the gate with
   `needs-decision [at=<epoch>] [key=nm-<run>-<step>]: ask-user findings=<id1>,<id2>,... file=~/.no-mistakes/worktrees/c0c4fcacb05a/01M69MFQ8X8XAHRAZ9PNXNTDR2/.test-conventions-thvp7fco/promote-third-party/data/scenario-promote-third-party/nm-<run>-findings.txt`
   naming every ask-user finding id from that gate. The status line only points at the file; it never restates or summarizes a finding's content.

# Definition of done
Delivery contract: mode=no-mistakes
Ship branch: fix/no-ticket-scenario-promote-third-party
Ticket: no-ticket
Commit type: fix
Every commit subject on this branch and the pull request title must read `fix(<scope>): <message>`, where `<scope>` names the area changed and `<message>` is a short imperative description.
This project publishes outside the organizations this home declares as ours, so its subjects carry no ticket segment: never write `fix/no-ticket(<scope>)`, the ticket id, or any other internal marker into a commit subject or the pull request title.
The branch is exactly `fix/no-ticket-scenario-promote-third-party`; do not rename it.
Run locally only the tests for what you changed, plus affected lint and formatting checks.
Never run or wait on full-suite local hooks (including Husky pre-commit/pre-push suites) or a full monorepo test run.
If such a hook would run, bypass it for that command only with `git -c core.hooksPath=/dev/null commit ...` or an authorized `git -c core.hooksPath=/dev/null push ...`; never disable hooks globally or bypass the no-mistakes gate.
Where this delivery path authorizes you to push a branch that forge CI runs on, finish local iteration and push ONCE per task when ready; no-mistakes owns its push, and local-only never pushes.
A Gerrit `gerrit-axi publish` patch set or an external-review re-upload made to correct the work before reporting done is not a second push and is not reported as blocked, because no forge CI runs on it.
PR CI is the full regression gate for PR delivery; keep CI spend down and never trigger extra CI reruns yourself, including failed-job reruns or manual workflow dispatches.
The pipeline still owns its configured test step, repair loop, and `ci.rerun_transient`.
This machine runs only a few memory-heavy commands at once, and an ordinary Node build or test run claims one of those places by itself.
Run a heavy command that cannot see Firstmate's Node preload - one whose script replaces `NODE_OPTIONS` instead of appending to it, or that runs outside Node - through `~/.no-mistakes/worktrees/c0c4fcacb05a/01M69MFQ8X8XAHRAZ9PNXNTDR2/bin/fm-build-lock.py -- <command>`, so it waits for a place instead of exhausting the machine.
Waiting for a place is expected, not a failure.

The implementation is complete only when committed on your branch; the TASK is complete only when the pipeline has turned that commit into a PR with green checks.
As soon as the implementation is committed and your tree is clean, invoke /no-mistakes yourself and drive the run to its outcome: do not report done first, and do not wait for firstmate to send you the pipeline.
The pipeline owns the push; never push from this copy.

For a conflict-only rebase or conflict resolution of an already-open PR, use `FM_HOME=~/.no-mistakes/worktrees/c0c4fcacb05a/01M69MFQ8X8XAHRAZ9PNXNTDR2/.test-conventions-thvp7fco/promote-third-party ~/.no-mistakes/worktrees/c0c4fcacb05a/01M69MFQ8X8XAHRAZ9PNXNTDR2/bin/fm-pr-refresh.sh prepare scenario-promote-third-party <pr-url>` before any push or pipeline refresh; its header owns classification, publication wrapping, and the firstmate-controlled ready call.
In direct-PR mode, pass the publication command after `--` to that helper; in no-mistakes mode, prepare first and let the pipeline publish.
This hold overrides the ordinary ready/done instructions below: keep the draft and declared wait until firstmate explicitly asks for the helper's `ready` call.
Do not report done or mark it ready while `state/scenario-promote-third-party.pr-refresh` exists.
Never hand-fix or push around the pipeline's repair loop.
When a required check is red, read its failure log.
Never push an empty, no-op, or "retrigger" commit to rerun CI.
When no-mistakes owns CI, report unrelated failures through its CI step; its "skip as unrelated with evidence" path remains valid.
Follow the CI-round policy below before authorizing further CI repairs.

## CI-round policy
After three CI rounds on one PR, stop speculative publication: a fourth or later round requires a locally reproduced failure and a locally verified fix.
Count distinct published PR heads that started CI, including the initial publication, across pipeline runs, retries, rebases, and worker replacements; never reset the count by restarting validation.
Multiple workflows on one head, draft-to-ready events, and reruns on that same head do not create another head round; worker-triggered reruns remain forbidden.
Only where the target project sets `auto_fix.ci: 2` does a new PR's run allow the initial publication and at most two automatic repair attempts; other values allow different per-run attempts, and no value is a lifetime PR counter, so recount the PR's published heads after each CI outcome.
Once the PR has three published heads and its CI is still red, stop pushing and stop accepting automatic repair rounds: at the next gate, respond instead of approving another fix round.
Before responding, read all failing logs after the head's executing checks settle and give the complete actionable failure set to the pipeline in that one gate response.
Require in that response's `--instructions` that the pipeline reproduce each actionable failing check locally before editing, run heavy reproduction and verification inside the project's heavy-slot wrapper, apply the root-cause fix, and verify the same command passes on the candidate head before publishing once.
Require recorded evidence of the failing command and result before the fix, the passing command and result after it, and the candidate head; relevant passing tests alone are not proof that the CI failure was reproduced.
If local reproduction or verification is unavailable or fails, require the pipeline to hold publication and report the blocker to firstmate; do not authorize a speculative push, an empty commit, a restart to reset the budget, or a worker fix outside the pipeline.
If the pipeline publishes a further round without a gate, report its version, the observed rounds, and the needed configuration or upstream enforcement to firstmate without editing shared daemon configuration yourself; a brief instruction is not a deterministic guard on the daemon.

As soon as the pipeline opens its PR, read it by its full URL.
If it is a draft, confirm the pipeline's local review, test and lint steps passed and the work is ready, then mark it ready using the forge command below BEFORE waiting for CI green.
A draft-skipping workflow needs that ready transition to run its full suites; skipped draft checks alone never prove the ready PR green.
If this head's checks were skipped while it was draft, require fresh results from the workflows the ready transition triggers on this head before treating CI as green; otherwise completed, non-skipped results on this same head count. When checks were skipped while draft, read the ready time with `gh api --paginate repos/<owner>/<repo>/issues/<number>/timeline --jq '.[] | select(.event == "ready_for_review") | .created_at' | tail -n 1` and wait with `~/.no-mistakes/worktrees/c0c4fcacb05a/01M69MFQ8X8XAHRAZ9PNXNTDR2/bin/fm-pr-checks.sh --watch --after <ready time> <pr-url>`, so no check skipped before the ready transition counts.
Your only `done:` is the CI-ready line below, and a ship `done:` naming no PR is refused rather than recorded, because the work is not shipped.

You drive no-mistakes by responding to its gates, not by implementing fixes.
Follow the guidance no-mistakes itself provides for the mechanics: it loads when you invoke /no-mistakes, and `no-mistakes axi run --help` plus the `help` lines in each `axi` response are authoritative and version-matched to the installed binary.
When starting no-mistakes, pass `--intent` as only this brief's `## Captain's intent` subsection body, not its heading, plus any later words the captain actually said.
Preserve the actual words without adding speaker labels or direct address; the subsection heading supplies provenance outside the pipeline input.
For a legacy brief with no such subsection, include only words on lines marked `[captain] `, excluding that metadata prefix; never copy its mixed `# Task` wholesale.
If it has no provenance-marked captain words, stop and ask firstmate instead of starting no-mistakes.
Do not include `## Firstmate spec`, later Firstmate build constraints, or your own decisions and tradeoffs.
The `--intent` string you pass must be self-sufficient: that string plus the codebase must let a reader reconstruct roughly the same specification, without depending on a separate report, a PR, or context that lives only in this conversation.
When the captain's intent refers to a report, decision, or PR ("do items 1, 2, 3, and 7 of the report"), write the substance of the referenced items into `--intent` in the captain's terms, not only the pointer; that substance is the captain's ask by reference, while Firstmate's build instructions and your own decisions still stay out.
This replaces the no-mistakes skill's advice to enrich `--intent` with decisions and tradeoffs; that advice does not apply to Firstmate-dispatched work.
Do not hand-edit, commit, or fix findings yourself while a run is active - the pipeline applies every fix.

One drive call blocks until the next gate or outcome, which routinely outlives what your harness lets a single command run: Claude Code kills a command at ten minutes maximum, while one fix round is capped around thirty minutes and up to three rounds chain.
So background the drive call instead of sitting in one blocking hold your harness will kill, and read its return when it finishes.
Declare that wait using the brief's status-reporting rule before waiting on the backgrounded drive call.
Where a harness's own command limit is not established, assume it bounds commands and use that same backgrounded shape.
Only a drive call's return reports the green PR: `no-mistakes axi status` shows progress but never reports `checks-passed` while the ci step is still monitoring the PR for merge, so never wait on a status poll for the next gate or outcome.
Whenever a drive call returns without a gate or an outcome - its own wait elapsed, or it was killed or timed out - reattach at once by re-running `no-mistakes axi run` without flags, backgrounded the same way; once checks are green it returns `checks-passed` immediately, and if it refuses because no run is active, read the finished outcome from `no-mistakes axi status`.
A killed or timed-out call is never evidence the daemon died: the daemon accepts your response immediately and runs the round in the background, so the call was only ever waiting for a read while the run kept working.
Reattach and keep going rather than reporting the pipeline blocked; rule 7 owns the checks that decide when a pipeline block is real.
After an interrupted terminal run refuses a fresh run or rerun, use `bash "~/.no-mistakes/worktrees/c0c4fcacb05a/01M69MFQ8X8XAHRAZ9PNXNTDR2/bin/fm-nm-recover.sh" "<task-worktree>" "<exact-task-branch>" --home "<owning-home>" --task "<task-id>"` and follow its action.

Two firstmate-specific rules layer on top of that guidance:
- ask-user findings are never yours to answer: escalate to firstmate using rule 6's ask-user format and stop.
  Firstmate applies `ask-user-authority` and obtains any required captain decision.
  When the decision comes back, feed it to the gate with `no-mistakes axi respond` and let the pipeline apply it - do not route the question to "the user" or implement the fix yourself.
- NEVER pass `--yes` (or `-y`) to `no-mistakes axi run` or `no-mistakes axi respond`. It is banned fleet-wide.
  It auto-resolves every gate including ask-user findings with no escalation, and answering your own ask-user finding is a hard rule violation.

The pipeline's PR step drafts a conventional title like `fix(<scope>): <message>`, which is already the format this project requires: never add a ticket segment to it.
Read the title the moment the run has a PR URL - from `no-mistakes axi status` as soon as the PR step has opened the PR, before the CI wait - and edit it ONCE only if it carries a ticket segment or a pipeline-internal `no-mistakes(<step>): ...` subject, so it reads `fix(<scope>): <message>`.
The pipeline owns its push and publishes its own repair commits, whose subjects read `no-mistakes(<step>): ...`, before custody returns to this copy, and `no-mistakes sync` never updates a remote; rewording them before publication would mean taking the push from the pipeline, which you never do.
The pull request title is therefore the one subject you control on this upstream, and it is what a squash merge lands; leave the published branch's pipeline commits alone, and never rewrite an already-published branch.
Edit it with `gh-axi pr edit <PR URL> --title '<the corrected title>'`, then read it back with `gh-axi pr view <PR URL>` and confirm the title it prints is the corrected one.

For a separate GitHub CI wait, use `~/.no-mistakes/worktrees/c0c4fcacb05a/01M69MFQ8X8XAHRAZ9PNXNTDR2/bin/fm-pr-checks.sh --watch <pr-url>` (policy: `fm-pr-checks-lib.sh`); advisory checks do not block.
After /no-mistakes reports CI green (the CI-ready return point - do not wait for it to keep monitoring in the background until merge), read the PR back from the forge and confirm it is not a draft (`gh-axi pr view <PR URL>` must print `draft: no`, naming the PR by its full URL so the read can never resolve against another repository); if it is a draft, mark it ready with `gh-axi pr ready <PR URL>`.
If that read found a draft whose head checks were skipped while draft, wait for the newly ready PR's fresh results on that head before reporting done; completed, non-skipped results on the same head otherwise stand. When checks were skipped while draft, read the ready time with `gh api --paginate repos/<owner>/<repo>/issues/<number>/timeline --jq '.[] | select(.event == "ready_for_review") | .created_at' | tail -n 1` and wait with `~/.no-mistakes/worktrees/c0c4fcacb05a/01M69MFQ8X8XAHRAZ9PNXNTDR2/bin/fm-pr-checks.sh --watch --after <ready time> <pr-url>`, so no check skipped before the ready transition counts.
A draft cannot be merged, so a done report on one leaves the merge unasked.
Then append `done [at=<epoch>]: PR {url} checks green` and stop. You are finished.
That CI-ready `done:` is accepted only when this copy's HEAD - your latest commit - is one the /no-mistakes run pushed, so commit nothing after the run; the check tests that commit, not merely that a branch moved.
If you deliberately keep the PR a draft, append `paused [at=<epoch>]: {why the draft is held}` instead of done.
