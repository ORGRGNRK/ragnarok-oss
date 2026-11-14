"""Proofs that need no model and no network. Each one prints one line."""
import contextlib
import hashlib
import io
import json
import os
import subprocess
import sys
import tarfile
import tempfile
from pathlib import Path

from debug_pipeline.docker_plan import assert_safe, plan_create, plan_disconnect
from debug_pipeline.pipeline import Fence, check_git_url, repo_root, run, valid_ticket
from debug_pipeline.prompt import POINTER, PROMPT_MAX, build_prompt, failure_excerpt
from debug_pipeline.receipt import ReceiptLog, verify
from debug_pipeline.workers import sample_worker

PLANTED = "sk-test-FAKEKEY0123456789abcd"
LEAK = "sk-test-LEAKEDKEY0123456789"
TICKET = "AB23CD"
TEST = "python3 test_calc.py"
RECORDED_OUTSIDE = "ops/alexus/setup-ai-users-alexus.sh"
RECORDED_OUTSIDE_SHA256 = "76603ea35cf11063daf804429274586c6ac28022e77661653418e95740393ff3"


def fail(msg):
    print(msg, file=sys.stderr)
    return 1


class _WriteTracker:
    """Records filesystem writes and flags any path outside the allowed roots."""

    def __init__(self, roots):
        self.roots = [Path(root).resolve() for root in roots]
        self.seen = []
        self.bad = []

    def note(self, path):
        if path is None or isinstance(path, int):
            return
        text = os.fsdecode(path)
        if not text or text.startswith("<") or text == "/dev/null":
            return
        candidate = Path(text)
        if not candidate.is_absolute():
            candidate = Path.cwd() / candidate
        try:
            resolved = candidate.resolve()
        except OSError:
            resolved = candidate
        key = str(resolved)
        if key in self.seen:
            return
        self.seen.append(key)
        if any(resolved == root or root in resolved.parents for root in self.roots):
            return
        self.bad.append(key)


@contextlib.contextmanager
def track_writes(roots):
    tracker = _WriteTracker(roots)
    originals = {
        "open": os.open,
        "mkdir": os.mkdir,
        "makedirs": os.makedirs,
        "rename": os.rename,
        "replace": os.replace,
    }
    write_flags = os.O_WRONLY | os.O_RDWR | os.O_APPEND | os.O_CREAT

    def wrapped_open(path, flags, mode=0o777, *, dir_fd=None):
        if isinstance(flags, int) and flags & write_flags:
            tracker.note(path)
        return originals["open"](path, flags, mode, dir_fd=dir_fd)

    def wrapped_mkdir(path, mode=0o777, *, dir_fd=None):
        tracker.note(path)
        return originals["mkdir"](path, mode, dir_fd=dir_fd)

    def wrapped_makedirs(name, mode=0o777, exist_ok=False):
        tracker.note(name)
        return originals["makedirs"](name, mode, exist_ok=exist_ok)

    def wrapped_rename(src, dst, *, src_dir_fd=None, dst_dir_fd=None):
        tracker.note(dst)
        return originals["rename"](src, dst, src_dir_fd=src_dir_fd, dst_dir_fd=dst_dir_fd)

    def wrapped_replace(src, dst, *, src_dir_fd=None, dst_dir_fd=None):
        tracker.note(dst)
        return originals["replace"](src, dst, src_dir_fd=src_dir_fd, dst_dir_fd=dst_dir_fd)

    os.open = wrapped_open
    os.mkdir = wrapped_mkdir
    os.makedirs = wrapped_makedirs
    os.rename = wrapped_rename
    os.replace = wrapped_replace
    try:
        yield tracker
    finally:
        os.open = originals["open"]
        os.mkdir = originals["mkdir"]
        os.makedirs = originals["makedirs"]
        os.rename = originals["rename"]
        os.replace = originals["replace"]


def _under_roots(path, roots):
    resolved = Path(path).resolve()
    return any(resolved == root or root in resolved.parents for root in roots)


def sample_dir():
    return repo_root() / "runner" / "debug-pipeline" / "samples" / "broken_calc"


def fresh():
    root = Path(tempfile.mkdtemp(prefix="debug-pipeline-prove-"))
    out = root / "out"
    store = root / "store"
    store.mkdir()
    (store / f"intake:1700000000000:{TICKET}.json").write_text(
        '{"ticket":"AB23CD","problem":"add is wrong"}\n', encoding="utf-8"
    )
    return out, store


def go(worker, rounds=4, keep_secrets=False):
    out, store = fresh()
    result = run(
        TICKET, sample_dir(), TEST, out, store,
        runner_name="fake", worker=worker, rounds=rounds, keep_secrets=keep_secrets,
    )
    return result


def archive_parts(path):
    parts = {}
    with tarfile.open(path) as tar:
        for name in tar.getnames():
            data = tar.extractfile(name).read()
            parts[name] = data
    return parts


def text_blob(parts):
    chunks = []
    for name, data in parts.items():
        if name == "filesystem.tar":
            continue
        chunks.append(data.decode("utf-8", "replace"))
    return "\n".join(chunks)


def prove_baseline():
    result = go(sample_worker)
    if result["result"] != "OK":
        return fail("baseline run did not finish: " + result["receipt"].read_text(encoding="utf-8")[-500:])
    for line in result["receipt"].read_text(encoding="utf-8").splitlines():
        rec = json.loads(line)
        if rec["cmd"].startswith("baseline test:") and rec["status"] == "FAILED" and "exit 0" not in rec["cmd"]:
            print("baseline FAILED")
            return 0
    return fail("baseline failure was not recorded")


def prove_fix():
    result = go(sample_worker)
    if result["result"] != "OK" or result["runner"] != "fake":
        return fail("fix did not pass in the fake runner")
    parts = archive_parts(result["archive"])
    if b"return a + b" not in parts["filesystem.tar"]:
        return fail("fixed code is not in the filesystem tarball")
    saw = False
    for line in result["receipt"].read_text(encoding="utf-8").splitlines():
        rec = json.loads(line)
        if rec["cmd"].startswith("retest:") and rec["status"] == "OK" and "exit 0" in rec["cmd"]:
            saw = True
    if not saw:
        return fail("passing retest was not recorded")
    print("fake runner fixed the sample")
    return 0


def prove_tamper():
    out, _store = fresh()
    log = ReceiptLog(out / "receipt.jsonl", "debug-pipeline@selfcheck")
    log.append("Action", "OK", "/work", "one")
    log.append("Action", "OK", "/work", "two")
    log.append("Action", "OK", "/work", "three")
    ok, msg = verify(log.path)
    if not ok:
        return fail(msg)
    lines = log.path.read_text(encoding="utf-8").splitlines()
    rec = json.loads(lines[1])
    rec["cmd"] = rec["cmd"] + "X"
    lines[1] = json.dumps(rec, ensure_ascii=False, separators=(",", ":"))
    log.path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    _ok, msg = verify(log.path)
    if "line 2 (seq 2): contents changed" not in msg:
        return fail(msg)
    print(msg)
    return 0


def prove_archive():
    result = go(sample_worker)
    if result["archive"] is None:
        return fail("no archive")
    parts = archive_parts(result["archive"])
    needed = {"filesystem.tar", "receipt.jsonl", "diff.patch", "head.hash", "report.txt"}
    if not needed <= set(parts):
        return fail("archive members: " + ", ".join(sorted(parts)))
    receipt = parts["receipt.jsonl"].decode("utf-8")
    diff = parts["diff.patch"].decode("utf-8")
    head = parts["head.hash"].decode("utf-8").strip()
    last = json.loads(receipt.strip().splitlines()[-1])
    if last["hash"] != head:
        return fail("head hash does not match the last receipt line")
    if "return a - b" not in diff or "return a + b" not in diff:
        return fail("diff does not show the change")
    side = Path(str(result["archive"]) + ".sha256").read_text(encoding="utf-8").split()[0]
    digest = __import__("hashlib").sha256(result["archive"].read_bytes()).hexdigest()
    if side != digest or result["sha256"] != digest:
        return fail("archive hash does not match")
    copy = result["archive"].with_name("packed-receipt.jsonl")
    copy.write_text(receipt, encoding="utf-8")
    ok, msg = verify(copy)
    if not ok:
        return fail(msg)
    print("archive hash matches")
    return 0


