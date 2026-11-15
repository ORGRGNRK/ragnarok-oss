#!/usr/bin/env python3
"""memory.py -- Ragnarok's memory layer, from the command line (Mac).

Three layers (see db/memory.sql):
  core      the CURRENT Verified + Timeless facts, as a numbered title index that fits a hook (<10,000 chars)
  archival  every version of every fact with the dates it was true (memory.facts in data/'s Postgres)
  recall    past conversations and files: the nomic corpus (Heimdall corpus, scripts/recall/search-fast.py)

  memory.py core                      print the boot index (what a session should know exists)
  memory.py get KEY|ID                full text of one fact (current version), with its dates and status
  memory.py history KEY               every version of a fact: when it was true, who wrote it
  memory.py search "words" [-k N]     facts (by meaning) + recall (past chats/files), labelled by layer
  memory.py remember KEY "title" "body" [--kind K] [--desc D]   new or changed fact -> lands Unchecked
  memory.py set-status KEY Verified|Timeless|Stale|Unchecked     (a person; the checker retires failed facts)
  memory.py retire KEY                fact stopped being true: gets an end date, text kept
  memory.py import-ygg                Yggdrasil Memories (ygg-scratch copy) -> facts, keeping status + dates
  memory.py import-claude             Claude Code memory files -> facts (Unchecked, like every import)
  memory.py embed                     add nomic vectors for facts that have none
  memory.py stats
  memory.py import-words              the owner's own messages from Claude Code transcripts -> memory.words (+ vectors)
  memory.py words "about" [-k N]      his messages closest in meaning: how he actually says things
  memory.py check [--write]           run each fact's Checks on alexus: all pass -> Verified, any fail -> retired

Talks to Postgres with `docker exec` (admin login inside the container, nothing secret on a command line).
Embeddings: Ollama nomic-embed-text at MEMORY_EMBED_URL (default Alexus alexus:11434), the same
model and prefixes as the recall corpus ("search_document: " / "search_query: "), so the vectors agree.
"""
import argparse
import glob
import json
import os
import re
import subprocess
import sys
import urllib.request

# The databases live on Alexus (moved 2026-11-02). docker exec runs there over one shared ssh connection
# (ControlMaster keeps each call ~0.1 s). RAGNAROK_DB_SSH="" runs docker locally instead.
import shlex
_SSH = os.environ.get("RAGNAROK_DB_SSH", "ssh -o BatchMode=yes -o ConnectTimeout=5 -o ControlMaster=auto "
                      "-o ControlPath=~/.ragnarok/ssh-alexus-%C -o ControlPersist=600 alexus")
def _on_alexus(cmd):
    return shlex.split(_SSH) + [shlex.join(cmd)] if _SSH else cmd
PG = _on_alexus(["docker", "exec", "-i", "ragnarok-data-postgres-1", "psql", "-U", "kit_admin", "-d", "clientdata",
      "-X", "-q", "-At", "-v", "ON_ERROR_STOP=1"])
PG = json.loads(os.environ["MEMORY_PG"]) if os.environ.get("MEMORY_PG") else PG          # tests use a throwaway db
YGG = _on_alexus(["docker", "exec", "-i", "ygg-scratch-pg", "psql", "-U", "postgres", "-d", "ygg_ragnarok_core", "-X", "-q", "-At"])
EMBED_URL = os.environ.get("MEMORY_EMBED_URL", "http://alexus:11434/api/embed")   # Alexus, tailnet (new server 2026-11-10)
EMBED_MODEL = "nomic-embed-text"
RECALL_PY = os.path.expanduser("~/Developer/scripts/recall/.venv/bin/python")
RECALL_SEARCH = os.path.expanduser("~/Developer/scripts/recall/search-fast.py")
RECALL_CORPUS = os.path.expanduser("~/Library/Application Support/Heimdall/corpus/chunks.jsonl")
RECALL_EMBED_URL = os.environ.get("RECALL_EMBED_URL", "http://alexus:11434/v1/embeddings")
CLAUDE_MEM = os.path.expanduser("~/.claude/projects/*/memory")   # every Claude Code project, not just one
CORE_LIMIT = 9500          # Claude Code cuts hook text at 10,000 characters
ACTOR = os.environ.get("MEMORY_ACTOR", "memory.py (Claude Code, Mac yggdrasil)")
TAG = "$mem_q7Z$"


