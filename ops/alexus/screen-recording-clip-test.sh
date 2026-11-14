#!/bin/bash
# Exercises screen-recording-clip.py with stand-in ffmpeg and ffprobe. No network.
set -e
cd "$(dirname "$0")"
ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT
RAW="$ROOT/raw"
OUT="$ROOT/out"
BIN="$ROOT/bin"
AG="$ROOT/agents"
mkdir -p "$RAW" "$OUT" "$BIN" "$AG/20261111-125032-a36b31" "$AG/old-run"
LOG="$ROOT/ffmpeg.log"
touch "$LOG"

cat > "$BIN/ffprobe" <<'EOF'
#!/bin/sh
for a in "$@"; do
  if [ "$a" = "a" ]; then
    exit 0
  fi
done
printf '%s\n' "${FAKE_DURATION:-1209.455}"
EOF
cat > "$BIN/ffmpeg" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$FAKE_FFMPEG_LOG"
out=""
for a in "$@"; do out=$a; done
printf 'fake-mp4' > "$out"
EOF
chmod +x "$BIN/ffprobe" "$BIN/ffmpeg"

STORED="20261111T211324Z_9336_Screen_Recording_2026-11-11_at_12.50.23_PM.mov"
printf 'raw-bytes-do-not-touch' > "$RAW/$STORED"
RAW_SUM=$(shasum -a 256 "$RAW/$STORED" | awk '{print $1}')
ORIG="Screen Recording 2026-11-11 at 12.50.23 PM.mov"
B64=$(printf '%s' "$ORIG" | /usr/bin/base64 | tr -d '\n')
printf '%s\t%s\n' "$STORED" "$B64" > "$RAW/manifest.tsv"

python3 - "$AG/20261111-125032-a36b31/state.json" <<'PY'
import json, sys
json.dump({
  "id": "20261111-125032-a36b31",
  "task": "create a pipeline to allow screen recording to go directly to alexus",
  "started": "2026-11-11T12:50:32-0800",
  "ended": "2026-11-11T13:16:50-0800",
  "handoffs": [
    {"from": "grok", "to": "claude", "at": "2026-11-11T13:09:12-0800"},
  ],
  "plan": [
    {"id": "boot", "step": "Load the rules", "status": "completed"},
    {"id": "verify", "step": "Verify the path works and record the fact", "status": "completed"},
  ],
  "actions": [
    {"at": "2026-11-11T12:50:51-0800", "kind": "said",
     "what": "I'll set up a screen-recording path that lands straight on alexus."},
    {"at": "2026-11-11T12:57:39-0800", "kind": "tool",
     "what": "updating the plan boot: completed, survey: completed, design: in_progress"},
    {"at": "2026-11-11T13:00:37-0800", "kind": "tool",
     "what": 'running /usr/bin/ssh -o BatchMode=yes -i "$HOME/.ssh/id_ed25519" sam@alexus true'},
    {"at": "2026-11-11T13:05:52-0800", "kind": "said",
     "what": "The shipper was treating a failed copy as a success. I'm fixing that, then I'll run the tests."},
    {"at": "2026-11-11T13:06:21-0800", "kind": "tool",
     "what": "running ./ops/mac-scripts/screen-recording-ship-test.sh"},
    {"at": "2026-11-11T13:07:36-0800", "kind": "tool",
     "what": "running set -e\nplutil -lint co.rgnrk.screen-recording-ship.plist\n./ops/mac-scripts/screen-recording-ship-test.sh\n/bin/bash ./ops/mac-scripts/screen-recording-ship.sh install"},
    {"at": "2026-11-11T13:07:55-0800", "kind": "tool",
     "what": 'running chmod 700 "$HOME/Screen-Recordings" # drop the two proof files; the pipeline is what stays /usr/bin/ssh -o BatchMode=yes -o ConnectTimeout='},
    {"at": "2026-11-11T13:08:22-0800", "kind": "tool",
     "what": "running ./ops/mac-scripts/screen-recording-ship-test.sh"},
    {"at": "2026-11-11T13:08:59-0800", "kind": "tool",
     "what": "updating the plan build: completed, verify: completed"},
    {"at": "2026-11-11T13:09:11-0800", "kind": "said",
     "what": "Screen recordings from this Mac now copy themselves to alexus."},
    {"at": "2026-11-11T13:14:05-0800", "kind": "tool",
     "what": "step 5 → completed: Verify the path works and record the fact"},
  ],
}, open(sys.argv[1], "w"), indent=2)
PY
cp "$AG/20261111-125032-a36b31/state.json" "$RAW/runs-src.json"
mkdir -p "$RAW/runs/${STORED%.mov}"
cp "$AG/20261111-125032-a36b31/state.json" "$RAW/runs/${STORED%.mov}/20261111-125032-a36b31.json"
# A run that finished before the recording must not be cut.
printf '%s\n' '{"id":"old-run","started":"2026-11-11T12:00:00-0800","ended":"2026-11-11T12:40:00-0800","plan":[],"actions":[]}' \
  > "$RAW/runs/${STORED%.mov}/old-run.json"

