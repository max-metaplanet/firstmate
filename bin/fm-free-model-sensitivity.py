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

On Linux the read block is a seccomp user notifier in the parent. On macOS it
is a sandbox-exec profile that denies the same classes of path (see
darwin_profile), and a launch refuses when /usr/bin/sandbox-exec is missing or
the profile does not apply. No platform ever runs the model unconfined.
The same confine denies the network on both platforms except loopback TCP.
Per-host egress is not enforceable (seccomp sees addresses, sandbox-exec
matches addresses and ports), so the model call goes through ModelProxy, a
loopback forwarder in the unconfined parent that enforces the hostnames; see
docs/configuration.md for the stated guarantees.
The home-relative blocked set (HOME_BLOCKED, HOME_KEY_SUFFIXES, SYSTEM_BLOCKED)
is one definition read by both platforms.
Segment classes
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
import hmac
import http.client
import http.server
import json
import os
import platform
import re
import secrets
import select
import shutil
import signal
import socket
import stat
import struct
import subprocess
import sys
import tempfile
import threading
import urllib.parse
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
BPF_JMP_JGE_K = 0x35
BPF_JMP_JSET_K = 0x45
BPF_ALU_AND_K = 0x54
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
# The home-relative blocked set. secrets_path (the Linux notifier) and
# darwin_block_patterns (the macOS profile) both read these three definitions,
# so the platforms cannot drift. A key file is blocked by suffix anywhere under
# the home, never outside it.
HOME_BLOCKED = (
    ".doppler",
    ".doppler.yaml",
    ".supabase",
    ".aws",
    ".azure",
    ".config/gcloud",
    ".config/gh",
    ".config/doppler",
    ".config/opencode/service.json",
    ".ssh",
    ".gnupg",
    ".netrc",
    ".git-credentials",
    ".npmrc",
    ".docker/config.json",
    "Library/Keychains",
    ".local/share/keyrings",
)
HOME_KEY_SUFFIXES = (".pem", ".key")
SYSTEM_BLOCKED = ("/Library/Keychains", "/System/Library/Keychains")
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


def home_roots(home: str) -> set[str]:
    if not home:
        return set()
    return {os.path.normpath(home), os.path.realpath(home)}


def secrets_path(path: str, home: str) -> bool:
    parts = parts_of(path)
    if not parts:
        return False
    if ".secrets" in parts or parts[-1] in SECRET_NAMES:
        return True
    candidate = os.path.normpath(path if os.path.isabs(path) or not home else os.path.join(home, path))
    if any(_under(candidate, root) for root in SYSTEM_BLOCKED):
        return True
    for root in home_roots(home):
        if any(_under(candidate, os.path.join(root, rel)) for rel in HOME_BLOCKED):
            return True
        if _under(candidate, root) and candidate.lower().endswith(HOME_KEY_SUFFIXES):
            return True
    return False


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


NET_SYSCALLS = {
    "aarch64": {"socket": 198, "bind": 200, "listen": 201, "connect": 203, "sendto": 206, "sendmsg": 211, "sendmmsg": 269},
    "x86_64": {"socket": 41, "connect": 42, "sendto": 44, "sendmsg": 46, "bind": 49, "listen": 50, "sendmmsg": 307},
}


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
            "ptrace": 117,
            "process_vm_readv": 270,
            "process_vm_writev": 271,
            "pidfd_getfd": 438,
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
            "ptrace": 101,
            "process_vm_readv": 310,
            "process_vm_writev": 311,
            "pidfd_getfd": 438,
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


AF_UNIX = 1
AF_INET = 2
AF_INET6 = 10
AF_NETLINK = 16
SOCK_STREAM = 1
IPPROTO_TCP = 6
MSG_FASTOPEN = 0x20000000
SYS_PIDFD_GETFD = 438
PIDFD_THREAD = os.O_EXCL


def assemble(items: list[tuple]) -> bytes:
    """Assemble classic BPF from (op, ...) items; jumps name forward labels."""
    labels: dict[str, int] = {}
    ins: list[tuple] = []
    for item in items:
        if item[0] == "label":
            labels[item[1]] = len(ins)
        else:
            ins.append(item)
    words = []
    for index, item in enumerate(ins):
        op = item[0]
        if op in ("jeq", "jge", "jset"):
            code = {"jeq": BPF_JMP_JEQ_K, "jge": BPF_JMP_JGE_K, "jset": BPF_JMP_JSET_K}[op]
            jt = 0 if item[2] is None else labels[item[2]] - index - 1
            jf = 0 if len(item) < 4 or item[3] is None else labels[item[3]] - index - 1
            if not (0 <= jt < 256 and 0 <= jf < 256):
                raise ValueError("seccomp jump out of range")
            words.append(struct.pack("<HBBI", code, jt, jf, item[1] & 0xFFFFFFFF))
        elif op == "ld":
            words.append(struct.pack("<HBBI", BPF_LD_W_ABS, 0, 0, item[1]))
        elif op == "and":
            words.append(struct.pack("<HBBI", BPF_ALU_AND_K, 0, 0, item[1]))
        else:
            words.append(struct.pack("<HBBI", BPF_RET_K, 0, 0, item[1] & 0xFFFFFFFF))
    return b"".join(words)


