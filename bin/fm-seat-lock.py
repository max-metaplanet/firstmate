#!/usr/bin/env python3
"""Machine-local seat coordination for managed sessions and token renewal.

seat_lock(provider, profile, exclusive, blocking) yields a Lease with fd,
read_state() and exclusive-only write_state(dict). Close, never LOCK_UN, ends a
lease so descriptors inherited by a still-running child retain the lock; only
guard unlocks, after its child has exited.
read_state(provider, profile) reads the last atomically published state without
waiting for renewal. Missing state is {}. Unsafe files/roots fail closed.

The default root is ~/.local/state/firstmate-seat-locks, independent of FM_HOME.
FM_SEAT_LOCK_ROOT selects a private absolute root for an isolated deployment or
test; every cooperating process must use the same root. Root and files must be
owned by this UID, without group/other access, symlinks, or file hardlinks.
Codex identity follows auth.json aliases. Claude uses its exact selector on
macOS, where an empty selector is the distinct ordinary Keychain login, and
the canonical .credentials.json path elsewhere. No credential is opened.
The ordinary selector contract belongs to fm-worker-account-lib.sh.

owners(provider, profile, home) returns only {pid, reason} records. It inspects
own-UID vendor processes through kernel process identity, environment and open
files; either binding suffices, and an unreadable plausible owner blocks renewal.
Only home/state/*.meta and its own lead record are read, never another home's
registry or an unrecorded endpoint namespace. Recorded endpoints use the existing
recovery-grade backend reader; unverified endpoints block. Remote records do not
claim local credentials. This is a snapshot, not a lease over unmanaged CLIs.

CLI: guard [--nonblocking] --provider P --profile PATH -- COMMAND [ARGS...]
holds a shared lease through child exit and passes its descriptor to that child.
TERM/INT/HUP are forwarded, but the wrapper waits rather than releasing a live
child's lease. Once the child exits the wrapper unlocks that open file, so a
daemon or tool process the session left behind cannot keep holding the seat. available takes a nonblocking shared lease (exit 75 when busy).
state is a nonblocking, read-only JSON snapshot. owners prints the safe scan.
identity prints the credential identity without reading or creating lock state.
"""

import argparse
from contextlib import contextmanager
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import signal
import stat
import subprocess
import sys
import time


class SeatLockError(RuntimeError):
    """A fail-closed structural or storage error with no sensitive payload."""


def identity(provider, profile):
    if provider not in ("claude", "codex"):
        raise SeatLockError("unsupported seat provider")
    if provider == "claude" and not profile and sys.platform == "darwin":
        return "ordinary-keychain"
    profile = os.fspath(profile or (Path.home() / ("." + provider)))
    if not os.path.isabs(profile):
        raise SeatLockError("seat profile must be absolute")
    if provider == "codex":
        auth = os.path.realpath(os.path.join(profile, "auth.json"))
        if os.path.basename(auth) != "auth.json":
            raise SeatLockError("Codex alias does not name an auth.json owner")
        if os.path.islink(os.path.join(profile, "auth.json")) and not os.path.isfile(auth):
            raise SeatLockError("Codex authentication alias is unresolved")
        return auth
    if sys.platform == "darwin":
        return profile
    return os.path.realpath(os.path.join(profile, ".credentials.json"))


def _key(provider, profile):
    return hashlib.sha256((provider + "\0" + identity(provider, profile)).encode()).hexdigest()


def _private(info, directory=False):
    kind = stat.S_ISDIR if directory else stat.S_ISREG
    return (kind(info.st_mode) and info.st_uid == os.getuid()
            and not info.st_mode & 0o077 and (directory or info.st_nlink == 1))


def _root(create):
    path = os.environ.get("FM_SEAT_LOCK_ROOT", str(Path.home() / ".local/state/firstmate-seat-locks"))
    if not os.path.isabs(path):
        raise SeatLockError("seat lock root must be absolute")
    if create:
        try:
            os.makedirs(path, mode=0o700, exist_ok=True)
        except OSError as error:
            raise SeatLockError("cannot create private seat lock root") from error
    try:
        info = os.lstat(path)
    except FileNotFoundError:
        return None
    if not _private(info, directory=True):
        raise SeatLockError("unsafe seat lock root")
    try:
        fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    except OSError as error:
        raise SeatLockError("cannot open private seat lock root") from error
    actual = os.fstat(fd)
    if not _private(actual, directory=True) or (info.st_dev, info.st_ino) != (actual.st_dev, actual.st_ino):
        os.close(fd)
        raise SeatLockError("seat lock root changed")
    return fd


