#!/usr/bin/env python3
"""handoff -- every Claude Code session leaves a handoff for the next one, in a database (owner, 2026-11-14: "yeah every
session put it into a handoff for the next" / "save it to another database and then have the next session pull from it").

Where it lives: database `handoffs` (table `sessions`) in ragnarok-data-postgres-1 on Alexus, reached the same way as
the shared memory (docker exec over one ssh connection). One row per session.

  handoff.py --end      SessionEnd hook. Saves the row:
                          - EVERY request the owner typed, in order (built by walking the transcript, not by asking:
                            a search can never return what was skipped, memory ygg:67)
                          - commits made in ~/Developer/ragnarok during the session, and what is left uncommitted
                        then, detached, a headless `claude -p` fills `summary`: Open or blocked (with the next step),
                        Done (with proof), Claimed but not proven, What went wrong.
  handoff.py --start    SessionStart hook. Pulls the newest row (last 7 days) and puts it in front of the new session.
  handoff.py --show [N] print the newest N handoffs (default 1), for Grok/Codex/people.
  handoff.py --write TRANSCRIPT   the summary step (what the detached job runs; also by hand).

If Alexus can't be reached, the row waits in ~/.ragnarok/handoffs/queue/ and is sent on the next start or end (a queue,
not a second home: it is deleted once the database has it). Only real interactive sessions (entrypoint "cli") with 2+
requests count; scripted `claude -p` runs and the summarizer itself (RAGNAROK_HANDOFF_CHILD=1) are skipped.
Never blocks anything. Log: ~/.ragnarok/handoffs/handoff.log
"""
import datetime
import json
import os
import re
import shlex
import socket
import subprocess
import sys
import time

HOME = os.path.expanduser("~/.ragnarok/handoffs")
QUEUE = os.path.join(HOME, "queue")
LOG = os.path.join(HOME, "handoff.log")
REPO = os.path.expanduser("~/Developer/ragnarok")
MAX_DIGEST = 120_000
TAG = "$hand_k3P$"
_SSH = os.environ.get("RAGNAROK_DB_SSH", "ssh -o BatchMode=yes -o ConnectTimeout=5 -o ControlMaster=auto "
                      "-o ControlPath=~/.ragnarok/ssh-alexus-%C -o ControlPersist=600 alexus")
_PSQL = ["docker", "exec", "-i", "ragnarok-data-postgres-1", "psql", "-U", "kit_admin", "-d", "handoffs",
         "-X", "-q", "-At", "-v", "ON_ERROR_STOP=1"]
PG = shlex.split(_SSH) + [shlex.join(_PSQL)] if _SSH else _PSQL


def log(**kw):
    kw["ts"] = time.strftime("%Y-%m-%dT%H:%M:%S")
    try:
        os.makedirs(HOME, mode=0o700, exist_ok=True)
        with open(LOG, "a") as f:
            f.write(json.dumps(kw) + "\n")
    except OSError:
        pass


# ------------------------------------------------------------------ database

def lit(s):
    if s is None:
        return "NULL"
    return TAG + str(s).replace(TAG, "") + TAG


def sql(q, timeout=60):
    p = subprocess.run(PG, input=q, capture_output=True, text=True, timeout=timeout)
    if p.returncode:
        raise RuntimeError((p.stderr or p.stdout).strip()[:300])
    return p.stdout


def save(row):
    """Upsert one session row. Raises if Alexus can't be reached (the caller queues it)."""
    cols = [c for c in ["session_id", "ai", "machine", "started", "ended", "transcript", "requests", "commits",
                        "uncommitted", "summary", "summary_ok"] if c in row]

    def val(c):
        if c == "requests":
            return lit(json.dumps(row[c], ensure_ascii=False)) + "::jsonb"
        if c == "summary_ok":
            return "true" if row[c] else "false"
        return lit(row[c])
    sets = ", ".join(f"{c} = EXCLUDED.{c}" for c in cols if c != "session_id") + ", written = now()"
    sql(f"INSERT INTO sessions ({', '.join(cols)}) VALUES ({', '.join(val(c) for c in cols)}) "
        f"ON CONFLICT (session_id) DO UPDATE SET {sets};")


