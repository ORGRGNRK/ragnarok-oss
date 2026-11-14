#!/usr/bin/env python3
"""Heimdall's link to alexus-core chat.

    alexus-chat-bridge.py prep          -> JSON {system, user_name, persona}   (persona prompt + silent boot context)
    alexus-chat-bridge.py seal < msgs   -> JSON {packet_id, sha256, archive_path, summary, next_steps}  (Switch Packet)

prep reuses alexus-core/bin/ragnarok_bridge.py unchanged (profile, persona prompt, silent /boot + /resume).
Never runs the interactive setup interview: no profile = default tsundere persona, nothing written.

seal does what ragnarok_bridge.auto_switch_and_end does (summary by llama3.2:3b, mark old packets superseded,
insert the new Switch Packet, archive the transcript with its SHA-256, insert a session_transcripts row), with one
change: the SQL goes to psql on stdin, with the text inside random dollar-quotes, instead of inside a remote shell
command, so nothing the model writes can be run as a shell command on Alexus.
Note (same as alexus-core today): this writes straight to Postgres, not through the HQ MCP, so it does not get an
HQ write_log receipt.
"""
import datetime, glob, hashlib, json, os, re, secrets, subprocess, sys, urllib.request

def _resolve_core_bin():
    here = os.path.dirname(os.path.abspath(__file__))
    real = os.path.dirname(os.path.realpath(__file__))
    for cand in (
        os.environ.get("ALEXUS_CORE_BIN", ""),
        os.path.abspath(os.path.join(here, "../alexus-core/bin")),
        os.path.abspath(os.path.join(real, "../../../agents/alexus-core/bin")),
        os.path.expanduser("~/Developer/ragnarok/agents/alexus-core/bin"),
        os.path.expanduser("~/Developer/alexus-core/bin"),
    ):
        if cand and os.path.isfile(os.path.join(cand, "ragnarok_bridge.py")):
            return cand
    return os.path.expanduser("~/Developer/alexus-core/bin")


CORE_BIN = _resolve_core_bin()
PENDING = os.path.expanduser("~/.ragnarok/chat-seal-pending")   # seals that couldn't reach the database (retried)
PROJECT = "alexus-core"


def fail(msg):
    """One plain line for the app to show, never a traceback."""
    print(msg, file=sys.stderr)
    sys.exit(1)


def bridge():
    """H3: alexus-core is loaded only when needed, with a clear message if it isn't there."""
    sys.path.insert(0, CORE_BIN)
    try:
        import ragnarok_bridge
    except ImportError as e:
        fail(f"alexus-core isn't checked out at {CORE_BIN} ({e})")
    return ragnarok_bridge


def alexus_host():
    """ALEXUS_HOST, read the same way as ragnarok_bridge (environment, then ~/.ragnarok/local.conf, then the tailnet address)."""
    return bridge().ALEXUS_HOST


def ollama_base():
    """H4: OLLAMA_HOST may be in Ollama's own form (0.0.0.0:11434, host:port, no scheme)."""
    a = alexus_host()
    h = os.environ.get("OLLAMA_HOST", "").strip() or f"http://{a}:11434"
    if "://" not in h:
        h = "http://" + h
    h = h.rstrip("/").replace("://0.0.0.0", f"://{a}")
    return h


def owner_name():
    """OWNER_NAME from ~/.ragnarok/local.conf, else the first name on this login, else "you"."""
    try:
        for line in open(os.path.expanduser("~/.ragnarok/local.conf"), encoding="utf-8"):
            k, sep, v = line.strip().partition("=")
            if sep and k.strip() == "OWNER_NAME" and re.fullmatch(r"[A-Za-z][A-Za-z .'-]{0,39}", v.strip().strip("\"'")):
                return v.strip().strip("\"'")
    except OSError:
        pass
    try:
        import pwd
        first = pwd.getpwuid(os.getuid()).pw_gecos.split(",")[0].split()[0]
        if re.fullmatch(r"[A-Za-z][A-Za-z.'-]{0,39}", first):
            return first
    except (KeyError, IndexError):
        pass
    return "you"


def prep():
    rb = bridge()
    profile = rb.load_profile() or {"user_name": owner_name(), "persona_id": "tsundere"}
    system = rb.get_system_prompt_for_profile(profile)
    boot = rb.silent_boot(project_slug=PROJECT)
    print(json.dumps({"system": f"{system}\n\n{boot}", "user_name": profile.get("user_name", owner_name()),
                      "persona": profile.get("persona_id", "tsundere")}))


def q(text):
    """Dollar-quote text with a random tag that does not occur in it."""
    while True:
        tag = "h" + secrets.token_hex(6)
        if f"${tag}$" not in text:
            return f"${tag}${text}${tag}$"


class Refused(RuntimeError):
    """The database answered and said no (bad SQL, a constraint): sending it again won't help."""


def psql(rb, sql):
    try:
        r = subprocess.run(rb.on_alexus("docker exec -i ck-ragnarok-hq-postgres-1 psql -U kit_admin -d clientdata -v ON_ERROR_STOP=1 -q -t -A", timeout=5),
                           input=sql, capture_output=True, text=True, timeout=20)
    except (OSError, subprocess.TimeoutExpired) as e:
        raise RuntimeError(f"couldn't reach Alexus ({e})")
    if r.returncode == 255:
        raise RuntimeError("Alexus is unreachable over ssh")
    if r.returncode != 0:
        raise Refused(f"the database refused it: {(r.stderr.strip().splitlines() or ['exit %d' % r.returncode])[-1][:200]}")
    return r.stdout.strip()


