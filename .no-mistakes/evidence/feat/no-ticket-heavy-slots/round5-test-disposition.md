# Test evidence disposition for b3809439d09733d9f9534db9c451c7e45bbfb6d4

The supplied configured-command log was read in full, including its decoded top-level summary. The selector chose 56 local scripts with local_budget_ms=300000 and explicitly deferred broad suites to CI. The retained execution failed (54 passed, 2 failed); it is not a passing configured command.

The orphan-reaper dry-run assertion passes alone on both target and main. The configured extension lock-order assertion passes alone on target. Full extension comparisons still fail on both heads, at different points: target in the remote section, main because Node is missing. These are distinct observed failures, not proven identical causes. Under decision 010 no production/test changes are authorized for these nonreproducing or baseline failures. The outer executor owns supported unrelated-failure disposition; this Test agent performed no approval, skip, override, or pipeline control.

Retained real-product checks in this pipeline cover one/two heavy slots, queueing and SIGKILL release; real Vitest/Playwright symlink commands and available version commands; runner slot-wait accounting in text and JSON; slots reporting; and active-extension replacement refusal followed by successful replacement after the poll exits.

Supplied exact-target live evidence additionally covers actual public spawn/control/teardown with native Codex workers: ordinary refusal at cap 1, named ad hoc admission to occupancy 2, refusal to transfer that grant to another ordinary worker, removal of the grant on cleanup without modifying capacity declarations, and deferred --ad-hoc-slot replay through a real worker-park tick. The R worker starts without a second manual spawn, its replay record is consumed, and both generated per-cap grant bits are present. The cleanup log records all worker exits and guarded cleanups at exit 0, private tmux closure, and final occupancy/ad_hoc 0. Pane captures show actual native Codex tool execution.

The supplied focused fleet/project/admission regression logs also pass the under-cap, independent-cap, relaunch and old-record cases. These are supplementary behavioral tests, not additional live-worker proofs.

This turn only inspected source and evidence, read pipeline status/help, and copied supplied proof into the designated evidence directory. It started no servers/workers, reran no completed suites, changed no source, and left no working-tree fixtures. No UI change requires screenshots. Broad deferred coverage still requires CI green before merge.

Product scenarios are supported by retained and supplied live evidence. Overall Test remains no-go because the configured command has exit 1 and this phase cannot approve/override it. If the outer executor can accept its supported unrelated-failure classification, the product evidence is ready for that decision; do not interpret this report as a clean configured Test pass.
