"""Hermetic boundary fixture for the optional official Upstash SDK."""

import base64
import json
import os
from pathlib import Path
import shutil
import subprocess
from types import SimpleNamespace


__version__ = '0.4.0'
root = Path(os.environ['FM_UPSTASH_FIXTURE_ROOT'])


class BoxError(Exception):
    def __init__(self, message, status_code=None):
        super().__init__(message)
        self.status_code = status_code


def settings():
    return json.loads((root / 'upstash.json').read_text())


def event(operation, **data):
    with (root / 'upstash-calls.jsonl').open('a') as log:
        log.write(json.dumps(dict(operation=operation, **data)) + '\n')


def options(values):
    assert values.pop('api_key') == 'upstash_fixture_secret'
    assert values.pop('base_url') == 'https://us-east-1.box.upstash.com'
    assert type(values.pop('timeout')) is int
    assert values.pop('debug') is False
    assert not values, values


def listing():
    path = root / 'upstash-vms.json'
    return json.loads(path.read_text()) if path.exists() else []


def write_listing(items):
    (root / 'upstash-vms.json').write_text(json.dumps(items))


class Files:
    def __init__(self, box):
        self.box = box

    def path(self, path):
        assert path.startswith('/home/user/fm-job/') or path == '/home/user/fm-job'
        return self.box.directory / path.removeprefix('/home/user/')

    def mkdir(self, path, *, parents=False):
        self.path(path).mkdir(parents=parents, exist_ok=parents)

    def upload(self, files):
        event('upload')
        if settings().get('upload_error'):
            raise BoxError('upstash_fixture_secret upload failed')
        for file in files:
            shutil.copyfile(file['path'], self.path(file['destination']))

    def read(self, path, *, encoding=None):
        assert encoding == 'base64'
        data = self.path(path).read_bytes()
        if settings().get('secret_output') and path.endswith('.out'):
            data = b'upstash_fixture_secret'
        return base64.b64encode(data).decode()

    def stat(self, path):
        size = self.path(path).stat().st_size
        if settings().get('secret_output') and path.endswith('.out'):
            size = len(b'upstash_fixture_secret')
        if settings().get('truncated') and path.endswith('.out'):
            size += 1
        return SimpleNamespace(size=size)


class Exec:
    def __init__(self, box):
        self.box = box

    def command(self, command):
        event('exec')
        if command.startswith('if [ "$(id -u)" = 0 ]; then install -d -m 700 '):
            assert '/home/user/fm-job' in command and 'sudo -n install' in command
            (self.box.directory / 'fm-job').mkdir(exist_ok=True)
            return SimpleNamespace(exit_code=0, stdout='', stderr='')
        if settings().get('missing_marker'):
            (self.box.directory / 'fm-job/exit').unlink(missing_ok=True)
        command = command.replace('/home/user/fm-job', str(self.box.directory / 'fm-job'))
        command = command.replace('HOME=/home/user', 'HOME=' + str(self.box.directory))
        result = subprocess.run(['sh', '-c', command], cwd=self.box.directory,
                                env={'PATH': os.environ['PATH']}, capture_output=True)
        if settings().get('unknown_exec') and '/source || exit 125' in command:
            raise BoxError('upstash_fixture_secret lost execution response')
        return SimpleNamespace(exit_code=result.returncode,
                               stdout=result.stdout.decode(), stderr=result.stderr.decode())


class Box:
    def __init__(self, identity):
        self.id = identity
        self.directory = root / ('upstash-files-' + identity)
        self.directory.mkdir(exist_ok=True)
        self.files = Files(self)
        self.exec = Exec(self)

    def __enter__(self):
        return self

    def __exit__(self, *_args):
        self.close()

    def close(self):
        pass

    @classmethod
    def list(cls, **kwargs):
        options(kwargs)
        event('list')
        if settings().get('list_error'):
            raise BoxError('upstash_fixture_secret list failed')
        return [SimpleNamespace(model_dump=lambda value=item: value) for item in listing()]

    @classmethod
    def list_env(cls, **kwargs):
        options(kwargs)
        event('list_env')
        return {'SECRET': 'upstash_fixture_secret'} if settings().get('account_env') else {}

    @classmethod
    def get(cls, identity, **kwargs):
        options(kwargs)
        event('get')
        return cls(identity)

    def delete(self):
        event('delete', identity=self.id)
        if settings().get('delete_error'):
            raise BoxError('upstash_fixture_secret cleanup failed')
        if not settings().get('still_listed'):
            write_listing([item for item in listing() if item['id'] != self.id])


class EphemeralBox:
    @classmethod
    def create(cls, *, runtime, size, ttl, name, labels, env, **kwargs):
        options(kwargs)
        assert runtime == 'node' and size == 'small'
        assert 1 <= ttl <= 3600 and env == {} and labels == [name[-20:]]
        assert len(labels) <= 5 and all(len(label) <= 20 for label in labels)
        event('create', runtime=runtime, size=size, ttl=ttl, name=name, labels=labels, env=env)
        status = settings().get('create_rejected')
        if status:
            raise BoxError('upstash_fixture_secret rejected', status)
        identity = 'small-' + name
        write_listing([*listing(), dict(id=identity, name=name, labels=labels, status='idle')])
        if settings().get('lost_create'):
            raise BoxError('upstash_fixture_secret lost create response')
        return Box(identity)
