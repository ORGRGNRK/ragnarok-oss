#!/usr/bin/env python3
"""Code-derived chaining (no AI). Matches one script's outputs to another's inputs using script_facts:
  file      : A writes path P, B reads P                    (exact path 0.85; same distinctive file name 0.45)
  table     : A writes DB table T, B reads T                (0.7; 0.5 for short/generic-looking names)
  endpoint  : A serves port/route, B calls that port/route  (port+route 0.8; port only 0.5)
  invokes   : A's code runs B (by path or distinctive script name)  (path 0.9; name 0.6)
Rewrites all link_kind IN ('chain','invokes') rows in one transaction and logs counts to change_log.
Excluded (vendor/borrowed/duplicate) rows are left out. Resources used by too many scripts are skipped as generic."""
import json, os, re, collections, sys
import pg

GENERIC_NAMES = {"config.json", "settings.json", "package.json", "data.json", "output.json", "out.json", "input.json",
                 "result.json", "results.json", "index.js", "main.py", "app.py", "server.py", "test.py", "run.sh",
                 "install.sh", "setup.sh", "build.sh", ".env", "env", "log.txt", "output.txt", "out.txt", "README.md",
                 "requirements.txt", "tsconfig.json", "start.sh", "index.html", "state.json", "cache.json", "tmp", "out", "x"}
GENERIC_TABLES = {"users", "items", "data", "test", "t", "tmp", "foo", "bar", "logs", "log", "events", "records", "rows",
                  "table", "tables", "name", "names", "values", "information_schema.tables", "sqlite_master", "x", "y", "a", "b"}
MAX_PRODUCERS, MAX_CONSUMERS = 8, 12
GENERIC_ROUTES = {"/health", "/healthz", "/status", "/ping", "/api", "/metrics", "/login", "/logout", "/v1", "/api/v1",
                  "/api/v2", "/index", "/version", "/ready", "/live", "/static", "/api/health", "/api/status", "/auth"}
# source/doc files that patch scripts edit in turn are an edit sequence, not a data hand-off
CODE_EXT = {".py", ".js", ".ts", ".mjs", ".cjs", ".tsx", ".jsx", ".swift", ".sh", ".zsh", ".bash", ".patch", ".diff",
            ".md", ".go", ".rs", ".rb", ".c", ".h", ".m", ".css", ".html", ".plist", ".xcconfig", ".pbxproj", ".toml", ".lock"}
def code_file(p): return os.path.splitext(p)[1].lower() in CODE_EXT

def basename(p): return os.path.basename(p.rstrip("/"))
def distinctive(name):
    return name not in GENERIC_NAMES and len(name) >= 8 and ("." in name or "-" in name or "_" in name) and "$" not in name and "{" not in name

