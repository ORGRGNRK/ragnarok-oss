"""Pluggable publisher.

The default backend is dryrun: it writes what it would post under
~/.ragnarok/plan-daemon/published/ and reports published=False, because a
local file is not a public post.

Any other backend is a stub. It refuses. It does not log in, create an
account, read or store a password, or post anything.
"""
from __future__ import annotations

import os
from pathlib import Path

from paths import published_dir


class PublishResult(object):
    def __init__(self, ok: bool, published: bool, backend: str, detail: str, path: str = ""):
        self.ok = bool(ok)
        self.published = bool(published)
        self.backend = backend
        self.detail = detail
        self.path = path


def publish(text: str, kind: str = "post", day: str = "", home: Path = None, backend: str = None) -> PublishResult:
    if home is None:
        home = Path.home()
    if backend is None:
        backend = os.environ.get("PLAN_PUBLISH_BACKEND", "dryrun")
    if backend == "dryrun":
        dest = published_dir(home)
        dest.mkdir(parents=True, exist_ok=True)
        path = dest / ("%s-%s.md" % (day or "undated", kind or "post"))
        body = (
            "backend: dryrun\n"
            "day: %s\n"
            "kind: %s\n"
            "would post the text below. Nothing was sent to a network.\n\n%s\n"
            % (day, kind, text.strip())
        )
        path.write_text(body, encoding="utf-8")
        return PublishResult(True, False, "dryrun", "wrote dry-run copy", str(path))
    return PublishResult(
        False,
        False,
        str(backend),
        "Real posting is stubbed until you configure credentials yourself. "
        "This program will not log in, store a password, or post.",
    )
