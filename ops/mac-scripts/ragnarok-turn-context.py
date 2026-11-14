#!/usr/bin/env python3
"""
RAGNAROK turn envelope — UserPromptSubmit hook. SLICES 1 + 2.

WHY THIS EXISTS
  Ruleset v4.8 mandates a lane banner on every reply turn, including the state
  "LANE: UNSET -- declare a lane or boot" for a session that never booted. But
  that mandate is PROSE inside the Ruleset, and the Ruleset is read #1 OF BOOT.
  So the one indicator whose whole job is to announce "no boot has run" was only
  available to a session that had already booted -- structurally incapable of
  firing in the exact case it was written for. Reminders rec6ZDZOlhrV6HZ2k.

  Prose rules need a reader. Path rules enforce themselves (Memories
  recR2JjTLAF00Hn14). This moves the banner from prose to path.

SLICE 1 (2026-08-22): host time, REAL elapsed gap, cwd.
SLICE 2 (2026-08-22): boot state. Reminders rec9DaS5CMva4vwrc.

THE TWO-HALF BOOT STAMP, which is the whole design of slice 2
  UserPromptSubmit hands this hook the RAW prompt, so it can see that the owner
  typed a boot door. It CANNOT see whether the boot succeeded -- Airtable may be
  down, and the Session Boot Procedure says "If Airtable fails: say so and stop.
  Never fake a boot." A hook that stamped "booted" on sight of the word would be
  lying on exactly the failure it exists to catch.
    REQUESTED  <- written here, path-enforced, cannot be forgotten
    CONFIRMED  <- written by ragnarok-boot-stamp, only after the reads landed
  Requested-and-never-confirmed renders LOUDLY. That silent half-boot is the
  failure mode; it does not get to look like success. Same doctrine as the Stale
  Gate and price-mcp's off_ladder: a non-answer is a first-class answer.

  A natural-language boot ("boot RAGNAROK") is not matched here on purpose --
  prose matching invites false positives. Those still stamp, via the confirm
  half, which writes a stamp whether or not a request was ever recorded.

WHAT IT DELIBERATELY DOES NOT DO
  - No network. No Airtable. This runs on EVERY prompt of EVERY session on this
    box; a per-turn API call would tax every turn the owner takes.
  - It does not assert the lane from nothing. It reports what the stamp says and
    what it does not know. A hook that GUESSED the lane would be Ruleset v4.7's
    provenance defect in new clothes: an absent trust field resolving to MORE
    authority than it earned.

FAILURE MODE: silent and open. Always exit 0, always valid JSON or nothing. This
sits in front of every prompt the owner types; if it breaks it must degrade to
invisible, never to a blocked prompt.
"""
import json
import os
import re
import sys
from datetime import datetime, timezone

TURN_DIR = os.environ.get(
    "RAGNAROK_TURN_STATE", os.path.expanduser("~/.claude/ragnarok-turn-state")
)
BOOT_DIR = os.environ.get(
    "RAGNAROK_BOOT_STATE", os.path.expanduser("~/.claude/boot-state")
)
TZ = os.environ.get("RAGNAROK_TZ", "America/Los_Angeles")

# Session Boot Procedure v1.15 -- the door sets the lane. Order matters:
# longest/most specific first, so "/boot system" never matches bare "/boot".
DOORS = [
    (re.compile(r"^/boot\s+business\b", re.I), "/boot business", "BUSINESS"),
    (re.compile(r"^/boot\s+system\b", re.I),   "/boot system",   "SYSTEM"),
    # /boot flipped is a VIEW MODIFIER, not a door: it PRESERVES the lane its
    # preceding boot established. Matched only so it never falls through to the
    # bare-/boot rule below and silently reassigns the lane to PERSONAL.
    (re.compile(r"^/boot\s+flipped\b", re.I),  "/boot flipped",  None),
    # /boot personal (Procedure v1.19) is the slim glance; plain /boot is now
    # ALL-LANES. Both set PERSONAL -- the trunk -- so the lane is unchanged;
    # the door is recorded by name so the stamp's request and confirm halves
    # agree on which one ran.
    (re.compile(r"^/boot\s+personal\b", re.I), "/boot personal", "PERSONAL"),
    (re.compile(r"^/boot\b", re.I),            "/boot",          "PERSONAL"),
    # /resume runs the MATCHING boot and takes that boot's lane, which is not
    # knowable from the prompt. Recorded as pending, never guessed.
    (re.compile(r"^/resume\b", re.I),          "/resume",        None),
    # /rez is the collision-free key for the same door (added 2026-09-01:
    # Claude Code's built-in /resume session picker shadows the skill, so the
    # typed form had to move). Recorded as /resume — one door, two keys.
    (re.compile(r"^/rez\b", re.I),             "/resume",        None),
]


