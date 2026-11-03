import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import types
import contextlib
import io
sys.dont_write_bytecode = True
repo = Path.cwd()
base = types.ModuleType('boat_before')
sys.modules[base.__name__] = base
text = subprocess.check_output(['git', 'show', '433d50d9804ef94050035222005edc3bb71b04a7:bin/fm-boat-run.py'])
exec(compile(text, 'boat-before.py', 'exec'), base.__dict__)
spec = importlib.util.spec_from_file_location('boat_after', repo / 'bin/fm-boat-run.py')
head = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = head
spec.loader.exec_module(head)
with tempfile.TemporaryDirectory(prefix='boat-regression-', dir=repo / '.fm-test-scratch') as scratch:
    root = Path(scratch) / 'source'
    root.mkdir()
    def git(*args):
        return subprocess.check_output(['git', '-C', str(root), *args], stderr=subprocess.DEVNULL)
    git('init', '-q', '--template=')
    git('config', 'user.name', 'Disposable validation')
    git('config', 'user.email', 'validation@example.invalid')
    (root / 'app.txt').write_text('current source\n')
    git('add', '.')
    git('commit', '-qm', 'historical fixture POSTGRES_PASSWORD=postgres')
    git('commit', '--allow-empty', '-qm', 'clean tip')
    git('update-ref', 'refs/remotes/origin/main', 'HEAD')
    report = {}
    for label, module in [('before', base), ('after', head)]:
        archive = Path(scratch) / (label + '.tar.gz')
        notice = io.StringIO()
        with contextlib.redirect_stderr(notice):
            try:
                value = module.source(root, [], archive, set(), 50)
            except module.Failure as exc:
                report[label] = {'error': str(exc), 'code': exc.code, 'archive_exists': archive.exists()}
            else:
                report[label] = {'history_result': value[2], 'archive_exists': archive.exists(), 'notice': notice.getvalue()}
    assert report['before']['code'] == 2 and not report['before']['archive_exists']
    assert report['after']['history_result']['history'] == 'fallback-synthetic'
    assert report['after']['archive_exists']
    print(json.dumps(report, indent=2))
