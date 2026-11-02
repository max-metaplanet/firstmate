# Claude Code slash-completion composer fixtures

These two frames are the replay inputs for the completion-popup cases in [`../../fm-composer-lib.test.sh`](../../fm-composer-lib.test.sh) and [`../../fm-backend-herdr.test.sh`](../../fm-backend-herdr.test.sh).
They exercise the bare-row selection in [`../../../bin/fm-composer-lib.sh`](../../../bin/fm-composer-lib.sh), which owns which row on a screen is the composer.

## Why they exist

Claude marks the selected row of its slash-command completion list with the SAME agent prompt glyph its composer uses, and it draws that list on either side of the composer.
A pane that drew it BELOW the composer's closing rule therefore put a second, lower agent-glyph row on the screen, and the bottom-most-candidate rule selected the list instead of the composer: the composer read returned `/exit Exit the CLI /context Visualize current context usage ...`, the typed `/exit` was judged unsent, and `bin/fm-control.sh exit` cleared it and reported that the exit command could not be sent.

| File | Shape | What the composer read must return |
| --- | --- | --- |
| `slash-popup-below-composer.pane` | the list below the composer's closing rule | `/exit`, the composer's own row |
| `slash-popup-above-composer.pane` | the same list above the composer, over the footer row | `/exit`, the composer's own row |

`slash-popup-above-composer.pane` is the control: that shape already read correctly, and the fix must not move it.

## String provenance

The composer rules, the composer row (prompt glyph, then U+00A0, then the typed command), the three completion rows with their two-column `/name` + gap + description layout, and the `⏵⏵ bypass permissions on · PR … · 1 shell` footer are transcribed byte for byte, including their 119-column rules and their indentation, from captures taken on 2026-11-02 against Claude Code 2.1.316 on Herdr 0.9.1: a live worker pane that had just refused the exit command, and a lab pane of the same build that rendered the list above its composer.
The command names and descriptions are the shipped product's own (`/exit`, `/context`, `/usage-credits`).

The transcript rows above the composer are composed, and the PR number in the footer is `#0000`: the real captures carry the worker's own project text, which is why the raw captures are not committed here.

## Replay transformations and limits

| Required shape | Real anchor used | What remains unproven live |
| --- | --- | --- |
| The composer read selects the composer, not the completion list, when the list is below it | The refusing live pane's own rows and geometry | The frames are plain text: ANSI styling the live pane also carried is not represented, so these cases pin structure only |
| The above-list shape keeps reading correctly | A lab pane of the same build | Same |

Passing replay assertions establish behavior for these explicit inputs.
No frame can establish that this is still the shape Claude renders, and no frame can carry timing.
Both of those are the live guard's job: `FM_HERDR_SUBMIT_CONFIRM_LIVE=1 tests/fm-herdr-submit-confirm-live-e2e.test.sh` submits a real `/exit` to a real Claude behind its real completion list, and separately requires the real composer to paint typed text inside the payload proof's bounded window.
The timing half of the same failure - the composer still reading empty 1.2s after the text was typed - is pinned portably by the stubbed call sequences in [`../../fm-backend-herdr.test.sh`](../../fm-backend-herdr.test.sh).
