#!/usr/bin/env python3
"""read-first -- PreToolUse hook. Owner, 2026-11-14: "you need to read first ... make a hook so you read it then
when the hook comes back then you would have ran it already."

That day Claude built a bounty step that called Grok first, without reading the debug-pipeline README that says
local Ollama goes first and Grok is only the fallback. Reading was a rule in prose; this puts it in the path.

The first time in a session that the AI changes or runs something inside a project (Edit/Write on a file there, or
a Bash command that names a path there or runs from there), the call is refused ONCE and the project's README
(nearest README.md walking up, inside ~/Developer) comes back in the refusal. The AI reads it, checks its plan,
and makes the same call again; this time it goes through. Reading a README with the Read tool counts as read.

Read-only commands (ls, cat, head, grep, sed -n, git status/log/diff/show, ...) are never refused. Never blocks
on its own error (exit 0). State: ~/.claude/read-first/<session>.json   Log: ~/.claude/read-first.log
"""
import json
import os
import re
import shlex
import sys
import time

HOME = os.path.expanduser("~")
ROOT = os.path.join(HOME, "Developer")
STATE_DIR = os.path.join(HOME, ".claude", "read-first")
LOG = os.path.join(HOME, ".claude", "read-first.log")
MAX_CHARS = 9000
READ_ONLY = {
    "ls", "cat", "head", "tail", "less", "wc", "grep", "rg", "ugrep", "find", "file", "stat", "du", "df", "pwd",
    "echo", "printf", "which", "type", "tree", "diff", "jq", "date", "true", "test", "[", "basename", "dirname",
    "realpath", "readlink", "sort", "uniq", "cut", "tr", "column", "nl", "awk", "ragnarok-memory", "env",
}
GIT_READ = {"status", "log", "diff", "show", "branch", "remote", "rev-parse", "ls-files", "blame", "grep"}


def log(msg):
    try:
        with open(LOG, "a") as f:
            f.write(time.strftime("%Y-%m-%d %H:%M:%S ") + msg + "\n")
    except OSError:
        pass


def readme_for(path):
    """Nearest README.md at or above path, but never above ~/Developer/<repo> (the repo root counts)."""
    path = os.path.realpath(os.path.expanduser(path))
    if not path.startswith(ROOT + os.sep):
        return None
    d = path if os.path.isdir(path) else os.path.dirname(path)
    while d.startswith(ROOT + os.sep):
        p = os.path.join(d, "README.md")
        if os.path.isfile(p):
            return p
        d = os.path.dirname(d)
    return None


def segments(cmd):
    return [s.strip() for s in re.split(r"&&|\|\||;|\||\n", cmd) if s.strip()]


def read_only(cmd):
    for seg in segments(cmd):
        try:
            words = shlex.split(seg, posix=True)
        except ValueError:
            return False
        words = [w for w in words if not re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", w)]  # skip VAR=x prefixes
        if not words:
            continue
        w0 = os.path.basename(words[0])
        if w0 == "cd":
            continue
        if w0 == "git" and len(words) > 1:
            sub = next((w for w in words[1:] if not w.startswith("-") and w not in ("-C",)), "")
            if sub in GIT_READ:
                continue
            return False
        if w0 == "sed" and "-i" not in words and not any(w.startswith("-i") for w in words):
            continue
        if w0 not in READ_ONLY:
            return False
        if ">" in seg.replace("2>&1", "").replace("2>/dev/null", "").replace(">/dev/null", ""):
            return False
    return True


def paths_in(cmd, cwd):
    out = []
    # Mac paths, and Alexus paths (/home/<user>/Developer/...): the repos there are the same repos, so the
    # README is read from this Mac's copy.
    for tok in re.findall(r"(?:~|/Users/[^/\s]+|/home/[^/\s]+)/Developer/[^\s'\"|;&)]+", cmd):
        out.append(ROOT + tok.split("/Developer", 1)[1])
    if cwd and cwd.startswith(ROOT + os.sep):
        out.append(cwd)
    return out


def main():
    try:
        inp = json.load(sys.stdin)
    except Exception:
        return 0
    tool = inp.get("tool_name", "")
    ti = inp.get("tool_input") or {}
    session = re.sub(r"[^A-Za-z0-9_-]", "", str(inp.get("session_id") or "unknown"))[:80]
    state_path = os.path.join(STATE_DIR, session + ".json")
    try:
        seen = set(json.load(open(state_path)))
    except Exception:
        seen = set()

    def save():
        os.makedirs(STATE_DIR, exist_ok=True)
        tmp = state_path + ".tmp"
        with open(tmp, "w") as f:
            json.dump(sorted(seen), f)
        os.replace(tmp, state_path)

    if tool == "Read":
        p = os.path.realpath(os.path.expanduser(ti.get("file_path", "")))
        if os.path.basename(p) == "README.md" and p not in seen:
            seen.add(p)
            save()
        return 0
    if tool in ("Edit", "Write", "MultiEdit", "NotebookEdit"):
        candidates = [ti.get("file_path") or ti.get("notebook_path") or ""]
    elif tool == "Bash":
        cmd = ti.get("command", "")
        if read_only(cmd):
            return 0
        candidates = paths_in(cmd, inp.get("cwd") or os.getcwd())
    else:
        return 0

    for c in candidates:
        if not c:
            continue
        rd = readme_for(c)
        if not rd or rd in seen:
            continue
        try:
            text = open(rd, encoding="utf-8", errors="replace").read()
        except OSError:
            continue
        seen.add(rd)
        save()
        more = "" if len(text) <= MAX_CHARS else f"\n\n[... {len(text) - MAX_CHARS} more characters: Read {rd} for the rest]"
        reason = (f"READ FIRST (hook, owner 2026-11-14): this {tool} call touches {os.path.dirname(rd)}, whose README "
                  f"has not been read this session. Here it is. Check your plan against it (how the tool is meant to "
                  f"run, which model/backend goes first, what it must not do), say in one line what it changes, then make "
                  f"the same call again; it will go through.\n\n===== {rd} =====\n{text[:MAX_CHARS]}{more}")
        log(f"{session} refused once {tool}: showed {rd}")
        print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny",
                                                  "permissionDecisionReason": reason}}))
        return 0
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as err:  # never wedge the agent
        log(f"error: {err!r}")
        sys.exit(0)
