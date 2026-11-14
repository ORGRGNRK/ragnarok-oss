#!/usr/bin/env python3
"""Live check of the lock: nothing opens without a YubiKey touch, and every write needs its own touch.

    python3 tests/lock-test.py        (on Alexus; needs `cryptography`)

Starts a private Heimdall Web with a software key (tests/live.py) and makes real requests to it. The one thing it
stores for real is a note in Intake tagged heimdall-web-test, which it archives again. It never posts to the Room.
"""
import json, sys, time

from live import Site, FakeKey, ORIGIN, b64u

fails = []


def check(name, ok, extra=""):
    print(("ok   " if ok else "FAIL ") + name + (f"  [{extra}]" if extra and not ok else ""))
    if not ok:
        fails.append(name)


site = Site()
try:
    # ---- locked
    for page in ("/", "/room", "/agents", "/hub", "/intake", "/timeline", "/proved"):
        s, _, h = site.call("GET", page)
        check(f"locked: {page} sends you to the YubiKey page", s == 302 and h["Location"] == "/gate?next=" + page, f"{s} {h.get('Location')}")
    for api in ("/api/timeline", "/api/intake/items", "/api/intake/items/1", "/api/intake/items/1/content", "/api/hub", "/api/agents",
                "/api/room/read", "/api/room/tasks", "/api/models", "/api/proved/public", "/api/nothing-here"):
        s, d, _ = site.json("GET", api)
        check(f"locked: GET {api} is refused", s == 401 and d.get("locked") is True, f"{s} {d}")
    for api in ("/api/start", "/api/send", "/api/seal", "/api/room/say", "/api/intake/text", "/api/intake/file", "/api/intake/items/1/archive",
                "/api/agents/start", "/api/proved/public"):
        s, d, _ = site.json("POST", api, {"text": "x", "task": "x"})
        check(f"locked: POST {api} is refused", s == 401 and d.get("locked") is True, f"{s} {d}")
    for page in ("/gate", "/gate.js", "/style.css", "/splash.js"):
        check(f"locked: {page} still loads (the YubiKey page needs it)", site.call("GET", page)[0] == 200)
    s, d, _ = site.json("GET", "/api/gate")
    check("locked: the gate reports one key and gives nothing else away", s == 200 and set(d) == {"keys", "canRegister", "origin"} and d["keys"] == 1)
    check("locked: no challenge is handed out for a write", site.touch("room:say") is None)
    s, d, _ = site.json("GET", "/api/timeline", cookie="hw_session=made-up-value")
    check("a made-up cookie opens nothing", s == 401)

    # ---- opening it
    s, d, _ = site.json("POST", "/api/gate/session", {})
    check("opening without a touch is refused", s == 403, f"{s} {d}")
    s, d, _ = site.json("POST", "/api/gate/session", {"gate": FakeKey().touch(site.json("POST", "/api/gate/challenge", {"purpose": "session"})[1]["challenge"])})
    check("opening with a key that isn't registered is refused", s == 403)
    cookie = site.unlock()
    check("a touch opens it; the cookie is HttpOnly, Secure, SameSite=Strict", all(x in cookie for x in ("HttpOnly", "Secure", "SameSite=Strict", "Max-Age=")))
    check("open: the pages load", all(site.call("GET", p)[0] == 200 for p in ("/", "/room", "/agents", "/hub", "/intake", "/timeline")))
    s, d, _ = site.json("GET", "/api/intake/items")
    check("open: reading works without another touch", s == 200 and "items" in d, f"{s} {d}")

    # ---- writes need their own touch
    s, d, _ = site.json("POST", "/api/intake/text", {"text": "lock test, no touch", "tag": "heimdall-web-test"})
    check("open: storing a note with no touch is refused", s == 403 and "YubiKey" in d.get("error", ""), f"{s} {d}")
    s, d, _ = site.json("POST", "/api/intake/text", {"text": "lock test, wrong touch", "tag": "heimdall-web-test", "gate": site.touch("intake:archive")})
    check("open: a touch made for archiving can't store a note", s == 403)
    s, d, _ = site.json("POST", "/api/room/say", {"text": "lock test, must never be posted"})
    check("open: posting to the Room with no touch is refused", s == 403, f"{s} {d}")
    s, d, _ = site.json("POST", "/api/room/task", {"text": "lock test, must never be posted", "gate": site.touch("room:say")})
    check("open: a touch made for a message can't create a task", s == 403)
    s, d, _ = site.json("POST", "/api/room/claim", {"id": "abcd"})
    check("open: claiming a task with no touch is refused", s == 403)
    s, d, _ = site.json("POST", "/api/proved/public", {"id": None})
    check("open: changing the public page with no touch is refused", s == 403)
    s, d, _ = site.json("POST", "/api/agents/start", {"task": "lock test, must never start"})
    check("open: starting an agent with no touch is refused", s == 403)
    s, d, _ = site.json("POST", "/api/agents/start", {"task": "lock test, bad runner", "runners": ["muse"], "gate": site.touch("agents:start")})
    check("open: an unknown runner is refused before anything starts", s == 400, f"{s} {d}")
    s, d, _ = site.json("POST", "/api/agents/20260101-000000-abcd/handoff", {"who": "grok"})
    check("open: handing off with no touch is refused", s == 403)
    s, raw, _ = site.call("POST", "/api/intake/file", b"x", {"Content-Type": "text/plain", "X-Filename": "lock-test.txt"})
    check("open: storing a file with no touch is refused", s == 403, f"{s} {raw[:120]}")
    s, raw, _ = site.call("POST", "/api/intake/file", b"x", {"Content-Type": "text/plain", "X-Filename": "lock-test.txt",
                                                              "X-Gate": b64u(json.dumps(site.touch("intake:text")).encode())})
    check("open: a touch made for a note can't store a file", s == 403)

    good = site.touch("intake:text")
    s, d, _ = site.json("POST", "/api/intake/text", {"text": "lock test note", "tag": "heimdall-web-test", "gate": good})
    note = d.get("id")
    check("open: with its own touch, the note is stored", s == 200 and bool(note), f"{s} {d}")
    s, d2, _ = site.json("POST", "/api/intake/text", {"text": "lock test replay", "tag": "heimdall-web-test", "gate": good})
    check("open: the same touch can't be used twice", s == 403)
    s, d, _ = site.json("POST", f"/api/intake/items/{note}/archive", {})
    check("open: archiving with no touch is refused", s == 403)
    s, d, _ = site.json("POST", f"/api/intake/items/{note}/archive", {"gate": site.touch("intake:archive")})
    check("open: with its own touch, it is archived", s == 200, f"{s} {d}")

    # ---- other sites, locking again
    s, raw, _ = site.call("POST", "/api/room/say", b'{"text":"x"}', {"Content-Type": "application/json", "Origin": "https://evil.example"})
    check("a request sent from another website is refused, even with the cookie", s == 403 and b"origin" in raw, f"{s} {raw[:80]}")
    s, raw, _ = site.call("POST", "/api/gate/challenge", b'{"purpose":"session"}', {"Origin": ORIGIN})
    check("a request from the real address is not", s == 200)
    old = site.cookie
    s, d, h = site.json("POST", "/api/gate/lock", {})
    check("Lock closes it: the same cookie opens nothing afterwards", s == 200 and site.json("GET", "/api/timeline", cookie=old)[0] == 401)
finally:
    site.close()

short = Site(ttl=1)
try:
    short.unlock()
    ok_now = short.json("GET", "/api/gate")[0] == 200 and short.call("GET", "/timeline")[0] == 200
    time.sleep(1.6)
    check("a session ends by itself when its time is up", ok_now and short.call("GET", "/timeline")[0] == 302)
finally:
    short.close()

print("\nall passed" if not fails else f"\n{len(fails)} FAILED")
sys.exit(1 if fails else 0)
