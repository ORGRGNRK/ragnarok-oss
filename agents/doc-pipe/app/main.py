"""Ragnarok pipe: photo of a document -> local Qwen vision -> Postgres."""
import hashlib
import json
import os
import secrets
import threading
import time
from datetime import date
from pathlib import Path

import psycopg
from psycopg.types.json import Jsonb
from fastapi import BackgroundTasks, Depends, FastAPI, HTTPException, Request, UploadFile
from fastapi.responses import FileResponse, HTMLResponse, Response
from fastapi.security import HTTPBasic, HTTPBasicCredentials

from . import checks, extract

DB_URL = os.environ["DATABASE_URL"]
IMAGE_DIR = Path(os.environ.get("PIPE_IMAGE_DIR", "/opt/ragnarok-pipe/data/images"))
WEB_USER = os.environ["PIPE_WEB_USER"]
WEB_PASSWORD = os.environ["PIPE_WEB_PASSWORD"]
MAX_UPLOAD = 25 * 1024 * 1024
ALLOWED = {".jpg", ".jpeg", ".png", ".webp", ".heic", ".heif", ".gif", ".bmp", ".tif", ".tiff"}

IMAGE_DIR.mkdir(parents=True, exist_ok=True, mode=0o700)
app = FastAPI(title="Ragnarok pipe", docs_url=None, redoc_url=None, openapi_url=None)
security = HTTPBasic(realm="ragnarok-pipe")
model_lock = threading.Lock()  # CPU only: one photo at a time


def auth(request: Request, creds: HTTPBasicCredentials = Depends(security)) -> str:
    ok_u = secrets.compare_digest(creds.username.encode(), WEB_USER.encode())
    ok_p = secrets.compare_digest(creds.password.encode(), WEB_PASSWORD.encode())
    if not (ok_u and ok_p):
        raise HTTPException(401, "bad login", headers={"WWW-Authenticate": 'Basic realm="ragnarok-pipe"'})
    ts = request.headers.get("Tailscale-User-Login")
    return f"{creds.username} via {ts}" if ts else creds.username


def db():
    return psycopg.connect(DB_URL, autocommit=False)


def log(cur, actor, step, ok, result, document_id=None, model=None, detail=None):
    cur.execute(
        "INSERT INTO processing_log(actor, document_id, step, model, ok, result, detail) "
        "VALUES (%s,%s,%s,%s,%s,%s,%s)",
        (actor, document_id, step, model, ok, result, Jsonb(extract.jsonable(detail)) if detail is not None else None))


def save_fields(cur, doc_id, f, status, errors, raw_json=None, latency=None, reviewer=None):
    cur.execute(
        """UPDATE documents SET status=%s, doc_type=%s, vendor=%s, doc_date=%s, subtotal=%s, tax=%s,
               total=%s, currency=%s, language=%s, raw_text=%s, model_confidence=%s, errors=%s,
               extracted_json=COALESCE(%s, extracted_json), latency_ms=COALESCE(%s, latency_ms),
               reviewed_by=COALESCE(%s, reviewed_by),
               reviewed_at=CASE WHEN %s::text IS NULL THEN reviewed_at ELSE now() END,
               updated_at=now()
           WHERE id=%s""",
        (status, f["document_type"], f["vendor"], f["doc_date"], f["subtotal"], f["tax"], f["total"],
         f["currency"], f["language"], f["raw_text"], f["model_confidence"], Jsonb(errors),
         Jsonb(raw_json) if raw_json is not None else None, latency, reviewer, reviewer, doc_id))
    cur.execute("DELETE FROM line_items WHERE document_id=%s", (doc_id,))
    for i, it in enumerate(f["line_items"], 1):
        cur.execute("INSERT INTO line_items(document_id, position, description, qty, unit_price, amount) "
                    "VALUES (%s,%s,%s,%s,%s,%s)",
                    (doc_id, i, it["description"], it["qty"], it["unit_price"], it["amount"]))


