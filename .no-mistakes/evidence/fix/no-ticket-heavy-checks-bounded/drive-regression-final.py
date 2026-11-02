import os, pathlib, subprocess, tempfile
root=pathlib.Path.cwd()
with tempfile.TemporaryDirectory(dir=root/'state', prefix='test-routing-') as tmp:
 p=pathlib.Path(tmp); tool=p/'actionlint'
 tool.write_text('#!/bin/sh\nif [ "$1" = -version ]; then printf "1.7.12\\n"; exit 0; fi\nprintf "%s\\n" "ci.yml: could not parse as YAML (injected analyzer response)" >&2\nexit 1\n')
 tool.chmod(0o755)
 source=(root/'tests/fm-lint-workflows.test.sh').read_text()
 source=source.split('\ntest_pins_an_explicit_version\n')[0]
 source=source.replace('. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"', '. tests/lib.sh')
 source+='\nfor mode in present missing nonexecutable; do test_fm_lint_default_path_catches_broken_ci_yml "$mode"; done\n'
 env=dict(os.environ, PATH=str(p)+os.pathsep+os.environ['PATH'], TMPDIR=str(p), FM_TEST_SCRATCH_ROOT=str(p), FM_BUILD_LOCK_FILE=str(p/'pool'), FM_BUILD_LOCK_INSTALL_DIR=str(p/'install'))
 env.pop('FM_BUILD_LOCK_HELD',None); env.pop('FM_BUILD_LOCK_BYPASS',None)
 print('Automated boundary check: real lint orchestration; injected ShellCheck and workflow analyzer responses. No actual linter executed. Does not prove YAML parsing.',flush=True)
 r=subprocess.run(['bash','-c',source],env=env,text=True,capture_output=True,timeout=45)
 print(r.stdout); print(r.stderr); print('exit',r.returncode)
 assert r.returncode==0
