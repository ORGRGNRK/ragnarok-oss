#!/usr/bin/env python3
"""Heimdall Web: the Heimdall Chat tab as a web page, served from Alexus, so it works from any browser
(Linux on the Mac, macOS, iPhone, iPad).

The logic is NOT in here. Starting a chat and sealing it run app/heimdall/bin/alexus-chat-bridge.py, the
same script the Mac app runs. This file only moves text between the page, that script and Ollama.

    python3 server.py [--host 127.0.0.1] [--port 8750]

On Alexus run it with ALEXUS_SSH=local (the bridge then talks to Docker directly instead of ssh-ing to
itself) and OLLAMA_HOST=http://127.0.0.1:11434. Bind it to the tailnet address.

The whole site is locked behind a YubiKey: one touch opens it in a browser for 12 hours, and every write
(Room posts, Intake store/archive, agents, the public Proved page) needs its own fresh touch. See the gate
section below; tests/lock-test.py checks it against a running copy.

Every message is appended to ~/.ragnarok/heimdall-chat.jsonl in the Mac app's format, with "source".
Standard library only.
"""
import argparse, datetime, json, os, secrets, subprocess, sys, threading, urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import getpass, re as _re


def local_conf(key, default=""):
    """One KEY=value from ~/.ragnarok/local.conf (read only, never run); default if missing or odd."""
    val = None
    try:
        with open(os.path.expanduser("~/.ragnarok/local.conf"), encoding="utf-8") as f:
            for line in f:
                k, sep, v = line.strip().partition("=")
                if sep and not k.startswith("#") and k.strip() == key:
                    val = v.strip().strip("\"'")
    except OSError:
        pass
    return val if val and not val.startswith("-") and _re.fullmatch(r"[A-Za-z0-9 ._:/@'-]{1,253}", val) else default

HERE = os.path.dirname(os.path.abspath(__file__))
BRIDGE = os.path.normpath(os.path.join(HERE, "../heimdall/bin/alexus-chat-bridge.py"))
LOG = os.path.expanduser("~/.ragnarok/heimdall-chat.jsonl")
DEFAULT_MODEL = "llama3.2:3b"
MAX_BODY = 2_000_000
MAX_MSGS = 200

ROOM = os.environ.get("ROOM_BIN", os.path.expanduser("~/Developer/ragnarok-room/bin/room"))
PAGES = {"/": ("index.html", "text/html; charset=utf-8"), "/index.html": ("index.html", "text/html; charset=utf-8"),
         "/room": ("room.html", "text/html; charset=utf-8"), "/style.css": ("style.css", "text/css; charset=utf-8")}
ROOM_ID = __import__("re").compile(r"^[0-9a-f]{4,16}$")
PAGES["/agents"] = ("agents.html", "text/html; charset=utf-8")
PAGES["/gate.js"] = ("gate.js", "text/javascript; charset=utf-8")
PAGES["/gate"] = ("gate.html", "text/html; charset=utf-8")
PAGES["/lock.js"] = ("lock.js", "text/javascript; charset=utf-8")
PAGES["/hub"] = ("hub.html", "text/html; charset=utf-8")
HUB_BIN = os.path.normpath(os.path.join(HERE, "../heimdall/bin/ragnarok-hub"))
PAGES["/timeline"] = ("timeline.html", "text/html; charset=utf-8")
PAGES["/intake"] = ("intake.html", "text/html; charset=utf-8")
PAGES["/splash.js"] = ("splash.js", "text/javascript; charset=utf-8")
TIMELINE_BIN = os.path.normpath(os.path.join(HERE, "../heimdall/bin/ragnarok-timeline"))

# Agents run as the claude login on Alexus (its own Claude Code sign-in, its own receipts), never as the owner's login.
AGENT_SSH = os.environ.get("AGENT_SSH", "claude@127.0.0.1")
AGENT_KEY = os.path.expanduser(os.environ.get("AGENT_KEY", "~/.ssh/heimdall-agent"))
AGENT_BIN = os.environ.get("AGENT_BIN", os.path.normpath(os.path.join(HERE, "../heimdall/bin/ragnarok-agent")))
AGENT_HOME = "/home/claude"
RUN_ID = __import__("re").compile(r"^[0-9]{8}-[0-9]{6}-[0-9a-f]{4,12}$")
RUNNERS = ("claude", "grok", "codex")


def agent_sequence(data):
    """Who starts, then who the run hands off to. No `runners` field means Claude, then Codex, then Grok."""
    raw = data.get("runners") if isinstance(data, dict) else None
    if raw is None:
        return ["claude", "codex", "grok"]
    if isinstance(raw, str):
        raw = [p.strip() for p in raw.split(",") if p.strip()]
    if not isinstance(raw, list) or not 1 <= len(raw) <= len(RUNNERS):
        return None
    out = []
    for item in raw:
        if not isinstance(item, str):
            return None
        who = item.strip().lower()
        if who not in RUNNERS or who in out:
            return None
        out.append(who)
    return out


# Runs on the claude side: newest runs' summaries as JSON (one ssh call instead of one per run).
LIST_RUNS = r'''
import json, os, glob
rows = []
for p in sorted(glob.glob(os.path.expanduser("~/.ragnarok/agents/*/state.json")), key=os.path.getmtime, reverse=True)[:40]:
    try:
        d = json.load(open(p))
    except Exception:
        continue
    hops = [{"from": h.get("from"), "to": h.get("to")} for h in (d.get("handoffs") or []) if isinstance(h, dict)]
    row = {k: d.get(k) for k in ("id", "name", "who", "started_who", "status", "verdict", "task", "started", "ended", "cwd", "tools", "handoff_chain")}
    row["handoffs"] = hops
    row["handoff_chain"] = row.get("handoff_chain") or []
    rows.append(row)
print(json.dumps(rows))
'''