def arg_offset(index: int, high: bool = False) -> int:
    return 16 + 8 * index + (4 if high else 0)


def build_filter(audit_arch: int, notify: set[int], deny: set[int], net: dict[str, int] | None = None) -> bytes:
    """The seccomp program every confined process runs under.

    Network rules read only registers, never memory, so a thread cannot change
    what they saw. Only stream sockets may be created: a datagram or raw
    socket could send to an off-host address without a connect the supervisor
    sees. A send that names a destination is refused, as is a fast-open send,
    which would connect inside the send. connect, bind, and listen go to the
    supervisor, which completes them itself.
    """
    net = net or {}
    deny_errno = SECCOMP_RET_ERRNO | errno.EPERM
    items: list[tuple] = [
        ("ld", 4),
        ("jeq", audit_arch, "arch_ok"),
        ("ret", deny_errno),
        ("label", "arch_ok"),
        ("ld", 0),
        # x32 syscalls reuse the x86_64 audit arch with bit 30 set.
        ("jge", 0x40000000, "deny"),
    ]
    for number in sorted(deny):
        items.append(("jeq", number, "deny"))
    handlers = {}
    for name in ("socket", "sendto", "sendmsg", "sendmmsg"):
        if name in net:
            handlers[name] = f"h_{name}"
            items.append(("jeq", net[name], f"h_{name}"))
    for number in sorted(notify | {net[name] for name in ("connect", "bind", "listen") if name in net}):
        items.append(("jeq", number, "notify"))
    items.append(("ret", SECCOMP_RET_ALLOW))
    if "socket" in handlers:
        items += [
            ("label", "h_socket"),
            ("ld", arg_offset(0)),
            ("jeq", AF_UNIX, "stream"),
            ("jeq", AF_INET, "stream"),
            ("jeq", AF_INET6, "stream"),
            ("jeq", AF_NETLINK, "allow", "eacces"),
            ("label", "stream"),
            ("ld", arg_offset(1)),
            ("and", 0xF),
            ("jeq", SOCK_STREAM, "proto", "eacces"),
            # SCTP and MPTCP can connect without the connect call the
            # supervisor sees, so only the default protocol and TCP pass.
            ("label", "proto"),
            ("ld", arg_offset(2)),
            ("jeq", 0, "allow"),
            ("jeq", IPPROTO_TCP, "allow", "eacces"),
        ]
    if "sendto" in handlers:
        items += [
            ("label", "h_sendto"),
            ("ld", arg_offset(4)),
            ("jeq", 0, "sendto_hi", "eacces"),
            ("label", "sendto_hi"),
            ("ld", arg_offset(4, True)),
            ("jeq", 0, "allow", "eacces"),
        ]
    if "sendmsg" in handlers:
        items += [("label", "h_sendmsg"), ("ld", arg_offset(2)), ("jset", MSG_FASTOPEN, "eacces", "allow")]
    if "sendmmsg" in handlers:
        items += [("label", "h_sendmmsg"), ("ld", arg_offset(3)), ("jset", MSG_FASTOPEN, "eacces", "allow")]
    items += [
        ("label", "allow"),
        ("ret", SECCOMP_RET_ALLOW),
        ("label", "eacces"),
        ("ret", SECCOMP_RET_ERRNO | errno.EACCES),
        ("label", "notify"),
        ("ret", SECCOMP_RET_USER_NOTIF),
        ("label", "deny"),
        ("ret", deny_errno),
    ]
    return assemble(items)


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


def read_mem(pid: int, address: int, size: int) -> bytes | None:
    if not address or size <= 0:
        return None
    libc = ctypes.CDLL(None, use_errno=True)
    buf = ctypes.create_string_buffer(size)
    local = IOVec(ctypes.addressof(buf), size)
    remote = IOVec(address, size)
    got = libc.process_vm_readv(pid, ctypes.byref(local), 1, ctypes.byref(remote), 1, 0)
    if got != size:
        return None
    return buf.raw[:size]


def loopback_sockaddr(raw: bytes) -> bool:
    """True only for an IPv4 or IPv6 socket address on this machine's loopback."""
    if len(raw) < 2:
        return False
    family = struct.unpack_from("<H", raw)[0]
    if family == AF_INET and len(raw) >= 8:
        return raw[4] == 127
    if family == AF_INET6 and len(raw) >= 24:
        addr = raw[8:24]
        return addr == b"\0" * 15 + b"\1" or (addr[:10] == b"\0" * 10 and addr[10:12] == b"\xff\xff" and addr[12] == 127)
    return False


def thread_group(tid: int) -> int:
    with open(f"/proc/{tid}/status", encoding="ascii") as handle:
        for line in handle:
            if line.startswith("Tgid:"):
                return int(line.split()[1])
    raise OSError(errno.ESRCH, "no thread group")


