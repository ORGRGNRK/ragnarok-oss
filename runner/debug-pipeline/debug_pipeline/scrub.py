"""Scrub customer text with the catalog redactor. This file does not copy it.

The redactor is ops/script-catalog/redact.py. It returns (text, count) and
replaces secret values with its own marker. A second pass that still finds a
known shape means a secret survived.
"""
import importlib.util
import re
from pathlib import Path


class SecretSurvived(Exception):
    def __init__(self, where):
        super().__init__(where)
        self.where = where


def load_redactor(repo):
    path = repo / "ops" / "script-catalog" / "redact.py"
    if not path.is_file():
        raise FileNotFoundError(f"scrubber missing: {path}")
    spec = importlib.util.spec_from_file_location("ragnarok_catalog_redact", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return IntakeRedactor(mod.redact)


def scrub(redact, text):
    if text is None:
        return "", 0
    if not isinstance(text, str):
        text = str(text)
    return redact(text)


def survives(redact, text):
    _, count = redact(text or "")
    return count > 0


def scrub_bytes(redact, data, name=None):
    """Scrub a customer file. UTF-8 when it is text, otherwise a byte-preserving pass."""
    try:
        text = data.decode("utf-8")
        encoding = "utf-8"
    except UnicodeError:
        text = data.decode("latin-1")
        encoding = "latin-1"
    file_scrub = getattr(redact, "file", None)
    cleaned, count = file_scrub(name, text) if name is not None and file_scrub else redact(text)
    return cleaned.encode(encoding), count, cleaned


class IntakeRedactor:
    """Extend the shared shape scrubber with literal values from .env files.

    Values stay in host memory only. Register all files before showing any file.
    This handles neutral names such as DATABASE_URL, not just secret-ish names.
    """
    def __init__(self, redact):
        self.redact = redact
        self.values = set()

    def register(self, name, data):
        base = Path(name).name
        if not (base == ".env" or base.startswith(".env.") or base.endswith(".env")):
            return
        text = data.decode("utf-8", "replace")
        for line in text.splitlines():
            match = re.match(r"^\s*(?:export\s+)?[A-Za-z_][A-Za-z0-9_]*\s*=\s*(.*)$", line)
            if not match:
                continue
            value = match.group(1).strip()
            if value.startswith((chr(34), chr(39))):
                quote = value[0]
                end = value.find(quote, 1)
                value = value[1:end] if end >= 0 else value[1:]
            else:
                value = re.split(r"\s+#", value, maxsplit=1)[0].rstrip()
            if len(value) >= 8 and value != "[REDACTED]":
                self.values.add(value)

    def file(self, name, text):
        base = Path(name).name
        text, count = self(text)
        if base == ".env" or base.startswith(".env.") or base.endswith(".env"):
            def replace(match):
                nonlocal count
                value = match.group(2).strip()
                if not value or value in ('[REDACTED]', '\"[REDACTED]\"', "'[REDACTED]'"):
                    return match.group(0)
                count += 1
                return match.group(1) + "[REDACTED]"
            text = re.sub(r"(?m)^(\s*(?:export\s+)?[A-Za-z_][A-Za-z0-9_]*\s*=\s*)([^\n]+)$", replace, text)
        return text, count

    def __call__(self, text):
        text, found = self.redact(text)
        count = 0
        # Protect existing markers from short values, such as A or REDACTED.
        chunks = text.split("[REDACTED]")
        for value in sorted(self.values, key=len, reverse=True):
            next_chunks = []
            for chunk in chunks:
                count += chunk.count(value)
                next_chunks.extend(chunk.split(value))
            chunks = next_chunks
        return "[REDACTED]".join(chunks), count + found
