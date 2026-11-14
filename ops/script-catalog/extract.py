#!/usr/bin/env python3
"""Deterministic script extractor (no AI). Writes staging SQLite data/staging.db.
Sources: Claude Code transcripts (~/.claude/projects/**/*.jsonl), LocalAI app chats,
Codex sessions (if present), and script files on disk. All bodies are redacted before storage."""
import os, re, json, glob, hashlib, sqlite3, stat, subprocess, sys, time
from datetime import datetime, timezone
from redact import redact

HOME = os.path.expanduser("~")
HERE = os.path.dirname(os.path.abspath(__file__))
DB = os.path.join(HERE, "data", "staging.db")
MIN_LINES = 10

EXT_LANG = {".py": "python", ".sh": "bash", ".bash": "bash", ".zsh": "zsh", ".command": "bash",
            ".js": "javascript", ".mjs": "javascript", ".cjs": "javascript", ".ts": "typescript",
            ".tsx": "typescript", ".applescript": "applescript", ".scpt": "applescript",
            ".swift": "swift", ".sql": "sql", ".rb": "ruby", ".pl": "perl", ".ps1": "powershell",
            ".lua": "lua", ".go": "go", ".rs": "rust", ".php": "php"}
FENCE_LANG = {"bash": "bash", "sh": "bash", "shell": "bash", "zsh": "zsh", "console": "bash",
              "python": "python", "py": "python", "python3": "python", "js": "javascript",
              "javascript": "javascript", "node": "javascript", "mjs": "javascript", "ts": "typescript",
              "typescript": "typescript", "tsx": "typescript", "applescript": "applescript",
              "osascript": "applescript", "sql": "sql", "psql": "sql", "swift": "swift", "ruby": "ruby",
              "rb": "ruby", "powershell": "powershell", "ps1": "powershell", "go": "go", "rust": "rust",
              "lua": "lua", "perl": "perl", "php": "php"}
FENCE_RE = re.compile(r"(?ms)^[ \t]*```[ \t]*([A-Za-z0-9_+\-]*)[^\n]*\n(.*?)^[ \t]*```")
HEREDOC_RE = re.compile(r"""(?s)(?:cat|tee)\s+(?:-a\s+)?>?\s*["']?([~/\w.\-$]+\.\w+|[~/\w.\-$]+/[\w.\-]+)["']?\s*<<-?\s*["']?(\w+)["']?[^\n]*\n(.*?)\n\s*\2\s*(?:\n|$)""")
HEREDOC_RE2 = re.compile(r"""(?s)cat\s*<<-?\s*["']?(\w+)["']?\s*>\s*["']?([~/\w.\-$]+)["']?[^\n]*\n(.*?)\n\s*\1\s*(?:\n|$)""")

def norm(s):
    s = s.replace("\r\n", "\n").replace("\r", "\n")
    lines = [l.rstrip() for l in s.split("\n")]
    while lines and not lines[0]: lines.pop(0)
    while lines and not lines[-1]: lines.pop()
    return "\n".join(lines)

def h(s): return hashlib.sha256(s.encode("utf-8", "replace")).hexdigest()

def lang_for(path=None, tag=None, body=""):
    if path:
        ext = os.path.splitext(path)[1].lower()
        if ext in EXT_LANG: return EXT_LANG[ext]
    if tag and tag.lower() in FENCE_LANG: return FENCE_LANG[tag.lower()]
    first = body.split("\n", 1)[0] if body else ""
    if first.startswith("#!"):
        for k, v in (("python", "python"), ("zsh", "zsh"), ("bash", "bash"), ("/sh", "bash"), ("node", "javascript"),
                     ("osascript", "applescript"), ("ruby", "ruby"), ("deno", "typescript"), ("bun", "typescript")):
            if k in first: return v
    return None

def ms_to_iso(v):
    try: return datetime.fromtimestamp(int(v) / 1000, timezone.utc).isoformat()
    except Exception: return None

