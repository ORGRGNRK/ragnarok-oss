#!/usr/bin/env python3
"""agent-receipt.py: receipts for what an AI does on this machine, sent to the client kit's agent_log.

Every event (a command an AI agent ran, a file it edited, a tool it used) becomes one receipt in the kit's
hash-chained, append-only agent_log. Python 3 standard library only; macOS and Linux.

  agent-receipt.py hook [ACTOR]     Claude Code / Codex hook: JSON on stdin (PostToolUse, PostToolUseFailure)
  agent-receipt.py shell EXIT CMD   from a shell prompt hook (zsh precmd / bash PROMPT_COMMAND): one command
  agent-receipt.py log --cmd TEXT [--actor NAME] [--target PATH] [--kind Read|Change]   one manual receipt
  agent-receipt.py flush            send anything waiting in the spool
  agent-receipt.py status           where it sends, how many are waiting (never prints the token)

Settings: ~/.config/kit-receipts/env (KEY=value lines, must be private: chmod 600), or the same names in
the environment:
  KIT_RECEIPT_URL    e.g. http://127.0.0.1:8790/receipts  (plain http only to this machine or a Tailscale
                     address; anything else must be https)
  KIT_RECEIPT_TOKEN  the kit's RECEIPT_TOKEN (it can only ADD receipts: no tools, no data)
  KIT_RECEIPT_ACTOR  default actor name (default: the hook's own label, e.g. "Claude Code")

How it never gets in the way and never loses a receipt:
  1. secrets are redacted on this machine first (the server redacts again)
  2. the event is appended to ~/.local/state/kit-receipts/spool.jsonl (0600) right away
  3. a background process sends the spool, oldest first; on success those lines are removed
  4. server down -> the lines wait and go with the next event or `flush`
  Hook mode always exits 0 and prints nothing. File contents are never sent, only the path.
"""
import fcntl
import ipaddress
import json
import os
import re
import socket
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from datetime import datetime, timezone

CONF = os.environ.get("KIT_RECEIPT_ENV_FILE") or os.path.expanduser("~/.config/kit-receipts/env")
STATE = os.environ.get("KIT_RECEIPT_STATE") or os.path.expanduser("~/.local/state/kit-receipts")
SPOOL = os.path.join(STATE, "spool.jsonl")
ERRLOG = os.path.join(STATE, "errors.log")
BATCH = 200
MAX_CMD = 8000

_REDACTIONS = [
    (re.compile(r'(?i)\b([A-Z0-9_.\-]*(?:password|passwd|secret|token|api[_-]?key|access[_-]?key|private[_-]?key|credentials?)[A-Z0-9_.\-]*)("?\s*[=:]\s*)("[^"]*"|\'[^\']*\'|[^\s"\'&;|,}]+)'), r'\1\2[REDACTED]'),
    (re.compile(r'(?i)(\s--?[A-Z0-9_\-]*(?:password|passwd|secret|token|api[_-]?key)[A-Z0-9_\-]*)(\s+)("[^"]*"|\'[^\']*\'|[^\s"\'&;|]+)'), r'\1\2[REDACTED]'),
    (re.compile(r'(?i)\b(bearer|basic)\s+[A-Za-z0-9._~+/=\-]{8,}'), r'\1 [REDACTED]'),
    (re.compile(r'(?i)\b(x-api-key|xc-token|xc-auth|authorization)(\s*:\s*)[^\s"\']+'), r'\1\2[REDACTED]'),
    (re.compile(r'(://[^/\s:@]+):[^/\s@]+@'), r'\1:[REDACTED]@'),
    (re.compile(r'\b(sk-(?:ant-|proj-)?[A-Za-z0-9_\-]{16,})'), '[REDACTED]'),
    (re.compile(r'\b(xai-[A-Za-z0-9]{16,})'), '[REDACTED]'),
    (re.compile(r'\b(gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})'), '[REDACTED]'),
    (re.compile(r'\b(xox[abprs]-[A-Za-z0-9\-]{10,})'), '[REDACTED]'),
    (re.compile(r'\b(AKIA[0-9A-Z]{16})\b'), '[REDACTED]'),
    (re.compile(r'\b(AIza[0-9A-Za-z_\-]{30,})'), '[REDACTED]'),
    (re.compile(r'-----BEGIN [A-Z ]*PRIVATE KEY-----.*?(-----END [A-Z ]*PRIVATE KEY-----|$)', re.S), '[REDACTED PRIVATE KEY]'),
]


def redact(text):
    if not isinstance(text, str):
        return text
    for rx, rep in _REDACTIONS:
        text = rx.sub(rep, text)
    return text if len(text) <= MAX_CMD else text[:MAX_CMD] + "...[truncated]"


