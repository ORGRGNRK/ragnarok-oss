#!/usr/bin/env python3
"""Cut a short clip from one screen recording, using the agent run record.

The raw file stays where it is. This only reads it. Clips and a sidecar
go in a different folder. The graphics card is left alone (software
encoder). ollama and whisper share that card.

A clip is a run told in order, as short jump cuts:

- the ask, in the first seconds, where the task is on screen
- each moment a plan step is marked completed
- the agent's own said lines, when they fit
- the test command, and the live end-to-end send
- a handoff from one AI to another
- the end product, the final answer, only when the recording reaches it

If the recording stops before the run finishes, the end product is left
out and the sidecar says so. Nothing is invented to fill that gap.
Each piece has a small caption: what it is, and the clock time.

Safe to run twice. A second pass with the same recording and the same
run record does no cutting. A newer run record replaces the clip.

  screen-recording-clip.py --once
  screen-recording-clip.py --install
"""

from __future__ import annotations

import fcntl
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
from datetime import datetime, timedelta, timezone
from pathlib import Path

LOOSE_WINDOW = 3 * 60 * 60  # when the length is not known yet
ASK_LEN = 12.0
PLAN_LEN = 7.0
SAID_LEN = 8.0
TEST_LEAD = 2.0
TEST_LEN = 16.0
SEND_TAIL = 10.0
SEND_CAP = 26.0
HANDOFF_LEAD = 3.0
HANDOFF_LEN = 12.0
END_LEN = 10.0
# The closing answer has to land near the end of the run. An earlier
# progress line is not the end product, even when it is the last said.
END_NEAR_S = 120.0
# A 20 minute recording aims at 120 seconds, the top of the asked range.
# Shorter and longer recordings scale from that.
BUDGET_AT_20MIN = 120.0
TWENTY_MIN = 20 * 60.0
FONT_CANDIDATES = (
    "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
    "/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf",
    "/usr/share/fonts/truetype/freefont/FreeSans.ttf",
)
FAIL_RE = re.compile(r"\b(fail|failed|failure|fix|fixed|fixing|error|broke|broken)\b", re.IGNORECASE)

RAW_SUFFIXES = {".mov", ".mp4", ".m4v"}
NAME_RE = re.compile(
    r"Screen Recording (\d{4})-(\d{2})-(\d{2}) at (\d{1,2})\.(\d{2})\.(\d{2})\s*([AP]M)",
    re.IGNORECASE,
)
def home() -> Path:
    return Path(os.environ.get("SCREEN_CLIP_HOME", str(Path.home())))


def raw_dir() -> Path:
    return Path(os.environ.get("SCREEN_CLIP_RAW", str(home() / "screen-recordings")))


def out_dir() -> Path:
    return Path(os.environ.get("SCREEN_CLIP_OUT", str(home() / "screen-recording-clips")))


def ffmpeg_bin() -> str:
    return os.environ.get("SCREEN_CLIP_FFMPEG", "ffmpeg")


def ffprobe_bin() -> str:
    return os.environ.get("SCREEN_CLIP_FFPROBE", "ffprobe")


def log(msg: str) -> None:
    print(msg, file=sys.stderr, flush=True)


def parse_offset(text: str) -> timedelta:
    m = re.fullmatch(r"([+-])(\d{2}):?(\d{2})", text.strip())
    if not m:
        raise ValueError(f"bad offset {text!r}")
    sign = 1 if m.group(1) == "+" else -1
    return sign * timedelta(hours=int(m.group(2)), minutes=int(m.group(3)))


def parse_at(text: str) -> datetime:
    s = text.strip()
    if re.search(r"[+-]\d{4}$", s):
        s = s[:-2] + ":" + s[-2:]
    return datetime.fromisoformat(s)


def fmt_at(dt: datetime) -> str:
    base = dt.strftime("%Y-%m-%dT%H:%M:%S")
    if dt.microsecond:
        base += f".{dt.microsecond // 1000:03d}"
    off = dt.utcoffset() or timedelta(0)
    sign = "+" if off >= timedelta(0) else "-"
    minutes = int(abs(off).total_seconds()) // 60
    h, m = divmod(minutes, 60)
    return f"{base}{sign}{h:02d}{m:02d}"


def clean_name(name: str) -> str:
    return name.replace("\u202f", " ").replace("\u00a0", " ")


def parse_recording_name(name: str) -> datetime | None:
    """Wall-clock start from a macOS recording name, with no timezone yet."""
    m = NAME_RE.search(clean_name(name))
    if not m:
        return None
    year, month, day, hour, minute, second, ap = m.groups()
    h = int(hour) % 12
    if ap.upper() == "PM":
        h += 12
    return datetime(int(year), int(month), int(day), h, int(minute), int(second))


def attach_offset(naive: datetime, offset: timedelta) -> datetime:
    return naive.replace(tzinfo=timezone(offset))


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def load_json(path: Path) -> dict | None:
    try:
        data = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as exc:
        log(f"skip {path.name}: {exc}")
        return None
    if not isinstance(data, dict):
        log(f"skip {path.name}: not a record")
        return None
    return data


def export_run(path: Path) -> dict:
    """Recover truncated command receipts from this run's tool events only."""
    data = json.loads(path.read_text())
    events = path.with_name("events.jsonl")
    commands = []
    if events.is_file():
        for line in events.read_text().splitlines():
            try:
                event = json.loads(line)
            except ValueError:
                continue
            for block in event.get("message", {}).get("content", []):
                if isinstance(block, dict) and block.get("type") == "tool_use":
                    command = block.get("input", {}).get("command")
                    if isinstance(command, str):
                        commands.append("running " + command)
    for action in data.get("actions", []):
        what = action.get("what", "")
        if what.endswith("…") and what.startswith("running "):
            matches = set(c for c in commands if " ".join(c.split()).startswith(what[:-1]))
            if len(matches) == 1:
                action["what"] = matches.pop()
                action["source"] = "events.jsonl tool_use.command matching state.json prefix"
    return data


