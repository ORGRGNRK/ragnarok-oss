#!/usr/bin/env python3
"""Checks for ragnarok-agent-log, in a temp folder (no root, no sudo, nothing real is touched)."""
import importlib.machinery, importlib.util, json, os, subprocess, sys, tempfile, threading

HERE = os.path.dirname(os.path.abspath(__file__))
loader = importlib.machinery.SourceFileLoader("agentlog", os.path.join(HERE, "ragnarok-agent-log"))
m = importlib.util.module_from_spec(importlib.util.spec_from_loader("agentlog", loader)); loader.exec_module(m)
fails = []


def check(name, ok, extra=""):
    print(("ok   " if ok else "FAIL ") + name + (f"  [{extra}]" if extra and not ok else ""))
    if not ok:
        fails.append(name)


with tempfile.TemporaryDirectory() as d:
    led, lock, run = os.path.join(d, "ledger.jsonl"), os.path.join(d, "lock"), "20261111-034607-beaf27"
    lines = [b'{"type":"assistant","n":1}', "héllo ✓ ünïcode".encode(), b"x" * (m.CAP + 500), b'\xff\xfe not utf-8', b'{"type":"result"}']
    for l in lines:
        m.append(led, lock, "claude@box", run, "events.jsonl", l)
    recs = [json.loads(l) for l in open(led, encoding="utf-8")]
    check("each line becomes one numbered record", [r["seq"] for r in recs] == [1, 2, 3, 4, 5])
    check("each record carries the hash of the one before", recs[0]["prev_hash"] == m.ZERO and all(recs[i]["prev_hash"] == recs[i - 1]["hash"] for i in range(1, 5)))
    check("a long line is cut in the text but its full hash and length are kept", recs[2]["cut"] and len(recs[2]["text"]) == m.CAP and recs[2]["len"] == m.CAP + 500)
    check("the chain verifies", m.verify(led) == (True, 5, ""))

    own = os.path.join(d, "events.jsonl")
    open(own, "wb").write(b"\n".join(lines) + b"\n")
    check("a run's own log matches the ledger", m.check(led, run, "events.jsonl", own)[0])
    open(own, "wb").write(b"\n".join([lines[0], b'{"type":"assistant","n":2}'] + lines[2:]) + b"\n")
    check("an edited line in the run's own log is caught", "line 2" in m.check(led, run, "events.jsonl", own)[2])
    open(own, "wb").write(b"\n".join(lines[:3]) + b"\n")
    check("lines deleted from the run's own log are caught", "3 lines" in m.check(led, run, "events.jsonl", own)[2])

    def tamper(fn):
        rows = [json.loads(l) for l in open(led, encoding="utf-8")]
        fn(rows)
        t = os.path.join(d, "t.jsonl")
        open(t, "w", encoding="utf-8").write("".join(json.dumps(r, ensure_ascii=False) + "\n" for r in rows))
        return m.verify(t)
    check("changing a record's text breaks the chain", not tamper(lambda r: r[1].update(text="edited"))[0])
    check("changing who did it breaks the chain", not tamper(lambda r: r[1].update(actor="grok@box"))[0])
    check("removing a record breaks the chain", not tamper(lambda r: r.pop(2))[0])
    check("swapping two records breaks the chain", not tamper(lambda r: r.insert(1, r.pop(2)))[0])
    def rehash(r):
        r[1]["text"] = "edited"; r[1]["hash"] = m.digest(r[1])
    ok, n, why = tamper(rehash)
    check("an edit with its own hash recomputed still breaks at the next record", not ok and "record 3" in why, why)
    check("removing the newest record is NOT caught by the chain alone (that is what append-only and the anchor are for)", tamper(lambda r: r.pop())[0])

    def writer(k):
        for i in range(40):
            m.append(led, lock, f"ai{k}@box", run, "events.jsonl", f"w{k}-{i}".encode())
    ts = [threading.Thread(target=writer, args=(k,)) for k in range(4)]
    [t.start() for t in ts]; [t.join() for t in ts]
    check("four writers at once still make one unbroken chain", m.verify(led) == (True, 165, ""), str(m.verify(led)))

    exe = [sys.executable, os.path.join(HERE, "ragnarok-agent-log")]
    for bad in (["../x", "events.jsonl"], [run, "../../etc/passwd"], [run, "a/b"], [run], ["--file", "/tmp/x", run, "s"]):
        r = subprocess.run(exe + bad, input=b"x\n", capture_output=True)
        check(f"arguments {bad} are refused", r.returncode != 0 and b"usage" in r.stderr)
print("\nall passed" if not fails else f"\n{len(fails)} FAILED")
sys.exit(1 if fails else 0)
