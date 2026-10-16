"""Deterministic public dispatch-interface regressions, called by fm-seat.test.sh.

Fake quota-axi reads documents and logs requests; no credentials or network.
Cache aging changes persisted test evidence, never production source or clocks.
"""
import concurrent.futures
import datetime
import fcntl
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import time

ROOT = Path(sys.argv[1])
BASE = Path(sys.argv[2])


def iso(age=0):
    return datetime.datetime.fromtimestamp(time.time() - age, datetime.timezone.utc).isoformat()


def quota(left=80):
    return {"schemaVersion": 5, "providers": [{
        "provider": "claude", "source": "oauth",
        "state": {"status": "fresh", "stale": False, "refreshedAt": iso()},
        "windows": [{"id": key, "kind": kind, "percentRemaining": left}
                    for key, kind in [("five_hour", "session"), ("seven_day", "weekly")]],
        "quotaSemantics": {"status": "known", "effectiveAvailability": [{
            "scope": "all_models", "status": "known", "effectivePercentRemaining": left,
            "boundedBy": ["five_hour", "seven_day"],
            "runway": {"status": "through_reset"}}]}}]}


def failure(status="rate_limited", **state):
    return {"schemaVersion": 5, "providers": [{"provider": "claude", "source": "unavailable",
            "windows": [], "state": {"status": status, **state},
            "quotaSemantics": {"status": "unknown", "effectiveAvailability": []}}]}


class Case:
    def __init__(self):
        self.base = Path(tempfile.mkdtemp(dir=BASE))
        self.profile = self.base / "profile"
        self.profile.mkdir()
        self.config = self.base / "config"
        self.config.mkdir()
        (self.config / "claude-seat-extra-usage").write_text("stop\n")
        self.cache = self.base / "cache"
        self.calls = self.base / "calls"
        self.response = self.base / "response"
        fake = self.base / "quota-axi"
        fake.write_text('#!/usr/bin/env python3\nimport os,time\nfrom pathlib import Path\n'
                        'p=Path(os.environ["QUOTA_FIXTURE"])\n'
                        'with (p/"calls").open("a") as f: f.write(" ".join(__import__("sys").argv[1:])+"\\n")\n'
                        'time.sleep(float(os.environ.get("QUOTA_DELAY", "0")))\n'
                        'print((p/"response").read_text())\n')
        fake.chmod(0o700)
        self.env = dict(os.environ, PATH=str(self.base) + ":" + os.environ["PATH"],
                        QUOTA_FIXTURE=str(self.base), FM_SEAT_QUOTA_CACHE_ROOT=str(self.cache),
                        CONFIG=str(self.config))
        for name in ("CLAUDE_CODE_OAUTH_TOKEN", "CLAUDE_SECURESTORAGE_CONFIG_DIR", "FM_SEAT_READ_DEADLINE"):
            self.env.pop(name, None)
        self.set(quota())

    def set(self, value):
        self.response.write_text(json.dumps(value))

    def run(self, profile=None, **env):
        script = '. "$1/bin/fm-timeout-lib.sh"; . "$1/bin/fm-seat-lib.sh"; . "$1/bin/fm-quota-axi-lib.sh"; fm_seat_dispatch_reason "$(fm_seat_dispatch_decision "$2")"'
        return subprocess.run(["bash", "-c", script, "test", str(ROOT), str(profile or self.profile)],
                              env=dict(self.env, **env), capture_output=True, text=True)

    def expect(self, allowed, text, **env):
        out = self.run(**env)
        assert (out.returncode == 0) == allowed, out.stdout + out.stderr
        assert text in out.stdout, out.stdout + out.stderr
        return out.stdout

    def count(self):
        return len(self.calls.read_text().splitlines()) if self.calls.exists() else 0

    def age(self, age, mutate=None):
        path, = self.cache.glob("*.json")
        record = json.loads(path.read_text())
        record["good"]["providers"][0]["state"]["refreshedAt"] = iso(age)
        if mutate:
            mutate(record["good"]["providers"][0])
        path.write_text(json.dumps(record))
        return path


