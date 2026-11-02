#!/usr/bin/env python3
"""Send a worker's heavy command to Boat first, or to the local heavy slot.

A heavy command is one whose peak memory can exhaust a small machine, and
fm-build-lock.js owns which command that is. Running it locally costs this
machine one of its few heavy places; running it on an ephemeral Boat VM costs
it nothing. So a declared project's worker-started heavy command goes to Boat
first, and the local heavy slot plus memory cap is the fallback.

  fm-heavy-route.py --kind KIND -- COMMAND [ARGS...]
      route one heavy command, already classified by the preload
  fm-heavy-route.py publish --home DIR --config DIR
      validate DIR/boat-heavy and write the machine's routing record
Kinds: next-build, vitest, playwright, eslint, tsc, queue-preflight.
Force the local path for one command: FM_HEAVY_ROUTE=local <command>.
FM_BUILD_LOCK_BYPASS=1 still skips the preload, and so this script, entirely.

Routing is declared, never guessed: without a declaration naming the project,
nothing about a heavy command changes. Every reason to stay local prints one
line to stderr and runs the command through fm-build-lock.py exactly as an
undeclared project does, so a routing failure can only cost the Boat attempt.

Declaration: <config-dir>/boat-heavy in the machine's root Firstmate home,
resolved like config/heavy-slots (fm_project_capacity_config_dir). One line per
project, parsed as a shell word list so a value may be quoted:

  core bootstrap='corepack enable pnpm; pnpm install --frozen-lockfile' type=large

<project-name> is the FIRST word and is the basename of the worktree the heavy
command runs in, which for a task worktree is the project's own name. Every
later word is <key>=<value>:
  bootstrap    required, nonempty. A shell command run at the remote source
               root before the heavy command. Remote node_modules never
               travel, so a project that needs them installs them here.
  local-only   heavy kinds that always stay local, comma separated. Defaults
               to playwright,queue-preflight: a browser run needs browsers, and
               a preflight reads a private remote and repository variables, so
               both need credentials this adapter deliberately cannot carry.
               An empty value declares that no kind stays local.
  type         Boat machine type, passed to fm-boat-run.sh --type unchanged.
  timeout      whole seconds, passed to fm-boat-run.sh --timeout unchanged,
               which owns its own bounds.
Blank lines are ignored. A line is a comment when it is `#` or starts with `#`
followed by whitespace. Any other shape, an unknown or repeated key, a project
named twice, a missing bootstrap, an unknown kind, or an unreadable file makes
the whole declaration unreadable, and publication refuses rather than guessing
which projects were meant to be routed.

Publication: the record is machine-wide, beside fm-build-lock.py's installed
preload and heavy-slot record, because a heavy command runs in a worker shell
that cannot read any home's configuration. Every ship or scout launch rewrites
it, so a change applies at the next launch; the last launch on the machine wins,
exactly as the heavy-slot count does.

Only a worker-started command is routed. A command with no FM_TASK_ID in its
environment keeps its existing path, which leaves the no-mistakes daemon's own
steps and their Boat integration (bin/fm-boat-test-wrapper.sh) untouched.

Remote shape: fm-boat-run.sh owns the upload, the account budget, the result
and the cleanup; this script only builds the command for it. The local node
interpreter is replaced by `node` from the remote PATH, the preload's own
--require is dropped, and an argument naming a path inside the worktree becomes
that path relative to the remote source root. Nothing from the local
environment travels. The source is the worktree as it stands: HEAD's tracked
files with their uncommitted edits, plus every untracked or newly staged file
that is not ignored, each through fm-boat-run.sh's own --input screen.

Nothing a remote run writes comes back, so a command whose job includes writing
into the worktree stays local: next build, tsc without an explicit --noEmit or
in build mode, vitest updating snapshots or writing coverage or an output file,
and eslint fixing files or writing an output file. Remote output is captured and printed when the command
finishes rather than streamed.

Only result kind `completed` is a verdict: that remote exit is the command's
exit, and an unconfirmed cleanup is reported without changing it. Every other
outcome means the command never ran, so it runs locally after one notice.
"""

import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile

SOURCE = Path(__file__).resolve().parent
RECORD = "boat-route"
KINDS = ("next-build", "vitest", "playwright", "eslint", "tsc", "queue-preflight")
DEFAULT_LOCAL_ONLY = ("playwright", "queue-preflight")
KEYS = ("bootstrap", "local-only", "type", "timeout")
# fm-boat-run.sh's header owns this path; the remote command is built against it.
REMOTE_SOURCE = "/home/user/fm-job/source"
SCRATCH = ".fm-test-scratch"


class Unreadable(Exception):
    """The declaration cannot be acted on, so publication refuses."""


def install_dir():
    target = Path(os.environ.get("FM_BUILD_LOCK_INSTALL_DIR")
                  or Path.home() / ".local/share/firstmate-build-lock")
    if not target.is_absolute():
        raise Unreadable("FM_BUILD_LOCK_INSTALL_DIR must be absolute")
    return target


