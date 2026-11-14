#!/usr/bin/env python3
"""Summarize catalog scripts with the local Ollama model (strict JSON). Usage:
   summarize.py --pilot            # 8 varied scripts
   summarize.py --ids 1,2,3        # specific scripts
   summarize.py --all [--limit N]  # every non-excluded script without a valid v3 summary for its current body
Phase 2 (prompt v3): code-extracted facts (script_facts) and code-derived links (script_links) go into the prompt so
the model describes instead of guessing. Bodies over MAX_CHARS are sent as head + tail and flagged truncated.
Resumable: --all skips scripts that already have a valid v3 summary for their current content_hash.
Every call is appended to LOG (jsonl) and to change_log."""
import json, re, sys, time, urllib.request, urllib.error, argparse, os, fcntl
import pg

OLLAMA = os.environ.get("OLLAMA_URL", "http://alexus:11434")
PROMPT_VERSION = "v3"
MAX_CHARS = 12000
HEAD, TAIL = 8000, 3500
LOG = os.environ.get("SC_LOG", os.path.join(os.path.dirname(os.path.abspath(__file__)), "data", "summarize.log.jsonl"))
KEYS = ["name", "purpose", "inputs", "outputs", "dependencies", "side_effects", "risk", "reuse_notes", "pipes_into"]
SCHEMA = {"type": "object", "required": KEYS, "properties": {
    "name": {"type": "string"}, "purpose": {"type": "string"},
    "inputs": {"type": "array", "items": {"type": "string"}}, "outputs": {"type": "array", "items": {"type": "string"}},
    "dependencies": {"type": "array", "items": {"type": "string"}}, "side_effects": {"type": "array", "items": {"type": "string"}},
    "risk": {"type": "string", "enum": ["none", "low", "medium", "high"]}, "reuse_notes": {"type": "string"},
    "pipes_into": {"type": "array", "items": {"type": "string"}}}}
SYSTEM = """You catalog scripts so their owner can reuse them instead of rewriting them.
Read the script and reply with ONLY a JSON object with exactly these keys:
name: short kebab-case name for what it does.
purpose: one sentence, specific (what system/data it touches).
inputs: what it actually reads, each item specific: "arg --foo", "env FOO_URL", "file ~/x.json", "stdin lines", "API: Airtable", "Postgres table x". Leave out categories it does not use.
outputs: what it actually produces, each item specific: "stdout: JSON report", "file out.csv", "Postgres table x updated", "POST to Slack", "iMessage".
dependencies: tools, libraries, services it needs.
side_effects: EVERY effect beyond printing: modifies or deletes files, runs remote commands over ssh, shuts down/reboots machines, sends messages/emails, network writes, git push, changes system config, installs software, spends money. [] only if it just reads and prints.
risk: none (read-only), low (writes its own files), medium (edits existing files, network writes, messages), high (deletes data, shutdowns, system config, money, irreversible).
reuse_notes: one or two sentences: how to reuse it and what to parameterize.
pipes_into: concrete chains based on ITS real outputs, e.g. which kind of script or model could consume them; [] if its output is not machine-usable.
Secrets were replaced with [REDACTED]; never guess them. Be factual; do not invent behavior that is not in the code.

You are also given FACTS that a static analyzer extracted from the code (CLI args, env vars, files, network calls,
destructive commands, DB tables, APIs, served endpoints) and LINKS to other catalog scripts found by matching files,
tables and endpoints. Rules:
- inputs and outputs must come from the FACTS or from lines you can point to in the code. If FACTS list no CLI args,
  env vars, files or stdin, do not invent them. Never write generic items like "CLI args" or "env vars"; name them.
- side_effects must include every destructive command listed in FACTS that the script really runs (skip ones that are only
  in messages/strings), plus network writes and remote ssh commands.
- pipes_into: use the LINKS ("feeds ...") when present, naming the script; otherwise describe a concrete consumer of its
  real output, or [].
- Do not copy wording from these instructions; describe this script."""
EMAIL = re.compile(r"[\w.+-]+@(?![\d.]+\b)[\w-]+(?:\.[\w-]+)*\.[A-Za-z]{2,}")
PHONE = re.compile(r"\+?1?[\s\-.(]*\d{3}[\s\-.)]*\d{3}[\s\-.]*\d{4}\b")

