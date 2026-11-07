#!/usr/bin/env python3
"""Free OpenCode sensitivity boundary.

This file is the single owner of three facts: which paths are sensitive,
which configured OpenCode model ids are free, and which environment names
carry Doppler, Supabase, cloud, or GitHub-write tokens.

bin/fm-dispatch-resolve.sh applies the deny after classification.
bin/fm-spawn.sh confines only a launch whose resolved model is free.
A paid OpenCode model and every other harness keep their environment and
their read access. A routine path may still resolve to a free model.

`mech` is the handoff a worker runs for a rename, a format, boilerplate,
or test scaffolding. It launches only a documented free OpenCode model
under this same scrub and read block in a scratch copy of the caller's
current tree, prints only the model's change against that copy, and never
touches the caller's worktree. The worker reviews that diff before applying it.

The read block is a seccomp user notifier in the parent. Segment classes
apply inside the task worktree, the directory confine starts in, so toolchain
files elsewhere stay readable. Env and Doppler file names, secrets files,
and token stores apply anywhere. The child cannot
complete open, stat, or exec of a blocked path, including by a raw syscall.
The parent opens an allowed file itself and installs that fd, so a symlink
swap after the check cannot hand the child a secret inode.
"""

from __future__ import annotations

import ctypes
import errno
import json
import os
import platform
import select
import shutil
import signal
import socket
import stat
import struct
import subprocess
import sys
import tempfile
from ctypes import c_uint16, c_uint32, c_uint64, c_ulong

AT_FDCWD = -100
SECCOMP_SET_MODE_FILTER = 1
SECCOMP_FILTER_FLAG_NEW_LISTENER = 8
SECCOMP_GET_NOTIF_SIZES = 3
SECCOMP_RET_ALLOW = 0x7FFF0000
SECCOMP_RET_USER_NOTIF = 0x7FC00000
SECCOMP_RET_ERRNO = 0x00050000
SECCOMP_ADDFD_FLAG_SEND = 1 << 1
SECCOMP_USER_NOTIF_FLAG_CONTINUE = 1
PR_SET_NO_NEW_PRIVS = 38
O_CLOEXEC = 0o2000000
O_CREAT = 0o100
O_DIRECTORY = 0o200000

BPF_LD_W_ABS = 0x20
BPF_JMP_JEQ_K = 0x15
BPF_RET_K = 0x06

ENV_NAMES = {
    "env.local",
    "env.development",
    "env.production",
    "env.staging",
    "env.test",
}
DOPPLER_NAMES = {
    "doppler.yaml",
    "doppler.yml",
    ".doppler.yaml",
    ".doppler.yml",
}
CI_NAMES = {
    ".gitlab-ci.yml",
    ".gitlab-ci.yaml",
    "jenkinsfile",
    "azure-pipelines.yml",
    "azure-pipelines.yaml",
    "bitbucket-pipelines.yml",
}
SECRET_NAMES = {
    "secrets",
    ".secrets",
    "secrets.json",
    "secrets.yaml",
    "secrets.yml",
    "secrets.env",
    "secrets.toml",
    "credentials.json",
    "service-account.json",
    "serviceaccount.json",
    ".git-credentials",
    ".netrc",
}
# Home-relative token stores that would put a scrubbed token back on disk.
TOKEN_STORES = (
    ".doppler",
    ".doppler.yaml",
    ".supabase",
    ".aws",
    ".azure",
    ".config/gcloud",
    ".config/gh",
    ".git-credentials",
    ".netrc",
    ".config/doppler",
)
SEGMENTS = {
    "auth": "auth",
    "authentication": "auth",
    "oauth": "auth",
    "payments": "payments",
    "payment": "payments",
    "billing": "payments",
    "stripe": "payments",
    "doppler": "doppler",
    ".doppler": "doppler",
    "migrations": "migration",
    "migrate": "migration",
    "migration": "migration",
    "alembic": "migration",
    "flyway": "migration",
    "infra": "infra",
    "terraform": "infra",
    "k8s": "infra",
    "kubernetes": "infra",
    "helm": "infra",
    "deploy": "infra",
    "deployment": "infra",
    "argocd": "infra",
    "cloudformation": "infra",
}
FILE_STEMS = {
    "auth": "auth",
    "oauth": "auth",
    "payment": "payments",
    "payments": "payments",
    "billing": "payments",
    "stripe": "payments",
}


