#!/usr/bin/env python3
"""Static fact extraction by code (no AI). For every script body: CLI args, env vars, files read/written,
network calls (URLs masked), destructive commands, DB tables, APIs, served endpoints, invoked scripts,
stdout format and a code-derived risk floor. Stores one row per script in script_facts.
Usage: facts.py [--ids 1,2] [--dry]   (default: all scripts whose facts are missing or stale)"""
import re, json, sys, argparse, hashlib, os
from urllib.parse import urlsplit, urlunsplit, parse_qsl, urlencode
import pg

VERSION = "f1"
HOME_RE = re.compile(r"^(?:" + re.escape(os.path.expanduser("~")) + r"|\$\{?HOME\}?|~)(?=/|$)")

# ------------------------------------------------------------------ helpers
DOCSTRING = re.compile(r'(?m)^[ \t]*[rRbBuU]?("""|\'\'\')[\s\S]*?\1')
def strip_comments(lang, text):
    """Blank out comment lines and python docstrings (keeps line numbers). Shebang kept."""
    if lang == "python":
        text = DOCSTRING.sub(lambda m: "\n" * m.group(0).count("\n"), text)
    out = []
    for i, l in enumerate(text.split("\n")):
        t = l.lstrip()
        if i == 0 and t.startswith("#!"): out.append(l); continue
        if lang in ("bash", "zsh", "python", "ruby", "perl") and t.startswith("#"): out.append(""); continue
        if lang in ("javascript", "typescript", "swift", "go", "rust") and t.startswith("//"): out.append(""); continue
        if lang == "sql" and t.startswith("--"): out.append(""); continue
        if lang == "applescript" and t.startswith("--"): out.append(""); continue
        out.append(l)
    return "\n".join(out)

def norm_path(p, vars_=None):
    p = p.strip().strip("'\"`").rstrip(";,)")
    if vars_:
        for _ in range(3):
            q = re.sub(r"\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?", lambda m: vars_.get(m.group(1), m.group(0)), p)
            if q == p: break
            p = q
    p = p.strip("'\"")
    p = HOME_RE.sub("~", p)
    p = re.sub(r"/+", "/", p)
    return p

GENERIC_FILES = {"/dev/null", "/dev/stdout", "/dev/stderr", "/dev/stdin", "/dev/tty", "-", "&1", "&2"}
def looks_path(p):
    if not p or len(p) > 300 or " " in p or p in GENERIC_FILES or p.startswith(("&", "-", "http:", "https:", ">", "<", "/dev/", "|")): return False
    if p in ("/", "~", "~/", ".", "..") or p.endswith("/dev/null"): return False
    if re.fullmatch(r"\$\{?\w+\}?", p): return False                    # bare $VAR, unknowable
    if re.fullmatch(r"[\d.]+", p): return False
    return "/" in p or p.startswith("~") or bool(re.search(r"\.[A-Za-z0-9]{1,6}$", p))

SECRETISH_Q = re.compile(r"(?i)key|token|secret|sig|signature|pass|auth|code|session|cred|jwt")
def mask_url(u):
    u = u.rstrip(".,;:)]'\"`\\")
    if u.count("{") < u.count("}"): u = u.rstrip("}")
    try: sp = urlsplit(u)
    except ValueError: return u
    host = sp.hostname or ""
    labels = host.split(".")
    labels = ["[MASKED]" if (len(l) >= 16 and re.search(r"\d", l) and re.search(r"[a-z]", l)) else l for l in labels]
    try: port = sp.port
    except ValueError: port = None
    netloc = ".".join(labels) + (f":{port}" if port else "") if host else sp.netloc
    if "@" in sp.netloc: netloc = "[USER]@" + netloc
    segs = ["[MASKED]" if (len(s) >= 24 and re.search(r"\d", s) and re.search(r"[A-Za-z]", s) and "$" not in s and "{" not in s) else s
            for s in sp.path.split("/")]
    q = parse_qsl(sp.query, keep_blank_values=True)
    q = [(k, "[MASKED]" if SECRETISH_Q.search(k) else v) for k, v in q]
    return urlunsplit((sp.scheme, netloc, "/".join(segs), urlencode(q, safe="[]$:{}"), ""))

API_HOSTS = [
    (r"api\.airtable\.com|airtable\.com", "Airtable"), (r"api\.telegram\.org", "Telegram Bot API"),
    (r"hooks\.slack\.com|slack\.com/api", "Slack"), (r"api\.github\.com|github\.com", "GitHub"),
    (r"api\.openai\.com", "OpenAI"), (r"api\.anthropic\.com", "Anthropic"), (r"api\.x\.ai", "xAI"),
    (r"generativelanguage\.googleapis\.com", "Gemini"), (r"googleapis\.com", "Google API"),
    (r"api\.cloudflare\.com", "Cloudflare API"), (r":11434", "Ollama"), (r"nocodb|:8080/api/v[12]", "NocoDB"),
    (r"ntfy\.sh", "ntfy"), (r"api\.pushover\.net", "Pushover"), (r"discord(app)?\.com/api", "Discord"),
    (r"api\.stripe\.com", "Stripe"), (r"graph\.microsoft\.com", "Microsoft Graph"), (r"api\.twilio\.com", "Twilio"),
    (r"upwork\.com", "Upwork"), (r"api\.elevenlabs\.io", "ElevenLabs"), (r"huggingface\.co", "Hugging Face"),
    (r"pypi\.org|files\.pythonhosted", "PyPI"), (r"registry\.npmjs", "npm"),
]
API_IMPORTS = {"openai": "OpenAI", "anthropic": "Anthropic", "pyairtable": "Airtable", "airtable": "Airtable",
               "boto3": "AWS", "botocore": "AWS", "slack_sdk": "Slack", "telegram": "Telegram", "stripe": "Stripe",
               "twilio": "Twilio", "psycopg": "Postgres", "psycopg2": "Postgres", "asyncpg": "Postgres", "pg": "Postgres",
               "sqlite3": "SQLite", "better-sqlite3": "SQLite", "ollama": "Ollama", "googleapiclient": "Google API",
               "gspread": "Google Sheets", "@anthropic-ai/sdk": "Anthropic", "@airtable/blocks": "Airtable",
               "playwright": "Playwright browser", "selenium": "Selenium browser", "puppeteer": "Puppeteer browser",
               "imaplib": "IMAP mail", "smtplib": "SMTP mail", "paramiko": "SSH", "redis": "Redis", "pymongo": "MongoDB",
               "nodemailer": "SMTP mail", "discord": "Discord", "tweepy": "X/Twitter", "praw": "Reddit"}