def fetch_child_fd(tid: int, fd: int) -> int:
    """A duplicate of the child's descriptor, sharing its open file description."""
    pidfd = os.pidfd_open(thread_group(tid))
    try:
        libc = ctypes.CDLL(None, use_errno=True)
        got = libc.syscall(SYS_PIDFD_GETFD, pidfd, fd, 0)
        if got < 0:
            err = ctypes.get_errno()
            raise OSError(err, os.strerror(err))
        return got
    finally:
        os.close(pidfd)


def egress_enforceable() -> str | None:
    """None when the supervisor can complete a child's connect itself, else why not."""
    if os.environ.get("FM_TEST_SEAM") == "1" and os.environ.get("FM_TEST_NO_FD_DUP") == "1":
        return "descriptor duplication is disabled by the test seam"
    if not hasattr(os, "pidfd_open"):
        return "this Python has no pidfd_open"
    probe = socket.socket()
    try:
        dup = fetch_child_fd(os.getpid(), probe.fileno())
        os.close(dup)
    except OSError as exc:
        return f"the supervisor cannot duplicate a socket descriptor ({exc})"
    finally:
        probe.close()
    return None


def handle_net(notify_fd: int, valid_req: int, ident: int, pid: int, kind: str, args: tuple) -> int:
    """Complete connect, bind, or listen for the child, or refuse it. Returns 0 or an errno.

    The address is read once from the child's memory, checked, and applied to
    a duplicate of the child's own descriptor, so a thread rewriting that
    memory afterwards changes nothing. Only loopback TCP is allowed: no
    off-host address, no unix socket, no wildcard bind.
    """
    fd = as_i64(args[0])
    if fd < 0 or fd > 2**31 - 1:
        return errno.EBADF
    raw = b""
    if kind in ("connect", "bind"):
        size = int(args[2]) & 0xFFFFFFFF
        if size < 2 or size > 128:
            return errno.EINVAL
        got = read_mem(pid, args[1], size)
        if got is None:
            return errno.EFAULT
        raw = got
        if not loopback_sockaddr(raw):
            return errno.EACCES
    libc = ctypes.CDLL(None, use_errno=True)
    dup = fetch_child_fd(pid, fd)
    try:
        try:
            ioctl(notify_fd, valid_req, struct.pack("Q", ident))
        except OSError:
            return errno.ENOENT
        if kind == "listen":
            name = ctypes.create_string_buffer(128)
            length = ctypes.c_uint32(128)
            if libc.getsockname(dup, name, ctypes.byref(length)) != 0:
                return ctypes.get_errno() or errno.EBADF
            if not loopback_sockaddr(name.raw[: length.value]):
                return errno.EACCES
            rc = libc.listen(dup, int(as_i64(args[1])))
        elif kind == "connect":
            rc = libc.connect(dup, raw, len(raw))
        else:
            rc = libc.bind(dup, raw, len(raw))
        return 0 if rc == 0 else (ctypes.get_errno() or errno.EIO)
    finally:
        os.close(dup)


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


def supervise(notify_fd: int, child: int, home: str, root: str, names: dict[str, int], net: dict[str, int], notif_size: int) -> None:
    recv_req = _ioc(3, 0, notif_size)
    send_req = _ioc(3, 1, 24)
    valid_req = _ioc(1, 2, 8)
    addfd_req = _ioc(1, 3, 24)
    # glibc opens through openat. openat2 is denied below: its flag argument
    # is a struct pointer, so the parent cannot install a checked fd for it.
    open_numbers = {names[name] for name in ("openat", "open") if name in names}
    path_at = {names[name] for name in ("openat", "openat2", "statx", "newfstatat", "faccessat", "faccessat2", "readlinkat", "name_to_handle_at") if name in names}
    net_kinds = {net[name]: name for name in ("connect", "bind", "listen") if name in net}
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
        completed = False
        try:
            if nr in net_kinds:
                error = handle_net(notify_fd, valid_req, ident, pid, net_kinds[nr], args)
                completed = error == 0
            elif nr in path_at or nr == names.get("open") or nr in (names.get("execve"), names.get("execveat")):
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
        err_out = 0 if continue_call or completed else -int(error or errno.EIO)
        resp = ctypes.create_string_buffer(struct.pack("QqiI", ident, 0, err_out, flags_out))
        try:
            ioctl(notify_fd, send_req, resp)
        except OSError:
            continue


def scrub_tokens() -> None:
    for key in list(os.environ):
        if token_name(key):
            del os.environ[key]