def parts_of(path: str) -> list[str]:
    text = path.strip().replace("\\", "/")
    while "//" in text:
        text = text.replace("//", "/")
    if text.startswith("./"):
        text = text[2:]
    text = os.path.normpath(text) if text else ""
    if text in ("", "."):
        return []
    text = text.rstrip("/")
    return [seg.lower() for seg in text.split("/") if seg not in ("", ".")]


def sensitive_class(path: str) -> str | None:
    """Return the sensitive class, or None when the path may use a free model."""
    parts = parts_of(path)
    if not parts:
        return None
    base = parts[-1]
    if base == ".env" or base.startswith(".env.") or base.endswith(".env") or base in ENV_NAMES:
        return "env"
    if base in DOPPLER_NAMES:
        return "doppler"
    if base in CI_NAMES or ".circleci" in parts or ".buildkite" in parts:
        return "ci"
    for index, seg in enumerate(parts[:-1]):
        if seg == ".github" and parts[index + 1] == "workflows":
            return "ci"
    for seg in parts[:-1]:
        kind = SEGMENTS.get(seg)
        if kind:
            return kind
    if base.endswith(".sql") and "migration" in base:
        return "migration"
    if (
        base.endswith(".tf")
        or base.endswith(".tfvars")
        or base in {"vercel.json", "dockerfile", "fly.toml", "cdk.json", "chart.yaml", "chart.yml"}
        or base in {"serverless.yml", "serverless.yaml", "render.yaml", "render.yml", "pulumi.yaml", "pulumi.yml"}
        or (base.startswith("docker-compose") and base.endswith((".yml", ".yaml")))
        or ("deploy" in base and base.endswith(".sh"))
        or base in {"values.yaml", "values.yml"}
        or (base.startswith("values-") and base.endswith((".yaml", ".yml")))
        or base.endswith((".k8s.yaml", ".k8s.yml"))
        or ("deployment" in base and base.endswith((".yaml", ".yml")))
        or ("ingress" in base and base.endswith((".yaml", ".yml")))
    ):
        return "infra"
    stem = base.split(".", 1)[0]
    return FILE_STEMS.get(stem)


def _under(path: str, root: str) -> bool:
    path = os.path.normpath(path)
    root = os.path.normpath(root)
    return path == root or path.startswith(root + os.sep)


def secrets_path(path: str, home: str) -> bool:
    parts = parts_of(path)
    if not parts:
        return False
    if ".secrets" in parts or parts[-1] in SECRET_NAMES:
        return True
    if not home:
        return False
    home = os.path.normpath(home)
    candidate = path if os.path.isabs(path) else os.path.join(home, path)
    for rel in TOKEN_STORES:
        if _under(os.path.normpath(candidate), os.path.join(home, rel)):
            return True
    return _under(os.path.normpath(candidate), os.path.join(home, ".secrets"))


PROC_PRIVATE = {"environ", "mem"}


def proc_private(path: str) -> bool:
    parts = os.path.normpath(path).split("/")
    return len(parts) > 3 and parts[1] == "proc" and parts[-1] in PROC_PRIVATE


def path_blocked(path: str, home: str, root: str) -> bool:
    if sensitive_class(os.path.basename(path)) in ("env", "doppler"):
        return True
    if _under(path, root) and sensitive_class(os.path.relpath(path, root)) is not None:
        return True
    return secrets_path(path, home) or proc_private(path)


def is_free_opencode(harness: str | None, model: str | None) -> bool:
    """A free OpenCode model is an opencode launch on a documented free model.

    That is an id whose final segment is `free` or ends in `-free` or `:free`
    (OpenCode Zen and OpenRouter free ids, such as GLM and DeepSeek ones),
    `big-pickle`, or no model at all, since opencode's own default may be
    free. Another harness stays paid even when its id ends in `-free`.
    """
    if harness != "opencode":
        return False
    if not model or model == "default":
        return True
    leaf = model.split("/")[-1].lower()
    return leaf in ("free", "big-pickle") or leaf.endswith(("-free", ":free"))