APP_API = re.compile(r'tell\s+application\s+"([^"]+)"')

BASH_STD_ENV = set("HOME USER PATH PWD SHELL TERM TMPDIR RANDOM SECONDS LINENO BASH_SOURCE IFS OSTYPE UID EUID HOSTNAME PPID "
                   "OLDPWD LANG LC_ALL BASH_REMATCH PIPESTATUS FUNCNAME REPLY OPTARG OPTIND EPOCHSECONDS BASHPID LOGNAME "
                   "DISPLAY XDG_RUNTIME_DIR SSH_AUTH_SOCK ZSH_VERSION BASH_VERSION MACHTYPE HOSTTYPE COLUMNS LINES SUDO_USER".split())

DESTRUCTIVE = [  # (regex, label, level)
    (r"\brm\s+(?:-[a-zA-Z]*[rR][a-zA-Z]*|--recursive)\b", "rm -r", "high"),
    (r"\brm\s+(?!-[a-zA-Z]*[rR])", "rm", "medium"),
    (r"(?<![.\w-])(shutdown|reboot|poweroff|halt)\b(?!\s*\()", "shutdown/reboot", "high"),
    (r"\bsystemctl\s+(?:--user\s+)?(poweroff|reboot|suspend|hibernate)\b", "systemctl power", "high"),
    (r"\bsystemctl\s+(?:--user\s+)?(stop|disable|mask|restart|kill)\b", "systemctl stop/restart", "medium"),
    (r"\bpmset\s+sleepnow|\bpmset\b", "pmset", "medium"),
    (r"\bosascript\b", "osascript", "medium"),
    (r"(?<![.\w-])(kill|killall|pkill)\s+-?", "kill", "medium"),
    (r"(?<![.\w-])sudo\b", "sudo", "medium"),
    (r"\bdd\s+if=", "dd", "high"), (r"\bmkfs(\.\w+)?\b", "mkfs", "high"),
    (r"\bdiskutil\s+(erase\w*|partition\w*|zeroDisk|secureErase|apfs\s+delete\w*)", "diskutil erase", "high"),
    (r"\bdiskutil\s+(unmount\w*|eject)", "diskutil unmount", "medium"),
    (r"\blaunchctl\s+(unload|bootout|remove|disable|kickstart\s+-k)", "launchctl unload", "medium"),
    (r"\bcrontab\s+-r\b", "crontab -r", "high"),
    (r"\bgit\s+push\s+[^\n]*(--force\b|-f\b|--force-with-lease)", "git push --force", "high"),
    (r"\bgit\s+reset\s+--hard\b", "git reset --hard", "high"), (r"\bgit\s+clean\s+-\w*f", "git clean -f", "high"),
    (r"\bgit\s+push\b", "git push", "medium"), (r"\bgit\s+branch\s+-D\b", "git branch -D", "medium"),
    (r"\bchmod\s+-R\b|\bchown\s+-R\b", "chmod/chown -R", "medium"),
    (r"\bfind\b[^\n|;]*\s-delete\b", "find -delete", "high"), (r"\bshred\b|\bsrm\b", "shred", "high"),
    (r"\b(docker|podman)\s+(rm|rmi|kill|stop)\b", "container rm/stop", "medium"),
    (r"\b(docker|podman)\s+(system\s+prune|volume\s+rm|volume\s+prune)", "container prune", "high"),
    (r"\bDROP\s+(TABLE|DATABASE|SCHEMA|VIEW|ROLE)\b", "SQL DROP", "high"),
    (r"\bTRUNCATE\s+(TABLE\s+)?[a-z_\"]", "SQL TRUNCATE", "high"),
    (r"\bDELETE\s+FROM\b", "SQL DELETE", "medium"),
    (r"\btmutil\s+(delete\w*|disable)", "tmutil delete", "high"),
    (r"\b(brew|pip3?|npm|apt(-get)?|dnf)\s+(uninstall|remove|purge)\b", "uninstall software", "medium"),
    (r"\b(brew|pip3?|npm|apt(-get)?|dnf|cargo|gem)\s+install\b", "install software", "low"),
    (r"\bshutil\.rmtree\b", "shutil.rmtree", "high"), (r"\bos\.(remove|unlink|rmdir)\b|\.unlink\(\)|\.rmdir\(\)", "delete file (python)", "medium"),
    (r"\bos\.kill\b|\bprocess\.kill\b", "kill (code)", "medium"),
    (r"\bfs(?:\.promises)?\.(rm|rmSync|unlink|unlinkSync|rmdir|rmdirSync)\b|\bfsp?\.rm\(", "delete file (node)", "medium"),
    (r"\bremoveItem\(at", "removeItem (swift)", "medium"),
    (r"\bdefaults\s+(write|delete)\b", "defaults write", "medium"),
    (r"\bnvram\b|\bcsrutil\b|\bspctl\b|\bscutil\s+--set\b", "system config", "high"),
    (r"\bsecurity\s+(delete|add)-\w+", "keychain change", "medium"),
]
DESTRUCTIVE = [(re.compile(r), l, lv) for r, l, lv in DESTRUCTIVE]
LEVEL = {"none": 0, "low": 1, "medium": 2, "high": 3}

