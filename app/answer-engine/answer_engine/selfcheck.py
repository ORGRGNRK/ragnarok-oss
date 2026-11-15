"""Checks that use fake CLIs, a temporary home, and no network."""

import http.client
import json
import os
import signal
import subprocess
import sys
import tempfile
import textwrap
import threading
import time

from answer_engine import db, runner
from answer_engine.page import PAGE
from answer_engine.providers.claude import ClaudeProvider
from answer_engine.providers.codex import CodexProvider
from answer_engine.providers.grok import GrokProvider
from answer_engine.providers import messages
from answer_engine.redact import redact
from answer_engine.server import host_allowed
from answer_engine.trace import NOTICE, thinking_notice

FAKE_SOURCE = textwrap.dedent(
    """\
    #!/usr/bin/env python3
    import json
    import os
    import sys
    import time

    def emit(obj):
        sys.stdout.write(json.dumps(obj) + "\\n")
        sys.stdout.flush()

    def scenario(question):
        # The app sends a grounding rule and earlier turns first; the user's message is the last line.
        parts = question.strip().splitlines()[-1].split(" ") if question.strip() else []
        if len(parts) >= 2 and parts[0] == "SCENARIO":
            return parts[1]
        return ""

    def family_of(argv):
        if "streaming-messages-json" in argv:
            return "messages"
        if "stream-json" in argv:
            return "messages"
        if "--json" in argv:
            return "codex"
        return "messages"

    def messages_ok(text):
        emit({"type": "result", "subtype": "success", "is_error": False, "result": text})

    def messages_err(text):
        emit({"type": "result", "subtype": "error", "is_error": True, "result": text})

    def codex_ok(text):
        emit({"type": "item.completed", "item": {"id": "a1", "type": "agent_message", "text": text}})
        emit({"type": "turn.completed"})

    def codex_err(text):
        emit({"type": "turn.failed", "error": {"message": text}})

    def finish(family, text, error=False):
        if family == "codex":
            if error:
                codex_err(text)
            else:
                codex_ok(text)
        else:
            if error:
                messages_err(text)
            else:
                messages_ok(text)

    def planted():
        def s(codes):
            return "".join(chr(c) for c in codes)
        sk = s((115, 107, 45)) + "abcdefghijklmnopqrstuvwx"
        ghp = s((103, 104, 112, 95)) + "abcdefghijklmnopqrstuvwx"
        gpat = s((103, 105, 116, 104, 117, 98, 95, 112, 97, 116, 95)) + "abcdefghijklmnopqrstuvwx"
        xai = s((120, 97, 105, 45)) + "abcdefghijklmnopqrstuvwx"
        dashes = s((45, 45, 45, 45, 45))
        begin = s((66, 69, 71, 73, 78))
        end = s((69, 78, 68))
        private = s((80, 82, 73, 86, 65, 84, 69))
        key = s((75, 69, 89))
        pem = dashes + begin + " " + private + " " + key + dashes + "\\nQUJD\\n" + dashes + end + " " + private + " " + key + dashes
        return sk, ghp, gpat, xai, pem

    def key_headers():
        def s(codes):
            return "".join(chr(c) for c in codes)
        dashes = s((45, 45, 45, 45, 45))
        begin = s((66, 69, 71, 73, 78))
        private = s((80, 82, 73, 86, 65, 84, 69))
        key = s((75, 69, 89))
        def line(label):
            return dashes + begin + label + private + " " + key + dashes
        return [line(" "), line(" RSA "), line(" OPENSSH ")]

    def run_order(family):
        if family == "codex":
            emit({"type": "thread.started", "thread_id": "t1"})
            emit({"type": "turn.started"})
            emit({"type": "item.completed", "item": {"id": "r1", "type": "reasoning", "text": "**Checking the tide**"}})
            emit({
                "type": "item.completed",
                "item": {
                    "id": "c1",
                    "type": "command_execution",
                    "command": "echo tide",
                    "aggregated_output": "high\\n",
                    "exit_code": 0,
                    "status": "completed",
                },
            })
            codex_ok("The tide is high.")
            return
        emit({"type": "system", "subtype": "init", "model": "fake-claude"})
        emit({
            "type": "assistant",
            "message": {
                "model": "fake-claude",
                "content": [
                    {"type": "thinking", "thinking": "I should search."},
                    {"type": "tool_use", "id": "toolu_1", "name": "WebSearch", "input": {"query": "tide tables"}},
                ],
            },
        })
        emit({
            "type": "user",
            "message": {
                "content": [
                    {"type": "tool_result", "tool_use_id": "toolu_1", "content": "The tide is high at noon."},
                ],
            },
        })
        messages_ok("High tide is at noon.")

    def run_secret(family):
        sk, ghp, gpat, xai, pem = planted()
        blob = "before " + sk + " middle " + ghp + " mid2 " + gpat + " mid3 " + xai + " after " + pem + chr(10) + chr(10).join(key_headers())
        if family == "codex":
            emit({
                "type": "item.completed",
                "item": {
                    "id": "c1",
                    "type": "command_execution",
                    "command": "search",
                    "aggregated_output": blob,
                    "exit_code": 0,
                    "status": "completed",
                },
            })
            codex_ok("Stored without secrets.")
            return
        emit({
            "type": "assistant",
            "message": {
                "content": [
                    {"type": "tool_use", "id": "t1", "name": "WebFetch", "input": {"query": "tide"}},
                ],
            },
        })
        emit({
            "type": "user",
            "message": {
                "content": [
                    {"type": "tool_result", "tool_use_id": "t1", "content": blob},
                ],
            },
        })
        messages_ok("Stored without secrets.")

    def run_long(family):
        blob = "A" * 25000
        if family == "codex":
            emit({
                "type": "item.completed",
                "item": {
                    "id": "c1",
                    "type": "command_execution",
                    "command": "search",
                    "aggregated_output": blob,
                    "exit_code": 0,
                    "status": "completed",
                },
            })
            codex_ok("long done")
            return
        emit({
            "type": "assistant",
            "message": {
                "content": [
                    {"type": "tool_use", "id": "t1", "name": "WebSearch", "input": {"query": "long"}},
                ],
            },
        })
        emit({
            "type": "user",
            "message": {
                "content": [
                    {"type": "tool_result", "tool_use_id": "t1", "content": blob},
                ],
            },
        })
        messages_ok("long done")

    def run_fts(family):
        if family == "codex":
            emit({"type": "item.completed", "item": {"id": "r1", "type": "reasoning", "text": "Searching the harbor."}})
            emit({
                "type": "item.completed",
                "item": {
                    "id": "c1",
                    "type": "web_search",
                    "query": "harbor",
                    "action": "search",
                    "results": "harbor chart",
                },
            })
            codex_ok("The note is lumenharbor.")
            return
        emit({"type": "system", "subtype": "init", "model": "fake-claude"})
        emit({
            "type": "assistant",
            "message": {
                "content": [
                    {"type": "thinking", "thinking": "Searching the harbor."},
                    {"type": "tool_use", "id": "toolu_h", "name": "WebSearch", "input": {"query": "harbor"}},
                ],
            },
        })
        emit({
            "type": "user",
            "message": {
                "content": [
                    {"type": "tool_result", "tool_use_id": "toolu_h", "content": "harbor chart"},
                ],
            },
        })
        messages_ok("The note is lumenharbor.")

    def run_grok_search():
        emit({"type": "system", "subtype": "init", "model": "fake-grok"})
        emit({
            "type": "stream_event",
            "event": {"type": "message_start", "message": {"model": "fake-grok", "id": "m1"}},
        })
        emit({
            "type": "stream_event",
            "event": {
                "type": "content_block_start",
                "index": 0,
                "content_block": {"type": "thinking", "thinking": ""},
            },
        })
        emit({
            "type": "stream_event",
            "event": {
                "type": "content_block_delta",
                "index": 0,
                "delta": {"type": "thinking_delta", "thinking": "I should search."},
            },
        })
        emit({"type": "stream_event", "event": {"type": "content_block_stop", "index": 0}})
        emit({
            "type": "stream_event",
            "event": {
                "type": "content_block_start",
                "index": 1,
                "content_block": {"type": "server_tool_use", "id": "srv_1", "name": "web_search", "input": {}},
            },
        })
        emit({
            "type": "stream_event",
            "event": {
                "type": "content_block_delta",
                "index": 1,
                "delta": {"type": "input_json_delta", "partial_json": '{"query":"tide chart"}'},
            },
        })
        emit({"type": "stream_event", "event": {"type": "content_block_stop", "index": 1}})
        emit({
            "type": "stream_event",
            "event": {"type": "message_delta", "delta": {"stop_reason": "end_turn"}},
        })
        emit({"type": "stream_event", "event": {"type": "message_stop"}})
        emit({
            "type": "assistant",
            "message": {
                "model": "fake-grok",
                "content": [
                    {"type": "thinking", "thinking": "I should search."},
                    {"type": "server_tool_use", "id": "srv_1", "name": "web_search", "input": {"query": "tide chart"}},
                    {
                        "type": "web_search_tool_result",
                        "tool_use_id": "srv_1",
                        "content": [
                            {"type": "web_search_result", "url": "https://tide.example/chart", "title": "Tide chart"},
                        ],
                    },
                ],
            },
        })
        messages_ok("High tide is at noon.")

    def main():
        argv = sys.argv[1:]
        question = argv[-1] if argv else ""
        family = family_of(argv)
        name = scenario(question)
        if name == "sleep":
            time.sleep(30)
            finish(family, "slept")
            return 0
        if name == "busy":
            time.sleep(1.5)
            finish(family, "finished waiting")
            return 0
        if name == "env":
            info = {
                "cwd": os.getcwd(),
                "base": os.path.basename(os.getcwd()),
                "listing": sorted(os.listdir(os.getcwd())),
                "keys": sorted(os.environ.keys()),
                "path": os.environ.get("PATH", ""),
                "home": os.environ.get("HOME", ""),
                "planted": os.environ.get("AE_PLANTED_SENTINEL", ""),
            }
            finish(family, json.dumps(info))
            return 0
        if name == "script":
            finish(family, "<" + "script>alert(1)</" + "script>")
            return 0
        if name == "secret":
            run_secret(family)
            return 0
        if name == "long":
            run_long(family)
            return 0
        if name == "fts":
            run_fts(family)
            return 0
        if name == "order":
            run_order(family)
            return 0
        if name == "groksearch":
            run_grok_search()
            return 0
        if name == "nothinking":
            finish(family, "A plain answer with no thinking.")
            return 0
        if name == "ping":
            finish(family, "pong")
            return 0
        if name == "fallback":
            if family == "codex":
                finish(family, "The second provider answered.")
                return 0
            finish(family, "usage limit reached", error=True)
            return 1
        finish(family, "No scenario.")
        return 0

    if __name__ == "__main__":
        try:
            code = main()
        except Exception:
            sys.stderr.write("fake failed\\n")
            code = 1
        sys.exit(code)
    """
)


