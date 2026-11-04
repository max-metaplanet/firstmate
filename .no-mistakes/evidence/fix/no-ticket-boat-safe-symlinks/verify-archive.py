import json, os, pathlib, subprocess, tarfile, tempfile

root = pathlib.Path.cwd()
evidence = pathlib.Path('~/.no-mistakes/evidence/01M6KGR63PE0SXR8W47T3PRM85')
records = []
def git(work, *args):
    return subprocess.run(['git', '-C', str(work), *args], check=True, capture_output=True).stdout.decode().strip()
with tempfile.TemporaryDirectory(prefix='.archive-validation-', dir=root) as scratch:
    base = pathlib.Path(scratch)
    for label in ['safe', 'filtered', 'missing', 'cycle', 'chain-escape', 'escaping', 'absolute', 'explicit-input']:
        case = base / label
        work = case / 'repo'
        work.mkdir(parents=True)
        home = case / 'home'
        home.mkdir()
        git(work, 'init', '-q')
        git(work, 'config', 'user.name', 'Archive validation')
        git(work, 'config', 'user.email', 'validation@example.invalid')
        (work / '.agents/skills/test-plan').mkdir(parents=True)
        (work / '.agents/skills/test-plan/SKILL.md').write_text('Test-plan fixture\n')
        (work / '.claude').mkdir()
        (work / 'tracked.txt').write_text('committed\n')
        expected = {}
        omitted = []
        refused = label in ['escaping', 'absolute']
        if label == 'safe':
            expected = {'.claude/skills': '../.agents/skills', 'file-link': 'tracked.txt', 'chain': 'file-link'}
        elif label == 'filtered':
            (work / '.env.fixture').write_text('private fixture bytes\n')
            (work / '.claude/settings.json').write_text('{"API_SECRET":"synthetic-fixture-material"}\n')
            (work / 'only-filtered').mkdir()
            (work / 'only-filtered/.env').write_text('private\n')
            expected = {'env-link': '.env.fixture', 'content-link': '.claude/settings.json', 'dir-link': 'only-filtered'}
            omitted = list(expected) + ['.env.fixture', '.claude/settings.json', 'only-filtered/.env']
        elif label == 'missing':
            expected = {'missing-link': 'missing.txt', 'unselected-link': 'extra.txt'}
            omitted = list(expected) + ['extra.txt']
        elif label == 'cycle':
            expected = {'a': 'b', 'b': 'a'}
            omitted = list(expected)
        elif label == 'chain-escape':
            expected = {'a': '.', 'b': 'a/../repo/tracked.txt'}
            omitted = ['b']
        elif label == 'escaping':
            expected = {'link': '../outside'}
        elif label == 'absolute':
            expected = {'link': str(work / 'tracked.txt')}
        else:
            expected = {'input-link': 'extra.txt'}
        for name, target in expected.items():
            (work / name).symlink_to(target)
        git(work, 'add', '--force', '.')
        git(work, 'commit', '-qm', 'archive fixture')
        head = git(work, 'rev-parse', 'HEAD')
        (work / 'tracked.txt').write_text('current working bytes\n')
        (work / 'extra.txt').write_text('explicit bytes\n')
        env = dict(os.environ, HOME=str(home), FM_HOME=str(home), FM_BOAT_BIN='/bin/false')
        for key in ['FM_ROOT_OVERRIDE', 'FM_STATE_OVERRIDE', 'FM_DATA_OVERRIDE', 'FM_CONFIG_OVERRIDE', 'FM_PROJECTS_OVERRIDE', 'FM_TASK_ID']:
            env.pop(key, None)
        argv = ['bash', str(root / 'bin/fm-boat-run.sh'), 'run', '--worktree', str(work), '--output', str(case / 'output')]
        if label == 'explicit-input':
            argv += ['--input', 'extra.txt']
        argv += ['--', 'true']
        run = subprocess.run(argv, env=env, capture_output=True, text=True, timeout=15)
        result = json.loads((case / 'output/result.json').read_text())
        record = dict(scenario=label, exit=run.returncode, stderr=run.stderr.strip(), result=result)
        archive = case / 'output/upload/source.tar.gz'
        if refused:
            assert run.returncode == 2 and 'unsafe symlink target' in run.stderr, record
            assert not archive.exists(), record
            record['observable'] = 'Unsafe target refused before any source archive or provider allocation.'
        else:
            assert run.returncode == 69 and 'Boat key unavailable' in run.stderr, record
            assert result['source_head'] == head, record
            with tarfile.open(archive) as tar:
                members = {m.name: m for m in tar.getmembers()}
                assert not set(omitted) & members.keys(), record
                for name, target in expected.items():
                    if name not in omitted:
                        assert members[name].issym() and members[name].linkname == target, (label, name)
                record['archive_members'] = [{ 'name': m.name, 'type': 'symlink' if m.issym() else 'file', 'target': m.linkname } for m in members.values()]
                extracted = case / 'extracted'
                extracted.mkdir()
                tar.extractall(extracted, filter='data')
                assert (extracted / 'tracked.txt').read_text() == 'current working bytes\n'
                if label == 'safe':
                    record['read_through_skill_link'] = (extracted / '.claude/skills/test-plan/SKILL.md').read_text()
                    assert record['read_through_skill_link'] == 'Test-plan fixture\n'
                    assert (extracted / 'chain').read_text() == 'current working bytes\n'
                if label == 'explicit-input':
                    assert (extracted / 'input-link').read_text() == 'explicit bytes\n'
            record['observable'] = 'Actual CLI archive extracted; link types, target text, admitted bytes and exclusions match intent.'
        assert not result.get('vm_id'), record
        records.append(record)
        print(json.dumps(record), flush=True)
(evidence / 'archive-results.json').write_text(json.dumps(records, indent=2) + '\n')