c = Case()
with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
    results = list(pool.map(lambda _: c.run(QUOTA_DELAY="1"), range(6)))
assert all(r.returncode == 0 for r in results), [r.stdout + r.stderr for r in results]
assert c.count() == 1, c.calls.read_text()
assert sum("source=fresh-cache" in r.stdout for r in results) == 5
assert "--provider claude --no-credential-refresh --full --json" in c.calls.read_text()
assert stat.S_IMODE(c.cache.stat().st_mode) == 0o700
assert all(stat.S_IMODE(p.stat().st_mode) == 0o600 for p in c.cache.iterdir())
# Another home/config shares the same profile evidence.
second = c.base / "second-config"
second.mkdir()
(second / "claude-seat-extra-usage").write_text("stop\n")
c.expect(True, "source=fresh-cache", CONFIG=str(second))
assert c.count() == 1
# A symlink profile selects another Keychain service in the real producer.
alias = c.base / "alias"
alias.symlink_to(c.profile)
assert c.run(profile=alias).returncode == 0
assert c.count() == 2
other = c.base / "other"
other.mkdir()
assert c.run(profile=other).returncode == 0
assert c.count() == 3
c.expect(True, "source=live", CLAUDE_SECURESTORAGE_CONFIG_DIR="another-store")
assert c.count() == 4
print("PASS: simultaneous readers refresh once; homes share evidence; credential selectors stay isolated; private permissions")

for age, allowed in [(110, True), (130, True), (890, True), (910, False)]:
    c = Case()
    c.expect(True, "source=live")
    c.age(age)
    c.set(failure())
    c.expect(allowed, "source=fresh-cache" if age == 110 else "source=last-good-fallback" if allowed else "fallback=unsafe-or-missing")
    assert c.count() == (1 if age == 110 else 2)

# A fresh cache cannot retain a projection whose usable runway has elapsed.
c = Case()
c.expect(True, "source=live")
c.age(100, lambda r: r["quotaSemantics"]["effectiveAvailability"][0]["runway"].update(
    status="projected_exhaustion", usableRunwaySeconds=50, projectedExhaustedAt=iso(50)))
c.set(failure())
c.expect(False, "fallback=unsafe-or-missing")
assert c.count() == 2

for content in ["not-json", "null", "[]"]:
    c = Case()
    c.expect(True, "source=live")
    c.age(200)
    c.response.write_text(content)
    c.expect(True, "source=last-good-fallback")
print("PASS: fresh TTL and 900-second last-good boundary, unreadable JSON fallback")


# A failed live read falls back at the launch boundary the policy itself
# enforces, never at a higher bar of its own: a seat at 18 percent is dispatched
# by a live read, so the same reading seconds past the fresh window must not be
# reported as quota that could not be read. At or below that boundary, and
# below a configured floor, it still refuses.
def remaining(value):
    def mutate(provider):
        for window in provider["windows"]:
            window["percentRemaining"] = value
        provider["quotaSemantics"]["effectiveAvailability"][0]["effectivePercentRemaining"] = value
    return mutate


for value, floor, allowed in [(18, None, True), (18, "20", False), (10, None, False), (0, None, False)]:
    c = Case()
    c.expect(True, "source=live")
    if floor:
        (c.config / "claude-seat-floor").write_text(floor + "\n")
    c.age(122, remaining(value))
    c.set(failure())
    c.expect(allowed, "source=last-good-fallback" if allowed else "fallback=unsafe-or-missing")
    assert c.count() == 2
print("PASS: a failed live read falls back at the configured launch boundary and refuses at or below it")