def _open_private(root_fd, name, flags, missing=False):
    try:
        fd = os.open(name, flags | os.O_NOFOLLOW, 0o600, dir_fd=root_fd)
    except FileNotFoundError:
        if missing:
            return None
        raise SeatLockError("seat coordination file is missing") from None
    except OSError as error:
        raise SeatLockError("cannot safely open seat coordination file") from error
    if not _private(os.fstat(fd)):
        os.close(fd)
        raise SeatLockError("unsafe seat coordination file")
    return fd


def _read_state(root_fd, key):
    fd = _open_private(root_fd, key + ".json", os.O_RDONLY, missing=True)
    if fd is None:
        return {}
    with os.fdopen(fd, "r", encoding="utf-8") as stream:
        try:
            text = stream.read(65537)
            if len(text) > 65536:
                raise ValueError("oversized")
            result = json.loads(text)
            if not isinstance(result, dict):
                raise ValueError("not object")
            return result
        except (ValueError, UnicodeError) as error:
            raise SeatLockError("unreadable renewal state") from error


def read_state(provider, profile):
    key = _key(provider, profile)
    fd = _root(False)
    if fd is None:
        return {}
    try:
        return _read_state(fd, key)
    finally:
        os.close(fd)


class Lease:
    def __init__(self, fd, root_fd, key, exclusive):
        self.fd, self.root_fd, self.key, self.exclusive = fd, root_fd, key, exclusive

    def read_state(self):
        return _read_state(self.root_fd, self.key)

    def write_state(self, record):
        if not self.exclusive:
            raise SeatLockError("renewal state requires an exclusive lease")
        if not isinstance(record, dict):
            raise SeatLockError("renewal state must be an object")
        content = (json.dumps(record, separators=(",", ":")) + "\n").encode()
        if len(content) > 65536:
            raise SeatLockError("renewal state is too large")
        existing = _open_private(self.root_fd, self.key + ".json", os.O_RDONLY, missing=True)
        if existing is not None:
            os.close(existing)
        temporary = self.key + "." + secrets.token_hex(12) + ".tmp"
        fd = _open_private(self.root_fd, temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL)
        try:
            with os.fdopen(fd, "wb") as stream:
                stream.write(content)
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(temporary, self.key + ".json", src_dir_fd=self.root_fd, dst_dir_fd=self.root_fd)
            os.fsync(self.root_fd)
        finally:
            try:
                os.unlink(temporary, dir_fd=self.root_fd)
            except FileNotFoundError:
                pass


@contextmanager
def seat_lock(provider, profile, exclusive=False, blocking=True):
    key = _key(provider, profile)
    root_fd = _root(True)
    if root_fd is None:
        raise SeatLockError("seat lock root disappeared")
    fd = None
    try:
        fd = _open_private(root_fd, key + ".lock", os.O_RDWR | os.O_CREAT)
        operation = fcntl.LOCK_EX if exclusive else fcntl.LOCK_SH
        if not blocking:
            operation |= fcntl.LOCK_NB
        fcntl.flock(fd, operation)
        yield Lease(fd, root_fd, key, exclusive)
    finally:
        # An inherited descriptor is still a lease. LOCK_UN here would release
        # the child's lock too, unlike closing this process's own descriptor.
        if fd is not None:
            os.close(fd)
        os.close(root_fd)


def _run(arguments, timeout=4):
    try:
        return subprocess.run(arguments, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                              timeout=timeout, check=False)
    except (OSError, subprocess.TimeoutExpired):
        return None


def _current(pid):
    result = _run(["ps", "-p", str(pid), "-o", "uid=", "-o", "lstart="])
    if result is None:
        raise SeatLockError("process identity unreadable")
    if result.returncode == 1 and not result.stdout.strip() and not result.stderr.strip():
        return None
    if result.returncode or result.stderr.strip():
        raise SeatLockError("process identity unreadable")
    parts = result.stdout.decode(errors="replace").strip().split(None, 1)
    if len(parts) != 2 or not parts[0].isdigit():
        raise SeatLockError("process identity unreadable")
    if parts[0] != str(os.getuid()):
        return None
    return parts[1]


