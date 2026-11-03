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
The preload intercepts a top-level turbo, nx, lerna, or recursive/filtered pnpm
invocation before it launches children.
Orchestrated pnpm routing recognizes only the directly installed `pnpm/bin/pnpm.cjs` entry; Corepack-launched pnpm stays local.
A provably safe task graph goes to Boat
as one job. Unknown options, scripts, dependencies, caches or outputs keep the
whole run local. An inherited FM_HEAVY_ORCHESTRATOR marker and an ancestor check
prevent children from submitting jobs, including after local fallback.

Remote shape: fm-boat-run.sh owns the upload, the account budget, the result
and the cleanup; this script only builds the command for it. The local node
interpreter is replaced by `node` from the remote PATH, the preload's own
--require is dropped, and an argument naming a path inside the worktree becomes
that path relative to the remote source root. Nothing from the local
environment travels. The source is HEAD's tracked files with their uncommitted
edits plus every newly staged addition, each through fm-boat-run.sh's own
--input screen. An untracked file that is not ignored never travels, so while
one exists the command stays local and the notice names it.

docs/configuration.md "Boat-first heavy routing" owns command input/output
eligibility, including the implicit incremental-cache exception and the
configuration-based Vitest local-only requirement. normalized_options owns
the recognized-safe option boundary; proves_no_outputs resolves tsc's
configuration with `tsc --showConfig` outside the preload.
Remote output is captured and printed when the command finishes rather than
streamed.

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
    plan = orchestration(command)
    if plan and not plan[1][-1].startswith(str(root) + "/"):
        command = [plan[0], *command[len(plan[1]):]]
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


def proves_no_outputs(command, cwd=None, cache_notice=True):
    """Whether tsc emits nothing except an unnamed incremental cache."""
    try:
        shown = subprocess.run([*command, "--showConfig"], capture_output=True, text=True,
                               timeout=60, cwd=cwd,
                               env=dict(os.environ, FM_BUILD_LOCK_BYPASS="1"))
        options = json.loads(shown.stdout).get("compilerOptions")
    except (OSError, subprocess.SubprocessError, ValueError, AttributeError):
        return False
    if not (shown.returncode == 0 and isinstance(options, dict) and
            options.get("noEmit") is True and not options.get("composite") and
            "tsBuildInfoFile" not in options):
        return False
    if options.get("incremental") and cache_notice:
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


def unsafe_to_route(kind, command, cwd=None):
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
        return not proves_no_outputs(command, cwd=cwd, cache_notice=cwd is None)
    if kind in ("eslint", "vitest"):
        return False
    return True


TASK_KINDS = {"type-check": "tsc", "typecheck": "tsc", "check-types": "tsc",
              "lint": "eslint", "test": "vitest", "test:run": "vitest",
              "test:ci": "vitest", "build": "next-build"}
ORCHESTRATOR_OPTIONS = {
    "turbo": {"--filter": "value", "-F": "value", "--concurrency": "value",
              "--no-cache": "bool", "--output-logs": "value"},
    "pnpm": {"--filter": "value", "-F": "value", "--recursive": "bool", "-r": "bool",
             "--parallel": "bool", "--stream": "bool", "--aggregate-output": "bool",
             "--workspace-concurrency": "value", "--if-present": "bool"},
    "nx": {"--projects": "value", "--target": "value", "-t": "value",
           "--targets": "value", "--parallel": "value", "--skipNxCache": "bool",
           "--skip-nx-cache": "bool", "--skipSync": "bool", "--skip-sync": "bool"},
    "lerna": {"--scope": "value", "--ignore": "value", "--concurrency": "value",
              "--stream": "bool", "--parallel": "bool", "--no-prefix": "bool",
              "--skip-nx-cache": "bool"},
}