def run_window(record: dict) -> tuple[datetime, datetime | None] | None:
    try:
        started = parse_at(str(record["started"]))
    except (KeyError, ValueError):
        return None
    ended = None
    if record.get("ended"):
        try:
            ended = parse_at(str(record["ended"]))
        except ValueError:
            ended = None
    return started, ended


def overlaps(started: datetime, ended: datetime | None, rec_start: datetime, rec_end: datetime) -> bool:
    if started >= rec_end:
        return False
    if ended is not None and ended <= rec_start:
        return False
    return True


def length_budget(duration: float) -> float:
    scaled = duration * (BUDGET_AT_20MIN / TWENTY_MIN)
    return max(45.0, min(160.0, scaled))


def font_file() -> str:
    env = os.environ.get("SCREEN_CLIP_FONT", "")
    if env and Path(env).is_file():
        return env
    for candidate in FONT_CANDIDATES:
        if Path(candidate).is_file():
            return candidate
    return ""


def filter_path(path: str) -> str:
    return path.replace("\\", "\\\\").replace(":", "\\:").replace(",", "\\,")


def short_clock(dt: datetime) -> str:
    return dt.strftime("%H:%M:%S")


def caption_text(label: str, when: datetime) -> str:
    label = " ".join(label.split())
    if len(label) > 48:
        label = label[:47] + "…"
    return f"{label}  {short_clock(when)}"


def completed_steps(what: str) -> list[str]:
    """Step names a receipt marks completed. In-progress ticks are not steps."""
    names: list[str] = []
    if re.search(r"updating the plan", what, re.IGNORECASE):
        body = re.split(r"updating the plan\s+", what, maxsplit=1, flags=re.IGNORECASE)[-1]
        for match in re.finditer(r"([^:,]+):\s*completed\b", body, re.IGNORECASE):
            name = match.group(1).strip()
            if name and name not in names:
                names.append(name)
    for match in re.finditer(r"step\s+\d+\s*(?:→|->)\s*completed:\s*(.+)", what):
        name = match.group(1).strip()
        if name and name not in names:
            names.append(name)
    return names


def is_test_run(what: str) -> bool:
    low = what.strip().lower()
    if not low.startswith("running"):
        return False
    if "bash -n" in low or low.startswith("running chmod"):
        return False
    return (
        "-test.sh" in low
        or "_test.sh" in low
        or " pytest" in f" {low}"
        or " npm test" in low
        or " go test" in low
    )


_STOP = frozenset(
    """
    a an the to of and or for on in at by from with into so it is be as that
    this my your our their was were are been being not no nor but if then else
    when while over under out up down off its his her just than too very can
    will about after before again running set echo true exit yes none home usr
    bin tmp var sudo
    """.split()
)


def _terms(text: str) -> set[str]:
    out: set[str] = set()
    for word in re.findall(r"[A-Za-z0-9]+", text.lower()):
        if len(word) < 4 or word in _STOP:
            continue
        out.add(word)
        if word.endswith("s") and len(word) > 5:
            out.add(word[:-1])
    return out


def deliverable_terms(record: dict, actions: list[dict]) -> set[str]:
    """Words for what this run said it would build, from the plan and the files it edited."""
    chunks = [str(record.get("task") or ""), str(record.get("name") or "")]
    for step in record.get("plan") or []:
        if isinstance(step, dict):
            chunks.append(
                " ".join(str(step.get(key) or "") for key in ("step", "title", "id", "doing"))
            )
        elif isinstance(step, str):
            chunks.append(step)
    for action in actions:
        what = str(action.get("what") or "")
        if what.lower().startswith("editing") or " editing " in f" {what.lower()} ":
            chunks.append(what)
    return _terms(" ".join(chunks))


def is_connectivity_probe(what: str) -> bool:
    """An ssh or ping that only checks the host answers. That is not the work running."""
    low = " ".join(what.lower().split())
    if re.search(r"\bping\s+\S+\s*$", low):
        return True
    if not re.search(r"\bssh\b", low):
        return False
    if re.search(r"\b(true|exit)\s*$", low):
        return True
    stripped = re.sub(r"\b[\w.+-]+@[\w.-]+", " ", low)
    stripped = re.sub(r"/(?:usr/)?bin/ssh\b", " ", stripped)
    stripped = re.sub(r"\bssh\b", " ", stripped)
    stripped = re.sub(r"-[A-Za-z]\s+\S+", " ", stripped)
    if re.search(r"\b(python3?|node|ruby|perl|demo)\b|\.(?:py|sh|js|go)\b", stripped):
        return False
    useful = [
        word for word in re.findall(r"[a-z0-9]{4,}", stripped)
        if word not in _STOP and word not in {
            "batchmode", "connecttimeout", "identitiesonly", "identityagent",
            "stricthostkeychecking", "timeout", "identities", "identity",
            "agent", "internal", "ed25519",
        }
    ]
    return not useful


def is_inspection(what: str) -> bool:
    """Reading, listing, and printing are not a demonstration."""
    low = what.lower()
    if "bash -n" in low:
        return True
    # chmod and mkdir prepare a file. They are not the file running, so
    # they stay out of this exception. An interpreter or a script does.
    if re.search(r"\b(make|python3?|node|ruby|perl|go|cargo|swift)\b", low):
        return False
    if re.search(r"(?:^|\s)(?:\./|bash\s+|sh\s+|zsh\s+)\S", low):
        return False
    return bool(re.search(
        r"(?:^|[;&|(]\s*)(?:sudo\s+)?(?:/\S+/)?(?:"
        r"cat|ls|head|tail|less|more|grep|egrep|fgrep|find|diff|wc|pwd|whoami|"
        r"hostname|sw_vers|ps|stat|file|shasum|sha256sum|awk|cut|tr|printf|date|"
        r"basename|dirname|which|type|sed|nc|ping|launchctl|defaults|plutil"
        r")\b",
        low,
    ))


