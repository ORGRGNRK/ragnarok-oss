#!/usr/bin/env python3
"""Read-only search page for the script catalog.

Stdlib HTTP server + psycopg. Connects with the read-only role from SC_RO_DSN
(set via an EnvironmentFile, never in code). Binds SC_WEB_HOST:SC_WEB_PORT only.
"""
import html, json, os, re, socket, sys, traceback
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlencode, urlparse

import psycopg
from psycopg.rows import dict_row

DSN = os.environ.get("SC_RO_DSN")
HOST = os.environ.get("SC_WEB_HOST", "127.0.0.1")
PORT = int(os.environ.get("SC_WEB_PORT", "8449"))
LIMIT = 200
RISKS = ["none", "low", "medium", "high"]
STATUSES = ["active", "low_priority", "excluded"]

def esc(x):
    return html.escape("" if x is None else str(x), quote=True)

def db():
    c = psycopg.connect(DSN, row_factory=dict_row, connect_timeout=5, autocommit=True)
    c.execute("SET default_transaction_read_only = on; SET statement_timeout = '10s'")
    return c

CSS = """
body{font:14px/1.45 -apple-system,system-ui,sans-serif;margin:0;color:#1b1b1b;background:#fafafa}
header{background:#1f2937;color:#fff;padding:10px 18px}header a{color:#fff;text-decoration:none;font-weight:600}
main{padding:14px 18px;max-width:1300px}
form.f{display:flex;flex-wrap:wrap;gap:6px;align-items:center;margin-bottom:10px}
form.f input[type=text]{width:320px;padding:5px}select{padding:4px}
table{border-collapse:collapse;width:100%;background:#fff}td,th{border-bottom:1px solid #e5e7eb;padding:5px 7px;text-align:left;vertical-align:top}
th{background:#f3f4f6;font-weight:600}
.r-high{background:#fee2e2;color:#991b1b}.r-medium{background:#fef3c7;color:#92400e}.r-low{background:#e0f2fe;color:#075985}.r-none{background:#f3f4f6;color:#555}
.pill{display:inline-block;border-radius:9px;padding:0 7px;font-size:12px;margin:1px}.tag{background:#ede9fe;color:#5b21b6}
.muted{color:#6b7280}pre{background:#0f172a;color:#e2e8f0;padding:10px;overflow:auto;max-height:640px;font-size:12px}
.grid{display:grid;grid-template-columns:1fr 1fr;gap:14px}.card{background:#fff;border:1px solid #e5e7eb;padding:10px 12px;margin-bottom:12px}
h2{font-size:15px;margin:4px 0 8px}ul{margin:4px 0;padding-left:20px}code{font-size:12px}
"""

def page(title, body):
    return f"""<!doctype html><html><head><meta charset=utf-8><meta name=viewport content="width=device-width">
<title>{esc(title)}</title><style>{CSS}</style></head><body>
<header><a href="/">Script catalog</a> <span class=muted style="color:#9ca3af">read-only · tailnet only</span></header>
<main>{body}</main></body></html>"""

def risk_pill(r):
    return f'<span class="pill r-{esc(r or "none")}">{esc(r or "?")}</span>'

def options(values, sel, blank="any"):
    out = [f'<option value="">{esc(blank)}</option>']
    for v in values:
        out.append(f'<option value="{esc(v)}"{" selected" if v == sel else ""}>{esc(v)}</option>')
    return "".join(out)