export PATH="$BIN:$PATH"
export FAKE_FFMPEG_LOG="$LOG"
export FAKE_DURATION=1209.455
export SCREEN_CLIP_RAW="$RAW"
export SCREEN_CLIP_OUT="$OUT"
export SCREEN_CLIP_FFMPEG="$BIN/ffmpeg"
export SCREEN_CLIP_FFPROBE="$BIN/ffprobe"
printf 'font' > "$ROOT/font.ttf"
export SCREEN_CLIP_FONT="$ROOT/font.ttf"

# No clock file: the start comes from the manifest name and the run's offset.
python3 ./screen-recording-clip.py --plan > "$ROOT/plan.json"
python3 - "$ROOT/plan.json" <<'PY'
import json, sys
reports = json.load(open(sys.argv[1]))
assert len(reports) == 1, reports
r = reports[0]
parts = r["parts"]
assert len(parts) > 2, parts
assert parts[0]["part"] == "ask" and parts[0]["file_start_s"] < 60
assert parts[-1]["file_start_s"] >= r["duration_s"] - 120
by = {}
for p in parts:
    by.setdefault(p["part"], []).append(p)
    assert p["caption"] and ":" in p["caption"]
assert "verification" in by and "how_it_worked" in by and "plan" in by and "handoff" in by and "said" in by
ver = by["verification"][0]
assert ver["receipts"][0]["at"].startswith("2026-11-11T13:06:21")
assert "screen-recording-ship-test" in ver["receipts"][0]["what"]
assert "verify: completed" not in ver["receipts"][0]["what"]
how = by["how_it_worked"][0]
assert how["receipts"][0]["at"].startswith("2026-11-11T13:07:36"), how
assert "/bin/bash ./ops/mac-scripts/screen-recording-ship.sh install" in how["receipts"][0]["what"]

assert all("proof files" not in x["what"] for x in how["receipts"]), how
assert all("chmod 700" not in x["what"] for x in how["receipts"]), how
assert "plutil" not in how["caption"]
plan = by["plan"]
assert any("boot" in (p.get("plan_step") or "") for p in plan)
assert any("verify: completed" in x["what"] for p in plan for x in p["receipts"])
assert all(not x["at"].startswith("2026-11-11T13:14:05") for p in parts for x in p["receipts"])
assert by["handoff"][0]["receipts"][0]["at"].startswith("2026-11-11T13:09:12")
# The failure-then-fix line is its own piece. The closing line sits with the handoff.
assert any("failed copy" in x["what"] for p in by["said"] for x in p["receipts"])
assert any("copy themselves" in x["what"] for p in by["handoff"] for x in p["receipts"])
missing = {m["part"]: m for m in r["missing"]}
assert "end_product" in missing and "end_product" not in by
assert "13:16:50" in missing["end_product"]["reason"]
assert "not on this video" in missing["end_product"]["reason"]
assert "old-run" not in r["runs"]
print("plan ok", len(parts), [p["part"] for p in parts])
PY

python3 ./screen-recording-clip.py --once
SIDE="$OUT/${STORED%.mov}.json"
CLIP="$OUT/${STORED%.mov}.mp4"
test -f "$SIDE"
test -f "$CLIP"
test "$(shasum -a 256 "$RAW/$STORED" | awk '{print $1}')" = "$RAW_SUM"
test -z "$(find "$RAW" -name '*.mp4')"
grep -q libx264 "$LOG"
if grep -E 'h264_nvenc|hevc_nvenc|videotoolbox|qsv' "$LOG"; then
  echo "ffmpeg was asked to use a hardware encoder" >&2
  exit 1
