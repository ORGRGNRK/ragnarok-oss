#!/usr/bin/env python3
"""premise-check -- check what a message NAMES against what is actually there.

Reinstated 2026-10-26 from Alexus /srv/ragnarok/projects/scripts/
ragnarok-premise-check.py (2026-09-08), on the owner's call: "reinstate the
premise check and make it for both of us."

WHY IT EXISTS. owner, 2026-09-08: "i had to get angry to find out its me
hallucinating shit." Three of his premises that night were wrong and arrived
in the same voice as the right ones. Every other check on this box watches the
AI; this one was the only thing that checked a premise from the owner. It was
never wired on the MacBook and was not running anywhere when it was found
again on 10-26.

TWO MODES, one rule each:
  (no args)   UserPromptSubmit -- the owner's prompt. The files, folders and
              skills it names are looked up, and when it says a file
              "says/has/contains" something, those words are counted in it.
              A missing path or a zero is shown to him (one line) and put in
              front of the model. Never blocks him.
  --answer    Stop -- the model's answer. Every path it names is looked up.
              A path under a MacBook-only root (~, /Users, /private, /tmp,
              /Applications, /Library) that does not exist blocks the stop
              once, so the model corrects it. Deterministic: no model judges
              anything, so it cannot guess (the 09-02 guess-guard lesson).

ALEXUS PATHS (2026-10-31, answer mode only). A path the answer or the session
ties to Alexus (alexus / ALEXUS_HOST / ALEXUS_TAILSCALE / ssh / scp on its line
or the 3 lines above, host:/path, or a Bash call in this session that ran it via
ssh/scp) is checked ON ALEXUS with one
`ssh -o BatchMode=yes -o ConnectTimeout=5 grok@<ALEXUS_HOST> test -e ...`.
Present there -> fine. Absent there -> blocks like a missing Mac path.
ssh fails (Alexus down, at its disk-unlock screen, key refused) -> reported as
"unverifiable, host unreachable", never as missing, never blocks.

WHAT IT CANNOT SEE. It runs on the MacBook. A path that is not here and not
under a MacBook-only root (/srv, /home, /etc, /opt/ragnarok-...) may live on
Alexus; it is reported as "not on this Mac, not checked elsewhere", never as
missing. Same for a ~ path the text places on another host (host:~/x, or
"alexus" on its line or the 3 lines above). No network, no database, no ssh: it runs on every turn and must be
instant. It checks that a named thing exists, never that a claim about it is
true.

Always exits 0. A hook that can wedge a prompt gets removed within a day, and
then nothing is checking at all.

Log: ~/.claude/premise-check.log (one JSON line per run, findings or not).
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import time

HOME = os.path.expanduser("~")
# Run on Alexus itself (claude@alexus, 2026-11-08): Alexus paths are local there, nothing to ssh to, and the
# messages say "Alexus" instead of "this Mac".
ON_ALEXUS = sys.platform.startswith("linux") and os.uname().nodename.lower().startswith("alexus")
HERE = "Alexus" if ON_ALEXUS else "this Mac"
LOG = os.path.join(HOME, ".claude", "premise-check.log")
SKILL_DIRS = [os.path.join(HOME, ".claude", "skills")]
LOCAL_ROOTS = ((HOME + "/", "/home/", "/tmp/", "/opt/", "/etc/", "/var/", "/srv/", "/mnt/", "/usr/") if ON_ALEXUS
               else (HOME + "/", "/Users/", "/private/", "/tmp/", "/Applications/", "/Library/"))
# A ~ path the answer places on another machine is not a Mac path (10-30: four
# Alexus paths blocked the stop 11 times in one session). Placed = written as
# host:~/path, or a remote name on its line or the REMOTE_WINDOW lines above.
def _local_conf(key, default=""):
    """One KEY=value from ~/.ragnarok/local.conf (read only, never run)."""
    try:
        for line in open(os.path.expanduser("~/.ragnarok/local.conf"), encoding="utf-8"):
            k, sep, v = line.strip().partition("=")
            if sep and not k.startswith("#") and k.strip() == key:
                default = v.strip().strip("\"'")
    except OSError:
        pass
    return default


REMOTE_HOSTS = tuple(h for h in ("alexus", _local_conf("ALEXUS_HOST"), _local_conf("ALEXUS_TAILSCALE")) if h)
REMOTE_RE = re.compile("|".join(re.escape(h) for h in REMOTE_HOSTS) + r"|(?<![./\w-])(ssh|scp)\b", re.I)
REMOTE_WINDOW = 3
ALEXUS_SSH = ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "grok@" + _local_conf("ALEXUS_HOST", "alexus")]
SSH_TIMEOUT = 7   # the hook's own timeout is 10 s

MAX_REFERENTS = 8
MAX_TERMS = 6
MAX_BYTES = 2_000_000
MAX_LINES = 24

STOP = {
    "the", "and", "for", "that", "this", "with", "from", "what", "when", "have",
    "has", "was", "were", "are", "you", "your", "can", "cant", "dont", "doesnt",
    "not", "but", "its", "it", "there", "their", "then", "than", "into", "onto",
    "make", "made", "just", "like", "look", "looks", "need", "needs", "want",
    "wants", "should", "shouldve", "would", "could", "why", "how", "who", "which",
    "where", "some", "any", "all", "one", "two", "three", "check", "fix", "change",
    "run", "does", "did", "say", "says", "said", "get", "got", "put", "add",
    "about", "over", "under", "out", "off", "back", "down", "same", "every",
    "thing", "things", "stuff", "shit", "fuck", "fucking", "dude", "yeah",
}

# A content claim lives AFTER an assertion verb: "the part that SAYS needs 2
# receipts". Terms come from after the last marker only, or every noun in the
# sentence reads as a zero and the output is noise nobody reads.
ASSERT_RE = re.compile(
    r"\b(says?|said|has|have|contains?|carries|carry|reads?|mentions?|states?|"
    r"tells?|shows?|includes?|lists?|requires?|wants|needs?|about)\b", re.I)
URL_RE = re.compile(r"\b[a-z][a-z0-9+.-]*://\S+", re.I)
PATH_RE = re.compile(r"(?<![\w/~.])((?:~|\.{1,2})?/[\w.\-/]{2,160})")
CMD_RE = re.compile(r"(?<![\w/])/([a-z][a-z0-9_-]{1,20})\b")
QUOTED_RE = re.compile(r"[\"“]([^\"”\n]{3,60})[\"”]")
WORD_RE = re.compile(r"[A-Za-z][A-Za-z0-9_.-]{3,}")


def log(entry):
    entry["ts"] = time.strftime("%Y-%m-%dT%H:%M:%S")
    try:
        with open(LOG, "a") as f:
            f.write(json.dumps(entry) + "\n")
    except Exception:
        pass


def resolve(token: str) -> str:
    p = os.path.expanduser(token) if token.startswith("~") else token
    return p.rstrip(".,:;)")  # sentence punctuation is not part of a path


def is_local(path: str) -> bool:
    return path.startswith(LOCAL_ROOTS)


def placed_remote(text: str, token: str) -> bool:
    lines = text.splitlines()
    for i, line in enumerate(lines):
        at = line.find(token)
        if at < 0:
            continue
        if re.search(r"[\w.-]+:$", line[:at]):
            return True
        near = " ".join(lines[max(0, i - REMOTE_WINDOW):i + 1])
        if REMOTE_RE.search(near):
            return True
    return False


def ran_remote(transcript: str, token: str, path: str) -> bool:
    """True when a Bash call in this session named the path inside an ssh/scp command."""
    if not transcript:
        return False
    try:
        with open(transcript) as f:
            for line in f:
                if token not in line and path not in line:
                    continue
                try:
                    o = json.loads(line)
                except Exception:
                    continue
                for b in o.get("message", {}).get("content") or []:
                    if isinstance(b, dict) and b.get("type") == "tool_use":
                        cmd = str((b.get("input") or {}).get("command", ""))
                        if (token in cmd or path in cmd) and re.search(r"\b(ssh|scp)\b", cmd):
                            return True
    except Exception:
        pass
    return False


def check_alexus(paths: list[str]) -> dict:
    """{path: "Y"|"N"|"U"} from one ssh call; {} when Alexus can't be asked.
    U = grok can't see into the nearest existing parent (e.g. another user's
    0700 home), so "absent" can't be told from "hidden"."""
    if not paths:
        return {}
    one = ('p={q}; if test -e "$p"; then echo Y; else d=$p; while [ "$d" != / ] && [ ! -e "$d" ]; '
           'do d=$(dirname "$d"); done; if [ -x "$d" ] && [ -r "$d" ]; then echo N; else echo U; fi; fi')
    script = "; ".join(one.format(q=sh_quote(p)) for p in paths)
    try:
        r = subprocess.run(ALEXUS_SSH + [script], capture_output=True, text=True,
                           timeout=SSH_TIMEOUT, stdin=subprocess.DEVNULL)
    except Exception:
        return {}
    marks = r.stdout.split()
    if r.returncode != 0 or len(marks) != len(paths):
        return {}
    return dict(zip(paths, marks))