# ------------------------------------------------------------------ YubiKey gate (WebAuthn)
# Starting, stopping, resuming, and handing off agents needs a fresh security-key touch in the browser. The server checks the
# signature itself against the key registered here, so a request without a touch never reaches the claude login.
# Registration is only open while ~/.ragnarok/heimdall-web/allow-register exists; it is removed after one key.
import base64, hashlib, struct, time as _time
GATE_DIR = os.path.expanduser(os.environ.get("HEIMDALL_GATE_DIR", "~/.ragnarok/heimdall-web"))
CRED_FILE = os.path.join(GATE_DIR, "yubikeys.json")
ALLOW_REGISTER = os.path.join(GATE_DIR, "allow-register")
RP_ID = os.environ.get("WEBAUTHN_RP_ID") or local_conf("HEIMDALL_WEB_HOST", "localhost")   # the https name the YubiKey is bound to
ORIGIN = "https://" + RP_ID
CHALLENGE_TTL = 120
challenges = {}          # challenge (b64url) -> (purpose, expires)

# The whole site is locked. One touch ("session") opens it for SESSION_TTL in that browser; the browser then holds a
# random cookie and the server remembers only its hash, in memory (a restart locks every browser again).
# Each write below needs its own fresh touch on top of that.
SESSION_TTL = int(os.environ.get("HEIMDALL_SESSION_TTL", 12 * 3600))
SESSION_COOKIE = "hw_session"
open_sessions = {}       # sha256(cookie value) -> expires
WRITE_PURPOSES = ("agents:start", "agents:stop", "agents:resume", "agents:handoff", "room:say", "room:task", "room:claim", "room:done",
                  "intake:text", "intake:file", "intake:archive", "proved:public")
OPEN_GET = {"/gate", "/gate.js", "/style.css", "/splash.js", "/api/gate"}          # reachable while locked
OPEN_POST = {"/api/gate/challenge", "/api/gate/register", "/api/gate/session", "/api/gate/lock"}


def b64u(b):
    return base64.urlsafe_b64encode(b).rstrip(b"=").decode()


def unb64u(s):
    if not isinstance(s, str) or len(s) > 20000:
        raise ValueError("bad base64")
    return base64.urlsafe_b64decode(s + "=" * (-len(s) % 4))


def cbor(data, i=0):
    """Minimal CBOR reader for WebAuthn: ints, byte/text strings, arrays, maps. Returns (value, next index)."""
    ib = data[i]; major, info = ib >> 5, ib & 31; i += 1
    if info < 24:
        n = info
    elif info in (24, 25, 26, 27):
        size = 1 << (info - 24)
        n = int.from_bytes(data[i:i + size], "big"); i += size
    else:
        raise ValueError("unsupported CBOR")
    if major == 0:
        return n, i
    if major == 1:
        return -1 - n, i
    if major in (2, 3):
        v = data[i:i + n]
        return (bytes(v) if major == 2 else v.decode()), i + n
    if major == 4:
        out = []
        for _ in range(n):
            v, i = cbor(data, i); out.append(v)
        return out, i
    if major == 5:
        out = {}
        for _ in range(n):
            k, i = cbor(data, i); v, i = cbor(data, i); out[k] = v
        return out, i
    raise ValueError("unsupported CBOR type")


def load_keys():
    try:
        with open(CRED_FILE) as f:
            return json.load(f)
    except (OSError, ValueError):
        return []


def save_keys(keys):
    os.makedirs(GATE_DIR, mode=0o700, exist_ok=True)
    tmp = CRED_FILE + ".tmp"
    with open(os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), "w") as f:
        json.dump(keys, f, indent=1)
    os.replace(tmp, CRED_FILE)


def new_challenge(purpose):
    now = _time.time()
    with lock:
        for c in [c for c, (_, exp) in challenges.items() if exp < now]:
            challenges.pop(c, None)
        c = b64u(secrets.token_bytes(32))
        challenges[c] = (purpose, now + CHALLENGE_TTL)
    return c


def check_client_data(cdj_b64, kind, purpose):
    cdj = unb64u(cdj_b64)
    cd = json.loads(cdj)
    if cd.get("type") != kind:
        raise ValueError("wrong WebAuthn type")
    if cd.get("origin") != ORIGIN:
        raise ValueError(f"wrong origin {cd.get('origin')!r}; use {ORIGIN}")
    with lock:
        got = challenges.pop(cd.get("challenge", ""), None)    # single use, even if the rest fails
    if not got or got[1] < _time.time():
        raise ValueError("challenge unknown or expired; touch again")
    if got[0] != purpose:
        raise ValueError("this touch was for a different action")
    return cdj


def check_auth_data(ad):
    if len(ad) < 37 or ad[:32] != hashlib.sha256(RP_ID.encode()).digest():
        raise ValueError("signed for a different site")
    if not ad[32] & 0x01:
        raise ValueError("the key was not touched")
    return ad[32], struct.unpack(">I", ad[33:37])[0]


