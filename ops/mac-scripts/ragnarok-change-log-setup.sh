#!/bin/bash
# One-time setup, run by the owner: lets the Mac's push key also deliver change
# receipts. Rewrites ~claude/bin/receive-transcript on Alexus so its forced
# command accepts two things and nothing else:
#   <session-uuid>.jsonl  -> a transcript into /srv/ragnarok/transcripts/macbook (unchanged)
#   change                -> one JSON change entry, handed to `ragnarok log-change` as the owner
# authorized_keys is not touched.
set -euo pipefail
ssh claude@alexus 'bash -s' <<'EOF'
set -e
cat > ~/bin/receive-transcript <<'SH'
#!/bin/bash
# Forced command for the Mac's push key. Accepts exactly two requests:
#   <session-uuid>.jsonl  one Claude Code transcript on stdin -> the macbook drop folder
#   change                one change entry (JSON) on stdin   -> ragnarok log-change
set -euo pipefail
name="${SSH_ORIGINAL_COMMAND:-}"
if [ "$name" = "change" ]; then
  owner_dir=$(ls -d /home/*/Yggdrasil-v2 2>/dev/null | head -1); owner=$(stat -c %U "$owner_dir")   # whoever owns Yggdrasil-v2
  head -c 65536 | sudo -n -u "$owner" -H "$owner_dir/mcp/bin/ragnarok" log-change --via mac-push-key
  exit $?
fi
[[ "$name" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.jsonl$ ]] || { echo "refused: expected <session-uuid>.jsonl or change, got '$name'" >&2; exit 2; }
dir=/srv/ragnarok/transcripts/macbook
umask 027
tmp=$(mktemp "$dir/.incoming.XXXXXX")
head -c 52428800 > "$tmp"
chgrp ragnarok "$tmp"; chmod 640 "$tmp"
mv -f "$tmp" "$dir/$name"
echo "$dir/$name $(sha256sum "$dir/$name" | cut -d' ' -f1)"
SH
chmod 755 ~/bin/receive-transcript
echo "SETUP OK"
grep -c 'log-change' ~/bin/receive-transcript
EOF
