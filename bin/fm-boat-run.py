#!/usr/bin/env python3
"""Boat adapter implementation. Public contract: fm-boat-run.sh --help."""

import argparse
import base64
import contextlib
import datetime
import fcntl
import hashlib
import io
import json
import os
import re
import shlex
import shutil
import signal
import stat
import subprocess
import sys
import tarfile
import tempfile
import time
import uuid
from dataclasses import dataclass
from pathlib import Path, PurePosixPath


class Failure(Exception):
    def __init__(self, message, code=74):
        super().__init__(message)
        self.code = code


class HistoryScreenRefusal(Failure):
    pass


class UploadRejected(Failure):
    pass


class _Terminated(BaseException):
    def __init__(self, code):
        self.code = code


ACTIVE_CHILD = None
MACHINE_TYPES = ('default', 'large', 'xlarge')
REMOTE_ROOT = '/home/user/fm-job'
LEASE_IDLE = 1500
LEASE_LIFETIME = 7200


def task_owner(home, task, root=None):
    if not re.fullmatch(r'[a-zA-Z0-9_-][a-zA-Z0-9._-]{0,63}', task or ''):
        return None
    try:
        fields = {}
        for line in (home / 'state' / (task + '.meta')).read_text().splitlines():
            key, value = line.split('=', 1)
            if key in fields:
                return None
            fields[key] = value
        worktree = Path(fields['worktree']).resolve(strict=True)
        if (fields.get('endpoint_task_id') != task or fields.get('kind') not in ('ship', 'scout')
                or not fields.get('spawn_gen') or (root is not None and root != worktree)):
            return None
        return dict(home=str(home.resolve()), task=task, generation=fields['spawn_gen'],
                    worktree=str(worktree))
    except (OSError, KeyError, ValueError):
        return None


def job_path(state, owner):
    identity = owner['home'] + '\0' + owner['task']
    return state / 'jobs' / ('task-' + hashlib.sha256(identity.encode()).hexdigest() + '.json')


def owner_current(owner):
    return owner == task_owner(Path(owner['home']), owner['task'])


def compute_available(boat, seconds, machine):
    limits = boat.call('limits', '--json')
    credit = limits.get('creditBalanceSeconds')
    return (type(credit) in (int, float) and credit >= seconds *
            {'default': 1, 'large': 2, 'xlarge': 4}[machine]
            and limits.get('billingStatus') in ('active', 'trialing'))


def start_expiry(record):
    subprocess.Popen([sys.executable, str(Path(__file__).resolve()), 'expire',
                      '--lease', record.stem], stdin=subprocess.DEVNULL,
                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                     start_new_session=True, close_fds=True, cwd=record.parent)


# A Linux subreaper adopts double-forked descendants even after setsid/env -i.
# The token also identifies survivors from an interrupted prior reset.
REMOTE_PROCESSES = r'''import ctypes,os,pathlib,shutil,signal,subprocess,sys,time
root=pathlib.Path(sys.argv[1])
action,token=sys.argv[2:4]
tag=('FM_BOAT_RUN_TOKEN='+token).encode()
if not sys.platform.startswith('linux') or ctypes.CDLL(None,use_errno=True).prctl(36,1,0,0,0)!=0:
 raise RuntimeError('Linux child subreaper unavailable')
def reset():
 for attempt in range(30):
  found=set()
  parents={}
  for p in pathlib.Path('/proc').iterdir():
   if not p.name.isdecimal() or int(p.name)==os.getpid(): continue
   try:
    parents[int(p.name)]=int((p/'stat').read_text().rsplit(')',1)[1].split()[1])
    if tag in (p/'environ').read_bytes().split(b'\0'):
     found.add(int(p.name))
   except (FileNotFoundError,ProcessLookupError,PermissionError): pass
  descendants={os.getpid()}
  while True:
   children={pid for pid,parent in parents.items() if parent in descendants}
   if children<=descendants: break
   descendants.update(children)
  found.update(descendants-{os.getpid()})
  while True:
   try:
    pid,status=os.waitpid(-1,os.WNOHANG)
    if pid==0: break
    found.discard(pid)
   except ChildProcessError: break
  if not found: return
  for pid in found:
   try: os.kill(pid,signal.SIGKILL)
   except ProcessLookupError: pass
  time.sleep(.1)
 raise RuntimeError('owned processes survived reset')
reset()
if action=='prepare':
 if root.is_symlink(): root.unlink()
 elif root.exists(): shutil.rmtree(root)
 root.mkdir()
 (root/'home').mkdir()
 (root/'tmp').mkdir()
elif action=='run':
 env={'PATH':os.environ['PATH'],'HOME':str(root/'home'),'TMPDIR':str(root/'tmp'),
      'CI':'1','NEXT_TELEMETRY_DISABLED':'1','FM_BOAT_RUN_TOKEN':token}
 child=subprocess.Popen(['timeout','-k','15',sys.argv[4],*sys.argv[5:]],
                        cwd=root/'source',env=env,start_new_session=True)
 try: code=child.wait()
 finally:
  try: os.killpg(child.pid,signal.SIGKILL)
  except ProcessLookupError: pass
  reset()
 (root/'exit').write_text(str(code if code>=0 else 128-code))
'''


def owned_processes(boat, job, action, args=None, output=None):
    command = ['python3', '-c', REMOTE_PROCESSES, REMOTE_ROOT, action, job['token']]
    if args is not None:
        command.extend([str(args.timeout), *args.command])
    return boat.command(job['vm_id'], command,
                        remote_timeout=args.timeout + 30 if args else 60,
                        timeout=args.timeout + 90 if args else 90,
                        capture_path=output / 'command.log' if output else None)


def prepare_source(boat, job, args, upload, digest, push_timeout, reused):
    vm = job['vm_id']
    if job.get('owner') and job.get('provider') == 'boat':
        owned_processes(boat, job, 'prepare')
    boat.upload(vm, upload, push_timeout)
    boat.command(vm, ['bash', '-c',
                 f'echo {digest} {REMOTE_ROOT}/source.tar.gz | sha256sum -c - && '
                 f'mkdir -p {REMOTE_ROOT}/source && tar xzf {REMOTE_ROOT}/source.tar.gz -C {REMOTE_ROOT}/source'],
                 timeout=90)
    if args.swap_gib and not reused:
        boat.command(vm, ['bash', '-c',
                     f'sudo -n fallocate -l {args.swap_gib}G /swapfile-fm-offload && '
                     'sudo -n chmod 600 /swapfile-fm-offload && '
                     'sudo -n mkswap /swapfile-fm-offload && '
                     'sudo -n swapon /swapfile-fm-offload'])


def fresh_job(args, owner):
    job_id = uuid.uuid4().hex
    ttl = LEASE_LIFETIME if owner else args.timeout + 900
    return dict(name='fm-offload-' + job_id, vm_id=None, cleanup='pending',
                ttl=ttl, expires=time.time() + ttl + 180,
                create_started=False, type=args.type, provider='boat', token=job_id,
                owner=owner, swap_gib=args.swap_gib, lease_state='busy',
                hard_expires=time.time() + ttl)