def fail(message):
    sys.stderr.write("selfcheck: " + message + "\n")
    raise SystemExit(1)


def ok(name):
    print("ok " + name, flush=True)


def check(cond, message):
    if not cond:
        fail(message)


def root_dir():
    return os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def bin_path():
    return os.path.join(root_dir(), "bin", "answer-engine")


def planted():
    def s(codes):
        return "".join(chr(code) for code in codes)

    sk = s((115, 107, 45)) + "abcdefghijklmnopqrstuvwx"
    ghp = s((103, 104, 112, 95)) + "abcdefghijklmnopqrstuvwx"
    gpat = s((103, 105, 116, 104, 117, 98, 95, 112, 97, 116, 95)) + "abcdefghijklmnopqrstuvwx"
    xai = s((120, 97, 105, 45)) + "abcdefghijklmnopqrstuvwx"
    dashes = s((45, 45, 45, 45, 45))
    begin = s((66, 69, 71, 73, 78))
    end = s((69, 78, 68))
    private = s((80, 82, 73, 86, 65, 84, 69))
    key = s((75, 69, 89))
    pem = (
        dashes
        + begin
        + " "
        + private
        + " "
        + key
        + dashes
        + "\nQUJD\n"
        + dashes
        + end
        + " "
        + private
        + " "
        + key
        + dashes
    )
    return sk, ghp, gpat, xai, pem


