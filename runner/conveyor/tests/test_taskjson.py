#!/usr/bin/env python3
"""Unit tests for conveyor-taskjson (branch json-tasks). Mocks only: the one
network test talks to a stand-in OpenAI-compatible server on 127.0.0.1 that
this file starts and stops; no model or real API is called.

    python3 tests/test_taskjson.py      (stdlib only, Python 3.8+)
"""
import copy
import http.server
import importlib.machinery
import importlib.util
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import unittest

PKG = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TOOL = os.path.join(PKG, "conveyor-taskjson")
SCHEMA_DIR = os.path.join(PKG, "task-schema")
_loader = importlib.machinery.SourceFileLoader("taskjson", TOOL)
_spec = importlib.util.spec_from_loader("taskjson", _loader)
TJ = importlib.util.module_from_spec(_spec)
_loader.exec_module(TJ)

with open(os.path.join(SCHEMA_DIR, "example-task.json")) as _f:
    EXAMPLE = json.load(_f)


def run(*args, env=None, stdin=None):
    e = dict(os.environ)
    e.update(env or {})
    return subprocess.run([sys.executable, TOOL] + list(args), capture_output=True, text=True, env=e, input=stdin)


def put(path, mode, text):
    with open(path, mode) as f:
        f.write(text)


def get_json(path):
    with open(path) as f:
        return json.load(f)


def good(root="/tmp/x"):
    """A minimal valid task (the example task, re-rooted)."""
    t = copy.deepcopy(EXAMPLE)
    t["root"] = root
    return t


class Validation(unittest.TestCase):
    def test_example_task_is_valid(self):
        r = run("validate", os.path.join(SCHEMA_DIR, "example-task.json"))
        self.assertEqual(r.returncode, 0, r.stdout)
        self.assertTrue(r.stdout.startswith("VALID"))

    def test_broken_schema_example_rejected(self):
        r = run("validate", os.path.join(SCHEMA_DIR, "broken-schema-example.json"))
        self.assertEqual(r.returncode, 1)
        self.assertIn("INVALID", r.stdout)

    def test_broken_rules_example_rejected(self):
        r = run("validate", os.path.join(SCHEMA_DIR, "broken-rules-example.json"))
        self.assertEqual(r.returncode, 1)
        self.assertIn("INVALID", r.stdout)

    def test_missing_field_and_wrong_secrets(self):
        t = good(); del t["goal"]; t["constraints"]["secrets"] = "allowed"
        errs = TJ.task_errors(t)
        self.assertTrue(any("goal" in e for e in errs), errs)

    def test_write_scope_must_cover_files(self):
        t = good(); t["files_to_touch"].append({"path": "elsewhere/file.py", "action": "edit"})
        self.assertTrue(TJ.task_errors(t))

    def test_human_check_rejected_by_default_allowed_by_switch(self):
        t = good(); t["acceptance"]["checks"].append({"claim": "a person likes it", "verify": "HUMAN"})
        os.environ.pop("CONVEYOR_JSON_ALLOW_HUMAN", None)
        self.assertTrue(any("HUMAN" in e for e in TJ.task_errors(t)))
        os.environ["CONVEYOR_JSON_ALLOW_HUMAN"] = "1"
        try:
            self.assertEqual(TJ.task_errors(t), [])
        finally:
            del os.environ["CONVEYOR_JSON_ALLOW_HUMAN"]

    def test_trivial_and_duplicate_checks(self):
        t = good(); t["acceptance"]["checks"] = [{"claim": "it works", "verify": "true"}, {"claim": "it works", "verify": "ls -la"}]
        errs = TJ.task_errors(t)
        self.assertTrue(any("proves nothing" in e for e in errs), errs)
        self.assertTrue(any("same claim" in e for e in errs), errs)

    def test_allowed_roots(self):
        t = good("/srv/other/project")
        os.environ["CONVEYOR_JSON_ALLOWED_ROOTS"] = "/srv/code:/tmp"
        try:
            self.assertTrue(any("ALLOWED_ROOTS" in e for e in TJ.task_errors(t)))
            self.assertEqual(TJ.task_errors(good("/tmp/ok")), [])
        finally:
            del os.environ["CONVEYOR_JSON_ALLOWED_ROOTS"]


