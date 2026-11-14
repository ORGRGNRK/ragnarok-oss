#!/bin/bash
# Usage: summarize.sh <file>
# <file> holds "Subject: ..." on line 1, "From: ..." on line 2, then the email body.
# Prints ONE short line (no "Upwork:" prefix). On any model failure/timeout prints the subject.
DIR="$(cd "$(dirname "$0")" && pwd)"
FILE="$1"
MODEL="qwen2.5:3b"
OLLAMA_URL="http://alexus:11434/api/generate"
[ -r "$DIR/config" ] && . "$DIR/config"
[ -n "$UA_MODEL" ] && MODEL="$UA_MODEL"
[ -n "$UA_OLLAMA_URL" ] && OLLAMA_URL="$UA_OLLAMA_URL"

SUBJECT="$(head -n 1 "$FILE" 2>/dev/null | sed 's/^Subject: //')"
[ -z "$SUBJECT" ] && SUBJECT="new email"

fallback() { printf '%s\n' "$SUBJECT" | tr -d '\r\n' | cut -c1-200; echo; exit 0; }
[ -r "$FILE" ] || fallback

LOG="$HOME/Library/Logs/upwork-alert.log"
REQ="$(/usr/bin/python3 - "$FILE" "$MODEL" <<'PY'
import json, sys
text = open(sys.argv[1], encoding="utf-8", errors="replace").read()[:1800]
prompt = ("You summarize Upwork notification emails for a freelancer. "
          "Reply with ONE short plain-English line (max 15 words), no quotes, no emoji, no prefix. Keep the client name and job topic if present; do not give advice. "
          "Examples: 'Client viewed your n8n proposal' / 'New message from client Acme: can you start Monday?' / "
          "'Invitation to interview for Zapier automation job'.\n\nEMAIL:\n" + text + "\n\nONE-LINE SUMMARY:")
print(json.dumps({"model": sys.argv[2], "prompt": prompt, "stream": False,
                  "keep_alive": "30m", "options": {"temperature": 0.2, "num_predict": 60}}))
PY
)" || fallback

RESP="$(printf '%s' "$REQ" | /usr/bin/curl -s -m 20 -H 'Content-Type: application/json' --data-binary @- "$OLLAMA_URL")" || { echo "$(date '+%F %T') model call failed/timeout" >> "$LOG"; fallback; }

LINE="$(printf '%s' "$RESP" | /usr/bin/python3 -c '
import json,sys,re
try:
    r=json.load(sys.stdin)["response"]
except Exception:
    sys.exit(1)
r=r.strip().splitlines()[0] if r.strip() else ""
r=re.sub(r"^(upwork\s*[:\-]\s*)","",r.strip().strip("\"'\''"),flags=re.I).strip()
print(r[:200])
')" 
if [ -z "$LINE" ]; then echo "$(date '+%F %T') bad model response" >> "$LOG"; fallback; fi
printf '%s\n' "$LINE"
