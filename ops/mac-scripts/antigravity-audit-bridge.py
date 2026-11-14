#!/usr/bin/env python3
"""Antigravity Stop Hook: Local Tailscale Evidence Referee (Gjallarhorn).

Audits the model's final response against the turn's tool evidence (plus earlier
turns and compacted <CONTEXT_SUMMARY> across multi-turn back-and-forths) using
an on-site Ollama model on Alexus over LAN/Tailscale (alexus / alexus).
Fails open on connection timeout or network errors.
"""
import json
import os
import re
import sys
import time
import urllib.request

ALEXUS_TAILSCALE = "http://alexus:11434"
ALEXUS_LAN = "http://alexus:11434"
MODEL = os.environ.get("GJALLARHORN_MODEL", "qwen2.5-coder:3b")
TIMEOUT_SECS = 15
AUDIT_LOG = os.path.expanduser("~/.ragnarok/gjallarhorn-audit.jsonl")

SHORT_ANSWER_BOUND = 150
ACK_PATTERN = re.compile(r"^\W*(✓|ok(ay)?|done|got it|yes|no|right on|👍)\W*$", re.I)
FALSE_FLAG_RE = re.compile(
    r"\bno evidence (is )?needed\b|\bnot a (checkable |factual )+claim\b|"
    r"\bnot a factual claim\b|\bnot flagged\b|\bacceptable\.?\s*$|"
    r"^\s*supported\b|(?<!not )\bsupported( by (the )?evidence)?\.?\s*$",
    re.I,
)

AUDITOR_SYSTEM = """You are an auditor verifying an AI assistant's answers against evidence.
Compare the claims in the assistant's answer against the tool outputs and conversation facts.
Tool inputs (file edits, writes, commands run) and earlier-turn tool outputs or context summaries count as valid evidence.
NEVER flag opinions, metaphors, mythology, jokes, greetings, advice, future plans, questions, or general conversation.
NEVER list claims that ARE supported by the evidence.
Be very conservative. If unsure, do not flag.

If everything in the answer is supported by the evidence, reply ONLY with:
{"all_supported": true, "unsupported": []}

If and ONLY if the answer makes a false factual claim about specific code, local files, commands, or technical infrastructure that is NOT backed by the evidence, reply ONLY with:
{
  "all_supported": false,
  "unsupported": [
    {"claim": "<short quote from answer>", "why": "<why the evidence does not support it>"}
  ]
}
"""


def log_audit(entry):
    entry.setdefault("ts", time.strftime("%Y-%m-%dT%H:%M:%S"))
    try:
        os.makedirs(os.path.dirname(AUDIT_LOG), exist_ok=True)
        with open(AUDIT_LOG, "a", encoding="utf-8") as f:
            f.write(json.dumps(entry, ensure_ascii=False) + "\n")
    except Exception:
        pass


def configured_ollama_candidates():
    cands = []
    env_url = os.environ.get("OLLAMA_URL", "").strip()
    if env_url:
        cands.append(env_url.rstrip("/"))
    conf = os.environ.get("RAGNAROK_LOCAL_CONF") or os.path.expanduser("~/.ragnarok/local.conf")
    if os.path.isfile(conf):
        vals = {}
        try:
            with open(conf, "r", encoding="utf-8") as f:
                for line in f:
                    line = line.strip()
                    if line and not line.startswith("#") and "=" in line:
                        k, v = line.split("=", 1)
                        vals[k.strip()] = v.strip().strip("\"'")
        except Exception:
            pass
        if vals.get("OLLAMA_URL"):
            cands.append(vals["OLLAMA_URL"].rstrip("/"))
        if vals.get("ALEXUS_HOST"):
            cands.append(f"http://{vals['ALEXUS_HOST']}:11434")
        if vals.get("ALEXUS_TAILSCALE"):
            cands.append(f"http://{vals['ALEXUS_TAILSCALE']}:11434")
    for base in (ALEXUS_LAN, ALEXUS_TAILSCALE):
        if base not in cands:
            cands.append(base)
    return cands


def get_ollama_url():
    for base in configured_ollama_candidates():
        try:
            req = urllib.request.Request(f"{base}/api/tags", headers={"User-Agent": "Gjallarhorn-Referee"})
            with urllib.request.urlopen(req, timeout=1.5) as r:
                if r.status == 200:
                    return base
        except Exception:
            continue
    return None


def filter_unsupported(items, all_supported=False):
    if all_supported is True:
        return []
    out = []
    neg_cue = re.compile(
        r"\b(not|no\b|never|absent|missing|contradict|false|unsupported|unverified|doesn['’]t|does not|did not|didn['’]t|without|lack|fail|wrong|different|instead)\b",
        re.I,
    )
    for u in items or []:
        if not isinstance(u, dict):
            continue
        if u.get("supported") is True:
            continue
        claim = str(u.get("claim") or "").strip()
        why = str(u.get("why") or "").strip()
        if not claim or FALSE_FLAG_RE.search(why):
            continue
        if why and not neg_cue.search(why):
            continue
        out.append({"claim": claim, "why": why})
    return out


