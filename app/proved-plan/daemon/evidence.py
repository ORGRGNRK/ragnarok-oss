"""Last-24-hour facts from git and agent outcome files. Stdlib only."""
from __future__ import annotations

import json
import re
from datetime import datetime, timedelta
from pathlib import Path

_SECRET = re.compile(
    r"(?i)(\bsk-[A-Za-z0-9]{10,}\b|\bghp_[A-Za-z0-9]{10,}\b|\bxox[baprs]-[A-Za-z0-9-]{10,}\b|"
    r"(api[_-]?key|token|secret|password)\s*[:=]\s*\S+|/Users/[A-Za-z0-9._-]+)"
)
# Dotted quads. Applied before the secret pass so a commit subject cannot keep an address.
_IPV4 = re.compile(
    r"\b(?:(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}"
    r"(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\b"
)
# At least two colons, hex groups only, so a short git hash is left alone.
_IPV6 = re.compile(
    r"(?i)(?<![0-9A-Fa-f:])(?:[0-9A-Fa-f]{0,4}:){2,7}[0-9A-Fa-f]{0,4}(?![0-9A-Fa-f:])"
)


def redact(text: str) -> str:
    text = _IPV4.sub("[redacted]", text)
    text = _IPV6.sub("[redacted]", text)
    return _SECRET.sub("[redacted]", text)


def git_log(repo: Path, run) -> str:
    repo = Path(repo)
    if not repo.is_dir():
        return "(missing)"
    try:
        result = run(
            [
                "git",
                "-C",
                str(repo),
                "log",
                "--all",
                "--since=24 hours ago",
                "--date=short",
                "--pretty=format:%h %ad %s",
            ],
            capture_output=True,
            text=True,
            timeout=30,
        )
    except Exception as exc:
        return "(git failed: %s)" % exc
    if getattr(result, "returncode", 1) != 0:
        err = (getattr(result, "stderr", "") or "").strip().splitlines()
        return "(git failed: %s)" % (err[-1] if err else result.returncode)
    out = (getattr(result, "stdout", "") or "").strip()
    return out or "(no commits in the last 24h)"


def _flat(value: object) -> str:
    if value is None or value is False or value == "":
        return ""
    if isinstance(value, (dict, list)):
        value = json.dumps(value, ensure_ascii=False)
    else:
        value = str(value)
    return " ".join(value.split())[:240]


def agent_outcomes(agents_dir: Path, now: datetime, limit: int = 40) -> str:
    agents_dir = Path(agents_dir)
    if not agents_dir.is_dir():
        return "(no agent directory)"
    if now.tzinfo is None:
        cutoff = (now - timedelta(hours=24)).timestamp()
    else:
        cutoff = (now - timedelta(hours=24)).timestamp()
    found = []
    for path in agents_dir.glob("*/state.json"):
        try:
            stamp = path.stat().st_mtime
        except OSError:
            continue
        if stamp >= cutoff:
            found.append((stamp, path))
    found.sort(reverse=True)
    lines = []
    for _, path in found[:limit]:
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            continue
        if not isinstance(data, dict):
            continue
        bits = []
        for key in ("id", "name", "status", "verdict", "exit_code", "final", "remark"):
            shown = _flat(data.get(key))
            if shown:
                bits.append("%s=%s" % (key, shown))
        if bits:
            lines.append("; ".join(bits))
    return "\n".join(lines) if lines else "(no agent outcomes in the last 24h)"


def collect(now: datetime, repos, agents_dir: Path, run) -> str:
    parts = []
    for repo in repos:
        repo = Path(repo)
        parts.append("## git %s\n%s" % (repo.name, git_log(repo, run)))
    parts.append("## agent outcomes\n%s" % agent_outcomes(agents_dir, now))
    text = redact("\n\n".join(parts))
    return text[:12000]
