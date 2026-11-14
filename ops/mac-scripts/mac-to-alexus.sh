#!/bin/bash
# mac-to-alexus.sh: copy everything that only exists on the macOS side of this MacBook to Alexus, so it can be
# reached from Linux (Asahi can't read the Mac's disk). Safe to run again before the final switch.
#   home folders  -> alexus:~/mac-home/        (same layout as the Mac's home folder)
#   Pictures      -> alexus:/mnt/seagate/mac-offload-2026-11-10/Pictures
# Nothing is deleted on the Mac. Left out on purpose: ~/.ssh (make new keys on Linux; private keys don't travel
# through the server) and rebuildable folders (node_modules, .build, .venv, DerivedData, __pycache__, .wrangler).
# After copying it checks every file's name and size on both sides and says so.
set -uo pipefail
HOST="alexus"
EXC=(node_modules .build .venv DerivedData __pycache__ .wrangler)
export COPYFILE_DISABLE=1          # no ._ sidecar files

copy() {   # copy DEST_DIR ITEM...   (items are relative to ~)
  local dest="$1"; shift
  local items=() ex=() prune=() i
  for i in "$@"; do [ -e "$HOME/$i" ] && items+=("$i"); done
  for i in "${EXC[@]}"; do ex+=(--exclude "$i"); prune+=(-name "$i" -o); done
  unset 'prune[${#prune[@]}-1]'
  echo "== ${items[*]} -> $dest"
  tar -cf - -C "$HOME" "${ex[@]}" "${items[@]}" 2>/tmp/mac-to-alexus.err | ssh "$HOST" "mkdir -p '$dest' && tar -xf - -C '$dest' 2>/dev/null"
  [ -s /tmp/mac-to-alexus.err ] && { echo "   could not read:"; head -5 /tmp/mac-to-alexus.err | sed 's/^/     /'; }
  local here there
  here=$(cd "$HOME" && find "${items[@]}" \( "${prune[@]}" \) -prune -o -type f -exec stat -f '%z %N' {} + 2>/dev/null | LC_ALL=C sort)
  there=$(ssh "$HOST" "cd '$dest' && find $(printf "'%s' " "${items[@]}") \\( $(printf -- "-name '%s' -o " "${EXC[@]}" | sed 's/ -o $//') \\) -prune -o -type f -printf '%s %p\n' 2>/dev/null" | LC_ALL=C sort)
  local n; n=$(printf '%s\n' "$here" | grep -c .)
  if [ "$here" = "$there" ]; then echo "   OK: all $n files match by name and size"
  else
    local missing; missing=$(comm -23 <(printf '%s\n' "$here") <(printf '%s\n' "$there") | grep -c .)
    echo "   CHECK: $missing of $n files differ or are missing on Alexus (first few):"
    comm -23 <(printf '%s\n' "$here") <(printf '%s\n' "$there") | head -5 | sed 's/^/     /'
    return 1
  fi
}

rc=0
copy mac-home Developer .ragnarok .alexus .claude .codex .grok .gemini .local/bin .config Documents Desktop Downloads || rc=1
copy /mnt/seagate/mac-offload-2026-11-10 Pictures || rc=1
ssh "$HOST" 'chmod 700 ~/mac-home; du -sh ~/mac-home | cut -f1 | sed "s/^/mac-home on Alexus: /"; df -h / | tail -1 | awk "{print \"Alexus disk free: \" \$4}"'
exit $rc
