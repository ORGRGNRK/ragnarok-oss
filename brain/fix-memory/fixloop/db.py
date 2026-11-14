"""Postgres + pgvector access for the fix memory.

The tables live in the data layer's ONE Postgres (ragnarok/data/db/brain.sql). Receipts are not
written here: the database's kit_write_log trigger writes a hash-chained write_log receipt for every
INSERT into brain.brain_fixes / brain.brain_fix_events, in the same transaction. We only say who
(actor), which run (session) and why (note) via receipts.set_context()."""
from __future__ import annotations

import json
import uuid

import psycopg

from . import receipts
from .config import settings

# One id per process (one fixloop run / one MCP server session), so its receipts can be grouped.
SESSION = f"fixloop-{uuid.uuid4().hex[:12]}"


def connect() -> psycopg.Connection:
    if not settings.pg_password:
        raise RuntimeError("No database password found. Start the data layer first (cd ragnarok/data && ./kit up), "
                         "or set FIXLOOP_PG_PASSWORD.")
    return psycopg.connect(settings.conninfo())


def _vec(v: list[float]) -> str:
    return "[" + ",".join(f"{x:.7f}" for x in v) + "]"


def search_fixes(embedding: list[float], k: int = 3) -> list[dict]:
    with connect() as conn, conn.cursor() as cur:
        cur.execute(
            """SELECT f.id, f.source, f.project, f.error_text, f.cause, f.fix,
                      (SELECT w.hash FROM write_log w WHERE w.table_name = 'brain_fixes'
                         AND w.record_id = f.id::text AND w.action = 'INSERT' ORDER BY w.seq DESC LIMIT 1) AS receipt_hash,
                      1 - (v.embedding <=> %s::vector) AS similarity
               FROM brain.fix_vectors v JOIN brain.brain_fixes f ON f.id = v.fix_id
               ORDER BY v.embedding <=> %s::vector LIMIT %s""",
            (_vec(embedding), _vec(embedding), k),
        )
        cols = [d.name for d in cur.description]
        return [dict(zip(cols, r)) for r in cur.fetchall()]


def record_fix(*, source: str, project: str | None, error_text: str, cause: str, fix: str,
               embedding: list[float], extra: dict | None = None, actor: str | None = None) -> dict:
    """Insert a fix (+ its search vector). The write_log receipt is written by the database."""
    with connect() as conn, conn.cursor() as cur:
        receipts.set_context(cur, actor or settings.actor, SESSION,
                             f"fix learned ({source}) for {project or 'unknown project'}: {(cause or '')[:200]}")
        from . import ollama   # the model name Ollama reported for the embedding just made (callers embed, then record)
        detail = {"embed_model": settings.embed_model, "embed_model_reported": ollama.reported["embed"], **(extra or {})}
        cur.execute(
            """INSERT INTO brain.brain_fixes (source, project, error_text, cause, fix, detail)
               VALUES (%s,%s,%s,%s,%s,%s::jsonb) RETURNING id""",
            (source, project, error_text, cause, fix, json.dumps(detail, default=str)),
        )
        fix_id = cur.fetchone()[0]
        cur.execute("INSERT INTO brain.fix_vectors (fix_id, embedding, embed_model) VALUES (%s, %s::vector, %s)",
                    (fix_id, _vec(embedding), settings.embed_model))
        rec = receipts.receipt_for(cur, "brain_fixes", fix_id)
    return {"fix_id": fix_id, **rec}


def record_reuse(fix_id: int, project: str | None, extra: dict | None = None, actor: str | None = None) -> dict:
    """A stored fix healed a new failure as-is: a 'fix_reused' event (receipted), no new fix row."""
    with connect() as conn, conn.cursor() as cur:
        receipts.set_context(cur, actor or settings.actor, SESSION,
                             f"stored fix #{fix_id} reused as-is for {project or 'unknown project'}")
        cur.execute(
            """INSERT INTO brain.brain_fix_events (kind, fix_id, project, detail)
               VALUES ('fix_reused', %s, %s, %s::jsonb) RETURNING id""",
            (fix_id, project, json.dumps(extra or {}, default=str)),
        )
        ev_id = cur.fetchone()[0]
        rec = receipts.receipt_for(cur, "brain_fix_events", ev_id)
    return {"fix_id": fix_id, "event_id": ev_id, "reused": True, **rec}


def reembed(embed_fn) -> int:
    """Recompute every search vector from its error text; one receipted 'reembed' event."""
    with connect() as conn, conn.cursor() as cur:
        receipts.set_context(cur, settings.actor, SESSION, f"search vectors rebuilt with {settings.embed_model}")
        cur.execute("SELECT id, error_text FROM brain.brain_fixes ORDER BY id")
        rows = cur.fetchall()
        for fid, err in rows:
            cur.execute(
                """INSERT INTO brain.fix_vectors (fix_id, embedding, embed_model) VALUES (%s, %s::vector, %s)
                   ON CONFLICT (fix_id) DO UPDATE SET embedding = EXCLUDED.embedding,
                     embed_model = EXCLUDED.embed_model, updated_at = now()""",
                (fid, _vec(embed_fn(err)), settings.embed_model))
        cur.execute("INSERT INTO brain.brain_fix_events (kind, detail) VALUES ('reembed', %s::jsonb)",
                    (json.dumps({"fix_ids": [r[0] for r in rows], "embed_model": settings.embed_model,
                                 "method": "error_signature"}),))
    return len(rows)


def recent_receipts(limit: int = 10) -> list[dict]:
    """The newest write_log receipts for brain tables (the big text fields are shortened)."""
    with connect() as conn, conn.cursor() as cur:
        cur.execute(
            """SELECT seq, created_at, table_name, record_id, actor, session, note, prev_hash, hash,
                      new_value->>'kind' AS kind, new_value->>'source' AS source, new_value->>'project' AS project,
                      new_value->>'fix_id' AS fix_id, left(new_value->>'cause', 120) AS cause
               FROM write_log WHERE table_name = ANY(%s) ORDER BY seq DESC LIMIT %s""",
            (list(receipts.BRAIN_TABLES), limit),
        )
        cols = [d.name for d in cur.description]
        rows = [dict(zip(cols, r)) for r in cur.fetchall()]
    for r in rows:
        r["created_at"] = r["created_at"].isoformat()
        r["kind"] = r["kind"] or ("fix_recorded" if r["table_name"] == "brain_fixes" else "event")
    return rows


def verify_chain() -> tuple[bool, int, str]:
    with connect() as conn, conn.cursor() as cur:
        return receipts.verify(cur)


def stats() -> dict:
    with connect() as conn, conn.cursor() as cur:
        cur.execute("SELECT source, count(*) FROM brain.brain_fixes GROUP BY source ORDER BY source")
        by_source = {s: n for s, n in cur.fetchall()}
        cur.execute("SELECT kind, count(*) FROM brain.brain_fix_events GROUP BY kind ORDER BY kind")
        events = {s: n for s, n in cur.fetchall()}
        cur.execute("SELECT count(*) FROM write_log WHERE table_name = ANY(%s)", (list(receipts.BRAIN_TABLES),))
        return {"fixes_by_source": by_source, "events": events, "write_log_receipts": cur.fetchone()[0]}


def dumps(obj) -> str:
    return json.dumps(obj, indent=2, default=str)
