"""Run SQL against script_catalog on Alexus via ssh + podman exec (local socket; no password on the wire)."""
import subprocess, socket, os
# On Alexus itself (summary run, web app host) talk to the container directly; elsewhere go over ssh.
LOCAL = os.environ.get("SC_LOCAL") == "1" or socket.gethostname().split(".")[0] == "alexus"
SSH = [] if LOCAL else ["ssh", "-o", "BatchMode=yes", "grok@alexus"]
PSQL = "podman exec -i ragnarok-pipe-db psql -v ON_ERROR_STOP=1 -q -X -U script_catalog -d script_catalog"

def run(sql, args="", check=True):
    cmd = ["bash", "-c", PSQL + " " + args] if LOCAL else SSH + [PSQL + " " + args]
    r = subprocess.run(cmd, input=sql, capture_output=True, text=True)
    if check and r.returncode != 0:
        raise RuntimeError("psql failed: " + r.stderr[-2000:])
    return r.stdout

def query(sql):
    """Return rows as lists of strings (unit-separator delimited)."""
    out = run(sql, "-At -F $'\\x1f'")
    return [l.split("\x1f") for l in out.split("\n") if l]

def lit(v):
    if v is None: return "NULL"
    if isinstance(v, bool): return "true" if v else "false"
    if isinstance(v, int): return str(v)
    return "'" + str(v).replace("'", "''") + "'"

def arr(xs, typ="text"):
    return "ARRAY[" + ",".join(lit(x) for x in xs) + "]::" + typ + "[]"

def rows(sql):
    """Return rows as dicts (safe for multi-line text columns)."""
    import json
    out = run(f"SELECT coalesce(json_agg(t), '[]') FROM ({sql.strip().rstrip(';')}) t;", "-At")
    return json.loads(out)
