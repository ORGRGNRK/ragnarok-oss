# Heimdall — notes for any AI editing this app

God's-eye macOS app: live timeline of everything the owner's AIs (claude, argon, grok, codex) and the owner do, on the Mac and on Alexus.
Plan and milestones: docs/PLAN.md.

- Build: `./make-app.sh` → build/Heimdall.app (Swift package, macOS 14, ad-hoc signed). `--install` makes it the current build.
- One outside package: SwiftTerm (exact 1.99.0, MIT) draws the Shell tab (Sources/Heimdall/ShellTerminal.swift). ShellSession still owns zsh, the command log and the transcript; the view only draws bytes and sends keys.
- Global Provider and Model selection (2026-11-03): The New agent sheet now pairs a first-class Provider picker alongside the Model picker for every agent runner (`who`). Claude supports Anthropic direct, AWS Bedrock (`CLAUDE_CODE_USE_BEDROCK=1`), Google Vertex (`CLAUDE_CODE_USE_VERTEX=1`), and Microsoft Foundry (`CLAUDE_CODE_USE_FOUNDRY=1`); Grok supports xAI and Custom gateways; Codex (ChatGPT) supports OpenAI direct, Alexus (Ollama server API via LocalConfig/OLLAMA_URL), Ollama (Local via `--oss --local-provider ollama`), and LM Studio (Local via `--oss --local-provider lmstudio`) with dynamic model discovery (Sources/Heimdall/LocalModelLoader.swift). Runs record `provider` and `model` in `state.json`.
- Antigravity removed (2026-11-07, the owner): Google does not support wrapping `agy` in apps on consumer plans, so Heimdall no longer launches it. The Timeline still reads old Antigravity logs. Do not add it back without them asking.
- Agents tab (Sources/Heimdall/Agents.swift) + bin/ragnarok-agent: spawns `claude -p`, `grok -p`, `muse exec`, or `codex exec` unattended (`--who claude|grok|muse|codex`, default claude) in a chosen folder, detached so it survives app restarts. Claude uses auto permission mode; its tools are named one by one in TOOLS ("default,X" gives only X). Grok uses `--always-approve` and `--no-plan` (it does not wait on a plan), turns workflows off, and drops scheduler / plan-mode tools so a run cannot leave a job behind. Grok still loads the owner's Claude hooks. Muse is currently an unattended runner. Codex uses `--approve-for-me`, which applies automatic review with the `workspace-write` sandbox. Every runner uses proved mode by default since 2026-11-07 (`--plain` turns it off). A first leg with 0 tool calls is failed as "did no work", which also triggers handoff. Provider handoff (2026-11-06): runs automatically hand off across `claude → codex → grok` (customizable via `--handoff p1,p2` or disabled via `--no-handoff`) when a provider fails, hits quota, crashes, makes zero tool calls, or leaves non-human `LEFT:` / pending plan steps. A stuck proved-mode checklist (the same failing output, or the same critic refutation) is a dead end and is not handed off; `ragnarok-agent handoff <id> [--who <provider>]` (or the "Hand off" menu in the Agents tab) hands off any run with its task, plan, checklist, and action history; `ragnarok-agent resume <id> [--who <provider>] [--approve-human] ["answer / context"]` (or the "Human Helper Intervention Needed" / "Answer & Resume" card in the Agents tab) resumes a run in-place after the owner answers a question, provides context, or unlocks a hardware gate. Room task cards can start the default Claude runner automatically or open the normal agent sheet for manual provider/folder selection; a linked run stores `room_task_id`, and the Room posts the claim as that provider's SSH identity. Per run ~/.ragnarok/agents/<id>/: state.json (includes who, started_who, handoff_chain, handoffs, human_request, human_replies, and optional room_task_id; the tracker: status, now, plan from TaskCreate/TaskUpdate or the todo list, actions, cost), events.jsonl (raw stream), task.txt. CLI: ragnarok-agent start|resume|handoff|list|show|stop. Check without a model: `bin/ragnarok-agent selfcheck`.
- Proved mode (2026-11-02, the conveyor's rule layered on the agent; default for every runner, `--plain` or the tab's "Prove it" toggle turns it off). The agent writes `checklist.md` in its run folder (`- [ ] claim :: verify: cmd [:: expect: regex]`, or `verify: HUMAN`). It is frozen the first time it appears: lines can be added, but removed or changed lines come back as first written. After the agent says done, the runner runs every command itself under `sandbox-exec` (no file writes outside temp folders, no ssh/scp/sftp/rsync, 120 s each). Failures go back to the same session (`--resume`). A round whose failing checks print the same output as the last round, or more than 4 rounds, is a dead end. A check the sandbox cannot run (ssh, scp, sftp, rsync) and a whole-repo git status or diff are left for the owner and are not scored as failures. Gjallarhorn still records a flag and does not start another leg. When all commands pass, a fresh critic (`CRITIC_GUIDE`) tries to refute the work. Any AI can judge: `critic_order` starts at the next AI after the worker and goes round the ring, moving on when one gives no verdict. The critic works in a throwaway APFS clone of the folder; if the folder can't be cloned, only Claude and Codex judge, in their read-only modes; refutations go back too, and the same refutation twice is a dead end. Outcome is in state.json `verdict`: proved / needs you (a HUMAN line or a check the sandbox cannot run) / dead end, plus `checks`, `critic`, `verdict_note`. Costs are summed per process (agent legs plus critics). selfcheck covers the loop with fake CLIs.
- Chat, then do (2026-11-02): the New agent sheet's default for Claude is Plan it. bin/ragnarok-plan (`new` / `revise --session`) runs a read-only planner (`claude -p --output-format json`, PLANNER_GUIDE) that answers UNDERSTOOD / WILL / WONT plus a checklist, and runs each check once before any work (a check that already passes is flagged "already true, proves nothing"). The owner revises it in plain words (same planner session) or edits the checklist by hand, then Approve and start runs `ragnarok-agent start --checklist FILE`: the checklist is frozen before the agent starts and the agent gets DO_GUIDE (just do the work). The agent never writes its own exam. "Start without a plan" is on Claude, Grok, and Codex and keeps the old path. It follows the Prove it checkbox. Plan it stays on Claude, because the planner is claude. The planner reuses ragnarok-agent's parse_checklist and run_checks (one grammar). `bin/ragnarok-plan selfcheck` uses a fake planner.
- Run: open ~/Applications/Ragnarok.app (the one app, in the Dock). Opened directly, it hands off to the hidden launcher
  ~/Library/Application Support/Heimdall/Ragnarok Launcher.app (built by make-launcher.sh; edits never change it; one at a time),
  which runs ~/Applications/Ragnarok.app, restarts it on crash, rolls back to previous.app if a not-yet-proven build crashes within 20 s (no time limit since install); after 5 crashes in 2 min it switches to the saved known-good copy. Every start closes other running Heimdall copies;
  after 20 s up with its commit on main, previous.app, broken.app.* and build/Heimdall.app are deleted.