def search(qs):
    g = lambda k: (qs.get(k, [""])[0] or "").strip()
    q, lang, proj, src, risk, tag, status = (g(k) for k in ("q", "lang", "project", "source", "risk", "tag", "status"))
    where, args = [], []
    if status == "all":
        pass
    elif status:
        where.append("v.catalog_status = %s"); args.append(status)
    else:
        where.append("v.catalog_status <> 'excluded'")
    for col, val in (("v.language", lang), ("v.project", proj), ("v.source", src), ("v.risk", risk)):
        if val:
            where.append(f"{col} = %s"); args.append(val)
    if tag:
        where.append("%s = ANY(v.tags)"); args.append(tag)
    order = "v.id"
    if q:
        terms = [t for t in re.split(r"\s+", q) if t][:8]
        for t in terms:
            like = f"%{t}%"
            where.append("(v.path ILIKE %s OR v.name ILIKE %s OR v.purpose ILIKE %s OR v.reuse_notes ILIKE %s "
                         "OR v.project ILIKE %s OR v.facts::text ILIKE %s OR s.body_redacted ILIKE %s)")
            args += [like] * 7
        order = "(v.name ILIKE %s OR v.path ILIKE %s) DESC, (v.purpose ILIKE %s) DESC, v.id"
        args_order = [f"%{terms[0]}%"] * 3
    else:
        args_order = []
    w = ("WHERE " + " AND ".join(where)) if where else ""
    with db() as c:
        facets = c.execute("""SELECT
            (SELECT array_agg(DISTINCT language ORDER BY language) FROM scripts WHERE language IS NOT NULL) langs,
            (SELECT array_agg(DISTINCT project ORDER BY project) FROM scripts WHERE project IS NOT NULL) projects,
            (SELECT array_agg(DISTINCT source ORDER BY source) FROM scripts) sources,
            (SELECT array_agg(DISTINCT t ORDER BY t) FROM scripts, unnest(tags) t) tags""").fetchone()
        total = c.execute(f"SELECT count(*) n FROM catalog_v v JOIN scripts s ON s.id=v.id {w}", args).fetchone()["n"]
        rows = c.execute(f"""SELECT v.id, v.path, v.name, v.purpose, v.language, v.project, v.source, v.risk, v.tags,
                 v.catalog_status, v.summary_id, v.summary_stale, v.lines, v.truncated
                 FROM catalog_v v JOIN scripts s ON s.id=v.id {w} ORDER BY {order} LIMIT {LIMIT}""",
                         args + args_order).fetchall()
        done = c.execute("SELECT count(*) FILTER (WHERE summary_id IS NOT NULL AND prompt_version='v3') v3, count(*) n FROM catalog_v WHERE catalog_status<>'excluded'").fetchone()
    form = f"""<form class=f method=get action="/">
<input type=text name=q value="{esc(q)}" placeholder="search name, purpose, path, code, facts…" autofocus>
<label>lang <select name=lang>{options(facets['langs'] or [], lang)}</select></label>
<label>project <select name=project>{options(facets['projects'] or [], proj)}</select></label>
<label>source <select name=source>{options(facets['sources'] or [], src)}</select></label>
<label>risk <select name=risk>{options(RISKS, risk)}</select></label>
<label>tag <select name=tag>{options(facets['tags'] or [], tag)}</select></label>
<label>status <select name=status>{options(STATUSES + ['all'], status, 'not excluded')}</select></label>
<button>Search</button> <a href="/">reset</a></form>
<p class=muted>{total} match{'es' if total != 1 else ''}{f' (showing first {LIMIT})' if total > LIMIT else ''} ·
v3 summaries: {done['v3']}/{done['n']} non-excluded scripts</p>"""
    trs = []
    for r in rows:
        title = r["name"] or os.path.basename(r["path"] or "") or f"#{r['id']}"
        tags = "".join(f'<span class="pill tag">{esc(t)}</span>' for t in (r["tags"] or []))
        purpose = esc(r["purpose"]) if r["purpose"] else '<span class=muted>not summarized yet</span>'
        if r["summary_stale"]:
            purpose += ' <span class=muted>(stale)</span>'
        trs.append(f"""<tr><td><a href="/s/{r['id']}">#{r['id']}</a></td>
<td><a href="/s/{r['id']}"><b>{esc(title)}</b></a><br><code class=muted>{esc(r['path'])}</code></td>
<td>{purpose}</td><td>{esc(r['language'])}</td><td>{esc(r['project'])}</td><td>{esc(r['source'])}</td>
<td>{risk_pill(r['risk'])}</td><td>{tags}{'' if r['catalog_status']=='active' else f'<br><span class=muted>{esc(r["catalog_status"])}</span>'}</td></tr>""")
    table = ("<table><tr><th>id</th><th>script</th><th>purpose</th><th>lang</th><th>project</th><th>source</th><th>risk</th><th>tags</th></tr>"
             + "".join(trs) + "</table>")
    return page("Script catalog", form + table)

