"""Offline checks for the bounty steps. No GitHub writes, no model calls.

  debug-pipeline bounty selfcheck            decisions, test-path rules, classify, PR text
  debug-pipeline bounty selfcheck --docker   also the real path on a local fake repo: dependency image,
                                             the reproduce test failing in Docker, the debug pipeline
                                             fixing it in Docker, ship building the branch, --send refused
                                             without a person at a terminal (nothing is pushed)
"""
import argparse
import json
import shutil
import subprocess
import tempfile
from pathlib import Path

from debug_pipeline import bounty as B

fails = 0


def check(cond, what):
    global fails
    print(f"  {'PASS' if cond else 'FAIL'}  {what}")
    if not cond:
        fails += 1


def facts(**kw):
    f = {"issue": {"title": "parse_duration drops days", "body": "`parse_duration('1d')` returns 0", "state": "open",
                   "labels": [{"name": "💎 Bounty"}]},
         "comments": [{"user": {"login": "algora-pbc[bot]"}, "body": "## 💎 $50 bounty • Example"}],
         "timeline": [], "repo": {"default_branch": "main"}, "languages": {"Python": 1}, "root": ["pyproject.toml"],
         "commits": []}
    for k, v in kw.items():
        if k in ("title", "body", "state"):
            f["issue"][k] = v
        else:
            f[k] = v
    return f


def decisions():
    print("== triage decisions")
    t = B.triage_decide(facts(), "o", "r", 1)
    check(t["verdict"] == "GO" and t["bounty_usd"] == 50 and t["stack"] == "python", "clean bounty issue -> GO, $50, python")
    t = B.triage_decide(facts(state="closed"), "o", "r", 1)
    check(t["verdict"] == "SKIP", "closed issue -> SKIP")
    t = B.triage_decide(facts(commits=[{"sha": "abc1234", "commit": {"message": "Fix days unit, fixes #1"}}]), "o", "r", 1)
    check(t["verdict"] == "SKIP" and any("already mentions" in s for s in t["skip"]), "a commit that fixes #1 -> SKIP (already fixed upstream)")
    merged = {"event": "cross-referenced", "source": {"issue": {"number": 9, "user": {"login": "x"}, "state": "closed",
                                                                "pull_request": {"merged_at": "2026-01-01"}}}}
    t = B.triage_decide(facts(timeline=[merged]), "o", "r", 1)
    check(t["verdict"] == "SKIP", "a merged PR referencing it -> SKIP")
    crowd = [{"event": "cross-referenced", "source": {"issue": {"number": i, "user": {"login": f"u{i}"}, "state": "open",
                                                                "pull_request": {}}}} for i in range(6)]
    t = B.triage_decide(facts(timeline=crowd), "o", "r", 1)
    check(t["verdict"] == "SKIP" and any("crowded" in s for s in t["skip"]), "6 open competing PRs -> SKIP (crowded)")
    t = B.triage_decide(facts(timeline=crowd), "o", "r", 1, force=True)
    check(t["verdict"] == "GO", "--force turns crowded into a note")
    t = B.triage_decide(facts(body="crashes 25% of the time with my SDRplay RSPdx over USB"), "o", "r", 1)
    check(t["verdict"] == "SKIP" and any("hardware" in s for s in t["skip"]), "hardware bug (the Gqrx kind) -> SKIP")
    t = B.triage_decide(facts(comments=[], **{"issue": {"title": "x", "body": "y", "state": "open", "labels": []}}), "o", "r", 1)
    check(t["verdict"] == "SKIP" and any("no bounty" in s for s in t["skip"]), "no bounty -> SKIP")
    # ParaSpell: a "Bug bounty 💰" label and no $ anywhere (paid by severity table) is still a bounty
    t = B.triage_decide(facts(comments=[], **{"issue": {"title": "x", "body": "y", "state": "open",
                                                       "labels": [{"name": "Bug bounty 💰"}]}}), "o", "r", 1)
    check(not any("no bounty" in s for s in t["skip"]) and any("payout table" in w for w in t["warn"]),
          "bounty label without amount -> not skipped, noted")
    t = B.triage_decide(facts(root=["Cargo.toml"]), "o", "r", 1)
    check(t["verdict"] == "SKIP", "unsupported stack (Rust) -> SKIP")