- Change the app: `bin/heimdall-edit <claude|grok|codex|api:anthropic|api:openai|api:xai|api:gemini|manual> "instruction"`
  (or the Edit bar in the app). Staging worktree → build → `Heimdall --selftest` → commit → install. Fails = nothing changes.
  If you add a feed or parser, add a case to Sources/Heimdall/SelfTest.swift.
  Long instructions: pass `-` and send the text on stdin. heimdall-edit and ragnarok-heal share bin/loop-lib.sh
  (one logger, a lock that clears itself after a crash, Ctrl-C/TERM cleanup). Manual mode never stashes or resets
  the owner's folder, and copies new files only from the code folders (never secret-looking names).
  .ragnarok-heal is read as KEY=value lines (BUILD, TEST, INSTALL), never run. A tested change that can't be merged is
  kept on branch heal-kept/<id>. Unsaved editor text is kept in ~/Library/Application Support/Heimdall/unsaved/.
- Hub tab (Sources/Heimdall/Hub*.swift, merged from the control-center branch 2026-11-01): every project on the Mac and
  Alexus in one place: git, app, containers (start/stop/restart/logs ask first), Services (MCP health, LaunchAgents),
  hand-off to the room/conveyor, one History per project, and "Change it with an AI (proven)":
  bin/ragnarok-heal <folder> <ai> "change" (staging copy → AI → build → test → commit → install; no test = refused;
  steps from <project>/.ragnarok-heal or detected). If the build or the test fails, the same AI gets that failure
  and tries again in the same copy, up to 4 rounds (HEAL_ROUNDS). It does not stop and wait to be started again.
  For this app the Hub uses bin/heimdall-edit instead.
