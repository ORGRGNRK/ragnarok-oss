"""Run one question against the configured providers.

The child process gets an allowlisted environment, a new empty working
folder, and a hard time limit. Only the provider's own stream is recorded.
"""

import json
import os
import select
import shutil
import signal
import subprocess
import tempfile
import threading
import time
from pathlib import Path

from answer_engine import db
from answer_engine.providers import make_provider
from answer_engine.redact import cap_text, redact

RUN_LOCK = threading.Lock()
DEFAULT_TIMEOUT = 300.0
TIMEOUT_TEXT = "This run timed out."
KNOWN = ("claude", "grok", "codex")
_LINE_LIMIT = 4_000_000


def home_dir():
    raw = os.environ.get("ANSWER_ENGINE_HOME")
    if raw:
        return Path(raw)
    return Path.home() / ".answer-engine"


def database_path():
    root = home_dir()
    root.mkdir(parents=True, exist_ok=True)
    return str(root / "answers.db")


def timeout_seconds():
    raw = os.environ.get("ANSWER_ENGINE_TIMEOUT_SECONDS", "")
    if not raw:
        return DEFAULT_TIMEOUT
    try:
        value = float(raw)
    except ValueError:
        return DEFAULT_TIMEOUT
    if value <= 0:
        return DEFAULT_TIMEOUT
    return value


def child_env():
    env = {}
    for key in ("HOME", "USER", "LOGNAME"):
        if os.environ.get(key):
            env[key] = os.environ[key]
    env["TMPDIR"] = os.environ.get("TMPDIR") or "/tmp"
    env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"
    env["LANG"] = "C.UTF-8"
    env["LC_ALL"] = "C.UTF-8"
    env["TERM"] = "dumb"
    return env


def load_settings():
    order = ["claude", "grok", "codex"]
    bins = {}
    path = home_dir() / "settings.json"
    data = {}
    if path.is_file():
        try:
            loaded = json.loads(path.read_text(encoding="utf-8"))
            if isinstance(loaded, dict):
                data = loaded
        except (OSError, ValueError):
            data = {}
    raw_order = data.get("provider_order")
    if isinstance(raw_order, list):
        picked = [str(name) for name in raw_order if str(name) in KNOWN]
        if picked:
            order = picked
    for name in KNOWN:
        value = data.get(name + "_bin")
        if isinstance(value, str) and value:
            bins[name] = value
    env_order = os.environ.get("ANSWER_ENGINE_PROVIDER_ORDER")
    if env_order:
        picked = [part.strip() for part in env_order.split(",") if part.strip() in KNOWN]
        if picked:
            order = picked
    for name, env_name in (
        ("claude", "ANSWER_ENGINE_CLAUDE_BIN"),
        ("codex", "ANSWER_ENGINE_CODEX_BIN"),
        ("grok", "ANSWER_ENGINE_GROK_BIN"),
    ):
        if os.environ.get(env_name):
            bins[name] = os.environ[env_name]
    return order, bins


def _normalize(event, provider_name, model, duration):
    text = redact(event.get("text") or "")
    kind = event.get("type") or ""
    if kind in ("tool_call", "tool_result", "error"):
        text = cap_text(text)
    prepared = {
        "type": kind,
        "provider": event.get("provider") or provider_name or "",
        "kind": event.get("kind") or "",
        "text": text,
        "name": event.get("name") or "",
        "tool_id": event.get("tool_id") or "",
        "interim": bool(event.get("interim")),
        "model": event.get("model") or model or "",
        "duration_ms": int(duration),
    }
    if event.get("pid"):
        prepared["pid"] = int(event["pid"])
    return prepared


def _kill_group(proc):
    if proc.poll() is not None:
        return
    try:
        os.killpg(proc.pid, signal.SIGKILL)
    except (ProcessLookupError, PermissionError, OSError):
        try:
            proc.kill()
        except OSError:
            pass
    try:
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        try:
            proc.kill()
        except OSError:
            pass
        try:
            proc.wait(timeout=2)
        except subprocess.TimeoutExpired:
            pass