def human_gap(seconds):
    s = int(seconds)
    if s < 60:
        return f"{s}s"
    m, s = divmod(s, 60)
    if m < 60:
        return f"{m}m"
    h, m = divmod(m, 60)
    if h < 24:
        return f"{h}h {m}m" if m else f"{h}h"
    d, h = divmod(h, 24)
    return f"{d}d {h}h" if h else f"{d}d"


def local_now():
    try:
        from zoneinfo import ZoneInfo
        return datetime.now(ZoneInfo(TZ))
    except Exception:
        return datetime.now().astimezone()


def safe_name(session):
    return "".join(c for c in str(session) if c.isalnum() or c in "-_")[:64] or "unknown"


def read_json(path):
    try:
        with open(path, encoding="utf-8") as fh:
            d = json.load(fh)
            return d if isinstance(d, dict) else {}
    except Exception:
        return {}


def write_json(path, data):
    """Best-effort. A state write that fails must not cost the owner a turn."""
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        tmp = path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump(data, fh)
        os.replace(tmp, path)
    except Exception:
        pass


def match_door(prompt):
    p = (prompt or "").lstrip()
    for rx, door, lane in DOORS:
        if rx.match(p):
            return door, lane
    return None, None


def boot_line(boot, now_epoch):
    """One line of truth about boot state. Never claims more than the stamp says."""
    if not boot:
        return ("BOOT: none — no boot has run in this session. "
                "Lane is UNSET unless the owner declared one in conversation.")

    conf_epoch = boot.get("confirmed_epoch")
    if conf_epoch:
        lane = boot.get("confirmed_lane") or "UNKNOWN"
        when = datetime.fromtimestamp(conf_epoch).astimezone()
        age = human_gap(max(0, now_epoch - conf_epoch))
        door = boot.get("confirmed_door") or boot.get("requested_door") or ""
        tail = f" via {door}" if door else ""
        return (f"BOOT: {lane} — confirmed {when.strftime('%H:%M')} ({age} ago){tail}. "
                f"Lane is {lane} unless the owner has since declared another.")

    req_epoch = boot.get("requested_epoch")
    if req_epoch:
        door = boot.get("requested_door") or "a boot door"
        lane = boot.get("requested_lane")
        when = datetime.fromtimestamp(req_epoch).astimezone()
        age = human_gap(max(0, now_epoch - req_epoch))
        target = f" (would set {lane})" if lane else " (lane not knowable from the door)"
        return (f"BOOT: NOT CONFIRMED — {door} was requested {when.strftime('%H:%M')} "
                f"({age} ago){target} and no boot has confirmed since. Either it is "
                f"still running, or it FAILED. Do not act as though state is loaded; "
                f"say so and re-run the door.")

    return ("BOOT: none — no boot has run in this session. "
            "Lane is UNSET unless the owner declared one in conversation.")


RECALL_INDEX = os.path.expanduser("~/.claude/recall-index.json")
RECALL_STALE_HOURS = 26  # one hourly refresh may be missed without alarm