def sh_quote(p: str) -> str:
    if p.startswith("~/"):
        return '"$HOME"/' + sh_quote(p[2:])
    return "'" + p.replace("'", "'\\''") + "'"


def being_created(text: str, token: str) -> bool:
    # A path the answer tells someone to CREATE (ssh-keygen -f X, > X, mkdir X)
    # is not a claim that it exists (10-31: keygen targets blocked 3 stops).
    for line in text.splitlines():
        at = line.find(token)
        if at >= 0 and re.search(r"(?:\s-f|\s-o|>>?|\bmkdir(?: -p)?|\btouch)\s+['\"]?$", line[:at]):
            return True
    return False


def describe(path: str) -> str:
    try:
        if os.path.islink(path):
            return f"symlink -> {os.readlink(path)}"
        if os.path.isdir(path):
            return f"folder, {len(os.listdir(path))} entries"
        if os.path.isfile(path):
            return f"{os.path.getsize(path):,} bytes"
        return "exists"
    except Exception:
        return "unreadable"


def referents(text: str) -> list[tuple[str, str]]:
    text = URL_RE.sub(" ", text)
    out, seen = [], set()
    for tok in PATH_RE.findall(text):
        p = resolve(tok)
        if p in seen or len(p) < 3 or p.count("/") < 1:
            continue
        seen.add(p)
        out.append((tok, p))
    for name in CMD_RE.findall(text):
        for root in SKILL_DIRS:
            p = os.path.join(root, name, "SKILL.md")
            if os.path.isfile(p) and p not in seen:
                # "/boot" also matched as the literal path /boot; drop that.
                out = [(l, q) for (l, q) in out if q != "/" + name]
                seen.add(p)
                out.append((f"/{name}", p))
    return out[:MAX_REFERENTS]