def process(doc_id: int):
    """Background job: run the model on the stored image and save the result."""
    with db() as conn, conn.cursor() as cur:
        cur.execute("SELECT image_path FROM documents WHERE id=%s", (doc_id,))
        path = cur.fetchone()[0]
    model = extract.MODEL
    try:
        b64, info = extract.prepare_image(Path(path).read_bytes())
        with db() as conn, conn.cursor() as cur:
            log(cur, "pipeline", "prepare_image", True, "resized", doc_id, None, info)
        with model_lock:
            t0 = time.monotonic()
            data, reply, attempts = None, None, []
            for attempt in (1, 2):  # retry once on bad JSON
                reply, ms, stats = extract.call_model(b64, attempt)
                try:
                    data = extract.parse_json(reply)
                    attempts.append({"attempt": attempt, "ms": ms, "ok": True, **stats})
                    break
                except Exception as e:
                    attempts.append({"attempt": attempt, "ms": ms, "ok": False, "error": str(e),
                                     "reply_head": reply[:300]})
            total_ms = int((time.monotonic() - t0) * 1000)
        with db() as conn, conn.cursor() as cur:
            for a in attempts:
                log(cur, "pipeline", "model_call", a["ok"], f"attempt {a['attempt']} {a['ms']} ms",
                    doc_id, model, a)
            if data is None:
                errs = ["model did not return valid JSON after 2 attempts"]
                cur.execute("UPDATE documents SET status='needs_review', errors=%s, model=%s, latency_ms=%s, "
                            "extracted_json=%s, updated_at=now() WHERE id=%s",
                            (Jsonb(errs), model, total_ms, Jsonb({"unparsed_reply": reply}), doc_id))
                log(cur, "pipeline", "validate", False, "bad JSON", doc_id, model, {"errors": errs})
                return
            fields, problems = extract.validate(data)
            picked, dprob, dinfo = checks.check_date(fields["doc_date"], fields["raw_text"], date.today())
            if picked and not fields["doc_date"]:
                problems = [p for p in problems if p != "no date found"]
            fields["doc_date"] = picked
            problems += dprob
            log(cur, "pipeline", "date_check", not dprob, f"date {picked}" + (f", {len(dprob)} problem(s)" if dprob else ""),
                doc_id, None, {**dinfo, "problems": dprob})
            if len(attempts) > 1:  # first answer was broken JSON: this photo is hard for the model
                problems.append("model needed a retry (first answer was not valid JSON); double-check everything")
            status = "needs_review" if problems else "ok"
            log(cur, "pipeline", "validate", not problems, status, doc_id, model, {"problems": problems})
            cur.execute("UPDATE documents SET model=%s WHERE id=%s", (model, doc_id))
            save_fields(cur, doc_id, fields, status, problems, raw_json=data, latency=total_ms)
            log(cur, "pipeline", "store", True, f"status={status}, {len(fields['line_items'])} line items",
                doc_id, model, {"latency_ms": total_ms})
    except Exception as e:  # model down, DB down, unreadable image...
        with db() as conn, conn.cursor() as cur:
            cur.execute("UPDATE documents SET status='failed', errors=%s, updated_at=now() WHERE id=%s",
                        (Jsonb([f"{type(e).__name__}: {e}"]), doc_id))
            log(cur, "pipeline", "error", False, f"{type(e).__name__}: {e}"[:500], doc_id, model)


@app.on_event("startup")
def resume_stuck():
    for _ in range(30):  # wait for Postgres after a reboot
        try:
            with db() as conn, conn.cursor() as cur:
                cur.execute("SELECT id FROM documents WHERE status='processing' ORDER BY id")
                ids = [r[0] for r in cur.fetchall()]
            break
        except psycopg.OperationalError:
            time.sleep(2)
    else:
        return
    for i in ids:
        threading.Thread(target=process, args=(i,), daemon=True).start()


@app.get("/healthz")
def healthz():
    with db() as conn, conn.cursor() as cur:
        cur.execute("SELECT 1")
    return {"ok": True, "model": extract.MODEL}


MAX_FILES = 50  # per request on /api/upload-many


class UploadProblem(Exception):
    def __init__(self, status: int, text: str):
        super().__init__(text)
        self.status, self.text = status, text


async def store_upload(file: UploadFile, who: str) -> dict:
    """Check and store one photo. Returns {"id", "duplicate"}; a new photo also gets "new": True so the
    caller queues it for the model. Raises UploadProblem for a file that can't be taken."""
    return store_bytes(await file.read(MAX_UPLOAD + 1), file.filename, who)