def token_name(name: str) -> bool:
    """True when the variable is a Doppler, Supabase, cloud, or GitHub-write token."""
    if name == "DOPPLER_TOKEN" or (name.startswith("DOPPLER_") and "TOKEN" in name):
        return True
    if name.startswith("SUPABASE_") and any(part in name for part in ("KEY", "TOKEN", "SECRET")):
        return True
    if name in {
        "AWS_ACCESS_KEY_ID",
        "AWS_SECRET_ACCESS_KEY",
        "AWS_SESSION_TOKEN",
        "AWS_SECURITY_TOKEN",
        "GOOGLE_APPLICATION_CREDENTIALS",
        "GOOGLE_OAUTH_ACCESS_TOKEN",
        "CLOUDSDK_AUTH_ACCESS_TOKEN",
        "AZURE_CLIENT_SECRET",
        "AZURE_CLIENT_CERTIFICATE_PASSWORD",
        "ARM_CLIENT_SECRET",
        "ARM_CLIENT_CERTIFICATE_PASSWORD",
        "DIGITALOCEAN_ACCESS_TOKEN",
        "DIGITALOCEAN_TOKEN",
        "GH_TOKEN",
        "GITHUB_TOKEN",
        "GH_ENTERPRISE_TOKEN",
        "GITHUB_ENTERPRISE_TOKEN",
        "GITHUB_PAT",
        "GH_PAT",
    }:
        return True
    return False


def target_paths(brief: str) -> list[str]:
    found = []
    for line in brief.splitlines():
        if line.startswith("Target paths:"):
            found.extend(line[len("Target paths:") :].split())
    return found


def brief_sensitive(path: str) -> bool:
    with open(path, encoding="utf-8") as handle:
        text = handle.read()
    return any(sensitive_class(item) is not None for item in target_paths(text))


def apply_resolution(payload: dict) -> bool:
    candidates = payload.get("candidates") or []
    denied = False
    for candidate in candidates:
        profile = candidate.get("profile") or {}
        if is_free_opencode(profile.get("harness"), profile.get("model")):
            candidate["eligible"] = False
            candidate.pop("unranked", None)
            candidate["reason"] = "sensitive target path denies a free OpenCode model"
            denied = True
    if not denied:
        return False
    chosen = payload.get("chosen") or {}
    chosen_profile = chosen.get("profile") or {}
    if not is_free_opencode(chosen_profile.get("harness"), chosen_profile.get("model")):
        return True
    eligible = [
        item
        for item in candidates
        if item.get("eligible") and not item.get("unranked") and isinstance(item.get("spendPriority"), (int, float)) and not isinstance(item.get("spendPriority"), bool)
    ]
    if not eligible:
        payload["status"] = "escalate"
        payload["reason"] = "sensitive target path denies a free OpenCode model and no other rankable candidate remains"
        payload.pop("chosen", None)
        return True
    best = max(item.get("spendPriority") for item in eligible)
    tops = [item for item in eligible if item.get("spendPriority") == best]
    if len(tops) > 1:
        payload["status"] = "escalate"
        payload["reason"] = "genuine spendPriority tie"
        payload.pop("chosen", None)
        return True
    payload["status"] = "clear"
    payload.pop("reason", None)
    payload["chosen"] = tops[0]
    return True


def arch_tables():
    machine = platform.machine()
    if machine in ("aarch64", "arm64"):
        return 0xC00000B7, 277, 167, {
            "openat": 56,
            "openat2": 437,
            "execve": 221,
            "execveat": 281,
            "statx": 291,
            "newfstatat": 79,
            "faccessat": 48,
            "faccessat2": 439,
            "readlinkat": 78,
            "name_to_handle_at": 264,
        }, {
            "io_uring_setup": 425,
            "io_uring_enter": 426,
            "io_uring_register": 427,
        }, None
    if machine in ("x86_64", "amd64"):
        return 0xC000003E, 317, 157, {
            "open": 2,
            "openat": 257,
            "openat2": 437,
            "execve": 59,
            "execveat": 281,
            "statx": 332,
            "newfstatat": 262,
            "faccessat": 269,
            "faccessat2": 439,
            "readlinkat": 267,
            "name_to_handle_at": 303,
        }, {
            "io_uring_setup": 425,
            "io_uring_enter": 426,
            "io_uring_register": 427,
        }, 2
    return None


def _ioc(direction: int, number: int, size: int) -> int:
    return (direction << 30) | (ord("!") << 8) | number | (size << 16)


class NotifSizes(ctypes.Structure):
    _fields_ = [
        ("seccomp_notif", c_uint16),
        ("seccomp_notif_resp", c_uint16),
        ("seccomp_data", c_uint16),
    ]


class SockFilter(ctypes.Structure):
    _fields_ = [
        ("code", c_uint16),
        ("jt", ctypes.c_uint8),
        ("jf", ctypes.c_uint8),
        ("k", c_uint32),
    ]


class SockFprog(ctypes.Structure):
    _fields_ = [("len", c_uint16), ("filter", ctypes.POINTER(SockFilter))]


class IOVec(ctypes.Structure):
    _fields_ = [("base", ctypes.c_void_p), ("len", ctypes.c_size_t)]


