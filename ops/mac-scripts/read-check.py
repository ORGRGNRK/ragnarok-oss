#!/usr/bin/env python3
"""read-check -- two of the owner's questions from 2026-11-13, turned into checks so they stop having to ask them.

  "AT WHAT POINT DID YOU DO A FUCKING WEBSEARCH"  (answer mode, Stop hook)
      A reply that calls something standard / mainstream / best practice / "how other people do it"
      with no WebSearch or WebFetch in the same turn is blocked: search now and cite it, or label the
      claim "not checked". That night Claude called a dozen changes "the standard way" and searched
      only after being yelled at.

  "put it in code. look before answering stupid"  (answer mode, Stop hook; 2026-11-14)
      A reply that hands a step back to the owner (account step, needs you, not logged in, no key/access,
      you'll need to...) with no `ragnarok-memory search` and no access check (gh auth status, bw status,
      op, ssh) in the same turn is blocked: look first. That day Claude said GitHub needed him while gh was
      logged in, and pointed at 1Password while memory said where the key was.

  "i bet you didnt even read the whole handoff"  (prompt mode, UserPromptSubmit hook)
      When he says continue / last chat / where we left off, the previous session's transcript path is
      put in front of the model with the rule: read ALL of it (every message) before acting, and say
      how much was read. That night Claude skimmed his lines and one memory note and guessed.

Never blocks the owner. Silent when nothing matches. Log: ~/.claude/read-check.log
  read-check.py            prompt mode
  read-check.py --answer   answer mode
"""
import glob
import json
import os
import re
import sys
import time

LOG = os.path.expanduser("~/.claude/read-check.log")
STANDARD = re.compile(
    r"\b(industry[- ]standard|standard (way|practice|approach|setup|move|tool|pattern)|the standard\b|"
    r"mainstream|best[- ]practice|the usual way|usual (way|setup|pattern)|"
    r"how (other people|everyone|people|most people|teams) (do|run|build|handle)|is standard\b|already standard)",
    re.I)
# "continue"/"keep going" only mean the previous chat at the start of a session; these mean it any time:
EXPLICIT = re.compile(r"\b(last (chat|session|conversation)|previous (chat|session|conversation)|the handoff|where we left off)\b", re.I)
CONTINUE = re.compile(r"\b(continu\w*|contiue|contine|contnue|cotinue|countinue|keep going|pick (it|this) (back )?up)\b", re.I)
SEARCH_TOOLS = {"WebSearch", "WebFetch"}
HANDBACK = re.compile(
    r"\b(account step|(that|this) (part|step|one) (is|waits for) (yours|you)|is yours\b|needs you\b|needs? (you|your) to|"
    r"you(?:'ll| will)? (?:need|have) to|only you can|waits? for you|"
    r"(?:isn't|is not|not) (?:signed|logged) in|i (?:can't|cannot|don't have) (?:access|get|reach|log|sign|create|push|open|read)|"
    r"(?:no|without) (?:access|credentials?|token|api key|permission)\b|"
    r"needs? (?:a |an |your )?(?:[a-z]+ )?(?:key|token|password|permission|login|sign-?in)\b)", re.I)
# A turn "looked" when it ran one of these in Bash: the shared memory, or a real access check.
LOOKED = re.compile(r"ragnarok-memory\s+(search|get|core)|gh auth status|\bbw (status|list|get)|\bop (item|read|whoami|vault)|"
                    r"\bssh\b|security find-|claude auth|tailscale status", re.I)


def log(entry):
    entry["ts"] = time.strftime("%Y-%m-%dT%H:%M:%S")
    try:
        with open(LOG, "a") as f:
            f.write(json.dumps(entry) + "\n")
    except OSError:
        pass


def turn_entries(transcript):
    """Transcript entries since the last real prompt from the owner (not a tool result)."""
    rows = []
    with open(transcript) as f:
        for line in f:
            try:
                rows.append(json.loads(line))
            except ValueError:
                continue
    start = 0
    for i, o in enumerate(rows):
        if o.get("type") == "user" and not o.get("isSidechain") and isinstance(o.get("message", {}).get("content"), str):
            start = i
    return rows[start:]


