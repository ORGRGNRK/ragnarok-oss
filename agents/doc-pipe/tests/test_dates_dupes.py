"""Offline tests: date picking, likely-duplicate flags, the new endpoints and the processing step.
No Postgres (in-memory fake), no model (call_model stubbed), no .env. Run: .venv/bin/python tests/test_dates_dupes.py"""
import io, json, os, sys, tempfile
from datetime import date
from decimal import Decimal
from pathlib import Path

tmp = tempfile.mkdtemp(prefix="pipe-test-")
os.environ.update(DATABASE_URL="postgresql://fake", PIPE_WEB_USER="tester", PIPE_WEB_PASSWORD="test-only-pw", PIPE_IMAGE_DIR=tmp)
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from PIL import Image
from fastapi.testclient import TestClient
import app.main as m
from app import checks

fails = []
def check(name, cond):
    print(("ok   " if cond else "FAIL ") + name)
    if not cond: fails.append(name)

T = date(2026, 11, 1)
promo = """TARGET
Store 1234
10/28/2026 14:32 REG 3 TRAN 5521
MILK 3.49
TOTAL 3.49
VISA ****1111 AUTH 99812
Take our survey! Enter by 9/15
Offer valid through 12/31/2026
Returns before 01/27/2027"""
# 1) date picking
d, p, info = checks.check_date(date(2026, 10, 28), promo, T)
check("right date kept, no problem", d == date(2026, 10, 28) and p == [])
d, p, _ = checks.check_date(date(2026, 9, 15), promo, T)
check("promo 9/15 replaced by the transaction-line date and flagged", d == date(2026, 10, 28) and p and "promo" in p[0])
d, p, _ = checks.check_date(date(2026, 12, 31), promo, T)
check("future 'valid through' date replaced and flagged", d == date(2026, 10, 28) and p and "future" in p[0])
d, p, _ = checks.check_date(None, promo, T)
check("missing date filled from the transaction line", d == date(2026, 10, 28) and p == [])
only_promo = "SHOP\nMILK 3.49\nTOTAL 3.49\nCoupon expires 9/15/2026"
d, p, _ = checks.check_date(date(2026, 9, 15), only_promo, T)
check("only a promo date on it -> kept but flagged for review", d == date(2026, 9, 15) and p and "promo" in p[0])
label_above = "CAFE\nOffer ends:\n09/15/2026\nDate:\n10/20/2026\nTOTAL 5.00"
d, p, _ = checks.check_date(date(2026, 9, 15), label_above, T)
check("label on the line above counts (Offer ends: / Date:)", d == date(2026, 10, 20) and p)
d, p, _ = checks.check_date(date(2026, 10, 5), "SHOP 10/20/2026 09:12\nTOTAL 1.00", T)
check("model date not printed but a transaction date is -> flagged, not changed", d == date(2026, 10, 5) and p and "isn't printed" in p[0])
check("prices and times aren't dates", checks.candidates("TOTAL 9.15\n10:15 AM\n$9/15 off") == [])
check("Oct 28, 2026 and 2026-10-28 read", [c["date"] for c in checks.candidates("Oct 28, 2026 2:15 PM\nDate 2026-10-28")] == [date(2026, 10, 28)] * 2)

# 2) duplicates
A = {"id": 1, "status": "ok", "vendor": "TARGET #1234", "total": Decimal("23.10"), "doc_date": date(2026, 10, 28), "raw_text": "", "extracted_json": {}}
B = dict(A, id=2, vendor="Target", doc_date=date(2026, 10, 29))
C = dict(A, id=3, vendor="Walmart")
D = dict(A, id=4, total=Decimal("23.11"))
E = dict(A, id=5, extracted_json={"card_last4": "2222"}); A2 = dict(A, extracted_json={"card_last4": "1111"})
F = dict(A, id=6, doc_date=date(2026, 11, 20))
check("same total, similar vendor, 1 day apart -> duplicate", checks.why_duplicate(A, B) is not None)
check("different shop / total / far date / card -> not", checks.why_duplicate(A, C) is None and checks.why_duplicate(A, D) is None
      and checks.why_duplicate(A2, E) is None and checks.why_duplicate(A, F) is None)