@contextlib.contextmanager
def allocation(args, boats, owner):
    state = boats[0].state
    record = job_path(state, owner) if owner else state / 'jobs' / (uuid.uuid4().hex + '.json')
    with lock(state / (record.stem + '.lock')):
        if owner and not owner_current(owner):
            raise Failure('task ownership changed while waiting for Boat lease', 70)
        old = json.loads(record.read_text()) if record.exists() else None
        if old and old.get('owner') and (
                old['owner'].get('home') != owner['home'] or old['owner'].get('task') != owner['task']):
            raise Failure('lease record ownership mismatch', 70)
        if old and old.get('closing') == owner and owner is not None:
            raise Failure('task Boat lease is closing', 70)
        eligible = [b for b in boats if args.type in b.account.types]
        compatible = next((b for b in eligible if old and
                           str(b.account.key_file) == old.get('account_key_file') and
                           b.account.environment == old.get('environment', '') and
                           b.account.cleanup_confirmation == old.get('cleanup_confirmation')), None)
        if old and old.get('cleanup') != 'deleted':
            ready = (owner and old.get('owner') == owner and compatible and
                     old.get('lease_state') == 'idle' and old.get('type') == args.type and
                     old.get('swap_gib') == args.swap_gib and
                     time.time() < old.get('idle_expires', 0) and
                     time.time() + args.timeout + 1080 < old['hard_expires'])
            if ready:
                try:
                    ready = (hashlib.sha256(compatible.account.key_file.read_bytes()).hexdigest()
                             == old.get('key_fingerprint') and
                             compute_available(compatible, args.timeout + 1080, args.type))
                    ready = ready and any(vm.get('id') == old['vm_id'] and
                                          vm.get('name') == old['name']
                                          for vm in compatible.listing())
                except Failure:
                    ready = False
            if ready:
                old['lease_state'] = 'busy'
                save(record, old)
                yield compatible, old, record, True
                return
            uncertain = old.get('lease_state') == 'busy'
            cleanup_job(state, boats[0].cli_home, old, record)
            if uncertain:
                raise Failure('previous lease command outcome unknown; cleaned, refusing retry', 74)
        yield boats[0], fresh_job(args, owner), record, False


def lease_live(job, home):
    owner = job.get('owner')
    if owner and owner.get('home') != str(home):
        raise Failure('lease belongs to another home; refusing cleanup', 70)
    return (owner and owner_current(owner) and not job.get('closing') and
            job.get('lease_state') == 'idle' and job.get('cleanup') == 'retained' and
            time.time() < min(job.get('idle_expires', 0), job.get('hard_expires', 0)))


def cleanup_job(state, cli_home, job, record):
    if job.get('cleanup') == 'deleted':
        return
    if job.get('owner') and job['owner'].get('home') != str(state.parent.parent):
        raise Failure('lease belongs to another home; refusing cleanup', 70)
    if job.get('owner'):
        job['lease_state'] = 'closing'
        save(record, job)
    key_file = Path(job.get('account_key_file', str(default_key_file())))
    if not key_file.is_absolute():
        raise Failure('invalid recorded account key path', 70)
    provider = job.get('provider', 'boat')
    if provider == 'upstash':
        Upstash(state, key_file).cleanup(job, record)
    elif provider == 'boat':
        Boat(state, cli_home, Account(key_file)).cleanup(job, record)
    else:
        raise Failure('invalid recorded provider', 70)


def terminate(number, _frame):
    if ACTIVE_CHILD is not None:
        with contextlib.suppress(ProcessLookupError):
            os.killpg(ACTIVE_CHILD.pid, signal.SIGKILL)
    raise _Terminated(128 + number)


def save(path, value):
    staged = path.with_suffix('.tmp')
    with staged.open('w') as handle:
        handle.write(json.dumps(value, indent=2) + '\n')
        handle.flush()
        os.fsync(handle.fileno())
    staged.replace(path)
    directory = os.open(path.parent, os.O_RDONLY)
    try:
        os.fsync(directory)
    finally:
        os.close(directory)


@contextlib.contextmanager
def lock(path, wait=True):
    with path.open('a') as handle:
        try:
            fcntl.flock(handle, fcntl.LOCK_EX | (0 if wait else fcntl.LOCK_NB))
        except BlockingIOError:
            yield False
            return
        yield True


def relative(name):
    p = PurePosixPath(name)
    if not name or p.is_absolute() or '..' in p.parts or str(p) != name or name == '.':
        raise Failure('paths must be normalized relative paths', 2)
    return p


def excluded(name, artifact=False):
    parts = PurePosixPath(name).parts
    dirs = {'.git', '.ssh', '.aws', '.config', '.boat', '.no-mistakes', '.claude', '.codex',
            'node_modules', '.pnpm-store', '.next', '.turbo', 'secrets',
            'credentials', 'playwright-auth', '.auth'}
    if artifact:
        dirs -= {'.next', '.turbo'}
    return any(part.lower() in dirs or part.lower().startswith('.env') or
               part.lower() in {'.npmrc', '.netrc', '.pypirc', 'api-key',
                                'credentials.json', 'auth.json', 'storage-state.json',
                                'storagestate.json', 'id_rsa', 'id_ed25519'} or
               part.lower().endswith(('.pem', '.key', '.p12', '.pfx')) for part in parts)


PROMISOR = 'fm-boat-withheld'
SOURCE_ALLOWLIST = {'.npmrc', '.claude/settings.json', '.claude/settings.local.json',
                    '.claude/settings.example.json',
                    '.claude/commands/reimage-dev.md',
                    '.github/tools/jev/vendor/.claude/agents/security-compliance.md',
                    '.github/tools/jev/vendor/.claude/agents/release-engineer.md'}
# A credential nobody writes by accident: a private-key block, or a key in the
# issued form its provider prints. These say credential whatever surrounds them.
_CREDENTIAL_ISSUED = (
    r"-----BEGIN (?:[A-Z0-9]+ )*PRIVATE KEY-----|"
    r"\b(?:sk-[A-Za-z0-9_-]{12,}|gh[pousr]_[A-Za-z0-9]{20,}|"
    r"github_pat_[A-Za-z0-9_]{20,}|AKIA[0-9A-Z]{16})")
# A credential by its written shape, which a sentence about credentials can
# wear too. Only the established prose phrases "bearer decisions" and
# "bearer shares" are exempt; short tokens and quoted nouns remain screened.
_CREDENTIAL_SHAPED = (
    r"\bbearer\s+(?!(?:decisions|shares)[.,;:]?(?:\s|$))\S+|"
    r"[a-z][a-z0-9+.-]*://[^/\s:@]+:[^/\s@]+@|" + _CREDENTIAL_ISSUED)
# A credential-looking key being assigned, which is a file's shape rather than
# a credential's. The match starts at the key's own first character, which lets
# one exact exception stand: Git's `Co-authored-by:` trailer is a name, not a
# key, and a file carrying commit messages carries it on nearly every merge.
_CREDENTIAL_KEY = (
    r"(?<![\w.-])(?!co-authored-by[\s:=])"
    r"[\w.-]*(?:auth|token|password|passwd|secret|credential|api[_-]?key|"
    r"access[_-]?key|private[_-]?key)[\w.-]*[\"']?\s*[:=]")
# File content: both, because a file is where a key is set.
CREDENTIAL_CONTENT = re.compile(_CREDENTIAL_KEY + "|" + _CREDENTIAL_SHAPED, re.IGNORECASE)
# Commit prose can name commands such as secrets:scan or quote example URLs.
# Explicit credential assignments and bearer tokens still refuse the upload,
# as do issued credentials, because commits cannot be withheld independently.
CREDENTIAL_COMMIT = re.compile(
    _CREDENTIAL_KEY.replace(r"\s*[:=]", r"\s*=") + "|" +
    r"\bbearer\s+(?!(?:decisions|shares)[.,;:]?(?:\s|$))\S+|" +
    _CREDENTIAL_ISSUED, re.IGNORECASE)


def safe_text(data, pattern):
    """True when <data> is UTF-8 text that <pattern> finds no credential in."""
    try:
        text = data.decode('utf-8')
    except UnicodeDecodeError:
        return False
    return not ('\x00' in text or pattern.search(text))


def safe_allowlisted(name, data):
    if not safe_text(data, CREDENTIAL_CONTENT):
        return False
    return not (name == '.npmrc' and
                re.search(r'auth|token', data.decode('utf-8'), re.IGNORECASE))


def git(root, *args, input=None):
    # No user Git aliases, hooks or inherited repository selection.
    env = {k: v for k, v in os.environ.items() if not k.startswith('GIT_')}
    result = subprocess.run(['git', '-C', str(root), *args], env=env, input=input,
                            capture_output=True, check=True)
    return result.stdout