def _inventory():
    result = _run(["ps", "-U", str(os.getuid()), "-o", "uid=", "-o", "pid=", "-o", "comm="])
    if result is None or result.returncode:
        raise SeatLockError("process inventory unavailable")
    rows = {}
    for line in result.stdout.decode(errors="replace").splitlines():
        parts = line.strip().split(None, 2)
        if len(parts) == 3 and parts[0] == str(os.getuid()) and parts[1].isdigit():
            rows[int(parts[1])] = parts[2]
    if os.getpid() not in rows:
        raise SeatLockError("process inventory incomplete")
    return rows


def _native_vendors(processes):
    # The session owner defines exact harness path components, including
    # version-named native installs. Batch it rather than duplicating its table.
    evidence = []
    for pid, command in processes.items():
        paths = [command]
        if sys.platform.startswith("linux"):
            try:
                paths.append(os.readlink("/proc/{}/exe".format(pid)))
                argv0 = Path("/proc/{}/cmdline".format(pid)).read_bytes().split(b"\0", 1)[0]
                paths.append(argv0.decode(errors="replace"))
            except OSError:
                pass
        for path in paths:
            evidence.extend((str(pid), path))
    script = '''. "$1/fm-session-lock-lib.sh"
while IFS= read -r -d '' pid && IFS= read -r -d '' path; do
  if name=$(fm_harness_path_name "$path"); then
    printf '%s\\t%s\\n' "$pid" "$name"
  fi
done
'''
    try:
        result = subprocess.run(["bash", "-c", script, "_", str(Path(__file__).resolve().parent)],
                                input=("\0".join(evidence) + "\0").encode(),
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=4, check=False)
    except (OSError, subprocess.TimeoutExpired) as error:
        raise SeatLockError("vendor path classification unavailable") from error
    if result.returncode or result.stderr.strip():
        raise SeatLockError("vendor path classification unavailable")
    identified = {}
    for line in result.stdout.decode(errors="replace").splitlines():
        parts = line.split("\t")
        if len(parts) != 2 or not parts[0].isdigit():
            raise SeatLockError("vendor path classification unreadable")
        identified.setdefault(int(parts[0]), set()).add(parts[1])
    return identified


def _vendor(pid, command, provider, installed, native):
    name = os.path.basename(command).lower()
    if provider in native.get(pid, ()) or name == provider or (installed and os.path.realpath(command) == installed):
        return True
    # Interpreter-based distribution: bind its first script argument to the
    # installed entry point or the vendor package, not an arbitrary mention.
    if name not in ("node", "bun", "nodejs"):
        return False
    try:
        args = Path("/proc/{}/cmdline".format(pid)).read_bytes().decode(errors="replace").split("\0")
    except OSError:
        result = _run(["ps", "ww", "-p", str(pid), "-o", "command="])
        if result is None or result.returncode:
            return None
        args = result.stdout.decode(errors="replace").strip().split()
    script = next((item for item in args[1:] if item and not item.startswith("-")), "")
    package = "/@openai/codex/" if provider == "codex" else "/@anthropic-ai/claude-code/"
    return bool(script and ((installed and os.path.realpath(script) == installed) or package in script))


def _environment(pid):
    if sys.platform.startswith("linux"):
        try:
            content = Path("/proc/{}/environ".format(pid)).read_bytes()
            values = dict(item.split(b"=", 1) for item in content.split(b"\0") if b"=" in item)
            return {key.decode(): values[key].decode(errors="replace") for key in
                    (b"HOME", b"CODEX_HOME", b"CLAUDE_CONFIG_DIR", b"CLAUDE_SECURESTORAGE_CONFIG_DIR") if key in values}
        except (OSError, ValueError):
            return None
    result = _run(["ps", "eww", "-p", str(pid), "-o", "command="])
    if result is None or result.returncode:
        return None
    text = result.stdout.decode(errors="replace").strip()
    values = {}
    for key in ("HOME", "CODEX_HOME", "CLAUDE_CONFIG_DIR", "CLAUDE_SECURESTORAGE_CONFIG_DIR"):
        matches = re.findall(r"(?:^|\s)" + key + r"=(.*?)(?=\s[A-Za-z_][A-Za-z0-9_]*=|$)", text)
        if len(matches) > 1:
            return None
        if matches:
            values[key] = matches[0]
    return values if values else None


def _environment_identity(provider, values):
    if values is None:
        return None
    if provider == "claude":
        profile = values.get("CLAUDE_SECURESTORAGE_CONFIG_DIR") or values.get("CLAUDE_CONFIG_DIR")
        if not profile and sys.platform == "darwin":
            return identity(provider, "")
    else:
        profile = values.get("CODEX_HOME")
    if not profile:
        if not values.get("HOME"):
            return None
        profile = os.path.join(values["HOME"], "." + provider)
    try:
        return identity(provider, profile)
    except (SeatLockError, OSError):
        return None