_SETUP_VERBS = frozenset(
    "chmod chown chgrp mkdir rmdir mv cp rm ln install touch".split()
)
_INTERPRETERS = frozenset("python python3 node ruby perl bash sh zsh".split())


def _command_segments(what: str) -> list[str]:
    """Shell pieces, with a trailing comment removed so a note cannot execute."""
    code = re.split(r"\s+#", what, maxsplit=1)[0]
    return re.split(r"&&|\|\||[;&\n]", code)


def executed_files(what: str) -> list[str]:
    """Files a receipt actually runs.

    `python3 demo.py` and `./demo.py` run demo.py. `chmod 700 demo.py` only
    changes its mode, and `plutil -lint` only checks syntax, so neither file
    is in the list.
    """
    found: list[str] = []
    for segment in _command_segments(what):
        tokens = segment.split()
        if tokens and tokens[0].lower() == "running":
            tokens = tokens[1:]
        while tokens and re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", tokens[0]):
            tokens = tokens[1:]
        if tokens and tokens[0] == "set":
            tokens = tokens[1:]
            while tokens and tokens[0].startswith("-"):
                tokens = tokens[1:]
        if not tokens:
            continue
        verb = tokens[0].rsplit("/", 1)[-1].lower()
        if verb in _SETUP_VERBS:
            continue
        if verb in _INTERPRETERS:
            if verb in {"bash", "sh", "zsh"} and "-n" in tokens[1:3]:
                continue
            for tok in tokens[1:]:
                if not tok.startswith("-"):
                    found.append(tok)
                    break
            continue
        if tokens[0].startswith("./") or re.search(r"\.(?:py|sh|js|ts|go|rb|mjs)$", tokens[0], re.I):
            found.append(tokens[0])
    return found


def demo_score(what: str, terms: set[str]) -> int:
    """How strongly a receipt shows the thing the plan described actually running.

    A syntax check, a connectivity probe, an inspection, and a setup command
    such as chmod score nothing. `plutil -lint` is a syntax check. A command
    scores when it runs a file the plan or an edit names. Naming that file
    in chmod or lint is not enough, and SSH to a host is not enough.
    """
    low = what.strip().lower()
    if not low.startswith("running"):
        return 0
    if "bash -n" in low or is_connectivity_probe(what) or is_inspection(what):
        return 0
    executed = [name for name in executed_files(what)
                if _terms(Path(name).name) & terms and not re.search(r"(?:^|[-_/.])tests?(?:[-_/.]|$)", name, re.I)]
    if not executed:
        return 0
    body = re.sub(r"\b[\w.+-]+@[\w.-]+", " ", what)
    # Rank the executed filenames, not prose arguments (for example a
    # memory command quoting a description of the whole deliverable).
    return 4 + max(len(_terms(Path(name).name) & terms) for name in executed)


def closing_match(said: str, final: str) -> bool:
    """True when a said line is the record's final answer, not a progress note.

    Receipts are often cut short, so the said text may be a prefix of final.
    """
    if not final.strip():
        return False
    left = " ".join(said.replace("…", " ").split())
    right = " ".join(final.replace("…", " ").split())
    if len(left) < 24 or len(right) < 24:
        return False
    shorter, longer = (left, right) if len(left) <= len(right) else (right, left)
    return longer.startswith(shorter)


def in_window(at: datetime, rec_start: datetime, rec_end: datetime) -> bool:
    return rec_start <= at <= rec_end


def offset_s(at: datetime, rec_start: datetime) -> float:
    return (at - rec_start).total_seconds()


def cap_around(anchor: float, duration: float, cap: float, tail: float) -> tuple[float, float]:
    """A window of at most `cap` seconds that contains `anchor`."""
    end = min(duration, anchor + tail)
    start = max(0.0, end - cap)
    if anchor < start:
        start = max(0.0, anchor - 1)
        end = min(duration, start + cap)
    if anchor > end:
        end = min(duration, anchor + 0.4)
        start = max(0.0, end - cap)
    if end <= start:
        end = min(duration, start + min(cap, 1.0))
    return start, end


def span(anchor: float, duration: float, length: float, lead: float = 0.0) -> tuple[float, float] | None:
    start = max(0.0, anchor - lead)
    end = min(duration, start + length)
    if end - start < 1:
        return None
    if anchor > end:
        end = min(duration, anchor + 0.4)
    if anchor < start:
        start = max(0.0, anchor - 0.4)
    return start, end