def pick_model():
    tags = json.load(urllib.request.urlopen(OLLAMA + "/api/tags", timeout=10))["models"]
    names = [m["name"] for m in tags]
    for pref in ("qwen2.5-coder:7b", "qwen2.5:7b", "qwen2.5:3b"):
        if pref in names: return pref
    raise SystemExit("no suitable model")

def validate(obj):
    if not isinstance(obj, dict): return "not an object"
    missing = [k for k in KEYS if k not in obj]
    if missing: return "missing " + ",".join(missing)
    for k in ("inputs", "outputs", "dependencies", "side_effects", "pipes_into"):
        if not isinstance(obj[k], list): return k + " not a list"
    if obj["risk"] not in ("none", "low", "medium", "high"): return "bad risk"
    if not str(obj["purpose"]).strip(): return "empty purpose"
    return None

def facts_text(fx):
    if not fx: return "(none extracted)"
    out = []
    for k in ("cli_args", "stdin", "env_vars", "files_read", "files_written", "files_modified", "databases", "tables_read",
              "tables_written", "apis", "serves", "invokes", "commands_run", "embedded_code", "stdout"):
        v = fx.get(k)
        if v: out.append(f"{k}: " + "; ".join(json.dumps(x) if isinstance(x, dict) else str(x) for x in v[:25]))
    for n in fx.get("network", [])[:20]:
        out.append("network: " + ", ".join(f"{a}={b}" for a, b in n.items() if b is not None))
    for d in fx.get("destructive", [])[:20]:
        out.append(f"destructive line {d['line']}: {d['cmd']} ({d['level']}): {d['text'][:110]}")
    if fx.get("risk_code"): out.append(f"code-detected risk floor: {fx['risk_code']} ({', '.join(fx.get('risk_reasons', [])) or 'nothing found'})")
    return "\n".join(out) or "(none extracted)"

def links_text(sid):
    rows = pg.rows(f"""SELECT l.link_kind, l.src_id, l.dst_id, l.reason, l.confidence,
        coalesce(regexp_replace(a.path, '^.*/', ''), 'chat script #' || a.id) AS a_name, coalesce(regexp_replace(b.path, '^.*/', ''), 'chat script #' || b.id) AS b_name
        FROM script_links l JOIN scripts a ON a.id = l.src_id JOIN scripts b ON b.id = l.dst_id
        WHERE l.link_kind IN ('chain','invokes') AND {sid} IN (l.src_id, l.dst_id) ORDER BY l.confidence DESC LIMIT 12""")
    out = []
    for r in rows:
        if r["link_kind"] == "chain":
            out.append((f"feeds {r['b_name']} (#{r['dst_id']})" if r["src_id"] == sid else f"is fed by {r['a_name']} (#{r['src_id']})") + f": {r['reason']} [confidence {r['confidence']}]")
        else:
            out.append(f"runs {r['b_name']} (#{r['dst_id']})" if r["src_id"] == sid else f"is run by {r['a_name']} (#{r['src_id']})")
    return "\n".join(out) or "(none found)"

def _in_code(tok, body):
    if tok in body: return True
    if tok.startswith("-"):  # model wrote --flag for -flag, or a UserDefaults/argparse key
        n = tok.lstrip("-")
        return ("-" + n) in body or f'"{n}"' in body or f"'{n}'" in body
    return False

def ground(obj, body):
    """Drop input/output items that name a flag, env var or file path not present in the code. Returns dropped items."""
    dropped = []
    for key in ("inputs", "outputs"):
        keep = []
        for it in obj.get(key, []):
            s = str(it); toks = []
            m = re.match(r"(?i)^\s*(?:arg|flag|option)s?\s*:?\s*(-{1,2}[\w-]+)", s)
            if m: toks.append(m.group(1))
            m = re.match(r"(?i)^\s*env(?:ironment)?(?: var(?:iable)?)?s?\s*:?\s*\$?([A-Z][A-Z0-9_]+)", s)
            if m: toks.append(m.group(1))
            m = re.match(r"(?i)^\s*file\s*:?\s*([~/.\w$][^\s,;()]*\.\w+|[~/][^\s,;()]+)", s)
            if m: toks.append(m.group(1).lstrip("~").split("/")[-1] or m.group(1))
            if toks and not all(_in_code(t, body) for t in toks): dropped.append({"field": key, "item": s})
            else: keep.append(it)
        obj[key] = keep
    return dropped

