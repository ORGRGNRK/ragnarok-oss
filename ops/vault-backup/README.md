# vault-backup

Nightly (03:30 Pacific) encrypted backup of Vaultwarden and Pocket ID. Script header says what is in it.

- Copies: /mnt/seagate/backups/vault/ (newest 30) and gdrive:ragnarok-backups/vault/ (120 days).
- Encrypted with age to age.pub. The private key is on the Mac: ~/.ragnarok/vault-backup/age.key.
  Without that key the backups cannot be opened. Keep a second copy of it offline.
- Failure: vault-backup-failed.service posts to the room.
- Install: symlink the three units into ~/.config/systemd/user/, daemon-reload, enable --now vault-backup.timer.

## Restore (tested 2026-11-13: 2336 items, 2 Pocket ID passkeys came back)
1. rclone copy gdrive:ragnarok-backups/vault/<newest> .   (or take it from the Seagate)
2. On the Mac: age -d -i ~/.ragnarok/vault-backup/age.key <file> | tar -xf -
3. Stop the containers, put vaultwarden/{db.sqlite3,rsa_key.pem,attachments} into ops/vaultwarden/data/,
   pocket-id/pocket-id.db + uploads into ops/pocket-id/data/, encryption_key into ops/pocket-id/secrets/
   (delete any old -wal/-shm files first), start the containers.
