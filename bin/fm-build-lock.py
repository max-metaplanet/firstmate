#!/usr/bin/env python3
"""Hold the machine's heavy slots: the commands that spike RAM run in a pool.

A heavy slot is claimed when a heavy command starts, not reserved when a worker
spawns. The pool is machine-wide for one OS user, so every Firstmate home,
every worker, and the no-mistakes daemon all draw from it.

fm-build-lock.js is a Node preload carried in NODE_OPTIONS, so it survives
shells that rebuild PATH (rc files, version managers, agent shell snapshots).
Only Node executing a heavy CLI re-runs itself through this script; every other
Node process returns from the preload without starting another interpreter. The
preload owns which command is heavy. Package managers and Turbo remain
unlocked; the heavy commands they start claim slots themselves.

  fm-build-lock.py -- COMMAND [ARGS...]   run another heavy command in a slot
  fm-build-lock.py node-option            print the NODE_OPTIONS entry
  fm-build-lock.py node-env-file OUT
      write OUT as one export statement adding the entry to the inherited
      NODE_OPTIONS, so a pane shell (fish included) only sources a plain export
  fm-build-lock.py install-daemon-env [--unit-dir DIR]
      write a systemd user drop-in giving every no-mistakes daemon unit the
      preload; it activates at the daemon's next restart, never restarts it.
Bypass once: FM_BUILD_LOCK_BYPASS=1 pnpm build.

Pool size: FM_HEAVY_SLOTS when set, else the installed heavy-slots record, else
1. Every command above that prints or writes a NODE_OPTIONS entry rewrites that
record from FM_HEAVY_SLOTS, so bin/fm-spawn.sh's launch refreshes it from the
root home's config/heavy-slots for the whole machine; a size that is not a
positive integer of at most six digits is an error rather than a guess.
Lowering the size never evicts a running command, so occupancy can exceed the
new size until those commands exit.

Every entry names an installed copy of the preload and this script in
~/.local/share/firstmate-build-lock (FM_BUILD_LOCK_INSTALL_DIR overrides it),
refreshed by every command that prints or writes one, so no long-lived
NODE_OPTIONS depends on a checkout that can be removed; a missing --require
target stops every Node process.

Slot 1 is the default /var/tmp/firstmate-heavy-build-<uid>.lock, shared by every
home under the same OS user, independent of HOME and TMPDIR; slot N is that path
with `.N` appended. FM_BUILD_LOCK_FILE can select an absolute shared path (all
participants must use the same path). Never delete a live slot file: flock
protects its inode, not its pathname. Python fcntl.flock works on Linux and
macOS without the flock CLI. Errors fail closed. The exec'd command owns an
inheritable fd; exit, including SIGKILL, releases it when the last inheriting
descendant exits. Recursive descendants reuse the logical command's slot,
including runners that close extra fds or scrub the environment, so a heavy
command nested inside another never takes a second slot. Waiting for a slot
polls the pool and is not first-come-first-served; a waiter just waits.

Coverage is NODE_OPTIONS-based: runtimes other than Node, other build tools, a
script that overwrites NODE_OPTIONS instead of appending to it, or a launcher
that clears it need the explicit `-- COMMAND` wrapper. The daemon drop-in is
systemd-only; a launchd-managed daemon is not covered.
"""

import fcntl
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import time

SOURCE = Path(__file__).resolve().parent
FILES = {"fm-build-lock.py": 0o755, "fm-build-lock.js": 0o644}
DROP_IN = "fm-build-lock.conf"
SLOTS_RECORD = "heavy-slots"
POLL_SECONDS = 0.25


def install_dir():
    target = Path(os.environ.get("FM_BUILD_LOCK_INSTALL_DIR")
                  or Path.home() / ".local/share/firstmate-build-lock")
    if not target.is_absolute():
        raise ValueError("FM_BUILD_LOCK_INSTALL_DIR must be absolute")
    return target


def pool_size():
    raw = os.environ.get("FM_HEAVY_SLOTS")
    source = "FM_HEAVY_SLOTS"
    if raw is None:
        try:
            record = install_dir() / SLOTS_RECORD
            raw = record.read_text()
        except (FileNotFoundError, RuntimeError):
            # No record written yet, or no home directory to hold one.
            return 1
        source = str(record)
    raw = raw.strip()
    if not raw:
        return 1
    if not raw.isdigit() or raw.startswith("0") or len(raw) > 6:
        raise ValueError(f"{source} must be a positive integer of at most six digits, not {raw!r}")
    return int(raw)


def install():
    target = install_dir()
    target.mkdir(parents=True, exist_ok=True)
    for name, mode in FILES.items():
        data = (SOURCE / name).read_bytes()
        installed = target / name
        if SOURCE == target or (installed.is_file() and installed.read_bytes() == data):
            continue
        staged = target / f".{name}.{os.getpid()}"
        staged.write_bytes(data)
        staged.chmod(mode)
        staged.replace(installed)
    if os.environ.get("FM_HEAVY_SLOTS") is not None:
        staged = target / f".{SLOTS_RECORD}.{os.getpid()}"
        staged.write_text(f"{pool_size()}\n")
        staged.replace(target / SLOTS_RECORD)
    return target / "fm-build-lock.js"


def node_option():
    option = f"--require={install()}"
    # NODE_OPTIONS is split on whitespace and the value is embedded in shells.
    if any(not (char.isalnum() or char in "/._-=+") for char in option):
        raise ValueError(f"preload path is not NODE_OPTIONS-safe: {option}")
    return option


