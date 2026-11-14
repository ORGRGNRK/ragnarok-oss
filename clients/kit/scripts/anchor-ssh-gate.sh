#!/usr/bin/env bash
# scripts/anchor-ssh-gate.sh -- runs on the SERVER as the SSH "forced command" for the Mac's anchor key.
# The key can then do exactly one thing: ./kit anchor [WRITE_SEQ ACCESS_SEQ]. No shell, no other
# command, no port forwarding. Put this in the server owner's ~/.ssh/authorized_keys (one line):
#   restrict,command="$HOME/Developer/ragnarok-hq/scripts/anchor-ssh-gate.sh" ssh-ed25519 AAAA... ragnarok-anchor
set -euo pipefail
set -f   # no wildcard expansion of anything the client sent
req="${SSH_ORIGINAL_COMMAND:-anchor}"
case "$req" in
  anchor|"anchor "*) ;;
  *) echo "this key may only run: anchor [WRITE_SEQ ACCESS_SEQ]" >&2; exit 2 ;;
esac
# shellcheck disable=SC2086
set -- $req; shift
[ $# -le 2 ] || { echo "anchor takes at most two numbers" >&2; exit 2; }
for n in "$@"; do case "$n" in ''|*[!0-9]*) echo "anchor arguments must be whole numbers" >&2; exit 2 ;; esac; done
exec "$(cd "$(dirname "$0")/.." && pwd)/kit" anchor "$@"
