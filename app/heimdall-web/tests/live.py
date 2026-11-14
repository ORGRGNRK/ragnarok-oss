"""Shared by the live tests: start a private Heimdall Web on this machine with a software security key registered,
and talk to it the way a browser does (cookie, touches). The real key file and the running site are not touched.
It still talks to the real services behind it (Intake), which is the point of a live test."""
import json, os, socket, subprocess, sys, tempfile, time, urllib.error, urllib.parse, urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from fakekey import FakeKey, ORIGIN, b64u, enc  # noqa: E402


class Site:
    def __init__(self, ttl=None):
        self.dir = tempfile.mkdtemp(prefix="heimdall-live-")
        with socket.socket() as s:
            s.bind(("127.0.0.1", 0))
            self.port = s.getsockname()[1]
        self.base = f"http://127.0.0.1:{self.port}"
        env = dict(os.environ, HEIMDALL_GATE_DIR=self.dir, ALEXUS_SSH="local", WEBAUTHN_RP_ID="heimdall.example.ts.net")
        if ttl is not None:
            env["HEIMDALL_SESSION_TTL"] = str(ttl)
        self.proc = subprocess.Popen([sys.executable, "-u", os.path.join(HERE, "..", "server.py"), "--port", str(self.port)],
                                     env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        for _ in range(50):
            try:
                urllib.request.urlopen(self.base + "/api/gate", timeout=1)
                break
            except OSError:
                time.sleep(0.1)
        self.cookie = ""
        self.key = FakeKey()
        open(os.path.join(self.dir, "allow-register"), "w").close()
        ch = self.json("POST", "/api/gate/challenge", {"purpose": "register"})[1]["challenge"]
        s, d, _ = self.json("POST", "/api/gate/register", self.key.register(ch))
        assert s == 200, d

    def close(self):
        self.proc.terminate()
        self.proc.wait(5)

    def call(self, method, path, body=None, headers=None, cookie=None):
        h = dict(headers or {})
        c = self.cookie if cookie is None else cookie
        if c:
            h["Cookie"] = c

        class NoRedirect(urllib.request.HTTPRedirectHandler):
            def redirect_request(self, *a, **k):
                return None
        req = urllib.request.Request(self.base + path, method=method, data=body, headers=h)
        try:
            with urllib.request.build_opener(NoRedirect).open(req, timeout=60) as r:
                return r.status, r.read(), r.headers
        except urllib.error.HTTPError as e:
            return e.code, e.read(), e.headers

    def json(self, method, path, obj=None, **kw):
        s, raw, h = self.call(method, path, None if obj is None else json.dumps(obj).encode(), {"Content-Type": "application/json"}, **kw)
        try:
            return s, json.loads(raw or b"{}"), h
        except ValueError:
            return s, {"raw": raw[:200].decode("utf-8", "replace")}, h

    def touch(self, purpose, key=None):
        """A fresh touch for one purpose, as the page's touch() returns it. None if the server won't give a challenge."""
        s, d, _ = self.json("POST", "/api/gate/challenge", {"purpose": purpose})
        return (key or self.key).touch(d["challenge"]) if s == 200 else None

    def unlock(self):
        s, d, h = self.json("POST", "/api/gate/session", {"gate": self.touch("session")})
        assert s == 200, d
        self.set_cookie = h["Set-Cookie"]
        self.cookie = self.set_cookie.split(";")[0]
        return self.set_cookie
