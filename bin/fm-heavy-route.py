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
FM_BUILD_LOCK_BYPASS=1 skips the preload, and so this script, entirely.

Routing is declared, never guessed: without a declaration naming the project,
nothing about a heavy command changes, and no routing notice is printed.
For a declared project's worker-started command, a reason to stay local prints
one line to stderr and runs the command through fm-build-lock.py.

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
               a preflight needs a read-only GitHub token that waits on a
               separate credential design this adapter deliberately lacks.
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
Only a top-level heavy command is routed: one with turbo, nx, lerna, or a
recursive or filtered pnpm among its ancestor processes takes a local heavy slot,
so an orchestrator fanning out N heavy children never starts N machines.

Remote shape: fm-boat-run.sh owns the upload, the account budget, the result
and the cleanup; this script only builds the command for it. The local node
interpreter is replaced by `node` from the remote PATH, the preload's own
--require is dropped, and an argument naming a path inside the worktree becomes
that path relative to the remote source root. Nothing from the local
environment travels. The source is HEAD's tracked files with their uncommitted
edits plus every newly staged addition, each through fm-boat-run.sh's own
--input screen. An untracked file that is not ignored never travels, so while
one exists the command stays local and the notice names it.

Nothing a remote run writes comes back, so a command whose job includes writing
into the worktree stays local: next build, a tsc build or a tsc whose resolved
configuration (`tsc --showConfig`, run outside the preload) does not prove
noEmit with incremental and composite disabled, a tsc writing traces or CPU
profiles, vitest updating snapshots or writing coverage or an output file, and
eslint fixing files or writing reports, caches or suppressions. A vitest configuration file that
writes coverage or a reporter's output file is invisible here, so such a project
declares vitest local-only. Remote output is captured and printed when the
command finishes rather than streamed.
Only options recognized by normalized_options for that kind may route;
unknown, malformed or ambiguous arguments stay local. Enabled stdin input
also stays local because the remote command receives no stdin.

