import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import types

repo = Path.cwd()
evidence = Path('~/.no-mistakes/evidence/01M6FBF89KPQW92H8D5PG5G513')
reports = []

def git(root, *args):
    return subprocess.run(['git', '-C', str(root), *args], check=True, capture_output=True).stdout

with tempfile.TemporaryDirectory(prefix='.boat-screening-', dir=repo) as scratch:
    base = Path(scratch)
    home = base / 'home'
    home.mkdir()
    env = dict(os.environ, HOME=str(home), FM_HOME=str(home), PYTHONDONTWRITEBYTECODE='1')
    # An explicit absent disposable key prevents all remote calls and operator-data reads.
    (home / 'config').mkdir()
    (home / 'config/boat-keys').write_text(str(base / 'absent-key') + '\n')

    def fixture(name, contents, path='.agents/skills/verify-app/features.md', commit_message='document review states'):
        root = base / name
        root.mkdir()
        git(root, 'init', '-q', '--template=')
        git(root, 'config', 'user.name', 'Screening Check')
        git(root, 'config', 'user.email', 'screening@example.invalid')
        target = root / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(contents)
        git(root, 'add', '.')
        git(root, 'commit', '-qm', commit_message)
        git(root, 'update-ref', 'refs/remotes/origin/main', 'HEAD')
        return root

    def launch(root, label, depth):
        output = base / ('output-' + label)
        command = ['bash', str(repo / 'bin/fm-boat-run.sh'), 'run', '--worktree', str(root),
                   '--output', str(output), *(['--history-depth', str(depth)] if depth else []), '--', 'true']
        run = subprocess.run(command, env=env, capture_output=True, timeout=30)
        result = json.loads((output / 'result.json').read_text())
        return run, result, output

    prose = ('| State | Notes |\n|' + '-' * 680 + '|---|\n'
             '| blocked | blocked bearer decisions, pending review |\n'
             '| transfer | The bearer shares are transferable. |\n').encode()
    root = fixture('prose', prose)
    # Preserve the prose in an ancestor as well as the tip.
    (root / 'new.txt').write_text('clean descendant\n')
    git(root, 'add', '.')
    git(root, 'commit', '-qm', 'clean descendant')
    for depth in (1, 2, 8):
        run, result, output = launch(root, 'prose-' + str(depth), depth)
        assert result['kind'] == 'unavailable', (run.returncode, run.stderr, result)
        assert b'Boat key unavailable' in run.stderr, run.stderr
        assert 'source_sha256' in result, result
        archive = output / 'upload/source.tar.gz'
        with tarfile.open(archive) as tar:
            assert tar.extractfile('.agents/skills/verify-app/features.md').read() == prose
            # Extract the generated product artifact, including screened Git history.
            exported = base / ('exported-' + str(depth))
            exported.mkdir()
            tar.extractall(exported, filter='data')
            assert git(exported, 'show', 'HEAD:.agents/skills/verify-app/features.md') == prose
            assert git(exported, 'show', 'origin/main:.agents/skills/verify-app/features.md') == prose
            commits = git(exported, 'rev-list', '--all', '--count').decode().strip()
        reports.append({'scenario':'prose archive', 'depth':depth, 'screening':'accepted',
                        'archive_file_bytes':len(prose), 'exported_commits':int(commits),
                        'cli_exit':run.returncode, 'remote_boundary':'Boat key unavailable (intentionally isolated)'})
        if depth == 2:
            (evidence / 'screened-archive-manifest.txt').write_text('\n'.join(tarfile.open(archive).getnames()) + '\n')

    # Counterfactual executes the prior production exporter against the identical Git repository.
    old = types.ModuleType('previous_boat_screening')
    old.__file__ = str(repo / 'bin/fm-boat-run.py')
    sys.modules[old.__name__] = old
    source = git(repo, 'show', '8c8bd9464e651a0634c7de245f5bbc867751fb7e:bin/fm-boat-run.py')
    exec(compile(source, old.__file__, 'exec'), old.__dict__)
    try:
        old.source(root, [], base / 'previous.tar.gz', set(), 2)
    except old.Failure as exc:
        assert 'credential-looking or binary blob: .agents/skills/verify-app/features.md' in str(exc), str(exc)
        reports.append({'scenario':'before-fix reproduction', 'screening':'refused', 'message':str(exc)})
    else:
        raise AssertionError('Prior exporter did not reproduce the reported rejection')

    cases = [
        ('short-bearer', b'Bearer a9F2k7Q4m8X\n'),
        ('single-bearer', b'Bearer x\n'),
        ('decision-prefix', b'Bearer decisions-private\n'),
        ('shares-prefix', b'Bearer shares-private\n'),
        ('quoted-decision', b'{"header":"Bearer decisions"}\n'),
        ('jwt', b'Bearer eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJmaXh0dXJlIn0.signature\n'),
        ('private-key', b'-----BEGIN RSA PRIVATE KEY-----\n'),
        ('secret-assignment', b'API_SECRET=fixture-only\n'),
        ('binary', b'\x00fixture-only'),
    ]
    for label, contents in cases:
        root = fixture(label, contents)
        # Remove from the tip: the guard must catch the ancestor, not just current files.
        target = root / '.agents/skills/verify-app/features.md'
        git(root, 'rm', str(target.relative_to(root)))
        (root / 'clean.txt').write_text('clean descendant\n')
        git(root, 'add', '.')
        git(root, 'commit', '-qm', 'remove unsafe ancestor file')
        git(root, 'update-ref', 'refs/remotes/origin/main', 'HEAD')
        run, result, output = launch(root, label, 2)
        assert run.returncode == 2 and result['kind'] == 'invalid', (label, run.stderr, result)
        assert b'history refused:' in run.stderr, (label, run.stderr)
        assert not (output / 'upload/source.tar.gz').exists(), label
        assert not contents.strip() in run.stdout + run.stderr, label
        reports.append({'scenario':label, 'cli_exit':run.returncode, 'screening':'refused before archive/remote',
                        'message':run.stderr.decode().strip()})
    root = fixture('commit-credential', b'clean documentation\n', commit_message='Bearer a9F2k7Q4m8X')
    run, result, output = launch(root, 'commit-credential', 2)
    assert run.returncode == 2 and b'binary commit' in run.stderr, (run.stderr, result)
    assert b'a9F2k7Q4m8X' not in run.stdout + run.stderr
    reports.append({'scenario':'commit credential', 'cli_exit':run.returncode, 'screening':'refused', 'message':run.stderr.decode().strip()})
    for label, content, include in [
        ('settings-clean', b'{"permissions":{"allow":["Bash(npm test)"]}}', True),
        ('settings-short', b'{"header":"Bearer a9F2k7Q4m8X"}', False),
        ('settings-quoted', b'{"header":"Bearer decisions"}', False),
        ('settings-prefix', b'{"header":"Bearer shares-private"}', False),
    ]:
        root = fixture(label, content, path='.claude/settings.json')
        run, result, output = launch(root, label, None)
        assert run.returncode == 69 and result['kind'] == 'unavailable', (label, run.stderr, result)
        with tarfile.open(output / 'upload/source.tar.gz') as archive:
            assert ('.claude/settings.json' in archive.getnames()) == include, label
        if not include:
            assert b'excluded allowlisted file' in run.stderr, label
            assert content not in run.stdout + run.stderr, label
        reports.append({'scenario':label, 'archive_includes_settings':include,
                        'cli_exit':run.returncode, 'remote_boundary':'isolated missing key'})
    for record in (home / 'state/boat-offload/jobs').glob('*.json'):
        assert not json.loads(record.read_text()).get('create_started'), 'unexpected remote creation'
(evidence / 'boat-screening-results.json').write_text(json.dumps(reports, indent=2) + '\n')
for report in reports:
    print(json.dumps(report))