def mask_pii(t): return PHONE.sub("[PHONE]", EMAIL.sub("[EMAIL]", t))

def log(rec):
    os.makedirs(os.path.dirname(LOG), exist_ok=True)
    with open(LOG, "a") as fh: fh.write(json.dumps(rec) + "\n")

def call(model, user):
    body = {"model": model, "stream": False, "format": SCHEMA, "keep_alive": "10m",
            "options": {"temperature": 0.1, "num_ctx": 8192, "num_predict": 700},
            "messages": [{"role": "system", "content": SYSTEM}, {"role": "user", "content": user}]}
    req = urllib.request.Request(OLLAMA + "/api/chat", data=json.dumps(body).encode(), headers={"Content-Type": "application/json"})
    t = time.time()
    r = json.load(urllib.request.urlopen(req, timeout=600))
    return r["message"]["content"], int((time.time() - t) * 1000), r

def summarize(model, s, run_label):
    sid, lang, path, kind, project, body, chash = (s[k] for k in ('id','language','path','kind','project','body_redacted','content_hash'))
    fx = s.get("facts")
    if isinstance(fx, str): fx = json.loads(fx)
    body = mask_pii(body)
    trunc = len(body) > MAX_CHARS
    if trunc:
        body = body[:HEAD] + f"\n\n... [{len(body) - HEAD - TAIL} characters omitted; FACTS cover the whole file] ...\n\n" + body[-TAIL:]
    user = (f"Language: {lang}\nPath: {path or '(none, from a chat)'}\nProject: {project}\nKind: {kind}\n"
            f"{'NOTE: the code below is truncated (head and tail only).' if trunc else ''}\n\n"
            f"FACTS (static analysis of the full script):\n{mask_pii(facts_text(fx))}\n\nLINKS to other catalog scripts:\n{links_text(sid)}\n\n"
            f"```{lang}\n{body}\n```")
    attempts, total_ms, obj, raw, err = 0, 0, None, "", None
    for _ in range(2):
        attempts += 1
        for wait in (0, 30, 120, 300):          # Ollama down/restarting: wait instead of recording junk
            if wait: time.sleep(wait)
            try:
                raw, ms, meta = call(model, user); total_ms += ms; neterr = None; break
            except (urllib.error.URLError, ConnectionError, TimeoutError) as e:
                neterr = f"{type(e).__name__}: {e}"
        if neterr: raise SystemExit(f"Ollama unreachable, stopping (resumable): {neterr}")
        try:
            obj = json.loads(raw); err = validate(obj)
        except Exception as e:
            err = f"{type(e).__name__}: {e}"; obj = None
        if not err: break
        user += "\n\nYour previous reply was invalid (" + str(err)[:200] + "). Reply with ONLY the JSON object."
    ok = err is None
    o = obj if ok else {}
    ung = ground(o, s["body_redacted"]) if ok else []
    j = lambda v: pg.lit(json.dumps(v)) + "::jsonb"
    fv = s.get("facts_version")
    pg.run(f"""BEGIN;
INSERT INTO summaries(script_id,content_hash,model,prompt_version,name,purpose,inputs,outputs,dependencies,side_effects,risk,reuse_notes,pipes_into,raw_reply,valid_json,attempts,latency_ms,run_label,truncated,facts_version,input_chars,ungrounded)
VALUES({sid},{pg.lit(chash)},{pg.lit(model)},{pg.lit(PROMPT_VERSION)},{pg.lit(o.get('name'))},{pg.lit(o.get('purpose'))},{j(o.get('inputs'))},{j(o.get('outputs'))},{j(o.get('dependencies'))},{j(o.get('side_effects'))},{pg.lit(o.get('risk'))},{pg.lit(o.get('reuse_notes'))},{j(o.get('pipes_into'))},{pg.lit(raw)},{pg.lit(ok)},{attempts},{total_ms},{pg.lit(run_label)},{pg.lit(trunc)},{pg.lit(fv)},{len(user)},{j(ung)});
INSERT INTO change_log(actor,action,script_id,ok,detail) VALUES('grok-bot','summarize',{sid},{pg.lit(ok)},{j({'model': model, 'prompt': PROMPT_VERSION, 'ms': total_ms, 'attempts': attempts, 'truncated': trunc, 'error': err, 'run': run_label, 'ungrounded_dropped': len(ung)})});
COMMIT;""")
    log({"ts": time.strftime("%Y-%m-%dT%H:%M:%S%z"), "id": sid, "ok": ok, "ms": total_ms, "attempts": attempts, "truncated": trunc,
         "input_chars": len(user), "ungrounded_dropped": len(ung), "error": err, "run": run_label, "name": o.get("name")})
    return dict(id=sid, lang=lang, path=path, project=project, kind=kind, ok=ok, err=err, ms=total_ms, attempts=attempts,
                truncated=trunc, chars=len(s['body_redacted']), summary=o)

