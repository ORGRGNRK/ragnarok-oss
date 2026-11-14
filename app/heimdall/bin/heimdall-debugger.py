#!/usr/bin/env python3
"""heimdall-debugger.py — Cross-platform Terminal Pipeline & Error Debugger.

Native app targets macOS. The terminal engine requires Python 3.12+.
Isolated repair uses POSIX process groups and Linux Docker containers.
Windows execution has not been validated.
Integrates directly with Heimdall's terminal logging and shell transcripts,
scrubs configured secrets and known patterns, extracts error failure points and stack traces,
and loops back into an AI model using a specialized pipeline & error debugging prompt.

Supported Providers:
  - Local / Network Ollama (default zero-friction runner: llama3.1, qwen2.5-coder, etc.)
  - Claude CLI (`claude`)
  - Codex CLI (`codex`)
  - Grok CLI (`grok`)
  - Direct APIs: OpenAI-compatible, Anthropic, Google Gemini (via standard library urllib)

Usage:
  heimdall-debug                     # Interactive Terminal UI (TUI / REPL)
  heimdall-debug last                # Triage & debug the last failed terminal command
  heimdall-debug watch               # Live background/foreground watcher for failed pipeline commands
  heimdall-debug run "<command>"     # Execute pipeline command; auto-debug if it exits non-zero
  heimdall-debug pipe                # Read pipeline output from stdin (e.g. `npm test 2>&1 | heimdall-debug pipe`)
  heimdall-debug triage <file>       # Triage and debug a specific log file
  heimdall-debug selfcheck           # Run cross-platform regression tests and diagnostics

Options:
  --provider <name>   Override provider: ollama, claude, codex, grok, openai, anthropic, gemini
  --model <name>      Override model name (e.g. qwen2.5-coder:7b, llama3.1:8b, gemini-3.8-flash-high)
  --log-file <path>   Override log file to inspect (last/triage only)
  --no-color          Disable ANSI color styling
  --json              Output diagnosis as JSON
"""

import argparse
import io
import contextlib
import base64
import datetime
import glob
import json
import math
import os
from pathlib import Path
import platform
import re
import select
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid

def display(text):
    """Untrusted model/command output cannot impersonate controller event frames."""
    print("\n".join("[output] " + line if line.startswith("PIPELINE_EVENT ") else line
                    for line in str(text).split("\n")))


_children = set()
_active_runners = set()


def stop_children(signum=None, frame=None):
    for runner in list(_active_runners):
        runner.cancel()
    for child in list(_children):
        try:
            if os.name == "posix":
                os.killpg(child.pid, signal.SIGKILL)
            else:
                subprocess.run(["taskkill", "/PID", str(child.pid), "/T", "/F"], capture_output=True)
        except (ProcessLookupError, OSError):
            pass
    if signum is not None:
        raise SystemExit(128 + signum)