def rules():
    print("== test rules")
    tmp = Path(tempfile.mkdtemp())
    (tmp / "tests").mkdir()
    (tmp / "tests" / "test_old.py").write_text("")
    ok = lambda s, p: (lambda: B.check_test_path(s, p, tmp))

    def raises(fn):
        try:
            fn()
            return False
        except ValueError:
            return True
    check(B.check_test_path("python", "tests/test_issue_1.py", tmp) == "tests/test_issue_1.py", "tests/test_issue_1.py accepted")
    check(raises(ok("python", "../evil/test_x.py")), "path with .. refused")
    check(raises(ok("python", "/etc/test_x.py")), "absolute path refused")
    check(raises(ok("python", "src/helper.py")), "a non-test name refused (the fixer could edit it)")
    check(raises(ok("python", "tests/test_old.py")), "overwriting an existing test refused")
    check(raises(ok("go", "pkg/thing_test.py")), "wrong language refused")
    check(B.check_test_path("go", "pkg/dur_issue_test.go", tmp) == "pkg/dur_issue_test.go", "Go _test.go accepted (now frozen by the pipeline)")
    check(B.check_test_path("node", "tests/issue.test.js", tmp) == "tests/issue.test.js", "node .test.js accepted")
    shutil.rmtree(tmp)
    print("== classify")
    check(B.classify("python", 0, "1 passed")[0] == "PASSES", "exit 0 -> PASSES (doesn't reproduce)")
    check(B.classify("python", 1, "E   AssertionError: assert 0 == 86400\n1 failed")[0] == "GOOD", "assertion failure -> GOOD")
    check(B.classify("python", 2, "ERROR collecting tests/test_x.py")[0] == "BROKEN", "collection error -> BROKEN")
    check(B.classify("python", 5, "no tests ran")[0] == "BROKEN", "no tests ran -> BROKEN")
    check(B.classify("go", 1, "FAIL\tpkg [build failed]")[0] == "BROKEN", "go build failure -> BROKEN")
    check(B.classify("go", 1, "--- FAIL: TestDays")[0] == "GOOD", "go test failure -> GOOD")
    check(B.classify("node", 1, "SyntaxError: Unexpected token")[0] == "BROKEN", "node syntax error -> BROKEN")
    print("== PR text")
    title, body = B.pr_text({"title": "parse_duration drops days", "number": 7},
                            {"test_path": "tests/test_issue_7.py", "why": "1d is 86400s", "head": "a" * 40, "test_cmd": "pytest"},
                            " dur.py | 2 +-\n")
    check(body.rstrip().endswith("/claim #7") and "Fixes #7" in body and "AI assistance" in body,
          "PR body has Fixes #N, the AI disclosure and /claim #N")
    check(B.ticket_for("https://github.com/o/r/issues/1") == B.ticket_for("https://github.com/o/r/issues/1")
          and len(B.ticket_for("x")) == 6, "ticket id is stable and 6 characters")


