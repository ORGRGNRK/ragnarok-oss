#!/usr/bin/env python3
"""share-run: one agent run as a single self-contained web page a stranger can read on a phone.

    share-run.py RUN_ID [--agents-dir DIR] > run.html
    share-run.py --all [--only ID,ID,...] [--agents-dir DIR] > runs.html     every proved-mode run, with a dropdown

Everything on the page comes from the run's own record files (state.json, critic.jsonl): the task, the runner's
own events, what the critic refuted, the proof checks and the verdict. Only the fixed labels are written here.

Before anything is printed the text is scrubbed (home folder paths, IP addresses, e-mail addresses) and then
searched for credential shapes; if one is found NOTHING is printed and the exit code is 4.
Read-only. Standard library only.
"""
import html, json, os, re, sys
from datetime import datetime
from pathlib import Path

SECRET_SHAPES = [r"sk-[A-Za-z0-9_-]{20,}", r"gh[pousr]_[A-Za-z0-9]{30,}", r"xox[abprs]-[A-Za-z0-9-]{10,}",
                 r"AKIA[0-9A-Z]{16}", r"-----BEGIN [A-Z ]*PRIVATE KEY-----", r"eyJ[A-Za-z0-9_-]{20,}\.eyJ[A-Za-z0-9_-]{20,}",
                 r"\b[0-9]{8,10}:AA[A-Za-z0-9_-]{30,}", r"(?i)\b(password|passwd|secret|api[_-]?key|token)\s*[=:]\s*\S{8,}"]
WHO = {"claude": "Claude", "grok": "Grok", "codex": "Codex", "muse": "Muse", "antigravity": "Antigravity"}


def scrub(s):
    s = re.sub(r"/(Users|home)/[A-Za-z0-9._-]+", "~", s or "")
    s = re.sub(r"\b(?:\d{1,3}\.){3}\d{1,3}\b", "[address]", s)
    s = re.sub(r"\b[\w.+-]+@[\w-]+\.[\w.-]+\b", "[email]", s)
    return s


def strings(v):
    if isinstance(v, str):
        yield v
    elif isinstance(v, dict):
        for x in v.values():
            yield from strings(x)
    elif isinstance(v, list):
        for x in v:
            yield from strings(x)


def refutations(path):
    """Every distinct REFUTED line the critic wrote, longest copy of each (the stream repeats partial text)."""
    found = {}
    if not path.exists():
        return []
    for line in path.read_text(errors="replace").splitlines():
        if "REFUTED" not in line:
            continue
        try:
            rec = json.loads(line)
        except ValueError:
            continue
        for s in strings(rec):
            for m in re.finditer(r"(?m)^\s*REFUTED:\s*(.+)$", s):
                t = m.group(1).strip()
                if t.startswith("<") or len(t) < 30:        # the instruction template, not a finding
                    continue
                key = t[:50]
                if len(t) > len(found.get(key, "")):
                    found[key] = t
    return list(found.values())


def hhmm(ts):
    try:
        return datetime.strptime(ts, "%Y-%m-%dT%H:%M:%S%z").strftime("%H:%M")
    except (ValueError, TypeError):
        return ""


def minutes(a, b):
    try:
        f = "%Y-%m-%dT%H:%M:%S%z"
        return round((datetime.strptime(b, f) - datetime.strptime(a, f)).total_seconds() / 60)
    except (ValueError, TypeError):
        return None


def md(s):
    """Escape, then show `code` spans; nothing else is interpreted."""
    return re.sub(r"`([^`\n]+)`", r"<code>\1</code>", html.escape(scrub(s)))


