# Mac receipts

One receipt for every command and every file write an AI makes on the owner's MacBook, in the same shape
as Alexus's login-shell logger (`grok-receipt-shell` -> `grok-receipt-log`), written to a hash-chained,
append-only table in the scratch Postgres.

**Where:** `ygg-scratch-pg` (127.0.0.1:5547), database `ygg_receipts`, table `mac.receipts`. Its own
schema, so the restored `public."Write Log"` / `Archive` and every business table are untouched.

| field | rule |
|---|---|
| kind / action / status | read-only allowlist -> `Read` / `Read` / `Observed` (also on a nonzero exit). Anything else -> `Change` / `Created`,`Deleted`,`Updated`; `Failed` only for a nonzero exit on a change |
| exit_code | the command's exit code (null when the source does not say) |
| record_ref | `macbook:<clean path>` of the target, else `macbook:<cwd>` |
| actor / session | `Grok Bot` (conversation id), `Claude Code` / `Grok CLI` (session id), `human-terminal` (Terminal session), `Codex`/`Gemini CLI`/... when their env marker is seen |
| command | redacted (core `src/core/redact.ts` + shell rules: `NAME=value` for secret-looking names, `--password x`, bearer/basic headers, `user:pass@` URLs, known token shapes, and every value in the scratch `.env`). File writes log only `<tool> <path> (contents not logged)` |
| chain | `entry_hash = sha256(prev_hash || "\n" || payload::text)`, genesis = 64 zeros, `mac.append()` serialises with an advisory lock; UPDATE/DELETE/TRUNCATE refused by triggers; `mac.verify()` recomputes |

## Sources

- `receipts.zsh` (sourced from `~/.zshenv`): Grok Bot's non-interactive runner shells (EXIT trap, one
  receipt per command), other AI CLIs' `zsh -c` with a known env marker, and interactive Terminal
  (preexec/precmd, Actor `human-terminal`; `export RAGNAROK_RECEIPTS_TERMINAL=0` in `~/.zshenv` before
  the source line to stop). Claude Code's own shells (`CLAUDECODE=1`) are skipped: its hook covers them.
- `receipt.mjs claude-hook`: `~/.claude/settings.json` PostToolUse + PostToolUseFailure on
  `Bash|Write|Edit|MultiEdit|NotebookEdit`. Grok CLI reads the same file, so its shell / edit tools are
  receipted too (Actor `Grok CLI`).
- **Gemini CLI** (added 2026-11-02): `~/.gemini/settings.json` `hooks.AfterTool` on
  `run_shell_command|write_file|replace` runs `receipt.mjs claude-hook` (Actor `Gemini CLI`, from the event name
  `AfterTool`). Its shells also carry `GEMINI_CLI`, so a shell command can get a second, `zsh-exit` receipt.
- **Antigravity** (`agy`, added 2026-11-02): `~/.gemini/config/hooks.json` (the file the CLI and app share), named
  hook `ragnarok-receipts`, `PostToolUse` matcher `*` (Actor `Antigravity`, from its camelCase `toolCall` payload;
  `run_command`, `write_to_file`, `replace_file_content`, `multi_replace_file_content`, `create_file`, `delete_file`).
  The command ends with `echo '{}'` because Antigravity expects a JSON object back.
- **Codex** (added 2026-11-02): `~/.codex/hooks.json` `PostToolUse` on `Bash|apply_patch` (Codex `apply_patch`
  covers its Edit/Write aliases); patch receipts contain paths and operation counts, never patch contents. Its
  `UserPromptSubmit` also runs the compatible evidence rules, memory arm, and premise check hooks shared with the
  Claude/Grok setup. The Claude transcript-based drift and answer auditors are not copied because their transcript
  reader expects Claude's JSONL format.
