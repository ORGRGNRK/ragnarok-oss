# Remote power for a Windows PC over Tailscale: Wake-on-LAN + SSH shutdown

Runbook written 2026-10-23 by Claude Code (MacBook session `1de3c586`), after a working setup on the
"Jon PC". **Section 1 is for a Claude session**, sections 2–3 explain why the method works, section 4
is what happened here, and sections 5–9 are the step-by-step guide for replicating it, including what
to tell the user and how to troubleshoot.

Everything in section 4 was **observed** on 2026-10-23. Anything else is marked *(inferred)* or
*(general knowledge)*.

---

The machine-specific values (`<PC_MAC>`, `<PC_LAN_IP>`, `<PC_TAILNET_IP>`, the Windows login) live in
`~/.ragnarok/local.conf` as `WOL_MAC`, `WOL_LAN_IP`, `WOL_TAILNET_IP`, `WOL_SSH_USER`, `WOL_KEY`, `WOL_RELAY`.

## 1. If you are a Claude session reading this

You are being asked to make a remote Windows PC wake up and shut down on command, or to repair a
setup like that. Work through it in this order:

1. **Collect the facts in §5 (Phase 0).** Never guess a MAC address, an IP or a username. Read each
   one off the machine, or ask the user for it.
2. **Get a shell on the target (§5 Phase 1).** That step installs an SSH server and an authorized key
   on someone's computer. Claude Code's auto-mode safety check treats that as **persistence**: it
   refused to send these setup commands over Telegram (§4, step 3). Don't route around that refusal.
   Show the user the commands, or save them to a file on their screen, and let **the user** run them
   on the target. Check first whose machine it is (here every machine was the user's own).
3. **Read the hardware facts over SSH (§5 Phase 2)**, then **build the two scripts from §6**. Fill in
   the CONFIG block from the facts you read. Leave the code as it is.
4. **Test using the protocol in §7.** A test only counts if the PC is confirmed off *before* the
   packet goes out, and the user confirms nobody touched the power button.
5. **If the wake fails**, work through §8 in order. Don't change BIOS or power settings on someone
   else's machine without asking the user.
6. **Record the result**: what was verified, when, and how. Keep "sent" and "woke it" separate.
7. **Ask before** any destructive or hard-to-reverse step, or one that affects another person:
   turning off hibernation, changing the BIOS, deleting accounts.

---

## 2. How Wake-on-LAN works (general knowledge)

- **The magic packet** is 6 bytes of `FF` followed by the target's MAC address repeated 16 times,
  102 bytes in all. It's sent as UDP, usually to port 9 (sometimes 7) and to the subnet broadcast
  address. Neither the port nor the protocol really matters: the network card scans every frame it
  receives for that byte pattern.
- **Who listens:** when the PC is off or asleep, only the network card is powered. It reads frames on
  the wire and, when it sees its own MAC repeated 16 times, tells the motherboard to power on.
- **Why it must be sent from the same LAN:** the packet is a layer-2 broadcast inside one subnet, and
  routers don't forward broadcasts. A powered-off PC also has no IP stack and no Tailscale running,
  so **nothing sent over the tailnet can reach it**. The packet has to start on the target's own
  LAN. So the design uses a **relay**: an always-on machine on that LAN that sends the packet when
  asked over SSH.
- **Three things all have to be enabled:**
  1. **The network card driver** (Windows Device Manager → adapter → Power Management / Advanced):
     "Wake on Magic Packet" on.
  2. **The motherboard firmware (BIOS/UEFI):** a setting like "Wake on LAN", "Power On By PCI-E" or
     "Resume by LAN". Some boards also need "ErP / EuP / Deep Sleep" **turned off**, because that mode
     cuts power to the card when the PC is off.
  3. **The off state:** a real shutdown (S5) or sleep (S3) leaves the card armed. **Windows Fast
     Startup** turns "Shut down" into a hybrid hibernate (S4), and on *some* machines the card isn't
     armed in that state. On the Jon PC it **was** armed (§4, step 6), so Fast Startup didn't matter
     there. Don't assume either way. Test it.
- **Wired only, in practice:** Wake-on-LAN over Wi-Fi ("WoWLAN") rarely works from a full shutdown.
  Use Ethernet.

## 3. How this setup is built

```
 MacBook (anywhere)                    home LAN <home LAN>/24
 ─────────────────                     ───────────────────────────────────────────
  wol-jon.py ──ssh over tailnet──▶  Alexus (always on, Fedora, <ALEXUS_LAN_IP>)
                                       └─ python3 sender ──UDP broadcast──▶ Jon PC NIC
                                                                            <PC_MAC>
  wol-jon.py ◀──tailscale ping── (Jon PC boots, Tailscale starts, <PC_TAILNET_IP> answers)

  off-jon.py ──ssh (key auth, tailnet)──▶ Jon PC: shutdown /s /t 30 /c "<warning>"
  off-jon.py ◀──tailscale ping stops answering── "OFF"
```

| Role | This instance | What it needs |
|---|---|---|
| Controller | MacBook (macOS), runs both scripts | Python 3, `ssh`, Tailscale CLI at `/Applications/Tailscale.app/Contents/MacOS/Tailscale` |
| Relay | Alexus, `claude@alexus`, LAN <ALEXUS_LAN_IP> | Always on, wired to the target's LAN, `python3` (stdlib only), SSH reachable from the controller. **Nothing gets installed on it**: the sender code is piped to `python3 -` |
| Target | Jon PC `Jon-2--1_`, Windows, LAN <PC_LAN_IP>, tailnet <PC_TAILNET_IP> | Ethernet card with Wake on Magic Packet on; OpenSSH Server; the controller's public key; Tailscale set to start at boot |

## 4. What we did and what happened (2026-10-23, observed)

1. **Reached it on Tailscale.** `tailscale ping jon-2--1` got a pong. A port probe showed 22, 3389 and
   5985 closed and only 445 open, so there was no remote shell.
2. **Made a dedicated key** on the MacBook: `ssh-keygen -t ed25519 -N "" -f ~/.ssh/jon_ed25519`.
3. **Tried to send the OpenSSH setup block to the user over Telegram.** Claude Code's auto-mode
   safety check **refused** it ("Unauthorized Persistence"). Instead we wrote the block to
   `~/Desktop/jon-pc-ssh-setup.txt`, opened it in TextEdit and copied it to the clipboard. The user ran
   it in an admin PowerShell on the PC.
4. **Connected:** `ssh -i ~/.ssh/jon_ed25519 <login>@<PC_TAILNET_IP>` returned `<pc>\<login>`.
5. **Read the hardware facts** with `Get-NetAdapter -Physical`, `Get-NetAdapterPowerManagement` and the
   `HiberbootEnabled` registry value:
   - Intel I226-V, MAC `<PC_MAC>`, Up 1 Gbps, <PC_LAN_IP>
   - WakeOnMagicPacket **Enabled** (already on; nobody changed it)
   - HiberbootEnabled **1** (Fast Startup on)
6. **Wrote `wol-jon.py`.** First we sent with the PC awake, which proves the send path only. Then:
   - The user shut the PC down **from the Start menu**. The Windows log shows `13:20:06 Shutdown Off`.
   - At 13:20:17 Claude confirmed it was off: no tailnet pong, and no LAN ping from Alexus.
   - `wol-jon.py` sent the packet through Alexus.
   - **13:20:57 cold boot** (Kernel-Boot: `Soft boot: false`, boot type `0x0`), then a tailnet
     pong: `UP`.
   - The user, sitting at the PC: **"it turned on by itself."** Windows doesn't record what caused a
     cold boot, so this eyewitness account is what rules out the power button.
   - **Correction:** before the test, Claude had predicted Fast Startup would block the wake. That
     was carried over from a different machine (the living-room PC), and it was **wrong here**.
7. **Wrote `off-jon.py`.** The first version used `shutdown /s /full`. **This Windows build rejected
   `/full`**: it printed the usage text and did nothing. Its help text lists `/hybrid` as the Fast
   Startup variant, so plain `/s` is already a full shutdown. After the fix it printed `shutdown
   scheduled in 30s`, then `OFF` once the PC dropped off the tailnet.

## 5. Replication, step by step

### Phase 0: facts to collect

| Fact | How to get it | Example (this instance) |
|---|---|---|
| Target's Tailscale IP | `tailscale status` on the controller | <PC_TAILNET_IP> |
| Target's Windows username | `whoami` on the target (Phase 1 prints it) | `<pc>\<login>` → user `<login>` |
| Target's **wired** MAC + LAN IP | Phase 2 | <PC_MAC>, <PC_LAN_IP> |
| LAN broadcast address | LAN IP with the last octet set to 255, for a /24 (check the prefix length in Phase 2) | <LAN_BROADCAST> |
| Relay | Any always-on machine **on the same LAN**, reachable by SSH from the controller, with `python3` | `claude@alexus` |
| Whose machine is the target? | Ask the user | the user's own PC; if it belongs to someone else, ask before changing its settings |

No always-on relay? Use `--local` from a machine on the LAN, or a router that can send WoL (OpenWrt
`etherwake`, or most consumer routers' WoL page).

### Phase 1: a shell on the Windows target (the user does this part)

On the controller, make a key used only for this target:
```bash
ssh-keygen -t ed25519 -N "" -C "claude-code@<controller>-><target>" -f ~/.ssh/<target>_ed25519
cat ~/.ssh/<target>_ed25519.pub
```

Give the user the block below, with their public key in `$k`. Deliver it as a file on their screen or
on the clipboard; §1 says why it can't be sent over a messaging relay. Tell them:
**Start → type PowerShell → right-click → Run as administrator → paste → Enter.** Success looks like
`Online : True` on the first line and the account name on the last.

```powershell
Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
Start-Service sshd; Set-Service sshd -StartupType Automatic
New-NetFirewallRule -Name sshd-tailnet -DisplayName "OpenSSH (tailnet only)" -Direction Inbound -Protocol TCP -LocalPort 22 -RemoteAddress 100.64.0.0/10 -Action Allow
$k = '<PASTE THE ONE-LINE PUBLIC KEY HERE>'
New-Item -Force -ItemType Directory "$env:USERPROFILE\.ssh" | Out-Null; Add-Content "$env:USERPROFILE\.ssh\authorized_keys" $k
Add-Content C:\ProgramData\ssh\administrators_authorized_keys $k
icacls C:\ProgramData\ssh\administrators_authorized_keys /inheritance:r /grant "Administrators:F" /grant "SYSTEM:F"
whoami
```
- **Line 3** opens port 22 to Tailscale addresses only (CGNAT range 100.64.0.0/10), not the rest of
  the LAN.
- **Lines 5–7** put the key in both places: Windows OpenSSH reads `administrators_authorized_keys` for
  accounts in the Administrators group, and the per-user file for everyone else. Both are needed
  unless you know which kind of account it is. The `icacls` line is required: sshd ignores that file
  if anyone else can write to it.

Verify from the controller:
```bash
ssh -i ~/.ssh/<target>_ed25519 -o IdentitiesOnly=yes -o BatchMode=yes <user>@<tailnet-ip> whoami
```

### Phase 2: read the hardware facts (Claude does this over SSH)

The Windows default SSH shell is `cmd.exe`, which mangles nested quotes. **Send PowerShell as
`-EncodedCommand`** (UTF-16LE, then base64). One inline attempt in this session failed with
"The filename, directory name, or volume label syntax is incorrect."

```bash
PS='Get-NetAdapter -Physical | Format-Table Name,InterfaceDescription,MacAddress,Status,LinkSpeed -Auto | Out-String -Width 200
Get-NetIPAddress -AddressFamily IPv4 | Format-Table InterfaceAlias,IPAddress,PrefixLength -Auto | Out-String -Width 200
Get-NetAdapterPowerManagement -Name * -EA SilentlyContinue | Format-Table Name,WakeOnMagicPacket -Auto | Out-String -Width 200
"HiberbootEnabled=" + (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power").HiberbootEnabled'
ENC=$(printf '%s' "$PS" | iconv -t UTF-16LE | base64)
ssh -i ~/.ssh/<target>_ed25519 -o IdentitiesOnly=yes -o BatchMode=yes <user>@<tailnet-ip> "powershell -NoProfile -EncodedCommand $ENC"
```
Take the **wired** adapter: an "Ethernet" name, or an Intel / Realtek / Killer description, with
Status Up. Not Wi-Fi, Bluetooth or Tailscale. Write down its MAC, its LAN IPv4 and the prefix length
(24 means broadcast is `x.y.z.255`). If WakeOnMagicPacket isn't `Enabled`, see §8, step B2.

### Phase 3: build the scripts (§6)

Save them on the controller, for example as `~/scripts/wol-<target>.py` and `~/scripts/off-<target>.py`.
Fill in the CONFIG blocks, then `chmod +x` both.

### Phase 4: test (§7), then record the result

## 6. The scripts (templates; change only the CONFIG block)

### 6a. `wol-<target>.py`: wake

```python
#!/usr/bin/env python3
"""Wake <TARGET> with a Wake-on-LAN magic packet.

    wol-<target>.py            send from the relay (always on, same LAN), then wait for it on the tailnet
    wol-<target>.py --local    send from this machine instead (only works when it is on the target's LAN)
    wol-<target>.py --no-wait  send and exit

A magic packet is a LAN broadcast and a powered-off PC runs no Tailscale, so the packet must start
inside the target's LAN. The relay is asked over ssh; nothing is installed there: this file pipes its
own sender to `python3 -`.
"""
import subprocess
import sys
import time

# ---- CONFIG: fill from Phase 0/2; leave everything else as is ----
MAC = "AA-BB-CC-DD-EE-FF"          # target's WIRED adapter MAC
BROADCAST = "<LAN_BROADCAST>"        # target LAN broadcast
LAN_IP = "192.168.1.X"             # target's LAN IPv4 (directed copy of the packet)
TAILNET_IP = "100.X.Y.Z"           # target's Tailscale IP (to see it come up)
RELAY = "user@100.A.B.C"           # always-on machine ON THE TARGET'S LAN, reachable by ssh
TAILSCALE = "/Applications/Tailscale.app/Contents/MacOS/Tailscale"   # Linux: "tailscale"
# -------------------------------------------------------------------

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
    """Run the same sender here (--local) or on the relay; both get it on stdin."""
    cmd = ["python3", "-", MAC, BROADCAST, LAN_IP]
    if where == "relay":
        cmd = ["ssh", "-o", "ConnectTimeout=8", RELAY] + cmd
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
    print("no answer yet. Work through 'If it does not wake' in the runbook.")
    return False


if __name__ == "__main__":
    args = sys.argv[1:]
    send("this machine" if "--local" in args else "relay")
    if "--no-wait" not in args:
        sys.exit(0 if wait_for_it() else 1)
```

### 6b. `off-<target>.py`: shut down

```python
#!/usr/bin/env python3
"""Turn <TARGET> off over ssh. Pair: wol-<target>.py turns it back on.

    off-<target>.py              shutdown in 30 s (a warning pops up; anyone at the PC can cancel)
    off-<target>.py --now        shutdown immediately
    off-<target>.py --restart    restart in 30 s (add --now for immediately)
    off-<target>.py --cancel     cancel a shutdown/restart that is still counting down

Plain `shutdown /s` (without /hybrid) is a real shutdown even when Fast Startup is on. Do NOT add
/full: at least one Windows build rejects it and does nothing (observed 2026-10-23).
"""
import subprocess
import sys
import time

# ---- CONFIG ----
HOST = "user@100.X.Y.Z"                      # Windows account @ target's Tailscale IP
KEY = "/Users/<you>/.ssh/<target>_ed25519"   # the key from Phase 1
TAILNET_IP = "100.X.Y.Z"
TAILSCALE = "/Applications/Tailscale.app/Contents/MacOS/Tailscale"   # Linux: "tailscale"
DELAY = 30
WARNING = "Remote shutdown requested. Run 'shutdown /a' to cancel."
# ----------------


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
    print(f"{what} scheduled in {delay}s" + ("" if delay == 0 else " (cancel: --cancel)"))
    if "--restart" not in args:
        print("waiting for it to drop off the tailnet ...")
        print("OFF" if gone(delay + 120) else "still answering after the wait; check the PC")
```

The live copies for this instance are `~/scripts/wol-jon.py` and `~/scripts/off-jon.py` on the MacBook.
They are these templates with the values from §3 filled in.

## 7. Test protocol (what counts as proof)

1. **Prove the send path first**, with the target awake: `wol-<target>.py --no-wait`. It should print
   `magic packet sent …`. A packet to an awake PC is harmless. This proves the relay and SSH work,
   **not** that the PC will wake.
2. **Turn it off**, either with `off-<target>.py` or by having the user shut down from the Start menu.
   That second option is the stricter test, because it's the Fast Startup path.
3. **Confirm it's off before sending.** Two checks:
   ```bash
   tailscale ping -c 2 --timeout 3s <tailnet-ip>                                   # expect: timed out
   ssh <relay> 'ping -c 2 -W 1 <lan-ip> >/dev/null && echo still-on || echo off'  # expect: off
   ```
4. **Send:** `wol-<target>.py`. Expect `UP: pong from …` within about 30–90 seconds.
5. **Rule out a human:** ask the user whether anyone pressed the power button. Windows writes no
   wake-source event for a cold boot (`Power-Troubleshooter` only covers resume from sleep), so the
   log alone can't tell Wake-on-LAN apart from the button.
6. **Optional log check** (as an `-EncodedCommand`):
   ```powershell
   (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
   Get-WinEvent -FilterHashtable @{LogName="System"; StartTime=(Get-Date).AddMinutes(-15)} |
     Where-Object { $_.ProviderName -match "Power-Troubleshooter|Kernel-Boot|Kernel-General|Kernel-Power" } |
     Format-Table TimeCreated,ProviderName,Id -Auto
   ```
   The boot time should come just after the packet was sent. `Kernel-Boot 27` = boot type: `0x0`
   is a cold boot, `0x1` a Fast Startup resume.
7. **Record** what was verified and when, keeping "send verified" and "wake verified" separate.

## 8. If it does not wake: troubleshooting in order

Each step lists a cause, how to check it, and the fix. Stop at the first one that explains the
failure.

**A. The packet never left, or never reached the right LAN**
- A1. The script printed `could not send from relay` → SSH to the relay failed. Run
  `ssh <relay> true` and fix keys or Tailscale. As a stopgap, use `--local` from a machine on the
  target's LAN.
- A2. **The relay isn't on the target's LAN.** Compare `ip -4 addr` on the relay with the target's
  LAN IP and prefix. Two machines on the same tailnet can still be on different LANs. Pick a relay
  that's physically on the target's network.
- A3. **Wrong broadcast address** (the subnet isn't a /24). Work out the broadcast from the prefix
  length in Phase 2. The directed copy to `LAN_IP` usually still works for a while after power-off,
  until the router forgets the PC's address.
- A4. Relay firewall: outbound UDP is almost always allowed. Check with
  `sudo tcpdump -i any udp port 9` on a second LAN machine while sending.

**B. The packet arrived but the card wasn't listening**
- B1. **Wrong MAC**: the Wi-Fi or a virtual adapter's MAC instead of the wired card's. Re-run
  Phase 2 and use the **physical, wired** adapter.
- B2. **Windows driver setting:** `Get-NetAdapterPowerManagement -Name Ethernet` should show
  WakeOnMagicPacket `Enabled`. To enable it (admin; **ask the user first** if it isn't their PC):
  `Set-NetAdapterPowerManagement -Name Ethernet -WakeOnMagicPacket Enabled`. Also check Device
  Manager → adapter → Power Management: "Allow this device to wake the computer" and "Only allow a
  magic packet to wake the computer". Some drivers also have an Advanced property, "Wake on Magic
  Packet" or "Shutdown Wake-On-Lan", that must be Enabled:
  `Get-NetAdapterAdvancedProperty -Name Ethernet | Where-Object DisplayName -match "Wake"`.
- B3. **Fast Startup leaves the card unarmed** (true on some machines, not the Jon PC). Test with a
  real shutdown: `off-<target>.py`, which uses plain `/s`, then wake. If that works and a Start-menu
  shutdown doesn't, the fix is `powercfg /h off`, which turns off hibernation and Fast Startup. It's
  a change to the owner's machine and makes boots slightly slower, so ask first. Undo:
  `powercfg /h on`.
- B4. **The cable link drops at power-off.** If the switch-port or card link light goes dark when the
  PC is off, the card has no power. That points to the BIOS (C).

**C. Firmware (BIOS/UEFI): needs the user in front of the PC**
- C1. Enter the BIOS (usually Del or F2 at power-on). Enable "Wake on LAN", "Power On By PCI-E/PCI"
  or "Resume by LAN" (the name varies by board).
- C2. **Disable "ErP", "EuP 2013" or "Deep Sleep"**: these cut standby power to the card.
- C3. Onboard LAN must be enabled, and some boards also have a "LAN option ROM / PXE" setting that
  ties into Wake-on-LAN.
- C4. After a power cut or unplug, many boards won't wake until the PC has been powered on once
  normally. If the PSU was switched off at the wall, nothing will wake it.

**D. It woke, but the script says "no answer yet"**
- D1. Tailscale isn't starting at boot, or isn't up until someone logs in. Check whether the PC
  answers on the LAN from the relay (`ping <lan-ip>`). If it does, the wake worked. On the target,
  set the Tailscale service to Automatic and turn on its "Run unattended" option, so it connects
  before login.
- D2. A slow boot can take longer than 150 seconds. Re-run `tailscale ping` after a minute.

**E. Shutdown script failures**
- E1. `shutdown refused: Usage: …` means a switch this Windows build doesn't support (`/full` was
  one). Use plain `/s`.
- E2. `Permission denied (publickey)` means the key isn't in the file sshd reads. Admin accounts use
  `C:\ProgramData\ssh\administrators_authorized_keys`, and that file needs the `icacls` line from
  Phase 1.
- E3. A connection timeout means sshd isn't running (`Get-Service sshd`) or the firewall rule is
  missing (`Get-NetFirewallRule -Name sshd-tailnet`).

## 9. Undo / cleanup (to retire remote access)

Run on the target in an admin PowerShell:
```powershell
Stop-Service sshd; Remove-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
Remove-NetFirewallRule -Name sshd-tailnet
Remove-Item C:\ProgramData\ssh\administrators_authorized_keys
```
On the controller: delete `~/.ssh/<target>_ed25519` and its `.pub`, remove the target's line from
`~/.ssh/known_hosts`, and delete the two scripts. If `powercfg /h off` was used, restore it with
`powercfg /h on`. Remove Tailscale from the target and from the tailnet admin console if it was
installed only for this.

For this instance, the cleanup list is in Yggdrasil **Reminders Id 3**, and the verified facts are in
**Memories Id 89**.
