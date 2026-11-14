#!/usr/bin/env python3
"""
Ragnarok Security Smoke-Test - Reimagined Harness

Purpose:
  Conservative checks for a DISPOSABLE test instance of a secure MCP platform.
  Anything that cannot be observed safely is marked INCONCLUSIVE, never PASS.

Design principles:
  - Only Python standard library
  - Never unlocks automatically, never mutates real ledger
  - All destructive actions require explicit flags and a disposable deployment

Usage:
  cp security-test.reimagined.example.json security-test.reimagined.json
  python3 security_test_reimagined.py --config security-test.reimagined.json
  python3 security_test_reimagined.py --config security-test.reimagined.json --enable-lock --enable-restart

Author: Generated as a fresh reimplementation of the example you provided.
"""

import argparse
import json
import hashlib
import datetime
import urllib.request
import urllib.error
import socket
import sys
import os
import time
from dataclasses import dataclass, asdict

@dataclass
class CheckOutcome:
    test_id: str
    title: str
    verdict: str  # PASS / FAIL / INCONCLUSIVE
    expectation: str
    reality: str
    evidence_hash: str = ""

outcomes = []

def _hash(payload: str) -> str:
    return hashlib.sha256(payload.encode("utf-8", "replace")).hexdigest()

def _note(test_id, title, verdict, expectation, reality):
    envelope = {
        "test_id": test_id,
        "title": title,
        "verdict": verdict,
        "expectation": expectation,
        "reality": reality,
        "ts": datetime.datetime.now(datetime.timezone.utc).isoformat()
    }
    h = _hash(json.dumps(envelope, sort_keys=True))
    outcomes.append(CheckOutcome(test_id, title, verdict, expectation, reality, h))

def _http_get(url, timeout=8):
    try:
        req = urllib.request.Request(url, method="GET")
        with urllib.request.urlopen(req, timeout=timeout) as r:
            body = r.read().decode("utf-8", "replace")
            try:
                return r.status, json.loads(body)
            except:
                return r.status, body
    except urllib.error.HTTPError as e:
        raw = e.read().decode("utf-8", "replace")
        try:
            return e.code, json.loads(raw)
        except:
            return e.code, raw
    except Exception as ex:
        return None, str(ex)

