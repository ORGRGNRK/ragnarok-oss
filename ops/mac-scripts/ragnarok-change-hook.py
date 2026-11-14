#!/usr/bin/env python3
"""RETIRED 2026-11-02: no longer a hook. Its receiver on Alexus (ssh claude@alexus change -> ragnarok log-change) was gone,
so entries only piled up in ~/.ragnarok/change-queue.jsonl. Its read-back check (Confirmed) and ssh host tag now live in
connector/ygg-business/hooks/mac-receipts/receipt.mjs, which writes to the receipts log on Alexus; the 739 queued
entries were imported there (source change-hook-queue). Kept for history only.

Claude Code PostToolUse hook: receipt every change a session makes to a machine.

Reads the hook JSON on stdin. File writes/edits always count; a Bash command
counts when it runs a state-changing verb (rm, mv, chmod, kill, git push,
installs, service changes...) or redirects output into a file, including
inside an ssh command. Reads are ignored, and so is the session scratchpad.

A file write or edit is also read back from disk after the tool ran (a hash for
Write, the new text for Edit) and sent as `verified`; only a change read back
this way is Confirmed, everything else is Observed (Ruleset R-75).

Each change is queued in ~/.ragnarok/change-queue.jsonl, then a detached
flusher sends the queue to Alexus (`ssh claude@alexus change`, the forced
command) where `ragnarok log-change` writes the receipt. If Alexus is
unreachable the entry stays queued and goes with the next flush, so nothing
is dropped quietly. The hook itself never blocks or fails a tool call.

  ragnarok-change-hook.py           hook mode (stdin = hook JSON)
  ragnarok-change-hook.py --flush   send whatever is queued
"""
import fcntl
import hashlib
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

DIR = Path.home() / ".ragnarok"
QUEUE = DIR / "change-queue.jsonl"
REJECTED = DIR / "change-rejected.jsonl"
FLUSH_LOG = DIR / "change-flush.log"
KEY = Path.home() / ".ssh" / "alexus"
ACTOR = "Claude Code"

VERBS = {"rm", "rmdir", "unlink", "shred", "mv", "cp", "chmod", "chown", "chgrp", "chattr", "setfacl", "ln", "mkdir",
         "touch", "truncate", "dd", "tee", "install", "kill", "pkill", "killall", "crontab",
         "rsync", "scp", "useradd", "usermod", "userdel", "groupadd", "passwd", "chsh", "dnf", "apt", "apt-get", "flatpak",
         "nmcli", "firewall-cmd", "restorecon", "ssh-keygen", "sudoedit"}
# Tools whose read subcommands (systemctl status/cat/list-timers, podman ps) used
# to be receipted as changes. Only these subcommands count (2026-10-23, R-75).
_CONTAINER = {"run", "rm", "rmi", "stop", "start", "restart", "kill", "create", "pull", "build", "update", "rename",
              "pause", "unpause", "commit", "tag", "push", "load", "import"}
SUBVERBS = {
    "systemctl": {"start", "stop", "restart", "try-restart", "reload", "reload-or-restart", "enable", "disable",
                  "reenable", "mask", "unmask", "daemon-reload", "kill", "set-property", "edit", "reset-failed", "link",
                  "preset", "isolate", "revert"},
    "launchctl": {"load", "unload", "bootstrap", "bootout", "enable", "disable", "kickstart", "kill", "start", "stop",
                  "remove", "submit"},
    "podman": _CONTAINER, "docker": _CONTAINER,
    "semanage": {"-a", "-d", "-m", "-D"},
    "git": {"commit", "push", "reset", "checkout", "switch", "rebase", "merge", "clean", "rm", "mv", "stash", "tag",
            "branch", "restore", "pull", "am", "apply", "cherry-pick", "revert", "init", "clone"},
    "brew": {"install", "uninstall", "upgrade", "reinstall", "tap", "untap", "services", "link", "unlink"},
    "npm": {"install", "i", "uninstall", "ci", "update", "link"},
    "pip": {"install", "uninstall"}, "pip3": {"install", "uninstall"},
    "tailscale": {"up", "down", "set", "serve", "funnel", "logout"},
    "defaults": {"write", "delete"},
    "sed": {"-i"}, "perl": {"-i", "-pi"},
}
DELETE = {"rm", "rmdir", "unlink", "shred", "userdel", "git rm", "git clean", "brew uninstall", "npm uninstall",
          "pip uninstall", "pip3 uninstall", "defaults delete", "curl DELETE"}