class Problem(Exception):
    pass


def lit(s):
    if s is None:
        return "NULL"
    s = str(s)
    if TAG in s:
        raise Problem("text contains the quoting tag")
    return TAG + s + TAG


def sql(q, side=None):
    p = subprocess.run(side or PG, input=q, capture_output=True, text=True, timeout=300)
    if p.returncode:
        raise Problem((p.stderr or p.stdout).strip()[:500])
    return p.stdout


def rows(q, side=None):
    out = sql(f"SELECT coalesce(json_agg(t), '[]') FROM ({q}) t;", side)
    return json.loads(out.strip() or "[]")


def embed(texts, prefix):
    body = json.dumps({"model": EMBED_MODEL, "input": [prefix + t for t in texts]}).encode()
    req = urllib.request.Request(EMBED_URL, body, {"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=120) as r:
        return json.load(r)["embeddings"]


def vec(v):
    return "[" + ",".join(f"{x:.6f}" for x in v) + "]"


def key_where(k):
    return f"id = {int(k)}" if str(k).isdigit() else f"fact_key = {lit(k)}"


# ------------------------------------------------------------------ layers

def core():
    """Boot index as compact JSON: one fact per line, full titles, nothing trimmed. Bodies are NOT here (get KEY)."""
    rs = rows("SELECT fact_key, title, kind, status, valid_from::date AS since, last_verified::date AS checked "
              "FROM memory.core ORDER BY kind NULLS LAST, id")
    head = {"what": "RAGNAROK memory core index: the facts that are Verified or Timeless right now",
            "how": "titles only; read a fact in full before relying on it: memory.py get KEY (or memory_get_fact)",
            "row": ["key", "title", "status V=Verified T=Timeless", "recorded"], "kind": "a {kind} line applies to the rows under it", "count": len(rs)}
    lines, kind = [json.dumps(head, ensure_ascii=False)], object()
    for r in rs:
        if r["kind"] != kind:
            kind = r["kind"]
            lines.append(json.dumps({"kind": kind}, ensure_ascii=False))
        lines.append(json.dumps([r["fact_key"], r["title"], r["status"][0], r["since"]], ensure_ascii=False))
    out = "\n".join(lines)
    if len(out) > CORE_LIMIT:
        raise Problem(f"core index is {len(out)} chars, over the {CORE_LIMIT} hook limit: retire or shorten titles")
    return out


ALEXUS_SSH = ["ssh", "-i", os.path.expanduser("~/.ssh/id_claude"), "-o", "IdentitiesOnly=yes", "-o", "BatchMode=yes",
              "-o", "ConnectTimeout=10", "claude@alexus", "bash -s"]
CHECK_ACTOR = "memory check (the owner's checker rules; run by Claude Code as Mac yggdrasil, ssh claude@alexus)"


def _probe_script(items):
    """bash for Alexus: one line per check, 'i<TAB>OK|FAIL|UNKNOWN<TAB>why'. Read-only: test -e, systemctl is-active, curl."""
    out = []
    for i, (kind, target) in enumerate(items):
        t = target.replace("'", "")
        if kind in ("path", "gitrepo"):
            sub = "/.git" if kind == "gitrepo" else ""
            out.append(f"p='{t}{sub}'; if [ -e \"$p\" ]; then echo '{i}\tOK\texists'; else d=$(dirname \"$p\"); "
                       f"while [ ! -e \"$d\" ]; do d=$(dirname \"$d\"); done; "
                       f"if [ -r \"$d\" ] && [ -x \"$d\" ]; then echo '{i}\tFAIL\tmissing'; else echo \"{i}\tUNKNOWN\tcannot read $d\"; fi; fi")
        elif kind == "unit" and t.startswith("system:"):
            out.append(f"s=$(systemctl is-active '{t[7:]}' 2>&1 | head -1); [ \"$s\" = active ] && echo '{i}\tOK\tactive' || echo \"{i}\tFAIL\t$s\"")
        elif kind == "url":
            out.append(f"c=$(curl -s -o /dev/null -m 5 -w %{{http_code}} '{t}'); case $c in 2*|3*|401|403) echo \"{i}\tOK\tHTTP $c\";; "
                       f"*) echo \"{i}\tFAIL\tHTTP $c\";; esac")
        else:
            out.append(f"echo '{i}\tUNKNOWN\tclaude cannot run a {kind} check on {t[:40]}'")
    return "\n".join(out) + "\n"


def check(write=False):
    """The owner's checker rule (memory-check, 2026-10-24; changed 2026-11-14): every check passes -> Verified;
    any check fails -> retired; a check that cannot be run -> status left alone. Timeless facts are not checked.
    Only checks aimed at alexus run (MacBook checks: not yet). --write applies; without it, a report."""
    facts = rows("SELECT fact_key, status, checks FROM memory.current WHERE status <> 'Timeless' AND checks IS NOT NULL ORDER BY id")
    items, owner = [], []
    for f in facts:
        for line in re.split(r"[\n;]", f["checks"]):
            m = re.match(r"^\s*(path|gitrepo|unit|url)\s+(\S+)\s*$", line)
            if not m:
                continue
            kind, target = m.groups()
            if kind == "url":
                items.append((kind, target)); owner.append(f["fact_key"])
            elif target.startswith("alexus:"):
                items.append((kind, target[len("alexus:"):])); owner.append(f["fact_key"])
    if not items:
        return "nothing to check"
    p = subprocess.run(ALEXUS_SSH, input=_probe_script(items), capture_output=True, text=True, timeout=300)
    res = {}
    for line in p.stdout.splitlines():
        parts = line.split("\t", 2)
        if len(parts) == 3 and parts[0].isdigit():
            res[int(parts[0])] = (parts[1], parts[2])
    if not res:
        raise Problem("could not reach alexus: " + (p.stderr or "no output").strip()[:200])
    by = {}
    for i, (kind, target) in enumerate(items):
        by.setdefault(owner[i], []).append((kind, target) + res.get(i, ("UNKNOWN", "no answer")))
    out, changes = [], []
    for f in facts:
        r = by.get(f["fact_key"])
        if not r:
            continue
        verdicts = {x[2] for x in r}
        new = "Stale" if "FAIL" in verdicts else ("Verified" if verdicts == {"OK"} else None)
        out.append(f"{f['fact_key']} [{f['status']}] -> {new or 'left alone'}: " +
                   "; ".join(f"{k} {t} {v}{'' if v == 'OK' else ' (' + w + ')'}" for k, t, v, w in r))
        if new and new != f["status"]:
            changes.append((f["fact_key"], new))
    if write and changes:
        # A fact whose check fails is retired (gone from search and core, text kept with an end date),
        # not left lying around as Stale. the owner, 2026-11-14: "why dont you delete it when it goes stale".
        sql("BEGIN;\n" + "\n".join(
            f"SELECT memory.retire({lit(k)}, {lit(CHECK_ACTOR)});" if s == "Stale" else
            f"SELECT memory.set_status({lit(k)}, {lit(s)}, {lit(CHECK_ACTOR)});" for k, s in changes) + "\nCOMMIT;")
    out.append(f"{len(changes)} status change(s) " + ("WRITTEN" if write else "proposed (run with --write to apply)") + ": " +
               ", ".join(f"{k}->{s}" for k, s in changes))
    return "\n".join(out)


ARM_FLOOR, ARM_MARGIN, ARM_MAX, ARM_BUDGET = 0.65, 0.04, 3, 6000   # tuned 11-02 on memory-arm-cases.json (9 real prompts)


def arm(prompt):
    """Cartridge-style routing (agents/alexus-core `cmd_ask`): score every current fact against THIS prompt,
    arm the top one only if it clears the floor, plus others within the margin of it, and inject just those in full.
    Only Verified/Timeless facts are armed (the owner's boot rule); Unchecked matches are named, not loaded.
    Floor/margin: 0.60/0.06 armed off-topic facts at 0.61-0.64 in real use (11-02); 0.65/0.04 passes all 9 cases
    in scripts/memory-arm-cases.json. Re-run `memory.py arm-eval` after changing them or re-embedding."""
    qv = vec(embed([prompt], "search_query: ")[0])
    rs = rows(f"""SELECT f.fact_key, f.title, f.status, f.body, f.valid_from::date AS recorded,
                         (1 - (v.embedding <=> {lit(qv)}::vector)) AS s
                  FROM memory.fact_vectors v JOIN memory.facts f ON f.id = v.fact_id
                  WHERE f.valid_to IS NULL ORDER BY s DESC LIMIT 12""")
    if not rs or rs[0]["s"] < ARM_FLOOR:
        return ""
    top = rs[0]["s"]
    hits = [r for r in rs if r["s"] >= ARM_FLOOR and top - r["s"] <= ARM_MARGIN]
    armed = [r for r in hits if r["status"] in ("Verified", "Timeless")][:ARM_MAX]
    skipped = [r["fact_key"] for r in hits if r["status"] not in ("Verified", "Timeless")][:3]
    out, used = ["RAGNAROK memory armed for this prompt (matched by meaning; full text):" if armed
                 else "RAGNAROK memory: no checked fact matched this prompt strongly enough to load."], 0
    for r in armed:
        body = r["body"] if used + len(r["body"]) <= ARM_BUDGET else r["body"][:max(0, ARM_BUDGET - used)] + " [cut: memory.py get]"
        used += len(body)
        out.append(f"\n## {r['fact_key']} [{r['status']}, recorded {r['recorded']}, match {r['s']:.2f}] {r['title']}\n{body}")
    if skipped:
        out.append("\nAlso matched but Unchecked/Stale (not loaded; open only if needed): " + ", ".join(skipped))
    return "\n".join(out) if armed or skipped else ""


def armed_keys(prompt):
    return re.findall(r"^## (\S+) \[", arm(prompt), re.M)


def arm_eval():
    cases = json.load(open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "memory-arm-cases.json")))["cases"]
    bad, out = 0, []
    for c in cases:
        got = armed_keys(c["prompt"])
        ok = sorted(got) == sorted(c["arm"])
        bad += not ok
        out.append(f"{'ok  ' if ok else 'MISS'} {c['prompt'][:50]!r}: want {c['arm']} got {got}")
    out.append(f"{len(cases) - bad}/{len(cases)} cases right (floor {ARM_FLOOR}, margin {ARM_MARGIN}, max {ARM_MAX})")
    return "\n".join(out)


