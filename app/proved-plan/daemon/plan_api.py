"""Bearer client for the plan.rgnrk.co machine API. Stdlib only."""
from __future__ import annotations

import json
import os
import urllib.error
import urllib.request
from pathlib import Path

# Cloudflare rejects urllib's default User-Agent (Python-urllib/x.y) with 403 / error 1010
# before the request reaches the Worker. This name is allowed through.
USER_AGENT = "proved-plan-daemon/1.0"


def load_token(environ: dict | None = None) -> str:
    env = os.environ if environ is None else environ
    direct = str(env.get("DAEMON_TOKEN") or "").strip()
    if direct:
        return direct
    path = str(env.get("DAEMON_TOKEN_FILE") or (Path.home() / ".ragnarok" / "plan-daemon" / "token"))
    try:
        return Path(path).read_text(encoding="utf-8").strip()
    except OSError:
        return ""


class PlanClient(object):
    def __init__(self, base: str, token: str, opener=None, timeout: int = 30):
        self.base = base.rstrip("/")
        self.token = token
        self.opener = opener
        self.timeout = timeout

    def state(self, day: str) -> dict:
        return self._req("GET", "/api/state?day=" + day, None)

    def check(self, day: str, item_id: str, done: bool) -> dict:
        return self._req("POST", "/api/check", {"day": day, "id": item_id, "done": done})

    def numbers(self, day: str, numbers: dict) -> dict:
        return self._req("POST", "/api/numbers", {"day": day, "numbers": numbers})

    def _req(self, method: str, path: str, body: dict | None) -> dict:
        if not self.token:
            raise RuntimeError("DAEMON_TOKEN is not set")
        data = None if body is None else json.dumps(body).encode("utf-8")
        req = urllib.request.Request(self.base + path, data=data, method=method)
        req.add_header("User-Agent", USER_AGENT)
        req.add_header("authorization", "Bearer " + self.token)
        req.add_header("accept", "application/json")
        if body is not None:
            req.add_header("content-type", "application/json")
        try:
            if self.opener is not None:
                res = self.opener(req)
            else:
                res = urllib.request.urlopen(req, timeout=self.timeout)
            raw = res.read().decode("utf-8")
            status = getattr(res, "status", None)
            if status is None:
                status = res.getcode()
        except urllib.error.HTTPError as exc:
            raw = exc.read().decode("utf-8", "replace")
            status = exc.code
        try:
            parsed = json.loads(raw) if raw else {}
        except ValueError:
            parsed = {}
        if not isinstance(parsed, dict):
            parsed = {}
        if status != 200 or parsed.get("ok") is False:
            detail = parsed.get("error") or raw[:300]
            raise RuntimeError("%s %s -> %s %s" % (method, path, status, detail))
        return parsed
