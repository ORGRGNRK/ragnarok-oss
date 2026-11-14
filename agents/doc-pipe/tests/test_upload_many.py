"""Offline test for /api/upload and /api/upload-many: no Postgres, no model, no .env.
The database is an in-memory fake and the model step is stubbed, so nothing real is written.
Run: .venv/bin/python tests/test_upload_many.py"""
import io, os, sys, tempfile
from pathlib import Path

tmp = tempfile.mkdtemp(prefix="pipe-test-")
os.environ.update(DATABASE_URL="postgresql://fake", PIPE_WEB_USER="tester", PIPE_WEB_PASSWORD="test-only-pw",
                  PIPE_IMAGE_DIR=tmp)
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from PIL import Image
from fastapi.testclient import TestClient
import app.main as m

docs, logs, processed = {}, [], []


class Cur:
    def __init__(self): self.r = None
    def __enter__(self): return self
    def __exit__(self, *a): return False
    def execute(self, sql, args=()):
        if sql.startswith("SELECT id FROM documents WHERE sha256"):
            ids = [i for i, d in docs.items() if d["sha"] == args[0]]
            self.r = (min(ids),) if ids else None
        elif sql.startswith("INSERT INTO documents"):
            i = len(docs) + 1; docs[i] = {"filename": args[0], "sha": args[1], "path": args[2]}; self.r = (i,)
        elif sql.startswith("INSERT INTO processing_log"):
            logs.append(args)
        else:
            raise AssertionError("unexpected SQL: " + sql)
    def fetchone(self): return self.r


class Conn:
    def __enter__(self): return self
    def __exit__(self, *a): return False
    def cursor(self): return Cur()


m.db = lambda: Conn()
m.process = lambda i: processed.append(i)   # model stubbed: just note which ids were queued


def img(color, fmt="JPEG"):
    b = io.BytesIO(); Image.new("RGB", (8, 8), color).save(b, fmt); return b.getvalue()


c = TestClient(m.app)
auth = ("tester", "test-only-pw")
fails = []
def check(name, cond):
    print(("ok   " if cond else "FAIL ") + name)
    if not cond: fails.append(name)

check("no login -> 401 on upload-many", c.post("/api/upload-many", files=[("files", ("a.jpg", img("red")))]).status_code == 401)
check("wrong login -> 401", c.post("/api/upload-many", auth=("tester", "nope"), files=[("files", ("a.jpg", img("red")))]).status_code == 401)
check("no login -> 401 on page", c.get("/").status_code == 401)
r = c.post("/api/upload-many", auth=auth, files=[
    ("files", ("red.jpg", img("red"))), ("files", ("blue.png", img("blue", "PNG"), "image/png")),
    ("files", ("again.jpg", img("red"))), ("files", ("notes.txt", b"hello", "text/plain")),
    ("files", ("empty.jpg", b""))])
j = r.json(); res = j["results"]
check("batch -> 200", r.status_code == 200)
check("5 per-file results in order", [x["filename"] for x in res] == ["red.jpg", "blue.png", "again.jpg", "notes.txt", "empty.jpg"])
check("two new photos stored", res[0]["ok"] and res[1]["ok"] and not res[0]["duplicate"] and res[0]["id"] != res[1]["id"] and j["stored"] == 2)
check("same photo twice -> duplicate of the first", res[2]["ok"] and res[2]["duplicate"] and res[2]["id"] == res[0]["id"] and j["duplicates"] == 1)
check("wrong type refused, rest kept", not res[3]["ok"] and ".txt" in res[3]["error"])
check("empty file refused", not res[4]["ok"] and res[4]["error"] == "empty file" and j["failed"] == 2)
check("both new photos queued for the model, once each", processed == [res[0]["id"], res[1]["id"]])
check("images saved 0600", all(oct(os.stat(d["path"]).st_mode & 0o777) == "0o600" for d in docs.values()))
check("every stored/duplicate photo logged", len(logs) == 3)
processed.clear()
r1 = c.post("/api/upload", auth=auth, files={"file": ("green.jpg", img("green"))})
check("single upload still works", r1.status_code == 200 and r1.json() == {"id": 3, "duplicate": False} and processed == [3])
check("single upload: bad type -> 415", c.post("/api/upload", auth=auth, files={"file": ("x.txt", b"hi")}).status_code == 415)
check("too many files -> 413", c.post("/api/upload-many", auth=auth, files=[("files", (f"{i}.jpg", img((i, 0, 0)))) for i in range(m.MAX_FILES + 1)]).status_code == 413)
page = c.get("/", auth=auth).text
check("page has a multi-select photo picker", 'id="pick" type="file" accept="image/*" multiple' in page and "api/upload-many" in page)
check("page has an Edit button", 'id="editbtn"' in page and "Save changes" in page)
for f in Path(tmp).iterdir(): f.unlink()
os.rmdir(tmp)
print("ALL PASS" if not fails else f"{len(fails)} FAILED")
sys.exit(1 if fails else 0)