def _open_files(pid):
    result = _run(["lsof", "-nP", "-a", "-p", str(pid), "-F0pn"])
    if result is None or result.returncode not in (0, 1) or result.stderr.strip():
        return None
    paths = []
    for token in result.stdout.split(b"\0"):
        token = token.lstrip(b"\n")
        if token.startswith(b"n/"):
            paths.append(token[1:].decode(errors="replace"))
    return paths


def _file_binding(paths, provider, profile, wanted):
    directories = [] if provider == "codex" else [os.path.realpath(profile or (Path.home() / ".claude"))]
    if provider == "codex" or sys.platform != "darwin":
        directories.append(os.path.dirname(wanted))
    for path in paths or ():
        path = path.removesuffix(" (deleted)") if hasattr(path, "removesuffix") else re.sub(r" \(deleted\)$", "", path)
        actual = os.path.realpath(path)
        if any(actual == directory or actual.startswith(directory.rstrip("/") + "/")
               for directory in directories):
            return True
    return False


def _record_profile(record, provider, home):
    keys = (("codex_seat", "codex_home", "CODEX_HOME", "codex-home") if provider == "codex" else
            ("claude_seat", "claude_config_dir", "CLAUDE_CONFIG_DIR", "claude-config-dir"))
    value = next((record[key] for key in keys if key in record), None)
    if value is None and record.get("harness") == provider:
        value = record.get("seat") or record.get("profile")
    if not value:
        return "" if record.get("harness") == provider else None
    if value in ("default", "ordinary"):
        return ""
    if os.path.isabs(value):
        return value
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", value) or ".." in value:
        return None
    root = Path.home() / ("." + provider + "-seats")
    try:
        configured = (Path(home) / "config" / (provider + "-seats-root")).read_text().splitlines()[0]
        if os.path.isabs(configured):
            root = Path(configured)
    except (OSError, IndexError):
        pass
    return str(root / value)


def _records(provider, profile, home, process_ids, deadline):
    result = []
    state = Path(home) / "state"
    if not state.exists():
        return result
    if state.is_symlink() or not state.is_dir():
        return [{"pid": 0, "reason": "recorded-state-unreadable"}]
    try:
        paths = list(state.glob("*.meta"))
        if (state / ".lock-runtime").exists():
            paths.append(state / ".lock-runtime")
    except OSError:
        return [{"pid": 0, "reason": "recorded-state-unreadable"}]
    for path in paths:
        if time.monotonic() > deadline:
            result.append({"pid": 0, "reason": "owner-scan-deadline"})
            break
        try:
            if path.is_symlink() or path.stat().st_size > 1048576:
                raise OSError("unsafe record")
            record = dict(line.split("=", 1) for line in path.read_text().splitlines() if "=" in line)
        except (OSError, UnicodeError):
            result.append({"pid": 0, "reason": "recorded-state-unreadable"})
            continue
        if path.name == ".lock-runtime":
            if provider != "claude":
                continue
            try:
                lock = state / ".lock"
                if lock.is_symlink():
                    raise OSError("unsafe lock record")
                current_pid = lock.read_text().splitlines()[0]
            except (OSError, IndexError, UnicodeError):
                result.append({"pid": 0, "reason": "recorded-owner-unverified"})
                continue
            if record.get("pid") != current_pid:
                continue
            record["harness"] = "claude"
        if record.get("remote_host") or record.get("harness", provider) != provider:
            continue
        selected = _record_profile(record, provider, home)
        if selected is None:
            continue
        try:
            if identity(provider, selected) != identity(provider, profile):
                continue
        except (SeatLockError, OSError):
            result.append({"pid": 0, "reason": "recorded-seat-unreadable"})
            continue
        pid = next((int(record[key]) for key in ("pid", "worker_pid", "agent_pid", "session_pid")
                    if record.get(key, "").isdigit()), None)
        if pid is not None:
            if pid in process_ids:
                result.append({"pid": pid, "reason": "recorded-owner"})
            continue
        target = record.get("window")
        backend = record.get("backend", "tmux")
        if not target or backend not in ("tmux", "herdr", "orca", "cmux", "zellij"):
            result.append({"pid": 0, "reason": "recorded-owner-unverified"})
            continue
        environment = dict(os.environ, FM_HOME=str(home), FM_STATE_OVERRIDE=str(state))
        script = '. "$1/fm-backend.sh"; fm_backend_agent_state "$2" "$3"'
        try:
            check = subprocess.run(["bash", "-c", script, "_", str(Path(__file__).resolve().parent), backend, target],
                                   env=environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                   timeout=4, check=False)
            status = check.stdout.decode(errors="replace").strip()
        except (OSError, subprocess.TimeoutExpired):
            status = "unreadable"
        if status not in ("dead", "missing"):
            result.append({"pid": 0, "reason": "recorded-owner" if status == "alive" else "recorded-owner-unverified"})
    return result


