"""Locations under ~/.ragnarok/plan-daemon. Nothing here is copied out of the repo."""
from __future__ import annotations

from pathlib import Path


def plan_root(home: Path) -> Path:
    return Path(home) / ".ragnarok" / "plan-daemon"


def queue_dir(home: Path) -> Path:
    return plan_root(home) / "queue"


def published_dir(home: Path) -> Path:
    return plan_root(home) / "published"


def counted_dir(home: Path) -> Path:
    return plan_root(home) / "counted"


def log_path(home: Path) -> Path:
    return plan_root(home) / "log.jsonl"
