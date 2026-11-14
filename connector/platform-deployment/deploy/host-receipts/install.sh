#!/bin/sh
# OPTIONAL host step: receipts for every AI command / file write on THIS machine (zsh + Claude Code
# and Codex hooks), written to the packaged DB (ygg_receipts.mac.receipts on 127.0.0.1:$YGG_PG_PORT).
# Backs up modified config files first and preserves unrelated settings.
# Needs: zsh, Node >= 22 on the host, and this repo built on the host (npm ci && npm run build)
# so receipt.mjs can load dist/core/redact.js and the pg driver.
#   deploy/host-receipts/install.sh [--dry-run]
set -eu
cd "$(dirname "$0")/../.."
ROOT=$(pwd -P)
DRY=0; [ "${1:-}" = --dry-run ] && DRY=1
NODE=${RAGNAROK_RCPT_NODE:-$(command -v node || true)}
[ -n "$NODE" ] && [ -x "$NODE" ] || { echo "host-receipts: node not found (set RAGNAROK_RCPT_NODE=/path/to/node)"; exit 2; }
"$NODE" -e 'process.exit(+process.versions.node.split(".")[0] >= 22 ? 0 : 1)' || { echo "host-receipts: need Node >= 22"; exit 2; }
[ -r "${YGG_SCRATCH_ENV:-$ROOT/.env}" ] || { echo "host-receipts: receipt env file missing; set YGG_SCRATCH_ENV or run ./install.sh first"; exit 2; }
[ -d "$ROOT/node_modules/pg" ] && [ -r "$ROOT/dist/core/redact.js" ] || { echo "host-receipts: run 'npm ci && npm run build' in $ROOT first"; exit 2; }
JS="$ROOT/hooks/mac-receipts/receipt.mjs"
ENV_FILE=${YGG_SCRATCH_ENV:-$ROOT/.env}
TS=$(date +%Y%m%d-%H%M%S)
ZSHENV="$HOME/.zshenv"; SETTINGS="$HOME/.claude/settings.json"; CODEX="$HOME/.codex/hooks.json"

# 1. backups
for f in "$ZSHENV" "$SETTINGS" "$CODEX"; do
  if [ -e "$f" ]; then
    if [ $DRY = 1 ]; then echo "would back up $f -> $f.bak-$TS"; else cp -p "$f" "$f.bak-$TS"; echo "backed up $f -> $f.bak-$TS"; fi
  fi
done

# 2. zsh hook (~/.zshenv)
if [ -e "$ZSHENV" ] && grep -q 'mac-receipts/receipts.zsh' "$ZSHENV"; then
  echo "zshenv: a receipts.zsh source line already exists; left unchanged"
else
  BLOCK=$(cat <<ZSH
# >>> ygg mac receipts (deploy/host-receipts/install.sh) >>>
export YGG_SCRATCH_ENV="$ENV_FILE" RAGNAROK_RCPT_NODE="$NODE" RAGNAROK_RCPT_JS="$JS"
[[ -r "$ROOT/hooks/mac-receipts/receipts.zsh" ]] && source "$ROOT/hooks/mac-receipts/receipts.zsh"
# <<< ygg mac receipts <<<
ZSH
)
  if [ $DRY = 1 ]; then echo "would append to $ZSHENV:"; echo "$BLOCK"; else printf '\n%s\n' "$BLOCK" >> "$ZSHENV"; echo "zshenv: hook block appended"; fi
fi

# 3. Claude Code hooks (~/.claude/settings.json): PostToolUse + PostToolUseFailure
CMD="YGG_SCRATCH_ENV='$ENV_FILE' '$NODE' '$JS' claude-hook"
DRY=$DRY SETTINGS="$SETTINGS" CMD="$CMD" "$NODE" -e '
const fs = require("fs"), path = require("path");
const f = process.env.SETTINGS, cmd = process.env.CMD, dry = process.env.DRY === "1";
let s = {}; try { s = JSON.parse(fs.readFileSync(f, "utf8")); } catch (e) { if (e.code !== "ENOENT") { console.log("settings.json unreadable; left unchanged"); process.exit(1); } }
const has = /receipt\.mjs\x27? claude-hook/.test(JSON.stringify(s.hooks || {}));
if (has) { console.log("claude settings: a receipt.mjs claude-hook entry already exists; left unchanged"); process.exit(0); }
s.hooks = s.hooks || {};
for (const ev of ["PostToolUse", "PostToolUseFailure"]) {
  (s.hooks[ev] = s.hooks[ev] || []).push({ matcher: "Bash|Write|Edit|MultiEdit|NotebookEdit", hooks: [{ type: "command", command: cmd }] });
}
if (dry) { console.log("would add PostToolUse + PostToolUseFailure hooks to " + f); process.exit(0); }
fs.mkdirSync(path.dirname(f), { recursive: true });
fs.writeFileSync(f, JSON.stringify(s, null, 2) + "\n");
console.log("claude settings: hooks added");'

# 4. Codex user hooks (~/.codex/hooks.json): PostToolUse for shell and patch actions.
CODEX="$CODEX" CMD="$CMD" DRY="$DRY" "$NODE" -e '
const fs = require("fs"), path = require("path");
const f = process.env.CODEX, cmd = process.env.CMD, dry = process.env.DRY === "1";
let s = {}; try { s = JSON.parse(fs.readFileSync(f, "utf8")); } catch (e) { if (e.code !== "ENOENT") { console.log("Codex hooks.json unreadable; left unchanged"); process.exit(1); } }
s.hooks = s.hooks || {};
const event = s.hooks.PostToolUse = s.hooks.PostToolUse || [];
const ours = event.find(g => g.matcher === "^(Bash|apply_patch)$" && (g.hooks || []).some(h => String(h.command || "").includes("receipt.mjs") && String(h.command || "").includes("claude-hook")));
if (!ours) event.push({ matcher: "^(Bash|apply_patch)$", hooks: [{ type: "command", command: cmd, timeout: 30, statusMessage: "Platform receipt ledger" }] });
if (dry) { console.log("would update Codex PostToolUse hooks in " + f); process.exit(0); }
fs.mkdirSync(path.dirname(f), { recursive: true }); fs.writeFileSync(f, JSON.stringify(s, null, 2) + "\n", { mode: 0o600 }); fs.chmodSync(f, 0o600);
console.log("Codex hooks: " + (ours ? "receipt entry already present" : "PostToolUse hook added"));'

# 5. migrate (idempotent) + verify
if [ $DRY = 0 ]; then
  YGG_SCRATCH_ENV="$ENV_FILE" "$NODE" "$JS" migrate >/dev/null 2>&1 || true
  YGG_SCRATCH_ENV="$ENV_FILE" "$NODE" "$JS" verify || true
fi
echo "host-receipts: done. Off switch: touch ~/.ragnarok/receipts.off. Remove: deploy/host-receipts/uninstall.sh"
