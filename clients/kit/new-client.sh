#!/usr/bin/env bash
# ./new-client.sh <client-name> [--dest DIR] [--port-offset N] [--no-up]
# One shot: makes a new client folder next to this kit (ragnarok/clients/<name>/) AND starts its stack:
#   - client/ (schema + an EMPTY seed), a ./kit wrapper, .gitignore; the code stays in this one kit
#   - writes a new .env with brand-new random passwords and tokens (nothing shared between clients)
#   - tables come from the example schema (examples/inventory) so you can edit it; no rows are loaded
#   - gives the client its own docker project name and ports, so clients never collide
#   - runs ./kit up (Postgres + MCP + NocoDB, hardened); --no-up only makes the folder
# Example:  ./new-client.sh acme-plumbing --port-offset 10
#   -> ../acme-plumbing (clients/acme-plumbing) with Postgres 5452, NocoDB 8100, MCP 8800
set -euo pipefail
. "$(cd "$(dirname "$0")" && pwd)/scripts/lib.sh"

name=""; dest=""; offset=0; git=1; up=1
while [ $# -gt 0 ]; do
  case "$1" in
    --dest) dest="${2:?--dest needs a folder}"; shift 2 ;;
    --port-offset) offset="${2:?--port-offset needs a number}"; shift 2 ;;
    --no-git) git=0; shift ;;
    --no-up) up=0; shift ;;
    -h|--help) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) die "unknown option $1" ;;
    *) [ -z "$name" ] || die "only one client name, please"; name="$1"; shift ;;
  esac
done
[ -n "$name" ] || die "usage: ./new-client.sh <client-name> [--dest DIR] [--port-offset N]"
slug="$(printf '%s' "$name" | tr 'A-Z' 'a-z' | tr -c 'a-z0-9' '-' | sed -e 's/--*/-/g' -e 's/^-//' -e 's/-$//')"
[ -n "$slug" ] || die "client name needs some letters or numbers"
case "$offset" in ''|*[!0-9]*) die "--port-offset must be a whole number" ;; esac
dest="${dest:-$(dirname "$ROOT")/$slug}"
[ ! -e "$dest" ] || die "$dest already exists; pick another name or --dest"

mkdir -p "$dest/client"
# one client = one small folder of settings, not a copy of the kit's code (ragnarok/docs/FOLD-PLAN.md)
cp "$ROOT/examples/inventory/schema.json" "$dest/client/"
# no starting rows: the tables are created empty (put rows in client/seed.json and run ./kit seed if you ever want them)
printf '{}\n' > "$dest/client/seed.json"
[ -f "$ROOT/client/README.md" ] && cp "$ROOT/client/README.md" "$dest/client/README.md"
cp "$ROOT/scripts/client-kit-wrapper" "$dest/kit"; chmod +x "$dest/kit"
printf '.env\n.env.*\n.secrets/\nbackups/\n.test/\nmoney-reports/\n' > "$dest/.gitignore"

# fresh secrets + its own project name and ports
make_env "$ROOT/.env.example" "$dest/.env" "ck-$slug"
pg=$((5442 + offset)); nc=$((8090 + offset)); mcp=$((8790 + offset))
for p in $pg $nc $mcp; do [ $p -lt 65536 ] || die "port offset too large"; done
tmp="$dest/.env.tmp"
sed -e "s/^POSTGRES_PORT=.*/POSTGRES_PORT=$pg/" -e "s/^NOCODB_PORT=.*/NOCODB_PORT=$nc/" -e "s/^MCP_PORT=.*/MCP_PORT=$mcp/" "$dest/.env" > "$tmp"
mv "$tmp" "$dest/.env"; chmod 600 "$dest/.env"
[ $git = 1 ] || true   # --no-git kept for old habits: the folder is part of the ragnarok repo, nothing to init

bold "Created $dest  (docker project ck-$slug)"
say "Secrets: fresh random values were written to $dest/.env (private; it is git-ignored). Nothing is printed here."
say "Ports:   Postgres 127.0.0.1:$pg   NocoDB 127.0.0.1:$nc   MCP 127.0.0.1:$mcp"
if [ $up = 1 ]; then
  bold "Starting it (./kit up)"
  "$dest/kit" up
  say "Tables are empty (nothing was loaded)."
fi
cat <<NEXT

Next:
  cd "$dest"
  - Change the tables: edit client/schema.json, then ./kit check and ./kit up again
  - ./kit status       what's running and how many records each table has
  - ./kit test         proves everything works on a throwaway copy
  - Connect Claude (see README.md, "Connect Claude"). The MCP token is MCP_TOKEN in .env.
NEXT