def get(k):
    rs = rows(f"SELECT * FROM memory.facts WHERE {key_where(k)} ORDER BY (valid_to IS NULL) DESC, version DESC LIMIT 1")
    if not rs:
        raise Problem(f"no fact {k}")
    r = rs[0]
    when = f"true from {r['valid_from'][:10]}" + (f" to {r['valid_to'][:10]} (NOT current)" if r["valid_to"] else ", current")
    out = [f"{r['fact_key']} v{r['version']} [{r['status']}] {r['title']}",
           f"{when}; source: {r['source']}; written by: {r['actor']}"
           + (f"; last verified {r['last_verified'][:10]}" if r["last_verified"] else "")]
    if r["description"]:
        out.append(r["description"])
    out += ["", r["body"]]
    if r["checks"]:
        out += ["", "Checks: " + r["checks"]]
    return "\n".join(out)


def history(k):
    rs = rows(f"SELECT id, version, status, title, valid_from, valid_to, actor, source FROM memory.facts "
              f"WHERE fact_key = {lit(k)} ORDER BY version")
    if not rs:
        raise Problem(f"no fact {k}")
    return "\n".join(f"v{r['version']} #{r['id']} [{r['status']}] {r['valid_from'][:16]} -> "
                     f"{(r['valid_to'] or 'now')[:16]}  {r['title'][:70]}  ({r['actor']})" for r in rs)


