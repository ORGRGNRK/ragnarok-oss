#!/usr/bin/env python3
"""
Wake a Windows PC (set in ~/.ragnarok/local.conf) with a Wake-on-LAN magic packet.

    wol-jon.py            send from Alexus (always on, same LAN), then wait for it on the tailnet
    wol-jon.py --local    send from this machine instead (only works when it is on the home LAN)
    wol-jon.py --no-wait  send and exit

WHY IT GOES THROUGH ALEXUS: a magic packet is a LAN broadcast. A sleeping PC has no Tailscale
running, so nothing sent over the tailnet can reach it; the packet has to start inside
the home LAN. Alexus is always on and on that LAN, so the MacBook asks it to send.
No install is needed there: this file pipes its own sender to `python3 -` over ssh.

Facts read off the PC on 2026-10-23 (Get-NetAdapter over ssh):
  Intel(R) Ethernet Controller I226-V (MAC and LAN IP in local.conf), WakeOnMagicPacket Enabled.
  HiberbootEnabled = 1 (Windows Fast Startup ON).
VERIFIED 2026-10-23 13:20: woke the PC from a normal Start-menu shutdown with Fast Startup still on
(cold boot at 13:20:57, the owner watching). Full write-up: ~/scripts/WOL-RUNBOOK.md
"""
import socket
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


# The PC's facts live in ~/.ragnarok/local.conf: WOL_MAC, WOL_LAN_IP, WOL_TAILNET_IP, optional WOL_BROADCAST
# (default: LAN_IP with the last number 255) and WOL_RELAY (an always-on login on the same LAN; default claude@alexus).
MAC = _conf("WOL_MAC") or sys.exit("set WOL_MAC in ~/.ragnarok/local.conf")
LAN_IP = _conf("WOL_LAN_IP") or sys.exit("set WOL_LAN_IP in ~/.ragnarok/local.conf")
BROADCAST = _conf("WOL_BROADCAST") or LAN_IP.rsplit(".", 1)[0] + ".255"
TAILNET_IP = _conf("WOL_TAILNET_IP") or sys.exit("set WOL_TAILNET_IP in ~/.ragnarok/local.conf")
ALEXUS = _conf("WOL_RELAY", "claude@alexus")
TAILSCALE = "/Applications/Tailscale.app/Contents/MacOS/Tailscale"

SENDER = r'''
import socket, sys
mac, bcast, ip = sys.argv[1:4]
payload = b"\xff" * 6 + bytes.fromhex(mac.replace("-", "").replace(":", "")) * 16
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
for port in (9, 7):
    s.sendto(payload, (bcast, port))   # subnet broadcast
    s.sendto(payload, (ip, port))      # directed, in case the router keeps a stale ARP entry
print(f"magic packet sent for {mac} to {bcast} and {ip} (ports 9, 7)")
'''


def send(where):
    """Run the same sender here (--local) or on Alexus; both get it on stdin."""
    cmd = ["python3", "-", MAC, BROADCAST, LAN_IP]
    if where == "alexus":
        cmd = ["ssh", "-o", "ConnectTimeout=8", ALEXUS] + cmd
    r = subprocess.run(cmd, input=SENDER, text=True, capture_output=True)
    sys.stdout.write(r.stdout)
    if r.returncode != 0:
        sys.exit(f"could not send from {where}: {r.stderr.strip() or r.returncode}")


def wait_for_it(seconds=150):
    print(f"waiting up to {seconds}s for {TAILNET_IP} on the tailnet ...")
    deadline = time.time() + seconds
    while time.time() < deadline:
        r = subprocess.run([TAILSCALE, "ping", "-c", "1", "--timeout", "3s", TAILNET_IP],
                           capture_output=True, text=True)
        if r.returncode == 0 and "pong" in r.stdout:
            print("UP:", r.stdout.strip().splitlines()[-1])
            return True
        time.sleep(5)
    print("no answer yet. Work through 'If it does not wake' in ~/scripts/WOL-RUNBOOK.md.")
    return False


if __name__ == "__main__":
    args = sys.argv[1:]
    send("this machine" if "--local" in args else "alexus")
    if "--no-wait" not in args:
        sys.exit(0 if wait_for_it() else 1)
