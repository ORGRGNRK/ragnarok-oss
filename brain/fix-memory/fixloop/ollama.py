"""Minimal Ollama client (local/LAN only). No cloud APIs are used anywhere in this project."""
from __future__ import annotations

import json
import urllib.request

from .config import settings


# The model name each kind of call was answered by, as Ollama itself reported it in its response
# ("model" field), which is not necessarily the name we asked for. Stored on the fix's receipt
# (detail.embed_model_reported / coder_model_reported) next to the configured names.
reported: dict[str, str | None] = {"embed": None, "chat": None}
_chat_seen: list[str] = []


def _name(v) -> str | None:
    if not isinstance(v, str):
        return None
    s = "".join(ch for ch in v if ch.isprintable()).strip()[:200]
    return s or None


def chat_models_reported() -> list[str]:
    """Every model name the chat API answered with in this process, first seen first."""
    return list(_chat_seen)


def _post(path: str, body: dict, timeout: int = 600) -> dict:
    req = urllib.request.Request(
        settings.ollama_host + path,
        data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.loads(resp.read())


def tags() -> list[str]:
    with urllib.request.urlopen(settings.ollama_host + "/api/tags", timeout=10) as resp:
        return [m["name"] for m in json.loads(resp.read()).get("models", [])]


def embed(text: str, kind: str = "document") -> list[float]:
    """Embed with nomic-embed-text. nomic expects a task prefix."""
    prefix = "search_query: " if kind == "query" else "search_document: "
    out = _post("/api/embed", {"model": settings.embed_model, "input": prefix + text}, timeout=120)
    reported["embed"] = _name(out.get("model"))
    return out["embeddings"][0]


def chat(system: str, user: str, temperature: float = 0.1) -> str:
    out = _post(
        "/api/chat",
        {
            "model": settings.coder_model,
            "stream": False,
            "options": {"temperature": temperature, "num_ctx": 8192},
            "messages": [
                {"role": "system", "content": system},
                {"role": "user", "content": user},
            ],
        },
    )
    reported["chat"] = name = _name(out.get("model"))
    if name and name not in _chat_seen:
        _chat_seen.append(name)
    return out["message"]["content"]
