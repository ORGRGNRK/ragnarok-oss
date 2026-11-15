import json
import os
import stat
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import touchgate

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPT = os.path.join(ROOT, "touchgate.py")

HELPER = """#!/usr/bin/env python3
import base64, json, os, subprocess, sys
mode = os.environ.get("TOUCHGATE_TEST_MODE", "approve")
args = sys.argv[1:]
challenge = ""
if "--challenge" in args:
    challenge = args[args.index("--challenge") + 1]
if mode == "sleep":
    import time
    time.sleep(30)
    sys.exit(0)
if mode == "deny":
    print(json.dumps({"ok": False, "error": "biometric_approval_not_granted"}))
    sys.exit(5)
if mode == "garbage":
    print(json.dumps({"ok": True, "challenge": challenge, "signature": "bm90LWEgc2ln"}))
    sys.exit(0)
key = os.environ["TOUCHGATE_TEST_KEY"]
work = os.environ["TOUCHGATE_TEST_WORK"]
payload = os.path.join(work, "payload")
sig = os.path.join(work, "sig")
with open(payload, "wb") as handle:
    handle.write(b"touchgate:v1:" + challenge.encode())
subprocess.check_call(
    ["openssl", "dgst", "-sha256", "-sign", key, "-out", sig, payload],
    stdout=subprocess.DEVNULL,
    stderr=subprocess.DEVNULL,
)
with open(sig, "rb") as handle:
    signature = base64.b64encode(handle.read()).decode()
print(json.dumps({"ok": True, "challenge": challenge, "signature": signature}))
"""


def write_helper(directory):
    path = os.path.join(directory, "helper.py")
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(HELPER)
    os.chmod(path, os.stat(path).st_mode | stat.S_IEXEC)
    return path


