#!/bin/bash
# nightly.sh: run by launchd (com.heimdall.corpus) at 04:30. Rebuilds the memory index (build-corpus.sh --embed;
# unchanged chunks reuse their cached embeddings) and writes one line to ~/.ragnarok/heimdall-edits.jsonl,
# so the timeline shows it and a failure lands in the failure feed.
export PATH="/opt/homebrew/bin:/usr/bin:/bin"
LOG="$HOME/.ragnarok/heimdall-edits.jsonl"
OUT="$HOME/Library/Logs/heimdall-corpus.log"
mkdir -p "$HOME/.ragnarok" "$HOME/Library/Logs"   # I1: a fresh account has neither
export PYTHONUNBUFFERED=1                           # I2: output lines stay in the order they happened
started=$(date +%s)
"$HOME/Developer/heimdall/recall/build-corpus.sh" --embed --quiet > "$OUT" 2>&1; rc=$?   # I2: the real exit code
if [ $rc -eq 0 ]; then
  ok=true; detail="$(grep -Eo '[0-9,]+ vectors' "$OUT" | tail -1) in $(( $(date +%s) - started )) s"
else
  why=$(grep -Ei 'error|refused|traceback|failed|denied' "$OUT" | tail -1); [ -n "$why" ] || why=$(tail -1 "$OUT")
  ok=false; detail="index rebuild failed (exit $rc): $(printf '%s' "$why" | cut -c1-200)"
fi
python3 -c 'import json,os,sys,datetime; print(json.dumps({"ts": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="milliseconds").replace("+00:00","Z"), "edit": "corpus", "who": "nightly", "by": os.environ.get("USER", ""), "step": "corpus", "ok": sys.argv[1]=="true", "detail": sys.argv[2]}))' "$ok" "$detail" >> "$LOG"