fi
# The raw path is an input, never the file ffmpeg writes.
python3 - "$LOG" "$RAW" "$OUT" <<'PY'
import sys
log, raw, out = sys.argv[1:]
lines = open(log).read().splitlines()
assert lines, "ffmpeg was not called"
for line in lines:
    assert "libx264" in line or "concat" in line, line
    if "libx264" in line:
        assert "drawtext" in line, line
    assert not line.rstrip().endswith(raw) or False
print("ffmpeg argv ok", len(lines))
PY
N1=$(wc -l < "$LOG" | tr -d ' ')
python3 ./screen-recording-clip.py --once
N2=$(wc -l < "$LOG" | tr -d ' ')
test "$N1" = "$N2"
test "$(shasum -a 256 "$RAW/$STORED" | awk '{print $1}')" = "$RAW_SUM"

# The run finishes while the recording is still going: the end product is cut
# from the closing line, and the raw file is still the same bytes.
python3 - "$RAW/runs/${STORED%.mov}/20261111-125032-a36b31.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["ended"] = "2026-11-11T13:09:20-0800"
d["final"] = "Screen recordings from this Mac now copy themselves to alexus."
json.dump(d, open(p, "w"))
PY
python3 ./screen-recording-clip.py --once
N3=$(wc -l < "$LOG" | tr -d ' ')
test "$N3" -gt "$N2"
python3 - "$SIDE" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
ends = [p for p in r["parts"] if p["part"] == "end_product"]
assert len(ends) == 1, r["missing"]
assert "copy themselves" in ends[0]["receipts"][0]["what"]
assert "end_product" not in {m["part"] for m in r["missing"]}
print("end product ok")
PY
test "$(shasum -a 256 "$RAW/$STORED" | awk '{print $1}')" = "$RAW_SUM"

# An early progress line is not the end product. A connectivity ssh is not
# how the work ran; the command that runs the plan's file is.
python3 - <<'PY'
import importlib.util
from datetime import datetime, timedelta, timezone
spec = importlib.util.spec_from_file_location("clip", "screen-recording-clip.py")
clip = importlib.util.module_from_spec(spec)
spec.loader.exec_module(clip)
off = timezone(timedelta(hours=-8))
start = datetime(2026, 11, 11, 12, 50, 23, tzinfo=off)
end = start + timedelta(seconds=1209)
record = {
    "id": "demo-run",
    "task": "build the demo",
    "started": "2026-11-11T12:50:32-0800",
    "ended": "2026-11-11T13:09:00-0800",
    "final": "Starting implementation; nothing works yet.",
    "plan": [{"step": "Show demo.py working", "status": "completed"}],
    "actions": [
        {"at": "2026-11-11T12:51:00-0800", "kind": "said",
         "what": "Starting implementation; nothing works yet."},
        {"at": "2026-11-11T13:05:00-0800", "kind": "tool",
         "what": "running ssh yggdrasil@alexus true"},
        {"at": "2026-11-11T13:06:00-0800", "kind": "tool",
         "what": "running python3 demo.py"},
    ],
}
terms = clip.deliverable_terms(record, record["actions"])
assert clip.demo_score("running python3 demo.py", terms) > 0
assert clip.demo_score("running ssh yggdrasil@alexus true", terms) == 0
parts, missing = clip.choose_parts(record, start, end, 1209)
assert not any(p["part"] == "end_product" for p in parts), parts
assert any(m["part"] == "end_product" for m in missing)
how = [p for p in parts if p["part"] == "how_it_worked"]
assert len(how) == 1, parts
assert any("demo.py" in x["what"] for x in how[0]["receipts"])
assert all("ssh yggdrasil@alexus true" not in x["what"] for x in how[0]["receipts"])
print("progress line and ssh probe rejected")
PY
python3 ./screen-recording-clip.py --once
N4=$(wc -l < "$LOG" | tr -d ' ')
test "$N4" = "$N3"

