"""Parse a Messages-style stream-json line.

Claude's `--output-format stream-json` and Grok's `streaming-messages-json`
both use this shape: system/init, assistant content blocks, user tool results,
optional stream_event deltas, and a terminal result. Only text the process
actually emitted is turned into events. A redacted thinking block is skipped.
"""

import json


def new_state():
    return {
        "ok": False,
        "error": "",
        "error_emitted": False,
        "critical": False,
        "model": "",
        "answer": "",
        "blocks": {},
        "skip_assistant": False,
        "seen": {},
        "tools": {},
    }


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


def _tool_text(content):
    if content is None:
        return ""
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        texts = []
        other = False
        for item in content:
            if isinstance(item, dict) and item.get("type") == "text" and isinstance(item.get("text"), str):
                texts.append(item["text"])
            else:
                other = True
                break
        if texts and not other:
            return "\n".join(texts)
    return json.dumps(content, ensure_ascii=False)


def _input_text(block):
    if block.get("input_json"):
        return block.get("input_json") or ""
    raw = block.get("input")
    if isinstance(raw, str):
        return raw
    if raw is None:
        return ""
    return json.dumps(raw, ensure_ascii=False, sort_keys=True)


def content_events(block, state):
    if not isinstance(block, dict):
        return []
    block_type = block.get("type") or ""
    if block_type == "thinking":
        text = block.get("thinking") or ""
        if not isinstance(text, str) or not text.strip():
            return []
        return [_event("thinking", text=text, thinking_kind="")]
    if block_type == "redacted_thinking":
        return []
    if block_type == "text":
        text = block.get("text") or ""
        if not isinstance(text, str) or text == "":
            return []
        return [_event("answer", text=text, interim=True)]
    if block_type in ("tool_use", "server_tool_use", "mcp_tool_use"):
        name = block.get("name") or ""
        tool_id = block.get("id") or ""
        if tool_id:
            state["tools"][tool_id] = name
        return [_event("tool_call", text=_input_text(block), name=name, tool_id=tool_id)]
    if block_type in ("tool_result", "web_search_tool_result", "web_fetch_tool_result"):
        tool_id = block.get("tool_use_id") or block.get("id") or ""
        name = state["tools"].get(tool_id) or block.get("name") or ""
        return [_event("tool_result", text=_tool_text(block.get("content")), name=name, tool_id=tool_id)]
    return []


def _from_accumulated(block, state):
    normalized = {
        "type": block.get("type"),
        "thinking": block.get("thinking") or "",
        "text": block.get("text") or "",
        "name": block.get("name") or "",
        "id": block.get("id") or "",
        "tool_use_id": block.get("tool_use_id") or "",
        "content": block.get("content"),
        "input_json": block.get("input_json") or "",
        "input": block.get("input"),
    }
    return content_events(normalized, state)


def _fingerprint(event):
    kind = event.get("type") or ""
    tool_id = event.get("tool_id") or ""
    text = event.get("text") or ""
    if kind == "tool_call" and tool_id:
        return (kind, tool_id)
    if kind == "tool_result":
        return (kind, tool_id, text)
    if kind == "thinking":
        return (kind, text)
    if kind == "answer":
        return (kind, bool(event.get("interim")), text)
    return (kind, tool_id, event.get("name") or "", text)


def _remember(state, events, key="seen"):
    seen = state.setdefault(key, {})
    for event in events:
        mark = _fingerprint(event)
        seen[mark] = seen.get(mark, 0) + 1


def _unseen(state, events, key="seen"):
    # Partials already recorded these blocks. The flushed assistant frame
    # still carries blocks the partial stream never sent, including the
    # web search hit list, which arrives on that frame rather than as a delta.
    # The real CLI can also send the assistant frame first, so this runs both ways.
    seen = state.get(key) or {}
    kept = []
    for event in events:
        mark = _fingerprint(event)
        count = seen.get(mark, 0)
        if count:
            seen[mark] = count - 1
            continue
        kept.append(event)
    return kept


def _stream_event(event, state):
    if not isinstance(event, dict):
        return []
    event_type = event.get("type") or ""
    if event_type == "message_start":
        message = event.get("message") or {}
        if isinstance(message, dict) and message.get("model"):
            state["model"] = message["model"]
        return []
    if event_type == "content_block_start":
        block = event.get("content_block") or {}
        if not isinstance(block, dict):
            return []
        index = event.get("index", 0)
        state["blocks"][index] = {
            "type": block.get("type"),
            "thinking": block.get("thinking") or "",
            "text": block.get("text") or "",
            "name": block.get("name") or "",
            "id": block.get("id") or "",
            "tool_use_id": block.get("tool_use_id") or "",
            "content": block.get("content"),
            "input": block.get("input") if isinstance(block.get("input"), (dict, list)) else None,
            "input_json": "",
        }
        return []
    if event_type == "content_block_delta":
        index = event.get("index", 0)
        block = state["blocks"].get(index)
        delta = event.get("delta") or {}
        if block is None or not isinstance(delta, dict):
            return []
        delta_type = delta.get("type") or ""
        if delta_type == "thinking_delta":
            block["thinking"] += delta.get("thinking") or ""
        elif delta_type == "text_delta":
            block["text"] += delta.get("text") or ""
        elif delta_type == "input_json_delta":
            block["input_json"] += delta.get("partial_json") or ""
        return []
    if event_type == "content_block_stop":
        index = event.get("index", 0)
        block = state["blocks"].pop(index, None)
        if block is None:
            return []
        events = _unseen(state, _from_accumulated(block, state), key="seen_assistant")
        if events:
            state["skip_assistant"] = True
            _remember(state, events)
        return events
    return []


def _assistant(obj, state):
    skipping = bool(state.get("skip_assistant"))
    state["skip_assistant"] = False
    message = obj.get("message") or {}
    if not isinstance(message, dict):
        return []
    if message.get("model"):
        state["model"] = message["model"]
    content = message.get("content")
    events = []
    if isinstance(content, list):
        for block in content:
            events.extend(content_events(block, state))
    elif isinstance(content, str) and content:
        events.append(_event("answer", text=content, interim=True))
    if skipping:
        return _unseen(state, events)
    _remember(state, events, key="seen_assistant")
    return events


def _user(obj, state):
    message = obj.get("message") or {}
    if not isinstance(message, dict):
        return []
    content = message.get("content")
    events = []
    if isinstance(content, list):
        for block in content:
            events.extend(content_events(block, state))
    return events


def _result(obj, state):
    subtype = str(obj.get("subtype") or "")
    is_error = bool(obj.get("is_error")) or subtype.startswith("error")
    if is_error:
        message = obj.get("result") or subtype or "provider error"
        if not isinstance(message, str):
            message = json.dumps(message, ensure_ascii=False)
        state["ok"] = False
        state["critical"] = True
        state["error"] = message
        state["error_emitted"] = True
        return [_event("error", text=message)]
    text = obj.get("result") or ""
    if not isinstance(text, str):
        text = json.dumps(text, ensure_ascii=False)
    state["ok"] = True
    state["answer"] = text
    if text:
        return [_event("answer", text=text, interim=False)]
    return []


def parse_obj(obj, state):
    if not isinstance(obj, dict):
        return []
    kind = obj.get("type") or ""
    if kind == "system":
        if obj.get("subtype") == "init" and obj.get("model"):
            state["model"] = obj["model"]
        return []
    if kind == "stream_event":
        return _stream_event(obj.get("event") or {}, state)
    if kind == "assistant":
        return _assistant(obj, state)
    if kind == "user":
        return _user(obj, state)
    if kind == "result":
        return _result(obj, state)
    return []
