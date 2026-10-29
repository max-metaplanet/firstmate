Instruction012 serial rerun comparison

Pipeline head b3809439d09733d9f9534db9c451c7e45bbfb6d4 and refreshed origin/main e2f8f938344ee5ba6801772abd62f6b040dec2fd were unchanged since prior archives. Both full failing suites were run alone, serially, from their exact read-only archives. Result records: round6-comparison-results.json; exact transcripts: round6-compare-{branch,main}-{fm-remote-job-orphan-reap,fm-extension-binding}.log; driver round6-comparisons.py.

Target orphan reaper exit0; main orphan reaper exit0. This includes the currently reported serving-child/process-group assertion; it did not reproduce alone on target or main. Target full extension suite exit0, including local lock-order cleanup AND remote conformance. Main extension suite exit1 at missing Node / remote transport never published binding, before the reported lock-order terminal-source assertion. No assertion is made that these are identical baseline failure causes.

Both current target failures pass alone on target. Firstmate instruction012 explicitly says to record them as unrelated/nonreproducing rather than change code in this situation. No source changes made. These passes classify the loaded configured-command failures; they are not represented as a clean pass for that separate configured command, and no Test override/skip is authorized.