# install adds one cron line and does not drop the line that was already there.
CRON="$ROOT/cron"
printf '%s\n' '*/15 * * * * /usr/bin/python3 -I /home/sam/.local/bin/log-ship.py' > "$CRON"
SCREEN_CLIP_CRON_FILE="$CRON" python3 ./screen-recording-clip.py --install
SCREEN_CLIP_CRON_FILE="$CRON" python3 ./screen-recording-clip.py --install
test "$(grep -c 'screen-recording-clip.py --once' "$CRON")" = "1"
grep -q 'log-ship.py' "$CRON"

# Narrow no-break space before AM/PM still parses.
NBSP_NAME=$(python3 -c 'print("Screen Recording 2026-11-11 at 12.50.23\u202fPM.mov")')
python3 ./screen-recording-clip.py --clock --name "$NBSP_NAME" --offset -0800 \
  | grep -q '2026-11-11T12:50:23-0800'

# Two demonstrations 35 seconds apart used to be capped from the earlier
# one, so the piece ended before the selected command while the caption
# still named it. The selected command stays inside the piece.
python3 - <<'PY'
import importlib.util
from datetime import timedelta
from pathlib import Path
spec = importlib.util.spec_from_file_location("clip", "screen-recording-clip.py")
clip = importlib.util.module_from_spec(spec)
spec.loader.exec_module(clip)
start = clip.parse_at("2026-11-11T12:50:23-0800")
def at(offset):
    return clip.fmt_at(start + timedelta(seconds=offset))
record = {
    "id": "cap-run",
    "task": "build the demo",
    "started": at(9),
    "ended": at(400),
    "plan": [{"step": "Show demo.py working", "status": "completed"}],
    "actions": [
        {"at": at(30), "kind": "tool", "what": "running python3 demo.py"},
        {"at": at(65), "kind": "tool", "what": "running python3 demo.py"},
    ],
}
report = clip.build_report(Path("clip.mov"), "clip.mov", start, 1209, [record])
how = [p for p in report["parts"] if p["part"] == "how_it_worked"]
assert len(how) == 1, report["parts"]
piece = how[0]
assert piece["file_start_s"] <= piece["anchor_s"] <= piece["file_end_s"], piece
assert abs(piece["anchor_s"] - 65) < 0.01, piece
assert piece["file_end_s"] - piece["file_start_s"] <= 26.01, piece
print("anchor stays inside", piece["file_start_s"], piece["file_end_s"], piece["anchor_s"])
PY

# chmod of the deliverable prepares the file. It does not run it, so it
# is not the live demonstration.
python3 - <<'PY'
import importlib.util
from datetime import timedelta
spec = importlib.util.spec_from_file_location("clip", "screen-recording-clip.py")
clip = importlib.util.module_from_spec(spec)
spec.loader.exec_module(clip)
start = clip.parse_at("2026-11-11T12:50:23-0800")
end = start + timedelta(seconds=1209)
record = {
    "id": "chmod-run",
    "task": "build the demo",
    "started": clip.fmt_at(start + timedelta(seconds=9)),
    "ended": clip.fmt_at(start + timedelta(seconds=400)),
    "plan": [{"step": "Show demo.py working", "status": "completed"}],
    "actions": [{
        "at": clip.fmt_at(start + timedelta(seconds=40)),
        "kind": "tool",
        "what": "running chmod 700 demo.py",
    }],
}
parts, missing = clip.choose_parts(record, start, end, 1209)
assert not any(p["part"] == "how_it_worked" for p in parts), parts
assert all("Live send" not in p.get("caption", "") for p in parts)
assert any(m["part"] == "how_it_worked" for m in missing), missing
assert clip.demo_score("running chmod 700 demo.py", clip.deliverable_terms(record, record["actions"])) == 0
print("chmod is not a demonstration")
PY

# plutil -lint checks syntax. It is not the pipeline running, even when
# the plist name matches the plan. A later lint must not beat an earlier run.
python3 - <<'PY'
import importlib.util
from datetime import timedelta
spec = importlib.util.spec_from_file_location("clip", "screen-recording-clip.py")
clip = importlib.util.module_from_spec(spec)
spec.loader.exec_module(clip)
start = clip.parse_at("2026-11-11T12:50:23-0800")
end = start + timedelta(seconds=1209)
def at(offset):
    return clip.fmt_at(start + timedelta(seconds=offset))