def make_key(directory):
    key = os.path.join(directory, "key.pem")
    pub = os.path.join(directory, "pub.pem")
    subprocess.check_call(
        ["openssl", "ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", key],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    subprocess.check_call(
        ["openssl", "ec", "-in", key, "-pubout", "-out", pub],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    return key, pub


class HookTests(unittest.TestCase):
    def test_cli_check_gated_and_not_gated(self):
        gated = subprocess.run(
            [sys.executable, SCRIPT, "--check", "rm -rf /"],
            capture_output=True, text=True, cwd=ROOT,
        )
        self.assertEqual(gated.returncode, 0)
        self.assertIn("GATED", gated.stdout)
        self.assertNotIn("not gated", gated.stdout)
        free = subprocess.run(
            [sys.executable, SCRIPT, "--check", "ls"],
            capture_output=True, text=True, cwd=ROOT,
        )
        self.assertEqual(free.returncode, 0)
        self.assertIn("not gated", free.stdout)

    def test_cli_blocks_when_helper_missing(self):
        with tempfile.TemporaryDirectory() as tmp:
            env = os.environ.copy()
            env["HOME"] = tmp
            payload = json.dumps({"tool_name": "Bash", "tool_input": {"command": "rm -rf ./data"}})
            result = subprocess.run(
                [sys.executable, SCRIPT],
                input=payload, capture_output=True, text=True, env=env, cwd=ROOT,
            )
            self.assertEqual(result.returncode, 2)
            self.assertIn("Do not retry or work around it.", result.stderr)
            self.assertTrue(
                "no way to ask" in result.stderr or "Linux support is planned" in result.stderr,
                result.stderr,
            )
            with open(os.path.join(tmp, ".touchgate", "log.jsonl"), encoding="utf-8") as handle:
                row = json.loads(handle.readline())
            self.assertIs(row["approved"], False)
            self.assertIn("rm -rf ./data", row["command"])

    def test_cli_allows_a_safe_command_without_a_log(self):
        with tempfile.TemporaryDirectory() as tmp:
            env = os.environ.copy()
            env["HOME"] = tmp
            payload = json.dumps({"tool_name": "Bash", "tool_input": {"command": "ls"}})
            result = subprocess.run(
                [sys.executable, SCRIPT],
                input=payload, capture_output=True, text=True, env=env, cwd=ROOT,
            )
            self.assertEqual(result.returncode, 0)
            self.assertEqual(result.stderr, "")
            self.assertFalse(os.path.exists(os.path.join(tmp, ".touchgate", "log.jsonl")))

    def test_unreadable_payloads_fail_closed(self):
        for raw in ("not json", "", "[]", "null", '"rm -rf ./data"'):
            with self.subTest(raw=raw), tempfile.TemporaryDirectory() as tmp:
                env = os.environ.copy()
                env["HOME"] = tmp
                result = subprocess.run(
                    [sys.executable, SCRIPT],
                    input=raw, capture_output=True, text=True, env=env, cwd=ROOT,
                )
                self.assertEqual(result.returncode, 2)
                self.assertIn("Do not retry", result.stderr)

    def test_crash_in_hook_fails_closed(self):
        old_stdin, old_stderr, old_run = sys.stdin, sys.stderr, touchgate.run_hook

        def boom(_payload):
            raise RuntimeError("boom")

        sys.stdin = __import__("io").StringIO("{}")
        sys.stderr = __import__("io").StringIO()
        touchgate.run_hook = boom
        try:
            self.assertEqual(touchgate.main([]), 2)
            self.assertIn("Do not retry", sys.stderr.getvalue())
        finally:
            sys.stdin, sys.stderr, touchgate.run_hook = old_stdin, old_stderr, old_run

    def test_linux_fails_closed(self):
        with tempfile.TemporaryDirectory() as tmp:
            log_file = os.path.join(tmp, "log.jsonl")
            code = touchgate.run_hook(
                {"tool_name": "Bash", "tool_input": {"command": "terraform destroy"}},
                config=touchgate.default_config(),
                log_file=log_file,
                platform="linux",
            )
            self.assertEqual(code, 2)
            with open(log_file, encoding="utf-8") as handle:
                row = json.loads(handle.readline())
            self.assertEqual(row["method"], "not-macos")
            self.assertIn("planned", row["detail"])

    def test_missing_helper_on_macos_fails_closed(self):
        with tempfile.TemporaryDirectory() as tmp:
            code = touchgate.run_hook(
                {"tool_name": "Bash", "tool_input": {"command": "rm -rf ./data"}},
                config=touchgate.default_config(),
                auth=os.path.join(tmp, "missing-helper"),
                pubkey=os.path.join(tmp, "pub.pem"),
                log_file=os.path.join(tmp, "log.jsonl"),
                platform="darwin",
            )
            self.assertEqual(code, 2)

    def test_denied_touch_exits_2(self):
        with tempfile.TemporaryDirectory() as tmp:
            helper = write_helper(tmp)
            env = os.environ.copy()
            env["TOUCHGATE_TEST_MODE"] = "deny"
            old = os.environ.get("TOUCHGATE_TEST_MODE")
            os.environ["TOUCHGATE_TEST_MODE"] = "deny"
            try:
                code = touchgate.run_hook(
                    {"tool_name": "Bash", "tool_input": {"command": "rm -rf ./data"}},
                    config=touchgate.default_config(),
                    auth=helper,
                    pubkey=os.path.join(tmp, "pub.pem"),
                    log_file=os.path.join(tmp, "log.jsonl"),
                    platform="darwin",
                )
            finally:
                if old is None:
                    os.environ.pop("TOUCHGATE_TEST_MODE", None)
                else:
                    os.environ["TOUCHGATE_TEST_MODE"] = old
            self.assertEqual(code, 2)
            self.assertIn("deny", env["TOUCHGATE_TEST_MODE"])

    def test_timeout_exits_2(self):
        with tempfile.TemporaryDirectory() as tmp:
            helper = write_helper(tmp)
            os.environ["TOUCHGATE_TEST_MODE"] = "sleep"
            try:
                code = touchgate.run_hook(
                    {"tool_name": "Bash", "tool_input": {"command": "rm -rf ./data"}},
                    config=touchgate.default_config(),
                    auth=helper,
                    pubkey=os.path.join(tmp, "pub.pem"),
                    log_file=os.path.join(tmp, "log.jsonl"),
                    platform="darwin",
                    ask_timeout=0.4,
                )
            finally:
                os.environ.pop("TOUCHGATE_TEST_MODE", None)
            self.assertEqual(code, 2)

    def test_bad_signature_exits_2(self):
        with tempfile.TemporaryDirectory() as tmp:
            helper = write_helper(tmp)
            _key, pub = make_key(tmp)
            os.environ["TOUCHGATE_TEST_MODE"] = "garbage"
            try:
                code = touchgate.run_hook(
                    {"tool_name": "Bash", "tool_input": {"command": "rm -rf ./data"}},
                    config=touchgate.default_config(),
                    auth=helper,
                    pubkey=pub,
                    log_file=os.path.join(tmp, "log.jsonl"),
                    platform="darwin",
                )
            finally:
                os.environ.pop("TOUCHGATE_TEST_MODE", None)
            self.assertEqual(code, 2)

    def test_valid_signature_exits_0(self):
        with tempfile.TemporaryDirectory() as tmp:
            helper = write_helper(tmp)
            key, pub = make_key(tmp)
            os.environ["TOUCHGATE_TEST_MODE"] = "approve"
            os.environ["TOUCHGATE_TEST_KEY"] = key
            os.environ["TOUCHGATE_TEST_WORK"] = tmp
            try:
                code = touchgate.run_hook(
                    {"tool_name": "Bash", "tool_input": {"command": "rm -rf ./data"}},
                    config=touchgate.default_config(),
                    auth=helper,
                    pubkey=pub,
                    log_file=os.path.join(tmp, "log.jsonl"),
                    platform="darwin",
                )
            finally:
                os.environ.pop("TOUCHGATE_TEST_MODE", None)
                os.environ.pop("TOUCHGATE_TEST_KEY", None)
                os.environ.pop("TOUCHGATE_TEST_WORK", None)
            self.assertEqual(code, 0)
            with open(os.path.join(tmp, "log.jsonl"), encoding="utf-8") as handle:
                row = json.loads(handle.readline())
            self.assertIs(row["approved"], True)
            self.assertEqual(row["method"], "touchid")

    def test_mcp_delete_is_gated_and_query_is_not(self):
        with tempfile.TemporaryDirectory() as tmp:
            code = touchgate.run_hook(
                {"tool_name": "mcp__github__delete_file", "tool_input": {"path": "README.md"}},
                config=touchgate.default_config(),
                log_file=os.path.join(tmp, "log.jsonl"),
                platform="linux",
            )
            self.assertEqual(code, 2)
            self.assertIsNone(touchgate.mcp_target("mcp__search__query"))
            self.assertIsNone(touchgate.mcp_target("mcp__ui__dropdown_select"))
            self.assertIsNone(touchgate.mcp_target("mcp__db__droplet_create"))
            self.assertEqual(touchgate.mcp_target("mcp__db__drop_table"), "mcp__db__drop_table")
            self.assertEqual(touchgate.mcp_target("mcp__k8s__destroy_ns"), "mcp__k8s__destroy_ns")
            self.assertEqual(touchgate.mcp_target("mcp__mail__trash_message"), "mcp__mail__trash_message")

    def test_allowlisted_rm_does_not_ask(self):
        called = []

        def approver(what):
            called.append(what)
            return False, "touchid", "denied"

        with tempfile.TemporaryDirectory() as tmp:
            code = touchgate.run_hook(
                {"tool_name": "Bash", "tool_input": {"command": "rm -rf ./node_modules"}},
                config=touchgate.default_config(),
                log_file=os.path.join(tmp, "log.jsonl"),
                platform="darwin",
                approver=approver,
            )
        self.assertEqual(code, 0)
        self.assertEqual(called, [])


if __name__ == "__main__":
    unittest.main()