def store_bytes(data: bytes, filename: str | None, who: str) -> dict:
    """Same as store_upload, for bytes already in hand (raw-body uploads)."""
    class _F:  # keeps the code below identical for both callers
        pass
    file = _F(); file.filename = filename
    if len(data) > MAX_UPLOAD:
        raise UploadProblem(413, "file too big (25 MB max)")
    if not data:
        raise UploadProblem(400, "empty file")
    ext = Path(file.filename or "photo.jpg").suffix.lower() or ".jpg"
    if ext not in ALLOWED:
        raise UploadProblem(415, f"not an image type I accept: {ext}")
    sha = hashlib.sha256(data).hexdigest()
    with db() as conn, conn.cursor() as cur:
        cur.execute("SELECT id FROM documents WHERE sha256=%s ORDER BY id LIMIT 1", (sha,))
        dup = cur.fetchone()
        if dup:
            log(cur, who, "upload", True, f"duplicate of document {dup[0]}", dup[0], None,
                {"filename": file.filename, "sha256": sha})
            return {"id": dup[0], "duplicate": True}
    path = IMAGE_DIR / f"{sha}{ext}"
    path.write_bytes(data)
    os.chmod(path, 0o600)
    with db() as conn, conn.cursor() as cur:
        cur.execute("INSERT INTO documents(filename, sha256, image_path, uploaded_by, model) "
                    "VALUES (%s,%s,%s,%s,%s) RETURNING id",
                    (file.filename, sha, str(path), who, extract.MODEL))
        doc_id = cur.fetchone()[0]
        log(cur, who, "upload", True, "stored", doc_id, None,
            {"filename": file.filename, "bytes": len(data), "sha256": sha})
    return {"id": doc_id, "duplicate": False, "new": True}


def process_many(ids: list[int]):
    """Background job for a batch: the model reads the photos one after another."""
    for i in ids:
        process(i)


@app.post("/api/upload")
async def upload(file: UploadFile, bg: BackgroundTasks, who: str = Depends(auth)):
    try:
        r = await store_upload(file, who)
    except UploadProblem as e:
        raise HTTPException(e.status, e.text)
    if r.pop("new", False):
        bg.add_task(process, r["id"])
    return r


@app.post("/api/upload-many")
async def upload_many(files: list[UploadFile], bg: BackgroundTasks, who: str = Depends(auth)):
    """Several photos at once (form field "files", repeated). Each is handled like /api/upload; one bad file
    doesn't stop the rest. Returns {"results": [{"filename", "ok", "id", "duplicate", "error"}, ...],
    "stored", "duplicates", "failed"}."""
    if len(files) > MAX_FILES:
        raise HTTPException(413, f"too many photos at once ({len(files)}); {MAX_FILES} max per batch")
    results, queued = [], []
    for f in files:
        item = {"filename": f.filename, "ok": False, "id": None, "duplicate": False, "error": None}
        try:
            r = await store_upload(f, who)
            item.update(ok=True, id=r["id"], duplicate=r["duplicate"])
            if r.get("new"):
                queued.append(r["id"])
        except UploadProblem as e:
            item["error"] = e.text
        except Exception as e:  # DB hiccup etc.: report it for this file and carry on
            item["error"] = f"{type(e).__name__}: {e}"[:300]
        finally:
            await f.close()
        results.append(item)
    if queued:
        bg.add_task(process_many, queued)
    return {"results": results, "stored": len(queued),
            "duplicates": sum(1 for r in results if r["duplicate"]),
            "failed": sum(1 for r in results if not r["ok"])}


RAW_TYPES = {"image/jpeg": ".jpg", "image/jpg": ".jpg", "image/png": ".png", "image/heic": ".heic", "image/heif": ".heif",
             "image/webp": ".webp", "image/gif": ".gif", "image/tiff": ".tiff", "image/bmp": ".bmp"}


@app.post("/api/upload-raw")
async def upload_raw(request: Request, bg: BackgroundTasks, filename: str | None = None, who: str = Depends(auth)):
    """One photo as the raw request body (what an iPhone Shortcut's "Get Contents of URL" sends with Request Body = File).
    Name: ?filename=…, else the X-Filename header, else from the Content-Type. Same checks, dedupe and model step as /api/upload."""
    ctype = (request.headers.get("content-type") or "").split(";")[0].strip().lower()
    name = (filename or request.headers.get("x-filename") or "").strip() or "photo"
    if not Path(name).suffix:
        name += RAW_TYPES.get(ctype, ".jpg")
    body = bytearray()
    async for chunk in request.stream():
        body += chunk
        if len(body) > MAX_UPLOAD:
            raise HTTPException(413, "file too big (25 MB max)")
    try:
        r = store_bytes(bytes(body), name, who)
    except UploadProblem as e:
        raise HTTPException(e.status, e.text)
    if r.pop("new", False):
        bg.add_task(process, r["id"])
    return {"filename": name, "ok": True, **r}