def skip_symlink(name, data, skipped, context):
    if not safe_allowlisted(name, data):
        raise Failure(context + 'credential-looking or binary symlink target: ' + name, 2)
    target = data.decode('utf-8')
    depth = len(PurePosixPath(name).parent.parts)
    if not target or target.startswith('/'):
        raise Failure(context + 'unsafe symlink target: ' + name, 2)
    for part in target.split('/'):
        if part == '..':
            if depth == 0:
                raise Failure(context + 'unsafe symlink target: ' + name, 2)
            depth -= 1
        elif part not in ('', '.'):
            depth += 1
    if name not in skipped:
        print('boat-offload: skipped in-repo symlink: ' + name, file=sys.stderr)
        skipped.add(name)


def history(root, head, depth, destination, key_files, uploaded, skipped):
    try:
        base = git(root, 'rev-parse', '--verify', 'refs/remotes/origin/main^{commit}').decode().strip()
    except subprocess.CalledProcessError as exc:
        raise Failure('history refused: origin/main commit is unavailable', 2) from exc
    fetched = destination / 'fetched'
    exported = destination / 'exported'
    fetched.mkdir()
    exported.mkdir()
    object_format = git(root, 'rev-parse', '--show-object-format').decode().strip()
    for repo in (fetched, exported):
        git(repo, 'init', '--quiet', '--template=', '--object-format=' + object_format)
    # A file transport negotiates shallow boundaries without copying local
    # config, refs, reflogs, stashes, alternates or unrelated object storage.
    git(fetched, '-c', 'protocol.file.allow=always', 'fetch', '--quiet', '--no-tags',
        '--no-write-fetch-head', '--depth=' + str(depth), root.as_uri(), head, base)
    git(fetched, 'update-ref', 'refs/heads/fm-boat-test', head)
    git(fetched, 'symbolic-ref', 'HEAD', 'refs/heads/fm-boat-test')
    git(fetched, 'update-ref', 'refs/remotes/origin/main', base)
    scanned = {}
    kept = set()
    withheld = set()
    screened = []
    for commit in git(fetched, 'rev-list', '--all').splitlines():
        if not safe_text(git(fetched, 'cat-file', 'commit', commit.decode()), CREDENTIAL_COMMIT):
            raise HistoryScreenRefusal('history refused: credential-looking or binary commit: ' +
                                       commit.decode(), 2)
        entries = git(fetched, 'ls-tree', '-rz', '--full-tree', commit.decode()).split(b'\0')
        for entry in filter(None, entries):
            meta, name = entry.split(b'\t', 1)
            name = os.fsdecode(name)
            relative(name)
            mode, kind, oid = meta.split()
            if mode == b'120000' and kind == b'blob':
                try:
                    skip_symlink(name, git(fetched, 'cat-file', 'blob', oid.decode()),
                                 skipped, 'history refused: ')
                except Failure as exc:
                    raise HistoryScreenRefusal(str(exc), exc.code) from exc
                # The pack retains screened target text, never dereferenced content.
                kept.add(oid)
                continue
            # A withheld object keeps its tree entry, so every commit keeps the
            # identity the project's own tooling reads, while its content stays
            # out of the upload.
            if ((excluded(name) and name not in SOURCE_ALLOWLIST) or
                    (root / name).resolve() in key_files or
                    kind != b'blob' or mode not in (b'100644', b'100755')):
                withheld.add(oid)
                continue
            # Bytes the source archive already carries leave this machine anyway.
            if oid in uploaded:
                kept.add(oid)
                continue
            # .npmrc has an additional content rule, even for a reused blob.
            scan_key = (oid, name == '.npmrc')
            if scan_key not in scanned:
                scanned[scan_key] = safe_allowlisted(
                    name, git(fetched, 'cat-file', 'blob', oid.decode()))
                if not scanned[scan_key]:
                    screened.append(name)
            if scanned[scan_key]:
                kept.add(oid)
            else:
                withheld.add(oid)
    # Content a withheld path shares with an uploaded one is already eligible.
    withheld -= kept
    if withheld:
        print('boat-offload: history withheld %d object(s) from the upload, %d of them '
              'screened historical blobs%s' %
              (len(withheld), len(screened),
               '; first ' + screened[0] if screened else ''), file=sys.stderr)
    objects = set(git(fetched, 'rev-list', '--objects', '--no-object-names', '--all').splitlines())
    # Explicit object IDs avoid exporting any extra objects the transport may
    # have sent. pack-objects without --revs never follows shallow parents.
    pack = git(fetched, 'pack-objects', str(exported / '.git/objects/pack/screened'),
               input=b'\n'.join(sorted(objects - withheld)) + b'\n').decode().strip()
    if withheld:
        # Git's own partial-clone marking, as `clone --filter=blob:none` writes
        # it: the pack declares the absent objects promised, so every ordinary
        # ref, ancestry, name and date query works and `fsck` stays clean,
        # while a read of a withheld object's content fails loudly against a
        # promisor remote that carries no URL to reach. The promisor remote is
        # named for what it is rather than `origin`, so nothing can mistake it
        # for the project's own remote.
        (exported / '.git/objects/pack' / ('screened-' + pack + '.promisor')).write_bytes(b'')
        git(exported, 'config', 'core.repositoryformatversion', '1')
        git(exported, 'config', 'extensions.partialclone', PROMISOR)
        git(exported, 'config', 'remote.' + PROMISOR + '.promisor', 'true')
    if (fetched / '.git/shallow').exists():
        shutil.copyfile(fetched / '.git/shallow', exported / '.git/shallow')
    git(exported, 'update-ref', 'refs/heads/fm-boat-test', head)
    git(exported, 'symbolic-ref', 'HEAD', 'refs/heads/fm-boat-test')
    git(exported, 'update-ref', 'refs/remotes/origin/main', base)
    git(exported, 'read-tree', head)
    shutil.rmtree(exported / '.git/logs', ignore_errors=True)
    return exported / '.git'


def source(root, inputs, archive, key_files, history_depth=None):
    head = git(root, 'rev-parse', 'HEAD').decode().strip()
    entries = git(root, 'ls-tree', '-rz', '--full-tree', 'HEAD').split(b'\0')
    names = []
    skipped = set()
    for entry in filter(None, entries):
        meta, name = entry.split(b'\t', 1)
        name = os.fsdecode(name)
        mode, kind, oid = meta.split()
        if mode == b'120000' and kind == b'blob':
            relative(name)
            path = root / name
            for parent in path.parents:
                if parent == root:
                    break
                if parent.is_symlink():
                    raise Failure('source symlink refused: ' + name, 2)
            data = (os.fsencode(os.readlink(path)) if path.is_symlink() else
                    git(root, 'cat-file', 'blob', oid.decode()))
            skip_symlink(name, data, skipped, 'source refused: ')
            continue
        if (excluded(name) and name not in SOURCE_ALLOWLIST) or (root / name).resolve() in key_files:
            continue
        if meta.split()[0] not in (b'100644', b'100755'):
            raise Failure('source contains unsupported symlink or submodule: ' + name, 2)
        names.append(name)
    for name in inputs:
        relative(name)
        if (excluded(name) and name not in SOURCE_ALLOWLIST) or (root / name).resolve() in key_files:
            raise Failure('extra input is a credential/cache path: ' + name, 2)
        if not (root / name).exists():
            raise Failure('extra input missing: ' + name, 2)
        names.append(name)
    object_format = (None if history_depth is None else
                     git(root, 'rev-parse', '--show-object-format').decode().strip())
    try:
        history_result = archive_source(
            root, names, archive, history_depth, key_files, head, object_format, skipped)
    except BaseException:
        archive.unlink(missing_ok=True)
        raise
    return head, hashlib.sha256(archive.read_bytes()).hexdigest(), history_result


class _Hashing:
    def __init__(self, handle, digest):
        self.handle = handle
        self.digest = digest

    def read(self, size=-1):
        chunk = self.handle.read(size)
        self.digest.update(chunk)
        return chunk


