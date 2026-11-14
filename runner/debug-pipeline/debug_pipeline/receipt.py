"""Append-only SHA-256 receipt log.

The line shape matches the receipt logger installed from
ops/alexus/setup-ai-users-alexus.sh: seq, ts, actor, kind, status, cwd, cmd,
prev_hash, hash. The hash is the SHA-256 of

    seq|ts|actor|kind|status|cwd|cmd|prev_hash

with no extra newline. The first prev_hash is 64 zeros.

Status is only OK, FAILED, or NOT VERIFIED, the same three words as
~/client-kit/tools/audit.py. verify names the first bad line.
"""
import datetime
import fcntl
import hashlib
import json
import os

STATUSES = ("OK", "FAILED", "NOT VERIFIED")
GENESIS = "0" * 64
FIELDS = ("seq", "ts", "actor", "kind", "status", "cwd", "cmd", "prev_hash", "hash")


def payload(rec):
    return "|".join(str(rec[k]) for k in ("seq", "ts", "actor", "kind", "status", "cwd", "cmd", "prev_hash"))


def digest(rec):
    return hashlib.sha256(payload(rec).encode("utf-8")).hexdigest()


def verify(path):
    """Return (ok, message). The message names the first bad line."""
    prev = GENESIS
    n = 0
    try:
        handle = open(path, "rb")
    except OSError as err:
        return False, f"CHAIN BROKEN: line 1: can't read the log: {err.strerror}"
    with handle:
        for raw in handle:
            n += 1
            if not raw.strip():
                return False, f"CHAIN BROKEN: line {n}: blank receipt line"
            try:
                rec = json.loads(raw)
            except ValueError:
                return False, f"CHAIN BROKEN: line {n}: not a receipt line"
            if not isinstance(rec, dict) or any(k not in rec for k in FIELDS):
                return False, f"CHAIN BROKEN: line {n}: not a receipt line"
            seq = rec["seq"]
            if seq != n:
                return False, f"CHAIN BROKEN: line {n} (seq {seq}): seq is {seq}, expected {n}"
            if rec["status"] not in STATUSES:
                return False, f"CHAIN BROKEN: line {n} (seq {seq}): status is not OK, FAILED, or NOT VERIFIED"
            if rec["prev_hash"] != prev:
                return False, f"CHAIN BROKEN: line {n} (seq {seq}): does not follow the line before it"
            if rec["hash"] != digest(rec):
                return False, f"CHAIN BROKEN: line {n} (seq {seq}): contents changed after it was logged"
            prev = rec["hash"]
    return True, f"chain intact: {n} lines"


class ReceiptLog:
    """Host-side writer. Opened append-only. There is no update and no delete."""

    def __init__(self, path, actor, fence=None):
        self.path = path
        self.lock = path.with_name(path.name + ".lock")
        self.actor = actor
        self.fence = fence
        if fence is not None:
            fence.allow(self.path)
            fence.allow(self.lock)
        self.path.parent.mkdir(parents=True, exist_ok=True)
        if not self.path.exists():
            fd = os.open(self.path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o644)
            os.close(fd)

    def append(self, kind, status, cwd, cmd):
        if status not in STATUSES:
            raise ValueError(f"status must be OK, FAILED, or NOT VERIFIED, not {status}")
        if self.fence is not None:
            self.fence.allow(self.path)
        with open(self.lock, "a") as lk:
            fcntl.flock(lk, fcntl.LOCK_EX)
            seq, prev = self._tail()
            ts = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
            rec = {
                "seq": seq + 1,
                "ts": ts,
                "actor": self.actor,
                "kind": kind,
                "status": status,
                "cwd": cwd,
                "cmd": cmd,
                "prev_hash": prev,
            }
            rec["hash"] = digest(rec)
            line = json.dumps(rec, ensure_ascii=False, separators=(",", ":")) + "\n"
            fd = os.open(self.path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o644)
            try:
                os.write(fd, line.encode("utf-8"))
            finally:
                os.close(fd)
        return rec

    def _tail(self):
        if not self.path.exists() or self.path.stat().st_size == 0:
            return 0, GENESIS
        with open(self.path, "rb") as handle:
            handle.seek(0, os.SEEK_END)
            size = handle.tell()
            handle.seek(max(0, size - 1024 * 1024))
            lines = [ln for ln in handle.read().split(b"\n") if ln]
        rec = json.loads(lines[-1])
        return int(rec["seq"]), str(rec["hash"])

    def head(self):
        seq, prev = self._tail()
        return GENESIS if seq == 0 else prev

    def text(self):
        return self.path.read_text(encoding="utf-8")
