legacy-batch-replay-base-vs-head.txt: the real bin/fm-jev-prod-check.sh `check` run in disposable FM_HOMEs
seeded with tests/fixtures/jev-prod-monitor/legacy-pending.tsv (the archived 18-item wake), gh stubbed at the
forge boundary to return no candidates. Base (b2035432) re-delivers "18 verdicts" (13 build-skipped, 4
read-budget-exhausted, 1 deployment-unreadable); head (83216498) wakes only the deployment-unreadable item;
both deliver nothing on the second poll.
targeted-jev-prod-cases.log: 11 intent-targeted cases from tests/fm-jev-prod-check.test.sh run via a filtered
runner (suite itself is deferred to CI by the change-scope classifier).