def _reason(state, stderr_text, code):
    text = (state.get("error") or "").strip()
    if text:
        return cap_text(redact(text))
    err = (stderr_text or "").strip()
    if err:
        return cap_text(redact(err))
    if code is None:
        return "the provider did not start"
    return "exit %s" % code


def _run_process(provider, question, workdir, timeout, emit):
    command = provider.build_command(question, workdir)
    state = provider.new_state()
    try:
        proc = subprocess.Popen(
            command,
            cwd=workdir,
            env=child_env(),
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            start_new_session=True,
        )
    except OSError as exc:
        return {
            "ok": False,
            "answer": "",
            "error": cap_text(redact(str(exc))),
            "timed_out": False,
            "code": None,
            "pid": None,
            "error_emitted": False,
            "state": state,
        }

    stderr_buf = bytearray()

    def drain_err():
        try:
            while True:
                chunk = proc.stderr.read(4096)
                if not chunk:
                    break
                if len(stderr_buf) < 100000:
                    room = 100000 - len(stderr_buf)
                    stderr_buf.extend(chunk[:room])
        except OSError:
            pass

    drainer = threading.Thread(target=drain_err, daemon=True)
    drainer.start()

    buf = bytearray()
    fd = proc.stdout.fileno()
    os.set_blocking(fd, False)
    started = time.monotonic()
    deadline = started + timeout
    timed_out = False

    def take_line(raw):
        if len(raw) > _LINE_LIMIT:
            emit(
                {
                    "type": "error",
                    "text": "A stream line was longer than the reader allows and was cut.",
                },
                provider.name,
                state.get("model") or "",
            )
            return
        line = raw.decode("utf-8", "replace").strip()
        if not line:
            return
        try:
            obj = json.loads(line)
        except json.JSONDecodeError:
            return
        for event in provider.parse_line(obj, state):
            emit(event, provider.name, state.get("model") or "")

    def drain_ready():
        while True:
            try:
                chunk = os.read(fd, 65536)
            except BlockingIOError:
                return False
            except OSError:
                return True
            if not chunk:
                return True
            buf.extend(chunk)
            while True:
                nl = buf.find(b"\n")
                if nl < 0:
                    break
                raw = bytes(buf[:nl])
                del buf[: nl + 1]
                take_line(raw)

    eof = False
    while not eof:
        if proc.poll() is not None:
            drain_ready()
            break
        now = time.monotonic()
        if now >= deadline:
            timed_out = True
            break
        try:
            ready, _, _ = select.select([fd], [], [], min(0.2, deadline - now))
        except (OSError, ValueError):
            break
        if ready:
            eof = drain_ready()

    if buf.strip():
        take_line(bytes(buf))

    if timed_out:
        _kill_group(proc)
        drainer.join(timeout=1)
        return {
            "ok": False,
            "answer": "",
            "error": TIMEOUT_TEXT,
            "timed_out": True,
            "code": proc.returncode,
            "pid": proc.pid,
            "error_emitted": False,
            "state": state,
        }

    try:
        code = proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        _kill_group(proc)
        code = proc.returncode
    drainer.join(timeout=1)
    stderr_text = bytes(stderr_buf).decode("utf-8", "replace")
    answer = state.get("answer") or ""
    if not isinstance(answer, str):
        answer = str(answer)
    ok = bool(state.get("ok")) and bool(answer.strip())
    return {
        "ok": ok,
        "answer": redact(answer) if ok else "",
        "error": "" if ok else _reason(state, stderr_text, code),
        "timed_out": False,
        "code": code,
        "pid": proc.pid,
        "error_emitted": bool(state.get("error_emitted")),
        "state": state,
    }