check("same transaction number -> duplicate", "transaction" in (checks.why_duplicate(dict(C, extracted_json={"transaction_id": "TC 5521 0012"}), dict(D, extracted_json={"transaction_id": "TC55210012"})) or ""))
same_time_diff = checks.why_duplicate(dict(A, extracted_json={"transaction_time": "14:32"}), dict(A, id=9, extracted_json={"transaction_time": "18:05"}))
check("same shop, total, day but another time -> not", same_time_diff is None)
fl = checks.flags([A, B, C], [], T)
check("flag goes on the later one", fl[2]["possible_duplicate_of"] == 1 and fl[1]["possible_duplicate_of"] is None)
fl = checks.flags([A, B, C], [(2, "dup_dismiss", {"of": 1})], T)
check("'not a duplicate' hides it", fl[2]["possible_duplicate_of"] is None)
fl = checks.flags([A, B], [(2, "dup_mark", {"of": 1})], T)
check("marked duplicate", fl[2]["marked_duplicate_of"] == 1 and fl[2]["possible_duplicate_of"] is None)
fl = checks.flags([A, B], [(2, "dup_mark", {"of": 1}), (2, "dup_unmark", {})], T)
check("undo mark brings the flag back", fl[2]["marked_duplicate_of"] is None and fl[2]["possible_duplicate_of"] == 1)
same_day = [dict(A, id=i, vendor=v, total=Decimal(i), doc_date=date(2026, 9, 15)) for i, v in ((1, "Shell"), (2, "CVS"), (3, "Target"))]
fl = checks.flags(same_day, [], T)
check("3 shops sharing one date -> check-date flag on each", all(any("3 receipts" in x for x in fl[i]["date_flags"]) for i in (1, 2, 3)))
fl = checks.flags(same_day, [(2, "date_ok", {"date": "2026-09-15"})], T)
check("'the date is right' hides it", fl[2]["date_flags"] == [] and fl[1]["date_flags"])

# 3) endpoints with a fake database
docs, logs = {}, []
COLS = {"list": ["id", "uploaded_at", "filename", "status", "doc_type", "vendor", "doc_date", "total", "currency", "latency_ms"]}
class Cur:
    def __init__(self): self.r = []; self.description = None
    def __enter__(self): return self
    def __exit__(self, *a): return False
    def execute(self, sql, args=()):
        sql = " ".join(sql.split()); self.description = None
        if sql.startswith("SELECT id, status, vendor, total, doc_date, raw_text, extracted_json FROM documents"):
            self.r = [(d["id"], d["status"], d["vendor"], d["total"], d["doc_date"], d["raw_text"], d["extracted_json"]) for d in docs.values()]
        elif sql.startswith("SELECT document_id, step, detail FROM processing_log"):
            self.r = [(l["doc"], l["step"], l["detail"]) for l in logs if l["step"] in args[0]]
        elif sql.startswith("SELECT id, uploaded_at"):
            self.description = [type("C", (), {"name": c}) for c in COLS["list"]]
            self.r = [(d["id"], None, d.get("filename"), d["status"], None, d["vendor"], d["doc_date"], d["total"], "USD", None) for d in sorted(docs.values(), key=lambda d: -d["id"])]
        elif sql.startswith("SELECT id FROM documents WHERE id = ANY"):
            self.r = [(i,) for i in args[0] if i in docs]
        elif sql.startswith("SELECT doc_date FROM documents"):
            self.r = [(docs[args[0]]["doc_date"],)] if args[0] in docs else []
        elif sql.startswith("SELECT id FROM documents WHERE sha256"):
            self.r = [(i,) for i, d in docs.items() if d.get("sha") == args[0]][:1]
        elif sql.startswith("INSERT INTO documents"):
            i = max(docs, default=0) + 1
            docs[i] = {"id": i, "filename": args[0], "sha": args[1], "path": args[2], "status": "processing", "vendor": None,
                       "total": None, "doc_date": None, "raw_text": "", "extracted_json": {}}; self.r = [(i,)]
        elif sql.startswith("SELECT image_path FROM documents"):
            self.r = [(docs[args[0]]["path"],)]
        elif sql.startswith("INSERT INTO processing_log"):
            logs.append({"actor": args[0], "doc": args[1], "step": args[2], "result": args[5], "detail": args[6].obj if args[6] is not None else None})
        elif sql.startswith("SELECT id, doc_date, vendor, doc_type"):
            self.r = [(d["id"], d["doc_date"], d["vendor"], None, None, None, d["total"], "USD", d["status"]) for d in sorted(docs.values(), key=lambda d: d["id"]) if d["status"] != "failed"]
        elif sql.startswith("UPDATE documents SET status=%s, doc_type"):
            d = docs[args[-1]]; d.update(status=args[0], vendor=args[2], doc_date=args[3], total=args[6], raw_text=args[9])
        elif sql.startswith("UPDATE documents SET model") or sql.startswith("DELETE FROM line_items") or sql.startswith("INSERT INTO line_items"):
            pass
        else:
            raise AssertionError("unexpected SQL: " + sql[:80])
    def fetchone(self): return self.r[0] if self.r else None
    def fetchall(self): return self.r