def prove_ticket():
    result = go(sample_worker)
    if result["ticket_record"] is None:
        return fail("no ticket record")
    rec = json.loads(Path(result["ticket_record"]).read_text(encoding="utf-8"))
    if rec.get("ticket") != TICKET or rec.get("result") != "OK":
        return fail("ticket record result is wrong")
    if rec.get("sha256") != result["sha256"] or rec.get("head_hash") != result["head_hash"]:
        return fail("ticket record hash does not match the archive")
    if Path(rec["archive"]).resolve() != Path(result["archive"]).resolve():
        return fail("ticket record does not point at the archive")
    print("ticket points at archive")
    return 0


def prove_fence():
    if not valid_ticket(TICKET):
        return fail("sample ticket is not a real ticket number")
    root = Path(tempfile.mkdtemp(prefix="debug-pipeline-fence-"))
    fence = Fence([root])
    try:
        fence.allow("/etc/passwd")
        return fail("fence allowed a write outside the run folder")
    except PermissionError:
        pass
    out, store = fresh()
    before = set(Path("/private/tmp").glob("debug-pipeline-work-*"))
    try:
        with track_writes([out, store]) as tracker:
            result = run(
                TICKET, sample_dir(), TEST, out, store,
                runner_name="fake", worker=sample_worker,
            )
        if result["result"] != "OK":
            return fail("fence sample run failed")
        if tracker.bad:
            return fail("wrote outside the archive and store folders: " + ", ".join(tracker.bad[:8]))
        allowed = [out.resolve(), store.resolve()]
        work_hits = [path for path in tracker.seen if "debug-pipeline-work-" in path]
        if not work_hits:
            return fail("temporary work was not recorded")
        for path in work_hits:
            if not _under_roots(path, allowed):
                return fail("temporary work escaped the archive folder: " + path)
        leaked = set(Path("/private/tmp").glob("debug-pipeline-work-*")) - before
        if leaked:
            return fail("temporary work was created outside the archive folder")
    finally:
        from debug_pipeline.pipeline import _force_rmtree
        _force_rmtree(out.parent)
    outside = repo_root() / RECORDED_OUTSIDE
    current = hashlib.sha256(outside.read_bytes()).hexdigest()
    if current != RECORDED_OUTSIDE_SHA256:
        return fail("outside file differs from the recorded start: " + RECORDED_OUTSIDE)
    done = subprocess.run(
        ["git", "status", "--porcelain", "-uall"],
        cwd=repo_root(), capture_output=True, text=True,
    )
    if done.returncode != 0:
        return fail(done.stderr.strip() or "git status failed")
    bad = []
    for line in done.stdout.splitlines():
        path = line[3:].strip().strip('"')
        if " -> " in path:
            path = path.split(" -> ", 1)[1].strip()
        if path.startswith("runner/debug-pipeline/"):
            continue
        # Already compared to the recorded start. A byte change failed above.
        if path == RECORDED_OUTSIDE:
            continue
        bad.append(path)
    if bad:
        return fail("wrote outside the pipeline folder: " + ", ".join(bad))
    print("fence holds")
    return 0


def prove_readonly():
    out, _store = fresh()
    parent = Path(tempfile.mkdtemp(prefix="debug-pipeline-ro-"))
    fence = Fence([out, parent])
    from debug_pipeline.pipeline import FakeRunner
    runner = FakeRunner(parent / "work", fence)
    log = ReceiptLog(out / "receipt.jsonl", "debug-pipeline@selfcheck", fence)
    log.append("Action", "OK", "/work", "readonly probe")
    runner.refresh_receipt(log.path)
    mode = runner.receipt_copy.stat().st_mode
    if mode & 0o222:
        return fail("receipt copy is writable")
    try:
        with open(runner.receipt_copy, "a", encoding="utf-8") as handle:
            handle.write("TAMPER\n")
        return fail("write to the worker log succeeded")
    except OSError:
        pass
    try:
        with open(runner.receipt_copy.parent / "evil", "w", encoding="utf-8") as handle:
            handle.write("x")
        return fail("worker could create a file next to the log")
    except OSError:
        pass

    class Hostile:
        def __init__(self):
            self.write_failed = False

        def __call__(self, prompt, view):
            try:
                with open(view.receipt_copy, "a", encoding="utf-8") as handle:
                    handle.write("TAMPER\n")
            except OSError:
                self.write_failed = True
            text = view.read_text("calc.py")
            if "return a - b" not in text:
                return {"files": {"calc.py": text}}
            return {"edits": [{"path": "calc.py", "old": "return a - b", "new": "return a + b"}]}

    runner.destroy()
    hostile = Hostile()
    result = go(hostile)
    if not hostile.write_failed:
        return fail("worker write was not rejected")
    if "TAMPER" in result["receipt"].read_text(encoding="utf-8"):
        return fail("tamper landed in the host receipt")
    if result["result"] != "OK":
        return fail("readonly run did not finish")
    print("worker log is read-only")
    return 0


def prove_prompt():
    huge = "X" * 100000
    one = build_prompt(TEST, 2, [{"round": 1, "what": huge, "where": huge}])
    if len(one.encode("utf-8")) > PROMPT_MAX or ("X" * 1000) in one:
        return fail("one long attempt bloated the prompt")
    if POINTER not in one or "- round 1:" not in one:
        return fail("round 2 prompt is missing the pointer or the attempt line")
    many = [{"round": i, "what": huge, "where": huge} for i in range(1, 40)]
    wide = build_prompt(TEST, 2, many)
    if len(wide.encode("utf-8")) > PROMPT_MAX or ("X" * 1000) in wide:
        return fail("many long attempts bloated the prompt")

    class Steps:
        def __init__(self):
            self.n = 0

        def __call__(self, prompt, view):
            self.n += 1
            view.read_text("calc.py")
            if self.n == 1:
                return {"edits": [{"path": "calc.py", "old": "return a - b", "new": "return b - a"}]}
            return {"edits": [{"path": "calc.py", "old": "return b - a", "new": "return a + b"}]}

    result = go(Steps(), rounds=4)
    if len(result["prompts"]) < 2:
        return fail("the loop did not reach round 2")
    second = result["prompts"][1]
    if POINTER not in second or "- round 1:" not in second:
        return fail("live round 2 prompt is missing the pointer or the summary")
    if len(second.encode("utf-8")) > PROMPT_MAX or "receipt.jsonl" not in second:
        return fail("live round 2 prompt is the wrong size")
    if result["receipt"].read_text(encoding="utf-8") in second:
        return fail("the whole receipt was pasted into the prompt")
    print("prompt bounded")
    return 0


def prove_repeat():
    def same(prompt, view):
        view.read_text("calc.py")
        return {"edits": [{"path": "calc.py", "old": "return a - b", "new": "return b - a"}]}

    result = go(same, rounds=2)
    text = result["receipt"].read_text(encoding="utf-8")
    if "repeat: identical change already tried" not in text:
        return fail("repeat was not recorded")
    if result["worker_calls"] < 2:
        return fail("the second attempt did not run")
    print("repeat recorded")
    return 0


def prove_docker_plan():
    args = plan_create("dbg-ab23cd", "python:3.12-slim", "/tmp/debug-pipeline-receipt.jsonl", False)
    assert_safe(args)
    if args[args.index("--network") + 1] != "none":
        return fail("default network is not off")
    if "docker.sock" in " ".join(args) or "--privileged" in args:
        return fail("docker plan is too open")
    mount = args[args.index("--mount") + 1]
    if "target=/receipt/receipt.jsonl,readonly" not in mount:
        return fail("receipt is not a read-only mount")
    home = os.path.expanduser("~")
    bad = plan_create("dbg-ab23cd", "python:3.12-slim", home, False)
    try:
        assert_safe(bad)
        return fail("a home mount was accepted")
    except ValueError:
        pass
    off = plan_disconnect("dbg-ab23cd")
    if off[:3] != ["docker", "network", "disconnect"]:
        return fail("network is not disconnected after pull")
    for bad_url in ("git@github.com:org/repo.git", "file:///tmp/x", "https://user:secret@example.com/repo.git"):
        try:
            check_git_url(bad_url)
            return fail("bad git url accepted: " + bad_url)
        except ValueError:
            pass
    print("docker plan ok")
    return 0


def _shown(result):
    return "\n".join(result["prompts"]) + "\n" + "\n".join(result["shown"])