Only result kind `completed` with confirmed command dispatch is a verdict:
that remote exit is the command's exit, and an unconfirmed cleanup is reported
without changing it. Failed setup or any other unconfirmed outcome falls back
locally after one notice. A failed remote vitest run that reports a snapshot
missing, mismatched or not
written is not a verdict either, because the remote run is under CI, where
vitest never writes a new snapshot; it too runs locally after one notice.
"""

import json
import os
from pathlib import Path
import re
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
ORCHESTRATORS = ("turbo", "nx", "lerna")
SNAPSHOT_UNWRITTEN = re.compile(
    rb"Snapshot .{0,200}(?:mismatched|missing)|snapshots? (?:was |were )?not written", re.I)


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
    if sep:
        if tail == str(root):
            return head + "=" + REMOTE_SOURCE
        if tail.startswith(inside):
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


def staged_or_untracked(root):
    """(newly staged additions, first untracked unignored path or None), or None."""
    def names(*args):
        listed = subprocess.run(["git", "-C", str(root), *args], capture_output=True,
                                check=True, timeout=60).stdout
        return [os.fsdecode(name) for name in listed.split(b"\0") if name]
    try:
        untracked = names("ls-files", "-z", "--others", "--exclude-standard")
        added = names("diff", "--cached", "--no-renames", "--name-only", "--diff-filter=A",
                      "-z")
    except (OSError, subprocess.SubprocessError):
        return None
    return added, (untracked[0] if untracked else None)


def proves_no_outputs(command):
    """Whether tsc emits nothing except an unnamed incremental cache."""
    try:
        shown = subprocess.run([*command, "--showConfig"], capture_output=True, text=True,
                               timeout=60, env=dict(os.environ, FM_BUILD_LOCK_BYPASS="1"))
        options = json.loads(shown.stdout).get("compilerOptions")
    except (OSError, subprocess.SubprocessError, ValueError, AttributeError):
        return False
    if not (shown.returncode == 0 and isinstance(options, dict) and
            options.get("noEmit") is True and not options.get("composite") and
            "tsBuildInfoFile" not in options):
        return False
    if options.get("incremental"):
        print("heavy-route: the incremental cache is not preserved for this run",
              file=sys.stderr, flush=True)
    return True


OPTION_TYPES = {
    "eslint": {
        **dict.fromkeys(("--fix", "--cache", "--suppress-all", "--prune-suppressions",
                         "--stdin"), ("bool", "disabled")),
        **dict.fromkeys(("--quiet", "--color"), ("bool", "safe")),
        **dict.fromkeys(("-o", "--output-file", "--cache-file", "--cache-location",
                         "--suppress-rule", "--suppressions-location", "--stdin-filename"),
                       ("value", "never")),
        **dict.fromkeys(("-f", "--format", "--max-warnings"), ("value", "safe")),
    },
    "tsc": {
        **dict.fromkeys(("--noEmit", "--composite"), ("bool", "resolved")),
        "--incremental": ("bool", "disabled"),
        "--pretty": ("bool", "safe"),
        **dict.fromkeys(("-b", "--build"), ("bool", "never")),
        **dict.fromkeys(("-p", "--project"), ("value", "safe")),
        **dict.fromkeys(("--generateTrace", "--generateCpuProfile", "--tsBuildInfoFile"),
                       ("value", "never")),
    },
    "vitest": {
        "--run": ("bool", "enabled"),
        **dict.fromkeys(("-u", "--update", "--coverage", "--coverage.enabled"),
                       ("bool", "never")),
        **dict.fromkeys(("--silent", "--color", "--passWithNoTests"), ("bool", "safe")),
        **dict.fromkeys(("--root", "--dir", "--reporter", "--testNamePattern", "-t"),
                       ("value", "safe")),
        **dict.fromkeys(("--outputFile", "--outputFile.json", "--coverage.reporter"),
                       ("value", "never")),
    },
}


def normalized_options(kind, command):
    options = []
    schema = OPTION_TYPES.get(kind)
    if schema is None:
        return None
    args = command[1:]
    index = 0
    while index < len(args):
        arg = args[index]
        index += 1
        if not arg or arg in ("-", "--"):
            return None
        if not arg.startswith("-"):
            if kind == "vitest" and arg not in ("run", ".", "..") and \
                    "/" not in arg and not Path(arg).suffix:
                return None
            continue
        name, sep, value = arg.partition("=")
        if name == "--require":
            required = value if sep else (args[index] if index < len(args) else "")
            if Path(required).name != "fm-build-lock.js":
                return None
            if not sep:
                index += 1
            continue
        negated = name.startswith("--no-")
        if negated:
            name = "--" + name[5:]
        value_type, policy = schema.get(name, (None, None))
        if value_type is None or (negated and value_type != "bool"):
            return None
        if value_type == "bool":
            if not sep:
                value = "true"
                if index < len(args) and args[index].lower() in ("true", "false"):
                    value = args[index].lower()
                    index += 1
            if value.lower() not in ("true", "false"):
                return None
            value = value.lower()
            if negated:
                value = "true" if value == "false" else "false"
        else:
            if not sep:
                if index == len(args):
                    return None
                value = args[index]
                index += 1
            if not value or value.startswith("-"):
                return None
            if kind == "eslint" and name in ("-f", "--format") and value not in (
                    "stylish", "json", "json-with-metadata"):
                return None
            if kind == "vitest" and name == "--reporter" and value not in (
                    "default", "basic", "verbose", "dot", "json", "junit", "tap", "tap-flat"):
                return None
        options.append((value, policy))
    return options


def unsafe_to_route(kind, command):
    """Reject unknown arguments and commands whose input or output cannot travel."""
    if kind == "next-build":
        return True
    options = normalized_options(kind, command)
    if options is None:
        return True
    if any(policy == "never" or (policy == "disabled" and value != "false") or
           (policy == "enabled" and value != "true") for value, policy in options):
        return True
    if kind == "tsc":
        return not proves_no_outputs(command)
    if kind in ("eslint", "vitest"):
        return False
    return True


def orchestrated():
    """The first orchestrator among this process's ancestors, or None."""
    pid = os.getppid()
    while pid > 1:
        try:
            argv = [os.fsdecode(word) for word in
                    Path("/proc/%d/cmdline" % pid).read_bytes().split(b"\0") if word]
            stat = Path("/proc/%d/stat" % pid).read_text()
            pid = int(stat[stat.rindex(")") + 2:].split()[1])
        except (OSError, ValueError, IndexError):
            return None
        names = set()
        for word in argv[:2]:
            parts = word.split("/")
            names.add(parts[-1].split(".")[0])
            names.update(parts[at + 1] for at, part in enumerate(parts[:-1])
                         if part == "node_modules")
        found = names.intersection(ORCHESTRATORS)
        if found:
            return found.pop()
        fanout = [word for word in argv[1:]
                  if word in ("-r", "--recursive", "-F") or word.startswith("--filter")]
        if "pnpm" in names and fanout:
            return "pnpm " + fanout[0]
    return None


