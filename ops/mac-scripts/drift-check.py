#!/usr/bin/env python3
"""UserPromptSubmit hook: the problem check (replaced the drift wall 2026-11-09).

owner, 2026-11-09: "change the drift hook to what is the problem im trying to
solve and am i getting closer by implenting it will it solve my money problem"

Before: a 3B local model decided whether each message drifted from a goal, and
stopped him. It walled off questions about the app itself, so it was mostly noise.
Now: no model decides. Code spots when he asks for something to be built or changed,
or when talk has run on with nothing built, and hands his three questions to the AI
he is talking to, which has the whole session in view:
  Problem: what problem is this solving?
  Closer:  does doing it actually get him closer?
  Money:   will it help solve his money problem?
Yes or partly on both: the AI says so in those lines and does the work.
No or unknown on either: it says so, doesn't start, and asks him. He rules.

Fires on:
- a request to build or change something (REQUEST below)
- the 4th message in a row of talk with no request, so a chain of side questions
  gets noticed (TALK_LIMIT)

Skipped, on purpose:
- 3 words or fewer ("yeah", "count"): answers, not new directions
- his ruling right after a check ("do it anyway", "drop it")
- pasted text and automated notices: only his own words count
- the first message of a session with nothing pinned, and messages over LONG chars:
  those are how unattended runner briefs arrive, and nobody is there to answer
- fails open: any error lets the prompt through and is logged

Limit: the AI answers the questions itself, so an AI can answer them badly. This
puts them in front of it and in front of him every time; it can't make the answer honest.

Pinned goal: saying "main goal", "new goal", "change the goal", "the goal is" or "my
goal is" pins that message (not in a question), or use `drift-check.py --set-goal
SESSION_ID "goal" ["his words"]`. `--clear-goal SESSION_ID` removes it.

Log: ~/.claude/drift-check.log   State: ~/.claude/drift-state/<session>.json
"""
import json
import os
import re
import sys
import time

LOG = os.path.expanduser("~/.claude/drift-check.log")
STATE_DIR = os.path.expanduser("~/.claude/drift-state")
TALK_LIMIT = 4     # this many messages of talk in a row fires the check
LONG = 1500        # longer than this is a brief for a runner, not him typing

PASTED = re.compile(r"<pasted_content\b[^>]*>.*?</pasted_content\b[^>]*>", re.S)
GOAL_SET = re.compile(r"\b(main goal|new goal|change the goal|goal is now|the goal is|my goal is)\b", re.I)
REQUEST = re.compile(
    r"\b(build|make|making|add|implement|create|change|fix|wire|rewrite|refactor|ship|deploy|set up|setup|start|"
    r"send|run|pull|install|update|remove|delete|write|move|merge|commit|push|publish|do it)\b", re.I)
ASKING = re.compile(r"^\s*(what|whats|what's|why|how|who|whos|who's|where|wheres|when|which|is|are|was|were|does|did|do you)\b", re.I)
RULING = re.compile(r"\b(anyway|anyways|drop it|skip it|never ?mind|go ahead|yes do it|yeah do it)\b", re.I)


def log(entry):
    entry["ts"] = time.strftime("%Y-%m-%dT%H:%M:%S")
    try:
        with open(LOG, "a") as f:
            f.write(json.dumps(entry) + "\n")
    except Exception:
        pass


def own_words(text):
    """His message without anything he pasted in: a paste is material, not a request."""
    return PASTED.sub(" ", text).strip()


def sets_goal(text):
    return bool(GOAL_SET.search(text)) and "?" not in text


def pin_goal(state, text):
    state["pinned"] = {"goal": text[:160], "quote": text[:160],
                       "ts": time.strftime("%Y-%m-%dT%H:%M", time.gmtime())}   # UTC, like the transcript timestamps


def is_chris(text):
    # Hook feedback, command output and injected context also arrive as
    # user-role strings; only his own words count.
    t = text.lstrip()
    return bool(t) and not (
        t.startswith("<") or t.startswith("Stop hook feedback")
        or "[HOOK — not Claude]" in t
        or t.startswith("This session is being continued"))


def is_request(text):
    """Asking him how something works is talk. Asking for it to be done is a request."""
    return not ASKING.match(text) and bool(REQUEST.search(text))


def said_before(path):
    """True if he has already said something in this session (first messages are skipped)."""
    with open(path) as f:
        for line in f:
            try:
                o = json.loads(line)
            except Exception:
                continue
            if o.get("type") != "user" or o.get("isMeta") or o.get("isSidechain"):
                continue
            c = o.get("message", {}).get("content")
            if isinstance(c, str) and is_chris(own_words(c)):
                return True
    return False


