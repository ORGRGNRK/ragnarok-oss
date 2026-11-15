"""Hardware gate: fail closed, and never call the publisher without approval."""
from __future__ import annotations

import io
import json
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from subprocess import CompletedProcess

import support  # noqa: F401

from approve import draft_day, draft_kind, hardware_gate, run_approve
from publish import PublishResult, publish


DAY = "2026-11-08"


def cp(args, code=0, stdout="", stderr=""):
    return CompletedProcess(args, code, stdout, stderr)


class FakeClient(object):
    def __init__(self, posts=0):
        self.mutations = []
        self.posts = posts

    def state(self, day):
        return {"ok": True, "day": day, "tasks": {}, "rhythm": {}, "numbers": {"posts": self.posts}}

    def check(self, day, item_id, done):
        self.mutations.append(("check", day, item_id, done))
        return {"ok": True}

    def numbers(self, day, numbers):
        self.mutations.append(("numbers", day, numbers))
        self.posts = numbers["posts"]
        return {"ok": True, "numbers": numbers}


class GateTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.home = Path(self.tmp.name)
        self.enclave = self.home / "EnclaveAuthenticator"
        self.enclave.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        self.enclave.chmod(0o755)
        self.fido = self.home / "fido-auth.sh"
        self.fido.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        self.fido.chmod(0o755)

    def tearDown(self):
        self.tmp.cleanup()

    def _draft(self, body, name="%s-post.md" % DAY, source="model"):
        from queue_file import render_queue

        directory = self.home / "queue"
        directory.mkdir(parents=True, exist_ok=True)
        path = directory / name
        path.write_text(render_queue(name, source, DAY, body), encoding="utf-8")
        return path

    def _run(self, path, gate, publisher, client=None):
        out = io.StringIO()
        err = io.StringIO()
        with redirect_stdout(out), redirect_stderr(err):
            code = run_approve(path, self.home, gate=gate, publisher=publisher, client=client)
        return code, out.getvalue(), err.getvalue()

    def test_kind_and_day_parse(self):
        self.assertEqual(draft_kind("%s-post.md" % DAY), "post")
        self.assertEqual(draft_kind("%s-outreach-1.md" % DAY), "outreach-1")
        self.assertEqual(draft_day("%s-outreach-2.md" % DAY), DAY)

    def test_fido_ok_does_not_fall_through(self):
        calls = []

        def spawn(args, **kwargs):
            calls.append(list(args))
            if args[1:2] == ["-L"]:
                return cp(args, stdout="ioreg: yubikey\n")
            if args[0] == "osascript":
                return cp(args)
            if args[0] == str(self.fido):
                return cp(args, stdout="label:AUTH_KEY_OK\n")
            raise AssertionError(args)

        self.assertTrue(
            hardware_gate(
                "post: hello",
                spawn=spawn,
                fido_token=str(self.home / "fido2-token"),
                fido=str(self.fido),
                enclave=str(self.enclave),
            )
        )
        self.assertFalse(any(item[0] == str(self.enclave) for item in calls))

    def test_fido_without_auth_key_ok_fails_closed(self):
        def spawn(args, **kwargs):
            if args[1:2] == ["-L"]:
                return cp(args, stdout="some key\n")
            if args[0] == "osascript":
                return cp(args)
            if args[0] == str(self.fido):
                return cp(args, code=0, stdout="touched\n", stderr="AUTH_KEY_OK")
            raise AssertionError("enclave must not run when a key is listed")

        self.assertFalse(
            hardware_gate("post: hello", spawn=spawn, fido_token="fido2-token", fido=str(self.fido), enclave=str(self.enclave))
        )

        def cancelled(args, **kwargs):
            if args[1:2] == ["-L"]:
                return cp(args, stdout="some key\n")
            if args[0] == "osascript":
                return cp(args)
            if args[0] == str(self.fido):
                return cp(args, code=1, stdout="AUTH_KEY_OK\n")
            raise AssertionError(args)

        self.assertFalse(
            hardware_gate("post: hello", spawn=cancelled, fido_token="fido2-token", fido=str(self.fido), enclave=str(self.enclave))
        )

    def test_enclave_requires_ok_matching_challenge_and_signature(self):
        challenges = []

        def spawn(args, **kwargs):
            if args[1:2] == ["-L"]:
                return cp(args, stdout="")
            if args[0] == "osascript":
                return cp(args)
            if args[0] == str(self.enclave):
                challenge = args[args.index("--challenge") + 1]
                reason = args[args.index("--reason") + 1]
                self.assertRegex(challenge, r"^[0-9a-f]{32}$")
                self.assertTrue(reason.startswith("post: "))
                challenges.append(challenge)
                return cp(args, stdout=json.dumps({"ok": True, "challenge": challenge, "signature": "sig"}) + "\n")
            raise AssertionError(args)

        self.assertTrue(hardware_gate("post: one", spawn=spawn, fido_token="fido2-token", fido=str(self.fido), enclave=str(self.enclave)))
        self.assertTrue(hardware_gate("post: two", spawn=spawn, fido_token="fido2-token", fido=str(self.fido), enclave=str(self.enclave)))
        self.assertEqual(len(challenges[0]), 32)
        self.assertNotEqual(challenges[0], challenges[1])

        def mismatch(args, **kwargs):
            if args[1:2] == ["-L"]:
                return cp(args, stdout="   \n")
            if args[0] == "osascript":
                return cp(args)
            return cp(args, stdout=json.dumps({"ok": True, "challenge": "0" * 32, "signature": "sig"}))

        self.assertFalse(hardware_gate("post: x", spawn=mismatch, fido_token="fido2-token", fido=str(self.fido), enclave=str(self.enclave)))

        def cancelled(args, **kwargs):
            if args[1:2] == ["-L"]:
                return cp(args, stdout="")
            if args[0] == "osascript":
                return cp(args)
            return cp(args, code=1, stdout=json.dumps({"ok": False, "error": "cancelled"}))

        self.assertFalse(hardware_gate("post: x", spawn=cancelled, fido_token="fido2-token", fido=str(self.fido), enclave=str(self.enclave)))

        def no_signature(args, **kwargs):
            if args[1:2] == ["-L"]:
                return cp(args, stdout="")
            if args[0] == "osascript":
                return cp(args)
            challenge = args[args.index("--challenge") + 1]
            return cp(args, stdout=json.dumps({"ok": True, "challenge": challenge, "signature": "  "}))

        self.assertFalse(hardware_gate("post: x", spawn=no_signature, fido_token="fido2-token", fido=str(self.fido), enclave=str(self.enclave)))

        def garbage(args, **kwargs):
            if args[1:2] == ["-L"]:
                return cp(args, stdout="")
            if args[0] == "osascript":
                return cp(args)
            return cp(args, stdout="not json")

        self.assertFalse(hardware_gate("post: x", spawn=garbage, fido_token="fido2-token", fido=str(self.fido), enclave=str(self.enclave)))

    def test_missing_authenticators_fail_closed(self):
        def spawn(args, **kwargs):
            if args[1:2] == ["-L"]:
                raise OSError("fido2-token missing")
            if args[0] == "osascript":
                return cp(args)
            raise AssertionError(args)

        self.assertFalse(
            hardware_gate(
                "post: x",
                spawn=spawn,
                fido_token=str(self.home / "missing-token"),
                fido=str(self.home / "missing-fido"),
                enclave=str(self.home / "missing-enclave"),
            )
        )

    def test_publisher_called_zero_times_when_auth_fails(self):
        draft = self._draft("A" * 120)
        hits = []
        original = publish

        def direct(*args, **kwargs):
            hits.append("direct")
            return original(*args, **kwargs)

        def injected(*args, **kwargs):
            hits.append("injected")
            return PublishResult(True, True, "fake", "should not run")

        import publish as publish_mod

        publish_mod.publish = direct
        try:
            code, out, err = self._run(draft, lambda reason: False, injected, FakeClient())
            self.assertEqual(code, 1)
            self.assertIn("A" * 80, out)
            self.assertIn("Not approved", err)

            def cancel(reason):
                raise RuntimeError("cancelled")

            code, out, err = self._run(draft, cancel, injected, FakeClient())
            self.assertEqual(code, 1)
            self.assertIn("failed closed", err)

            # A listed-empty token and a missing enclave is "missing", not an approval.
            def quiet(args, **kwargs):
                if args[0] == "osascript":
                    return cp(args)
                return cp(args, stdout="")

            def missing_gate(reason):
                return hardware_gate(
                    reason,
                    spawn=quiet,
                    fido_token=str(self.home / "no-token"),
                    fido=str(self.home / "no-fido"),
                    enclave=str(self.home / "no-enclave"),
                )

            code, out, err = self._run(draft, missing_gate, injected, FakeClient())
            self.assertEqual(code, 1)
            self.assertIn("Not approved", err)
            self.assertEqual(hits, [])
            published = self.home / ".ragnarok" / "plan-daemon" / "published"
            self.assertFalse(published.exists())
        finally:
            publish_mod.publish = original

        # The denial return sits above the only publisher call.
        source = Path(support.DAEMON / "approve.py").read_text(encoding="utf-8")
        self.assertLess(source.index("if not ok:"), source.index("result = pub("))

    def test_reason_is_post_plus_80_chars(self):
        seen = {}

        def gate(reason):
            seen["reason"] = reason
            return False

        body = "word " * 40
        draft = self._draft(body)
        self._run(draft, gate, lambda *a, **k: PublishResult(True, True, "fake", "x"))
        reason = seen["reason"]
        self.assertTrue(reason.startswith("post: "))
        self.assertEqual(len(reason), len("post: ") + 80)
        self.assertEqual(reason, "post: " + " ".join(body.split())[:80])
        self.assertNotIn("source:", reason)
        self.assertNotIn("-post.md", reason)
        self.assertTrue(reason.startswith("post: word "))

    def test_outreach_is_never_sent(self):
        draft = self._draft("Please say hello.\n", name="%s-outreach-1.md" % DAY)

        def gate(reason):
            raise AssertionError("outreach must not ask for a post approval")

        def publisher(*args, **kwargs):
            raise AssertionError("outreach must not be published")

        code, out, err = self._run(draft, gate, publisher)
        self.assertEqual(code, 2)
        self.assertIn("Please say hello.", out)
        self.assertIn("never sent", err)

    def test_numbers_only_after_real_publish(self):
        draft = self._draft("Shipped the checklist worker.\n")

        def dry(text, kind, day, home):
            return publish(text, kind=kind, day=day, home=home, backend="dryrun")

        client = FakeClient(posts=2)
        code, out, err = self._run(draft, lambda reason: True, dry, client)
        self.assertEqual(code, 0)
        self.assertEqual(client.mutations, [])
        copy = self.home / ".ragnarok" / "plan-daemon" / "published" / ("%s-post.md" % DAY)
        posted = copy.read_text(encoding="utf-8")
        self.assertIn("Shipped the checklist worker.", posted)
        self.assertIn("Nothing was sent", posted)
        self.assertNotIn("source:", posted)
        self.assertNotIn("# %s-post.md" % DAY, posted)

        def stub(text, kind, day, home):
            return publish(text, kind=kind, day=day, home=home, backend="x")

        refused = FakeClient(posts=2)
        code, out, err = self._run(draft, lambda reason: True, stub, refused)
        self.assertEqual(code, 1)
        self.assertEqual(refused.mutations, [])
        self.assertIn("will not log in", err)

        def real(text, kind, day, home):
            return PublishResult(True, True, "fake", "posted")

        bumped = FakeClient(posts=2)
        code, out, err = self._run(draft, lambda reason: True, real, bumped)
        self.assertEqual(code, 0)
        self.assertEqual(
            bumped.mutations,
            [("check", DAY, "post", True), ("numbers", DAY, {"posts": 3})],
        )

        again = FakeClient(posts=3)
        code, out, err = self._run(draft, lambda reason: True, real, again)
        self.assertEqual(code, 0)
        self.assertEqual(again.mutations, [])

        def failed(text, kind, day, home):
            return PublishResult(False, False, "fake", "network said no")

        no = FakeClient(posts=3)
        code, out, err = self._run(draft, lambda reason: True, failed, no)
        self.assertEqual(code, 1)
        self.assertEqual(no.mutations, [])

        def denied(text, kind, day, home):
            raise AssertionError("publisher called")

        blocked = FakeClient()
        code, out, err = self._run(draft, lambda reason: False, denied, blocked)
        self.assertEqual(code, 1)
        self.assertEqual(blocked.mutations, [])


if __name__ == "__main__":
    unittest.main()
