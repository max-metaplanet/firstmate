#!/usr/bin/env python3
"""Private seat quota evidence cache; fm-seat-lib.sh remains the launch-policy owner.

Usage: fm-seat-quota-cache.py PROFILE READ_BOUND FLOOR POLICY [PROVIDER]
The existing bounded, non-renewing quota-axi transport runs under a
per-profile kernel lock. Its public JSON stays unchanged; this helper returns a
private envelope {report, note}. The public shell producer unwraps the report
without metadata. POLICY=raw serves rotation/login probes: they share fresh
reads and backoff but keep their per-pass memo and never receive aged fallback.

One machine-user cache lives at ~/.cache/firstmate-seat-quota (override with
FM_SEAT_QUOTA_CACHE_ROOT for isolated tests). SHA-256 of the seat provider, the
canonical profile directory, and the producer's NFC Keychain selector identifies
a record, so claude and codex never share one. PROVIDER defaults to claude and
is passed explicitly because FM_SEAT_PROVIDER reaches callers as a plain or
local shell assignment that no child process inherits; the bounded transport is
told the same provider this record is keyed to.
Environment bearer overrides never store or reuse successful evidence; only their
backoff is shared conservatively within the profile, without hashing any secret.
An ambient selector differs from explicitly naming ~/.claude, and aliases with
different Keychain selectors stay isolated, exactly as quota-axi resolves them. No
credential material is read. Directories are 0700, files 0600, publication is an
atomic replace, and flock releases on process death. Unsafe paths fail closed.

Fresh, successful OAuth evidence is reusable for <120 seconds from the producer's
refreshedAt. Only positive plan quota is cached: paid usage always needs a live
read. After transient failure, evidence is fallback-only through 900 seconds.
Fallback requires BOTH session and weekly windows, every account availability
and every session/weekly/monthly window to be known, >max(20, floor+10) percent
remaining, and no exhausted or unknown account runway. Projected exhaustion
must be more than 120 seconds ahead, both by timestamp and by age-adjusted
usableRunwaySeconds. Every declared boundedBy window must exist and clear the
same headroom threshold. Any reported extra-usage
window must have finite nonnegative spend and limit, and an allow-policy cap must
still exceed that spend. It never authorizes paid overflow from cached spend.
Unknown/auth-required/expired auth, missing or invalid credentials, and absent
profiles cannot fall back. A definitive auth failure retires the last good read.
The producer's state.retryAfter is an ISO instant, not error-message text; it
blocks all live reads by this cache until that instant, including unsafe-fallback
holds. Producer-owned stale quota is never promoted to a fresh success.
A failed refresh is shared with every reader that was already waiting on the
lock, and a reader whose lock wait expires judges the published record without
refreshing; both use only the same bounded last-good predicate or hold.
"""

import datetime
import fcntl
import hashlib
import json
import math
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import time
import unicodedata


def number(value):
    return type(value) in (int, float) and math.isfinite(value)


def instant(value):
    if not isinstance(value, str):
        return None
    try:
        parsed = datetime.datetime.fromisoformat(value.replace("Z", "+00:00"))
        return parsed.timestamp() if parsed.tzinfo else None
    except ValueError:
        return None


def row(report):
    if not isinstance(report, dict) or report.get("schemaVersion") not in (5, 6):
        return {}
    rows = [r for r in report.get("providers", [])
            if isinstance(r, dict) and r.get("provider") == "claude"]
    if report["schemaVersion"] == 6:
        rows = [r for r in rows if r.get("accountKey") == "default"]
    return rows[0] if len(rows) == 1 else {}


def applicable(report):
    return [a for a in row(report).get("quotaSemantics", {}).get("effectiveAvailability", [])
            if a.get("scope") in ("all_models", "all_products")]


def healthy_availability(items, boundary):
    return bool(items) and all(
        a.get("status") == "known" and number(a.get("effectivePercentRemaining"))
        and boundary < a["effectivePercentRemaining"] <= 100
        and a.get("runway", {}).get("status") in ("through_reset", "projected_exhaustion")
        for a in items)


def runway_current(items, now, age, margin=0):
    for availability in items:
        runway = availability.get("runway", {})
        if runway.get("status") == "projected_exhaustion":
            exhaustion = instant(runway.get("projectedExhaustedAt"))
            seconds = runway.get("usableRunwaySeconds")
            if exhaustion is None or exhaustion <= now + margin or not number(seconds) or seconds <= age + margin:
                return False
    return True


def success(report, now):
    r = row(report)
    state = r.get("state", {})
    stamp = instant(state.get("refreshedAt"))
    return (r.get("source") == "oauth" and state.get("status") == "fresh"
            and state.get("stale") is False and not state.get("error")
            and state.get("authStatus") in (None, "usable")
            and stamp is not None and 0 <= now - stamp < 120
            and healthy_availability(applicable(report), 0)
            and runway_current(applicable(report), now, now - stamp))


