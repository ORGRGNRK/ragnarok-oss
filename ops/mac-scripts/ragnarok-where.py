#!/usr/bin/env python3
"""
RAGNAROK where-am-I -- which computer the session is actually working on, and in which folder.

WHY (owner, 2026-10-23): "is there a way to make the hook show for both of us and have it put the
current computer and cwd everytime it switches?" Claude Code's own cwd is always the MacBook's, but
half the work happens through `ssh` on Alexus or the Jon PC, and nothing on screen said so. The turn
envelope only reached the model (additionalContext), never the owner.

Three entry points, one state file per session (~/.claude/ragnarok-where/<session>.json):

  track   PostToolUse hook on Bash. Reads the command that just ran: the LAST `ssh [opts] target`
          in it is where the work happened (a `cd DIR` inside the remote command gives the folder);
          no ssh means the MacBook and the session cwd. When the machine or folder differs from the
          last command's, it tells BOTH sides: systemMessage to the owner, additionalContext to the model.
  status  statusLine command. Prints "📍 machine · cwd · lane" from the state file (falls back to
          this Mac and the workspace dir before any command has run).
  line    Imported by ragnarok-turn-context.py for the envelope's machine line.

It reads command TEXT, so it can be wrong: an ssh inside a quoted string or a heredoc counts, and a
remote `cd` in a subshell does not undo. It only ever says where the last command pointed.
"""
import json
import os
import re
import shlex
import socket
import subprocess
import sys

STATE_DIR = os.path.expanduser("~/.claude/ragnarok-where")
BOOT_DIR = os.environ.get("RAGNAROK_BOOT_STATE", os.path.expanduser("~/.claude/boot-state"))
HOME = os.path.expanduser("~")

# Tailnet addresses to the names the owner uses for them (tailscale status, 2026-10-23).
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


# Addresses -> the names the owner uses, from ~/.ragnarok/local.conf: ALEXUS_HOST / ALEXUS_TAILSCALE, and
# HOST_NAMES=addr:name,addr:name for other machines (e.g. a PC or tablet on the tailnet).
NAMES = {h: "alexus" for h in (_local_conf("ALEXUS_HOST"), _local_conf("ALEXUS_TAILSCALE")) if h}
for _pair in _local_conf("HOST_NAMES").split(","):
    if ":" in _pair:
        NAMES[_pair.rsplit(":", 1)[0].strip()] = _pair.rsplit(":", 1)[1].strip()
# ssh options that take a value (man ssh), so the value is not mistaken for the target.
SSH_ARG_OPTS = set("BbcDEeFIiJLlmOoPpQRSWw")


def local_name():
    # socket.gethostname() returns 'unknown<hex>' on this Mac; macOS's own LocalHostName is reliable.
    try:
        name = subprocess.run(["scutil", "--get", "LocalHostName"], capture_output=True,
                              text=True, timeout=2).stdout.strip()
    except Exception:
        name = ""
    name = name or socket.gethostname().split(".")[0]
    return "macbook" if "macbook" in name.lower() else (name.lower() or "this-mac")


def safe(session):
    # Same rule as ragnarok-turn-context.py safe_name, so both find the same boot stamp.
    return "".join(c for c in str(session) if c.isalnum() or c in "-_")[:64] or "unknown"


def read(path):
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    except Exception:
        return {}


def write(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(data, fh)
    os.replace(tmp, path)


def short(path):
    return "~" + path[len(HOME):] if path and path.startswith(HOME) else (path or "unknown")


def ssh_target(command):
    """(machine, user, remote_cwd) for the last ssh in the command, or None."""
    try:
        tokens = shlex.split(command, posix=True)
    except ValueError:
        tokens = command.split()
    found = None
    i = 0
    while i < len(tokens):
        if os.path.basename(tokens[i]) == "ssh":
            j = i + 1
            while j < len(tokens) and tokens[j].startswith("-"):
                opt = tokens[j]
                if len(opt) == 2 and opt[1] in SSH_ARG_OPTS:
                    j += 1  # skip the option's value
                j += 1
            if j < len(tokens):
                target = tokens[j]
                user, _, host = target.rpartition("@")
                remote = tokens[j + 1] if j + 1 < len(tokens) else ""
                m = re.search(r"(?:^|[;&|(\s])cd\s+([^\s;&|)]+)", remote)
                found = (NAMES.get(host, host), user or None, m.group(1) if m else "~")
                i = j
        i += 1
    return found


def where_from(command, session_cwd):
    hit = ssh_target(command or "")
    if hit:
        machine, user, cwd = hit
        return {"machine": machine, "user": user, "cwd": cwd, "via": "ssh"}
    return {"machine": local_name(), "user": None, "cwd": short(session_cwd), "via": "local"}


def label(w):
    who = f"{w['user']}@" if w.get("user") else ""
    return f"{who}{w.get('machine', '?')} · {w.get('cwd', '?')}"


def line(session, session_cwd):
    """Envelope line: where the LAST command ran (not where the next one will)."""
    w = read(os.path.join(STATE_DIR, safe(session) + ".json"))
    if not w:
        return f"machine: {local_name()} (no command run yet) · cwd {short(session_cwd)}"
    return f"machine (last command): {label(w)}"


def track():
    payload = json.loads(sys.stdin.read())
    if payload.get("tool_name") != "Bash":
        return
    session = payload.get("session_id")
    path = os.path.join(STATE_DIR, safe(session) + ".json")
    cmd = (payload.get("tool_input") or {}).get("command", "")
    now = where_from(cmd, payload.get("cwd"))
    before = read(path)
    write(path, now)
    if before and (before.get("machine"), before.get("cwd")) == (now["machine"], now["cwd"]):
        return
    text = f"📍 now on {label(now)}" + (f"  (was {label(before)})" if before else "")
    print(json.dumps({
        "systemMessage": text,
        "hookSpecificOutput": {"hookEventName": "PostToolUse", "additionalContext": text},
    }))


def status():
    payload = json.loads(sys.stdin.read() or "{}")
    session = payload.get("session_id")
    cwd = (payload.get("workspace") or {}).get("current_dir") or payload.get("cwd")
    w = read(os.path.join(STATE_DIR, safe(session) + ".json")) or where_from("", cwd)
    lane = read(os.path.join(BOOT_DIR, safe(session) + ".json")).get("confirmed_lane")
    print(f"📍 {label(w)}" + (f" · {lane}" if lane else " · not booted"))


if __name__ == "__main__":
    try:
        {"track": track, "status": status}[sys.argv[1]]()
    except Exception:
        pass  # never cost a prompt or a tool call
    sys.exit(0)
