#!/bin/bash
# Exercises screen-recording-ship.sh against a fake alexus. No network.
set -e
cd "$(dirname "$0")"
ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT
IN="$ROOT/in"
DESK="$ROOT/desk"
STATE="$ROOT/state"
FAKE="$ROOT/remote"
LOG="$ROOT/log"
mkdir -p "$IN" "$DESK" "$STATE"
NOW=$(date +%s)
echo $((NOW - 3600)) > "$STATE/since"

run() {
  SCREEN_SHIP_IN="$IN" \
  SCREEN_SHIP_DESKTOP="$DESK" \
  SCREEN_SHIP_STATE="$STATE" \
  SCREEN_SHIP_LOG="$LOG" \
  SCREEN_SHIP_FAKE_DIR="$FAKE" \
  SCREEN_SHIP_STABILITY="${1:-0}" \
  /bin/bash ./screen-recording-ship.sh
}

# Inbox clip is old enough. It ships and the local file goes.
printf 'hello-recording' > "$IN/clip.mov"
touch -t 202001010000 "$IN/clip.mov"
run 0
test ! -e "$IN/clip.mov"
shipped=$(find "$FAKE" -type f ! -name manifest.tsv)
test "$(cat "$shipped")" = "hello-recording"
test "$(stat -f %z "$shipped")" = "15"
grep -q 'sent clip.mov' "$LOG"

# A file still being written (mtime is now, stability window 30s) stays.
printf 'still-going' > "$IN/live.mov"
run 30
test -f "$IN/live.mov"
test "$(find "$FAKE" -type f ! -name manifest.tsv | wc -l | tr -d ' ')" = "1"

# Desktop: an old Screen Recording stays. A new one ships. A random movie stays.
printf 'old-desk' > "$DESK/Screen Recording old.mov"
touch -t 202001010000 "$DESK/Screen Recording old.mov"
printf 'new-desk' > "$DESK/Screen Recording new.mov"
printf 'nope' > "$DESK/holiday.mov"
run 0
test -f "$DESK/Screen Recording old.mov"
test ! -e "$DESK/Screen Recording new.mov"
test -f "$DESK/holiday.mov"
find "$FAKE" -type f ! -name manifest.tsv -exec cat {} + | grep -q 'new-desk'

# A screenshot in the inbox goes back to the Desktop and is not shipped. An existing Desktop file is not overwritten.
printf 'png-bytes' > "$IN/Screenshot a.png"
touch -t 202001010000 "$IN/Screenshot a.png"
printf 'mine' > "$DESK/Screenshot b.png"
printf 'other' > "$IN/Screenshot b.png"
touch -t 202001010000 "$IN/Screenshot b.png"
run 0
test ! -e "$IN/Screenshot a.png"
test "$(cat "$DESK/Screenshot a.png")" = "png-bytes"
test "$(cat "$DESK/Screenshot b.png")" = "mine"
test -f "$IN/Screenshot b.png"
test -z "$(find "$FAKE" -name '*Screenshot*')"
rm -f "$IN/Screenshot b.png"

# Size mismatch: partial remote is removed, local file stays.
printf 'full-bytes' > "$IN/bad.mov"
touch -t 202001010000 "$IN/bad.mov"
SCREEN_SHIP_IN="$IN" SCREEN_SHIP_DESKTOP="$DESK" SCREEN_SHIP_STATE="$STATE" \
  SCREEN_SHIP_LOG="$LOG" SCREEN_SHIP_FAKE_DIR="$FAKE" SCREEN_SHIP_STABILITY=0 \
  SCREEN_SHIP_FAKE_SHORT=1 /bin/bash ./screen-recording-ship.sh
test -f "$IN/bad.mov"
test -z "$(find "$FAKE" -name '*bad.mov' -type f)"
grep -q 'size mismatch for bad.mov' "$LOG"

# Not on the LAN: nothing is removed.
printf 'queued' > "$IN/queued.mov"
touch -t 202001010000 "$IN/queued.mov"
SCREEN_SHIP_IN="$IN" SCREEN_SHIP_DESKTOP="$DESK" SCREEN_SHIP_STATE="$STATE" \
  SCREEN_SHIP_LOG="$LOG" SCREEN_SHIP_FAKE_DIR= SCREEN_SHIP_STABILITY=0 \
  SCREEN_SHIP_SKIP_RESOLVE=1 /bin/bash ./screen-recording-ship.sh