def recall_lines(now_epoch):
    """SLICE 3 -- the index half of recall. owner, 2026-08-26: "the boot will
    surface the semantics while the lane will surface the index every pass so it
    never gets lost."

    Retrieval takes two passes: knowing a thing EXISTS, then finding it. This is
    pass 1, and it is re-injected on EVERY turn on purpose -- that is what makes
    it survive context compaction and a ten-hour session. A session cannot search
    for a rule it does not know exists, and without this there is no search LOOP
    at all: one query, one word-shape, and a near-miss reads as "nothing exists"
    with full confidence. Memories recpFqQlc5uVNwtwJ.

    NO NETWORK HERE, EVER. ragnarok-recall-refresh.py talks to Airtable on a
    timer; this only reads the local cache it writes. Airtable being down must
    mean a stale index, never a stalled turn -- this hook runs in front of every
    prompt of every session on this box.

    Every failure mode renders explicitly rather than vanishing (Memories
    reca2bNBc67US1y3O). Absent, empty and stale are three different facts and
    none of them may look like a healthy read.
    """
    try:
        with open(RECALL_INDEX, encoding="utf-8") as fh:
            data = json.load(fh)
        records = data["records"]
        refreshed = data.get("refreshed", "unknown")
        age_h = (now_epoch - int(data.get("refreshed_epoch", 0))) / 3600.0
    except (OSError, ValueError, KeyError):
        return ["recall: INDEX UNAVAILABLE -- ~/.claude/recall-index.json is missing or"
                " unreadable. This is NOT '0 memories'; run"
                " ~/scripts/ragnarok-recall-refresh.py."]
    if not records:
        return ["recall: INDEX EMPTY -- the cache holds no records, which means it was"
                " written wrong, not that Memories is empty."]

    # STALE GATE (Session Boot Procedure v1.9): expired data never renders as a
    # clean answer. A stale index is still worth showing -- knowing a thing
    # existed yesterday is most of the job -- but it must say so out loud.
    stale = " [STALE since %s -- %.0fh old]" % (refreshed, age_h) if age_h > RECALL_STALE_HOURS else ""

    out = ["recall: Memories INDEX -- %d records, refreshed %s.%s" % (len(records), refreshed, stale),
           "  This is what EXISTS, not what it says. Pull Content by id when one is relevant.",
           "  Never report 'nothing exists' off one query shape without checking this list."]
    # DELIVERY BUDGET (2026-09-04). The harness truncates an oversized hook to a
    # ~2 KB preview + a file path, and the model gets the preview -- so the full
    # index NEVER arrived: measured on this box, 15 of 122 records, with Rule
    # (19), Feedback (14), Project (26) and Reference (41) delivered at ZERO,
    # every turn, in every session since this hook was written. The line above
    # says "surface the index every pass"; the path was surfacing 12% of one
    # section. Prose rules need a reader (Memories recR2JjTLAF00Hn14) -- and
    # this is the reader, so it has to fit.
    #
    # Two mechanical guarantees, in the path rather than in this comment:
    #   1. Names are clipped so the whole index fits the budget.
    #   2. Sections are emitted RULE-FIRST, so if anything is ever dropped it is
    #      Reference and not a rule. Never re-sort this by type name.
    NAME_CLIP = 32
    SECTION_ORDER = ["Rule", "Feedback", "Project", "Owner", "the owner", "Reference"]

    def _clip(n):
        n = " ".join(str(n).split())
        return n if len(n) <= NAME_CLIP else n[:NAME_CLIP - 1] + "\u2026"

    by_type = {}
    for r in records:
        by_type.setdefault(r.get("type") or "other", []).append(r)
    ordered = [t for t in SECTION_ORDER if t in by_type]
    ordered += sorted(t for t in by_type if t not in SECTION_ORDER)

    for t in ordered:
        out.append("  --- %s ---" % t)
        for r in by_type[t]:
            out.append("  %s  %s" % (r.get("id", "?"), _clip(r.get("name", "?"))))
    return out


MEMORIES_CACHE = os.environ.get(
    "RAGNAROK_MEMORIES_CACHE", os.path.expanduser("~/.claude/memories-cache.json"))
MEMORIES_REFRESH = os.path.expanduser("~/scripts/ragnarok-memories-refresh.py")
MEMORIES_REFRESH_AGE = 10 * 60   # older than this: start a refresh in the background
MEMORIES_STALE_HOURS = 26        # older than this: say STALE out loud
MEMORIES_BUDGET = 800            # chars; the harness previews ~2 KB of this WHOLE hook (2026-09-04)


