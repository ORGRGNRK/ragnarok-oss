#!/usr/bin/env python3
"""room — the shared room for the owner and their AIs (lives on Alexus).

Everyone writes only to their own file, data/<login>.jsonl, created mode 0644 in a sticky folder,
so only that login can change it. The author shown for every message is the file's OWNER (from the
filesystem), not anything written inside the message, so nobody can post as someone else through
this command. (The login that owns the room folder is shown as "owner".) A file that someone else can write is marked unverified.

  room say "text"          post a message            (text "-" = read it from stdin)
  room task "text"         post a task; prints its id
      [--outcome "what must be true when it's done"]
      [--proof "how that is shown"]...          (one per proof; "claim :: verify: command" makes it a checked line)
      [--wall "a line the work must not cross"]...  enforced by the runner when written as one of:
                           no-network | read-only | write-only: PATHS | app-only: APPS | deny: REGEX | once: REGEX
                           | no-tool: TOOLS        (anything else is plain text: in the brief, not enforced)
                           a task with --outcome needs at least one --proof
  room task --spec -       the same as JSON on stdin: {"text", "outcome", "proof": [..], "walls": [..]}
  room claim ID            say you're working on task ID   (--reopen to claim a task that's done)
  room done ID ["note"]    mark task ID done
  room read [N]            last N messages (default 20)
  room tasks               open and claimed tasks
  room watch               print new messages as JSON lines, forever (Heimdall uses this)
  room whoami              who the room thinks you are
Add --json to read/tasks for machine-readable output (with say/task it is just text).
"""
import datetime, glob, json, os, pwd, re, secrets, sys, time

# Deployed as <room>/bin/room next to <room>/data; RAGNAROK_ROOM overrides.
BASE = os.environ.get("RAGNAROK_ROOM", os.path.join(os.path.dirname(os.path.dirname(os.path.realpath(__file__))), "data"))
try:
    NAMES = {pwd.getpwuid(os.stat(BASE).st_uid).pw_name: "owner"}   # whoever owns the room folder shows as "owner"
except (OSError, KeyError):
    NAMES = {}


def name_of(uid):
    try:
        n = pwd.getpwuid(uid).pw_name
    except KeyError:
        n = f"uid{uid}"
    return NAMES.get(n, n)


def own_file():
    """This login's file. If someone else already made a file with our name, use (or make) another one
    that we own; the author shown is always the file's owner, so a squatted name can't fake anything."""
    uid = os.geteuid()
    me = pwd.getpwuid(uid).pw_name
    candidates = [os.path.join(BASE, me + ".jsonl")] + sorted(glob.glob(os.path.join(BASE, me + "-*.jsonl")))
    for p in candidates:
        if os.path.exists(p) and os.stat(p).st_uid == uid:
            break
    else:
        p = candidates[0]
        if os.path.exists(p):   # taken by someone else
            p = os.path.join(BASE, f"{me}-{secrets.token_hex(3)}.jsonl")
        os.close(os.open(p, os.O_WRONLY | os.O_CREAT | os.O_APPEND | os.O_EXCL, 0o644))
    if os.stat(p).st_mode & 0o777 != 0o644:
        try:
            os.chmod(p, 0o644)   # only the owner can write (drops group write inherited from the folder's ACL)
        except PermissionError:
            pass                 # already marked append-only (chattr +a): its mode is fixed, and it can only grow
    return p


def now():
    return datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


# Walls the agent runner (heimdall bin/ragnarok-agent, parse_wall) enforces. Keep the two in step.
ENFORCED_WALL = re.compile(r"^(no-network|read-only)$|^(write-only|app-only|deny|once|no-tool)\s*:\s*\S", re.I)


def clean_list(v, name):
    if v is None:
        return []
    if not isinstance(v, list) or not all(isinstance(x, str) for x in v):
        sys.exit(f"room: {name} must be a list of text lines")
    return [" ".join(x.split()) for x in v if x.strip()]


def task_spec(text, outcome, proof, walls):
    """outcome / proof / walls: the task's domain. What must be true, how it is shown, what the work must not cross.
    How to get there is left to whoever does it."""
    spec = {}
    outcome = " ".join((outcome or "").split())
    proof, walls = clean_list(proof, "proof"), clean_list(walls, "walls")
    if (proof or walls) and not outcome:
        sys.exit("room: --proof and --wall need an --outcome")
    if outcome and not proof:
        sys.exit("room: a task with an --outcome needs at least one --proof (how it is shown to be done)")
    if outcome:
        spec = {"outcome": outcome, "proof": proof, "walls": walls}
        loose = [w for w in walls if not ENFORCED_WALL.match(w)]
        if loose:
            print("room: these walls are plain text, so the runner can't enforce them: " + "; ".join(loose)
                  + "\n      enforced forms: no-network | read-only | write-only: PATHS | app-only: APPS | deny: REGEX"
                  " | once: REGEX | no-tool: TOOLS", file=sys.stderr)
    if not text.strip() and outcome:
        text = outcome
    return text, spec