def confine_linux(home: str, command: list[str], proxy: ModelProxy) -> int:
    root = os.path.realpath(os.getcwd())
    tables = arch_tables()
    if tables is None:
        print("free-model sensitivity: this architecture cannot confine a free OpenCode model", file=sys.stderr)
        return 2
    audit, sys_seccomp, sys_prctl, names, deny_names, _open = tables
    net = NET_SYSCALLS.get("aarch64" if platform.machine() in ("aarch64", "arm64") else "x86_64", {})
    why = egress_enforceable()
    if why:
        print(f"free-model sensitivity: {why}, so network egress cannot be denied and a free OpenCode model was not run", file=sys.stderr)
        return 2
    scrub_tokens()
    parent, child = socket.socketpair()
    pid = os.fork()
    if pid == 0:
        try:
            parent.close()
            # Python ignores SIGPIPE and SIGXFSZ, and exec keeps ignored
            # signals ignored; restore the defaults so pipelines terminate.
            signal.signal(signal.SIGPIPE, signal.SIG_DFL)
            signal.signal(signal.SIGXFSZ, signal.SIG_DFL)
            listener = install_filter(build_filter(audit, set(names.values()), set(deny_names.values()), net), sys_seccomp, sys_prctl)
            send_fd(child, listener)
            os.close(listener)
            child.close()
            os.execvpe(command[0], command, os.environ)
        except OSError as exc:
            print(f"free-model sensitivity: confine failed: {exc}", file=sys.stderr)
        os._exit(127)
    child.close()
    proxy.start()
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
        supervise(listener, pid, home, root, names, net, sizes.seccomp_notif or 80)
    finally:
        os.close(listener)
    _pid, status = os.waitpid(pid, 0)
    if os.WIFEXITED(status):
        return os.WEXITSTATUS(status)
    if os.WIFSIGNALED(status):
        return 128 + os.WTERMSIG(status)
    return 1


# The model endpoints the confined process may reach, and only through the
# proxy below. The proxy runs in the unconfined supervisor, so it enforces the
# hostname itself; the confined process has no other network route.
MODEL_UPSTREAMS = {
    "zen": ("opencode.ai", "/zen", re.compile(r"^/v1/[A-Za-z0-9._/-]+$")),
    "openrouter": ("openrouter.ai", "/api", re.compile(r"^/v1/[A-Za-z0-9._/-]+$")),
    "models": ("models.dev", "", re.compile(r"^/(experimental/v2\.0/)?api\.json$")),
}
PROXY_MAX_BODY = 64 * 1024 * 1024
HOP_HEADERS = {"connection", "keep-alive", "proxy-authenticate", "proxy-authorization", "te", "trailer", "transfer-encoding", "upgrade", "host", "content-length"}


def test_upstream() -> str | None:
    if os.environ.get("FM_TEST_SEAM") == "1":
        return os.environ.get("FM_TEST_MODEL_UPSTREAM") or None
    return None