def query_auditor(ollama_base, evidence_text, answer_text, system_prompt=AUDITOR_SYSTEM, model=None):
    prompt = f"{system_prompt}\n\nEVIDENCE:\n{evidence_text}\n\nANSWER TO AUDIT:\n{answer_text}\n\nJSON output:"
    payload = {
        "model": model or MODEL,
        "prompt": prompt,
        "stream": False,
        "format": "json",
        "keep_alive": "30m",
        "options": {"temperature": 0},
    }
    req = urllib.request.Request(
        f"{ollama_base}/api/generate",
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=TIMEOUT_SECS) as resp:
        body = json.loads(resp.read().decode("utf-8"))
        raw = body.get("response", "{}")
        parsed = json.loads(raw)
        if isinstance(parsed, dict) and "unsupported" in parsed:
            parsed["unsupported"] = filter_unsupported(
                parsed.get("unsupported"),
                all_supported=parsed.get("all_supported", False),
            )
        return parsed


def resolve_transcript_file(transcript_path):
    """Prefer transcript_full.jsonl over compact transcript.jsonl so steps >4KB aren't truncated."""
    if not transcript_path:
        return ""
    if transcript_path.endswith("transcript.jsonl"):
        full_candidate = os.path.join(os.path.dirname(transcript_path), "transcript_full.jsonl")
        if os.path.isfile(full_candidate):
            return full_candidate
    return transcript_path


def _summarize_step_tools(item, max_chars=4000):
    """Extract tool call inputs and tool/system outputs from a single transcript step."""
    chunks = []
    stype = item.get("type")
    source = item.get("source")
    content = item.get("content", "")

    for tc in item.get("tool_calls") or []:
        if isinstance(tc, dict):
            tname = tc.get("name") or tc.get("tool") or "tool"
            targs = tc.get("arguments") or tc.get("input") or {}
            if not isinstance(targs, str):
                try:
                    targs = json.dumps(targs, ensure_ascii=False)
                except Exception:
                    targs = str(targs)
            chunks.append(f"[tool_call {tname}] {targs[:1500]}")

    if stype in ("GENERIC", "TOOL_OUTPUT") and content:
        chunks.append(str(content)[:max_chars])
    elif stype == "SYSTEM_MESSAGE" and content and "[Alexus Local Referee]" not in str(content):
        # Async background command completions (WaitMsBeforeAsync) arrive as SYSTEM_MESSAGE
        chunks.append(str(content)[:max_chars])
    elif stype not in ("PLANNER_RESPONSE", "USER_INPUT") and "output" in str(content) and content:
        chunks.append(str(content)[:max_chars])
    return chunks


def extract_last_turn_meta(transcript_path):
    actual_path = resolve_transcript_file(transcript_path)
    if not actual_path or not os.path.isfile(actual_path):
        return "", "", {"already_audited": False, "turn_tools": 0, "earlier_tools": 0, "path": actual_path}

    last_user_prompt = ""
    last_assistant_answer = ""
    turn_evidence = []
    earlier_evidence = []
    user_history = []
    context_summaries = []
    already_audited = False

    try:
        with open(actual_path, "r", encoding="utf-8") as f:
            lines = []
            for raw_line in f:
                if raw_line.strip():
                    try:
                        lines.append(json.loads(raw_line))
                    except Exception:
                        continue

        turn_start_idx = -1
        for idx in range(len(lines) - 1, -1, -1):
            if lines[idx].get("source") == "USER_EXPLICIT" and lines[idx].get("type") == "USER_INPUT":
                turn_start_idx = idx
                last_user_prompt = str(lines[idx].get("content", ""))
                break

        if turn_start_idx == -1:
            return "", "", {"already_audited": False, "turn_tools": 0, "earlier_tools": 0, "path": actual_path}

        # 1. Current turn evidence & assistant answer
        all_turn_chunks = []
        for item in lines[turn_start_idx + 1:]:
            stype = item.get("type")
            source = item.get("source")
            content = str(item.get("content", "") or "")
            if stype == "SYSTEM_MESSAGE" and "[Alexus Local Referee]" in content:
                already_audited = True
            if stype == "PLANNER_RESPONSE" and source == "MODEL" and content:
                last_assistant_answer = content
            all_turn_chunks.extend(_summarize_step_tools(item, max_chars=3500))

        # Keep the newest turn tool chunks within a 16,000-char budget so long turns
        # never truncate the latest tool outputs or earlier multi-turn context.
        turn_chars = 0
        for chunk in reversed(all_turn_chunks):
            turn_evidence.append(chunk)
            turn_chars += len(chunk)
            if turn_chars >= 16000:
                break
        turn_evidence.reverse()

        # 2. Earlier turns across multi-turn back-and-forths (walk newest-first up to budget)
        earlier_chars = 0
        for item in reversed(lines[:turn_start_idx + 1]):
            stype = item.get("type")
            source = item.get("source")
            content = str(item.get("content", "") or "")
            if stype == "USER_INPUT" and content:
                if "<CONTEXT_SUMMARY>" in content and len(context_summaries) < 2:
                    context_summaries.append(content[:3500])
                elif source == "USER_EXPLICIT" and len(user_history) < 8:
                    user_history.append(content[:400])
                continue
            if earlier_chars < 7500:
                for chunk in reversed(_summarize_step_tools(item, max_chars=1800)):
                    earlier_evidence.append(chunk)
                    earlier_chars += len(chunk)
                    if earlier_chars >= 7500:
                        break
    except Exception:
        pass

    earlier_evidence.reverse()
    user_history.reverse()

    parts = [f"Current user request:\n{last_user_prompt[:1200]}"]
    if len(user_history) > 1:
        parts.append("Recent user messages in this session:\n" + "\n---\n".join(user_history[:-1]))
    if context_summaries:
        parts.append("Compacted session context summary:\n" + "\n".join(context_summaries))
    if turn_evidence:
        parts.append("Current turn tool calls & outputs:\n" + "\n---\n".join(turn_evidence))
    if earlier_evidence:
        parts.append("Earlier turns tool calls & outputs (multi-turn context):\n" + "\n---\n".join(earlier_evidence))

    evidence_summary = "\n\n".join(parts)
    meta = {
        "already_audited": already_audited,
        "turn_tools": len(turn_evidence),
        "earlier_tools": len(earlier_evidence),
        "path": actual_path,
    }
    return evidence_summary[:28000], last_assistant_answer, meta