SQL_WRITE = re.compile(r"(?i)\b(INSERT\s+INTO|UPDATE|DELETE\s+FROM|CREATE\s+(?:TABLE|VIEW|MATERIALIZED\s+VIEW|INDEX\s+\w+\s+ON)(?:\s+IF\s+NOT\s+EXISTS)?|ALTER\s+TABLE(?:\s+IF\s+EXISTS)?|DROP\s+TABLE(?:\s+IF\s+EXISTS)?|TRUNCATE(?:\s+TABLE)?|COPY|UPSERT\s+INTO|REPLACE\s+INTO|INSERT\s+OR\s+\w+\s+INTO)\s+(?:ONLY\s+)?([A-Za-z_][\w]*(?:\.[A-Za-z_]\w*)?|\"[^\"]+\")")
SQL_READ = re.compile(r"(?i)\b(FROM|JOIN)\s+([A-Za-z_][\w]*(?:\.[A-Za-z_]\w*)?|\"[^\"]+\")")
SQL_CTX = re.compile(r"(?i)\b(SELECT\b[\s\S]{0,400}?\bFROM|INSERT\s+INTO|UPDATE\s+\w+\s+SET|DELETE\s+FROM|CREATE\s+TABLE|ALTER\s+TABLE)")
SQL_NOT_TABLE = set("select where set values on as and or not null true false the a an of to in is it this that json jsonb "
                    "lateral unnest generate_series information_schema pg_catalog pg_stat_activity dual stdin stdout "
                    "now current_date only exists if table".split())

STR_LIT = re.compile(r'''("""[\s\S]*?"""|\'\'\'[\s\S]*?\'\'\'|`[^`]*`|"(?:[^"\\\n]|\\.)*"|'(?:[^'\\\n]|\\.)*')''')
SQL_STR = re.compile(r'''("""[\s\S]{0,6000}?"""|\'\'\'[\s\S]{0,6000}?\'\'\'|`[^`]{0,6000}`|"(?:[^"\\]|\\.){0,6000}"|'(?:[^'\\]|\\.){0,6000}')''')
URL_RE = re.compile(r"""\b((?:https?|wss?)://[^\s"'`<>()\[\]\\|^]+)""")
SQL_SEG = re.compile(r"(?is)\b(SELECT|INSERT\s+(?:OR\s+\w+\s+)?INTO|UPDATE|DELETE\s+FROM|CREATE\s+(?:TABLE|VIEW|INDEX)|ALTER\s+TABLE|DROP\s+TABLE|TRUNCATE|WITH\s+\w+\s+AS|COPY)\b[^;\"`]{0,1500}")

def lineno(text, pos): return text.count("\n", 0, pos) + 1

def add(d, key, val, limit=60):
    if val is None: return
    lst = d.setdefault(key, [])
    if val not in lst and len(lst) < limit: lst.append(val)

# ------------------------------------------------------------------ shell analysis (also used for commands in other languages)
def logical_lines(text):
    """Join backslash-continued lines; yield (first_line_no, joined)."""
    buf, start = [], None
    for i, l in enumerate(text.split("\n"), 1):
        if start is None: start = i
        if l.rstrip().endswith("\\"):
            buf.append(l.rstrip()[:-1]); continue
        buf.append(l); yield start, " ".join(buf); buf, start = [], None
    if buf: yield start, " ".join(buf)