mutations = [
    lambda r: r["windows"][0].update(percentRemaining=10),
    lambda r: r["windows"][1].update(percentRemaining=10),
    lambda r: r["windows"][1].update(percentRemaining=None),
    lambda r: r["windows"].pop(),
    lambda r: r["windows"].append({"id": "month", "kind": "monthly", "percentRemaining": 0}),
    lambda r: r["quotaSemantics"]["effectiveAvailability"].append({"scope": "all_products", "status": "unknown"}),
    lambda r: r["quotaSemantics"]["effectiveAvailability"].append({"scope": "all_products", "status": "known", "effectivePercentRemaining": 10}),
    lambda r: r["quotaSemantics"]["effectiveAvailability"][0]["runway"].update(status="exhausted_now"),
    lambda r: r["windows"].append({"id": "extra_usage", "kind": "credits", "spentUsd": None, "limitUsd": 100}),
    lambda r: r["quotaSemantics"]["effectiveAvailability"][0].update(boundedBy=["missing-bound"]),
    lambda r: r["quotaSemantics"]["effectiveAvailability"][0]["runway"].update(status="projected_exhaustion", usableRunwaySeconds=250, projectedExhaustedAt=iso(-50)),
    lambda r: r["state"].update(authStatus="unusable"),
    lambda r: r.update(source="cache"),
]
for mutate in mutations:
    c = Case()
    c.expect(True, "source=live")
    c.age(200, mutate)
    c.set(failure())
    c.expect(False, "fallback=unsafe-or-missing")
c = Case()
c.expect(True, "source=live")
c.age(200)
(c.config / "claude-seat-floor").write_text("70\n")
c.set(failure())
c.expect(False, "fallback=unsafe-or-missing")
(c.config / "claude-seat-floor").write_text("69\n")
c.expect(True, "source=last-good-fallback")
# A sound projection and model-only restrictions do not create an account hold.
c = Case()
c.expect(True, "source=live")
c.age(200, lambda r: r["quotaSemantics"]["effectiveAvailability"][0]["runway"].update(
    status="projected_exhaustion", usableRunwaySeconds=1000, projectedExhaustedAt=iso(-1000)))
c.set(failure())
c.expect(True, "source=last-good-fallback")
c = Case()
schema6 = quota()
schema6["schemaVersion"] = 6
schema6["providers"][0]["accountKey"] = "default"
other_row = quota(0)["providers"][0]
other_row["accountKey"] = "another-account"
schema6["providers"].insert(0, other_row)
c.set(schema6)
c.expect(True, "source=live")
# Age the selected default row, not the unrelated account at index zero.
path, = c.cache.glob("*.json")
record = json.loads(path.read_text())
record["good"]["providers"][1]["state"]["refreshedAt"] = iso(200)
path.write_text(json.dumps(record))
c.set(failure())
c.expect(True, "source=last-good-fallback")
print("PASS: all bounding windows, projected runway, unknown facts, floors, paid/auth guards, and schema 6 account binding")

for status, state in [("auth_required", {}), ("error", {"error": "credentials_missing"}),
                      ("error", {"error": "credentials_invalid"}), ("unavailable", {"authStatus": "unusable"})]:
    c = Case()
    c.expect(True, "source=live")
    c.age(200)
    c.set(failure(status, **state))
    c.expect(False, "fallback=unsafe-or-missing")
    c.set(failure())
    c.expect(False, "fallback=unsafe-or-missing")
# The existing renewable-login exception survives without using last-good data.
c = Case()
c.expect(True, "source=live")
c.age(200)
c.set(failure("unavailable", authStatus="expired_refreshable"))
c.expect(True, "access token has lapsed")
assert json.loads(next(c.cache.glob("*.json")).read_text())["good"] is None
print("PASS: explicit auth failures retire evidence; existing renewable-login policy remains intact")

