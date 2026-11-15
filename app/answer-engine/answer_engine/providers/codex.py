"""Codex exec --json adapter.

Event names match the exec JSONL schema: thread.started, turn.started,
turn.completed, turn.failed, item.started, item.updated, item.completed, error.
A reasoning item's text is the summary Codex emits, so it is labelled summary.
"""

import json

from answer_engine.providers.base import Provider
from answer_engine.providers.claude import resolve_bin


def _event(kind, text="", name="", tool_id="", thinking_kind="", interim=False):
    return {
        "type": kind,
        "text": text if isinstance(text, str) else "",
        "name": name or "",
        "tool_id": tool_id or "",
        "kind": thinking_kind or "",
        "interim": bool(interim),
        "model": "",
    }


class CodexProvider(Provider):
    name = "codex"

    def new_state(self):
        return {
            "ok": False,
            "error": "",
            "error_emitted": False,
            "critical": False,
            "model": "",
            "answer": "",
            "started": set(),
        }

    def build_command(self, question, workdir):
        # Feature names passed to --disable are names printed by `codex features list`.
        disabled = (
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
        )
        command = [
            resolve_bin(self.binary),
            "exec",
            "--json",
            "--color",
            "never",
            "--sandbox",
            "read-only",
            "--ignore-user-config",
            "--ignore-rules",
            "--ephemeral",
            "--skip-git-repo-check",
            "-C",
            workdir,
        ]
        for name in disabled:
            command.extend(["--disable", name])
        command.extend(["--", question])
        return command

    def parse_line(self, obj, state):
        if not isinstance(obj, dict):
            return []
        kind = obj.get("type") or ""
        if kind in ("thread.started", "turn.started"):
            return []
        if kind == "turn.completed":
            if not state.get("critical"):
                state["ok"] = True
            return []
        if kind == "turn.failed":
            err = obj.get("error") or {}
            message = err.get("message") if isinstance(err, dict) else "turn failed"
            if not isinstance(message, str) or not message:
                message = "turn failed"
            state["ok"] = False
            state["critical"] = True
            state["error"] = message
            state["error_emitted"] = True
            return [_event("error", text=message)]
        if kind == "error":
            message = obj.get("message") or "error"
            if not isinstance(message, str):
                message = json.dumps(message, ensure_ascii=False)
            state["ok"] = False
            state["critical"] = True
            state["error"] = message
            state["error_emitted"] = True
            return [_event("error", text=message)]
        if kind in ("item.started", "item.updated", "item.completed"):
            item = obj.get("item") or {}
            if not isinstance(item, dict):
                return []
            return self._item(kind, item, state)
        return []

    def _item(self, phase, item, state):
        item_type = item.get("type") or item.get("item_type") or ""
        item_id = str(item.get("id") or "")
        if item_type == "reasoning":
            if phase != "item.completed":
                return []
            text = item.get("text") or ""
            if isinstance(text, list):
                text = "\n".join(part for part in text if isinstance(part, str))
            if not isinstance(text, str) or not text.strip():
                return []
            return [_event("thinking", text=text, thinking_kind="summary")]
        if item_type == "command_execution":
            return self._command(phase, item, state, item_id)
        if item_type == "web_search":
            return self._web_search(phase, item, state, item_id)
        if item_type in ("agent_message", "assistant_message"):
            if phase != "item.completed":
                return []
            text = item.get("text") or ""
            if not isinstance(text, str):
                text = json.dumps(text, ensure_ascii=False)
            if text == "":
                return []
            state["answer"] = text
            return [_event("answer", text=text, interim=False)]
        if item_type == "mcp_tool_call":
            return self._mcp(phase, item, state, item_id)
        if item_type == "error" and phase == "item.completed":
            message = item.get("message") or "error"
            if not isinstance(message, str):
                message = json.dumps(message, ensure_ascii=False)
            return [_event("error", text=message)]
        if phase == "item.completed":
            return [
                _event(
                    "tool_call",
                    text=json.dumps(item, ensure_ascii=False),
                    name=item_type or "item",
                    tool_id=item_id,
                )
            ]
        return []

    def _command(self, phase, item, state, item_id):
        command = item.get("command") or ""
        if not isinstance(command, str):
            command = json.dumps(command, ensure_ascii=False)
        if phase == "item.started":
            state["started"].add(item_id)
            return [_event("tool_call", text=command, name="command_execution", tool_id=item_id)]
        if phase != "item.completed":
            return []
        output = item.get("aggregated_output") or ""
        if not isinstance(output, str):
            output = json.dumps(output, ensure_ascii=False)
        lines = []
        if item.get("exit_code") is not None:
            lines.append("exit_code: %s" % item.get("exit_code"))
        if item.get("status"):
            lines.append("status: %s" % item.get("status"))
        text = output
        if lines:
            if text and not text.endswith("\n"):
                text += "\n"
            text += "\n".join(lines)
        events = []
        if item_id not in state["started"]:
            events.append(_event("tool_call", text=command, name="command_execution", tool_id=item_id))
        events.append(_event("tool_result", text=text, name="command_execution", tool_id=item_id))
        return events

    def _web_search(self, phase, item, state, item_id):
        shown = json.dumps(
            {"query": item.get("query"), "action": item.get("action")},
            ensure_ascii=False,
        )
        if phase == "item.started":
            state["started"].add(item_id)
            return [_event("tool_call", text=shown, name="web_search", tool_id=item_id)]
        if phase != "item.completed":
            return []
        output = json.dumps(
            {
                "query": item.get("query"),
                "action": item.get("action"),
                "results": item.get("results"),
            },
            ensure_ascii=False,
        )
        events = []
        if item_id not in state["started"]:
            events.append(_event("tool_call", text=shown, name="web_search", tool_id=item_id))
        events.append(_event("tool_result", text=output, name="web_search", tool_id=item_id))
        return events

    def _mcp(self, phase, item, state, item_id):
        name = "/".join(part for part in (item.get("server") or "", item.get("tool") or "") if part)
        if not name:
            name = "mcp_tool_call"
        arguments = item.get("arguments")
        text = arguments if isinstance(arguments, str) else json.dumps(arguments, ensure_ascii=False)
        if phase == "item.started":
            state["started"].add(item_id)
            return [_event("tool_call", text=text, name=name, tool_id=item_id)]
        if phase != "item.completed":
            return []
        output = json.dumps(
            {"result": item.get("result"), "error": item.get("error"), "status": item.get("status")},
            ensure_ascii=False,
        )
        events = []
        if item_id not in state["started"]:
            events.append(_event("tool_call", text=text, name=name, tool_id=item_id))
        events.append(_event("tool_result", text=output, name=name, tool_id=item_id))
        return events
