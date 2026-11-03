import contextlib
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile

sys.dont_write_bytecode = True
repo = Path.cwd()
evidence = Path('~/.no-mistakes/evidence/01M6FND4HQKP7721YDSGR6AAAN')
spec = importlib.util.spec_from_file_location('boat_adapter', repo / 'bin/fm-boat-run.py')
boat = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = boat
spec.loader.exec_module(boat)
# Execute the production wrapper's remote bootstrap verbatim, locally. There
# is no Boat CLI substitute, no VM, and no replacement for any source function.
wrapper = (repo / 'bin/fm-boat-test-wrapper.sh').read_text()
bootstrap = wrapper.split("remote=$(cat <<'REMOTE'\n", 1)[1].split('\nREMOTE\n)', 1)[0]
results = []

def git(root, *args, check=True):
    return subprocess.run(['git', '-C', str(root), *args], check=check,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                          env={**os.environ, 'GIT_CONFIG_GLOBAL': '/dev/null',
                               'GIT_CONFIG_NOSYSTEM': '1'}).stdout.decode().strip()

with tempfile.TemporaryDirectory(prefix='boat-source-live-', dir=repo / '.fm-test-scratch') as scratch:
    scratch = Path(scratch)
    def init(name):
        root = scratch / name
        root.mkdir()
        git(root, 'init', '-q', '--template=')
        git(root, 'config', 'user.name', 'Disposable validation')
        git(root, 'config', 'user.email', 'validation@example.invalid')
        (root / 'app.txt').write_text('committed current source\n')
        commit(root, 'initial source')
        return root
    def commit(root, message):
        git(root, 'add', '-A')
        git(root, 'commit', '--allow-empty', '-qm', message)
        return git(root, 'rev-parse', 'HEAD')
    def package(root, depth=50):
        archive = scratch / (root.name + '.tar.gz')
        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr):
            value = boat.source(root, [], archive, set(), depth)
        assert value[1] == hashlib.sha256(archive.read_bytes()).hexdigest()
        return archive, value, stderr.getvalue()
    def unpack(archive, name):
        dest = scratch / (name + '-extracted')
        dest.mkdir()
        with tarfile.open(archive) as tf:
            tf.extractall(dest, filter='data')
            names = tf.getnames()
        return dest, names
    def record(name, **data):
        row = {'scenario': name, **data}
        results.append(row)
        print(json.dumps(row), flush=True)
    def bootstrap_check(dest, synthetic):
        expected = 'refs/fm-boat/no-local-history' if synthetic else 'refs/remotes/origin/main'
        command = '''set -eu
printf 'base_ref=%s\\n' "$PIPELINE_TEST_BASE_REF"
printf 'history_commits=%s\\n' "$(git rev-list --count --all)"
printf 'source='; cat app.txt
printf 'base_tree='; git ls-tree origin/main
'''
        env = {k: v for k, v in os.environ.items() if not k.startswith(('GIT_', 'FM_'))}
        out = subprocess.run(['bash', '-c', bootstrap, 'production-bootstrap', command], cwd=dest,
                             env=env, capture_output=True, text=True, timeout=20)
        assert out.returncode == 0, out.stderr
        assert 'base_ref=' + expected in out.stdout
        if synthetic:
            assert git(dest, 'ls-tree', 'origin/main') == ''
            assert git(dest, 'log', '--all', '--format=%B').splitlines() == [
                'Adapter-filtered test source', '', 'Empty conservative test base']
            missing = subprocess.run(['git', 'rev-parse', '--verify', expected], cwd=dest,
                                     capture_output=True)
            assert missing.returncode != 0
        return out.stdout, out.stderr

    for name, unsafe_message in [('credential-commit', 'old fixture POSTGRES_PASSWORD=postgres'),
                                 ('binary-commit', 'old binary message\x01')]:
        root = init(name)
        if name == 'binary-commit':
            # Non-UTF8 Git commit message, valid as a Git object but not safe text.
            tree = git(root, 'write-tree')
            parent = git(root, 'rev-parse', 'HEAD')
            raw = (f'tree {tree}\nparent {parent}\nauthor Fixture <a@example.invalid> 1000000000 +0000\ncommitter Fixture <a@example.invalid> 1000000000 +0000\n\n'.encode() + b'old binary \xff\n')
            bad = subprocess.run(['git', '-C', str(root), 'hash-object', '-t', 'commit', '-w', '--stdin'], input=raw, capture_output=True, check=True).stdout.decode().strip()
            git(root, 'update-ref', 'HEAD', bad)
        else:
            bad = commit(root, unsafe_message)
        commit(root, 'clean current tip')
        git(root, 'update-ref', 'refs/remotes/origin/main', 'HEAD')
        (root / 'app.txt').write_text('dirty current source\n')
        archive, value, notice = package(root)
        dest, names = unpack(archive, name)
        assert value[2]['history'] == 'fallback-synthetic'
        assert bad in value[2]['history_reason']
        assert not any(n == '.git' or n.startswith('.git/') for n in names)
        assert (dest / 'app.txt').read_text() == 'dirty current source\n'
        assert 'POSTGRES_PASSWORD' not in notice and '\ufffd' not in notice
        assert notice.count('falling back to synthetic snapshot') == 1
        output, bootstrap_notice = bootstrap_check(dest, True)
        record(name, history=value[2], notice=notice, archive_members=names,
               bootstrap_output=output, bootstrap_notice=bootstrap_notice)

    root = init('historical-unsafe-link')
    (root / 'old-link').symlink_to('/outside-disposable-root')
    commit(root, 'old unsafe link')
    (root / 'old-link').unlink()
    commit(root, 'remove unsafe link')
    git(root, 'update-ref', 'refs/remotes/origin/main', 'HEAD')
    archive, value, notice = package(root)
    dest, names = unpack(archive, root.name)
    assert value[2]['history'] == 'fallback-synthetic' and 'old-link' in notice
    assert not (dest / '.git').exists()
    record(root.name, history=value[2], notice=notice, archive_members=names)

    root = init('screened-historical-blob')
    (root / 'fixture.sh').write_text('POSTGRES_PASSWORD=postgres\n')
    old = commit(root, 'old fixture')
    oid = git(root, 'rev-parse', old + ':fixture.sh')
    (root / 'fixture.sh').unlink()
    commit(root, 'remove old fixture')
    git(root, 'update-ref', 'refs/remotes/origin/main', 'HEAD')
    archive, value, notice = package(root)
    dest, names = unpack(archive, root.name)
    assert value[2]['history'] == 'screened'
    read = subprocess.run(['git', 'cat-file', 'blob', oid], cwd=dest, capture_output=True)
    assert read.returncode != 0
    assert git(dest, 'rev-parse', 'HEAD') == git(root, 'rev-parse', 'HEAD')
    assert 'history withheld' in notice and 'POSTGRES_PASSWORD' not in notice
    record(root.name, history=value[2], notice=notice, withheld_blob_read_exit=read.returncode,
           preserved_head=git(dest, 'rev-parse', 'HEAD'))

    root = init('safe-prose-and-Claude-history')
    (root / '.claude/commands').mkdir(parents=True)
    (root / '.claude/commands/reimage-dev.md').write_text('# Development\nBearer decisions and bearer shares.\n')
    (root / '.agents/skills').mkdir(parents=True)
    (root / '.agents/skills/guide.md').write_text('# Safe guide\n')
    (root / '.claude/skills').symlink_to('../.agents/skills')
    old = commit(root, 'bearer decisions and bearer shares; secrets:scan')
    (root / '.claude/skills').unlink()
    commit(root, 'remove historical safe link')
    git(root, 'update-ref', 'refs/remotes/origin/main', old)
    archive, value, notice = package(root)
    dest, names = unpack(archive, root.name)
    assert value[2]['history'] == 'screened'
    assert git(dest, 'show', old + ':.claude/skills') == '../.agents/skills'
    assert 'Bearer decisions' in git(dest, 'show', old + ':.claude/commands/reimage-dev.md')
    output, bootstrap_notice = bootstrap_check(dest, False)
    record(root.name, history=value[2], notice=notice, bootstrap_output=output,
           bootstrap_notice=bootstrap_notice, safe_historical_link=git(dest, 'show', old + ':.claude/skills'))

    for name in ('missing-base', 'unsafe-current-link'):
        root = init(name)
        if name == 'unsafe-current-link':
            git(root, 'update-ref', 'refs/remotes/origin/main', 'HEAD')
            (root / 'current-link').symlink_to('/outside-disposable-root')
            commit(root, 'unsafe current link')
        archive = scratch / (name + '.tar.gz')
        stderr = io.StringIO()
        try:
            with contextlib.redirect_stderr(stderr):
                boat.source(root, [], archive, set(), 50)
        except boat.Failure as exc:
            assert type(exc) is boat.Failure
            assert exc.code == 2
            assert not archive.exists()
            assert 'falling back' not in stderr.getvalue()
            record(name, refused=str(exc), code=exc.code, archive_exists=archive.exists())
        else:
            raise AssertionError('Required boundary refusal was swallowed: ' + name)

(evidence / 'boat-source-live-results.json').write_text(json.dumps(results, indent=2) + '\n')