def gate_register(data):
    from cryptography.hazmat.primitives.asymmetric import ec
    from cryptography.hazmat.primitives import serialization
    if not os.path.exists(ALLOW_REGISTER):
        raise ValueError("registration is closed")
    check_client_data(data.get("clientDataJSON"), "webauthn.create", "register")
    att, _ = cbor(unb64u(data.get("attestationObject")))
    ad = att["authData"]
    flags, count = check_auth_data(ad)
    if not flags & 0x40:
        raise ValueError("no credential in the response")
    n = struct.unpack(">H", ad[53:55])[0]
    cred_id = ad[55:55 + n]
    key, _ = cbor(ad, 55 + n)
    if key.get(1) != 2 or key.get(3) != -7 or key.get(-1) != 1:
        raise ValueError("only P-256 (ES256) keys are supported")
    pub = ec.EllipticCurvePublicNumbers(int.from_bytes(key[-2], "big"), int.from_bytes(key[-3], "big"),
                                        ec.SECP256R1()).public_key()
    pem = pub.public_bytes(serialization.Encoding.PEM, serialization.PublicFormat.SubjectPublicKeyInfo).decode()
    keys = [k for k in load_keys() if k["id"] != b64u(cred_id)]
    keys.append({"id": b64u(cred_id), "pem": pem, "count": count, "name": str(data.get("name") or "YubiKey")[:40],
                 "added": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds")})
    save_keys(keys)
    os.remove(ALLOW_REGISTER)
    return len(keys)


def gate_verify(gate, purpose):
    """Raise ValueError unless `gate` is a fresh, correctly signed touch of a registered key for `purpose`."""
    from cryptography.hazmat.primitives.asymmetric import ec
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.exceptions import InvalidSignature
    if not isinstance(gate, dict):
        raise ValueError("this needs a YubiKey touch")
    keys = load_keys()
    if not keys:
        raise ValueError("no YubiKey registered yet")
    k = next((k for k in keys if k["id"] == gate.get("id")), None)
    if not k:
        raise ValueError("that key isn't registered here")
    cdj = check_client_data(gate.get("clientDataJSON"), "webauthn.get", purpose)
    ad = unb64u(gate.get("authenticatorData"))
    _, count = check_auth_data(ad)
    pub = serialization.load_pem_public_key(k["pem"].encode())
    try:
        pub.verify(unb64u(gate.get("signature")), ad + hashlib.sha256(cdj).digest(), ec.ECDSA(hashes.SHA256()))
    except InvalidSignature:
        raise ValueError("signature check failed")
    if (count or k["count"]) and count <= k["count"]:
        raise ValueError("the key's counter went backwards (possible cloned key)")
    with lock:
        keys = load_keys()
        for x in keys:
            if x["id"] == k["id"]:
                x["count"] = count
        save_keys(keys)


# ------------------------------------------------------------------ the public page (PROVED_PUBLIC_URL)
# One run at a time, the one the owner picks on the private /proved page. It is cut out of the generated all-runs page
# (already scrubbed and credential-checked by share-run.py) and sent to the Cloudflare Worker in public-worker/.
PUBLIC_URL = os.environ.get("PROVED_PUBLIC_URL") or local_conf("PROVED_PUBLIC_URL", "")
PUBLIC_TOKEN = os.path.join(GATE_DIR, "proved-publish-token")
PUBLIC_STATE = os.path.join(GATE_DIR, "proved-public.json")


def public_state():
    try:
        with open(PUBLIC_STATE) as f:
            return json.load(f)
    except (OSError, ValueError):
        return {"id": None}


def public_call(method, body=None):
    with open(PUBLIC_TOKEN) as f:
        token = f.read().strip()
    req = urllib.request.Request(PUBLIC_URL + "/publish", method=method, data=body,
                                 headers={"Authorization": "Bearer " + token, "User-Agent": "heimdall-web/1",
                                          "Content-Type": "text/html; charset=utf-8"})
    with urllib.request.urlopen(req, timeout=20) as r:
        return json.load(r)


def public_page(rid):
    """The standalone page for one run, cut from the all-runs page. Raises ValueError if it isn't there."""
    with open(os.path.join(GATE_DIR, "proved.html"), encoding="utf-8") as f:
        allp = f.read()
    start = allp.find(f'<section id="r-{rid}"')
    if start < 0:
        raise ValueError("that run isn't on the proved page")
    body = allp[allp.index(">", start) + 1:allp.index("</section>", start)]
    style = allp[allp.index("<style>"):allp.index("</style>") + 8]
    return ('<!doctype html>\n<html lang="en"><head><meta charset="utf-8">'
            '<meta name="viewport" content="width=device-width, initial-scale=1">'
            f'<title>A proved run — Ragnarok</title>\n{style}</head><body><main>{body}</main></body></html>\n')


# ------------------------------------------------------------------ Intake (the Intake service on this machine)
# Storing, searching and archiving are the Intake service's job (clients/intake, port 8910). This only passes
# requests through with the token from ~/.ragnarok/intake.env, so the token never reaches a browser.
# Stored bytes are data: a picture of a plain kind is shown, everything else is only ever sent as a download.
import http.client, mimetypes, urllib.parse
INTAKE_CONF = os.path.expanduser(os.environ.get("RAGNAROK_INTAKE_CONF", "~/.ragnarok/intake.env"))
INTAKE_ID = __import__("re").compile(r"^[0-9]{1,12}$")
INTAKE_INLINE = {"image/png", "image/jpeg", "image/gif", "image/webp"}      # never svg or html: they can carry script
INTAKE_PHOTO = {".jpg", ".jpeg", ".png", ".gif", ".webp", ".heic", ".heif", ".tif", ".tiff", ".bmp"}
INTAKE_SENDER = os.environ.get("INTAKE_SENDER") or os.environ.get("USER") or "heimdall-web"


def intake_conf():
    kv = {}
    try:
        with open(INTAKE_CONF, encoding="utf-8", errors="replace") as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith("#") and "=" in line:
                    k, v = line.split("=", 1)
                    kv[k.strip()] = v.strip().strip("\"'")
    except OSError:
        pass
    url, token = kv.get("URL", "").rstrip("/"), kv.get("TOKEN", "")
    parts = urllib.parse.urlsplit(url)
    if parts.scheme not in ("http", "https") or not parts.hostname or len(token) < 32:
        raise RuntimeError("Intake is not set up on Alexus. ~/.ragnarok/intake.env needs a URL and a TOKEN.")
    return parts, token


def intake_open(timeout):
    parts, token = intake_conf()
    cls = http.client.HTTPSConnection if parts.scheme == "https" else http.client.HTTPConnection
    return cls(parts.hostname, parts.port or (443 if parts.scheme == "https" else 80), timeout=timeout), token


def intake_call(method, path, body=None, headers=None, timeout=60):
    """One request to Intake. Returns (status, bytes). Status 0 means Intake did not answer."""
    conn, token = intake_open(timeout)
    try:
        conn.request(method, path, body=body, headers=dict(headers or {}, Authorization="Bearer " + token))
        r = conn.getresponse()
        return r.status, r.read()
    except (OSError, http.client.HTTPException):
        return 0, b""
    finally:
        conn.close()


def intake_error(status, raw, fallback):
    if status == 0:
        return "Intake did not answer, so nothing was loaded or sent."
    if status == 401:
        return "Intake refused the token."
    try:
        err = json.loads(raw or b"{}").get("error")
    except (ValueError, AttributeError):
        err = None
    try:
        token = intake_conf()[1]
    except RuntimeError:
        token = ""
    return (str(err).replace(token, "[token]") if token else str(err)) if err else f"{fallback} (HTTP {status})"


def intake_name(raw):
    """A filename stored as data. A slash, a backslash, a control character, "." or ".." is refused."""
    name = (raw or "").strip()
    if not name or len(name) > 255 or name in (".", "..") or any(c in name for c in "/\\") or any(ord(c) < 32 for c in name):
        return None
    return name


def intake_meta(headers, key, value):
    """Headers are Latin-1. Every value also goes as UTF-8 percent-encoding, as the Mac app and ragnarok-intake send it."""
    if not value:
        return
    headers[key + "-Utf8"] = "UTF-8''" + urllib.parse.quote(value, safe="")
    try:
        value.encode("latin-1")
        headers[key] = value
    except UnicodeEncodeError:
        pass


def session_new():
    token = b64u(secrets.token_bytes(32))
    now = _time.time()
    with lock:
        for h in [h for h, exp in open_sessions.items() if exp < now]:
            open_sessions.pop(h, None)
        open_sessions[hashlib.sha256(token.encode()).hexdigest()] = now + SESSION_TTL
    return token


def session_cookie(header):
    for part in (header or "").split(";"):
        k, _, v = part.strip().partition("=")
        if k == SESSION_COOKIE:
            return v
    return ""


def session_ok(header):
    token = session_cookie(header)
    if not token:
        return False
    with lock:
        return open_sessions.get(hashlib.sha256(token.encode()).hexdigest(), 0) > _time.time()


def agent(remote_cmd, stdin=None, timeout=30):
    """One command as the claude login, over ssh to this machine with Heimdall's own key."""
    argv = ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "-o", "IdentitiesOnly=yes"]
    if os.path.exists(AGENT_KEY):
        argv += ["-i", AGENT_KEY]
    r = subprocess.run(argv + [AGENT_SSH, remote_cmd], input=stdin, capture_output=True, text=True, timeout=timeout)
    return r.returncode, r.stdout, r.stderr.strip()


def agent_cli(args, timeout=30):
    import shlex
    return agent("PATH=$HOME/.local/bin:$PATH " + " ".join(shlex.quote(a) for a in ["python3", AGENT_BIN] + args),
                 timeout=timeout)

sessions = {}            # session id -> system prompt (lost on restart; the page then starts a new chat)
lock = threading.Lock()


def room(args, stdin=None):
    """Run the room command (room.py) as this login. On Alexus (ALEXUS_SSH=local) directly, elsewhere over ssh."""
    target = os.environ.get("ALEXUS_SSH", "").strip() or (local_conf("ALEXUS_USER", getpass.getuser()) + "@" + local_conf("ALEXUS_TAILSCALE", "alexus"))
    if target == "local":
        argv = [sys.executable, ROOM] + args
    else:
        import shlex
        argv = ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5", target, " ".join(shlex.quote(a) for a in [ROOM] + args)]
    r = subprocess.run(argv, input=stdin, capture_output=True, text=True, timeout=20)
    return r.returncode, r.stdout, r.stderr.strip()


def ollama():
    h = os.environ.get("OLLAMA_HOST", "").strip() or "http://127.0.0.1:11434"
    return (h if "://" in h else "http://" + h).rstrip("/")


def log(session, role, content):
    rec = {"ts": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
           "session": session, "role": role, "content": content, "source": "heimdall-web"}
    os.makedirs(os.path.dirname(LOG), exist_ok=True)
    with lock, open(os.open(LOG, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600), "a", encoding="utf-8") as f:
        f.write(json.dumps(rec) + "\n")


def bridge(cmd, stdin=None, timeout=120):
    r = subprocess.run([sys.executable, BRIDGE, cmd], input=stdin, capture_output=True, text=True, timeout=timeout)
    out = None
    try:
        out = json.loads(r.stdout) if r.stdout.strip() else None
    except ValueError:
        pass
    return r.returncode, out, r.stderr.strip()


def clean(messages):
    """Only user/assistant turns with text, capped; the system prompt always comes from the server."""
    if not isinstance(messages, list):
        raise ValueError("messages must be a list")
    out = []
    for m in messages[-MAX_MSGS:]:
        if isinstance(m, dict) and m.get("role") in ("user", "assistant") and isinstance(m.get("content"), str):
            out.append({"role": m["role"], "content": m["content"][:20000]})
    return out


class Handler(BaseHTTPRequestHandler):
    server_version = "HeimdallWeb/1"

    def log_message(self, fmt, *args):
        sys.stderr.write("%s %s\n" % (self.address_string(), fmt % args))

    def send_json(self, code, obj, headers=()):
        body = json.dumps(obj).encode()
        self.send_response(code)
        for k, v in headers:
            self.send_header(k, v)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def body(self):
        n = int(self.headers.get("Content-Length") or 0)
        if n > MAX_BODY:
            raise ValueError("request too large")
        return json.loads(self.rfile.read(n) or b"{}")

    def locked(self):
        return not session_ok(self.headers.get("Cookie"))

    def needs_touch(self, gate, purpose):
        """True (and the refusal is already sent) unless `gate` is a fresh touch for exactly this write."""
        try:
            gate_verify(gate, purpose)
            return False
        except Exception as e:
            self.send_json(403, {"error": f"YubiKey: {e}"})
            return True

    def do_GET(self):
        path, _, query = self.path.partition("?")
        if path not in OPEN_GET and self.locked():
            if path.startswith("/api/"):
                return self.send_json(401, {"error": "Heimdall is locked. Touch your YubiKey to open it.", "locked": True})
            self.send_response(302)
            self.send_header("Location", "/gate?next=" + urllib.parse.quote(path, safe="/"))
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", "0")
            return self.end_headers()
        if path == "/proved":
            # The proved-runs page is generated (share-run.py --all) and holds run data, so it lives outside the repo.
            try:
                with open(os.path.join(GATE_DIR, "proved.html"), "rb") as f:
                    body = f.read()
            except OSError:
                return self.send_json(404, {"error": "no proved-runs page yet; generate one with share-run.py --all"})
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            return self.wfile.write(body)
        if path == "/api/proved/public":
            return self.send_json(200, dict(public_state(), url=PUBLIC_URL))
        if path == "/api/hub":
            # This machine, live (ragnarok-hub), plus the Mac's last snapshot if publish-hub.sh has sent one.
            try:
                r = subprocess.run([sys.executable, HUB_BIN], capture_output=True, text=True, timeout=60)
                if r.returncode != 0:
                    raise RuntimeError((r.stderr.strip().splitlines() or [f"exit {r.returncode}"])[-1])
                here = json.loads(r.stdout)
            except Exception as e:
                return self.send_json(502, {"error": f"hub: {e}"})
            mac = None
            try:
                with open(os.path.join(GATE_DIR, "hub-mac.json")) as f:
                    mac = json.load(f)
            except (OSError, ValueError):
                pass
            return self.send_json(200, {"here": here, "mac": mac})
        if path == "/api/timeline":
            # This machine's logs, read now by ragnarok-timeline. With since=EPOCH only newer events come back.
            # The first call (no since) also carries the laptop's last snapshot, if publish-timeline.sh has sent one.
            args = {k: v for k, _, v in (kv.partition("=") for kv in query.split("&"))}
            try:
                since = float(args.get("since") or 0)
                hours = min(max(float(args.get("hours") or 24), 1), 24 * 14)
            except ValueError:
                return self.send_json(400, {"error": "since and hours must be numbers"})
            try:
                r = subprocess.run([sys.executable, TIMELINE_BIN, "--host", "alexus", "--hours", str(hours),
                                    "--since", str(since)], capture_output=True, text=True, timeout=60)
                if r.returncode != 0:
                    raise RuntimeError((r.stderr.strip().splitlines() or [f"exit {r.returncode}"])[-1])
                here = json.loads(r.stdout)
            except Exception as e:
                return self.send_json(502, {"error": f"timeline: {e}"})
            out = {"here": here}
            if not since:
                out["mac"] = None
                try:
                    with open(os.path.join(GATE_DIR, "timeline-mac.json")) as f:
                        out["mac"] = json.load(f)
                except (OSError, ValueError):
                    pass
            return self.send_json(200, out)
        if path == "/api/intake/items":
            # The list (newest first, archived left out) plus the disk line. Filters are passed through.
            args = urllib.parse.parse_qs(query, keep_blank_values=False)
            q = {"limit": "200"}
            for k in ("q", "kind", "sender", "tag"):
                v = (args.get(k) or [""])[0].strip()[:200]
                if v and (k != "kind" or v in ("text", "file", "photo")):
                    q[k] = v
            try:
                status, raw = intake_call("GET", "/intake/items?" + urllib.parse.urlencode(q))
                if status != 200:
                    return self.send_json(502, {"error": intake_error(status, raw, "Intake did not return a list")})
                items = json.loads(raw).get("items") or []
                ds, draw = intake_call("GET", "/intake/disk", timeout=15)
                disk = json.loads(draw) if ds == 200 else None
            except (RuntimeError, ValueError) as e:
                return self.send_json(502, {"error": str(e)})
            return self.send_json(200, {"items": items, "disk": disk and {k: disk.get(k) for k in ("free_bytes", "used_bytes")}})
        if path.startswith("/api/intake/items/"):
            rest = path[len("/api/intake/items/"):].split("/")
            if not INTAKE_ID.match(rest[0]) or rest[1:] not in ([], ["content"]):
                return self.send_json(400, {"error": "bad item"})
            try:
                status, raw = intake_call("GET", "/intake/items/" + rest[0])
                if status != 200:
                    return self.send_json(502, {"error": intake_error(status, raw, "Could not open that item")})
                item = json.loads(raw)
                if not rest[1:]:
                    return self.send_json(200, item)
                return self.intake_content(rest[0], item, "download" in query)
            except (RuntimeError, ValueError) as e:
                return self.send_json(502, {"error": str(e)})
        if path == "/api/gate":
            return self.send_json(200, {"keys": len(load_keys()), "canRegister": os.path.exists(ALLOW_REGISTER),
                                        "origin": ORIGIN})
        if path == "/api/agents":
            try:
                code, out, err = agent("python3 -", stdin=LIST_RUNS)
                if code != 0:
                    raise RuntimeError(err.splitlines()[-1] if err else f"exit {code}")
                return self.send_json(200, {"items": json.loads(out or "[]")})
            except Exception as e:
                return self.send_json(502, {"error": f"agents: {e}"})
        if path.startswith("/api/agents/"):
            rid = path.rsplit("/", 1)[1]
            if not RUN_ID.match(rid):
                return self.send_json(400, {"error": "bad run id"})
            try:
                code, out, err = agent_cli(["show", rid])
                if code != 0:
                    raise RuntimeError(err.splitlines()[-1] if err else f"exit {code}")
                d = json.loads(out)
                d["actions"] = (d.get("actions") or [])[-60:]
                return self.send_json(200, d)
            except Exception as e:
                return self.send_json(502, {"error": f"agent run: {e}"})
        if path in ("/api/room/read", "/api/room/tasks"):
            n = "".join(c for c in query.partition("n=")[2].split("&")[0] if c.isdigit())[:3] or "60"
            args = ["read", n, "--json"] if path.endswith("read") else ["tasks", "--json"]
            try:
                code, out, err = room(args)
                if code != 0:
                    raise RuntimeError(err.splitlines()[-1] if err else f"exit {code}")
                return self.send_json(200, {"items": json.loads(out or "[]")})
            except Exception as e:
                return self.send_json(502, {"error": f"room: {e}"})
        if path in PAGES:
            name, ctype = PAGES[path]
            with open(os.path.join(HERE, name), "rb") as f:
                body = f.read().replace(b"__HEIMDALL_WEB_HOST__", RP_ID.encode())
            self.send_response(200)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(body)
        elif self.path == "/api/models":
            try:
                with urllib.request.urlopen(ollama() + "/api/tags", timeout=5) as r:
                    names = [m["name"] for m in json.load(r)["models"] if "embed" not in m["name"]]
                self.send_json(200, {"models": names, "default": DEFAULT_MODEL})
            except Exception as e:
                self.send_json(502, {"error": f"can't reach Ollama: {e}"})
        else:
            self.send_json(404, {"error": "not found"})

    def do_POST(self):
        origin = self.headers.get("Origin")
        if origin and origin != ORIGIN:            # a browser on another site never gets to act here
            self.close_connection = True
            return self.send_json(403, {"error": "wrong origin"})
        if self.path not in OPEN_POST and self.locked():
            self.close_connection = True           # the unread body must not be taken for the next request
            return self.send_json(401, {"error": "Heimdall is locked. Touch your YubiKey to open it.", "locked": True})
        if self.path == "/api/intake/file":
            return self.intake_upload()            # the body is the file itself, not JSON
        try:
            data = self.body()
        except ValueError as e:
            return self.send_json(400, {"error": str(e)})
        if self.path == "/api/gate/session":
            try:
                gate_verify(data.get("gate"), "session")
            except Exception as e:
                return self.send_json(403, {"error": f"YubiKey: {e}"})
            return self.send_json(200, {"ok": True, "hours": SESSION_TTL / 3600}, headers=[(
                "Set-Cookie", f"{SESSION_COOKIE}={session_new()}; Path=/; Max-Age={SESSION_TTL}; HttpOnly; Secure; SameSite=Strict")])
        if self.path == "/api/gate/lock":
            token = session_cookie(self.headers.get("Cookie"))
            with lock:
                open_sessions.pop(hashlib.sha256(token.encode()).hexdigest(), None)
            return self.send_json(200, {"ok": True}, headers=[(
                "Set-Cookie", f"{SESSION_COOKIE}=; Path=/; Max-Age=0; HttpOnly; Secure; SameSite=Strict")])
        if self.path == "/api/intake/text":
            return None if self.needs_touch(data.get("gate"), "intake:text") else self.intake_text(data)
        if self.path.startswith("/api/intake/items/") and self.path.endswith("/archive"):
            return None if self.needs_touch(data.get("gate"), "intake:archive") else self.intake_archive(self.path.split("/")[4])
        if self.path == "/api/start":
            return self.start()
        if self.path == "/api/send":
            return self.send(data)
        if self.path == "/api/seal":
            return self.seal(data)
        if self.path in ("/api/room/say", "/api/room/task", "/api/room/claim", "/api/room/done"):
            verb = self.path.rsplit("/", 1)[1]
            return None if self.needs_touch(data.get("gate"), "room:" + verb) else self.room_post(verb, data)
        if self.path == "/api/proved/public":
            if self.needs_touch(data.get("gate"), "proved:public"):
                return
            rid = data.get("id")
            try:
                if rid is None:
                    public_call("DELETE")
                    state = {"id": None}
                else:
                    if not isinstance(rid, str) or not RUN_ID.match(rid):
                        return self.send_json(400, {"error": "bad run id"})
                    page = public_page(rid)
                    public_call("PUT", page.encode())
                    state = {"id": rid, "at": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds")}
                with open(os.open(PUBLIC_STATE, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), "w") as f:
                    json.dump(state, f)
            except ValueError as e:
                return self.send_json(400, {"error": str(e)})
            except Exception as e:
                return self.send_json(502, {"error": f"couldn't update the public page: {e}"})
            return self.send_json(200, dict(state, url=PUBLIC_URL))
        if self.path == "/api/gate/challenge":
            purpose = data.get("purpose")
            if purpose not in ("register", "session") + WRITE_PURPOSES:
                return self.send_json(400, {"error": "unknown purpose"})
            if purpose in WRITE_PURPOSES and self.locked():
                return self.send_json(401, {"error": "Heimdall is locked. Touch your YubiKey to open it.", "locked": True})
            if purpose == "register" and not os.path.exists(ALLOW_REGISTER):
                return self.send_json(403, {"error": "registration is closed"})
            return self.send_json(200, {"challenge": new_challenge(purpose), "rpId": RP_ID,
                                        "keys": [k["id"] for k in load_keys()]})
        if self.path == "/api/gate/register":
            try:
                n = gate_register(data)
            except Exception as e:
                return self.send_json(400, {"error": f"registration failed: {e}"})
            return self.send_json(200, {"ok": True, "keys": n})
        if self.path == "/api/agents/start" or (self.path.startswith("/api/agents/")
                                                and self.path.rsplit("/", 1)[1] in ("stop", "resume", "handoff")):
            verb = "start" if self.path.endswith("/start") else self.path.rsplit("/", 1)[1]
            try:
                gate_verify(data.get("gate"), "agents:" + verb)
            except Exception as e:
                return self.send_json(403, {"error": f"YubiKey: {e}"})
            if verb == "start":
                return self.agent_start(data)
            return self.agent_act(self.path.split("/")[3], verb, data)
        self.send_json(404, {"error": "not found"})

    def intake_content(self, iid, item, download):
        """A stored item's bytes. Shown in the page only if it is a plain picture; anything else is a download."""
        mime = str(item.get("mime") or "").split(";")[0].strip().lower()
        inline = mime in INTAKE_INLINE and not download
        name = intake_name(str(item.get("original_filename") or "")) or f"intake-{iid}"
        conn, token = intake_open(6 * 60 * 60)
        try:
            conn.request("GET", f"/intake/items/{iid}/content", headers={"Authorization": "Bearer " + token})
            r = conn.getresponse()
            if r.status != 200:
                return self.send_json(502, {"error": intake_error(r.status, r.read(), "Could not read that file")})
            self.send_response(200)
            self.send_header("Content-Type", mime if inline else "application/octet-stream")
            self.send_header("X-Content-Type-Options", "nosniff")
            self.send_header("Content-Security-Policy", "default-src 'none'; sandbox")
            self.send_header("Content-Disposition", ("inline" if inline else "attachment") +
                             "; filename*=UTF-8''" + urllib.parse.quote(name, safe=""))
            if r.getheader("Content-Length"):
                self.send_header("Content-Length", r.getheader("Content-Length"))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            while True:
                chunk = r.read(1024 * 1024)
                if not chunk:
                    break
                self.wfile.write(chunk)
        except (BrokenPipeError, ConnectionResetError):
            pass
        except (OSError, http.client.HTTPException):
            self.close_connection = True
        finally:
            conn.close()

    def intake_text(self, data):
        text = data.get("text").strip() if isinstance(data.get("text"), str) else ""
        if not text:
            return self.send_json(400, {"error": "nothing to store"})
        payload = {"kind": "text", "body": text, "sender": INTAKE_SENDER, "source_machine": "heimdall-web"}
        tag = data.get("tag").strip()[:200] if isinstance(data.get("tag"), str) else ""
        if tag:
            payload["tags"] = tag
        try:
            status, raw = intake_call("POST", "/intake/items", json.dumps(payload).encode(),
                                      {"Content-Type": "application/json"}, timeout=120)
        except RuntimeError as e:
            return self.send_json(502, {"error": str(e)})
        if status != 201:
            return self.send_json(502, {"error": intake_error(status, raw, "Intake did not store that text")})
        self.send_json(200, {"ok": True, "id": json.loads(raw).get("id")})

    def intake_upload(self):
        """A file or photo, passed straight through to Intake as it arrives (never held whole in memory or on disk)."""
        def refuse(code, msg):
            self.close_connection = True           # the unread body must not be taken for the next request
            return self.send_json(code, {"error": msg})
        try:
            size = int(self.headers.get("Content-Length") or -1)
        except ValueError:
            size = -1
        try:
            gate_verify(json.loads(unb64u(self.headers.get("X-Gate") or "")), "intake:file")
        except Exception as e:
            return refuse(403, f"YubiKey: {e}" if isinstance(e, ValueError) and "base64" not in str(e) else "YubiKey: this needs a YubiKey touch")
        name = intake_name(urllib.parse.unquote(self.headers.get("X-Filename") or ""))
        if size < 0:
            return refuse(411, "the upload has no length. Nothing was stored.")
        if not name:
            return refuse(400, "That filename is not allowed. Nothing was stored.")
        mime = (self.headers.get("Content-Type") or "").split(";")[0].strip().lower()
        if not __import__("re").match(r"^[a-z0-9!#$&^_.+-]+/[a-z0-9!#$&^_.+-]+$", mime):
            mime = mimetypes.guess_type(name)[0] or "application/octet-stream"
        kind = "photo" if mime.startswith("image/") or os.path.splitext(name)[1].lower() in INTAKE_PHOTO else "file"
        headers = {"Content-Type": mime, "Content-Length": str(size)}
        intake_meta(headers, "X-Intake-Filename", name)
        intake_meta(headers, "X-Intake-Kind", kind)
        intake_meta(headers, "X-Intake-Sender", INTAKE_SENDER)
        intake_meta(headers, "X-Intake-Source-Machine", "heimdall-web")
        intake_meta(headers, "X-Intake-Mime", mime)
        intake_meta(headers, "X-Intake-Tags", urllib.parse.unquote(self.headers.get("X-Tags") or "").strip()[:200])
        try:
            conn, token = intake_open(6 * 60 * 60)
        except RuntimeError as e:
            return refuse(502, str(e))
        try:
            conn.putrequest("POST", "/intake/items")
            conn.putheader("Authorization", "Bearer " + token)
            for k, v in headers.items():
                conn.putheader(k, v)
            conn.endheaders()
            left = size
            while left > 0:
                chunk = self.rfile.read(min(left, 1024 * 1024))
                if not chunk:
                    raise OSError("the upload stopped early")
                conn.send(chunk)
                left -= len(chunk)
            r = conn.getresponse()
            status, raw = r.status, r.read()
        except (OSError, http.client.HTTPException) as e:
            return refuse(502, f"the upload did not finish, so nothing was stored ({e})")
        finally:
            conn.close()
        if status != 201:
            self.close_connection = True
            return self.send_json(502, {"error": intake_error(status, raw, "Intake did not store that file")})
        d = json.loads(raw)
        self.send_json(200, {"ok": True, "id": d.get("id"), "new": bool(d.get("blob_new")), "name": name})

    def intake_archive(self, iid):
        if not INTAKE_ID.match(iid):
            return self.send_json(400, {"error": "bad item"})
        try:
            status, raw = intake_call("POST", f"/intake/items/{iid}/archive", b"", {"Content-Length": "0"}, timeout=30)
        except RuntimeError as e:
            return self.send_json(502, {"error": str(e)})
        if status != 200:
            return self.send_json(502, {"error": intake_error(status, raw, "Could not archive that item. Nothing was erased")})
        self.send_json(200, {"ok": True})

    def agent_start(self, data):
        """Start an agent (proved mode) in a folder under the claude login's home; default ~/work.

        `runners` is who starts, then who the run hands off to, in order. One name means no handoff.
        """
        task = data.get("task").strip() if isinstance(data.get("task"), str) else ""
        if not task:
            return self.send_json(400, {"error": "no task"})
        seq = agent_sequence(data)
        if not seq:
            return self.send_json(400, {"error": "pick Claude, Grok, or Codex"})
        folder = data.get("cwd").strip() if isinstance(data.get("cwd"), str) and data.get("cwd").strip() else "work"
        cwd = os.path.normpath(folder if folder.startswith("/") else os.path.join(AGENT_HOME, folder))
        if cwd != AGENT_HOME and not cwd.startswith(AGENT_HOME + "/"):
            return self.send_json(400, {"error": f"the folder must be inside {AGENT_HOME}"})
        name = data.get("name").strip()[:60] if isinstance(data.get("name"), str) else ""
        who, *chain = seq
        import shlex
        args = ["start", "--who", who, "--cwd", cwd] + (["--name", name] if name else [])
        args += ["--handoff", ",".join(chain)] if chain else ["--no-handoff"]
        args += ["--", task[:8000]]
        cmd = f"mkdir -p {shlex.quote(cwd)} && PATH=$HOME/.local/bin:$PATH " + \
              " ".join(shlex.quote(a) for a in ["python3", AGENT_BIN] + args)
        try:
            code, out, err = agent(cmd, timeout=60)
        except subprocess.TimeoutExpired:
            return self.send_json(504, {"error": "starting the agent took over 60 s"})
        except OSError as e:
            return self.send_json(502, {"error": f"couldn't reach the claude login: {e}"})
        rid = (out.strip().splitlines() or [""])[-1]
        if code != 0 or not RUN_ID.match(rid):
            return self.send_json(502, {"error": (err.splitlines()[-1] if err else out.strip()[-200:]) or f"exit {code}"})
        self.send_json(200, {"id": rid})

    def agent_act(self, rid, verb, data):
        if not RUN_ID.match(rid):
            return self.send_json(400, {"error": "bad run id"})
        if verb == "handoff":
            who = data.get("who").strip().lower() if isinstance(data.get("who"), str) else ""
            if who not in RUNNERS:
                return self.send_json(400, {"error": "hand off to Claude, Grok, or Codex"})
            args = ["handoff", rid, "--who", who]
        else:
            args = ["stop", rid] if verb == "stop" else ["resume", rid]
            if verb == "resume":
                text = data.get("text").strip()[:4000] if isinstance(data.get("text"), str) else ""
                if text:
                    args.append(text)
        try:
            code, out, err = agent_cli(args, timeout=60)
        except (subprocess.TimeoutExpired, OSError) as e:
            return self.send_json(502, {"error": str(e)})
        if code != 0:
            return self.send_json(502, {"error": err.splitlines()[-1] if err else f"exit {code}"})
        if verb == "handoff":
            new_id = (out.strip().splitlines() or [""])[-1]
            if not RUN_ID.match(new_id):
                return self.send_json(502, {"error": "handoff did not return a run"})
            return self.send_json(200, {"ok": True, "id": new_id})
        self.send_json(200, {"ok": True, "out": out.strip()[-300:]})

    def room_post(self, verb, data):
        """say/task take text (sent on stdin, so it is never a shell argument); claim/done take a task id."""
        text = data.get("text") if isinstance(data.get("text"), str) else ""
        if verb in ("say", "task"):
            text = text.strip()[:8000]
            if not text:
                return self.send_json(400, {"error": "nothing to post"})
            args, stdin = [verb, "-"], text
            if verb == "task":                    # room task takes its text as one argument, not "-"
                args, stdin = ["task", "--spec", "-"], json.dumps({"text": text})
        else:
            tid = data.get("id") if isinstance(data.get("id"), str) else ""
            if not ROOM_ID.match(tid):
                return self.send_json(400, {"error": "bad task id"})
            args, stdin = [verb, tid], None
            if verb == "done" and text.strip():
                args.append(text.strip()[:2000])
        try:
            code, out, err = room(args, stdin)
        except subprocess.TimeoutExpired:
            return self.send_json(504, {"error": "the room took over 20 s"})
        except OSError as e:
            return self.send_json(502, {"error": f"couldn't run the room command: {e}"})
        if code != 0:
            return self.send_json(502, {"error": err.splitlines()[-1] if err else f"exit {code}"})
        self.send_json(200, {"ok": True, "out": out.strip()})

    def start(self):
        try:
            code, out, err = bridge("prep", timeout=60)
        except subprocess.TimeoutExpired:
            return self.send_json(504, {"error": "the chat bridge took over 60 s"})
        if code != 0 or not out or "system" not in out:
            return self.send_json(502, {"error": "boot failed: " + (err.splitlines()[-1] if err else "no system prompt")})
        sid = f"chat-{datetime.datetime.now():%Y-%m-%dT%H:%M:%S}-{secrets.token_hex(2)}"
        with lock:
            sessions[sid] = out["system"]
        self.send_json(200, {"session": sid, "user_name": out.get("user_name", local_conf("OWNER_NAME", "you")), "persona": out.get("persona", "")})

    def send(self, data):
        sid = data.get("session")
        with lock:
            system = sessions.get(sid)
        if system is None:
            return self.send_json(409, {"error": "this chat isn't open on the server any more; start a new one"})
        try:
            msgs = clean(data.get("messages"))
        except ValueError as e:
            return self.send_json(400, {"error": str(e)})
        extra = data.get("extra")
        history = [{"role": "system", "content": system}] + msgs
        if isinstance(extra, str) and extra:
            history.append({"role": "user", "content": extra[:2000]})
        elif msgs and msgs[-1]["role"] == "user":
            log(sid, "user", msgs[-1]["content"])
        model = data.get("model") if isinstance(data.get("model"), str) and data.get("model") else DEFAULT_MODEL
        req = urllib.request.Request(ollama() + "/api/chat", headers={"Content-Type": "application/json"},
                                     data=json.dumps({"model": model, "messages": history, "stream": True}).encode())
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Accel-Buffering", "no")
        self.end_headers()
        reply = []
        try:
            with urllib.request.urlopen(req, timeout=300) as r:
                for line in r:
                    try:
                        d = json.loads(line)
                    except ValueError:
                        continue
                    piece = (d.get("message") or {}).get("content") or ""
                    if d.get("error"):
                        piece = f"\n[Ollama error: {d['error']}]"
                    if piece:
                        reply.append(piece)
                        self.wfile.write(piece.encode())
                        self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass                                  # the page went away; still log what was said
        except Exception as e:
            msg = f"\n[Can't reach Ollama: {e}]"
            reply.append(msg)
            try:
                self.wfile.write(msg.encode())
            except OSError:
                pass
        log(sid, "assistant", "".join(reply).strip())
        self.close_connection = True

    def seal(self, data):
        sid = data.get("session")
        with lock:
            system = sessions.get(sid)
        if system is None:
            return self.send_json(409, {"error": "this chat isn't open on the server any more"})
        try:
            msgs = clean(data.get("messages"))
        except ValueError as e:
            return self.send_json(400, {"error": str(e)})
        try:
            code, out, err = bridge("seal", stdin=json.dumps([{"role": "system", "content": system}] + msgs), timeout=120)
        except subprocess.TimeoutExpired:
            return self.send_json(504, {"error": "saving the summary took over 2 minutes; the chat is kept"})
        if code == 0 and out and out.get("packet_id"):
            result = f"Chat summary saved ({out['packet_id']})" if out.get("read_back") else \
                     f"Chat summary sent ({out['packet_id']}) but couldn't confirm it was saved"
            saved = True
        elif code == 0 and out and out.get("skipped"):
            result, saved = f"Nothing to save: {out['skipped']}", True
        else:
            result, saved = "Seal failed: " + (err.splitlines()[-1] if err else f"exit {code}"), False
        log(sid, "seal", result)
        if saved:
            with lock:
                sessions.pop(sid, None)
        self.send_json(200 if saved else 502, {"saved": saved, "result": result})


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=8750)
    a = ap.parse_args()
    if not os.path.isfile(BRIDGE):
        sys.exit(f"chat bridge not found at {BRIDGE}")
    print(f"Heimdall Web on http://{a.host}:{a.port}  (Ollama {ollama()}, bridge {BRIDGE})", flush=True)
    ThreadingHTTPServer((a.host, a.port), Handler).serve_forever()


if __name__ == "__main__":
    main()