def search(q, k=6):
    out = []
    try:
        qv = embed([q], "search_query: ")[0]
        facts = rows(f"""SELECT f.fact_key, f.title, f.status, left(coalesce(f.description, f.body), 220) AS gist,
                                round((1 - (v.embedding <=> {lit(vec(qv))}::vector))::numeric, 3) AS score
                         FROM memory.fact_vectors v JOIN memory.facts f ON f.id = v.fact_id
                         WHERE f.valid_to IS NULL ORDER BY v.embedding <=> {lit(vec(qv))}::vector LIMIT {int(k)}""")
        out.append("== facts (archival, current versions)")
        out += [f"{r['score']}  {r['fact_key']} [{r['status']}] {r['title']}\n       {r['gist']}" for r in facts] or ["(none)"]
    except Exception as e:
        out.append(f"== facts: could not search ({str(e)[:150]})")
    if os.path.exists(RECALL_PY) and os.path.exists(RECALL_CORPUS):
        p = subprocess.run([RECALL_PY, "-I", RECALL_SEARCH, RECALL_CORPUS, q, str(k)], capture_output=True, text=True,
                           timeout=60, env=dict(os.environ, RECALL_EMBED_URL=RECALL_EMBED_URL))
        try:
            hits = json.loads(p.stdout)["hits"]
            out.append("== recall (past chats and files)")
            out += ["%s  %s\n       %s" % (h["score"], h.get("name") or h.get("rec"), " ".join(h["text"].split())[:220])
                    for h in hits]
        except Exception:
            out.append(f"== recall: could not search ({(p.stderr or p.stdout).strip()[:150]})")
    else:
        out.append("== recall: corpus not on this machine")
    return "\n".join(out)


