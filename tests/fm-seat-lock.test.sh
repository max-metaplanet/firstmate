#!/usr/bin/env bash
# Real-process lock lifetime, private renewal state, and independent owner signals.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-seat-lock.XXXXXX")
export FM_SEAT_LOCK_ROOT="$TMP_ROOT/locks"
export PYTHONDONTWRITEBYTECODE=1
python3 - "$ROOT/bin/fm-seat-lock.py" "$TMP_ROOT" <<'PY'
import importlib.util
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import time

source, scratch = sys.argv[1], Path(sys.argv[2])
spec = importlib.util.spec_from_file_location("seat_lock", source)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
profile = scratch / "profile"
profile.mkdir()
(profile / "auth.json").write_text("{}\n")
alias = scratch / "alias"
alias.mkdir()
(alias / "auth.json").symlink_to(profile / "auth.json")
home = scratch / "home"
(home / "state").mkdir(parents=True)
children = []


def cli(operation, selected=profile, **kw):
    return subprocess.run([sys.executable, source, operation, "--provider", "codex", "--profile", str(selected)],
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=5, **kw)


def ready(path):
    end = time.monotonic() + 6
    while time.monotonic() < end:
        if path.exists():
            return
        time.sleep(.03)
    raise AssertionError("test child did not become ready")


def released():
    end = time.monotonic() + 6
    while time.monotonic() < end:
        try:
            with module.seat_lock("codex", profile, exclusive=True, blocking=False):
                return
        except BlockingIOError:
            time.sleep(.03)
    raise AssertionError("seat lease remained after child exit")