def orchestration(command):
    """Return (tool, launcher argv, tasks, options), or None for an unknown shape."""
    for index, word in enumerate(command):
        path = str(Path(word).resolve()).replace("\\", "/")
        tool = next((name for name, ending in (
            ("turbo", "/turbo/bin/turbo"), ("nx", "/nx/bin/nx.js"),
            ("lerna", "/lerna/dist/cli.js"), ("lerna", "/lerna/cli.js"),
            ("pnpm", "/pnpm/bin/pnpm.cjs")) if path.endswith(ending)), None)
        if tool:
            break
    else:
        return None
    prefix = command[1:index]
    while prefix:
        flag, prefix = prefix[0], prefix[1:]
        if flag == "--require" and prefix and Path(prefix[0]).name == "fm-build-lock.js":
            prefix = prefix[1:]
        elif not (flag.startswith("--require=") and
                  Path(flag.partition("=")[2]).name == "fm-build-lock.js"):
            return None
    args = command[index + 1:]
    tasks, options = [], {}
    while args:
        word, args = args[0], args[1:]
        if word.startswith("-F") and word != "-F" and not word.startswith("--"):
            word = "--filter=" + word[2:]
        if word.startswith("-"):
            name, sep, value = word.partition("=")
            shape = ORCHESTRATOR_OPTIONS[tool].get(name)
            if shape is None:
                return None
            if shape == "value":
                if not sep:
                    if not args or args[0].startswith("-"):
                        return None
                    value, args = args[0], args[1:]
                if not value:
                    return None
            else:
                if sep and value != "true":
                    return None
                value = "true"
            options.setdefault(name, []).append(value)
            if name in ("--target", "--targets", "-t"):
                tasks += value.split(",")
        else:
            tasks.append(word)
            if tool == "pnpm" and word != "run":
                if args:
                    return None
                break
    if tasks[:1] in (["run"], ["run-many"]):
        tasks = tasks[1:]
    if tool == "nx":
        tasks = [task.split(":")[1] if ":" in task and len(task.split(":")) == 2
                 else task for task in tasks]
    if not tasks or any(task not in TASK_KINDS for task in tasks):
        return None
    if tool == "pnpm" and not any(key in options for key in (
            "-r", "--recursive", "-F", "--filter")):
        return None
    return tool, command[:index + 1], tasks, options


def read_json(path):
    loaded = json.loads(path.read_text())
    if not isinstance(loaded, dict):
        raise ValueError("expected an object")
    return loaded


def safe_script(script, directory, settings, root):
    """A package task must be a single known heavy executable, never a shell program."""
    words = shlex.split(script)
    if not words or re.search(r"[;&|<>`$\n\r]", script):
        return False
    name = words[0]
    kind = {"tsc": "tsc", "eslint": "eslint", "vitest": "vitest"}.get(name)
    if kind is None or kind in settings.get("local_only", []):
        return False
    if kind == "vitest" and words[1:2] != ["run"] and "--run" not in words[1:]:
        return False
    # Resolve the same executable as the package manager, without running a lifecycle hook.
    executable = directory / "node_modules/.bin" / name
    parent = directory
    while not executable.is_file() and parent != root:
        parent = parent.parent
        executable = parent / "node_modules/.bin" / name
    return executable.is_file() and not unsafe_to_route(
        kind, [str(executable), *words[1:]], cwd=directory)