def key_headers():
    def s(codes):
        return "".join(chr(code) for code in codes)

    dashes = s((45, 45, 45, 45, 45))
    begin = s((66, 69, 71, 73, 78))
    private = s((80, 82, 73, 86, 65, 84, 69))
    key = s((75, 69, 89))

    def line(label):
        return dashes + begin + label + private + " " + key + dashes

    return [line(" "), line(" RSA "), line(" OPENSSH ")]


def pgp_header():
    def s(codes):
        return "".join(chr(code) for code in codes)

    dashes = s((45, 45, 45, 45, 45))
    begin = s((66, 69, 71, 73, 78))
    end = s((69, 78, 68))
    private = s((80, 82, 73, 86, 65, 84, 69))
    key = s((75, 69, 89))
    pgp = s((80, 71, 80))
    block = s((66, 76, 79, 67, 75))
    opening = dashes + begin + " " + pgp + " " + private + " " + key + " " + block + dashes
    closing = dashes + end + " " + pgp + " " + private + " " + key + " " + block + dashes
    return opening, closing


def script_payload():
    return "<" + "script>alert(1)</" + "script>"


def types_of(item):
    return [event["type"] for event in item["events"]]


def brief(item):
    answer = item.get("answer") or ""
    return "status=%s provider=%s answer=%s types=%s" % (
        item.get("status"),
        item.get("provider"),
        answer[:180],
        types_of(item),
    )


def use_order(order):
    os.environ["ANSWER_ENGINE_PROVIDER_ORDER"] = order


def run_question(question, order):
    use_order(order)
    return runner.ask(question)


class Running:
    def __init__(self, proc, port):
        self.proc = proc
        self.port = port

    def stop(self):
        proc = self.proc
        if proc.poll() is not None:
            return
        try:
            os.killpg(proc.pid, signal.SIGTERM)
        except OSError:
            try:
                proc.terminate()
            except OSError:
                return
        try:
            proc.wait(timeout=3)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(proc.pid, signal.SIGKILL)
            except OSError:
                try:
                    proc.kill()
                except OSError:
                    return
            try:
                proc.wait(timeout=3)
            except subprocess.TimeoutExpired:
                return


def start_server():
    env = os.environ.copy()
    env["PYTHONDONTWRITEBYTECODE"] = "1"
    env.pop("ANSWER_ENGINE_TIMEOUT_SECONDS", None)
    proc = subprocess.Popen(
        [sys.executable, bin_path(), "serve", "--port", "0"],
        cwd=root_dir(),
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        start_new_session=True,
        text=True,
    )
    lines = []

    def drain():
        try:
            for line in proc.stdout:
                lines.append(line)
        except Exception:
            return

    threading.Thread(target=drain, daemon=True).start()
    deadline = time.time() + 5
    port = None
    while time.time() < deadline:
        snapshot = list(lines)
        for line in snapshot:
            if line.startswith("listening "):
                port = int(line.split()[1])
                break
        if port is not None or proc.poll() is not None:
            break
        time.sleep(0.05)
    if port is None:
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except OSError:
            pass
        fail("server did not listen: %s" % "".join(lines)[-500:])
    return Running(proc, port)