def boat(settings, command, kind, home, bin_dir, root, inputs):
    """Run the heavy command on one ephemeral Boat VM. Returns an exit code, or None."""
    scratch = root.parent / SCRATCH
    try:
        scratch.mkdir(exist_ok=True)
        job = Path(tempfile.mkdtemp(dir=str(scratch), prefix="fm-heavy-route.%s." % kind))
    except OSError as error:
        return local("the Boat evidence directory could not be made (%s)" % error, command)
    output = job / "boat"
    relative = os.path.relpath(os.getcwd(), str(root))
    dispatched = "fm-heavy-command-" + os.urandom(16).hex()
    script = ["set -euo pipefail", "{", settings["bootstrap"], "} >&2"]
    if relative != ".":
        script.append("cd " + shlex.quote(relative))
    script.append("printf '\\n%s\\n' " + shlex.quote(dispatched) + " >&2")
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
    finished = subprocess.run(adapter, env=dict(os.environ, FM_HOME=str(home)), check=False,
                              capture_output=True)
    sys.stderr.buffer.write(finished.stderr.replace(
        ("\n" + dispatched + "\n").encode(), b"", 1))
    sys.stderr.buffer.flush()
    try:
        result = json.loads((output / "result.json").read_text())
    except (OSError, ValueError):
        result = {}
    if result.get("kind") != "completed" or not isinstance(result.get("remote_exit"), int):
        return local("Boat did not run it (%s, exit %d); discarded remote stdout; evidence %s"
                     % (result.get("kind") or "no result", finished.returncode,
                        output / "result.json"), command)
    if result.get("cleanup") != "deleted":
        print("heavy-route: the Boat machine's cleanup is %s; reap it (evidence %s)"
              % (result.get("cleanup") or "unknown", output / "result.json"),
              file=sys.stderr, flush=True)
    try:
        log = (output / "command.log").read_bytes()
    except OSError:
        log = b""
    if dispatched.encode() not in log.splitlines():
        return local("Boat setup did not dispatch the heavy command; "
                     "discarded remote stdout; evidence %s"
                     % (output / "result.json"), command)
    if kind == "vitest" and result["remote_exit"] != 0:
        if SNAPSHOT_UNWRITTEN.search(log):
            return local("Boat's vitest failed on a snapshot it may not write under CI; "
                         "discarded remote stdout", command)
    sys.stdout.buffer.write(finished.stdout)
    sys.stdout.buffer.flush()
    return result["remote_exit"]


def route(kind, command):
    if kind not in KINDS:
        raise Unreadable("unknown heavy kind %r; known: %s" % (kind, ", ".join(KINDS)))
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
        return local("%s is declared local-only for this project" % kind, command)
    ancestor = orchestrated()
    if ancestor:
        return local("%s runs under %s, so only that top-level command could go to Boat"
                     % (kind, ancestor), command)
    tree = staged_or_untracked(root)
    if tree is None:
        return local("the worktree's uncommitted files could not be listed", command)
    if tree[1]:
        return local("untracked file %s would not travel to Boat" % tree[1], command)
    if unsafe_to_route(kind, command):
        return local("%s has unknown or ambiguous options, reads input Boat cannot receive, "
                     "or writes files Boat would not bring back" % kind, command)
    home, bin_dir = loaded.get("home"), loaded.get("bin")
    if not (isinstance(home, str) and isinstance(bin_dir, str)
            and Path(bin_dir, "fm-boat-run.sh").is_file()):
        return local("the recorded Firstmate copy is gone", command)
    return boat(settings, command, kind, home, bin_dir, root, tree[0])


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
