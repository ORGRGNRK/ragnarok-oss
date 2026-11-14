# ops/tools/ — three standalone tools from the Alexus scripts repo

Copied 2026-11-02 from `~/Developer/scripts` (the Alexus `~/scripts` repo) at commit `90946c1`. The originals are unchanged.
These are plain copies without their git history; the history is still in that repo.

| Tool | What it does | Runs on |
|---|---|---|
| `git-history-scan` | Finds passwords and keys in a repo's **whole git history**, not just the current files. It prints only a short fingerprint, the file and the commit, never the secret. It never rewrites history. | Mac or Alexus |
| `claude-export-unpack` | Turns a Claude.ai data-export zip into one markdown file per conversation (into `~/claude-chats`), with secrets redacted first. | Alexus (see note) |
| `box-check/` | Checks the machine itself: fstab vs. real mounts, disks nothing mounts, full disks with unused space, writes to places that vanish at reboot. Read-only. | Alexus (Linux only) |
| `ragnarok-save` | Not a tool here: the other two load its list of secret patterns. It is also the Alexus transcript saver; don't run it from this folder. | — |

## How to run

    ops/tools/git-history-scan --shapes-only             # every repo in ~/Developer (and ~/repos on Alexus)
    ops/tools/git-history-scan --shapes-only ~/Developer/greenlight   # one repo
    ops/tools/box-check/check.py                         # on Alexus

`--shapes-only` matches secret *patterns* only. Without it the scan also loads the real keys kept on Alexus
(its `~/repos/...` and `~/scripts/...` .env files) and looks for exact copies of them; on the Mac those files
aren't there.

**claude-export-unpack note:** it refuses to write anything unless it could load the real keys to redact.
Those live on Alexus, so on the Mac it writes nothing. That is on purpose.

## Tests

    bash ops/tools/tests/git-history-scan-fixtures.sh       # 27 checks
    bash ops/tools/tests/claude-export-unpack-fixtures.sh   # 40 checks
    python3 ops/tools/box-check/tests/box-fixtures.py       # 25 checks

All use fake values only. Changes from the originals: the two tools find `ragnarok-save` next to themselves
(falling back to `~/scripts/ragnarok-save`), `git-history-scan` also walks `~/Developer`, and the tests
work on macOS as well as Linux (`stat`, `wc`).