def extract_last_turn(transcript_path):
    ev, ans, _ = extract_last_turn_meta(transcript_path)
    return ev, ans


def main():
    t0 = time.time()
    try:
        raw_input = sys.stdin.read()
        if not raw_input.strip():
            print(json.dumps({"decision": "ok"}))
            return
        payload = json.loads(raw_input)
    except Exception:
        print(json.dumps({"decision": "ok"}))
        return

    transcript_path = payload.get("transcriptPath")
    conv_id = payload.get("conversationId") or payload.get("session_id")
    model_name = payload.get("modelName")
    if not transcript_path or not os.path.isfile(transcript_path):
        print(json.dumps({"decision": "ok"}))
        return

    evidence, answer, meta = extract_last_turn_meta(transcript_path)
    entry = {
        "source": "antigravity",
        "session": conv_id,
        "agent_model": model_name,
        "referee_model": MODEL,
        "turn_tools": meta.get("turn_tools", 0),
        "earlier_tools": meta.get("earlier_tools", 0),
    }

    if meta.get("already_audited"):
        entry["skipped"] = "already_audited_this_turn"
        entry["secs"] = round(time.time() - t0, 2)
        log_audit(entry)
        print(json.dumps({"decision": "ok"}))
        return

    clean_ans = answer.strip()
    if len(clean_ans) < SHORT_ANSWER_BOUND or ACK_PATTERN.match(clean_ans):
        entry["skipped"] = f"short_answer ({len(clean_ans)} chars)"
        entry["secs"] = round(time.time() - t0, 2)
        log_audit(entry)
        print(json.dumps({"decision": "ok"}))
        return

    if meta.get("turn_tools", 0) == 0 and meta.get("earlier_tools", 0) == 0:
        entry["skipped"] = "no_tool_evidence"
        entry["secs"] = round(time.time() - t0, 2)
        log_audit(entry)
        print(json.dumps({"decision": "ok"}))
        return

    ollama_url = get_ollama_url()
    if not ollama_url:
        entry["skipped"] = "ollama_offline"
        entry["secs"] = round(time.time() - t0, 2)
        log_audit(entry)
        print(json.dumps({"decision": "ok"}))
        return

    try:
        audit_res = query_auditor(ollama_url, evidence, clean_ans)
        unsupported = filter_unsupported(audit_res.get("unsupported", []))
        entry["flags"] = unsupported
        entry["ollama_url"] = ollama_url

        if unsupported:
            lines = "\n".join(f"- \"{u.get('claim', '')}\": {u.get('why', '')}" for u in unsupported if u.get("claim"))
            if lines:
                entry["decision"] = "continue"
                entry["secs"] = round(time.time() - t0, 2)
                log_audit(entry)
                print(json.dumps({
                    "decision": "continue",
                    "reason": (
                        "📯 [Alexus Local Referee] Evidence audit flagged claims unsupported by tool output:\n"
                        f"{lines}\n\n"
                        "Verify each claim with a tool, or clearly label it as unverified inference."
                    ),
                }))
                return
    except Exception as e:
        entry["error"] = f"{type(e).__name__}: {e}"[:200]

    entry["decision"] = "ok"
    entry["secs"] = round(time.time() - t0, 2)
    log_audit(entry)
    print(json.dumps({"decision": "ok"}))


if __name__ == "__main__":
    main()
