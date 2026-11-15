# Answer engine

A local page for one question at a time. You type a problem. A provider answers it with web search and web fetch. Under the answer, a closed toggle labelled "How it got this answer" shows the path that provider actually emitted: thinking (when it sent any), each tool call and its input, each tool result, which provider ran, the model name when the stream sent one, and how many milliseconds each step took.

The milliseconds are measured here. They are not a duration reported by the provider.

Every finished answer is stored on this machine and can be searched. Opening an old question shows the stored answer and the full path again.

The adapters have not yet been run against a real provider. Tests use fake CLIs that print the stream shapes described by each CLI's help.

## Run

Python 3 and the standard library only. There is no install step and no build.

```
bin/answer-engine serve
bin/answer-engine serve --port 8734
bin/answer-engine selfcheck
```

`serve` listens on 127.0.0.1 only. The default port is 8734. A browser on this machine can open `http://127.0.0.1:8734/`.

`selfcheck` runs the fake-CLI checks. It does not call a real provider and it does not use the network. If `HOME` or `ANSWER_ENGINE_HOME` is unset, it uses a new temporary directory for that one.

## Data

The database is `answers.db` under `ANSWER_ENGINE_HOME`. When that variable is unset, the directory is `.answer-engine` in the home directory.

Optional `settings.json` in that same directory:

```json
{
  "provider_order": ["claude", "grok", "codex"],
  "claude_bin": "claude",
  "codex_bin": "codex",
  "grok_bin": "grok"
}
```

Environment variables override the file:

- `ANSWER_ENGINE_HOME`
- `ANSWER_ENGINE_PROVIDER_ORDER` (comma-separated)
- `ANSWER_ENGINE_CLAUDE_BIN`
- `ANSWER_ENGINE_CODEX_BIN`
- `ANSWER_ENGINE_GROK_BIN`
- `ANSWER_ENGINE_TIMEOUT_SECONDS` (default 300; a non-positive or invalid value also means 300)

The default order is Claude, then Grok, then Codex. If the current provider fails or is out of usage, the next one is tried. The path shows a line that starts "Switching from … to … because … failed:". A timeout does not move on to the next provider.

Search uses SQLite FTS5 over the question and the answer.

## What each provider exposes

Only text the process emitted is stored. Nothing here writes, reconstructs, or paraphrases thinking. A thinking block the provider marks as redacted is skipped, not filled in. If the stream has no thinking text, the toggle says "This AI did not share its thinking". A reasoning summary is stored as a summary and labelled "Reasoning summary" on the page. A summary alone does not count as the provider sharing its thinking, so that same sentence is shown as well.

Claude (`claude --help`): `--output-format stream-json` with `--verbose` and `--include-partial-messages`. The stream can include thinking, tool calls, tool results, and a final result. A run that sends only the final result has no thinking in the path.

Codex (`codex exec --help`): `--json` JSONL. A reasoning item is the summary Codex emits, so it is labelled as a summary. Command, web search, and other completed items are shown as tool calls with their results. The agent message is the answer. `turn.failed` and a top-level `error` are failures.

Grok is included because `grok --help` lists machine-readable formats: `json`, `streaming-json`, and `streaming-messages-json`. This adapter asks for `streaming-messages-json`, which is the Messages stream shape (assistant blocks, tool results, and a final result), and parses that. The separate native `streaming-json` event names are not parsed.

## What is enforced

The provider process is started in a new empty temporary directory, with a minimal environment, and with a 300 second limit. The environment passed in is only `HOME` (when this process has one), `USER`, `LOGNAME`, `TMPDIR` (or `/tmp`), a fixed `PATH`, `LANG`, `LC_ALL`, and `TERM`. The parent environment is not copied. Variables that exist only in the parent, including API keys, are not passed. `HOME` is passed so a real CLI can find its own login files. A program the operating system runs directly sees that set. An interpreter started from a script can add its own variables after launch; those are not taken from the parent.

After 300 seconds the process group is killed. The stored answer and the page say "This run timed out."

