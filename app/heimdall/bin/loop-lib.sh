# loop-lib.sh — shared by bin/heimdall-edit and bin/ragnarok-heal (source it; bash 3.2 compatible).
# Fixes from the 2026-11-01 break-test report:
#   A7  one long-running logger process (not one python3 per output line)
#   A6  stream() keeps a last line that has no trailing newline
#   A3  the lock holds the owner's PID; a lock left by a dead process is cleared (with its worktree/branch leftovers)
#   A4  INT/TERM/HUP run the caller's cleanup, not only EXIT
#
# The caller sets: LOG (jsonl path), LOGFIELDS (a JSON object fragment, e.g. '"edit":"ID","who":"claude"'),
# and defines cleanup(). Then: loop_logger_start; loop_lock <dir> <stale-cleanup-function>; ... log step ok detail.

loop_logger_start() {
  LOOP_FIFO="$(mktemp -u "${TMPDIR:-/tmp}/loop-log.XXXXXX")"
  mkfifo -m 600 "$LOOP_FIFO" || return 1
  # records are step \0 ok \0 detail \0; one python process writes one JSON line per record, flushing each
  /usr/bin/python3 -u -c '
import json, sys, datetime, os
fields = json.loads("{" + sys.argv[2] + "}")
out = open(sys.argv[1], "a", buffering=1)
os.chmod(sys.argv[1], 0o600)
buf = b""
with open(sys.argv[3], "rb", buffering=0) as f:
    while True:
        chunk = f.read(65536)
        if not chunk: break
        buf += chunk
        parts = buf.split(b"\0")
        while len(parts) >= 4:
            step, ok, detail = (p.decode("utf-8", "replace") for p in parts[:3])
            parts = parts[3:]
            rec = {"ts": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")}
            rec.update(fields); rec.update({"step": step, "ok": ok == "1", "detail": detail[-4000:]})
            out.write(json.dumps(rec) + "\n")
        buf = b"\0".join(parts)
' "$LOG" "$LOGFIELDS" "$LOOP_FIFO" &
  LOOP_LOGGER_PID=$!
  exec 7>"$LOOP_FIFO"
  rm -f "$LOOP_FIFO"
}

log() {  # step ok detail
  printf '%s\0%s\0%s\0' "$1" "$2" "${3:-}" >&7 2>/dev/null || true
}

loop_logger_stop() {
  exec 7>&- 2>/dev/null
  [ -n "${LOOP_LOGGER_PID:-}" ] && wait "$LOOP_LOGGER_PID" 2>/dev/null
  LOOP_LOGGER_PID=""
}

stream() {  # step command...: every output line to the log and stdout; returns the command's exit code
  local step=$1; shift
  "$@" </dev/null 2>&1 | while IFS= read -r line || [ -n "$line" ]; do log "$step" 1 "$line"; printf '%s\n' "$line"; done
  return "${PIPESTATUS[0]}"
}

# loop_lock DIR STALE_FN: take DIR as a lock holding our PID. If it exists but its owner is gone, run STALE_FN
# (remove the dead run's worktree/branch), clear it and take it. Exits 3 if a live run holds it.
loop_lock() {
  local dir=$1 stale_fn=$2 owner
  mkdir -p "$(dirname "$dir")"
  if ! mkdir "$dir" 2>/dev/null; then
    owner="$(cat "$dir/pid" 2>/dev/null)"
    if [ -n "$owner" ] && kill -0 "$owner" 2>/dev/null; then
      echo "$(basename "$0"): another run is going (pid $owner). Wait for it to finish." >&2; exit 3
    fi
    "$stale_fn" "$owner"
    rm -rf "$dir"
    mkdir "$dir" 2>/dev/null || { echo "$(basename "$0"): couldn't take the lock $dir" >&2; exit 3; }
    LOOP_CLEANED_STALE=1
  fi
  echo $$ > "$dir/pid"
  LOOP_LOCK="$dir"
  trap 'loop_on_exit' EXIT
  trap 'loop_on_signal' INT TERM HUP
}

loop_on_signal() {
  log interrupted 0 "stopped by a signal; cleaned up the staging copy"
  type cleanup >/dev/null 2>&1 && cleanup
  exit 130
}

loop_on_exit() {
  loop_logger_stop
  [ -n "${LOOP_LOCK:-}" ] && rm -rf "$LOOP_LOCK"
}

# one-line, single-record text (for files read line by line, e.g. update-ready)
oneline() { printf '%s' "$1" | tr '\n\r|' '   '; }