def archive_source(root, names, archive, history_depth, key_files, head, object_format, skipped):
    uploaded = set()
    history_result = {'history': 'synthetic'}
    with contextlib.ExitStack() as stack:
        output = stack.enter_context(tarfile.open(archive, 'w:gz', dereference=True))
        for name in sorted(set(names)):
            relative(name)
            path = root / name
            # Deleted tracked files remain deleted. Reject any symlink component.
            for parent in (path, *path.parents):
                if parent == root:
                    break
                if parent.is_symlink():
                    raise Failure('source symlink refused: ' + name, 2)
            if not path.exists():
                continue
            if not path.is_file():
                raise Failure('source input must be a regular file: ' + name, 2)
            if name in SOURCE_ALLOWLIST:
                data = path.read_bytes()
                if not safe_allowlisted(name, data):
                    print('boat-offload: excluded allowlisted file with credential-looking content: ' +
                          name, file=sys.stderr)
                    continue
                info = output.gettarinfo(path, arcname=name)
                info.size = len(data)
                output.addfile(info, io.BytesIO(data))
                if history_depth is not None:
                    digest = hashlib.new(object_format, b'blob %d\0' % info.size)
                    digest.update(data)
                    uploaded.add(digest.hexdigest().encode())
            elif history_depth is None:
                output.add(path, arcname=name, recursive=False)
            else:
                info = output.gettarinfo(path, arcname=name)
                digest = hashlib.new(object_format, b'blob %d\0' % info.size)
                with path.open('rb') as handle:
                    output.addfile(info, _Hashing(handle, digest))
                uploaded.add(digest.hexdigest().encode())
        if history_depth is not None:
            scratch = stack.enter_context(tempfile.TemporaryDirectory(dir=archive.parent, prefix='history-'))
            try:
                history_git = history(root, head, history_depth, Path(scratch), key_files, uploaded, skipped)
            except HistoryScreenRefusal as exc:
                history_result.update(history='fallback-synthetic', history_reason=str(exc))
                print('boat-offload: falling back to synthetic snapshot; ' + str(exc), file=sys.stderr)
            else:
                output.add(history_git, arcname='.git')
                history_result['history'] = 'screened'
    return history_result


def default_key_file():
    return (Path.home() / '.config/boat/api-key').resolve()


def upstash_key_file():
    return (Path.home() / '.config/upstash/box-api-key').resolve()


@dataclass(frozen=True)
class Account:
    key_file: Path
    live_cap: int = 2
    pending_cap: int = 2
    daily_cap: int = 75
    environment: str = ''
    cleanup_confirmation: str = 'deletion'
    types: tuple[str, ...] = ('default',)

    def daily_path(self, state):
        if self.key_file == default_key_file():
            return state / 'daily.json'
        identity = hashlib.sha256(os.fsencode(self.key_file)).hexdigest()
        return state / ('daily-' + identity + '.json')


def accounts(home):
    config = home / 'config/boat-keys'
    if not config.exists():
        if config.is_symlink():
            raise Failure('Boat account configuration unavailable', 2)
        return [Account(default_key_file())]
    parsed = []
    try:
        for line in config.read_text().splitlines():
            fields = shlex.split(line, comments=True)
            if not fields:
                continue
            key_file = Path(fields[0]).expanduser()
            if not key_file.is_absolute():
                raise ValueError('relative key path')
            options = {}
            for field in fields[1:]:
                name, value = field.split('=', 1)
                if name not in ('live_cap', 'pending_cap', 'daily_cap',
                                'environment', 'cleanup_confirmation', 'types') or name in options:
                    raise ValueError('invalid cap field')
                if name.endswith('_cap'):
                    value = int(value)
                    if value < 1:
                        raise ValueError('invalid cap')
                elif name == 'types':
                    value = tuple(value.split(','))
                    if len(set(value)) != len(value) or any(t not in MACHINE_TYPES for t in value):
                        raise ValueError('invalid machine types')
                elif not value or (name == 'cleanup_confirmation' and value not in ('deletion', 'list')):
                    raise ValueError('invalid account option')
                options[name] = value
            account = Account(key_file.resolve(), **options)
            if any(a.key_file == account.key_file for a in parsed):
                raise ValueError('duplicate key path')
            parsed.append(account)
        if not parsed:
            raise ValueError('empty account list')
    except (OSError, ValueError) as exc:
        raise Failure('invalid Boat account configuration', 2) from exc
    return parsed