def claim_terms(text: str) -> list[str]:
    terms = [q.strip() for q in QUOTED_RE.findall(text)]
    marks = list(ASSERT_RE.finditer(text))
    tail = text[marks[-1].end():] if marks else ""
    for w in WORD_RE.findall(tail):
        if w.lower() in STOP or "/" in w:
            continue
        terms.append(w)
    ded = []
    for t in terms:
        if t.lower() not in {d.lower() for d in ded}:
            ded.append(t)
    return ded[:MAX_TERMS]


def counts(path: str, terms: list[str]) -> list[tuple[str, int]]:
    try:
        if os.path.getsize(path) > MAX_BYTES:
            return []
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            body = fh.read().lower()
    except Exception:
        return []
    return [(t, body.count(t.lower())) for t in terms]


def check(text: str, with_terms: bool, transcript: str = "", remote_check: bool = False):
    """Return (lines, missing, zeros, elsewhere)."""
    refs = referents(text)
    remote_q = []   # (index into lines, label, path) to look up on Alexus
    terms = claim_terms(text) if with_terms else []
    lines, missing, zeros, elsewhere = [], [], [], []
    for label, path in refs:
        if os.path.exists(path):
            lines.append(f"  {label} -> found [{describe(path)}]")
            if terms and os.path.isfile(path):
                c = counts(path, terms)
                if c:
                    c.sort(key=lambda x: (x[1] != 0, x[0].lower()))
                    lines.append("      words: " + "  ".join(f"{t}=0 <-" if n == 0 else f"{t}={n}" for t, n in c))
                    zeros += [f"{t} in {label}" for t, n in c if n == 0]
        elif being_created(text, label):
            lines.append(f"  {label} -> not here yet (the text creates it)")
            elsewhere.append(label)
        elif not ON_ALEXUS and (placed_remote(text, label) or (remote_check and ran_remote(transcript, label, path))):
            if remote_check:
                # ~ on Alexus is grok's home there; ask for the literal path.
                rpath = label.rstrip(".,:;)")
                remote_q.append((len(lines), label, rpath))
                lines.append("")
            else:
                lines.append(f"  {label} -> not on {HERE} (text places it on another machine; not checked there)")
                elsewhere.append(label)
        elif is_local(path):
            lines.append(f"  {label} -> DOES NOT EXIST on {HERE}")
            missing.append(label)
        else:
            lines.append(f"  {label} -> not on {HERE} (maybe on Alexus; not checked there)")
            elsewhere.append(label)
    if remote_q:
        found = check_alexus([r for _, _, r in remote_q])
        for at, label, rpath in remote_q:
            if not found:
                lines[at] = f"  {label} -> not on this Mac; on Alexus: unverifiable, host unreachable"
                elsewhere.append(label + " (Alexus unreachable)")
            elif found.get(rpath) == "Y":
                lines[at] = f"  {label} -> not on this Mac; found on Alexus"
                elsewhere.append(label + " (on Alexus)")
            elif found.get(rpath) != "N":
                lines[at] = f"  {label} -> not on this Mac; on Alexus: unverifiable (grok can't read its parent folder)"
                elsewhere.append(label + " (Alexus: no permission to check)")
            elif label.startswith("~"):
                # ~ on Alexus is grok's home, not necessarily the one meant: report, don't block
                # (remote-placed ~ paths never blocked before 10-31 either).
                lines[at] = f"  {label} -> not on this Mac; not under grok's ~ on Alexus (other homes not checked)"
                elsewhere.append(label + " (not under grok's ~ on Alexus)")
            else:
                lines[at] = f"  {label} -> DOES NOT EXIST on this Mac or on Alexus (checked via ssh)"
                missing.append(label + " (checked: not on this Mac, not on Alexus)")
    return lines, missing, zeros, elsewhere