def prove_scrub():
    raw = (sample_dir() / "calc.py").read_text(encoding="utf-8")
    if PLANTED not in raw:
        return fail("the sample no longer contains the planted key")
    result = go(sample_worker)
    if result["result"] != "OK":
        return fail("scrub run did not finish")
    shown = _shown(result)
    parts = archive_parts(result["archive"])
    blob = shown + "\n" + result["receipt"].read_text(encoding="utf-8") + "\n" + text_blob(parts)
    if PLANTED in blob or "FAKEKEY" in blob:
        return fail("planted key leaked into the prompt, log, or archive text")
    if PLANTED in parts["filesystem.tar"].decode("utf-8", "replace") or b"FAKEKEY" in parts["filesystem.tar"]:
        return fail("planted key leaked into the container filesystem")
    if "[REDACTED]" not in shown:
        return fail("worker was not shown the scrubbed file")
    print("planted key absent")
    return 0


def prove_scrub_count():
    result = go(sample_worker)
    text = result["receipt"].read_text(encoding="utf-8")
    if "scrubbed 1 secret value" not in text:
        return fail("scrub count was not logged: " + text)
    if PLANTED in text or "FAKEKEY" in text:
        return fail("the scrub log contains the value")
    print("scrubbed 1 secret value")
    return 0


def prove_survivor():
    def leak(prompt, view):
        view.read_text("calc.py")
        return {"edits": [{
            "path": "calc.py",
            "old": "return a - b",
            "new": "return a + b  # " + LEAK,
        }]}

    result = go(leak, rounds=4)
    text = result["receipt"].read_text(encoding="utf-8")
    if result["result"] != "FAILED":
        return fail("survivor run did not stop as FAILED")
    if "secret shape survived; run stopped" not in text:
        return fail("stop was not recorded")
    if LEAK in text or "LEAKEDKEY" in text:
        return fail("the leaked key was written to the receipt")
    if result["worker_calls"] != 1:
        return fail("the run kept going after the leaked key")
    if result["archive"] is not None:
        blob = text_blob(archive_parts(result["archive"]))
        if LEAK in blob or "LEAKEDKEY" in blob:
            return fail("the leaked key was packed into the archive")
    print("secret shape survived; run stopped")
    return 0


def prove_keep_secrets():
    raw = (sample_dir() / "calc.py").read_text(encoding="utf-8")
    if PLANTED not in raw:
        return fail("the sample no longer contains the planted key")
    result = go(sample_worker, keep_secrets=True)
    text = result["receipt"].read_text(encoding="utf-8")
    phrase = "secrets left in the container because the test needs them"
    if phrase not in text:
        return fail("the run did not say the real values stayed in the container")
    if result["result"] != "OK":
        return fail("keep-secrets run did not finish")
    shown = _shown(result)
    parts = archive_parts(result["archive"])
    blob = shown + "\n" + text_blob(parts)
    if PLANTED in blob or "FAKEKEY" in blob:
        return fail("keep-secrets still showed the key to the worker or the archive text")
    if b"FAKEKEY" not in parts["filesystem.tar"]:
        return fail("the container copy did not keep the real value")
    if result.get("preview_secret_hits") != 0:
        return fail("raw values were written to the host preview")
    print(phrase)
    return 0


def _archive_call_kinds(calls):
    kinds = []
    for call in calls:
        blob = " ".join(str(part) for part in call)
        if call[:2] == ["docker", "stop"]:
            kinds.append("stop")
        elif call[:2] == ["docker", "export"]:
            kinds.append("export")
        elif "kill" in blob and "-STOP" in blob:
            kinds.append("freeze")
        elif "tar" in call and "-cf" in call:
            kinds.append("tmpfs")
    return kinds


def _tar(files):
    buffer = io.BytesIO()
    with tarfile.open(fileobj=buffer, mode="w") as tar:
        for name, data in files.items():
            info = tarfile.TarInfo(name)
            info.size = len(data)
            tar.addfile(info, io.BytesIO(data))
    return buffer.getvalue()


class _Done:
    def __init__(self, code=0, out=b""):
        self.returncode = code
        self.stdout = out
        self.stderr = b""


def prove_container_repair():
    from debug_pipeline.pipeline import (
        DockerBox, FakeRunner, Fence, _force_rmtree, load_controller, load_redactor,
    )
    from debug_pipeline.scrub import scrub_bytes

    parent = Path("/private/tmp") / "debug-pipeline-repair-prove"
    _force_rmtree(parent)
    parent.mkdir()
    try:
        outside = hashlib.sha256((repo_root() / RECORDED_OUTSIDE).read_bytes()).hexdigest()
        if outside != RECORDED_OUTSIDE_SHA256:
            return fail("outside file differs from the recorded start")
        fence = Fence([parent])
        redact = load_redactor(repo_root())
        controller = load_controller(repo_root())
        runner = FakeRunner(parent / "work", fence)
        runner.pull_local(sample_dir(), redact, True)
        preview = (runner.work / "calc.py").read_bytes()
        inside = (runner.container_root / "calc.py").read_bytes()
        if b"FAKEKEY" in preview or b"return a - b" not in preview:
            return fail("host preview was not the scrubbed file")
        if b"FAKEKEY" not in inside or b"return a - b" not in inside:
            return fail("container copy did not keep the raw value")
        proposal = {"edits": [{"path": "calc.py", "old": "return a - b", "new": "return a + b"}]}
        runner.apply_change(controller, proposal, ["calc.py"], redact)
        inside = (runner.container_root / "calc.py").read_bytes()
        preview = (runner.work / "calc.py").read_bytes()
        if b"return a + b" not in inside or b"FAKEKEY" not in inside:
            return fail("the repair did not land inside the container copy")
        if b"FAKEKEY" in preview or b"return a + b" not in preview:
            return fail("the host preview received raw values or missed the scrubbed fix")
        if runner.preview_secret_hits(redact) != 0:
            return fail("scrubbed preview still matches a secret shape")
        code, _out = runner.run_test(TEST)
        if code != 0:
            return fail("the test did not run against the container copy")
        if list(parent.glob("stage-*")):
            return fail("a validation stage was left on disk")

        mirror = FakeRunner(parent / "docker-preview" / "work", fence)
        cleaned, _found, _text = scrub_bytes(redact, (sample_dir() / "calc.py").read_bytes())
        mirror.store_scrubbed("calc.py", cleaned)
        box = DockerBox(
            mirror, "dbg-ab23cd-prove", "python:3.12-slim",
            "/private/tmp/debug-pipeline-receipt.jsonl", False,
        )
        state = {"calc.py": (sample_dir() / "calc.py").read_bytes()}
        calls = []

        def fake_run(args, timeout=120, check=True, input_bytes=None):
            calls.append(list(args))
            if "python3" in args and input_bytes:
                req = json.loads(input_bytes)
                text = state[req["path"]].decode("utf-8")
                if req["op"] == "edit":
                    if text.count(req["old"]) != 1:
                        return _Done(2)
                    state[req["path"]] = text.replace(req["old"], req["new"], 1).encode("utf-8")
                else:
                    state[req["path"]] = req["text"].encode("utf-8")
                return _Done(0)
            if "tar" in args and "-cf" in args and "-C" in args:
                root = args[args.index("-C") + 1]
                if root == "/":
                    blob = _tar({
                        "work/calc.py": state["calc.py"],
                        "tmp/state.bin": b"TMPFS-MARKER",
                    })
                else:
                    blob = _tar({"calc.py": state["calc.py"]})
                return _Done(0, blob)
            if args[:2] == ["docker", "export"]:
                return _Done(0, _tar({"usr/lib/installed-dep.txt": b"INSTALLED-DEP"}))
            return _Done(0)

        box._run = fake_run
        box.apply_change(controller, proposal, ["calc.py"], redact)
        if b"FAKEKEY" not in state["calc.py"] or b"return a + b" not in state["calc.py"]:
            return fail("docker apply did not change the container file")
        if b"FAKEKEY" in (mirror.work / "calc.py").read_bytes():
            return fail("docker apply wrote the raw value to the host preview")
        host_raw = b""
        for path in mirror.container_root.rglob("*"):
            if path.is_file():
                host_raw += path.read_bytes()
        if b"FAKEKEY" in host_raw:
            return fail("docker kept raw values on the host")
        if any("find" in call or "-delete" in call for call in calls):
            return fail("apply wiped the container before writing")
        calls.clear()
        dest = parent / "filesystem.tar"
        box.export_filesystem(dest)
        if any("find" in call or "-delete" in call for call in calls):
            return fail("archive wiped /work before saving it")
        kinds = _archive_call_kinds(calls)
        if kinds != ["freeze", "tmpfs", "stop", "export"]:
            return fail("archive did not freeze, stop, and save the container: " + ",".join(kinds))
        saved = dest.read_bytes()
        if b"INSTALLED-DEP" not in saved or b"TMPFS-MARKER" not in saved or b"return a + b" not in saved:
            return fail("archive dropped container state or tmpfs contents")
        if b"FAKEKEY" not in saved:
            return fail("archive dropped the value that stayed in the container")
        print("repair stayed inside the container")
        return 0
    finally:
        _force_rmtree(parent)