class Boat:
    def __init__(self, state, cli_home, account):
        self.account = account
        self.state = state
        self.cli_home = cli_home
        self.binary = os.environ.get('FM_BOAT_BIN', 'boat')

    def call(self, *args, timeout=90, raw=False, capture_path=None):
        global ACTIVE_CHILD
        try:
            key = self.account.key_file.read_text().strip()
            if not key:
                raise ValueError('empty key')
        except (OSError, ValueError) as exc:
            raise Failure('Boat key unavailable', 69) from exc
        env = {'PATH': os.environ.get('PATH', '/usr/bin:/bin'),
               'HOME': str(self.cli_home),
               'XDG_CONFIG_HOME': str(self.cli_home / '.config'),
               'BOAT_NO_UPDATE': '1', 'BOAT_API_KEY': key}
        process = None
        out = b''
        try:
            process = subprocess.Popen([self.binary, *args], env=env, stdin=subprocess.DEVNULL,
                                       stdout=subprocess.PIPE,
                                       stderr=subprocess.STDOUT if capture_path else subprocess.PIPE,
                                       start_new_session=True)
            ACTIVE_CHILD = process
            out, err = process.communicate(timeout=max(1, timeout))
            err = err or b''
            if process.returncode:
                # CLI errors can contain credentials or terminal control data.
                detail = (err or out).decode(errors='replace').replace(key, '[REDACTED]')[-2000:]
                raise Failure('Boat request failed: ' + args[0] + ' ' + repr(detail))
            if key.encode() in out or key.encode() in err:
                raise Failure('Boat response contained credential material')
            if raw:
                return out
            if args[0] == 'new':
                frames = [json.loads(line) for line in out.splitlines() if line.strip()]
                return next(frame for frame in reversed(frames) if frame.get('event') == 'ready')
            return json.loads(out)
        except subprocess.TimeoutExpired as exc:
            raise Failure('Boat request unavailable: ' + args[0] +
                          f' (timeout; {type(exc).__name__}; limit={timeout}s)') from exc
        except OSError as exc:
            raise Failure('Boat request unavailable: ' + args[0] +
                          f' (OS error; {type(exc).__name__}; errno={exc.errno})') from exc
        except (ValueError, StopIteration) as exc:
            raise Failure('Boat request unavailable: ' + args[0] +
                          f' (bad response; {type(exc).__name__})') from exc
        finally:
            if process is not None and process.poll() is None:
                with contextlib.suppress(ProcessLookupError):
                    os.killpg(process.pid, signal.SIGKILL)
                out, _ = process.communicate()
            ACTIVE_CHILD = None
            if capture_path is not None:
                capture_path.write_bytes(out.replace(key.encode(), b'[REDACTED]'))

    def listing(self):
        data = self.call('list', '--all', '--json')
        if not isinstance(data.get('sandboxes'), list) or data.get('pageInfo', {}).get('hasMore') is not False:
            raise Failure('Boat listing incomplete; refusing to infer absence')
        return data['sandboxes']

    def upload(self, vm, upload, timeout):
        self.call('push', vm, str(upload), '--to', REMOTE_ROOT,
                  timeout=timeout, raw=True)

    def download(self, vm, remote, destination):
        self.call('scp', vm + ':' + remote, str(destination), raw=True, timeout=180)

    def command(self, vm, argv, remote_timeout=60, timeout=90, capture_path=None):
        # Boat automatically emits JSON when stdout is captured. Blocking exec
        # returns stdout/stderr fields; streaming exec returns typed JSONL frames.
        args = [vm, '--timeout', str(remote_timeout)]
        if capture_path is not None:
            args.append('--stream')
        payload = self.call('exec', *args, '--', *argv, timeout=timeout, raw=True,
                            capture_path=capture_path)
        frames = [json.loads(line) for line in payload.splitlines() if line.strip()]
        output = bytearray()
        streams = {'stdout': bytearray(), 'stderr': bytearray()}
        terminal = None
        for frame in frames:
            if frame.get('type') in ('stdout', 'stderr'):
                data = frame['data'].encode()
                streams[frame['type']].extend(data)
                output.extend(data)
            elif 'exitCode' in frame:
                terminal = frame
                for name in streams:
                    data = frame.get(name, '').encode()
                    streams[name].extend(data)
                    output.extend(data)
        if capture_path is not None:
            capture_path.write_bytes(output)
        sys.stderr.buffer.write(streams['stderr'])
        sys.stderr.buffer.flush()
        if terminal is None or terminal.get('exitCode') != 0 or any(
                terminal.get(field) for field in ('stdoutTruncated', 'stderrTruncated',
                                                  'timedOut', 'launcherFailed', 'oomKilled')):
            raise Failure('Boat command result missing, failed or truncated')
        return bytes(streams['stdout'])

    def cleanup(self, job, record):
        if job['cleanup'] == 'deleted':
            return
        if not job.get('create_started'):
            job['cleanup'] = 'deleted'
            save(record, job)
            return
        if job.get('key_fingerprint'):
            try:
                matches = hashlib.sha256(self.account.key_file.read_bytes()).hexdigest() == job['key_fingerprint']
            except OSError:
                matches = False
            if not matches:
                raise Failure('recorded Boat key changed; cleanup cannot identify account', 70)
        confirmation = job.get('cleanup_confirmation', 'deletion')
        if confirmation not in ('deletion', 'list'):
            raise Failure('invalid recorded cleanup confirmation', 70)
        matches = [vm for vm in self.listing() if vm.get('name') == job['name']]
        if not job.get('vm_id') and len(matches) == 1:
            job['vm_id'] = matches[0]['id']
            save(record, job)
        if len(matches) > 1:
            raise Failure('ambiguous VM name; retained for reap', 70)
        vm_id = job.get('vm_id')
        if vm_id and not re.fullmatch(r'bx_[a-zA-Z0-9]+', vm_id):
            raise Failure('invalid recorded VM id', 70)
        if (vm_id and not job.get('deletion_id') and
                any(vm.get('id') == vm_id for vm in self.listing())):
            deleted = self.call('delete', vm_id, '--yes', '--json', timeout=180)
            # CLI emits a deletion operation object (confirmed by live proof).
            operation = deleted.get('operation', deleted)
            job['deletion_id'] = operation.get('id') or deleted.get('operationId')
            save(record, job)
        if job.get('deletion_id') and confirmation == 'deletion':
            deadline = time.monotonic() + 120
            while True:
                data = self.call('deletion', 'status', job['deletion_id'], '--json')
                operation = data.get('operation', data)
                if operation.get('status') == 'completed':
                    break
                if time.monotonic() >= deadline:
                    raise Failure('deletion not completed; retained for reap', 70)
                time.sleep(2)
        deadline = time.monotonic() + 120
        while vm_id and any(vm.get('id') == vm_id for vm in self.listing()):
            if confirmation != 'list' or time.monotonic() >= deadline:
                raise Failure('VM still listed; retained for reap', 70)
            time.sleep(2)
        # A create that lost its response can appear after the first list. Keep
        # its reservation until the TTL elapses, even if presently absent.
        if not vm_id and job.get('create_started') and time.time() < job['expires']:
            raise Failure('create outcome unknown; retain until TTL and reap', 70)
        job['cleanup'] = 'deleted'
        save(record, job)