def build(d, refuted):
    who = WHO.get(d.get("who"), d.get("who") or "agent")
    verdict = (d.get("verdict") or d.get("status") or "?").upper()
    events = [a for a in d.get("actions") or [] if a.get("kind") == "system" and "compact_boundary" not in str(a.get("what"))]
    sent_back = [e for e in events if str(e.get("what", "")).startswith("sent back")]
    # Several critics can be tried in a row; the one that did the work each round is the last one started.
    critics, last = [], None
    for e in events + [{"what": "end"}]:
        m = re.match(r"critic started on (\w+)", str(e.get("what", "")))
        if m:
            last = m.group(1)
        elif last:
            if last not in critics:
                critics.append(last)
            last = None
    mins = minutes(d.get("started"), d.get("ended"))
    task = (d.get("task") or "").strip()
    first, _, rest = task.partition("\n\n")
    checks = d.get("checks") or []
    crit = d.get("critic") or {}

    rows = [f'<li><time>{hhmm(d.get("started"))}</time><div><b>{html.escape(who)} starts work.</b></div></li>']
    shown_refuted = False
    for e in events:
        what = str(e.get("what", ""))
        cls, extra = "", ""
        if what.startswith("sent back"):
            cls = ' class="back"'
            if "critic" in what and refuted and not shown_refuted:
                shown_refuted = True
                extra = "".join(f'<blockquote><span class="tag">Refuted</span> {md(r)}</blockquote>' for r in refuted)
        rows.append(f'<li{cls}><time>{hhmm(e.get("at"))}</time><div><b>{md(what[:1].upper() + what[1:])}</b>{extra}</div></li>')
    rows.append(f'<li class="end"><time>{hhmm(d.get("ended"))}</time><div><b>{html.escape(verdict.capitalize())}.</b> '
                f'{md(d.get("verdict_note") or "")}</div></li>')

    check_rows = "".join(
        f'<li><span class="mk {"y" if c.get("ok") is True else "n" if c.get("ok") is False else "q"}">'
        f'{"✓" if c.get("ok") is True else "✗" if c.get("ok") is False else "?"}</span><div>{md(c.get("claim", ""))}'
        f'<code class="cmd">{html.escape(scrub(c.get("cmd") or ""))}</code></div></li>' for c in checks)
    confirmed = [m.group(1).strip() for m in re.finditer(r"CONFIRMED:\s*(.+?)(?=\s+CONFIRMED:|\s+REFUTED:|$)", crit.get("text") or "", re.S)]
    crit_html = "".join(f"<li>{md(c)}</li>" for c in confirmed[:6])

    facts = [f"{len(sent_back)} time{'s' if len(sent_back) != 1 else ''} sent back" if sent_back else "never sent back",
             f"{len(checks)} proof check{'s' if len(checks) != 1 else ''}",
             f"{d.get('tools') or 0} tool calls"] + ([f"{mins} min"] if mins is not None else [])
    return f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>A proved run — Ragnarok</title>
