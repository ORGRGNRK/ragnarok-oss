#!/usr/bin/env bash
# Nightly backup of the owner's Vaultwarden (vault.example.com) and Pocket ID (auth.example.com).
# owner, 2026-11-13: "is my server still being synced to something offsite" -> it wasn't. "do it".
#
# What: a consistent copy of both SQLite databases (Python's sqlite3 backup API, safe while the apps run), plus
#   Vaultwarden's rsa_key.pem + attachments/sends and Pocket ID's uploads + encryption key, in one tar,
#   encrypted with age to a PUBLIC key. The PRIVATE key is NOT on this server: it lives on the Mac at
#   ~/.ragnarok/vault-backup/age.key (and should be copied somewhere offline). A stolen backup is unreadable.
# Where: /mnt/seagate/backups/vault/ (keeps the newest 30) and gdrive:ragnarok-backups/vault/ (keeps 120 days).
# Fails loudly: any error exits nonzero, and vault-backup-failed.service posts to the room.
# Restore: see README.md next to this file.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
OPS="$(dirname "$HERE")"
RCLONE="${RCLONE:-$HOME/.local/bin/rclone}"
LOCAL="${LOCAL:-/mnt/seagate/backups/vault}"
REMOTE="${REMOTE:-gdrive:ragnarok-backups/vault}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
NAME="vault-$STAMP.tar.age"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
chmod 700 "$WORK"; mkdir -p "$WORK/b/vaultwarden" "$WORK/b/pocket-id"

python3 -I - "$OPS" "$WORK/b" <<'PY'
import sqlite3, sys
ops, out = sys.argv[1], sys.argv[2]
for src, dst in ((f"{ops}/vaultwarden/data/db.sqlite3", f"{out}/vaultwarden/db.sqlite3"),
                 (f"{ops}/pocket-id/data/pocket-id.db", f"{out}/pocket-id/pocket-id.db")):
    s = sqlite3.connect(f"file:{src}?mode=ro", uri=True); d = sqlite3.connect(dst)
    s.backup(d); d.close(); s.close()
    ok = sqlite3.connect(dst).execute("pragma integrity_check").fetchone()[0]
    if ok != "ok": sys.exit(f"integrity check failed for {dst}: {ok}")
c = sqlite3.connect(f"{out}/vaultwarden/db.sqlite3")
n = c.execute("select count(*) from ciphers").fetchone()[0]
if n < 100: sys.exit(f"only {n} vault items in the copy; refusing to treat that as a good backup")
print(f"copied: {n} vault items")
PY
VW="$OPS/vaultwarden/data"; PI="$OPS/pocket-id"
cp -p "$VW/rsa_key.pem" "$WORK/b/vaultwarden/"
for d in attachments sends; do [ -d "$VW/$d" ] && cp -rp "$VW/$d" "$WORK/b/vaultwarden/"; done
[ -d "$PI/data/uploads" ] && cp -rp "$PI/data/uploads" "$WORK/b/pocket-id/"
cp -p "$PI/secrets/encryption_key" "$WORK/b/pocket-id/"
cp -p "$OPS/vaultwarden/compose.yml" "$WORK/b/vaultwarden/"; cp -p "$PI/compose.yml" "$WORK/b/pocket-id/"

tar -C "$WORK/b" -cf - . | age -R "$HERE/age.pub" -o "$WORK/$NAME"
[ -s "$WORK/$NAME" ] || { echo "encrypted file is empty"; exit 1; }

mountpoint -q /mnt/seagate || { echo "Seagate is not mounted at /mnt/seagate"; exit 1; }
mkdir -p "$LOCAL"; cp "$WORK/$NAME" "$LOCAL/$NAME.part" && mv "$LOCAL/$NAME.part" "$LOCAL/$NAME"
ls -1t "$LOCAL"/vault-*.tar.age | tail -n +31 | xargs -r rm -f --
echo "seagate: $LOCAL/$NAME ($(stat -c %s "$LOCAL/$NAME") bytes)"

"$RCLONE" copyto "$WORK/$NAME" "$REMOTE/$NAME" -q
"$RCLONE" lsf "$REMOTE/$NAME" -q | grep -qx "$NAME" || { echo "offsite copy not found after upload"; exit 1; }
"$RCLONE" delete "$REMOTE" --min-age 120d --include 'vault-*.tar.age' -q || echo "note: old offsite copies not pruned"
echo "offsite: $REMOTE/$NAME"