def shell_facts(text, f, vars_, base_line=0):
    for i, raw in logical_lines(text):
        line = raw.strip()
        if not line or line.startswith("#"): continue
        ln = base_line + i
        # redirects
        for m in re.finditer(r"(?<![<>&\d])(>>?|&>)\s*(\"[^\"]+\"|'[^']+'|[^\s;|&)]+)", line):
            p = norm_path(m.group(2), vars_)
            if looks_path(p): add(f, "files_written", p)
        for m in re.finditer(r"(?<![<])<\s*(\"[^\"]+\"|'[^']+'|[^\s;|&<(]+)", line):
            if m.group(1).startswith(("<", "(")): continue
            p = norm_path(m.group(1), vars_)
            if looks_path(p): add(f, "files_read", p)
        for m in re.finditer(r"\btee\s+(?:-a\s+)?(\"[^\"]+\"|'[^']+'|[^\s;|&)]+)", line):
            p = norm_path(m.group(1), vars_)
            if looks_path(p): add(f, "files_written", p)
        for m in re.finditer(r"(?:^|[;&|]\s*|\bthen\s+|\bdo\s+|\$\()\s*(?:sudo\s+)?(cat|source|\.|jq\s+[^|;]*?|head|tail|less|wc|sqlite3|grep\s+[^|;]*?)\s+((?:\"[^\"]+\"|'[^']+'|[~/$][^\s;|&)]*)(?:\s+|$))", line):
            cmd = m.group(1).split()[0]
            p = norm_path(m.group(2), vars_)
            if looks_path(p): add(f, "db_files" if cmd == "sqlite3" else "files_read", p)
        for m in re.finditer(r"\b(cp|mv|rsync|install|ln)\s+(?:-[\w-]+\s+)*((?:[^\s;|&]+\s+)+?)([^\s;|&]+)\s*(?:$|[;|&])", line):
            srcs = [norm_path(x, vars_) for x in m.group(2).split() if not x.startswith("-")]
            dst = norm_path(m.group(3), vars_)
            for s in srcs:
                if looks_path(s) and ":" not in s: add(f, "files_read", s)
            if looks_path(dst) and ":" not in dst: add(f, "files_written", dst)
        for m in re.finditer(r"\b(mkdir|touch)\s+(?:-\w+\s+)*([^\s;|&]+)", line):
            p = norm_path(m.group(2), vars_)
            if looks_path(p): add(f, "files_written", p)
        for m in re.finditer(r"\bsed\s+-i\S*\s+(?:''\s+)?(?:-e\s+)?(?:'[^']*'|\"[^\"]*\")\s+([^\s;|&]+)", line):
            p = norm_path(m.group(1), vars_)
            if looks_path(p): add(f, "files_modified", p)
        # network
        if re.search(r"\b(curl|wget|http|xh)\b", line):
            method = "GET"
            mm = re.search(r"(?:-X|--request)\s+['\"]?(\w+)", line)
            if mm: method = mm.group(1).upper()
            elif re.search(r"\s(-d|--data\S*|-F|--form|--json|-T|--upload-file)\b", line) or re.search(r"\bwget\s+[^\n]*--post", line): method = "POST"
            urls = URL_RE.findall(line)
            for u in urls: add(f, "network", {"via": "curl" if "curl" in line else "http", "method": method, "url": mask_url(u), "line": ln})
            if not urls and re.search(r"\bcurl\b", line):
                cands = [c.strip('"') for c in re.findall(r"(\"\$\{?\w+\}?[^\"\s]*\"|\$\{?\w+\}?[^\s\"']*)", line[line.find("curl"):])]
                good = [c for c in cands if "/" in c or re.search(r"(?i)url|host|endpoint|base|api\b", c)]
                if good: add(f, "network", {"via": "curl", "method": method, "url": good[0], "line": ln})
            mo = re.search(r"\s-o\s+([^\s;|&]+)", line)
            if mo and re.search(r"\bcurl\b", line):
                p = norm_path(mo.group(1), vars_)
                if looks_path(p): add(f, "files_written", p)
        for m in re.finditer(r"\b(ssh|scp|rsync|mosh|sftp)\b((?:\s+-[\w]+(?:\s+(?!-)[^\s@]+(?=\s+-))?)*)\s+([^\s;|&]*@?[\w.\-$\{\}]+)(?::(\S*))?", line):
            tool, target = m.group(1), m.group(3)
            if tool in ("scp", "rsync") and ":" not in m.group(0): continue
            if tool == "ssh" and target.startswith("-"): continue
            if target in ("-o", "-i", "-p", "-t", "-n", "-N", "-L", "-R", "-f"): continue
            remote_cmd = None
            if tool == "ssh":
                rest = line[m.end():].strip()
                remote_cmd = rest[:120] or None
            add(f, "network", {"via": tool, "target": re.sub(r"^[^@\s]+@", "[USER]@", target) if "@" in target and not re.match(r"^[^@]+@[\d.]+$", target) else target,
                               "remote_cmd": remote_cmd, "line": ln})
        # invocations of other scripts
        for m in re.finditer(r"(?:^|[;&|(]\s*|\bthen\s+|\bdo\s+|\$\(\s*|exec\s+|nohup\s+|sudo\s+)(?:(?:python3?|bash|sh|zsh|node|deno|bun|ruby|osascript|swift|uv\s+run|npx\s+tsx|tsx)\s+)?((?:[~/.$][^\s;|&)\"']*)?[\w.\-]+\.(?:py|sh|zsh|js|mjs|ts|rb|applescript|scpt|command)|(?:~|\$HOME|\$\{HOME\}|" + re.escape(os.path.expanduser("~")) + r")/(?:bin|scripts|\.local/bin)/[\w.\-]+|\./[\w.\-]+)\b", line):
            add(f, "invokes", norm_path(m.group(1), vars_))
        # db via psql/sqlite3 command lines
        mm = re.search(r"\bpsql\b[^\n]*?(?:-d\s+|--dbname[= ])([\w\-]+)", line)
        if mm: add(f, "databases", "postgres:" + mm.group(1))
        mm = re.search(r"\bsqlite3\s+(?:-\w+\s+)*([^\s;|&]+)", line)
        if mm:
            p = norm_path(mm.group(1), vars_)
            if looks_path(p): add(f, "databases", "sqlite:" + p)

def shell_vars(text):
    vars_ = {}
    for m in re.finditer(r"(?m)^\s*(?:export\s+|local\s+|readonly\s+)?([A-Za-z_][A-Za-z0-9_]*)=(\"[^\"\n]*\"|'[^'\n]*'|[^\s;#]+)", text):
        v = m.group(2).strip("'\"")
        if "$(" in v or "`" in v: continue
        vars_.setdefault(m.group(1), v)
    return vars_

def shell_args_env(text, f, assigned):
    if re.search(r"\$(\{)?[1-9]\b|\$@|\$\*|\$#|\$\{@", text):
        nums = sorted(set(re.findall(r"\$\{?([1-9])\b", text)))
        if nums: add(f, "cli_args", "positional $" + ",$".join(nums))
        if re.search(r"\$@|\$\*|\$\{@", text): add(f, "cli_args", "$@ (all args)")
    for m in re.finditer(r"getopts\s+['\"]?([\w:]+)", text): add(f, "cli_args", "getopts " + m.group(1))
    for m in re.finditer(r"(?m)^\s*\(?((?:-{1,2}[\w][\w-]*\|?)+)\)", text):
        for o in m.group(1).split("|"):
            if o.startswith("-"): add(f, "cli_args", o)
    for m in re.finditer(r"\$\{?([A-Z][A-Z0-9_]{2,})\b", text):
        n = m.group(1)
        if n in BASH_STD_ENV or n in assigned: continue
        add(f, "env_vars", n)