def retry_pending(rb):
    """H2: seals saved while Alexus was unreachable are sent now, one at a time, oldest first.
    N14: one the database refuses moves to pending/failed/ (kept, not retried) and the rest still go;
    if Alexus can't be reached, all of them stay for next time."""
    sent = 0
    for f in sorted(glob.glob(os.path.join(PENDING, "*.sql"))):
        try:
            with open(f) as h:
                psql(rb, h.read())
            os.remove(f); sent += 1
        except Refused as e:
            bad = os.path.join(PENDING, "failed")
            os.makedirs(bad, mode=0o700, exist_ok=True)
            os.replace(f, os.path.join(bad, os.path.basename(f)))
            print(f"a saved summary was refused by the database and moved to {bad}: {e}", file=sys.stderr)
        except (OSError, RuntimeError):
            break
    return sent


def seal():
    try:
        messages = json.load(sys.stdin)
    except ValueError:
        fail("seal: the chat sent to the bridge wasn't valid JSON")
    if not isinstance(messages, list):
        fail("seal: expected a list of chat messages")
    messages = [m for m in messages if isinstance(m, dict)]
    if not any(m.get("role") == "user" for m in messages):
        print(json.dumps({"skipped": "nothing was said"})); return
    rb = bridge()
    # N13: the app passes its chat's session id; a newer seal of the same chat replaces one still waiting to be sent
    session = re.sub(r"[^A-Za-z0-9]", "", sys.argv[2])[:40] if len(sys.argv) > 2 else ""
    # H1: unique even for two seals in the same second
    packet_id = f"SW-{datetime.datetime.now():%Y%m%d-%H%M%S}-{secrets.token_hex(2)}-{PROJECT}"
    prompt = ("Summarize this AI chat session in two concise sections:\n"
              "SUMMARY_STATE: (3-4 bullet points of what was decided, built, verified, or discussed)\n"
              "NEXT_STEPS: (2-3 immediate actionable next steps)\n\nConversation:\n")
    prompt += "".join(f"{str(m.get('role', '?')).upper()}: {m.get('content', '')}\n" for m in messages[-10:] if m.get("role") != "system")
    try:
        req = urllib.request.Request(f"{ollama_base()}/api/generate", headers={"Content-Type": "application/json"},
                                     data=json.dumps({"model": "llama3.2:3b", "prompt": prompt, "stream": False}).encode())
        with urllib.request.urlopen(req, timeout=60) as r:
            text = json.loads(r.read())["response"].strip()
    except Exception as e:  # keep sealing even if the summary fails, and say so
        text = f"Session closed from Heimdall. (Summary failed: {e})"
    state, nxt = text, "Continue on next boot."
    if "NEXT_STEPS:" in text:
        a, b = text.split("NEXT_STEPS:", 1)
        state, nxt = a.replace("SUMMARY_STATE:", "").strip(), b.strip()

    os.makedirs(rb.TRANSCRIPTS_DIR, exist_ok=True)
    path = os.path.join(rb.TRANSCRIPTS_DIR, f"{packet_id}.jsonl")
    content = json.dumps(messages)
    with open(path, "x") as f:   # H1: never replace another chat's transcript
        f.write(content)
    sha = hashlib.sha256(content.encode()).hexdigest()

    sql = f"""BEGIN;
UPDATE switch_packets SET resume_target = false, status = 'Superseded' WHERE project_slug = {q(PROJECT)} AND resume_target = true;
INSERT INTO switch_packets (packet_id, project_slug, ai_actor, resume_target, status, summary_state, next_steps)
  VALUES ({q(packet_id)}, {q(PROJECT)}, 'Alexus (Llama 3.2) via Heimdall', true, 'Active Target', {q(state)}, {q(nxt)});
INSERT INTO session_transcripts (session_id, project_slug, ai_actor, save_type, archive_path, transcript_sha256, notes)
  VALUES ({q(packet_id)}, {q(PROJECT)}, 'Alexus', 'Session Close (/end)', {q(path)}, {q(sha)}, 'Sealed from Heimdall chat');
COMMIT;"""
    retry_pending(rb)
    try:
        psql(rb, sql)
    except RuntimeError as e:
        # H2: keep it to send next time, and say so in one line (the app keeps the chat open)
        os.makedirs(PENDING, mode=0o700, exist_ok=True)
        pf = os.path.join(PENDING, packet_id + (f".{session}" if session else "") + ".sql")
        if session:
            for old in glob.glob(os.path.join(PENDING, f"*.{session}.sql")):
                os.remove(old)   # the same chat sealed again while offline: only the newest summary is sent
        with open(os.open(pf, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "w") as h:
            h.write(sql)
        fail(f"couldn't save the summary to the database: {e}. The transcript is saved and the summary will be sent next time.")
    back = psql(rb, f"SELECT count(*) FROM switch_packets WHERE packet_id = {q(packet_id)} AND resume_target;")
    print(json.dumps({"packet_id": packet_id, "sha256": sha, "archive_path": path, "summary": state,
                      "next_steps": nxt, "read_back": back == "1"}))


if __name__ == "__main__":
    {"prep": prep, "seal": seal}.get(sys.argv[1] if len(sys.argv) > 1 else "", lambda: sys.exit(__doc__))()
