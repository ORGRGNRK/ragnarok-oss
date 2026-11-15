"""SQLite storage and FTS5 search for questions and their traces."""

import json
import sqlite3
import threading
from datetime import datetime, timezone

_LOCK = threading.Lock()

SCHEMA = """
CREATE TABLE IF NOT EXISTS questions (
    id INTEGER PRIMARY KEY,
    question TEXT NOT NULL,
    answer TEXT NOT NULL DEFAULT '',
    provider TEXT NOT NULL DEFAULT '',
    status TEXT NOT NULL DEFAULT 'running',
    created_at TEXT NOT NULL,
    finished_at TEXT
);
CREATE TABLE IF NOT EXISTS events (
    id INTEGER PRIMARY KEY,
    question_id INTEGER NOT NULL,
    seq INTEGER NOT NULL,
    type TEXT NOT NULL,
    provider TEXT NOT NULL DEFAULT '',
    duration_ms INTEGER,
    payload TEXT NOT NULL,
    FOREIGN KEY (question_id) REFERENCES questions(id)
);
CREATE INDEX IF NOT EXISTS events_question_seq ON events(question_id, seq);
CREATE VIRTUAL TABLE IF NOT EXISTS questions_fts USING fts5(
    question,
    answer,
    question_id UNINDEXED
);
"""


def now_iso():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def connect(path):
    conn = sqlite3.connect(str(path), timeout=5)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA foreign_keys=ON")
    conn.executescript(SCHEMA)
    cols = [r[1] for r in conn.execute("PRAGMA table_info(questions)")]
    if "parent_id" not in cols:
        # A reply points at the question it follows. Older databases get the column added in place.
        conn.execute("ALTER TABLE questions ADD COLUMN parent_id INTEGER")
    return conn


def _refresh_fts(conn, question_id, question, answer):
    conn.execute("DELETE FROM questions_fts WHERE question_id = ?", (question_id,))
    conn.execute(
        "INSERT INTO questions_fts(question, answer, question_id) VALUES (?, ?, ?)",
        (question, answer, question_id),
    )


def start_question(path, question, parent_id=None):
    with _LOCK:
        conn = connect(path)
        try:
            created = now_iso()
            cur = conn.execute(
                "INSERT INTO questions(question, answer, provider, status, created_at, parent_id) VALUES (?, '', '', 'running', ?, ?)",
                (question, created, parent_id),
            )
            question_id = cur.lastrowid
            _refresh_fts(conn, question_id, question, "")
            conn.commit()
            return question_id
        finally:
            conn.close()


def add_event(path, question_id, seq, event):
    payload = {
        "text": event.get("text") or "",
        "kind": event.get("kind") or "",
        "name": event.get("name") or "",
        "tool_id": event.get("tool_id") or "",
        "interim": bool(event.get("interim")),
        "model": event.get("model") or "",
    }
    if event.get("pid"):
        payload["pid"] = int(event["pid"])
    with _LOCK:
        conn = connect(path)
        try:
            conn.execute(
                "INSERT INTO events(question_id, seq, type, provider, duration_ms, payload) VALUES (?, ?, ?, ?, ?, ?)",
                (
                    question_id,
                    seq,
                    event.get("type") or "",
                    event.get("provider") or "",
                    event.get("duration_ms"),
                    json.dumps(payload, ensure_ascii=False),
                ),
            )
            conn.commit()
        finally:
            conn.close()


def finish_question(path, question_id, answer, provider, status):
    with _LOCK:
        conn = connect(path)
        try:
            row = conn.execute(
                "SELECT question FROM questions WHERE id = ?",
                (question_id,),
            ).fetchone()
            question = row["question"] if row else ""
            conn.execute(
                "UPDATE questions SET answer = ?, provider = ?, status = ?, finished_at = ? WHERE id = ?",
                (answer or "", provider or "", status or "error", now_iso(), question_id),
            )
            _refresh_fts(conn, question_id, question, answer or "")
            conn.commit()
        finally:
            conn.close()


def _row_to_question(row):
    return {
        "id": row["id"],
        "question": row["question"],
        "answer": row["answer"],
        "provider": row["provider"],
        "status": row["status"],
        "created_at": row["created_at"],
        "finished_at": row["finished_at"],
        "parent_id": row["parent_id"] if "parent_id" in row.keys() else None,
    }