def model_order():
    """README order: the local Ollama model first, Grok only as the fallback."""
    import os
    from debug_pipeline import workers as W
    print("\n== model order (local first)")
    tags = {"http://a:11434": {"models": [{"name": "qwen2.5vl:7b"}, {"name": "llama3.2:3b"}, {"name": "qwen2.5-coder:7b"}]},
            "http://b:11434": {"models": [{"name": "nomic-embed-text"}, {"name": "phi4"}]}}

    def fetch(url):
        if url not in tags:
            raise OSError("down")
        return tags[url]
    check(B.local_ollama(["http://down:1", "http://a:11434"], fetch) == ("http://a:11434", "qwen2.5-coder:7b"),
          "an Ollama that is down is skipped; a coder model is picked over vision/small ones")
    check(B.local_ollama(["http://b:11434"], fetch) == ("http://b:11434", "phi4"), "no preferred model -> first text model (not an embedder)")
    check(B.local_ollama(["http://down:1"], fetch) is None, "no Ollama answering -> None")
    saved = {k: os.environ.pop(k, None) for k in ("BOUNTY_MODEL", "DEBUG_PIPELINE_ENDPOINT", "DEBUG_PIPELINE_API_KEY")}
    real_tok = W.grok_token
    try:
        W.grok_token = lambda: "x.y.z"
        calls = B.default_model_calls(local=("http://127.0.0.1:11434", "qwen2.5-coder:7b"))
        check([c.label for c in calls] == ["qwen2.5-coder:7b @ 127.0.0.1:11434", "grok-4.7 @ api.x.ai"],
              f"reproduce asks local first, then Grok ({[c.label for c in calls]})")
        calls = B.default_model_calls(local=False)
        check([c.label for c in calls] == ["grok-4.7 @ api.x.ai"], "no local Ollama -> Grok only")
        W.grok_token = lambda: ""
        check([c.label for c in B.default_model_calls(local=("http://h:11434", "m"))] == ["m @ h:11434"],
              "Grok fallback off / no login -> local only")
        try:
            B.default_model_calls(local=False)
            stopped = False
        except B.Stop:
            stopped = True
        check(stopped, "no local and no Grok -> stops with a clear message")
        # an expired subscription token is renewed with `grok models` before it is used
        import base64 as b64
        jwt = lambda exp: "h." + b64.urlsafe_b64encode(json.dumps({"exp": exp}).encode()).decode().rstrip("=") + ".s"
        W.grok_token = real_tok
        files, ran = [jwt(1), jwt(4102444800)], []
        real_file, real_run, real_which = W._grok_file_token, W.subprocess.run, W.shutil.which
        W._grok_file_token = lambda: files[min(len(ran), 1)]
        W.subprocess.run = lambda cmd, **kw: ran.append(cmd)
        W.shutil.which = lambda name: "/bin/" + name
        try:
            tok = W.grok_token()
        finally:
            W._grok_file_token, W.subprocess.run, W.shutil.which = real_file, real_run, real_which
        check(ran == [["grok", "models"]] and tok == files[1], "expired Grok token -> renewed with `grok models`, new token used")
    finally:
        W.grok_token = real_tok
        for k, v in saved.items():
            if v is not None:
                os.environ[k] = v


FAKE_REPO = {
    "pyproject.toml": '[project]\nname = "durlib"\nversion = "0.1"\ndependencies = []\n[build-system]\nrequires = ["setuptools"]\nbuild-backend = "setuptools.build_meta"\n',
    "durlib/__init__.py": "",
    "durlib/dur.py": ('UNITS = {"s": 1, "m": 60, "h": 3600}\n\n\ndef parse_duration(text):\n'
                      '    total = 0\n    num = ""\n    for ch in text:\n        if ch.isdigit():\n            num += ch\n'
                      '        elif ch in UNITS:\n            total += int(num) * UNITS[ch]\n            num = ""\n'
                      '    return total\n'),
    "tests/test_basic.py": "from durlib.dur import parse_duration\n\n\ndef test_hours():\n    assert parse_duration('2h') == 7200\n",
}
FAKE_TEST = ("from durlib.dur import parse_duration\n\n\ndef test_days_unit():\n"
             "    assert parse_duration('1d2h') == 86400 + 7200\n")