def answer_mode(inp):
    entry = {"mode": "answer", "session": inp.get("session_id")}
    if inp.get("stop_hook_active"):
        entry["skipped"] = "correction pass"; log(entry); return
    transcript = inp.get("transcript_path") or ""
    try:
        turn = turn_entries(transcript)
    except OSError:
        entry["skipped"] = "no transcript"; log(entry); return
    text, searched, looked = "", False, False
    for o in turn:
        if o.get("type") != "assistant" or o.get("isSidechain"):
            continue
        for b in o.get("message", {}).get("content") or []:
            if not isinstance(b, dict):
                continue
            if b.get("type") == "text":
                text += b.get("text", "") + "\n"
            elif b.get("type") == "tool_use" and b.get("name") in SEARCH_TOOLS:
                searched = True
            elif b.get("type") == "tool_use" and b.get("name") == "Bash" and LOOKED.search(str((b.get("input") or {}).get("command", ""))):
                looked = True
    last = inp.get("last_assistant_message")
    if isinstance(last, str) and last.strip():
        text += last
    hits = sorted({m.group(0).lower() for m in STANDARD.finditer(text)})
    handback = sorted({m.group(0).lower() for m in HANDBACK.finditer(text)})
    entry.update(hits=hits, searched=searched, handback=handback, looked=looked)
    log(entry)
    if handback and not looked:
        print(json.dumps({
            "decision": "block",
            "reason": ("🟦 [HOOK — not Claude] Look check: this reply hands a step back to the owner ("
                       + ", ".join(f'"{h}"' for h in handback[:4]) + ") but nothing was looked up this turn "
                       "(owner, 2026-11-14: \"put it in code. look before answering stupid\"). Before saying it needs him: "
                       "run `ragnarok-memory search \"<the thing>\"` and the real access check (gh auth status, bw status, "
                       "op whoami, ssh), then do it yourself if you can. Only money, accounts he must own, deleting, sending "
                       "outside or a permission denial wait for him. If the words only quote him or a check was already shown "
                       "this turn, reply with only: ✓"),
        }))
        return
    if not hits or searched:
        return
    print(json.dumps({
        "decision": "block",
        "reason": ("🟦 [HOOK — not Claude] Read check: this reply says " + ", ".join(f'"{h}"' for h in hits[:4])
                   + " but there was no WebSearch or WebFetch this turn (owner, 2026-11-13: \"AT WHAT POINT DID YOU DO "
                     "A FUCKING WEBSEARCH\"). Either search now and add the sources, or rewrite those claims as "
                     "\"not checked\". If the words only quote the owner or describe their own setup, reply with only: ✓"),
    }))


def previous_transcript(current):
    folder = os.path.dirname(current) if current else ""
    files = [p for p in glob.glob(os.path.join(folder, "*.jsonl")) if os.path.abspath(p) != os.path.abspath(current or "")]
    files.sort(key=os.path.getmtime, reverse=True)
    return files[0] if files else ""


def prompts_so_far(transcript):
    """Real prompts from the owner in this session (slash-command wrappers and tool results don't count)."""
    n = 0
    try:
        with open(transcript) as f:
            for line in f:
                try:
                    o = json.loads(line)
                except ValueError:
                    continue
                c = o.get("message", {}).get("content")
                if o.get("type") == "user" and not o.get("isSidechain") and isinstance(c, str) and not c.lstrip().startswith("<"):
                    n += 1
    except OSError:
        pass
    return n


def prompt_mode(inp):
    prompt = inp.get("prompt") or ""
    entry = {"mode": "prompt", "session": inp.get("session_id")}
    if not (EXPLICIT.search(prompt) or (CONTINUE.search(prompt) and prompts_so_far(inp.get("transcript_path") or "") <= 1)):
        return
    prev = previous_transcript(inp.get("transcript_path") or "")
    entry["previous"] = prev
    log(entry)
    if not prev:
        return
    size = os.path.getsize(prev)
    print(json.dumps({"hookSpecificOutput": {"hookEventName": "UserPromptSubmit", "additionalContext": (
        "🟦 [HOOK — not Claude] READ CHECK (owner, 2026-11-13: \"i bet you didnt even read the whole handoff\"). "
        f"He is continuing earlier work. Previous session transcript: {prev} ({size // 1024} KB). Before acting or "
        "answering, read ALL of it: every user message and every assistant reply, not a grep, not head/tail, not only "
        "his lines. Then say in one line how much you read. A memory note or recap is not the handoff; the transcript is.")}}))


def main():
    try:
        inp = json.loads(sys.stdin.read())
    except Exception:
        return
    if "--answer" in sys.argv[1:]:
        answer_mode(inp)
    else:
        prompt_mode(inp)


if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        log({"error": f"{type(e).__name__}: {e}"[:300]})
    finally:
        sys.exit(0)
