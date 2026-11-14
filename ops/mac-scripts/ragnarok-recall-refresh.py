#!/usr/bin/env python3
"""
RAGNAROK recall index refresh — the CACHE half of turn-envelope slice 3.

WHY THIS EXISTS
  owner, 2026-08-26: "when you look for it it takes 1 pass for semantic recall
  and another pass to actually find it" -- "if you dont hit it directly first
  try."

  Retrieval is two passes. PASS 1 is knowing a thing EXISTS. PASS 2 is finding
  and reading it. RAGNAROK only ever built pass 2: every retrieval surface on
  this box (Airtable formulas, grep, crew doctor, the Write Log) assumes you
  already know what you are after. A missing pass 2 is visible -- you looked and
  came back empty. A missing pass 1 is INVISIBLE: you never looked, and nothing
  anywhere records a search that was never run.

  Worse, without pass 1 there is no search LOOP. One query, one word-shape, and
  a near-miss returns "nothing exists" with full confidence rather than "try
  different words." A session once grepped `mirror`/`mirroring`, missed
  packages/iphone-agent entirely, and told the owner no such project existed --
  twelve slices, live-verified on a real phone. The grep was competent. It just
  did not hit directly on the first try.

  Memories recpFqQlc5uVNwtwJ. Tracked at Reminders recBLMqfzIFg7iul8.

WHAT THIS IS
  The owner's design, 2026-08-26: "the boot will surface the semantics while the
  lane will surface the index every pass so it never gets lost."

  Two tiers, split by failure mode. Semantics are expensive and stable within a
  session, so boot buys them once. The INDEX is cheap and must never be absent,
  so the turn envelope re-injects it on every single pass -- which is what makes
  it survive context compaction and a ten-hour session. This script is the
  refresher; ragnarok-turn-context.py is the reader.

WHY A CACHE FILE AND NOT A LIVE READ
  The hook runs in front of EVERY prompt of EVERY Claude Code session on this
  box, and its own header states it makes no network call on purpose. Putting
  Airtable on that path would mean every turn degrades when Airtable is slow,
  behind a 5s timeout, including sessions that have nothing to do with RAGNAROK.
  So: this script talks to Airtable on a timer, the hook only ever reads a local
  file. Airtable down means a STALE index, never a stalled turn.

  Premise Check 2026-08-26: PROCEED WITH CHANGE -- the change is exactly this.

NAME ONLY, DELIBERATELY
  The cache carries id + Type + Name. NOT Description, NOT Content. Two reasons.
  (1) Pass 1 only has to establish that a thing EXISTS; these Names are already
  written as full summaries ("Staleness is DIRECTIONAL -- every un-maintained
  surface rots toward 'fine'"), so they do that job alone. (2) The Projection
  Rule (Session Boot Procedure v1.10) -- read the fields the output line prints
  and nothing else. Measured: Name+Type is ~7.2K chars; adding Description takes
  it past 12K, on every turn, for detail that is one call away.

VECTORS ARE NOT NEEDED YET, AND THAT IS A MEASUREMENT
  The owner asked whether the index should be one semantic vector. Right instinct,
  premature at this size: the whole index already fits in a turn, so top-k
  retrieval would add an embedding model, a service dependency on the hot path,
  and a new silent failure mode to buy nothing. Ollama on this box cannot embed
  today anyway (started without --embeddings; only llama3.2:3b and qwen2.5vl:3b
  are pulled). When the index outgrows the turn -- a few hundred records -- add
  a vector per record here and have the hook rank against the prompt. Same hook,
  same envelope, smarter list. Do not build it before the cost is real.

CREDENTIALS
  The Airtable PAT is read at RUNTIME from the airtable-mcp package .env, the
  same boundary dispatch-overseer uses. Nothing new stores it, and it is never
  written into the cache.
"""

import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

BASE = os.environ.get("AIRTABLE_BASE") or (lambda p: next((l.split("=", 1)[1].strip().strip("\"'") for l in (open(p).read().splitlines() if os.path.exists(p) else []) if l.strip().startswith("AIRTABLE_BASE=")), ""))(os.path.expanduser("~/.ragnarok/local.conf"))  # ~/.ragnarok/local.conf
MEMORIES = "tble5ZAxuPmcZMDUs"
ENV_FILE = os.path.expanduser("~/airtable-mcp/.env")
OUT = os.path.expanduser("~/.claude/recall-index.json")
TIMEOUT = 20


def pat():
    """Read the PAT from the package .env. Never printed, never cached."""
    try:
        with open(ENV_FILE, encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if line.startswith("AIRTABLE_PAT="):
                    return line.split("=", 1)[1].strip().strip("'\"")
    except OSError:
        pass
    return None


def fetch(token):
    """Page through Memories, projecting Name + Type only."""
    records, offset = [], None
    while True:
        params = [("fields[]", "Name"), ("fields[]", "Type"), ("pageSize", "100")]
        if offset:
            params.append(("offset", offset))
        url = f"https://api.airtable.com/v0/{BASE}/{MEMORIES}?" + urllib.parse.urlencode(params)
        req = urllib.request.Request(url, headers={"Authorization": f"Bearer {token}"})
        with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
            page = json.load(resp)
        for r in page.get("records", []):
            f = r.get("fields", {})
            name = (f.get("Name") or "").strip()
            if not name:
                continue  # an unnamed record cannot serve pass 1
            records.append({"id": r["id"], "type": (f.get("Type") or "?").strip(), "name": name})
        offset = page.get("offset")
        if not offset:
            break
    return records


def main():
    token = pat()
    if not token:
        # FAIL LOUDLY IN THE FILE, never silently. An absent index and a stale
        # index are different facts and the hook must be able to tell them apart
        # (Memories reca2bNBc67US1y3O -- unknowns render, never vanish).
        print(f"recall-refresh: no AIRTABLE_PAT in {ENV_FILE}", file=sys.stderr)
        return 1

    records = fetch(token)
    if not records:
        # Never overwrite a good cache with an empty one. A zero-record result is
        # far more likely to be a bad read than a truly empty Memories table, and
        # replacing a working index with nothing is the expensive direction.
        print("recall-refresh: 0 records returned — keeping existing cache", file=sys.stderr)
        return 1

    records.sort(key=lambda r: (r["type"].lower(), r["name"].lower()))
    payload = {
        "source": f"{BASE}/{MEMORIES}",
        "refreshed_epoch": int(time.time()),
        "refreshed": time.strftime("%Y-%m-%d %H:%M:%S %Z"),
        "count": len(records),
        "records": records,
    }

    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    tmp = OUT + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(payload, fh, ensure_ascii=False)
    os.replace(tmp, OUT)  # atomic: the hook never reads a half-written index
    print(f"recall-refresh: {len(records)} records -> {OUT}")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (urllib.error.URLError, urllib.error.HTTPError, OSError, ValueError) as exc:
        print(f"recall-refresh: {type(exc).__name__}: {exc}", file=sys.stderr)
        sys.exit(1)
