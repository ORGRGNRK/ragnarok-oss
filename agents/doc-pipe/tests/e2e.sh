#!/bin/bash
# End-to-end test over Tailscale: upload each synthetic image, wait for the model, print the result.
# Usage: PIPE_AUTH=user:password tests/e2e.sh https://alexus:8448 img1.jpg [img2.jpg ...]
set -eu
BASE=$1; shift
for img in "$@"; do
  r=$(curl -sS -u "$PIPE_AUTH" -F "file=@$img" "$BASE/api/upload")
  id=$(echo "$r" | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])')
  echo "uploaded $img -> document $id"
  while :; do
    s=$(curl -sS -u "$PIPE_AUTH" "$BASE/api/documents/$id")
    st=$(echo "$s" | python3 -c 'import sys,json;print(json.load(sys.stdin)["status"])')
    [ "$st" != processing ] && break; sleep 5
  done
  echo "$s" > "/tmp/pipe-doc-$id.json"; echo "document $id: $st (saved /tmp/pipe-doc-$id.json)"
done
