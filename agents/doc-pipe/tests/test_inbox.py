"""Offline test for the watched inbox: temp folder, fake upload (no network, no DB, no model). Run: .venv/bin/python tests/test_inbox.py"""
import os, sys, tempfile, time
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from app import inbox as ib

fails = []
def check(name, cond):
    print(("ok   " if cond else "FAIL ") + name)
    if not cond: fails.append(name)

d = Path(tempfile.mkdtemp(prefix="inbox-test-"))
old = time.time() - 60
def put(name, data=b"\xff\xd8photo", age_old=True):
    p = d / name; p.write_bytes(data)
    if age_old: os.utime(p, (old, old))
    return p
put("a.jpg", b"A"); put("b.HEIC", b"B"); put("same.jpg", b"A"); put("doc.pdf", b"%PDF"); put("notes.txt", b"x"); put("empty.jpg", b"")
put("bad.jpg", b"C"); put("fresh.jpg", b"F", age_old=False); put(".rsync-tmp.jpg", b"T"); put("x.jpg.part", b"P")
(d / "done").mkdir(); put_done = d / "done" / "a.jpg"; put_done.write_bytes(b"older")   # name clash in done/
sent = []
def fake_upload(files):
    sent.append([n for n, _ in files])
    seen = {}
    out = []
    for n, b in files:
        if n == "bad.jpg": out.append({"filename": n, "ok": False, "error": "not an image I can read"}); continue
        dup = b in seen; seen.setdefault(b, len(seen) + 1)
        out.append({"filename": n, "ok": True, "id": seen[b], "duplicate": dup})
    return out
c = ib.run(d, upload=fake_upload, sleep=lambda s: None)
names = lambda sub: sorted(p.name for p in (d / sub).iterdir())
check("uploads only settled photos, in batches", sum(sent, []) == ["a.jpg", "b.HEIC", "bad.jpg", "same.jpg"] and all(len(x) <= 5 for x in sent))
check("counts", c == {"seen": 7, "done": 3, "duplicates": 1, "failed": 4, "waiting": 0})
check("done/ keeps originals, no overwrite", len([n for n in names("done") if n.endswith("a.jpg")]) == 2 and (d / "done" / "a.jpg").read_bytes() == b"older"
      and "b.HEIC" in names("done") and "same.jpg" in names("done"))
fl = names("failed")
check("failed/ gets the file + a reason", {"doc.pdf", "doc.pdf.reason.txt", "notes.txt", "empty.jpg", "bad.jpg", "bad.jpg.reason.txt"} <= set(fl)
      and "PDF" in (d / "failed" / "doc.pdf.reason.txt").read_text() and "read" in (d / "failed" / "bad.jpg.reason.txt").read_text())
check("half-written / hidden / temp files left alone", {"fresh.jpg", ".rsync-tmp.jpg", "x.jpg.part"} <= {p.name for p in d.iterdir()})
total = sum(1 for p in d.rglob("*") if p.is_file() and not p.name.endswith(".reason.txt") and p.name not in ("inbox.log", ".lock"))
check("nothing deleted (11 files in, 11 files still there)", total == 11)
check("log written", "done a.jpg -> document #1" in (d / "inbox.log").read_text())
# a file that's still growing between the two looks is skipped
g = put("growing.jpg", b"1")
def grow(_): g.write_bytes(b"12"); os.utime(g, (old, old + 1))
check("a file still being written is skipped", ib.ready_files(d, sleep=grow) == [] or g not in ib.ready_files(d, sleep=grow))
# pipe down: files stay for the next run
def down(files): raise ConnectionError("refused")
c2 = ib.run(d, upload=down, sleep=lambda s: None)
check("pipe down -> files stay in the inbox", (d / "growing.jpg").exists() and c2["waiting"] == 1)
# dry run moves nothing
c3 = ib.run(d, upload=fake_upload, dry_run=True, sleep=lambda s: None)
check("dry run moves nothing", (d / "growing.jpg").exists() and c3["done"] == 1)
e = Path(tempfile.mkdtemp(prefix="inbox-empty-"))
check("empty inbox -> nothing to do", ib.run(e, upload=fake_upload, sleep=lambda s: None)["seen"] == 0)
import shutil; shutil.rmtree(d); shutil.rmtree(e)
print("ALL PASS" if not fails else f"{len(fails)} FAILED")
sys.exit(1 if fails else 0)
