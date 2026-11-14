#!/usr/bin/env python3
"""
Turn the Jon PC (Jon-2--1_) off over ssh. Pair: wol-jon.py turns it back on.

    off-jon.py              shutdown in 30 s (a warning pops up; anyone at the PC can cancel)
    off-jon.py --now        full shutdown immediately
    off-jon.py --restart    restart in 30 s (add --now for immediately)
    off-jon.py --cancel     cancel a shutdown/restart that is still counting down

WHY plain /s: Windows Fast Startup is ON on this PC (HiberbootEnabled=1, read 2026-10-23). The Start-menu
"shut down" is then a hybrid hibernate; `shutdown /s` WITHOUT /hybrid is a real shutdown (this
build has no /full switch -- it rejected it 2026-10-23). WoL was verified to wake it either way,
and Fast Startup is left on.

Connects as WOL_SSH_USER@WOL_TAILNET_IP with WOL_KEY (OpenSSH Server set up 2026-10-23).
VERIFIED 2026-10-23 ~13:24. Full write-up: ~/scripts/WOL-RUNBOOK.md
"""
import subprocess
import sys
import time

def _conf(key, default=""):
    """One KEY=value from ~/.ragnarok/local.conf (read only, never run)."""
    try:
        for line in open(__import__("os").path.expanduser("~/.ragnarok/local.conf"), encoding="utf-8"):
            k, sep, v = line.strip().partition("=")
            if sep and not k.startswith("#") and k.strip() == key:
                default = v.strip().strip("\"'")
    except OSError:
        pass
    return default


# From ~/.ragnarok/local.conf: WOL_TAILNET_IP, WOL_SSH_USER (the Windows login), WOL_KEY (default ~/.ssh/id_ed25519).
TAILNET_IP = _conf("WOL_TAILNET_IP") or sys.exit("set WOL_TAILNET_IP in ~/.ragnarok/local.conf")
HOST = _conf("WOL_SSH_USER") or sys.exit("set WOL_SSH_USER in ~/.ragnarok/local.conf") + "@" + TAILNET_IP
KEY = __import__("os").path.expanduser(_conf("WOL_KEY", "~/.ssh/id_ed25519"))
TAILSCALE = "/Applications/Tailscale.app/Contents/MacOS/Tailscale"
DELAY = 30
WARNING = "Remote shutdown from the owner's Mac. Run 'shutdown /a' to cancel."


def run(cmd):
    return subprocess.run(["ssh", "-i", KEY, "-o", "IdentitiesOnly=yes", "-o", "BatchMode=yes",
                           "-o", "ConnectTimeout=8", HOST, cmd], capture_output=True, text=True)


def gone(seconds=120):
    deadline = time.time() + seconds
    while time.time() < deadline:
        r = subprocess.run([TAILSCALE, "ping", "-c", "1", "--timeout", "3s", TAILNET_IP],
                           capture_output=True, text=True)
        if "pong" not in r.stdout:
            return True
        time.sleep(5)
    return False


if __name__ == "__main__":
    args = sys.argv[1:]
    if "--cancel" in args:
        r = run("shutdown /a")
        print("cancelled" if r.returncode == 0 else f"nothing to cancel ({(r.stderr or r.stdout).strip()})")
        sys.exit(r.returncode)
    delay = 0 if "--now" in args else DELAY
    action = "/r" if "--restart" in args else "/s"
    r = run(f'shutdown {action} /t {delay} /c "{WARNING}"')
    if r.returncode != 0:
        sys.exit(f"shutdown refused: {(r.stderr or r.stdout).strip() or r.returncode}")
    what = "restart" if "--restart" in args else "shutdown"
    print(f"{what} scheduled in {delay}s" + ("" if delay == 0 else " (cancel: off-jon.py --cancel)"))
    if "--restart" not in args:
        print("waiting for it to drop off the tailnet ...")
        print("OFF" if gone(delay + 120) else "still answering after the wait; check the PC")