- Belt tab (merged 2026-11-02): Sources/Belt (Conveyor board, from app/belt-ui), its own module; only BeltTab is public.
- Trimmed 2026-11-02 (the owner chose the cuts after the data was checked): the LocalAI tab and its modules are gone (8 chats /
  2 tasks stay in ~/Library/Application Support/LocalAI; standalone source is app/local-ai and git history). The Room is
  the shared chat + task list only (file tree, editor, explain panel and its AI terminal removed; the AITerminal and
  Explainer engines stay for --ask-alexus, --explain and the Alexus chat). Home Assistant is a tab again (put back the same
  day: HA's page inside Ragnarok; the Hub's house button switches to it). Money hides Debts/Inventory/Contacts until they have rows. The Edit bar picker shows
  claude and grok (heimdall-edit still takes the others).
- Switch / resume packets (Hub → project → "Switch / resume packet"): one packet per project in Ragnarok HQ Switch_Packets
  (slug = folder name, lowercased). bin/ragnarok-packet get|save|seed talks to the HQ MCP (receipted writes).
  bin/ragnarok-resume <folder> <ai> [--rounds N] hands the packet to the AI through heimdall-edit/ragnarok-heal, then
  writes the next packet; --packet-only just writes one. Steps needing the owner are kept as "OWNER:" steps.
  Log: ~/.ragnarok/ragnarok-resume.jsonl. If you finish work by hand, save a packet so the next AI can continue.