def http_request(port, method, path, host, body=None, timeout=20):
    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=timeout)
    headers = {"Host": host}
    data = None
    if body is not None:
        data = json.dumps(body).encode("utf-8")
        headers["Content-Type"] = "application/json"
        headers["Content-Length"] = str(len(data))
    try:
        conn.request(method, path, body=data, headers=headers)
        resp = conn.getresponse()
        payload = resp.read()
        return resp.status, payload
    finally:
        conn.close()


def sse_events(payload):
    found = []
    text = payload.decode("utf-8")
    for block in text.split("\n\n"):
        for line in block.split("\n"):
            if line.startswith("data:"):
                found.append(json.loads(line[5:].strip()))
    return found


def dead(pid):
    try:
        os.kill(pid, 0)
    except OSError:
        return True
    return False


def check_redactor():
    for header in key_headers():
        check(redact(header) == "[redacted]", "private key header was kept")
        check(redact("note " + header + " tail") == "note [redacted] tail", "private key header was kept in text")
    ok("private-key-header")
    sk, ghp, gpat, xai, pem = planted()
    raw = "before " + sk + " middle " + ghp + " mid2 " + gpat + " mid3 " + xai + " after " + pem
    cleaned = redact(raw)
    for secret in (sk, ghp, gpat, xai, pem):
        check(secret not in cleaned, "redactor missed a planted secret")
    check(cleaned.count("[redacted]") >= 5, "redactor replacement missing")
    state = messages.new_state()
    events = messages.parse_obj(
        {
            "type": "assistant",
            "message": {"content": [{"type": "redacted_thinking", "data": "hidden"}]},
        },
        state,
    )
    check(events == [], "redacted thinking was turned into text")
    provider = GrokProvider("grok")
    state = provider.new_state()
    events = provider.parse_line(
        {"type": "result", "subtype": "success", "is_error": False, "result": "from grok"},
        state,
    )
    check(len(events) == 1 and events[0]["type"] == "answer" and events[0]["text"] == "from grok", "grok parse")
    check(state.get("ok") is True, "grok parse did not accept the result")


def check_commands():
    claude = ClaudeProvider("/tmp/fake-claude").build_command("hello", "/tmp/answer-engine-cmd")
    check(claude[claude.index("--tools") + 1] == "WebSearch,WebFetch", "claude tools")
    check(claude[claude.index("--allowedTools") + 1] == "WebSearch,WebFetch", "claude allowed tools")
    check("--safe-mode" in claude, "claude safe-mode")
    check("--strict-mcp-config" in claude, "claude strict mcp")
    check("--restricted" in claude, "claude restricted")
    check("--disable-slash-commands" in claude, "claude slash commands")
    check("--bare" not in claude, "claude bare")
    mcp = json.loads(claude[claude.index("--mcp-config") + 1])
    check(mcp == {"mcpServers": {}}, "claude mcp config")
    check({"Bash", "Read", "Write", "Edit", "PowerShell"}.isdisjoint(claude), "claude extra tools")
    joined = "\n".join(claude)
    check("dangerously-skip-permissions" not in joined, "claude skip permissions")
    check("bypassPermissions" not in joined, "claude bypass")
    check(claude[claude.index("--permission-mode") + 1] == "dontAsk", "claude permission mode")
    check(claude[-2] == "--" and claude[-1] == "hello", "claude question")

    codex = CodexProvider("/tmp/fake-codex").build_command("hello", "/tmp/answer-engine-cmd")
    check(codex[1] == "exec", "codex exec")
    check("--json" in codex, "codex json")
    check(codex[codex.index("--sandbox") + 1] == "read-only", "codex sandbox")
    check("--ignore-user-config" in codex, "codex ignore config")
    check("--ignore-rules" in codex, "codex ignore rules")
    check("--ephemeral" in codex, "codex ephemeral")
    check("--search" not in codex, "codex search flag")
    check("dangerously-bypass-approvals-and-sandbox" not in codex, "codex bypass sandbox")
    check("dangerously-bypass-hook-trust" not in codex, "codex bypass hooks")
    disabled = set()
    for index, part in enumerate(codex):
        if part == "--disable" and index + 1 < len(codex):
            disabled.add(codex[index + 1])
    for name in (
        "shell_tool",
        "unified_exec",
        "unified_exec_tty",
        "hooks",
        "plugins",
        "computer_use",
        "browser_use",
        "browser_use_external",
        "browser_use_full_cdp_access",
        "image_generation",
        "multi_agent",
    ):
        check(name in disabled, "codex disable " + name)
    check(codex[codex.index("-C") + 1] == "/tmp/answer-engine-cmd", "codex workdir")

    grok = GrokProvider("/tmp/fake-grok").build_command("hello", "/tmp/answer-engine-cmd")
    check(grok[grok.index("--output-format") + 1] == "streaming-messages-json", "grok format")
    check(grok[grok.index("--tools") + 1] == "web_search,web_fetch", "grok tools")
    removed = grok[grok.index("--disallowed-tools") + 1].split(",")
    for name in (
        "read_file",
        "search_replace",
        "grep",
        "list_dir",
        "run_terminal_command",
        "todo_write",
        "spawn_subagent",
    ):
        check(name in removed, "grok disallowed " + name)
    check("--no-subagents" in grok, "grok subagents")
    check(grok[grok.index("--sandbox") + 1] == "strict", "grok sandbox")
    check(grok[grok.index("--permission-mode") + 1] == "dontAsk", "grok permission")
    check(grok[grok.index("--cwd") + 1] == "/tmp/answer-engine-cmd", "grok cwd")
    check("--always-approve" not in grok, "grok always approve")
    check(grok[-2] == "-p" and grok[-1] == "hello", "grok question")
    ok("claude-command-limits")