class Conn:
    def __enter__(self): return self
    def __exit__(self, *a): return False
    def cursor(self): return Cur()
m.db = lambda: Conn()
queued = []
real_process = m.process
m.process = lambda i: queued.append(i)

def img(color):
    b = io.BytesIO(); Image.new("RGB", (8, 8), color).save(b, "JPEG"); return b.getvalue()
c = TestClient(m.app); auth = ("tester", "test-only-pw")
for route in ("/api/upload-raw", "/api/documents/1/duplicate", "/api/documents/1/date-ok"):
    check(f"no login -> 401 on {route}", c.post(route, content=b"x").status_code == 401)
check("no login -> 401 on export", c.get("/api/export.csv").status_code == 401)
r = c.post("/api/upload-raw", auth=auth, content=img("red"), headers={"Content-Type": "image/jpeg"})
check("raw body upload stored + queued", r.status_code == 200 and r.json()["ok"] and r.json()["filename"] == "photo.jpg" and queued == [1])
r2 = c.post("/api/upload-raw?filename=IMG_0001.HEIC", auth=auth, content=img("red"), headers={"Content-Type": "image/heic"})
check("same photo again -> duplicate, not queued", r2.json()["duplicate"] and r2.json()["id"] == 1 and queued == [1])
check("raw: wrong type -> 415", c.post("/api/upload-raw?filename=a.txt", auth=auth, content=b"hi").status_code == 415)
check("raw: empty -> 400", c.post("/api/upload-raw", auth=auth, content=b"", headers={"Content-Type": "image/jpeg"}).status_code == 400)
# two receipts of the same purchase + one other
docs.clear(); logs.clear()
for i, v, t, dd in ((1, "Target", "23.10", date(2026, 10, 28)), (2, "TARGET 1234", "23.10", date(2026, 10, 28)), (3, "CVS", "5.00", date(2026, 10, 2))):
    docs[i] = {"id": i, "status": "ok", "vendor": v, "total": Decimal(t), "doc_date": dd, "raw_text": "", "extracted_json": {}, "path": "x"}