lint = "running set -e plutil -lint /Users/sam/Developer/ragnarok/ops/mac-scripts/co.rgnrk.screen-recording-ship.plist"
record = {
    "id": "lint-run",
    "task": "ship screen recordings to alexus",
    "started": at(9),
    "ended": at(400),
    "plan": [{"step": "Run screen-recording-ship.sh", "status": "completed"}],
    "actions": [
        {"at": at(30), "kind": "tool", "what": "running ./ops/mac-scripts/screen-recording-ship.sh"},
        {"at": at(50), "kind": "tool", "what": lint},
    ],
}
terms = clip.deliverable_terms(record, record["actions"])
assert clip.demo_score(lint, terms) == 0, clip.demo_score(lint, terms)
assert clip.demo_score("running ./ops/mac-scripts/screen-recording-ship.sh", terms) > 0
parts, missing = clip.choose_parts(record, start, end, 1209)
how = [p for p in parts if p["part"] == "how_it_worked"]
assert len(how) == 1, parts
assert any("screen-recording-ship.sh" in x["what"] and "plutil" not in x["what"] for x in how[0]["receipts"]), how
assert "plutil" not in how[0]["caption"]
assert "Live send" not in how[0]["caption"]
print("plist lint is not the run")
PY

# A lock directory left by a killed pass must not block the next one.
# A live holder still does. The kernel drops the lock when that holder dies.
rm -rf "$OUT/.lock"
mkdir "$OUT/.lock"
echo $$ > "$OUT/.lock/pid"
python3 ./screen-recording-clip.py --once >"$ROOT/lock-live.out" 2>"$ROOT/lock-live.err" || true
grep -q 'already running' "$ROOT/lock-live.err"
rm -rf "$OUT/.lock"
mkdir "$OUT/.lock"
python3 ./screen-recording-clip.py --once >"$ROOT/lock-stale.out" 2>"$ROOT/lock-stale.err"
if grep -q 'already running' "$ROOT/lock-stale.err"; then
  echo "stale lock directory blocked a later pass" >&2
  exit 1
fi
test ! -d "$OUT/.lock"
test -f "$OUT/.lock"
python3 - "$OUT/.lock" <<'PY' &
import fcntl, os, sys, time
fd = os.open(sys.argv[1], os.O_RDWR)
fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
open(sys.argv[1] + ".held", "w").close()
time.sleep(30)
PY
holder=$!
i=0
while [ ! -f "$OUT/.lock.held" ]; do
  i=$((i + 1))
  [ "$i" -lt 50 ] || { echo "holder did not take the lock" >&2; exit 1; }
  sleep 0.1
done
python3 ./screen-recording-clip.py --once >"$ROOT/lock-held.out" 2>"$ROOT/lock-held.err" || true
grep -q 'already running' "$ROOT/lock-held.err"
kill -9 "$holder" 2>/dev/null || true
wait "$holder" 2>/dev/null || true
rm -f "$OUT/.lock.held"
python3 ./screen-recording-clip.py --once >"$ROOT/lock-dead.out" 2>"$ROOT/lock-dead.err"
if grep -q 'already running' "$ROOT/lock-dead.err"; then
  echo "dead lock blocked a later pass" >&2
  exit 1
fi

echo "screen-recording-clip tests passed"

# Export recovers only an unambiguous tool command matching a truncated receipt.
python3 - "$ROOT" <<'PY'
import importlib.util,json,sys
from pathlib import Path
s=importlib.util.spec_from_file_location('c','screen-recording-clip.py');c=importlib.util.module_from_spec(s);s.loader.exec_module(c)
p=Path(sys.argv[1])/'state.json'
command='set -e\nplutil -lint demo.plist\n/bin/bash ./screen-recording-ship.sh install'
p.write_text(json.dumps({'actions':[{'what':'running set -e plutil -lint demo…'}]}))
p.with_name('events.jsonl').write_text(json.dumps({'message':{'content':[{'type':'tool_use','input':{'command':command}}]}})+'\n')
r=c.export_run(p)
assert r['actions'][0]['what']=='running '+command
terms={'screen','recording','ship','memory'}
assert c.demo_score('running ./screen-recording-ship-test.sh',terms)==0
assert c.demo_score('running '+command,terms)>c.demo_score('running python3 memory.py "screen recording ship"',terms)
print('full command recovered; live shipper beats test and memory')
PY