def owners(provider, profile, home):
    wanted = identity(provider, profile)
    profile = os.fspath(profile) if profile else ""
    try:
        processes = _inventory()
        native = _native_vendors(processes)
    except SeatLockError:
        return [{"pid": 0, "reason": "process-inventory-unreadable"}]
    installed = shutil.which(provider)
    installed = os.path.realpath(installed) if installed else None
    deadline = time.monotonic() + 25
    found = _records(provider, profile, home, processes, deadline)
    for pid, command in processes.items():
        if pid == os.getpid():
            continue
        vendor = _vendor(pid, command, provider, installed, native)
        if vendor is False:
            continue
        if time.monotonic() > deadline:
            found.append({"pid": pid, "reason": "owner-scan-deadline"})
            break
        try:
            before = _current(pid)
        except SeatLockError:
            found.append({"pid": pid, "reason": "owner-process-unreadable"})
            continue
        if before is None:
            continue
        if vendor is None:
            found.append({"pid": pid, "reason": "vendor-identity-unreadable"})
            continue
        environment = _environment_identity(provider, _environment(pid))
        paths = _open_files(pid)
        try:
            after = _current(pid)
        except SeatLockError:
            found.append({"pid": pid, "reason": "owner-process-unreadable"})
            continue
        if after is None:
            continue
        if before != after:
            reason = "owner-process-changed"
        elif environment == wanted:
            reason = "environment-owner"
        elif _file_binding(paths, provider, profile, wanted):
            reason = "open-file-owner"
        elif environment is None:
            reason = "owner-environment-unreadable"
        elif paths is None:
            reason = "owner-files-unreadable"
        else:
            continue
        found.append({"pid": pid, "reason": reason})
    return list({(row["pid"], row["reason"]): row for row in found}.values())


def guard(provider, profile, command, blocking=True):
    if not command:
        raise SeatLockError("guard requires a command")
    with seat_lock(provider, profile, exclusive=False, blocking=blocking) as lease:
        child = None
        pending = []

        def forward(signum, _frame):
            if child is None:
                pending.append(signum)
            elif child.poll() is None:
                try:
                    child.send_signal(signum)
                except ProcessLookupError:
                    pass

        previous = {sig: signal.signal(sig, forward) for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP)}
        try:
            child = subprocess.Popen(command, pass_fds=(lease.fd,))
            for signum in pending:
                forward(signum, None)
            code = child.wait()
            fcntl.flock(lease.fd, fcntl.LOCK_UN)
            return code if code >= 0 else 128 - code
        finally:
            for sig, handler in previous.items():
                signal.signal(sig, handler)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("operation", choices=("guard", "available", "state", "owners", "identity"))
    parser.add_argument("--provider", choices=("claude", "codex"), required=True)
    parser.add_argument("--profile", required=True)
    parser.add_argument("--home", default=os.environ.get("FM_HOME", "."))
    parser.add_argument("--nonblocking", action="store_true")
    arguments = sys.argv[1:]
    command = []
    if "--" in arguments:
        separator = arguments.index("--")
        arguments, command = arguments[:separator], arguments[separator + 1:]
    args = parser.parse_args(arguments)
    try:
        if args.operation == "guard":
            return guard(args.provider, args.profile, command, not args.nonblocking)
        if args.operation == "available":
            with seat_lock(args.provider, args.profile, exclusive=False, blocking=False):
                return 0
        if args.operation == "state":
            print(json.dumps(read_state(args.provider, args.profile), separators=(",", ":")))
        elif args.operation == "identity":
            print(identity(args.provider, args.profile))
        else:
            print(json.dumps(owners(args.provider, args.profile, args.home), separators=(",", ":")))
        return 0
    except BlockingIOError:
        print("seat lock: seat is busy", file=sys.stderr)
        return 75
    except (SeatLockError, OSError, ValueError) as error:
        message = str(error) if isinstance(error, SeatLockError) else "seat coordination failed"
        print("seat lock: " + message, file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
