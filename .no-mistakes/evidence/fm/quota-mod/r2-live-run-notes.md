# firstmate-quota live run (this run, files prefixed r2-, plus claude-p-seats-transcript.txt and seat-board-json-transcript.txt)

Herdr lab fm-lab-quota3-91649-13547 (provisioned + torn down via bin/fm-herdr-lab.sh, teardown exit 0), Claude Code 2.1.291,
CLAUDE_CONFIG_DIR=seat-max-gmail, FM_SEAT_BOARD_CACHE_DIR = throwaway copy of ~/.cache/fm-seat-board
(seat-max file aged to 10 days, others touched to now). The real cache was never written.

- r2-01: FM_QUOTA_ENABLED=1, band on startup: live seat 5h/7d % left + reset wait, "others tightest seat-max 3% (10d old, stale)".
- r2-02 (05:18:54): /seats pane: every seat, [this session]/[new workers] marks, per-seat ages (43s/44s old, 10d old stale), "read 19s ago; next live refresh in 10m".
- r2-03 (05:19:47): no new read ("read 59s ago"), the same rows now say "(1m old, stale)": ages advance with the clock.
- r2-04 (05:19:58): Refresh (r): "read 0s ago; next live refresh in 9m"; cache mtimes identical before/after (r2-cache-mtimes-*), so no refreshing read.
- r2-05: relaunched with FM_QUOTA_ENABLED unset: no band, /seats is not in the command completions. Input was never submitted.

Unintended spend: one relaunch command was typed into a still-running Claude session and submitted as a prompt
(~$0.51, interrupted). Separately, the claude -p gate-off checks fell through to the model (~$0.45 each, several runs).