class Secrets(unittest.TestCase):
    # Fake tokens are assembled at run time so this file never holds one.
    FAKES = ["s" + "k-" + "A1b2C3d4" * 3, "x" + "ai-" + "Z9" * 12, "gh" + "p_" + "q" * 30,
             "AK" + "IA" + "ABCDEFGHIJKLMNOP", "-----BEGIN RSA PRIV" + "ATE KEY-----"]

    def test_tokens_anywhere_are_rejected(self):
        for fake in self.FAKES:
            t = good(); t["steps"].append("Use %s when calling the service." % fake)
            self.assertTrue(any("credential" in e for e in TJ.task_errors(t)), fake)

    def test_reading_secret_stores_is_rejected(self):
        for cmd in ["cat .env", "grep KEY ~/.ssh/id_rsa", "printenv", "security find-generic-password -s x -w"]:
            t = good(); t["acceptance"]["checks"].append({"claim": "reads it %s" % cmd, "verify": cmd})
            self.assertTrue(any("secret store" in e for e in TJ.task_errors(t)), cmd)

    def test_ordinary_words_are_fine(self):
        t = good(); t["steps"].append("Mention the token bucket and the environment variable docs.")
        self.assertEqual(TJ.task_errors(t), [])


class Extraction(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.mkdtemp()
        self.raw, self.text, self.out = (os.path.join(self.d, n) for n in ("a.jsonl", "a.log", "t.json"))

    def tearDown(self):
        shutil.rmtree(self.d)

    def write(self, raw="", text=""):
        put(self.raw, "w", raw); put(self.text, "w", text)

    def test_native_structured_output_wins(self):
        self.write(raw=json.dumps({"type": "result", "result": "x", "structured_output": good()}) + "\n", text="junk")
        r = run("extract-task", self.raw, self.text, self.out, "--by", "planner:test")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("structured output", r.stderr)

    def test_fenced_block_in_prose(self):
        self.write(text="Sure! Here it is:\n```json\n%s\n```\nHope that helps." % json.dumps(good(), indent=2))
        r = run("extract-task", self.raw, self.text, self.out, "--by", "planner:test")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("fenced", r.stderr)

    def test_bare_object_in_prose(self):
        self.write(text="The plan: %s -- done." % json.dumps(good()))
        self.assertEqual(run("extract-task", self.raw, self.text, self.out, "--by", "p").returncode, 0)

    def test_belt_stamps_status_and_provenance(self):
        t = good(); t["status"] = "proposed"; t["provenance"] = {"proposed_by": "me", "source": "chat", "proposed_at": "nope"}
        self.write(text=json.dumps(t))
        r = run("extract-task", self.raw, self.text, self.out, "--by", "planner:claude")
        self.assertEqual(r.returncode, 0, r.stdout)
        got = get_json(self.out)
        self.assertEqual(got["status"], "queue")
        self.assertEqual(got["provenance"]["proposed_by"], "planner:claude")
        self.assertEqual(got["provenance"]["source"], "planner")
        self.assertRegex(got["provenance"]["proposed_at"], r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d[+-]\d\d:\d\d$")

    def test_no_json_and_invalid_json_are_reported(self):
        self.write(text="I could not do it.")
        r = run("extract-task", self.raw, self.text, self.out, "--by", "p")
        self.assertEqual(r.returncode, 1); self.assertIn("no task JSON", r.stdout)
        t = good(); del t["steps"]
        self.write(text=json.dumps(t))
        r = run("extract-task", self.raw, self.text, self.out, "--by", "p")
        self.assertEqual(r.returncode, 1); self.assertIn("steps", r.stdout)

    def test_verdicts(self):
        self.write(text='{"verdict": "pass", "issues": []}')
        r = run("extract-verdict", self.raw, self.text, self.out)
        self.assertEqual((r.returncode, r.stdout.strip()), (0, "pass"))
        v = {"verdict": "issues", "issues": [{"where": "steps[0]", "problem": "too vague to act on", "fix": "name the file"}]}
        self.write(text=json.dumps(v))
        r = run("extract-verdict", self.raw, self.text, self.out)
        self.assertEqual(r.returncode, 0)
        self.assertEqual(r.stdout.splitlines(), ["issues", "ISSUE: steps[0]: too vague to act on (fix: name the file)"])
        for bad in ['{"verdict": "pass", "issues": [{"where": "x", "problem": "a real problem"}]}',
                    '{"verdict": "issues", "issues": []}', '{"verdict": "maybe", "issues": []}']:
            self.write(text=bad)
            self.assertEqual(run("extract-verdict", self.raw, self.text, self.out).returncode, 1, bad)


class Rendering(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.mkdtemp()
        self.repo = os.path.join(self.d, "repo")
        os.makedirs(self.repo)
        g = lambda *a: subprocess.run(["git", "-C", self.repo] + list(a), check=True, capture_output=True)
        g("init", "-q")
        put(os.path.join(self.repo, "README"), "w", "seed\n")
        g("add", "README"); g("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "seed")
        self.t = {"schema_version": "conveyor-task/0.1", "id": "add-notes", "title": "Add notes file",
                  "goal": "notes/today.md exists and says hello.", "project": "demo", "root": self.repo,
                  "files_to_touch": [{"path": "notes/today.md", "action": "create"}],
                  "steps": ["Create notes/today.md containing hello."],
                  "constraints": {"network": "none", "secrets": "none", "write_scope": ["notes/"]},
                  "acceptance": {"checks": [
                      {"claim": "today.md says hello", "verify": "grep -q hello notes/today.md"},
                      {"claim": "exactly one line", "verify": "wc -l < notes/today.md", "expect": "^\\s*1$"}],
                      "expected_result": "notes/today.md says hello."},
                  "limits": {"max_files_changed": 1, "max_lines_changed": 3}, "depends_on": [],
                  "status": "queue", "provenance": {"proposed_by": "planner:test", "source": "planner",
                                                    "proposed_at": "2026-10-28T01:00:00-07:00"}}
        self.f = os.path.join(self.d, "t.task.json")
        put(self.f, "w", json.dumps(self.t))

    def tearDown(self):
        shutil.rmtree(self.d)

    def render(self):
        r = run("render", self.f, "--tool", TOOL, "--note", "planned by test")
        self.assertEqual(r.returncode, 0, r.stderr)
        return r.stdout

    def test_render_is_a_checklist_conveyor_check_reads(self):
        body = self.render()
        self.assertIn("Goal: notes/today.md exists and says hello.", body)
        self.assertIn("- secrets: none", body)
        self.assertIn("- write only: notes/", body)
        md = os.path.join(self.d, "task.md")
        put(md, "w", "# Add notes file\n\n" + body)
        r = subprocess.run([sys.executable, os.path.join(PKG, "conveyor-check"), "--list", md], capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(len([ln for ln in r.stdout.splitlines() if ln.strip()]), 3, r.stdout)
        self.assertIn(":: verify: cd %s && grep -q hello notes/today.md" % self.repo, body)
        self.assertIn(":: expect: ^\\s*1$", body)
        self.assertRegex(body, r"(?m)^- \[ \] only files inside write_scope changed.* scope-check ")

    def test_render_runs_the_tasks_commands(self):
        body = self.render()
        md = os.path.join(self.d, "task.md")
        put(md, "w", "# x\n\n" + body)
        check = [sys.executable, os.path.join(PKG, "conveyor-check"), md]
        self.assertNotEqual(subprocess.run(check, capture_output=True, text=True, cwd=self.d).returncode, 0)
        os.makedirs(os.path.join(self.repo, "notes"))
        put(os.path.join(self.repo, "notes", "today.md"), "w", "hello\n")
        put(md, "w", "# x\n\n" + body)
        r = subprocess.run(check, capture_output=True, text=True, cwd=self.d)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual(r.stdout.count("PASS"), 3, r.stdout)

    def test_scope_check(self):
        self.render()  # records the baseline
        os.makedirs(os.path.join(self.repo, "notes"))
        put(os.path.join(self.repo, "notes", "today.md"), "w", "hello\n")
        self.assertEqual(run("scope-check", self.f).returncode, 0)
        put(os.path.join(self.repo, "README"), "a", "changed\n")
        r = run("scope-check", self.f)
        self.assertEqual(r.returncode, 1)
        self.assertIn("outside write_scope: README", r.stdout)
        subprocess.run(["git", "-C", self.repo, "checkout", "-q", "README"], check=True)
        put(os.path.join(self.repo, "notes", "today.md"), "w", "hello\n" * 10)
        r = run("scope-check", self.f)
        self.assertEqual(r.returncode, 1)
        self.assertIn("lines changed, limit 3", r.stdout)

    def test_pre_existing_dirty_files_are_not_blamed(self):
        put(os.path.join(self.repo, "scratch.txt"), "w", "was here before\n")
        self.render()
        os.makedirs(os.path.join(self.repo, "notes"))
        put(os.path.join(self.repo, "notes", "today.md"), "w", "hello\n")
        self.assertEqual(run("scope-check", self.f).returncode, 0)

    def test_non_git_root_gets_a_note_not_a_scope_line(self):
        self.t["root"] = os.path.join(self.d, "plain"); os.makedirs(self.t["root"])
        put(self.f, "w", json.dumps(self.t))
        body = self.render()
        self.assertIn("Scope note:", body)
        self.assertNotIn("scope-check", body)

    def test_invalid_task_is_not_rendered(self):
        del self.t["steps"]; put(self.f, "w", json.dumps(self.t))
        self.assertEqual(run("render", self.f, "--tool", TOOL, "--note", "x").returncode, 1)


class FakeServer(http.server.BaseHTTPRequestHandler):
    seen = []
    reply = ""

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        FakeServer.seen.append((self.path, dict(self.headers), body))
        out = json.dumps({"choices": [{"message": {"role": "assistant", "content": FakeServer.reply}}]}).encode()
        self.send_response(200); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(out))); self.end_headers(); self.wfile.write(out)

    def log_message(self, *a):
        pass


class ApiSeat(unittest.TestCase):
    def setUp(self):
        self.srv = http.server.HTTPServer(("127.0.0.1", 0), FakeServer)
        threading.Thread(target=self.srv.serve_forever, daemon=True).start()
        self.url = "http://127.0.0.1:%d/v1" % self.srv.server_address[1]
        FakeServer.seen = []

    def tearDown(self):
        self.srv.shutdown(); self.srv.server_close()

    def test_schema_is_sent_key_is_used_and_never_printed(self):
        FakeServer.reply = json.dumps(good())
        fake_key = "local-test-" + "k" * 12
        sf = os.path.join(SCHEMA_DIR, "task.schema.json")
        r = run("api", stdin="plan this", env={
            "CONVEYOR_API_ROLE": "planner", "CONVEYOR_PLANNER_API_BASE_URL": self.url,
            "CONVEYOR_PLANNER_API_MODEL": "any-model", "CONVEYOR_API_KEY_ENV": "MY_TEST_KEY",
            "MY_TEST_KEY": fake_key, "CONVEYOR_API_SCHEMA_FILE": sf})
        self.assertEqual(r.returncode, 0, r.stderr)
        path, headers, body = FakeServer.seen[0]
        self.assertEqual(path, "/v1/chat/completions")
        self.assertEqual(body["model"], "any-model")
        self.assertEqual(body["response_format"]["type"], "json_schema")
        self.assertEqual(body["response_format"]["json_schema"]["schema"]["$id"], get_json(sf)["$id"])
        self.assertEqual(headers.get("Authorization"), "Bearer " + fake_key)
        self.assertNotIn(fake_key, r.stdout + r.stderr)
        ev = json.loads(r.stdout.strip().splitlines()[-1])
        self.assertEqual(ev["structured_output"]["id"], EXAMPLE["id"])

    def test_response_format_none_and_missing_settings(self):
        FakeServer.reply = "not json"
        r = run("api", stdin="x", env={"CONVEYOR_API_BASE_URL": self.url, "CONVEYOR_API_MODEL": "m",
                                       "CONVEYOR_API_RESPONSE_FORMAT": "none",
                                       "CONVEYOR_API_SCHEMA_FILE": os.path.join(SCHEMA_DIR, "task.schema.json")})
        self.assertEqual(r.returncode, 0)
        self.assertNotIn("response_format", FakeServer.seen[0][2])
        self.assertNotIn("structured_output", json.loads(r.stdout))
        env = {k: "" for k in os.environ if k.startswith("CONVEYOR_") and "API" in k}
        self.assertEqual(run("api", stdin="x", env=env).returncode, 3)

    def test_unreachable_server_is_exit_3(self):
        r = run("api", stdin="x", env={"CONVEYOR_API_BASE_URL": "http://127.0.0.1:9/v1", "CONVEYOR_API_MODEL": "m",
                                       "CONVEYOR_API_TIMEOUT": "3"})
        self.assertEqual(r.returncode, 3)


if __name__ == "__main__":
    unittest.main(verbosity=1)
