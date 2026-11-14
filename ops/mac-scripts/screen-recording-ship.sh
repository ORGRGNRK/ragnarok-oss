#!/bin/bash
# screen-recording-ship — macOS screen recordings land on alexus.
#
# The screenshot tool saves into ~/Screen-Recordings (set by `install`). When a
# file has sat unchanged for 15 seconds, this copies it to
# alexus:~/screen-recordings and removes the local file only after the
# remote size matches. A recording still in progress keeps growing, so it stays.
#
# The copy uses OpenSSH on the house LAN. The address is alexus's current
# Tailscale endpoint when that endpoint is a private IPv4 and answers with an
# OpenSSH banner — never a pinned IP.
#
# Away from the LAN it tries alexus's tailnet address, at most once every 10
# minutes and with a hard 12 second limit. Tailscale SSH on this net asks for a
# browser check; while that check is pending the try times out and the file
# stays here. After the owner passes the check, the next try ships it.
#
# The save location is one macOS setting shared with screenshots, so screenshots
# land in ~/Screen-Recordings too. Anything there that is not a video is moved
# straight back to the Desktop, never over an existing file.
#
# Desktop files named "Screen Recording *" newer than the install are picked up
# only when this is run by hand from a terminal: macOS does not let a launch
# agent list the Desktop (measured 2026-11-11). Recordings already on the
# Desktop are left alone.
#
# Runs as the Mac user (yggdrasil). Remote account is yggdrasil, key
# ~/.ssh/id_ed25519, IdentityAgent turned off so launchd does not wait on 1Password.
#
# The matching agent run record (state.json) is copied next to the video,
# under screen-recordings/runs/<stored-name>/. Alexus cuts the short clip
# from that record. A later pass sends the record again when that run still
# overlaps a recording and the file has changed. A run that does not overlap
# is not sent, and is not a reason to log in.
# launchd label: co.rgnrk.screen-recording-ship
#   screen-recording-ship.sh install
#   screen-recording-ship.sh            # one pass

IN="${SCREEN_SHIP_IN:-$HOME/Screen-Recordings}"
DESKTOP="${SCREEN_SHIP_DESKTOP:-$HOME/Desktop}"
STATE="${SCREEN_SHIP_STATE:-$HOME/.ragnarok/screen-recording-ship}"
LOG="${SCREEN_SHIP_LOG:-$HOME/Library/Logs/screen-recording-ship.log}"
KEY="${SCREEN_SHIP_KEY:-$HOME/.ssh/id_ed25519}"
STABILITY="${SCREEN_SHIP_STABILITY:-15}"
RESERVE_KB="${SCREEN_SHIP_RESERVE_KB:-8388608}"   # leave 8 GiB free on alexus
FAKE="${SCREEN_SHIP_FAKE_DIR:-}"
TAILNET_EVERY="${SCREEN_SHIP_TAILNET_EVERY:-600}"
REMOTE_DIR="screen-recordings"
TS_BIN="/Applications/Tailscale.app/Contents/MacOS/Tailscale"
AGENTS="${SCREEN_SHIP_AGENTS:-$HOME/.ragnarok/agents}"
CLIPPY="${SCREEN_SHIP_CLIPPY:-$(cd "$(dirname "$0")/../alexus" && pwd)/screen-recording-clip.py}"

log() {
  mkdir -p "$(dirname "$LOG")"
  printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$LOG"
  [ -t 1 ] && printf '%s %s\n' "$(date '+%F %T')" "$*"
}

# Private IPv4 where alexus is answering real OpenSSH, or empty.
resolve_lan_ip() {
  [ -n "$FAKE" ] && return 0
  if [ -n "${SCREEN_SHIP_HOST:-}" ]; then
    printf '%s\n' "$SCREEN_SHIP_HOST"
    return 0
  fi
  [ -n "${SCREEN_SHIP_SKIP_RESOLVE:-}" ] && return 0
  [ -x "$TS_BIN" ] || return 0
  /usr/bin/python3 - "$TS_BIN" <<'PY'
import ipaddress, json, socket, subprocess, sys
ts = sys.argv[1]
try:
    raw = subprocess.check_output([ts, "status", "--json"], timeout=8)
except Exception:
    raise SystemExit(0)
data = json.loads(raw)
ip = None
for peer in data.get("Peer", {}).values():
    dns = peer.get("DNSName") or ""
    if not dns.startswith("alexus."):
        continue
    cur = peer.get("CurAddr") or ""
    if cur.startswith("["):
        host = cur[1:].split("]", 1)[0]
    elif cur.count(":") == 1:
        host = cur.rsplit(":", 1)[0]
    else:
        host = cur
    try:
        addr = ipaddress.ip_address(host)
    except ValueError:
        continue
    if addr.version != 4 or not addr.is_private:
        continue
    ip = host
    break
if not ip:
    raise SystemExit(0)
s = socket.socket()
s.settimeout(3)
try:
    s.connect((ip, 22))
    banner = s.recv(80)
except Exception:
    raise SystemExit(0)
finally:
    s.close()
if banner.startswith(b"SSH-2.0-OpenSSH"):
    sys.stdout.write(ip)
PY
}