def prove_frozen_guard():
    """The three holes the critic found: a mutable check, a dropped mode, a live capture."""
    from debug_pipeline.docker_plan import plan_create
    from debug_pipeline.pipeline import (
        DockerBox, FakeRunner, Fence, _files_from_tar, _force_rmtree, _tar_from_files,
        apply_one, build_frozen_validator, is_validator_path, load_controller, load_redactor,
        split_source_items,
    )

    if not is_validator_path("check.py") or not is_validator_path("package.json"):
        return fail("check.py or package.json is still outside the frozen set")
    parent = Path("/private/tmp") / "debug-pipeline-frozen-prove"
    _force_rmtree(parent)
    parent.mkdir()
    try:
        redact = load_redactor(repo_root())
        controller = load_controller(repo_root())
        blob = _tar_from_files({"run.sh": (b"#!/bin/sh\nexit 1\n", 0o755)})
        items = _files_from_tar(blob)
        if len(items) != 1 or items[0][0] != "run.sh" or (items[0][2] & 0o777) != 0o755:
            return fail("pull tar dropped the executable bit")
        _files, _count, _scrubbed, _preview, payload = split_source_items(items, redact, False)
        again = _files_from_tar(_tar_from_files(payload))
        if len(again) != 1 or (again[0][2] & 0o777) != 0o755:
            return fail("pull payload dropped the executable bit")

        src = parent / "src"
        src.mkdir()
        (src / "calc.py").write_text("def add(a, b):\n    return a - b\n", encoding="utf-8")
        (src / "check.py").write_text(
            "import calc\nraise SystemExit(0 if calc.add(2, 2) == 4 else 1)\n",
            encoding="utf-8",
        )
        (src / "package.json").write_text(
            '{"scripts": {"test": "python3 check.py"}}\n',
            encoding="utf-8",
        )
        script = src / "run.sh"
        script.write_text("#!/bin/sh\nexit 1\n", encoding="utf-8")
        script.chmod(0o755)
        if (script.stat().st_mode & 0o777) != 0o755:
            return fail("could not create an executable run.sh")

        fence = Fence([parent])
        runner = FakeRunner(parent / "one" / "work", fence)
        runner.pull_local(src, redact, False)
        landed = (runner.container_root / "run.sh").stat().st_mode & 0o777
        if landed != 0o755:
            return fail(f"run.sh landed as {landed:04o}")
        calc_src = (src / "calc.py").stat().st_mode & 0o777
        calc_got = (runner.container_root / "calc.py").stat().st_mode & 0o777
        if calc_got != calc_src:
            return fail(f"calc.py mode changed from {calc_src:04o} to {calc_got:04o}")

        stage = parent / "stage"
        stage.mkdir()
        (stage / "calc.py").write_text("def add(a, b):\n    return a - b\n", encoding="utf-8")
        apply_one(
            controller,
            {"edits": [{"path": "calc.py", "old": "return a - b", "new": "return a + b"}]},
            stage,
            ["calc.py", "check.py", "package.json"],
        )
        if "return a + b" not in (stage / "calc.py").read_text(encoding="utf-8"):
            return fail("a product file could not be edited")
        for name in ("check.py", "package.json"):
            try:
                apply_one(
                    controller,
                    {"files": {name: "raise SystemExit(0)\n"}},
                    stage,
                    ["check.py", "package.json", "calc.py"],
                )
            except ValueError as err:
                if "path rejected" not in str(err):
                    return fail(str(err))
            else:
                return fail(name + " stayed editable")

        runner.freeze_validator("npm test")
        outside = runner.validator_root
        if outside == runner.container_root or runner.container_root in outside.parents:
            return fail("validator sits inside the writable tree")
        entry = (outside / "run-frozen.sh").read_text(encoding="utf-8")
        frozen_check = str(outside / "check.py")
        if frozen_check not in entry or "npm" in entry:
            return fail("npm test still runs the mutable package.json")
        if "python3 check.py" in entry:
            return fail("the check still uses a relative path inside the customer tree")
        (runner.container_root / "check.py").write_text("raise SystemExit(0)\n", encoding="utf-8")
        (runner.container_root / "package.json").write_text(
            '{"scripts": {"test": "exit 0"}}\n',
            encoding="utf-8",
        )
        code, _out = runner.run_test("npm test")
        if code == 0:
            return fail("editing the in-tree check changed the verdict")
        if str(runner.container_root) in runner.frozen_cmd:
            return fail("the accepted command runs inside the customer tree")
        real = (outside / "check.py").read_text(encoding="utf-8")
        if "calc.add" not in real:
            return fail("the frozen check was replaced")
        try:
            runner.apply_change(
                controller,
                {"files": {"package.json": '{"scripts": {"test": "exit 0"}}\n'}},
                ["package.json", "calc.py"],
                redact,
            )
        except ValueError as err:
            if "path rejected" not in str(err):
                return fail(str(err))
        else:
            return fail("package.json was applied inside the customer tree")

        other = FakeRunner(parent / "two" / "work", fence)
        other.pull_local(src, redact, False)
        other.freeze_validator("sh run.sh")
        frozen_script = other.validator_root / "run.sh"
        frozen_mode = frozen_script.stat().st_mode & 0o777
        if not (frozen_mode & 0o111) or (frozen_mode & 0o222):
            return fail(f"frozen run.sh mode is {frozen_mode:04o}")
        if str(frozen_script) not in (other.validator_root / "run-frozen.sh").read_text(encoding="utf-8"):
            return fail("the executable test script was not the frozen command")
        try:
            other.apply_change(
                controller,
                {"files": {"run.sh": "#!/bin/sh\nexit 0\n"}},
                ["run.sh", "calc.py"],
                redact,
            )
        except ValueError as err:
            if "path rejected" not in str(err):
                return fail(str(err))
        else:
            return fail("the test script named by the command stayed editable")

        args = plan_create("dbg-ab23cd", "python:3.12-slim", "/tmp/debug-pipeline-receipt.jsonl", False)
        from debug_pipeline.docker_plan import assert_safe
        assert_safe(args)
        joined = " ".join(args)
        if "--tmpfs /validator:rw,exec,nosuid,size=32m,uid=0,gid=0,mode=755" not in joined:
            return fail("validator is not a root-owned tmpfs")
        if joined.count("--mount") != 1:
            return fail("validator freeze added a host mount")

        mirror = FakeRunner(parent / "docker-preview" / "work", fence)
        box = DockerBox(
            mirror, "dbg-ab23cd-prove", "python:3.12-slim",
            "/private/tmp/debug-pipeline-receipt.jsonl", False,
        )
        calls = []

        def fake_run(args, timeout=120, check=True, input_bytes=None):
            calls.append(list(args))
            if "tar" in args and "-cf" in args and "-C" in args:
                return _Done(0, _tar({"work/marker.txt": b"MARKER", "tmp/marker.txt": b"TMP"}))
            if args[:2] == ["docker", "export"]:
                return _Done(0, _tar({"usr/lib/installed-dep.txt": b"DEP"}))
            return _Done(0)

        box._run = fake_run
        box.export_filesystem(parent / "filesystem.tar")
        kinds = _archive_call_kinds(calls)
        if kinds != ["freeze", "tmpfs", "stop", "export"]:
            return fail("archive captured a writable tree: " + ",".join(kinds))

        def cheat(prompt, view):
            return {"files": {"check.py": "raise SystemExit(0)\n"}}

        out, store = fresh()
        try:
            cheated = run(
                TICKET, src, "python3 check.py", out, store,
                runner_name="fake", worker=cheat, rounds=1,
            )
            cheated_text = cheated["receipt"].read_text(encoding="utf-8")
        finally:
            _force_rmtree(out.parent)
        if cheated["result"] == "OK":
            return fail("a rewritten check.py was accepted")
        if "path rejected" not in cheated_text:
            return fail("the mutable check was not rejected: " + cheated_text[-400:])

        def fix(prompt, view):
            return {"edits": [{"path": "calc.py", "old": "return a - b", "new": "return a + b"}]}

        out, store = fresh()
        try:
            fixed = run(
                TICKET, src, "python3 check.py", out, store,
                runner_name="fake", worker=fix, rounds=1,
            )
            fixed_text = fixed["receipt"].read_text(encoding="utf-8")
        finally:
            _force_rmtree(out.parent)
        if fixed["result"] != "OK":
            return fail("the frozen check did not see the product fix: " + fixed_text[-400:])
        if "validator frozen outside the customer tree" not in fixed_text:
            return fail("the receipt does not record the frozen check")
        # build_frozen_validator is part of the docker pull path too. A mode
        # that survives split_source_items must still be executable there.
        _locked, built = build_frozen_validator(
            {"run.sh": (b"#!/bin/sh\nexit 1\n", 0o755), "check.py": (b"raise SystemExit(1)\n", 0o644)},
            "sh run.sh",
            "/work",
            "/validator",
        )
        if (built["run.sh"][1] & 0o111) == 0 or (built["run.sh"][1] & 0o222):
            return fail("docker validator copy dropped the executable bit")
        print("validator frozen outside the customer tree")
        return 0
    finally:
        _force_rmtree(parent)