# ------------------------------------------------------------------ writing

def remember(k, title, body, kind=None, desc=None):
    fid = sql(f"SELECT memory.remember({lit(k)}, {lit(title)}, {lit(body)}, {lit(kind)}, {lit(desc)}, 'cli', {lit(ACTOR)});").strip()
    embed_missing()
    return fid


def set_status(k, status):
    return sql(f"BEGIN; SELECT memory.set_status({lit(k)}, {lit(status)}, {lit(ACTOR)}); COMMIT;").strip().splitlines()[-1]


def retire(k):
    return sql(f"BEGIN; SELECT memory.retire({lit(k)}, {lit(ACTOR)}); COMMIT;").strip().splitlines()[-1]


def import_rows(items, actor):
    """items: dicts with key,title,kind,desc,body,status,checks,last_verified,valid_from,source"""
    stmts = ["BEGIN;"]
    for it in items:
        stmts.append("SELECT memory.import_fact(" + ", ".join(lit(it.get(f)) for f in
                     ("key", "title", "kind", "desc", "body", "status", "checks", "last_verified", "valid_from", "source"))
                     + f", {lit(actor)});")
    stmts.append("COMMIT;")
    before = rows("SELECT count(*) AS n FROM memory.facts")[0]["n"]
    sql("\n".join(stmts))
    after = rows("SELECT count(*) AS n FROM memory.facts")[0]["n"]
    return after - before


def import_ygg():
    src = rows('SELECT id, "Name", "Type", "Description", "Content", "Status", "Checks", "Last_Verified", '
               '"Created_Date", created_at FROM "Memories" ORDER BY id', YGG)
    items = []
    for r in src:
        body = (r["Content"] or r["Description"] or "").strip()
        if not body:
            continue
        items.append({"key": f"ygg:{r['id']}", "title": (r["Name"] or f"Memory {r['id']}").strip(), "kind": r["Type"],
                      "desc": r["Description"], "body": body, "status": r["Status"] or "Unchecked",
                      "checks": r["Checks"], "last_verified": r["Last_Verified"],
                      "valid_from": r["Created_Date"] or r["created_at"],
                      "source": f"ygg_ragnarok_core.Memories#{r['id']} (ygg-scratch copy of Alexus rehearsal, dump 2026-10-28)"})
    n = import_rows(items, "import-ygg: " + ACTOR)
    embed_missing()
    return f"read {len(src)} Yggdrasil memories, {len(items)} with text; {n} new fact versions written (unchanged ones skipped)"


def import_claude():
    items = []
    for p in sorted(glob.glob(os.path.join(CLAUDE_MEM, "*.md"))):
        if os.path.basename(p) == "MEMORY.md":
            continue
        t = open(p).read()
        m = re.match(r"^---\n(.*?)\n---\n(.*)$", t, re.S)
        meta, body = (m.group(1), m.group(2).strip()) if m else ("", t.strip())
        g = lambda f: (re.search(rf"^\s*{f}:\s*(.+)$", meta, re.M) or [None, None])[1]
        name = (g("name") or os.path.basename(p)[:-3]).strip().strip('"')
        desc = (g("description") or "").strip().strip('"')
        items.append({"key": f"claude:{name}", "title": desc or name, "kind": (g("type") or "").strip() or None,
                      "desc": desc, "body": body, "status": "Unchecked", "checks": None, "last_verified": None,
                      "valid_from": None, "source": f"Claude Code memory file {p.replace(os.path.expanduser('~'), '~')}"})
    n = import_rows(items, "import-claude: " + ACTOR)
    embed_missing()
    return f"read {len(items)} Claude Code memory files; {n} new fact versions written (unchanged ones skipped)"