def build_filter(audit_arch: int, notify: set[int], deny: set[int]) -> bytes:
    words = []

    def stmt(code: int, k: int) -> None:
        words.append(struct.pack("<HBBI", code, 0, 0, k & 0xFFFFFFFF))

    def jump(k: int, jt: int, jf: int) -> None:
        words.append(struct.pack("<HBBI", BPF_JMP_JEQ_K, jt, jf, k & 0xFFFFFFFF))

    stmt(BPF_LD_W_ABS, 4)
    jump(audit_arch, 1, 0)
    stmt(BPF_RET_K, SECCOMP_RET_ERRNO | errno.EPERM)
    stmt(BPF_LD_W_ABS, 0)
    for number in sorted(deny):
        jump(number, 0, 1)
        stmt(BPF_RET_K, SECCOMP_RET_ERRNO | errno.EPERM)
    for number in sorted(notify):
        jump(number, 0, 1)
        stmt(BPF_RET_K, SECCOMP_RET_USER_NOTIF)
    stmt(BPF_RET_K, SECCOMP_RET_ALLOW)
    return b"".join(words)


def install_filter(blob: bytes, sys_seccomp: int, sys_prctl: int) -> int:
    libc = ctypes.CDLL(None, use_errno=True)
    count = len(blob) // 8
    filters = (SockFilter * count).from_buffer_copy(blob)
    prog = SockFprog(count, filters)
    if libc.syscall(sys_prctl, PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) != 0:
        raise OSError(ctypes.get_errno(), "prctl")
    fd = libc.syscall(sys_seccomp, SECCOMP_SET_MODE_FILTER, SECCOMP_FILTER_FLAG_NEW_LISTENER, ctypes.byref(prog))
    if fd < 0:
        raise OSError(ctypes.get_errno(), "seccomp")
    return fd


def send_fd(sock: socket.socket, fd: int) -> None:
    sock.sendmsg([b"x"], [(socket.SOL_SOCKET, socket.SCM_RIGHTS, struct.pack("i", fd))])


def recv_fd(sock: socket.socket) -> int:
    _, ancdata, _, _ = sock.recvmsg(1, socket.CMSG_LEN(4))
    for level, kind, data in ancdata:
        if level == socket.SOL_SOCKET and kind == socket.SCM_RIGHTS:
            return struct.unpack("i", data[:4])[0]
    raise OSError(errno.EIO, "listener fd missing")


def read_cstr(pid: int, address: int) -> str | None:
    if not address:
        return None
    libc = ctypes.CDLL(None, use_errno=True)
    buf = ctypes.create_string_buffer(4096)
    local = IOVec(ctypes.addressof(buf), 4096)
    remote = IOVec(address, 4096)
    got = libc.process_vm_readv(pid, ctypes.byref(local), 1, ctypes.byref(remote), 1, 0)
    if got < 0:
        return None
    raw = buf.raw[:got]
    end = raw.find(b"\0")
    if end < 0:
        return None
    return raw[:end].decode("utf-8", "surrogateescape")


def as_i64(value: int) -> int:
    if value >= 2**63:
        return value - 2**64
    return value


def resolve_path(pid: int, dirfd: int, path: str) -> tuple[str, str]:
    if path.startswith("/"):
        lexical = path
    else:
        if dirfd == AT_FDCWD:
            base = os.readlink(f"/proc/{pid}/cwd")
        else:
            base = os.readlink(f"/proc/{pid}/fd/{dirfd}")
        lexical = os.path.join(base, path)
    lexical = os.path.normpath(lexical)
    for alias, target in (
        ("/proc/self", f"/proc/{pid}"),
        ("/proc/thread-self", f"/proc/{pid}"),
        ("/dev/fd", f"/proc/{pid}/fd"),
        ("/dev/stdin", f"/proc/{pid}/fd/0"),
        ("/dev/stdout", f"/proc/{pid}/fd/1"),
        ("/dev/stderr", f"/proc/{pid}/fd/2"),
    ):
        if lexical == alias or lexical.startswith(alias + "/"):
            lexical = target + lexical[len(alias) :]
            break
    try:
        resolved = os.path.realpath(lexical)
    except OSError:
        resolved = lexical
    return lexical, resolved


def ioctl(fd: int, request: int, buffer) -> int:
    libc = ctypes.CDLL(None, use_errno=True)
    rc = libc.ioctl(fd, c_ulong(request), buffer)
    if rc < 0:
        err = ctypes.get_errno()
        raise OSError(err, os.strerror(err))
    return rc