def model_proxy_handler(token: str):
    class Handler(http.server.BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.0"
        server_version = "fm-model-proxy"

        def log_message(self, *_args) -> None:
            pass

        def refuse(self, status: int, why: str) -> None:
            body = (why + "\n").encode()
            self.send_response(status)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(body)

        def forward(self) -> None:
            parts = urllib.parse.urlsplit(self.path)
            segments = parts.path.split("/", 3)
            if len(segments) < 4 or not hmac.compare_digest(segments[1], token):
                return self.refuse(403, "not a model proxy path")
            route = MODEL_UPSTREAMS.get(segments[2])
            rest = "/" + segments[3]
            if route is None or not route[2].match(rest) or any(part in ("", ".", "..") for part in rest[1:].split("/")):
                return self.refuse(403, "this path is not a model endpoint")
            host, base, _allowed = route
            length = int(self.headers.get("Content-Length") or 0)
            if self.headers.get("Transfer-Encoding") or length > PROXY_MAX_BODY:
                return self.refuse(411, "send the body with a Content-Length")
            body = self.rfile.read(length) if length else None
            headers = {k: v for k, v in self.headers.items() if k.lower() not in HOP_HEADERS}
            target = base + rest + ("?" + parts.query if parts.query else "")
            override = test_upstream()
            try:
                if override:
                    upstream = urllib.parse.urlsplit(override)
                    conn = http.client.HTTPConnection(upstream.hostname, upstream.port, timeout=900)
                    headers["Host"] = f"{upstream.hostname}:{upstream.port}"
                    target = "/" + segments[2] + rest + ("?" + parts.query if parts.query else "")
                else:
                    conn = http.client.HTTPSConnection(host, timeout=900)
                    headers["Host"] = host
                conn.request(self.command, target, body, headers)
                resp = conn.getresponse()
            except (OSError, http.client.HTTPException) as exc:
                return self.refuse(502, f"upstream failed: {exc.__class__.__name__}")
            try:
                self.send_response(resp.status, resp.reason)
                for key, value in resp.getheaders():
                    if key.lower() not in HOP_HEADERS or key.lower() == "content-length":
                        self.send_header(key, value)
                self.send_header("Connection", "close")
                self.end_headers()
                while True:
                    chunk = resp.read1(65536)
                    if not chunk:
                        break
                    self.wfile.write(chunk)
                    self.wfile.flush()
            except OSError:
                pass
            finally:
                conn.close()

        do_GET = forward
        do_POST = forward

    return Handler


class ModelProxy:
    """A loopback forwarder that carries only the model API calls and the model catalog."""

    def __init__(self) -> None:
        host = "127.0.0.1"
        if os.environ.get("FM_TEST_SEAM") == "1" and os.environ.get("FM_TEST_PROXY_BIND"):
            host = os.environ["FM_TEST_PROXY_BIND"]
        self.token = secrets.token_urlsafe(16)
        self.server = http.server.ThreadingHTTPServer((host, 0), model_proxy_handler(self.token))
        self.server.daemon_threads = True
        self.port = self.server.server_address[1]
        self.thread: threading.Thread | None = None

    def start(self) -> None:
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def close(self) -> None:
        if self.thread is not None:
            self.server.shutdown()
        self.server.server_close()

    def base(self) -> str:
        return f"http://127.0.0.1:{self.port}/{self.token}"

    def environment(self, directory: str) -> dict[str, str]:
        """What the model client needs to talk to this proxy instead of the internet."""
        config = {
            "provider": {
                "opencode": {"options": {"baseURL": self.base() + "/zen/v1"}},
                "openrouter": {"options": {"baseURL": self.base() + "/openrouter/v1"}},
            }
        }
        path = os.path.join(directory, "opencode-proxy.json")
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(config, handle)
        return {"OPENCODE_CONFIG": path, "OPENCODE_MODELS_URL": self.base() + "/models"}


SANDBOX_EXEC = "/usr/bin/sandbox-exec"
SBPL_UNSAFE = set('"\\^]')
SBPL_LITERAL = set(".*+?(){}|$[")


def sbpl_regex(text: str) -> str:
    """Escape text for an SBPL regex, matching letters in either case.

    macOS volumes fold case by default, so a case-sensitive pattern would let
    `.ENV` through where `.env` is blocked. Characters that would end the
    string or open a regex construct are escaped as one-character classes.
    """
    out = []
    for char in text:
        if char in SBPL_UNSAFE or ord(char) < 0x20 or ord(char) == 0x7F:
            raise ValueError(f"path character {char!r} cannot be written into a sandbox profile")
        if char.isascii() and char.isalpha():
            out.append(f"[{char.lower()}{char.upper()}]")
        elif char in SBPL_LITERAL:
            out.append(f"[{char}]")
        else:
            out.append(char)
    return "".join(out)


def sbpl_alternatives(names) -> str:
    return "(" + "|".join(sbpl_regex(name) for name in sorted(names)) + ")"


def darwin_block_patterns(home: str, root: str) -> list[str]:
    """Regexes over a resolved absolute path that mirror path_blocked.

    Every pattern is anchored at both ends, so it reads the same whether the
    sandbox matches a whole path or searches within it. Paths reach the
    sandbox already resolved, so a symlink to a blocked file is blocked as the
    file it names. A pattern that must match a path and everything under it is
    emitted as two patterns, one for the path and one for its children.
    """
    patterns = []

    def below(prefix: str, body: str) -> None:
        patterns.append(f"^{prefix}{body}$")
        patterns.append(f"^{prefix}{body}/.*$")

    # The file-name classes apply anywhere.
    patterns.append("^.*/[^/]*" + sbpl_regex(".env") + "$")
    patterns.append("^.*/" + sbpl_regex(".env.") + "[^/]*$")
    patterns.append("^.*/" + sbpl_alternatives(ENV_NAMES | DOPPLER_NAMES | SECRET_NAMES) + "$")
    below(".*/", sbpl_regex(".secrets"))
    homes = {os.path.normpath(home), os.path.realpath(home)} if home and os.path.isabs(home) else set()
    for base in sorted(homes):
        prefix = sbpl_regex(base.rstrip("/")) + "/"
        below(prefix, sbpl_alternatives(HOME_BLOCKED))
        patterns.append(f"^{prefix}.*" + sbpl_alternatives(HOME_KEY_SUFFIXES) + "$")
    for system in SYSTEM_BLOCKED:
        below("", sbpl_regex(system))
    # The path classes apply only inside the task worktree.
    inside = sbpl_regex(root.rstrip("/")) + "(/|/.*/)"
    patterns.append(f"^{inside}" + sbpl_alternatives(CI_NAMES) + "$")
    below(inside, "[.]" + "(" + sbpl_regex("circleci") + "|" + sbpl_regex("buildkite") + ")")
    below(inside, sbpl_regex(".github/workflows"))
    patterns.append(f"^{inside}" + sbpl_alternatives(SEGMENTS) + "/.+$")
    patterns.append(f"^{inside}[^/]*" + sbpl_regex("migration") + "[^/]*" + sbpl_regex(".sql") + "$")
    patterns.append(f"^{inside}[^/]*" + sbpl_regex(".") + "(" + sbpl_regex("tf") + "|" + sbpl_regex("tfvars") + ")$")
    infra_names = {
        "vercel.json", "dockerfile", "fly.toml", "cdk.json", "chart.yaml", "chart.yml",
        "serverless.yml", "serverless.yaml", "render.yaml", "render.yml", "pulumi.yaml", "pulumi.yml",
        "values.yaml", "values.yml",
    }
    patterns.append(f"^{inside}" + sbpl_alternatives(infra_names) + "$")
    yaml_ext = "(" + sbpl_regex(".yml") + "|" + sbpl_regex(".yaml") + ")"
    patterns.append(f"^{inside}" + sbpl_regex("docker-compose") + "[^/]*" + yaml_ext + "$")
    patterns.append(f"^{inside}[^/]*" + sbpl_regex("deploy") + "[^/]*" + sbpl_regex(".sh") + "$")
    patterns.append(f"^{inside}" + sbpl_regex("values-") + "[^/]*" + yaml_ext + "$")
    patterns.append(f"^{inside}[^/]*" + sbpl_regex(".k8s") + yaml_ext + "$")
    patterns.append(f"^{inside}[^/]*" + sbpl_regex("deployment") + "[^/]*" + yaml_ext + "$")
    patterns.append(f"^{inside}[^/]*" + sbpl_regex("ingress") + "[^/]*" + yaml_ext + "$")
    stems = sbpl_alternatives(FILE_STEMS)
    patterns.append(f"^{inside}{stems}$")
    patterns.append(f"^{inside}{stems}" + sbpl_regex(".") + "[^/]*$")
    return patterns


# No network except loopback TCP and UDP. A unix socket, DNS through
# mDNSResponder, and every off-host address stay denied; the last rule wins, so
# the allows come after the deny.
DARWIN_NETWORK_RULES = (
    "(deny network*)",
    '(allow network-outbound (remote ip "localhost:*"))',
    '(allow network-bind (local ip "localhost:*"))',
    '(allow network-inbound (local ip "localhost:*"))',
)


def darwin_profile(home: str, root: str) -> str:
    """The sandbox-exec profile: default allow, with the read block denied.

    Open for read, open for write or create, stat, access, readlink, and exec
    of a blocked path are all denied, as the Linux notifier denies every one
    of those calls on it. Network is denied except loopback. Other writes and the rest stay allowed.
    The last two rules stand in for /proc/<pid>/environ and /proc/<pid>/mem:
    another process's environment block, which still holds the tokens the
    supervisor unset, and its memory.
    """
    lines = ["(version 1)", "(allow default)"]
    for pattern in darwin_block_patterns(home, root):
        lines.append(f'(deny file-read* file-write-data file-write-create process-exec* (regex #"{pattern}"))')
    lines.append("(deny process-info* (target others))")
    lines.append('(deny sysctl-read (sysctl-name "kern.procargs2"))')
    lines.extend(DARWIN_NETWORK_RULES)
    return "\n".join(lines) + "\n"


def sandbox_exec_path() -> str:
    if os.environ.get("FM_TEST_SEAM") == "1" and os.environ.get("FM_TEST_SANDBOX_EXEC"):
        return os.environ["FM_TEST_SANDBOX_EXEC"]
    return SANDBOX_EXEC


def confine_darwin(home: str, command: list[str], proxy: ModelProxy) -> int:
    sandbox = sandbox_exec_path()
    if not (os.path.isfile(sandbox) and os.access(sandbox, os.X_OK)):
        print(f"free-model sensitivity: {sandbox} is missing, so a free OpenCode model cannot be confined and was not run", file=sys.stderr)
        return 2
    try:
        profile = darwin_profile(home, os.path.realpath(os.getcwd()))
    except ValueError as exc:
        print(f"free-model sensitivity: {exc}, so a free OpenCode model cannot be confined and was not run", file=sys.stderr)
        return 2
    scrub_tokens()
    # sandbox-exec returns the command's own status, so a profile that fails
    # to apply cannot be told from a command that exits with the same number.
    # Applying the profile to a no-op first makes a failure unambiguous.
    try:
        probe = subprocess.run([sandbox, "-p", profile, "/usr/bin/true"], capture_output=True, env=os.environ)
    except OSError as exc:
        print(f"free-model sensitivity: sandbox-exec failed to start ({exc}), so a free OpenCode model cannot be confined and was not run", file=sys.stderr)
        return 2
    if probe.returncode != 0:
        detail = probe.stderr.decode("utf-8", "replace").strip()
        print(f"free-model sensitivity: sandbox-exec could not apply the read-block profile ({detail or 'status ' + str(probe.returncode)}), so a free OpenCode model cannot be confined and was not run", file=sys.stderr)
        return 2
    proxy.start()
    try:
        status = subprocess.run([sandbox, "-p", profile, *command], env=os.environ).returncode
    except OSError as exc:
        print(f"free-model sensitivity: confine failed: {exc}", file=sys.stderr)
        return 2
    if status < 0:
        return 128 - status
    return status


def confine_system() -> str:
    if os.environ.get("FM_TEST_SEAM") == "1" and os.environ.get("FM_TEST_CONFINE_SYSTEM"):
        return os.environ["FM_TEST_CONFINE_SYSTEM"]
    return platform.system()


def confine(home: str, command: list[str]) -> int:
    system = confine_system()
    if system not in ("Linux", "Darwin"):
        print(f"free-model sensitivity: no confine exists for {system or 'this system'}, so a free OpenCode model was not run", file=sys.stderr)
        return 2
    scratch = tempfile.mkdtemp(prefix="fm-confine-")
    saved = {name: os.environ.get(name) for name in ("OPENCODE_CONFIG", "OPENCODE_MODELS_URL")}
    proxy = None
    try:
        try:
            proxy = ModelProxy()
            os.environ.update(proxy.environment(scratch))
        except OSError as exc:
            print(f"free-model sensitivity: the model proxy could not start ({exc}), so the confined process would have no model route and a free OpenCode model was not run", file=sys.stderr)
            return 2
        if system == "Linux":
            return confine_linux(home, command, proxy)
        return confine_darwin(home, command, proxy)
    finally:
        if proxy is not None:
            proxy.close()
        for name, value in saved.items():
            if value is None:
                os.environ.pop(name, None)
            else:
                os.environ[name] = value
        shutil.rmtree(scratch, ignore_errors=True)


CHECK_PROBE = r"""
import errno, os, socket, sys, urllib.parse
home, outside, routine = sys.argv[1:4]
bad = 0
def report(ok, name, detail=""):
    global bad
    bad += not ok
    print(("PASS " if ok else "FAIL ") + name + (" " + detail if detail else ""))
def denied(path):
    try:
        open(path, "rb").read(1)
    except OSError as exc:
        return exc.errno in (errno.EACCES, errno.EPERM)
    return False
for rel in (".ssh/id_ed25519", ".gnupg/private-keys-v1.d/k.key", ".netrc", ".git-credentials", ".npmrc",
            ".docker/config.json", "Library/Keychains/login.keychain-db", "certs/server.pem", "deep/er/token.KEY"):
    report(denied(os.path.join(home, rel)), "read blocked: ~/" + rel)
report(not denied(outside), "read allowed: *.pem outside the home")
report(not denied(routine), "read allowed: ordinary file")
def refused(connect):
    sock = socket.socket(*connect[0])
    sock.settimeout(3)
    try:
        sock.connect(connect[1])
    except OSError as exc:
        return exc.errno in (errno.EACCES, errno.EPERM), exc
    finally:
        sock.close()
    return False, None
for label, spec in (
    ("off-host IPv4", ((socket.AF_INET, socket.SOCK_STREAM), ("192.0.2.1", 9))),
    ("off-host IPv6", ((socket.AF_INET6, socket.SOCK_STREAM), ("2001:db8::1", 9))),
):
    ok, exc = refused(spec)
    report(ok, "network denied: " + label, "" if ok else repr(exc))
try:
    udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        udp.sendto(b"x", ("192.0.2.1", 9))
        report(False, "network denied: off-host UDP")
    except OSError as exc:
        report(exc.errno in (errno.EACCES, errno.EPERM), "network denied: off-host UDP")
    finally:
        udp.close()
except OSError as exc:
    report(exc.errno in (errno.EACCES, errno.EPERM), "network denied: off-host UDP")
url = urllib.parse.urlsplit(os.environ.get("OPENCODE_MODELS_URL", ""))
try:
    conn = socket.create_connection((url.hostname, url.port), timeout=5)
    conn.sendall(b"GET /not-the-token/models/x HTTP/1.0\r\nHost: x\r\n\r\n")
    first = conn.recv(64).split(b"\r\n")[0]
    conn.close()
    report(first.startswith(b"HTTP/1.0 403"), "loopback allowed: model proxy answers and refuses a wrong path", first.decode("latin-1"))
except (OSError, TypeError) as exc:
    report(False, "loopback allowed: model proxy answers", repr(exc))
sys.exit(1 if bad else 0)
"""


def confine_check() -> int:
    """Run the guarantees under the real confine, with planted canaries; the macOS proof."""
    scratch = os.path.realpath(tempfile.mkdtemp(prefix="fm-confine-check-"))
    try:
        home = os.path.join(scratch, "home")
        outside = os.path.join(scratch, "outside", "x.pem")
        routine = os.path.join(scratch, "work", "app.txt")
        for rel in (
            ".ssh/id_ed25519", ".gnupg/private-keys-v1.d/k.key", ".netrc", ".git-credentials", ".npmrc",
            ".docker/config.json", "Library/Keychains/login.keychain-db", "certs/server.pem", "deep/er/token.KEY",
        ):
            path = os.path.join(home, rel)
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "w", encoding="utf-8") as handle:
                handle.write("canary\n")
        for path in (outside, routine):
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "w", encoding="utf-8") as handle:
                handle.write("ok\n")
        caller = os.getcwd()
        os.chdir(os.path.join(scratch, "work"))
        try:
            return confine(home, [sys.executable, "-I", "-c", CHECK_PROBE, home, outside, routine])
        finally:
            os.chdir(caller)
    finally:
        shutil.rmtree(scratch, ignore_errors=True)


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