def prove_command_fence():
    """Shell operators stay operators, package entry files are frozen, work stays in out."""
    from debug_pipeline.pipeline import (
        FakeRunner, Fence, _force_rmtree, apply_one, build_frozen_validator,
        load_controller, load_redactor,
    )

    try:
        build_frozen_validator(
            {"test_calc.py": (b"raise SystemExit(0)\n", 0o644)},
            "python3 test_calc.py $(echo hi)",
            "/work",
            "/validator",
        )
    except ValueError as err:
        if "not supported" not in str(err):
            return fail(str(err))
    else:
        return fail("command substitution was accepted")

    locked, payload = build_frozen_validator(
        {"test_calc.py": (b"raise SystemExit(0)\n", 0o644)},
        "python3 test_calc.py && echo done",
        "/work",
        "/validator",
    )
    entry = payload["run-frozen.sh"][0].decode("utf-8")
    if "'&&'" in entry or '"&&"' in entry or "&&" not in entry:
        return fail("shell operator was quoted or dropped: " + entry)
    if "/validator/test_calc.py" not in entry:
        return fail("the test file was not frozen")
    if "test_calc.py" not in locked:
        return fail("the test file was not locked")

    parent = Path("/private/tmp") / "debug-pipeline-command-prove"
    _force_rmtree(parent)
    parent.mkdir()
    try:
        src = parent / "src"
        src.mkdir()
        (src / "test_calc.py").write_text("raise SystemExit(0)\n", encoding="utf-8")
        fence = Fence([parent])
        runner = FakeRunner(parent / "work", fence)
        redact = load_redactor(repo_root())
        runner.pull_local(src, redact, False)
        runner.freeze_validator("python3 test_calc.py && echo done")
        ran = (runner.validator_root / "run-frozen.sh").read_text(encoding="utf-8")
        if "'&&'" in ran or "&&" not in ran:
            return fail("the frozen command quoted &&")
        code, out = runner.run_test("python3 test_calc.py && echo done")
        if code != 0 or "done" not in out:
            return fail("&& did not run the next command: " + repr(out))

        pkg = parent / "pkg"
        pkg.mkdir()
        (pkg / "package.json").write_text(
            '{"scripts": {"test": "node verify.js"}}\n',
            encoding="utf-8",
        )
        (pkg / "verify.js").write_text("process.exit(1)\n", encoding="utf-8")
        (pkg / "calc.js").write_text("module.exports = 1\n", encoding="utf-8")
        locked, payload = build_frozen_validator(
            {
                "package.json": ((pkg / "package.json").read_bytes(), 0o644),
                "verify.js": ((pkg / "verify.js").read_bytes(), 0o644),
                "calc.js": ((pkg / "calc.js").read_bytes(), 0o644),
            },
            "npm test",
            "/work",
            "/validator",
        )
        script = payload["run-frozen.sh"][0].decode("utf-8")
        if "/validator/verify.js" not in script or "node verify.js" in script:
            return fail("package script still targets the writable verify.js: " + script)
        if "/work/verify.js" in script:
            return fail("package script points at /work/verify.js")
        if "verify.js" not in locked or "calc.js" in locked:
            return fail("the package entry file was not the locked file")
        controller = load_controller(repo_root())
        stage = parent / "stage"
        stage.mkdir()
        try:
            apply_one(
                controller,
                {"files": {"verify.js": "process.exit(0)\n"}},
                stage,
                ["verify.js", "calc.js", "package.json"],
                locked,
            )
        except ValueError as err:
            if "path rejected" not in str(err):
                return fail(str(err))
        else:
            return fail("verify.js stayed editable")

        other = FakeRunner(parent / "pkg-work" / "work", fence)
        other.pull_local(pkg, redact, False)
        other.freeze_validator("npm test")
        frozen_verify = (other.validator_root / "verify.js").read_bytes()
        (other.container_root / "verify.js").write_text("process.exit(0)\n", encoding="utf-8")
        if (other.validator_root / "verify.js").read_bytes() != frozen_verify:
            return fail("the frozen entry file changed with the customer tree")
        ran = (other.validator_root / "run-frozen.sh").read_text(encoding="utf-8")
        if str(other.validator_root / "verify.js") not in ran:
            return fail("the run does not use the frozen entry file")
        if "node verify.js" in ran:
            return fail("the run still names the writable entry file")
        try:
            other.apply_change(
                controller,
                {"files": {"verify.js": "process.exit(0)\n"}},
                ["verify.js", "calc.js"],
                redact,
            )
        except ValueError as err:
            if "path rejected" not in str(err):
                return fail(str(err))
        else:
            return fail("an edit to verify.js was applied")
    finally:
        _force_rmtree(parent)

    out, store = fresh()
    before = set(Path("/private/tmp").glob("debug-pipeline-work-*"))
    try:
        with track_writes([out, store]) as tracker:
            result = run(
                TICKET, sample_dir(), TEST, out, store,
                runner_name="fake", worker=None,
            )
        if tracker.bad:
            return fail("wrote outside the archive and store folders: " + ", ".join(tracker.bad[:8]))
        allowed = [out.resolve(), store.resolve()]
        work_hits = [path for path in tracker.seen if "debug-pipeline-work-" in path]
        if not work_hits:
            return fail("temporary work was not recorded")
        for path in work_hits:
            if not _under_roots(path, allowed):
                return fail("temporary work escaped the archive folder: " + path)
        leaked = set(Path("/private/tmp").glob("debug-pipeline-work-*")) - before
        if leaked:
            return fail("temporary work was created outside the archive folder")
        if result["result"] not in {"OK", "FAILED", "NOT VERIFIED"}:
            return fail("the fenced run did not finish")
    finally:
        _force_rmtree(out.parent)
    print("checks stay frozen and writes stay in the archive folder")
    return 0


