# ops/mac-scripts — the Mac's ~/scripts

`~/scripts` on the Mac is a link to this folder (since 2026-11-02), so Claude Code's hooks
(`~/.claude/settings.json`), the launch agents (log-ship, business-sync) and anything else using `~/scripts/...`
run the code in this repo. Edit here; there is no other copy.

Claude Code hooks that live here: evidence-rules.py, drift-check.py, premise-check.py (UserPromptSubmit),
ragnarok-change-hook.py (PostToolUse), evidence-audit.py and premise-check.py --answer (Stop), and
ragnarok-hq-mcp.sh (the ragnarok-hq MCP server over ssh). `*.bak-*` files are older versions kept as they were.

## alexus-tunnel

The databases run on Alexus. `alexus-tunnel` (LaunchAgent `co.rgnrk.alexus-tunnel`, installed by `alexus-tunnel-install`)
forwards the Mac's 127.0.0.1 ports in `PORTS=` to the same ports on Alexus over ssh, so anything on the Mac that
used a local port keeps working. To change the ports, edit `PORTS=`, then run
`launchctl kickstart -k gui/$(id -u)/co.rgnrk.alexus-tunnel`.

## screen-recording-ship

macOS screen recordings save into `~/Screen-Recordings` and, once the file has stopped growing, copy to `<you>@alexus:~/screen-recordings` (mode 0700). The local file is removed only after the remote size matches. Install: `screen-recording-ship.sh install` (LaunchAgent `co.rgnrk.screen-recording-ship`). Log: `~/Library/Logs/screen-recording-ship.log`. Test: `screen-recording-ship-test.sh`.

- At home it uses OpenSSH on alexus's current private LAN endpoint (looked up from Tailscale each run, not pinned), key `~/.ssh/id_ed25519`.
- Away from home it tries alexus's tailnet address at most once every 10 minutes with a 12 second limit. Tailscale SSH asks for a browser check; while that is pending the file waits. Pass the check (`ssh alexus` in a terminal, open the link) and the next try ships it.
- The save location is shared with screenshots. Anything in `~/Screen-Recordings` that is not a video is moved back to the Desktop within seconds.
- A launch agent cannot list the Desktop (macOS privacy), so recordings on the Desktop are only picked up when the script is run by hand in a terminal, and only if newer than the install. To send an older one, move it into `~/Screen-Recordings`.
- The run record for that recording (`~/.ragnarok/agents/<id>/state.json`) is copied to `screen-recordings/runs/<stored-name>/` next to the video. A later pass sends it again when that run still overlaps the recording and the file has changed, so a run that finishes after the video shipped still arrives. If that copy fails, the checkpoint stays put and the next pass tries the same file again. The pass remembers the bytes it uploaded for each recording, so a record that changes while the copy is going out is sent on the next pass. One recording's successful copy does not count for another recording of the same run. A run that does not overlap is left where it is, and does not open a login. Alexus cuts the short clip from that record into `~/screen-recording-clips`, using the checkout copy `~/Developer/ragnarok/ops/alexus/screen-recording-clip.py`. The raw recording is not changed. See `ops/alexus/README.md`.

## bambu-slice

Slices a model for the P1S with the Bambu Studio on Alexus, over ssh as `claude@`, and checks the result. It makes a file and never
talks to the printer. Defaults: PETG, 0.16 mm, 100% infill. See `--help` and `ops/alexus/bambustudio/README.md`.