# alexus's tailnet IPv4, looked up now, or empty.
tailnet_ip() {
  [ -x "$TS_BIN" ] || return 0
  /usr/bin/python3 - "$TS_BIN" <<'PY'
import json, subprocess, sys
try:
    data = json.loads(subprocess.check_output([sys.argv[1], "status", "--json"], timeout=8))
except Exception:
    raise SystemExit(0)
for peer in data.get("Peer", {}).values():
    if (peer.get("DNSName") or "").startswith("alexus.") and peer.get("Online"):
        for ip in peer.get("TailscaleIPs") or []:
            if "." in ip:
                sys.stdout.write(ip)
                raise SystemExit(0)
PY
}

# Tailnet address if a login gets through inside 12 seconds, else empty.
# Tried at most once per TAILNET_EVERY seconds so a pending browser check is
# not asked for again every 30 seconds.
resolve_tailnet() {
  [ -n "${SCREEN_SHIP_SKIP_RESOLVE:-}" ] && return 0
  now=$(date +%s)
  last=$(cat "$STATE/tailnet-tried" 2>/dev/null || echo 0)
  case "$last" in ''|*[!0-9]*) last=0;; esac
  [ $((now - last)) -ge "$TAILNET_EVERY" ] || return 0
  echo "$now" > "$STATE/tailnet-tried"
  ip=$(tailnet_ip | tr -d '[:space:]')
  [ -n "$ip" ] || return 0
  if ( /usr/bin/perl -e 'alarm shift; exec @ARGV' 12 /usr/bin/ssh -o BatchMode=yes \
      -o ConnectTimeout=8 -o IdentitiesOnly=yes -o IdentityAgent=none \
      -o StrictHostKeyChecking=accept-new -i "$KEY" "${ip}" true \
      </dev/null >/dev/null 2>&1 ) 2>/dev/null; then
    rm -f "$STATE/tailnet-tried"
    printf '%s\n' "$ip"
  fi
}