def prove_model_freeze():
    """A model edit is validated, and discovery executes the frozen tests."""
    import shlex

    from debug_pipeline.pipeline import (
        FakeRunner, Fence, _force_rmtree, build_frozen_validator, load_controller, load_redactor,
    )
    from debug_pipeline.workers import ModelWorker, post_model

    _locked, payload = build_frozen_validator(
        {
            "calc.py": (b"def add(a, b):\n    return a - b\n", 0o644),
            "test_calc.py": (b"import unittest\nimport calc\n", 0o644),
        },
        "python3 -m unittest discover",
        "/work",
        "/validator",
    )
    script = payload["run-frozen.sh"][0].decode("utf-8")
    if "cd /work\n" in script or "cd '/work'" in script:
        return fail("discovery starts in the writable tree: " + script)
    if "\ncd /validator\n" not in script:
        return fail("discovery does not start on the frozen copy: " + script)
    if "test_calc.py" not in _locked:
        return fail("discovery left the test file unlocked")
    if "/work" in script.split("exec sh -c", 1)[-1]:
        return fail("discovery command still names the writable tree")

    _locked_s, aimed_payload = build_frozen_validator(
        {"test_calc.py": (b"raise SystemExit(1)\n", 0o644)},
        "python3 -m unittest discover -s /work",
        "/work",
        "/validator",
    )
    aimed = aimed_payload["run-frozen.sh"][0].decode("utf-8")
    if "-s /work" in aimed or "-s '/work'" in aimed or "cd /work\n" in aimed:
        return fail("discovery -s still points at the writable tree: " + aimed)
    if "-s /validator" not in aimed and "-s '/validator'" not in aimed:
        return fail("discovery -s was not moved onto the frozen tree: " + aimed)

    _glued, glued_payload = build_frozen_validator(
        {"test_calc.py": (b"raise SystemExit(1)\n", 0o644)},
        "python3 -m unittest discover -s/work",
        "/work",
        "/validator",
    )
    glued_text = glued_payload["run-frozen.sh"][0].decode("utf-8")
    if "-s/work" in glued_text or "cd /work\n" in glued_text:
        return fail("glued discovery path still names the writable tree: " + glued_text)
    if "-s/validator" not in glued_text and "-s'/validator'" not in glued_text:
        return fail("glued discovery path was not moved: " + glued_text)

    parent = Path("/private/tmp") / "debug-pipeline-model-prove"
    _force_rmtree(parent)
    parent.mkdir()
    try:
        src = parent / "src"
        src.mkdir()
        (src / "calc.py").write_text("def add(a, b):\n    return a - b\n", encoding="utf-8")
        frozen_test = (
            "import unittest\n"
            "import calc\n"
            "class AddTests(unittest.TestCase):\n"
            "    def test_add(self):\n"
            "        self.assertEqual(calc.add(1, 1), 2)\n"
        )
        (src / "test_calc.py").write_text(frozen_test, encoding="utf-8")
        fence = Fence([parent])
        runner = FakeRunner(parent / "box" / "work", fence)
        redact = load_redactor(repo_root())
        runner.pull_local(src, redact, False)
        runner.freeze_validator("python3 -m unittest discover")
        entry = (runner.validator_root / "run-frozen.sh").read_text(encoding="utf-8")
        customer = str(runner.container_root)
        validator = str(runner.validator_root)
        if f"\ncd {customer}\n" in entry or f"\ncd {shlex.quote(customer)}\n" in entry:
            return fail("the live discovery script starts in the writable tree")
        if f"\ncd {validator}\n" not in entry and f"\ncd {shlex.quote(validator)}\n" not in entry:
            return fail("the live discovery script does not start on the frozen copy: " + entry)
        before = (runner.validator_root / "test_calc.py").read_bytes()
        digest = runner.validator_digest
        (runner.container_root / "test_calc.py").write_text(
            "import unittest\n"
            "class AddTests(unittest.TestCase):\n"
            "    def test_add(self):\n"
            "        self.assertTrue(True)\n",
            encoding="utf-8",
        )
        code, out = runner.run_test("python3 -m unittest discover")
        if code == 0 or "Ran 1 test" not in out or "FAIL" not in out:
            return fail("discovery ran the writable tests: " + repr(code) + " " + out[-500:])
        if (runner.validator_root / "test_calc.py").read_bytes() != before:
            return fail("the frozen test bytes changed")
        if runner.validator_digest != digest or not runner._validator_intact():
            return fail("the validator digest changed when the customer test changed")

        controller = load_controller(repo_root())
        preview = parent / "preview"
        preview.mkdir()
        (preview / "calc.py").write_text("def add(a, b):\n    return a - b\n", encoding="utf-8")
        (preview / "test_calc.py").write_text(frozen_test, encoding="utf-8")

        class _Runner:
            def __init__(self):
                self.work = preview
                self.locked_paths = {"test_calc.py"}
                self.fence = fence

        class _View:
            def read_receipt(self):
                return ""

            def read_text(self, rel):
                return (preview / rel).read_text(encoding="utf-8")

        seen = []

        def transport(prompt, system, model):
            seen.append(prompt)
            return (
                "```json\n"
                "{\"edits\":[{\"path\":\"calc.py\",\"old\":\"return a - b\",\"new\":\"return a + b\"}]}\n"
                "```"
            )

        worker = ModelWorker("test-model", transport=transport)
        worker.bind(_Runner(), controller)
        proposal = worker("make the test pass", _View())
        if proposal.get("edits") != [
            {"path": "calc.py", "old": "return a - b", "new": "return a + b"}
        ]:
            return fail("the validated edit was not returned")
        if not seen or "return a - b" not in seen[0] or "FILE test_calc.py (read-only)" not in seen[0]:
            return fail("the model was not shown the frozen test as read-only")

        def bad_transport(prompt, system, model):
            return "{\"files\":{\"test_calc.py\":\"raise SystemExit(0)\\n\"}}"

        bad = ModelWorker("test-model", transport=bad_transport)
        bad.bind(_Runner(), controller)
        try:
            bad("make the test pass", _View())
        except ValueError as err:
            if "path rejected" not in str(err):
                return fail(str(err))
        else:
            return fail("a model edit to the test was returned")

        try:
            post_model("ftp://example", "test-model", "system", "prompt", False)
        except ValueError as err:
            if "http" not in str(err):
                return fail(str(err))
        else:
            return fail("a non-http model endpoint was accepted")
    finally:
        _force_rmtree(parent)

    seen_run = []

    def run_transport(prompt, system, model):
        seen_run.append(prompt)
        return json.dumps({
            "edits": [{"path": "calc.py", "old": "return a - b", "new": "return a + b"}],
        })

    out_dir, store = fresh()
    try:
        result = run(
            TICKET, sample_dir(), TEST, out_dir, store,
            runner_name="fake",
            worker=ModelWorker("test-model", transport=run_transport),
            rounds=1,
        )
        if result["result"] != "OK":
            text = ""
            if result["receipt"] is not None and Path(result["receipt"]).exists():
                text = Path(result["receipt"]).read_text(encoding="utf-8")
            return fail("model edit did not fix the sample: " + text[-500:])
        if not seen_run or PLANTED in seen_run[0] or "calc.py" not in seen_run[0]:
            return fail("the model prompt was empty, unlabeled, or carried the planted key")
    finally:
        _force_rmtree(out_dir.parent)

    env = os.environ.copy()
    env.pop("DEBUG_PIPELINE_MODEL", None)
    env["PYTHONDONTWRITEBYTECODE"] = "1"
    launcher = repo_root() / "runner" / "debug-pipeline" / "debug-pipeline"
    help_run = subprocess.run(
        [sys.executable, str(launcher), "run", "--help"],
        cwd=repo_root(), capture_output=True, text=True, env=env,
    )
    if help_run.returncode != 0 or "{fake,none,model}" not in help_run.stdout.replace(" ", ""):
        return fail("the model worker is not on the command line: " + help_run.stdout)
    sink = Path("/private/tmp") / "debug-pipeline-model-cli"
    _force_rmtree(sink)
    sink.mkdir()
    try:
        missing = subprocess.run(
            [
                sys.executable, str(launcher), "run",
                "--ticket", TICKET, "--source", str(sample_dir()), "--test", TEST,
                "--worker", "model", "--runner", "fake",
                "--store", str(sink / "store"), "--out", str(sink / "out"),
            ],
            cwd=repo_root(), capture_output=True, text=True, env=env,
        )
        if missing.returncode != 2 or "an explicit model is required" not in missing.stderr:
            return fail("a model run without a model name continued: " + missing.stderr + missing.stdout)
    finally:
        _force_rmtree(sink)
    print("model edits are validated and discovery runs the frozen tests")
    return 0


def prove_handoff_gaps():
    from debug_pipeline.pipeline import DockerBox, FakeRunner, Fence, _force_rmtree
    out, _store = fresh()
    try:
        log = ReceiptLog(out / "blank.jsonl", "selfcheck")
        log.append("Action", "OK", "/work", "one")
        line = log.path.read_bytes()
        for data, physical in ((b"\n" + line, 1), (line + b"\n", 2)):
            log.path.write_bytes(data)
            ok, message = verify(log.path)
            if ok or f"line {physical}: blank receipt line" not in message:
                return fail(message)
        box = DockerBox(FakeRunner(out / "preview", Fence([out])),
                        "proof", "python:3.12-slim", str(log.path), False)
        calls = []
        def fake_run(args, **kwargs):
            calls.append(args)
            if "tar" in args:
                if args[-3:] != ["work", "tmp", "validator"]:
                    raise AssertionError("validator missing from capture")
                return _Done(0, _tar({"validator/run-frozen.sh": b"FROZEN-CHECK"}))
            if args[:2] == ["docker", "export"]:
                return _Done(0, _tar({"validator/stale": b"STALE"}))
            return _Done(0)
        box._run = fake_run
        dest = out / "captured.tar"
        box.export_filesystem(dest)
        with tarfile.open(dest) as tar:
            if tar.extractfile("validator/run-frozen.sh").read() != b"FROZEN-CHECK":
                return fail("validator missing")
            if "validator/stale" in tar.getnames():
                return fail("stale validator was not replaced")
        print("physical lines and validator capture proved")
        return 0
    finally:
        _force_rmtree(out.parent)


