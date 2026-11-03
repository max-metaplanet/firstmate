#!/usr/bin/env bash
# Privacy contract for the mirror capture filter, against real capture shapes.
set -euo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
work=$(fm_test_tmproot fm-t3-redact)
python3 - "$ROOT" "$work" <<'PY'
from pathlib import Path
import subprocess
import sys

root, work = map(Path, sys.argv[1:])
filter_path = root / 'bin' / 'fm-t3-redact.py'


def redact(text, *args):
    result = subprocess.run([sys.executable, str(filter_path), *args], input=text,
                            capture_output=True, text=True, timeout=20)
    assert result.returncode == 0, result.stderr
    return result.stdout


# A Claude Code pane as a real capture renders it: ANSI colour, box drawing,
# a spinner, a tool call that echoed an export, and ordinary prose.
claude_pane = (
    "\x1b[2m╭──────────────────────────────────────────╮\x1b[0m\n"
    "\x1b[2m│\x1b[0m \x1b[1m>\x1b[0m run the deploy check                 \x1b[2m│\x1b[0m\n"
    "\x1b[2m╰──────────────────────────────────────────╯\x1b[0m\n"
    "\x1b[32m●\x1b[0m Bash(scripts/deploy-check.sh)\n"
    "  \x1b[2m⎿\x1b[0m  + export VERCEL_TOKEN=prj_9f2Ab7Qz1XcV0mNk4LpR8sTu\n"
    "     + curl -H 'Authorization: Bearer "
    "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJkZXBsb3kifQ.KxP7Qb2Vn4Rd9Lm0Xe3Zc8Aa1Bb2Cc3Dd4Ee5Ff6Gg' \\\n"
    "       https://api.example.com/v1/deploy\n"
    "     deploy check passed in 4.2s\n"
    "\x1b[2m✻\x1b[0m Thinking… (3s · ↑ 1.2k tokens)\n"
    "  Updated src/deploy/check.ts:118 and re-ran the suite.\n")
lines = redact(claude_pane).splitlines()
joined = '\n'.join(lines)
assert 'prj_9f2Ab7Qz1XcV0mNk4LpR8sTu' not in joined
assert 'eyJhbGciOiJIUzI1NiJ9' not in joined
assert '\x1b' not in joined and '\x07' not in joined
assert '[redacted]' in joined, joined
assert any('deploy check passed in 4.2s' == line.strip() for line in lines), joined
assert any('src/deploy/check.ts:118' in line for line in lines), joined
assert any('run the deploy check' in line for line in lines), joined
print('ok - a real Claude pane keeps its readable output and loses its credentials')

# A git/gh tool log, an .env diff, and an ssh/aws style dump: the shapes a
# worker most often prints while doing ordinary delivery work.
tool_log = (
    "remote: Pushing to https://x-access-token:ghs_K1l2M3n4O5p6Q7r8S9t0U1v2W3x4Y5@github.com/acme/app\n"
    "+ GITHUB_TOKEN=ghp_AbCdEf0123456789AbCdEf0123456789\n"
    "diff --git a/.env.local b/.env.local\n"
    "+DATABASE_URL=postgres://app:s3cr3tpw@db.internal:5432/app\n"
    "+NEXT_PUBLIC_SITE_URL=https://example.com\n"
    "aws_secret_access_key = wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY\n"
    "AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE\n"
    '  "sessionToken": "FwoGZXIvYXdzEBYaDHRlc3RzZXNzaW9uIg",\n'
    "Warning: 1 moderate severity vulnerability\n"
    "  api_key: AIzaSyA1b2C3d4E5f6G7h8I9j0K1l2M3n4O5p6Q\n"
    "-----BEGIN OPENSSH PRIVATE KEY-----\n"
    "b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZWQyNTUx\n"
    "-----END OPENSSH PRIVATE KEY-----\n"
    "Everything up-to-date\n")
joined = redact(tool_log)
for secret in ('ghs_K1l2M3n4O5p6Q7r8S9t0U1v2W3x4Y5', 'ghp_AbCdEf0123456789AbCdEf0123456789',
               's3cr3tpw', 'wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY', 'AKIAIOSFODNN7EXAMPLE',
               'FwoGZXIvYXdzEBYaDHRlc3RzZXNzaW9uIg', 'AIzaSyA1b2C3d4E5f6G7h8I9j0K1l2M3n4O5p6Q',
               'b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQ'):
    assert secret not in joined, (secret, joined)
assert 'PRIVATE KEY-----' not in joined, joined
assert 'Everything up-to-date' in joined and 'moderate severity vulnerability' in joined
assert 'github.com/acme/app' in joined, joined
assert 'https://example.com' not in joined, joined
print('ok - push logs, env diffs and credential dumps lose every secret and keep their shape')

# Credential headers: a scheme word is not the credential, so the whole value goes.
headers = (
    'curl -H "Authorization: token abcdefghijklmnopqrstuvwxyz123456" https://api.example.com\n'
    "curl -H 'Authorization: Digest username=\"bot\", response=\"6629fae4\"' https://x.example\n"
    '  "authorization": "ApiKey shortsecret99",\n'
    'Proxy-Authorization: Negotiate YIIBhgYGKwYBBQUCoIIBejCCAXag\n'
    'Cookie: theme=dark; session=s3ss10nV4lu3\n'
    'Set-Cookie: sid=abc123secret; Path=/; HttpOnly\n')
joined = redact(headers)
for secret in ('abcdefghijklmnopqrstuvwxyz123456', '6629fae4', 'shortsecret99', 'YIIBhgYGKwYBBQUCoIIB',
               's3ss10nV4lu3', 'abc123secret'):
    assert secret not in joined, (secret, joined)
assert 'https://api.example.com' in joined, joined
print('ok - Authorization and Cookie headers lose their whole value whatever the scheme')

# Bounding: a long capture contributes only its recent tail, each line clipped,
# and the tail is taken after redaction so a secret cannot ride in on length.
long_capture = '\n'.join(
    [f'line {n}' for n in range(400)] + ['x' * 4000, 'TOKEN=' + 'z' * 500, 'final line'])
lines = redact(long_capture).splitlines()
assert len(lines) <= 24, len(lines)
assert all(len(line) <= 160 for line in lines), max(len(line) for line in lines)
assert lines[-1] == 'final line'
assert 'zzzz' not in '\n'.join(lines)
assert redact('only this\n', '3').splitlines() == ['only this']
assert redact('a\nb\nc\nd\n', '2').splitlines() == ['c', 'd']
assert redact('') == '' and redact('\n\n   \n') == ''
print('ok - the tail is bounded by line count and width after redaction')

# Invalid bytes and lone control characters never reach a caller.
assert redact('ok\x00\x07\x08line\r\n') .strip() == 'okline'
assert redact('\x1b]0;title\x07shell prompt\n').strip() == 'shell prompt'
assert 'short key body' not in redact('-----BEGIN PRIVATE KEY-----\nshort key body\n-----END PRIVATE KEY-----\n')
assert 'single-name-secret' not in redact('X=single-name-secret\n')
assert 'inline-value' not in redact('"ENV_VALUE": "inline-value"\n')
assert 'half quoted' not in redact('ENV_VALUE="half quoted\n')
print('ok - control bytes, terminal titles, short private key bodies and env dumps are dropped')
PY