for age, allowed in [(200, True), (910, False)]:
    c = Case()
    c.expect(True, "source=live")
    c.age(age)
    c.set(failure(retryAfter=iso(-300)))
    c.expect(allowed, "backoff=")
    count = c.count()
    c.set(quota())
    c.expect(allowed, "backoff=")
    assert c.count() == count
    path, = c.cache.glob("*.json")
    record = json.loads(path.read_text())
    record["retryAt"] = time.time() - 1
    path.write_text(json.dumps(record))
    c.expect(True, "source=live")
    assert c.count() == count + 1
# Missing last-good also shares retry-after and holds without another request.
c = Case()
c.set(failure(retryAfter=iso(-300)))
c.expect(False, "backoff=")
c.expect(False, "backoff=")
assert c.count() == 1
# Producer-owned stale reports cannot renew the local cache or bypass its age.
c = Case()
stale = quota()
stale["providers"][0].update(source="cache")
stale["providers"][0]["state"].update(status="stale", stale=True, retryAfter=iso(-300))
c.set(stale)
c.expect(False, "fallback=unsafe-or-missing")
c.expect(False, "fallback=unsafe-or-missing")
assert c.count() == 1
print("PASS: authoritative ISO retry-after suppresses live reads for safe and unsafe/missing fallback")

# A failed refresh without retry-after answers every reader already waiting on
# the lock, with the same bounded fallback; later readers may retry.
def burst(case):
    with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
        return list(pool.map(lambda _: case.run(QUOTA_DELAY="1"), range(6)))
for name, last_good in [("safe", lambda c: c.age(200)),
                        ("unsafe", lambda c: c.age(200, lambda r: r["windows"][0].update(percentRemaining=10))),
                        ("missing", None)]:
    for response in [failure(), "not-json"]:
        c = Case()
        if last_good:
            c.expect(True, "source=live")
            last_good(c)
        before = c.count()
        c.set(response) if isinstance(response, dict) else c.response.write_text(response)
        results = burst(c)
        assert c.count() == before + 1, (name, c.calls.read_text())
        safe = name == "safe"
        assert all((r.returncode == 0) == safe for r in results), [r.stdout for r in results]
        source = "source=last-good-fallback" if safe else "fallback=unsafe-or-missing"
        assert all(source in r.stdout for r in results), [r.stdout for r in results]
        assert sum("failure=live" in r.stdout for r in results) == 1
        assert sum("failure=shared-" in r.stdout for r in results) == 5
        c.expect(safe, "failure=live")
        assert c.count() == before + 2
# A reader whose lock wait expires judges published evidence without a live read.
def held(case, allowed, text):
    path, = case.cache.glob("*.lock")
    with path.open("r+") as stream:
        fcntl.flock(stream, fcntl.LOCK_EX)
        return case.expect(allowed, text, FM_SEAT_READ_DEADLINE=str(int(time.time()) + 2))
for age, mutate, allowed, text in [
        (50, None, True, "source=fresh-cache"),
        (200, None, True, "source=last-good-fallback"),
        (200, lambda r: r["windows"][1].update(percentRemaining=10), False, "fallback=unsafe-or-missing"),
        (910, None, False, "fallback=unsafe-or-missing")]:
    c = Case()
    c.expect(True, "source=live")
    c.age(age, mutate)
    c.set(failure())
    out = held(c, allowed, text)
    assert c.count() == 1
    assert age == 50 or "failure=cache-lock-timeout" in out, out
c = Case()
c.expect(True, "source=live")
path, = c.cache.glob("*.json")
path.unlink()
held(c, False, "failure=cache-lock-timeout")
assert c.count() == 1
print("PASS: concurrent failures share one attempt; lock-deadline readers use only safe published last-good evidence")

for defect in ["json", "mode", "symlink", "directory-mode"]:
    c = Case()
    c.expect(True, "source=live")
    path, = c.cache.glob("*.json")
    if defect == "json":
        path.write_text("broken")
    elif defect == "mode":
        path.chmod(0o644)
    elif defect == "symlink":
        target = c.base / "displaced"
        path.rename(target)
        path.symlink_to(target)
    else:
        c.cache.chmod(0o755)
    c.expect(False, "cache-unreadable")
    assert c.count() == 1