def safe_orchestration(plan, root, settings):
    """Prove a conservative superset of tasks, including dependencies and hooks."""
    tool, launcher, tasks, options = plan
    if any(TASK_KINDS[task] in settings.get("local_only", []) for task in tasks):
        return False
    if Path.cwd() != root:
        return False
    try:
        listed = subprocess.run(["git", "ls-files", "-z"], cwd=root,
                                capture_output=True, check=True, timeout=30).stdout
        packages = {}
        for raw in listed.split(b"\0"):
            path = Path(os.fsdecode(raw))
            if path.name != "package.json":
                continue
            directory = root / path.parent
            packages[directory] = read_json(root / path)
        if not packages:
            return False
        if tool == "pnpm":
            for setting, allowed in (
                    ("include-workspace-root", ("false", "undefined")),
                    ("filter", ("undefined",)),
                    ("filter-prod", ("undefined",)),
                    ("workspace-packages", ("undefined",)),
                    ("ignore-workspace", ("false", "undefined")),
                    ("legacy-dir-filtering", ("false", "undefined")),
                    ("test-pattern", ("undefined",)),
                    ("changed-files-ignore-pattern", ("undefined",)),
                    ("resume-from", ("undefined",)),
                    ("link-workspace-packages", ("false", "undefined")),
                    ("shared-workspace-lockfile", ("true", "undefined"))):
                effective = subprocess.run(
                    [*launcher, "config", "get", setting, "--location=project"], cwd=root,
                    capture_output=True, text=True, check=True, timeout=30,
                    env=dict(os.environ, FM_BUILD_LOCK_BYPASS="1"))
                if effective.stdout.strip() not in allowed:
                    return False
            query = [*launcher, "--recursive"]
            for key in ("--filter", "-F"):
                for value in options.get(key, []):
                    query += [key, value]
            query += ["list", "--depth", "-1", "--json"]
            shown = subprocess.run(query, cwd=root, capture_output=True, text=True,
                                   check=True, timeout=60,
                                   env=dict(os.environ, FM_BUILD_LOCK_BYPASS="1"))
            selected = json.loads(shown.stdout)
            directories = [Path(package["path"]).resolve() for package in selected]
            if not options.get("--filter") and not options.get("-F"):
                directories = [directory for directory in directories if directory != root]
            definitions = {}
        elif tool == "turbo":
            shown = subprocess.run([*launcher, *tasks, "--dry=json"], cwd=root,
                                   capture_output=True, text=True, check=True, timeout=60,
                                   env=dict(os.environ, FM_BUILD_LOCK_BYPASS="1"))
            graph = json.loads(shown.stdout)["tasks"]
            if not graph:
                return False
            count = 0
            for task in graph:
                definition = task["resolvedTaskDefinition"]
                if definition.get("outputs") or definition.get("persistent") or \
                        definition.get("with") or \
                        (definition.get("cache") is not False and "--no-cache" not in options):
                    return False
                directory = (root / task["directory"]).resolve()
                package = packages[directory]
                name = task["task"]
                scripts = package.get("scripts", {})
                if scripts.get("pre" + name) or scripts.get("post" + name):
                    return False
                if task.get("command") not in ("<NONEXISTENT>", None, ""):
                    if task["command"] != scripts.get(name) or not safe_script(
                            task["command"], directory, settings, root):
                        return False
                    count += 1
            return count > 0
        else:
            nx = read_json(root / "nx.json") if (root / "nx.json").exists() else {}
            if any(nx.get(key) for key in ("plugins", "tasksRunnerOptions", "sync", "extends",
                                           "namedInputs")):
                return False
            if tool == "lerna":
                lerna = read_json(root / "lerna.json")
                if lerna.get("command") or lerna.get("useNx") is False:
                    return False
            definitions = nx.get("targetDefaults", {})
            if any(name not in TASK_KINDS for name in definitions):
                return False
            directories = [directory for directory in packages
                           if tool == "nx" or directory != root]
            if (root / "workspace.json").exists() or (root / "angular.json").exists():
                return False
            if any(Path(os.fsdecode(raw)).name == "project.json" and
                   root / Path(os.fsdecode(raw)).parent not in packages
                   for raw in listed.split(b"\0") if raw):
                return False
        visited = set()
        pending = list(tasks)
        count = 0
        while pending:
            name = pending.pop()
            if name in visited:
                continue
            visited.add(name)
            default = definitions.get(name, {})
            for directory in directories:
                package = packages[directory]
                scripts = package.get("scripts", {})
                target = {}
                if tool != "pnpm":
                    package_nx = package.get("nx", {})
                    if package_nx.get("namedInputs"):
                        return False
                    layers = [default, package_nx.get("targets", {}).get(name, {})]
                    project = directory / "project.json"
                    if project.exists():
                        project_config = read_json(project)
                        if project_config.get("namedInputs"):
                            return False
                        layers.append(project_config.get("targets", {}).get(name, {}))
                    for layer in layers:
                        if layer.get("inputs"):
                            return False
                        if "options" in target and "options" in layer:
                            return False
                        target.update(layer)
                if set(target) - {"executor", "options", "outputs", "cache", "dependsOn",
                                  "inputs", "metadata", "parallelism"}:
                    return False
                script = scripts.get(name)
                script_directory = directory
                if target.get("executor") == "nx:run-commands":
                    script_directory = root
                    script = target.get("options", {}).get("command")
                    if set(target.get("options", {})) != {"command"}:
                        return False
                elif target.get("executor") not in (None, "nx:run-script"):
                    return False
                dependencies = target.get("dependsOn", [])
                if any(not isinstance(dep, str) or dep.lstrip("^") not in TASK_KINDS
                       for dep in dependencies):
                    return False
                pending += [dep.lstrip("^") for dep in dependencies]
                if tool != "pnpm" and (script or target) and (target.get("cache") is not False and
                        "--skipNxCache" not in options and "--skip-nx-cache" not in options):
                    return False
                if target.get("outputs") or target.get("configurations") or \
                        target.get("defaultConfiguration") or target.get("syncGenerators") or \
                        target.get("continuous") or target.get("options") and \
                        target.get("executor") != "nx:run-commands":
                    return False
                if not script:
                    continue
                if scripts.get("pre" + name) or scripts.get("post" + name) or \
                        not safe_script(script, script_directory, settings, root):
                    return False
                count += 1
        return count > 0
    except (OSError, ValueError, KeyError, TypeError, AttributeError, subprocess.SubprocessError):
        return False