FLAG_STEPS = ("dup_dismiss", "dup_mark", "dup_unmark", "date_ok")


def all_flags(cur) -> dict:
    """Possible-duplicate and check-the-date flags for every receipt, worked out when asked (data unchanged)."""
    cur.execute("SELECT id, status, vendor, total, doc_date, raw_text, extracted_json FROM documents")
    docs = [dict(zip(("id", "status", "vendor", "total", "doc_date", "raw_text", "extracted_json"), r)) for r in cur.fetchall()]
    cur.execute("SELECT document_id, step, detail FROM processing_log WHERE step = ANY(%s) ORDER BY seq", (list(FLAG_STEPS),))
    return checks.flags(docs, cur.fetchall(), date.today())


@app.post("/api/documents/{doc_id}/duplicate")
async def duplicate_action(doc_id: int, request: Request, who: str = Depends(auth)):
    """Body {"action": "dismiss" | "mark" | "unmark", "of": N}. dismiss = "not a duplicate of #N" (that pair is never
    flagged again); mark = it IS a duplicate of #N (left out of totals and the export); unmark = undo mark.
    Saved as entries in the append-only processing log; the receipt itself is not changed or deleted."""
    body = await request.json()
    action, of = body.get("action"), body.get("of")
    if action not in ("dismiss", "mark", "unmark"):
        raise HTTPException(400, "action must be dismiss, mark or unmark")
    if action != "unmark" and (not isinstance(of, int) or of == doc_id):
        raise HTTPException(400, "of must be the other receipt's number")
    with db() as conn, conn.cursor() as cur:
        cur.execute("SELECT id FROM documents WHERE id = ANY(%s)", ([doc_id] + ([of] if isinstance(of, int) else []),))
        found = {r[0] for r in cur.fetchall()}
        if doc_id not in found or (action != "unmark" and of not in found):
            raise HTTPException(404, "no such document")
        log(cur, who, "dup_" + action, True, {"dismiss": f"not a duplicate of #{of}", "mark": f"marked duplicate of #{of}",
                                              "unmark": "duplicate mark removed"}[action], doc_id, None, {"of": of})
        f = all_flags(cur).get(doc_id, {})
    return {"id": doc_id, **f}


@app.post("/api/documents/{doc_id}/date-ok")
def date_ok(doc_id: int, who: str = Depends(auth)):
    """"The date is right": hides this receipt's check-the-date flag for its current date (log entry only)."""
    with db() as conn, conn.cursor() as cur:
        cur.execute("SELECT doc_date FROM documents WHERE id=%s", (doc_id,))
        r = cur.fetchone()
        if not r:
            raise HTTPException(404, "no such document")
        day = r[0].isoformat() if r[0] else None
        log(cur, who, "date_ok", True, f"date {day} confirmed", doc_id, None, {"date": day})
    return {"id": doc_id, "date": day}


@app.get("/api/export.csv")
def export_csv(who: str = Depends(auth)):
    """Receipts as CSV, leaving out the ones marked as duplicates."""
    import csv, io
    with db() as conn, conn.cursor() as cur:
        fl = all_flags(cur)
        cur.execute("SELECT id, doc_date, vendor, doc_type, subtotal, tax, total, currency, status FROM documents "
                    "WHERE status <> 'failed' ORDER BY doc_date NULLS LAST, id")
        rows = cur.fetchall()
    buf = io.StringIO(); w = csv.writer(buf)
    w.writerow(["id", "date", "vendor", "type", "subtotal", "tax", "total", "currency", "status", "check_date"])
    for r in rows:
        f = fl.get(r[0], {})
        if f.get("marked_duplicate_of"):
            continue
        w.writerow(list(r) + ["yes" if f.get("date_flags") else ""])
    return Response(buf.getvalue(), media_type="text/csv",
                    headers={"Content-Disposition": 'attachment; filename="receipts.csv"'})


DOC_COLS = ("id, uploaded_at, uploaded_by, filename, sha256, status, doc_type, vendor, doc_date, subtotal, tax, "
            "total, currency, language, raw_text, extracted_json, model, model_confidence, latency_ms, errors, "
            "reviewed_at, reviewed_by")


def row_dict(cur, row):
    return extract.jsonable({d.name: (v.isoformat() if hasattr(v, "isoformat") else v)
                             for d, v in zip(cur.description, row)})