print("PASS: corrupt, public, and symlinked cache records fail closed without a live read")

c = Case()
(c.config / "claude-seat-extra-usage").write_text("allow 10\n")
paid = quota(0)
paid["providers"][0]["windows"].append({"id": "extra_usage", "kind": "credits", "spentUsd": 9, "limitUsd": 100})
c.set(paid)
c.expect(True, "under the $10 cap")
paid["providers"][0]["windows"][-1]["spentUsd"] = 10
c.set(paid)
c.expect(False, "at or over the $10 cap")
assert c.count() == 2
c.set(quota())
c.expect(True, "source=live")
c.age(200, lambda r: r["windows"].append({"id": "extra_usage", "kind": "credits", "spentUsd": 10, "limitUsd": 100}))
c.set(failure())
c.expect(False, "fallback=unsafe-or-missing")
# Environment-token evidence never pollutes or borrows stored-profile evidence.
c = Case()
c.expect(True, "source=live")
c.set(failure())
c.expect(False, "fallback=unsafe-or-missing", CLAUDE_CODE_OAUTH_TOKEN="fixture-only-noncredential")
assert all("fixture-only" not in p.name for p in c.cache.iterdir())
c.expect(True, "source=fresh-cache")
print("PASS: paid cap requires live spend; environment bearer overrides cannot share profile quota")

# The real managed pipeline launcher shares dispatch cache state and makes the
# provenance visible on stderr, while independent seat guards still run first.
c = Case()
(c.config / "claude-seats-root").write_text(str(c.base) + "\n")
(c.config / "claude-seat").write_text("profile\n")
native = c.base / "native"
native.write_text("#!/usr/bin/env bash\nprintf 'native-started\\n'\n")
native.chmod(0o700)
def launch():
    return subprocess.run(["bash", str(ROOT / "bin/fm-seat-pipeline.sh"), "launch",
                           "--default-profile", "", str(c.base), str(native)],
                          env=c.env, capture_output=True, text=True)
assert launch().returncode == 0
result = launch()
assert result.returncode == 0 and "source=fresh-cache" in result.stderr, result
assert c.count() == 1
c.age(200)
c.set(failure(retryAfter=iso(-300)))
result = launch()
assert result.returncode == 0 and "source=last-good-fallback" in result.stderr, result
assert "age=" in result.stderr and "backoff=" in result.stderr
(c.config / "claude-seat-auto-exclude").write_text("profile\n")
result = launch()
assert result.returncode == 75 and "manually excluded" in result.stderr, result
assert "native-started" not in result.stdout and c.count() == 2
# Raw quota consumers honor the same backoff and retain the public producer JSON.
raw_script = '. "$1/bin/fm-timeout-lib.sh"; . "$1/bin/fm-seat-lib.sh"; fm_seat_quota_json "$2"'
result = subprocess.run(["bash", "-c", raw_script, "raw", str(ROOT), str(c.profile)],
                        env=c.env, capture_output=True, text=True)
assert result.returncode == 0 and json.loads(result.stdout) == json.loads(c.response.read_text()), result
assert c.count() == 2
print("PASS: managed pipeline launches and raw readers share cache/backoff, preserve JSON, and retain exclusions")

# A launcher whose own PATH has no quota-axi reads quota through the home's
# recorded quota tool path, and names the missing record when none holds one.
# The record is deliberately not bound to the session lock: no case here writes
# a lock at all, because a home upgraded mid-session must not have to wait for
# its lead to restart before its launches can read quota again.
def launch_case():
    case = Case()
    (case.config / "claude-seats-root").write_text(str(case.base) + "\n")
    (case.config / "claude-seat").write_text("profile\n")
    (case.base / "state").mkdir()
    return case