def check_partial_search():
    opening, closing = pgp_header()
    check(redact(opening) == "[redacted]", "pgp private key header was kept")
    check(redact("note " + opening + " tail") == "note [redacted] tail", "pgp header kept in text")
    body = "QUJD"
    orphan = key_headers()[1] + "\n" + body
    cleaned = redact(orphan)
    check(body not in cleaned, "private key body without an end line was kept")
    check(key_headers()[1] not in cleaned, "orphan private key header was kept")
    full = opening + "\n" + body + "\n" + closing
    full_cleaned = redact(full)
    check(body not in full_cleaned and closing not in full_cleaned, "full pgp block left a piece")
    trailed = redact(orphan + "\n\nThe tide is high.")
    check(body not in trailed and "The tide is high." in trailed, "orphan body ate the following sentence")
    check("only tools" not in PAGE, "page claims an unenforced tool limit")
    check("allowed to use" not in PAGE, "page claims a tool allowlist")
    check("The trace shows each tool that actually ran." in PAGE, "page lost its intro")
    readme_path = os.path.join(root_dir(), "README.md")
    with open(readme_path, encoding="utf-8") as handle:
        readme = handle.read()
    check("--sandbox strict" in readme, "readme missing strict sandbox")
    check("still reads everywhere" in readme, "readme missing read-only scope")
    check("warns and continues without enforcement" in readme, "readme missing sandbox fail-open")
    check("/tmp" in readme and "/var/tmp" in readme, "readme missing strict temp writes")
    check("no-op" in readme and "macOS" in readme, "readme missing macOS network note")
    grok = GrokProvider("/tmp/fake-grok").build_command("hello", "/tmp/answer-engine-cmd")
    check(grok[grok.index("--sandbox") + 1] == "strict", "grok sandbox is not strict")
    item = run_question("SCENARIO groksearch", "grok")
    calls = [event for event in item["events"] if event["type"] == "tool_call"]
    results = [event for event in item["events"] if event["type"] == "tool_result"]
    thinks = [event for event in item["events"] if event["type"] == "thinking"]
    check(len(thinks) == 1 and thinks[0]["text"] == "I should search.", "grok thinking duplicated " + brief(item))
    check(len(calls) == 1 and calls[0]["name"] == "web_search", "grok search tool call " + brief(item))
    check(len(results) == 1, "grok search result missing " + brief(item))
    check("tide.example/chart" in results[0]["text"], "grok search url missing " + brief(item))
    check(item["provider"] == "grok" and item["status"] == "done", "grok search status " + brief(item))
    stored = open(runner.database_path(), "rb").read()
    check(b"tide.example/chart" in stored, "grok search url was not stored")
    ok("partial-search-strict-pgp")


def check_assistant_first():
    # Seen from the real claude CLI: the assistant frame arrives before content_block_stop.
    from answer_engine.providers import messages
    state = messages.new_state()
    frames = [
        {"type": "stream_event", "event": {"type": "content_block_start", "index": 0, "content_block": {"type": "tool_use", "id": "t1", "name": "WebSearch"}}},
        {"type": "stream_event", "event": {"type": "content_block_delta", "index": 0, "delta": {"type": "input_json_delta", "partial_json": '{"query":"tide"}'}}},
        {"type": "assistant", "message": {"content": [{"type": "tool_use", "id": "t1", "name": "WebSearch", "input": {"query": "tide"}}]}},
        {"type": "stream_event", "event": {"type": "content_block_stop", "index": 0}},
        {"type": "stream_event", "event": {"type": "content_block_start", "index": 0, "content_block": {"type": "text", "text": ""}}},
        {"type": "stream_event", "event": {"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": "High tide."}}},
        {"type": "assistant", "message": {"content": [{"type": "text", "text": "High tide."}]}},
        {"type": "stream_event", "event": {"type": "content_block_stop", "index": 0}},
    ]
    events = []
    for frame in frames:
        events.extend(messages.parse_obj(frame, state))
    calls = [event for event in events if event["type"] == "tool_call"]
    texts = [event for event in events if event["type"] == "answer"]
    check(len(calls) == 1, "assistant-first tool call duplicated")
    check(len(texts) == 1, "assistant-first text duplicated")
    ok("assistant-frame-first-no-duplicates")