<meta name="description" content="{html.escape(who)} said it was done. The work was checked, sent back {len(sent_back)} times, then proved.">
<style>
:root{{--bg:#0d0d0d;--panel:#151515;--line:#2a2a2a;--gold:#c9a84c;--text:#e8e4d8;--dim:#8a857a;--amber:#e0a030;--red:#d9534f}}
*{{box-sizing:border-box}}body{{margin:0;background:var(--bg);color:var(--text);font:16px/1.6 ui-monospace,"SF Mono",Menlo,"Courier New",monospace}}
main{{max-width:46rem;margin:0 auto;padding:28px 16px 64px}}
.mark{{font-family:"Courier New",monospace;font-weight:700;letter-spacing:.08em;color:var(--gold)}}
.mark small{{color:var(--dim);font-weight:400;letter-spacing:.15em;text-transform:uppercase}}
h1{{font-size:26px;line-height:1.25;margin:26px 0 10px;font-weight:700}}
h2{{font-size:12px;letter-spacing:.18em;text-transform:uppercase;color:var(--gold);font-weight:400;margin:38px 0 12px}}
.lede{{color:var(--dim);margin:0 0 18px}}
.verdict{{display:inline-block;border:1px solid var(--gold);color:var(--gold);padding:4px 12px;letter-spacing:.2em;font-size:13px}}
.facts{{color:var(--dim);font-size:13px;margin-top:10px}}
.task{{background:var(--panel);border:1px solid var(--line);border-radius:6px;padding:14px 16px;white-space:pre-wrap;word-wrap:break-word;font-size:14px}}
details summary{{cursor:pointer;color:var(--dim);font-size:13px;margin-top:10px}}
ol,ul{{list-style:none;padding:0;margin:0}}
.tl li{{display:flex;gap:14px;padding:10px 0;border-top:1px solid var(--line)}}
.tl time{{color:var(--dim);font-size:13px;flex:none;width:3.2em;padding-top:2px}}
.tl b{{font-weight:400}}.tl .back b{{color:var(--amber)}}.tl .end b{{color:var(--gold)}}
blockquote{{margin:10px 0 0;padding:10px 12px;border-left:2px solid var(--red);background:var(--panel);font-size:14px;word-wrap:break-word}}
.tag{{color:var(--red);font-size:11px;letter-spacing:.15em;text-transform:uppercase;margin-right:6px}}
.checks li{{display:flex;gap:12px;padding:10px 0;border-top:1px solid var(--line)}}
.mk{{flex:none;width:1.2em}}.mk.y{{color:var(--gold)}}.mk.n{{color:var(--red)}}.mk.q{{color:var(--amber)}}
code{{background:var(--panel);border:1px solid var(--line);border-radius:3px;padding:0 4px;font-size:.92em;word-break:break-word}}
code.cmd{{display:block;margin-top:6px;padding:6px 8px;color:var(--dim);font-size:13px}}
.crit li{{padding:8px 0;border-top:1px solid var(--line);font-size:14px;color:var(--dim)}}
footer{{margin-top:48px;padding-top:16px;border-top:1px solid var(--line);color:var(--dim);font-size:13px}}
a{{color:var(--gold)}}
</style></head><body><main>
<div class="mark">CLR — Rgnrk. <small>proved</small></div>
<h1>{html.escape(who)} said it was done. {"It wasn't, until it was proved." if sent_back and verdict == "PROVED" else "Here is what the checks say."}</h1>
<p class="lede">An AI agent's own "done" isn't believed here. The runner runs the proof itself, and a second AI tries to break the work. This is one real run, shown from its own record.</p>
<span class="verdict">{html.escape(verdict)}</span>
<div class="facts">{html.escape(who)}{" · checked by " + html.escape(" and ".join(WHO.get(c, c) for c in critics)) if critics else ""} · {" · ".join(facts)}</div>

<h2>The task</h2>
<div class="task">{html.escape(scrub(first))}</div>
{f'<details><summary>Full task as given</summary><div class="task" style="margin-top:8px">{html.escape(scrub(rest))}</div></details>' if rest else ''}

<h2>What happened</h2>
<ol class="tl">{''.join(rows)}</ol>

<h2>Proof checks, run by the runner, not the agent</h2>
<ul class="checks">{check_rows}</ul>

{f'<h2>The critic’s last word</h2><ul class="crit">{crit_html}</ul>' if crit_html else ''}

<footer>Generated from run <code>{html.escape(d.get("id", ""))}</code>: the task, events, refutations, checks and verdict are copied from the run's record files. Only the headings were written by a person.<br><br>Don't ship probably. Ship provably. · <a href="https://github.com/ORGRGNRK/alexus-app">github.com/ORGRGNRK/alexus-app</a></footer>
</main></body></html>
"""


def checked(page):
    """The credential shape found in `page`, or None."""
    for shape in SECRET_SHAPES:
        m = re.search(shape, page)
        if m:
            return f"{shape[:24]}… near character {m.start()}"
    return None


def build_all(base, only=None):
    """One page holding every proved-mode run (the ones with proof checks), newest first, picked from a dropdown.
    A run with a credential shape in it is left out and named on stderr."""
    runs, skipped = [], []
    for sp in sorted(base.glob("*/state.json"), reverse=True):
        try:
            d = json.loads(sp.read_text())
        except (OSError, ValueError):
            continue
        if not d.get("checks") or not d.get("id") or (only and d["id"] not in only):
            continue
        page = build(d, refutations(sp.parent / "critic.jsonl"))
        why = checked(page)
        if why:
            skipped.append((d["id"], why)); continue
        body = page[page.index("<main>") + 6:page.index("</main>")]
        back = sum(1 for a in d.get("actions") or [] if a.get("kind") == "system" and str(a.get("what", "")).startswith("sent back"))
        verdict = d.get("verdict") or d.get("status") or "?"
        label = f"{verdict} · {WHO.get(d.get('who'), d.get('who') or '?')} · {scrub(d.get('name') or (d.get('task') or '')[:50])} · {(d.get('started') or '')[:10]}" \
                + (f" · sent back {back}×" if back else "")
        runs.append((d["id"], label, body, back if verdict == "proved" else -1))
    if not runs:
        sys.exit("no proved-mode runs to show")
    style = page[page.index("<style>"):page.index("</style>") + 8]
    best = max(runs, key=lambda r: r[3])[0]       # default: the proved run that was sent back the most
    opts = "".join(f'<option value="{html.escape(i)}"{" selected" if i == best else ""}>{html.escape(l)}</option>' for i, l, _, _ in runs)
    secs = "".join(f'<section id="r-{html.escape(i)}"{"" if i == best else " hidden"}>{b}</section>' for i, _, b, _ in runs)
    out = f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Proved runs — Ragnarok</title>
{style}
<style>.pick{{position:sticky;top:0;background:var(--bg);border-bottom:1px solid var(--line);padding:10px 16px;z-index:1}}
#pub{{max-width:46rem;margin:8px auto 0;font-size:13px;color:var(--dim)}}
#pub button{{font:inherit;font-size:12px;letter-spacing:.08em;text-transform:uppercase;color:var(--gold);background:transparent;border:1px solid var(--gold);border-radius:4px;padding:5px 10px;cursor:pointer}}
#pub button:disabled{{opacity:.4;cursor:default}}#puboff{{color:var(--dim)!important;border-color:var(--line)!important}}
.pick select{{width:100%;max-width:46rem;display:block;margin:0 auto;font:inherit;font-size:14px;color:var(--text);background:var(--panel);border:1px solid var(--line);border-radius:4px;padding:8px}}</style>
</head><body>
<div class="pick"><select id="pick" aria-label="Choose a run">{opts}</select>
<div id="pub" hidden><span id="pubnow"></span> <button id="pubgo"></button> <button id="puboff" hidden>Take the public page down</button></div></div>
<main>{secs}</main>
<script src="gate.js"></script><script src="lock.js"></script>
<script>
const pick = document.getElementById("pick");
function show(id) {{
  if (!document.getElementById("r-" + id)) return;
  for (const s of document.querySelectorAll("main > section")) s.hidden = s.id !== "r-" + id;
  pick.value = id; window.scrollTo(0, 0);
}}
pick.onchange = () => {{ location.hash = pick.value; }};
window.onhashchange = () => show(location.hash.slice(1));
if (location.hash) show(location.hash.slice(1));

// The public page (only when this page is served by Heimdall Web; a saved copy has no server to ask).
const pub = document.getElementById("pub"), now = document.getElementById("pubnow"),
      go = document.getElementById("pubgo"), off = document.getElementById("puboff");
let publicId = null, publicUrl = "";
function paint() {{
  const mine = pick.value === publicId;
  now.textContent = publicId ? (mine ? "This run is the public page: " : "A different run is public (" + publicId + ") at ") + publicUrl.replace("https://", "")
                             : "Nothing is public right now.";
  go.textContent = mine ? "Public now" : "Show this run on " + publicUrl.replace("https://", "");
  go.disabled = mine; off.hidden = !publicId;
}}
async function setPublic(id) {{
  go.disabled = off.disabled = true;
  try {{
    const gate = await touch("proved:public");      // changing what is public needs a YubiKey touch
    const r = await fetch("api/proved/public", {{ method: "POST", body: JSON.stringify({{ id, gate }}) }});
    const d = await r.json();
    if (!r.ok) throw new Error(d.error);
    publicId = d.id;
  }} catch (e) {{ now.textContent = e.message; off.disabled = false; return; }}
  off.disabled = false; paint();
}}
go.onclick = () => setPublic(pick.value);
off.onclick = () => setPublic(null);
pick.addEventListener("change", paint); window.addEventListener("hashchange", paint);
fetch("api/proved/public").then(r => r.ok ? r.json() : null).then(d => {{
  if (!d) return; publicId = d.id; publicUrl = d.url; pub.hidden = false; paint();
}}).catch(() => {{}});
</script>
</body></html>
"""
    return out, [r[0] for r in runs], skipped


def main():
    args = sys.argv[1:]
    base = Path.home() / ".ragnarok/agents"
    if "--agents-dir" in args:
        i = args.index("--agents-dir"); base = Path(args[i + 1]); del args[i:i + 2]
    only = None
    if "--only" in args:
        i = args.index("--only"); only = set(args[i + 1].split(",")); del args[i:i + 2]
    if args == ["--all"]:
        page, shown, skipped = build_all(base, only)
        if checked(page):
            print("NOT WRITTEN: a credential shape survived.", file=sys.stderr); sys.exit(4)
        for rid, why in skipped:
            print(f"left out {rid}: credential shape ({why})", file=sys.stderr)
        print(f"{len(shown)} runs on the page, {len(skipped)} left out", file=sys.stderr)
        sys.stdout.write(page)
        return
    if len(args) != 1 or not re.fullmatch(r"[0-9]{8}-[0-9]{6}-[0-9a-f]{4,12}", args[0]):
        sys.exit(__doc__)
    run = base / args[0]
    try:
        d = json.loads((run / "state.json").read_text())
    except (OSError, ValueError) as e:
        sys.exit(f"can't read that run: {e}")
    page = build(d, refutations(run / "critic.jsonl"))
    why = checked(page)
    if why:
        print(f"NOT WRITTEN: something shaped like a credential is in this run ({why}).", file=sys.stderr)
        sys.exit(4)
    sys.stdout.write(page)


if __name__ == "__main__":
    main()