def seed_tree(top: str, tree: str, home: str, patch_path: str) -> str:
    """Apply the caller's change against HEAD, staged or not, to tree, then
    copy untracked files, leaving out refused paths, and return the tree id
    of that copy."""
    changed = git_bytes(["-C", top, "diff", "--name-only", "-z", "--no-renames", "HEAD"])
    allowed = [n for n in os.fsdecode(changed).split("\0") if n and not path_refused(n, home)]
    if allowed:
        patch = git_bytes(["-C", top, "--literal-pathspecs", "diff", "--binary", "--no-renames", "HEAD", "--", *allowed])
        with open(patch_path, "wb") as handle:
            handle.write(patch)
        git_bytes(["-C", tree, "apply", "--binary", patch_path])
    untracked = git_bytes(["-C", top, "ls-files", "-z", "--others", "--exclude-standard"])
    for rel in os.fsdecode(untracked).split("\0"):
        if not rel or rel.endswith("/") or path_refused(rel, home):
            continue
        source = os.path.join(top, rel)
        target = os.path.join(tree, rel)
        os.makedirs(os.path.dirname(target), exist_ok=True)
        if os.path.islink(source):
            os.symlink(os.readlink(source), target)
        else:
            shutil.copy2(source, target)
    git_bytes(["-C", tree, "add", "-A"])
    return git_bytes(["-C", tree, "write-tree"]).decode().strip()