def check_orders():
    claude = run_question("SCENARIO order", "claude")
    check(types_of(claude) == ["thinking", "tool_call", "tool_result", "answer", "done"], "claude order " + brief(claude))
    thinking = claude["events"][0]
    check(thinking["text"] == "I should search." and thinking["kind"] == "", "claude thinking")
    check(thinking.get("model") == "fake-claude", "claude model")
    check(claude["events"][1]["name"] == "WebSearch" and "tide tables" in claude["events"][1]["text"], "claude tool")
    check("noon" in claude["events"][2]["text"], "claude tool result")
    check(claude["answer"] == "High tide is at noon." and claude["provider"] == "claude", "claude answer")
    check(claude["status"] == "done", "claude status")
    ok("claude-event-order")

    codex = run_question("SCENARIO order", "codex")
    check(types_of(codex) == ["thinking", "tool_call", "tool_result", "answer", "done"], "codex order " + brief(codex))
    check(codex["events"][0]["kind"] == "summary", "codex summary kind")
    check(codex["events"][0]["text"] == "**Checking the tide**", "codex summary text")
    check(codex["events"][0].get("model") == "", "codex invented a model")
    check(codex["events"][1]["name"] == "command_execution", "codex tool")
    check("high" in codex["events"][2]["text"], "codex tool result")
    check(codex["answer"] == "The tide is high." and codex["provider"] == "codex", "codex answer")
    check(thinking_notice(codex["events"]) == NOTICE, "summary counted as full thinking")
    check("Reasoning summary" in PAGE, "summary label missing from the page")
    ok("codex-event-order")

    for item in (claude, codex):
        seen = set(types_of(item))
        check({"thinking", "tool_call", "tool_result"}.issubset(seen), "trace types " + brief(item))
    ok("trace-thinking-toolcall-toolresult")


def check_nothinking():
    item = run_question("SCENARIO nothinking", "claude")
    check("thinking" not in types_of(item), "thinking was stored " + brief(item))
    check(thinking_notice(item["events"]) == NOTICE, "notice")
    check(NOTICE in PAGE, "page missing notice")
    check('ev.kind === "summary"' in PAGE, "page missing summary check")
    check("function setText" in PAGE and "el.textContent" in PAGE, "page missing textContent")
    ok("no-thinking-stored")
    ok("no-thinking-page-text")


def check_fallback():
    item = run_question("SCENARIO fallback", "claude,codex")
    switch = "Switching from claude to codex because claude failed: usage limit reached"
    texts = [event["text"] for event in item["events"]]
    check(switch in texts, "switch missing " + brief(item))
    check("usage limit reached" in texts, "failure missing " + brief(item))
    check(texts.index(switch) < texts.index("The second provider answered."), "switch order")
    check(item["provider"] == "codex" and item["status"] == "done", "fallback provider " + brief(item))
    check(item["answer"] == "The second provider answered.", "fallback answer")
    ok("provider-fallback")


def check_secrets():
    sk, ghp, gpat, xai, pem = planted()
    item = run_question("SCENARIO secret", "claude")
    blob = json.dumps(item)
    stored = open(runner.database_path(), "rb").read()
    for secret in (sk, ghp, gpat, xai, pem, *key_headers()):
        check(secret not in blob, "secret returned from storage")
        check(secret.encode("utf-8") not in stored, "secret written in the database file")
    results = [event["text"] for event in item["events"] if event["type"] == "tool_result"]
    check(any("[redacted]" in text for text in results), "redaction marker missing")
    check(item["answer"] == "Stored without secrets.", "secret answer " + brief(item))
    ok("secrets-redacted")


def interpreter_keys():
    # The interpreter can add variables after exec. Measure that on the same
    # allowlist, then the provider child must match it and nothing from the parent.
    proc = subprocess.run(
        ["/usr/bin/env", "python3", "-c", "import json,os; print(json.dumps(sorted(os.environ)))"],
        env=runner.child_env(),
        cwd=os.environ["ANSWER_ENGINE_HOME"],
        capture_output=True,
        text=True,
        timeout=15,
        check=False,
    )
    check(proc.returncode == 0, "could not read a clean interpreter environment")
    return set(json.loads(proc.stdout))


def passed_at_exec():
    proc = subprocess.run(
        ["/usr/bin/env"],
        env=runner.child_env(),
        capture_output=True,
        text=True,
        timeout=10,
        check=False,
    )
    check(proc.returncode == 0, "could not read the environment at exec")
    keys = set()
    for line in proc.stdout.splitlines():
        if "=" in line:
            keys.add(line.split("=", 1)[0])
    return keys


def check_env():
    check(passed_at_exec() == set(runner.child_env()), "process start env is not the allowlist")
    item = run_question("SCENARIO env", "claude")
    try:
        info = json.loads(item["answer"])
    except ValueError:
        fail("env answer was not json " + brief(item))
    expected = runner.child_env()
    baseline = interpreter_keys()
    got = set(info["keys"])
    if got != baseline:
        fail(
            "env keys mismatch extra=%s missing=%s"
            % (",".join(sorted(got - baseline)), ",".join(sorted(baseline - got)))
        )
    check(set(expected).issubset(got), "allowlist missing from the child")
    check(info["path"] == expected["PATH"], "child PATH")
    check(info["home"] == os.environ.get("HOME"), "child HOME")
    check(info["planted"] == "", "planted variable reached the child")
    check("AE_PLANTED_SENTINEL" not in got, "planted name reached the child")
    check("ANSWER_ENGINE_HOME" not in got, "app home reached the child")
    check("ANSWER_ENGINE_CLAUDE_BIN" not in got, "provider path reached the child")
    check(info["base"].startswith("answer-engine-"), "workdir name " + info["base"])
    check(info["listing"] == [], "workdir was not empty")
    check(os.path.abspath(info["cwd"]) != root_dir(), "workdir is the project")
    ok("minimal-env")
    ok("empty-workdir")


