#!/bin/bash
# build-corpus.sh: Heimdall's memory index, built with the owner's own tools (~/Developer/scripts):
#   ragnarok-corpus/compile.py  -> chunks.jsonl (redacted; refuses to build if a live secret survives)
#   recall/build-matrix.py      -> chunks.vectors.npy + chunks.meta.jsonl
# Corpus = ~/Developer only (HOME is pointed there for the walk), no Yggdrasil export (none on this Mac).
# Embeddings: nomic-embed-text in Ollama on Alexus. Output stays on this Mac, 0700.
#   build-corpus.sh            compile only (fast; shows what would go in)
#   build-corpus.sh --embed    compile + embed + matrix (slow the first time)
set -eu
REAL="$HOME"; S="$REAL/Developer/scripts"; H="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$REAL/Library/Application Support/Heimdall/corpus"
mkdir -p "$OUT"; chmod 700 "$OUT"
export HEIMDALL_REAL_HOME="$REAL" CORPUS_OUT="$OUT" CORPUS_SAVE_SCRIPT="$H/recall/mac-save-adapter.py"
. "$H/bin/local-config.sh"   # item 30: Alexus address from ~/.ragnarok/local.conf
if [ -z "${RECALL_EMBED_URL:-}" ]; then
  if curl -sf -m 2 "$OLLAMA_URL/api/tags" >/dev/null 2>&1; then
    export RECALL_EMBED_URL="$OLLAMA_URL/v1/embeddings"
  else
    export RECALL_EMBED_URL="http://$ALEXUS_TAILSCALE:11434/v1/embeddings"
  fi
fi
cd "$S/ragnarok-corpus"
HOME="$REAL/Developer" python3 compile.py --no-ygg "$@"
if [ "${1:-}" = --embed ]; then
  "$S/recall/.venv/bin/python" "$S/recall/build-matrix.py" "$OUT/chunks.jsonl"
fi