class Upstash:
    """Optional official SDK transport for free small ephemeral boxes."""

    base_url = 'https://us-east-1.box.upstash.com'

    def __init__(self, state, key_file):
        self.state = state
        self.key_file = key_file
        self.box = None

    def credentials(self):
        try:
            if stat.S_IMODE(self.key_file.stat().st_mode) != 0o600:
                raise ValueError('key permissions')
            key = self.key_file.read_text().strip()
            if not key:
                raise ValueError('empty key')
            return key
        except (OSError, ValueError) as exc:
            raise Failure('Upstash key unavailable or not mode 0600', 69) from exc

    def sdk(self):
        try:
            from upstash_box import Box, EphemeralBox, __version__
        except ImportError as exc:
            raise Failure('Upstash unavailable: install optional upstash-box==0.4.0', 69) from exc
        if __version__ != '0.4.0':
            raise Failure('Upstash requires the validated optional upstash-box==0.4.0', 69)
        return Box, EphemeralBox

    def options(self, timeout=90):
        return dict(api_key=self.credentials(), base_url=self.base_url,
                    timeout=timeout * 1000, debug=False)

    def request(self, operation, function, *args, **kwargs):
        try:
            return function(*args, **kwargs)
        except Exception as exc:
            # SDK exceptions may include response bodies or authentication data.
            status = getattr(exc, 'status_code', None)
            detail = ' HTTP ' + str(status) if type(status) is int else ''
            message = 'Upstash ' + operation + ' failed' + detail + ' (' + type(exc).__name__ + ')'
            if (operation == 'upload' and type(status) is int and
                    status in (400, 401, 402, 403, 404, 413, 415, 422, 429)):
                raise UploadRejected(message, 75 if status in (402, 429) else 69) from exc
            raise Failure(message,
                          75 if status in (402, 429) else
                          69 if status in (401, 403) else 74) from exc

    def listing(self):
        Box, _ = self.sdk()
        data = self.request('list', Box.list, **self.options())
        if not isinstance(data, list):
            raise Failure('Upstash listing incomplete; refusing to infer absence')
        try:
            items = [item.model_dump() for item in data]
        except (AttributeError, TypeError, ValueError) as exc:
            raise Failure('invalid Upstash listing') from exc
        if any(not isinstance(item.get('id'), str) for item in items):
            raise Failure('Upstash listing missing box identity')
        return [item for item in items if item.get('status') != 'deleted']

    def admit(self, job, record, args, upload_bytes):
        if args.type != 'default' or args.swap_gib:
            raise Failure('Upstash free small is incompatible with requested type or swap', 69)
        if upload_bytes > 100_000_000:
            raise Failure('Upstash source archive exceeds the 100 MB admission limit', 69)
        Box, EphemeralBox = self.sdk()
        with lock(self.state / 'admission.lock'):
            try:
                options = self.options()
                environment = self.request('account environment', Box.list_env, **options)
                if not isinstance(environment, dict) or environment:
                    raise Failure('Upstash requires an empty account environment', 69)
                live = self.listing()
            except Failure as exc:
                raise Failure(str(exc), 69) from exc
            pending = [json.loads(p.read_text()) for p in (self.state / 'jobs').glob('*.json')]
            live_ids = {item['id'] for item in live}
            reserved = sum(p.get('provider') == 'upstash' and p.get('cleanup') != 'deleted'
                           and p.get('account_key_file') == str(self.key_file)
                           and p.get('vm_id') not in live_ids for p in pending)
            if len(live) + reserved >= 10:
                raise Failure('Upstash free concurrent box cap reached', 75)
            # This is a worst-case local reservation, not observed account usage.
            # Never refund early deletion: creation, transfers and other clients
            # make measured command wall time an unsafe quota oracle.
            job['expires'] = time.time() + job['ttl'] + 180
            month = datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m')
            end_month = datetime.datetime.fromtimestamp(
                job['expires'], datetime.timezone.utc).strftime('%Y-%m')
            if end_month != month:
                raise Failure('Upstash local CPU reservation would cross a UTC month', 75)
            identity = hashlib.sha256(os.fsencode(self.key_file)).hexdigest()
            budget_path = self.state / ('upstash-monthly-' + identity + '.json')
            budget = json.loads(budget_path.read_text()) if budget_path.exists() else {}
            used = budget.get('reserved_cpu_seconds', 0) if budget.get('month') == month else 0
            reservation = 2 * (job['ttl'] + 180)
            if type(used) is not int or used < 0:
                raise Failure('invalid Upstash local monthly reservation', 69)
            if used + reservation > 5 * 3600:
                raise Failure('Upstash local free monthly CPU reservation exhausted', 75)
            save(budget_path, dict(month=month, reserved_cpu_seconds=used + reservation))
            job.update(provider='upstash', account_key_file=str(self.key_file),
                       create_started=True, reserved_cpu_seconds=reservation)
            save(record, job)
            try:
                self.box = self.request(
                    'create', EphemeralBox.create, runtime='node', size='small',
                    ttl=job['ttl'], name=job['name'], labels=[job['name'][-20:]], env={},
                    **self.options(timeout=180))
            except Failure as exc:
                if exc.code in (69, 75):
                    save(budget_path, dict(month=month, reserved_cpu_seconds=used))
                    job['create_started'] = False
                    job['reserved_cpu_seconds'] = 0
                    save(record, job)
                raise
            if (not isinstance(self.box.id, str) or
                    not re.fullmatch(r'[a-zA-Z0-9][a-zA-Z0-9_-]{0,127}', self.box.id)):
                raise Failure('Upstash create returned no valid box id')
            job['vm_id'] = self.box.id
            save(record, job)

    def connect(self, vm, timeout=90):
        Box, _ = self.sdk()
        return self.request('connect', Box.get, vm, **self.options(timeout))

    def upload(self, vm, upload, timeout):
        deadline = time.monotonic() + timeout

        def remaining():
            seconds = int(deadline - time.monotonic())
            if seconds < 1:
                raise Failure('Upstash upload deadline exceeded')
            return seconds

        with self.connect(vm, remaining()) as box:
            paths = str(PurePosixPath(REMOTE_ROOT).parent) + ' ' + REMOTE_ROOT
            prepare = ('if [ "$(id -u)" = 0 ]; then install -d -m 700 ' + paths +
                       '; else sudo -n install -d -m 700 -o "$(id -u)" -g "$(id -g)" ' +
                       paths + '; fi')
            prepared = self.request('prepare canonical source root', box.exec.command, prepare)
            if prepared.exit_code != 0:
                raise Failure('Upstash cannot prepare canonical /home/user/fm-job '
                              '(exit ' + str(prepared.exit_code) + ')')
        paths = []
        # The service rejected even 16 MiB despite advertising 100 MB per file.
        # Keep each request below the empirically productive 9.4 MB transfer.
        with tempfile.TemporaryDirectory(dir=upload, prefix='upstash-parts-') as scratch:
            part = Path(scratch) / 'source.part'
            with (upload / 'source.tar.gz').open('rb') as source_file:
                for index, data in enumerate(iter(lambda: source_file.read(8 * 1024 * 1024), b'')):
                    part.write_bytes(data)
                    remote = REMOTE_ROOT + '/source.part-%06d' % index
                    with self.connect(vm, remaining()) as box:
                        self.request('upload', box.files.upload,
                                     [dict(path=str(part), destination=remote)])
                    paths.append(remote)
            seconds = remaining()
            self.command(vm, ['bash', '-c', 'cat -- ' + shlex.join(paths) + ' > ' +
                              REMOTE_ROOT + '/source.tar.gz && rm -- ' + shlex.join(paths)],
                         remote_timeout=min(60, seconds), timeout=seconds)

    def read(self, box, path):
        encoded = self.request('read', box.files.read, path, encoding='base64')
        try:
            data = base64.b64decode(encoded, validate=True)
        except (ValueError, TypeError) as exc:
            raise Failure('Upstash returned invalid file encoding') from exc
        metadata = self.request('stat', box.files.stat, path)
        if type(metadata.size) is not int or metadata.size != len(data):
            raise Failure('Upstash file result missing or truncated')
        if self.credentials().encode() in data:
            raise Failure('Upstash response contained credential material')
        return data

    def download(self, vm, remote, destination):
        with self.connect(vm, 180) as box:
            destination.write_bytes(self.read(box, remote))

    def command(self, vm, argv, remote_timeout=60, timeout=90, capture_path=None):
        prefix = REMOTE_ROOT + '/transport-' + uuid.uuid4().hex
        script = (shlex.join(argv) + ' >' + prefix + '.out 2>' + prefix + '.err; '
                  'rc=$?; printf "%s" "$rc" >' + prefix + '.exit')
        with self.connect(vm, timeout) as box:
            self.request('exec', box.exec.command,
                         'timeout -k 15 ' + str(remote_timeout) + ' sh -c ' + shlex.quote(script))
            stdout = self.read(box, prefix + '.out')
            stderr = self.read(box, prefix + '.err')
            if capture_path is not None:
                capture_path.write_bytes(stdout + stderr)
            status = self.read(box, prefix + '.exit')
        sys.stderr.buffer.write(stderr)
        sys.stderr.buffer.flush()
        if status != b'0':
            raise Failure('Upstash command result missing, failed or timed out')
        return stdout

    def cleanup(self, job, record):
        if job['cleanup'] == 'deleted':
            return
        if not job.get('create_started'):
            job['cleanup'] = 'deleted'
            save(record, job)
            return
        live = self.listing()
        matches = [item for item in live if item.get('name') == job['name']
                   and job['name'][-20:] in (item.get('labels') or [])]
        if len(matches) > 1:
            raise Failure('ambiguous Upstash box name; retained for reap', 70)
        if not job.get('vm_id') and matches:
            job['vm_id'] = matches[0]['id']
            save(record, job)
        vm = job.get('vm_id')
        if vm and not re.fullmatch(r'[a-zA-Z0-9][a-zA-Z0-9_-]{0,127}', vm):
            raise Failure('invalid recorded Upstash box id', 70)
        if vm and any(item['id'] == vm for item in live):
            with self.connect(vm, 180) as box:
                self.request('delete', box.delete)
            if any(item['id'] == vm for item in self.listing()):
                raise Failure('Upstash box still listed; retained for reap', 70)
        if not vm and time.time() < job['expires']:
            raise Failure('Upstash create outcome unknown; retain until TTL and reap', 70)
        if self.box is not None:
            self.box.close()
        job['cleanup'] = 'deleted'
        save(record, job)


def admit(boats, job, record):
    state = boats[0].state
    with lock(state / 'admission.lock'):
        pending = [json.loads(p.read_text()) for p in (state / 'jobs').glob('*.json')]
        failures = []
        for boat in boats:
            account = boat.account
            reserved = sum(p.get('cleanup') != 'deleted' and
                           p.get('account_key_file', str(default_key_file())) == str(account.key_file)
                           for p in pending)
            if reserved >= account.pending_cap:
                failures.append(Failure('Boat pending cap reached', 75))
                continue
            try:
                limits = boat.call('limits', '--json')
                live = boat.listing()
                if len(live) >= account.live_cap:
                    raise Failure('Boat live cap reached', 75)
                if limits.get('canStart') is False or limits.get('nextStartDollars', 0) != 0:
                    raise Failure('Boat cannot start within the included budget', 75)
                starts = limits.get('starts', {})
                for window in ('minute', 'hour', 'day'):
                    remaining = starts.get(window, {}).get('remaining')
                    if not isinstance(remaining, int):
                        raise Failure('Boat start budget unavailable', 69)
                    if remaining < 1:
                        raise Failure('Boat ' + window + ' start cap reached', 75)
                daily_path = account.daily_path(state)
                today = datetime.datetime.now(datetime.timezone.utc).date().isoformat()
                daily = json.loads(daily_path.read_text()) if daily_path.exists() else {}
                used = daily.get('attempts', 0) if daily.get('date') == today else 0
                if used >= account.daily_cap:
                    raise Failure('local daily start cap reached', 75)
            except Failure as exc:
                failures.append(Failure(str(exc), 69 if exc.code != 75 else 75))
                continue
            save(daily_path, {'date': today, 'attempts': used + 1})
            job.update(create_started=True, account_key_file=str(account.key_file),
                       cleanup_confirmation=account.cleanup_confirmation,
                       environment=account.environment,
                       key_fingerprint=hashlib.sha256(account.key_file.read_bytes()).hexdigest())
            save(record, job)
            try:
                create_args = ['new', '--type', job['type'], '--ttl', str(job['ttl']),
                               '--no-env', '--no-snapshots', '--name', job['name'], '--json']
                if account.environment:
                    create_args.extend(['--environment', account.environment])
                created = boat.call(*create_args, timeout=180)
                vm = created.get('sandbox', created)
                vm_id = vm.get('id') or created.get('sandboxId')
                if not isinstance(vm_id, str) or not re.fullmatch(r'bx_[a-zA-Z0-9]+', vm_id):
                    raise Failure('Boat create returned no valid VM id')
                job['vm_id'] = vm_id
                save(record, job)
            except Failure as exc:
                raise Failure(str(exc), 69) from exc
            return boat
        if len(boats) == 1:
            raise failures[0]
        raise Failure('no Boat account available',
                      69 if any(f.code == 69 for f in failures) else 75)


