#!/usr/bin/env python3
"""Serve bin/fm-seat-board.sh's one generated page on loopback.

``bin/fm-seat-board.sh serve`` is the only supported caller; run this through
that script rather than directly, since it is what generates and keeps
regenerating the page this process reads on every request.

Usage: fm-seat-board-server.py <port> <page-path>

This exists instead of ``python3 -m http.server`` because that module validates
no Host header. Binding 127.0.0.1 stops a remote connection but not DNS
rebinding: a hostile page whose own domain is re-pointed at 127.0.0.1 is
same-origin to the browser, so it could read a board that shows every seat's
account email, quota windows and extra-usage spend. So this server:

* answers only when the request's Host header is exactly ``127.0.0.1`` or
  ``localhost`` with this server's own port, and refuses anything else with 403
  and no page content;
* serves the page only under a random per-run path segment, named in the URL
  printed on start, so a caller that never saw that URL cannot guess where to
  ask;
* serves nothing but that one page, under GET and HEAD only, so there is no
  path translation and no second file to reach.

With <port> 0 the kernel picks a free port, and the printed URL names the port
it got.

Exit status:
  0  the server ran and was stopped;
  2  the arguments were invalid;
  3  the port could not be bound.
"""

import hmac
import http.server
import secrets
import sys
from urllib.parse import urlsplit

REFUSED_HOST = b"Host not allowed: this board answers on loopback only.\n"
REFUSED_PATH = b"Not found: open the URL fm-seat-board.sh printed on start.\n"
UNREADABLE_PAGE = b"The seat board page could not be read.\n"


def allowed_hosts(port):
    """Every Host value this server answers for, lowercased."""
    return frozenset({"127.0.0.1:%d" % port, "localhost:%d" % port})


class SeatBoardHandler(http.server.BaseHTTPRequestHandler):
    # Narrowed from socketserver's BaseServer: every request reads this one
    # server's page path, route and allowed hosts.
    server: "SeatBoardServer"

    # An idle or slow connection is dropped rather than holding its thread.
    timeout = 10

    # Answer with a bare product token, so the refusal surface does not also
    # report this host's Python version.
    server_version = "fm-seat-board"
    sys_version = ""

    def do_GET(self):
        self.answer(with_body=True)

    def do_HEAD(self):
        self.answer(with_body=False)

    def answer(self, with_body):
        host = (self.headers.get("Host") or "").strip().lower()
        if host not in self.server.allowed_hosts:
            self.respond(403, "text/plain; charset=utf-8", REFUSED_HOST, with_body)
            return
        if not self.route_matches():
            self.respond(404, "text/plain; charset=utf-8", REFUSED_PATH, with_body)
            return
        try:
            with open(self.server.page_path, "rb") as page:
                body = page.read()
        except OSError:
            self.respond(503, "text/plain; charset=utf-8", UNREADABLE_PAGE, with_body)
            return
        self.respond(200, "text/html; charset=utf-8", body, with_body)

    def route_matches(self):
        try:
            path = urlsplit(self.path).path
        except ValueError:
            return False
        # compare_digest rejects a non-ASCII str, and no such path can match a
        # token drawn from the URL-safe alphabet anyway.
        if not path.isascii():
            return False
        route = self.server.route
        return any(
            hmac.compare_digest(path, candidate) for candidate in (route, route + "/")
        )

    def respond(self, code, content_type, body, with_body):
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        if with_body:
            self.wfile.write(body)

    def log_message(self, format, *args):  # noqa: A002 - matches the base name
        # The request line is attacker-chosen text landing in the operator's
        # terminal, so every control character is replaced before it is
        # written. Older Pythons do not do this for us.
        line = format % args
        safe = "".join(char if 32 <= ord(char) < 127 else "?" for char in line)
        sys.stderr.write("fm-seat-board: %s\n" % safe)


class SeatBoardServer(http.server.ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, port, page_path, route):
        self.page_path = page_path
        self.route = route
        super().__init__(("127.0.0.1", port), SeatBoardHandler)
        # Bound after the bind, so a kernel-assigned port is the one checked.
        self.allowed_hosts = allowed_hosts(self.server_address[1])


def main(argv):
    if len(argv) != 3:
        sys.stderr.write("usage: fm-seat-board-server.py <port> <page-path>\n")
        return 2
    try:
        port = int(argv[1])
    except ValueError:
        sys.stderr.write("error: port must be a number, got %r\n" % argv[1])
        return 2
    if not 0 <= port <= 65535:
        sys.stderr.write("error: port must be between 0 and 65535, got %d\n" % port)
        return 2
    route = "/" + secrets.token_urlsafe(18)
    try:
        server = SeatBoardServer(port, argv[2], route)
    except OSError as exc:
        sys.stderr.write("error: could not bind 127.0.0.1:%d: %s\n" % (port, exc))
        return 3
    sys.stdout.write(
        "Seat board: http://127.0.0.1:%d%s/\n" % (server.server_address[1], route)
    )
    sys.stdout.write("Ctrl-C to stop.\n")
    sys.stdout.flush()
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