def prove_model_receipt():
    from unittest.mock import patch
    from debug_pipeline.workers import post_model
    from debug_pipeline.pipeline import _force_rmtree
    requests = []
    reads = []
    receipt = "BASELINE-READ-ONLY-EVIDENCE\n" + "x" * 10000
    def reader():
        reads.append(True)
        return receipt
    for ollama in (False, True):
        requests.clear()
        reads.clear()
        def urlopen(req, timeout):
            payload = json.loads(req.data)
            requests.append(payload)
            if len(requests) == 1:
                fn = {"name": "read_receipt", "arguments": {"offset": 0} if ollama else '{"offset":0}'}
                message = {"role": "assistant", "content": "", "tool_calls": [
                    {"id": "read-1", "type": "function", "function": fn}]}
            else:
                message = {"role": "assistant", "content": '{"files":{"calc.py":"fixed"}}'}
            body = {"message": message} if ollama else {"choices": [{"message": message}]}
            return io.BytesIO(json.dumps(body).encode())
        with patch("urllib.request.urlopen", urlopen):
            answer = post_model("http://localhost/" + ("api/chat" if ollama else "v1/chat/completions"),
                                "test-model", "system", "short pointer prompt", False, read_receipt=reader)
        if not reads or len(requests) != 2 or "fixed" not in answer:
            return fail("receipt tool was not used")
        first = requests[0]["messages"]
        if receipt[:20] in json.dumps(first) or len(first) != 2:
            return fail("raw log was pasted into prompt")
        tool = requests[1]["messages"][-1]
        data = json.loads(tool["content"])
        if tool["role"] != "tool" or data["data"] != receipt[:2048] or data["eof"]:
            return fail("receipt tool page was wrong or unbounded")
    captured = []
    def worker(prompt, view):
        captured.append(prompt)
        return sample_worker(prompt, view)
    out, store = fresh()
    try:
        result = run(TICKET, sample_dir(), TEST, out, store, runner_name="fake", worker=worker)
        if result["result"] != "OK" or not captured or "Current failure: exit 1:" not in captured[0]:
            return fail("baseline failure evidence missing from first repair prompt")
        if len(captured[0].encode()) > PROMPT_MAX or '"prev_hash"' in captured[0]:
            return fail("failure prompt unbounded or contains raw log")
    finally:
        _force_rmtree(out.parent)
    print("model receipt tool and failure evidence proved")
    return 0


def prove_env_archive():
    from debug_pipeline.pipeline import _force_rmtree
    out, store = fresh()
    source = out.parent / "customer"
    source.mkdir()
    literal = "customerOpaqueValue92847"
    try:
        for path in sample_dir().iterdir():
            if path.is_file():
                (source / path.name).write_bytes(path.read_bytes())
        (source / ".env").write_text("DATABASE_URL=" + literal + "\nPORT=1\nMODE=dev\n")
        (source / "notes.txt").write_text("observed " + literal)
        captured = []
        def worker(prompt, view):
            captured.append(view.read_text(".env"))
            captured.append(view.read_text("notes.txt"))
            return sample_worker(prompt, view)
        result = run(TICKET, source, TEST, out, store, runner_name="fake", worker=worker)
        if result["result"] != "OK":
            return fail("env run failed")
        blob = "\n".join(captured) + result["receipt"].read_text()
        parts = archive_parts(result["archive"])
        if literal in blob or literal.encode() in parts["filesystem.tar"]:
            return fail("env literal escaped")
        if "PORT=1" in captured[0] or "MODE=dev" in captured[0]:
            return fail("short or neutral env value escaped")
        test = (source / "test_calc.py").read_text()
        (source / "test_calc.py").write_text(
            "from pathlib import Path\n"
            "Path('generated.log').write_text('sk-' + 'test-' + 'RUNTIMEKEY0123456789abcd')\n" + test)
        result = run(TICKET, source, TEST, out.parent / "second", store,
                     runner_name="fake", worker=sample_worker)
        if result["result"] != "FAILED" or result["archive"] is not None:
            return fail("generated secret was archived")
        if "secret shape survived in archive filesystem; run stopped" not in result["receipt"].read_text():
            return fail("archive survivor stop missing")
        print("env intake and archive survivor gate proved")
        return 0
    finally:
        _force_rmtree(out.parent)


def prove_docker_archive_scope():
    from debug_pipeline.pipeline import (
        DockerBox, FakeRunner, FolderTicketStore, _force_rmtree, _seal,
    )
    from debug_pipeline.scrub import load_redactor, survives
    out, store_path = fresh()
    out.mkdir()
    try:
        redact = load_redactor(repo_root())
        library = b"passwd = netrcobj.authenticators(host)\n"
        if not survives(redact, library.decode()):
            return fail("fixture no longer triggers the shared redactor")
        fence = Fence([out, store_path])
        mirror = FakeRunner(out / "preview" / "work", fence)
        mirror.original = {"calc.py": "print('ok')\n"}
        mirror.store_scrubbed("calc.py", b"print('ok')\n")
        log = ReceiptLog(out / "receipt.jsonl", "selfcheck", fence)
        store = FolderTicketStore(store_path, fence)
        box = DockerBox(mirror, "proof", "python:3.12-slim", str(log.path), False)
        customer = {"work/calc.py": b"print('ok')\n", "tmp/clean.txt": b"clean"}
        def fake_run(args, **kwargs):
            if args[:2] == ["docker", "export"]:
                return _Done(0, _tar({"usr/local/lib/python3.12/ftplib.py": library}))
            if "tar" in args:
                root = args[args.index("-C") + 1]
                return _Done(0, _tar(customer if root == "/" else {"calc.py": b"print('ok')\n"}))
            return _Done(0)
        box._run = fake_run
        result = {"result": "OK", "archive": None}
        _seal(result, TICKET, out, fence, log, box, redact, store, "OK", 0, "docker")
        if result["result"] != "OK" or result["archive"] is None:
            return fail("immutable library source blocked Docker sealing")
        parts = archive_parts(result["archive"])
        if library not in parts["filesystem.tar"]:
            return fail("base library was removed or changed")
        actual = hashlib.sha256(result["archive"].read_bytes()).hexdigest()
        if actual != result["sha256"] or json.loads(result["ticket_record"].read_text())["sha256"] != actual:
            return fail("sealed archive hash or ticket attachment mismatch")
        for root in ("work", "tmp", "validator"):
            blocked = out / root
            blocked.mkdir()
            customer[root + "/generated.log"] = LEAK.encode()
            result = {"result": "OK", "archive": None}
            _seal(result, TICKET, blocked, fence, log, box, redact, store, "OK", 0, "docker")
            del customer[root + "/generated.log"]
            if result["result"] != "FAILED" or result["archive"] is not None or (blocked / f"{TICKET}.tar").exists():
                return fail("customer secret escaped the Docker archive gate: " + root)
        print("Docker archive scope proved with fake Docker")
        return 0
    finally:
        _force_rmtree(out.parent)


def prove_short_env_refresh():
    from debug_pipeline.pipeline import DockerBox, FakeRunner, _force_rmtree, load_controller
    from debug_pipeline.scrub import load_redactor
    from debug_pipeline.workers import ModelWorker
    out, store = fresh()
    source = out.parent / "customer"
    source.mkdir()
    raw = b"REGION=xy7u\n"
    clean = "REGION=[REDACTED]\n"
    try:
        for path in sample_dir().iterdir():
            if path.is_file():
                (source / path.name).write_bytes(path.read_bytes())
        (source / ".env").write_bytes(raw)
        seen = []
        def worker(prompt, view):
            seen.append(view.read_text(".env"))
            if len(seen) == 1:
                return {"edits": [{"path": "calc.py", "old": "return a - b", "new": "return b - a"}]}
            return {"edits": [{"path": "calc.py", "old": "return b - a", "new": "return a + b"}]}
        result = run(TICKET, source, TEST, out, store, runner_name="fake", worker=worker, keep_secrets=True)
        if result["result"] != "OK" or seen != [clean, clean]:
            return fail("short env value returned to the fake worker after an edit")
        parts = archive_parts(result["archive"])
        if "xy7u" in text_blob(parts) or "xy7u" in _shown(result):
            return fail("short env value leaked into archive metadata or worker context")
        if raw not in parts["filesystem.tar"]:
            return fail("keep-secrets lost the container value")
        fence = Fence([out])
        mirror = FakeRunner(out / "docker-preview" / "work", fence)
        redact = load_redactor(repo_root())
        mirror.pull_local(source, redact, True)
        controller = load_controller(repo_root())
        box = DockerBox(mirror, "proof", "python:3.12-slim", str(result["receipt"]), False)
        source_map = {".env": raw, "calc.py": b"def add(a, b):\n    return a + b\n"}
        box._run = lambda *args, **kwargs: _Done(0, _tar(source_map))
        box._refresh_preview(redact)
        if box.read_text(".env") != clean or box.snapshot_text(redact)[".env"] != clean:
            return fail("Docker refresh or snapshot exposed the short env value")
        if mirror.snapshot_text(redact)[".env"] != clean:
            return fail("fake snapshot exposed the short env value")
        class View:
            def read_text(self, rel):
                return box.read_text(rel)
        model = ModelWorker("test-model")
        model.bind(box, controller)
        if "xy7u" in model._context("bounded pointer", View()):
            return fail("Docker model context exposed the short env value")
        print("short env refresh and snapshots stay scrubbed")
        return 0
    finally:
        _force_rmtree(out.parent)


