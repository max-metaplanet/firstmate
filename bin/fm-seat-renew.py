#!/usr/bin/env python3
"""Renewal coordinator, called by fm-seat-renew.sh.

The credential-store lock covers a fresh non-renewing probe, immediate owner
preflight, vendor CLI refresh, and fresh-state verification. Managed sessions
hold shared locks. Unmanaged sessions are checked immediately before refresh;
a new unmanaged launch after that snapshot remains the accepted residual race.
Only expired_refreshable enters a vendor. Invalid credentials latch renewal
until a later read proves healthy, and enqueue a durable check with login argv.

The registered check starts due one-shot jobs in separate sessions; it never
waits for or kills token rotation. A job defers signals while its vendor runs,
passes the lock descriptor through the adapter, and publishes atomic history.
No credential contents, vendor diagnostics, or process environments are logged.
"""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

BIN = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("seat_lock", BIN / "fm-seat-lock.py")
locks = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = locks
spec.loader.exec_module(locks)
INTERVAL = 900


def probe(provider, name, profile):
    result = subprocess.run(
        ["bash", str(BIN / "fm-seat-renew.sh"), "--provider", provider, "--probe", "--probe-profile", profile, name],
        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, check=False,
    )
    try:
        value = json.loads(result.stdout)
        return value if isinstance(value, dict) else {"state": "unknown"}
    except ValueError:
        return {"state": "unknown"}


def wake(provider, name, result):
    message = f"{provider}-seat: {name} credentials-invalid; renewal stopped; run: {result['loginCommand']}"
    # The existing wake owner handles durable delivery and watcher recovery.
    return subprocess.run(
        ["bash", "-c", '. "$1"; fm_wake_append check "$2" "$3"', "seat-renewal",
         str(BIN / "fm-wake-lib.sh"), f"seat-renewal:{provider}:{name}", message],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False,
    ).returncode == 0


def merged(result, state):
    return dict(result, **{key: state.get(key) for key in ("outcome", "lastAttempt", "lastRenewal")})


def renew(args):
    result = {"state": "unknown", "reason": "Renewal lock unavailable", "outcome": "busy"}
    try:
        with locks.seat_lock(args.provider, args.profile, exclusive=True, blocking=False) as lease:
            state = lease.read_state()
            now = int(time.time())
            if args.scheduled and now - state.get("lastChecked", 0) < INTERVAL:
                return 0
            state["lastChecked"] = now
            lease.write_state(state)
            result = probe(args.provider, args.name, args.profile)
            if result.get("state") == "invalid":
                state["outcome"] = "invalid"
                state["invalidLatched"] = True
                state["loginCommand"] = result.get("loginCommand")
                if not state.get("invalidNotified"):
                    state["invalidNotified"] = wake(args.provider, args.name, result)
            elif result.get("state") == "healthy":
                state.update(outcome="healthy", invalidLatched=False, invalidNotified=False)
            elif state.get("invalidLatched"):
                state["outcome"] = "invalid"
                result["reason"] = "Renewal stopped after invalid credentials; a healthy read after login clears the stop."
                result["loginCommand"] = state.get("loginCommand")
            elif result.get("state") != "expired_refreshable":
                state["outcome"] = "unknown"
            else:
                # No cached quota reads, no vendor between this scan and refresh.
                live = locks.owners(args.provider, args.profile, os.environ["FM_HOME"])
                if live:
                    state["outcome"] = "owned"
                    result["reason"] = "Live owner or uncertain ownership; retry on the next check."
                else:
                    state.update(outcome="renewing", lastAttempt=now)
                    lease.write_state(state)
                    # A timeout must never kill single-use token redemption.
                    for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
                        signal.signal(sig, signal.SIG_IGN)
                    env = os.environ.copy()
                    env["FM_SEAT_LOCK_FD"] = str(lease.fd)
                    completed = subprocess.run(
                        [sys.executable, str(BIN / "fm-seat-vendor-renew.py"),
                         "--provider", args.provider, "--profile", args.profile],
                        stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                        stderr=subprocess.DEVNULL, env=env, pass_fds=(lease.fd,), check=False,
                    )
                    result = probe(args.provider, args.name, args.profile)
                    if result.get("state") == "healthy":
                        state.update(outcome="renewed", lastRenewal=int(time.time()), invalidLatched=False,
                                     invalidNotified=False)
                    elif result.get("state") == "invalid":
                        state.update(outcome="invalid", invalidLatched=True, loginCommand=result.get("loginCommand"))
                        state["invalidNotified"] = wake(args.provider, args.name, result)
                    else:
                        state["outcome"] = "failed"
                        result["reason"] = "Vendor exited without a verified fresh credential; retry on the next check."
                    # Success requires a fresh read even when vendor exit was zero.
                    state["vendorExit"] = completed.returncode
            lease.write_state(state)
            result = merged(result, state)
    except BlockingIOError:
        result["reason"] = "A managed session or another renewal holds this seat; retry later."
    except (OSError, ValueError, RuntimeError, TypeError):
        result = {"state": "unknown", "outcome": "failed", "reason": "Renewal guard failed closed."}
    if not args.scheduled:
        print(json.dumps(result))
    return 0 if result.get("state") == "healthy" else 1


def auto():
    rows = subprocess.run(["bash", str(BIN / "fm-seat-renew.sh"), "--profiles"],
                          stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, check=False)
    if rows.returncode:
        print("seat-renewal: cannot enumerate registered profiles")
        return 1
    started = set()
    for row in rows.stdout.splitlines():
        try:
            item = json.loads(row)
            identity = (item["provider"], locks.identity(item["provider"], item["profile"]))
            if identity in started:
                continue
            started.add(identity)
            state = locks.read_state(item["provider"], item["profile"])
            if int(time.time()) - state.get("lastChecked", 0) < INTERVAL:
                continue
            subprocess.Popen(
                [sys.executable, str(Path(__file__).resolve()), "renew", "--scheduled",
                 "--provider", item["provider"], "--profile", item["profile"], "--name", item["name"]],
                start_new_session=True, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL, close_fds=True,
            )
        except (ValueError, KeyError, OSError, locks.SeatLockError):
            print("seat-renewal: a profile guard failed closed")
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("auto", "renew"))
    parser.add_argument("--provider", choices=("claude", "codex"))
    parser.add_argument("--profile")
    parser.add_argument("--name")
    parser.add_argument("--scheduled", action="store_true")
    args = parser.parse_args()
    if args.action == "auto":
        return auto()
    if not args.provider or args.profile is None or not args.name:
        parser.error("renew requires provider, profile and name")
    return renew(args)


if __name__ == "__main__":
    sys.exit(main())