def env_file(out):
    option = node_option()
    value = os.environ.get("NODE_OPTIONS", "")
    if option not in value.split():
        value = f"{value} {option}" if value.strip() else option
    if "'" in value or "\\" in value:
        raise ValueError("inherited NODE_OPTIONS has quotes or backslashes")
    staged = Path(f"{out}.{os.getpid()}.tmp")
    staged.write_text(f"export NODE_OPTIONS='{value}'\n")
    staged.replace(out)
    return 0


def install_daemon_env(args):
    if args[:1] == ["--unit-dir"] and len(args) == 2:
        unit_dir = Path(args[1])
    elif not args:
        config = os.environ.get("XDG_CONFIG_HOME") or str(Path.home() / ".config")
        unit_dir = Path(config) / "systemd" / "user"
    else:
        print(__doc__, file=sys.stderr)
        return 2
    units = sorted(unit_dir.glob("no-mistakes-daemon-*.service"))
    if not units:
        raise FileNotFoundError(f"no no-mistakes daemon unit in {unit_dir}")
    text = f'[Service]\nEnvironment="NODE_OPTIONS={node_option()}"\n'
    for unit in units:
        directory = unit.with_name(unit.name + ".d")
        directory.mkdir(exist_ok=True)
        staged = directory / (DROP_IN + ".tmp")
        staged.write_text(text)
        staged.replace(directory / DROP_IN)
        print(f"wrote {directory / DROP_IN}; activates at the next "
              f"`systemctl --user daemon-reload` and {unit.name} restart")
    return 0


def slot_paths():
    base = os.environ.get("FM_BUILD_LOCK_FILE", f"/var/tmp/firstmate-heavy-build-{os.getuid()}.lock")
    if not os.path.isabs(base):
        raise ValueError("FM_BUILD_LOCK_FILE must be absolute")
    return [base] + [f"{base}.{slot}" for slot in range(2, pool_size() + 1)]


def record(fd):
    os.lseek(fd, 0, os.SEEK_SET)
    try:
        held = json.loads(os.read(fd, 4096))
    except (ValueError, UnicodeError):
        return {}
    return held if isinstance(held, dict) else {}


def ancestor(pid):
    current = os.getpid()
    for _ in range(128):
        if current <= 1:
            return False
        if current == pid:
            return True
        result = subprocess.run(["ps", "-o", "ppid=", "-p", str(current)],
                                capture_output=True, text=True, check=False)
        try:
            current = int(result.stdout.strip())
        except ValueError:
            return False
    return False


def open_slot(path):
    fd = os.open(path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    info = os.fstat(fd)
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid():
        os.close(fd)
        raise ValueError("heavy slot must be a regular file owned by this user")
    return fd


def take_free_slot(paths):
    """Lock and return one free slot's fd, plus the pids holding the busy ones.

    Every other slot this opens is closed again, which releases it; the returned
    fd stays locked so no concurrent waiter can take the same slot.
    """
    free = None
    busy = []
    base = Path(paths[0])
    prefix = base.name + "."
    retired = [str(path) for path in base.parent.iterdir()
               if path.name.startswith(prefix)
               and (suffix := path.name[len(prefix):]).isascii()
               and suffix.isdigit() and len(suffix) <= 6
               and not suffix.startswith("0") and int(suffix) > len(paths)]
    for path in [*paths, *retired]:
        fd = open_slot(path)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            busy.append(record(fd).get("pid"))
            os.close(fd)
            continue
        if free is None and path in paths:
            free = fd
        else:
            os.close(fd)
    if free is not None and len(busy) >= len(paths):
        os.close(free)
        free = None
    return free, busy


def acquire():
    waiting = False
    while True:
        paths = slot_paths()
        free, busy = take_free_slot(paths)
        if any(isinstance(pid, int) and ancestor(pid) for pid in busy):
            if free is not None:
                os.close(free)
            return
        if free is not None:
            break
        if not waiting:
            held = ", ".join(str(pid) for pid in busy if pid is not None) or "unknown"
            print(f"waiting for a heavy slot ({len(paths)} on this machine, "
                  f"held by pid {held})", file=sys.stderr, flush=True)
            waiting = True
        time.sleep(POLL_SECONDS)
    os.lseek(free, 0, os.SEEK_SET)
    os.ftruncate(free, 0)
    os.write(free, json.dumps({"pid": os.getpid()}).encode())
    os.set_inheritable(free, True)


def main():
    args = sys.argv[1:]
    if args == ["node-option"]:
        print(node_option())
        return 0
    if args[:1] == ["node-env-file"] and len(args) == 2:
        return env_file(args[1])
    if args[:1] == ["install-daemon-env"]:
        return install_daemon_env(args[1:])
    if len(args) < 2 or args[0] != "--":
        print(__doc__, file=sys.stderr)
        return 2
    command, args = args[1], args[2:]
    if os.environ.get("FM_BUILD_LOCK_BYPASS") != "1":
        acquire()
    # The preload in the exec'd Node process recognizes itself by this pid.
    os.environ["FM_BUILD_LOCK_HELD"] = str(os.getpid())
    os.execvp(command, [command, *args])


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, RuntimeError, ValueError) as error:
        print(f"build lock: {error}", file=sys.stderr)
        sys.exit(75)
