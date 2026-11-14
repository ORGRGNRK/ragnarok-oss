#!/usr/bin/env python3
"""Live check of the Intake tab's server routes:  python3 tests/intake-test.py   (on Alexus; needs `cryptography`)

Starts a private Heimdall Web with a software key (tests/live.py), which talks to the real Intake. It stores a note, a tiny PNG and an HTML file
(all tagged heimdall-web-test), reads them back, and archives them again. Standard library only.
"""
import base64, json, sys, urllib.parse

from live import Site, b64u

site = Site()
site.unlock()
TAG = "heimdall-web-test"
PNG = base64.b64decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")
fails, made = [], []


def call(method, path, body=None, headers=None):
    return site.call(method, path, body, headers)


def touched(purpose, obj=None):
    """A JSON body carrying a fresh touch for this write."""
    return json.dumps(dict(obj or {}, gate=site.touch(purpose))).encode()


def check(name, ok, extra=""):
    print(("ok   " if ok else "FAIL ") + name + (f"  [{extra}]" if extra and not ok else ""))
    if not ok:
        fails.append(name)


def upload(name, data, mime):
    s, raw, _ = call("POST", "/api/intake/file", data, {"Content-Type": mime, "X-Filename": urllib.parse.quote(name, safe=""),
                                                         "X-Tags": TAG, "X-Gate": b64u(json.dumps(site.touch("intake:file")).encode())})
    d = json.loads(raw or b"{}")
    if s == 200 and d.get("id"):
        made.append(d["id"])
    return s, d


try:
    s, raw, _ = call("GET", "/intake")
    check("the page loads and never contains the token route", s == 200 and b"Authorization" not in raw)
    s, raw, _ = call("GET", "/api/intake/items")
    d = json.loads(raw)
    check("the list and the disk line come back", s == 200 and isinstance(d.get("items"), list) and d["disk"]["free_bytes"] > 0, raw[:200])

    s, raw, _ = call("POST", "/api/intake/text", touched("intake:text", {"text": "heimdall-web intake check note ✓", "tag": TAG}),
                     {"Content-Type": "application/json"})
    d = json.loads(raw)
    note = d.get("id")
    made.append(note) if note else None
    check("a note is stored", s == 200 and bool(note), raw[:200])
    s, raw, _ = call("GET", f"/api/intake/items/{note}")
    check("the note reads back with its text", s == 200 and "check note ✓" in json.loads(raw).get("body", ""), raw[:200])
    s, raw, _ = call("POST", "/api/intake/text", touched("intake:text", {"text": "   "}), {"Content-Type": "application/json"})
    check("an empty note is refused", s == 400)

    s, d = upload("héllo ünïcode ✓.png", PNG, "image/png")
    png = d.get("id")
    check("a picture with a non-English name is stored", s == 200 and d.get("name") == "héllo ünïcode ✓.png", str(d))
    s, raw, _ = call("GET", f"/api/intake/items/{png}")
    it = json.loads(raw)
    check("its name, kind and size survive", it.get("original_filename") == "héllo ünïcode ✓.png" and it.get("kind") == "photo"
          and int(it.get("size")) == len(PNG), raw[:300])
    s, raw, h = call("GET", f"/api/intake/items/{png}/content")
    check("the picture comes back byte for byte, shown as a picture", s == 200 and raw == PNG and h["Content-Type"] == "image/png"
          and h["Content-Disposition"].startswith("inline") and h["X-Content-Type-Options"] == "nosniff")
    s, raw, h = call("GET", f"/api/intake/items/{png}/content?download")
    check("Download sends it as a file", s == 200 and raw == PNG and h["Content-Disposition"].startswith("attachment"))

    page = b"<html><script>document.title='ran'</script></html>"
    s, d = upload("page.html", page, "text/html")
    html = d.get("id")
    s, raw, h = call("GET", f"/api/intake/items/{html}/content")
    check("a stored web page is only ever a download, never shown", s == 200 and raw == page and h["Content-Type"] == "application/octet-stream"
          and h["Content-Disposition"].startswith("attachment") and "sandbox" in h["Content-Security-Policy"])
    s, d = upload("fake.svg", b"<svg xmlns='http://www.w3.org/2000/svg'><script>1</script></svg>", "image/svg+xml")
    s, raw, h = call("GET", f"/api/intake/items/{d.get('id')}/content")
    check("an SVG (which can carry script) is a download too", s == 200 and h["Content-Type"] == "application/octet-stream")

    for bad in ("../etc/passwd", "a/b.txt", "..", "bad\nname.txt", ""):
        s, d = upload(bad, b"x", "text/plain")
        check(f"filename {bad!r} is refused", s == 400, str(d))
    s, raw, _ = call("GET", "/api/intake/items/abc")
    check("a non-numeric item id is refused", s == 400)
    s, raw, _ = call("GET", "/api/intake/items/999999999")
    check("an item that does not exist says so", s == 502 and b"error" in raw, raw[:200])

    s, raw, _ = call("GET", "/api/intake/items?" + urllib.parse.urlencode({"tag": TAG, "kind": "photo"}))
    got = [i["id"] for i in json.loads(raw)["items"]]
    check("searching by tag and kind finds the picture and not the note", png in got and note not in got, str(got))
finally:
    for iid in made:
        s, raw, _ = call("POST", f"/api/intake/items/{iid}/archive", touched("intake:archive"), {"Content-Type": "application/json"})
        if s != 200:
            check(f"archive {iid}", False, raw[:200].decode("utf-8", "replace"))
    s, raw, _ = call("GET", "/api/intake/items?" + urllib.parse.urlencode({"tag": TAG}))
    left = json.loads(raw).get("items", [None])
    check(f"all {len(made)} test items are archived and gone from the list", left == [], str(left)[:200])
    site.close()
print("\nall passed" if not fails else f"\n{len(fails)} FAILED")
sys.exit(1 if fails else 0)
