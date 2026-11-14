#!/usr/bin/env python3
"""
Verification Dyno: the hardware-presence gate fails CLOSED.

Loads the `alexus` script as a module (nothing runs: its main() is behind __main__) and checks
verify_hardware_presence() with a fake terminal, fake gate binaries and a fake key ring. It never
calls the real bin/fido-auth.sh or bin/auth-gate, never reads ~/.alexus (HOME is a temp dir), and needs no network.

  1. no TTY on stdin                       -> refused, and no gate binary is even started
  2. ALEXUS_REQUIRE_AUTH=0 (old off-switch) -> ignored: still refused without a gate
  3. no FIDO2 key/script and no auth-gate  -> refused
  4. a TTY + a gate that says yes          -> allowed; a gate that says no -> refused
  5. FIDO2 key "not inserted" (exit 3) and no Touch ID gate -> refused
  6. only ask / chat / auth-test call the gate; status, cartridges, lookup, verify-receipts don't
"""
import ast
import importlib.machinery
import importlib.util
import io
import os
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(os.path.dirname(HERE), "alexus")

loader = importlib.machinery.SourceFileLoader("alexus_cli_under_test", SCRIPT)
spec = importlib.util.spec_from_loader(loader.name, loader)
ax = importlib.util.module_from_spec(spec)
loader.exec_module(ax)

passed = failed = 0


def check(name, cond):
    global passed, failed
    if cond:
        passed += 1
        print(f"  PASS  {name}")
    else:
        failed += 1
        print(f"  FAIL  {name}")


class FakeStdin(io.StringIO):
    def __init__(self, tty):
        super().__init__("")
        self._tty = tty

    def isatty(self):
        return self._tty


TMP = tempfile.mkdtemp(prefix="alexus-gate-test-")


def script(name, rc):
    p = os.path.join(TMP, name)
    with open(p, "w") as f:
        f.write(f"#!/bin/sh\nexit {rc}\n")
    os.chmod(p, 0o700)
    return p


MISSING = os.path.join(TMP, "does-not-exist")
calls = []
real_system = os.system


def spy_system(cmd):
    calls.append(cmd)
    return real_system(cmd)


def run(tty, auth_gate=MISSING, fido=MISSING, keys=(), env=None):
    """verify_hardware_presence() under controlled conditions; returns (result, gate_calls)."""
    old = (sys.stdin, ax.AUTH_GATE_BIN, ax.FIDO_AUTH_BIN, ax.get_enrolled_keys, os.system,
           os.environ.get("ALEXUS_REQUIRE_AUTH"), ax.render_star_fox_hud, sys.stdout, sys.stderr)
    calls.clear()
    home = os.environ.get("HOME")
    try:
        sys.stdin = FakeStdin(tty)
        ax.AUTH_GATE_BIN, ax.FIDO_AUTH_BIN = auth_gate, fido
        ax.get_enrolled_keys = lambda: list(keys)
        ax.render_star_fox_hud = lambda *a, **k: None
        os.system = spy_system
        os.environ["HOME"] = TMP                  # no real ~/.alexus (legacy credential) in play
        os.environ.pop("ALEXUS_REQUIRE_AUTH", None)
        if env is not None:
            os.environ["ALEXUS_REQUIRE_AUTH"] = env
        sys.stdout = sys.stderr = io.StringIO()   # keep the gate's banners out of the test output
        ok = ax.verify_hardware_presence()
        return ok, list(calls)
    finally:
        (sys.stdin, ax.AUTH_GATE_BIN, ax.FIDO_AUTH_BIN, ax.get_enrolled_keys, os.system, envv,
         ax.render_star_fox_hud, sys.stdout, sys.stderr) = old
        os.environ.pop("ALEXUS_REQUIRE_AUTH", None)
        if envv is not None:
            os.environ["ALEXUS_REQUIRE_AUTH"] = envv
        if home is not None:
            os.environ["HOME"] = home


yes, no = script("gate-yes", 0), script("gate-no", 1)
fido_absent = script("fido-absent", 3)