def special_file(*paths: str) -> bool:
    for path in paths:
        try:
            st_mode = os.stat(path).st_mode
        except FileNotFoundError:
            continue
        if not (stat.S_ISREG(st_mode) or stat.S_ISDIR(st_mode)):
            return True
    return False


def supervise(notify_fd: int, child: int, home: str, root: str, names: dict[str, int], notif_size: int) -> None:
    recv_req = _ioc(3, 0, notif_size)
    send_req = _ioc(3, 1, 24)
    valid_req = _ioc(1, 2, 8)
    addfd_req = _ioc(1, 3, 24)
    # glibc opens through openat. openat2 is denied below: its flag argument
    # is a struct pointer, so the parent cannot install a checked fd for it.
    open_numbers = {names[name] for name in ("openat", "open") if name in names}
    path_at = {names[name] for name in ("openat", "openat2", "statx", "newfstatat", "faccessat", "faccessat2", "readlinkat", "name_to_handle_at") if name in names}
    poller = select.poll()
    poller.register(notify_fd, select.POLLIN)
    while True:
        # POLLHUP without POLLIN means every task under the filter has exited.
        # RECV alone cannot tell that apart from one cancelled notification,
        # which also returns ENOENT when its task is signalled or dies.
        events = 0
        for _fd, revents in poller.poll():
            events |= revents
        if not events & select.POLLIN:
            if events & (select.POLLHUP | select.POLLERR | select.POLLNVAL):
                break
            continue
        buf = ctypes.create_string_buffer(notif_size)
        try:
            ioctl(notify_fd, recv_req, buf)
        except OSError as exc:
            if exc.errno in (errno.ENOENT, errno.EINTR):
                continue
            raise
        ident, pid, _flags = struct.unpack_from("QII", buf.raw, 0)
        nr = struct.unpack_from("I", buf.raw, 16)[0]
        args = struct.unpack_from("6Q", buf.raw, 32)
        try:
            ioctl(notify_fd, valid_req, struct.pack("Q", ident))
        except OSError:
            continue
        allow_fd = None
        remote_flags = 0
        error = errno.EACCES
        continue_call = False
        try:
            if nr in path_at or nr == names.get("open") or nr in (names.get("execve"), names.get("execveat")):
                if nr == names.get("execve") or nr == names.get("open"):
                    raw = read_cstr(pid, args[0])
                    dirfd = AT_FDCWD
                elif nr == names.get("execveat"):
                    raw = read_cstr(pid, args[1])
                    dirfd = as_i64(args[0])
                else:
                    raw = read_cstr(pid, args[1])
                    dirfd = as_i64(args[0])
                if raw is None:
                    error = errno.EFAULT
                else:
                    lexical, resolved = resolve_path(pid, dirfd, raw)
                    if nr == names.get("openat2"):
                        # openat2's flag argument is a struct pointer, so the
                        # parent cannot install an fd for it. Denying the call
                        # keeps that path from skipping the inode check.
                        error = errno.EPERM
                    elif path_blocked(lexical, home, root) or path_blocked(resolved, home, root):
                        error = errno.EACCES
                    elif nr in open_numbers:
                        flags = int(as_i64(args[2])) if nr != names.get("open") else int(as_i64(args[1]))
                        mode = 0o666
                        if flags & O_CREAT:
                            mode = int(args[3 if nr != names.get("open") else 2]) & 0o7777
                        # An O_PATH fd reads no data, and ADDFD rejects one
                        # with EBADF, so the checked call runs in the child.
                        if flags & os.O_PATH or special_file(resolved, lexical):
                            continue_call = True
                        else:
                            fd = os.open(resolved, flags | O_CLOEXEC, mode)
                            try:
                                opened = os.path.realpath(f"/proc/self/fd/{fd}")
                                if path_blocked(opened, home, root):
                                    error = errno.EACCES
                                else:
                                    allow_fd = fd
                                    fd = None
                                    remote_flags = O_CLOEXEC if flags & O_CLOEXEC else 0
                            finally:
                                if fd is not None:
                                    os.close(fd)
                    else:
                        continue_call = True
            else:
                continue_call = True
        except OSError as exc:
            error = exc.errno or errno.EIO
        if allow_fd is not None:
            try:
                ioctl(
                    notify_fd,
                    addfd_req,
                    struct.pack("QIIII", ident, SECCOMP_ADDFD_FLAG_SEND, allow_fd, 0, remote_flags),
                )
                continue
            except OSError as exc:
                # A failed install must not end supervision: answer the call
                # with the error so the loop keeps serving the worker.
                error = exc.errno or errno.EIO
            finally:
                os.close(allow_fd)
        flags_out = SECCOMP_USER_NOTIF_FLAG_CONTINUE if continue_call else 0
        # seccomp_notif_resp.error is 0 or a negative errno. A positive value
        # is rejected, and the target would otherwise observe a live fd.
        err_out = 0 if continue_call else -int(error or errno.EIO)
        resp = ctypes.create_string_buffer(struct.pack("QqiI", ident, 0, err_out, flags_out))
        try:
            ioctl(notify_fd, send_req, resp)
        except OSError:
            continue


