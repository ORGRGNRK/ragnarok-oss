#!/usr/bin/env bash
# Creates isolated Linux users for each AI agent on alexus, installs the
# automatic receipt-logging login shell, and authorizes the Mac SSH key.
set -euo pipefail

AI_USERS=("claude" "argon" "grok" "codex")
PUBKEY="${1:-}"

echo "== 1. Installing /usr/local/libexec/ragnarok-receipt-log =="
sudo mkdir -p /var/log/ragnarok /usr/local/libexec
sudo chmod 755 /var/log/ragnarok

sudo tee /usr/local/libexec/ragnarok-receipt-log >/dev/null <<'EOF'
#!/usr/bin/env bash
# Automatic append-only SHA-256 hash-chained receipt logger for AI SSH sessions
set -u
ACTOR="${1:-unknown}"
CMD="${2:-}"
EXIT_CODE="${3:-0}"
PWD_DIR="${4:-/}"
TS="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
LOG_FILE="/var/log/ragnarok/ai_ssh_receipts.jsonl"

# Redact before classification, hashing, and persistence. Keep historical lines unchanged so the
# existing hash chain remains verifiable; every line written by this version stores scrubbed text.
CMD="$(printf '%s' "$CMD" | sed -E \
  -e 's/([A-Za-z0-9_]*(KEY|TOKEN|SECRET|PASS(WORD|WD)?|AUTH|CREDENTIALS?|COOKIE|PRIVATE|DSN)[A-Za-z0-9_]*=)([^ ;&|]+)/\1***/Ig' \
  -e 's/(--(password|passwd|pass|token|api-key|secret|auth)(=|[[:space:]]+))([^ ;&|]+)/\1***/Ig' \
  -e 's/(Bearer[[:space:]]+)[A-Za-z0-9._~+\/-]+=*/\1***/Ig' \
  -e 's/(sshpass[[:space:]]+-p[[:space:]]+)[^[:space:]]+/\1***/g' \
  -e 's/(https?:\/\/[^:/@[:space:]]+:)[^@/[:space:]]+@/\1***@/Ig')"

# Classify Read vs Write (from commit 10fc858 lesson)
if printf '%s' "$CMD" | grep -Eq '^[[:space:]]*(ls|cat|head|tail|grep|rg|find|ps|systemctl status|docker ps|docker logs|git status|git log|git diff|ip |df |free |uname|whoami|id|pwd|echo|curl -s http://127\.0\.0\.1:[0-9]+/health)'; then
  KIND="Read"
  STATUS="Observed (exit=${EXIT_CODE})"
else
  KIND="Action"
  if [ "$EXIT_CODE" -eq 0 ]; then
    STATUS="Applied (exit=0)"
  else
    STATUS="Failed (exit=${EXIT_CODE})"
  fi
fi

# Lock and compute SHA-256 chain
(
  flock -x 200
  PREV_HASH="0000000000000000000000000000000000000000000000000000000000000000"
  SEQ=1
  if [ -s "$LOG_FILE" ]; then
    LAST_LINE="$(tail -n 1 "$LOG_FILE")"
    PREV_HASH="$(printf '%s' "$LAST_LINE" | jq -r '.hash // empty' 2>/dev/null || echo "$PREV_HASH")"
    LAST_SEQ="$(printf '%s' "$LAST_LINE" | jq -r '.seq // 0' 2>/dev/null || echo 0)"
    SEQ=$((LAST_SEQ + 1))
  fi

  PAYLOAD="${SEQ}|${TS}|${ACTOR}|${KIND}|${STATUS}|${PWD_DIR}|${CMD}|${PREV_HASH}"
  HASH="$(printf '%s' "$PAYLOAD" | sha256sum | awk '{print $1}')"

  jq -nc \
    --argjson seq "$SEQ" \
    --arg ts "$TS" \
    --arg actor "$ACTOR" \
    --arg kind "$KIND" \
    --arg status "$STATUS" \
    --arg cwd "$PWD_DIR" \
    --arg cmd "$CMD" \
    --arg prev_hash "$PREV_HASH" \
    --arg hash "$HASH" \
    '{seq:$seq, ts:$ts, actor:$actor, kind:$kind, status:$status, cwd:$cwd, cmd:$cmd, prev_hash:$prev_hash, hash:$hash}' \
    >> "$LOG_FILE"
) 200>/var/log/ragnarok/.receipt.lock
EOF
sudo chmod 755 /usr/local/libexec/ragnarok-receipt-log

echo "== 2. Installing /usr/local/bin/ragnarok-receipt-shell =="
sudo tee /usr/local/bin/ragnarok-receipt-shell >/dev/null <<'EOF'
#!/usr/bin/env bash
# Login shell wrapper for AI users: executes command, logs receipt with SHA-256 hash chain
ACTOR="$(id -un)@$(hostname -s)"

if [ "${1:-}" = "-c" ] && [ -n "${2:-}" ]; then
  CMD="$2"
  /bin/bash -c "$CMD"
  RC=$?
  /usr/local/libexec/ragnarok-receipt-log "$ACTOR" "$CMD" "$RC" "$PWD" || true
  exit $RC
else
  # Interactive session fallback
  /usr/local/libexec/ragnarok-receipt-log "$ACTOR" "INTERACTIVE_LOGIN" "0" "$PWD" || true
  exec /bin/bash "$@"
fi
EOF
sudo chmod 755 /usr/local/bin/ragnarok-receipt-shell
grep -qxF '/usr/local/bin/ragnarok-receipt-shell' /etc/shells || echo '/usr/local/bin/ragnarok-receipt-shell' | sudo tee -a /etc/shells >/dev/null

# Ensure log file is writable by the ragnarok-ai group (append-only in practice via wrapper)
sudo groupadd -f ragnarok-ai
sudo touch /var/log/ragnarok/ai_ssh_receipts.jsonl /var/log/ragnarok/.receipt.lock
sudo chown root:ragnarok-ai /var/log/ragnarok/ai_ssh_receipts.jsonl /var/log/ragnarok/.receipt.lock
sudo chmod 660 /var/log/ragnarok/ai_ssh_receipts.jsonl /var/log/ragnarok/.receipt.lock

echo "== 3. Creating AI users (${AI_USERS[*]}) =="
for U in "${AI_USERS[@]}"; do
  if ! id "$U" >/dev/null 2>&1; then
    sudo useradd -m -s /usr/local/bin/ragnarok-receipt-shell -G ragnarok-ai,docker "$U"
    echo "Created user: $U (shell=/usr/local/bin/ragnarok-receipt-shell)"
  else
    sudo usermod -s /usr/local/bin/ragnarok-receipt-shell -aG ragnarok-ai,docker "$U"
    echo "Updated user: $U"
  fi

  if [ -n "$PUBKEY" ]; then
    sudo mkdir -p "/home/$U/.ssh"
    printf '%s\n' "$PUBKEY" | sudo tee "/home/$U/.ssh/authorized_keys" >/dev/null
    sudo chown -R "$U:$U" "/home/$U/.ssh"
    sudo chmod 700 "/home/$U/.ssh"
    sudo chmod 600 "/home/$U/.ssh/authorized_keys"
  fi
done

echo ""
echo "=========================================================="
echo "  AI SSH USERS READY: ${AI_USERS[*]}"
echo "  Receipt Ledger: /var/log/ragnarok/ai_ssh_receipts.jsonl"
echo "=========================================================="
