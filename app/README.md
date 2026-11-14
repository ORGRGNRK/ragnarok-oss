# app/ — Swift front end

**The one app is Ragnarok.app, built from `app/heimdall/`** (`./make-app.sh`, changes via `bin/heimdall-edit`).

Since 2026-11-02 (commit 2ea62f9) it also holds:
- **Belt tab**: the Conveyor board, from `belt-ui/`, now `heimdall/Sources/Belt` (its own Swift module).
- **LocalAI tab**: chat, tasks, workspace tools and receipts, from `local-ai/`, now `heimdall/Sources/LocalAI` + `Sources/ToolCallParsing`.
  Built **without MLX**, so it chats through a model server (LM Studio, Ollama, Alexus). Settings on ⌘,.
  Why: MLX needs xcodebuild to compile its Metal shaders, and every heimdall-edit builds from a fresh copy, so MLX would add many minutes to each change.

Other folders:
- `belt-ui/`: frozen; edit the Belt in `heimdall/Sources/Belt`.
- `local-ai/`: still the source of the standalone on-device (MLX) LocalAI.app. Its code was copied, not shared: a fix to chat code here must be copied to `heimdall/Sources/LocalAI` (MLX parts are behind `#if canImport(MLXLMCommon)` there).
- `cli-tools/`: separate Xcode project, not merged.
