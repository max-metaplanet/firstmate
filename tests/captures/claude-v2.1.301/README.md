# Claude Code quota-wall pane fixtures

These frames are the replay inputs for the Claude cases in [`../../fm-quota-wall.test.sh`](../../fm-quota-wall.test.sh) and [`../../fm-crew-state.test.sh`](../../fm-crew-state.test.sh).
They exercise `fm_quota_wall_detect` in [`../../../bin/fm-quota-wall-lib.sh`](../../../bin/fm-quota-wall-lib.sh), which owns the needle list this directory supplies evidence for.

## String provenance

Every banner string in these frames is unchanged vendor text from the shipped Claude Code 2.1.301 executable, read at `~/.local/share/claude/versions/2.1.301` on 2026-10-15.
Each string was confirmed present as an exact byte sequence with `LC_ALL=C grep -q -a -F -- "<string>" <artifact>`, which is also what [`../../fm-quota-wall-banners-live-e2e.test.sh`](../../fm-quota-wall-banners-live-e2e.test.sh) re-runs against whatever Claude Code is installed, so a string dropped in a later release fails loudly instead of silently turning the detector off.

| File | Vendor strings it carries | Class the detector must report |
| --- | --- | --- |
| `usage-limit.pane` | `Usage limit reached`, `your usage limit resets`, `/upgrade to increase your usage limit.` | `usage-limit` |
| `extra-usage-stop.pane` | `Usage limit reached`, `You've hit your monthly spend limit.`, `/usage-credits to adjust your monthly spend limit.` | `extra-usage` |
| `idle-no-wall.pane` | none | no wall at all |

`extra-usage-stop.pane` deliberately carries BOTH a usage-limit string and a spend-limit one, because that is the shape of the stop it represents: the plan quota is gone and the paid extra usage that would cover it is capped.
The detector must report the more specific `extra-usage` for it, which is what makes the class order in `fm_quota_wall_classes` load-bearing rather than cosmetic.

`idle-no-wall.pane` is the negative control: an ordinary idle Claude window with no banner, which must stay on the existing stale path and must never be moved.

## Replay transformations and limits

The banner strings are unchanged; the surrounding frame is composed.
The prompt echo, tool-result line, box-drawn composer and shortcut hint are written to the shape Claude Code renders them in, so the frames read like a captured tail, but they were not captured from a live walled session: producing one would require actually exhausting an account's limit and its extra-usage cap.

| Required shape | Real anchor used | What remains unproven live |
| --- | --- | --- |
| A usage wall is recognized from the worker's own window | The shipped executable's own banner strings | The frame around them is composed, so pane geometry, wrapping and any ANSI decoration a real stop renders are not represented |
| A capped extra-usage stop is classified as itself, not as a plain usage limit | Both vendor strings confirmed present as exact bytes in one artifact | That the two render together in one frame is inferred from the product's documented behavior, not observed on a stopped session |
| An idle window with no banner stays on the ordinary stale path | An ordinary idle frame in the same rendered shape | Composed like the others |

Passing replay assertions establish behavior for these explicit inputs, not the absent live scenarios in the final column.