def confine(home: str, command: list[str]) -> int:
    root = os.path.realpath(os.getcwd())
    tables = arch_tables()
    if tables is None:
        print("free-model sensitivity: this architecture cannot confine a free OpenCode model", file=sys.stderr)
        return 2
    audit, sys_seccomp, sys_prctl, names, deny_names, _open = tables
    for key in list(os.environ):
        if token_name(key):
            del os.environ[key]
    parent, child = socket.socketpair()
    pid = os.fork()
    if pid == 0:
        try:
            parent.close()
            # Python ignores SIGPIPE and SIGXFSZ, and exec keeps ignored
            # signals ignored; restore the defaults so pipelines terminate.
            signal.signal(signal.SIGPIPE, signal.SIG_DFL)
            signal.signal(signal.SIGXFSZ, signal.SIG_DFL)
            listener = install_filter(build_filter(audit, set(names.values()), set(deny_names.values())), sys_seccomp, sys_prctl)
            send_fd(child, listener)
            os.close(listener)
            child.close()
            os.execvpe(command[0], command, os.environ)
        except OSError as exc:
            print(f"free-model sensitivity: confine failed: {exc}", file=sys.stderr)
        os._exit(127)
    child.close()
    try:
        listener = recv_fd(parent)
    except OSError as exc:
        print(f"free-model sensitivity: confine failed: {exc}", file=sys.stderr)
        os.waitpid(pid, 0)
        return 2
    parent.close()
    libc = ctypes.CDLL(None, use_errno=True)
    sizes = NotifSizes()
    if libc.syscall(sys_seccomp, SECCOMP_GET_NOTIF_SIZES, 0, ctypes.byref(sizes)) != 0:
        os.close(listener)
        os.kill(pid, 9)
        os.waitpid(pid, 0)
        return 2
    try:
        supervise(listener, pid, home, root, names, sizes.seccomp_notif or 80)
    finally:
        os.close(listener)
    _pid, status = os.waitpid(pid, 0)
    if os.WIFEXITED(status):
        return os.WEXITSTATUS(status)
    if os.WIFSIGNALED(status):
        return 128 + os.WTERMSIG(status)
    return 1


class GitError(Exception):
    pass


MECH_SECONDS = 900


def git_bytes(args: list[str]) -> bytes:
    proc = subprocess.run(["git", "--no-pager", *args], capture_output=True)
    if proc.returncode != 0:
        detail = proc.stderr.decode("utf-8", "replace").strip()
        raise GitError(detail or "git " + " ".join(args) + " failed")
    return proc.stdout


def path_refused(path: str, home: str) -> str | None:
    kind = sensitive_class(path)
    if kind:
        return kind
    if secrets_path(path, home):
        return "secrets"
    return None


def mech_refusal(model: str | None, paths: list[str], prompt: str, home: str) -> str | None:
    """Why this handoff must not launch, or None when it may."""
    if not is_free_opencode("opencode", model):
        shown = model if model else ""
        return f"refusing '{shown}' because it is not a documented free OpenCode model"
    if not prompt.strip():
        return "mech needs the edit after --"
    if not paths:
        return "mech needs at least one --path"
    for path in paths:
        kind = path_refused(path, home)
        if kind:
            return f"refusing sensitive path {path} ({kind})"
    return None


def mech_command(model: str | None, paths: list[str], prompt: str) -> list[str]:
    text = (
        "Mechanical edit only: a rename, a format, boilerplate, or test scaffolding. "
        "Do not commit, push, or merge. Do not read secrets. Stop when the files are edited.\n"
        "Edit only these paths: " + ", ".join(paths) + "\n\n"
        + prompt
    )
    command = ["timeout", "--kill-after=30", str(MECH_SECONDS), "opencode", "run", "--standalone"]
    if model and model != "default":
        command.extend(["--model", model])
    command.append(text)
    return command