def main(dry=False):
    rows = pg.rows("""SELECT s.id, s.path, s.source, s.language, s.catalog_status, f.facts
                      FROM scripts s JOIN script_facts f ON f.script_id = s.id WHERE s.catalog_status <> 'excluded'""")
    prov = {(r["src_id"], r["dst_id"]) for r in pg.rows("SELECT src_id, dst_id FROM script_links WHERE link_kind='provenance'")}
    same = lambda a, b: a == b or (a, b) in prov or (b, a) in prov
    by_id = {r["id"]: r for r in rows}
    for r in rows:
        if r["path"]: r["npath"] = re.sub("^" + re.escape(os.path.expanduser("~")) + "(?=/)", "~", r["path"])
    prod = collections.defaultdict(set); cons = collections.defaultdict(set)   # key -> ids
    for r in rows:
        f = r["facts"] or {}
        writes = set(f.get("files_written", []) + f.get("files_modified", []))
        r["writes"] = writes | {basename(p) for p in writes}
        for p in writes:
            if "$" in p or "{" in p or code_file(p): continue
            prod[("file", p)].add(r["id"])
            if distinctive(basename(p)): prod[("fname", basename(p))].add(r["id"])
        for p in f.get("files_read", []) + [d.split(":", 1)[1] for d in f.get("databases", []) if d.startswith("sqlite:")]:
            if "$" in p or "{" in p or code_file(p) or p in writes: continue
            cons[("file", p)].add(r["id"])
            if distinctive(basename(p)): cons[("fname", basename(p))].add(r["id"])
        for t in f.get("tables_written", []):
            if t not in GENERIC_TABLES: prod[("table", t)].add(r["id"])
        for t in f.get("tables_read", []):
            if t not in GENERIC_TABLES and t not in f.get("tables_written", []): cons[("table", t)].add(r["id"])
        for sv in f.get("serves", []):
            if sv.get("port"): prod[("port", sv["port"])].add(r["id"])
            if sv.get("route") and len(sv["route"]) > 2: prod[("route", sv["route"].split("<")[0].split("{")[0].split(":")[0].rstrip("/"))].add(r["id"])
        for n in f.get("network", []) + [{"url": u} for u in f.get("urls_referenced", [])]:
            u = n.get("url") or ""
            m = re.match(r"\w+://(localhost|127\.0\.0\.1|0\.0\.0\.0|100\.\d+\.\d+\.\d+|[\w-]+\.tail\w+\.ts\.net|alexus(?:\.local)?)(?::(\d+))?(/[^?#\s]*)?", u)
            if m and m.group(2): cons[("port", int(m.group(2)))].add(r["id"])
            if m and m.group(3) and len(m.group(3)) > 2: cons[("route", m.group(3).rstrip("/"))].add(r["id"])
    # invokes
    name_index = collections.defaultdict(set); path_index = collections.defaultdict(set)
    for r in rows:
        if r.get("npath"):
            path_index[r["npath"]].add(r["id"])
            bn = basename(r["npath"])
            if len(bn) >= 6 and bn not in GENERIC_NAMES: name_index[bn].add(r["id"])
    edges = {}
    def edge(kind, src, dst, match, reason, conf, ev):
        if same(src, dst): return
        k = (kind, src, dst, match)
        if k not in edges or edges[k]["confidence"] < conf:
            edges[k] = dict(reason=reason, confidence=conf, evidence=ev)
    skipped = collections.Counter()
    for key, ps in prod.items():
        cs = cons.get(key, set())
        if not cs: continue
        if len(ps) > MAX_PRODUCERS or len(cs) > MAX_CONSUMERS: skipped[key[0]] += 1; continue
        kind, val = key
        for a in ps:
            for b in cs:
                if kind == "file": edge("chain", a, b, "file", f"#{a} writes {val}; #{b} reads it", 0.85, {"path": val})
                elif kind == "fname":
                    if val in by_id[b]["writes"] or ("chain", a, b, "file") in edges: continue
                    edge("chain", a, b, "file-name", f"#{a} writes a file named {val}; #{b} reads a file with that name", 0.45, {"name": val})
                elif kind == "table":
                    edge("chain", a, b, "table", f"#{a} writes table {val}; #{b} reads it", 0.7 if len(val) >= 6 else 0.5, {"table": val})
                elif kind == "port": edge("chain", a, b, "endpoint-port", f"#{a} serves on port {val}; #{b} calls that port", 0.5, {"port": val})
                elif kind == "route":
                    if val.lower() in GENERIC_ROUTES or len(val) < 6: continue
                    edge("chain", a, b, "endpoint-route", f"#{a} serves route {val}; #{b} calls it", 0.6, {"route": val})
    # port+route together -> stronger
    for (kind, src, dst, match), e in list(edges.items()):
        if match == "endpoint-port" and any(k[1] == src and k[2] == dst and k[3] == "endpoint-route" for k in edges):
            e["confidence"] = 0.8; e["reason"] += " (route also matches)"
    for r in rows:
        for inv in (r["facts"] or {}).get("invokes", []):
            p = inv.lstrip("./") if inv.startswith("./") else inv
            hits = path_index.get(inv, set())
            if hits:
                for b in hits: edge("invokes", r["id"], b, "path", f"#{r['id']} runs {inv}", 0.9, {"invoked": inv})
                continue
            bn = basename(p)
            hits = name_index.get(bn, set())
            if hits and len(hits) <= 4 and distinctive(bn):
                for b in hits: edge("invokes", r["id"], b, "name", f"#{r['id']} runs a script named {bn}", 0.6, {"invoked": inv})
    # also bare command names that match catalog script names (e.g. ragnarok-save), from commands in the body
    body_rows = pg.rows("SELECT id, body_redacted FROM scripts WHERE catalog_status <> 'excluded'")
    cmd_names = {n: ids for n, ids in name_index.items() if "-" in n and "." not in n and len(n) >= 8 and len(ids) <= 4}
    if cmd_names:
        rx = re.compile(r"(?m)(?:^|[;&|(]\s*|\$\(\s*|\bthen\s+|\bdo\s+|\bexec\s+|ssh\s+\S+\s+['\"]?)(" + "|".join(re.escape(n) for n in sorted(cmd_names, key=len, reverse=True)) + r")(?=[\s;|&)'\"]|$)")
        for br in body_rows:
            for m in set(x.group(1) for x in rx.finditer(br["body_redacted"])):
                for b in cmd_names[m]:
                    if by_id.get(br["id"]) and basename(by_id[br["id"]].get("npath") or "") == m: continue
                    edge("invokes", br["id"], b, "name", f"#{br['id']} runs command {m}", 0.6, {"invoked": m})
    stats = collections.Counter((k[0], k[3]) for k in edges)
    detail = {"edges": len(edges), "by_kind": {f"{a}:{b}": n for (a, b), n in sorted(stats.items())}, "skipped_generic_keys": dict(skipped)}
    if dry:
        print(json.dumps(detail, indent=1))
        for k, e in list(edges.items())[:40]: print(k, e["reason"], e["confidence"])
        return
    sql = ["BEGIN;", "DELETE FROM script_links WHERE link_kind IN ('chain','invokes');"]
    for (kind, a, b, match), e in edges.items():
        sql.append(f"INSERT INTO script_links(link_kind,src_id,dst_id,match_type,reason,confidence,evidence,created_by) VALUES("
                   f"{pg.lit(kind)},{a},{b},{pg.lit(match)},{pg.lit(e['reason'])},{e['confidence']},{pg.lit(json.dumps(e['evidence']))}::jsonb,'chain.py');")
    sql.append(f"INSERT INTO change_log(actor,action,ok,detail) VALUES('grok-bot','chain',true,{pg.lit(json.dumps(detail))}::jsonb);")
    sql.append("COMMIT;")
    pg.run("\n".join(sql))
    print(json.dumps(detail, indent=1))

if __name__ == "__main__":
    main(dry="--dry" in sys.argv)