# Every directory that can serve quota-axi leaves this PATH, so the launcher
# is as blind to the tool as a daemon started outside a login shell.
def blind_path(case):
    return ":".join(entry for entry in case.env["PATH"].split(":")
                    if entry and not os.access(os.path.join(entry, "quota-axi"), os.X_OK))


def launch(case, env=None):
    return subprocess.run(["bash", str(ROOT / "bin/fm-seat-pipeline.sh"), "launch",
                           "--default-profile", "", str(case.base), str(native)],
                          env=env or dict(case.env, PATH=blind_path(case)),
                          capture_output=True, text=True)


# No record at all: the hold must name the missing record, because this launch
# read no quota rather than reading quota and finding it wanting.
c = launch_case()
result = launch(c)
assert result.returncode == 75 and "no recorded quota tool path" in result.stderr, result
assert "quota could not be read" not in result.stderr, result
assert c.count() == 0, c.calls.read_text()

# A record naming the directory the tool is in carries the launch.
c = launch_case()
(c.base / "state" / ".quota-tool-dir").write_text(str(c.base) + "\n")
result = launch(c)
assert result.returncode == 0 and "native-started" in result.stdout, result
assert c.count() == 1, c.calls.read_text()

# A record naming a directory without the tool names no tool at all, so the
# hold is the missing record again rather than a seat's unreadable quota.
c = launch_case()
(c.base / "state" / ".quota-tool-dir").write_text(str(c.base / "profile") + "\n")
result = launch(c)
assert result.returncode == 75 and "no recorded quota tool path" in result.stderr, result
assert c.count() == 0, c.calls.read_text()

# A home that restarted before this change carries only the old lock-bound
# field. The upgrade itself must not hold its launches, so that field still
# carries one while it exists - and a lock-bound record whose pid does not
# match the lock names nothing, exactly as it always did.
c = launch_case()
(c.base / "state" / ".lock-runtime").write_text("pid=4242424\nquotabin=%s\n" % c.base)
result = launch(c)
assert result.returncode == 75 and "no recorded quota tool path" in result.stderr, result
(c.base / "state" / ".lock").write_text("4242424\n")
result = launch(c)
assert result.returncode == 0 and "native-started" in result.stdout, result
assert c.count() == 1, c.calls.read_text()

# The durable record wins over the old field when both are present.
c = launch_case()
(c.base / "state" / ".lock").write_text("4242424\n")
(c.base / "state" / ".lock-runtime").write_text(
    "pid=4242424\nquotabin=%s\n" % (c.base / "profile"))
(c.base / "state" / ".quota-tool-dir").write_text(str(c.base) + "\n")
result = launch(c)
assert result.returncode == 0 and "native-started" in result.stdout, result
assert c.count() == 1, c.calls.read_text()

# A launch that CAN read quota and is held on the seat's own quota keeps the
# gate's wording: the record is not the cause and must not be blamed.
c = launch_case()
c.set(failure())
result = launch(c, env=c.env)
assert result.returncode == 75 and "quota could not be read" in result.stderr, result
assert "no recorded quota tool path" not in result.stderr, result

# A record that does hold the tool, with quota still unreadable, keeps the
# gate's wording too: the record did its job and is not the cause.
c = launch_case()
c.set(failure())
(c.base / "state" / ".quota-tool-dir").write_text(str(c.base) + "\n")
result = launch(c)
assert result.returncode == 75 and "quota could not be read" in result.stderr, result
assert "no recorded quota tool path" not in result.stderr, result
assert c.count() == 1, c.calls.read_text()

# Reading through the record never rewrites it: the launching daemon is a pure
# reader of a path firstmate owns.
c = launch_case()
record = c.base / "state" / ".quota-tool-dir"
record.write_text(str(c.base) + "\n")
assert launch(c).returncode == 0
assert record.read_text() == str(c.base) + "\n", record.read_text()
print("PASS: a blind launcher reads quota through the recorded quota tool path, names the record when none holds the tool, and never rewrites it")
