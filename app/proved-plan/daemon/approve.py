#!/usr/bin/env python3
"""Show a queued draft, require hardware presence, and only then call the publisher.

A FIDO key listed by fido2-token must answer AUTH_KEY_OK from fido-auth.sh.
Otherwise the Secure Enclave Touch ID sheet must return ok:true for the same
challenge this process just minted, plus a signature. Anything else fails
closed, and the publisher is not called.

Outreach files are drafts. This command refuses them and does not send them.
"""
from __future__ import annotations

import hashlib
import json
import os
import secrets
import subprocess
import sys
from pathlib import Path

from journal import log_action
from paths import counted_dir
from plan_api import PlanClient, load_token
from publish import publish
from queue_file import split_queue

FIDO_TOKEN = "/opt/homebrew/bin/fido2-token"
FIDO = os.path.expanduser("~/Developer/ragnarok/agents/alexus-core/bin/fido-auth.sh")
ENCLAVE = os.path.expanduser("~/Applications/Ragnarok.app/Contents/Resources/EnclaveAuthenticator")


def _notify(spawn, message: str) -> None:
    script = "display notification %s with title %s" % (json.dumps(message), json.dumps("Proved plan"))
    try:
        spawn(["osascript", "-e", script], capture_output=True, text=True, timeout=5)
    except Exception:
        return


def _key_plugged(spawn, fido_token: str) -> bool:
    try:
        result = spawn([fido_token, "-L"], capture_output=True, text=True, timeout=5)
    except Exception:
        return False
    return bool((getattr(result, "stdout", "") or "").strip())


def _last_json(stdout: str) -> dict:
    lines = [line for line in (stdout or "").splitlines() if line.strip()]
    if not lines:
        return {}
    parsed = json.loads(lines[-1])
    return parsed if isinstance(parsed, dict) else {}


def hardware_gate(reason: str, spawn=None, fido_token: str = FIDO_TOKEN, fido: str = FIDO, enclave: str = ENCLAVE) -> bool:
    """True only after a real hardware approval. Fails closed."""
    spawn = subprocess.run if spawn is None else spawn
    _notify(spawn, "Approve this post with your key or Touch ID.")
    try:
        if _key_plugged(spawn, fido_token):
            if not os.access(fido, os.X_OK):
                return False
            result = spawn([fido], capture_output=True, text=True, timeout=90)
            return result.returncode == 0 and "AUTH_KEY_OK" in (result.stdout or "")
        if not os.access(enclave, os.X_OK):
            return False
        challenge = secrets.token_hex(16)  # 32 hex characters
        result = spawn(
            [enclave, "--challenge", challenge, "--reason", reason],
            capture_output=True,
            text=True,
            timeout=120,
        )
        try:
            body = _last_json(result.stdout)
        except (ValueError, TypeError):
            return False
        signature = body.get("signature")
        return (
            result.returncode == 0
            and body.get("ok") is True
            and body.get("challenge") == challenge
            and isinstance(signature, str)
            and bool(signature.strip())
        )
    except Exception:
        return False


def draft_kind(name: str) -> str:
    stem = name[:-3] if name.endswith(".md") else name
    parts = stem.split("-", 3)
    if len(parts) >= 4 and len(parts[0]) == 4:
        return stem.split("-", 3)[3]
    return ""


def draft_day(name: str) -> str:
    stem = name[:-3] if name.endswith(".md") else name
    day = "-".join(stem.split("-")[:3])
    if len(day) == 10:
        return day
    return ""


def show_draft(text: str) -> None:
    sys.stdout.write(text if text.endswith("\n") else text + "\n")


def _default_publisher(text: str, kind: str, day: str, home: Path):
    return publish(text, kind=kind, day=day, home=home)


def _record_real_post(client, home: Path, day: str, draft: Path) -> None:
    digest = hashlib.sha256(draft.read_bytes()).hexdigest()[:20]
    receipt = counted_dir(home) / ("%s.json" % digest)
    if receipt.is_file():
        log_action(home, "record_skip", reason="already counted", day=day)
        return
    state = client.state(day)
    current = (state.get("numbers") or {}).get("posts") or 0
    posts = int(current) + 1
    client.check(day, "post", True)
    client.numbers(day, {"posts": posts})
    receipt.parent.mkdir(parents=True, exist_ok=True)
    receipt.write_text(json.dumps({"day": day, "posts": posts}) + "\n", encoding="utf-8")
    log_action(home, "record_post", day=day, posts=posts)


def run_approve(draft, home: Path, gate=None, publisher=None, client=None, spawn=None) -> int:
    """Print the draft. Call the publisher only after the gate returns true."""
    draft = Path(draft)
    if not draft.is_file():
        print("No such draft.", file=sys.stderr)
        log_action(home, "approve_missing", file=draft.name)
        return 2
    text = draft.read_text(encoding="utf-8")
    show_draft(text)
    kind = draft_kind(draft.name)
    day = draft_day(draft.name)
    if kind != "post" or not day:
        print("Only a dated post draft can go out. Outreach drafts are never sent.", file=sys.stderr)
        log_action(home, "approve_refused", kind=kind or "unknown")
        return 2
    source, body = split_queue(text)
    if source != "model" or not body.strip():
        print("Only a model draft can go out. This file is not a model draft, so nothing was posted.", file=sys.stderr)
        log_action(home, "approve_refused", kind=kind, source=source or "missing")
        return 2
    snippet = " ".join(body.split())[:80]
    reason = "post: " + snippet
    log_action(home, "gate_ask", reason=reason)
    try:
        if gate is None:
            ok = hardware_gate(reason, spawn=spawn)
        else:
            ok = bool(gate(reason))
    except Exception as exc:
        log_action(home, "gate_error", error=str(exc)[:300])
        print("Hardware gate failed closed. Nothing was posted.", file=sys.stderr)
        return 1
    if not ok:
        log_action(home, "gate_denied")
        print("Not approved. Nothing was posted.", file=sys.stderr)
        return 1
    log_action(home, "gate_ok")
    pub = _default_publisher if publisher is None else publisher
    try:
        result = pub(body, kind="post", day=day, home=home)
    except Exception as exc:
        log_action(home, "publish_error", error=str(exc)[:300])
        print("Publisher failed. The checklist was not changed.", file=sys.stderr)
        return 1
    log_action(
        home,
        "publish_result",
        ok=bool(result.ok),
        published=bool(result.published),
        backend=str(result.backend),
        detail=str(result.detail)[:300],
    )
    if not result.ok:
        print(result.detail, file=sys.stderr)
        return 1
    if not result.published:
        log_action(home, "record_skip", reason="backend did not report a real post", backend=str(result.backend))
        print(result.detail)
        return 0
    if client is None:
        base = os.environ.get("PLAN_API_BASE", "https://plan.rgnrk.co")
        client = PlanClient(base, load_token())
    try:
        _record_real_post(client, home, day, draft)
    except Exception as exc:
        log_action(home, "record_error", error=str(exc)[:300])
        print("The post was reported, but the checklist was not updated: %s" % exc, file=sys.stderr)
        return 1
    return 0


def main(argv=None) -> int:
    args = list(sys.argv[1:] if argv is None else argv)
    if len(args) != 1:
        print("usage: approve.py <draft>", file=sys.stderr)
        return 2
    return run_approve(Path(args[0]), home=Path.home())


if __name__ == "__main__":
    sys.exit(main())
