#!/usr/bin/env python3
"""
ragnarok-memories-refresh -- writes ~/.claude/memories-cache.json from the LIVE
Yggdrasil Memories table (Postgres on alexus, public."Memories").

WHY A CACHE. The turn envelope (ragnarok-turn-context.py) runs in front of every
prompt and must never wait on a network. It reads this file, and when the file
is older than its refresh age it starts this script DETACHED and renders what
it already has. So a dead tailnet means a stale memory block, never a stalled
turn -- the same rule the old recall-index.json cache followed.

READ ONLY. The query runs inside BEGIN READ ONLY as the database owner role; it
cannot write. Memories are written through the Yggdrasil MCP (create_records),
which receipts them -- never here.

On alexus it talks to the container directly; anywhere else it goes over ssh as
the `claude` user, the same path every other Mac -> alexus read takes.
"""
import json
import os
import socket
import subprocess
import sys
import time
from datetime import datetime

CACHE = os.environ.get("RAGNAROK_MEMORIES_CACHE", os.path.expanduser("~/.claude/memories-cache.json"))
HOST = os.environ.get("RAGNAROK_ALEXUS", "claude@alexus")

SQL = """BEGIN READ ONLY;
SELECT coalesce(json_agg(json_build_object(
  'id', id, 'type', "Type", 'name', "Name", 'description', "Description",
  'created', coalesce("Created_Date"::text, created_at::date::text),
  'updated', coalesce("Last_Updated"::text, updated_at::date::text)
) ORDER BY id), '[]'::json) FROM public."Memories";
COMMIT;
"""
PSQL = ("cd /tmp && sudo -u yggdrasil XDG_RUNTIME_DIR=/run/user/1000 "
        "podman exec -i ygg-staging-pg psql -U postgres -d yggdrasil -At -v ON_ERROR_STOP=1")


def on_alexus():
    return bool(__import__("glob").glob("/home/*/Yggdrasil-v2")) or socket.gethostname().lower().startswith("alexus")


def main():
    cmd = ["bash", "-c", PSQL] if on_alexus() else \
          ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5", HOST, PSQL]
    r = subprocess.run(cmd, input=SQL, capture_output=True, text=True, timeout=30)
    if r.returncode != 0:
        print("memories refresh failed: " + (r.stderr.strip()[-300:] or f"rc {r.returncode}"), file=sys.stderr)
        return 1
    # psql prints BEGIN / COMMIT around the one JSON line.
    rows = next(json.loads(l) for l in r.stdout.splitlines() if l.startswith("["))
    now = time.time()
    data = {"refreshed_epoch": now,
            "refreshed": datetime.now().astimezone().strftime("%Y-%m-%d %H:%M %Z"),
            "source": 'yggdrasil public."Memories" (Postgres, live)',
            "records": rows}
    os.makedirs(os.path.dirname(CACHE), exist_ok=True)
    tmp = CACHE + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(data, fh)
    os.replace(tmp, CACHE)
    print(f"memories cache: {len(rows)} records")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as e:
        print(f"memories refresh error: {e}", file=sys.stderr)
        sys.exit(1)