def check_timeout():
    os.environ["ANSWER_ENGINE_TIMEOUT_SECONDS"] = "1.2"
    started = time.monotonic()
    try:
        item = run_question("SCENARIO sleep", "claude,codex")
    finally:
        os.environ.pop("ANSWER_ENGINE_TIMEOUT_SECONDS", None)
    elapsed = time.monotonic() - started
    check(item["status"] == "timeout", "timeout status " + brief(item))
    check(item["answer"] == runner.TIMEOUT_TEXT, "timeout answer " + brief(item))
    check(elapsed < 15, "timeout was not killed promptly")
    check(not any((event["text"] or "").startswith("Switching from") for event in item["events"]), "timeout switched")
    check(all(event["provider"] in ("claude", "") for event in item["events"]), "timeout used another provider")
    pids = [event.get("pid") for event in item["events"] if event.get("pid")]
    check(bool(pids), "timeout pid missing")
    check(dead(pids[0]), "timed out process is still alive")
    ok("timeout-killed")


def check_long():
    item = run_question("SCENARIO long", "claude")
    results = [event for event in item["events"] if event["type"] == "tool_result"]
    check(bool(results), "long tool result missing " + brief(item))
    text = results[0]["text"]
    check(len(text) <= 20000, "tool result over the cap")
    check(text.endswith("\n[cut]"), "cut marker missing")
    check("A" * 100 in text, "tool result lost its text")


def check_page(html):
    start = html.find("<details")
    check(start >= 0, "served page has no details")
    end = html.find(">", start)
    tag = html[start : end + 1]
    check(tag == '<details id="trace">', "details tag is " + tag)
    check(html.count("<details") == 1, "details count")
    check("<summary>How it got this answer</summary>" in html, "summary label")
    check("https://" not in html and "http://" not in html, "external url")
    check("<script src" not in html.lower(), "external script")
    check("<link" not in html.lower(), "external link")
    check('rel="stylesheet"' not in html.lower(), "external stylesheet")
    check("innerHTML" not in html, "innerHTML")
    check("insertAdjacentHTML" not in html, "insertAdjacentHTML")
    check("document.write" not in html, "document.write")
    check("textContent" in html, "textContent")
    check("prefers-color-scheme" in html, "dark mode")
    check("color-scheme" in html, "color scheme")
    check("width=device-width" in html, "viewport")
    check("max-width" in html, "phone width")
    check(NOTICE in html, "notice text")
    ok("page-details-closed")
    ok("page-no-external-assets")


def check_http(running):
    port = running.port
    host = "127.0.0.1:%d" % port
    status, payload = http_request(port, "GET", "/", host)
    check(status == 200, "localhost status %s" % status)
    html = payload.decode("utf-8")
    check_page(html)
    ok("server-localhost")
    status, payload = http_request(port, "GET", "/", "127.0.0.1")
    check(status == 200, "bare host status %s" % status)
    status, payload = http_request(port, "GET", "/", "evil.example")
    check(status == 403, "bad host status %s" % status)
    check(b"forbidden" in payload, "bad host body")
    check(b"<details" not in payload, "bad host returned the page")
    ok("server-bad-host")

    holder = {}

    def run_busy():
        try:
            holder["result"] = http_request(
                port,
                "POST",
                "/api/ask",
                host,
                {"question": "SCENARIO busy"},
                timeout=20,
            )
        except Exception as exc:
            holder["error"] = str(exc)

    worker = threading.Thread(target=run_busy)
    worker.start()
    time.sleep(0.3)
    saw = False
    last = None
    deadline = time.time() + 3
    while time.time() < deadline:
        status, payload = http_request(
            port,
            "POST",
            "/api/ask",
            host,
            {"question": "SCENARIO ping"},
            timeout=20,
        )
        last = (status, payload[:120])
        if status == 409 and b"busy" in payload:
            saw = True
            break
        time.sleep(0.05)
    worker.join(10)
    check(saw, "busy not observed %s" % (last,))
    check("error" not in holder, "busy request failed")
    check(holder["result"][0] == 200, "first request status %s" % holder["result"][0])
    ok("server-busy")

    status, payload = http_request(
        port,
        "POST",
        "/api/ask",
        host,
        {"question": "SCENARIO script"},
        timeout=20,
    )
    check(status == 200, "script status %s" % status)
    done = [event for event in sse_events(payload) if event["type"] == "done"]
    check(bool(done) and done[-1].get("question_id"), "script done event")
    question_id = done[-1]["question_id"]
    status, payload = http_request(port, "GET", "/api/questions/%s" % question_id, host)
    item = json.loads(payload.decode("utf-8"))
    check(item["answer"] == script_payload(), "script answer was rewritten")
    status, page = http_request(port, "GET", "/", host)
    check(b"alert(1)" not in page, "page contains the script payload")
    check(b"innerHTML" not in page and b"el.textContent" in page, "rendering path")
    ok("script-shown-as-text")

    status, payload = http_request(
        port,
        "POST",
        "/api/ask",
        host,
        {"question": "SCENARIO fts harbor"},
        timeout=20,
    )
    check(status == 200, "fts ask status %s" % status)
    done = [event for event in sse_events(payload) if event["type"] == "done"]
    check(bool(done), "fts done missing")
    question_id = done[-1]["question_id"]
    running.stop()
    check(running.proc.wait(timeout=3) is not None or running.proc.poll() is not None, "server stayed up")
    again = start_server()
    try:
        status, payload = http_request(
            again.port,
            "GET",
            "/api/search?q=lumenharbor",
            "127.0.0.1:%d" % again.port,
        )
        check(status == 200, "search status %s" % status)
        results = json.loads(payload.decode("utf-8"))["results"]
        check(any(row["id"] == question_id for row in results), "fts missed the answer")
        status, payload = http_request(
            again.port,
            "GET",
            "/api/questions/%s" % question_id,
            "127.0.0.1:%d" % again.port,
        )
        item = json.loads(payload.decode("utf-8"))
        seen = set(types_of(item))
        check({"thinking", "tool_call", "tool_result"}.issubset(seen), "reopened trace " + brief(item))
        check(any(event["text"] == "Searching the harbor." for event in item["events"]), "thinking text")
        check(any(event["type"] == "tool_result" and "harbor chart" in event["text"] for event in item["events"]), "tool text")
        check(item["answer"] == "The note is lumenharbor.", "fts answer")
        ok("fts-search-reopen")

        huge = "uniqcapmarker " + ("x" * 4000)
        check(len(huge) > 4000, "cap fixture")
        status, payload = http_request(
            again.port,
            "POST",
            "/api/ask",
            "127.0.0.1:%d" % again.port,
            {"question": huge},
        )
        check(status == 400 and b"too long" in payload, "question cap %s" % status)
        status, payload = http_request(
            again.port,
            "GET",
            "/api/search?q=uniqcapmarker",
            "127.0.0.1:%d" % again.port,
        )
        check(json.loads(payload.decode("utf-8"))["results"] == [], "overlong question was stored")
        status, payload = http_request(
            again.port,
            "POST",
            "/api/ask",
            "127.0.0.1:%d" % again.port,
            {"question": "   "},
        )
        check(status == 400 and b"empty" in payload, "empty question %s" % status)
    finally:
        again.stop()


