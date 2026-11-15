"""Dry-run writes a local copy. Real networks refuse and store nothing."""
from __future__ import annotations

import os
import tempfile
import unittest
from pathlib import Path

import support  # noqa: F401

from plan_api import PlanClient, load_token
from publish import publish


class PublishTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.home = Path(self.tmp.name)
        self.old = os.environ.pop("PLAN_PUBLISH_BACKEND", None)

    def tearDown(self):
        if self.old is None:
            os.environ.pop("PLAN_PUBLISH_BACKEND", None)
        else:
            os.environ["PLAN_PUBLISH_BACKEND"] = self.old
        self.tmp.cleanup()

    def test_default_is_dryrun_and_not_a_real_post(self):
        result = publish("Hello from yesterday.", kind="post", day="2026-11-08", home=self.home)
        self.assertTrue(result.ok)
        self.assertFalse(result.published)
        self.assertEqual(result.backend, "dryrun")
        text = Path(result.path).read_text(encoding="utf-8")
        self.assertIn("Hello from yesterday.", text)
        self.assertIn("Nothing was sent", text)
        self.assertTrue(str(result.path).startswith(str(self.home)))

    def test_real_backend_refuses_without_storing_anything(self):
        for backend in ("x", "mastodon", "bluesky", "real"):
            result = publish("secret draft", kind="post", day="2026-11-08", home=self.home, backend=backend)
            self.assertFalse(result.ok)
            self.assertFalse(result.published)
            self.assertIn("will not log in", result.detail)
            self.assertEqual(result.path, "")
        published = self.home / ".ragnarok" / "plan-daemon" / "published"
        self.assertFalse(published.exists())
        blob = ""
        for path in self.home.rglob("*"):
            if path.is_file():
                blob += path.read_text(encoding="utf-8")
        self.assertNotIn("secret draft", blob)

    def test_client_shapes_and_token_file(self):
        seen = []

        class Resp(object):
            def __init__(self, status, body):
                self.status = status
                self._body = body

            def read(self):
                return self._body

            def getcode(self):
                return self.status

        def opener(req):
            seen.append(req)
            url = req.full_url
            if url.endswith("/api/state?day=2026-11-08"):
                return Resp(200, b'{"ok":true,"numbers":{"posts":1}}')
            if url.endswith("/api/check"):
                return Resp(200, b'{"ok":true,"rhythm":{"post":true}}')
            if url.endswith("/api/numbers"):
                return Resp(200, b'{"ok":true,"numbers":{"posts":2}}')
            raise AssertionError(url)

        client = PlanClient("https://plan.rgnrk.co", "secret-token", opener=opener)
        self.assertEqual(client.state("2026-11-08")["numbers"]["posts"], 1)
        client.check("2026-11-08", "post", True)
        client.numbers("2026-11-08", {"posts": 2})
        self.assertEqual(seen[0].get_header("Authorization"), "Bearer secret-token")
        for req in seen:
            self.assertEqual(req.get_header("User-agent"), "proved-plan-daemon/1.0")
            self.assertNotIn("urllib", req.get_header("User-agent").lower())
        self.assertEqual(seen[0].get_method(), "GET")
        self.assertTrue(seen[1].full_url.endswith("/api/check"))
        self.assertEqual(seen[1].get_method(), "POST")
        import json

        self.assertEqual(json.loads(seen[1].data.decode("utf-8")), {"day": "2026-11-08", "id": "post", "done": True})
        self.assertEqual(json.loads(seen[2].data.decode("utf-8"))["numbers"], {"posts": 2})

        token = self.home / "token"
        token.write_text("  from-file\n", encoding="utf-8")
        self.assertEqual(load_token({"DAEMON_TOKEN_FILE": str(token)}), "from-file")
        self.assertEqual(load_token({"DAEMON_TOKEN": " inline ", "DAEMON_TOKEN_FILE": str(token)}), "inline")
        self.assertEqual(load_token({"DAEMON_TOKEN_FILE": str(self.home / "missing")}), "")

        def down(req):
            return Resp(401, b'{"ok":false,"error":"Unauthorized"}')

        with self.assertRaises(RuntimeError):
            PlanClient("https://plan.rgnrk.co", "nope", opener=down).state("2026-11-08")


if __name__ == "__main__":
    unittest.main()
