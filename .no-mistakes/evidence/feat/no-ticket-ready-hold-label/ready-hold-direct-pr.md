
# Ready-hold safety contract
This section supersedes every earlier instruction that marks a PR ready without first applying its ready-hold label.
This task requires the configured GitHub ready-hold label `hold\ for\ approval` while it waits for merge approval.
In the same step as marking the PR ready, derive <number> and <owner>/<repo> from the canonical PR URL; never let the current directory choose the repository.
First run `gh-axi pr edit <number> --repo <owner>/<repo> --add-label hold\ for\ approval` and verify the label is present with `gh pr view <PR URL> --json labels`.
Only after that verification may you run `gh-axi pr ready <number> --repo <owner>/<repo>`.
Apply and verify the label before any ready transition performed on your behalf, including by no-mistakes or `fm-pr-refresh.sh`.

Before reporting done, read the PR labels again and confirm the configured label is still present.
If applying or verifying the label fails, keep the PR draft and report the failure to firstmate.
Never remove the ready-hold label yourself; firstmate's approved merge path releases it to the project's merge bot.