WORD_SKIP = re.compile(r"^(<command-|<local-command|<bash-|<system-reminder>|<task-notification>|Stop hook feedback|Caveat:|"
                       r"\[Request interrupted|This session is being continued|Base directory for this skill|<user-prompt-submit-hook>|# |\[Image)")


def _claude_words():
    """The owner's own typed messages from Claude Code transcripts: user turns only, no tool results, hook/skill/system
    text, compaction summaries or pasted blocks (those are not his words); over 2,000 chars skipped (pastes)."""
    import hashlib
    out, seen = [], set()
    for p in sorted(glob.glob(os.path.expanduser("~/.claude/projects/*/*.jsonl"))):
        project = os.path.basename(os.path.dirname(p))
        for line in open(p, errors="replace"):
            try:
                r = json.loads(line)
            except ValueError:
                continue
            if r.get("type") != "user" or r.get("isMeta") or r.get("isCompactSummary") or r.get("toolUseResult") is not None:
                continue
            c = r.get("message", {}).get("content")
            parts = [c] if isinstance(c, str) else [x.get("text", "") for x in c or [] if isinstance(x, dict) and x.get("type") == "text"]
            for t in parts:
                t = re.sub(r"<pasted_content.*?</pasted_content>", "", t, flags=re.S)
                t = re.sub(r"<system-reminder>.*?</system-reminder>", "", t, flags=re.S).strip()
                if not t or WORD_SKIP.match(t) or len(t) > 2000 or not r.get("timestamp"):
                    continue
                h = hashlib.md5(t.encode()).hexdigest()
                if h in seen:
                    continue
                seen.add(h)
                out.append({"said_at": r["timestamp"], "text": t, "session": r.get("sessionId"), "project": project, "hash": h})
    return out


def import_words(batch=32):
    items = _claude_words()
    have = {r["text_hash"] for r in rows("SELECT text_hash FROM memory.words")}
    new = [w for w in items if w["hash"] not in have]
    for i in range(0, len(new), 200):
        sql("BEGIN;\n" + "\n".join(
            f"INSERT INTO memory.words (said_at, text, source, session, project, text_hash) VALUES ({lit(w['said_at'])}, {lit(w['text'])}, "
            f"'claude-code', {lit(w['session'])}, {lit(w['project'])}, {lit(w['hash'])}) ON CONFLICT (text_hash) DO NOTHING;"
            for w in new[i:i + 200]) + "\nCOMMIT;")
    todo = rows("SELECT w.id, w.text FROM memory.words w LEFT JOIN memory.word_vectors v ON v.word_id = w.id WHERE v.word_id IS NULL ORDER BY w.id")
    done = 0
    for i in range(0, len(todo), batch):
        part = todo[i:i + batch]
        try:
            vs = embed([r["text"][:4000] for r in part], "search_document: ")
        except Exception as e:
            return f"found {len(items)} messages, {len(new)} new; embedded {done}, embedder unreachable ({str(e)[:80]}): run again"
        sql("BEGIN;\n" + "\n".join(f"INSERT INTO memory.word_vectors (word_id, embedding, embed_model) VALUES ({r['id']}, "
                                   f"{lit(vec(v))}::vector, {lit(EMBED_MODEL)}) ON CONFLICT (word_id) DO NOTHING;" for r, v in zip(part, vs)) + "\nCOMMIT;")
        done += len(part)
    return f"found {len(items)} of the owner's messages, {len(new)} new; embedded {done}"


def search_words(q, k=8):
    qv = vec(embed([q], "search_query: ")[0])
    rs = rows(f"""SELECT w.said_at::date AS d, w.text, round((1 - (v.embedding <=> {lit(qv)}::vector))::numeric, 3) AS s
                  FROM memory.word_vectors v JOIN memory.words w ON w.id = v.word_id
                  ORDER BY v.embedding <=> {lit(qv)}::vector LIMIT {int(k)}""")
    return "\n".join(f"{r['s']}  {r['d']}  {' '.join(r['text'].split())[:200]}" for r in rs) or "(no words yet)"