def prepare():
    if not os.environ.get("HOME"):
        os.environ["HOME"] = tempfile.mkdtemp(prefix="ae-home-")
    if not os.environ.get("ANSWER_ENGINE_HOME"):
        os.environ["ANSWER_ENGINE_HOME"] = tempfile.mkdtemp(prefix="ae-data-")
    os.makedirs(os.environ["ANSWER_ENGINE_HOME"], exist_ok=True)
    os.environ.pop("ANSWER_ENGINE_TIMEOUT_SECONDS", None)
    os.environ["AE_PLANTED_SENTINEL"] = "planted-sentinel-value"
    fake = os.path.join(os.environ["ANSWER_ENGINE_HOME"], "fake-provider")
    source = FAKE_SOURCE
    compile(source, fake, "exec")
    with open(fake, "w", encoding="utf-8") as handle:
        handle.write(source)
    os.chmod(fake, 0o755)
    os.environ["ANSWER_ENGINE_CLAUDE_BIN"] = fake
    os.environ["ANSWER_ENGINE_CODEX_BIN"] = fake
    os.environ["ANSWER_ENGINE_GROK_BIN"] = fake
    check(os.path.abspath(runner.database_path()).startswith(os.path.abspath(os.environ["ANSWER_ENGINE_HOME"])), "db home")
    check(host_allowed("127.0.0.1") and host_allowed("localhost:8734"), "host allow")
    check(not host_allowed("evil.example"), "host deny")
    check(not host_allowed("[::1]"), "host ipv6")
    check(not host_allowed("user@127.0.0.1"), "host userinfo")
    check(not host_allowed(None) and not host_allowed(""), "host missing")


def check_thread():
    first = run_question("SCENARIO order", "claude")
    use_order("claude")
    second = runner.ask("SCENARIO order", parent_id=first["id"])
    check(second["question"] == "SCENARIO order", "reply stored only the user's words")
    check(second.get("parent_id") == first["id"], "reply points at its parent")
    thread = second.get("thread") or []
    check(len(thread) == 1 and thread[0]["id"] == first["id"], "reply shows the earlier turn")
    prompt = runner.build_prompt("why?", [{"question": "q1", "answer": "a1"}])
    check(prompt.startswith(runner.GROUNDING), "prompt starts with the grounding rule")
    check("User: q1" in prompt and "Assistant: a1" in prompt, "prompt carries earlier turns")
    check(prompt.strip().split("\n")[-1] == "why?", "user's message is last")
    check("web search" in runner.GROUNDING, "grounding asks for a web search")
    check("register by the job" in runner.GROUNDING and "never how well it is backed up" in runner.GROUNDING, "style rules present")
    ok("thread")


def main():
    running = None
    try:
        prepare()
        check_redactor()
        check_commands()
        check_partial_search()
        check_assistant_first()
        check_orders()
        check_nothinking()
        check_fallback()
        check_secrets()
        check_env()
        check_timeout()
        check_long()
        check_thread()
        use_order("claude,codex")
        running = start_server()
        check_http(running)
        ok("selfcheck")
        return 0
    finally:
        if running is not None:
            running.stop()
