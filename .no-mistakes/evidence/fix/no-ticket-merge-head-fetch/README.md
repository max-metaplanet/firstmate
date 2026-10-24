# Merge-head fetch validation (fix/no-ticket-merge-head-fetch)
Real bin/fm-pr-merge.sh -> bin/fm-pr-check.sh driven against disposable git repos:
a bare "origin" holding refs/pull/9/head (an update-branch merge commit present only on origin),
a single-branch project clone that lacks the live head, and a stubbed `gh` returning the live head.
- head-run.log: target commit 7b3f25ce. All 6 variants (worker, unpushed, missing, missing-nm, unrelated, unrelated-nm)
  plus an extra fetch-failure case (origin unreachable) behave as intended.
- base-run.log: same regression against base 7abecfff reproduces the reported refusal
  "named head ... is unreachable outside the worker copy".