def choose_parts(record: dict, rec_start: datetime, rec_end: datetime, duration: float) -> tuple[list[dict], list[dict]]:
    """Jump cuts for one run, in receipt order, plus parts the video does not hold."""
    run_id = str(record.get("id") or "")
    window = run_window(record)
    parts: list[dict] = []
    missing: list[dict] = []
    if window is None:
        missing.append({
            "part": "ask",
            "run": run_id,
            "reason": f"Run {run_id} has no start time, so nothing was cut from it.",
        })
        return parts, missing
    started, ended = window
    if not overlaps(started, ended, rec_start, rec_end):
        return parts, missing

    actions = []
    for action in record.get("actions") or []:
        if not isinstance(action, dict):
            continue
        try:
            at = parse_at(str(action.get("at") or ""))
        except ValueError:
            continue
        actions.append({
            "at": at,
            "kind": str(action.get("kind") or ""),
            "what": str(action.get("what") or ""),
        })
    on_video = [a for a in actions if in_window(a["at"], rec_start, rec_end)]

    def receipt(action: dict) -> dict:
        return {"at": fmt_at(action["at"]), "kind": action["kind"], "what": action["what"], "run": run_id}

    def add_piece(part: str, start: float, end: float, anchor: float, when: datetime, label: str, receipts: list[dict], score: int = 0, plan_step: str | None = None) -> None:
        if end - start < 1:
            return
        item = {
            "part": part,
            "run": run_id,
            "file_start_s": round(start, 3),
            "file_end_s": round(end, 3),
            "anchor_s": round(anchor, 3),
            "clock_start": fmt_at(rec_start + timedelta(seconds=start)),
            "clock_end": fmt_at(rec_start + timedelta(seconds=end)),
            "caption": caption_text(label, when),
            "receipts": receipts,
            "score": score,
        }
        if plan_step:
            item["plan_step"] = plan_step
        parts.append(item)

    def covers(at: datetime) -> dict | None:
        t = offset_s(at, rec_start)
        for piece in parts:
            if piece["file_start_s"] - 1 <= t <= piece["file_end_s"] + 1:
                return piece
        return None

    # The ask: the opening of the run, where the task text is on screen.
    task = str(record.get("task") or record.get("name") or "run started").strip()
    anchor = offset_s(started, rec_start)
    if 0 <= anchor <= 60:
        ask_span = (0.0, min(duration, ASK_LEN))
    else:
        ask_span = span(max(0.0, anchor), duration, ASK_LEN, lead=4)
    if ask_span and 0 <= anchor <= duration:
        add_piece(
            "ask", ask_span[0], ask_span[1], min(max(anchor, ask_span[0]), ask_span[1] - 0.4),
            started, "Ask",
            [{"at": fmt_at(started), "kind": "started", "what": task, "run": run_id}],
        )

    # Each plan update that marks one or more steps completed. One moment
    # on screen, even when several steps tick together.
    for action in on_video:
        names = completed_steps(action["what"])
        if not names:
            continue
        t = offset_s(action["at"], rec_start)
        bounds = span(t, duration, PLAN_LEN, lead=1)
        if not bounds:
            continue
        label = "Plan  " + ", ".join(names)
        add_piece("plan", bounds[0], bounds[1], t, action["at"], label, [receipt(action)], plan_step=", ".join(names))

    # Verification is the test command, not the plan tick that says verify.
    tests = [a for a in on_video if is_test_run(a["what"])]
    if tests:
        chosen = min(tests, key=lambda a: a["at"])
        t = offset_s(chosen["at"], rec_start)
        bounds = span(t, duration, TEST_LEN, lead=TEST_LEAD)
        if bounds:
            add_piece("verification", bounds[0], bounds[1], t, chosen["at"], "Test", [receipt(chosen)])
    else:
        missing.append({
            "part": "verification",
            "run": run_id,
            "reason": "No test command inside this recording.",
        })

    # How it worked: the command that runs what the plan describes.
    # A connectivity probe does not qualify, and an early probe does not
    # stretch the piece back across the recording.
    terms = deliverable_terms(record, actions)
    sends = []
    for action in on_video:
        score = demo_score(action["what"], terms)
        if score <= 0:
            continue
        sends.append((score, action))
    if sends:
        best_score, best = max(sends, key=lambda item: (item[0], item[1]["at"]))
        near = []
        for score, action in sends:
            if score < 6:
                continue
            if abs((action["at"] - best["at"]).total_seconds()) <= 40:
                near.append(action)
        if not near:
            near = [best]
        times = [offset_s(a["at"], rec_start) for a in near]
        anchor_t = offset_s(best["at"], rec_start)
        start = max(0.0, min(times) - 2)
        end = min(duration, max(times) + SEND_TAIL)
        if end - start > SEND_CAP:
            # Prefer the early window when it already holds the selected
            # command, so a nearby receipt stays in the piece. When that
            # window stops before the selected command, slide so the caption
            # and the frames name the same moment.
            capped_start = max(0.0, min(times) - 1)
            capped_end = min(duration, capped_start + SEND_CAP)
            if capped_start <= anchor_t <= capped_end:
                start, end = capped_start, capped_end
            else:
                start, end = cap_around(anchor_t, duration, SEND_CAP, SEND_TAIL)
        inside = [a for a in near if start <= offset_s(a["at"], rec_start) <= end]
        if not inside:
            inside = [best]
        inside.sort(key=lambda a: a["at"])
        add_piece(
            "how_it_worked", start, end, anchor_t, best["at"], "Ran",
            [receipt(a) for a in inside], score=best_score,
        )
    else:
        missing.append({
            "part": "how_it_worked",
            "run": run_id,
            "reason": "No receipt inside this recording shows the work running.",
        })

    # Handoffs between AIs, from the handoff list and from handoff actions.
    handoffs = []
    for item in record.get("handoffs") or []:
        if not isinstance(item, dict) or not item.get("at"):
            continue
        try:
            at = parse_at(str(item["at"]))
        except ValueError:
            continue
        if not in_window(at, rec_start, rec_end):
            continue
        frm = str(item.get("from") or "").strip()
        to = str(item.get("to") or "").strip()
        handoffs.append({
            "at": at,
            "kind": "handoff",
            "what": f"handoff from {frm or '?'} to {to or '?'}",
            "frm": frm,
            "to": to,
        })
    for action in on_video:
        if action["kind"] != "handoff":
            continue
        if any(abs((action["at"] - h["at"]).total_seconds()) < 2 for h in handoffs):
            continue
        match = re.search(r"from\s+(\S+)\s+to\s+(\S+)", action["what"], re.IGNORECASE)
        frm = match.group(1) if match else ""
        to = match.group(2).rstrip(":") if match else ""
        handoffs.append({**action, "frm": frm, "to": to})
    for item in handoffs:
        t = offset_s(item["at"], rec_start)
        bounds = span(t, duration, HANDOFF_LEN, lead=HANDOFF_LEAD)
        if not bounds:
            continue
        who = f"{item.get('frm') or '?'} to {item.get('to') or '?'}"
        add_piece("handoff", bounds[0], bounds[1], t, item["at"], f"Handoff  {who}", [receipt(item)])

    # End product is the record's final answer, and only when that answer
    # was said as the run finished, on this video. The last said line is
    # not a stand-in: an early progress note stays a progress note.
    closing = None
    if ended is None:
        missing.append({
            "part": "end_product",
            "run": run_id,
            "reason": f"Run {run_id} has not ended, so there is no end product on this video.",
        })
    elif ended > rec_end:
        missing.append({
            "part": "end_product",
            "run": run_id,
            "reason": (
                f"The recording ends at {fmt_at(rec_end)} and run {run_id} ends at "
                f"{record.get('ended')}, so the end product is not on this video."
            ),
        })
    else:
        final = str(record.get("final") or "").strip()
        near = [
            a for a in on_video
            if a["kind"] == "said"
            and started <= a["at"] <= ended
            and 0 <= (ended - a["at"]).total_seconds() <= END_NEAR_S
            and closing_match(a["what"], final)
        ]
        if not final:
            missing.append({
                "part": "end_product",
                "run": run_id,
                "reason": (
                    f"Run {run_id} ended at {record.get('ended')} inside the recording "
                    "but it has no final answer, so there is no end product."
                ),
            })
        elif not near:
            missing.append({
                "part": "end_product",
                "run": run_id,
                "reason": (
                    f"Run {run_id} ended at {record.get('ended')} but its final answer "
                    "is not next to the end of the run, so there is no end product on this video."
                ),
            })
        else:
            closing = max(near, key=lambda a: a["at"])
            t = offset_s(closing["at"], rec_start)
            bounds = span(t, duration, END_LEN, lead=1)
            if bounds:
                add_piece("end_product", bounds[0], bounds[1], t, closing["at"], "End", [receipt(closing)])

    # Said lines. One that lands inside a piece already cut stays on that
    # piece's receipt list, so the same frames are not shown twice.
    plan_times = [a["at"] for a in on_video if completed_steps(a["what"])]
    test_times = [a["at"] for a in tests]
    handoff_times = [h["at"] for h in handoffs]
    saids = []
    for action in on_video:
        if action["kind"] != "said":
            continue
        if closing is not None and action["at"] == closing["at"]:
            continue
        host = covers(action["at"])
        if host is not None:
            host["receipts"].append(receipt(action))
            continue
        score = 1
        if FAIL_RE.search(action["what"]):
            score += 6
        if any(abs((action["at"] - other).total_seconds()) <= 45 for other in plan_times + test_times):
            score += 5
        if any(abs((action["at"] - other).total_seconds()) <= 20 for other in handoff_times):
            score += 2
        saids.append((score, action))
    for score, action in saids:
        t = offset_s(action["at"], rec_start)
        bounds = span(t, duration, SAID_LEN, lead=0.5)
        if not bounds:
            continue
        add_piece("said", bounds[0], bounds[1], t, action["at"], "Said", [receipt(action)], score=score)
    return parts, missing


