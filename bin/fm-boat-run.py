#!/usr/bin/env python3
"""Boat adapter implementation. Public contract: fm-boat-run.sh --help."""

import argparse
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


class _Terminated(BaseException):
    def __init__(self, code):
        self.code = code


ACTIVE_CHILD = None


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


SOURCE_ALLOWLIST = {'.npmrc', '.claude/settings.json', '.claude/settings.local.json',
                    '.claude/settings.example.json'}
CREDENTIAL_CONTENT = re.compile(
    r"[\w.-]*(?:auth|token|password|passwd|secret|credential|api[_-]?key|"
    r"access[_-]?key|private[_-]?key)[\w.-]*[\"']?\s*[:=]|"
    r"\bbearer\s+\S+|-----BEGIN (?:[A-Z0-9]+ )*PRIVATE KEY-----|"
    r"https?://[^/\s:@]+:[^/\s@]+@|"
    r"\b(?:sk-[A-Za-z0-9_-]{12,}|gh[pousr]_[A-Za-z0-9]{20,}|"
    r"github_pat_[A-Za-z0-9_]{20,}|AKIA[0-9A-Z]{16})",
    re.IGNORECASE)


def safe_allowlisted(name, data):
    try:
        text = data.decode('utf-8')
    except UnicodeDecodeError:
        return False
    return not ('\x00' in text or CREDENTIAL_CONTENT.search(text) or
                (name == '.npmrc' and re.search(r'auth|token', text, re.IGNORECASE)))


def git(root, *args):
    # No user Git aliases, hooks or inherited repository selection.
    env = {k: v for k, v in os.environ.items() if not k.startswith('GIT_')}
    result = subprocess.run(['git', '-C', str(root), *args], env=env,
                            capture_output=True, check=True)
    return result.stdout


def source(root, inputs, archive, key_files):
    head = git(root, 'rev-parse', 'HEAD').decode().strip()
    entries = git(root, 'ls-tree', '-rz', '--full-tree', 'HEAD').split(b'\0')
    names = []
    for entry in filter(None, entries):
        meta, name = entry.split(b'\t', 1)
        name = os.fsdecode(name)
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
    with tarfile.open(archive, 'w:gz', dereference=True) as output:
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
            else:
                output.add(path, arcname=name, recursive=False)
    return head, hashlib.sha256(archive.read_bytes()).hexdigest()


def default_key_file():
    return (Path.home() / '.config/boat/api-key').resolve()


