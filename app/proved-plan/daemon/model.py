"""Draft text with the Alexus model on the LAN. No other model endpoint is used."""
from __future__ import annotations

import json
import os
import re
import urllib.request

import evidence as evidence_mod



def _local_model_url() -> str:
    """OLLAMA_URL, else ALEXUS_HOST port 11434, from ~/.ragnarok/local.conf (read, never run); + /api/chat."""
    conf = {}
    try:
        with open(os.path.expanduser("~/.ragnarok/local.conf"), encoding="utf-8") as f:
            for line in f:
                k, sep, v = line.strip().partition("=")
                if sep and not k.startswith("#"):
                    conf[k.strip()] = v.strip().strip("\"'")
    except OSError:
        pass
    url = conf.get("OLLAMA_URL", "").rstrip("/")
    if not re.fullmatch(r"https?://[A-Za-z0-9.:\[\]-]+", url):
        host = conf.get("ALEXUS_HOST", "")
        host = host if re.fullmatch(r"[A-Za-z0-9.:-]{1,253}", host) and not host.startswith("-") else "alexus.local"
        url = "http://" + host + ":11434"
    return url + "/api/chat"


MODEL_URL = os.environ.get("PLAN_MODEL_URL") or _local_model_url()
MODEL_NAME = "llama3.1:8b"
NUM_CTX = 8192

SYSTEM = (
    "You draft the owner's daily Proved note from the evidence in the user message. "
    "Return as JSON. "
    "Use only facts that appear in the evidence. Do not invent metrics, names, quotes, or results. "
    "Do not include machine paths, IP addresses, tokens, or home directory names. "
    "The post is one short public note about the last day's real work. "
    "The two outreach strings are private drafts the owner might send by hand to two different people: "
    "a local business owner, or a developer who ships software. "
    "Address each note to that person. "
    "Do not address a model, a server, a program, or another assistant. "
    "Do not use the name Alexus. "
    "If the evidence names no contact, address the role and do not invent a personal name. "
    "Say they are drafts. Do not claim that anything was sent or posted."
)

# A greeting to the LAN box, or the box's name anywhere, is not outreach.
_MACHINE_NAME = re.compile(r"(?i)\b(?:alexus|llama|ollama)\b")
_MACHINE_GREETING = re.compile(
    r"(?i)(?:^|\b)(?:hi|hello|hey|dear)\s*,?\s*(?:assistant|model|server|program)\b"
)
_GREETED_NAME = re.compile(
    r"(?:^|\b)(?:[Hh]i|[Hh]ello|[Hh]ey|[Dd]ear)\s*,?\s*([A-Z][a-z]{2,})\b"
)
_ROLE_WORDS = (
    "owner",
    "developer",
    "neighbor",
    "friend",
    "customer",
    "client",
    "founder",
    "builder",
    "colleague",
    "teammate",
    "business",
)

# Ollama structured output. Constrains message.content to the object parse_draft accepts.
DRAFT_SCHEMA = {
    "type": "object",
    "properties": {
        "post": {"type": "string"},
        "outreach": {
            "type": "array",
            "items": {"type": "string"},
            "minItems": 2,
            "maxItems": 2,
        },
    },
    "required": ["post", "outreach"],
}


def chat_payload(evidence: str) -> dict:
    return {
        "model": MODEL_NAME,
        "stream": False,
        "format": DRAFT_SCHEMA,
        "options": {"num_ctx": NUM_CTX, "temperature": 0},
        "messages": [
            {"role": "system", "content": SYSTEM},
            {"role": "user", "content": evidence},
        ],
    }


def chat(evidence: str, url: str = MODEL_URL, post=None, timeout: int = 120) -> str:
    payload = chat_payload(evidence)
    if post is None:
        data = _post(url, payload, timeout)
    else:
        data = post(url, payload)
    content = (data.get("message") or {}).get("content")
    if not isinstance(content, str) or not content.strip():
        raise RuntimeError("empty model reply")
    return content


def _post(url: str, payload: dict, timeout: int) -> dict:
    raw = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(url, data=raw, method="POST")
    req.add_header("content-type", "application/json")
    res = urllib.request.urlopen(req, timeout=timeout)
    return json.loads(res.read().decode("utf-8"))


def parse_draft(content: str) -> dict:
    text = content.strip()
    if text.startswith("```"):
        text = re.sub(r"^```(?:json)?\s*", "", text)
        text = re.sub(r"\s*```$", "", text)
    data = json.loads(text)
    post = data.get("post")
    outreach = data.get("outreach")
    if not isinstance(post, str) or not post.strip():
        raise ValueError("model post was empty")
    if not isinstance(outreach, list) or len(outreach) < 2:
        raise ValueError("model outreach was not two strings")
    first = str(outreach[0]).strip()
    second = str(outreach[1]).strip()
    if not first or not second:
        raise ValueError("model outreach was empty")
    return {"post": post.strip(), "outreach": [first, second]}


def require_human_outreach(drafts: dict, evidence: str = "") -> dict:
    """Raise when an outreach string is addressed to a machine or an invented name.

    plan_daemon treats that as a model failure, so the text is not saved as
    source: model and the next hour can try again.
    """
    for item in drafts.get("outreach") or []:
        if _MACHINE_NAME.search(item) or _MACHINE_GREETING.search(item):
            raise ValueError("outreach addressed a machine")
        match = _GREETED_NAME.search(item)
        if not match:
            continue
        name = match.group(1)
        lowered = name.lower()
        named = bool(re.search(r"\b%s\b" % re.escape(name), evidence or "", re.I))
        if lowered in _ROLE_WORDS or named:
            continue
        window = item[match.start() : match.start() + 80].lower()
        if any(role in window for role in _ROLE_WORDS):
            continue
        raise ValueError("outreach invented a personal name")
    return drafts


def fallback_draft(evidence: str) -> dict:
    note = evidence_mod.redact(evidence).strip()[:1500] or "(no commits or agent outcomes in the last 24 hours)"
    return {
        "post": (
            "Notes from the last 24 hours. The local model did not answer, "
            "so this is an unedited list and nothing here has gone out.\n\n" + note
        ),
        "outreach": [
            "Draft only, not sent. The local model did not answer. Pick a person before writing this by hand.",
            "Draft only, not sent. Second note stays a placeholder until the local model answers.",
        ],
    }
