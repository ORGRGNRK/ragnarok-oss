# loop-lib.sh — shared by bin/heimdall-edit and bin/ragnarok-heal (source it; bash 3.2 compatible).
# Fixes from the 2026-11-01 break-test report:
#   A7  one long-running logger process (not one python3 per output line)
#   A6  stream() keeps a last line that has no trailing newline
#   A3  the lock holds the owner's PID; a lock left by a dead process is cleared (with its worktree/branch leftovers)
#   A4  INT/TERM/HUP run the caller's cleanup, not only EXIT
# From the 2026-11-11 report:
#   N5/N8  each stream() step runs in its own process group and is waited on in the background, so Stop (TERM) acts
#          at once: the trap kills the whole group (the AI and anything it started), then cleans up
#   N3/N4  see loop_lock
#   A8     STREAM_STDIN=FILE feeds a file to the step's stdin (a long prompt goes there, not into the argument list)
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
  local step=$1 in=/dev/null rc; shift
  [ -n "${STREAM_STDIN:-}" ] && in="$STREAM_STDIN"
  LOOP_PGFILE="$(mktemp "${TMPDIR:-/tmp}/loop-pg.XXXXXX")"
  # perl writes its pid (= the new group id) to LOOP_PGFILE, starts a process group, then becomes the command
  { /usr/bin/perl -e 'open(F, ">", shift) and print(F $$) and close(F); setpgrp(0, 0); exec { $ARGV[0] } @ARGV or exit 127' \
      "$LOOP_PGFILE" "$@" <"$in" 2>&1; echo $? > "$LOOP_PGFILE.rc"; } \
    | while IFS= read -r line || [ -n "$line" ]; do log "$step" 1 "$line"; printf '%s\n' "$line"; done &
  wait $!   # a signal interrupts this wait, so the trap runs now instead of when the command ends
  rc="$(cat "$LOOP_PGFILE.rc" 2>/dev/null)"
  rm -f "$LOOP_PGFILE" "$LOOP_PGFILE.rc"; LOOP_PGFILE=""
  return "${rc:-1}"
}

loop_kill_step() {  # TERM the running step's whole process group, KILL it if still there after 2 s
  local pg i
  [ -n "${LOOP_PGFILE:-}" ] && pg="$(cat "$LOOP_PGFILE" 2>/dev/null)"
  [ -n "${pg:-}" ] || return 0
  kill -TERM -- "-$pg" 2>/dev/null || return 0
  for i in 1 2 3 4 5 6 7 8 9 10; do kill -0 -- "-$pg" 2>/dev/null || break; sleep 0.2; done
  kill -KILL -- "-$pg" 2>/dev/null
  rm -f "$LOOP_PGFILE" "$LOOP_PGFILE.rc"; LOOP_PGFILE=""
}

# loop_lock DIR STALE_FN: take DIR as a lock holding our PID and its start time. If it exists but its owner is gone,
# run STALE_FN (remove the dead run's worktree/branch), clear it and take it. Exits 3 if a live run holds it.
#   N3: only one run may clear a stale lock (it must first make DIR.breaking); the others say a run is going
#   N4: the PID's start time is saved too, so a PID reused by an unrelated program doesn't block edits forever
loop_lock_alive() {  # DIR: true if the run that took this lock is still the one running
  local owner started
  owner="$(sed -n 1p "$1/pid" 2>/dev/null)"; started="$(sed -n 2p "$1/pid" 2>/dev/null)"
  if [ -z "$owner" ]; then   # no pid yet: a run is between mkdir and writing it, unless the lock is over a minute old
    [ -z "$(find "$1" -maxdepth 0 -mmin +1 2>/dev/null)" ]; return
  fi
  kill -0 "$owner" 2>/dev/null || return 1
  [ -z "$started" ] || [ "$(ps -o lstart= -p "$owner" 2>/dev/null)" = "$started" ]
}

loop_lock() {
  local dir=$1 stale_fn=$2 me
  me="$(basename "$0")"
  mkdir -p "$(dirname "$dir")"
  if ! mkdir "$dir" 2>/dev/null; then
    if loop_lock_alive "$dir"; then
      echo "$me: another run is going (pid $(sed -n 1p "$dir/pid" 2>/dev/null)). Wait for it to finish." >&2; exit 3
    fi
    [ -n "$(find "$dir.breaking" -maxdepth 0 -mmin +1 2>/dev/null)" ] && rmdir "$dir.breaking" 2>/dev/null
    mkdir "$dir.breaking" 2>/dev/null || { echo "$me: another run is starting. Wait for it to finish." >&2; exit 3; }
    if loop_lock_alive "$dir"; then   # someone took it between our two looks
      rmdir "$dir.breaking"; echo "$me: another run is going. Wait for it to finish." >&2; exit 3
    fi
    "$stale_fn" "$(sed -n 1p "$dir/pid" 2>/dev/null)"
    rm -rf "$dir"
    if ! mkdir "$dir" 2>/dev/null; then rmdir "$dir.breaking"; echo "$me: couldn't take the lock $dir" >&2; exit 3; fi
    rmdir "$dir.breaking"
    LOOP_CLEANED_STALE=1
  fi
  printf '%s\n%s\n' "$$" "$(ps -o lstart= -p $$ 2>/dev/null)" > "$dir/pid"
  LOOP_LOCK="$dir"
  trap 'loop_on_exit' EXIT
  trap 'loop_on_signal' INT TERM HUP
}

loop_on_signal() {
  loop_kill_step
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