test -f "$IN/queued.mov"
grep -q 'not on the LAN' "$LOG"
test -f "$STATE/waiting"

# The run record that overlaps the recording is copied next to it. One that
# ended earlier is not. A second pass does not make a second copy.
# Times use this machine's offset. The recording name is local wall time,
# and the shipper attaches date +%z, so a fixed -0800 would miss the run
# when the test is not in Pacific time.
AG="$ROOT/agents"
off=$(date +%z)
mkdir -p "$AG/20261111-125032-a36b31" "$AG/old-run"
printf '%s\n' "{\"id\":\"20261111-125032-a36b31\",\"started\":\"2026-11-11T12:50:32${off}\",\"ended\":\"2026-11-11T13:16:50${off}\",\"plan\":[],\"actions\":[]}" \
  > "$AG/20261111-125032-a36b31/state.json"
printf '%s\n' "{\"id\":\"old-run\",\"started\":\"2026-11-11T12:00:00${off}\",\"ended\":\"2026-11-11T12:40:00${off}\",\"plan\":[],\"actions\":[]}" \
  > "$AG/old-run/state.json"
printf 'on-video' > "$IN/Screen Recording 2026-11-11 at 12.50.23 PM.mov"
touch -t 202001010000 "$IN/Screen Recording 2026-11-11 at 12.50.23 PM.mov"
SCREEN_SHIP_IN="$IN" SCREEN_SHIP_DESKTOP="$DESK" SCREEN_SHIP_STATE="$STATE" \
  SCREEN_SHIP_LOG="$LOG" SCREEN_SHIP_FAKE_DIR="$FAKE" SCREEN_SHIP_STABILITY=0 \
  SCREEN_SHIP_AGENTS="$AG" SCREEN_SHIP_DURATION_S=1209.455 \
  /bin/bash ./screen-recording-ship.sh
test ! -e "$IN/Screen Recording 2026-11-11 at 12.50.23 PM.mov"
clock=$(find "$FAKE/runs" -name clock.json)
test -n "$clock"
grep -q "12:50:23${off}" "$clock"
states=$(find "$FAKE/runs" -name '*.json' ! -name clock.json)
test "$(printf '%s\n' "$states" | wc -l | tr -d ' ')" = "1"
grep -q '20261111-125032-a36b31' "$states"
# Again, with nothing new to ship: still one run record.
SCREEN_SHIP_IN="$IN" SCREEN_SHIP_DESKTOP="$DESK" SCREEN_SHIP_STATE="$STATE" \
  SCREEN_SHIP_LOG="$LOG" SCREEN_SHIP_FAKE_DIR="$FAKE" SCREEN_SHIP_STABILITY=0 \
  SCREEN_SHIP_AGENTS="$AG" SCREEN_SHIP_DURATION_S=1209.455 \
  /bin/bash ./screen-recording-ship.sh
states=$(find "$FAKE/runs" -name '*.json' ! -name clock.json)
test "$(printf '%s\n' "$states" | wc -l | tr -d ' ')" = "1"

# A run that starts after the recording ended is not copied, even though
# its state.json is newer than the last check.
mkdir -p "$AG/20261111-140000-later"
printf '%s\n' "{\"id\":\"20261111-140000-later\",\"started\":\"2026-11-11T14:00:00${off}\",\"ended\":\"2026-11-11T14:30:00${off}\",\"plan\":[],\"actions\":[]}" \
  > "$AG/20261111-140000-later/state.json"
SCREEN_SHIP_IN="$IN" SCREEN_SHIP_DESKTOP="$DESK" SCREEN_SHIP_STATE="$STATE" \
  SCREEN_SHIP_LOG="$LOG" SCREEN_SHIP_FAKE_DIR="$FAKE" SCREEN_SHIP_STABILITY=0 \
  SCREEN_SHIP_AGENTS="$AG" SCREEN_SHIP_DURATION_S=1209.455 \
  /bin/bash ./screen-recording-ship.sh