def artifacts(boat, vm, names, output):
    if not names:
        return
    # Build archive remotely without following links. Validate each requested
    # member again locally before creating any files under the output directory.
    script = '''import pathlib,tarfile,sys
root=pathlib.Path(sys.argv[1])/'source'
with tarfile.open(root.parent/'artifacts.tar.gz',mode='w:gz') as t:
 for name in sys.argv[2:]:
  p=root/name
  if not p.exists(): raise RuntimeError('missing artifact')
  for f in [p,*p.rglob('*')] if p.is_dir() else [p]:
   if f.is_symlink() or any(x.is_symlink() for x in f.parents if x!=root): raise RuntimeError('artifact symlink')
   if not (f.is_dir() or f.is_file()): raise RuntimeError('special artifact')
   t.add(f,arcname=str(f.relative_to(root)),recursive=False)
'''
    boat.command(vm, ['python3', '-c', script, REMOTE_ROOT, *names],
                 remote_timeout=120, timeout=180)
    downloaded = output / 'artifacts.tar.gz'
    boat.download(vm, REMOTE_ROOT + '/artifacts.tar.gz', downloaded)
    with tarfile.open(downloaded, mode='r:gz') as archive:
        members = archive.getmembers()
        for member in members:
            relative(member.name)
            if excluded(member.name, artifact=True) or not (member.isfile() or member.isdir()) or not any(
                    member.name == name or member.name.startswith(name + '/') for name in names):
                raise Failure('unsafe returned artifact')
        target = output / 'artifacts'
        target.mkdir()
        for member in members:
            path = target / member.name
            if member.isdir():
                path.mkdir(parents=True, exist_ok=True)
            else:
                path.parent.mkdir(parents=True, exist_ok=True)
                with archive.extractfile(member) as src, path.open('wb') as dest:
                    shutil.copyfileobj(src, dest)


