#!/usr/bin/env python3
"""Serialize heavy builds across Firstmate homes on this machine.

fm-build-lock.js is a Node preload carried in NODE_OPTIONS, so it survives
shells that rebuild PATH (rc files, version managers, agent shell snapshots).
Only Node executing Next's resolved dist/bin/next CLI with `build` re-runs
itself through this lock; every other Node process returns from the preload
without starting another interpreter. Package managers and Turbo remain
unlocked; their Next build leaves lock.

  fm-build-lock.py -- COMMAND [ARGS...]   run another heavy command locked
  fm-build-lock.py node-option            print the NODE_OPTIONS entry
  fm-build-lock.py node-env-file OUT
      write OUT as one export statement adding the entry to the inherited
      NODE_OPTIONS, so a pane shell (fish included) only sources a plain export
  fm-build-lock.py install-daemon-env [--unit-dir DIR]
      write a systemd user drop-in giving every no-mistakes daemon unit the
      preload; it activates at the daemon's next restart, never restarts it.
Bypass once: FM_BUILD_LOCK_BYPASS=1 pnpm build.

Every entry names an installed copy of the preload and this script in
~/.local/share/firstmate-build-lock (FM_BUILD_LOCK_INSTALL_DIR overrides it),
refreshed by every command that prints or writes one, so no long-lived
NODE_OPTIONS depends on a checkout that can be removed; a missing --require
target stops every Node process.

The default /var/tmp/firstmate-heavy-build-<uid>.lock is shared by every home
under the same OS user, independent of HOME and TMPDIR. FM_BUILD_LOCK_FILE can
select an absolute shared path (all participants must use the same path).
Never delete a live lock file: flock protects its inode, not its pathname.
Python fcntl.flock works on Linux and macOS without the flock CLI. Errors fail
closed. The exec'd build owns an inheritable fd; exit, including SIGKILL,
releases it when the last inheriting descendant exits. Recursive descendants
reuse the logical build's lock, including runners that close extra fds or
scrub the environment.

Coverage is NODE_OPTIONS-based: runtimes other than Node, other build tools,
or launchers that clear NODE_OPTIONS need the explicit wrapper. The daemon
drop-in is systemd-only; a launchd-managed daemon is not covered.
"""

import fcntl
import json
import os
from pathlib import Path
import stat
import subprocess
import sys

SOURCE = Path(__file__).resolve().parent
FILES = {"fm-build-lock.py": 0o755, "fm-build-lock.js": 0o644}
DROP_IN = "fm-build-lock.conf"


def install():
    target = Path(os.environ.get("FM_BUILD_LOCK_INSTALL_DIR")
                  or Path.home() / ".local/share/firstmate-build-lock")
    if not target.is_absolute():
        raise ValueError("FM_BUILD_LOCK_INSTALL_DIR must be absolute")
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


def record(fd):
    os.lseek(fd, 0, os.SEEK_SET)
    try:
        return json.loads(os.read(fd, 4096))
    except (ValueError, UnicodeError):
        return {}


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


def acquire():
    path = os.environ.get("FM_BUILD_LOCK_FILE", f"/var/tmp/firstmate-heavy-build-{os.getuid()}.lock")
    if not os.path.isabs(path):
        raise ValueError("FM_BUILD_LOCK_FILE must be absolute")
    fd = os.open(path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    info = os.fstat(fd)
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid():
        raise ValueError("build lock must be a regular file owned by this user")
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        owner = record(fd)
        if isinstance(owner.get("pid"), int) and ancestor(owner["pid"]):
            os.close(fd)
            return
        print(f"waiting for build lock (held by pid {owner.get('pid', 'unknown')})", file=sys.stderr, flush=True)
        fcntl.flock(fd, fcntl.LOCK_EX)
    os.lseek(fd, 0, os.SEEK_SET)
    os.ftruncate(fd, 0)
    os.write(fd, json.dumps({"pid": os.getpid()}).encode())
    os.set_inheritable(fd, True)


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
    except (OSError, ValueError) as error:
        print(f"build lock: {error}", file=sys.stderr)
        sys.exit(75)