class Store:
    def __init__(self):
        os.makedirs(os.path.dirname(DB), exist_ok=True)
        if os.path.exists(DB): os.remove(DB)
        self.c = sqlite3.connect(DB)
        self.c.executescript("""
        CREATE TABLE occurrences(
          id INTEGER PRIMARY KEY, source TEXT, kind TEXT, source_file TEXT, session_id TEXT, project TEXT,
          ts TEXT, language TEXT, path TEXT, lines INTEGER, content_hash TEXT, secrets_redacted INTEGER,
          body TEXT, partial INTEGER DEFAULT 0);
        CREATE TABLE source_stats(source TEXT, files INTEGER, bytes INTEGER, first_ts TEXT, last_ts TEXT, note TEXT);
        CREATE TABLE skipped(source TEXT, reason TEXT, n INTEGER);
        """)
        self.skips = {}
    def add(self, source, kind, source_file, session, project, ts, language, path, body, partial=0):
        body = norm(body)
        n = body.count("\n") + 1 if body else 0
        if n < MIN_LINES:
            self.skip(source, f"{kind}:<{MIN_LINES} lines"); return
        red, cnt = redact(body)
        self.c.execute("INSERT INTO occurrences(source,kind,source_file,session_id,project,ts,language,path,lines,content_hash,secrets_redacted,body,partial) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)",
                       (source, kind, source_file, session, project, ts, language, path, n, h(red), cnt, red, partial))
    def skip(self, source, reason): self.skips[(source, reason)] = self.skips.get((source, reason), 0) + 1
    def stat(self, source, files, nbytes, first, last, note=""):
        self.c.execute("INSERT INTO source_stats VALUES(?,?,?,?,?,?)", (source, files, nbytes, first, last, note))
    def close(self):
        self.c.executemany("INSERT INTO skipped VALUES(?,?,?)", [(a, b, n) for (a, b), n in self.skips.items()])
        self.c.commit(); self.c.close()

def fences(st, source, text, sf, sess, proj, ts):
    for m in FENCE_RE.finditer(text or ""):
        tag, body = m.group(1), m.group(2)
        lang = lang_for(tag=tag, body=body)
        if not lang:
            st.skip(source, f"fence:lang={tag or 'none'}"); continue
        st.add(source, "fence", sf, sess, proj, ts, lang, None, body)

def project_of(cwd, f):
    if cwd:
        p = cwd.replace(HOME, "~")
        if "/scratch-workspaces/" in p: return "claude-desktop-scratch"
        if "phonegrader" in p: return "phonegrader-tmp"
        if "/Developer/" in p: return p.split("/Developer/")[1].split("/")[0]
        return p
    return os.path.basename(os.path.dirname(f))

# ---------------------------------------------------------------- Claude Code
def claude_code(st):
    files = glob.glob(os.path.join(HOME, ".claude/projects/**/*.jsonl"), recursive=True)
    tot = sum(os.path.getsize(f) for f in files); tss = []
    for f in files:
        sess = os.path.splitext(os.path.basename(f))[0]
        pending = {}  # tool_use_id -> (name, input)
        cwd = None
        with open(f, errors="replace") as fh:
            for line in fh:
                try: d = json.loads(line)
                except Exception: continue
                ts = d.get("timestamp"); cwd = d.get("cwd") or cwd
                if ts: tss.append(ts)
                proj = project_of(cwd, f)
                sid = d.get("sessionId") or sess
                m = d.get("message")
                if not isinstance(m, dict): continue
                cont = m.get("content")
                if m.get("role") == "assistant" and isinstance(cont, list):
                    for b in cont:
                        if not isinstance(b, dict): continue
                        if b.get("type") == "text":
                            fences(st, "claude-code", b.get("text"), f, sid, proj, ts)
                        elif b.get("type") == "tool_use":
                            name, inp = b.get("name"), b.get("input") or {}
                            pending[b.get("id")] = (name, inp)
                            if name in ("Write", "create_file") and inp.get("content") is not None:
                                p = inp.get("file_path") or inp.get("path")
                                lang = lang_for(p, body=inp["content"])
                                if lang: st.add("claude-code", "write", f, sid, proj, ts, lang, p, inp["content"])
                                else: st.skip("claude-code", "write:non-script ext")
                            elif name == "Bash":
                                cmd = inp.get("command") or ""
                                got = False
                                for rx, pi, bi in ((HEREDOC_RE, 1, 3), (HEREDOC_RE2, 2, 3)):
                                    for hm in rx.finditer(cmd):
                                        p, body = hm.group(pi), hm.group(bi)
                                        lang = lang_for(p, body=body)
                                        if lang:
                                            st.add("claude-code", "heredoc", f, sid, proj, ts, lang, p, body); got = True
                                        else: st.skip("claude-code", "heredoc:non-script ext")
                                if not got and cmd.count("\n") + 1 >= MIN_LINES:
                                    st.add("claude-code", "bash_cmd", f, sid, proj, ts, "bash", None, cmd)
                # results of Edit / MultiEdit carry the original file -> reconstruct final content
                tur = d.get("toolUseResult")
                if isinstance(tur, dict) and tur.get("filePath") and ("oldString" in tur or "edits" in tur):
                    p = tur["filePath"]; lang = lang_for(p)
                    if not lang: st.skip("claude-code", "edit:non-script ext"); continue
                    orig = tur.get("originalFile")
                    edits = tur.get("edits") or [{"old_string": tur.get("oldString"), "new_string": tur.get("newString"), "replace_all": tur.get("replaceAll")}]
                    if orig is None:
                        frag = "\n".join(e.get("new_string") or "" for e in edits)
                        st.add("claude-code", "edit_fragment", f, sid, proj, ts, lang, p, frag, partial=1); continue
                    out = orig; ok = True
                    for e in edits:
                        o, n = e.get("old_string") or "", e.get("new_string") or ""
                        if o and o in out: out = out.replace(o, n) if e.get("replace_all") else out.replace(o, n, 1)
                        else: ok = False
                    st.add("claude-code", "edit", f, sid, proj, ts, lang, p, out, partial=0 if ok else 1)
    tss.sort()
    st.stat("claude-code (~/.claude/projects)", len(files), tot, tss[0] if tss else None, tss[-1] if tss else None)