# ------------------------------------------------------------------ per-language
def python_facts(text, f, consts, base=None):
    rel = lambda p: (base.rstrip("/") + "/" + p) if base and p and not p.startswith(("/", "~", "$")) else p
    for m in re.finditer(r"add_argument\(\s*(['\"][^'\"]+['\"](?:\s*,\s*['\"][^'\"]+['\"])?)", text):
        add(f, "cli_args", " / ".join(x.strip("'\" ") for x in m.group(1).split(",")))
    for m in re.finditer(r"@click\.(?:option|argument)\(\s*['\"]([^'\"]+)", text): add(f, "cli_args", m.group(1))
    for m in re.finditer(r"sys\.argv\[(\d+)(?::\]?)?", text): add(f, "cli_args", f"sys.argv[{m.group(1)}]")
    if re.search(r"\bfor\s+\w+\s+in\s+sys\.stdin|sys\.stdin\.read|input\(\)|fileinput\.input", text): add(f, "stdin", "reads stdin")
    for m in re.finditer(r"os\.environ\s*\[\s*['\"](\w+)|os\.environ\.get\(\s*['\"](\w+)|os\.getenv\(\s*['\"](\w+)|environ\.get\(\s*['\"](\w+)|environ\[['\"](\w+)", text):
        add(f, "env_vars", next(g for g in m.groups() if g))
    def resolve(arg):
        arg = arg.strip()
        m = re.match(r"""^(?:Path\(|os\.path\.expanduser\(|pathlib\.Path\()?\s*[rfb]?(['"])(.+?)\1""", arg)
        if m: return [rel(norm_path(m.group(2)))]
        m = re.match(r"^([A-Za-z_]\w*)\b", arg)
        if m and m.group(1) in consts: return [rel(x) for x in consts[m.group(1)]]
        return []
    for m in re.finditer(r"\bopen\(\s*([^,()\n]+(?:\([^()\n]*\))?[^,()\n]*)(?:,\s*(?:mode\s*=\s*)?([rfb]?['\"]([rwaxbt+]+)['\"]))?", text):
        mode = m.group(3) or "r"
        for p in resolve(m.group(1)):
            if looks_path(p): add(f, "files_written" if re.search(r"[wax+]", mode) else "files_read", p)
    for m in re.finditer(r"([\w\"'()/.~\-]+?)\.(write_text|write_bytes|read_text|read_bytes|mkdir|touch|unlink)\(", text):
        for p in resolve(m.group(1).replace("Path(", "", 1) if m.group(1).startswith("Path(") else m.group(1)):
            if looks_path(p): add(f, "files_read" if m.group(2).startswith("read") else "files_written", p)
    for m in re.finditer(r"\b(?:pd\.)?(read_csv|read_json|read_excel|read_parquet|to_csv|to_json|to_excel|to_parquet|savefig|imwrite|imread|load_workbook)\(\s*([^,)\n]+)", text):
        for p in resolve(m.group(2)):
            if looks_path(p): add(f, "files_read" if m.group(1).startswith(("read", "imread", "load")) else "files_written", p)
    for m in re.finditer(r"sqlite3\.connect\(\s*([^,)\n]+)", text):
        p = resolve(m.group(1))
        add(f, "databases", "sqlite:" + (p[0] if p else "?"))
    if re.search(r"psycopg2?\.connect|asyncpg\.connect|create_engine\(\s*['\"]postgres", text): add(f, "databases", "postgres")
    for m in re.finditer(r"\b(requests|httpx|session|sess|client|http)\.(get|post|put|patch|delete|request)\(\s*([^,)\n]+)", text):
        u = m.group(3).strip()
        if m.group(1) not in ("requests", "httpx") and not re.search(r"(?i)://|url|endpoint|base|api|f['\"]/", u): continue
        um = URL_RE.search(u)
        ru = [x for x in resolve(u) if "://" in x]
        url = mask_url(um.group(1)) if um else (mask_url(ru[0]) if ru else u[:80])
        add(f, "network", {"via": m.group(1), "method": m.group(2).upper() if m.group(2) != "request" else "?", "url": url, "line": lineno(text, m.start())})
    for m in re.finditer(r"urlopen\(\s*([^,)\n]+)|urllib\.request\.Request\(\s*([^,)\n]+)", text):
        u = (m.group(1) or m.group(2)).strip()
        um = URL_RE.search(u)
        meth = "POST" if re.search(r"data\s*=|method\s*=\s*['\"](POST|PUT|PATCH|DELETE)", text[m.start():m.start() + 400]) else "GET"
        add(f, "network", {"via": "urllib", "method": meth, "url": mask_url(um.group(1)) if um else u[:80], "line": lineno(text, m.start())})
    for m in re.finditer(r"^\s*(?:import|from)\s+([\w.]+)", text, re.M): add(f, "imports", m.group(1).split(".")[0])
    for m in re.finditer(r"@\w+\.(route|get|post|put|delete|patch)\(\s*['\"]([^'\"]+)", text):
        add(f, "serves", {"route": m.group(2), "method": m.group(1).upper() if m.group(1) != "route" else "ANY"})
    for m in re.finditer(r"(?:port\s*=\s*|HTTPServer\(\s*\(\s*['\"][^'\"]*['\"]\s*,\s*|\.run\([^)]*port\s*=\s*)(\d{2,5})", text):
        add(f, "serves", {"port": int(m.group(1))})
    # commands run from python
    cmds = []
    for m in re.finditer(r"(?:subprocess\.(?:run|call|check_call|check_output|Popen)|os\.system|os\.popen|sh\()\(\s*(\[[^\]]*\]|f?['\"]{1,3}[\s\S]{0,400}?['\"]{1,3})", text):
        a = m.group(1)
        if a.startswith("["): cmds.append((" ".join(re.findall(r"['\"]([^'\"]*)['\"]", a)), lineno(text, m.start())))
        else: cmds.append((a.strip("f'\""), lineno(text, m.start())))
    for c, ln in cmds: add(f, "commands_run", c[:160])
    return cmds