def post(kind, text, ref=None, extra=None):
    if text == "-":
        if sys.stdin.isatty():   # D8: don't sit silently waiting for typed input
            sys.exit(f"usage: room {kind} \"text\"   (or pipe the text in with: room {kind} -)")
        text = sys.stdin.read()
    text = text.strip()
    if not text and kind in ("say", "task"):
        sys.exit("room: nothing to post")
    rec = {"ts": now(), "id": secrets.token_hex(4), "type": kind, "text": text, "host": os.uname().nodename}
    if ref:
        rec["ref"] = ref
    if extra:
        rec.update(extra)
    via = os.environ.get("RAGNAROK_ROOM_VIA")
    if via:
        rec["via"] = via
    try:
        os.makedirs(BASE, exist_ok=True)   # D2: a missing room folder is created when posting
        target = own_file()
    except OSError as e:
        sys.exit(f"room: can't write to the room folder {BASE}: {e.strerror}")
    with open(target, "a") as f:
        f.write(json.dumps(rec) + "\n")
    print(rec["id"])


WARNED = set()


def warn_once(path, e):
    if path not in WARNED:
        WARNED.add(path)
        print(f"room: skipping {os.path.basename(path)}: {e.strerror or e}", file=sys.stderr)


def records_from(path, start=0):
    """D1: an unreadable file (permissions, a folder named *.jsonl) is skipped with one warning, not a traceback."""
    try:
        st = os.stat(path)
        if not os.path.isfile(path):
            raise IsADirectoryError(21, "not a regular file")
        with open(path, "rb") as f:
            f.seek(start)
            data = f.read()
    except OSError as e:
        warn_once(path, e)
        return [], start
    author = name_of(st.st_uid)
    trusted = not (st.st_mode & 0o022)
    out = []
    end = start + data.rfind(b"\n") + 1 if b"\n" in data else start
    for line in data[: end - start].splitlines():
        try:
            r = json.loads(line)
        except ValueError:
            continue
        if not isinstance(r, dict) or not r.get("type") or ("text" not in r and r.get("type") not in ("claim", "done")):
            continue   # D7: {} or junk lines aren't messages
        r["by"] = author if trusted else author + "?"
        if not trusted:
            r["unverified"] = True
        out.append(r)
    return out, end


def require_room():
    if not os.path.isdir(BASE):   # D2: a missing folder is an error, not an empty room
        print(f"room: room folder {BASE} not found", file=sys.stderr); sys.exit(2)


def size_of(p):
    try:
        return os.path.getsize(p)
    except OSError:
        return 0


def load():
    out = []
    for p in glob.glob(os.path.join(BASE, "*.jsonl")):
        out += records_from(p)[0]
    # N9: a record whose ts isn't text (a number, null) can't be ordered with the rest; it is left out
    return sorted((r for r in out if isinstance(r.get("ts"), str)), key=lambda r: r["ts"])


def spec_lines(r, indent):
    out = []
    if r.get("outcome"):
        out.append(f"{indent}outcome: {r['outcome']}")
    as_list = lambda v: [v] if isinstance(v, str) else (v if isinstance(v, list) else [])   # N11: "run" is one proof
    for x in as_list(r.get("proof")):
        out.append(f"{indent}proof:   {x}")
    for x in as_list(r.get("walls")):
        out.append(f"{indent}wall:    {x}")
    return out


def show(r):
    t = r.get("ts", "")[11:19]
    k = r.get("type")
    ref = f" [{r['ref']}]" if r.get("ref") else ""
    tag = {"say": "", "task": f"TASK {r.get('id')}: ", "claim": "claimed", "done": "done"}.get(k, k + ": ")
    body = r.get("text", "")
    if k in ("claim", "done"):
        body = f"{tag}{ref}" + (f" — {body}" if body else "")
    else:
        body = tag + body
    print(f"{t}  {r.get('by', '?'):>8}  {body}")
    if k == "task":
        for line in spec_lines(r, " " * 20):
            print(line)


def task_states(recs):
    tasks = {}
    for r in recs:
        if r.get("type") == "task":
            if not isinstance(r.get("id"), str) or not r["id"]:
                continue   # N10: a task with no id can't be claimed or finished; left out
            tasks[r["id"]] = {"id": r["id"], "text": r.get("text", ""), "by": r.get("by", "?"), "ts": r.get("ts", ""), "state": "open", "owner": None}
            for f in ("outcome", "proof", "walls"):
                if r.get(f):
                    tasks[r["id"]][f] = [r[f]] if f != "outcome" and isinstance(r[f], str) else r[f]   # N11
        elif r.get("type") in ("claim", "done") and r.get("ref") in tasks:
            t = tasks[r["ref"]]
            t["state"] = "claimed" if r["type"] == "claim" else "done"
            t["owner"] = r["by"]
    return list(tasks.values())