def refresh_memories_detached(now_epoch, cache_epoch):
    """Start ragnarok-memories-refresh WITHOUT waiting for it. The hook still never
    touches the network itself; this turn renders the cache it already has. A
    marker file stops every turn of a burst from starting another ssh."""
    if cache_epoch and now_epoch - cache_epoch < MEMORIES_REFRESH_AGE:
        return
    marker = MEMORIES_CACHE + ".refreshing"
    try:
        if now_epoch - os.path.getmtime(marker) < 60:
            return
    except OSError:
        pass
    try:
        open(marker, "w").close()
        import subprocess
        subprocess.Popen([sys.executable, MEMORIES_REFRESH], stdin=subprocess.DEVNULL,
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                         start_new_session=True)
    except Exception:
        pass


def memory_lines(now_epoch):
    """DURABLE MEMORY, 2026-10-21, the owner: "add bullet pointed lines of the durable
    memory that gets saved to postgres as full data lines". One bullet per LIVE
    Memories row (Postgres, not the Airtable archive), every field but Content:
    Content is the long body and is pulled by id when a row is relevant.

    The 2026-10-20 removal (below, in main) was of a week-stale cache of 157
    clipped titles. This differs on both counts: it is refreshed from the live
    table every 10 minutes, and it carries the description, not a clipped name.
    Absent, empty and stale still render as three different facts."""
    try:
        with open(MEMORIES_CACHE, encoding="utf-8") as fh:
            data = json.load(fh)
        records = data["records"]
        cache_epoch = float(data.get("refreshed_epoch", 0))
        refreshed = data.get("refreshed", "unknown")
    except (OSError, ValueError, KeyError, TypeError):
        refresh_memories_detached(now_epoch, 0)
        return ["MEMORY: cache not built yet -- a refresh has been started. This is NOT '0 memories'."]
    refresh_memories_detached(now_epoch, cache_epoch)
    age_h = (now_epoch - cache_epoch) / 3600.0
    stale = f" [STALE -- {age_h:.0f}h old]" if age_h > MEMORIES_STALE_HOURS else ""
    if not records:
        return [f"MEMORY: the live Memories table is empty (read {refreshed}){stale}."]
    out = [f"MEMORY (durable, live Postgres Memories, {len(records)} rows, read {refreshed}){stale}:"]
    used, shown = 0, 0
    for r in records:
        line = (f"- #{r.get('id')} [{r.get('type') or '?'}] {' '.join(str(r.get('name') or '?').split())}"
                f" -- {' '.join(str(r.get('description') or '').split())}"
                f" (created {r.get('created') or '?'}, updated {r.get('updated') or '?'})")
        if used + len(line) > MEMORIES_BUDGET:
            break
        out.append(line)
        used += len(line)
        shown += 1
    if shown < len(records):
        out.append(f"- ...{len(records) - shown} more not shown (budget). Read them with list_records on Memories.")
    return out


LESSONS_DB = os.path.expanduser("~/scripts/lessons/lessons.jsonl")
LESSONS_LIMIT = 5


def lesson_lines():
    """The box remembering what the model cannot.

    A model's weights are frozen between sessions, so nothing it works out
    stays worked out. The only thing that changes the next session's
    behaviour is what sits in front of it BEFORE it speaks — which is this
    envelope. owner, 2026-09-02: "make something so you stay persistent and
    learn from your mistakes."

    Deliberately capped and newest-first. An unbounded list becomes another
    CLAUDE.md: history that reads as instruction (Ruleset v4.11). Five lines
    get read every turn; fifty get skipped.

    NEVER RAISES and never touches the network. This hook runs in front of
    every prompt the owner types; a lessons file that breaks it would take the
    boot line, the recall index and the lane banner down with it.
    """
    try:
        if not os.path.exists(LESSONS_DB):
            return []
        rows = []
        with open(LESSONS_DB) as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    r = json.loads(line)
                except ValueError:
                    continue
                if not r.get("retired"):
                    rows.append(r)
        if not rows:
            return []
        # Recurrence outranks recency: a mistake made three times is more
        # worth a line than a fresh one made once.
        rows.sort(key=lambda r: (r.get("hits", 1), r.get("added", "")), reverse=True)
        out = ["lessons: %d active — mistakes already made; do not repeat them." % len(rows)]
        for r in rows[:LESSONS_LIMIT]:
            hits = r.get("hits", 1)
            tag = (" x%d" % hits) if hits > 1 else ""
            out.append("  [%s%s] %s" % (r.get("source", "?"), tag, r.get("text", "")[:400]))
        if len(rows) > LESSONS_LIMIT:
            out.append("  (%d more: ~/scripts/lessons/lesson list)" % (len(rows) - LESSONS_LIMIT))
        return out
    except Exception:                                             # noqa: BLE001
        return []