def orchestrated(command=None):
    """The first orchestrator among this process's ancestors, or None."""
    pid = os.getppid()
    first = True
    while pid > 1:
        try:
            argv = [os.fsdecode(word) for word in
                    Path("/proc/%d/cmdline" % pid).read_bytes().split(b"\0") if word]
            stat = Path("/proc/%d/stat" % pid).read_text()
            pid = int(stat[stat.rindex(")") + 2:].split()[1])
        except (OSError, ValueError, IndexError):
            return None
        if first and command and command[1:] == argv[1:]:
            first = False
            continue
        first = False
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
                  if word in ("-r", "--recursive", "-F") or word.startswith("--filter")
                  or word.startswith("-F")]
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
    if kind == "orchestrator":
        script.append("export FM_HEAVY_ORCHESTRATOR=remote FM_BUILD_LOCK_BYPASS=1 NX_DAEMON=false")
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
    if kind in ("vitest", "orchestrator") and result["remote_exit"] != 0:
        if SNAPSHOT_UNWRITTEN.search(log):
            return local("Boat's vitest failed on a snapshot it may not write under CI; "
                         "discarded remote stdout", command)
    sys.stdout.buffer.write(finished.stdout)
    sys.stdout.buffer.flush()
    return result["remote_exit"]


def route(kind, command):
    if kind not in (*KINDS, "orchestrator"):
        raise Unreadable("unknown heavy kind %r; known: %s" % (kind, ", ".join(KINDS)))
    if os.environ.get("FM_HEAVY_ORCHESTRATOR") or os.environ.get("FM_BUILD_LOCK_HELD"):
        return local("", command)
    plan = None
    if kind == "orchestrator":
        plan = orchestration(command)
        os.environ["FM_HEAVY_ORCHESTRATOR"] = "local"
    if not os.environ.get("FM_TASK_ID"):
        if kind == "orchestrator":
            os.execvp(command[0], command)
        return local("", command)
    loaded = record()
    if loaded is None:
        if kind == "orchestrator":
            os.execvp(command[0], command)
        return local("", command)
    root = worktree()
    if root is None:
        if kind == "orchestrator":
            os.execvp(command[0], command)
        return local("", command)
    settings = loaded["projects"].get(root.name)
    if not isinstance(settings, dict) or not settings.get("bootstrap"):
        if kind == "orchestrator":
            os.execvp(command[0], command)
        return local("", command)
    if kind in (settings.get("local_only") or []):
        return local("%s is declared local-only for this project" % kind, command)
    ancestor = orchestrated(command if kind == "orchestrator" else None)
    if ancestor:
        return local("%s runs under %s, so only that top-level command could go to Boat"
                     % (kind, ancestor), command)
    tree = staged_or_untracked(root)
    if tree is None:
        return local("the worktree's uncommitted files could not be listed", command)
    if tree[1]:
        return local("untracked file %s would not travel to Boat" % tree[1], command)
    if (kind == "orchestrator" and (plan is None or not safe_orchestration(plan, root, settings))) \
            or (kind != "orchestrator" and unsafe_to_route(kind, command)):
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