def backlog_of(recs, keep=50, hours=48):
    """D6: the last `keep` messages, everything from the last 48 h, and every task record (with its claims/done),
    so open tasks never drop out of the backlog."""
    cut = (datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(hours=hours)).isoformat().replace("+00:00", "Z")
    tail = set(id(r) for r in recs[-keep:])
    return [r for r in recs if id(r) in tail or r.get("ts", "") >= cut or r.get("type") in ("task", "claim", "done")]


def watch():
    require_room()
    offsets = {}
    recs = load()
    for r in backlog_of(recs):
        print(json.dumps(r), flush=True)
    for p in glob.glob(os.path.join(BASE, "*.jsonl")):
        offsets[p] = size_of(p)
    while True:
        new = []
        for p in glob.glob(os.path.join(BASE, "*.jsonl")):
            size = size_of(p)
            start = offsets.get(p, 0)
            if size < start:
                start = 0
            if size > start:
                got, end = records_from(p, start)
                offsets[p] = end
                new += got
        for r in sorted(new, key=lambda r: r.get("ts", "")):
            print(json.dumps(r), flush=True)
        time.sleep(1)


def main(argv):
    if not argv or argv[0] in ("-h", "--help", "help"):
        print(__doc__); return
    cmd, rest = argv[0], argv[1:]
    # D4: --json is a flag only for read/tasks; in a message it's just text
    as_json = cmd in ("read", "tasks") and "--json" in rest
    if cmd in ("read", "tasks"):
        rest = [a for a in rest if a != "--json"]
    reopen = cmd == "claim" and "--reopen" in rest
    if cmd == "claim":
        rest = [a for a in rest if a != "--reopen"]
    if cmd == "say":
        post("say", " ".join(rest) if rest else "-")
    elif cmd == "task":
        if rest[:2] == ["--spec", "-"]:
            if sys.stdin.isatty():
                sys.exit('usage: echo \'{"text": "...", "outcome": "...", "proof": ["..."], "walls": ["..."]}\' | room task --spec -')
            try:
                d = json.loads(sys.stdin.read())
            except ValueError as e:
                sys.exit(f"room: --spec - needs JSON on stdin ({e})")
            if not isinstance(d, dict):
                sys.exit("room: --spec - needs a JSON object")
            text, spec = task_spec(str(d.get("text") or ""), d.get("outcome"), d.get("proof"), d.get("walls"))
            if not text.strip():
                sys.exit("room: nothing to post")
            post("task", text, extra=spec)
            return
        words, outcome, proof, walls = [], None, [], []
        it = iter(rest)
        for a in it:
            if a in ("--outcome", "--proof", "--wall"):
                v = next(it, None)
                if v is None:
                    sys.exit(f"room: {a} needs text after it")
                if a == "--outcome":
                    outcome = v
                elif a == "--proof":
                    proof.append(v)
                else:
                    walls.append(v)
            else:
                words.append(a)
        if outcome is None and not proof and not walls:
            post("task", " ".join(words) if words else "-")
        else:
            text, spec = task_spec(" ".join(words), outcome, proof, walls)
            post("task", text or "-", extra=spec)
    elif cmd in ("claim", "done"):
        if not rest:
            sys.exit(f"room: {cmd} needs a task id")
        require_room()
        # D5: only real tasks, and a finished task isn't silently reopened
        t = {x["id"]: x for x in task_states(load())}.get(rest[0])
        if t is None:
            sys.exit(f"room: no task with id {rest[0]!r} (see: room tasks)")
        if cmd == "claim" and t["state"] == "done" and not reopen:
            sys.exit(f"room: task {rest[0]} is already done; use: room claim {rest[0]} --reopen")
        if cmd == "done" and t["state"] == "done":
            sys.exit(f"room: task {rest[0]} is already done")
        post(cmd, " ".join(rest[1:]), ref=rest[0])
    elif cmd == "read":
        require_room()
        n = 20
        if rest:   # D3: N must be a positive whole number
            if not rest[0].isdigit() or int(rest[0]) < 1:
                sys.exit(f"room: read N needs a positive whole number, not {rest[0]!r}")
            n = int(rest[0])
        recs = load()[-n:]
        if as_json:
            print(json.dumps(recs))
        else:
            for r in recs:
                show(r)
    elif cmd == "tasks":
        require_room()
        ts = [t for t in task_states(load()) if t["state"] != "done"]
        if as_json:
            print(json.dumps(ts))
        else:
            for t in ts:
                print(f"{t['id']}  {t['state']:>7}{' by ' + t['owner'] if t['owner'] else ''}  ({t['by']}) {t['text']}")
                for line in spec_lines(t, "          "):
                    print(line)
            if not ts:
                print("no open tasks")
    elif cmd == "watch":
        watch()
    elif cmd == "whoami":
        print(name_of(os.geteuid()))
    else:
        sys.exit(f"room: unknown command {cmd!r}. Try: room help")


if __name__ == "__main__":
    try:
        main(sys.argv[1:])
    except (BrokenPipeError, KeyboardInterrupt):
        pass
