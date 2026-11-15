"""Local HTTP server. It binds to 127.0.0.1 and serves one page."""

import json
import socket
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from answer_engine import db, runner
from answer_engine.page import PAGE

CSP = "default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; connect-src 'self'"
MAX_QUESTION = 4000
MAX_BODY = 65536


def host_allowed(value):
    if not value or not isinstance(value, str):
        return False
    host = value.strip()
    if not host or "@" in host or " " in host or "\\" in host or "/" in host:
        return False
    if host.startswith("["):
        return False
    name = host
    if host.count(":") > 1:
        return False
    if ":" in host:
        name, port = host.rsplit(":", 1)
        if not port.isdigit() or int(port) > 65535:
            return False
    lowered = name.lower()
    if lowered == "localhost":
        return True
    return name == "127.0.0.1"


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "answer-engine"
    sys_version = ""

    def log_message(self, fmt, *args):
        return

    def _json(self, code, obj):
        body = json.dumps(obj).encode("utf-8")
        self.send_response(code)
        self._common_headers("application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self._started = True
        self.wfile.write(body)

    def _common_headers(self, content_type):
        self.send_header("Content-Type", content_type)
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Security-Policy", CSP)

    def _guard(self):
        if host_allowed(self.headers.get("Host")):
            return True
        self._json(403, {"error": "forbidden"})
        return False

    def _read_body(self):
        raw = self.headers.get("Content-Length")
        try:
            length = int(raw or "0")
        except ValueError:
            return None
        if length < 0 or length > MAX_BODY:
            return None
        if length == 0:
            return b""
        return self.rfile.read(length)

    def do_GET(self):
        self._started = False
        try:
            self._get()
        except Exception:
            if not self._started:
                try:
                    self._json(500, {"error": "error"})
                except Exception:
                    pass

    def do_POST(self):
        self._started = False
        try:
            self._post()
        except Exception:
            if not self._started:
                try:
                    self._json(500, {"error": "error"})
                except Exception:
                    pass

    def _get(self):
        if not self._guard():
            return
        parsed = urllib.parse.urlsplit(self.path)
        path = parsed.path
        store = runner.database_path()
        if path == "/":
            body = PAGE.encode("utf-8")
            self.send_response(200)
            self._common_headers("text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Connection", "close")
            self.end_headers()
            self._started = True
            self.wfile.write(body)
            return
        if path == "/api/recent":
            self._json(200, {"results": db.recent(store)})
            return
        if path == "/api/search":
            query = urllib.parse.parse_qs(parsed.query).get("q", [""])[0]
            self._json(200, {"results": db.search(store, query)})
            return
        prefix = "/api/questions/"
        if path.startswith(prefix):
            ident = path[len(prefix):]
            if not ident.isdigit():
                self._json(404, {"error": "not found"})
                return
            item = db.get_question(store, int(ident))
            if item is None:
                self._json(404, {"error": "not found"})
                return
            self._json(200, item)
            return
        self._json(404, {"error": "not found"})

    def _chunk(self, payload):
        self.wfile.write(("%X\r\n" % len(payload)).encode("ascii"))
        self.wfile.write(payload)
        self.wfile.write(b"\r\n")
        self.wfile.flush()

    def _post(self):
        if not self._guard():
            return
        parsed = urllib.parse.urlsplit(self.path)
        if parsed.path != "/api/ask":
            self._json(404, {"error": "not found"})
            return
        raw = self._read_body()
        if raw is None:
            self._json(400, {"error": "bad request"})
            return
        try:
            data = json.loads(raw.decode("utf-8"))
        except (UnicodeError, ValueError):
            self._json(400, {"error": "bad request"})
            return
        if not isinstance(data, dict):
            self._json(400, {"error": "bad request"})
            return
        question = data.get("question")
        if not isinstance(question, str) or not question.strip():
            self._json(400, {"error": "empty question"})
            return
        if len(question) > MAX_QUESTION:
            self._json(400, {"error": "question too long"})
            return
        parent_id = data.get("parent_id")
        if parent_id is not None:
            if not isinstance(parent_id, int) or isinstance(parent_id, bool) or not db.exists(runner.database_path(), parent_id):
                self._json(400, {"error": "bad parent"})
                return
        if not runner.RUN_LOCK.acquire(blocking=False):
            self._json(409, {"error": "busy"})
            return
        try:
            self.send_response(200)
            self._common_headers("text/event-stream; charset=utf-8")
            self.send_header("Transfer-Encoding", "chunked")
            self.send_header("Connection", "close")
            self.end_headers()
            self._started = True

            def on_event(event):
                try:
                    line = "data: " + json.dumps(event, ensure_ascii=False, separators=(",", ":")) + "\n\n"
                    self._chunk(line.encode("utf-8"))
                except OSError:
                    return

            runner.ask(question, on_event=on_event, parent_id=parent_id)
            try:
                self.wfile.write(b"0\r\n\r\n")
                self.wfile.flush()
            except OSError:
                pass
        finally:
            runner.RUN_LOCK.release()


class Server(ThreadingHTTPServer):
    address_family = socket.AF_INET
    allow_reuse_address = True
    daemon_threads = True


def serve(port):
    import sys
    try:
        httpd = Server(("127.0.0.1", int(port)), Handler)
    except OSError:
        sys.stderr.write("could not listen\n")
        return 1
    sys.stdout.write("listening %d\n" % httpd.server_address[1])
    sys.stdout.flush()
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        httpd.server_close()
    return 0
