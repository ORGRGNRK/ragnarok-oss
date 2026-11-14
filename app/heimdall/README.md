# Heimdall (Ragnarok.app)

A macOS app that shows, live, what every AI on your machines is doing — Claude Code, Antigravity, Grok, Codex,
local Ollama models — next to your own shell commands, on your Mac and on a home server ("Alexus").
It can also change itself: any AI edits a staging copy, the copy must build and pass a self-test, and only
then is it installed. If a new build crashes, the launcher rolls back.

This started as one person's homelab tool and was written by AI. Expect rough edges and pieces that assume
a setup like the original one (see "What's optional" below).

## Needs

- macOS 14 or later (tiles need macOS 26), Swift 5.10+ (Xcode or the command-line tools)
- Optional: a Linux server reachable over ssh, with Ollama and Docker
- Optional: `xcodegen` and an Apple Development signing identity, for the Control Center tiles

## Install

```sh
cd app/heimdall              # inside this repo
./make-app.sh --install     # builds build/Heimdall.app and installs it as ~/Applications/Ragnarok.app
./make-launcher.sh          # the hidden launcher that restarts / rolls back the app
open ~/Applications/Ragnarok.app
```

Check a build without installing: `./make-app.sh && build/Heimdall.app/Contents/MacOS/Heimdall --selftest`
(run it from inside the git repo).

## Settings

Your server and addresses go in `~/.ragnarok/local.conf` (KEY=value lines; read, never run; not in git):

```
ALEXUS_HOST=192.168.1.10          # your server's address (default alexus.local)
ALEXUS_USER=me                    # your ssh login there (default: your Mac login name)
ALEXUS_TAILSCALE=alexus           # address when away from home
OLLAMA_URL=http://192.168.1.10:11434
```

Environment variables:

| Variable | What it does |
|---|---|
| `RAGNAROK_SIGN_ID` | your `Apple Development: …` identity; unset = the first one in your keychain, or ad-hoc signing (no Control Center tiles) |
| `RAGNAROK_HQ_MCP` | path to the script that connects to the HQ MCP server (switch/resume packets) |

## Unlock

The app opens with a FIDO2 security key or Touch ID. There is no password fallback, on purpose.

## Changing the app

```sh
bin/heimdall-edit claude "make the timeline font bigger"      # or grok, codex, antigravity, api:anthropic, manual
```

Staging worktree → AI edit → build → `Heimdall --selftest` → commit → install. If any step fails, nothing changes.
See AGENTS.md for the rules any AI editing this repo follows.

## What's optional

Some tabs read from a home server or from other parts of this repo. Without them those tabs show nothing
or an error; the rest of the app works:

- a Linux server reachable over ssh (`ALEXUS_HOST`), with Ollama and Docker: server tails, the shared room, local models
- the receipts hooks in `connector/ygg-business/hooks/mac-receipts/`: your shell commands in the timeline
- the task belt in `runner/conveyor/`: the Belt tab
- an HQ MCP server: switch/resume packets

## License

GNU Affero General Public License v3.0 — see the LICENSE at the top of this repo. If you run a modified version for others over a network,
you must offer them its source.

Note: this code was written by AI. In the US, purely AI-generated work may not be protected by copyright,
so the license may not be enforceable for every part.