def _event_row(row):
    payload = json.loads(row["payload"])
    event = {
        "seq": row["seq"],
        "type": row["type"],
        "provider": row["provider"],
        "duration_ms": row["duration_ms"],
        "text": payload.get("text") or "",
        "kind": payload.get("kind") or "",
        "name": payload.get("name") or "",
        "tool_id": payload.get("tool_id") or "",
        "interim": bool(payload.get("interim")),
        "model": payload.get("model") or "",
    }
    if payload.get("pid"):
        event["pid"] = payload["pid"]
    return event


def events_for(path, question_id):
    with _LOCK:
        conn = connect(path)
        try:
            rows = conn.execute(
                "SELECT seq, type, provider, duration_ms, payload FROM events WHERE question_id = ? ORDER BY seq ASC",
                (question_id,),
            ).fetchall()
            return [_event_row(row) for row in rows]
        finally:
            conn.close()


def get_question(path, question_id):
    with _LOCK:
        conn = connect(path)
        try:
            row = conn.execute("SELECT * FROM questions WHERE id = ?", (question_id,)).fetchone()
            if row is None:
                return None
            item = _row_to_question(row)
        finally:
            conn.close()
    item["events"] = events_for(path, question_id)
    item["thread"] = [{"id": t["id"], "question": t["question"], "answer": t["answer"]}
                      for t in thread_before(path, question_id)]
    return item


def thread_before(path, question_id, limit=20):
    """The earlier turns this question follows, oldest first (not including itself)."""
    out, seen = [], set()
    with _LOCK:
        conn = connect(path)
        try:
            row = conn.execute("SELECT parent_id FROM questions WHERE id = ?", (question_id,)).fetchone()
            current = row["parent_id"] if row else None
            while current is not None and current not in seen and len(out) < limit:
                seen.add(current)
                r = conn.execute("SELECT * FROM questions WHERE id = ?", (current,)).fetchone()
                if r is None:
                    break
                out.append(_row_to_question(r))
                current = r["parent_id"]
        finally:
            conn.close()
    out.reverse()
    return out


def exists(path, question_id):
    with _LOCK:
        conn = connect(path)
        try:
            return conn.execute("SELECT 1 FROM questions WHERE id = ?", (question_id,)).fetchone() is not None
        finally:
            conn.close()


def latest_by_question(path, question):
    with _LOCK:
        conn = connect(path)
        try:
            row = conn.execute(
                "SELECT * FROM questions WHERE question = ? ORDER BY id DESC LIMIT 1",
                (question,),
            ).fetchone()
            return _row_to_question(row) if row else None
        finally:
            conn.close()


def recent(path, limit=30):
    with _LOCK:
        conn = connect(path)
        try:
            rows = conn.execute(
                "SELECT * FROM questions ORDER BY id DESC LIMIT ?",
                (int(limit),),
            ).fetchall()
            return [_row_to_question(row) for row in rows]
        finally:
            conn.close()


def fts_query(text):
    words = []
    current = []
    for char in text or "":
        if char.isalnum() or char == "_":
            current.append(char)
        elif current:
            words.append("".join(current))
            current = []
    if current:
        words.append("".join(current))
    if not words:
        return ""
    return " AND ".join('"%s"' % word.replace('"', "") for word in words[:12])


def search(path, text, limit=20):
    match = fts_query(text)
    if not match:
        return []
    with _LOCK:
        conn = connect(path)
        try:
            try:
                rows = conn.execute(
                    "SELECT question_id FROM questions_fts WHERE questions_fts MATCH ? ORDER BY rank LIMIT ?",
                    (match, int(limit)),
                ).fetchall()
            except sqlite3.OperationalError:
                rows = conn.execute(
                    "SELECT question_id FROM questions_fts WHERE questions_fts MATCH ? LIMIT ?",
                    (match, int(limit)),
                ).fetchall()
            ids = [row["question_id"] for row in rows]
            items = []
            for question_id in ids:
                row = conn.execute("SELECT * FROM questions WHERE id = ?", (question_id,)).fetchone()
                if row is not None:
                    items.append(_row_to_question(row))
            return items
        finally:
            conn.close()
