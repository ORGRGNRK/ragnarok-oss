"""Drafting, queue files, and the rule that the hourly run never posts."""
from __future__ import annotations

import json
import re
import tempfile
import unittest
from datetime import datetime
from pathlib import Path
from subprocess import CompletedProcess

import support  # noqa: F401  (puts daemon/ on sys.path)

import model
import plan_daemon
import publish
from journal import log_action


DAY = "2026-11-08"
NOW = datetime(2026, 11, 8, 9, 30)


class FakeClient(object):
    def __init__(self, state=None, fail=False):
        self.calls = []
        self.fail = fail
        self.state_body = state or {
            "ok": True,
            "day": DAY,
            "tasks": {},
            "rhythm": {},
            "numbers": {},
        }

    def state(self, day):
        self.calls.append(("state", day))
        if self.fail:
            raise RuntimeError("api down")
        return self.state_body

    def check(self, day, item_id, done):
        self.calls.append(("check", day, item_id, done))
        raise AssertionError("hourly run must not tick the checklist")

    def numbers(self, day, numbers):
        self.calls.append(("numbers", day, numbers))
        raise AssertionError("hourly run must not bump numbers")


class DraftTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.home = Path(self.tmp.name)
        self.repos = []
        for name in ("ragnarok", "proved-plan"):
            path = self.home / name
            path.mkdir()
            self.repos.append(path)
        self.agents = self.home / "agents"
        job = self.agents / "job1"
        job.mkdir(parents=True)
        (job / "state.json").write_text(
            json.dumps(
                {
                    "id": "job1",
                    "name": "Format badges",
                    "status": "done",
                    "verdict": "pass",
                    "final": "helper landed",
                    "task": "do not leak this prompt body",
                }
            ),
            encoding="utf-8",
        )
        self.model_calls = []
        self.notes = []
        self.client = FakeClient()

    def tearDown(self):
        self.tmp.cleanup()

    def _git(self, args, **kwargs):
        return CompletedProcess(args, 0, "abc123 2026-11-07 ship the checklist\n", "")

    def _model(self, url, payload):
        self.model_calls.append((url, payload))
        return {
            "message": {
                "content": json.dumps(
                    {
                        "post": "Shipped the checklist worker.",
                        "outreach": ["Hello one, draft only.", "Hello two, draft only."],
                    }
                )
            }
        }

    def _cfg(self, **overrides):
        values = dict(
            home=self.home,
            now=NOW,
            repos=tuple(self.repos),
            agents_dir=self.agents,
            client=self.client,
            model_post=self._model,
            git_run=self._git,
            notify=self.notes.append,
            token="test-token",
        )
        values.update(overrides)
        return plan_daemon.Config(**values)

    def test_drafts_queue_files_from_real_evidence(self):
        result = plan_daemon.run(self._cfg())
        self.assertTrue(result["drafted"])
        self.assertEqual(result["source"], "model")
        names = [Path(path).name for path in result["files"]]
        self.assertEqual(names, ["%s-post.md" % DAY, "%s-outreach-1.md" % DAY, "%s-outreach-2.md" % DAY])
        post = Path(result["files"][0]).read_text(encoding="utf-8")
        self.assertIn("Shipped the checklist worker.", post)
        self.assertIn("source: model", post)
        first = Path(result["files"][1]).read_text(encoding="utf-8")
        second = Path(result["files"][2]).read_text(encoding="utf-8")
        self.assertIn("Hello one, draft only.", first)
        self.assertIn("DRAFT ONLY", first)
        self.assertIn("Hello two, draft only.", second)
        self.assertIn("never sent", first)

        self.assertEqual(len(self.model_calls), 1)
        url, payload = self.model_calls[0]
        self.assertEqual(url, model.MODEL_URL)
        self.assertEqual(payload["model"], "llama3.1:8b")
        self.assertEqual(payload["options"]["num_ctx"], 8192)
        self.assertEqual(payload["options"]["temperature"], 0)
        self.assertIs(payload["stream"], False)
        self.assertEqual(payload["format"], model.DRAFT_SCHEMA)
        self.assertEqual(payload["format"]["required"], ["post", "outreach"])
        evidence_text = payload["messages"][1]["content"]
        self.assertIn("abc123", evidence_text)
        self.assertIn("ship the checklist", evidence_text)
        self.assertIn("Format badges", evidence_text)
        self.assertIn("verdict=pass", evidence_text)
        self.assertNotIn("do not leak this prompt body", evidence_text)
        self.assertEqual(self.notes, ["Draft ready (%s). Approve it in Terminal before anything goes out." % DAY])
        self.assertEqual([call[0] for call in self.client.calls], ["state"])

        log = (self.home / ".ragnarok" / "plan-daemon" / "log.jsonl").read_text(encoding="utf-8")
        actions = [json.loads(line)["action"] for line in log.splitlines()]
        for action in ("start", "api_state", "evidence", "model", "queue_write", "notify"):
            self.assertIn(action, actions)

    def test_second_run_does_not_redraft_or_notify(self):
        plan_daemon.run(self._cfg())
        again = plan_daemon.run(self._cfg())
        self.assertFalse(again["drafted"])
        self.assertEqual(len(self.model_calls), 1)
        self.assertEqual(len(self.notes), 1)
        self.assertEqual(self.client.calls, [("state", DAY), ("state", DAY)])
        log = (self.home / ".ragnarok" / "plan-daemon" / "log.jsonl").read_text(encoding="utf-8")
        self.assertIn('"action": "skip"', log)

    def test_model_failure_still_queues_a_factual_fallback(self):
        def boom(url, payload):
            raise RuntimeError("model down")

        result = plan_daemon.run(self._cfg(model_post=boom))
        self.assertEqual(result["source"], "fallback")
        text = Path(result["files"][0]).read_text(encoding="utf-8")
        self.assertIn("source: fallback", text)
        self.assertIn("ship the checklist", text)
        self.assertIn("local model did not answer", text)
        self.assertEqual(len(self.notes), 1)
        self.assertIn("did not answer", self.notes[0])
        self.assertNotIn("Draft ready", self.notes[0])

    def test_api_failure_does_not_block_drafts_or_tick_the_site(self):
        client = FakeClient(fail=True)
        result = plan_daemon.run(self._cfg(client=client))
        self.assertTrue(result["drafted"])
        self.assertEqual(client.calls, [("state", DAY)])
        log = (self.home / ".ragnarok" / "plan-daemon" / "log.jsonl").read_text(encoding="utf-8")
        self.assertIn('"ok": false', log)

    def test_daemon_does_not_call_publisher(self):
        calls = []
        original = publish.publish

        def spy(*args, **kwargs):
            calls.append(1)
            return original(*args, **kwargs)

        publish.publish = spy
        try:
            plan_daemon.run(self._cfg())
        finally:
            publish.publish = original
        self.assertEqual(calls, [])
        source = Path(plan_daemon.__file__).read_text(encoding="utf-8")
        self.assertNotIn("import publish", source)
        self.assertNotIn("publish.publish", source)

    def test_chat_payload_sets_draft_schema(self):
        payload = model.chat_payload("one commit")
        schema = payload["format"]
        self.assertEqual(schema["type"], "object")
        self.assertEqual(schema["properties"]["post"]["type"], "string")
        outreach = schema["properties"]["outreach"]
        self.assertEqual(outreach["type"], "array")
        self.assertEqual(outreach["items"]["type"], "string")
        self.assertEqual(outreach["minItems"], 2)
        self.assertEqual(outreach["maxItems"], 2)
        self.assertEqual(schema["required"], ["post", "outreach"])
        parsed = model.parse_draft(json.dumps({"post": "Noted the commit.", "outreach": ["Draft one.", "Draft two."]}))
        self.assertEqual(parsed["outreach"], ["Draft one.", "Draft two."])

    def test_model_module_has_one_local_endpoint(self):
        text = Path(model.__file__).read_text(encoding="utf-8")
        urls = re.findall(r"https?://[^\s\"']+", text)
        self.assertEqual(urls, [])   # the one endpoint comes from local.conf (OLLAMA_URL / ALEXUS_HOST)
        self.assertTrue(model.MODEL_URL.endswith(":11434/api/chat") or model.MODEL_URL.endswith("/api/chat"))

    def test_notify_ready_uses_osascript(self):
        seen = []

        def spawn(args, **kwargs):
            seen.append(list(args))
            return CompletedProcess(args, 0, "", "")

        plan_daemon.notify_ready("Draft ready", spawn=spawn)
        self.assertEqual(seen[0][0], "osascript")
        self.assertEqual(seen[0][1], "-e")
        self.assertIn("display notification", seen[0][2])
        self.assertIn("Draft ready", seen[0][2])

    def test_log_drops_secret_fields(self):
        log_action(self.home, "example", token="nope", detail="kept")
        line = (self.home / ".ragnarok" / "plan-daemon" / "log.jsonl").read_text(encoding="utf-8")
        self.assertNotIn("nope", line)
        self.assertIn("kept", line)


if __name__ == "__main__":
    unittest.main()
