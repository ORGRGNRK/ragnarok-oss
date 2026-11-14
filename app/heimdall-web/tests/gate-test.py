#!/usr/bin/env python3
"""Tests for Heimdall Web's YubiKey gate, with a software authenticator standing in for the key.
Needs the `cryptography` package (Alexus has it). Touches nothing outside a temp folder.

    python3 tests/gate-test.py
"""
import base64, hashlib, importlib.util, json, os, struct, sys, tempfile

from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric import ec

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("server", os.path.join(HERE, "..", "server.py"))
srv = importlib.util.module_from_spec(spec)
spec.loader.exec_module(srv)

tmp = tempfile.mkdtemp(prefix="gate-test-")
srv.GATE_DIR = tmp
srv.CRED_FILE = os.path.join(tmp, "yubikeys.json")
srv.ALLOW_REGISTER = os.path.join(tmp, "allow-register")
srv.RP_ID, srv.ORIGIN = "heimdall.example.ts.net", "https://heimdall.example.ts.net"

b64u = srv.b64u
fails = 0


def check(name, ok):
    global fails
    print(("ok   " if ok else "FAIL ") + name)
    fails += 0 if ok else 1


sys.path.insert(0, HERE)
from fakekey import FakeKey, enc


def refused(fn):
    try:
        fn()
        return False
    except ValueError:
        return True


key = FakeKey()

# registration
check("register refused while closed", refused(lambda: srv.gate_register(key.register(srv.new_challenge("register")))))
open(srv.ALLOW_REGISTER, "w").close()
check("register refused from the wrong origin",
      refused(lambda: srv.gate_register(key.register(srv.new_challenge("register"), origin="http://100.64.0.7:8750"))))
check("register works while open", srv.gate_register(key.register(srv.new_challenge("register"))) == 1)
check("registration closes itself after one key", not os.path.exists(srv.ALLOW_REGISTER))
check("key file is private", oct(os.stat(srv.CRED_FILE).st_mode & 0o777) == "0o600")

# touches
c = srv.new_challenge("agents:start")
good = key.touch(c)
srv.gate_verify(good, "agents:start")
check("a real touch passes", True)
check("the same touch can't be replayed", refused(lambda: srv.gate_verify(good, "agents:start")))
check("no touch is refused", refused(lambda: srv.gate_verify(None, "agents:start")))
check("a touch for stop can't start", refused(lambda: srv.gate_verify(key.touch(srv.new_challenge("agents:stop")), "agents:start")))
check("a made-up challenge is refused", refused(lambda: srv.gate_verify(key.touch(b64u(os.urandom(32))), "agents:start")))
check("wrong origin is refused", refused(lambda: srv.gate_verify(key.touch(srv.new_challenge("agents:start"), origin="https://evil.example"), "agents:start")))
check("no touch flag is refused", refused(lambda: srv.gate_verify(key.touch(srv.new_challenge("agents:start"), touched=False), "agents:start")))
key.count = srv.load_keys()[0]["count"]      # refused touches above moved the fake key's counter; start from the stored one
check("a counter that doesn't go up is refused", refused(lambda: srv.gate_verify(key.touch(srv.new_challenge("agents:start"), bump=0), "agents:start")))
key.count += 5
check("a registration response can't be used as a touch",
      refused(lambda: srv.gate_verify(key.touch(srv.new_challenge("agents:start"), kind="webauthn.create"), "agents:start")))
other = FakeKey()
check("an unregistered key is refused", refused(lambda: srv.gate_verify(other.touch(srv.new_challenge("agents:start")), "agents:start")))
forged = key.touch(srv.new_challenge("agents:start"))
forged["signature"] = other.touch(srv.new_challenge("agents:start"))["signature"]
check("a signature from another key is refused", refused(lambda: srv.gate_verify(forged, "agents:start")))
wrong_site = FakeKey(rp="evil.example"); wrong_site.priv, wrong_site.cred_id = key.priv, key.cred_id; wrong_site.count = 100
check("a touch signed for another site is refused", refused(lambda: srv.gate_verify(wrong_site.touch(srv.new_challenge("agents:start")), "agents:start")))
srv.challenges[srv.new_challenge("agents:start")] = ("agents:start", 0)   # an expired one
exp = [ch for ch, (_, t) in srv.challenges.items() if t == 0][0]
check("an expired challenge is refused", refused(lambda: srv.gate_verify(key.touch(exp), "agents:start")))
srv.gate_verify(key.touch(srv.new_challenge("agents:resume")), "agents:resume")
check("a later real touch still passes", True)

print(f"\n{'all passed' if not fails else str(fails) + ' FAILED'}")
sys.exit(1 if fails else 0)