- Web pages from Alexus (Sources/Heimdall/WebPanel.swift): Money → Receipts (ragnarok-pipe, default http://<ALEXUS_TAILSCALE>:8448)
  and the Home Assistant tab (default http://<ALEXUS_TAILSCALE>:8123, falls back to http://<ALEXUS_HOST>:8123).
  The Hub project list always includes Home Assistant; its page tries the saved address, then Tailscale, then the home network,
  so a saved address that is the dead home-network IP cannot hide the Tailscale one. Status via curl,
  address editable (UserDefaults pipeURL / homeAssistantURL), Reload, Open in browser. Logins happen on the page (HA) or in a
  Basic-auth box kept for the session only (pipe); never read or embed the HA token. make-app.sh adds one ATS exception
  (plain http to ALEXUS_TAILSCALE only). Test: `Heimdall --webcheck <url>` loads a page in a real WKWebView.
- Reinstall bundle: bin/ragnarok-bundle (or Hub → Services → Make reinstall bundle) → ~/Ragnarok-Backups/ragnarok-bundle-*.tar.gz
  (600): git bundles of the ragnarok monorepo, ~/Developer/scripts and ~/conveyor (+ uncommitted work; linked folders such as
  ~/Developer/heimdall are inside ragnarok and are re-linked by install.sh), the app, known-good, LaunchAgent, ~/.ragnarok
  (no worktrees, tokens, .env or bundle keys), and install.sh (never overwrites). Files that look like they hold a key are left
  out and listed in its README.txt. Locked with the YubiKey (age) when bundle keys exist; it refuses to write unlocked then
  unless UNLOCKED=1. Keys, certificate and the search index are not in it.
- Reading logs as an AI: use bin/ragnarok-ai-log (list) / ragnarok-ai-log <shell|shell-cmds|receipts|edits|heal|chat|access> [N]
  — every line goes through the local secret scrubber (Sources/Heimdall/Scrub.swift, `Heimdall --scrub`). When the owner says
  something "errored", read it there instead of asking him to paste it. Shell tab output is written already scrubbed to
  ~/.ragnarok/heimdall-shell-output.log (0600, rotates at 1 MB). Add your own secret values to ~/.ragnarok/scrub-values.
  For other macOS apps, `bin/ragnarok-ai-log app <process> [duration]` reads recent error/fault events from Unified
  Logging, and `bin/ragnarok-ai-log file <path> [N]` tails a known local log file. Both scrub output before displaying
  it to the agent; the file command accepts log-like files or files under a Log(s) folder. Use app-specific logs only.
- App-level errors are scrubbed into ~/.ragnarok/ragnarok-app-errors.jsonl (0600, rotates at 1 MB), shown as a feed in Timeline,
  and readable through `bin/ragnarok-ai-log app-errors [N]`. Never log prompts, request bodies, or unsanitized server output.
- Failing services: `bin/ragnarok-services` (`status`, `restart`, `selfcheck`). Same lists as the Hub
  (MCP servers, Mac launch agents, containers on this laptop and on Alexus). A container line says
  which machine it is on. Anything that needs a login is left out of the
  report and is not restarted. `restart` only `docker restart`s an unhealthy or non-zero-exited container
  (ssh BatchMode, so it cannot ask for a password) or kickstarts a launch agent whose last exit was non-zero.
  An MCP server that failed to connect is reported only. Check: `python3 checks/services-check.py`.
- Error repair daemon: `bin/ragnarok-doctor` (`init|install|uninstall|status|show ID|retry ID|selfcheck`),
  per-user LaunchAgent `co.rgnrk.heimdall.doctor`; config/SQLite queue in `~/.ragnarok/doctor`.
  New scrubbed app errors only, one worker (grok, then claude, then codex as last fallback), severity priority, independent read-only review for critical.
  Dirty app folders pause work. Before/after regression + frozen build/selftest precede merge/install; runtime outcome
  stays Unverified. Source-only retained worktrees and bounded retries/calls; see docs/doctor.md. Do not put prompts,
  credentials or raw subprocess output into the source feed. Check: `python3 checks/doctor-check.py` (fake AI/scratch git).
- Links: ragnarok:// or ragnarok-cc:// — open · lock · hub · services · room?path=<folder>.
- Control Center tiles: Controls/ (WidgetKit extension, built into the app by make-app.sh). The app is signed with the owner's
  Apple Development identity for them; without it make-app.sh falls back to ad-hoc with no tiles.
- Parser check: see checks/parse-check-main.swift (run against real logs before changing Parsers.swift).
- Unlock: FIDO2 key via ~/Developer/alexus-core/bin/fido-auth.sh, or Touch ID. No password fallback. Do not add one.
- Every unlock/lock attempt goes to ~/.ragnarok/heimdall-access.jsonl (0600).
- The owner's terminal commands come from the existing receipts hook (~/.zshenv → ygg-mcp-business/hooks/mac-receipts/receipts.zsh),
  actor "human-terminal" → shown as owner. Don't add a second zsh hook.
- Alexus feeds use ssh as <ALEXUS_USER>@<ALEXUS_HOST> (read-only tails). Never print or log secrets.
- Everything personal or machine-specific lives in ~/.ragnarok/local.conf, KEY=value lines, not in git, read never run:
  ALEXUS_HOST (default alexus.local), ALEXUS_USER (default: the Mac login), ALEXUS_TAILSCALE (default alexus),
  OLLAMA_URL, HA_URL, OWNER_NAME (what the app and its AIs call the owner; default: first name of the Mac account),
  MY_NAMES (Money: own names on bank lines), SYNC_PUBLISH_URL (ragnarok-sync), HEIMDALL_WEB_HOST and
  PROVED_PUBLIC_URL (Heimdall Web, on the server). Missing file/key or odd value = the generic default.
  The code has no personal names, addresses or paths: the person using the app is "the owner" (actor id `owner`).
  Swift: LocalConfig.current (Sources/Heimdall/LocalConfig.swift); shell: `. bin/local-config.sh`; check: checks/local-config-check.sh.
  Don't hardcode an address, login, name or home path in new code; use these (or $HOME / NSHomeDirectory()).
- Name which account you ran as when you report changes.
- Inspect First: Do not propose code or state facts about custom scripts without checking the files or running `selfcheck`/help commands first. Never extrapolate or guess custom tool options or paths.
- Model Reasoning & Architecture: For multi-file Swift changes or daemon/hook modifications, switch to a pro model or use the proved agent runner. Use Flash primarily for targeted edits, summaries, or simple queries.
- Verifiable Steps: Always require and provide verification commands alongside changes (e.g., `./make-app.sh`, `Heimdall --selftest`, or `bin/ragnarok-agent selfcheck`) so any invalid assumptions break immediately against the compiler or tests.

## The shared room (talk to the owner and the other AIs)
One group chat + task list on Alexus, shown in Heimdall's Room tab and in the Timeline (source "room").
- On Alexus (your own login): `python3 ~<ALEXUS_USER>/Developer/ragnarok-room/bin/room <cmd>`.
  On the Mac: `bin/room [--as claude|argon|grok|codex] <cmd>` (ssh's in with `~/.ssh/id_<name>`; on the Mac `--as` is on trust).
- Commands: `say "text"`, `task "text"` (prints an id), `claim ID`, `done ID "note"`, `read [N]`, `tasks`, `whoami`.
- A task can carry its domain (2026-11-07): `task "title" --outcome "what must be true" --proof "how it is shown"…
  --wall "what must not be crossed"…` (an outcome needs ≥1 proof; a proof written `claim :: verify: command` becomes a
  checked line). Stored as `outcome`, `proof`, `walls` on the task record and returned by `tasks --json`. The domain
  says what and within which walls, never which clicks, scripts or order; that stays with whoever does the task.
- Enforced by the runner (`ragnarok-agent start --domain FILE`): proofs are labelled P1, P2…; a run is not proved
  until each label has its own passing checklist line (2 send-backs, then dead end). Walls the runner enforces:
  `no-network` and `read-only` / `write-only: PATHS` (Bash in a macOS sandbox; web/MCP/Write tools refused),
  `app-only: APPS`, `deny: REGEX`, `once: REGEX`, `no-tool: TOOLS` (a per-run PreToolUse hook refuses the move before
  it runs; a backstop stops the run as a dead end if a crossing ever succeeds). Walled runs are claude only and never
  hand off. Any other wall text is plain: in the brief and shown to the critic, not enforced (the room says so).
- Before starting work, run `room tasks`; claim what you take, mark it done with a one-line note when finished.
- The author is the file's owner on Alexus, so you can only post as yourself. Never put secrets in the room.
- Conveyor bridge (`~/conveyor/conveyor-room`, run by `conveyor-daemon` on the Mac once `~/.conveyor/room.on` exists):
  The owner's open, unclaimed tasks are claimed by the lane's driver AI, planned and built on the belt, and the result
  (or a needs-owner step, or a dead end) is posted back. Tasks starting with `no-belt:` are left for hand work.
  If you want to do one of the owner's tasks by hand, claim it first so the bridge leaves it alone.
  Paths: by default one read-only AI answers a task (it can look, not change); if it needs changes it goes to the
  conveyor. Start a post with `belt:` to send it straight to the full conveyor (meant for whole codebases).
  The owner's rule (2026-10-31): they get the end result. Planner/critic deadlocks are built anyway; only real
  `verify: HUMAN` steps (money, accounts, deleting, sending, sudo) come back, and he answers `approve <room id>`.

- Room work queue (`bin/room-agentd`, launchd job `co.rgnrk.room-agents`, added 2026-11-07): every 20 s it takes
  open, unclaimed tasks from verified authors (the owner or an AI), starts a proved `ragnarok-agent` run for each
  (claude, with the normal claude → codex → grok handoff; at most 2 at once), claims the task as claude, and when the
  run ends posts once: `done` with the DONE line (proved), or a message for needs-owner / dead end / stopped. Skips
  tasks starting `no-agent:`, `no-belt:`, `hand:`, `belt:`; while `~/.conveyor/room.on` exists the owner's tasks are left
  to the conveyor bridge. A task's outcome/proof/walls go into the run's brief as its domain, and `:: verify:` proofs
  are frozen into the run's checklist; enforced walls are blocked by the runner (see the room section). To do a task yourself, claim it first. `room-agentd status|pause|resume|once --dry|install|uninstall`;
  state and log in `~/.ragnarok/room-agentd/`.

## Known-good build (saved by owner, 2026-11-01)
- Git tags: `known-good` (moves to the newest saved build) and `working-2026-11-01` (fixed) → commit 102c279.
- A copy of that app: `~/Library/Application Support/Heimdall-known-good/Heimdall.app` (the launcher never deletes it).
- Restore if Heimdall won't come back: quit it, then
  `S=~/Library/Application\ Support; rm -rf ~/Applications/Ragnarok.app && cp -R "$S/Heimdall-known-good/Heimdall.app" ~/Applications/Ragnarok.app && open ~/Applications/Ragnarok.app`
- Only save a new known-good after the owner has used a build and says it works.

## Off-Mac backup (2026-11-01)
- Git remote `alexus` = <ALEXUS_USER>@<ALEXUS_HOST>:backups/heimdall.git (bare repo, all history and tags).
  bin/heimdall-edit pushes main + tags there after every install (logged as step "backup"; a failed push never blocks an edit).
  Commits made by hand: `git push alexus main --tags`.
- Known-good app copy on Alexus: ~/backups/heimdall-known-good-102c279.app.tgz.
- Restore on a new Mac: `git clone <ALEXUS_USER>@<ALEXUS_HOST>:backups/heimdall.git ~/Developer/heimdall && cd ~/Developer/heimdall && ./make-app.sh --install && ./make-launcher.sh`.
