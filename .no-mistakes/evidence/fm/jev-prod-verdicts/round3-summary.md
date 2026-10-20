# Round 3 live comparison: base d9717ac7 vs head 688c1b4f
Both ran 8 consecutive real polls (`bin/fm-jev-prod-check.sh check`, default 20s budget,
FM_JEV_PROD_BATCH_SECS=0 so batched items print immediately) against live
metaplanet-jp/core with lookback 48h, each in its own throwaway FM_HOME.

| | base | head |
|---|---|---|
| couldnt-check items emitted | 12 | 1 |
| production=build-skipped | 11 | 0 (11 sections recorded silently as `outcome ... not-applicable build-skipped`) |
| production=deployment-unreadable | 1 (PR 2283 portal:portal-previous) | 0 |
| production=read-budget-exhausted | 0 | 1 (PR 2283 portal:portal-previous) |
| cursor path | 2293→2292→2283→2272→2275→2285→2282→2284 | identical, advances every poll |

PR 2283 ground truth (round3-pr2283-portal-previous-ground-truth.txt): the Production – core-metaplanet
deployment 7195689137 has a `success` status at 08:58:59Z (no API/credential failure),
the merge has 96 deployment_status jev-check runs whose artifact listings consume the
budget, and portal:portal-previous has only a pre-merge section >1h after the deploy.
So this section is a genuine missing-production-verdict gap; head now names the budget as
the reason instead of claiming the deployment is unreadable, and the rotation moves past it.
