#!/usr/bin/env python3
"""log-ship -- copy NEW lines of local logs off-site (Google Drive via rclone).

owner, 2026-10-31: "can we move the audit logs outside of the macbook and
alexus ... just put it in cloud drive". Runs on both machines (cron on Alexus,
launchd on the Mac).

Each run, per source file:
  1. Reads from the saved byte offset to the last complete line. If the file
     was rotated (inode changed), the rest of the old file (<path>.1) is read
     first; if it shrank, it starts over from 0.
  2. Writes that slice, gzipped, to the spool as a NEW dated file, then saves
     the offset. Nothing is ever re-sent or overwritten.
  3. `rclone move --immutable` uploads the spool to
     <remote>/<host>/<source>/YYYY/MM/<source>-<host>-<UTC>.gz and removes
     a spooled file only after rclone has verified the upload. If the upload
     fails, the spool keeps it for the next run.

Copy-only: deleting or editing a local log never touches what is already on
Drive. Drive itself is NOT delete-proof (whoever holds the rclone login can
delete there); that was accepted on 10-31 in place of a paid locked bucket.

Usage:
  log-ship.py --host alexus --rclone ~/.local/bin/rclone \
      --source audit=/var/log/audit/audit.log [--source NAME=PATH ...]
State + spool: ~/.local/state/log-ship/   Log: ~/.local/state/log-ship/ship.log
"""
import argparse
import fcntl
import gzip
import json
import os
import subprocess
import sys
import time

STATE_DIR = os.path.expanduser("~/.local/state/log-ship")
REMOTE = "gdrive:RAGNAROK-Logs"
MAX_CHUNK = 50 * 1024 * 1024   # bytes read per source per run


def log(msg):
    line = f"{time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())} {msg}"
    print(line)
    with open(os.path.join(STATE_DIR, "ship.log"), "a") as f:
        f.write(line + "\n")


def read_range(path, start, limit):
    """Bytes from start up to the last newline, at most limit bytes."""
    with open(path, "rb") as f:
        f.seek(start)
        data = f.read(limit)
    cut = data.rfind(b"\n")
    return data[:cut + 1] if cut >= 0 else b""


def collect(name, path, state):
    st = os.stat(path)
    prev = state.get(name, {})
    ino, off = prev.get("inode"), prev.get("offset", 0)
    parts = []
    if ino is not None and ino != st.st_ino:
        old = path + ".1"
        if os.path.exists(old) and os.stat(old).st_ino == ino:
            parts.append(read_range(old, off, MAX_CHUNK))
        off = 0
    elif st.st_size < off:
        off = 0
    new = read_range(path, off, MAX_CHUNK)
    parts.append(new)
    state[name] = {"inode": st.st_ino, "offset": off + len(new)}
    return b"".join(parts)


def spool_chunk(host, name, data):
    now = time.gmtime()
    rel = os.path.join(host, name, time.strftime("%Y", now), time.strftime("%m", now))
    d = os.path.join(STATE_DIR, "spool", rel)
    os.makedirs(d, exist_ok=True)
    fn = os.path.join(d, f"{name}-{host}-{time.strftime('%Y%m%dT%H%M%SZ', now)}.gz")
    tmp = fn + ".part"
    with gzip.open(tmp, "wb") as g:
        g.write(data)
    os.replace(tmp, fn)
    return fn


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", required=True)
    ap.add_argument("--rclone", default="rclone")
    ap.add_argument("--remote", default=REMOTE)
    ap.add_argument("--source", action="append", default=[], help="NAME=PATH")
    a = ap.parse_args()
    os.makedirs(STATE_DIR, exist_ok=True)

    lock = open(os.path.join(STATE_DIR, ".lock"), "w")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        print("another run is in progress"); return 0

    state_file = os.path.join(STATE_DIR, "state.json")
    try:
        state = json.load(open(state_file))
    except (OSError, ValueError):
        state = {}

    for spec in a.source:
        name, _, path = spec.partition("=")
        path = os.path.expanduser(path)
        try:
            data = collect(name, path, state)
        except OSError as e:
            log(f"{name}: cannot read {path}: {e}")
            continue
        if data:
            fn = spool_chunk(a.host, name, data)
            log(f"{name}: spooled {len(data):,} bytes -> {os.path.basename(fn)}")
        # Offset is saved only after the chunk is safely in the spool.
        tmp = state_file + ".tmp"
        json.dump(state, open(tmp, "w"))
        os.replace(tmp, state_file)

    spool = os.path.join(STATE_DIR, "spool")
    pending = [os.path.join(r, f) for r, _, fs in os.walk(spool) for f in fs if f.endswith(".gz")]
    if not pending:
        return 0
    rclone = os.path.expanduser(a.rclone)
    p = subprocess.run([rclone, "move", spool, a.remote, "--immutable", "--include", "*.gz",
                        "--log-level", "ERROR"], capture_output=True, text=True)
    if p.returncode == 0:
        log(f"uploaded {len(pending)} file(s) to {a.remote}")
    else:
        log(f"upload FAILED (rclone exit {p.returncode}), kept in spool: {p.stderr.strip()[-300:]}")
    return p.returncode


if __name__ == "__main__":
    sys.exit(main())
