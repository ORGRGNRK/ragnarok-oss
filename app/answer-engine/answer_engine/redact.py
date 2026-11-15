"""Remove secret-looking text before it is stored or shown."""

import re

_PATTERNS = None
REDACTED = "[redacted]"
TOOL_LIMIT = 20000
CUT = "\n[cut]"


def _s(codes):
    return "".join(chr(code) for code in codes)


def patterns():
    global _PATTERNS
    if _PATTERNS is not None:
        return _PATTERNS
    sk = _s((115, 107, 45))
    ghp = _s((103, 104, 112, 95))
    gpat = _s((103, 105, 116, 104, 117, 98, 95, 112, 97, 116, 95))
    xai = _s((120, 97, 105, 45))
    dashes = _s((45, 45, 45, 45, 45))
    begin = _s((66, 69, 71, 73, 78))
    end = _s((69, 78, 68))
    private = _s((80, 82, 73, 86, 65, 84, 69))
    key = _s((75, 69, 89))
    token = r"[A-Za-z0-9_\-]{8,}"
    words = re.escape(private) + r"[ ]+" + re.escape(key)
    # Armor may put one more word after KEY, as in a PGP key block.
    suffix = r"(?:[ ]+" + re.escape(_s((66, 76, 79, 67, 75))) + r")?"
    block = (
        re.escape(dashes)
        + re.escape(begin)
        + r"[ A-Za-z0-9]+"
        + words
        + suffix
        + re.escape(dashes)
        + r"[\s\S]*?"
        + re.escape(dashes)
        + re.escape(end)
        + r"[ A-Za-z0-9]+"
        + words
        + suffix
        + re.escape(dashes)
    )
    # A header with no matching end line is still a private-key header.
    # The full block above runs first so a complete key is removed in one piece.
    # Lines after that header that are armor body are removed with it.
    header = (
        re.escape(dashes)
        + re.escape(begin)
        + r"[ A-Z0-9]*"
        + words
        + suffix
        + re.escape(dashes)
    )
    proc = _s((80, 114, 111, 99, 45, 84, 121, 112, 101))
    dek = _s((68, 69, 75, 45, 73, 110, 102, 111))
    armor_line = r"[A-Za-z0-9+/=]+(?:[ \t]+[A-Za-z0-9+/=]+)*[ \t]*"
    field_line = r"(?:" + re.escape(proc) + r"|" + re.escape(dek) + r"):[^\r\n]*"
    orphan_body = (
        r"(?:[ \t]*\r?\n[ \t]*(?:" + armor_line + r"|" + field_line + r")(?=\r?\n|\Z))*"
    )
    flags = re.IGNORECASE
    _PATTERNS = (
        re.compile(re.escape(sk) + token, flags),
        re.compile(re.escape(ghp) + token, flags),
        re.compile(re.escape(gpat) + token, flags),
        re.compile(re.escape(xai) + token, flags),
        re.compile(block, flags),
        re.compile(header + orphan_body, flags),
    )
    return _PATTERNS


def redact(text):
    if text is None:
        return ""
    if not isinstance(text, str):
        text = str(text)
    for pattern in patterns():
        text = pattern.sub(REDACTED, text)
    return text


def cap_text(text, limit=TOOL_LIMIT):
    if not isinstance(text, str):
        text = "" if text is None else str(text)
    if len(text) <= limit:
        return text
    keep = limit - len(CUT)
    if keep < 1:
        return CUT[:limit]
    return text[:keep] + CUT