# Screenshots share the save location. Put anything that is not a video back on the Desktop.
return_strays() {
  for f in "$IN"/*; do
    [ -f "$f" ] || continue
    [ -L "$f" ] && continue
    base=$(basename "$f")
    case "$base" in
      .*|*.mov|*.mp4|*.m4v|*.part|*.tmp|*.crdownload|*.download) continue;;
    esac
    now=$(date +%s)
    [ $((now - $(stat -f %m "$f"))) -ge 2 ] || continue
    if [ -e "$DESKTOP/$base" ]; then
      continue
    fi
    if mv -n -- "$f" "$DESKTOP/$base" 2>/dev/null && [ ! -e "$f" ]; then
      log "moved $base back to the Desktop (not a recording)"
    fi
  done
}

ssh_to() {
  target="$1"
  shift
  /usr/bin/ssh -o BatchMode=yes -o ConnectTimeout=10 -o IdentitiesOnly=yes \
    -o IdentityAgent=none -o StrictHostKeyChecking=accept-new \
    -o ServerAliveInterval=15 -o ServerAliveCountMax=3 \
    -i "$KEY" "${target}" "$@"
}

remote_avail_kb() {
  if [ -n "$FAKE" ]; then
    echo 999999999
    return 0
  fi
  ssh_to "$1" 'df -Pk "$HOME" | awk "NR==2{print \$4}"'
}

remote_put() {
  # remote_put SRC DEST HOST  -> prints the remote byte count. No manifest yet.
  src="$1"; dest="$2"; host="$3"
  if [ -n "$FAKE" ]; then
    mkdir -p "$FAKE"
    if [ -n "${SCREEN_SHIP_FAKE_DROP:-}" ]; then
      return 1
    fi
    cat "$src" > "$FAKE/.up-$dest"
    if [ -n "${SCREEN_SHIP_FAKE_SHORT:-}" ]; then
      printf 'x' > "$FAKE/.up-$dest"
    fi
    mv -f "$FAKE/.up-$dest" "$FAKE/$dest"
    stat -f %z "$FAKE/$dest"
    return 0
  fi
  ssh_to "$host" "mkdir -p -m 700 -- \"\$HOME/$REMOTE_DIR\" && umask 077 && cat > \"\$HOME/$REMOTE_DIR/.up-${dest}\" && mv -f \"\$HOME/$REMOTE_DIR/.up-${dest}\" \"\$HOME/$REMOTE_DIR/${dest}\" && chmod 600 \"\$HOME/$REMOTE_DIR/${dest}\" && stat -c %s \"\$HOME/$REMOTE_DIR/${dest}\"" < "$src"
}

remember_manifest_line() {
  # Local copy of what is already on alexus, so a later pass can decide
  # without logging in. One line per stored name.
  dest="$1"; b64="$2"
  mkdir -p "$STATE"
  if [ -f "$STATE/manifest.tsv" ] && awk -F '\t' -v d="$dest" '$1 == d { found=1 } END { exit !found }' "$STATE/manifest.tsv"; then
    return 0
  fi
  printf '%s\t%s\n' "$dest" "$b64" >> "$STATE/manifest.tsv"
}

remote_note() {
  dest="$1"; b64="$2"; host="$3"
  if [ -n "$FAKE" ]; then
    printf '%s\t%s\n' "$dest" "$b64" >> "$FAKE/manifest.tsv"
  else
    ssh_to "$host" "umask 077 && printf '%s\t%s\n' '${dest}' '${b64}' >> \"\$HOME/$REMOTE_DIR/manifest.tsv\" && chmod 600 \"\$HOME/$REMOTE_DIR/manifest.tsv\"" || return 1
  fi
  remember_manifest_line "$dest" "$b64"
}

remote_rm() {
  dest="$1"; host="$2"
  if [ -n "$FAKE" ]; then
    rm -f "$FAKE/$dest"
    return 0
  fi
  ssh_to "$host" "rm -f \"\$HOME/$REMOTE_DIR/${dest}\""
}

safe_name() {
  printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_' | cut -c1-120
}

# Seconds, or empty when this file is not a screen recording we can time.
recording_duration() {
  if [ -n "${SCREEN_SHIP_DURATION_S:-}" ]; then
    printf '%s\n' "$SCREEN_SHIP_DURATION_S"
    return 0
  fi
  case "$2" in
    "Screen Recording "*) ;;
    *) return 0 ;;
  esac
  d=$(mdls -raw -name kMDItemDurationSeconds -- "$1" 2>/dev/null || true)
  case "$d" in
    ''|'(null)') return 0 ;;
  esac
  printf '%s\n' "$d"
}

upload_file() {
  host="$1"; stem="$2"; leaf="$3"; src="$4"
  # Tests set this to make the next upload fail, so a missed run record
  # can be shown to stay pending.
  case "${SCREEN_SHIP_FAIL_UPLOADS:-}" in
    ''|0|*[!0-9]*) ;;
    *)
      SCREEN_SHIP_FAIL_UPLOADS=$((SCREEN_SHIP_FAIL_UPLOADS - 1))
      log "upload of $leaf failed; it will be tried again"
      return 1
      ;;
  esac
  if [ -n "$FAKE" ]; then
    mkdir -p "$FAKE/runs/$stem"
    cp "$src" "$FAKE/runs/$stem/$leaf"
    return 0
  fi
  local_sum=$(shasum -a 256 "$src" | awk '{print $1}')
  remote_sum=$(ssh_to "$host" "sha256sum \"\$HOME/$REMOTE_DIR/runs/$stem/$leaf\" 2>/dev/null" | awk '{print $1}')
  if [ -n "$local_sum" ] && [ "$local_sum" = "$remote_sum" ]; then
    return 0
  fi
  ssh_to "$host" "mkdir -p -m 700 -- \"\$HOME/$REMOTE_DIR/runs/$stem\" && umask 077 && cat > \"\$HOME/$REMOTE_DIR/runs/$stem/$leaf.tmp\" && mv -f \"\$HOME/$REMOTE_DIR/runs/$stem/$leaf.tmp\" \"\$HOME/$REMOTE_DIR/runs/$stem/$leaf\" && chmod 600 \"\$HOME/$REMOTE_DIR/runs/$stem/$leaf\"" < "$src"
}

upload_text() {
  host="$1"; stem="$2"; leaf="$3"; body="$4"
  if [ -n "$FAKE" ]; then
    mkdir -p "$FAKE/runs/$stem"
    printf '%s\n' "$body" > "$FAKE/runs/$stem/$leaf"
    return 0
  fi
  printf '%s\n' "$body" | ssh_to "$host" "mkdir -p -m 700 -- \"\$HOME/$REMOTE_DIR/runs/$stem\" && umask 077 && cat > \"\$HOME/$REMOTE_DIR/runs/$stem/$leaf.tmp\" && mv -f \"\$HOME/$REMOTE_DIR/runs/$stem/$leaf.tmp\" \"\$HOME/$REMOTE_DIR/runs/$stem/$leaf\" && chmod 600 \"\$HOME/$REMOTE_DIR/runs/$stem/$leaf\""
}

# Copy the run records that overlap this recording. Failures are logged
# by the caller; the raw video is never removed because of them.
ship_runs() {
  host="$1"; dest="$2"; name="$3"; dur="$4"; offset="$5"
  [ -f "$CLIPPY" ] || return 0
  stem="${dest%.*}"
  if [ -n "$dur" ]; then
    listed=$(/usr/bin/python3 "$CLIPPY" --list-runs --agents "$AGENTS" --name "$name" --duration "$dur" --offset "$offset" || true)
  else
    listed=$(/usr/bin/python3 "$CLIPPY" --list-runs --agents "$AGENTS" --name "$name" --offset "$offset" || true)
  fi
  clock=$(/usr/bin/python3 "$CLIPPY" --clock --name "$name" --duration "$dur" --offset "$offset" || true)
  if [ -z "$listed" ] && [ -z "$clock" ]; then
    return 0
  fi
  if [ -n "$clock" ]; then
    upload_text "$host" "$stem" "clock.json" "$clock" || return 1
  fi
  local failed=0
  while IFS="$(printf '\t')" read -r id path; do
    [ -n "$id" ] && [ -f "$path" ] || continue
    # Remember the bytes we actually copied. A rewrite during the copy
    # must not be recorded, or the next pass would treat it as sent.
    sum=$(file_sha "$path")
    exported=$(mktemp)
    if ! /usr/bin/python3 "$CLIPPY" --export-run "$path" > "$exported"; then
      rm -f "$exported"
      failed=1
      continue
    fi
    if ! upload_file "$host" "$stem" "$id.json" "$exported"; then
      rm -f "$exported"
      failed=1
      continue
    fi
    rm -f "$exported"
    now=$(file_sha "$path")
    if [ "$now" != "$sum" ]; then
      failed=1
      continue
    fi
    remember_upload "$dest" "$id" "$sum"
  done <<EOF
$listed
EOF
  [ "$failed" = 0 ] || return 1
  return 0
}

file_sha() {
  shasum -a 256 "$1" | awk '{print $1}'
}

# recording + run id -> sha256 of the state.json that landed for that
# recording. One run can overlap two recordings. A hash stored under the
# run id alone would mark the failed recording done when the other one
# succeeded. The mtime of runs-checked has the same hole for a rewrite
# that lands before that touch.
uploaded_sha() {
  dest="$1"; id="$2"
  [ -f "$STATE/runs-uploaded.tsv" ] || return 0
  awk -F '\t' -v d="$dest" -v i="$id" '$1 == d && $2 == i { print $3; exit }' "$STATE/runs-uploaded.tsv"
}

remember_upload() {
  dest="$1"; id="$2"; sum="$3"
  mkdir -p "$STATE"
  tmp="$STATE/runs-uploaded.tsv.tmp"
  if [ -f "$STATE/runs-uploaded.tsv" ]; then
    awk -F '\t' -v d="$dest" -v i="$id" '!($1 == d && $2 == i)' "$STATE/runs-uploaded.tsv" > "$tmp" || true
  else
    : > "$tmp"
  fi
  printf '%s\t%s\t%s\n' "$dest" "$id" "$sum" >> "$tmp"
  mv -f "$tmp" "$STATE/runs-uploaded.tsv"
}

duration_for() {
  dest="$1"
  if [ -f "$STATE/shipped-index.tsv" ]; then
    awk -F '\t' -v d="$dest" '$1 == d { print $2; exit }' "$STATE/shipped-index.tsv"
  fi
}

# Exit 0 when $1 is strictly newer than $2. The bash -nt test only sees
# whole seconds, so a record rewritten in the same second as the last check
# looked unchanged and was never sent.
file_newer() {
  [ -e "$1" ] || return 1
  [ -e "$2" ] || return 0
  /usr/bin/python3 -c 'import os, sys
a = os.stat(sys.argv[1]).st_mtime_ns
b = os.stat(sys.argv[2]).st_mtime_ns
raise SystemExit(0 if a > b else 1)' "$1" "$2"
}

# Exit 0 when an overlapping run's current bytes are not the bytes last
# uploaded. A run that does not overlap returns 1. Comparing mtimes to
# runs-checked misses a rewrite that happened before that file was touched.
overlapping_states_newer() {
  [ -f "$STATE/manifest.tsv" ] || return 0
  offset=$(date +%z)
  while IFS="$(printf '\t')" read -r dest b64 _; do
    [ -n "$dest" ] || continue
    name=$(printf '%s' "$b64" | /usr/bin/base64 -D 2>/dev/null || true)
    [ -n "$name" ] || continue
    dur=$(duration_for "$dest")
    if [ -n "$dur" ]; then
      listed=$(/usr/bin/python3 "$CLIPPY" --list-runs --agents "$AGENTS" --name "$name" --duration "$dur" --offset "$offset" || true)
    else
      listed=$(/usr/bin/python3 "$CLIPPY" --list-runs --agents "$AGENTS" --name "$name" --offset "$offset" || true)
    fi
    [ -n "$listed" ] || continue
    while IFS="$(printf '\t')" read -r id path; do
      [ -n "$path" ] && [ -f "$path" ] || continue
      current=$(file_sha "$path")
      recorded=$(uploaded_sha "$dest" "$id")
      if [ -z "$recorded" ] || [ "$current" != "$recorded" ]; then
        return 0
      fi
    done <<EOF
$listed
EOF
  done < "$STATE/manifest.tsv"
  return 1
}

# For recordings already on alexus, send a run record that has changed
# since the last pass. LAN only, so a tailnet browser check is not opened
# just to refresh. A state.json that does not overlap a known recording
# does not open a login. With SCREEN_SHIP_FAKE_DIR the files land in that folder.
refresh_runs() {
  host="$1"
  [ -f "$CLIPPY" ] || return 0
  if [ -n "$FAKE" ] && [ ! -f "$FAKE/manifest.tsv" ]; then
    return 0
  fi
  if [ -f "$STATE/manifest.tsv" ]; then
    overlapping_states_newer || return 0
  elif [ -z "$FAKE" ] && [ -f "$STATE/runs-checked" ]; then
    newer=""
    while IFS= read -r path; do
      [ -n "$path" ] || continue
      if file_newer "$path" "$STATE/runs-checked"; then
        newer=1
        break
      fi
    done <<EOF
$(find "$AGENTS" -mindepth 2 -maxdepth 2 -name state.json 2>/dev/null)
EOF
    [ -n "$newer" ] || return 0
  fi
  if [ -z "$FAKE" ]; then
    if [ -z "$host" ]; then
      host=$(resolve_lan_ip | tr -d '[:space:]')
    fi
    [ -n "$host" ] || return 0
    text=$(ssh_to "$host" "cat \"\$HOME/$REMOTE_DIR/manifest.tsv\" 2>/dev/null" || true)
  else
    text=$(cat "$FAKE/manifest.tsv")
  fi
  [ -n "$text" ] || return 0
  mkdir -p "$STATE"
  printf '%s\n' "$text" > "$STATE/manifest.tsv.tmp"
  mv -f "$STATE/manifest.tsv.tmp" "$STATE/manifest.tsv"
  offset=$(date +%z)
  # The checkpoint moves only after every overlapping record has landed.
  # A failure here leaves runs-checked where it is, so the next pass retries
  # a record that did not change again.
  failed=0
  while IFS="$(printf '\t')" read -r dest b64 _; do
    [ -n "$dest" ] || continue
    name=$(printf '%s' "$b64" | /usr/bin/base64 -D 2>/dev/null || true)
    [ -n "$name" ] || continue
    dur=$(duration_for "$dest")
    if ! ship_runs "$host" "$dest" "$name" "$dur" "$offset"; then
      log "run record for $dest did not upload; it will be tried again"
      failed=1
    fi
  done <<EOF
$text
EOF
  if [ "$failed" != 0 ]; then
    return 1
  fi
  touch "$STATE/runs-checked"
  if [ -z "$FAKE" ]; then
    # The cutter's home on alexus is the repo checkout, not a second copy.
    ssh_to "$host" "test -f \"\$HOME/Developer/ragnarok/ops/alexus/screen-recording-clip.py\" && /usr/bin/python3 -I \"\$HOME/Developer/ragnarok/ops/alexus/screen-recording-clip.py\" --once" \
      || log "clipper was not run; the recording on alexus was left as it is"
  fi
}

file_open() {
  # Exit 0 when some process has the file open. No match, or lsof cannot see, is not open.
  /usr/sbin/lsof -Fn -- "$1" >/dev/null 2>&1
}

consider() {
  f="$1"
  desk="$2"
  [ -f "$f" ] || return 0
  [ -L "$f" ] && return 0
  base=$(basename "$f")
  case "$base" in
    .*|*.part|*.tmp|*.crdownload|*.download) return 0;;
  esac
  case "$base" in
    *.mov|*.mp4|*.m4v) ;;
    *) return 0;;
  esac
  if [ "$desk" = desk ]; then
    case "$base" in
      "Screen Recording "*) ;;
      *) return 0;;
    esac
    m=$(stat -f %m "$f")
    [ "$m" -ge "$SINCE" ] || return 0
  fi
  now=$(date +%s)
  m=$(stat -f %m "$f")
  [ $((now - m)) -ge "$STABILITY" ] || return 0
  if file_open "$f"; then
    return 0
  fi
  CAND_FILES="$CAND_FILES
$f"
  CAND_SIGS="$CAND_SIGS
$(stat -f '%z %m' "$f")"
}

ship_one() {
  f="$1"
  sig="$2"
  host="$3"
  [ -f "$f" ] || return 0
  [ "$(stat -f '%z %m' "$f")" = "$sig" ] || return 0
  if file_open "$f"; then
    return 0
  fi
  local_size=$(stat -f %z "$f")
  case "$local_size" in
    ''|0|*[!0-9]*) log "skip $(basename "$f"): size $local_size"; return 0;;
  esac
  base=$(basename "$f")
  dest="$(date -u +%Y%m%dT%H%M%SZ)_${RANDOM}_$(safe_name "$base")"
  b64=$(printf '%s' "$base" | /usr/bin/base64 | tr -d '\n')
  avail=$(remote_avail_kb "$host") || avail=""
  avail=$(printf '%s' "$avail" | tr -d '[:space:]')
  case "$avail" in
    ''|*[!0-9]*) log "couldn't read free space on alexus; keeping $base"; return 1;;
  esac
  need=$((local_size / 1024 + RESERVE_KB))
  if [ "$avail" -lt "$need" ]; then
    log "alexus has ${avail}KB free, $base needs ${need}KB with the reserve; keeping it local"
    return 1
  fi
  remote_size=$(remote_put "$f" "$dest" "$host") || {
    log "couldn't reach alexus for $base; it stays and will be retried"
    return 1
  }
  remote_size=$(printf '%s' "$remote_size" | tr -d '[:space:]')
  case "$remote_size" in
    ''|*[!0-9]*) log "alexus gave no size for $base; keeping it local"; return 1;;
  esac
  if [ "$remote_size" != "$local_size" ]; then
    remote_rm "$dest" "$host" || true
    log "size mismatch for $base (local $local_size remote $remote_size); removed the partial and kept the local file"
    return 1
  fi
  remote_note "$dest" "$b64" "$host" || log "shipped $base but the manifest line failed"
  dur=$(recording_duration "$f" "$base")
  printf '%s\t%s\n' "$dest" "$dur" >> "$STATE/shipped-index.tsv"
  ship_runs "$host" "$dest" "$base" "$dur" "$(date +%z)" || log "shipped $base but the run record was not copied"
  printf '%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$local_size" "$base" >> "$STATE/shipped.tsv"
  rm -f -- "$f"
  log "sent $base ($local_size bytes) -> ${host}:~/$REMOTE_DIR/$dest"
  return 0
}

run_once() {
  mkdir -p "$IN" "$STATE"
  chmod 700 "$IN" 2>/dev/null || true
  if [ ! -f "$STATE/since" ]; then
    date +%s > "$STATE/since"
  fi
  SINCE=$(cat "$STATE/since" 2>/dev/null || echo 0)
  case "$SINCE" in
    ''|*[!0-9]*) SINCE=0;;
  esac

  LOCK="$STATE/lock"
  if ! mkdir "$LOCK" 2>/dev/null; then
    old=$(cat "$LOCK/pid" 2>/dev/null || true)
    if [ -n "$old" ] && kill -0 "$old" 2>/dev/null; then
      exit 0
    fi
    rm -rf "$LOCK"
    mkdir "$LOCK" 2>/dev/null || exit 0
  fi
  echo $$ > "$LOCK/pid"
  trap 'rm -rf "$LOCK"' EXIT

  return_strays

  CAND_FILES=""
  CAND_SIGS=""
  for f in "$IN"/*; do
    consider "$f" inbox
  done
  for f in "$DESKTOP"/Screen\ Recording\ *; do
    consider "$f" desk
  done

  # Drop the leading newline from the collectors.
  CAND_FILES=$(printf '%s' "$CAND_FILES" | sed '1{/^$/d;}')
  CAND_SIGS=$(printf '%s' "$CAND_SIGS" | sed '1{/^$/d;}')
  if [ -z "$CAND_FILES" ]; then
    refresh_runs ""
    exit 0
  fi

  if [ "$STABILITY" -gt 0 ]; then
    sleep "$STABILITY"
  fi

  if [ -n "$FAKE" ]; then
    host="fake"
  else
    host=$(resolve_lan_ip | tr -d '[:space:]')
    [ -n "$host" ] || host=$(resolve_tailnet | tr -d '[:space:]')
  fi
  if [ -z "$host" ]; then
    # Said once per wait, not every 30 seconds.
    if [ ! -f "$STATE/waiting" ]; then
      log "alexus is not on the LAN and the tailnet login did not get through; keeping the recordings local and retrying"
      : > "$STATE/waiting"
    fi
    exit 0
  fi
  rm -f "$STATE/waiting"
  if [ -z "$FAKE" ] && [ ! -f "$KEY" ]; then
    log "missing $KEY; keeping the recordings local"
    exit 0
  fi

  # Filenames may contain spaces, not newlines. Read from a file so `break` stays in this shell.
  printf '%s\n' "$CAND_FILES" > "$STATE/cand.files"
  printf '%s\n' "$CAND_SIGS" > "$STATE/cand.sigs"
  i=0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    i=$((i + 1))
    sig=$(sed -n "${i}p" "$STATE/cand.sigs")
    ship_one "$f" "$sig" "$host" || break
  done < "$STATE/cand.files"
  rm -f "$STATE/cand.files" "$STATE/cand.sigs"
  refresh_runs "$host"
}

install_agent() {
  mkdir -p "$IN" "$STATE" "$HOME/Library/Logs" "$HOME/Library/LaunchAgents"
  chmod 700 "$IN" 2>/dev/null || true
  if [ ! -f "$STATE/since" ]; then
    date +%s > "$STATE/since"
  fi
  defaults write com.apple.screencapture location -string "$IN"
  src="$(cd "$(dirname "$0")" && pwd)/co.rgnrk.screen-recording-ship.plist"
  dest="$HOME/Library/LaunchAgents/co.rgnrk.screen-recording-ship.plist"
  sed "s|@HOME@|$HOME|g" "$src" > "$dest"   # the plist is a template
  uid=$(id -u)
  launchctl bootout "gui/$uid" "$dest" 2>/dev/null || \
    launchctl bootout "gui/$uid/co.rgnrk.screen-recording-ship" 2>/dev/null || true
  launchctl bootstrap "gui/$uid" "$dest"
  launchctl enable "gui/$uid/co.rgnrk.screen-recording-ship" 2>/dev/null || true
  log "installed. New recordings save to $IN and ship to alexus:~/$REMOTE_DIR"
  printf 'save location: %s\n' "$(defaults read com.apple.screencapture location)"
  printf 'launch agent: gui/%s/co.rgnrk.screen-recording-ship\n' "$uid"
}

case "${1:-}" in
  install) install_agent ;;
  once|"") run_once ;;
  *) echo "usage: screen-recording-ship.sh [install]" >&2; exit 2 ;;
esac
