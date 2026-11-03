import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import sys
import tarfile
import tempfile

sys.dont_write_bytecode = True
repo = Path.cwd()
spec = importlib.util.spec_from_file_location('boat_adapter', repo / 'bin/fm-boat-run.py')
boat = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = boat
spec.loader.exec_module(boat)
# The recorded decision specifically requests read-only screening of this
# supplied source path. No Git writes, index refresh, VM, or source edits.
root = Path('~/firstmate/projects/core')
log = io.StringIO()
with tempfile.TemporaryDirectory(prefix='core-depth50-', dir=repo / '.fm-test-scratch') as scratch:
    archive = Path(scratch) / 'source.tar.gz'
    with contextlib.redirect_stderr(log):
        head, sha256, result = boat.source(root, [], archive, set(), 50)
    with tarfile.open(archive) as tf:
        names = tf.getnames()
    assert result['history'] in ('screened', 'fallback-synthetic')
    if result['history'] == 'fallback-synthetic':
        assert not any(n == '.git' or n.startswith('.git/') for n in names)
        assert 'falling back to synthetic snapshot' in log.getvalue()
    report = dict(source=str(root), depth=50, source_head=head, source_sha256=sha256,
                  history_result=result, notice=log.getvalue(), archive_bytes=archive.stat().st_size,
                  archive_member_count=len(names), git_included=any(n == '.git' or n.startswith('.git/') for n in names),
                  boat_vm_used=False, source_writes=False)
    print(json.dumps(report, indent=2))
