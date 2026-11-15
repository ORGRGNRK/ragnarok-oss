"""Queue file header versus the draft body.

The file the owner reads starts with a name, `source:`, and `day:`. The publisher
and the Touch ID reason get the body only. Approve refuses anything whose
source is not `model`.
"""
from __future__ import annotations

_DRAFT_NOTE = "DRAFT ONLY. This message is never sent by the daemon."


def render_queue(name: str, source: str, day: str, body: str) -> str:
    note = ""
    if "outreach" in name:
        note = _DRAFT_NOTE + "\n\n"
    return "# %s\n\nsource: %s\nday: %s\n\n%s%s\n" % (name, source, day, note, body.strip())


def split_queue(text: str) -> tuple:
    """Return (source, body).

    Source is the header value, or "" when the file has no source line.
    Body is the text after the day line. The outreach draft-only note is not
    part of the body. A file with no header fails closed: source is "" and the
    whole text is the body, which approve will not send.
    """
    lines = text.splitlines()
    source = ""
    day_at = None
    for index, line in enumerate(lines):
        stripped = line.strip()
        lower = stripped.lower()
        if lower.startswith("source:") and day_at is None:
            source = stripped.split(":", 1)[1].strip()
        elif lower.startswith("day:") and day_at is None:
            day_at = index
            break
    if day_at is None:
        return "", text.strip()
    rest = lines[day_at + 1 :]
    if rest and rest[0].strip() == "":
        rest = rest[1:]
    body = "\n".join(rest).strip()
    if body.startswith(_DRAFT_NOTE):
        body = body[len(_DRAFT_NOTE) :].strip()
    return source, body