def embed_missing(batch=16):
    todo = rows("SELECT f.id, f.title, coalesce(f.description, '') AS d, f.body FROM memory.facts f "
                "LEFT JOIN memory.fact_vectors v ON v.fact_id = f.id WHERE v.fact_id IS NULL ORDER BY f.id")
    done = 0
    for i in range(0, len(todo), batch):
        part = todo[i:i + batch]
        try:
            vs = embed([f"{r['title']}\n{r['d']}\n{r['body']}"[:6000] for r in part], "search_document: ")
        except Exception as e:
            return f"embedded {done}; embedder unreachable ({str(e)[:100]}), rest later"
        sql("BEGIN;\n" + "\n".join(
            f"INSERT INTO memory.fact_vectors (fact_id, embedding, embed_model) VALUES ({r['id']}, {lit(vec(v))}::vector, "
            f"{lit(EMBED_MODEL)}) ON CONFLICT (fact_id) DO UPDATE SET embedding = EXCLUDED.embedding, updated_at = now();"
            for r, v in zip(part, vs)) + "\nCOMMIT;")
        done += len(part)
    return f"embedded {done}"


def stats():
    r = rows("""SELECT count(*) FILTER (WHERE valid_to IS NULL) AS current, count(*) AS versions,
                       count(*) FILTER (WHERE valid_to IS NULL AND status='Verified') AS verified,
                       count(*) FILTER (WHERE valid_to IS NULL AND status='Timeless') AS timeless,
                       count(*) FILTER (WHERE valid_to IS NULL AND status='Unchecked') AS unchecked,
                       count(*) FILTER (WHERE valid_to IS NULL AND status='Stale') AS stale,
                       (SELECT count(*) FROM memory.fact_vectors) AS vectors FROM memory.facts""")[0]
    return (f"facts: {r['current']} current ({r['verified']} Verified, {r['timeless']} Timeless, {r['unchecked']} Unchecked, "
            f"{r['stale']} Stale), {r['versions']} versions in all, {r['vectors']} with vectors; "
            f"core index {len(core())} chars (limit {CORE_LIMIT})")


def main(argv=None):
    ap = argparse.ArgumentParser(description="Ragnarok memory layer")
    sp = ap.add_subparsers(dest="cmd", required=True)
    for c in ("core", "import-ygg", "import-claude", "embed", "stats", "arm-eval"):
        sp.add_parser(c)
    sp.add_parser("arm").add_argument("prompt", nargs="?")
    sp.add_parser("check").add_argument("--write", action="store_true")
    sp.add_parser("import-words")
    s = sp.add_parser("words"); s.add_argument("query"); s.add_argument("-k", type=int, default=8)
    for c in ("get", "history", "retire"):
        sp.add_parser(c).add_argument("key")
    s = sp.add_parser("search"); s.add_argument("query"); s.add_argument("-k", type=int, default=6)
    s = sp.add_parser("remember"); s.add_argument("key"); s.add_argument("title"); s.add_argument("body")
    s.add_argument("--kind"); s.add_argument("--desc")
    s = sp.add_parser("set-status"); s.add_argument("key"); s.add_argument("status", choices=["Verified", "Timeless", "Stale", "Unchecked"])
    a = ap.parse_args(argv)
    try:
        out = {"core": core, "import-ygg": import_ygg, "import-claude": import_claude, "embed": embed_missing,
               "stats": stats, "arm-eval": arm_eval}.get(a.cmd)
        if out:
            print(out())
        elif a.cmd == "import-words":
            print(import_words())
        elif a.cmd == "words":
            print(search_words(a.query, a.k))
        elif a.cmd == "check":
            print(check(a.write))
        elif a.cmd == "arm":
            # as a UserPromptSubmit hook: prompt arrives as JSON on stdin; any failure = say nothing, never block
            try:
                text = a.prompt or json.load(sys.stdin).get("prompt", "")
                print(arm(text) if text.strip() else "", end="")
            except Exception:
                pass
        elif a.cmd == "get":
            print(get(a.key))
        elif a.cmd == "history":
            print(history(a.key))
        elif a.cmd == "retire":
            print("retired #" + retire(a.key))
        elif a.cmd == "search":
            print(search(a.query, a.k))
        elif a.cmd == "remember":
            print("saved #" + remember(a.key, a.title, a.body, a.kind, a.desc) + " (Unchecked until checked)")
        elif a.cmd == "set-status":
            print("updated #" + set_status(a.key, a.status))
    except Problem as e:
        print(f"memory: {e}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