def fit_budget(parts: list[dict], budget: float) -> list[dict]:
    """Drop the least useful said lines, then shorten pieces, to meet the budget."""
    parts = [p for p in parts if p["file_end_s"] - p["file_start_s"] >= 1]

    def total() -> float:
        return sum(p["file_end_s"] - p["file_start_s"] for p in parts)

    while total() > budget:
        saids = [p for p in parts if p["part"] == "said"]
        if not saids:
            break
        worst = min(saids, key=lambda p: (p.get("score", 0), p["anchor_s"]))
        parts.remove(worst)
    floors = {
        "ask": 8.0,
        "plan": 4.0,
        "said": 5.0,
        "verification": 12.0,
        "how_it_worked": 14.0,
        "handoff": 8.0,
        "end_product": 8.0,
    }
    for _ in range(400):
        if total() <= budget:
            break
        shrinkable = []
        for piece in parts:
            floor = floors.get(piece["part"], 4.0)
            if piece["file_end_s"] - piece["file_start_s"] > floor + 0.05:
                shrinkable.append(piece)
        if not shrinkable:
            break
        piece = max(shrinkable, key=lambda p: p["file_end_s"] - p["file_start_s"])
        floor = floors.get(piece["part"], 4.0)
        room = (piece["file_end_s"] - piece["file_start_s"]) - floor
        cut = min(room, total() - budget)
        piece["file_end_s"] = round(piece["file_end_s"] - cut, 3)
        if piece["anchor_s"] >= piece["file_end_s"]:
            piece["file_end_s"] = round(piece["anchor_s"] + 0.4, 3)
    return parts


def separate_pieces(parts: list[dict]) -> list[dict]:
    """Keep each receipt's moment inside its own piece. No overlap."""
    parts = sorted(parts, key=lambda p: p["anchor_s"])
    for i in range(1, len(parts)):
        prev, cur = parts[i - 1], parts[i]
        if prev["file_end_s"] <= cur["file_start_s"]:
            continue
        mid = (prev["anchor_s"] + cur["anchor_s"]) / 2
        prev["file_end_s"] = round(min(prev["file_end_s"], max(prev["anchor_s"] + 0.4, mid)), 3)
        cur["file_start_s"] = round(max(cur["file_start_s"], min(cur["anchor_s"] - 0.4, mid)), 3)
    return [p for p in parts if p["file_end_s"] - p["file_start_s"] >= 1]


def read_manifest(path: Path) -> dict[str, str]:
    found: dict[str, str] = {}
    if not path.is_file():
        return found
    for line in path.read_text(errors="replace").splitlines():
        if not line.strip():
            continue
        dest, _, rest = line.partition("\t")
        b64 = rest.split("\t", 1)[0].strip()
        try:
            name = __import__("base64").b64decode(b64).decode()
        except Exception:
            continue
        found[dest.strip()] = name
    return found


