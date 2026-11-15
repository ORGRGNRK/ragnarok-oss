"""The queue header is not the post, and a fallback draft does not lock the day."""
from __future__ import annotations

import io
import json
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from datetime import datetime
from pathlib import Path
from subprocess import CompletedProcess

import support  # noqa: F401

import evidence
import model
import plan_daemon
from approve import run_approve
from publish import PublishResult


DAY = "2026-11-08"
NOW = datetime(2026, 11, 8, 9, 30)
POST = "Real post body about yesterday " + ("word " * 20)


def _queue(name, source, day, body):
    return "# %s\n\nsource: %s\nday: %s\n\n%s\n" % (name, source, day, body.strip())


class FakeClient(object):
    def __init__(self):
        self.calls = []

    def state(self, day):
        self.calls.append(("state", day))
        return {"ok": True, "day": day, "tasks": {}, "rhythm": {}, "numbers": {}}

    def check(self, day, item_id, done):
        raise AssertionError("hourly run must not tick the checklist")

    def numbers(self, day, numbers):
        raise AssertionError("hourly run must not bump numbers")


class QueueBodyTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.home = Path(self.tmp.name)
        self.repos = []
        for name in ("ragnarok", "proved-plan"):
            path = self.home / name
            path.mkdir()
            self.repos.append(path)
        self.agents = self.home / "agents"
        self.agents.mkdir()
        self.model_calls = []
        self.notes = []
        self.client = FakeClient()

    def tearDown(self):
        self.tmp.cleanup()

    def _git(self, args, **kwargs):
        return CompletedProcess(args, 0, "abc1234 2026-11-07 ship the checklist at alexus.local\n", "")

    def _cfg(self, poster):
        return plan_daemon.Config(
            home=self.home,
            now=NOW,
            repos=tuple(self.repos),
            agents_dir=self.agents,
            client=self.client,
            model_post=poster,
            git_run=self._git,
            notify=self.notes.append,
            token="test-token",
        )

    def _reply(self, post, outreach):
        def poster(url, payload):
            self.model_calls.append(payload)
            return {"message": {"content": json.dumps({"post": post, "outreach": outreach})}}

        return poster

    def _down(self, url, payload):
        self.model_calls.append(payload)
        raise RuntimeError("model down")

    def _actions(self):
        log = (self.home / ".ragnarok" / "plan-daemon" / "log.jsonl").read_text(encoding="utf-8")
        return [json.loads(line)["action"] for line in log.splitlines() if line.strip()]

    def test_publisher_and_reason_use_the_body(self):
        directory = self.home / "queue"
        directory.mkdir()
        name = "%s-post.md" % DAY
        path = directory / name
        path.write_text(_queue(name, "model", DAY, POST), encoding="utf-8")
        seen = {}

        def gate(reason):
            seen["reason"] = reason
            return True

        def publisher(text, kind, day, home):
            seen["text"] = text
            return PublishResult(True, False, "dryrun", "kept")

        out = io.StringIO()
        err = io.StringIO()
        with redirect_stdout(out), redirect_stderr(err):
            code = run_approve(path, self.home, gate=gate, publisher=publisher, client=FakeClient())
        self.assertEqual(code, 0)
        self.assertEqual(seen["text"].strip(), POST.strip())
        self.assertNotIn("source:", seen["text"])
        self.assertNotIn("day:", seen["text"])
        self.assertNotIn(name, seen["text"])
        flat = " ".join(POST.split())
        self.assertEqual(seen["reason"], "post: " + flat[:80])
        self.assertTrue(seen["reason"].startswith("post: Real post body about yesterday"))
        self.assertEqual(len(seen["reason"]), len("post: ") + 80)
        self.assertNotIn("source:", seen["reason"])
        self.assertNotIn("-post.md", seen["reason"])
        self.assertIn("source: model", out.getvalue())

    def test_fallback_and_unlabeled_are_refused_before_the_gate(self):
        directory = self.home / "queue"
        directory.mkdir()
        name = "%s-post.md" % DAY
        cases = [
            _queue(name, "fallback", DAY, "Notes from the last 24 hours.\n"),
            "Real post body about yesterday\n",
            _queue(name, "model", DAY, ""),
        ]
        for raw in cases:
            path = directory / name
            path.write_text(raw, encoding="utf-8")
            gates = []
            published = []

            def gate(reason):
                gates.append(reason)
                return True

            def publisher(text, kind, day, home):
                published.append(text)
                return PublishResult(True, True, "fake", "posted")

            err = io.StringIO()
            with redirect_stdout(io.StringIO()), redirect_stderr(err):
                code = run_approve(path, self.home, gate=gate, publisher=publisher, client=FakeClient())
            self.assertEqual(code, 2, raw)
            self.assertEqual(gates, [])
            self.assertEqual(published, [])
            self.assertIn("not a model draft", err.getvalue())

    def test_fallback_is_replaced_when_the_model_recovers(self):
        first = plan_daemon.run(self._cfg(self._down))
        self.assertEqual(first["source"], "fallback")
        self.assertEqual(len(self.model_calls), 1)
        self.assertEqual(len(self.notes), 1)
        post = Path(first["files"][0])
        self.assertIn("source: fallback", post.read_text(encoding="utf-8"))
        held = post.read_bytes()

        again = plan_daemon.run(self._cfg(self._down))
        self.assertFalse(again["drafted"])
        self.assertEqual(again["source"], "fallback")
        self.assertEqual(len(self.model_calls), 2)
        self.assertEqual(len(self.notes), 1)
        self.assertEqual(post.read_bytes(), held)

        healthy = self._reply(
            "Shipped the checklist worker.",
            [
                "Hello, local business owner. This is a draft and nothing was sent.",
                "Hello, developer who ships software. This is a draft and nothing was sent.",
            ],
        )
        recovered = plan_daemon.run(self._cfg(healthy))
        self.assertTrue(recovered["drafted"])
        self.assertEqual(recovered["source"], "model")
        self.assertEqual(len(self.model_calls), 3)
        text = post.read_text(encoding="utf-8")
        self.assertIn("source: model", text)
        self.assertIn("Shipped the checklist worker.", text)
        self.assertNotIn("source: fallback", text)
        self.assertEqual(self.notes[-1], "Draft ready (%s). Approve it in Terminal before anything goes out." % DAY)

    def test_state_is_read_when_model_drafts_exist(self):
        poster = self._reply(
            "Shipped the checklist worker.",
            [
                "Hello, local business owner. This is a draft and nothing was sent.",
                "Hello, developer who ships software. This is a draft and nothing was sent.",
            ],
        )
        plan_daemon.run(self._cfg(poster))
        again = plan_daemon.run(self._cfg(poster))
        self.assertFalse(again["drafted"])
        self.assertEqual(len(self.model_calls), 1)
        self.assertEqual(self.client.calls, [("state", DAY), ("state", DAY)])
        actions = self._actions()
        starts = [index for index, action in enumerate(actions) if action == "start"]
        second = actions[starts[1] :]
        self.assertLess(second.index("api_state"), second.index("skip"))

    def test_machine_greeting_is_not_saved_as_a_model_draft(self):
        poster = self._reply(
            "Shipped the checklist worker.",
            [
                "Hi Alexus, I've been working on the checklist.",
                "Hi Assistant, I've updated the receipts hook.",
            ],
        )
        result = plan_daemon.run(self._cfg(poster))
        self.assertEqual(result["source"], "fallback")
        text = Path(result["files"][0]).read_text(encoding="utf-8")
        self.assertIn("source: fallback", text)
        self.assertNotIn("Hi Alexus", text)
        self.assertNotIn("Hi Assistant", text)
        with self.assertRaises(ValueError):
            model.require_human_outreach(
                {
                    "post": "Noted.",
                    "outreach": [
                        "Hi Sam, the receipts hook is updated.",
                        "Hello, local business owner. Draft only.",
                    ],
                },
                evidence="ship the checklist",
            )

    def test_redact_strips_ip_addresses(self):
        sample = evidence.redact("abc1234 shipped at alexus.local via fe80::1 and 2001:db8::1")
        self.assertIn("abc1234", sample)
        self.assertNotIn("alexus.local", sample)
        self.assertNotIn("fe80::1", sample)
        self.assertNotIn("2001:db8::1", sample)
        self.assertIn("[redacted]", sample)
        facts = evidence.collect(NOW, self.repos, self.agents, self._git)
        self.assertNotIn("alexus.local", facts)
        self.assertIn("abc1234", facts)
        dumped = model.fallback_draft("see 10.1.2.3 for the host")
        self.assertNotIn("10.1.2.3", dumped["post"])

    def test_system_names_a_human_audience(self):
        system = model.SYSTEM
        lowered = system.lower()
        self.assertIn("local business owner", lowered)
        self.assertIn("developer who ships software", lowered)
        self.assertIn("alexus", lowered)
        self.assertIn("do not invent a personal name", lowered)
        self.assertIn("another assistant", lowered)
        sent = model.chat_payload("evidence")["messages"][0]["content"]
        self.assertEqual(sent, system)
        kept = model.require_human_outreach(
            {
                "post": "Noted the commit.",
                "outreach": [
                    "Hello, local business owner. This is a draft and nothing was sent.",
                    "Hello, developer who ships software. This is a draft and nothing was sent.",
                ],
            },
            evidence="ship the checklist",
        )
        self.assertIn("local business owner", kept["outreach"][0])


if __name__ == "__main__":
    unittest.main()