- **LocalAI** (Ragnarok's LocalAI tab and the standalone app, added 2026-11-02): `write_file` sends
  `receipt.mjs log --actor LocalAI`; `run_command` runs `zsh -lc` with `AI_AGENT=LocalAI`, which the zsh side logs.
- **Heimdall API editor** (`bin/heimdall-api-edit.py`, added 2026-11-02): one `receipt.mjs log` per file written,
  Actor `Heimdall API (<provider>)` (anthropic, openai, xai, gemini).
- `--actor NAME` on `claude-hook` overrides the worked-out actor. Tests: `node --test hooks/mac-receipts/hook-event.test.mjs`.

## Fail-open path

Hook -> redact -> append one line to `~/.ragnarok/receipts-spool.jsonl` (0600) -> background drain of the
spool, oldest first, into `mac.append()`. DB down: the line stays, and the next successful write sends
it (a batch being sent sits in `receipts-spool.jsonl.inflight`). Hooks never print and always exit 0;
the zsh side starts node detached with fds 0-9 closed or redirected, so nothing waits on it.
Diagnostics: `~/.ragnarok/receipts.log` (one line per receipt with its seq, no command text).

## Use

```sh
cd ~/Developer/ygg-mcp-business
scripts/log-change tail 30          # newest receipts, times in PT
scripts/log-change verify           # {"ok":true,...,"reason":"chain intact"}
scripts/log-change --actor the owner --cmd "rotated a token" --action Updated --ref /path   # manual receipt
node hooks/mac-receipts/receipt.mjs migrate    # (re)apply sql/001_mac_receipts.sql, idempotent
node --test hooks/mac-receipts/classify.test.mjs
```

SQL: `docker exec -it ygg-scratch-pg psql -U ygg_app -d ygg_receipts -c "select seq, at, actor, kind, action, status, exit_code, record_ref, command from mac.receipts order by seq desc limit 20"`

## Off

- Pause everything: `touch ~/.ragnarok/receipts.off` (remove the file to resume).
- Remove: delete the `mac receipts` block from `~/.zshenv` (or restore `~/.zshenv.bak-20261028`) and the
  two `receipt.mjs claude-hook` entries from `~/.claude/settings.json` (or restore
  `~/.claude/settings.json.bak-20261028-receipts`).

## Not covered

GUI apps (Meta app, Cursor/VS Code editors' own file saves, Finder; Antigravity's app is covered only if it loads
`~/.gemini/config/hooks.json`, which the CLI's notes say it shares but which wasn't tested), GUI app file writes that
do not pass through a configured hook, chat-only use of any provider (no tool ran, nothing to receipt), any AI that writes files
through its own process instead of a shell or a Claude-style hook (including Grok Bot's file-copy tools),
`bash`/`sh` shells (only zsh is hooked), non-interactive `zsh -c` from an AI with no env marker, commands
an AI types into Terminal.app (logged, but as `human-terminal`), and shells that kill zsh without a normal exit.
`ygg_app` owns the table and could drop the triggers; the chain would still show a rewrite.

## Confirmed, Alexus tag, and the old change hook (2026-11-02)

- **Confirmed:** after a Claude Code Write/Edit/MultiEdit, the file is read back from disk (sha256 for a write, the
  new text for an edit). A match makes the receipt `Confirmed` with a `verified` field; otherwise it stays
  `Observed` (Ruleset R-75). `sql/002_confirmed_status.sql` allows the new status; `receipt.mjs migrate` runs every file in `sql/`.
- **Alexus tag:** a change made with `ssh`/`scp`/`rsync` to Alexus (any of its addresses) gets `remote_host: alexus`
  and a record_ref starting `alexus:`.
- **Old change hook retired:** `scripts/ragnarok-change-hook.py` sent to a receiver on Alexus that no longer existed.
  It's off in ~/.claude/settings.json, and its queue (739 unique entries, 2026-10-30 → 11-02) was imported with
  `receipt.mjs import-change-queue` (source `change-hook-queue`, original times kept). The file is
  ~/.ragnarok/change-queue.imported-20261102.jsonl.