GROUNDING = (
    "Before you answer, run at least one web search on this question and read what it finds. "
    "Base the answer on those sources, not on memory alone. "
    "End with a short 'Sources:' list of the links you actually used. "
    "If the search finds nothing useful, say that plainly instead of guessing.\n\n"
    "How to write the answer:\n"
    "- Give the direct answer in one or two lines first. Then the depth. A short question is not a request for a shallow answer.\n"
    "- Pick the register by the job, not the topic. If something is broken and being fixed or diagnosed, use exact "
    "terms, model numbers, commands, measurements and steps. Otherwise use plain words and familiar examples.\n"
    "- Use the real term. If it is likely new to the reader, define it in half a sentence and keep going.\n"
    "- If you show a command, say in a few words what it does, not only what it proves.\n"
    "- On a follow-up, keep the level the user has shown; do not re-explain basics.\n"
    "- Keep what your sources confirmed separate from what you are assuming or unsure of, and label the assumptions.\n"
    "- Never claim a search, source, measurement or result you did not actually get.\n"
    "Style changes how the answer reads, never how well it is backed up."
)


def build_prompt(question, earlier):
    """What the provider is sent: the grounding rule, the conversation so far, then the new message.
    Only the owner's own words are stored as the question."""
    parts = [GROUNDING, ""]
    if earlier:
        parts.append("This continues an earlier conversation. Earlier turns, oldest first:")
        for turn in earlier:
            parts.append("User: " + (turn.get("question") or ""))
            parts.append("Assistant: " + (turn.get("answer") or ""))
        parts.append("")
        parts.append("New message from the user (a follow-up or added context):")
    parts.append(question)
    return "\n".join(parts)


def ask(question, on_event=None, parent_id=None):
    """Run providers in order. The caller serializes questions if it needs to."""
    question = redact(question or "")
    path = database_path()
    question_id = db.start_question(path, question, parent_id)
    prompt = build_prompt(question, db.thread_before(path, question_id))
    order, bins = load_settings()
    providers = []
    for name in order:
        provider = make_provider(name, bins)
        if provider is not None:
            providers.append(provider)

    seq = [1]
    clock = [time.monotonic()]
    status = "error"
    answer = ""
    provider_name = ""

    def emit(event, provider_for_event="", model=""):
        now = time.monotonic()
        duration = int((now - clock[0]) * 1000)
        if duration < 0:
            duration = 0
        clock[0] = now
        prepared = _normalize(event, provider_for_event, model, duration)
        prepared["seq"] = seq[0]
        seq[0] += 1
        db.add_event(path, question_id, prepared["seq"], prepared)
        if on_event is not None:
            wire = dict(prepared)
            if event.get("question_id") is not None:
                wire["question_id"] = event["question_id"]
            on_event(wire)
        return prepared

    try:
        if not providers:
            emit({"type": "error", "text": "No provider is configured."})
            answer = "No provider is configured."
            status = "error"
        for index, provider in enumerate(providers):
            workdir = tempfile.mkdtemp(prefix="answer-engine-", dir=str(home_dir()))
            clock[0] = time.monotonic()
            try:
                result = _run_process(
                    provider,
                    prompt,
                    workdir,
                    timeout_seconds(),
                    emit,
                )
            finally:
                shutil.rmtree(workdir, ignore_errors=True)
            provider_name = provider.name
            if result["timed_out"]:
                emit(
                    {"type": "error", "text": TIMEOUT_TEXT, "pid": result.get("pid")},
                    provider.name,
                )
                answer = TIMEOUT_TEXT
                status = "timeout"
                break
            if result["ok"]:
                answer = result["answer"]
                status = "done"
                break
            reason = result["error"] or "it failed"
            if index + 1 < len(providers):
                nxt = providers[index + 1]
                emit(
                    {
                        "type": "error",
                        "text": "Switching from %s to %s because %s failed: %s"
                        % (provider.name, nxt.name, provider.name, reason),
                    },
                    provider.name,
                )
                continue
            if not result["error_emitted"]:
                emit({"type": "error", "text": reason}, provider.name)
            answer = reason
            status = "error"
    except Exception as exc:
        answer = "The run failed."
        status = "error"
        try:
            emit({"type": "error", "text": cap_text(redact(str(exc)))})
        except Exception:
            pass
    finally:
        db.finish_question(path, question_id, answer, provider_name, status)
        try:
            emit(
                {"type": "done", "text": answer, "question_id": question_id},
                provider_name,
            )
        except Exception:
            pass
    return db.get_question(path, question_id)
