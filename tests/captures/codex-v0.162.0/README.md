# Codex quota-wall pane fixtures

These frames are the replay inputs for the Codex cases in [`../../fm-quota-wall.test.sh`](../../fm-quota-wall.test.sh) and [`../../fm-crew-state.test.sh`](../../fm-crew-state.test.sh).
They exercise `fm_quota_wall_detect` in [`../../../bin/fm-quota-wall-lib.sh`](../../../bin/fm-quota-wall-lib.sh), which owns the needle list this directory supplies evidence for.

## String provenance

Every banner string in these frames is unchanged vendor text from the shipped `@openai/codex` 0.162.0 artifact.
The artifact read was `node_modules/@openai/codex-darwin-arm64/vendor/aarch64-apple-darwin/bin/codex` inside that package, on 2026-10-15.
Each string was confirmed present as an exact byte sequence with `LC_ALL=C grep -q -a -F -- "<string>" <artifact>`, which is also what [`../../fm-quota-wall-banners-live-e2e.test.sh`](../../fm-quota-wall-banners-live-e2e.test.sh) re-runs against whatever Codex is installed, so a string dropped in a later release fails loudly instead of silently turning the detector off.

| File | Vendor strings it carries | Class the detector must report |
| --- | --- | --- |
| `out-of-credits.pane` | `You're out of credits.`, `Your workspace is out of credits. Add credits to continue using Codex.` | `out-of-credits` |
| `usage-limit.pane` | `Usage limit reached.`, `You've reached your usage limit. Increase your limits to continue using codex.` | `usage-limit` |
| `usage-limit-typographic.pane` | `You`+U+2019+`ve hit your usage limit.`, `Visit https://chatgpt.com/settings/usage to purchase more credits` | `usage-limit` |

`Your workspace is out of credits` is also the exact text observed on the two workers whose stop occasioned this library, on 2026-10-15 at about 21:35 UTC.

The typographic frame exists because the vendor mixes both apostrophes within one build: `You`+U+2019+`ve hit your usage limit` ships beside `You've reached your usage limit`.
That is why the detector folds U+2019 to the ASCII apostrophe before matching, and why one frame has to carry the raw multi-byte form.

## Replay transformations and limits

The banner strings are unchanged; the surrounding frame is composed.
Prompt echoes, tool-call lines, the composer glyph and the model/context footer are written to the shape Codex renders them in, so the frames read like a captured tail, but they were not captured from a live walled pane: producing one would require actually exhausting a workspace's credits.

| Required shape | Real anchor used | What remains unproven live |
| --- | --- | --- |
| A credit wall is recognized from the worker's own window | The shipped artifact's own banner strings, and the observed incident text | The frame around them is composed, so pane geometry, wrapping and any ANSI decoration a real stop renders are not represented |
| Both vendor apostrophe forms are recognized | Both forms confirmed present as exact bytes in one artifact | Which banner a given stop renders in which form was not observed |
| An idle window with no banner stays on the ordinary stale path | `../claude-v2.1.301/idle-no-wall.pane` | No recorded non-wall Codex idle frame; the negative case is covered by the Claude frame and by composed inputs |

Passing replay assertions establish behavior for these explicit inputs, not the absent live scenarios in the final column.
