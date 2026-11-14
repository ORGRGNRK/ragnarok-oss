"""Secret redaction. Replaces secret VALUES with [REDACTED]; returns (text, count)."""
import re

R = "[REDACTED]"
PATTERNS = [
    # private key blocks
    (re.compile(r"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----.*?-----END [A-Z0-9 ]*PRIVATE KEY-----", re.S), lambda m: R),
    (re.compile(r"-----BEGIN OPENSSH PRIVATE KEY-----.*?(-----END OPENSSH PRIVATE KEY-----|\Z)", re.S), lambda m: R),
    # well-known token shapes
    (re.compile(r"\b(sk-(?:ant-|proj-|live-|test-)?[A-Za-z0-9_\-]{16,})"), lambda m: R),
    (re.compile(r"\b(gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})"), lambda m: R),
    (re.compile(r"\b(xox[abprs]-[A-Za-z0-9\-]{10,})"), lambda m: R),
    (re.compile(r"\b(AKIA[0-9A-Z]{16})\b"), lambda m: R),
    (re.compile(r"\b(AIza[0-9A-Za-z_\-]{30,})"), lambda m: R),
    (re.compile(r"\b(pat[A-Za-z0-9]{14}\.[a-f0-9]{40,})"), lambda m: R),          # Airtable PAT
    (re.compile(r"\b(tskey-[A-Za-z0-9\-]{10,})"), lambda m: R),                     # Tailscale
    (re.compile(r"\b(ops_[A-Za-z0-9_\-]{20,}|eyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,})"), lambda m: R),  # 1P service acct / JWT
    (re.compile(r"\b(\d{8,10}:AA[A-Za-z0-9_\-]{30,})"), lambda m: R),             # Telegram bot token
    (re.compile(r"\b(whsec_[A-Za-z0-9]{16,}|rk_live_[A-Za-z0-9]{16,}|pk_live_[A-Za-z0-9]{16,})"), lambda m: R),
    # Authorization headers
    (re.compile(r"(?i)(authorization\s*[:=]\s*[\"']?\s*(?:bearer|basic|token)\s+)([^\s\"'\\]{6,})"), lambda m: m.group(1) + R),
    (re.compile(r"(?i)(\bbearer\s+)([A-Za-z0-9_\-\.=+/]{12,})"), lambda m: m.group(1) + R),
    # URLs with embedded credentials  scheme://user:pass@host
    (re.compile(r"([a-zA-Z][a-zA-Z0-9+.\-]*://[^/\s:@\"']+:)([^@\s\"'/]{3,})(@)"), lambda m: m.group(1) + R + m.group(3)),
    # 1Password secret references / restic
    (re.compile(r"(op://[^\s\"']+)"), lambda m: "op://" + R),
    (re.compile(r"(?i)(RESTIC_PASSWORD\w*\s*[=:]\s*[\"']?)([^\s\"']+)"), lambda m: m.group(1) + R),
    # key=value style assignments with secret-ish names (env, shell, python, json, yaml)
    (re.compile(r"""(?imx)
        ((?:^|[\s{,;(\"'])(?:export\s+)?["']?
          [A-Za-z0-9_\.\-]*(?:passw(?:or)?d|passwd|secret|token|api[_\-]?key|apikey|access[_\-]?key|private[_\-]?key|client[_\-]?secret|auth[_\-]?key|credential|pwd|pass\b)[A-Za-z0-9_\.\-]*
          ["']?\s*(?:=|:|:=)\s*)
        (["']?)([^\s"',;)\[\]}]{4,})(\2)""", re.M), None),
]

SAFE_VALUE = re.compile(r"""(?x)^(
   \$\{?[A-Za-z_][A-Za-z0-9_]*\}?.*      # $VAR / ${VAR}
 | \$\(.*                                  # $(cmd)
 | os\.environ.* | os\.getenv.* | process\.env.* | getenv.* | env\[.* | ENV\[.*
 | \[REDACTED\] | <[^>]*> | \.\.\.+ | x{4,} | \*{3,} | None | null | true | false | True | False | undefined
 | input\(.* | getpass.* | args?\..* | self\..* | config\..* | cfg\..* | settings\..* | req.* | request.* | data\[.* | json\..* | str | string | int | bool | Optional.* | \w+\(.*
)""")
BARE_IDENT = re.compile(r"^[A-Za-z_][A-Za-z_\.]*$")   # unquoted, no digits -> variable reference
QUOTED_SAFE = re.compile(r"^(\$|\{|<|\[REDACTED|x{4,}$|\*{3,}$|\.\.\.|your[_\-]|changeme$|example)", re.I)

def _assign(m):
    prefix, q, val, q2 = m.group(1), m.group(2), m.group(3), m.group(4)
    if q:
        if QUOTED_SAFE.match(val):
            return m.group(0)
    elif SAFE_VALUE.match(val) or BARE_IDENT.match(val):
        return m.group(0)
    return prefix + q + R + q2

def redact(text):
    count = 0
    for pat, fn in PATTERNS:
        f = fn or _assign
        def wrap(m, f=f):
            nonlocal count
            out = f(m)
            if out != m.group(0):
                count += 1
            return out
        text = pat.sub(wrap, text)
    return text, count