def settings():
    conf = {}
    if os.path.exists(CONF):
        st = os.stat(CONF)
        if st.st_mode & 0o077:
            raise SystemExit(f"{CONF} is readable by other users; run: chmod 600 {CONF}")
        for line in open(CONF, encoding="utf-8"):
            m = re.match(r'^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*$', line)
            if m and not line.lstrip().startswith("#"):
                conf[m.group(1)] = m.group(2).strip('"\'')
    for k in ("KIT_RECEIPT_URL", "KIT_RECEIPT_TOKEN", "KIT_RECEIPT_ACTOR"):
        if os.environ.get(k):
            conf[k] = os.environ[k]
    return conf


def url_ok(url):
    """Plain http only to this machine or a Tailscale address; everything else needs https."""
    u = urllib.parse.urlparse(url)
    if u.scheme == "https":
        return True
    if u.scheme != "http" or not u.hostname:
        return False
    h = u.hostname
    if h in ("localhost",) or h.endswith(".ts.net"):
        return True
    try:
        ip = ipaddress.ip_address(h)
        return ip.is_loopback or ip in ipaddress.ip_network("100.64.0.0/10") or ip in ipaddress.ip_network("fd7a:115c:a1e0::/48")
    except ValueError:
        return False


def now_iso():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"


def base(actor, producer, event):
    return {"event_uid": str(uuid.uuid4()), "at": now_iso(), "host": socket.gethostname().split(".")[0],
            "actor": actor, "producer": producer, "event": event}


def from_hook(payload, actor):
    ev = payload.get("hook_event_name") or payload.get("event") or "hook"
    tool = payload.get("tool_name") or payload.get("tool") or ""
    ti = payload.get("tool_input") or {}
    tr = payload.get("tool_response")
    rec = base(actor, "claude-hook", ev)
    rec.update({"tool": tool, "session": payload.get("session_id"), "cwd": payload.get("cwd")})
    path = ti.get("file_path") or ti.get("notebook_path") or ti.get("path")
    if tool in ("Write", "Edit", "MultiEdit", "NotebookEdit"):
        rec.update(kind="Change", target=path, command=f"{tool} {path} (contents not logged)")
    elif tool in ("Read", "Grep", "Glob", "LS", "WebFetch", "WebSearch"):
        q = ti.get("pattern") or ti.get("url") or ti.get("query") or ""
        rec.update(kind="Read", target=path, command=f"{tool} {path or ''} {q}".strip())
    elif "command" in ti:
        rec.update(kind="Observed", command=str(ti.get("command")))
    else:
        rec.update(kind="Observed", command=f"{tool} {json.dumps(sorted(ti.keys()))}" if ti else tool)
    failed = ev.endswith("Failure")
    if isinstance(tr, dict):
        if tr.get("is_error") or tr.get("interrupted"):
            failed = True
        for k in ("exit_code", "exitCode", "returncode"):
            if isinstance(tr.get(k), int):
                rec["exit_code"] = tr[k]
                failed = failed or tr[k] != 0
    rec["ok"] = not failed
    return rec