PILOT_SQL = """
WITH c AS (
  SELECT id, language, path, kind, project, body_redacted, content_hash, source, lines,
         row_number() OVER (PARTITION BY source, language ORDER BY abs(lines-60), id) rn
  FROM scripts WHERE NOT partial AND lines BETWEEN 15 AND 400)
SELECT id, language, path, kind, project, body_redacted, content_hash FROM c WHERE rn=1 AND (
  (source='disk' AND language IN ('python','bash','javascript','applescript','typescript')) OR
  (source='transcript' AND language IN ('python','bash','sql','typescript','javascript','zsh')))
ORDER BY source, language LIMIT 8"""

if __name__ == "__main__":
    ap = argparse.ArgumentParser(); ap.add_argument("--pilot", action="store_true"); ap.add_argument("--ids")
    ap.add_argument("--all", action="store_true"); ap.add_argument("--limit", type=int, default=0); ap.add_argument("--label")
    a = ap.parse_args()
    model = pick_model()
    cols = "s.id, s.language, s.path, s.kind, s.project, s.body_redacted, s.content_hash, f.facts, f.extractor_version AS facts_version"
    lock = open("/tmp/script-catalog-summarize.lock", "w")
    try: fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError: raise SystemExit("another summarize run is active")
    if a.pilot: rows = [dict(r, facts=None) for r in pg.rows(PILOT_SQL)]; label = "pilot"
    elif a.ids: rows = pg.rows(f"SELECT {cols} FROM scripts s LEFT JOIN script_facts f ON f.script_id=s.id WHERE s.id IN ({','.join(str(int(x)) for x in a.ids.split(','))}) ORDER BY s.id"); label = a.label or "ids"
    elif a.all:
        ids = [r["id"] for r in pg.rows(f"""SELECT s.id FROM scripts s WHERE s.catalog_status <> 'excluded'
            AND NOT EXISTS (SELECT 1 FROM summaries m WHERE m.script_id=s.id AND m.content_hash=s.content_hash AND m.valid_json AND m.prompt_version='{PROMPT_VERSION}')
            ORDER BY (s.catalog_status = 'low_priority'), s.id {'LIMIT %d' % a.limit if a.limit else ''}""")]
        label = a.label or "full-v3"
        print(json.dumps({"todo": len(ids)}), file=sys.stderr, flush=True)
        def gen():
            for i in ids:   # fetch one at a time so a long run always sees current bodies/facts
                r = pg.rows(f"SELECT {cols} FROM scripts s LEFT JOIN script_facts f ON f.script_id=s.id WHERE s.id={i}")
                if r: yield r[0]
        rows = gen()
    else: ap.error("choose --pilot, --ids or --all")
    out = []; t0 = time.time()
    for n, r in enumerate(rows, 1):
        res = summarize(model, r, label); out.append(res)
        print(json.dumps({"n": n, **{k: res[k] for k in ("id", "lang", "ok", "ms", "attempts", "truncated")}, "elapsed_s": int(time.time() - t0)}), file=sys.stderr, flush=True)
    if not a.all:
        os.makedirs("data", exist_ok=True)
        json.dump({"model": model, "results": out}, open("data/last_run.json", "w"), indent=1)
    print(json.dumps({"done": len(out), "ok": sum(1 for x in out if x["ok"])}), file=sys.stderr, flush=True)
