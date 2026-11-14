# ops/alexus/ — server scripts for the alexus box

**Holds:** copies of the 8 loose shell scripts that were sitting in `~/Developer/`. The originals were left in place (copied, not moved).

| Script | Rough purpose |
|---|---|
| activate-trunk-alexus.sh | activate the "trunk" setup on alexus |
| bootstrap-alexus.sh | first-time setup (sudo, LUKS/dracut) |
| deploy-to-alexus.sh | deploy to alexus |
| launch-alexus-hq.sh | start HQ |
| launch-alexus-trunk.sh | start trunk |
| lock-ai-identities.sh | lock down the AI user accounts |
| open-hq-nocodb.sh | open the NocoDB UI on HQ (note: fetches the DB password over SSH and prints it on screen) |
| setup-ai-users-alexus.sh | create the AI user accounts |

Checked 2026-10-30: no hardcoded secrets found in any of them.

## Short clips from screen recordings

A raw screen recording is the whole session, and most of it is waiting. The short clip is the run told in order, as jump cuts: the ask at the start, each plan step as it is marked completed, the agent's own said lines, the test command, the command that runs the work, a handoff between AIs, and the end product when the recording reaches the final answer.

The times come from the agent run's record, `state.json`. The plan ticks, the said lines, the test command, and the handoffs are receipts in that file (`at`, `kind`, `what`). The end product is the record's `final` answer, and only when that answer was said as the run finished. An earlier progress line is left out. How the work ran is a command that runs what the plan describes. A connection check is not that command. Changing a file's mode, making a directory, or linting a plist is not that command either. Nothing in the clip is chosen by watching the video. Each piece has a small caption burned in: what the piece is, and the clock time.

The Mac copies that record up next to the recording. `screen-recording-clip.py` on alexus cuts the pieces with ffmpeg and joins them. On alexus the script that runs is the one in the checkout `~/Developer/ragnarok/ops/alexus/screen-recording-clip.py`. There is not a second copy under `~/.local/bin`. The raw file is only read. It is never deleted, moved, or rewritten.

Clips go in `~/screen-recording-clips`, one folder over from `~/screen-recordings`. Each clip has a sidecar file: every piece, the clock times, and the receipt line it was cut from.

If the recording stops before the run finishes, there is no end product on that video. The sidecar says so. The script does not invent a piece to fill the gap.

A 20 minute recording comes out around one to two minutes. Shorter and longer recordings scale from that. Running it twice with the same recording and the same run record does nothing the second time. A pass that is killed does not leave the next pass stuck. When that run's record is updated, the clip is replaced. A run record that does not overlap the recording does not cause another cut. A cron line (`--install`) runs a pass every minute from the checkout path, so a new recording is cut once its run record has arrived.

ffmpeg is the Ubuntu package. Encoding stays on the CPU. The graphics card is shared with ollama and whisper and is not used for this.

## bambustudio/

Bambu Studio web desktop for the P1S, on the Tailscale address only. See `bambustudio/README.md`.

The Mac exports the run record before upload. If an action's command was shortened with an ellipsis, it recovers the full command only when exactly one tool event in that run's `events.jsonl` matches the prefix. This lets the cutter distinguish a batch that actually runs the shipper from a batch that only tests it. Tests remain verification pieces. Commands are ranked by the executed filename, so a later memory entry quoting the task cannot win by repeating its words.
