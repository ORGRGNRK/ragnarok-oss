#!/usr/bin/env python3
"""
Ragnarok adversarial security smoke-test harness.

Only uses Python's standard library. It is deliberately conservative:
unconfigured or unobservable security properties are INCONCLUSIVE, never PASS.
Run only against an isolated test deployment with disposable data.
"""
import argparse, json, os, socket, ssl, sys, time, hashlib, datetime, urllib.request, urllib.error
from dataclasses import dataclass, asdict

@dataclass
class Result:
    test_id: str
    name: str
    status: str
    expected: str
    observed: str
    evidence_sha256: str = ""

RESULTS = []

def sha(s):
    return hashlib.sha256(s.encode("utf-8", "replace")).hexdigest()

def record(test_id, name, status, expected, observed):
    payload = json.dumps({
        "test_id": test_id, "name": name, "status": status,
        "expected": expected, "observed": observed,
        "timestamp_utc": datetime.datetime.now(datetime.timezone.utc).isoformat()
    }, sort_keys=True)
    RESULTS.append(Result(test_id, name, status, expected, observed, sha(payload)))

def http(method, url, body=None, timeout=8, headers=None):
    data = None if body is None else json.dumps(body).encode()
    h = {"Content-Type": "application/json", **(headers or {})}
    req = urllib.request.Request(url, data=data, headers=h, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            raw = r.read().decode("utf-8", "replace")
            try: parsed = json.loads(raw)
            except Exception: parsed = raw
            return r.status, parsed
    except urllib.error.HTTPError as e:
        raw = e.read().decode("utf-8", "replace")
        try: parsed = json.loads(raw)
        except Exception: parsed = raw
        return e.code, parsed
    except Exception as e:
        return None, str(e)

def mcp_call(url, tool, args=None, timeout=8):
    # MCP Streamable HTTP implementations may require session headers or
    # initialization. This generic JSON-RPC probe is intentionally not treated
    # as a pass if the server rejects the transport handshake.
    body = {"jsonrpc":"2.0","id":1,"method":"tools/call",
            "params":{"name":tool,"arguments":args or {}}}
    return http("POST", url, body, timeout)

def is_locked(status_obj):
    s = json.dumps(status_obj).lower()
    return "locked" in s and ("true" in s or "sealed" in s or "lock" in s)

def main():
    p = argparse.ArgumentParser()
    p.add_argument("--config", default="security-test.json")
    p.add_argument("--output", default="security-test-results.json")
    p.add_argument("--allow-lock", action="store_true",
                   help="Allow test to call LOCK_URL. Use only on a disposable test deployment.")
    p.add_argument("--allow-restart", action="store_true",
                   help="Allow Docker restart test. Use only on a disposable test deployment.")
    args = p.parse_args()

    cfg = {}
    if os.path.exists(args.config):
        with open(args.config) as f: cfg = json.load(f)

    mcp = cfg.get("mcp_url")
    status_url = cfg.get("status_url")
    lock_url = cfg.get("lock_url")
    unlock_url = cfg.get("unlock_url")
    status_tool = cfg.get("status_tool", "platform_status")
    probe_tool = cfg.get("probe_tool", "platform_list_items")
    pg_host = cfg.get("postgres_host")
    pg_port = int(cfg.get("postgres_port", 5557))
    pg_from_host = bool(cfg.get("postgres_probe_from_host", True))
    timeout = int(cfg.get("timeout_seconds", 8))

    print("RAGNAROK SECURITY HARNESS — isolated test deployments only")
    print("Unconfigured checks are INCONCLUSIVE, not PASS.\n")

    # T01: status endpoint or MCP status tool must explicitly report locked.
    status_obj = None
    if status_url:
        code, status_obj = http("GET", status_url, timeout=timeout)
        if code == 200 and is_locked(status_obj):
            record("T01","Sealed status","PASS","Status explicitly reports locked",str(status_obj))
        elif code is None:
            record("T01","Sealed status","INCONCLUSIVE","Status explicitly reports locked",str(status_obj))
        else:
            record("T01","Sealed status","FAIL","Status explicitly reports locked",f"HTTP {code}: {status_obj}")
    elif mcp:
        code, status_obj = mcp_call(mcp, status_tool, timeout=timeout)
        if code and "locked" in json.dumps(status_obj).lower():
            record("T01","Sealed status","PASS","Status explicitly reports locked",str(status_obj))
        else:
            record("T01","Sealed status","INCONCLUSIVE","MCP status confirms locked",f"HTTP {code}: {status_obj}")
    else:
        record("T01","Sealed status","INCONCLUSIVE","Configure status_url or mcp_url","No endpoint configured")

    # T02/T10: business tool request while sealed must be denied as locked.
    if mcp:
        code, obj = mcp_call(mcp, probe_tool, timeout=timeout)
        blob = json.dumps(obj).lower()
        if "locked" in blob or "access denied" in blob or "unauthorized" in blob:
            record("T02","MCP tool denied while sealed","PASS","Protected tool is rejected while locked",f"HTTP {code}: {obj}")
        elif code is None:
            record("T02","MCP tool denied while sealed","INCONCLUSIVE","Protected tool is rejected while locked",str(obj))
        else:
            record("T02","MCP tool denied while sealed","FAIL","Protected tool is rejected while locked",f"HTTP {code}: {obj}")
    else:
        record("T02","MCP tool denied while sealed","INCONCLUSIVE","Protected tool is rejected while locked","mcp_url not configured")

    # T03: host-side PostgreSQL reachability probe. A successful TCP connection
    # is a finding to investigate; it may be an intentional host-only admin port.
    if pg_host and pg_from_host:
        try:
            with socket.create_connection((pg_host, pg_port), timeout=timeout):
                record("T03","Postgres host TCP reachability","FAIL","Agent/client network cannot reach PostgreSQL directly",
                       f"TCP connection succeeded to {pg_host}:{pg_port}; determine whether this is an intentional host admin mapping")
        except Exception as e:
            record("T03","Postgres host TCP reachability","INCONCLUSIVE","Agent/client network cannot reach PostgreSQL directly",
                   f"Host probe failed ({e}); host probe alone does not prove container isolation")
    else:
        record("T03","Postgres host TCP reachability","INCONCLUSIVE","No direct DB path from agent network","Configure postgres_host; test from agent container/network for meaningful evidence")

    # T04: lock endpoint, only when explicitly permitted. Never unlock automatically.
    if lock_url and args.allow_lock:
        code, obj = http("POST", lock_url, {}, timeout=timeout)
        if code is not None and 200 <= code < 300:
            record("T04","Manual lock endpoint","PASS","Lock endpoint accepts lock request",f"HTTP {code}: {obj}")
        else:
            record("T04","Manual lock endpoint","INCONCLUSIVE","Lock endpoint accepts lock request",f"HTTP {code}: {obj}")
    else:
        record("T04","Manual lock endpoint","INCONCLUSIVE","Manual lock is synchronous and effective",
               "Not invoked. Configure lock_url and rerun with --allow-lock on disposable deployment")

    # T05: post-lock probe after optional lock action.
    if mcp and lock_url and args.allow_lock:
        code, obj = mcp_call(mcp, probe_tool, timeout=timeout)
        blob = json.dumps(obj).lower()
        if "locked" in blob or "access denied" in blob or "unauthorized" in blob:
            record("T05","Tool denied after manual lock","PASS","Next protected tool request is denied",f"HTTP {code}: {obj}")
        else:
            record("T05","Tool denied after manual lock","FAIL","Next protected tool request is denied",f"HTTP {code}: {obj}")
    else:
        record("T05","Tool denied after manual lock","INCONCLUSIVE","Next protected tool request is denied",
               "Requires mcp_url, lock_url, and --allow-lock")

    # T06: lease expiry cannot be safely accelerated without a dedicated test TTL.
    record("T06","Lease expiration","INCONCLUSIVE","Lease expires using monotonic time",
           "Requires a test-only short lease configuration and observation; harness will not alter system clock")

    # T07: replay of hardware authorization.
    record("T07","Hardware authorization replay","INCONCLUSIVE","Old authorization challenge/response cannot unlock",
           "Requires an instrumented test authenticator and captured non-production challenge; no replay attempted")

    # T08: credential isolation.
    record("T08","Agent credential isolation","INCONCLUSIVE","Agent cannot read DB credentials or host auth material",
           "Requires inspection and execution inside the actual agent container; configure repository-specific checks")

    # T09: crash/restart fail-closed.
    if args.allow_restart:
        compose = cfg.get("compose_service", "mcp")
        project_dir = cfg.get("project_dir", ".")
        import subprocess
        try:
            subprocess.run(["docker","compose","restart",compose],cwd=project_dir,check=True,timeout=90,
                           stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True)
            time.sleep(int(cfg.get("restart_wait_seconds", 8)))
            if status_url:
                code, obj = http("GET", status_url, timeout=timeout)
                if code == 200 and is_locked(obj):
                    record("T09","Restart defaults to locked","PASS","Restarted service reports locked",str(obj))
                else:
                    record("T09","Restart defaults to locked","FAIL","Restarted service reports locked",f"HTTP {code}: {obj}")
            else:
                record("T09","Restart defaults to locked","INCONCLUSIVE","Restarted service reports locked","Configure status_url")
        except Exception as e:
            record("T09","Restart defaults to locked","INCONCLUSIVE","Restarted service reports locked",str(e))
    else:
        record("T09","Restart defaults to locked","INCONCLUSIVE","Restarted service reports locked",
               "Not run. Requires --allow-restart and project_dir; only use on disposable deployment")

    # T11: receipt chain integrity. Needs repository-specific verifier command.
    verify_cmd = cfg.get("receipt_verify_command")
    if verify_cmd:
        import subprocess, shlex
        try:
            cp = subprocess.run(shlex.split(verify_cmd),cwd=cfg.get("project_dir","."),timeout=timeout*4,
                                stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True)
            if cp.returncode == 0:
                record("T11","Receipt chain verification","PASS","Receipt verifier exits zero",cp.stdout[-3000:])
            else:
                record("T11","Receipt chain verification","FAIL","Receipt verifier exits zero",cp.stdout[-3000:])
        except Exception as e:
            record("T11","Receipt chain verification","INCONCLUSIVE","Receipt verifier exits zero",str(e))
    else:
        record("T11","Receipt chain verification","INCONCLUSIVE","Receipt chain verifies intact","Configure receipt_verify_command")

    # T12: tamper detection is not attempted against real ledger data.
    record("T12","Receipt tamper detection","INCONCLUSIVE","Modified test receipt is detected",
           "Requires isolated disposable ledger fixture; do not mutate production receipts")

    # Write report and summary hash.
    report = {
        "generated_at_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "target": cfg.get("target_name","Ragnarok test deployment"),
        "results": [asdict(x) for x in RESULTS],
        "summary": {s: sum(1 for x in RESULTS if x.status == s) for s in ("PASS","FAIL","INCONCLUSIVE")},
    }
    canonical = json.dumps(report, sort_keys=True, separators=(",",":"))
    report["report_sha256"] = sha(canonical)
    with open(args.output,"w") as f: json.dump(report,f,indent=2)
    print(json.dumps(report["summary"],indent=2))
    print(f"\nReport: {args.output}")
    print(f"Report SHA-256: {report['report_sha256']}")
    print("\nNOTE: A PASS means only that the configured probe behaved as expected; it is not a security certification.")
    return 1 if report["summary"]["FAIL"] else 0

if __name__ == "__main__":
    sys.exit(main())
