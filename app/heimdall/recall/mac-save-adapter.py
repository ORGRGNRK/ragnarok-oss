#!/usr/bin/env python3
"""mac-save-adapter — lets the owner's ragnarok-corpus/compile.py run on the Mac.

compile.py imports ~/scripts/ragnarok-save for its redaction and REFUSES to build
when it finds no live secrets (correctly: a sweep blind to this box's own tokens
is not a sweep). ragnarok-save's credential paths are the old Linux box's, so on
the Mac it finds none. This module is passed as CORPUS_SAVE_SCRIPT. It imports
ragnarok-save UNCHANGED and re-exports all of it, so there is still exactly one
redaction pass; it only ADDS the Mac's live credential values to the exact-match
set. Values are read here and never printed or written anywhere.
"""
import glob, importlib.machinery, importlib.util, json, os, re

REAL_HOME = os.environ.get("HEIMDALL_REAL_HOME") or os.path.expanduser("~")
SAVE = os.environ.get("HEIMDALL_RAGNAROK_SAVE", os.path.join(REAL_HOME, "Developer", "scripts", "ragnarok-save"))

_spec = importlib.util.spec_from_loader("ragnarok_save", importlib.machinery.SourceFileLoader("ragnarok_save", SAVE))
_save = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_save)
globals().update({k: v for k, v in vars(_save).items() if not k.startswith("__")})

# J1: credential words only as whole parts of the name (GITHUB_TOKEN, OPENAI_API_KEY), not inside words (PATH, COMPASS)
SECRET_KEY = re.compile(r"(^|_)(KEY|KEYS|APIKEY|TOKEN|SECRET|PAT|PASSWORD|PASSWD|PASS|PWD|BEARER|CREDENTIAL|CREDENTIALS|AUTH)(_|$)", re.I)
URL_PASSWORD = re.compile(r"[a-z][a-z0-9+.-]*://[^/\s:@]+:([^@\s/]+)@", re.I)   # postgres://user:PASSWORD@host


def _env_value(raw):
    """Value of KEY=value: quotes removed; an unquoted value loses its inline ` # comment`."""
    v = raw.strip()
    if v[:1] in ("'", '"'):
        q = v[0]; end = v.find(q, 1)
        return v[1:end] if end > 0 else v[1:]
    return re.split(r"\s+#", v, 1)[0].strip()


def _mac_secrets():
    found, sources = set(), []
    # .env files in the owner's projects: every value whose key name says it is a credential
    paths = set(glob.glob(os.path.join(REAL_HOME, "Developer", "**", ".env"), recursive=True))
    paths |= set(glob.glob(os.path.join(REAL_HOME, "Developer", "**", ".env.*"), recursive=True))   # J1: .env.local etc.
    for path in sorted(paths):
        if "/node_modules/" in path or path.endswith((".example", ".sample", ".template", ".dist")) or not os.path.isfile(path):
            continue
        try:
            for line in open(path, encoding="utf-8", errors="replace"):
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, v = line.split("=", 1)
                k = k.replace("export ", "").strip(); v = _env_value(v)
                where = f"{os.path.relpath(path, REAL_HOME)}:{k}"
                if SECRET_KEY.search(k) and len(v) >= getattr(_save, "MIN_SECRET_LEN", 16):
                    found.add(v); sources.append(where)
                for pw in URL_PASSWORD.findall(v):   # J1: a password inside DATABASE_URL and the like
                    found.add(pw); sources.append(where + " (url password)")
        except OSError:
            pass
    # Grok CLI tokens (the same file ragnarok-save reads on the old box, at the Mac's real home)
    try:
        for entry in json.load(open(os.path.join(REAL_HOME, ".grok", "auth.json"), encoding="utf-8")).values():
            if isinstance(entry, dict):
                for f in ("key", "refresh_token", "access_token", "id_token"):
                    v = (entry.get(f) or "").strip()
                    if v:
                        found.add(v); sources.append(f"grok auth:{f}")
    except (OSError, ValueError):
        pass
    return found, sources


def collect_secrets():
    nocodb, secrets, sources = _save.collect_secrets()
    extra, extra_src = _mac_secrets()
    min_len = getattr(_save, "MIN_SECRET_LEN", 16)
    return nocodb, set(secrets) | {s for s in extra if len(s) >= min_len}, list(sources) + extra_src