@dataclass(frozen=True)
class Account:
    key_file: Path
    live_cap: int = 2
    pending_cap: int = 2
    daily_cap: int = 75
    environment: str = ''
    cleanup_confirmation: str = 'deletion'

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
                                'environment', 'cleanup_confirmation') or name in options:
                    raise ValueError('invalid cap field')
                if name.endswith('_cap'):
                    value = int(value)
                    if value < 1:
                        raise ValueError('invalid cap')
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
        except (OSError, subprocess.TimeoutExpired, ValueError, StopIteration) as exc:
            raise Failure('Boat request unavailable: ' + args[0]) from exc
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

    def command(self, *args, timeout=90, capture_path=None):
        # Boat automatically emits JSON when stdout is captured. Blocking exec
        # returns stdout/stderr fields; streaming exec returns typed JSONL frames.
        payload = self.call('exec', *args, timeout=timeout, raw=True,
                            capture_path=capture_path)
        frames = [json.loads(line) for line in payload.splitlines() if line.strip()]
        output = bytearray()
        terminal = None
        for frame in frames:
            if frame.get('type') in ('stdout', 'stderr'):
                output.extend(frame['data'].encode())
            elif 'exitCode' in frame:
                terminal = frame
                output.extend(frame.get('stdout', '').encode())
                output.extend(frame.get('stderr', '').encode())
        if capture_path is not None:
            capture_path.write_bytes(output)
        if terminal is None or terminal.get('exitCode') != 0 or any(
                terminal.get(field) for field in ('stdoutTruncated', 'stderrTruncated',
                                                  'timedOut', 'launcherFailed', 'oomKilled')):
            raise Failure('Boat command result missing, failed or truncated')
        return bytes(output)

    def cleanup(self, job, record):
        if job['cleanup'] == 'deleted':
            return
        if not job.get('create_started'):
            job['cleanup'] = 'deleted'
            save(record, job)
            return
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
                       cleanup_confirmation=account.cleanup_confirmation)
            save(record, job)
            try:
                create_args = ['new', '--type', 'default', '--ttl', str(job['ttl']),
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
root=pathlib.Path('/home/user/fm-job/source')
with tarfile.open('/home/user/fm-job/artifacts.tar.gz',mode='w:gz') as t:
 for name in sys.argv[1:]:
  p=root/name
  if not p.exists(): raise RuntimeError('missing artifact')
  for f in [p,*p.rglob('*')] if p.is_dir() else [p]:
   if f.is_symlink() or any(x.is_symlink() for x in f.parents if x!=root): raise RuntimeError('artifact symlink')
   if not (f.is_dir() or f.is_file()): raise RuntimeError('special artifact')
   t.add(f,arcname=str(f.relative_to(root)),recursive=False)
'''
    boat.command(vm, '--timeout', '120', '--', 'python3', '-c', script,
                 *names, timeout=180)
    downloaded = output / 'artifacts.tar.gz'
    boat.call('scp', vm + ':/home/user/fm-job/artifacts.tar.gz', str(downloaded),
              raw=True, timeout=180)
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
              'swap_gib': args.swap_gib}
    job = None
    code = 2
    try:
        for name in args.artifact:
            relative(name)
            if excluded(name, artifact=True):
                raise Failure('credential/cache artifact refused', 2)
        upload = output / 'upload'
        upload.mkdir()
        head, digest = source(root, args.input, upload / 'source.tar.gz',
                              {b.account.key_file for b in boats})
        # Boat push honors enclosing gitignore rules. OUTPUT commonly lives in
        # ignored data/; a private index makes this one archive an explicit input
        # without changing the source repository or transferring its .git.
        git(upload, 'init', '--quiet')
        git(upload, 'add', '--force', '--', 'source.tar.gz')
        result.update(source_head=head, source_sha256=digest)
        job_id = uuid.uuid4().hex
        record = boat.state / 'jobs' / (job_id + '.json')
        job = {'name': 'fm-offload-' + job_id, 'vm_id': None, 'cleanup': 'pending',
               'ttl': args.timeout + 900, 'expires': time.time() + args.timeout + 1080,
               'create_started': False}
        with lock(boat.state / (job_id + '.lock')):
            try:
                result['kind'] = 'unavailable'
                try:
                    boat = admit(boats, job, record)
                finally:
                    if job.get('account_key_file'):
                        boat = next(b for b in boats if str(b.account.key_file) == job['account_key_file'])
                vm = job['vm_id']
                result.update(vm_id=vm, kind='adapter-error')
                boat.call('push', vm, str(upload), '--to', '/home/user/fm-job', timeout=300, raw=True)
                boat.command(vm, '--timeout', '60', '--', 'bash', '-c',
                          f'echo {digest} /home/user/fm-job/source.tar.gz | sha256sum -c - && '
                          'mkdir -p /home/user/fm-job/source && tar xzf /home/user/fm-job/source.tar.gz -C /home/user/fm-job/source',
                          timeout=90)
                if args.swap_gib:
                    boat.command(vm, '--timeout', '60', '--', 'bash', '-c',
                                 f'sudo -n fallocate -l {args.swap_gib}G /swapfile-fm-offload && '
                                 'sudo -n chmod 600 /swapfile-fm-offload && '
                                 'sudo -n mkswap /swapfile-fm-offload && '
                                 'sudo -n swapon /swapfile-fm-offload')
                command = shlex.join(args.command)
                remote = ('cd /home/user/fm-job/source || exit 125; '
                          'env -i PATH="$PATH" HOME=/home/user CI=1 '
                          'NEXT_TELEMETRY_DISABLED=1 '
                          f'timeout -k 15 {args.timeout} {command}; '
                          'rc=$?; printf "%s" "$rc" > /home/user/fm-job/exit')
                result['kind'] = 'execution-unknown'
                data = boat.command(vm, '--timeout', str(args.timeout + 30),
                                 '--stream', '--', 'bash', '-c', remote,
                                 timeout=args.timeout + 90,
                                 capture_path=output / 'command.log')
                sys.stdout.buffer.write(data)
                sys.stdout.buffer.flush()
                status = boat.command(vm, '--timeout', '30', '--', 'cat',
                                      '/home/user/fm-job/exit')
                if not re.fullmatch(rb'[0-9]{1,3}', status.strip()) or int(status) > 255:
                    raise Failure('remote exit marker missing or invalid')
                code = int(status)
                result.update(kind='completed', remote_exit=code)
                artifacts(boat, vm, args.artifact, output)
            except Failure as exc:
                result['execution_error'] = str(exc)
                raise
            finally:
                # Ignore a second interrupt while deleting; SIGKILL still leaves
                # the durable job record and bounded provider TTL.
                for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
                    signal.signal(sig, signal.SIG_IGN)
                try:
                    boat.cleanup(job, record)
                except Failure as exc:
                    result.update(cleanup='pending', cleanup_error=str(exc))
                    raise Failure('cleanup unconfirmed; run reap', 70) from exc
                result['cleanup'] = 'deleted'
    except Failure as exc:
        result['error'] = str(exc)
        code = exc.code
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
    runner = sub.add_parser('run')
    runner.add_argument('--worktree', required=True)
    runner.add_argument('--output', required=True)
    runner.add_argument('--input', action='append', default=[])
    runner.add_argument('--artifact', action='append', default=[])
    runner.add_argument('--timeout', type=int, default=1800)
    runner.add_argument('--swap-gib', type=int, choices=range(5), default=0)
    runner.add_argument('command', nargs=argparse.REMAINDER)
    args = parser.parse_args()
    home = Path(os.environ.get('FM_HOME', ''))
    if not home.is_absolute():
        raise Failure('FM_HOME must be explicit and absolute', 2)
    os.umask(0o077)
    state = home / 'state/boat-offload'
    (state / 'jobs').mkdir(parents=True, exist_ok=True)
    if args.action == 'run' and args.command[:1] == ['--']:
        args.command.pop(0)
    if args.action == 'run' and (not args.command or not 1 <= args.timeout <= 2700):
        raise Failure('command required; timeout must be 1..2700 seconds', 2)
    for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(sig, terminate)
    # Boat derives SSH ControlPath from HOME. A long operational-home path
    # exceeds Unix socket limits even though all ordinary files fit there.
    with tempfile.TemporaryDirectory(prefix='fmb.', dir='/tmp') as cli_home:
        os.chmod(cli_home, 0o700)
        if args.action == 'reap':
            failed = False
            for record in sorted((state / 'jobs').glob('*.json')):
                with lock(state / (record.stem + '.lock'), wait=False) as acquired:
                    if not acquired:
                        continue
                    try:
                        job = json.loads(record.read_text())
                        key_file = Path(job.get('account_key_file', str(default_key_file())))
                        if not key_file.is_absolute():
                            raise Failure('invalid recorded account key path', 70)
                        Boat(state, Path(cli_home), Account(key_file)).cleanup(job, record)
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