def transient(report):
    if report is None:
        return True
    r = row(report)
    state = r.get("state", {})
    if state.get("authStatus") not in (None, "usable") or state.get("status") == "auth_required":
        return False
    if state.get("error") in ("credentials_missing", "credentials_invalid", "Claude sign-in required"):
        return False
    attempts = r.get("attempts", [])
    if attempts and all(a.get("status") == "skipped" and a.get("error") in
                        ("credentials_missing", "credentials_invalid") for a in attempts):
        return False
    return state.get("status") in ("rate_limited", "unavailable", "error", "stale") or not r


def comfortable(report, floor, policy, now, age):
    boundary = max(20, floor + 10)
    if not healthy_availability(applicable(report), boundary):
        return False
    windows = row(report).get("windows", [])
    ids = [w.get("id") for w in windows]
    if len(ids) != len(set(ids)):
        return False
    declared = set()
    for availability in applicable(report):
        bounds = availability.get("boundedBy")
        if not isinstance(bounds, list) or not bounds or not all(isinstance(b, str) for b in bounds):
            return False
        declared.update(bounds)
    if not runway_current(applicable(report), now, age, 120):
        return False
    if not declared.issubset(set(ids)):
        return False
    bounded = [w for w in windows if w.get("kind") in ("session", "weekly", "monthly")
               or w.get("id") in declared]
    if not {"session", "weekly"}.issubset({w.get("kind") for w in bounded}):
        return False
    if not all(number(w.get("percentRemaining")) and boundary < w["percentRemaining"] <= 100
               for w in bounded):
        return False
    for w in windows:
        if w.get("id") == "extra_usage":
            if not (number(w.get("spentUsd")) and number(w.get("limitUsd"))
                    and 0 <= w["spentUsd"] <= w["limitUsd"]):
                return False
            if policy.startswith("allow ") and w["spentUsd"] >= float(policy[6:]):
                return False
    return True


def private(path, directory=False):
    info = path.lstat()
    wanted = stat.S_ISDIR if directory else stat.S_ISREG
    if not wanted(info.st_mode) or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != (0o700 if directory else 0o600):
        raise ValueError("unsafe cache permissions or path")


def publish(path, record):
    fd, name = tempfile.mkstemp(prefix=".publish-", dir=path.parent)
    try:
        with os.fdopen(fd, "w") as stream:
            json.dump(record, stream, allow_nan=False)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def live(profile, bound, lock_fd, provider):
    # Keep the existing producer, timeout, argument list, and JSON schema owner.
    script = Path(__file__).resolve().parent
    command = '. "$1/fm-timeout-lib.sh"; . "$1/fm-seat-lib.sh"; fm_seat_quota_live "$2"'
    read_deadline = int(time.time()) + bound
    if os.environ.get("FM_SEAT_READ_DEADLINE"):
        read_deadline = min(read_deadline, int(os.environ["FM_SEAT_READ_DEADLINE"]))
    # The caller's FM_SEAT_PROVIDER may be a plain or local shell assignment that
    # never entered this process's environment, so the transport is told the
    # provider this record is keyed to instead of re-deriving a claude default.
    env = dict(os.environ, FM_SEAT_READ_DEADLINE=str(read_deadline),
               FM_SEAT_PROVIDER=provider)
    env.pop("FM_SEAT_READ_MEMO_DIR", None)
    # The bounded transport inherits the lock: killing this coordinator cannot
    # permit another refresh while its already-started request is still running.
    result = subprocess.run(["bash", "-c", command, "seat-quota", str(script), profile],
                            env=env, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                            stderr=subprocess.DEVNULL, text=True, check=False, pass_fds=(lock_fd,))
    try:
        return json.loads(result.stdout) if result.returncode == 0 else None
    except ValueError:
        return None