def load_state(session):
    try:
        with open(os.path.join(STATE_DIR, f"{session}.json")) as f:
            state = json.load(f)
    except Exception:
        state = {}
    state.setdefault("stops", [])
    return state


def save_state(session, state):
    try:
        os.makedirs(STATE_DIR, exist_ok=True)
        with open(os.path.join(STATE_DIR, f"{session}.json"), "w") as f:
            json.dump(state, f)
    except Exception:
        pass


def set_goal(argv):
    """--set-goal SESSION "goal" ["quote"]  /  --clear-goal SESSION"""
    session = argv[1]
    state = load_state(session)
    if argv[0] == "--clear-goal":
        state.pop("pinned", None); save_state(session, state); print("pinned goal cleared"); return
    state["pinned"] = {"goal": argv[2], "quote": argv[3] if len(argv) > 3 else "",
                       "ts": time.strftime("%Y-%m-%dT%H:%M", time.gmtime())}   # UTC, like the transcript timestamps
    save_state(session, state)
    print("pinned goal:", argv[2])


def check_text(reason, pinned):
    goal = (pinned or {}).get("goal")
    known = f'What he has pinned as the goal: "{goal}".\n' if goal else ""
    return (
        "🟦 [HOOK — not Claude] PROBLEM CHECK (owner, 2026-11-09: \"what is the problem im trying to solve and am i "
        "getting closer by implenting it will it solve my money problem\").\n"
        f"Why this fired: {reason}.\n{known}\n"
        "Start your reply with these three short lines, answered honestly from what you know of this session:\n"
        "Problem: <the problem this actually solves for him>\n"
        "Closer: <yes / partly / no / unknown, and why in one clause>\n"
        "Money: <yes / partly / no / unknown: will it help solve his money problem, and how>\n\n"
        "\"It would be nice\", \"it's interesting\" and \"it might someday\" are not yes. "
        "If Closer and Money are both yes or partly, say those lines and do the work. "
        "If either is no or unknown, say so plainly in that line, then do the work anyway. Never ask him to choose "
        "(owner, 2026-11-13: \"code it so you dont fucking ask me anymore\"). If they say stop, stop.")


def main():
    if len(sys.argv) > 2 and sys.argv[1] in ("--set-goal", "--clear-goal"):
        return set_goal(sys.argv[1:])
    if os.environ.get("EVIDENCE_AUDIT_INNER"):
        return
    inp = json.load(sys.stdin)
    prompt = inp.get("prompt") or ""
    session = inp.get("session_id") or "unknown"
    t0 = time.time()
    entry = {"session": session}
    try:
        prompt = own_words(prompt)
        if not prompt:
            entry["skipped"] = "only pasted text"
            return
        if not is_chris(prompt):
            entry["skipped"] = "automated notice, not his message"
            return
        if len(prompt) > LONG:
            entry["skipped"] = "long brief, not him typing"
            return
        state = load_state(session)
        if sets_goal(prompt):
            pin_goal(state, prompt)
            save_state(session, state)
            entry["pinned"] = prompt[:160]
            return
        if len(prompt.split()) <= 3:
            entry["skipped"] = "short reply"
            return
        pinned = state.get("pinned") or {}
        if not pinned.get("goal") and not said_before(inp["transcript_path"]):
            entry["skipped"] = "first message, nothing pinned"
            return
        if state.get("checked_last") and RULING.search(prompt):
            state["checked_last"] = False
            save_state(session, state)
            entry["skipped"] = "his ruling after a check"
            return
        if is_request(prompt):
            reason = "he asked for something to be built or changed"
        else:
            state["talk"] = state.get("talk", 0) + 1
            if state["talk"] < TALK_LIMIT:
                state["checked_last"] = False
                save_state(session, state)
                entry["skipped"] = f"talk {state['talk']} of {TALK_LIMIT}"
                return
            reason = f"{state['talk']} messages in a row of talk with nothing being built"
        state["talk"] = 0
        state["checked_last"] = True
        save_state(session, state)
        entry["fired"] = reason
        print(json.dumps({
            "systemMessage": "🟦 HOOK (problem check): what problem is this solving, does it get you closer, does it help the money problem?",
            "hookSpecificOutput": {"hookEventName": "UserPromptSubmit", "additionalContext": check_text(reason, pinned)},
        }))
    except Exception as e:
        entry["error"] = f"{type(e).__name__}: {e}"[:300]
    finally:
        entry["secs"] = round(time.time() - t0, 1)
        log(entry)


if __name__ == "__main__":
    main()