def li_list(items):
    if not items:
        return '<span class=muted>—</span>'
    return "<ul>" + "".join(f"<li>{esc(i if isinstance(i, str) else json.dumps(i))}</li>" for i in items) + "</ul>"

def link_rows(rows, other):
    if not rows:
        return '<span class=muted>none found</span>'
    out = []
    for r in rows:
        out.append(f"""<li><a href="/s/{r[other]}">#{r[other]} {esc(r['oname'] or os.path.basename(r['opath'] or ''))}</a>
<span class=muted>· {esc(r['match_type'])} · conf {r['confidence'] if r['confidence'] is not None else '?'}</span><br>
<span class=muted>{esc(r['reason'])}</span></li>""")
    return "<ul>" + "".join(out) + "</ul>"

def detail(sid):
    with db() as c:
        v = c.execute("SELECT * FROM catalog_v WHERE id=%s", (sid,)).fetchone()
        if not v:
            return None
        s = c.execute("SELECT body_redacted, alt_paths, content_hash, sessions FROM scripts WHERE id=%s", (sid,)).fetchone()
        occ = c.execute("SELECT source_tool, kind, source_file, session_id, ts, path, partial FROM occurrences WHERE script_id=%s ORDER BY ts NULLS LAST LIMIT 100", (sid,)).fetchall()
        def links(kind, direction):
            me, other = ("src_id", "dst_id") if direction == "out" else ("dst_id", "src_id")
            return c.execute(f"""SELECT l.{other} AS oid, l.match_type, l.confidence, l.reason, o.path opath, cv.name oname
                FROM script_links l JOIN scripts o ON o.id=l.{other} LEFT JOIN catalog_v cv ON cv.id=o.id
                WHERE l.link_kind=%s AND l.{me}=%s ORDER BY l.confidence DESC NULLS LAST, l.{other}""", (kind, sid)).fetchall()
        feeds, fed_by = links("chain", "out"), links("chain", "in")
        runs, run_by = links("invokes", "out"), links("invokes", "in")
        prov_out, prov_in = links("provenance", "out"), links("provenance", "in")
        ung = c.execute("SELECT ungrounded FROM summaries WHERE id=%s", (v["summary_id"],)).fetchone() if v["summary_id"] else None
    title = v["name"] or os.path.basename(v["path"] or "") or f"#{sid}"
    tags = "".join(f'<span class="pill tag">{esc(t)}</span>' for t in (v["tags"] or []))
    meta = f"""<p><code>{esc(v['path'])}</code><br>
{esc(v['language'])} · {esc(v['kind'])} · project {esc(v['project'])} · source {esc(v['source'])} ({esc(', '.join(v['source_tools'] or []))}) ·
{v['lines']} lines · {v['version_count']} versions · {v['occurrence_count']} occurrences · risk {risk_pill(v['risk'])}
<span class=muted>(model {esc(v['risk_model'])}, code {esc(v['risk_code'])})</span><br>
status <b>{esc(v['catalog_status'])}</b> {f'<span class=muted>— {esc(v["status_reason"])}</span>' if v['status_reason'] else ''} {tags}<br>
<span class=muted>first seen {esc(v['first_seen'])} · last seen {esc(v['last_seen'])} · secrets redacted {v['secrets_redacted']}</span></p>"""
    if v["summary_id"]:
        summ = f"""<div class=card><h2>Summary <span class=muted>({esc(v['model'])}, prompt {esc(v['prompt_version'])}{', input truncated' if v['truncated'] else ''}{', STALE: code changed since' if v['summary_stale'] else ''})</span></h2>
<p><b>{esc(v['purpose'])}</b></p>
<div class=grid><div><b>Inputs</b>{li_list(v['inputs'])}<b>Outputs</b>{li_list(v['outputs'])}</div>
<div><b>Dependencies</b>{li_list(v['dependencies'])}<b>Side effects</b>{li_list(v['side_effects'])}</div></div>
<p><b>Reuse:</b> {esc(v['reuse_notes'])}</p>
{f'<p class=muted>Model said it pipes into: {esc(", ".join(map(str, v["pipes_into"] or [])))}</p>' if v['pipes_into'] else ''}
{f'<p class=muted>Dropped as not found in code: {esc("; ".join(u["item"] for u in ung["ungrounded"]))}</p>' if ung and ung['ungrounded'] else ''}
<p class=muted>Machine-written by a local 7B model; check against the code below.</p></div>"""
    else:
        summ = '<div class=card><h2>Summary</h2><p class=muted>Not summarized yet (or excluded).</p></div>'
    facts = v["facts"] or {}
    frows = "".join(f"<tr><th>{esc(k)}</th><td>{li_list(val if isinstance(val, list) else [val])}</td></tr>" for k, val in sorted(facts.items()) if val)
    facts_html = f'<div class=card><h2>Static facts <span class=muted>(extracted by code)</span></h2><table>{frows or "<tr><td class=muted>none</td></tr>"}</table></div>'
    links_html = f"""<div class=grid>
<div class=card><h2>What feeds this</h2>{link_rows(fed_by, 'oid')}<h2>Run by</h2>{link_rows(run_by, 'oid')}</div>
<div class=card><h2>What this feeds</h2>{link_rows(feeds, 'oid')}<h2>Runs</h2>{link_rows(runs, 'oid')}</div></div>
<div class=card><h2>Provenance (same script on disk / in chats)</h2>{link_rows(prov_in + prov_out, 'oid')}</div>"""
    orows = "".join(f"<tr><td>{esc(o['ts'])}</td><td>{esc(o['source_tool'])}</td><td>{esc(o['kind'])}</td><td><code>{esc(o['session_id'])}</code></td><td><code>{esc(o['source_file'])}</code></td><td><code>{esc(o['path'])}</code>{' (partial)' if o['partial'] else ''}</td></tr>" for o in occ)
    occ_html = f'<div class=card><h2>Source chats / occurrences ({len(occ)})</h2><table><tr><th>when</th><th>tool</th><th>kind</th><th>session</th><th>source file</th><th>path</th></tr>{orows}</table></div>'
    code = f'<div class=card><h2>Code (redacted)</h2><pre>{esc(s["body_redacted"])}</pre></div>'
    return page(f"#{sid} {title}", f"<h1 style='font-size:19px'>#{sid} {esc(title)}</h1>{meta}{summ}{links_html}{facts_html}{occ_html}{code}")

