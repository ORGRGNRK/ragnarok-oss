#!/usr/bin/env bash
# ./export.sh DEST   build the stand-alone client kit product folder from this kit.
#
# The source stays HERE (ragnarok/clients/kit). DEST is generated: every run replaces DEST/kit, so make
# changes in ragnarok and export again. Client folders made in DEST (DEST/<client>/) are never touched.
#
# DEST/
#   README.md   what it is, one-command install, what's included
#   kit/        the kit: Postgres + MCP + NocoDB stack, receipts + hash chains, anchors, hardening, installer
#   <client>/   made by kit/new-client.sh (secrets in its own .env, never in the kit)
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
DEST="${1:?usage: ./export.sh DEST}"
DEST="$(mkdir -p "$DEST" && cd "$DEST" && pwd)"
case "$DEST" in "$HERE"|"$HERE"/*) echo "DEST can't be inside the kit" >&2; exit 1 ;; esac

stage="$(mktemp -d)"; trap 'rm -rf "$stage"' EXIT
# only files git tracks (no .env, .secrets, backups, node_modules, dist, test leftovers)
git -C "$HERE" ls-files -z . | (cd "$HERE" && xargs -0 tar -cf - --exclude=export.sh) | tar -xf - -C "$stage"
mkdir -p "$stage/scripts/launchd"

# refuse to ship anything personal or secret-looking. The personal values come from ~/.ragnarok/local.conf
# (not in git), so this file never names them itself.
conf="$HOME/.ragnarok/local.conf"; me=$(id -un)
pat="/Users/$me|/home/$me"
if [ -r "$conf" ]; then
  for k in ALEXUS_HOST ALEXUS_TAILSCALE ALEXUS_USER TAILNET OWNER_EMAILS WOL_LAN_IP WOL_TAILNET_IP; do
    v=$(sed -n "s/^$k=//p" "$conf" | tail -1)
    for one in $(printf '%s' "$v" | tr ',' ' '); do
      [ ${#one} -ge 4 ] && pat="$pat|$(printf '%s' "$one" | sed 's/[.[\*^$()+?{}|]/\\&/g')"
    done
  done
fi
if grep -rIlE "$pat" "$stage" >/dev/null 2>&1; then
  echo "STOPPED: personal values found:" >&2
  grep -rInE "$pat" "$stage" | head >&2; exit 1
fi
if command -v gitleaks >/dev/null 2>&1; then
  gitleaks dir "$stage" --no-banner --exit-code 1 >/dev/null 2>&1 || { echo "STOPPED: gitleaks found something" >&2; gitleaks dir "$stage" --no-banner 2>&1 | tail -20 >&2; exit 1; }
fi

rm -rf "$DEST/kit"; mv "$stage" "$DEST/kit"; chmod 755 "$DEST/kit"
rev="$(git -C "$HERE" rev-parse --short HEAD)"; dirty=""; git -C "$HERE" diff --quiet -- . || dirty=" (+ uncommitted changes)"
cat > "$DEST/README.md" <<EOF
# RAGNAROK client kit

GENERATED from ragnarok/clients/kit @ $rev$dirty on $(date +%Y-%m-%d). Don't edit kit/ here: change it in
ragnarok and run clients/kit/export.sh again (it replaces kit/ and leaves client folders alone).

A self-hosted "database the AI can safely use" for one business: Postgres for the data, an MCP server for
the AI (Claude, Cursor, ...), NocoDB as a spreadsheet screen for people.

## Install a client (one command)

    cd kit
    ./new-client.sh "Acme Plumbing" --port-offset 10

Makes ../acme-plumbing with fresh random secrets, starts the whole stack, tables created empty.
Needs Docker (Docker Desktop / OrbStack on a Mac, Docker Engine on Linux). Then see kit/README.md
("Connect Claude"). \`./kit test\` in the client folder proves everything on a throwaway copy.

## Included

- **Receipts + hashing:** every change (write_log), every AI tool call (access_log) and every AI action on the machine
  (agent_log) gets a receipt in a
  SHA-256 hash chain inside Postgres; the database refuses UPDATE/DELETE/TRUNCATE on receipts, even for the
  admin. \`./kit verify\` recomputes every chain.
- **Off-server anchors:** \`./kit anchor\` + kit/scripts/mac-anchor.sh keep the newest hashes on another
  machine every hour, so even a rewrite by the server's admin is caught.
- **Guard rails for the AI:** no delete; archiving needs a code a person approves at a real terminal;
  read-only token and login; optional list of actors allowed to write.
- **Hardening (OWASP Docker + MCP cheat sheets, CIS Docker Benchmark):** secrets as files (nothing in
  docker inspect), read-only containers with all capabilities dropped, no-new-privileges, memory/process
  limits, digest-pinned images, split networks, failed-token blocking, encrypted backups with age,
  everything on 127.0.0.1 (reach it through Tailscale or Cloudflare Access).
- **AI machine receipts:** \`./kit receipts-setup --claude\` receipts every shell command, file edit and
  tool call an AI agent makes on a machine into \`agent_log\` (same hash chain and locks; secrets redacted
  on the machine first, file contents never sent, nothing lost when the server is down).
- **\`./kit money\`:** "where did the money go" report from bank / sales / supplier CSVs.

## Not included

- Receipts for an AI that runs with its hooks turned off (receipts show the gap, they don't prevent it).
- OAuth sign-in for the MCP server (it uses two long-lived bearer tokens).
EOF
echo "exported kit @ $rev$dirty -> $DEST"
