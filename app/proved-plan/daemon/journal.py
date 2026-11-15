"""Append-only action log at ~/.ragnarok/plan-daemon/log.jsonl."""
from __future__ import annotations

import json
from datetime import datetime, timezone
from pathlib import Path

from paths import log_path


def log_action(home: Path, action: str, **fields: object) -> None:
    path = log_path(home)
    path.parent.mkdir(parents=True, exist_ok=True)
    rec = {
        "ts": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "action": action,
    }
    for key, value in fields.items():
        if any(word in key.lower() for word in ("token", "secret", "password", "authorization")):
            continue
        rec[key] = value
    with path.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(rec, ensure_ascii=False) + "\n")
