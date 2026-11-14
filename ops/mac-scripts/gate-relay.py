#!/usr/bin/env python3
"""gate-relay: lets a Claude Code session on Alexus (claude@alexus) get the owner's Touch ID for a delete.

Alexus has no Touch ID or YubiKey, so delete-gate.py there writes a request to ~/.ragnarok/gate/req/ and waits.
This relay, running on the Mac, holds one ssh connection to claude@alexus and reads new requests as they appear
(`feed` mode runs on Alexus). For each request it:
  1. recomputes challenge = sha256(nonce + "\\n" + what)[:32] and refuses a request whose text doesn't match it
     (so the text on the Touch ID sheet is the delete that will be approved, not something swapped in);
  2. shows the Touch ID sheet via Ragnarok.app's EnclaveAuthenticator ("Alexus: allow deleting: ...");
  3. sends back the Secure Enclave signature (`answer` mode writes it on Alexus).
delete-gate.py on Alexus verifies the signature against the Mac's public key, which claude@ can read but not change.
No model is involved anywhere, so it costs nothing. Every decision is logged to ~/.ragnarok/heimdall-access.jsonl.

  gate-relay.py serve     (Mac) run in the foreground; reconnects if Alexus drops
  gate-relay.py feed      (Alexus, started by serve over ssh) print each new request as one JSON line
  gate-relay.py answer    (Alexus, started by serve over ssh) read one answer on stdin, write it for the hook
"""
import datetime, hashlib, json, os, re, secrets, subprocess, sys, time

HOME = os.path.expanduser("~")
GATE_DIR = os.path.join(HOME, ".ragnarok/gate")
REMOTE = os.environ.get("GATE_RELAY_HOST", "claude@alexus")
REMOTE_SCRIPT = os.environ.get("GATE_RELAY_SCRIPT", "~" + os.environ.get("GATE_RELAY_OWNER", os.environ.get("USER", "")) + "/Developer/ragnarok/ops/mac-scripts/gate-relay.py")   # the owner's checkout on Alexus
ENCLAVE = os.path.join(HOME, "Applications/Ragnarok.app/Contents/Resources/EnclaveAuthenticator")
ACCESS_LOG = os.path.join(HOME, ".ragnarok/heimdall-access.jsonl")
SSH = ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3"]
HEX = re.compile(r"^[0-9a-f]+$")


def challenge_for(nonce, what):
    return hashlib.sha256((nonce + "\n" + what).encode()).hexdigest()[:32]


def feed():
    req = os.path.join(GATE_DIR, "req")
    os.makedirs(req, mode=0o700, exist_ok=True)
    seen = set()
    while True:
        try:
            names = sorted(n for n in os.listdir(req) if n.endswith(".json") and not n.startswith("."))
        except OSError:
            names = []
        for n in names:
            if n in seen:
                continue
            seen.add(n)
            try:
                print(json.dumps(json.load(open(os.path.join(req, n)))), flush=True)
            except Exception:
                pass
        seen &= set(names)
        time.sleep(0.5)


def answer():
    res = json.loads(sys.stdin.read())
    rid = str(res.get("id", ""))
    if not (HEX.match(rid) and len(rid) == 16):
        sys.exit("bad id")
    resp = os.path.join(GATE_DIR, "resp")
    os.makedirs(resp, mode=0o700, exist_ok=True)
    tmp = os.path.join(resp, f".{rid}.tmp")
    with open(tmp, "w") as f:
        json.dump(res, f)
    os.replace(tmp, os.path.join(resp, rid + ".json"))


def log(ok, detail):
    rec = {"ts": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
           "method": "delete-gate:touchid-for-alexus", "ok": ok, "detail": detail[:300]}
    try:
        with open(ACCESS_LOG, "a") as f:
            f.write(json.dumps(rec) + "\n")
    except OSError:
        pass


def handle(req):
    rid, nonce, ch, what = (str(req.get(k, "")) for k in ("id", "nonce", "challenge", "what"))
    out = {"id": rid, "challenge": ch, "approved": False}
    if not (HEX.match(rid) and len(rid) == 16 and HEX.match(nonce) and HEX.match(ch) and len(ch) == 32):
        out["error"] = "malformed request"
    elif challenge_for(nonce, what) != ch:
        out["error"] = "request text does not match its challenge (refused without asking)"
    else:
        try:
            r = subprocess.run([ENCLAVE, "--challenge", ch, "--reason", "Alexus: allow deleting: " + what[:140]],
                               capture_output=True, text=True, timeout=100)
            res = json.loads(r.stdout.strip().splitlines()[-1]) if r.stdout.strip() else {}
        except Exception as e:
            res = {"error": f"authenticator failed: {e}"}
        if res.get("ok") is True and res.get("challenge") == ch and res.get("signature"):
            out.update(approved=True, signature=res["signature"], key_id=res.get("key_id", ""))
        else:
            out["error"] = str(res.get("error") or "not approved")
    log(out["approved"], f"{what}" + ("" if out["approved"] else f"  [{out.get('error')}]"))
    subprocess.run(SSH + [REMOTE, "python3", "-I", REMOTE_SCRIPT, "answer"], input=json.dumps(out),
                   text=True, capture_output=True, timeout=30)


def serve():
    while True:
        p = subprocess.Popen(SSH + [REMOTE, "python3", "-I", "-u", REMOTE_SCRIPT, "feed"],
                             stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
        print(f"gate-relay: listening to {REMOTE}", flush=True)
        for line in p.stdout:
            try:
                handle(json.loads(line))
            except Exception as e:
                print(f"gate-relay: {e}", flush=True)
        p.wait()
        print(f"gate-relay: connection ended ({p.returncode}); retrying in 10s", flush=True)
        time.sleep(10)


if __name__ == "__main__":
    mode = sys.argv[1] if len(sys.argv) > 1 else ""
    {"serve": serve, "feed": feed, "answer": answer}.get(mode, lambda: sys.exit(__doc__))()