def recording_clock(video: Path, manifest: dict[str, str], runs: Path) -> tuple[datetime, str] | None:
    """Start time with an offset, and the original name."""
    clock_path = runs / "clock.json"
    original = manifest.get(video.name, video.name)
    if clock_path.is_file():
        data = load_json(clock_path) or {}
        if data.get("start"):
            try:
                return parse_at(str(data["start"])), str(data.get("original") or original)
            except ValueError as exc:
                log(f"{video.name}: clock file {exc}")
    naive = parse_recording_name(original)
    if naive is None:
        return None
    offset = None
    for state in sorted(runs.glob("*.json")):
        if state.name == "clock.json":
            continue
        record = load_json(state)
        if not record:
            continue
        window = run_window(record)
        if window is None:
            continue
        offset = window[0].utcoffset()
        break
    if offset is None:
        return None
    return attach_offset(naive, offset), original


def probe_duration(path: Path) -> float:
    out = subprocess.check_output(
        [
            ffprobe_bin(), "-v", "error",
            "-show_entries", "format=duration",
            "-of", "default=nw=1:nk=1",
            str(path),
        ],
        text=True,
    )
    return float(out.strip())


def probe_audio(path: Path) -> bool:
    out = subprocess.check_output(
        [
            ffprobe_bin(), "-v", "error",
            "-select_streams", "a",
            "-show_entries", "stream=index",
            "-of", "csv=p=0",
            str(path),
        ],
        text=True,
    )
    return bool(out.strip())


def load_runs(runs: Path) -> list[tuple[Path, dict]]:
    found = []
    if not runs.is_dir():
        return found
    for path in sorted(runs.glob("*.json")):
        if path.name == "clock.json":
            continue
        record = load_json(path)
        if record:
            found.append((path, record))
    return found


def stamp_text(video: Path, states: list[Path], script: Path) -> str:
    st = video.stat()
    lines = [
        f"script {sha256_file(script)}",
        f"video {st.st_size} {st.st_mtime_ns}",
    ]
    for path in states:
        lines.append(f"state {path.name} {sha256_file(path)}")
    return "\n".join(lines) + "\n"


def ffmpeg_cut(src: Path, start: float, dur: float, dest: Path, audio: bool, caption_file: Path) -> list[str]:
    font = font_file()
    if not font:
        raise SystemExit("no font for the caption; set SCREEN_CLIP_FONT to a .ttf file")
    draw = (
        f"drawtext=fontfile={filter_path(font)}:textfile={filter_path(str(caption_file))}:"
        "fontsize=36:fontcolor=white:box=1:boxcolor=black@0.55:boxborderw=8:"
        "x=24:y=h-th-28"
    )
    cmd = [ffmpeg_bin(), "-y", "-hide_banner", "-loglevel", "error", "-nostdin"]
    if start > 0:
        coarse = max(0.0, start - 2.0)
        fine = start - coarse
        cmd += ["-ss", f"{coarse:.3f}", "-i", str(src), "-ss", f"{fine:.3f}"]
    else:
        cmd += ["-i", str(src)]
    cmd += ["-t", f"{dur:.3f}", "-map", "0:v:0"]
    if audio:
        cmd += ["-map", "0:a:0", "-c:a", "aac", "-b:a", "128k"]
    else:
        cmd += ["-an"]
    # Software only. The GTX 1080 stays with ollama and whisper.
    cmd += [
        "-vf", f"scale=trunc(iw/2)*2:trunc(ih/2)*2,{draw}",
        "-c:v", "libx264", "-preset", "veryfast", "-crf", "23",
        "-pix_fmt", "yuv420p", "-movflags", "+faststart",
        str(dest),
    ]
    return cmd


def run_cmd(cmd: list[str]) -> None:
    proc = subprocess.run(cmd)
    if proc.returncode != 0:
        raise SystemExit(f"ffmpeg failed ({proc.returncode})")


def cut_clip(video: Path, pieces: list[dict], dest: Path, audio: bool) -> None:
    dest.parent.mkdir(parents=True, exist_ok=True)
    os.chmod(dest.parent, 0o700)
    if dest.resolve() == video.resolve() or raw_dir().resolve() in dest.resolve().parents:
        raise SystemExit(f"refusing to write {dest} next to the raw recording")
    work = Path(tempfile.mkdtemp(prefix=f".{dest.stem}.", dir=str(dest.parent)))
    try:
        made: list[Path] = []
        for i, piece in enumerate(pieces):
            dur = piece["file_end_s"] - piece["file_start_s"]
            piece_path = work / f"piece-{i:02d}.mp4"
            caption_path = work / f"piece-{i:02d}.txt"
            caption_path.write_text(piece.get("caption") or piece["part"])
            before = video.stat()
            run_cmd(ffmpeg_cut(video, piece["file_start_s"], dur, piece_path, audio, caption_path))
            after = video.stat()
            if (before.st_size, before.st_mtime_ns) != (after.st_size, after.st_mtime_ns):
                raise SystemExit(f"raw recording changed while cutting {video.name}")
            made.append(piece_path)
        partial = dest.with_suffix(".partial.mp4")
        if len(made) == 1:
            os.replace(made[0], partial)
        else:
            listing = work / "list.txt"
            lines = []
            for path in made:
                escaped = str(path).replace("'", "'\\''")
                lines.append(f"file '{escaped}'\n")
            listing.write_text("".join(lines))
            run_cmd([
                ffmpeg_bin(), "-y", "-hide_banner", "-loglevel", "error", "-nostdin",
                "-f", "concat", "-safe", "0", "-i", str(listing),
                "-c", "copy", str(partial),
            ])
        os.replace(partial, dest)
        os.chmod(dest, 0o600)
    finally:
        for child in work.glob("*"):
            try:
                child.unlink()
            except OSError:
                pass
        try:
            work.rmdir()
        except OSError:
            pass