def prompt_mode(inp):
    prompt = inp.get("prompt") or ""
    entry = {"mode": "prompt", "session": inp.get("session_id")}
    lines, missing, zeros, elsewhere = check(prompt, with_terms=True)
    entry.update(refs=len(lines), missing=missing, zeros=zeros, elsewhere=elsewhere)
    log(entry)
    if not lines:
        return
    out = [f"PREMISE CHECK (hook, measured on {HERE} -- what the things this prompt names actually are):"]
    out += lines
    out.append("  A missing path or a zero is a finding. If something this prompt treats as present is "
               "missing or reads 0, say so in your first sentence before acting on it.")
    res = {"hookSpecificOutput": {"hookEventName": "UserPromptSubmit",
                                  "additionalContext": "\n".join(out[:MAX_LINES])}}
    if missing or zeros:
        bits = [f"not found: {', '.join(missing)}"] if missing else []
        bits += [f"0 hits: {', '.join(zeros)}"] if zeros else []
        res["systemMessage"] = "🟦 HOOK (premise check, your prompt): " + "; ".join(bits)
    print(json.dumps(res))


def answer_text(inp) -> str:
    last = inp.get("last_assistant_message")
    if isinstance(last, str) and last.strip():
        return last
    # Fallback: the last assistant text in the transcript.
    try:
        texts = []
        with open(inp["transcript_path"]) as f:
            for line in f:
                o = json.loads(line)
                if o.get("type") == "assistant" and not o.get("isSidechain"):
                    for b in o.get("message", {}).get("content") or []:
                        if isinstance(b, dict) and b.get("type") == "text":
                            texts.append(b.get("text", ""))
        return texts[-1] if texts else ""
    except Exception:
        return ""


def answer_mode(inp):
    entry = {"mode": "answer", "session": inp.get("session_id")}
    if inp.get("stop_hook_active"):
        entry["skipped"] = "correction pass"
        log(entry)
        return
    lines, missing, zeros, elsewhere = check(answer_text(inp), with_terms=False,
                                             transcript=inp.get("transcript_path") or "", remote_check=True)
    entry.update(refs=len(lines), missing=missing, elsewhere=elsewhere)
    log(entry)
    if not missing:
        return
    # No systemMessage banner: silent unless the correction changes something (10-31 ask).
    print(json.dumps({
        "decision": "block",
        "reason": (f"🟦 [HOOK — not Claude] Premise check: your answer names paths that do not exist on {HERE}"
                   + (" (Alexus-tied ones were also looked up on Alexus over ssh)" if any("Alexus" in m for m in missing) else "")
                   + ":\n"
                   + "\n".join(f"- {m}" for m in missing)
                   + "\n\nCheck each one with a tool. SILENT UNLESS CHANGED: if the path is fine (e.g. it lives on "
                     "another machine and the answer already says so), do not mention it. Only if you correct "
                     "the answer, tell the owner in one line starting with '🟦 Corrected:'. If nothing changed, reply "
                     "with only: ✓"),
    }))


def main():
    if os.environ.get("EVIDENCE_AUDIT_INNER"):
        return
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