def collect_diff(tree: str, base: str, paths: list[str], home: str) -> bytes:
    # Staging everything also captures new files and anything the model committed.
    git_bytes(["-C", tree, "add", "-A"])
    scope = ["-C", tree, "--literal-pathspecs", "diff", "--cached", "--no-renames", base]
    names = git_bytes([*scope, "--name-only", "-z", "--", *paths])
    for name in os.fsdecode(names).split("\0"):
        if name and path_refused(name, home):
            raise ValueError(f"refusing the model's change to sensitive path {name}")
    return git_bytes([*scope, "--binary", "--", *paths])


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
    caller_pwd = os.environ.get("PWD")
    code = 1
    diff = b""
    try:
        git_bytes(["worktree", "add", "--detach", "--quiet", tree, head])
    except GitError as exc:
        shutil.rmtree(scratch, ignore_errors=True)
        print(f"free-model sensitivity: could not create a scratch worktree: {exc}", file=sys.stderr)
        return 2
    try:
        base = seed_tree(top, tree, home, os.path.join(scratch, "caller.patch"))
        os.chdir(tree)
        # OpenCode works in the directory named by $PWD, not its process cwd.
        os.environ["PWD"] = tree
        os.environ["OPENCODE_CONFIG_CONTENT"] = '{"permission":{"*":"allow"}}'
        code = confine_quiet(home, mech_command(model, paths, prompt), log_path)
        diff = collect_diff(tree, base, paths, home)
    except (GitError, OSError, ValueError) as exc:
        print(f"free-model sensitivity: {exc}", file=sys.stderr)
        code = 1
    finally:
        os.chdir(caller)
        if caller_pwd is None:
            os.environ.pop("PWD", None)
        else:
            os.environ["PWD"] = caller_pwd
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
        "       fm-free-model-sensitivity.sh confine-profile --home <dir> [--root <dir>]\n"
        "       fm-free-model-sensitivity.sh confine-check\n"
        "       fm-free-model-sensitivity.sh mech [--model <id>] --path <path> [--path <path>...] -- <edit>\n"
        "\n"
        "mech hands a rename, a format, boilerplate, or test scaffolding to a free OpenCode model.\n"
        "  --model must be a documented free OpenCode id (last segment free, big-pickle, or ending\n"
        "  -free or :free) or be omitted; any other id is refused.\n"
        "  Each --path is relative to the repository top level, and the diff carries only\n"
        "  changes under those paths. A --path in the ci, migrations, infra, auth, payments,\n"
        "  env, or doppler class, or a secrets file or token store, is refused, and so is a\n"
        "  result in which the model changed such a path, even inside a declared directory.\n"
        "  The model runs confined, with tokens scrubbed and no network except a loopback proxy to\n"
        "  the model hosts, on a scratch copy of your current tree\n"
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
    if cmd == "confine-profile":
        try:
            home = flag_value(argv[2:], "--home")
        except SystemExit:
            usage()
            return 2
        try:
            root = flag_value(argv[2:], "--root")
        except SystemExit:
            root = os.getcwd()
        try:
            sys.stdout.write(darwin_profile(home, os.path.realpath(root)))
        except ValueError as exc:
            print(f"free-model sensitivity: {exc}", file=sys.stderr)
            return 2
        return 0
    if cmd == "confine-check":
        return confine_check()
    if cmd == "mech":
        return mech(argv[2:])
    usage()
    return 2


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv))
    except BrokenPipeError:
        sys.exit(0)