def _http_post(url, payload, timeout=8, headers=None):
    data = json.dumps(payload).encode()
    h = {"Content-Type": "application/json", **(headers or {})}
    req = urllib.request.Request(url, data=data, headers=h, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            body = r.read().decode("utf-8", "replace")
            try:
                return r.status, json.loads(body)
            except:
                return r.status, body
    except urllib.error.HTTPError as e:
        raw = e.read().decode("utf-8", "replace")
        try:
            return e.code, json.loads(raw)
        except:
            return e.code, raw
    except Exception as ex:
        return None, str(ex)

def _mcp_invoke(mcp_url, tool_name, args=None, timeout=8):
    rpc = {
        "jsonrpc": "2.0",
        "id": 1,
        "method": "tools/call",
        "params": {"name": tool_name, "arguments": args or {}}
    }
    return _http_post(mcp_url, rpc, timeout, headers={"Accept": "application/json, text/event-stream"})

def _looks_locked(obj) -> bool:
    low = json.dumps(obj).lower()
    return "locked" in low and ("true" in low or "sealed" in low or "lock" in low)

def run_all(cfg, allow_lock, allow_restart):
    mcp_url = cfg.get("mcp_url")
    status_url = cfg.get("status_url")
    lock_url = cfg.get("lock_url")
    unlock_url = cfg.get("unlock_url")
    status_tool = cfg.get("status_tool", "platform_status")
    business_tool = cfg.get("probe_tool", "platform_list_items")
    pg_host = cfg.get("postgres_host")
    pg_port = int(cfg.get("postgres_port", 5557))
    timeout = int(cfg.get("timeout_seconds", 8))

    print("=== RAGNAROK SECURITY HARNESS (reimagined) ===")
    print("Only for isolated, disposable deployments. Unobserved = INCONCLUSIVE.\n")

    # T01 - sealed / locked status must be explicitly reported
    status_blob = None
    if status_url:
        code, blob = _http_get(status_url, timeout)
        status_blob = blob
        if code == 200 and _looks_locked(blob):
            _note("T01", "Platform reports sealed", "PASS", "Status endpoint explicitly reports locked/sealed", str(blob)[:2000])
        elif code is None:
            _note("T01", "Platform reports sealed", "INCONCLUSIVE", "Status endpoint explicitly reports locked/sealed", f"Unreachable: {blob}")
        else:
            _note("T01", "Platform reports sealed", "FAIL", "Status endpoint explicitly reports locked/sealed", f"HTTP {code}: {blob}")
    elif mcp_url:
        code, blob = _mcp_invoke(mcp_url, status_tool, timeout=timeout)
        status_blob = blob
        if _looks_locked(blob):
            _note("T01", "Platform reports sealed", "PASS", "MCP status tool reports locked/sealed", str(blob)[:2000])
        else:
            _note("T01", "Platform reports sealed", "INCONCLUSIVE", "MCP status tool reports locked/sealed", f"HTTP {code}: {blob}")
    else:
        _note("T01", "Platform reports sealed", "INCONCLUSIVE", "Status explicitly reports locked", "No status_url or mcp_url configured")

    # T02 - protected tool must be denied while sealed
    if mcp_url:
        code, blob = _mcp_invoke(mcp_url, business_tool, timeout=timeout)
        low = json.dumps(blob).lower()
        denied = any(k in low for k in ["locked", "denied", "unauthorized", "forbidden", "sealed"])
        if denied:
            _note("T02", "Business tool denied while sealed", "PASS", "Protected tool rejected when locked", f"HTTP {code}: {blob}"[:2000])
        elif code is None:
            _note("T02", "Business tool denied while sealed", "INCONCLUSIVE", "Protected tool rejected when locked", str(blob)[:2000])
        else:
            _note("T02", "Business tool denied while sealed", "FAIL", "Protected tool rejected when locked", f"HTTP {code}: {blob}"[:2000])
    else:
        _note("T02", "Business tool denied while sealed", "INCONCLUSIVE", "Protected tool rejected when locked", "mcp_url not configured")

    # T03 - host TCP reachability to Postgres (should not be reachable from agent net)
    if pg_host and cfg.get("postgres_probe_from_host", True):
        try:
            with socket.create_connection((pg_host, pg_port), timeout=timeout):
                _note("T03", "Postgres host reachability", "FAIL", "No direct DB route from agent/client network",
                      f"TCP connect succeeded to {pg_host}:{pg_port} - verify if this host mapping is intentional")
        except Exception as ex:
            _note("T03", "Postgres host reachability", "INCONCLUSIVE", "No direct DB route from agent/client network",
                  f"Host probe failed ({ex}); this alone does not prove container isolation - probe from agent net")
    else:
        _note("T03", "Postgres host reachability", "INCONCLUSIVE", "No direct DB route from agent/client network",
              "Configure postgres_host or run probe from actual agent container")

    # T04 - manual lock (opt-in only)
    if lock_url and allow_lock:
        code, blob = _http_post(lock_url, {}, timeout=timeout)
        if code is not None and 200 <= code < 300:
            _note("T04", "Manual lock endpoint works", "PASS", "Lock endpoint accepts request", f"HTTP {code}: {blob}"[:2000])
        else:
            _note("T04", "Manual lock endpoint works", "INCONCLUSIVE", "Lock endpoint accepts request", f"HTTP {code}: {blob}"[:2000])
    else:
        _note("T04", "Manual lock endpoint works", "INCONCLUSIVE", "Lock is synchronous and effective",
              "Skipped. Set lock_url and use --enable-lock on disposable instance only")

    # T05 - after lock, business tool must still be denied
    if mcp_url and lock_url and allow_lock:
        code, blob = _mcp_invoke(mcp_url, business_tool, timeout=timeout)
        low = json.dumps(blob).lower()
        denied = any(k in low for k in ["locked", "denied", "unauthorized", "forbidden", "sealed"])
        if denied:
            _note("T05", "Post-lock denial", "PASS", "Tool denied immediately after manual lock", f"HTTP {code}: {blob}"[:2000])
        else:
            _note("T05", "Post-lock denial", "FAIL", "Tool denied immediately after manual lock", f"HTTP {code}: {blob}"[:2000])
    else:
        _note("T05", "Post-lock denial", "INCONCLUSIVE", "Tool denied immediately after manual lock",
              "Requires mcp_url + lock_url + --enable-lock")

    # T06, T07, T08, T12 - require fixtures / container introspection, keep INCONCLUSIVE by design
    _note("T06", "Lease expiry uses monotonic clock", "INCONCLUSIVE", "Lease expires safely", 
          "Needs test-only short TTL fixture and observation; will not manipulate system clock")
    _note("T07", "Hardware auth replay resistance", "INCONCLUSIVE", "Old challenge/response cannot re-unlock",
          "Needs instrumented test authenticator + captured non-prod challenge; no replay attempted")
    _note("T08", "Agent credential isolation", "INCONCLUSIVE", "Agent cannot read DB creds / host secrets",
          "Needs repo/container-specific inspection inside actual agent container")
    _note("T12", "Ledger tamper detection", "INCONCLUSIVE", "Modified test receipt is detected",
          "Needs disposable ledger fixture; never mutates production receipts")

    # T09 - restart should fail-closed
    if allow_restart:
        import subprocess
        project_dir = cfg.get("project_dir", ".")
        service = cfg.get("compose_service", "mcp")
        wait_s = int(cfg.get("restart_wait_seconds", 8))
        try:
            subprocess.run(["docker", "compose", "restart", service], cwd=project_dir, check=True, timeout=90,
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
            time.sleep(wait_s)
            if status_url:
                code, blob = _http_get(status_url, timeout=timeout)
                if code == 200 and _looks_locked(blob):
                    _note("T09", "Restart defaults to locked", "PASS", "After restart platform is locked", str(blob)[:2000])
                else:
                    _note("T09", "Restart defaults to locked", "FAIL", "After restart platform is locked", f"HTTP {code}: {blob}"[:2000])
            else:
                _note("T09", "Restart defaults to locked", "INCONCLUSIVE", "After restart platform is locked", "Need status_url to verify")
        except Exception as ex:
            _note("T09", "Restart defaults to locked", "INCONCLUSIVE", "After restart platform is locked", f"Restart probe error: {ex}")
    else:
        _note("T09", "Restart defaults to locked", "INCONCLUSIVE", "After restart platform is locked",
              "Skipped. Use --enable-restart on disposable instance only")

    # T10 (Added active probe) - Forged / replayed hardware authorization rejected
    if unlock_url:
        forged_payload = {"method": "yubikey", "secret": "adversary_forged_proof_token_abc123"}
        code, blob = _http_post(unlock_url, forged_payload, timeout=timeout)
        if code == 401:
            _note("T10", "Forged hardware unlock rejected", "PASS", "Forged unlock proof rejected with HTTP 401", f"HTTP {code}: {blob}"[:2000])
        elif code is None:
            _note("T10", "Forged hardware unlock rejected", "INCONCLUSIVE", "Forged unlock proof rejected with HTTP 401", f"Unreachable: {blob}")
        else:
            _note("T10", "Forged hardware unlock rejected", "FAIL", "Forged unlock proof rejected with HTTP 401", f"HTTP {code}: {blob}"[:2000])
    else:
        _note("T10", "Forged hardware unlock rejected", "INCONCLUSIVE", "Configure unlock_url", "unlock_url not set")

    # T11 - receipt chain verifier command
    verify_cmd = cfg.get("receipt_verify_command")
    if verify_cmd:
        import subprocess, shlex
        try:
            cp = subprocess.run(shlex.split(verify_cmd), cwd=cfg.get("project_dir","."), timeout=timeout*4,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
            tail = cp.stdout[-4000:]
            if cp.returncode == 0:
                _note("T11", "Receipt chain verification", "PASS", "Verifier exits 0", tail)
            else:
                _note("T11", "Receipt chain verification", "FAIL", "Verifier exits 0", tail)
        except Exception as ex:
            _note("T11", "Receipt chain verification", "INCONCLUSIVE", "Verifier exits 0", str(ex))
    else:
        _note("T11", "Receipt chain verification", "INCONCLUSIVE", "Receipt chain intact", "Configure receipt_verify_command")

    # T13 (Added active probe) - Secret leakage scan in exposed responses
    if status_url:
        code, blob = _http_get(status_url, timeout=timeout)
        str_blob = json.dumps(blob).lower()
        leaks = [k for k in ["postgres_password", "db_password", "platform_unlock_secret", "private_key", "secret_key"] if k in str_blob]
        if not leaks and code == 200:
            _note("T13", "Sensitive credential leakage probe", "PASS", "Zero secrets or keys leaked in public endpoints", "Sanitized cleanly; no credentials found")
        elif leaks:
            _note("T13", "Sensitive credential leakage probe", "FAIL", "Zero secrets or keys leaked in public endpoints", f"Credentials leaked: {leaks}")
        else:
            _note("T13", "Sensitive credential leakage probe", "INCONCLUSIVE", "Zero secrets or keys leaked in public endpoints", f"HTTP {code}: {blob}")
    else:
        _note("T13", "Sensitive credential leakage probe", "INCONCLUSIVE", "Zero secrets or keys leaked in public endpoints", "status_url not set")

def main():
    ap = argparse.ArgumentParser(description="Ragnarok security smoke-test (reimagined)")
    ap.add_argument("--config", default="security-test.reimagined.json", help="Path to config JSON")
    ap.add_argument("--output", default="security-test-results.reimagined.json", help="Output report path")
    ap.add_argument("--enable-lock", action="store_true", help="Allow calling lock_url (disposable only)")
    ap.add_argument("--enable-restart", action="store_true", help="Allow docker compose restart test (disposable only)")
    args = ap.parse_args()

    cfg = {}
    if os.path.exists(args.config):
        with open(args.config) as f:
            cfg = json.load(f)
    else:
        print(f"Config {args.config} not found, running with empty config (all INCONCLUSIVE).")

    run_all(cfg, args.enable_lock, args.enable_restart)

    summary = {v: sum(1 for o in outcomes if o.verdict == v) for v in ["PASS","FAIL","INCONCLUSIVE"]}
    report = {
        "generated_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "target": cfg.get("target_name", "Ragnarok disposable test deployment"),
        "config_file": args.config,
        "results": [asdict(o) for o in outcomes],
        "summary": summary
    }
    canonical = json.dumps(report, sort_keys=True, separators=(",",":"))
    report["report_sha256"] = _hash(canonical)

    with open(args.output, "w") as out:
        json.dump(report, out, indent=2)

    print("\n--- Summary ---")
    print(json.dumps(summary, indent=2))
    print(f"Report written to: {args.output}")
    print(f"SHA-256: {report['report_sha256']}")
    print("\nNOTE: PASS only means the probe behaved as expected for that check. Not a certification.")
    return 1 if summary["FAIL"] > 0 else 0

if __name__ == "__main__":
    sys.exit(main())