def seed_tree(top: str, tree: str, home: str) -> str:
    """Copy every path that differs from HEAD, staged or not, and every
    untracked file into tree, except refused paths, and return the tree id
    of that copy."""
    changed = git_bytes(["-C", top, "diff", "--name-only", "-z", "--no-renames", "HEAD"])
    untracked = git_bytes(["-C", top, "ls-files", "-z", "--others", "--exclude-standard"])
    for raw in sorted(set(changed.split(b"\0")) | set(untracked.split(b"\0"))):
        rel = os.fsdecode(raw)
        if not rel or rel.endswith("/") or path_refused(rel, home):
            continue
        source = os.path.join(top, rel)
        target = os.path.join(tree, rel)
        if os.path.isdir(source) and not os.path.islink(source):
            continue
        if os.path.isdir(target) and not os.path.islink(target):
            shutil.rmtree(target)
        elif os.path.lexists(target):
            os.remove(target)
        if os.path.islink(source):
            os.makedirs(os.path.dirname(target), exist_ok=True)
            os.symlink(os.readlink(source), target)
        elif os.path.isfile(source):
            os.makedirs(os.path.dirname(target), exist_ok=True)
            shutil.copy2(source, target)
    git_bytes(["-C", tree, "add", "-A"])
    return git_bytes(["-C", tree, "write-tree"]).decode().strip()


def collect_diff(tree: str, base: str, paths: list[str]) -> bytes:
    # Staging everything also captures new files and anything the model committed.
    git_bytes(["-C", tree, "add", "-A"])
    return git_bytes(["-C", tree, "diff", "--cached", "--binary", base, "--", *paths])