print("ALEXUS auth gate (fail closed)")
ok, c = run(tty=False, auth_gate=yes)
check("no TTY -> refused even though a gate exists", ok is False)
check("no TTY -> no gate binary was started", c == [])
ok, c = run(tty=False, auth_gate=yes, env="1")
check("no TTY + ALEXUS_REQUIRE_AUTH=1 -> refused", ok is False and c == [])
ok, c = run(tty=False, auth_gate=yes, env="0")
check("no TTY + ALEXUS_REQUIRE_AUTH=0 -> refused (old headless bypass is gone)", ok is False and c == [])
ok, c = run(tty=True, env="0")
check("TTY + ALEXUS_REQUIRE_AUTH=0 + no gate -> refused (env off-switch is gone)", ok is False)
ok, c = run(tty=True, auth_gate=no, env="0")
check("TTY + ALEXUS_REQUIRE_AUTH=0 + gate says no -> refused (the gate still ran)", ok is False and c == [no])
ok, c = run(tty=True)
check("TTY + no FIDO2 key/script + no auth-gate -> refused", ok is False and c == [])
ok, c = run(tty=True, auth_gate=yes)
check("TTY + Touch ID gate says yes -> allowed", ok is True and c == [yes])
ok, c = run(tty=True, auth_gate=no)
check("TTY + Touch ID gate says no -> refused", ok is False and c == [no])
ok, c = run(tty=True, fido=yes, keys=["k"], auth_gate=MISSING)
check("TTY + enrolled key + FIDO2 assertion ok -> allowed", ok is True and c == [yes])
ok, c = run(tty=True, fido=fido_absent, keys=["k"], auth_gate=MISSING)
check("TTY + key not inserted (exit 3) + no Touch ID gate -> refused", ok is False and c == [fido_absent])
ok, c = run(tty=True, fido=fido_absent, keys=["k"], auth_gate=yes)
check("TTY + key not inserted -> falls back to Touch ID (yes) -> allowed", ok is True and c == [fido_absent, yes])
ok, c = run(tty=True, fido=yes, keys=[], auth_gate=MISSING)
check("TTY + FIDO2 script but no enrolled key + no auth-gate -> refused", ok is False and c == [])

# Which commands are gated: read the source, not a guess.
tree = ast.parse(open(SCRIPT).read())
gated = set()
for fn in (n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name.startswith("cmd_")):
    if any(isinstance(x, ast.Call) and getattr(x.func, "id", "") == "verify_hardware_presence" for x in ast.walk(fn)):
        gated.add(fn.name)
check(f"gated commands are exactly ask, chat, auth-test (found: {sorted(gated)})",
      gated == {"cmd_ask", "cmd_chat", "cmd_auth_test"})
for free in ("cmd_status", "cmd_cartridges", "cmd_lookup", "cmd_verify_receipts", "cmd_list_keys"):
    check(f"{free} does not need a touch", free not in gated)
check("cmd_ask has no bypass_auth parameter any more",
      [a.arg for f in tree.body if isinstance(f, ast.FunctionDef) and f.name == "cmd_ask" for a in f.args.args] == ["query"])

# verify-receipts still works headless (on a throwaway copy of a tiny valid chain).
import hashlib, json
rec_file = os.path.join(TMP, "receipts.jsonl")
payload = {"index": 0, "timestamp": "2026-10-30T00:00:00Z", "task": "t", "cartridges": [], "execution_seconds": 0.1,
           "verification": "pass"}
ph = hashlib.sha256(json.dumps(payload, sort_keys=True).encode()).hexdigest()
rh = hashlib.sha256(f"0:2026-10-30T00:00:00Z:{'0'*64}:{ph}".encode()).hexdigest()
with open(rec_file, "w") as f:
    f.write(json.dumps({**payload, "prev_receipt_hash": "0" * 64, "payload_hash": ph, "receipt_hash": rh}) + "\n")
old = (ax.RECEIPTS_FILE, sys.stdin, sys.stdout, ax.verify_hardware_presence)
out = io.StringIO()
try:
    ax.RECEIPTS_FILE, sys.stdin, sys.stdout = rec_file, FakeStdin(False), out
    ax.verify_hardware_presence = lambda *a, **k: (_ for _ in ()).throw(AssertionError("gate called"))
    ax.cmd_verify_receipts()
    vr_ok = "VERIFIED" in out.getvalue()
except (AssertionError, SystemExit):
    vr_ok = False
finally:
    ax.RECEIPTS_FILE, sys.stdin, sys.stdout, ax.verify_hardware_presence = old
check("verify-receipts runs without a TTY and without the gate", vr_ok)

for n in os.listdir(TMP):
    os.remove(os.path.join(TMP, n))
os.rmdir(TMP)
print(f"\n{passed}/{passed + failed} checks passed")
sys.exit(1 if failed else 0)
