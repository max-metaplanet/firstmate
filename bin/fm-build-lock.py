#!/usr/bin/env python3
"""Serialize heavy builds across Firstmate homes on this machine.

build-shims/{next,node} use this executable through PATH. Only `next build`
and Node executing Next's resolved dist/bin/next CLI with `build` lock.
Package managers and Turbo remain unlocked; their Next build leaves lock.
Explicit other heavy commands: fm-build-lock.py -- COMMAND [ARGS...].
Bypass once: FM_BUILD_LOCK_BYPASS=1 pnpm build.

The default /var/tmp/firstmate-heavy-build-<uid>.lock is shared by every home
under the same OS user, independent of HOME and TMPDIR. FM_BUILD_LOCK_FILE can
select an absolute shared path (all participants must use the same path).
Never delete a live lock file: flock protects its inode, not its pathname.
Python fcntl.flock works on Linux and macOS without the flock CLI. Errors fail
closed. The exec'd build owns an inheritable fd; exit, including SIGKILL,
releases it when the last inheriting descendant exits. Recursive descendants
reuse the logical build's lock, including runners that close extra fds or
scrub the environment.

Coverage is PATH-based: absolute Node binaries, embedded runtimes, other build
tools, or shells that replace PATH need the explicit wrapper. Managed pipeline
Claude agents inherit the shims; daemon-run configured commands and other
pipeline providers do not inherit the Claude wrapper's environment.
"""

import fcntl
import json
import os
from pathlib import Path
import stat
import subprocess
import sys


def real_command(name):
    """Ignore every copy of our shims, including another home's installation."""
    for directory in os.get_exec_path():
        candidate = Path(directory or ".") / name
        if not candidate.is_file() or not os.access(candidate, os.X_OK):
            continue
        if candidate.resolve().name == "fm-build-lock.py":
            continue
        return str(candidate.absolute())
    raise FileNotFoundError(f"real {name} executable not found on PATH")


def node_build(args):
    # Node flags precede the script. Skip flags with separate values explicitly;
    # eval/print/stdin are never a CLI script invocation.
    value_flags = {"-r", "--require", "--import", "--loader", "--experimental-loader",
                   "--conditions", "-C", "--icu-data-dir"}
    index = 0
    while index < len(args):
        arg = args[index]
        if arg in {"-e", "--eval", "-p", "--print", "-", "-v", "--version", "-h", "--help"}:
            return False
        if arg == "--":
            index += 1
            break
        if not arg.startswith("-"):
            break
        index += 2 if arg in value_flags else 1
    return (index + 1 < len(args) and args[index + 1] == "build"
            and str(Path(args[index]).resolve()).endswith("/next/dist/bin/next"))


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
    name = Path(sys.argv[0]).name
    args = sys.argv[1:]
    if name in {"node", "next"}:
        command = real_command(name)
        heavy = (args[:1] == ["build"]) if name == "next" else node_build(args)
    else:
        if len(args) < 2 or args[0] != "--":
            print(__doc__, file=sys.stderr)
            return 2
        command, args = args[1], args[2:]
        heavy = True
    if name in {"node", "next"} and any(arg in {"-h", "--help"} for arg in args):
        heavy = False
    if heavy and os.environ.get("FM_BUILD_LOCK_BYPASS") != "1":
        acquire()
    os.execvpe(command, [command, *args], os.environ)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError) as error:
        print(f"build lock: {error}", file=sys.stderr)
        sys.exit(75)
