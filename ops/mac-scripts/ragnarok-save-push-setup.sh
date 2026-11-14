#!/bin/bash
# One-time setup, run by the owner: lets the Mac's ~/.ssh/alexus key drop Claude Code
# transcripts on Alexus for /save, and nothing else.
#
# On Alexus, as the claude user:
#   - /srv/ragnarok/transcripts/macbook  (group ragnarok, so the yggdrasil-run MCP can read it)
#   - ~claude/bin/receive-transcript     (accepts one <session-uuid>.jsonl on stdin, writes it there)
#   - ~claude/.ssh/authorized_keys       (the alexus key, forced to run receive-transcript only,
#                                         with "restrict": no shell, no forwarding, no pty)
set -euo pipefail
PUB=$(cat ~/.ssh/alexus.pub)
ssh claude@alexus "PUB='$PUB' bash -s" <<'EOF'
set -e
install -d -m 2770 -g ragnarok /srv/ragnarok/transcripts /srv/ragnarok/transcripts/macbook
mkdir -p ~/bin ~/.ssh && chmod 700 ~/.ssh
cat > ~/bin/receive-transcript <<'SH'
#!/bin/bash
# Forced command for the Mac's push key: accepts exactly one Claude Code
# transcript on stdin and writes it to the macbook drop folder. Nothing else.
set -euo pipefail
name="${SSH_ORIGINAL_COMMAND:-}"
[[ "$name" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.jsonl$ ]] || { echo "refused: expected <session-uuid>.jsonl, got '$name'" >&2; exit 2; }
dir=/srv/ragnarok/transcripts/macbook
umask 027
tmp=$(mktemp "$dir/.incoming.XXXXXX")
head -c 52428800 > "$tmp"
chgrp ragnarok "$tmp"; chmod 640 "$tmp"
mv -f "$tmp" "$dir/$name"
echo "$dir/$name $(sha256sum "$dir/$name" | cut -d' ' -f1)"
SH
chmod 755 ~/bin/receive-transcript
echo "command=\"/home/claude/bin/receive-transcript\",restrict $PUB" > ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
restorecon -R ~/.ssh 2>/dev/null || true
echo "SETUP OK"
ls -la ~/.ssh/authorized_keys ~/bin/receive-transcript
ls -ld /srv/ragnarok/transcripts/macbook
EOF