def real_path():
    print("== real path (Docker, local fake repo, fake model; nothing leaves this machine)")
    if subprocess.run(["docker", "info"], capture_output=True).returncode != 0:
        check(False, "Docker is not running")
        return
    root = Path(tempfile.mkdtemp(prefix="bounty-selfcheck-"))
    origin = root / "origin"
    for rel, text in FAKE_REPO.items():
        (origin / rel).parent.mkdir(parents=True, exist_ok=True)
        (origin / rel).write_text(text)
    g = lambda *a: subprocess.run(["git", "-C", str(origin), *a], capture_output=True, text=True)
    g("init", "-q", "-b", "main")
    g("add", "-A")
    g("-c", "user.name=t", "-c", "user.email=t@example.invalid", "commit", "-q", "-m", "init")
    work = root / "work"
    work.mkdir()
    t = B.triage_decide(facts(), "fake", "durlib", 1)
    (work / "triage.json").write_text(json.dumps(t))

    def cloner(owner, repo, dest):
        subprocess.run(["git", "clone", "-q", str(origin), str(dest)], check=True)
        return subprocess.run(["git", "-C", str(dest), "rev-parse", "HEAD"], capture_output=True, text=True).stdout.strip()

    replies = iter([
        json.dumps({"path": "tests/test_issue_1.py", "content": "def test_x(:\n", "why": "broken on purpose"}),
        json.dumps({"path": "tests/test_issue_1.py", "content": "def test_x():\n    assert True\n", "why": "passes on purpose"}),
        json.dumps({"path": "tests/test_issue_1.py", "content": FAKE_TEST, "why": "1d2h must be 93600 seconds"}),
    ])
    prompts = []

    def model(system, prompt):
        prompts.append(prompt)
        return next(replies)
    model.label = "scripted"
    args = argparse.Namespace(issue="https://github.com/fake/durlib/issues/1", work=str(work), force=False)
    def dead_local(system, prompt):
        raise ValueError("model request failed")
    dead_local.label = "local (down)"
    rc = B.cmd_reproduce(args, model_call=[dead_local, model], cloner=cloner)
    repro = json.loads((work / "repro.json").read_text())
    verdicts = [x["verdict"] for x in repro.get("tries", [])]
    check(rc == 0 and verdicts == ["BAD REPLY", "BROKEN", "PASSES", "GOOD"]
          and [x["model"] for x in repro["tries"]] == ["local (down)"] + ["scripted"] * 3,
          f"reproduce: local model down -> one try then the fallback; broken and passing tests rejected, real failing test kept ({verdicts})")
    check(len(prompts) == 3 and "DID NOT WORK" in prompts[1] and "DID NOT WORK" in prompts[2], "the model is told why its last test didn't count")
    check((work / "src" / "tests" / "test_issue_1.py").exists() and not (work / "repo" / "tests" / "test_issue_1.py").exists(),
          "the kept test is in src (for the pipeline), the clean clone is untouched")

    def fixer(prompt, view):
        text = view.read_text("durlib/dur.py")
        return {"edits": [{"path": "durlib/dur.py", "old": '"h": 3600}', "new": '"h": 3600, "d": 86400}'}]} if '"d"' not in text else {"files": {"durlib/dur.py": text}}
    fargs = argparse.Namespace(dir=str(work), model="", endpoint="", runner="docker")
    rc = B.cmd_fix(fargs, worker=fixer)
    fix = json.loads((work / "fix.json").read_text())
    check(rc == 0 and fix["result"] == "OK", f"fix: the debug pipeline made the reproduced test pass in Docker ({fix['result']})")

    sargs = argparse.Namespace(dir=str(work), send=False)
    import os
    os.environ.setdefault("GIT_AUTHOR_NAME", "selfcheck")
    os.environ.setdefault("GIT_AUTHOR_EMAIL", "selfcheck@example.invalid")
    os.environ.setdefault("GIT_COMMITTER_NAME", "selfcheck")
    os.environ.setdefault("GIT_COMMITTER_EMAIL", "selfcheck@example.invalid")
    rc = B.cmd_ship(sargs)
    show = subprocess.run(["git", "-C", str(work / "repo"), "show", "--stat", "--format=%s"], capture_output=True, text=True).stdout
    pr = (work / "pr.md").read_text()
    check(rc == 0 and "durlib/dur.py" in show and "tests/test_issue_1.py" in show, "ship: one local commit with the fix and the new test")
    check("/claim #1" in pr, "ship: pr.md ends with /claim #1")
    calls = []
    sargs = argparse.Namespace(dir=str(work), send=True)
    try:
        B.cmd_ship(sargs, runner=lambda *a, **k: calls.append(a))
        refused = False
    except B.Stop as err:
        refused = "TTY" in str(err)
    check(refused and not calls, "--send without a person at a terminal is refused; gh/git push never called")
    rc = B.cmd_ship(sargs, runner=lambda *a, **k: calls.append(a), confirm=lambda what: "999")
    check(rc == 2 and not calls, "--send with the wrong issue number typed -> cancelled, nothing called")
    from debug_pipeline.receipt import verify
    ok, msg = verify(str(work / "bounty-receipt.jsonl"))
    check(ok, f"bounty receipt chain: {msg}")
    subprocess.run(["docker", "image", "rm", "-f", repro["image"]], capture_output=True)
    shutil.rmtree(root, ignore_errors=True)


def main(argv):
    p = argparse.ArgumentParser(prog="debug-pipeline bounty selfcheck")
    p.add_argument("--docker", action="store_true")
    a = p.parse_args(argv)
    decisions()
    rules()
    model_order()
    if a.docker:
        real_path()
    print(f"\n{'ALL PASSED' if not fails else f'{fails} FAILED'}")
    return 0 if not fails else 1