One question runs at a time. A second request gets HTTP 409 and the page says "Busy. One question is already running."

The question is limited to 4000 characters. Tool inputs, tool results, and error text are limited to 20000 characters each, and the stored text ends with a cut marker when that happens. Text that looks like a provider key or a private key block is replaced with `[redacted]` before it is stored or shown.

The page is one HTML document served by this program. It does not load scripts, styles, or fonts from another host. Text from the model or a tool is inserted with `textContent`, not as HTML. A request whose Host header is not `localhost` or `127.0.0.1` is refused.

These limits were checked with fake CLIs. They were not checked by watching a real provider process.

### Claude

The command is built from flags on `claude --help`:

- `--tools WebSearch,WebFetch` and `--allowedTools WebSearch,WebFetch` replace and pre-allow that pair.
- `--permission-mode dontAsk` and `--permission-prompts none`.
- `--safe-mode`, which the help describes as disabling hooks, MCP, project instruction files, skills, plugins, and custom commands. Admin-managed policy still applies. Login still works. `--bare` is not used, because the help says that mode would ignore the saved login.
- `--restricted`, which the help describes as removing shell and code tools, ignoring user, project, and local settings, and confining any remaining file tools to the working directory.
- `--strict-mcp-config` with an MCP config whose server list is empty.
- `--disable-slash-commands` and `--no-session-persistence`.

`--dangerously-skip-permissions` is not passed. This does not disable an admin policy this program cannot see. It was not verified by running the real `claude` binary.

### Codex

`codex exec` has no flag that limits the model to web search and web fetch. `--search` is on `codex --help` and is not on `codex exec --help`, so it is not passed.

The strictest sandbox value on `codex exec --help` is `--sandbox read-only`. The help says that sandbox applies when the model runs shell commands. The command also passes `--disable` for `shell_tool`, `unified_exec`, `unified_exec_tty`, `hooks`, `plugins`, `computer_use`, `browser_use`, `browser_use_external`, `browser_use_full_cdp_access`, `image_generation`, and `multi_agent`. Those names are the ones printed by `codex features list`.

`--ignore-user-config`, `--ignore-rules`, `--ephemeral`, and `--skip-git-repo-check` are set. The empty temporary directory is the process working directory and the `-C` value. That avoids project instructions in the directory it was started from. No flag found here turns off user instruction files that live outside the user config file. MCP servers configured in that file should not load because the user config is ignored. That was not verified by running the real `codex` binary.

This is not a claim that shell is impossible, or that reads outside the temporary directory are blocked.

### Grok

The command uses flags from `grok --help`:

- `--tools web_search,web_fetch`
- `--disallowed-tools` for the other built-in tools named there: `read_file`, `search_replace`, `grep`, `list_dir`, `run_terminal_command`, `todo_write`, `spawn_subagent`
- `--no-subagents`
- `--sandbox strict`
- `--permission-mode dontAsk`
- `--cwd` set to the empty temporary directory
- `--verbatim` and `-p` for the question

`--always-approve` is not passed.

The command passes `--sandbox strict`. The installed user guide (`~/.grok/docs/user-guide/18-sandbox.md`) calls `strict` the most restrictive built-in profile. `read-only` still reads everywhere. `strict` reads the working directory, essential system paths, and the Grok home directory. Writes go to the working directory, `~/.grok/sessions`, `/tmp`, and `/var/tmp`. When the daemon backend runs the session, writes also include `~/.grok/daemon/run/strict`. Child-process network blocking is enforced on Linux only. On macOS it is a no-op, so this profile does not restrict child-process network there. Web tools that run inside the Grok process are outside that child-network rule. If a built-in profile cannot be applied, Grok warns and continues without enforcement. No flag found here disables MCP, hooks, or a global instructions file. The empty working directory has no project instruction file. A global instructions file in the Grok home is not turned off by any flag this program found. This was not verified by running the real `grok` binary.

## Local only

This is a program for one computer. It is not ready to put on the internet. It has no accounts, no deployment, and no shared server. Do not expose the port.