L = c.get("/api/documents", auth=auth).json()
row2 = next(x for x in L if x["id"] == 2)
check("list shows 'possible duplicate of #1'", row2["possible_duplicate_of"] == 1 and "same total" in row2["duplicate_reason"])
check("bad action refused", c.post("/api/documents/2/duplicate", auth=auth, json={"action": "delete", "of": 1}).status_code == 400)
check("unknown receipt -> 404", c.post("/api/documents/2/duplicate", auth=auth, json={"action": "mark", "of": 77}).status_code == 404)
r = c.post("/api/documents/2/duplicate", auth=auth, json={"action": "mark", "of": 1}).json()
check("mark as duplicate", r["marked_duplicate_of"] == 1 and logs[-1]["step"] == "dup_mark" and logs[-1]["actor"] == "tester")
csv_text = c.get("/api/export.csv", auth=auth).text
check("export leaves the marked duplicate out", "\n2," not in csv_text and "\n1," in csv_text and "\n3," in csv_text)
c.post("/api/documents/2/duplicate", auth=auth, json={"action": "unmark"})
r = c.post("/api/documents/2/duplicate", auth=auth, json={"action": "dismiss", "of": 1}).json()
check("not a duplicate -> flag gone, receipt kept", r["possible_duplicate_of"] is None and r["marked_duplicate_of"] is None and 2 in docs)
r = c.post("/api/documents/3/date-ok", auth=auth).json()
check("date-ok logs the current date", r["date"] == "2026-10-02" and logs[-1]["step"] == "date_ok")
check("nothing was ever deleted", len(docs) == 3)
# 4) processing with the model stubbed: a promo 9/15 date gets replaced and the receipt goes to review
m.process = real_process
pth = Path(tmp) / "r.jpg"; pth.write_bytes(img("white"))
docs[4] = {"id": 4, "status": "processing", "vendor": None, "total": None, "doc_date": None, "raw_text": "", "extracted_json": {}, "path": str(pth)}
reply = {"raw_text": promo, "document_type": "receipt", "vendor": "Target", "date": "2026-09-15", "currency": "USD", "language": "en",
         "line_items": [{"description": "MILK", "qty": 1, "unit_price": 3.49, "amount": 3.49}], "subtotal": 3.49, "tax": None, "total": 3.49,
         "model_confidence": 0.95, "notes": None, "transaction_time": "14:32", "card_last4": "1111", "transaction_id": "5521"}
m.extract.call_model = lambda b64, attempt=1: (json.dumps(reply), 5, {})
m.process(4)
check("processing: date fixed to the transaction date", docs[4]["doc_date"] == date(2026, 10, 28))
check("processing: sent to needs review", docs[4]["status"] == "needs_review")
check("processing: date_check logged", any(l["step"] == "date_check" and l["doc"] == 4 and not l["detail"].get("problems") == [] for l in logs))
reply.update(date="2026-10-28"); docs[4]["status"] = "processing"; m.process(4)
check("processing: correct date -> ok", docs[4]["status"] == "ok" and docs[4]["doc_date"] == date(2026, 10, 28))
check("prompt warns about promo dates", "valid through" in m.extract.PROMPT and "transaction_id" in m.extract.SCHEMA["required"])
branham = "Inv.DATE: 6 - 10 - 88 AMOUNT 1,318.85 DATE PAID 6-17-88 CHECK 008495"
cs = checks.candidates(branham)
check("invoice: spaced 2-digit date is 1988, not 2088", [x["date"] for x in cs] == [date(1988, 6, 10), date(1988, 6, 17)])
check("invoice: date paid is not the invoice date", [x["good"] for x in cs] == [True, False])
check("invoice: date filled from the invoice line", checks.check_date(None, branham, T)[0] == date(1988, 6, 10))
check("receipt: 2-digit year stays this century", checks.candidates("10/28/26 14:32 REG 3")[0]["date"] == date(2026, 10, 28))
inv = dict(raw_text="x", document_type="invoice", vendor="Branham", date="1988-06-10", currency="USD", language="en", model_confidence=0.9,
           invoice_number="E800896", subtotal=1583.25, discount=237.49, tax=None, total=1345.76,
           line_items=[dict(description="ad", qty=63, unit_price=22.75, amount=1433.25), dict(description="color", qty=1, unit_price=150, amount=150)])
check("invoice: subtotal - discount = net passes", m.extract.validate(inv)[1] == [])
check("invoice: negative discount handled", m.extract.validate({**inv, "discount": -237.49})[1] == [])
check("invoice: wrong net is flagged", any("discount" in p for p in m.extract.validate({**inv, "total": 1318.85})[1]))
check("invoice: missing number is flagged", "no invoice number found" in m.extract.validate({**inv, "invoice_number": None})[1])
check("invoice: prompt says printed money only", "Ignore handwriting" in m.extract.PROMPT and "invoice_number" in m.extract.SCHEMA["required"])
page = c.get("/", auth=auth).text
check("page has the duplicate/date buttons and totals", all(x in page for x in ("Not a duplicate", "Yes, it's a duplicate", "The date is right", "possible duplicate of", "api/export.csv", "check date")))
for f in Path(tmp).iterdir(): f.unlink()
os.rmdir(tmp)
print("ALL PASS" if not fails else f"{len(fails)} FAILED")
sys.exit(1 if fails else 0)
