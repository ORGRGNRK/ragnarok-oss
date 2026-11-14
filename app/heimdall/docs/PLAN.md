# Heimdall — god's-eye view of every AI (plan, 2026-10-31)

Goal (owner, 2026-10-31): a macOS app that shows everything every AI is doing, live, plus the owner's
own commands; opens only with YubiKey or Secure Enclave (Touch ID), uTrust key as fallback;
self-healing and usable while it repairs itself; everything attributed by OS user (AI or the owner);
a built-in shell with its own log that also shows the owner's commands; Alexus chat (from
alexus-core); editable live by the owner's commands or by any AI provider (subscription CLI or API).

## Pieces and where they come from

| Piece | Built from |
|---|---|
| Unlock gate | `alexus-core/bin/fido-auth.sh` (YubiKey primary, uTrust spare, keys in `~/.alexus/keys`) + LocalAuthentication (Secure Enclave / Touch ID), same idea as `alexus-core/src/auth_gate.swift` |
| Live feeds (Mac) | Claude Code `~/.claude/projects/*/*.jsonl`; Antigravity/Argon `~/.gemini/antigravity/brain/*/.system_generated/logs/transcript.jsonl`; Grok `~/.grok/sessions/*/*/chat_history.jsonl`; Mac AI receipts `~/.ragnarok/receipts-spool.jsonl`; the owner's Terminal commands come in through the mac receipts (actor human-terminal, existing hook in ~/.zshenv) |
| Live feeds (Alexus, via `ssh <ALEXUS_USER>@`, read only) | `/var/log/ragnarok/ai_ssh_receipts.jsonl` (every AI SSH command); `/var/log/audit/audit.log` lines with `key="ai_*"` (auid 1001 claude, 1002 argon, 1003 grok, 1004 codex, 1005 ai-admin) |
| Alexus chat | port of `alexus-core` `cmd_chat` (Ollama `/api/chat` at <ALEXUS_HOST>:11434, persona + silent boot from `ragnarok_bridge`) |
| App patterns | `~/conveyor-app` (SwiftUI package, `make-app.sh`, ad-hoc signing) |

## Milestones

1. **(done 2026-10-31) Locked live viewer** — unlock gate; one live timeline of all feeds above; filter by actor and
   host; click any event to read all of it. The owner's zsh commands logged.
2. **(done 2026-10-31) Self-healing supervisor + live editing** — tiny stable launcher keeps the last good build
   running; an edit (the owner or any AI) builds into staging, runs checks, swaps only if they pass;
   crash on start = automatic rollback. "Edit the app" box: instruction → chosen provider
   (claude / codex / grok / gemini CLI, or an API key) working in this repo; output streams into
   the timeline. Every swap and rollback logged.
3. **(done 2026-10-31) Alexus chat pane** (bin/alexus-chat-bridge.py + Chat.swift; seal SQL goes on stdin, not through a shell) — streaming chat, persona, boot context, Switch Packet on close.
4. **(done 2026-10-31, simple line terminal; full terminal needs the SwiftTerm package, which the safety check blocked) Built-in shell** — PTY terminal in the app; its own log (`~/.ragnarok/heimdall-shell.jsonl`)
   shown in the timeline next to the owner's other commands.

## Known limits (honest)
- Codex CLI is not installed on this Mac, so `codex` edits fail until it is. API edits need a key in the keychain
  (`security add-generic-password -s heimdall-api-<provider> -a "$USER" -w`); none set up or tested yet.
- Restart after an update needs a fresh unlock (Touch ID / key) — by design.
- Feeds read files that already exist; an AI that writes nothing (Codex has no `~/.codex` yet)
  shows nothing until it does.
- Reading Alexus uses the owner's account (ALEXUS_USER) (it can read audit.log and the AI receipts).
- Grok reasoning is stored encrypted by Grok; only its summary text is readable.