# ---------------------------------------------------------------- Codex (if present)
def codex(st):
    files = glob.glob(os.path.join(HOME, ".codex/sessions/**/*.jsonl"), recursive=True)
    if not files: st.stat("codex (~/.codex)", 0, 0, None, None, "not present"); return
    tot = sum(os.path.getsize(f) for f in files)
    for f in files:
        sess = os.path.basename(f)
        for line in open(f, errors="replace"):
            try: d = json.loads(line)
            except Exception: continue
            s = json.dumps(d)
            ts = d.get("timestamp")
            pl = d.get("payload") or d
            if isinstance(pl, dict):
                if pl.get("type") == "message" and pl.get("role") == "assistant":
                    for c in pl.get("content") or []:
                        if isinstance(c, dict): fences(st, "codex", c.get("text"), f, sess, "codex", ts)
                if pl.get("type") in ("function_call", "custom_tool_call") and "apply_patch" in s:
                    args = pl.get("arguments") or pl.get("input") or ""
                    for m in re.finditer(r"\*\*\* Add File: (\S+)\n(.*?)(?=\n\*\*\* |\Z)", args, re.S):
                        body = "\n".join(l[1:] for l in m.group(2).split("\n") if l.startswith("+"))
                        lang = lang_for(m.group(1), body=body)
                        if lang: st.add("codex", "apply_patch", f, sess, "codex", ts, lang, m.group(1), body)
    st.stat("codex (~/.codex)", len(files), tot, None, None)

# ---------------------------------------------------------------- LocalAI app
def localai(st):
    f = os.path.join(HOME, "Library/Application Support/LocalAI/chats.json")
    if not os.path.exists(f): st.stat("LocalAI app", 0, 0, None, None, "not present"); return
    d = json.load(open(f)); convs = d.get("conversations", []); tss = []
    for c in convs:
        for m in c.get("messages", []):
            ts = m.get("createdAt"); tss.append(ts or "")
            if m.get("role") == "assistant":
                fences(st, "localai", m.get("content"), f, c.get("id"), "LocalAI app", ts)
            for tc in m.get("toolCalls") or []:
                a = tc.get("arguments") if isinstance(tc, dict) else None
                if isinstance(a, str):
                    try: a = json.loads(a)
                    except Exception: a = None
                if isinstance(a, dict) and a.get("content") and (a.get("path") or a.get("file_path")):
                    p = a.get("path") or a.get("file_path"); lang = lang_for(p, body=a["content"])
                    if lang: st.add("localai", "write", f, c.get("id"), "LocalAI app", ts, lang, p, a["content"])
    tss = sorted(t for t in tss if t)
    st.stat("LocalAI app chats.json", 1, os.path.getsize(f), tss[0] if tss else None, tss[-1] if tss else None, f"{len(convs)} conversations")

# ---------------------------------------------------------------- disk
DISK_ROOTS = ["Developer", "Desktop", "Documents", "Downloads", "bin", ".local/bin", "scripts", ".config", ".claude"]
PRUNE_NAMES = {"node_modules", ".venv", "venv", "env", "site-packages", ".git", "build", "dist", "DerivedData",
               "__pycache__", ".next", ".cache", "Pods", "Carthage", ".build", "vendor", ".tox", ".mypy_cache",
               "KEYS AND SHIT", ".Trash", "Pictures", "Music", "Photos Library.photoslibrary",
               ".vercel", ".output", "coverage", ".turbo", ".svelte-kit", ".nuxt", "out", "plugins", "public", "Library", "script-catalog"}