test -z "$(find "$FAKE/runs" -name '20261111-140000-later.json')"
states=$(find "$FAKE/runs" -name '*.json' ! -name clock.json)
test "$(printf '%s\n' "$states" | wc -l | tr -d ' ')" = "1"

# The overlapping record, once it changes, is sent again.
printf '%s\n' "{\"id\":\"20261111-125032-a36b31\",\"started\":\"2026-11-11T12:50:32${off}\",\"ended\":\"2026-11-11T13:16:50${off}\",\"plan\":[],\"actions\":[],\"note\":\"resent-marker\"}" \
  > "$AG/20261111-125032-a36b31/state.json"
SCREEN_SHIP_IN="$IN" SCREEN_SHIP_DESKTOP="$DESK" SCREEN_SHIP_STATE="$STATE" \
  SCREEN_SHIP_LOG="$LOG" SCREEN_SHIP_FAKE_DIR="$FAKE" SCREEN_SHIP_STABILITY=0 \
  SCREEN_SHIP_AGENTS="$AG" SCREEN_SHIP_DURATION_S=1209.455 \
  /bin/bash ./screen-recording-ship.sh
grep -q 'resent-marker' "$FAKE"/runs/*/20261111-125032-a36b31.json
states=$(find "$FAKE/runs" -name '*.json' ! -name clock.json)
test "$(printf '%s\n' "$states" | wc -l | tr -d ' ')" = "1"

# A failed upload must not mark the record checked. The file did not change
# again, and the next pass still sends it.
printf '%s\n' "{\"id\":\"20261111-125032-a36b31\",\"started\":\"2026-11-11T12:50:32${off}\",\"ended\":\"2026-11-11T13:16:50${off}\",\"plan\":[],\"actions\":[],\"note\":\"retry-marker\"}" \
  > "$AG/20261111-125032-a36b31/state.json"
checked_before=$(stat -f %m "$STATE/runs-checked")
SCREEN_SHIP_FAIL_UPLOADS=1 \
  SCREEN_SHIP_IN="$IN" SCREEN_SHIP_DESKTOP="$DESK" SCREEN_SHIP_STATE="$STATE" \
  SCREEN_SHIP_LOG="$LOG" SCREEN_SHIP_FAKE_DIR="$FAKE" SCREEN_SHIP_STABILITY=0 \
  SCREEN_SHIP_AGENTS="$AG" SCREEN_SHIP_DURATION_S=1209.455 \
  /bin/bash ./screen-recording-ship.sh
if grep -q 'retry-marker' "$FAKE"/runs/*/20261111-125032-a36b31.json; then
  echo "failed upload was stored" >&2
  exit 1
fi
test "$(stat -f %m "$STATE/runs-checked")" = "$checked_before"
SCREEN_SHIP_IN="$IN" SCREEN_SHIP_DESKTOP="$DESK" SCREEN_SHIP_STATE="$STATE" \
  SCREEN_SHIP_LOG="$LOG" SCREEN_SHIP_FAKE_DIR="$FAKE" SCREEN_SHIP_STABILITY=0 \
  SCREEN_SHIP_AGENTS="$AG" SCREEN_SHIP_DURATION_S=1209.455 \
  /bin/bash ./screen-recording-ship.sh
grep -q 'retry-marker' "$FAKE"/runs/*/20261111-125032-a36b31.json
test "$(stat -f %m "$STATE/runs-checked")" -gt "$checked_before"

# A rewrite that lands before the checkpoint is touched used to look
# older than runs-checked and was never sent again. The bytes differ
# from the last upload, so this pass sends them. (stale-checkpoint)
printf '%s\n' "{\"id\":\"20261111-125032-a36b31\",\"started\":\"2026-11-11T12:50:32${off}\",\"ended\":\"2026-11-11T13:16:50${off}\",\"plan\":[],\"actions\":[],\"note\":\"stale-checkpoint\"}" \
  > "$AG/20261111-125032-a36b31/state.json"
touch "$STATE/runs-checked"
SCREEN_SHIP_IN="$IN" SCREEN_SHIP_DESKTOP="$DESK" SCREEN_SHIP_STATE="$STATE" \
  SCREEN_SHIP_LOG="$LOG" SCREEN_SHIP_FAKE_DIR="$FAKE" SCREEN_SHIP_STABILITY=0 \
  SCREEN_SHIP_AGENTS="$AG" SCREEN_SHIP_DURATION_S=1209.455 \
  /bin/bash ./screen-recording-ship.sh
grep -q 'stale-checkpoint' "$FAKE"/runs/*/20261111-125032-a36b31.json