try:
    assert cli("identity").stdout == cli("identity", alias).stdout
    assert not (scratch / "locks").exists(), "reading identity must not create the root"
    assert cli("state").stdout == b"{}\n"
    assert not (scratch / "locks").exists(), "reading missing state must not create the root"
    with module.seat_lock("codex", profile, exclusive=True, blocking=False) as lease:
        lease.write_state({"state": "renewing", "lastRenewal": 123})
        assert cli("available", alias).returncode == 75, "credential aliases must share exclusive contention"
        before = time.monotonic()
        state = cli("state", alias)
        assert json.loads(state.stdout)["state"] == "renewing"
        assert time.monotonic() - before < 3, "panel state must not wait for renewal"
    with module.seat_lock("codex", profile, exclusive=False, blocking=False):
        assert cli("available", alias).returncode == 0, "managed sessions may share a seat"
        try:
            with module.seat_lock("codex", alias, exclusive=True, blocking=False):
                raise AssertionError("renewal overlapped a live managed session")
        except BlockingIOError:
            pass
    with module.seat_lock("claude", profile, exclusive=True, blocking=False):
        assert cli("available").returncode == 0, "providers have independent identities"
    print("ok - private global leases bind credential aliases and state stays readable during renewal", flush=True)

    child_script = scratch / "child.py"
    child_script.write_text('''import os, pathlib, signal, sys, time
signal.signal(signal.SIGTERM, signal.SIG_IGN)
pathlib.Path(sys.argv[1]).write_text(str(os.getpid()))
while not pathlib.Path(sys.argv[2]).exists(): time.sleep(.03)
''')
    for mode in ("term", "kill"):
        marker, finish = scratch / (mode + ".ready"), scratch / (mode + ".finish")
        guard = subprocess.Popen([sys.executable, source, "guard", "--provider", "codex", "--profile", str(profile),
                                  "--", sys.executable, str(child_script), str(marker), str(finish)],
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        children.append(guard)
        ready(marker)
        pid = int(marker.read_text())
        assert cli("available").returncode == 0, "guard holds a shared, not exclusive lease"
        try:
            with module.seat_lock("codex", profile, exclusive=True, blocking=False):
                raise AssertionError("guard did not hold its lease")
        except BlockingIOError:
            pass
        guard.send_signal(signal.SIGTERM if mode == "term" else signal.SIGKILL)
        time.sleep(.12)
        if mode == "term":
            assert guard.poll() is None, "TERM cannot release a live child that ignored it"
        else:
            assert guard.wait(timeout=5) == -signal.SIGKILL
        os.kill(pid, 0)
        try:
            with module.seat_lock("codex", profile, exclusive=True, blocking=False):
                raise AssertionError("wrapper termination dropped the surviving child's lease")
        except BlockingIOError:
            pass
        finish.touch()
        if mode == "term":
            assert guard.wait(timeout=5) == 0
        released()
    print("ok - managed child retains its lease through wrapper TERM and unexpected wrapper death", flush=True)

    with module.seat_lock("codex", profile, exclusive=True, blocking=False) as lease:
        child = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(.5)"], pass_fds=(lease.fd,))
        children.append(child)
    assert cli("available").returncode == 75, "closing the parent's lease must preserve an inherited renewal lease"
    child.wait(timeout=5)
    released()
    print("ok - renewal subprocess fd inheritance retains exclusion until its owner exits", flush=True)

    # The installed interpreter is a real process with independent environment
    # and descriptors. macOS hides platform /bin/sleep's environment, so use
    # Python without copying or re-signing any installed executable.
    native = scratch / "bin" / "codex"
    native.parent.mkdir()
    executable = sys.executable
    if sys.platform == "darwin":
        # Homebrew's framework launcher execs Python.app; bind to that actual
        # image, which is the structural executable identity ps reports.
        executable = subprocess.check_output(["ps", "-p", str(os.getpid()), "-o", "comm="], text=True).strip()
    native.symlink_to(executable)
    original_path = os.environ["PATH"]
    os.environ["PATH"] = str(native.parent) + os.pathsep + original_path
    other = scratch / "other"
    other.mkdir()
    canary = "NEVER_PRINT_RAW_ENV_649278"
    env = dict(os.environ, CODEX_HOME=str(profile), PRIVATE_TEST_CANARY=canary)
    sleeper = "import time; time.sleep(300)"
    environment_only = subprocess.Popen([str(native), "-c", sleeper], env=env)
    children.append(environment_only)
    target_file = profile / "config.toml"
    target_file.write_text("# synthetic configuration\n")
    file_only = subprocess.Popen(["bash", "-c", 'exec 3<"$2"; exec "$1" -c "$3"', "_",
                                  str(native), str(target_file), sleeper], env=dict(env, CODEX_HOME=str(other)))
    children.append(file_only)
    seen = module.owners("codex", alias, home)
    assert {"pid": environment_only.pid, "reason": "environment-owner"} in seen, seen
    assert {"pid": file_only.pid, "reason": "open-file-owner"} in seen, seen
    assert all(set(row) == {"pid", "reason"} for row in seen)
    assert canary not in json.dumps(seen), "owner reports cannot contain raw environment"
    actual_files = subprocess.run(["lsof", "-nP", "-a", "-p", str(environment_only.pid), "-F0n"],
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=5)
    assert str(profile).encode() not in actual_files.stdout, "environment-only fixture accidentally opened the seat"
    print("ok - independent real environment and open-file bindings each prove ownership without leaking environment", flush=True)

    # A real process with a different environment and no matching open file is
    # not an owner; making its file table unreadable changes that to a hold.
    stranger = subprocess.Popen([str(native), "-c", sleeper], env=dict(env, CODEX_HOME=str(other)))
    children.append(stranger)
    assert not any(row["pid"] == stranger.pid for row in module.owners("codex", profile, home))
    fakebin = scratch / "unreadable-bin"
    fakebin.mkdir()
    lsof = fakebin / "lsof"
    lsof.write_text("#!/bin/sh\nexit 2\n")
    lsof.chmod(0o700)
    saved_path = os.environ["PATH"]
    os.environ["PATH"] = str(fakebin) + os.pathsep + saved_path
    try:
        seen = module.owners("codex", profile, home)
        assert {"pid": stranger.pid, "reason": "owner-files-unreadable"} in seen, seen
    finally:
        os.environ["PATH"] = saved_path
    print("ok - nonmatching live vendors are excluded, while an unreadable plausible owner fails closed", flush=True)

    # A running old native version remains an owner after the installed command
    # changes. Neither its basename nor executable matches the current install.
    versioned = scratch / "claude" / "versions" / "1.0.123"
    versioned.parent.mkdir(parents=True)
    versioned.symlink_to(executable)
    current = native.parent / "claude"
    current.symlink_to(shutil.which("sleep"))
    assert os.path.realpath(versioned) != os.path.realpath(current)
    version_env = dict(os.environ, CLAUDE_CONFIG_DIR=str(profile))
    version_env.pop("CLAUDE_SECURESTORAGE_CONFIG_DIR", None)
    old_env = subprocess.Popen([str(versioned), "-c", sleeper], env=version_env)
    children.append(old_env)
    old_file = subprocess.Popen(["bash", "-c", 'exec 3<"$2"; exec "$1" -c "$3"', "_",
                                 str(versioned), str(target_file), sleeper],
                                env=dict(version_env, CLAUDE_CONFIG_DIR=str(other)))
    children.append(old_file)
    helper = scratch / "fm-claude-helper"
    helper.symlink_to(executable)
    helper_process = subprocess.Popen([str(helper), "-c", sleeper], env=version_env)
    children.append(helper_process)
    seen = module.owners("claude", profile, home)
    assert {"pid": old_env.pid, "reason": "environment-owner"} in seen, seen
    assert {"pid": old_file.pid, "reason": "open-file-owner"} in seen, seen
    assert not any(row["pid"] == helper_process.pid for row in seen), seen
    actual_files = subprocess.run(["lsof", "-nP", "-a", "-p", str(old_env.pid), "-F0n"],
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=5)
    assert str(profile).encode() not in actual_files.stdout, "old-version environment fixture opened the seat"
    os.environ["PATH"] = original_path
    print("ok - older native versions retain independent owner signals without matching helper substrings", flush=True)

    plain = subprocess.Popen([shutil.which("sleep"), "300"])
    children.append(plain)
    (home / "state" / "worker.meta").write_text("harness=codex\ncodex_seat={}\npid={}\n".format(profile, plain.pid))
    assert {"pid": plain.pid, "reason": "recorded-owner"} in module.owners("codex", profile, home)
    foreign = scratch / "foreign" / "state"
    foreign.mkdir(parents=True)
    (foreign / "foreign.meta").write_text("harness=claude\nclaude_seat={}\npid={}\n".format(profile, plain.pid))
    assert not any(row["pid"] == plain.pid for row in module.owners("claude", profile, home)), "other homes' records must not be scanned"
    (home / "state" / ".lock").write_text(str(plain.pid) + "\n")
    (home / "state" / ".lock-runtime").write_text("pid={}\nprofile={}\n".format(plain.pid, profile))
    assert {"pid": plain.pid, "reason": "recorded-owner"} in module.owners("claude", profile, home)
    (home / "state" / ".lock").write_text("999999999\n")
    assert not any(row["pid"] == plain.pid for row in module.owners("claude", profile, home)), "stale lead records are not ownership"
    print("ok - recorded workers and a bound live lead hold renewal without scanning another home", flush=True)

    original_home = os.environ.get("HOME")
    user_home = scratch / "ordinary-user"
    explicit_default = user_home / ".claude"
    explicit_default.mkdir(parents=True)
    (explicit_default / ".credentials.json").write_text("{}\n")
    claude_alias = scratch / "claude-alias"
    claude_alias.mkdir()
    (claude_alias / ".credentials.json").symlink_to(explicit_default / ".credentials.json")
    ambient_home = scratch / "ambient-records"
    (ambient_home / "state").mkdir(parents=True)
    os.environ["HOME"] = str(user_home)
    try:
        ordinary_identity = subprocess.check_output([sys.executable, source, "identity", "--provider", "claude", "--profile", ""])
        with module.seat_lock("claude", "", exclusive=True, blocking=False) as lease:
            lease.write_state({"state": "ordinary"})
            for selected in ("", str(explicit_default), str(claude_alias)):
                checked = subprocess.run([sys.executable, source, "available", "--provider", "claude",
                                          "--profile", selected], stdout=subprocess.PIPE,
                                         stderr=subprocess.PIPE, timeout=5)
                same_identity = not selected or sys.platform != "darwin"
                selected_identity = subprocess.check_output([sys.executable, source, "identity", "--provider", "claude", "--profile", selected])
                assert (selected_identity == ordinary_identity) == same_identity
                assert checked.returncode == (75 if same_identity else 0), (selected, checked.returncode)
                stored = module.read_state("claude", selected)
                assert stored == ({"state": "ordinary"} if same_identity else {}), stored

        ordinary_env = dict(os.environ)
        ordinary_env.pop("CLAUDE_CONFIG_DIR", None)
        ordinary_env.pop("CLAUDE_SECURESTORAGE_CONFIG_DIR", None)
        ordinary_process = subprocess.Popen([str(versioned), "-c", sleeper], env=ordinary_env)
        children.append(ordinary_process)
        empty_process = subprocess.Popen([str(versioned), "-c", sleeper],
                                         env=dict(ordinary_env, CLAUDE_CONFIG_DIR=""))
        children.append(empty_process)
        explicit_process = subprocess.Popen([str(versioned), "-c", sleeper],
                                            env=dict(ordinary_env, CLAUDE_CONFIG_DIR=str(explicit_default)))
        children.append(explicit_process)
        ordinary_seen = module.owners("claude", "", ambient_home)
        explicit_seen = module.owners("claude", explicit_default, ambient_home)
        for child in (ordinary_process, empty_process):
            assert {"pid": child.pid, "reason": "environment-owner"} in ordinary_seen, ordinary_seen
            assert any(row["pid"] == child.pid for row in explicit_seen) == (sys.platform != "darwin"), explicit_seen
        assert {"pid": explicit_process.pid, "reason": "environment-owner"} in explicit_seen, explicit_seen
        assert any(row["pid"] == explicit_process.pid for row in ordinary_seen) == (sys.platform != "darwin"), ordinary_seen

        default_file = explicit_default / "config.json"
        default_file.write_text("{}\n")
        shared_files = subprocess.Popen(["bash", "-c", 'exec 3<"$2"; exec "$1" -c "$3"', "_",
                                        str(versioned), str(default_file), sleeper],
                                       env=dict(ordinary_env, CLAUDE_CONFIG_DIR=str(other)))
        children.append(shared_files)
        for selected in ("", explicit_default):
            assert {"pid": shared_files.pid, "reason": "open-file-owner"} in module.owners("claude", selected, ambient_home)

        # Metadata absence and a bound lead's empty selector mean ordinary.
        (ambient_home / "state" / "worker.meta").write_text("harness=claude\npid={}\n".format(plain.pid))
        (ambient_home / "state" / ".lock").write_text(str(plain.pid) + "\n")
        (ambient_home / "state" / ".lock-runtime").write_text("pid={}\nprofile=\n".format(plain.pid))
        assert {"pid": plain.pid, "reason": "recorded-owner"} in module.owners("claude", "", ambient_home)
        explicit_seen = module.owners("claude", explicit_default, ambient_home)
        assert any(row["pid"] == plain.pid for row in explicit_seen) == (sys.platform != "darwin"), explicit_seen
    finally:
        if original_home is None:
            os.environ.pop("HOME", None)
        else:
            os.environ["HOME"] = original_home
    print("ok - ordinary Claude respects platform credential identity across locks, environments, files, and records", flush=True)

    unsafe = scratch / "unsafe"
    unsafe.mkdir(mode=0o755)
    prior_root = os.environ["FM_SEAT_LOCK_ROOT"]
    os.environ["FM_SEAT_LOCK_ROOT"] = str(unsafe)
    assert cli("available").returncode == 2, "shared coordination roots are unsafe"
    link = scratch / "root-link"
    link.symlink_to(prior_root, target_is_directory=True)
    os.environ["FM_SEAT_LOCK_ROOT"] = str(link)
    assert cli("available").returncode == 2, "symlink lock roots must be refused"
    os.environ["FM_SEAT_LOCK_ROOT"] = prior_root
    key = next((scratch / "locks").glob("*.json"))
    key.chmod(0o644)
    assert cli("state").returncode == 2, "unsafe published state must be refused"
    print("ok - unsafe lock roots and renewal state fail closed", flush=True)
finally:
    for child in children:
        if child.poll() is None:
            child.terminate()
            try:
                child.wait(timeout=3)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait(timeout=3)
PY
pass 'seat locks and owner scans passed real-process regression coverage'
