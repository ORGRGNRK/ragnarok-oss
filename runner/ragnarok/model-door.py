#!/usr/bin/env python3
"""model-door.py -- the belt container's ONE way out: a tiny HTTP door on the Mac to the local model.

Why it exists. The belt's AI seats run inside a container. That container is on a docker network
with no internet; its only neighbour is a gateway container that forwards to this door on the Mac.
The door forwards exactly two kinds of request to the local Ollama (Alexus by default):
    GET  /v1/models
    POST /v1/chat/completions      (only for the models named in --allow)
Everything else gets 403: no /api/pull, no /api/delete, no other host. So an AI command in the
belt cannot download or delete models on Alexus, cannot reach a cloud API through the door,
and cannot use a model nobody chose.

    python3 model-door.py --upstream http://alexus:11434 --port 58190 \
        --allow qwen2.5-coder:7b --allow llama3.2:3b

The upstream must be a local address (127.x, 10.x, 172.16-31.x, 192.168.x, localhost, *.local):
"no cloud AI" is enforced here, not just written down. Stdlib only. One line per request on stderr
(method, path, model asked for, status, and for a chat answer the model name the upstream reported
in its response), never a request or response body.
"""
import argparse, ipaddress, json, socket, sys, urllib.error, urllib.parse, urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


def is_local_url(url):
    host = urllib.parse.urlparse(url).hostname or ""
    if host == "localhost" or host.endswith(".local"):
        return True
    try:
        ip = ipaddress.ip_address(socket.gethostbyname(host))
    except (OSError, ValueError):
        return False
    return ip.is_private or ip.is_loopback


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--upstream", required=True)
    ap.add_argument("--port", type=int, required=True)
    ap.add_argument("--bind", default="127.0.0.1")
    ap.add_argument("--allow", action="append", default=[], help="a model the belt may use (repeat)")
    a = ap.parse_args()
    up = a.upstream.rstrip("/")
    if not is_local_url(up):
        sys.exit("model-door: %s is not a local address; refusing (no cloud AI)" % up)
    if not a.allow:
        sys.exit("model-door: name at least one --allow model")
    allowed = set(a.allow)

    class Door(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def note(self, status, model="-", reported=None):
            sys.stderr.write("model-door: %s %s %s -> %s%s\n" % (self.command, self.path, model, status,
                                                                 "" if reported is None else " reported=%s" % reported))
            sys.stderr.flush()

        def reply(self, status, body, ctype="application/json"):
            self.send_response(status)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def refuse(self, why, model="-"):
            self.note(403, model)
            self.reply(403, json.dumps({"error": "model-door: " + why}).encode())

        def forward(self, method, path, body=None):
            req = urllib.request.Request(up + path, data=body, method=method,
                                         headers={"Content-Type": "application/json"})
            try:
                with urllib.request.urlopen(req, timeout=3600) as r:
                    return r.status, r.read()
            except urllib.error.HTTPError as e:
                return e.code, e.read()
            except OSError as e:
                return 502, json.dumps({"error": "model-door: upstream unreachable: %s" % e}).encode()

        def do_GET(self):
            if self.path.rstrip("/") != "/v1/models":
                return self.refuse("only GET /v1/models and POST /v1/chat/completions pass this door")
            status, body = self.forward("GET", "/v1/models")
            try:  # show only the allowed models
                d = json.loads(body)
                d["data"] = [m for m in d.get("data", []) if m.get("id") in allowed]
                body = json.dumps(d).encode()
            except (ValueError, AttributeError):
                pass
            self.note(status)
            self.reply(status, body)

        def do_POST(self):
            if self.path.rstrip("/") != "/v1/chat/completions":
                return self.refuse("only GET /v1/models and POST /v1/chat/completions pass this door")
            n = int(self.headers.get("Content-Length") or 0)
            if n <= 0 or n > 20_000_000:
                return self.refuse("bad request size")
            raw = self.rfile.read(n)
            try:
                model = json.loads(raw).get("model", "")
            except ValueError:
                return self.refuse("body is not JSON")
            if model not in allowed:
                return self.refuse("model %r is not allowed here" % model, model)
            status, body = self.forward("POST", "/v1/chat/completions", raw)
            try:  # the model name in the upstream's answer, logged on the Mac, outside the belt's box
                rm = json.loads(body).get("model")
                reported = "".join(ch for ch in rm if ch.isprintable() and not ch.isspace())[:200] if isinstance(rm, str) else "-"
            except (ValueError, AttributeError):
                reported = "-"
            self.note(status, model, reported)
            self.reply(status, body)

        def do_PUT(self): self.refuse("method not allowed")
        def do_DELETE(self): self.refuse("method not allowed")
        def do_PATCH(self): self.refuse("method not allowed")

    srv = ThreadingHTTPServer((a.bind, a.port), Door)
    sys.stderr.write("model-door: %s:%s -> %s (models: %s)\n" % (a.bind, a.port, up, ", ".join(sorted(allowed))))
    sys.stderr.flush()
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