def confine_quiet(home: str, command: list[str], log_path: str) -> int:
    saved_out = os.dup(1)
    saved_err = os.dup(2)
    try:
        fd = os.open(log_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        try:
            os.dup2(fd, 1)
            os.dup2(fd, 2)
        finally:
            os.close(fd)
        return confine(home, command)
    finally:
        os.dup2(saved_out, 1)
        os.dup2(saved_err, 2)
        os.close(saved_out)
        os.close(saved_err)


def parse_mech(argv: list[str]) -> tuple[str | None, list[str], str] | None:
    if "--" not in argv:
        return None
    split = argv.index("--")
    model = None
    paths: list[str] = []
    index = 0
    flags = argv[:split]
    while index < len(flags):
        flag = flags[index]
        if flag in ("--model", "--path"):
            if index + 1 >= len(flags):
                return None
            value = flags[index + 1]
            if flag == "--model":
                model = value
            else:
                paths.append(value)
            index += 2
            continue
        return None
    return model, paths, " ".join(argv[split + 1 :]).strip()


def mech(argv: list[str]) -> int:
    parsed = parse_mech(argv)
    if parsed is None:
        usage()
        return 2
    model, paths, prompt = parsed
    home = os.environ.get("HOME", "")
    reason = mech_refusal(model, paths, prompt, home)
    if reason:
        print(f"free-model sensitivity: {reason}", file=sys.stderr)
        return 1 if reason.startswith("refusing") else 2
    if not home:
        print("free-model sensitivity: mech needs HOME", file=sys.stderr)
        return 2
    if shutil.which("opencode") is None:
        print("free-model sensitivity: opencode is not on PATH", file=sys.stderr)
        return 2
    try:
        top = git_bytes(["rev-parse", "--show-toplevel"]).decode().strip()
        head = git_bytes(["rev-parse", "HEAD"]).decode().strip()
    except GitError as exc:
        print(f"free-model sensitivity: mech must run inside a git worktree ({exc})", file=sys.stderr)
        return 2
    scratch = tempfile.mkdtemp(prefix="fm-mech-")
    tree = os.path.join(scratch, "tree")
    log_path = os.path.join(scratch, "fm-mech.log")
    caller = os.getcwd()
    code = 1
    diff = b""
    try:
        git_bytes(["worktree", "add", "--detach", "--quiet", tree, head])
    except GitError as exc:
        shutil.rmtree(scratch, ignore_errors=True)
        print(f"free-model sensitivity: could not create a scratch worktree: {exc}", file=sys.stderr)
        return 2
    try:
        base = seed_tree(top, tree, home)
        os.chdir(tree)
        os.environ["OPENCODE_CONFIG_CONTENT"] = '{"permission":{"*":"allow"}}'
        code = confine_quiet(home, mech_command(model, paths, prompt), log_path)
        diff = collect_diff(tree, base, paths)
    except (GitError, OSError) as exc:
        print(f"free-model sensitivity: {exc}", file=sys.stderr)
        code = 1
    finally:
        os.chdir(caller)
        try:
            git_bytes(["worktree", "remove", "--force", tree])
        except GitError as exc:
            print(f"free-model sensitivity: could not remove the scratch worktree: {exc}", file=sys.stderr)
            code = 1
        if code != 0 and os.path.exists(log_path):
            with open(log_path, "rb") as handle:
                sys.stderr.buffer.write(handle.read(4000))
        shutil.rmtree(scratch, ignore_errors=True)
    sys.stdout.buffer.write(diff)
    return code


def usage() -> None:
    print(
        "usage: fm-free-model-sensitivity.sh class <path>\n"
        "       fm-free-model-sensitivity.sh free-model --harness <h> --model <id>\n"
        "       fm-free-model-sensitivity.sh token-name <NAME>\n"
        "       fm-free-model-sensitivity.sh brief-sensitive --brief <file>\n"
        "       fm-free-model-sensitivity.sh apply-resolution --brief <file>\n"
        "       fm-free-model-sensitivity.sh confine --home <dir> -- <command>...\n"
        "       fm-free-model-sensitivity.sh mech [--model <id>] --path <path> [--path <path>...] -- <edit>\n"
        "\n"
        "mech hands a rename, a format, boilerplate, or test scaffolding to a free OpenCode model.\n"
        "  --model must be a documented free OpenCode id (last segment free, big-pickle, or ending\n"
        "  -free or :free) or be omitted; any other id is refused.\n"
        "  Each --path is relative to the repository top level, and the diff carries only\n"
        "  changes under those paths. A --path in the ci, migrations, infra, auth, payments,\n"
        "  env, or doppler class, or a\n"
        "  secrets file or token store, is refused.\n"
        "  The model runs confined, with tokens scrubbed, on a scratch copy of your current tree\n"
        "  that leaves out refused paths. mech prints only the model's change as a diff against\n"
        "  that copy and never touches your worktree; review it, then git apply it at the top level.",
        file=sys.stderr,
    )


def flag_value(argv: list[str], flag: str) -> str:
    if flag not in argv:
        raise SystemExit(2)
    index = argv.index(flag)
    if index + 1 >= len(argv):
        raise SystemExit(2)
    return argv[index + 1]


def main(argv: list[str]) -> int:
    if len(argv) < 2 or argv[1] in ("-h", "--help"):
        usage()
        return 0 if len(argv) > 1 and argv[1] in ("-h", "--help") else 2
    cmd = argv[1]
    if cmd == "class":
        if len(argv) != 3:
            usage()
            return 2
        kind = sensitive_class(argv[2])
        if kind is None:
            return 1
        print(kind)
        return 0
    if cmd == "free-model":
        try:
            harness = flag_value(argv[2:], "--harness")
            model = flag_value(argv[2:], "--model")
        except SystemExit:
            usage()
            return 2
        return 0 if is_free_opencode(harness, model) else 1
    if cmd == "token-name":
        if len(argv) != 3:
            usage()
            return 2
        return 0 if token_name(argv[2]) else 1
    if cmd == "brief-sensitive":
        try:
            brief = flag_value(argv[2:], "--brief")
        except SystemExit:
            usage()
            return 2
        try:
            return 0 if brief_sensitive(brief) else 1
        except OSError as exc:
            print(f"free-model sensitivity: {exc}", file=sys.stderr)
            return 2
    if cmd == "apply-resolution":
        try:
            brief = flag_value(argv[2:], "--brief")
        except SystemExit:
            usage()
            return 2
        raw = sys.stdin.buffer.read()
        try:
            if not brief_sensitive(brief):
                sys.stdout.buffer.write(raw)
                return 0
            payload = json.loads(raw)
        except (OSError, json.JSONDecodeError) as exc:
            print(f"free-model sensitivity: {exc}", file=sys.stderr)
            return 2
        if not apply_resolution(payload):
            sys.stdout.buffer.write(raw)
            return 0
        json.dump(payload, sys.stdout)
        sys.stdout.write("\n")
        return 0
    if cmd == "confine":
        if "--" not in argv:
            usage()
            return 2
        split = argv.index("--")
        command = argv[split + 1 :]
        if not command:
            usage()
            return 2
        try:
            home = flag_value(argv[2:split], "--home")
        except SystemExit:
            home = os.environ.get("HOME", "")
        if not home:
            print("free-model sensitivity: confine needs --home", file=sys.stderr)
            return 2
        return confine(home, command)
    if cmd == "mech":
        return mech(argv[2:])
    usage()
    return 2


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv))
    except BrokenPipeError:
        sys.exit(0)