def declaration(path):
    """Parse <config-dir>/boat-heavy into {project: settings}."""
    projects = {}
    try:
        text = path.read_text()
    except FileNotFoundError:
        return projects
    except OSError as error:
        raise Unreadable("%s is not readable (%s)" % (path, error)) from error
    for lineno, raw in enumerate(text.splitlines(), 1):
        line = raw.strip()
        if not line or line == "#" or (line.startswith("#") and line[1].isspace()):
            continue
        try:
            words = shlex.split(line, comments=False)
        except ValueError as error:
            raise Unreadable("%s line %d is not a shell word list (%s)"
                             % (path, lineno, error)) from error
        name, fields = words[0], words[1:]
        if name in projects:
            raise Unreadable("%s line %d names %s a second time" % (path, lineno, name))
        settings = {"bootstrap": None, "local_only": list(DEFAULT_LOCAL_ONLY),
                    "type": None, "timeout": None}
        seen = set()
        for field in fields:
            key, sep, value = field.partition("=")
            if not sep or key not in KEYS:
                raise Unreadable("%s line %d has no <key>=<value> for one of %s: %r"
                                 % (path, lineno, ", ".join(KEYS), field))
            if key in seen:
                raise Unreadable("%s line %d repeats %s" % (path, lineno, key))
            seen.add(key)
            if key == "bootstrap":
                if not value.strip():
                    raise Unreadable("%s line %d has an empty bootstrap" % (path, lineno))
                settings["bootstrap"] = value
            elif key == "local-only":
                kinds = [k for k in value.split(",") if k]
                unknown = [k for k in kinds if k not in KINDS]
                if unknown:
                    raise Unreadable("%s line %d names unknown heavy kind(s) %s; known: %s"
                                     % (path, lineno, ", ".join(unknown), ", ".join(KINDS)))
                settings["local_only"] = kinds
            else:
                if not value.strip():
                    raise Unreadable("%s line %d has an empty %s" % (path, lineno, key))
                settings[key] = value
        if settings["bootstrap"] is None:
            raise Unreadable("%s line %d declares %s with no bootstrap, so no command could "
                             "find its dependencies remotely" % (path, lineno, name))
        projects[name] = settings
    return projects


def publish(args):
    home = config = None
    while args:
        flag, args = args[0], args[1:]
        if flag in ("--home", "--config") and args:
            value, args = args[0], args[1:]
            path = Path(value)
            if not path.is_absolute():
                raise Unreadable("%s must be an absolute path, not %r" % (flag, value))
            if flag == "--home":
                home = path
            else:
                config = path
        else:
            raise Unreadable("publish takes --home DIR --config DIR")
    if home is None or config is None:
        raise Unreadable("publish takes --home DIR --config DIR")
    record = {"version": 1, "home": str(home), "bin": str(SOURCE),
              "projects": declaration(config / "boat-heavy")}
    target = install_dir()
    try:
        target.mkdir(parents=True, exist_ok=True)
        staged = target / (".%s.%d" % (RECORD, os.getpid()))
        staged.write_text(json.dumps(record, sort_keys=True) + "\n")
        staged.replace(target / RECORD)
    except OSError as error:
        raise Unreadable("the routing record could not be written (%s)" % error) from error
    return 0


def local(reason, command):
    """Run the command in a local heavy slot, exactly as an undeclared project does."""
    if reason:
        print("heavy-route: %s; running locally in a heavy slot" % reason,
              file=sys.stderr, flush=True)
    os.execv(str(SOURCE / "fm-build-lock.py"),
             [str(SOURCE / "fm-build-lock.py"), "--", *command])


def record():
    try:
        loaded = json.loads((install_dir() / RECORD).read_text())
    except (OSError, ValueError, Unreadable):
        return None
    return loaded if isinstance(loaded, dict) and isinstance(loaded.get("projects"), dict) else None


def worktree():
    try:
        top = subprocess.run(["git", "rev-parse", "--show-toplevel"], capture_output=True,
                             text=True, check=True, timeout=30).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return None
    return Path(top) if top else None


def remote_argument(value, root):
    """A path inside the worktree, rewritten against the remote source root."""
    inside = str(root) + "/"
    head, sep, tail = value.partition("=")
    if value == str(root):
        return REMOTE_SOURCE
    if value.startswith(inside):
        return REMOTE_SOURCE + "/" + value[len(inside):]
    if sep and tail.startswith(inside):
        return head + "=" + REMOTE_SOURCE + "/" + tail[len(inside):]
    return value


def remote_command(command, root, preload):
    """The local heavy command as the disposable machine must run it."""
    remote = []
    skip = False
    for index, value in enumerate(command):
        if skip:
            skip = False
            continue
        if value == "--require" and index + 1 < len(command) and \
                Path(command[index + 1]).name == preload.name:
            skip = True
            continue
        if value.startswith("--require=") and Path(value[len("--require="):]).name == preload.name:
            continue
        if index == 0 and value.startswith("/") and not value.startswith(str(root) + "/"):
            remote.append(Path(value).name)
            continue
        remote.append(remote_argument(value, root))
    return remote