def queue(row):
    os.makedirs(QUEUE, mode=0o700, exist_ok=True)
    p = os.path.join(QUEUE, row["session_id"] + ".json")
    old = json.load(open(p)) if os.path.exists(p) else {}
    old.update(row)
    fd = os.open(p + ".tmp", os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump(old, f)
    os.replace(p + ".tmp", p)


def store(row):
    try:
        save(row)
        return "database"
    except Exception as e:
        queue(row)
        log(event="queued", session=row["session_id"], why=str(e)[:200])
        return "queued"


def flush():
    try:
        names = [n for n in os.listdir(QUEUE) if n.endswith(".json")]
    except OSError:
        return
    for n in names:
        p = os.path.join(QUEUE, n)
        try:
            save(json.load(open(p)))
            os.remove(p)
            log(event="flushed", file=n)
        except Exception as e:
            log(event="flush-failed", file=n, why=str(e)[:200])
            return   # Alexus still unreachable; try again next time


# ------------------------------------------------------------------ transcript

def read(transcript):
    rows = []
    with open(transcript, errors="replace") as f:
        for line in f:
            try:
                rows.append(json.loads(line))
            except ValueError:
                pass
    return rows


def requests(rows):
    """Every request the owner typed, including messages sent mid-turn, each with every reply text of that turn.
    Command wrappers, hook feedback and compaction summaries are not his words and are left out."""
    out, cur = [], None
    for o in rows:
        t = o.get("type")
        if t == "user" and not o.get("isSidechain") and not o.get("isMeta") and not o.get("isCompactSummary"):
            c = o.get("message", {}).get("content")
            if isinstance(c, str) and c.strip() and not c.lstrip().startswith("<") and not c.startswith("Stop hook feedback"):
                cur = {"ts": o.get("timestamp", ""), "text": c.strip(), "reply": ""}
                out.append(cur)
        elif t == "attachment":
            a = o.get("attachment") or {}
            if a.get("type") == "queued_command" and (a.get("origin") or {}).get("kind") == "human" and a.get("prompt"):
                cur = {"ts": a.get("timestamp", ""), "text": str(a["prompt"]).strip(), "reply": "", "midturn": True}
                out.append(cur)
        elif t == "assistant" and cur is not None and not o.get("isSidechain"):
            txt = "".join(b.get("text", "") for b in o.get("message", {}).get("content") or [] if isinstance(b, dict) and b.get("type") == "text")
            if txt.strip():
                cur["reply"] = (cur["reply"] + "\n" + txt.strip()).strip()
    return out


def interactive(rows):
    for o in rows:
        if o.get("entrypoint"):
            return o["entrypoint"] == "cli"
    return False


def git(*a):
    try:
        return subprocess.run(["git", "-C", REPO, *a], capture_output=True, text=True, timeout=20).stdout.strip()
    except Exception:
        return ""


def local(ts):
    try:
        return datetime.datetime.fromisoformat(str(ts).replace("Z", "+00:00")).astimezone().strftime("%m-%d %H:%M")
    except ValueError:
        return str(ts)[:16]


def base_row(transcript, session, reqs):
    since = reqs[0]["ts"]
    return {"session_id": session, "ai": "claude", "machine": socket.gethostname().split(".")[0], "started": since,
            "ended": datetime.datetime.now(datetime.timezone.utc).isoformat(), "transcript": transcript,
            "requests": [{"ts": r["ts"], "text": r["text"][:2000], **({"midturn": True} if r.get("midturn") else {})} for r in reqs],
            "commits": git("log", "--since", since, "--format=%h %s", "main") or "(none)",
            "uncommitted": git("status", "--porcelain") or "(nothing)"}


def digest(reqs):
    parts = [f"### Request {i} ({local(r['ts'])})\nOWNER: {r['text'][:1500]}\nREPLIES: {r['reply'][-3500:] or '(no reply text)'}\n"
             for i, r in enumerate(reqs, 1)]
    d = "\n".join(parts)
    return d if len(d) <= MAX_DIGEST else d[-MAX_DIGEST:]   # keep the end: the latest state matters most


PROMPT = """You are writing the handoff for the next AI session on the owner's machines. Below is every request the owner
made in the last session, each with the replies the AI gave to it (the end of them if long). Write ONLY these four
markdown sections, plain English, short lines, no preamble:

### Open or blocked
One line each: what is not finished, why, and the exact next step (command or click). Include anything the AI said it
would do and did not, anything waiting on the owner, and any failure. Most important first.

### Done (with proof)
One line each, only things the replies show were actually checked (a commit hash, a test result, a command output).

### Claimed but not proven
Things the AI said work or are true without showing a check.

### What went wrong
Mistakes, wrong claims, things the owner had to correct, one line each, so the next session does not repeat them.

Do not invent anything that is not in the text. Some answers may be missing from the text (said on screen but not
saved); do not claim a question went unanswered unless the owner said so. If a section is empty write "(none)".

"""


def write_summary(transcript):
    rows = read(transcript)
    reqs = requests(rows)
    if len(reqs) < 2:
        return
    session = next((o.get("sessionId") for o in rows if o.get("sessionId")), "unknown")
    row = base_row(transcript, session, reqs)
    claude = os.path.expanduser("~/.local/bin/claude")
    try:
        # --setting-sources project, run from ~/.ragnarok/handoffs: no user hooks. Without it the owner's Stop hooks
        # catch this run and it answers them with a bare "✓" instead of the summary (seen 2026-11-14).
        p = subprocess.run([claude if os.path.exists(claude) else "claude", "-p", "--model", "sonnet", "--setting-sources", "project"],
                           input=PROMPT + digest(reqs), capture_output=True, text=True, timeout=600,
                           env=dict(os.environ, RAGNAROK_HANDOFF_CHILD="1"), cwd=HOME)
        ok = p.returncode == 0 and len(p.stdout.strip()) > 40
        row["summary"] = p.stdout.strip() if ok else f"(summary failed: exit {p.returncode}; read the requests and the transcript)"
    except Exception as e:
        ok, row["summary"] = False, f"(summary failed: {type(e).__name__}; read the requests and the transcript)"
    row["summary_ok"] = ok
    where = store(row)
    log(event="summary", session=session, ok=ok, stored=where)


# ------------------------------------------------------------------ hooks

def end(inp):
    if os.environ.get("RAGNAROK_HANDOFF_CHILD"):
        return
    os.makedirs(HOME, mode=0o700, exist_ok=True)
    flush()
    transcript = inp.get("transcript_path") or ""
    if not os.path.isfile(transcript):
        log(event="end", skipped="no transcript"); return
    rows = read(transcript)
    if not interactive(rows):
        log(event="end", skipped="not an interactive session"); return
    reqs = requests(rows)
    if len(reqs) < 2:
        log(event="end", skipped=f"{len(reqs)} request(s)"); return
    session = inp.get("session_id") or next((o.get("sessionId") for o in rows if o.get("sessionId")), "unknown")
    where = store(base_row(transcript, session, reqs))   # the request list is saved now; the summary follows
    # The summary takes a minute; run it detached so closing Claude Code is never held up.
    subprocess.Popen([sys.executable, "-I", os.path.abspath(__file__), "--write", transcript],
                     stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                     start_new_session=True, env=dict(os.environ, RAGNAROK_HANDOFF_CHILD="1"))
    log(event="end", session=session, requests=len(reqs), stored=where, reason=inp.get("reason"))


def newest(n=1, exclude=""):
    q = ("SELECT coalesce(json_agg(t), '[]') FROM (SELECT session_id, ai, machine, started, ended, summary, summary_ok, "
         "jsonb_array_length(requests) AS n_requests, requests, commits, uncommitted FROM sessions "
         f"WHERE session_id <> {lit(exclude)} AND ended > now() - interval '7 days' ORDER BY ended DESC LIMIT {int(n)}) t;")
    return json.loads(sql(q, timeout=20).strip() or "[]")


def render(r, full=False):
    head = (f"Handoff from {r['ai']} session {r['session_id'][:8]} on {r['machine']} "
            f"({local(r['started'])} to {local(r['ended'])}, {r['n_requests']} requests from the owner)\n\n")
    body = r.get("summary") or "(summary not written yet: read the request list)"
    if full or not r.get("summary_ok"):
        reqs = "\n".join(str(i) + ". " + local(q["ts"]) + ": " + re.sub(r"\s+", " ", q["text"])[:300] for i, q in enumerate(r["requests"], 1))
        body += "\n\n### Every request the owner made\n" + reqs
    body += f"\n\n### Commits in ragnarok\n{r['commits']}\n\n### Left uncommitted\n{r['uncommitted']}"
    return head + body


def start(inp):
    if os.environ.get("RAGNAROK_HANDOFF_CHILD"):
        return
    flush()
    try:
        rs = newest(1, exclude=inp.get("session_id") or "")
    except Exception as e:
        log(event="start", failed=str(e)[:200]); return
    if not rs:
        return
    print(json.dumps({"hookSpecificOutput": {"hookEventName": "SessionStart", "additionalContext": (
        "🟦 [HOOK — not Claude] HANDOFF from the last session, pulled from the handoffs database on Alexus (owner, "
        "2026-11-14: \"save it to another database and then have the next session pull from it\"). Recheck anything "
        "marked open before reporting on it; things change between sessions. Full row with every request: "
        "`python3 ~/scripts/handoff.py --show`.\n\n" + render(rs[0])[:9000])}}))
    log(event="start", shown=rs[0]["session_id"])


def main():
    a = sys.argv[1:]
    if a[:1] == ["--write"] and len(a) > 1:
        write_summary(a[1]); return
    if a[:1] == ["--show"]:
        for r in newest(int(a[1]) if len(a) > 1 and a[1].isdigit() else 1):
            print(render(r, full=True) + "\n\n" + "=" * 60 + "\n")
        return
    try:
        inp = json.loads(sys.stdin.read() or "{}")
    except ValueError:
        inp = {}
    if "--end" in a:
        end(inp)
    elif "--start" in a:
        start(inp)
    else:
        print(__doc__)


if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        log(error=f"{type(e).__name__}: {e}"[:300])
    sys.exit(0)