def js_facts(text, f, consts):
    if re.search(r"process\.argv", text): add(f, "cli_args", "process.argv")
    for m in re.finditer(r"\.option\(\s*['\"]([^'\"]+)", text): add(f, "cli_args", m.group(1))
    for m in re.finditer(r"process\.env\.(\w+)|process\.env\[['\"](\w+)|Deno\.env\.get\(['\"](\w+)|Bun\.env\.(\w+)", text):
        add(f, "env_vars", next(g for g in m.groups() if g))
    if re.search(r"process\.stdin|readline\.createInterface\(\s*\{\s*input:\s*process\.stdin", text): add(f, "stdin", "reads stdin")
    def resolve(a):
        a = a.strip()
        m = re.match(r"""^(['"`])([^'"`]+)\1""", a)
        if m: return norm_path(m.group(2).replace("${os.homedir()}", "~").replace("${HOME}", "~"))
        m = re.match(r"^([A-Za-z_$][\w$]*)\b", a)
        return (consts.get(m.group(1)) or [None])[0] if m else None
    for m in re.finditer(r"\b(?:fs|fsp|fs\.promises|Deno|Bun)\.(readFileSync|readFile|createReadStream|readdirSync|readdir|readTextFile|file|existsSync|writeFileSync|writeFile|appendFileSync|appendFile|createWriteStream|mkdirSync|mkdir|writeTextFile|write|copyFileSync|renameSync)\(\s*([^,)\n]+)", text):
        p = resolve(m.group(2))
        if p and looks_path(p): add(f, "files_read" if re.match(r"read|createRead|exists|file$", m.group(1)) else "files_written", p)
    for m in re.finditer(r"\bfetch\(\s*([^,)\n]+)(?:,\s*\{([^}]{0,300}))?", text):
        u = m.group(1).strip(); um = URL_RE.search(u)
        mm = re.search(r"method:\s*['\"](\w+)", m.group(2) or "")
        add(f, "network", {"via": "fetch", "method": (mm.group(1).upper() if mm else "GET"), "url": mask_url(um.group(1)) if um else u[:80], "line": lineno(text, m.start())})
    for m in re.finditer(r"\baxios\.(get|post|put|patch|delete)\(\s*([^,)\n]+)", text):
        u = m.group(2).strip(); um = URL_RE.search(u)
        add(f, "network", {"via": "axios", "method": m.group(1).upper(), "url": mask_url(um.group(1)) if um else u[:80], "line": lineno(text, m.start())})
    for m in re.finditer(r"\b(?:app|router|server|fastify)\.(get|post|put|delete|patch|all|use)\(\s*['\"](/[^'\"]*)", text):
        add(f, "serves", {"route": m.group(2), "method": m.group(1).upper()})
    for m in re.finditer(r"\.listen\(\s*(\d{2,5})|\bport\s*[:=]\s*(\d{2,5})|PORT\s*\|\|\s*(\d{2,5})|\?\?\s*(\d{4,5})\b", text):
        add(f, "serves", {"port": int(next(g for g in m.groups() if g))})
    for m in re.finditer(r"""(?:require\(\s*|from\s+|import\s+)['"]([@\w][\w./\-]*)['"]""", text):
        n = m.group(1); add(f, "imports", "/".join(n.split("/")[:2]) if n.startswith("@") else n.split("/")[0].replace("node:", ""))
    cmds = []
    for m in re.finditer(r"\b(?:exec|execSync|spawn|spawnSync|execFile|execFileSync|\$)\s*\(?\s*(`[^`]{0,400}`|['\"][^'\"\n]{0,300}['\"])(?:\s*,\s*\[([^\]]*)\])?", text):
        c = m.group(1).strip("`'\"") + (" " + " ".join(re.findall(r"['\"]([^'\"]*)['\"]", m.group(2))) if m.group(2) else "")
        cmds.append((c, lineno(text, m.start()))); add(f, "commands_run", c[:160])
    return cmds

def swift_facts(text, f):
    if re.search(r"CommandLine\.arguments|ProcessInfo\.processInfo\.arguments", text): add(f, "cli_args", "CommandLine.arguments")
    for m in re.finditer(r"environment\[\s*\"(\w+)\"\]", text): add(f, "env_vars", m.group(1))
    for m in re.finditer(r"\bURL\(\s*(?:string|fileURLWithPath):\s*\"([^\"]+)\"", text):
        v = m.group(1)
        if "://" in v: add(f, "network", {"via": "URLSession", "method": "?", "url": mask_url(v), "line": lineno(text, m.start())})
        elif looks_path(norm_path(v)): add(f, "files_referenced", norm_path(v))
    for m in re.finditer(r"^\s*import\s+(\w+)", text, re.M): add(f, "imports", m.group(1))
    cmds = []
    for m in re.finditer(r"(?:launchPath|executableURL)\s*=\s*(?:URL\(fileURLWithPath:\s*)?\"([^\"]+)\"[\s\S]{0,300}?arguments\s*=\s*\[([^\]]*)\]", text):
        c = m.group(1) + " " + " ".join(re.findall(r"\"([^\"]*)\"", m.group(2)))
        cmds.append((c, lineno(text, m.start()))); add(f, "commands_run", c[:160])
    return cmds

def applescript_facts(text, f):
    for m in APP_API.finditer(text): add(f, "apis", "app: " + m.group(1))
    cmds = []
    for m in re.finditer(r'do shell script\s+"((?:[^"\\]|\\.)*)"', text):
        cmds.append((m.group(1).replace('\\"', '"'), lineno(text, m.start()))); add(f, "commands_run", m.group(1)[:160])
    return cmds

def consts_of(text):
    c = {}
    for m in re.finditer(r"""(?m)^\s*(?:export\s+)?(?:const\s+|let\s+|var\s+)?([A-Za-z_]\w*)\s*(?::\s*\w+\s*)?=\s*(?:Path\(|os\.path\.expanduser\(|path\.join\(\s*os\.homedir\(\)\s*,\s*|pathlib\.Path\()?\s*[rfb]?(['"`])([^'"`\n]+)\2""", text):
        v = m.group(3)
        if m.group(0).find("homedir()") >= 0: v = "~/" + v
        c.setdefault(m.group(1), [])
        if norm_path(v) not in c[m.group(1)]: c[m.group(1)].append(norm_path(v))
    # NAME = BASE / "x"  (pathlib)
    for m in re.finditer(r"""(?m)^\s*([A-Za-z_]\w*)\s*=\s*([A-Za-z_]\w*)\s*/\s*['"]([^'"\n]+)['"]""", text):
        if m.group(2) in c: c.setdefault(m.group(1), [b.rstrip("/") + "/" + m.group(3) for b in c[m.group(2)]])
    for m in re.finditer(r"""(?m)^\s*([A-Za-z_]\w*)\s*=\s*os\.path\.join\(\s*([A-Za-z_]\w*)\s*,\s*['"]([^'"\n]+)['"]\s*\)""", text):
        if m.group(2) in c: c.setdefault(m.group(1), [b.rstrip("/") + "/" + m.group(3) for b in c[m.group(2)]])
    return c