def evidence(profile, bound, floor, policy, provider="claude"):
    if provider not in ("claude", "codex"):
        raise ValueError("unsupported seat provider")
    canonical = Path(profile or Path.home() / ("." + provider)).resolve()
    if policy != "raw" and profile and not canonical.is_dir():
        return {"report": None, "note": "source=hold profile-missing"}
    root = Path(os.environ.get("FM_SEAT_QUOTA_CACHE_ROOT", Path.home() / ".cache/firstmate-seat-quota"))
    root.mkdir(mode=0o700, parents=True, exist_ok=True)
    private(root, True)
    # quota-axi/Claude hash the raw NFC selector for Keychain, not realpath.
    # Include both filesystem identity and secure-store identity; collapsing
    # aliases or the ambient/explicit default would merge distinct accounts.
    # The secure-store selector and ambient token are Claude's; a codex read is
    # keyed by its own home, and the provider itself separates the two records
    # so one profile path can never serve another provider's quota.
    claude = provider == "claude"
    storage = (os.environ.get("CLAUDE_SECURESTORAGE_CONFIG_DIR") if claude else None) or profile or None
    token_selected = claude and bool(os.environ.get("CLAUDE_CODE_OAUTH_TOKEN", "").strip())
    identity = [provider, unicodedata.normalize("NFC", str(canonical)),
                unicodedata.normalize("NFC", storage) if storage else None, token_selected]
    key = hashlib.sha256(json.dumps(identity).encode()).hexdigest()
    path = root / (key + ".json")
    lock = root / (key + ".lock")
    fd = os.open(lock, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "r+") as stream:
        private(lock)
        started = time.time()
        deadline = time.monotonic() + bound
        locked = False
        while not locked:
            try:
                fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
                locked = True
            except BlockingIOError:
                if time.monotonic() >= deadline:
                    break
                time.sleep(0.1)
        # Without the lock this still reads only an atomically replaced record.
        now = time.time()
        record = {"version": 1, "key": key, "good": None, "retryAt": 0}
        if path.exists() or path.is_symlink():
            private(path)
            record = json.loads(path.read_text())
            if (record.get("version") != 1 or record.get("key") != key
                    or not number(record.get("retryAt")) or record["retryAt"] < 0
                    or not number(record.get("failedAt", 0)) or record.get("failedAt", 0) < 0):
                raise ValueError("invalid cache record")
        good = None if token_selected else record.get("good")
        observed = instant(row(good).get("state", {}).get("refreshedAt"))
        age = now - observed if observed is not None else None
        backoff = max(0, math.ceil(record["retryAt"] - now))
        note = f"age={max(0, int(age)) if age is not None else 'unknown'}s backoff={backoff}s"
        if backoff == 0 and good is not None and success(good, now):
            return {"report": good, "note": "source=fresh-cache " + note}
        # A failure attempted while this reader waited answers the whole burst;
        # a reader arriving after it retries, so no backoff is invented.
        failed_at = record.get("failedAt", 0)
        shared = (locked and not backoff and not token_selected
                  and "failure" in record and failed_at >= started)
        if backoff:
            report, failure = record.get("failure"), "backoff"
        elif shared:
            report, failure = record["failure"], f"shared-{max(0, int(now - failed_at))}s-ago"
        elif not locked or deadline - time.monotonic() <= 0:
            report, failure = None, "cache-lock-timeout"
        else:
            report = live(profile, max(1, math.ceil(deadline - time.monotonic())),
                          stream.fileno(), provider)
            failure = "live"
            now = time.time()
            retry = instant(row(report).get("state", {}).get("retryAfter"))
            record["retryAt"] = max(0, retry or 0)
            if not token_selected and success(report, now):
                record["good"] = report
                record.pop("failure", None)
                record.pop("failedAt", None)
                publish(path, record)
                return {"report": report, "note": "source=live age=0s backoff=0s"}
            record["failure"] = report
            record["failedAt"] = now
            # A readable current quota (including low/paid/unknown quota) replaces
            # the old evidence; only a transient failure may retain it.
            if not transient(report):
                record["good"] = None
                good = None
            publish(path, record)
        age = now - observed if observed is not None else None
        backoff = max(0, math.ceil(record["retryAt"] - now))
        note = (f"age={max(0, int(age)) if age is not None else 'unknown'}s "
                f"backoff={backoff}s failure={failure}")
        if policy == "raw":
            return {"report": report, "note": "source=producer " + note}
        if (good is not None and age is not None and 0 <= age <= 900
                and success(good, observed) and transient(report) and comfortable(good, floor, policy, now, age)):
            return {"report": good, "note": "source=last-good-fallback " + note}
        # Never let the producer's own (up to seven day) stale cache bypass this
        # gate's bounded fallback, or use any report as live during backoff.
        state = row(report).get("state", {})
        hard_auth = (state.get("status") == "auth_required"
                     or state.get("authStatus") == "unusable"
                     or state.get("error") in ("credentials_missing", "credentials_invalid"))
        if hard_auth or backoff or row(report).get("source") == "cache" or state.get("stale"):
            report = None
        return {"report": report, "note": "source=live-or-hold fallback=unsafe-or-missing " + note}


def main():
    try:
        answer = evidence(sys.argv[1], int(sys.argv[2]), float(sys.argv[3]), sys.argv[4],
                          sys.argv[5] if len(sys.argv) > 5 else "claude")
    except (OSError, ValueError, TypeError, KeyError, AttributeError, OverflowError):
        answer = {"report": None, "note": "source=hold cache-unreadable"}
    print(json.dumps(answer, allow_nan=False))


if __name__ == "__main__":
    main()
