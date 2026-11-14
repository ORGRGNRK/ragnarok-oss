# LocalAI

A small, fully local macOS chat app. It loads an MLX-format LLM straight from disk
and runs inference on-device on the Apple-silicon GPU with
[MLX Swift](https://github.com/ml-explore/mlx-swift) /
[mlx-swift-lm](https://github.com/ml-explore/mlx-swift-lm). It makes no network calls, needs no server,
and doesn't depend on LM Studio. It only reads the model files that LM Studio downloaded.

Default model: `~/.lmstudio/models/lmstudio-community/Qwen2.5-Coder-7B-Instruct-MLX-4bit`

## Features

- Chat window with a sidebar of conversations, **New Chat** (⌘N), delete through the context menu
- Streaming output, **Stop** button (⌘.)
- Uses the model's own chat template, read from `tokenizer_config.json` through the tokenizer
- Editable system prompt, temperature, and max tokens in Settings (⌘,), persisted with `@AppStorage`
- Model directory setting with `~` expansion and a folder picker that shows hidden folders
- Model loading indicator with progress, plus a clear error if the folder or its files are missing
- Code blocks rendered monospaced with a **Copy** button; light inline Markdown (bold, italics, `code`, links, headings)
- Tokens/sec (and prompt stats) shown under each reply
- **Per-conversation usage totals** (prompt / completion / total tokens) in a bar above the transcript, saved with the chat
- **Tool calling** (Settings → Tools, **off by default**). This ports `get_time`, `list_dir` (max 200 entries), and
  `read_file` (max 20,000 chars) from the Python CLI, with up to 10 tool rounds per reply. It uses mlx-swift-lm's native tool-calling support:
  the tool schemas go into `UserInput(chat:tools:)` (rendered by Qwen's chat template) and into
  `generate(..., tools:)`, and the library parses Qwen2.5's `<tool_call>{json}</tool_call>` into
  `Generation.toolCall`. The app runs the tool and sends the result back as a `role: tool` message
  (`Chat.Message.tool`). Each call appears in the chat as a small collapsible row. As in the CLI, only the
  user prompt and the final reply are kept as history. Tools are read-only, and relative paths resolve against `~`.
- Conversations saved to `~/Library/Application Support/LocalAI/chats.json`

## Requirements

- Apple-silicon Mac, macOS 14 or later (tested target: M2 MacBook Air with 8 GB RAM, macOS 27)
- **Full Xcode** at `/Applications/Xcode.app`. The Command Line Tools alone are not enough because they can't compile Metal shaders.
  - If the build complains about the Metal toolchain: `xcodebuild -downloadComponent MetalToolchain`
- Network access **at build time only**, so Swift Package Manager can fetch the dependencies
- An MLX-format model folder (`config.json`, `tokenizer.json`, `tokenizer_config.json`, `*.safetensors`)

## Build

```bash
cd local-ai-app
chmod +x build.sh
./build.sh            # or ./build.sh --clean
```

`build.sh` does the following:

1. Runs
   ```bash
   xcodebuild -scheme LocalAI -configuration Release -destination 'platform=macOS' \
     -derivedDataPath ./build -skipMacroValidation -skipPackagePluginValidation \
     ARCHS=arm64 ONLY_ACTIVE_ARCH=YES build
   ```
   It uses `xcodebuild` instead of `swift build` because only Xcode's build system compiles
   MLX's `.metal` kernels into `mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib`.
   `ARCHS=arm64` skips building a useless x86_64 slice of MLX.
2. Assembles `dist/LocalAI.app`:
   - `Contents/MacOS/LocalAI` is the binary from `build/Build/Products/Release/`
   - `Contents/Info.plist` comes from `Support/Info.plist` (bundle id `com.ragnarok.localai`, `NSPrincipalClass = NSApplication`)
   - `Contents/Resources/*.bundle` holds every SwiftPM resource bundle, including `mlx-swift_Cmlx.bundle`
   - `Contents/Resources/mlx.metallib` is a copy of the compiled `default.metallib`, kept as a fallback
3. Ad-hoc signs it: `codesign --force --deep -s -`

The first build downloads the packages and compiles MLX's C++ and Metal code, so expect several minutes.

### How the Metal library is found at runtime

MLX's C++ (`mlx/backend/metal/device.cpp`) looks for the shader library in this order:

1. The `GPU.metallib` override path, if one is set
2. `mlx.metallib` next to the binary
3. `Resources/mlx.metallib` next to the binary
4. `mlx-swift_Cmlx.bundle/<resources>/default.metallib` inside `NSBundle.mainBundle`, then inside every bundle's resource directory. For the main app bundle that directory is `Contents/Resources`.
5. A few other fallbacks

At startup, before any MLX call, `ModelManager.configureMLX()` sets `GPU.metallib` to the first of these
that exists:
`Contents/Resources/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib`, `.../mlx-swift_Cmlx.bundle/default.metallib`,
`Contents/Resources/mlx.metallib`. If none exists, for example when you run from Xcode, it leaves MLX's automatic lookup alone.

## Run

```bash
open dist/LocalAI.app
# or, to see logs in the terminal:
dist/LocalAI.app/Contents/MacOS/LocalAI
```

The model starts loading on launch. To use a different model, open **Settings (⌘,)**,
choose a folder, and click **Load Model**. To install the app, copy `dist/LocalAI.app` to `/Applications`.

Because it is ad-hoc signed and not notarized, a copy made on another machine may need
right-click → Open the first time. A build made on the same Mac normally just runs.

### Developing in Xcode

`open Package.swift` (or `xed .`), select the **LocalAI** scheme and **My Mac**, then Run.
When you run from Xcode, MLX finds the metallib through the DerivedData bundle.

## Notes and limits (8 GB Macs)

- A 7B 4-bit model is about 4.3 GB of weights, so on an 8 GB M2 it fits but memory is tight. Close other
  heavy apps. The app keeps MLX's buffer cache at 512 MB (`Memory.cacheLimit`) and prefills
  in 256-token chunks. It sends at most about 24k characters of recent history per request, to bound the KV cache.
- **App Sandbox is deliberately off.** In a sandbox, `~` would resolve to the app container
  instead of `/Users/<you>`, and the app couldn't read `~/.lmstudio/...`.
- No network: the model is loaded through `ModelConfiguration(directory:)`, and the downloader
  passed to mlx-swift-lm (`OfflineDownloader`) throws if anything ever asks it to download.

## Project layout

```
Package.swift                 SwiftPM manifest (executable target LocalAI)
Support/Info.plist            Info.plist copied into the .app by build.sh
build.sh                      xcodebuild + .app assembly + ad-hoc codesign
Sources/LocalAI/
  LocalAIApp.swift            @main SwiftUI App, menus, Settings scene
  ContentView.swift           Split view, chat transcript, model status bar, input bar
  MessageViews.swift          Message rows, markdown/code-block rendering, copy buttons
  SettingsView.swift          Model path, system prompt, temperature, max tokens
  ChatViewModel.swift         Conversations, persistence, streaming generation, stop, tool loop, usage
  Tools.swift                 get_time / list_dir / read_file + JSON schemas
  ModelManager.swift          MLX setup (metallib, cache limit), model loading + progress
  LocalModelSupport.swift     Tokenizer adapter (swift-transformers), offline downloader, folder validation
  ChatModels.swift            Codable chat types + chats.json persistence
  Markdown.swift              Fenced code block splitter + inline markdown
  AppSettings.swift           Settings keys/defaults, ~ path expansion
```

## Dependencies (pinned exactly)

| Package | Version | Products used |
|---|---|---|
| github.com/ml-explore/mlx-swift-lm | 3.32.3 | MLXLLM, MLXLMCommon |
| github.com/ml-explore/mlx-swift | 0.32.3 | MLX |
| github.com/huggingface/swift-transformers | 1.3.5 | Tokenizers |

The LLM libraries moved from `mlx-swift-examples` to `mlx-swift-lm`. Version 3.x of mlx-swift-lm no longer bundles a tokenizer:
`LocalModelSupport.swift` adapts swift-transformers' `AutoTokenizer.from(modelFolder:)` to
`MLXLMCommon.TokenizerLoader`. This is the same code the optional `#huggingFaceTokenizerLoader()` macro
generates, written out by hand so no macros are needed.

## Troubleshooting

- **"Failed to load the default metallib"**: the shaders weren't compiled or copied. Rebuild with
  `./build.sh --clean` using full Xcode, and check that `dist/LocalAI.app/Contents/Resources/mlx-swift_Cmlx.bundle` exists.
- **Model directory not found**: fix the path in Settings. `~` is expanded. LM Studio keeps models under
  `~/.lmstudio/models/<publisher>/<model>`.
- **Very slow output or beach-balling**: the machine is swapping. Close other apps, or use a smaller model such as a 3B 4-bit.
- **Package resolution errors**: `rm -rf build` and rebuild. Make sure you have network access while building.

## Model server backend and attachments (added Oct 2026)

- **Settings → Backend**: *On-device (MLX)* (the original, default) or *Model server*.
  Server mode talks to a local OpenAI-compatible server (LM Studio, default `http://127.0.0.1:1234`)
  or Ollama (`http://127.0.0.1:11434`). API is auto-detected: `GET /api/tags` → Ollama, otherwise
  `GET /v1/models` → OpenAI-compatible. Chat uses streamed `POST /v1/chat/completions` (Ollama serves it too),
  including the same read-only tools when enabled. The MLX model is not loaded in server mode.
- **Model picker**: in the status bar and Settings, with Refresh; the choice is saved (`serverModel`).
  The MLX backend gets a picker of model folders found in `~/.lmstudio/models`.
- **Ollama pull**: Settings → Model server → "Pull a model by name" (`POST /api/pull`, streamed progress, cancellable).
- **Attachments**: paperclip button (⇧⌘O), drag & drop, or ⌘V with copied files/images. Text, code, JSON, CSV and
  PDF (PDFKit text) are inlined, capped at 30,000 chars per file with a truncation notice. Images are downscaled to 1280 px
  JPEG and sent as `image_url` data URIs (server mode only; the MLX model is text-only, so images are left out with a note).
  A warning appears if the selected model doesn't look vision-capable (Ollama `/api/show` capabilities, otherwise a name heuristic).

## Workspace tools: write_file and run_command (added Oct 2026)

Both tools work with either backend, and only when **Settings → Tools** is on. Each one has its own toggle there.

- **write_file(path, content)** (on by default once Tools is on): creates or overwrites a UTF-8 file inside
  `~/LocalAI-Workspace`, which is created if missing. The path must be relative. Absolute or `~` paths, `..` escapes,
  and symlinks that point outside the workspace are rejected. The size limit is 1 MB. To read or list workspace files,
  use the existing `read_file` and `list_dir` with `~/LocalAI-Workspace/...`.
- **run_command(command, cwd?)** (**off by default**): for every call, an **Approve / Deny** sheet shows the exact
  command and working folder. Nothing runs without Approve, and Stop (⌘.) denies it. On Approve the app runs
  `/bin/zsh -lc <command>` with the cwd inside the workspace. The timeout defaults to 60 s and can be changed in Settings;
  on timeout the command gets SIGTERM, then SIGKILL. The model gets the exit code, stdout and stderr, each truncated to 12,000 chars.
  Each execution appears in the transcript as a collapsible tool row.
  Note: only the working folder is sandboxed. An approved command runs with your full user permissions.