# ------------------------------------------------------------------ main extractor
def extract(lang, path, body):
    f = {}
    text = strip_comments(lang or "", body)
    cmds = []
    vars_ = shell_vars(text) if lang in ("bash", "zsh") else {}
    consts = consts_of(text)
    if lang in ("bash", "zsh"):
        # interpreters fed inline code: python3 - <<'X' ... X, python3 -c '...', node -e, osascript <<
        inner = []
        for m in re.finditer(r"(?s)\b(python3?|node|osascript|psql|sqlite3)\b[^\n]*?<<-?\s*['\"]?(\w+)['\"]?[^\n]*\n(.*?)\n\s*\2\b", text):
            inner.append((m.group(1), m.group(3), text[:m.start()]))
        for m in re.finditer(r"""\b(python3?|node)\s+-[ce]\s+(['"])(.*?)(?<!\\)\2""", text, re.S):
            inner.append((m.group(1), m.group(3), text[:m.start()]))
        for interp, code, before in inner:
            cds = re.findall(r"(?:^|[;&\n]\s*)cd\s+([^\s;&|]+)", before)
            base = norm_path(cds[-1], vars_) if cds else None
            il = {"python": "python", "python3": "python", "node": "javascript", "osascript": "applescript"}.get(interp)
            if il == "python": cmds += [(c, lineno(text, text.find(code)) + ln - 1) for c, ln in python_facts(code, f, consts_of(code), base)]
            elif il == "javascript": cmds += js_facts(code, f, consts_of(code))
            elif il == "applescript": cmds += applescript_facts(code, f)
            add(f, "embedded_code", interp)
        shell_facts(text, f, vars_)
        shell_args_env(text, f, set(vars_) | set(re.findall(r"(?m)^\s*(?:local\s+|declare\s+-\w+\s+)?([A-Za-z_]\w*)=", text))
                       | set(re.findall(r"\bread\s+(?:-\w+\s+)*([\w ]+)", text) and " ".join(re.findall(r"\bread\s+(?:-\w+\s+)*([\w ]+)", text)).split())
                       | set(re.findall(r"\bfor\s+(\w+)\s+in", text)))
        if re.search(r"\bread\s+(-\w+\s+)*\w|\bcat\s*-\s|<&0|/dev/stdin", text): add(f, "stdin", "reads stdin")
    elif lang == "python": cmds = python_facts(text, f, consts)
    elif lang in ("javascript", "typescript"): cmds = js_facts(text, f, consts)
    elif lang == "swift": cmds = swift_facts(text, f)
    elif lang == "applescript": cmds = applescript_facts(text, f)
    for c, ln in cmds:
        shell_facts(c, f, vars_, base_line=ln - 1)
    # URLs anywhere (string literals, comments excluded) not yet captured
    seen = {n.get("url") for n in f.get("network", []) if isinstance(n, dict)}
    for m in URL_RE.finditer(text):
        u = mask_url(m.group(1))
        if u in seen or re.search(r"(?i)\.(png|jpg|svg|gif|css)$|schema|w3\.org|example\.(com|org)|apple\.com/DTDs|localhost:\$", u): continue
        seen.add(u); add(f, "urls_referenced", u)
    # APIs
    allurls = [n.get("url", "") for n in f.get("network", []) if isinstance(n, dict)] + f.get("urls_referenced", []) + \
              [n.get("target", "") for n in f.get("network", []) if isinstance(n, dict)]
    for u in allurls:
        for rx, name in API_HOSTS:
            if u and re.search(rx, u): add(f, "apis", name); break
        else:
            hm = re.match(r"\w+://([^/:\s]+)(?::(\d+))?", u or "")
            if hm:
                host = hm.group(1)
                if re.match(r"^(localhost|127\.0\.0\.1|0\.0\.0\.0)$", host): add(f, "apis", f"local service :{hm.group(2) or 80}")
                elif host.startswith("100.") or host.endswith(".ts.net"): add(f, "apis", f"tailnet host {host}:{hm.group(2) or ''}".rstrip(":"))
    for imp in f.get("imports", []):
        if imp in API_IMPORTS: add(f, "apis", API_IMPORTS[imp])
    for n in f.get("network", []):
        if isinstance(n, dict) and n.get("via") in ("ssh", "scp", "rsync"): add(f, "apis", "ssh to " + n.get("target", "?"))
    if re.search(r"\bpsql\b|podman exec[^\n]*psql", text): add(f, "apis", "Postgres (psql)")
    if re.search(r"\bsqlite3\b", text): add(f, "apis", "SQLite")
    if re.search(r'tell application "Messages"|imessage', text, re.I): add(f, "apis", "app: Messages")
    # SQL tables
    sql_texts = [text] if lang == "sql" else [m.group(0) for m in SQL_STR.finditer(text) if SQL_CTX.search(m.group(0))] + \
                [m.group(0) for m in SQL_SEG.finditer(text) if re.search(r"(?i)\b(FROM|INTO|SET|TABLE|VIEW|ON)\b", m.group(0)) and re.match(r"[A-Z]", m.group(0))]
    if lang in ("bash", "zsh"):
        sql_texts += [m.group(0) for m in re.finditer(r"(?is)(?:psql|sqlite3)[^\n]*(?:-c\s+)?(?:\"[^\"]*\"|'[^']*'|<<-?\s*['\"]?(\w+)['\"]?\n.*?\n\s*\1\b)", text)]
    for st in sql_texts:
        st = re.sub(r"--[^\n]*", "", st)
        for m in SQL_WRITE.finditer(st):
            t = m.group(2).strip('"').lower()
            if t not in SQL_NOT_TABLE and not t.startswith(("$", "{")): add(f, "tables_written", t)
        for m in SQL_READ.finditer(st):
            t = m.group(2).strip('"').lower()
            if t not in SQL_NOT_TABLE and not re.match(r"^(pg_|information_schema)", t) and len(t) > 1: add(f, "tables_read", t)
    # Airtable tables by name in URL path
    for u in allurls:
        m = re.search(r"api\.airtable\.com/v0/(app\w+|\$\{?\w+\}?|\{[^}]+\})/([^/?\s]+)", u or "")
        if m: add(f, "tables_read", "airtable:" + m.group(2))
    # stdout format
    if re.search(r"print\(\s*json\.dumps|json\.dump\([^)]*sys\.stdout|console\.log\(\s*JSON\.stringify|\|\s*jq\b[^\n]*$", text, re.M): add(f, "stdout", "json")
    if re.search(r"csv\.writer\(\s*sys\.stdout|csv\.DictWriter\(\s*sys\.stdout", text): add(f, "stdout", "csv")
    if not f.get("stdout") and re.search(r"\bprint\(|\becho\b|\bprintf\b|console\.log|\bprint\s", text): add(f, "stdout", "text")
    # destructive commands (full text minus comments)
    risk = "none"; reasons = []
    for i, line in enumerate(text.split("\n"), 1):
        if not line.strip(): continue
        st = line.strip()
        if re.match(r"(echo|printf|say|log|info|warn|die|fail|pass|note|msg|usage|print|console\.log|logger\.\w+|log\.\w+)\b[\s(]", st): continue
        for rx, label, lv in DESTRUCTIVE:
            mt = rx.search(line)
            if mt:
                a, b = mt.start(), mt.end()
                if (a > 0 and line[a - 1] == "|") or re.match(r"\w*\|", line[b - 1:b + 20]) or re.match(r"[\w\-]*\|", line[a:a + 30].split()[0] if line[a:a + 30].split() else ""): continue
                if "`" in line[:a] and "`" in line[b:] and lang in ("python", "javascript", "typescript"): continue
                if label == "rm" and re.search(r"\brm\s+(-[a-zA-Z]*[rR])", line): continue
                if label.startswith("rm"):
                    tg = re.search(r"\brm\s+((?:-\w+\s+)*)(.*)", line).group(2)
                    tg = [t for t in re.split(r"[\s;&|]+", tg) if t and not t.startswith("-")][:6]
                    if tg and all(re.search(r"(?i)^[\"']?(\$\{?\w*(tmp|temp|err|lock|pid|scratch|stage|work|cache|build|dist)\w*\}?|/tmp/|/private/tmp/|\$TMPDIR|__pycache__|\S*\.build\b)", t) for t in tg):
                        lv = "low"; label = "rm temp/build files"
                if label == "kill" and re.search(r"\btrap\b", line): lv = "low"; label = "kill own child (trap)"
                if label == "git push" and re.search(r"--force|-f\b", line): continue
                add(f, "destructive", {"cmd": label, "level": lv, "line": i, "text": line.strip()[:160]}, limit=80)
                if LEVEL[lv] > LEVEL[risk]: risk = lv
                if label not in reasons: reasons.append(label)
    # network writes / remote commands / file writes raise the floor
    for n in f.get("network", []):
        if not isinstance(n, dict): continue
        if n.get("method") in ("POST", "PUT", "PATCH", "DELETE") or (n.get("via") == "ssh" and n.get("remote_cmd")) or n.get("via") in ("scp", "rsync"):
            if LEVEL[risk] < 2: risk = "medium"
            lab = "network write" if n.get("method") in ("POST", "PUT", "PATCH", "DELETE") else f"remote {n.get('via')}"
            if lab not in reasons: reasons.append(lab)
    if f.get("tables_written") and LEVEL[risk] < 2: risk = "medium"; reasons.append("writes DB tables")
    if (f.get("files_written") or f.get("files_modified")) and LEVEL[risk] < 1: risk = "low"; reasons.append("writes files")
    f["risk_code"] = risk; f["risk_reasons"] = reasons
    n_facts = sum(len(v) for k, v in f.items() if isinstance(v, list) and k not in ("risk_reasons", "imports", "stdout"))
    return f, risk, n_facts

