Absent setting: label=<>
Configured widget: label=<hold for approval>
unconfigured: label=<>
empty: label=<>

## direct-PR / yolo off

# Ready-hold safety contract
This section supersedes every earlier instruction that marks a PR ready without first applying its ready-hold label.
This task requires the configured GitHub ready-hold label `hold\ for\ approval` while it waits for merge approval.
In the same step as marking the PR ready, first run `gh-axi pr edit <PR URL> --add-label hold\ for\ approval` and verify the label is present with `gh pr view <PR URL> --json labels`.
Only after that verification may you run `gh-axi pr ready <PR URL>`.
Apply and verify the label before any ready transition performed on your behalf, including by no-mistakes or `fm-pr-refresh.sh`.

Before reporting done, read the PR labels again and confirm the configured label is still present.
If applying or verifying the label fails, keep the PR draft and report the failure to firstmate.
Never remove the ready-hold label yourself; firstmate's approved merge path releases it to the project's merge bot.

direct-PR / yolo on: no overlay emitted
direct-PR / undeclared project: no overlay emitted

## no-mistakes / yolo off

# Ready-hold safety contract
This section supersedes every earlier instruction that marks a PR ready without first applying its ready-hold label.
This task requires the configured GitHub ready-hold label `hold\ for\ approval` while it waits for merge approval.
In the same step as marking the PR ready, first run `gh-axi pr edit <PR URL> --add-label hold\ for\ approval` and verify the label is present with `gh pr view <PR URL> --json labels`.
Only after that verification may you run `gh-axi pr ready <PR URL>`.
Apply and verify the label before any ready transition performed on your behalf, including by no-mistakes or `fm-pr-refresh.sh`.
Require no-mistakes to create the PR as a draft and keep it draft until this label has been applied and verified; if its configured PR step cannot guarantee that ordering, report the blocker to firstmate before starting it.
Before reporting done, read the PR labels again and confirm the configured label is still present.
If applying or verifying the label fails, keep the PR draft and report the failure to firstmate.
Never remove the ready-hold label yourself; firstmate's approved merge path releases it to the project's merge bot.

no-mistakes / yolo on: no overlay emitted
no-mistakes / undeclared project: no overlay emitted

GitLab: no overlay emitted
error: invalid or duplicate ready-hold entry at ~/.no-mistakes/worktrees/c0c4fcacb05a/01M69HSXN04R1RBCAZ039PJZ4D/.ready-hold-validation/config/project-ready-hold-label:2
Duplicate declaration exit=1
error: invalid or duplicate ready-hold entry at ~/.no-mistakes/worktrees/c0c4fcacb05a/01M69HSXN04R1RBCAZ039PJZ4D/.ready-hold-validation/config/project-ready-hold-label:1
Malformed declaration exit=1