DISK_EXT = {".py", ".sh", ".bash", ".zsh", ".command", ".applescript", ".scpt", ".js", ".mjs", ".cjs", ".ts", ""}
JS_EXT = {".js", ".mjs", ".cjs", ".ts"}
JS_LIB_DIRS = re.compile(r"/(src|lib|components|app|pages|hooks|utils|types|styles|test|tests|__tests__|e2e|fixtures)/")

def js_entry(p, body, dp):
    """True for js/ts files that look like runnable entry scripts, not app/library modules."""
    fn = os.path.basename(p)
    if re.search(r"\.(test|spec|config|stories)\.", fn): return False
    if body.startswith("#!"): return True
    if re.search(r"/(scripts|bin|tools)/", p): return True
    if os.path.exists(os.path.join(dp, "package.json")): return True     # top-level server.js / index.js
    return not JS_LIB_DIRS.search(p) and not os.path.exists(os.path.join(os.path.dirname(dp), "package.json"))
PRUNE_CLAUDE = {"projects", "file-history", "paste-cache", "shell-snapshots", "cache", "plugins", "backups",
                "session-env", "sessions", "downloads", "_retired-2026-10-23"}
SF_DATALESS = 0x40000000
MEDICAL = re.compile(r"(?i)medical|health ?records|lab ?results")

def disk(st):
    n = 0; tot = 0; mt = []
    for r in DISK_ROOTS:
        root = os.path.join(HOME, r)
        if not os.path.isdir(root): continue
        for dp, dns, fns in os.walk(root):
            dns[:] = [x for x in dns if x not in PRUNE_NAMES and not x.endswith((".app", ".xcodeproj", ".photoslibrary", ".xcassets"))
                      and not MEDICAL.search(x) and not (dp == os.path.join(HOME, ".claude") and x in PRUNE_CLAUDE)]
            for fn in fns:
                p = os.path.join(dp, fn); ext = os.path.splitext(fn)[1].lower()
                if ext not in DISK_EXT: continue
                if fn.endswith((".min.js", ".d.ts")): continue
                try: s = os.lstat(p)
                except OSError: continue
                if not stat.S_ISREG(s.st_mode): continue
                if getattr(s, "st_flags", 0) & SF_DATALESS: st.skip("disk", "icloud-evicted (not downloaded)"); continue
                if s.st_size > 1_000_000: st.skip("disk", ">1MB"); continue
                if ext == "":
                    try:
                        with open(p, "rb") as fh: head = fh.read(64)
                    except OSError: continue
                    if not head.startswith(b"#!"): continue
                if ext == ".scpt":
                    try: body = subprocess.run(["osadecompile", p], capture_output=True, text=True, timeout=10).stdout
                    except Exception: st.skip("disk", "scpt decompile failed"); continue
                else:
                    try:
                        with open(p, "rb") as fh: raw = fh.read()
                    except OSError: continue
                    if b"\0" in raw[:4096]: st.skip("disk", "binary"); continue
                    body = raw.decode("utf-8", "replace")
                lang = lang_for(p, body=body)
                if not lang: continue
                if ext in JS_EXT and not js_entry(p, body, dp): st.skip("disk", "js/ts module (not an entry script)"); continue
                rel = p.replace(HOME, "~")
                parts = rel.split("/")
                proj = ("/".join(parts[1:3]) if len(parts) > 3 and parts[1] in ("Desktop", "Downloads", "Documents") else
                        parts[2] if parts[1] == "Developer" and len(parts) > 3 else "/".join(parts[:2]))
                ts = datetime.fromtimestamp(s.st_mtime, timezone.utc).isoformat()
                n += 1; tot += s.st_size; mt.append(ts)
                st.add("disk", "file", None, None, proj, ts, lang, p, body)
    mt.sort()
    st.stat("disk files", n, tot, mt[0] if mt else None, mt[-1] if mt else None, "script files found (before 10-line filter)")

if __name__ == "__main__":
    t = time.time(); st = Store()
    for fn in (claude_code, codex, localai, disk):
        fn(st); print(fn.__name__, "done", round(time.time() - t, 1), "s", file=sys.stderr)
    st.close()
