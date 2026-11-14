"""Watched inbox: photos dropped in ~/receipts-inbox are sent through the pipe's own upload (same checks, exact-copy
dedupe, model step and likely-duplicate flags), then moved to done/ or failed/ (with a .reason.txt). Nothing is
ever deleted. Run every minute by ragnarok-pipe-inbox.timer; `python -m app.inbox --dry-run` only reports.
Half-written files are left alone: a file must be at least 10 s old and the same size and time 5 s later."""
import fcntl
import json
import os
import sys
import time
from datetime import datetime
from pathlib import Path

INBOX = Path(os.environ.get("PIPE_INBOX", str(Path.home() / "receipts-inbox")))
URL = os.environ.get("PIPE_INBOX_URL", "http://127.0.0.1:8448/api/upload-many")
IMAGES = {".jpg", ".jpeg", ".png", ".webp", ".heic", ".heif", ".gif", ".bmp", ".tif", ".tiff"}
SKIP_SUFFIX = (".part", ".partial", ".tmp", ".crdownload", ".download", ".swp", "~", ".reason.txt")
MIN_AGE, SETTLE, BATCH = 10, 5, 5


def log(inbox: Path, line: str):
    with open(inbox / "inbox.log", "a") as f:
        f.write(f"{datetime.now().isoformat(timespec='seconds')} {line}\n")


def move(src: Path, folder: Path) -> Path:
    """Move without ever overwriting: a name already there gets a time prefix."""
    folder.mkdir(exist_ok=True)
    dst = folder / src.name
    if dst.exists():
        dst = folder / f"{datetime.now():%Y%m%d-%H%M%S}-{src.name}"
    n = 1
    while dst.exists():
        dst = folder / f"{datetime.now():%Y%m%d-%H%M%S}-{n}-{src.name}"; n += 1
    os.rename(src, dst)
    return dst


def fail(inbox: Path, src: Path, reason: str):
    dst = move(src, inbox / "failed")
    dst.with_name(dst.name + ".reason.txt").write_text(reason + "\n")
    log(inbox, f"failed {src.name}: {reason}")


def ready_files(inbox: Path, now=time.time, sleep=time.sleep) -> list[Path]:
    """Files in the inbox (not subfolders, not hidden or temp names) whose size and time have stopped changing."""
    def snap():
        out = {}
        for p in inbox.iterdir():
            if p.name.startswith(".") or p.name.endswith(SKIP_SUFFIX) or p.name == "inbox.log" or not p.is_file():
                continue
            st = p.stat()
            if now() - st.st_mtime >= MIN_AGE:
                out[p] = (st.st_size, st.st_mtime_ns)
        return out
    first = snap()
    if not first:
        return []
    sleep(SETTLE)
    second = snap()
    return sorted(p for p, s in first.items() if second.get(p) == s)


def default_upload(files: list[tuple[str, bytes]]) -> list[dict]:
    import httpx
    auth = (os.environ["PIPE_WEB_USER"], os.environ["PIPE_WEB_PASSWORD"])
    r = httpx.post(URL, auth=auth, files=[("files", (n, b)) for n, b in files], timeout=120)
    r.raise_for_status()
    return r.json()["results"]


def run(inbox: Path = INBOX, upload=default_upload, dry_run=False, now=time.time, sleep=time.sleep) -> dict:
    inbox.mkdir(exist_ok=True)
    (inbox / "done").mkdir(exist_ok=True); (inbox / "failed").mkdir(exist_ok=True)
    counts = {"seen": 0, "done": 0, "duplicates": 0, "failed": 0, "waiting": 0}
    with open(inbox / ".lock", "w") as lk:
        try:
            fcntl.flock(lk, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return {**counts, "note": "another run is busy"}
        files = ready_files(inbox, now, sleep)
        counts["seen"] = len(files)
        todo = []
        for p in files:
            ext = p.suffix.lower()
            size = p.stat().st_size
            if size == 0:
                reason = "empty file"
            elif ext == ".pdf":
                reason = "PDFs aren't supported by the pipe yet (no PDF reader on Alexus); save it as a photo or screenshot instead"
            elif ext not in IMAGES:
                reason = f"not a photo type the pipe takes ({ext or 'no extension'})"
            elif size > 25 * 1024 * 1024:
                reason = "file too big (25 MB max)"
            else:
                todo.append(p); continue
            counts["failed"] += 1
            if dry_run:
                print(f"would fail {p.name}: {reason}")
            else:
                fail(inbox, p, reason)
        for i in range(0, len(todo), BATCH):
            part = todo[i:i + BATCH]
            if dry_run:
                for p in part:
                    print(f"would upload {p.name}")
                counts["done"] += len(part); continue
            try:
                results = upload([(p.name, p.read_bytes()) for p in part])
            except Exception as e:   # pipe down or restarting: leave the files for the next run
                counts["waiting"] += len(todo) - i
                log(inbox, f"upload failed, will retry next run: {type(e).__name__}: {str(e)[:200]}")
                break
            for p, r in zip(part, results):
                if r.get("ok"):
                    move(p, inbox / "done")
                    counts["done"] += 1; counts["duplicates"] += bool(r.get("duplicate"))
                    log(inbox, f"done {p.name} -> document #{r['id']}" + (" (exact copy of one already uploaded)" if r.get("duplicate") else ""))
                else:
                    counts["failed"] += 1
                    fail(inbox, p, r.get("error") or "upload refused")
    return counts


if __name__ == "__main__":
    c = run(dry_run="--dry-run" in sys.argv)
    print(json.dumps(c))
