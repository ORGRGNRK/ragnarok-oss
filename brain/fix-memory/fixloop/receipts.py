"""Receipts live in the data layer's hash-chained, append-only write_log (ragnarok/data).

fixloop no longer keeps its own receipts table. Each fix (brain.brain_fixes) and each event
(brain.brain_fix_events: fix_reused, reembed) is an INSERT; the database's kit_write_log trigger
writes the receipt in the same transaction: who (actor), session, why (note), the full new row,
and a hash that covers the previous receipt. kit_verify() recomputes the whole chain."""
from __future__ import annotations

BRAIN_TABLES = ("brain_fixes", "brain_fix_events")


def set_context(cur, actor: str, session: str | None = None, note: str | None = None) -> None:
    """What the database trigger writes on the receipt (for this transaction only)."""
    cur.execute("SELECT set_config('receipt.actor', %s, true), set_config('receipt.session', %s, true), "
                "set_config('receipt.note', %s, true)", (actor[:80], (session or "")[:120], (note or "")[:500]))


def receipt_for(cur, table: str, row_id: int) -> dict:
    """The write_log receipt the trigger just wrote for this row."""
    cur.execute("SELECT seq, hash FROM write_log WHERE table_name = %s AND record_id = %s AND action = 'INSERT' "
                "ORDER BY seq DESC LIMIT 1", (table, str(row_id)))
    row = cur.fetchone()
    if not row:
        raise RuntimeError(f"no write_log receipt for {table} #{row_id}: is data/db/brain.sql applied (./kit up)?")
    return {"receipt_seq": int(row[0]), "receipt_hash": row[1]}


def verify(cur) -> tuple[bool, int, str]:
    """Recompute data/'s receipt chains (write_log and access_log) with kit_verify()."""
    cur.execute("SELECT chain, rows_checked, intact, first_bad_seq, problem FROM kit_verify()")
    rows = cur.fetchall()
    ok = bool(rows) and all(r[2] for r in rows)
    n = sum(int(r[1]) for r in rows)
    parts = [f"{r[0]}: {'INTACT' if r[2] else 'BROKEN at #' + str(r[3])} ({r[1]} rows)"
             + (f" {r[4]}" if r[4] and not r[2] else "") for r in rows]
    return ok, n, "; ".join(parts)
