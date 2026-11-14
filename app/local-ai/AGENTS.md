# AGENTS.md — LocalAI

## Current state / Next step
- On-device macOS chat app (MLX Swift; default model Qwen2.5-Coder-7B-Instruct 4-bit). Last commit 71fdf62 (2026-10-26).
- First committed 2026-10-26 (d6f4b2d): MLX chat, model-server backend, attachments, workspace tools (write_file, run_command with approval), receipts and claim checker.
- No handoff notes in this repo. A plan to merge LocalAI into the Conveyor Mac app exists in the Conveyor app repo (`docs/PLAN-one-app.md`); nothing is built for it yet.
- Next step: none recorded.

**Handoff rule:** before handing off or ending a session, commit, push if a remote exists, and update the block above.

## Project
- README.md is the full guide (build, run, limits, layout, troubleshooting).
- Build: `./build.sh` (or `./build.sh --clean`) makes `dist/LocalAI.app`. Needs full Xcode (Metal shaders).
- Tests: `swift test` (ToolCallParsing tests).
- Dependencies are pinned exactly; see README "Dependencies".

## Rules
- App Sandbox is deliberately off (see README); don't turn it on without handling model-file access.
- On-device mode makes no network calls: `OfflineDownloader` must keep throwing if anything asks to download.
- Target is an 8 GB M2 Mac; keep memory limits in mind (README "Notes and limits").
- `run_command` stays off by default and always needs Approve.