CURL_SENDS = {"-d", "--data", "--data-raw", "--data-binary", "--json", "-F", "--form", "-T", "--upload-file"}
# Claude Code's session scratchpad: temporary working files, not changes to the machine.
SCRATCH = re.compile(r"^(?:/private)?/tmp/claude-\d+/")
CREATE = {"mkdir", "touch", "useradd", "groupadd", "git init", "git clone"}
WRAPPERS = {"sudo", "exec", "time", "nohup", "env", "command", "builtin", "xargs"}
SUDO_ARG_FLAGS = {"-u", "-g", "-C", "-D", "-h", "-p", "-r", "-t", "-U"}
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


HOSTS = {h: "alexus" for h in ("alexus", _local_conf("ALEXUS_HOST"), _local_conf("ALEXUS_TAILSCALE")) if h}


def classify(cmd):
    """Return (action, target) for a state-changing command, else None."""
    hits = []
    for seg in re.split(r"[;&|\n`'\"(){}]|\$\(", cmd):
        w = seg.split()
        while w and (re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", w[0]) or w[0] in WRAPPERS or w[0].startswith("$")):
            if w[0] == "sudo":
                w = w[1:]
                while w and w[0].startswith("-"):
                    w = w[2:] if w[0] in SUDO_ARG_FLAGS else w[1:]
            else:
                w = w[1:]
        if not w:
            continue
        verb = os.path.basename(w[0])
        args = w[1:]
        if verb == "curl":
            # An HTTP write (the :4200 intents PATCHes went unreceipted until 2026-10-23).
            # Quotes split the segment, so the URL is taken from the whole command.
            meth = re.search(r"(?:-X|--request)\s*(POST|PUT|PATCH|DELETE)\b", seg)
            if not meth and not any(a in CURL_SENDS for a in args):
                continue
            url = re.search(r"https?://[^\s'\"]+", cmd)
            hits.append(("curl " + (meth.group(1) if meth else "POST"), [url.group(0)] if url else []))
            continue
        if verb in VERBS:
            name = verb
        elif verb in SUBVERBS and any(a in SUBVERBS[verb] for a in args[:5]):
            sub = next(a for a in args[:5] if a in SUBVERBS[verb])
            name = f"{verb} {sub}" if not sub.startswith("-") else verb + " -i"
        else:
            continue
        if name == "ssh-keygen" and "-R" not in args:
            continue  # only removing a known host changes anything
        targets = [a for a in args if not a.startswith("-") and a not in SUBVERBS.get(verb, ())]
        hits.append((name, targets))
    m = re.search(r"(?<![<0-9&>=-])>>?\s*(?!&|/dev/null)([~/\w.$][^\s;|&'\")]*)", cmd)
    if m:
        hits.append(("redirect", [m.group(1)]))
    if not hits:
        return None
    names = {h[0] for h in hits}
    if names & DELETE or ("ssh-keygen" in names):
        action = "Deleted"
    elif names <= CREATE:
        action = "Created"
    else:
        action = "Updated"
    first = next((h for h in hits if h[0] in DELETE), hits[0])
    target = " ".join(first[1])[:200] or first[0]
    return action, target


def host_of(cmd):
    m = re.match(r"\s*(?:\S+=\S+\s+)*(ssh|scp|rsync)\b(.*)", cmd, re.S)
    if m:
        for tok in re.split(r"[\s'\"]+", m.group(2)):
            h = tok.split("@")[-1].split(":")[0]
            if h in HOSTS:
                return HOSTS[h]
            if re.fullmatch(r"alexus(\.[\w.-]+)?", h):
                return "alexus"
    return "macbook"


def verify_file(tool, ti, path):
    """Read the file back after the tool ran (R-75). Returns {"ok", "how"}, or None
    when this edit cannot be checked from the file alone (a pure deletion, a notebook)."""
    try:
        data = Path(path).read_bytes()
    except OSError as ex:
        return {"ok": False, "how": f"file not readable after the tool ran ({ex.__class__.__name__})"}
    if tool == "Write":
        want = (ti.get("content") or "").encode()
        got = hashlib.sha256(data).hexdigest()
        if got == hashlib.sha256(want).hexdigest():
            return {"ok": True, "how": f"file sha256 {got[:12]} equals the content written"}
        return {"ok": False, "how": f"file sha256 {got[:12]} differs from the content written"}
    if tool not in ("Edit", "MultiEdit"):
        return None
    text = data.decode("utf-8", errors="replace")
    edits = ti.get("edits") if tool == "MultiEdit" else [ti]
    news = [e.get("new_string") or "" for e in edits or []]
    if not news or any(not n for n in news):
        return None
    missing = sum(1 for n in news if n not in text)
    if missing:
        return {"ok": False, "how": f"{missing} of {len(news)} new_string(s) not found in the file"}
    for e in edits:
        old = e.get("old_string") or ""
        if e.get("replace_all") and old and old not in (e.get("new_string") or "") and old in text:
            return {"ok": False, "how": "old_string still present after replace_all"}
    return {"ok": True, "how": f"{len(news)} new_string(s) found in the file"}


def entry_for(ev):
    tool = ev.get("tool_name", "")
    ti = ev.get("tool_input") or {}
    tr = ev.get("tool_response") or {}
    result = "error" if isinstance(tr, dict) and (tr.get("interrupted") or tr.get("is_error")) else "ok"
    verified = None
    if tool in ("Write", "Edit", "MultiEdit", "NotebookEdit"):
        path = ti.get("file_path") or ti.get("notebook_path") or "?"
        if SCRATCH.match(path):
            return None
        if result == "ok":
            verified = verify_file(tool, ti, path)
        if tool == "Write":
            action = "Created" if isinstance(tr, dict) and tr.get("type") == "create" else "Updated"
            command = f"write {len(ti.get('content') or '')} chars"
        else:
            action = "Updated"
            command = f"{tool.lower()} (contents not logged)"
        host, target = "macbook", path.replace(str(Path.home()), "~", 1)
    elif tool == "Bash":
        command = ti.get("command") or ""
        c = classify(command)
        if not c:
            return None
        action, target = c
        if SCRATCH.match(target):
            return None
        host = host_of(command)
    else:
        return None
    e = {"host": host, "action": action, "target": target, "tool": tool, "command": command,
         "cwd": ev.get("cwd", ""), "result": result, "at": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
         "actor": ACTOR, "session": ev.get("session_id") or "unknown",
         # source layer (2026-10-26): which program and machine this receipt comes from
         "source": {"agent": "Claude Code", "surface": "Claude Code PostToolUse hook (ssh claude@alexus change)",
                    "machine": "the owner's Mac (macbook)"}}
    if verified is not None:
        e["verified"] = verified
    return e


def locked(path, fn, blocking=True):
    DIR.mkdir(parents=True, exist_ok=True)
    with open(path, "a+") as lf:
        try:
            fcntl.flock(lf, fcntl.LOCK_EX | (0 if blocking else fcntl.LOCK_NB))
        except BlockingIOError:
            return None
        return fn()


def enqueue(e):
    def go():
        with open(QUEUE, "a") as q:
            q.write(json.dumps(e) + "\n")
    locked(DIR / "queue.lock", go)


def note(msg):
    with open(FLUSH_LOG, "a") as f:
        f.write(time.strftime("%Y-%m-%d %H:%M:%S ") + msg + "\n")


def flush():
    def go():
        sent = 0
        while True:
            lines = locked(DIR / "queue.lock", lambda: QUEUE.read_text().splitlines() if QUEUE.exists() else [])
            lines = [l for l in lines if l.strip()]
            if not lines:
                return
            head = lines[0]
            try:
                r = subprocess.run(["ssh", "-i", str(KEY), "-o", "IdentitiesOnly=yes", "-o", "BatchMode=yes",
                                    "-o", "ConnectTimeout=8", "claude@alexus", "change"],
                                   input=head, capture_output=True, text=True, timeout=60)
                out = (r.stdout + r.stderr).strip()
            except Exception as ex:  # unreachable: keep it queued for next time
                note(f"HELD -- {ex}")
                return
            if r.returncode == 0 and out.startswith("CHANGE LOGGED"):
                note(out)
                sent += 1
            elif "CHANGE NOT LOGGED" in out:
                with open(REJECTED, "a") as f:
                    f.write(json.dumps({"entry": json.loads(head), "reason": out}) + "\n")
                note(f"REJECTED -- {out}")
            else:
                note(f"HELD (exit {r.returncode}) -- {out[:300]}")
                return

            def drop():
                cur = QUEUE.read_text().splitlines()
                if cur and cur[0] == head:
                    tmp = QUEUE.with_suffix(".tmp")
                    tmp.write_text("".join(l + "\n" for l in cur[1:]))
                    os.replace(tmp, QUEUE)
            locked(DIR / "queue.lock", drop)
    locked(DIR / "flush.lock", go, blocking=False)


def main():
    if sys.argv[1:] == ["--flush"]:
        flush()
        return
    try:
        e = entry_for(json.load(sys.stdin))
        if e:
            enqueue(e)
            subprocess.Popen([sys.executable, "-I", os.path.abspath(__file__), "--flush"], start_new_session=True,
                             stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except Exception as ex:
        try:
            note(f"HOOK ERROR -- {ex!r}")
        except Exception:
            pass


if __name__ == "__main__":
    main()
    sys.exit(0)
