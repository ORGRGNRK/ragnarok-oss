# Heimdall Terminal Pipeline & Error Debugger

A high-performance, cross-platform terminal application for **macOS**, **Linux**, and **Windows** that monitors and ingests Heimdall and pipeline AI logging, scrubs credentials and secrets, detects errors and stack traces, and loops back into an AI model with a specialized pipeline and error debugging prompt.

---

## 1. Quick Start

### macOS & Linux
```bash
# Interactive TUI / REPL menu inside Heimdall or your shell:
heimdall-debug

# Debug the last failed command from Heimdall terminal:
heimdall-debug last

# Continuous background/foreground watch mode:
heimdall-debug watch

# Wrap and execute any pipeline command with automatic AI debugging on failure:
heimdall-debug run "npm test"
heimdall-debug run "pytest -v"
heimdall-debug run "cargo build"

# Ingest piped output from stdin:
my-broken-pipeline 2>&1 | heimdall-debug pipe

# Triage an arbitrary log file on disk:
heimdall-debug triage /var/log/pipeline-build.log

# Run regression self-check:
heimdall-debug selfcheck
```

### Windows (CMD & PowerShell)
Run via batch script or PowerShell wrapper:
```cmd
REM From Windows Command Prompt:
bin\heimdall-debug.bat last
bin\heimdall-debug.bat run "pytest -v"
bin\heimdall-debug.bat watch

# Or from Windows PowerShell:
.\bin\heimdall-debug.ps1 last
.\bin\heimdall-debug.ps1 run "npm run build"
```

---

## 2. Key Features

- **Multi-Platform Support**: Runs natively on macOS, Linux, and Windows with zero third-party pip dependencies (pure Python 3.8+ standard library).
- **Heimdall Terminal Logging Integration**: Directly tails and parses `~/.ragnarok/heimdall-shell.jsonl`, `~/.ragnarok/heimdall-shell-output.log`, and `~/.ragnarok/ragnarok-app-errors.jsonl`.
- **Pure-Python 3-Layer Secret Scrubber**:
  1. Known patterns: API keys (`sk-ant-*`, `sk-proj-*`, `xai-*`), GitHub tokens (`ghp_*`), AWS keys (`AKIA...`), Google keys (`AIza...`), Bearer tokens, JWTs, and private keys.
  2. Exact environment values: Scans sensitive environment variables and `~/.ragnarok/scrub-values`.
  3. High-entropy random strings: Mixed-case + digit non-hex sequences with Shannon entropy $\ge 4.0$.
  *Guarantees zero credentials or tokens ever reach prompts or terminal output.*
- **Multi-Model Provider Loop-Back**:
  - **Local/Network Ollama**: Automatically discovers Ollama hosts (`http://127.0.0.1:11434` or Alexus `http://<ALEXUS_HOST>:11434`) and streams completions with models like `qwen2.5-coder:3b`, `llama3.2:3b`, `llama3.1:8b`.
  - **Antigravity CLI (`agy`)**: Seamless execution via `agy -p`.
  - **Claude Code CLI (`claude`)**: Direct invocation via `claude -p`.
  - **OpenAI Codex CLI (`codex`)**: Headless execution via `codex exec`.
  - **xAI Grok CLI (`grok`)**: Execution via `grok -p`.
  - **Direct APIs**: OpenAI, Anthropic, and Google Gemini via standard library `urllib`.
- **Specialized Pipeline Debugging Protocol**:
  The system prompt enforces structured, battle-tested diagnostic responses:
  1. 🚨 **Failure Signature**: Command, exit code, culprit file:line, error class.
  2. 🔍 **Root Cause Analysis (RCA)**: Precise explanation of why it failed.
  3. 🛠️ **Remediation & Patch**: Code diff or configuration update.
  4. ⚡ **Executable Fix Command**: Copy-pasteable terminal command to fix immediately.
  5. 🧪 **Pipeline Verification Command**: Exact command to prove the pipeline is green.
  6. 🛡️ **Preventative Guard**: How to avoid recurrence in CI/CD.

---

## 3. Heimdall UI Integration

In Heimdall's native **Shell** tab:
- A new **"Debug last error"** button is located in the top control bar next to **Ctrl-C** and **Restart shell**.
- Clicking it immediately dispatches `heimdall-debug last` into the owner's active shell session, providing instant AI root-cause analysis and remediation right inside the terminal screen.