def execute(command, cwd=None, timeout=60):
    """Bounded owned command. Return evidence, including timeout and signal."""
    if os.name == "posix":
        from pipeline_debugger_controller import CommandRunner
        runner = CommandRunner(SecretScrubber(resolve_ragnarok_dir()).clean)
        runner.environment = dict(os.environ)
        _active_runners.add(runner)
        try:
            result = runner.run(["/bin/sh", "-c", command] if isinstance(command, str) else command,
                                cwd or Path.cwd(), timeout)
            result["command"] = command
            result["timed_out"] = result["status"] == "timed_out"
            if result["exit"] is None:
                result["exit"] = 1
            return result
        finally:
            _active_runners.discard(runner)
    start = time.monotonic()
    p = subprocess.Popen(command, shell=isinstance(command, str), cwd=cwd,
                         stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                         text=True, start_new_session=(os.name == "posix"))
    _children.add(p)
    timed_out = False
    try:
        try:
            out, err = p.communicate(timeout=timeout)
        except subprocess.TimeoutExpired:
            timed_out = True
            if os.name == "posix":
                os.killpg(p.pid, signal.SIGKILL)
            else:
                subprocess.run(["taskkill", "/PID", str(p.pid), "/T", "/F"], capture_output=True)
            out, err = p.communicate()
        return {"command": command, "cwd": str(cwd or Path.cwd()),
                "exit": p.returncode, "signal": -p.returncode if p.returncode < 0 else None,
                "timed_out": timed_out, "stdout": out, "stderr": err,
                "duration": time.monotonic() - start}
    finally:
        # A command can leave background processes even after its shell exits.
        if os.name == "posix":
            try:
                os.killpg(p.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        _children.discard(p)


# ---------------------------------------------------------------------------
# Cross-Platform Terminal Styling & Windows VT100 Setup
# ---------------------------------------------------------------------------

def init_terminal():
    """Enable ANSI virtual terminal processing on Windows if supported."""
    if sys.platform == "win32":
        try:
            import ctypes
            kernel32 = ctypes.windll.kernel32
            handle = kernel32.GetStdHandle(-11)  # STD_OUTPUT_HANDLE
            mode = ctypes.c_ulong()
            if kernel32.GetConsoleMode(handle, ctypes.byref(mode)):
                mode.value |= 0x0004  # ENABLE_VIRTUAL_TERMINAL_PROCESSING
                kernel32.SetConsoleMode(handle, mode)
        except Exception:
            pass

init_terminal()

class Colors:
    """ANSI color codes with automatic terminal capability detection."""
    _enabled = sys.stdout.isatty() and not os.environ.get("NO_COLOR")

    @classmethod
    def set_enabled(cls, enabled: bool):
        cls._enabled = enabled

    @classmethod
    def bold(cls, s: str) -> str: return f"\033[1m{s}\033[0m" if cls._enabled else s
    @classmethod
    def dim(cls, s: str) -> str: return f"\033[2m{s}\033[0m" if cls._enabled else s
    @classmethod
    def red(cls, s: str) -> str: return f"\033[31m{s}\033[0m" if cls._enabled else s
    @classmethod
    def green(cls, s: str) -> str: return f"\033[32m{s}\033[0m" if cls._enabled else s
    @classmethod
    def yellow(cls, s: str) -> str: return f"\033[33m{s}\033[0m" if cls._enabled else s
    @classmethod
    def blue(cls, s: str) -> str: return f"\033[34m{s}\033[0m" if cls._enabled else s
    @classmethod
    def magenta(cls, s: str) -> str: return f"\033[35m{s}\033[0m" if cls._enabled else s
    @classmethod
    def cyan(cls, s: str) -> str: return f"\033[36m{s}\033[0m" if cls._enabled else s
    @classmethod
    def red_bold(cls, s: str) -> str: return f"\033[1;31m{s}\033[0m" if cls._enabled else s
    @classmethod
    def green_bold(cls, s: str) -> str: return f"\033[1;32m{s}\033[0m" if cls._enabled else s
    @classmethod
    def yellow_bold(cls, s: str) -> str: return f"\033[1;33m{s}\033[0m" if cls._enabled else s
    @classmethod
    def blue_bold(cls, s: str) -> str: return f"\033[1;34m{s}\033[0m" if cls._enabled else s
    @classmethod
    def magenta_bold(cls, s: str) -> str: return f"\033[1;35m{s}\033[0m" if cls._enabled else s
    @classmethod
    def cyan_bold(cls, s: str) -> str: return f"\033[1;36m{s}\033[0m" if cls._enabled else s

# ---------------------------------------------------------------------------
# Cross-Platform Path Resolution
# ---------------------------------------------------------------------------

def resolve_ragnarok_dir() -> Path:
    """Resolve the Ragnarok directory across macOS, Linux, and Windows."""
    env_dir = os.environ.get("RAGNAROK_HOME") or os.environ.get("RAGNAROK_DIR")
    if env_dir:
        p = Path(env_dir).expanduser().resolve()
        if p.is_dir():
            return p

    home_rag = Path.home() / ".ragnarok"
    if home_rag.is_dir():
        return home_rag

    if sys.platform == "win32":
        appdata = os.environ.get("APPDATA")
        if appdata:
            win_rag = Path(appdata) / "ragnarok"
            if win_rag.is_dir():
                return win_rag

    # Default fallback
    home_rag.mkdir(parents=True, exist_ok=True, mode=0o700)
    return home_rag


def resolve_local_config(ragnarok_dir: Path) -> dict:
    """Read ~/.ragnarok/local.conf (KEY=value pairs) safely without execution."""
    cfg = {}
    conf_file = ragnarok_dir / "local.conf"
    if conf_file.is_file():
        try:
            with open(conf_file, "r", encoding="utf-8", errors="replace") as f:
                for line in f:
                    line = line.strip()
                    if not line or line.startswith("#"):
                        continue
                    if "=" in line:
                        k, v = line.split("=", 1)
                        cfg[k.strip()] = v.strip().strip('"').strip("'")
        except Exception:
            pass
    return cfg

# ---------------------------------------------------------------------------
# Cross-Platform 3-Layer Secret Scrubber (Pure Python Port of Scrub.swift)
# ---------------------------------------------------------------------------

class SecretScrubber:
    """Pure-Python implementation of Heimdall's 3-layer secret scrubber:
    1. Known secret regex patterns (API keys, JWT, SSH keys, passwords)
    2. Exact sensitive environment values & ~/.ragnarok/scrub-values
    3. High-entropy random alphanumeric strings (>=32 chars, Shannon entropy >= 4.0)
    """

    PATTERNS = [
        ("private-key", r"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?(?:-----END [A-Z ]*PRIVATE KEY-----|\Z)"),
        ("age-secret", r"AGE-(?:SECRET-KEY|PLUGIN-[A-Z0-9-]+?)-1[A-Z0-9]{20,}"),
        ("anthropic-key", r"sk-ant-[A-Za-z0-9_-]{20,}"),
        ("openai-key", r"sk-(?:proj-|svcacct-)?[A-Za-z0-9_-]{20,}"),
        ("xai-key", r"xai-[A-Za-z0-9]{20,}"),
        ("github-token", r"(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})"),
        ("gitlab-token", r"glpat-[A-Za-z0-9_-]{20,}"),
        ("slack-token", r"xox[abprs]-[A-Za-z0-9-]{10,}"),
        ("aws-key", r"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b"),
        ("google-key", r"AIza[0-9A-Za-z_-]{35}"),
        ("stripe-key", r"\b(?:sk|rk|pk)_(?:live|test)_[A-Za-z0-9]{16,}"),
        ("nocodb-token", r"nc_pat_[A-Za-z0-9_-]{16,}"),
        ("jwt", r"\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}"),
        ("bearer", r"(?i)\bbearer\s+[A-Za-z0-9._~+/=-]{16,}"),
        ("url-password", r"(?<=://)[^\s:/@]+:[^\s@/]+(?=@)"),
        ("assignment", r'(?i)\b(?:[A-Z0-9_]*(?:password|passwd|pwd|secret|token|api[_-]?key|apikey|auth|credential)[A-Z0-9_]*)\s*[:=]\s*["\']?(?!\[hidden)[^\s"\']{6,}'),
    ]

    _compiled_patterns = [(name, re.compile(pat)) for name, pat in PATTERNS]
    _secret_name_re = re.compile(r"(?i)(key|token|secret|pass|auth|credential|cookie|session)")
    _randomish_re = re.compile(r"(?<![A-Za-z0-9+_=-])[A-Za-z0-9+_=-]{32,}(?![A-Za-z0-9+_=-])")

    def __init__(self, ragnarok_dir: Path):
        self.ragnarok_dir = ragnarok_dir
        self.exact_values = []  # list of (label, exact_secret_str), sorted longest first
        self._load_exact_values()

    def _load_exact_values(self):
        found = {}
        # 1. Environment variables
        ignore_keys = {"SSH_AUTH_SOCK", "XPC_SERVICE_NAME", "TERM_SESSION_ID", "SECURITYSESSIONID", "COLORTERM"}
        for k, v in os.environ.items():
            if len(v) >= 8 and not v.startswith("/") and " " not in v and k not in ignore_keys:
                if self._secret_name_re.search(k):
                    found[v] = f"env:{k}"

        # 2. ~/.ragnarok/scrub-values
        scrub_file = self.ragnarok_dir / "scrub-values"
        if scrub_file.is_file():
            try:
                with open(scrub_file, "r", encoding="utf-8", errors="replace") as f:
                    for line in f:
                        line = line.strip()
                        if len(line) >= 6 and not line.startswith("#"):
                            found[line] = "listed"
            except Exception:
                pass

        # Sort longest string first so prefixes don't mask supersets
        self.exact_values = sorted(
            [(label, val) for val, label in found.items()],
            key=lambda item: len(item[1]),
            reverse=True,
        )

    @staticmethod
    def _entropy(s: str) -> float:
        """Compute Shannon entropy for random string identification."""
        if not s:
            return 0.0
        counts = {}
        for ch in s:
            counts[ch] = counts.get(ch, 0) + 1
        n = float(len(s))
        return -sum((c / n) * math.log2(c / n) for c in counts.values())

    def clean(self, text: str) -> str:
        """Scrub sensitive credentials, tokens, and random secrets from text."""
        if not text:
            return ""

        # Layer 1: exact values from env and scrub-values
        res = text
        for label, val in self.exact_values:
            if val in res:
                res = res.replace(val, f"[hidden:{label}]")

        # Layer 2: known pattern regexes
        for name, pattern in self._compiled_patterns:
            res = pattern.sub(f"[hidden:{name}]", res)

        # Layer 3: high entropy random strings
        def _replace_random(match):
            candidate = match.group(0)
            # Skip pure hexadecimal (git commit hashes, etc.)
            if all(c in "0123456789abcdefABCDEF" for c in candidate):
                return candidate
            has_upper = any(c.isupper() for c in candidate)
            has_lower = any(c.islower() for c in candidate)
            has_digit = any(c.isdigit() for c in candidate)
            if has_upper and has_lower and has_digit:
                if self._entropy(candidate) >= 4.0:
                    return "[hidden:random]"
            return candidate

        res = self._randomish_re.sub(_replace_random, res)
        return res

# ---------------------------------------------------------------------------
# Heimdall Log Readers & Data Models
# ---------------------------------------------------------------------------

class ShellCommandEntry:
    def __init__(self, ts: str, cmd: str, cwd: str, exit_code: int, src: str):
        self.ts = ts
        self.cmd = cmd
        self.cwd = cwd
        self.exit_code = exit_code
        self.src = src

    def to_dict(self):
        return {
            "ts": self.ts,
            "cmd": self.cmd,
            "cwd": self.cwd,
            "exit": self.exit_code,
            "src": self.src,
        }


def read_last_failed_command(ragnarok_dir: Path) -> ShellCommandEntry | None:
    """Read the most recent failed shell command from ~/.ragnarok/heimdall-shell.jsonl."""
    log_path = ragnarok_dir / "heimdall-shell.jsonl"
    if not log_path.is_file():
        return None

    try:
        with open(log_path, "r", encoding="utf-8", errors="replace") as f:
            lines = f.readlines()
        for line in reversed(lines):
            line = line.strip()
            if not line:
                continue
            try:
                data = json.loads(line)
                if data.get("exit", 0) != 0:
                    return ShellCommandEntry(
                        ts=data.get("ts", ""),
                        cmd=data.get("cmd", ""),
                        cwd=data.get("cwd", str(Path.cwd())),
                        exit_code=int(data.get("exit", 1)),
                        src=data.get("src", "heimdall-shell"),
                    )
            except Exception:
                continue
    except Exception:
        pass
    return None


def read_recent_shell_output(ragnarok_dir: Path, max_lines: int = 100) -> str:
    """Read the last N lines from ~/.ragnarok/heimdall-shell-output.log."""
    log_path = ragnarok_dir / "heimdall-shell-output.log"
    if not log_path.is_file():
        return ""

    try:
        with open(log_path, "r", encoding="utf-8", errors="replace") as f:
            lines = f.readlines()
        return "".join(lines[-max_lines:])
    except Exception:
        return ""


def read_last_app_error(ragnarok_dir: Path) -> dict | None:
    """Read the most recent error from ~/.ragnarok/ragnarok-app-errors.jsonl."""
    log_path = ragnarok_dir / "ragnarok-app-errors.jsonl"
    if not log_path.is_file():
        return None

    try:
        with open(log_path, "r", encoding="utf-8", errors="replace") as f:
            lines = f.readlines()
        for line in reversed(lines):
            line = line.strip()
            if not line:
                continue
            try:
                data = json.loads(line)
                if data.get("level") in ("error", "fault") or data.get("severity") in ("critical", "high", "medium"):
                    return data
            except Exception:
                continue
    except Exception:
        pass
    return None

# ---------------------------------------------------------------------------
# Specialized Pipeline & Error Debugging Prompt Builder
# ---------------------------------------------------------------------------

DEBUG_SYSTEM_PROMPT = """You are Heimdall's Autonomous Pipeline and Error Debugging Specialist.
Your mission is to perform precise, actionable diagnostic analysis on build failures, pipeline breaks, runtime exceptions, and shell command errors.

You MUST respond using the following structured Markdown format:

### 1. 🚨 Failure Signature
- **Pipeline Stage / Command**: The exact command or pipeline step that failed.
- **Exit Code / Signal**: Exit status code (e.g. 1, 127, 255, SIGSEGV).
- **Exact Failure Location**: Culprit file path and line number if visible in the trace, or N/A.
- **Error Classification**: (e.g., SyntaxError, Dependency/ImportMissing, Compiler/Linker, PermissionDenied, EnvironmentVariableMissing, SchemaMismatch, NetworkTimeout).

### 2. 🔍 Root Cause Analysis (RCA)
- Provide a concise, technically exact explanation of WHY this failure happened.
- Distinguish the primary trigger from secondary cascading errors.
- Note any OS-specific behaviors (macOS, Linux, or Windows).

### 3. 🛠️ Remediation & Patch
- Provide the precise fix. If a code or configuration file must be modified, give a clean unified diff (`diff` block) or exact before/after snippet.
- If dependencies or environment variables are missing, specify the exact configuration.

### 4. ⚡ Executable Fix Command
- Provide the exact copy-pasteable terminal command(s) to fix the issue immediately (e.g. install package, create directory, fix permissions, export variable). Wrap inside a single code block.

### 5. 🧪 Pipeline Verification Command
- Provide the exact terminal command to re-run and verify the pipeline passes cleanly.

### 6. 🛡️ Preventative Guard
- One clear sentence explaining how to prevent this defect in future pipeline or CI runs (e.g. pre-commit hook, compiler check, schema validator).
"""

def build_debugging_prompt(
    cmd: str,
    exit_code: int,
    cwd: str,
    log_context: str,
    error_summary: str = "",
    os_info: str = "",
) -> str:
    """Assemble the contextual user prompt for the debugging loop."""
    if not os_info:
        os_info = f"{platform.system()} {platform.release()} ({platform.machine()})"

    prompt = f"""[HEIMDALL PIPELINE FAILURE REPORT]
Operating System: {os_info}
Working Directory: {cwd}
Executed Command: {cmd}
Exit Code: {exit_code}
{f"Summary Note: {error_summary}" if error_summary else ""}

[SCRUBBED PIPELINE / TERMINAL LOG]
```
{log_context.strip() if log_context.strip() else "(No explicit output captured)"}
```

Please perform the complete Root Cause Analysis and provide the exact executable remediation according to your debugging protocol."""
    return prompt

# ---------------------------------------------------------------------------
# Multimodal Utilities & Image Encoding
# ---------------------------------------------------------------------------

def load_and_encode_images(image_paths: list[str]) -> list[dict]:
    """Load image files and return structured objects with metadata and base64 bytes."""
    encoded = []
    if not image_paths:
        return encoded
    for p_str in image_paths:
        if not p_str:
            continue
        p = Path(p_str).expanduser().resolve()
        if not p.is_file():
            continue
        suffix = p.suffix.lower()
        mime = "image/png"
        if suffix in (".jpg", ".jpeg"):
            mime = "image/jpeg"
        elif suffix == ".webp":
            mime = "image/webp"
        elif suffix == ".gif":
            mime = "image/gif"
        try:
            with open(p, "rb") as f:
                b64 = base64.b64encode(f.read()).decode("ascii")
                encoded.append({
                    "path": str(p),
                    "name": p.name,
                    "mime": mime,
                    "base64": b64,
                    "size": p.stat().st_size,
                })
        except Exception:
            continue
    return encoded

# ---------------------------------------------------------------------------
# AI Model Loop-Back Dispatcher (Cross-Platform & Multimodal)
# ---------------------------------------------------------------------------

class AIModelDispatcher:
    """Manages model loop-back across Ollama, Claude, Codex, Grok, and APIs."""

    def __init__(self, ragnarok_dir: Path, scrubber: SecretScrubber):
        self.ragnarok_dir = ragnarok_dir
        self.scrubber = scrubber
        self.config = resolve_local_config(ragnarok_dir)
        self.ollama_url = self._resolve_ollama_url()

    def _resolve_ollama_url(self) -> str:
        """Resolve Ollama endpoint from env, local.conf, localhost, or Alexus default."""
        if os.environ.get("OLLAMA_HOST"):
            return os.environ["OLLAMA_HOST"].rstrip("/")
        if os.environ.get("OLLAMA_URL"):
            return os.environ["OLLAMA_URL"].rstrip("/")
        if "OLLAMA_URL" in self.config:
            return self.config["OLLAMA_URL"].rstrip("/")
        if "ALEXUS_HOST" in self.config:
            return f"http://{self.config['ALEXUS_HOST']}:11434"

        # Check localhost first (fast connect timeout)
        try:
            req = urllib.request.Request("http://127.0.0.1:11434/api/tags", headers={"User-Agent": "heimdall-debugger"})
            with urllib.request.urlopen(req, timeout=0.5):
                return "http://127.0.0.1:11434"
        except Exception:
            pass

        # Fallback: the server's default name (set ALEXUS_HOST in ~/.ragnarok/local.conf)
        return "http://alexus.local:11434"

    def list_ollama_models(self, strict: bool = False) -> list[str]:
        """Fetch list of available models from Ollama."""
        try:
            url = f"{self.ollama_url}/api/tags"
            req = urllib.request.Request(url, headers={"User-Agent": "heimdall-debugger"})
            with urllib.request.urlopen(req, timeout=3) as resp:
                data = json.loads(resp.read().decode("utf-8"))
                return [m.get("name") for m in data.get("models", []) if m.get("name")]
        except Exception as error:
            if strict:
                raise RuntimeError("Ollama discovery failed: " + self.scrubber.clean(str(error))) from error
            return []

    def detect_available_providers(self) -> dict[str, str]:
        """Check which CLI tools and model endpoints are available."""
        available = {}

        # 1. Ollama
        ollama_models = self.list_ollama_models()
        if ollama_models:
            # Pick best coder/instruct model (prefer fast 3b models for responsive terminal debugging)
            preferred = ["qwen2.5-coder:3b", "llama3.2:3b", "qwen2.5-coder:7b", "llama3.1:8b"]
            picked = ollama_models[0]
            for p in preferred:
                if p in ollama_models:
                    picked = p
                    break
            available["ollama"] = f"Ollama ({picked} @ {self.ollama_url})"


        # 3. Claude CLI
        if shutil.which("claude"):
            available["claude"] = "Claude Code CLI (claude)"

        # 4. Codex CLI
        if shutil.which("codex"):
            available["codex"] = "OpenAI Codex CLI (codex)"

        # 5. Grok CLI
        if shutil.which("grok"):
            available["grok"] = "xAI Grok CLI (grok)"

        # 6. Direct APIs
        if os.environ.get("GEMINI_API_KEY"):
            available["gemini"] = "Google Gemini API (Direct)"
        if os.environ.get("OPENAI_API_KEY"):
            available["openai"] = "OpenAI API (Direct)"
        if os.environ.get("ANTHROPIC_API_KEY"):
            available["anthropic"] = "Anthropic API (Direct)"

        return available

    def query_ollama(self, prompt: str, system_prompt: str, model: str = "", images: list[dict] = None) -> str:
        """Call Ollama /api/chat with streaming to terminal, supporting multimodal vision."""
        if not model:
            models = self.list_ollama_models()
            if images:
                # If images are provided, prefer vision-capable models (e.g. qwen2.5vl:3b or llava)
                for v in ["qwen2.5vl:3b", "llava", "bakllava", "qwen2.5-coder:3b"]:
                    if v in models:
                        model = v
                        break
            if not model:
                for cand in ["qwen2.5-coder:3b", "llama3.2:3b", "qwen2.5-coder:7b", "llama3.1:8b", "codellama", "mistral"]:
                    if cand in models:
                        model = cand
                        break
            if not model and models:
                model = models[0]
            if not model:
                model = "llama3.1:8b"

        installed = self.list_ollama_models(strict=True)
        if model not in installed:
            raise ValueError(f"Ollama model {model!r} is unavailable; discovered models: {installed}")
        if images:
            req = urllib.request.Request(f"{self.ollama_url}/api/show", data=json.dumps({"model": model}).encode(), headers={"Content-Type": "application/json"})
            with urllib.request.urlopen(req, timeout=10) as response:
                capabilities = json.loads(response.read()).get("capabilities", [])
            if "vision" not in capabilities:
                raise ValueError(f"Ollama model {model!r} does not report vision support")

        url = f"{self.ollama_url}/api/chat"
        user_msg = {"role": "user", "content": prompt}
        if images:
            user_msg["images"] = [img["base64"] for img in images]

        payload = {
            "model": model,
            "messages": [
                {"role": "system", "content": system_prompt},
                user_msg,
            ],
            "stream": True,
            "options": {"temperature": 0.2, "num_ctx": 32768, "num_predict": 8192},
        }

        if getattr(self, "json_mode", False):
            payload["format"] = "json"
        req = urllib.request.Request(
            url,
            data=json.dumps(payload).encode("utf-8"),
            headers={"Content-Type": "application/json", "User-Agent": "heimdall-debugger"},
            method="POST",
        )

        full_reply = []
        request_started = time.monotonic()
        with urllib.request.urlopen(req, timeout=120) as resp:
            for line in resp:
                if time.monotonic() - request_started > 120:
                    raise TimeoutError("Ollama response exceeded the 120 second request budget")
                if sum(len(chunk) for chunk in full_reply) > 512 * 1024:
                    raise ValueError("Ollama response exceeded output budget")
                if not line:
                    continue
                try:
                    chunk = json.loads(line.decode("utf-8"))
                    msg = chunk.get("message", {}).get("content", "")
                    if msg:
                        full_reply.append(msg)
                    if chunk.get("done", False):
                        break
                except Exception:
                    continue
        reply = self.scrubber.clean("".join(full_reply))
        display(reply)
        return reply

    def query_cli(self, provider: str, prompt: str, system_prompt: str, model: str = "", images: list[dict] = None) -> str:
        """Invoke external CLI tool (claude, codex, grok)."""
        combined_prompt = f"{system_prompt}\n\n{prompt}"
        if images:
            raise ValueError(f"Image transport is not implemented for {provider}; use a supported API or Ollama vision model")

        if provider == "claude":
            cmd = ["claude", "-p", combined_prompt]
        elif provider == "codex":
            cmd = ["codex", "exec", combined_prompt]
        elif provider == "grok":
            cmd = ["grok", "-p", combined_prompt, "--no-plan"]
        else:
            raise ValueError(f"Unknown CLI provider: {provider}")

        if model:
            cmd.extend(["--model", model])
        result = execute(cmd, timeout=120)
        output = self.scrubber.clean(result["stdout"] + result["stderr"])
        display(output)
        if result.get("status") != "succeeded" or result["exit"] != 0:
            raise RuntimeError(f"{provider} failed (exit {result['exit']}, timed_out={result['timed_out']}): {output[-2000:]}")
        if not output.strip():
            raise RuntimeError(f"{provider} returned no response")
        return output

    def query_gemini_api(self, prompt: str, system_prompt: str, model: str = "gemini-1.5-flash", images: list[dict] = None) -> str:
        """Call Gemini API via standard library urllib with multimodal support."""
        api_key = os.environ.get("GEMINI_API_KEY", "")
        if not api_key:
            raise ValueError("GEMINI_API_KEY environment variable is required")

        url = f"https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent?key={api_key}"
        parts = [{"text": prompt}]
        if images:
            for img in images:
                parts.append({"inlineData": {"mimeType": img["mime"], "data": img["base64"]}})

        payload = {
            "system_instruction": {"parts": [{"text": system_prompt}]},
            "contents": [{"parts": parts}],
            "generationConfig": {"temperature": 0.2},
        }

        req = urllib.request.Request(
            url,
            data=json.dumps(payload).encode("utf-8"),
            headers={"Content-Type": "application/json"},
            method="POST",
        )

        with urllib.request.urlopen(req, timeout=60) as resp:
            data = json.loads(resp.read().decode("utf-8"))
            try:
                text = data["candidates"][0]["content"]["parts"][0]["text"]
                text = self.scrubber.clean(text)
                display(text)
                return text
            except (KeyError, IndexError):
                raise RuntimeError(f"Unexpected Gemini API response structure: {data}")

    def query_claude_text(self, prompt, system_prompt, model, images=None):
        if images:
            raise ValueError("The isolated Claude text adapter does not support images")
        if not model:
            raise ValueError("An explicit Claude model is required")
        # Tools and customizations are disabled; only the supplied scoped packet is sent.
        with tempfile.TemporaryDirectory(prefix="pipeline-cloud-text-") as cwd:
            cmd = ["claude", "-p", prompt, "--model", model, "--safe-mode", "--tools", "",
                   "--disable-slash-commands", "--no-session-persistence", "--setting-sources", "",
                   "--strict-mcp-config", "--mcp-config", '{"mcpServers":{}}',
                   "--system-prompt", system_prompt, "--output-format", "text"]
            result = execute(cmd, cwd=cwd, timeout=120)
        output = self.scrubber.clean(result["stdout"] + result["stderr"])
        if result.get("status") != "succeeded" or result["exit"] != 0:
            raise RuntimeError(f"Claude text request failed (exit {result['exit']}): {output[-2000:]}")
        display(output)
        return output

    def query_anthropic_api(self, prompt, system_prompt, model, images=None):
        key = os.environ.get("ANTHROPIC_API_KEY")
        if not key:
            raise ValueError("ANTHROPIC_API_KEY is required")
        if not model:
            raise ValueError("An explicit Anthropic model is required")
        content = [{"type": "text", "text": prompt}]
        for image in images or []:
            content.append({"type": "image", "source": {"type": "base64", "media_type": image["mime"], "data": image["base64"]}})
        req = urllib.request.Request("https://api.anthropic.com/v1/messages",
            data=json.dumps({"model": model, "system": system_prompt, "max_tokens": 8192,
                "messages": [{"role": "user", "content": content}]}).encode(),
            headers={"content-type": "application/json", "x-api-key": key, "anthropic-version": "2023-06-01"})
        with urllib.request.urlopen(req, timeout=120) as response:
            reply = self.scrubber.clean("".join(part.get("text", "") for part in json.loads(response.read())["content"]))
        display(reply)
        return reply

    def query_openai_api(self, prompt: str, system_prompt: str, model: str = "gpt-4o-mini", images: list[dict] = None) -> str:
        """Call OpenAI or compatible API via standard library urllib with multimodal support."""
        api_key = os.environ.get("OPENAI_API_KEY", "")
        base_url = os.environ.get("OPENAI_BASE_URL", "https://api.openai.com/v1").rstrip("/")
        url = f"{base_url}/chat/completions"

        if images:
            user_content = [{"type": "text", "text": prompt}]
            for img in images:
                user_content.append({"type": "image_url", "image_url": {"url": f"data:{img['mime']};base64,{img['base64']}"}})
        else:
            user_content = prompt

        payload = {
            "model": model,
            "messages": [
                {"role": "system", "content": system_prompt},
                {"role": "user", "content": user_content},
            ],
            "temperature": 0.2,
        }

        headers = {
            "Content-Type": "application/json",
            "Authorization": f"Bearer {api_key}" if api_key else "",
        }

        req = urllib.request.Request(url, data=json.dumps(payload).encode("utf-8"), headers=headers, method="POST")
        with urllib.request.urlopen(req, timeout=60) as resp:
            data = json.loads(resp.read().decode("utf-8"))
            text = data["choices"][0]["message"]["content"]
            text = self.scrubber.clean(text)
            display(text)
            return text

    def query(self, prompt: str, system_prompt: str, provider: str = "", model: str = "", images: list[dict] = None) -> str:
        reply = self._query(prompt, system_prompt, provider, model, images)
        reply = self.scrubber.clean(reply)
        print("PIPELINE_EVENT " + json.dumps({"type": "diagnosis", "response": reply}))
        return reply

    def _query(self, prompt: str, system_prompt: str, provider: str = "", model: str = "", images: list[dict] = None) -> str:
        """Dispatch prompt to the best or chosen provider with optional multimodal images."""
        # Clean prompt through scrubber to ensure no secrets ever leave
        clean_prompt = self.scrubber.clean(prompt)
        clean_system = self.scrubber.clean(system_prompt)

        available = self.detect_available_providers()
        if not provider:
            # If multimodal images are attached, prefer vision providers
            if images and "ollama" in available and any("vl" in m or "llava" in m for m in self.list_ollama_models()):
                provider = "ollama"
            elif images and "gemini" in available:
                provider = "gemini"
            elif images and "openai" in available:
                provider = "openai"
            elif "ollama" in available:
                provider = "ollama"
            elif "claude" in available:
                provider = "claude"
            elif "codex" in available:
                provider = "codex"
            elif "grok" in available:
                provider = "grok"
            elif "gemini" in available:
                provider = "gemini"
            elif "openai" in available:
                provider = "openai"
            else:
                provider = "ollama"

        prov_note = f"{Colors.cyan_bold('>>> Routing to AI Model Provider:')} {Colors.bold(provider)} {Colors.dim(f'(model: {model or 'default'})')}"
        if images:
            prov_note += f" {Colors.magenta_bold(f'[+ {len(images)} multimodal image(s)]')}"
        print(f"\n{prov_note}\n")

        if provider == "ollama":
            return self.query_ollama(clean_prompt, clean_system, model, images=images)
        elif provider in ("claude", "codex", "grok"):
            return self.query_cli(provider, clean_prompt, clean_system, model, images=images)
        elif provider == "gemini":
            return self.query_gemini_api(clean_prompt, clean_system, model or "gemini-1.5-flash", images=images)
        elif provider == "openai":
            return self.query_openai_api(clean_prompt, clean_system, model or "gpt-4o-mini", images=images)
        elif provider == "claude-text":
            return self.query_claude_text(clean_prompt, clean_system, model, images)
        elif provider == "anthropic":
            return self.query_anthropic_api(clean_prompt, clean_system, model, images)
        elif provider == "mock":
            mock_resp = f"""### 1. 🚨 Failure Signature
- **Pipeline Stage / Command**: Mock Pipeline Test
- **Exit Code / Signal**: Exit 1
- **Exact Failure Location**: tests/test_pipeline.py:42
- **Error Classification**: AssertionError

### 2. 🔍 Root Cause Analysis (RCA)
Simulated pipeline test failure detected. Multimodal attachments analyzed: {len(images) if images else 0}.

### 3. 🛠️ Remediation & Patch
Update test_pipeline.py to assert correct expected state.

### 4. ⚡ Executable Fix Command
```bash
pytest -v tests/test_pipeline.py
```

### 5. 🧪 Pipeline Verification Command
```bash
heimdall-debug last
```

### 6. 🛡️ Preventative Guard
Ensure pre-commit CI runs unit tests before push."""
            print(mock_resp)
            return mock_resp
        else:
            raise ValueError(f"Unsupported provider: {provider}")

# ---------------------------------------------------------------------------
# Multimodal Autonomous Agent Engine (Heimdall / Proved-Mode Reference)
# ---------------------------------------------------------------------------

class AutonomousAgentEngine:
    """Heimdall-inspired multi-modal autonomous pipeline repair agent.
    1. Formulates plan: - [ ] / - [~] / - [x]
    2. Executes repair action (tool execution)
    3. Runs verification check (Proved mode)
    4. Iterates until clean pass or max rounds reached
    """

    def __init__(self, dispatcher: AIModelDispatcher, scrubber: SecretScrubber, ragnarok_dir: Path):
        self.dispatcher = dispatcher
        self.scrubber = scrubber
        self.ragnarok_dir = ragnarok_dir

    def run(
        self,
        task: str,
        cwd: str = "",
        images: list[dict] = None,
        max_rounds: int = 3,
        provider: str = "",
        model: str = "",
    ) -> dict:
        cwd = cwd or str(Path.cwd())
        run_id = f"agent-{uuid.uuid4().hex[:8]}"
        run_dir = self.ragnarok_dir / "agents" / run_id
        run_dir.mkdir(parents=True, exist_ok=True, mode=0o700)

        print(f"\n{Colors.cyan_bold('╔═══════════════════════════════════════════════════════════════════════════╗')}")
        print(f"{Colors.cyan_bold('║')}  {Colors.bold(f'HEIMDALL AUTONOMOUS REPAIR AGENT [{run_id}]')}                      {Colors.cyan_bold('║')}")
        print(f"{Colors.cyan_bold('║')}  {Colors.dim(f'Task: {task[:58]:<58}')} {Colors.cyan_bold('║')}")
        if images:
            print(f"{Colors.cyan_bold('║')}  {Colors.dim(f'Multimodal Images: {len(images)} attached')}                                  {Colors.cyan_bold('║')}")
        print(f"{Colors.cyan_bold('╚═══════════════════════════════════════════════════════════════════════════╝')}\n")

        state = {
            "id": run_id,
            "task": task,
            "cwd": cwd,
            "status": "starting",
            "verdict": "in_progress",
            "plan": [],
            "actions": [],
            "rounds": 0,
        }

        agent_system = """You are Heimdall's Autonomous Pipeline Repair and Proving Agent.
Your job is to inspect errors (including any visual test screenshots), formulate a concrete multi-step plan, execute repair commands, and prove the fix with a verification check.

Respond using this EXACT format:

### PLAN
- [~] 1. <Active Step>
- [ ] 2. <Next Step>
- [ ] 3. <Verification Step>

### ACTION
TOOL: Bash
COMMAND:
```bash
<Terminal command to fix or patch the issue>
```

### VERIFICATION
```bash
<Terminal command to run to prove the fix passes>
```

### EXPLANATION
<Concise explanation of the repair action>
"""

        current_context = f"Task: {task}\nWorking Folder: {cwd}\n"
        shell_log = read_recent_shell_output(self.ragnarok_dir, max_lines=60)
        if shell_log:
            current_context += f"\nRecent Shell Output:\n```\n{shell_log}\n```\n"

        for round_idx in range(1, max_rounds + 1):
            state["rounds"] = round_idx
            print(f"{Colors.yellow_bold(f'--- [Agent Round {round_idx}/{max_rounds}] Planning & Action ---')}\n")

            prompt = f"{current_context}\nRound {round_idx}: Formulate or update your plan and provide the next repair ACTION and VERIFICATION check."
            reply = self.dispatcher.query(prompt, agent_system, provider=provider, model=model, images=images)

            # Parse plan
            plan_steps = []
            for line in reply.splitlines():
                l = line.strip()
                if l.startswith("- [ ]") or l.startswith("- [~]") or l.startswith("- [x]"):
                    status = "completed" if "[x]" in l else ("in_progress" if "[~]" in l else "pending")
                    step_text = l.split("]", 1)[1].strip()
                    plan_steps.append({"step": step_text, "status": status})
            if plan_steps:
                state["plan"] = plan_steps

            # Extract Action Command
            action_cmd = ""
            if "### ACTION" in reply:
                part = reply.split("### ACTION", 1)[1]
                if "### VERIFICATION" in part:
                    part = part.split("### VERIFICATION", 1)[0]
                if "```" in part:
                    c_part = part.split("```", 1)[1]
                    if "\n" in c_part:
                        c_part = c_part.split("\n", 1)[1]
                    action_cmd = c_part.split("```", 1)[0].strip()

            # Extract Verification Command
            verify_cmd = ""
            if "### VERIFICATION" in reply:
                part = reply.split("### VERIFICATION", 1)[1]
                if "### EXPLANATION" in part:
                    part = part.split("### EXPLANATION", 1)[0]
                if "```" in part:
                    c_part = part.split("```", 1)[1]
                    if "\n" in c_part:
                        c_part = c_part.split("\n", 1)[1]
                    verify_cmd = c_part.split("```", 1)[0].strip()

            act_code = None
            # Execute Action
            if action_cmd:
                print(f"\n{Colors.cyan_bold('⚡ [Agent Action Execution]')} Running: {Colors.bold(action_cmd)}")
                action_result = execute(action_cmd, cwd=cwd)
                act_code = action_result["exit"]
                act_out = self.scrubber.clean(action_result["stdout"] + action_result["stderr"])
                display(act_out.strip() or "(no output)")
                state["actions"].append({
                    "round": round_idx,
                    "tool": "Bash",
                    "cmd": action_cmd,
                    "exit": act_code,
                    "out": act_out[-500:],
                })

            # Execute Verification Check (Proved mode)
            if verify_cmd:
                print(f"\n{Colors.magenta_bold('🧪 [Proved Mode Verification]')} Running: {Colors.bold(verify_cmd)}")
                verification = execute(verify_cmd, cwd=cwd)
                ver_code = verification["exit"]
                ver_out = self.scrubber.clean(verification["stdout"] + verification["stderr"])
                state["verification"] = verification
                display(ver_out.strip() or "(clean exit)")
                print(f"{Colors.dim(f'Verification Exit Code: {ver_code}')}")

                if ver_code == 0 and act_code == 0 and verification["status"] == "succeeded" and action_result["status"] == "succeeded":
                    print(f"\n{Colors.green_bold('✔ VERDICT: UNVERIFIED')} (Agent-supplied check passed; independent validation required in round {round_idx}!)")
                    state["status"] = "completed"
                    state["verdict"] = "unverified"
                    for step in state["plan"]:
                        step["status"] = "completed"
                    break
                else:
                    print(f"\n{Colors.yellow_bold(f'✖ Verification failed (exit {ver_code})')} — looping back into agent...")
                    current_context += f"\nRound {round_idx} Result:\nAction command '{action_cmd}' executed (exit {act_code}).\nVerification command '{verify_cmd}' failed with exit code {ver_code}:\n```\n{ver_out[-1000:]}\n```\nPlease analyze why the verification failed and provide the refined fix.\n"
            else:
                state["status"] = "completed"
                state["verdict"] = "needs_you"
                break

        if state["verdict"] != "unverified":
            state["status"] = "completed"
            state["verdict"] = "needs_you"
            print(f"\n{Colors.yellow_bold('⚠ VERDICT: NEEDS YOU')} (Max rounds reached without clean verification pass)")

        # These legacy host actions are never independently validated.
        state["independent_validation"] = False
        state = json.loads(self.scrubber.clean(json.dumps(state)))
        print("PIPELINE_EVENT " + json.dumps({"type": "agent_state", "state": state}))
        # Persist state
        with open(run_dir / "state.json", "w", encoding="utf-8") as f:
            json.dump(state, f, indent=2)

        return state

# ---------------------------------------------------------------------------
# Core Operational Modes
# ---------------------------------------------------------------------------

def run_command_pipeline(cmd: str, dispatcher: AIModelDispatcher, scrubber: SecretScrubber, provider: str = "", model: str = "", images: list[dict] = None) -> int:
    """Run an arbitrary pipeline command, streaming live, and trigger AI debugging on failure."""
    display(f"{Colors.cyan_bold('[Heimdall Pipeline Wrapper]')} Running: {Colors.bold(scrubber.clean(cmd))}")
    print(Colors.dim("-" * 72))

    result = execute(cmd, timeout=120)
    output = scrubber.clean(result["stdout"] + result["stderr"])
    display(output)
    captured = output.splitlines(keepends=True)
    elapsed = result["duration"]
    code = result["exit"]
    print("PIPELINE_EVENT " + scrubber.clean(json.dumps({"type": "command_result", "stage": "pipeline", "result": result})))
    if result["status"] not in ("succeeded", "failed"):
        print(f"Pipeline {result['status']} (actual exit: {code}); no successful result recorded")
        return code or 1

    print(Colors.dim("-" * 72))
    if code == 0:
        print(f"{Colors.green_bold('✔ Pipeline succeeded')} in {elapsed:.2f}s (exit 0)")
        return 0

    print(f"{Colors.red_bold(f'✖ Pipeline failed with exit code {code}')} in {elapsed:.2f}s")
    print(f"{Colors.magenta_bold('⚡ Invoking AI Pipeline & Error Debugger loopback...')}")

    log_tail = "".join(captured[-150:])
    scrubbed_log = scrubber.clean(log_tail)

    prompt = build_debugging_prompt(
        cmd=cmd,
        exit_code=code,
        cwd=str(Path.cwd()),
        log_context=scrubbed_log,
        error_summary=f"Pipeline execution returned exit code {code}",
    )

    try:
        dispatcher.query(prompt, DEBUG_SYSTEM_PROMPT, provider=provider, model=model, images=images)
    except Exception as e:
        display(f"\n{Colors.red_bold('[Error querying model]')}: {scrubber.clean(str(e))}")
    return code


def run_last_error(dispatcher: AIModelDispatcher, scrubber: SecretScrubber, ragnarok_dir: Path, provider: str = "", model: str = "", images: list[dict] = None):
    """Find the last failed command from Heimdall logs and debug it."""
    print(f"{Colors.cyan_bold('[Heimdall AI Debugger]')} Searching for last failed command in {ragnarok_dir}...")

    cmd_entry = read_last_failed_command(ragnarok_dir)
    app_err = read_last_app_error(ragnarok_dir)

    if not cmd_entry and not app_err:
        print(f"{Colors.green_bold('No recorded failures or non-zero exit codes found in Heimdall logs.')}")
        return

    # Use command failure if present, else app error
    if cmd_entry:
        print(f"\n{Colors.yellow_bold('Found failed terminal command:')}")
        print(f"  Command:   {Colors.bold(scrubber.clean(cmd_entry.cmd))}")
        print(f"  Exit code: {Colors.red(str(cmd_entry.exit_code))}")
        print(f"  Folder:    {scrubber.clean(str(cmd_entry.cwd))}")
        print(f"  Timestamp: {scrubber.clean(str(cmd_entry.ts))}")

        shell_output = read_recent_shell_output(ragnarok_dir, max_lines=120)
        scrubbed_log = scrubber.clean(shell_output)

        prompt = build_debugging_prompt(
            cmd=cmd_entry.cmd,
            exit_code=cmd_entry.exit_code,
            cwd=cmd_entry.cwd,
            log_context=scrubbed_log,
            error_summary=f"Terminal command exited with code {cmd_entry.exit_code}",
        )
    else:
        print(f"\n{Colors.yellow_bold('Found Heimdall app error:')}")
        print(f"  Area:      {app_err.get('area')}")
        print(f"  Message:   {scrubber.clean(str(app_err.get('message')))}")
        print(f"  Timestamp: {app_err.get('ts')}")

        prompt = build_debugging_prompt(
            cmd=f"Heimdall Area: {app_err.get('area', 'unknown')}",
            exit_code=int(app_err.get("code", 1)),
            cwd=str(Path.home()),
            log_context=app_err.get("message", ""),
            error_summary=f"App logged error level={app_err.get('level')} severity={app_err.get('severity')}",
        )

    dispatcher.query(prompt, DEBUG_SYSTEM_PROMPT, provider=provider, model=model, images=images)


def run_watch_mode(dispatcher: AIModelDispatcher, scrubber: SecretScrubber, ragnarok_dir: Path, interval: float = 2.0, provider: str = "", model: str = ""):
    """Continuously monitor Heimdall shell log for newly completed commands that exited with an error."""
    shell_log = ragnarok_dir / "heimdall-shell.jsonl"
    print(f"{Colors.cyan_bold('[Heimdall Pipeline Watcher]')} Active monitoring on {shell_log}")
    print(f"{Colors.dim(f'Checking for non-zero exit codes every {interval}s. Press Ctrl+C to stop.')}\n")

    # Start watching from current EOF
    last_pos = shell_log.stat().st_size if shell_log.is_file() else 0

    try:
        while True:
            time.sleep(interval)
            if not shell_log.is_file():
                continue

            current_size = shell_log.stat().st_size
            if current_size < last_pos:
                last_pos = 0  # file rotated

            if current_size > last_pos:
                with open(shell_log, "r", encoding="utf-8", errors="replace") as f:
                    f.seek(last_pos)
                    new_lines = f.readlines()
                    last_pos = f.tell()

                for line in new_lines:
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        data = json.loads(line)
                        exit_code = int(data.get("exit", 0))
                        if exit_code != 0:
                            cmd = data.get("cmd", "")
                            cwd = data.get("cwd", str(Path.cwd()))
                            ts = data.get("ts", "")
                            print(f"\n{Colors.red_bold(f'🚨 Detected Failure in Shell:')} {Colors.bold(cmd)} (exit {exit_code}) at {ts}")
                            shell_output = read_recent_shell_output(ragnarok_dir, max_lines=80)
                            scrubbed_log = scrubber.clean(shell_output)

                            prompt = build_debugging_prompt(
                                cmd=cmd,
                                exit_code=exit_code,
                                cwd=cwd,
                                log_context=scrubbed_log,
                                error_summary="Watch mode caught non-zero command termination",
                            )
                            dispatcher.query(prompt, DEBUG_SYSTEM_PROMPT, provider=provider, model=model)
                            print(f"\n{Colors.cyan_bold('[Watcher resumed]')} Standing by for subsequent errors...\n")
                    except Exception as parse_err:
                        continue
    except KeyboardInterrupt:
        print(f"\n{Colors.yellow_bold('Watcher stopped.')}")


def run_pipe_mode(dispatcher: AIModelDispatcher, scrubber: SecretScrubber, provider: str = "", model: str = "", images: list[dict] = None):
    """Read logs piped through stdin and pass them directly to the AI debugging loop."""
    print(f"{Colors.cyan_bold('[Heimdall Pipeline Debugger]')} Ingesting log stream from stdin...")
    content = sys.stdin.read()
    if not content.strip():
        print(f"{Colors.yellow_bold('No content received on stdin.')}")
        return

    scrubbed = scrubber.clean(content)
    prompt = build_debugging_prompt(
        cmd="Piped Standard Input",
        exit_code=1,
        cwd=str(Path.cwd()),
        log_context=scrubbed[-4000:],
        error_summary="Diagnosing piped error log",
    )
    dispatcher.query(prompt, DEBUG_SYSTEM_PROMPT, provider=provider, model=model, images=images)


def run_triage_file(file_path: str, dispatcher: AIModelDispatcher, scrubber: SecretScrubber, provider: str = "", model: str = "", images: list[dict] = None):
    """Triage and debug an arbitrary log file on disk."""
    p = Path(file_path).expanduser().resolve()
    if not p.is_file():
        print(f"{Colors.red_bold(f'Log file not found: {file_path}')}")
        sys.exit(1)

    print(f"{Colors.cyan_bold('[Heimdall Pipeline Debugger]')} Triaging log file: {p}")
    with open(p, "r", encoding="utf-8", errors="replace") as f:
        lines = f.readlines()

    scrubbed = scrubber.clean("".join(lines[-150:]))
    prompt = build_debugging_prompt(
        cmd=f"Triage: {p.name}",
        exit_code=1,
        cwd=str(p.parent),
        log_context=scrubbed,
        error_summary=f"Log file triage for {p.name}",
    )
    dispatcher.query(prompt, DEBUG_SYSTEM_PROMPT, provider=provider, model=model, images=images)

# ---------------------------------------------------------------------------
# Interactive Terminal UI (TUI / REPL)
# ---------------------------------------------------------------------------

def run_interactive_tui(dispatcher: AIModelDispatcher, scrubber: SecretScrubber, ragnarok_dir: Path):
    """Interactive terminal menu running directly in Heimdall Shell or standard terminal."""
    selected_provider = ""
    selected_model = ""

    while True:
        available = dispatcher.detect_available_providers()
        prov_display = selected_provider or (list(available.keys())[0] if available else "none")
        os_info = f"{platform.system()} ({platform.machine()})"

        print(f"\n{Colors.cyan_bold('╔═══════════════════════════════════════════════════════════════════════════╗')}")
        print(f"{Colors.cyan_bold('║')}  {Colors.bold('HEIMDALL TERMINAL PIPELINE & ERROR DEBUGGER')}                          {Colors.cyan_bold('║')}")
        print(f"{Colors.cyan_bold('║')}  {Colors.dim(f'OS: {os_info:<16} | Provider: {prov_display:<14} | Log: ~/.ragnarok')}  {Colors.cyan_bold('║')}")
        print(f"{Colors.cyan_bold('╚═══════════════════════════════════════════════════════════════════════════╝')}")

        print(f"  {Colors.bold('[1]')} Debug Last Terminal Error    {Colors.dim('(Triage the most recent shell failure)')}")
        print(f"  {Colors.bold('[2]')} Watch Pipeline Loop          {Colors.dim('(Live background watcher for failures)')}")
        print(f"  {Colors.bold('[3]')} Run Pipeline Command         {Colors.dim('(Run any build/test cmd with auto-debug)')}")
        print(f"  {Colors.bold('[4]')} Tail Scrubbed Shell Log      {Colors.dim('(View live scrubbed terminal output)')}")
        print(f"  {Colors.bold('[5]')} Select AI Provider & Model   {Colors.dim('(Switch between Ollama, claude, codex, APIs)')}")
        print(f"  {Colors.bold('[6]')} Ask Follow-Up Question       {Colors.dim('(Query AI model interactively)')}")
        print(f"  {Colors.bold('[7]')} Run Selfcheck Diagnostic     {Colors.dim('(Verify scrubber, paths, and model engine)')}")
        print(f"  {Colors.bold('[q]')} Quit\n")

        try:
            choice = input(f"{Colors.cyan_bold('Select option [1-7, q]: ')}").strip().lower()
        except (KeyboardInterrupt, EOFError):
            print("\nExiting.")
            break

        if choice in ("1", "last"):
            run_last_error(dispatcher, scrubber, ragnarok_dir, provider=selected_provider, model=selected_model)
        elif choice in ("2", "watch"):
            run_watch_mode(dispatcher, scrubber, ragnarok_dir, provider=selected_provider, model=selected_model)
        elif choice in ("3", "run"):
            cmd = input(f"{Colors.yellow_bold('Enter command to execute: ')}").strip()
            if cmd:
                run_command_pipeline(cmd, dispatcher, scrubber, provider=selected_provider, model=selected_model)
        elif choice in ("4", "tail"):
            log_txt = read_recent_shell_output(ragnarok_dir, max_lines=40)
            print(f"\n{Colors.cyan_bold('--- Last 40 lines of scrubbed shell transcript ---')}")
            print(scrubber.clean(log_txt))
            print(Colors.dim("-" * 60))
        elif choice in ("5", "provider", "model"):
            print(f"\n{Colors.cyan_bold('Available Providers:')}")
            prov_list = list(available.keys())
            for idx, p_name in enumerate(prov_list, 1):
                print(f"  [{idx}] {p_name:<10} - {available[p_name]}")
            print("  [o] Other (manual string)")
            sel = input("Choose provider number or name (Enter to cancel): ").strip()
            if sel.isdigit() and 1 <= int(sel) <= len(prov_list):
                selected_provider = prov_list[int(sel) - 1]
            elif sel in prov_list or sel == "o":
                selected_provider = input("Enter provider name: ").strip() if sel == "o" else sel
            if selected_provider:
                m_input = input(f"Enter model name for {selected_provider} (leave blank for default): ").strip()
                selected_model = m_input
                print(f"{Colors.green_bold(f'Selected provider: {selected_provider}')} (model: {selected_model or 'default'})")
        elif choice in ("6", "ask", "chat"):
            query_text = input(f"{Colors.yellow_bold('Ask debugging question: ')}").strip()
            if query_text:
                dispatcher.query(query_text, DEBUG_SYSTEM_PROMPT, provider=selected_provider, model=selected_model)
        elif choice in ("7", "selfcheck"):
            run_selfcheck(dispatcher, scrubber, ragnarok_dir)
        elif choice in ("q", "quit", "exit"):
            print("Goodbye.")
            break

# ---------------------------------------------------------------------------
# Cross-Platform Automated Selfcheck & Test Suite
# ---------------------------------------------------------------------------

def run_selfcheck(dispatcher: AIModelDispatcher, scrubber: SecretScrubber, ragnarok_dir: Path):
    """Execute regression and verification suite for the debugger."""
    print(f"\n{Colors.cyan_bold('=== Running Heimdall Debugger Selfcheck Suite ===')}\n")
    passed = 0
    total = 0

    def check(name: str, condition: bool, note: str = ""):
        nonlocal passed, total
        total += 1
        if condition:
            passed += 1
            print(f"  {Colors.green('ok')}   {name:<35} {Colors.dim(note)}")
        else:
            print(f"  {Colors.red('FAIL')} {name:<35} {Colors.red(note)}")

    # 1. Platform & path checks
    check("platform-detection", platform.system() in ("Darwin", "Linux", "Windows"), f"OS: {platform.system()}")
    check("ragnarok-dir", ragnarok_dir.is_dir(), str(ragnarok_dir))

    # 2. Scrubber tests
    raw_secrets = (
        "sk-ant-api03-abcdef1234567890abcdef12345678 "
        "sk-proj-xyz1234567890abcdef1234567890abcdef "
        "ghp_1234567890abcdefghijklmnopqrstuvwxyz "
        "AKIAIOSFODNN7EXAMPLE "
        "password=SuperSecretPassword123! "
        "Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.doNotLeakThisSignature "
    )
    cleaned = scrubber.clean(raw_secrets)
    check("scrub-anthropic-key", "sk-ant-" not in cleaned and "[hidden:anthropic-key]" in cleaned)
    check("scrub-openai-key", "sk-proj-" not in cleaned and "[hidden:openai-key]" in cleaned)
    check("scrub-github-token", "ghp_" not in cleaned and "[hidden:github-token]" in cleaned)
    check("scrub-aws-key", "AKIA" not in cleaned and "[hidden:aws-key]" in cleaned)
    check("scrub-assignment", "SuperSecretPassword123!" not in cleaned and "[hidden:assignment]" in cleaned)
    check("scrub-jwt", "eyJhbGci" not in cleaned and "[hidden:jwt]" in cleaned)

    # 3. Shannon Entropy Random Scrubber
    high_entropy_random = "aB39kLmP0qWz7Xy2Rt5Vb8Nj4Fh1Ds6eQ"  # high entropy mixed 33 chars
    low_entropy_commit = "989728b3c1f0e2d4a5b6c7d8e9f0a1b2c3d4e5f6"  # pure hex
    cleaned_random = scrubber.clean(f"random string: {high_entropy_random}")
    cleaned_commit = scrubber.clean(f"git commit: {low_entropy_commit}")
    check("scrub-high-entropy", "[hidden:random]" in cleaned_random, "random high-entropy hidden")
    check("scrub-keep-commit-hex", low_entropy_commit in cleaned_commit, "hex commit hash preserved")

    # 4. JSONL Command Parsing
    mock_entry = ShellCommandEntry("2026-11-05T00:00:00Z", "pytest -v", "/tmp", 1, "test")
    check("data-model-entry", mock_entry.exit_code == 1 and mock_entry.cmd == "pytest -v")

    # 5. Prompt Generation
    prompt = build_debugging_prompt("npm run test", 1, "/workspace", "AssertionError: expected true to be false")
    check("prompt-contains-cmd", "npm run test" in prompt)
    check("prompt-contains-exit", "Exit Code: 1" in prompt)
    check("prompt-contains-log", "AssertionError" in prompt)

    # 6. Mock Model Dispatch
    mock_out = dispatcher.query("test prompt", DEBUG_SYSTEM_PROMPT, provider="mock")
    check("mock-model-dispatch", "Failure Signature" in mock_out and "Root Cause Analysis" in mock_out)

    # 7. Multimodal Image Encoding
    dummy_png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
    tmp_img = Path(tempfile.gettempdir()) / "test_diag.png"
    tmp_img.write_bytes(base64.b64decode(dummy_png))
    encoded_imgs = load_and_encode_images([str(tmp_img)])
    check("multimodal-image-encode", len(encoded_imgs) == 1 and encoded_imgs[0]["mime"] == "image/png", f"encoded {len(encoded_imgs)} image(s)")
    try:
        tmp_img.unlink()
    except Exception:
        pass

    # 8. Autonomous Agent Engine State Initializer
    agent = AutonomousAgentEngine(dispatcher, scrubber, ragnarok_dir)
    check("agent-engine-init", agent is not None, "autonomous agent ready")

    print(f"\n{Colors.cyan_bold('Selfcheck Complete:')} {passed}/{total} tests passed.\n")
    if passed != total:
        sys.exit(1)

# ---------------------------------------------------------------------------
# CLI Argument Parsing & Entry Point
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(
        description="Heimdall Cross-Platform Terminal Pipeline & Error Debugger",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument(
        "action",
        nargs="?",
        default="tui",
        choices=["tui", "last", "watch", "run", "pipe", "triage", "agent", "repair", "scrub", "models", "selfcheck"],
        help="Action to perform (default: tui)",
    )
    parser.add_argument("extra", nargs="*", help="Arguments for action (e.g. command for 'run', file for 'triage', task for 'agent')")
    parser.add_argument("--provider", default="", help="Override AI provider (ollama, claude, codex, grok, gemini, openai)")
    parser.add_argument("--model", default="", help="Override model name")
    parser.add_argument("--image", action="append", default=[], help="Attach image/screenshot path for multimodal diagnosis (can be repeated)")
    parser.add_argument("--rounds", type=int, default=3, help="Max rounds for autonomous agent (default: 3)")
    parser.add_argument("--log-file", default="", help="Override log file to inspect or watch")
    parser.add_argument("--interval", type=float, default=2.0, help="Watch interval in seconds (default: 2.0)")
    parser.add_argument("--no-color", action="store_true", help="Disable ANSI color codes")

    parser.add_argument("--cwd", default="", help="Project working folder")
    parser.add_argument("--failure-command", default="", help="Diagnose this selected command without running it")
    parser.add_argument("--failure-exit", type=int, default=1)
    parser.add_argument("--json", action="store_true", help="Emit a structured result envelope")
    parser.add_argument("--ollama-url", default="", help="Explicit Ollama endpoint (no credentials in URL)")
    parser.add_argument("--acceptance", default="", help="Outside acceptance JSON for isolated repair")
    parser.add_argument("--evidence", default="", help="New evidence directory outside source")
    parser.add_argument("--cloud-provider", default="", help="Optional direct API continuation provider")
    parser.add_argument("--cloud-model", default="")
    args = parser.parse_args()
    if args.cwd:
        os.chdir(Path(args.cwd).expanduser().resolve(strict=True))
    if args.log_file and args.action not in ("last", "triage"):
        parser.error("--log-file is supported only for last/triage; watch override is not implemented")
    if args.log_file:
        args.action, args.extra = "triage", [args.log_file]
    capture = io.StringIO() if args.json else None
    if capture is not None:
        Colors.set_enabled(False)
        sys.stdout = capture
    if os.name == "posix":
        signal.signal(signal.SIGTERM, stop_children)
        signal.signal(signal.SIGINT, stop_children)

    if args.no_color:
        Colors.set_enabled(False)

    ragnarok_dir = resolve_ragnarok_dir()
    scrubber = SecretScrubber(ragnarok_dir)
    if args.action == "scrub":
        print(scrubber.clean(sys.stdin.read()), end="")
        return
    dispatcher = AIModelDispatcher(ragnarok_dir, scrubber)
    if args.ollama_url:
        endpoint = urllib.parse.urlsplit(args.ollama_url)
        if endpoint.scheme not in ("http", "https") or not endpoint.hostname or endpoint.username or endpoint.password:
            parser.error("Ollama endpoint must be an http(s) URL without credentials")
        dispatcher.ollama_url = args.ollama_url.rstrip("/")
    encoded_images = load_and_encode_images(args.image) if args.image else None

    if args.action == "models":
        if args.provider not in ("", "ollama"):
            raise ValueError("Model discovery is implemented for Ollama only; other providers validate requests at their service")
        try:
            models = dispatcher.list_ollama_models(strict=True)
            result = {"provider": "ollama", "endpoint": dispatcher.ollama_url,
                      "models": models, "status": "available" if models else "empty",
                      "error": "" if models else "Ollama responded but has no installed models"}
        except Exception as error:
            result = {"provider": "ollama", "endpoint": dispatcher.ollama_url,
                      "models": [], "status": "blocked", "error": scrubber.clean(str(error))}
        print(scrubber.clean(json.dumps(result)))
        if result["status"] == "blocked":
            sys.exit(1)
    elif args.action == "tui":
        run_interactive_tui(dispatcher, scrubber, ragnarok_dir)
    elif args.action == "last":
        if args.failure_command:
            prompt = build_debugging_prompt(cmd=args.failure_command, exit_code=args.failure_exit,
                cwd=str(Path.cwd()), log_context="", error_summary="Selected recorded failure")
            dispatcher.query(prompt, DEBUG_SYSTEM_PROMPT, provider=args.provider, model=args.model, images=encoded_images)
        else:
            run_last_error(dispatcher, scrubber, ragnarok_dir, provider=args.provider, model=args.model, images=encoded_images)
    elif args.action == "watch":
        run_watch_mode(dispatcher, scrubber, ragnarok_dir, interval=args.interval, provider=args.provider, model=args.model)
    elif args.action == "run":
        if not args.extra:
            print(f"{Colors.red_bold('Error: provide a command to run (e.g. heimdall-debug run \"pytest\")')}")
            sys.exit(2)
        cmd = " ".join(args.extra)
        code = run_command_pipeline(cmd, dispatcher, scrubber, provider=args.provider, model=args.model, images=encoded_images)
        sys.exit(code)
    elif args.action == "pipe":
        run_pipe_mode(dispatcher, scrubber, provider=args.provider, model=args.model, images=encoded_images)
    elif args.action == "triage":
        if not args.extra:
            print(f"{Colors.red_bold('Error: provide a log file path for triage')}")
            sys.exit(2)
        run_triage_file(args.extra[0], dispatcher, scrubber, provider=args.provider, model=args.model, images=encoded_images)
    elif args.action == "repair":
        from pipeline_debugger_controller import RepairRun, ModelPatchProvider
        if not args.acceptance or not args.cwd:
            parser.error("repair requires --cwd and --acceptance; it never repairs the host checkout")
        if encoded_images:
            parser.error("Isolated file repair currently accepts text evidence only; attached images were not sent")
        evidence = args.evidence or str(ragnarok_dir / "debugger-runs" / uuid.uuid4().hex)
        run = RepairRun(Path.cwd(), args.acceptance, evidence, " ".join(args.extra), scrubber.clean)
        shutil.copy2(Path(__file__), run.root / "controller" / "heimdall-debugger.py")
        from pipeline_debugger_controller import manifest
        (run.root / "controller" / "manifest.json").write_text(json.dumps({k:v for k,v in manifest(run.root / "controller").items() if k != "manifest.json"}, indent=2))
        local = ModelPatchProvider(dispatcher, args.provider or "ollama", args.model)
        if local.provider != "ollama":
            parser.error("The first repair stage requires an Ollama local model")
        cloud = ModelPatchProvider(dispatcher, args.cloud_provider, args.cloud_model) if args.cloud_provider else None
        if os.name == "posix":
            def cancel_run(signum, frame):
                run.executor.cancel()
                raise InterruptedError("Cancelled by user")
            signal.signal(signal.SIGTERM, cancel_run)
            signal.signal(signal.SIGINT, cancel_run)
        result = run.run(local, cloud, args.rounds)
        sys.exit(0 if result["status"] == "passed_checks" else 1)
    elif args.action == "agent":
        parser.error("Legacy host agent execution is disabled; use repair with --cwd and --acceptance")
        task_desc = " ".join(args.extra) if args.extra else "Diagnose and fix recent terminal / pipeline failure"
        agent = AutonomousAgentEngine(dispatcher, scrubber, ragnarok_dir)
        res = agent.run(task=task_desc, cwd=str(Path.cwd()), images=encoded_images, max_rounds=args.rounds, provider=args.provider, model=args.model)
        sys.exit(0 if res.get("verdict") == "passed_checks" else 1)
    elif args.action == "selfcheck":
        run_selfcheck(dispatcher, scrubber, ragnarok_dir)

if __name__ == "__main__":
    original_stdout = sys.stdout
    code = 0
    try:
        main()
    except SystemExit as error:
        code = error.code if isinstance(error.code, int) else 1
    except Exception as error:
        code = 1
        # Exception messages may contain request URLs or provider output.
        display(SecretScrubber(resolve_ragnarok_dir()).clean(str(error)))
    finally:
        stop_children()
        if sys.stdout is not original_stdout:
            content = sys.stdout.getvalue()
            sys.stdout = original_stdout
            print(json.dumps({"version": 1, "status": "succeeded" if code == 0 else "failed", "exit": code, "output": content}))
    sys.exit(code)
