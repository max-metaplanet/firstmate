# firstmate-quota live run notes (Herdr lab fm-lab-quota-58061-20487, Claude Code 2.1.291, seat-max-gmail)

- w1: FM_QUOTA_ENABLED=1, real cache, default interval. Started ~04:59:3x. Band + /seats drawn (01, 02).
  Refresh (r) at ~05:00:35 -> "read 0s ago; next live refresh in 9m"; ~/.cache/fm-seat-board mtimes unchanged (03, cache-mtimes-*).
  Its single live refresh then landed at 05:09:54-58 (~10 min after start) and refilled the real board cache (designed behavior).
- w2: FM_QUOTA_ENABLED=1, FM_QUOTA_REFRESH_SECONDS=10 (below floor), temp cache dir.
  Pane said "next live refresh in 2m" (floor). 8 Refresh presses -> 0 quota calls.
  Live refreshes at 05:05:19-23 and 05:07:19-21 only (one read per seat per 2-min interval) (cadence-watch.log, 04).
  The PATH-stub for quota-axi was not picked up (pane shell re-prepends fnm path), so those were real
  `quota-axi --no-credential-refresh` reads written only into the temp cache.
- w3: FM_QUOTA_ENABLED=1, temp cache touched to now, default interval: "(13s old)" at 05:07:53 -> "(1m old, stale)" at 05:09:18
  with no new read (05, 06).
- w3 relaunched with FM_QUOTA_ENABLED unset: no band, /seats not offered (07). Input cleared, never submitted.
- Lab torn down via bin/fm-herdr-lab.sh teardown (exit 0); default session untouched.