def spool(rec):
    os.makedirs(STATE, mode=0o700, exist_ok=True)
    for k in ("command", "target", "cwd"):
        if rec.get(k) is not None:
            rec[k] = redact(str(rec[k]))
    rec = {k: v for k, v in rec.items() if v is not None and v != ""}
    fd = os.open(SPOOL, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
    with os.fdopen(fd, "a", encoding="utf-8") as f:
        fcntl.flock(f, fcntl.LOCK_EX)
        f.write(json.dumps(rec, separators=(",", ":")) + "\n")
    return rec


def note(msg):
    try:
        os.makedirs(STATE, mode=0o700, exist_ok=True)
        with open(ERRLOG, "a", encoding="utf-8") as f:
            f.write(f"{now_iso()} {msg}\n")
    except OSError:
        pass


def flush(verbose=False):
    """Send the spool oldest-first. Returns (sent, waiting)."""
    conf = settings()
    url, token = conf.get("KIT_RECEIPT_URL", ""), conf.get("KIT_RECEIPT_TOKEN", "")
    if not os.path.exists(SPOOL):
        return 0, 0
    if not url or not token:
        note("not sent: KIT_RECEIPT_URL / KIT_RECEIPT_TOKEN not set")
        return 0, sum(1 for _ in open(SPOOL, encoding="utf-8"))
    if not url_ok(url):
        note(f"not sent: {url} is plain http to a non-local address (use https or a Tailscale address)")
        return 0, sum(1 for _ in open(SPOOL, encoding="utf-8"))
    sent = 0
    with open(SPOOL, "r+", encoding="utf-8") as f:
        fcntl.flock(f, fcntl.LOCK_EX)
        lines = [l for l in f.read().splitlines() if l.strip()]
        while lines:
            chunk = lines[:BATCH]
            events = []
            for l in chunk:
                try:
                    events.append(json.loads(l))
                except ValueError:
                    note("dropped a spool line that is not JSON")
            req = urllib.request.Request(url, data=json.dumps({"events": events}).encode(), method="POST",
                                         headers={"content-type": "application/json", "authorization": f"Bearer {token}"})
            try:
                with urllib.request.urlopen(req, timeout=8) as r:
                    if r.status != 200:
                        raise urllib.error.HTTPError(url, r.status, "not 200", r.headers, None)
            except urllib.error.HTTPError as e:
                note(f"server answered {e.code}; {len(lines)} receipt(s) kept in the spool")
                break
            except (urllib.error.URLError, OSError) as e:
                note(f"server not reachable ({getattr(e, 'reason', e)}); {len(lines)} receipt(s) kept in the spool")
                break
            sent += len(chunk)
            lines = lines[BATCH:]
        f.seek(0)
        f.truncate()
        if lines:
            f.write("\n".join(lines) + "\n")
    if verbose:
        print(f"sent {sent}, waiting {len(lines)}")
    return sent, len(lines)


def flush_in_background():
    """Fork so the agent never waits on the network."""
    try:
        if os.fork() == 0:
            os.setsid()
            try:
                flush()
            finally:
                os._exit(0)
    except OSError:
        flush()


def main(argv):
    mode = argv[0] if argv else "help"
    conf_actor = None
    if mode == "hook":
        try:
            conf_actor = settings().get("KIT_RECEIPT_ACTOR")
            payload = json.loads(sys.stdin.read() or "{}")
            spool(from_hook(payload, (argv[1] if len(argv) > 1 else None) or conf_actor or "AI agent"))
            flush_in_background()
        except Exception as e:  # never break the agent
            note(f"hook error: {type(e).__name__}: {e}")
        return 0
    if mode == "shell":
        try:
            exit_code, cmd = argv[1], " ".join(argv[2:])
            if cmd.strip():
                rec = base(settings().get("KIT_RECEIPT_ACTOR") or os.environ.get("USER", "shell"), "shell", "command")
                rec.update(kind="Observed", command=cmd, cwd=os.getcwd(), ok=exit_code == "0",
                           exit_code=int(exit_code) if re.fullmatch(r"-?\d+", exit_code) else None)
                spool(rec)
                flush_in_background()
        except Exception as e:
            note(f"shell error: {type(e).__name__}: {e}")
        return 0
    if mode == "log":
        a = {argv[i][2:]: argv[i + 1] for i in range(1, len(argv) - 1, 2) if argv[i].startswith("--")}
        if not a.get("cmd"):
            print("usage: agent-receipt.py log --cmd TEXT [--actor NAME] [--target PATH] [--kind Read|Change]", file=sys.stderr)
            return 2
        rec = base(a.get("actor") or settings().get("KIT_RECEIPT_ACTOR") or os.environ.get("USER", "manual"), "log", "manual")
        rec.update(kind=a.get("kind") if a.get("kind") in ("Read", "Change") else "Observed",
                   command=a["cmd"], target=a.get("target"), cwd=os.getcwd(), ok=True)
        rec = spool(rec)
        sent, waiting = flush()
        print(f"{'LOGGED' if not waiting else 'SPOOLED (server not reachable; goes with the next send)'} {rec['event_uid']}")
        return 0
    if mode == "flush":
        flush(verbose=True)
        return 0
    if mode == "status":
        conf = settings()
        n = sum(1 for _ in open(SPOOL, encoding="utf-8")) if os.path.exists(SPOOL) else 0
        url = conf.get("KIT_RECEIPT_URL", "(not set)")
        print(f"sends to: {url}{'' if url_ok(url) else '  (REFUSED: plain http to a non-local address)'}")
        print(f"token:    {'set' if conf.get('KIT_RECEIPT_TOKEN') else 'NOT SET'} (never printed)")
        print(f"waiting:  {n} in {SPOOL}")
        if os.path.exists(ERRLOG):
            tail = open(ERRLOG, encoding="utf-8").read().splitlines()[-3:]
            if tail:
                print("last problems:\n  " + "\n  ".join(tail))
        return 0
    print(__doc__)
    return 0 if mode in ("help", "-h", "--help") else 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
