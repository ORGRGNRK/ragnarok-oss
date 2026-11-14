#!/usr/bin/env python3
"""Pick the cartridge (a JSON file of prompt rules) that best matches a question.

Ported from alexus-core's `alexus` script (get_embedding, cosine_similarity, load_cartridges and the
routing gate in cmd_ask), without the Touch ID gate, the bridges, the fixed "verification" scripts or
the speed claims. Standard library only.

How it works, honestly:
  1. Each cartridge's domain + standards + description is turned into a vector by a local embedding
     model (nomic-embed-text on Ollama). This happens on every run (9 small calls); nothing is cached,
     so it takes as long as Ollama takes, usually well over 50 ms.
  2. The question is turned into a vector the same way and compared to each cartridge (cosine).
  3. Gate (numbers carried over from alexus-core; hand-picked, not measured on real questions):
       - below 0.45: ignored;
       - a cartridge is vetoed if the question mentions one of its negative_exclusions words;
       - the best remaining one is chosen only if it scores 0.52 or more;
       - others within 0.06 of the best are reported as "close", not used.
     If nothing passes, no cartridge is chosen. That is a normal answer, not an error.
Similarity only says the question *sounds like* the cartridge's topic. It says nothing about whether
the cartridge's rules are true; they are all marked UNVERIFIED.

Usage: python3 brain/lookup/lookup.py "question"      (BRAIN_OLLAMA_HOST, default http://127.0.0.1:11434)
"""
from __future__ import annotations

import ipaddress
import json
import math
import os
import sys
import urllib.request
from dataclasses import dataclass, field
from pathlib import Path
from urllib.parse import urlparse

CARTRIDGES_DIR = Path(__file__).resolve().parent.parent / "cartridges"
FLOOR, PRIMARY, MARGIN = 0.45, 0.52, 0.06
EMBED_MODEL = os.environ.get("BRAIN_EMBED_MODEL", "nomic-embed-text")


def ollama_host() -> str:
    host = (os.environ.get("BRAIN_OLLAMA_HOST") or os.environ.get("FIXLOOP_OLLAMA_HOST")
            or "http://127.0.0.1:11434").rstrip("/")
    if not is_local_url(host):
        raise SystemExit(f"BRAIN_OLLAMA_HOST must be this machine or your LAN (no cloud AI); got {host!r}")
    return host


def is_local_url(url: str) -> bool:
    host = (urlparse(url).hostname or "").lower()
    if host in ("localhost", "host.docker.internal") or host.endswith(".local"):
        return True
    try:
        ip = ipaddress.ip_address(host)
    except ValueError:
        return False
    return ip.is_loopback or ip.is_private


def post_json(path: str, body: dict, timeout: float = 120) -> dict:
    req = urllib.request.Request(ollama_host() + path, data=json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.loads(resp.read().decode())


def ollama_embed(text: str) -> list[float]:
    return post_json("/api/embed", {"model": EMBED_MODEL, "input": text}, timeout=60)["embeddings"][0]


def cosine(a: list[float], b: list[float]) -> float:
    dot = sum(x * y for x, y in zip(a, b))
    na, nb = math.sqrt(sum(x * x for x in a)), math.sqrt(sum(y * y for y in b))
    return dot / (na * nb) if na and nb else 0.0


def load_cartridges(directory: Path = CARTRIDGES_DIR) -> list[dict]:
    out = []
    for f in sorted(Path(directory).glob("*.json")):
        d = json.loads(f.read_text())
        d["_file"] = f.name
        out.append(d)
    return out


def topic_text(c: dict) -> str:
    return f"{c.get('domain', '')} {' '.join(c.get('standards', []))} {c.get('description', '')}"


@dataclass
class Pick:
    chosen: dict | None
    scores: list[tuple[float, str]] = field(default_factory=list)     # (similarity, id), best first
    vetoed: list[tuple[str, list[str]]] = field(default_factory=list)  # (id, words that triggered it)
    close: list[str] = field(default_factory=list)
    reason: str = ""


def pick(question: str, cartridges: list[dict], embed=ollama_embed) -> Pick:
    q = embed(question)
    scored = sorted(((cosine(q, embed(topic_text(c))), c) for c in cartridges), key=lambda t: t[0], reverse=True)
    res = Pick(chosen=None, scores=[(round(s, 4), c["id"]) for s, c in scored])
    ql = question.lower()
    approved = []
    for s, c in scored:
        if s < FLOOR:
            continue
        hits = [w for w in c.get("negative_exclusions", []) if w.lower() in ql or w.replace("_", " ").lower() in ql]
        if hits:
            res.vetoed.append((c["id"], hits))
            continue
        approved.append((s, c))
    if not approved:
        res.reason = f"no cartridge scored {FLOOR} or more (after vetoes)"
        return res
    top_s, top_c = approved[0]
    if top_s < PRIMARY:
        res.reason = f"best match {top_c['id']} scored {top_s:.3f}, below the {PRIMARY} bar"
        return res
    res.chosen = top_c
    res.close = [c["id"] for s, c in approved[1:] if s >= PRIMARY and top_s - s <= MARGIN]
    res.reason = f"{top_c['id']} scored {top_s:.3f}"
    return res


def main(argv: list[str]) -> int:
    if not argv:
        print(__doc__.strip().splitlines()[-1].strip())
        return 2
    question = " ".join(argv)
    p = pick(question, load_cartridges())
    print("scores:")
    for s, cid in p.scores:
        print(f"  {s:6.3f}  {cid}")
    for cid, words in p.vetoed:
        print(f"  vetoed {cid}: question mentions {words}")
    if not p.chosen:
        print(f"no cartridge chosen: {p.reason}")
        return 0
    c = p.chosen
    print(f"chosen: {c['id']} ({p.reason}){'; close: ' + ', '.join(p.close) if p.close else ''}")
    print(f"WARNING ({c.get('status', 'UNVERIFIED')}): {c.get('warning', '')}")
    for i, r in enumerate(c.get("knowledge_rules", []), 1):
        print(f"  [{i}] {r}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