@app.get("/api/documents")
def list_docs(limit: int = 50, who: str = Depends(auth)):
    with db() as conn, conn.cursor() as cur:
        cur.execute("SELECT id, uploaded_at, filename, status, doc_type, vendor, doc_date, total, currency, "
                    "latency_ms FROM documents ORDER BY id DESC LIMIT %s", (min(limit, 500),))
        rows = [row_dict(cur, r) for r in cur.fetchall()]
        fl = all_flags(cur)
    for r in rows:
        r.update(fl.get(r["id"], {}))
    return rows


@app.get("/api/documents/{doc_id}")
def get_doc(doc_id: int, who: str = Depends(auth)):
    with db() as conn, conn.cursor() as cur:
        cur.execute(f"SELECT {DOC_COLS} FROM documents WHERE id=%s", (doc_id,))
        r = cur.fetchone()
        if not r:
            raise HTTPException(404, "no such document")
        d = row_dict(cur, r)
        cur.execute("SELECT position, description, qty, unit_price, amount FROM line_items "
                    "WHERE document_id=%s ORDER BY position", (doc_id,))
        d["line_items"] = [row_dict(cur, x) for x in cur.fetchall()]
        cur.execute("SELECT seq, created_at, actor, step, ok, result FROM processing_log "
                    "WHERE document_id=%s ORDER BY seq", (doc_id,))
        d["log"] = [row_dict(cur, x) for x in cur.fetchall()]
        d.update(all_flags(cur).get(doc_id, {}))
        return d


@app.get("/api/documents/{doc_id}/image")
def get_image(doc_id: int, who: str = Depends(auth)):
    with db() as conn, conn.cursor() as cur:
        cur.execute("SELECT image_path FROM documents WHERE id=%s", (doc_id,))
        r = cur.fetchone()
    if not r:
        raise HTTPException(404)
    return FileResponse(r[0])


@app.post("/api/documents/{doc_id}/review")
async def review(doc_id: int, request: Request, who: str = Depends(auth)):
    """Body: {"fields": {...same keys the model returns...}} -> saved as status 'approved'."""
    body = await request.json()
    with db() as conn, conn.cursor() as cur:
        cur.execute("SELECT extracted_json, status FROM documents WHERE id=%s", (doc_id,))
        r = cur.fetchone()
        if not r:
            raise HTTPException(404, "no such document")
        fields_in = body.get("fields") or r[0] or {}
        if not isinstance(fields_in, dict):
            raise HTTPException(400, "fields must be a JSON object")
        fields_in.setdefault("model_confidence", 1.0)
        fields, problems = extract.validate(fields_in)
        save_fields(cur, doc_id, fields, "approved", problems, raw_json=None, reviewer=who)
        log(cur, who, "review", True, f"approved (was {r[1]})", doc_id, None,
            {"remaining_problems": problems, "fields": fields_in})
        if body.get("date_confirmed") and fields["doc_date"]:
            log(cur, who, "date_ok", True, f"date {fields['doc_date']} confirmed in Edit", doc_id, None,
                {"date": fields["doc_date"].isoformat()})
    return {"id": doc_id, "status": "approved", "remaining_problems": problems}


@app.post("/api/documents/{doc_id}/reprocess")
def reprocess(doc_id: int, bg: BackgroundTasks, who: str = Depends(auth)):
    """Run the model again on a stored photo (e.g. after a model/prompt change)."""
    with db() as conn, conn.cursor() as cur:
        cur.execute("UPDATE documents SET status='processing', updated_at=now() WHERE id=%s RETURNING id", (doc_id,))
        if not cur.fetchone():
            raise HTTPException(404, "no such document")
        log(cur, who, "reprocess", True, "requested", doc_id, extract.MODEL)
    bg.add_task(process, doc_id)
    return {"id": doc_id, "status": "processing"}


@app.get("/api/log/verify")
def verify_log(who: str = Depends(auth)):
    with db() as conn, conn.cursor() as cur:
        cur.execute("SELECT * FROM processing_log_verify()")
        bad = cur.fetchall()
        cur.execute("SELECT count(*) FROM processing_log")
        n = cur.fetchone()[0]
    return {"rows": n, "intact": not bad, "first_problem": bad[0] if bad else None}


@app.get("/", response_class=HTMLResponse)
def index(who: str = Depends(auth)):
    return (Path(__file__).parent / "index.html").read_text()
