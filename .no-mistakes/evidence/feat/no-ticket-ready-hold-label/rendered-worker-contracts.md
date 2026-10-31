
## Configured yolo-off no-mistakes

# Ready-hold safety contract
This section supersedes every earlier instruction that marks a PR ready without first applying its ready-hold label.
This task requires the configured GitHub ready-hold label `awaiting\ approval` while it waits for merge approval.
In the same step as marking the PR ready, first run `gh-axi pr edit <PR URL> --add-label awaiting\ approval` and verify the label is present with `gh pr view <PR URL> --json labels`.
Only after that verification may you run `gh-axi pr ready <PR URL>`.
Apply and verify the label before any ready transition performed on your behalf, including by no-mistakes or `fm-pr-refresh.sh`.
Require no-mistakes to create the PR as a draft and keep it draft until this label has been applied and verified; if its configured PR step cannot guarantee that ordering, report the blocker to firstmate before starting it.
Before reporting done, read the PR labels again and confirm the configured label is still present.
If applying or verifying the label fails, keep the PR draft and report the failure to firstmate.
Never remove the ready-hold label yourself; firstmate's approved merge path releases it to the project's merge bot.

## Configured yolo-off direct-PR

# Ready-hold safety contract
This section supersedes every earlier instruction that marks a PR ready without first applying its ready-hold label.
This task requires the configured GitHub ready-hold label `awaiting\ approval` while it waits for merge approval.
In the same step as marking the PR ready, first run `gh-axi pr edit <PR URL> --add-label awaiting\ approval` and verify the label is present with `gh pr view <PR URL> --json labels`.
Only after that verification may you run `gh-axi pr ready <PR URL>`.
Apply and verify the label before any ready transition performed on your behalf, including by no-mistakes or `fm-pr-refresh.sh`.

Before reporting done, read the PR labels again and confirm the configured label is still present.
If applying or verifying the label fails, keep the PR draft and report the failure to firstmate.
Never remove the ready-hold label yourself; firstmate's approved merge path releases it to the project's merge bot.

Unchanged instructions: yolo=on forge=github mode=no-mistakes project=alpha project (overlay empty)

Unchanged instructions: yolo=off forge=gitlab mode=direct-PR project=alpha project (overlay empty)

Unchanged instructions: yolo=off forge=github mode=local-only project=alpha project (overlay empty)

Unchanged instructions: yolo=off forge=github mode=no-mistakes project=missing (overlay empty)

Unchanged instructions: yolo=off forge=github mode=no-mistakes project=empty (overlay empty)
error: invalid or duplicate ready-hold entry at ~/.no-mistakes/worktrees/c0c4fcacb05a/01M69HSXN04R1RBCAZ039PJZ4D/.test-scratch/render-config/project-ready-hold-label:2

Duplicate configuration refused.

Absent configuration leaves instructions unchanged.
