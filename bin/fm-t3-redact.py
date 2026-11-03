#!/usr/bin/env python3
"""Redact a worker's captured output before it leaves the home.

Usage: fm-t3-redact.py [lines] < capture   # redacted tail on stdout

Importers call redact_lines(text, lines). The filter is deliberately
conservative: a line it cannot read as safe loses the unreadable part rather
than being forwarded intact. It removes terminal control bytes, env-shaped
assignments, secret-shaped key/value pairs, known credential formats, URL
userinfo, and long opaque tokens, then bounds the result to a recent tail.

It is a filter, not a proof. A capture is free-form agent output, so no pattern
set can promise that every secret a worker happened to print is caught. The
residual risk is documented in docs/t3-backend.md and is the reason mirrors
stay opt-in per home.
"""

import re
import sys


MASK = "[redacted]"
TAIL_LINES = 24
LINE_CHARS = 160

# Terminal control bytes: CSI/OSC sequences first, then any remaining C0/C1.
ANSI = re.compile(r"\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)|\x1b[@-_][0-?]*[ -/]*[@-~]|\x1b.")
CONTROL = re.compile(r"[\x00-\x08\x0b-\x1f\x7f-\x9f]")

SECRET_WORD = (
    r"(?:api[_-]?key|auth[a-z_-]*|bearer|cert|cookie|credential[s]?|key|passphrase"
    r"|passwd|password|private[_-]?key|pwd|secret|session[_-]?id|signature|token)"
)

RULES = (
    # Private key blocks collapse whole-line, including the base64 body.
    (re.compile(r"-----(?:BEGIN|END) [A-Z ]*PRIVATE KEY-----.*"), MASK),
    (re.compile(r"^\s*[A-Za-z0-9+/]{32,}={0,2}\s*$"), MASK),
    # URL userinfo, before any token rule can split the credential apart.
    (re.compile(r"\b([a-z][a-z0-9+.-]*://)[^\s/@:]+:[^\s/@]+@"), r"\1" + MASK + "@"),
    # Named credential formats.
    (re.compile(r"\bgh[pousr]_[A-Za-z0-9]{16,}"), MASK),
    (re.compile(r"\bgithub_pat_[A-Za-z0-9_]{20,}"), MASK),
    (re.compile(r"\b(?:sk|pk|rk)-[A-Za-z0-9_-]{16,}"), MASK),
    (re.compile(r"\bxox[abprs]-[A-Za-z0-9-]{10,}"), MASK),
    (re.compile(r"\bAKIA[0-9A-Z]{16}\b"), MASK),
    (re.compile(r"\bASIA[0-9A-Z]{16}\b"), MASK),
    (re.compile(r"\bAIza[A-Za-z0-9_-]{20,}"), MASK),
    (re.compile(r"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]+"), MASK),
    (re.compile(r"(?i)\bbearer\s+[A-Za-z0-9._~+/=-]{12,}"), "Bearer " + MASK),
    (re.compile(r"(?i)\bbasic\s+[A-Za-z0-9+/]{12,}={0,2}"), "Basic " + MASK),
    # Env-shaped assignment: the name survives so the reader keeps the shape.
    (re.compile(r"\b([A-Z_][A-Z0-9_]*)=(?:'[^']*'|\"[^\"]*\"|\S+)"), r"\1=" + MASK),
    # Credential headers carry a scheme and a value, so the whole value goes.
    (re.compile(r"(?i)(\b(?:proxy-authorization|authorization|set-cookie|cookie)\"?\s*[:=]\s*[\"']?)(?:[^\n]*?(?=[\"'](?:\s|$))|[^\n]+)"),
     r"\1" + MASK),
    # Secret-shaped key/value in prose, JSON, YAML, or flags.
    (re.compile(r"(?i)(" + SECRET_WORD + r"\"?\s*[:=]\s*)(?:'[^']*'|\"[^\"]*\"|\S+)"), r"\1" + MASK),
    (re.compile(r"(?i)(--" + SECRET_WORD + r"(?:[_-][a-z]+)?[= ])(?:'[^']*'|\"[^\"]*\"|\S+)"), r"\1" + MASK),
    # Remaining long opaque runs: hex digests and base64-ish blobs.
    (re.compile(r"\b[0-9a-fA-F]{40,}\b"), MASK),
    (re.compile(r"(?<![A-Za-z0-9+/=_./-])[A-Za-z0-9+/_-]{40,}={0,2}(?![A-Za-z0-9+/=_./-])"), MASK),
    # A key whose scheme word is itself secret-shaped masks twice; say it once.
    (re.compile(r"\[redacted\](?:\s+\[redacted\])+"), MASK),
)


def redact_line(line):
    """Redact one capture line. Control bytes go before any pattern runs."""
    text = CONTROL.sub("", ANSI.sub("", line)).replace("\t", "    ").rstrip()
    if re.search(r"[\"']?\b[A-Z_][A-Z0-9_]*[\"']?\s*[:=]", text):
        return MASK
    for pattern, replacement in RULES:
        text = pattern.sub(replacement, text)
    return text[:LINE_CHARS].rstrip()


def redact_lines(text, lines=TAIL_LINES):
    """Redacted recent tail of a capture, as a bounded list of nonempty lines."""
    if not isinstance(text, str):
        return []
    if lines < 1:
        return []
    result = []
    private_key = False
    for line in text.splitlines():
        if re.search(r"-----BEGIN .*PRIVATE KEY-----", line):
            private_key = True
        if private_key:
            redacted = MASK
            if re.search(r"-----END .*PRIVATE KEY-----", line):
                private_key = False
        else:
            redacted = redact_line(line)
        if redacted:
            result.append(redacted)
    return result[-lines:]


def main():
    lines = int(sys.argv[1]) if len(sys.argv) > 1 else TAIL_LINES
    body = sys.stdin.buffer.read().decode("utf-8", errors="replace")
    for line in redact_lines(body, lines):
        print(line)


if __name__ == "__main__":
    main()
