#!/usr/bin/env bash
set -euo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export OLLAMA_HOST="${OLLAMA_HOST:-http://alexus:11434}"
export PYTHONUNBUFFERED="1"

exec /usr/bin/python3 -u "$(dirname "$0")"/mail_bridge.py daemon