def build_report(video: Path, original: str, rec_start: datetime, duration: float, runs: list[dict]) -> dict:
    rec_end = rec_start + timedelta(seconds=duration)
    parts: list[dict] = []
    missing: list[dict] = []
    used = []
    for record in runs:
        window = run_window(record)
        if window is None or not overlaps(window[0], window[1], rec_start, rec_end):
            continue
        used.append(str(record.get("id") or ""))
        one_parts, one_missing = choose_parts(record, rec_start, rec_end, duration)
        parts.extend(one_parts)
        missing.extend(one_missing)
    parts = separate_pieces(parts)
    parts = fit_budget(parts, length_budget(duration))
    if not used:
        missing.append({
            "part": "end_product",
            "run": "",
            "reason": "No run record overlaps this recording, so nothing was cut.",
        })
    # Clock labels follow the final bounds, after overlap trimming.
    for piece in parts:
        piece["clock_start"] = fmt_at(rec_start + timedelta(seconds=piece["file_start_s"]))
        piece["clock_end"] = fmt_at(rec_start + timedelta(seconds=piece["file_end_s"]))
        piece["length_s"] = round(piece["file_end_s"] - piece["file_start_s"], 3)
        piece.pop("score", None)
    return {
        "recording": video.name,
        "original_name": original,
        "recording_start": fmt_at(rec_start),
        "recording_end": fmt_at(rec_end),
        "duration_s": round(duration, 3),
        "runs": used,
        "parts": parts,
        "missing": missing,
    }


def write_json(path: Path, data: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    os.chmod(path.parent, 0o700)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(data, indent=2) + "\n")
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)


def handle_video(video: Path, manifest: dict[str, str], plan_only: bool) -> dict | None:
    stem = video.stem
    runs_path = raw_dir() / "runs" / stem
    states = load_runs(runs_path)
    if not states:
        log(f"no run record yet for {video.name}")
        return None
    clock = recording_clock(video, manifest, runs_path)
    if clock is None:
        log(f"{video.name}: cannot tell when the recording started")
        return None
    rec_start, original = clock
    try:
        duration = probe_duration(video)
    except (OSError, subprocess.CalledProcessError, ValueError) as exc:
        log(f"{video.name}: ffprobe failed ({exc})")
        return None
    if duration <= 0:
        log(f"{video.name}: duration {duration}")
        return None
    report = build_report(video, original, rec_start, duration, [r for _, r in states])
    if plan_only:
        return report
    out = out_dir()
    out.mkdir(parents=True, exist_ok=True)
    os.chmod(out, 0o700)
    clip = out / f"{stem}.mp4"
    side = out / f"{stem}.json"
    stamp_path = out / f"{stem}.stamp"
    # Only the runs that actually overlap. A later run's record can sit in
    # the folder without making the clip get cut again.
    used_ids = set(report["runs"])
    inputs = [
        path for path, record in states
        if str(record.get("id") or path.stem) in used_ids
    ]
    clock_path = runs_path / "clock.json"
    if clock_path.is_file():
        inputs.append(clock_path)
    stamp = stamp_text(video, inputs, Path(__file__).resolve())
    same = stamp_path.is_file() and stamp_path.read_text() == stamp and side.is_file()
    if same and (clip.is_file() or not report["parts"]):
        log(f"unchanged {clip.name}")
        return report
    if not report["parts"]:
        write_json(side, report)
        stamp_path.write_text(stamp)
        os.chmod(stamp_path, 0o600)
        log(f"no pieces for {video.name}")
        for item in report["missing"]:
            log(f"  {item['part']}: {item['reason']}")
        return report
    before = (video.stat().st_size, video.stat().st_mtime_ns)
    audio = probe_audio(video)
    cut_clip(video, report["parts"], clip, audio)
    after = (video.stat().st_size, video.stat().st_mtime_ns)
    if before != after:
        raise SystemExit(f"raw recording changed: {video}")
    report["clip"] = clip.name
    write_json(side, report)
    stamp_path.write_text(stamp)
    os.chmod(stamp_path, 0o600)
    names = ",".join(p["part"] for p in report["parts"])
    missed = ",".join(p["part"] for p in report["missing"]) or "none"
    length = sum(p["length_s"] for p in report["parts"])
    log(f"clip {clip.name} {length:.1f}s parts={names} missing={missed}")
    for item in report["missing"]:
        log(f"  {item['part']}: {item['reason']}")
    return report


def pid_alive(pid: int) -> bool:
    if pid <= 0:
        return False
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def clear_stale_dir_lock(lock: Path) -> bool:
    """Remove a leftover mkdir-lock when its owner is gone.

    The old lock was a directory. A reboot or a killed pass left it in
    place, and every later pass then stopped at "already running". A
    directory with no live pid is that leftover.
    """
    if not lock.is_dir():
        return True
    pid_path = lock / "pid"
    if pid_path.is_file():
        text = pid_path.read_text(errors="replace").strip()
        if text.isdigit() and pid_alive(int(text)):
            return False
    try:
        for child in list(lock.iterdir()):
            if child.is_file() or child.is_symlink():
                child.unlink()
        lock.rmdir()
    except OSError:
        return False
    return True