def main():
    ap = argparse.ArgumentParser(); ap.add_argument("--ids"); ap.add_argument("--dry", action="store_true"); ap.add_argument("--all", action="store_true")
    a = ap.parse_args()
    where = f"s.id IN ({','.join(str(int(x)) for x in a.ids.split(','))})" if a.ids else \
            ("true" if a.all else f"NOT EXISTS (SELECT 1 FROM script_facts x WHERE x.script_id=s.id AND x.content_hash=s.content_hash AND x.extractor_version='{VERSION}')")
    rows = pg.rows(f"SELECT s.id, s.language, s.path, s.body_redacted FROM scripts s WHERE {where} ORDER BY s.id")
    out = []
    for r in rows:
        try: fx, risk, n = extract(r["language"], r["path"], r["body_redacted"])
        except Exception as e: fx, risk, n = {"error": f"{type(e).__name__}: {e}"}, "none", 0
        out.append((r["id"], fx, risk, n))
    if a.dry:
        for i, fx, risk, n in out: print(i, risk, n, json.dumps(fx))
        return
    sql = ["BEGIN;"]
    for i, fx, risk, n in out:
        sql.append(f"""INSERT INTO script_facts(script_id,content_hash,extractor_version,facts,risk_code,n_facts,updated_at)
SELECT {i}, content_hash, '{VERSION}', {pg.lit(json.dumps(fx))}::jsonb, '{risk}', {n}, now() FROM scripts WHERE id={i}
ON CONFLICT (script_id) DO UPDATE SET content_hash=EXCLUDED.content_hash, extractor_version=EXCLUDED.extractor_version,
  facts=EXCLUDED.facts, risk_code=EXCLUDED.risk_code, n_facts=EXCLUDED.n_facts, updated_at=now();""")
    digest = hashlib.sha256(json.dumps([(i, fx) for i, fx, _, _ in out], sort_keys=True).encode()).hexdigest()
    detail = {"version": VERSION, "scripts": len(out), "with_facts": sum(1 for o in out if o[3] > 0),
              "errors": sum(1 for o in out if "error" in o[1]), "risk": {k: sum(1 for o in out if o[2] == k) for k in LEVEL}, "sha256": digest}
    sql.append(f"INSERT INTO change_log(actor,action,ok,detail) VALUES('grok-bot','facts',true,{pg.lit(json.dumps(detail))}::jsonb);")
    sql.append("COMMIT;")
    pg.run("\n".join(sql))
    print(json.dumps(detail))

if __name__ == "__main__":
    main()