def where_line(session, cwd):
    """Which computer the last command ran on, from ragnarok-where.py's state (2026-10-23)."""
    try:
        import importlib.util
        spec = importlib.util.spec_from_file_location(
            "ragnarok_where", os.path.join(os.path.dirname(os.path.abspath(__file__)), "ragnarok-where.py"))
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        return mod.line(session, cwd)
    except Exception:
        return "machine: unknown (ragnarok-where.py unreadable)"


def main():
    # SWITCHED OFF FOR A SEAT THAT IS NOT CHRIS TYPING (2026-09-10, intent
    # #127). This is a USER-scope hook, so it fires on every turn of every
    # Claude Code session on this box -- including converse's, the Telegram
    # thread, where it was measured at 5,216 tokens EVERY TURN against the
    # ~1,660 that converse itself injects per turn. Everything in this envelope
    # is for a session the owner is driving: the lane banner, the boot stamp, the
    # Memories index. A phone conversation needs none of it and converse
    # already strips the banner back out of the reply before it reaches him.
    # Opt-out rather than allowlist: a new seat should get the envelope by
    # default and have to say it does not want it.
    if os.environ.get("RAGNAROK_TURN_ENVELOPE", "").strip().lower() == "off":
        return  # emit nothing, cost nothing
    try:
        raw = sys.stdin.read()
        payload = json.loads(raw)
    except Exception:
        return  # unreadable stdin: emit nothing, cost nothing

    dbg = os.environ.get("RAGNAROK_TURN_DEBUG")
    if dbg:
        try:
            with open(dbg, "a", encoding="utf-8") as fh:
                fh.write(raw.rstrip() + "\n")
        except Exception:
            pass

    session = payload.get("session_id") or "unknown"
    name = safe_name(session)
    turn_path = os.path.join(TURN_DIR, name + ".json")
    boot_path = os.path.join(BOOT_DIR, name + ".json")

    now = local_now()
    now_epoch = datetime.now(timezone.utc).timestamp()

    # --- turn gap (slice 1) ---
    prev = read_json(turn_path).get("last_turn_epoch")
    write_json(turn_path, {"last_turn_epoch": now_epoch})
    if prev is None:
        gap = "first turn of this session"
    else:
        delta = now_epoch - prev
        gap = human_gap(delta) if delta >= 0 else "unknown (clock moved backwards)"

    # --- boot stamp (slice 2) ---
    boot = read_json(boot_path)
    door, lane = match_door(payload.get("prompt"))
    if door and door != "/boot flipped":
        # Record the REQUEST. Never the confirmation -- this hook cannot know
        # whether the reads landed, and stamping success here would fake a boot.
        boot = {
            "requested_epoch": now_epoch,
            "requested_door": door,
            "requested_lane": lane,          # None for /resume: not knowable yet
        }
        write_json(boot_path, boot)

    lines = [
        "RAGNAROK TURN ENVELOPE (deterministic facts, injected by harness hook — not from the model)",
        f"host time: {now.strftime('%A %Y-%m-%d %I:%M %p %Z')}",
        f"gap since your last turn: {gap}",
        f"cwd: {payload.get('cwd') or 'unknown'}",
        where_line(session, payload.get("cwd")),
        boot_line(boot, now_epoch),
        # MEMORIES INDEX REMOVED FROM THE ENVELOPE 2026-10-20, on the owner's word:
        # "drop the memory list". Its cache (~/.claude/recall-index.json) had not
        # refreshed since 2026-10-13, so every turn carried a week-stale list of
        # 157 titles, and the all-caps ones pulled sessions into the system's
        # voice ("it makes you talk weird"). recall_lines() and RECALL_INDEX are
        # left in place; the memories themselves are untouched in Yggdrasil.
        # LESSONS REMOVED FROM THE ENVELOPE 2026-09-11, on the owner's word:
        # "remove the lessons block too", following "remove everything that
        # changes the way you talk."
        #
        # lesson_lines() rendered up to three past mistakes before every prompt,
        # headed "mistakes already made; do not repeat them." Two of the three
        # live ones were the owner's own corrections, and one of those instructed a
        # phrasing -- say 'I am guessing' in the sentence itself -- which is the
        # kind of thing this removal is about.
        #
        # NOTHING WAS DELETED. ~/scripts/lessons/lessons.jsonl still holds all 5,
        # and ~/scripts/lessons/lesson still reads them. The store and its reader
        # are untouched; only the automatic injection is gone. A session that
        # wants them can run the command.
        #
        # lesson_lines() and LESSONS_DB are deliberately LEFT IN PLACE rather than
        # deleted, so re-enabling this is one line and not a rebuild.
    ]

    # REMINDERS, 2026-10-21, the owner: "the hook and envelope are reminders to boot
    # and to save memory". Facts about what to do next, not how to sound.
    confirmed = bool((boot or {}).get("confirmed_epoch"))
    if not confirmed and not door:
        lines.append("reminder: no confirmed boot -- /boot (or /boot business | /boot system) loads live state.")
    # RAGNAROK_TURN_FACTS_ONLY=1 (rewired 2026-11-08): time, gap, where, boot only. The memory block is what got
    # this hook pulled on 10-23 (stale content riding every turn); lessons stay off per the owner 09-11.
    if not os.environ.get("RAGNAROK_TURN_FACTS_ONLY"):
        lines += memory_lines(now_epoch)
    lines.append("reminder: save memory -- when the owner states a durable fact, rule or preference, write it to"
                 " Memories (Yggdrasil create_records, table Memories) and say so. /save is the transcript, not memory.")

    # THE LANE BANNER INSTRUCTION WAS REMOVED HERE, 2026-09-11, on the owner's word:
    # "remove everything that changes the way you talk."
    #
    # What stood here told every seat to open every reply with a bold
    # ━━ LANE: ... ━━ line. It was the only thing in this envelope that dictated
    # FORM rather than supplying FACT. Everything above it -- the boot state, the
    # Memories index, the lessons -- tells a session what is true; that block told
    # it how to sound.
    #
    # Two independent seats asked for this before the owner did. Grok, asked whether it
    # wanted the RAGNAROK skills: "the lane banner and Write Log receipt belong on
    # RAGNAROK sessions ... Reach is fine; silent always-on format law is not."
    # Codex agreed unprompted. The owner ruled yes to scoping it (Reminders
    # recE9rlB3SCUBfgLk), then went further and asked for its removal.
    #
    # THE LANE ITSELF IS NOT GONE. boot_line() above still reports which lane a
    # session booted into and still renders NOT CONFIRMED for an unstamped one.
    # The fact survives; only the instruction to perform it is gone.

    if door and door != "/boot flipped":
        lines += [
            "",
            f"BOOT DOOR DETECTED THIS TURN: {door}. After the boot's reads have actually",
            "landed — and only then — record it so later turns stop guessing:",
            "  ~/scripts/ragnarok-boot-stamp confirm --lane <PERSONAL|BUSINESS|SYSTEM>"
            f" --door '{door}'",
            "If the boot fails, do NOT run it. An unconfirmed request renders as a failed",
            "boot on every later turn, which is the correct and intended outcome.",
        ]

    # CHRIS SEES IT TOO (2026-10-23, "make the hook show for both of us"):
    # additionalContext reaches only the model. systemMessage is the one field a
    # hook can put on the owner's screen, so they get the same facts in one line.
    seen = " · ".join([l.strip() for l in lines[1:5] if l.strip()]
                      + [lines[5].split(". ")[0]])   # boot line, first sentence only
    print(json.dumps({
        "systemMessage": seen,
        "hookSpecificOutput": {
            "hookEventName": "UserPromptSubmit",
            "additionalContext": "\n".join(lines),
        }
    }))


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass  # never let this hook cost a prompt
    finally:
        sys.exit(0)