def acquire_lock(lock: Path):
    """An exclusive lock the kernel drops when this process dies.

    Returns the open file, or None when another live pass holds it.
    """
    lock.parent.mkdir(parents=True, exist_ok=True)
    if lock.exists() and lock.is_dir():
        if not clear_stale_dir_lock(lock):
            return None
    fd = os.open(lock, os.O_CREAT | os.O_RDWR, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        os.close(fd)
        return None
    os.ftruncate(fd, 0)
    os.write(fd, f"{os.getpid()}\n".encode())
    return fd


def once() -> int:
    raw = raw_dir()
    if not raw.is_dir():
        log(f"no recordings folder {raw}")
        return 0
    fd = acquire_lock(out_dir() / ".lock")
    if fd is None:
        log("already running")
        return 0
    try:
        manifest = read_manifest(raw / "manifest.tsv")
        videos = [
            p for p in sorted(raw.iterdir())
            if p.is_file() and p.suffix.lower() in RAW_SUFFIXES and not p.name.startswith(".")
        ]
        for video in videos:
            handle_video(video, manifest, False)
        return 0
    finally:
        try:
            fcntl.flock(fd, fcntl.LOCK_UN)
        finally:
            os.close(fd)


def plan_main() -> int:
    raw = raw_dir()
    manifest = read_manifest(raw / "manifest.tsv")
    videos = [
        p for p in sorted(raw.iterdir())
        if p.is_file() and p.suffix.lower() in RAW_SUFFIXES and not p.name.startswith(".")
    ]
    reports = []
    for video in videos:
        report = handle_video(video, manifest, True)
        if report is not None:
            reports.append(report)
    json.dump(reports, sys.stdout, indent=2)
    sys.stdout.write("\n")
    return 0


def list_runs(name: str, duration: float | None, offset_text: str, agents: Path) -> int:
    naive = parse_recording_name(name)
    if naive is None:
        return 0
    try:
        offset = parse_offset(offset_text)
    except ValueError:
        offset = None
    span = duration if duration and duration > 0 else LOOSE_WINDOW
    if not agents.is_dir():
        return 0
    for path in sorted(agents.glob("*/state.json")):
        record = load_json(path)
        if not record:
            continue
        window = run_window(record)
        if window is None:
            continue
        started, ended = window
        use_offset = offset if offset is not None else (started.utcoffset() or timedelta(0))
        rec_start = attach_offset(naive, use_offset)
        rec_end = rec_start + timedelta(seconds=span)
        if overlaps(started, ended, rec_start, rec_end):
            run_id = str(record.get("id") or path.parent.name)
            sys.stdout.write(f"{run_id}\t{path}\n")
    return 0


def clock_json(name: str, duration: str, offset_text: str) -> int:
    naive = parse_recording_name(name)
    if naive is None:
        return 0
    offset = parse_offset(offset_text)
    start = attach_offset(naive, offset)
    data = {"original": name, "start": fmt_at(start), "offset": offset_text}
    if duration:
        try:
            data["duration_s"] = float(duration)
        except ValueError:
            pass
    json.dump(data, sys.stdout)
    sys.stdout.write("\n")
    return 0


def install() -> int:
    script = Path(__file__).resolve()
    line = (
        f"* * * * * /usr/bin/python3 -I {script} --once "
        f">> {home() / '.local/state/screen-recording-clip.log'} 2>&1"
    )
    def rewritten(current: str) -> str:
        # One line, and it points at this file. An older copy's line is replaced.
        kept = [ln for ln in current.splitlines() if "screen-recording-clip.py --once" not in ln]
        body = "\n".join(kept).strip()
        return (body + "\n" if body else "") + line + "\n"

    cron_file = os.environ.get("SCREEN_CLIP_CRON_FILE")
    if cron_file:
        path = Path(cron_file)
        current = path.read_text() if path.is_file() else ""
        body = rewritten(current)
        if current == body:
            log("cron already installed")
            return 0
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(body)
        log("cron line written")
        return 0
    proc = subprocess.run(["crontab", "-l"], text=True, capture_output=True)
    current = proc.stdout if proc.returncode == 0 else ""
    body = rewritten(current)
    if current == body or current.strip() == body.strip():
        log("cron already installed")
        return 0
    state = home() / ".local/state"
    state.mkdir(parents=True, exist_ok=True)
    put = subprocess.run(["crontab", "-"], input=body, text=True)
    if put.returncode != 0:
        raise SystemExit("crontab refused the new line")
    log("cron installed")
    return 0


def main(argv: list[str]) -> int:
    if "--export-run" in argv:
        print(json.dumps(export_run(Path(argv[argv.index("--export-run") + 1]))))
        return 0
    if "--install" in argv:
        return install()
    if "--list-runs" in argv:
        name = ""
        duration = None
        offset_text = "-0800"
        agents = home() / ".ragnarok/agents"
        i = 0
        while i < len(argv):
            if argv[i] == "--name" and i + 1 < len(argv):
                name = argv[i + 1]
                i += 2
                continue
            if argv[i] == "--duration" and i + 1 < len(argv):
                try:
                    duration = float(argv[i + 1])
                except ValueError:
                    duration = None
                i += 2
                continue
            if argv[i] == "--offset" and i + 1 < len(argv):
                offset_text = argv[i + 1]
                i += 2
                continue
            if argv[i] == "--agents" and i + 1 < len(argv):
                agents = Path(argv[i + 1])
                i += 2
                continue
            i += 1
        return list_runs(name, duration, offset_text, agents)
    if "--clock" in argv:
        name = ""
        duration = ""
        offset_text = "-0800"
        i = 0
        while i < len(argv):
            if argv[i] == "--name" and i + 1 < len(argv):
                name = argv[i + 1]
                i += 2
                continue
            if argv[i] == "--duration" and i + 1 < len(argv):
                duration = argv[i + 1]
                i += 2
                continue
            if argv[i] == "--offset" and i + 1 < len(argv):
                offset_text = argv[i + 1]
                i += 2
                continue
            i += 1
        return clock_json(name, duration, offset_text)
    if "--plan" in argv:
        return plan_main()
    return once()


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv[1:]))
    except BrokenPipeError:
        raise SystemExit(0)