class H(BaseHTTPRequestHandler):
    server_version = "script-catalog"
    def send(self, code, body, ctype="text/html; charset=utf-8"):
        b = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(b)))
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Content-Security-Policy", "default-src 'none'; style-src 'unsafe-inline'")
        self.send_header("Referrer-Policy", "no-referrer")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(b)
    def do_HEAD(self):
        self.do_GET()
    def do_GET(self):
        u = urlparse(self.path)
        try:
            if u.path == "/":
                return self.send(200, search(parse_qs(u.query)))
            if u.path == "/healthz":
                with db() as c:
                    c.execute("SELECT 1")
                return self.send(200, "ok\n", "text/plain")
            m = re.fullmatch(r"/s/(\d+)", u.path)
            if m:
                out = detail(int(m.group(1)))
                return self.send(200, out) if out else self.send(404, page("Not found", "<p>No such script.</p>"))
            self.send(404, page("Not found", "<p>Not found.</p>"))
        except Exception:
            traceback.print_exc()
            self.send(500, page("Error", "<p>Internal error (see journal).</p>"))
    def log_message(self, fmt, *a):
        sys.stderr.write("%s %s\n" % (self.address_string(), fmt % a))

class Server(ThreadingHTTPServer):
    daemon_threads = True
    def server_bind(self):
        # IP_FREEBIND lets us bind the Tailscale IP even before tailscaled has brought it up at boot.
        self.socket.setsockopt(socket.SOL_IP, getattr(socket, "IP_FREEBIND", 15), 1)
        super().server_bind()

if __name__ == "__main__":
    if not DSN:
        sys.exit("SC_RO_DSN not set")
    print(f"listening on http://{HOST}:{PORT}", file=sys.stderr, flush=True)
    Server((HOST, PORT), H).serve_forever()