def uncommitted_new(root):
    """Files the worktree has that HEAD's tree lacks: untracked or newly staged."""
    def names(*args):
        listed = subprocess.run(["git", "-C", str(root), *args], capture_output=True,
                                check=True, timeout=60).stdout
        return {os.fsdecode(name) for name in listed.split(b"\0") if name}
    try:
        present = names("ls-files", "-z", "--cached", "--others", "--exclude-standard")
        committed = names("ls-tree", "-rz", "--name-only", "--full-tree", "HEAD")
    except (OSError, subprocess.SubprocessError):
        return None
    return sorted(name for name in present - committed if os.path.lexists(root / name))


def writes_worktree(kind, command):
    """Whether the command's job includes files Boat would leave on its machine."""
    args = [value.lower() for value in command[1:]]
    if kind == "next-build":
        return True
    if kind == "tsc":
        if "-b" in args or "--build" in args or "--noemit" not in args:
            return True
        at = args.index("--noemit")
        return at + 1 < len(args) and args[at + 1] == "false"
    if kind == "vitest":
        return any(value in ("-u", "--update") or value.startswith(
            ("--update=", "--coverage", "--outputfile")) for value in args)
    if kind == "eslint":
        return any(value in ("--fix", "-o") or value.startswith("--output-file")
                   for value in args)
    return False


def boat(settings, command, kind, home, bin_dir, root):
    """Run the heavy command on one ephemeral Boat VM. Returns an exit code, or None."""
    scratch = root.parent / SCRATCH
    try:
        scratch.mkdir(exist_ok=True)
        job = Path(tempfile.mkdtemp(dir=str(scratch), prefix="fm-heavy-route.%s." % kind))
    except OSError as error:
        return local("the Boat evidence directory could not be made (%s)" % error, command)
    output = job / "boat"
    inputs = uncommitted_new(root)
    if inputs is None:
        return local("the worktree's uncommitted files could not be listed", command)
    relative = os.path.relpath(os.getcwd(), str(root))
    script = ["set -euo pipefail", settings["bootstrap"]]
    if relative != ".":
        script.append("cd " + shlex.quote(relative))
    script.append("exec " + shlex.join(remote_command(command, root, SOURCE / "fm-build-lock.js")))
    adapter = [str(Path(bin_dir) / "fm-boat-run.sh"), "run",
               "--worktree", str(root), "--output", str(output)]
    for name in inputs:
        adapter += ["--input", name]
    if settings.get("timeout"):
        adapter += ["--timeout", str(settings["timeout"])]
    if settings.get("type"):
        adapter += ["--type", str(settings["type"])]
    adapter += ["--", "bash", "-c", "\n".join(script)]
    print("heavy-route: %s on Boat; output is printed when it finishes; evidence %s"
          % (kind, output / "result.json"), file=sys.stderr, flush=True)
    finished = subprocess.run(adapter, env=dict(os.environ, FM_HOME=str(home)), check=False)
    try:
        result = json.loads((output / "result.json").read_text())
    except (OSError, ValueError):
        result = {}
    if result.get("kind") != "completed" or not isinstance(result.get("remote_exit"), int):
        return local("Boat did not run it (%s, exit %d); evidence %s"
                     % (result.get("kind") or "no result", finished.returncode,
                        output / "result.json"), command)
    if result.get("cleanup") != "deleted":
        print("heavy-route: the Boat machine's cleanup is %s; reap it (evidence %s)"
              % (result.get("cleanup") or "unknown", output / "result.json"),
              file=sys.stderr, flush=True)
    return result["remote_exit"]


def route(kind, command):
    if kind not in KINDS:
        raise Unreadable("unknown heavy kind %r; known: %s" % (kind, ", ".join(KINDS)))
    if os.environ.get("FM_HEAVY_ROUTE") == "local":
        return local("", command)
    if not os.environ.get("FM_TASK_ID"):
        return local("", command)
    loaded = record()
    if loaded is None:
        return local("", command)
    root = worktree()
    if root is None:
        return local("", command)
    settings = loaded["projects"].get(root.name)
    if not isinstance(settings, dict) or not settings.get("bootstrap"):
        return local("", command)
    if kind in (settings.get("local_only") or []):
        return local("%s needs credentials Boat cannot carry" % kind, command)
    if writes_worktree(kind, command):
        return local("%s writes files Boat would not bring back" % kind, command)
    home, bin_dir = loaded.get("home"), loaded.get("bin")
    if not (isinstance(home, str) and isinstance(bin_dir, str)
            and Path(bin_dir, "fm-boat-run.sh").is_file()):
        return local("the recorded Firstmate copy is gone", command)
    return boat(settings, command, kind, home, bin_dir, root)


def main():
    args = sys.argv[1:]
    if args[:1] == ["publish"]:
        return publish(args[1:])
    if len(args) > 3 and args[0] == "--kind" and args[2] == "--":
        return route(args[1], args[3:])
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Unreadable as error:
        print("heavy-route: %s" % error, file=sys.stderr)
        sys.exit(2)
