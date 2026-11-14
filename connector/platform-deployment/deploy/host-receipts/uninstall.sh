#!/bin/sh
# Remove what deploy/host-receipts/install.sh added (only its marked ~/.zshenv block and hook
# entries that point at THIS repo). Backs both files up first. Receipts already written stay in the DB.
set -eu
cd "$(dirname "$0")/../.."
ROOT=$(pwd -P); TS=$(date +%Y%m%d-%H%M%S)
ZSHENV="$HOME/.zshenv"; SETTINGS="$HOME/.claude/settings.json"; CODEX="$HOME/.codex/hooks.json"
for f in "$ZSHENV" "$SETTINGS" "$CODEX"; do [ -e "$f" ] && cp -p "$f" "$f.bak-$TS" && echo "backed up $f -> $f.bak-$TS"; done
if [ -e "$ZSHENV" ] && grep -q '>>> ygg mac receipts (deploy/host-receipts/install.sh)' "$ZSHENV"; then
  awk '/^# >>> ygg mac receipts \(deploy\/host-receipts\/install.sh\) >>>/{skip=1} !skip{print} /^# <<< ygg mac receipts <<</{skip=0}' "$ZSHENV" > "$ZSHENV.tmp.$$" && mv "$ZSHENV.tmp.$$" "$ZSHENV"
  echo "zshenv: block removed"
else echo "zshenv: no installer block found"; fi
[ -e "$SETTINGS" ] && ROOT="$ROOT" SETTINGS="$SETTINGS" node -e '
const fs = require("fs"); const f = process.env.SETTINGS, root = process.env.ROOT;
const s = JSON.parse(fs.readFileSync(f, "utf8")); let n = 0;
for (const ev of ["PostToolUse", "PostToolUseFailure"]) {
  if (!s.hooks?.[ev]) continue;
  const keep = s.hooks[ev].filter((h) => !(h.hooks || []).some((x) => (x.command || "").includes(root + "/hooks/mac-receipts/receipt.mjs") && ++n));
  if (keep.length) s.hooks[ev] = keep; else delete s.hooks[ev];
}
fs.writeFileSync(f, JSON.stringify(s, null, 2) + "\n"); console.log("claude settings: removed " + n + " hook entries");' || true
if [ -e "$CODEX" ]; then ROOT="$ROOT" CODEX="$CODEX" node -e '
const fs = require("fs"), f = process.env.CODEX, root = process.env.ROOT;
const s = JSON.parse(fs.readFileSync(f, "utf8")); let n = 0;
for (const ev of ["PostToolUse", "UserPromptSubmit"]) {
  if (!s.hooks?.[ev]) continue;
  const keep = [];
  for (const group of s.hooks[ev]) {
    group.hooks = (group.hooks || []).filter(h => {
      const ours = ev === "PostToolUse"
        ? h.statusMessage === "Platform receipt ledger" && String(h.command || "").includes(root + "/hooks/mac-receipts/receipt.mjs")
        : ["Ragnarok evidence rules", "Ragnarok prompt memory", "Ragnarok premise check"].includes(h.statusMessage);
      if (ours) n++;
      return !ours;
    });
    if (group.hooks.length) keep.push(group);
  }
  if (keep.length) s.hooks[ev] = keep; else delete s.hooks[ev];
}
fs.writeFileSync(f, JSON.stringify(s, null, 2) + "\n", { mode: 0o600 }); fs.chmodSync(f, 0o600);
console.log("Codex hooks: removed " + n + " Ragnarok hook entries");' || true; fi
echo "host-receipts: uninstalled"