def prove_failure_feedback():
    from debug_pipeline.pipeline import _failure_view, _force_rmtree
    from debug_pipeline.scrub import load_redactor

    lead = "lead-in\n" * 50
    trace = lead + "real value 5\nTraceback (most recent call last):\n  File \"app.py\", line 2, in add\nAssertionError\n"
    excerpt = failure_excerpt(trace)
    if excerpt.count("lead-in") > 8 or "real value 5" not in excerpt or "Traceback" not in excerpt or "AssertionError" not in excerpt:
        return fail("excerpt dropped the traceback or the lines just above it")
    long = "Traceback (most recent call last):\n" + ("x" * 8000) + "\nValueError: tail-mark\n"
    tail = failure_excerpt(long)
    if "tail-mark" not in tail or len(tail.encode("utf-8")) > 2400:
        return fail("long traceback dropped its last line or ignored the cap")
    sent = build_prompt(
        TEST, 2, [{"round": 1, "what": "edit", "where": "exit 1"}],
        failure="exit 1: ValueError: tail-mark", output=long,
    )
    if "tail-mark" not in sent or POINTER not in sent or "- round 1:" not in sent:
        return fail("traceback tail was not sent back with the attempt line")
    if len(sent.encode("utf-8")) > PROMPT_MAX:
        return fail("traceback prompt exceeded the cap")
    redact = load_redactor(repo_root())
    leaked = "Traceback (most recent call last):\nRuntimeError: " + PLANTED + "\n"
    _where, cleaned = _failure_view(1, leaked, redact)
    if PLANTED in cleaned or "[REDACTED]" not in cleaned or PLANTED in _where:
        return fail("stderr secret was not scrubbed before it could be shown again")

    out, store = fresh()
    source = out.parent / "broken"
    source.mkdir()
    (source / "app.py").write_text(
        'def add(a, b):\n    raise RuntimeError("sk-test-" + "FAKEKEY0123456789abcd")\n',
        encoding="utf-8",
    )
    (source / "test_app.py").write_text(
        "import app\nassert app.add(2, 2) == 4\n",
        encoding="utf-8",
    )
    seen = []

    def worker(prompt, view):
        seen.append(prompt)
        text = view.read_text("app.py")
        old = 'raise RuntimeError("sk-test-" + "FAKEKEY0123456789abcd")'
        if old not in text:
            return {"files": {"app.py": text}}
        return {"edits": [{"path": "app.py", "old": old, "new": "return a + b"}]}

    try:
        result = run(
            TICKET, source, "python3 test_app.py", out, store,
            runner_name="fake", worker=worker,
        )
        receipt = result["receipt"].read_text(encoding="utf-8")
        if result["result"] != "OK":
            return fail("feedback run did not fix: " + receipt[-500:])
        if not seen or "Traceback" not in seen[0] or "RuntimeError" not in seen[0]:
            return fail("model prompt missed the traceback")
        if PLANTED in seen[0] or PLANTED in receipt:
            return fail("stderr secret reached the model or the receipt")
        if "[REDACTED]" not in seen[0] or "test output:" not in receipt:
            return fail("scrubbed stderr was not looped back")
    finally:
        _force_rmtree(out.parent)
    print("failed test output looped back")
    return 0


def prove_grok_fallback():
    from debug_pipeline.pipeline import _force_rmtree
    from debug_pipeline.workers import ModelWorker, is_local_model
    import debug_pipeline.workers as workers

    os.environ["DEBUG_PIPELINE_GROK_FALLBACK"] = "off"
    if workers.grok_token():
        return fail("fallback token was read while fallback is off")
    cloud = ModelWorker("grok-4.7", endpoint=workers.GROK_ENDPOINT, transport=lambda *_args: "{}")
    local = ModelWorker("qwen2.5-coder:7b", transport=lambda *_args: "{}")
    if is_local_model(cloud) or not is_local_model(local) or is_local_model(None):
        return fail("local model detection is wrong")

    out, store = fresh()
    source = out.parent / "calc"
    source.mkdir()
    (source / "calc.py").write_text(
        "def calc():\n"
        "    import math as m\n"
        "    z = x**2 + y**3\n"
        "    z = m.sqrt(z)\n"
        "\n"
        "x = 2\n"
        "y = 3\n"
        "z = 0\n",
        encoding="utf-8",
    )
    (source / "check_calc.py").write_text(
        "import math\n"
        "import calc\n"
        "got = calc.calc()\n"
        "expect = math.sqrt(2**2 + 3**3)\n"
        "assert got is not None and abs(got - expect) < 1e-9, got\n",
        encoding="utf-8",
    )

    def local_transport(prompt, system, model):
        return json.dumps({
            "edits": [{"path": "calc.py", "old": "z = 0", "new": "z = None"}],
        })

    def grok_transport(prompt, system, model):
        if "AssertionError" not in prompt and "None" not in prompt:
            return "{}"
        return json.dumps({
            "edits": [{
                "path": "calc.py",
                "old": "    z = m.sqrt(z)\n",
                "new": "    z = m.sqrt(z)\n    return z\n",
            }],
        })

    def stub():
        return ModelWorker("grok-4.7", endpoint=workers.GROK_ENDPOINT, transport=grok_transport)

    previous = workers.grok_fallback_worker
    workers.grok_fallback_worker = stub
    try:
        result = run(
            TICKET, source, "python3 check_calc.py", out, store,
            runner_name="fake",
            worker=ModelWorker("qwen2.5-coder:7b", transport=local_transport),
            rounds=1,
        )
        receipt = result["receipt"].read_text(encoding="utf-8")
        if result["result"] != "OK":
            return fail("grok fallback did not fix: " + receipt[-500:])
        if "falling back to grok-4.7" not in receipt or "z = None" not in receipt:
            return fail("receipt did not record the local failure and the grok fallback")
        if "return z" not in receipt:
            return fail("receipt did not record the grok edit")
        if "eyJ" in receipt:
            return fail("a login token reached the receipt")
        with tarfile.open(result["archive"]) as tar:
            diff = tar.extractfile("diff.patch").read().decode("utf-8")
        if "return z" not in diff or "z = None" in diff:
            return fail("fallback did not restore the source before the grok edit")
    finally:
        workers.grok_fallback_worker = previous
        _force_rmtree(out.parent)
    print("local model failure fell back to grok")
    return 0


PROVES = {
    "docker-archive-scope": prove_docker_archive_scope,
    "short-env-refresh": prove_short_env_refresh,
    "env-archive": prove_env_archive,
    "handoff-gaps": prove_handoff_gaps,
    "model-receipt": prove_model_receipt,
    "baseline": prove_baseline,
    "fix": prove_fix,
    "tamper": prove_tamper,
    "archive": prove_archive,
    "ticket": prove_ticket,
    "fence": prove_fence,
    "readonly": prove_readonly,
    "prompt": prove_prompt,
    "failure-feedback": prove_failure_feedback,
    "repeat": prove_repeat,
    "docker-plan": prove_docker_plan,
    "scrub": prove_scrub,
    "scrub-count": prove_scrub_count,
    "survivor": prove_survivor,
    "keep-secrets": prove_keep_secrets,
    "container-repair": prove_container_repair,
    "frozen-guard": prove_frozen_guard,
    "command-fence": prove_command_fence,
    "model-freeze": prove_model_freeze,
    "grok-fallback": prove_grok_fallback,
}


def main(argv):
    os.environ.setdefault("DEBUG_PIPELINE_GROK_FALLBACK", "off")
    if len(argv) >= 2 and argv[0] == "--prove":
        fn = PROVES.get(argv[1])
        if fn is None:
            print("unknown prove: " + argv[1], file=sys.stderr)
            return 2
        return fn()
    failed = [name for name, fn in PROVES.items() if fn() != 0]
    if failed:
        print("selfcheck failed: " + ", ".join(failed), file=sys.stderr)
        return 1
    print("selfcheck ok")
    return 0