# One run overlaps two recordings. The upload fails for the first
# destination only. Remembering the hash by run id alone would treat
# the failed destination as sent. (partial-fail)
printf 'second-recording' > "$IN/Screen Recording 2026-11-11 at 1.00.00 PM.mov"
touch -t 202001010000 "$IN/Screen Recording 2026-11-11 at 1.00.00 PM.mov"
SCREEN_SHIP_IN="$IN" SCREEN_SHIP_DESKTOP="$DESK" SCREEN_SHIP_STATE="$STATE" \
  SCREEN_SHIP_LOG="$LOG" SCREEN_SHIP_FAKE_DIR="$FAKE" SCREEN_SHIP_STABILITY=0 \
  SCREEN_SHIP_AGENTS="$AG" SCREEN_SHIP_DURATION_S=1209.455 \
  /bin/bash ./screen-recording-ship.sh
test ! -e "$IN/Screen Recording 2026-11-11 at 1.00.00 PM.mov"
printf '%s\n' "{\"id\":\"20261111-125032-a36b31\",\"started\":\"2026-11-11T12:50:32${off}\",\"ended\":\"2026-11-11T13:16:50${off}\",\"plan\":[],\"actions\":[],\"note\":\"partial-fail\"}" \
  > "$AG/20261111-125032-a36b31/state.json"
checked_partial=$(stat -f %m "$STATE/runs-checked")
SCREEN_SHIP_FAIL_UPLOADS=1 \
  SCREEN_SHIP_IN="$IN" SCREEN_SHIP_DESKTOP="$DESK" SCREEN_SHIP_STATE="$STATE" \
  SCREEN_SHIP_LOG="$LOG" SCREEN_SHIP_FAKE_DIR="$FAKE" SCREEN_SHIP_STABILITY=0 \
  SCREEN_SHIP_AGENTS="$AG" SCREEN_SHIP_DURATION_S=1209.455 \
  /bin/bash ./screen-recording-ship.sh
python3 - "$FAKE" <<'PY'
import base64, pathlib, sys
fake = pathlib.Path(sys.argv[1])
got = {}
for line in (fake / "manifest.tsv").read_text().splitlines():
    dest, b64, *_ = line.split("\t")
    name = base64.b64decode(b64).decode()
    if "12.50.23" not in name and "1.00.00" not in name:
        continue
    text = (fake / "runs" / dest.rsplit(".", 1)[0] / "20261111-125032-a36b31.json").read_text()
    got[name] = "partial-fail" in text
early = [name for name in got if "12.50.23" in name][0]
late = [name for name in got if "1.00.00" in name][0]
assert got[early] is False, got
assert got[late] is True, got
print("partial upload left the first recording pending")
PY
test "$(stat -f %m "$STATE/runs-checked")" = "$checked_partial"
SCREEN_SHIP_IN="$IN" SCREEN_SHIP_DESKTOP="$DESK" SCREEN_SHIP_STATE="$STATE" \
  SCREEN_SHIP_LOG="$LOG" SCREEN_SHIP_FAKE_DIR="$FAKE" SCREEN_SHIP_STABILITY=0 \
  SCREEN_SHIP_AGENTS="$AG" SCREEN_SHIP_DURATION_S=1209.455 \
  /bin/bash ./screen-recording-ship.sh
python3 - "$FAKE" <<'PY'
import base64, pathlib, sys
fake = pathlib.Path(sys.argv[1])
for line in (fake / "manifest.tsv").read_text().splitlines():
    dest, b64, *_ = line.split("\t")
    name = base64.b64decode(b64).decode()
    if "12.50.23" not in name and "1.00.00" not in name:
        continue
    text = (fake / "runs" / dest.rsplit(".", 1)[0] / "20261111-125032-a36b31.json").read_text()
    assert "partial-fail" in text, name
print("partial-fail reached both recordings")
PY

echo "screen-recording-ship tests passed"
