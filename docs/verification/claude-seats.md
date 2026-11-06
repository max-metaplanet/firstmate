# Seat login-state verification

Audience: maintainer verification.

This record supports the seat login-state classifier in
[`bin/fm-seat-lib.sh`](../../bin/fm-seat-lib.sh)'s `fm_seat_logged_in` and the states
[`docs/claude-seats.md`](../claude-seats.md) documents.
It records only the vendor-emitted facts that must be re-established when quota-axi or
a vendor CLI changes.
Task chronology and incident transcripts stay in private reports or PR evidence.

The classifier reads machine-readable fields - `state.authStatus` and each attempt's
`status` and `error` - rather than any error string, because
the same credential state is reported with different messages depending on which route
produced it.
The fixtures in [`tests/fm-seat.test.sh`](../../tests/fm-seat.test.sh) reproduce the
shapes below, and the portable suite is what enforces the classifier in CI; this record
is what says those fixtures still match the real tool.

## The field contract the classifier depends on

Verified 2026-09-24 against quota-axi 0.1.53 on darwin-arm64.

`quota-axi`'s own type declares the contract, in `dist/src/types.d.ts`:

```
/**
 * Machine-readable local auth usability, distinct from quota freshness.
 * Callers must not infer logout from provider status alone when this is set.
 */
export type ProviderAuthStatus = "usable" | "expired_refreshable" | "unusable";
```

`expired_refreshable` is documented there as soft expiry, not sign-out.

## Signed in, access token lapsed, session renewable

Reproduced on a throwaway Keychain-backed profile holding an expired credential that
still carried a refresh token.
A file-backed credential file does NOT reproduce this state on macOS: quota-axi
replaces a refreshable soft expiry from an oauth-file sidecar with the Keychain error
whenever the Keychain itself could not be read, so the read returns
`keychain_unreachable` instead.

```
CLAUDE_CONFIG_DIR=<profile> quota-axi --provider claude --no-credential-refresh --full --json
```

```json
{"source":"unavailable","status":"unavailable",
 "error":"Claude access token expired","authStatus":"expired_refreshable",
 "attempts":["oauth-file:skipped:credentials_missing",
             "keychain:failed:Claude access token expired"]}
```

The same state reached by the other route, when the quota endpoint rate limited the
read and the expiry was confirmed against the profile endpoint:

```json
{"source":"unavailable","status":"unavailable",
 "error":"Claude credential expired","authStatus":"expired_refreshable",
 "attempts":["oauth-file:skipped:credentials_missing",
             "keychain:failed:Claude quota endpoint rate limited",
             "oauth-profile:failed:identity_profile_http_401"]}
```

The error text differs between the two; `state.authStatus` does not.
That divergence is why the classifier matches the field, and
`test_the_lapsed_verdict_comes_from_the_field_not_the_message` pins it.

## Genuinely signed out

Reached by letting `claude doctor` run on that profile with a refresh token Anthropic
rejects.
Claude Code cleared the session in place: the Keychain item survived with
`accessToken` and `refreshToken` empty and `expiresAt` 0.

```json
{"source":"unavailable","status":"auth_required","error":"credentials_invalid",
 "attempts":["oauth-file:skipped:credentials_missing",
             "keychain:skipped:credentials_invalid (credentialPresent)"]}
```

This is NOT the every-attempt-`credentials_missing` shape the older attempts test looked
for, which is why the attempts test also accepts `credentials_invalid`: a sign-out is
established when every attempt was skipped because its store was inspected and found
missing or invalid.
Before this was read, both this state and the lapsed state above reported the same
`unknown` verdict and `--force` could cross either.

`auth_required` alone is NOT safe as a hard refusal, and the classifier ignores it.
quota-axi 0.1.53 also raises `auth_required` for any 401 from the usage endpoint
(`rejectUnusableUsageResponse`), including one against a locally valid credential that
still holds a refresh token; that read carries a `failed` keychain attempt and stays
undecided, so `--force` may cross it.

## Access token lifetime

Verified 2026-09-24 by reading only the `expiresAt` field of a real seat's credential
across a renewal, with no write and no refresh of any kind:

```
19:39:40Z start   expiresAt=2026-09-24T19:52:24.409Z
19:47:42Z RENEWED expiresAt -> 2026-09-25T03:47:31.503Z
```

The renewal landed at 19:47:31 and set expiry to 03:47:31: an **eight-hour** token
lifetime, and a renewal fired roughly five minutes BEFORE expiry by the running
session rather than after it.
So an active seat effectively never lapses, and `expired-renewable` is specifically the
reading for a seat nothing has launched on for eight hours.

## Why every seat quota read passes `--no-credential-refresh`

`quota-axi --help` states that every quota read "may delegate an expired session's
renewal to the vendor CLI that owns it", and `--no-credential-refresh` disables that
delegation.
The delegate is `claude doctor`.
quota-axi's own source records why a second refresher is dangerous:

> The value of a Claude refresh token never enters quota-axi: Anthropic rotates it on
> use, so exchanging it here would spend the Claude CLI's own single-use token and sign
> the user out of Claude Code.

> Claude Code owns its own session and refreshes it on its own schedule, and the refresh
> token behind that session is single-use. A second refresher racing a live session is
> how one holder ends up presenting a spent token.

Removing the flag would also achieve little here: quota-axi's own concurrency check
stands down whenever any Claude Code process is running on the machine, and treats an
unlistable process table the same way, so a fleet with crew running almost always trips
it.

## Grok: the published auth status is the whole verdict

Verified 2026-11-06 against quota-axi 0.1.69 and grok 1.0.77 on darwin-arm64.

Grok reports **no `oauth` source at all**, so the Claude and Codex positive test
(`.source == "oauth"`) can never pass for it and the classifier keys on
`state.authStatus` instead. A Grok account is selected entirely by its config home, so
each read below names that home; a read that omits `GROK_HOME` reports whichever account
the ambient home holds.

A signed-in home (measured at `~/.grok-max2`, before the second home moved to `~/.grok-seats/max2`):

```
$ GROK_HOME=~/.grok-max2 quota-axi --provider grok --no-credential-refresh --full --json
  "source": "web", "account": {"email": "max2@metaplanet.jp"},
  "state": {"authStatus": "usable"},
  "attempts": [{"source": "web", "status": "success", "error": null},
               {"source": "pi:xai", "status": "skipped", "error": "credentials_missing"}]
```

A home holding no Grok credential:

```
$ GROK_HOME=$(mktemp -d) quota-axi --provider grok --no-credential-refresh --full --json
  "source": "unavailable", "state": {"authStatus": "unusable"},
  "attempts": [{"source": "auth-json", "status": "skipped", "error": "credentials_missing"},
               {"source": "pi:xai", "status": "skipped", "error": "credentials_missing"}]
```

The empty-home shape is already the proven-empty shape the classifier's last test reads -
`source: unavailable` with every attempt skipped for `credentials_missing` - so Grok's
signed-out verdict needs no branch of its own. Only its positive verdict does.

Two further facts the implementation depends on:

- **`GROK_HOME` isolates, and quota-axi honours it.** The two homes above report different
  account emails (`max@metaplanet.jp` and `max2@metaplanet.jp`) and different remaining
  percentages in the same second, so the home is a real account selector rather than a
  hint.
- **`--profile-only` is not available for Grok.** `quota-axi --help` states the flag
  "requires explicit CLAUDE_CONFIG_DIR or CODEX_HOME"; passing it with `--provider grok`
  exits 5 and prints no report. The Grok transport therefore passes only
  `--no-credential-refresh`, and `tests/fm-seat.test.sh`'s Grok fake refuses the flag so a
  regression that added it fails there.

Grok publishes no `expired_refreshable` state, which is why this fleet has no guarded Grok
renewal and [`bin/fm-seat-renew.sh`](../../bin/fm-seat-renew.sh) refuses the provider.

## Refreshing this record

Re-run the reads above against the installed quota-axi after a quota-axi, Claude Code or
Grok upgrade, and confirm `state.authStatus` and the per-attempt `status` and `error` still carry these
values.
If any of these fields is renamed or dropped, the classifier falls back to reporting `unknown`
for both states, which is the pre-existing behaviour rather than an unsafe one, and
`tests/fm-seat.test.sh`'s fixtures must be re-captured.