def run(args, boats):
    boat = boats[0]
    try:
        root = Path(args.worktree).resolve(strict=True)
        top = Path(os.fsdecode(git(root, 'rev-parse', '--show-toplevel')).strip()).resolve()
    except (OSError, subprocess.SubprocessError) as exc:
        raise Failure('--worktree must name an existing git root', 2) from exc
    if top != root:
        raise Failure('--worktree must name the git root', 2)
    output = Path(args.output).resolve()
    if output == root or root in output.parents:
        raise Failure('--output must be outside the source tree', 2)
    try:
        output.mkdir(parents=True, exist_ok=False)
    except OSError as exc:
        raise Failure('--output must be a new writable directory', 2) from exc
    result = {'kind': 'invalid', 'remote_exit': None, 'cleanup': 'not-created',
              'swap_gib': args.swap_gib, 'provider': 'boat',
              'requested_type': args.type, 'actual_size': args.type}
    job = None
    code = 2
    try:
        eligible = [b for b in boats if args.type in b.account.types]
        if not eligible:
            raise Failure('no Boat account permits machine type ' + args.type +
                          '; configure types= in config/boat-keys', 2)
        for name in args.artifact:
            relative(name)
            if excluded(name, artifact=True):
                raise Failure('credential/cache artifact refused', 2)
        upload = output / 'upload'
        upload.mkdir()
        head, digest, history_result = source(
            root, args.input, upload / 'source.tar.gz',
            {upstash_key_file(), *(b.account.key_file for b in boats)}, args.history_depth)
        result.update(history_result)
        # Boat push honors enclosing gitignore rules. OUTPUT commonly lives in
        # ignored data/; a private index makes this one archive an explicit input
        # without changing the source repository or transferring its .git.
        git(upload, 'init', '--quiet')
        git(upload, 'add', '--force', '--', 'source.tar.gz')
        upload_bytes = (upload / 'source.tar.gz').stat().st_size
        # Allow 90s setup plus 128 KiB/s, within the existing TTL's transfer margin.
        push_timeout = min(600, max(300, 90 + (upload_bytes + 131071) // 131072))
        result.update(source_head=head, source_sha256=digest,
                      upload_bytes=upload_bytes, push_timeout_seconds=push_timeout)
        owner = task_owner(boat.state.parent.parent, os.environ.get('FM_TASK_ID'), root)
        if owner:
            result['lease'] = dict(owner=owner, state='busy', id=job_path(boat.state, owner).stem)
        with allocation(args, boats, owner) as (boat, job, record, reused):
            succeeded = False
            try:
                result['kind'] = 'unavailable'
                try:
                    try:
                        if not reused:
                            boat = admit(eligible, job, record)
                    except Failure as exc:
                        if job['create_started'] or exc.code not in (69, 75):
                            raise
                        result['boat_unavailable'] = str(exc)
                        # A missing optional key preserves the original Boat
                        # refusal and exit classification for existing callers.
                        key_file = upstash_key_file()
                        if not key_file.exists():
                            raise
                        boat = Upstash(boat.state, key_file)
                        job.update(owner=None, ttl=args.timeout + 900)
                        result.pop('lease', None)
                        result.update(provider='upstash', actual_size='small',
                                      resources=dict(cpu=2, memory_gib=4, disk_gib=10))
                        boat.admit(job, record, args, upload_bytes)
                finally:
                    if job.get('account_key_file') and job.get('provider') != 'upstash':
                        boat = next(b for b in boats if str(b.account.key_file) == job['account_key_file'])
                vm = job['vm_id']
                result.update(vm_id=vm, kind='adapter-error', reused=reused,
                              creates=0 if reused else 1)
                remote_root = REMOTE_ROOT
                try:
                    prepare_source(boat, job, args, upload, digest, push_timeout, reused)
                except Failure:
                    if not job.get('owner') or job.get('provider') != 'boat':
                        raise
                    boat.cleanup(job, record)
                    job = fresh_job(args, None)
                    boat = admit(eligible, job, record)
                    vm = job['vm_id']
                    reused = False
                    result.update(vm_id=vm, reused=False, creates=result['creates'] + 1,
                                  reuse_fallback=True)
                    prepare_source(boat, job, args, upload, digest, push_timeout, False)
                command = shlex.join(args.command)
                remote = (f'cd {remote_root}/source || exit 125; '
                          f'env -i PATH="$PATH" HOME={str(PurePosixPath(remote_root).parent)} CI=1 '
                          'NEXT_TELEMETRY_DISABLED=1 '
                          f'timeout -k 15 {args.timeout} {command}; '
                          f'rc=$?; printf "%s" "$rc" > {remote_root}/exit')
                result['kind'] = 'execution-unknown'
                if job.get('owner') and job.get('provider') == 'boat':
                    job['execution_started'] = True
                    save(record, job)
                    data = owned_processes(boat, job, 'run', args, output)
                else:
                    data = boat.command(vm, ['bash', '-c', remote],
                                 remote_timeout=args.timeout + 30,
                                 timeout=args.timeout + 90,
                                 capture_path=output / 'command.log')
                sys.stdout.buffer.write(data)
                sys.stdout.buffer.flush()
                status = boat.command(vm, ['cat', remote_root + '/exit'], remote_timeout=30)
                if not re.fullmatch(rb'[0-9]{1,3}', status.strip()) or int(status) > 255:
                    raise Failure('remote exit marker missing or invalid')
                code = int(status)
                result.update(kind='completed', remote_exit=code)
                artifacts(boat, vm, args.artifact, output)
                succeeded = True
            except Failure as exc:
                if result['kind'] == 'unavailable' and job['create_started']:
                    result['kind'] = 'adapter-error'
                result['execution_error'] = str(exc)
                raise
            finally:
                # Ignore a second interrupt while deleting; SIGKILL still leaves
                # the durable job record and bounded provider TTL.
                for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
                    signal.signal(sig, signal.SIG_IGN)
                try:
                    if job.get('account_key_file') and job.get('provider') == 'boat':
                        boat = next(b for b in boats if str(b.account.key_file) == job['account_key_file'])
                    retain = (succeeded and job.get('owner') and job.get('provider') == 'boat'
                              and owner_current(job['owner']) and
                              time.time() + LEASE_IDLE < job['hard_expires'])
                    if retain:
                        owned_processes(boat, job, 'finish')
                        try:
                            retain = compute_available(boat, LEASE_IDLE, args.type)
                        except Failure:
                            retain = False
                    if retain:
                        job.update(cleanup='retained', lease_state='idle',
                                   idle_expires=time.time() + LEASE_IDLE,
                                   commands=job.get('commands', 0) + 1)
                        save(record, job)
                        start_expiry(record)
                        result.update(cleanup='retained', lease=dict(
                            owner=job['owner'], state='idle', id=record.stem,
                            idle_expires=job['idle_expires'], hard_expires=job['hard_expires']))
                    else:
                        boat.cleanup(job, record)
                        result['cleanup'] = 'deleted'
                except Failure as exc:
                    result.update(cleanup='pending', cleanup_error=str(exc))
                    raise Failure('cleanup unconfirmed; run reap', 70) from exc
    except Failure as exc:
        result['error'] = str(exc)
        code = exc.code
        if (isinstance(exc, UploadRejected) and result['provider'] == 'upstash' and
                result['kind'] == 'adapter-error' and job and job.get('vm_id') and
                result['cleanup'] == 'deleted'):
            result['kind'] = 'unavailable'
    except _Terminated as exc:
        result.update(kind='interrupted', error='interrupted')
        code = exc.code
    except (OSError, ValueError, subprocess.SubprocessError, tarfile.TarError) as exc:
        result.update(kind='adapter-error', error=type(exc).__name__)
        code = 74
    finally:
        result['adapter_exit'] = code
        save(output / 'result.json', result)
    if result.get('error'):
        print('boat-offload: ' + result['error'], file=sys.stderr)
    return code


def main():
    if sys.argv[1:] in (['--help'], ['-h'], []):
        print(Path(__file__).with_suffix('.sh').read_text().split('set -euo')[0])
        return 0
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='action', required=True)
    sub.add_parser('reap')
    expiry = sub.add_parser('expire', help=argparse.SUPPRESS)
    expiry.add_argument('--lease', required=True)
    cleanup = sub.add_parser('cleanup-task')
    cleanup.add_argument('--task', required=True)
    cleanup.add_argument('--generation', required=True)
    runner = sub.add_parser('run')
    runner.add_argument('--worktree', required=True)
    runner.add_argument('--output', required=True)
    runner.add_argument('--input', action='append', default=[])
    runner.add_argument('--artifact', action='append', default=[])
    runner.add_argument('--timeout', type=int, default=1800)
    runner.add_argument('--type', choices=MACHINE_TYPES, default='default')
    runner.add_argument('--swap-gib', type=int, choices=range(5), default=0)
    runner.add_argument('--history-depth', type=int, default=None)
    runner.add_argument('command', nargs=argparse.REMAINDER)
    args = parser.parse_args()
    home = Path(os.environ.get('FM_HOME', ''))
    if not home.is_absolute():
        raise Failure('FM_HOME must be explicit and absolute', 2)
    home = home.resolve()
    os.umask(0o077)
    state = home / 'state/boat-offload'
    (state / 'jobs').mkdir(parents=True, exist_ok=True)
    if args.action == 'run' and args.command[:1] == ['--']:
        args.command.pop(0)
    if args.action == 'run' and (not args.command or not 1 <= args.timeout <= 2700):
        raise Failure('command required; timeout must be 1..2700 seconds', 2)
    if args.action == 'run' and args.history_depth is not None and not 1 <= args.history_depth <= 1000:
        raise Failure('history depth must be 1..1000', 2)
    for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(sig, terminate)
    if args.action == 'expire':
        if not re.fullmatch(r'task-[a-f0-9]{64}', args.lease):
            raise Failure('invalid lease record', 2)
        record = state / 'jobs' / (args.lease + '.json')
        with lock(state / (args.lease + '.expiry.lock'), wait=False) as acquired:
            if not acquired:
                return 0
            while record.exists():
                with lock(state / (record.stem + '.lock'), wait=False) as held:
                    if held:
                        job = json.loads(record.read_text())
                        if job.get('cleanup') == 'deleted':
                            return 0
                        if not lease_live(job, home):
                            break
                time.sleep(30)
            else:
                return 0
        # Reap rechecks under the job lock; a new command may have arrived.
        args.action = 'reap'
        args.only_lease = record
    # Boat derives SSH ControlPath from HOME. A long operational-home path
    # exceeds Unix socket limits even though all ordinary files fit there.
    with tempfile.TemporaryDirectory(prefix='fmb.', dir='/tmp') as cli_home:
        os.chmod(cli_home, 0o700)
        if args.action == 'cleanup-task':
            owner = task_owner(home, args.task)
            identity = dict(home=str(home), task=args.task)
            record = job_path(state, identity)
            if owner is None or owner['generation'] != args.generation:
                if record.exists():
                    prior = json.loads(record.read_text())
                    closed = prior.get('closing') or {}
                    if (prior.get('cleanup') == 'deleted' and closed.get('home') == str(home)
                            and closed.get('task') == args.task and closed.get('generation') == args.generation):
                        return 0
                    raise Failure('task cleanup ownership cannot be confirmed', 70)
                return 0
            with lock(state / (record.stem + '.lock'), wait=False) as acquired:
                if not acquired:
                    raise Failure('task Boat command active; retry cleanup after it finishes', 70)
                if not owner_current(owner):
                    raise Failure('task ownership changed during cleanup', 70)
                job = json.loads(record.read_text()) if record.exists() else dict(cleanup='deleted')
                if job.get('owner') and (job['owner'].get('home') != str(home)
                                          or job['owner'].get('task') != args.task):
                    raise Failure('task cleanup differs from recorded lease owner', 70)
                job['closing'] = owner
                save(record, job)
                cleanup_job(state, Path(cli_home), job, record)
            return 0
        if args.action == 'reap':
            failed = False
            for record in sorted((state / 'jobs').glob('*.json')):
                if getattr(args, 'only_lease', record) != record:
                    continue
                with lock(state / (record.stem + '.lock'), wait=False) as acquired:
                    if not acquired:
                        continue
                    try:
                        job = json.loads(record.read_text())
                        if not lease_live(job, home):
                            cleanup_job(state, Path(cli_home), job, record)
                    except Failure as exc:
                        print('boat-offload: ' + str(exc), file=sys.stderr)
                        failed = True
            return 70 if failed else 0
        return run(args, [Boat(state, Path(cli_home), a) for a in accounts(home)])


if __name__ == '__main__':
    try:
        sys.exit(main())
    except Failure as error:
        print('boat-offload: ' + str(error), file=sys.stderr)
        sys.exit(error.code)
    except _Terminated as error:
        sys.exit(error.code)
