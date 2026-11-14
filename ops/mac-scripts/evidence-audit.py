#!/usr/bin/env python3
"""Stop hook: audit the finished answer against this turn's tool output.

R-16 companion to evidence-rules.py. The rules hook only reminds; this one
checks. When a turn ends, it takes the answer plus every tool result since
the user's last message and asks the local referee on Alexus (Ollama,
GJALLARHORN_MODEL) which claims nothing in that output supports. No Claude model is
called: the web-search helper (start_search) fetches DuckDuckGo directly. If any are flagged, the stop is blocked and the flags go back to
the model to correct (check it, or label it unverified).

Limits, on purpose:
- Turns with no tool calls are skipped (nothing to check against; this is
  aimed at describing files, images, logs and command output).
- Very short answers (< SHORT_ANSWER chars) and bare acknowledgements ("✓")
  are skipped, unless they claim something was done/fixed/verified.
- One audit per turn. The correction pass runs with stop_hook_active set and
  is not re-audited, so it can't loop.
- Fails open. Any error or timeout lets the answer through and is logged.
- The inner `claude -p` runs with EVIDENCE_AUDIT_INNER=1, which both hooks
  check first, so it never audits itself.

2026-10-31 changes (the owner: "see if all of the stuff enforcing claude..."):
- Bigger evidence window (tool INPUTS too: a heredoc or Write body is the
  proof of what was written), plus an exact-match search of the FULL,
  unclipped text of every tool call in the session for the answer's
  specific tokens; matches that the clipped view lost are added as snippets.
- Images (Read of a .png/.jpg, any image block in a tool result, screenshots
  pasted by the owner) are evidence the auditor cannot see. Claims read off them
  go to "unchecked_image" (logged, never blocks), not "unsupported".
- Only past/present factual claims are audited. Plans, intentions,
  questions, hypotheticals and hedged inference are dropped (prompt rule
  plus a deterministic filter on the flagged quote).
- A user message with images (list content) now starts a turn, like a
  plain-text prompt.

Log: ~/.claude/evidence-audit.log (one JSON line per run).
Dry run (no model call, prints the prompt): EVIDENCE_AUDIT_DRYRUN=1.
"""
import json
import os
import re
import subprocess
import sys
import tempfile
import time
import urllib.request

LOG = os.path.expanduser("~/.claude/evidence-audit.log")
PER_RESULT = 20000     # chars kept from each tool result (head + tail)
ARGS_PER_CALL = 6000   # chars kept from each tool call's input
TOTAL_BUDGET = 150000  # chars of this turn's tool calls sent to the auditor
EARLIER_PER_RESULT = 4000   # chars kept from each earlier-turn result
EARLIER_BUDGET = 90000      # chars of earlier-turn output sent to the auditor
MATCH_BUDGET = 30000   # chars of full-text search snippets
MATCH_CONTEXT = 400    # chars either side of a match
MAX_PROBES = 60
SAID_PER_MSG = 600     # chars kept from each user prompt
SAID_BUDGET = 10000    # chars of user prompts sent to the auditor
HOOK_PER_MSG = 1200    # chars kept from each earlier hook message
HOOK_BUDGET = 10000    # chars of earlier hook messages sent to the auditor
MAX_IMAGES = 40
SHORT_ANSWER = 200
TIMEOUT = 100
IMAGE_EXT = re.compile(r"\.(png|jpe?g|gif|webp|heic|tiff?|bmp)$", re.I)

SYSTEM = """You audit an AI assistant's answer against the evidence it gathered this turn.

You get: the tool calls it made (inputs and outputs), snippets found by searching the full unclipped tool text for the answer's specific words, a list of images the assistant viewed, the conversation, and its answer text.

AUDIT ONLY FACTUAL CLAIMS ABOUT THE PAST OR PRESENT: what was done, what was run, what a file/output/system contains or does now, what passed or failed. Describing how existing code or a system behaves ("the app lists models up to 7 GB", "the script reboots when done") is a present-state claim: audit it.
NEVER flag (skip silently): plans and intentions ("I'll check", "next I'll", "let me"), steps for the future ("after that, one more touch", "you will need to"), instructions to the user, questions, offers, conditionals/hypotheticals ("if it shows X, do Y", "may", "might", "could"), opinions, stable general knowledge, and statements already marked as inference/unverified ("probably", "not checked"). Recommendations are skipped too, EXCEPT the real-world facts they rest on (next section).

REAL-WORLD FACTS (kind "world"): also audit claims about the outside world that change over time or differ by place: prices, payouts and offers; what a business, store, shop or service does, takes, accepts or pays; fees, policies, laws, rules; hours, locations, availability; current versions, releases, events. These count EVEN INSIDE a recommendation or option list ("a pawn shop can lend against it", "ecoATM pays cash on the spot", "Swappa charges 3%"). Flag one with kind "world" unless a WebSearch or WebFetch result in the evidence supports it, or the answer itself marks it unchecked/unknown. Do not flag stable knowledge that does not change by time or place (how a protocol works, arithmetic, what a word means).

UNSEARCHED GAPS (kind "unsearched"): flag when the answer says it does not know, has not looked, has not checked, or would be guessing about something in the OUTSIDE WORLD that a web search could answer (markets and how crowded they are, trends, what a company/product/service does, prices, current events, versions, how many people do X), AND the evidence shows no WebSearch or WebFetch this turn. Saying "not checked" does NOT clear this kind: the point is that the search should have been run. Do NOT flag gaps about local things (files, the user's own machines, apps or screens, what an untested build does), the user's own feelings, plans or preferences, or what nobody can know yet (the future).

Flag a past/present claim ONLY when the evidence does not show it:
- details, values, counts, names or versions that are absent from or contradict the outputs
- describing content beyond what was examined (parts of a file never read, motion between video frames)
- saying something works, passed, was fixed or verified when no output shows that check
- stating an unknown as fact instead of marking it unknown or inferred

Tool INPUTS are evidence of what the assistant wrote or ran (a Write body, an Edit's new text, a heredoc script). A command's output is evidence of what it printed.
What the user said, and what earlier hook messages said, are evidence too: a claim that repeats or relies on them is supported when the conversation section shows it.
Evidence from earlier in the session counts the same as this turn's. That section is clipped and may be missing older calls, so do not flag a claim about earlier work just because you cannot find it.
If an output is marked [truncated], do not flag a claim that the missing part could support unless the visible part or the full-text search snippets contradict it. The search snippets come from the FULL text, so they are reliable.

IMAGES: you cannot see the images listed under "Images the assistant viewed". A claim about what an image, screenshot, icon, photo or screen shows is NOT unsupported: put it in "unchecked_image" instead, never in "unsupported".

Be conservative: flag only clear cases.

Reply with ONLY a JSON object, no prose:
{"unsupported": [{"claim": "<short quote from the answer>", "kind": "past|present|world|unsearched", "why": "<what the evidence does or does not show>"}], "unchecked_image": [{"claim": "<short quote>"}]}
Use empty lists when everything is supported."""

# Deterministic backstop for the "plans are not claims" rule: a flagged quote
# that is first-person future, a future step, a question or a hypothetical is
# dropped even if the auditor listed it (10-31: "When it finishes, I'll check
# the result..." and "After that, one more touch..." blocked two stops).
PLAN_ANY = re.compile(
    r"\b(I['’]ll|I will|I['’]m going to|I am going to|we['’]ll|we will|let me|let['’]s|"
    r"next,? I|I plan|I would|you['’]ll need|you will need|will need|want me to|"
    r"shall I|should I|going to)\b", re.I)
PLAN_START = re.compile(
    r"^\W*(when\b.*\b(finish|finishes|done|ready|comes back)|after that|"
    r"next\b|to do|plan\b|try\b|run\b|click\b|type\b|open\b|press\b)", re.I)
HEDGE = re.compile(r"\b(may|might|could(?!n['’]t| not)|probably|likely|possibly|perhaps|maybe)\b", re.I)
IMAGE_WHY = re.compile(r"screenshot|\bimages?\b|picture|photo", re.I)
DONE_WORDS = re.compile(r"\b(fixed|works|working|passed|passes|verified|installed|built|builds|saved|pushed|"
                        r"deleted|removed|running|done|committed|deployed|restarted|tested)\b", re.I)
# An answer with no tool calls this turn is still audited when it talks about the outside world
# (11-02: "pawn shops will lend against the phone" went out unchecked in a turn with no tools).
WORLD_CUE = re.compile(r"\$\s?\d|\b(price|prices|pay|pays|paid|payout|offer|offers|cash|fee|fees|charge|charges|"
                       r"store|stores|shop|shops|pawn|kiosk|buyer|buyers|accept|accepts|take|takes|policy|policies|"
                       r"law|laws|legal|hours|open|near you|available|availability|release|released|latest|current)\b", re.I)
# The answer admits an outside-world gap: audited even when short or tool-less, so "I haven't looked" can't slip past
# (11-02: "I can't tell you how crowded the market is... I haven't looked" — the rule allowed it; the owner: code it in).
ADMIT = re.compile(r"\b(haven['’]t (looked|checked|searched)|not checked|didn['’]t (look|check|search)|I['’]d be guessing|"
                   r"can['’]t tell you|can['’]t say|don['’]t know|no idea|not sure|unverified)\b", re.I)
WORLD_TOPIC = re.compile(r"\b(markets?|trends?|industry|crowded|competition|competitors|prices?|pricing|charges?|pays?|costs?|payouts?|salar(y|ies)|jobs?|"
                         r"hiring|demand|economy|laws?|polic(y|ies)|fees?|news|latest version|current version|releases?|"
                         r"how many people|most people|everyone else)\b", re.I)


def unsearched_gaps(answer):
    """Sentences that admit not knowing something in the outside world (deterministic, no AI)."""
    return [x.strip() for x in re.split(r"(?<=[.!?])\s+|\n+", answer or "")
            if ADMIT.search(x) and WORLD_TOPIC.search(x)]
# Untested fix advice (11-10: told the owner "turn on Full Disk Access", then "restart Terminal", both guesses; the real
# blocker was the Claude Code classifier. The owner: "WHY DIDNT YOU JUST TELL ME THAT IN THE FIRST PLCE").
# A sentence that tells him to change a setting / restart something must be backed by a real failure this turn or
# the one before (an error in tool output), or it is blocked. Deterministic, no AI.
FIX_ASK = re.compile(r"\b(turn on|turn it on|enable|allow|grant|toggle|switch on|restart|relaunch|reopen|re-open|"
                     r"reinstall|quit (?:and|then) reopen|Cmd\+Q|log out and|reboot)\b", re.I)
FIX_TARGET = re.compile(r"\b(System Settings|Settings|Privacy|Full Disk Access|permissions?|access|Terminal|app|Mac|"
                        r"computer|browser|extension|Claude Code|login item|background item)\b", re.I)
FAIL_SEEN = re.compile(r"operation not permitted|permission denied|denied|not permitted|no such file|not found|"
                       r"error|failed|refused|timed? ?out|exit code [1-9]|could not|cannot|can't", re.I)


def untested_fix_advice(answer, results, earlier):
    """Sentences telling the owner to change a setting with no failure in this turn's (or the last few) tool output."""
    asks = [x.strip() for x in re.split(r"(?<=[.!?])\s+|\n+", answer or "")
            if FIX_ASK.search(x) and FIX_TARGET.search(x)]
    if not asks:
        return []
    recent = list(results) + list(earlier[-6:])
    if any(FAIL_SEEN.search(r[2] or "") for r in recent):
        return []
    return asks


SEARCH_TOOLS = {"WebSearch", "WebFetch"}
CLAIM_FILLER = {"a", "an", "the", "is", "are", "was", "were", "be", "of", "to", "in", "on", "for", "and", "or", "it",
                "this", "that", "my", "your", "i", "you", "just", "at", "as"}
ACK = re.compile(r"^\W*(✓|ok(ay)?|done|got it|yes|no|👍)\W*$", re.I)


def log(entry):
    entry["ts"] = time.strftime("%Y-%m-%dT%H:%M:%S")
    try:
        with open(LOG, "a") as f:
            f.write(json.dumps(entry) + "\n")
    except Exception:
        pass


def clip(text, n):
    if len(text) <= n:
        return text
    half = n // 2
    return text[:half] + "\n[truncated]\n" + text[-half:]


def result_text(content):
    if isinstance(content, str):
        return content, 0
    parts, n_img = [], 0
    for b in content or []:
        if not isinstance(b, dict):
            continue
        if b.get("type") == "text":
            parts.append(b.get("text", ""))
        elif b.get("type") == "image":
            n_img += 1
    return "\n".join(parts), n_img


def is_prompt(o):
    """A real user prompt: plain text, or text/images pasted by the owner (no tool results)."""
    if o.get("type") != "user" or o.get("isMeta") or o.get("isSidechain"):
        return False
    c = o.get("message", {}).get("content")
    if isinstance(c, str):
        return not c.startswith("Stop hook feedback")
    if isinstance(c, list) and c:
        types = {b.get("type") for b in c if isinstance(b, dict)}
        return "tool_result" not in types and bool(types & {"text", "image"})
    return False


def load_turn(path):
    entries = []
    with open(path) as f:
        for line in f:
            try:
                entries.append(json.loads(line))
            except Exception:
                continue
    start = 0
    for i, o in enumerate(entries):
        if is_prompt(o):
            start = i
    calls, results, texts, images, earlier = {}, [], [], [], []
    said, hooks = [], []
    for i, o in enumerate(entries):
        if o.get("isSidechain"):
            continue
        content = o.get("message", {}).get("content")
        current = i > start
        if o.get("type") == "user" and isinstance(content, str):
            if not o.get("isMeta"):
                if content.startswith("Stop hook feedback"):
                    hooks.append(content)
                else:
                    said.append(content)
            elif content.startswith("Stop hook feedback"):
                hooks.append(content)
            continue
        if not isinstance(content, list):
            continue
        if is_prompt(o):
            txt = "\n".join(b.get("text", "") for b in content if isinstance(b, dict) and b.get("type") == "text")
            n = sum(1 for b in content if isinstance(b, dict) and b.get("type") == "image")
            if n:
                images.append({"where": "pasted by the user" + (" (this turn)" if i >= start else ""), "count": n})
            said.append((txt + (f" [+{n} pasted image(s)]" if n else "")).strip())
            continue
        for b in content:
            if not isinstance(b, dict):
                continue
            t = b.get("type")
            if o.get("type") == "assistant" and t == "text" and current:
                texts.append(b.get("text", ""))
            elif o.get("type") == "assistant" and t == "tool_use":
                calls[b.get("id")] = (b.get("name"), b.get("input") or {})
            elif o.get("type") == "user" and t == "tool_result":
                name, inp = calls.get(b.get("tool_use_id"), ("?", {}))
                text, n_img = result_text(b.get("content"))
                fp = inp.get("file_path") if isinstance(inp, dict) else None
                if n_img or (fp and IMAGE_EXT.search(str(fp))):
                    images.append({"where": f"{name} {fp or ''}".strip() + (" (this turn)" if current else ""),
                                   "count": max(n_img, 1)})
                rec = (name, inp, text, bool(n_img))
                (results if current else earlier).append(rec)
    return results, texts, images, earlier, said, hooks


def call_args(inp, n):
    return clip(json.dumps(inp, ensure_ascii=False), n)


def earlier_block(earlier):
    # Earlier turns' output, newest first. Older calls fall off the end first.
    blocks, used = [], 0
    for name, inp, text, _ in reversed(earlier):
        body = f"### Earlier: {name} {call_args(inp, 600)}\n{clip(text, EARLIER_PER_RESULT)}"
        if used + len(body) > EARLIER_BUDGET:
            break
        used += len(body)
        blocks.append(body)
    if not blocks:
        return ""
    return ("\n\n## Evidence from earlier in the session (newest first, "
            f"{len(blocks)} of {len(earlier)} calls)\n\n" + "\n\n".join(blocks))


def conversation_block(said, hooks):
    def newest(msgs, per, budget):
        out, used = [], 0
        for m in reversed(msgs):
            body = clip(m, per)
            if used + len(body) > budget:
                break
            used += len(body)
            out.append("- " + body.replace("\n", "\n  "))
        return out
    parts = []
    s = newest(said, SAID_PER_MSG, SAID_BUDGET)
    if s:
        parts.append(f"### What the user said ({len(s)} of {len(said)}, newest first)\n" + "\n".join(s))
    h = newest(hooks, HOOK_PER_MSG, HOOK_BUDGET)
    if h:
        parts.append(f"### Earlier hook messages ({len(h)} of {len(hooks)}, newest first)\n" + "\n".join(h))
    return "\n\n## Conversation so far\n\n" + "\n\n".join(parts) if parts else ""


PROBE_RES = [
    re.compile(r"`([^`\n]{3,120})`"),                       # code spans
    re.compile(r"[\"“]([^\"”\n]{4,100})[\"”]"),             # quotes
    re.compile(r"\*\*([^*\n]{3,80})\*\*"),                  # bold labels
    re.compile(r"(?<![\w.])(\d[\d,.]*\s?(?:GB|MB|KB|ms|s|%|px|files?|records?|models?|lines?|checks?))\b"),
    re.compile(r"\b([0-9a-f]{7,40})\b"),                    # hashes
    re.compile(r"(?<![\w/~.])((?:~|\.{1,2})?/[\w.\-/]{3,160})"),  # paths
]


def probes(answer):
    out, seen = [], set()
    for rx in PROBE_RES:
        for m in rx.findall(answer):
            p = m.strip().rstrip(".,:;)")
            if len(p) < 3 or p.lower() in seen:
                continue
            seen.add(p.lower())
            out.append(p)
    return out[:MAX_PROBES]


def match_block(answer, prompt_so_far, full_records):
    """Search the FULL text of every tool call (input + output) for the answer's
    specific tokens; add a snippet for each one the clipped prompt does not show."""
    hay = [(label, f"{json.dumps(inp, ensure_ascii=False)}\n{text}") for label, inp, text in full_records]
    blocks, used, found = [], 0, 0
    low_prompt = prompt_so_far.lower()
    for p in probes(answer):
        if p.lower() in low_prompt:
            continue
        for label, h in reversed(hay):
            at = h.lower().find(p.lower())
            if at < 0:
                continue
            a, b = max(0, at - MATCH_CONTEXT), min(len(h), at + len(p) + MATCH_CONTEXT)
            body = f"### `{p}` found in {label} (chars {a}-{b} of {len(h)})\n…{h[a:b]}…"
            if used + len(body) > MATCH_BUDGET:
                break
            used += len(body)
            found += 1
            blocks.append(body)
            break
    if not blocks:
        return "", 0
    return ("\n\n## Full-text search: answer tokens found in parts of the tool text clipped above\n\n"
            + "\n\n".join(blocks)), found


def build_prompt(results, answer, images, earlier=(), said=(), hooks=()):
    blocks, used = [], 0
    for i, (name, inp, text, has_image) in enumerate(results, 1):
        args = call_args(inp, ARGS_PER_CALL)
        body = clip(text, PER_RESULT)
        if has_image:
            body = (body + "\n" if body else "") + f"[image: {inp.get('file_path', 'inline image')} -- not visible to you]"
        if used + len(body) + len(args) > TOTAL_BUDGET:
            args, body = call_args(inp, 400), "[omitted: evidence budget exceeded; see full-text search below]"
        used += len(body) + len(args)
        blocks.append(f"### Call {i}: {name} {args}\n{body}")
    img = ""
    if images:
        img = ("\n\n## Images the assistant viewed (NOT visible to you; claims read off them go in unchecked_image)\n"
               + "\n".join(f"- {x['where']} ({x['count']} image{'s' if x['count'] > 1 else ''})" for x in images[-MAX_IMAGES:]))
    head = "## Evidence gathered this turn\n\n" + "\n\n".join(blocks)
    rest = earlier_block(earlier) + conversation_block(said, hooks)
    full = [(f"Call {i}", inp, text) for i, (_, inp, text, _) in enumerate(results, 1)] + \
           [(f"earlier {name} call", inp, text) for name, inp, text, _ in earlier]
    matches, n_found = match_block(answer, head + rest, full)
    return head + matches + img + rest + "\n\n## Assistant answer\n\n" + answer, n_found


def content_words(text):
    words = re.findall(r"[a-z0-9']+", str(text).lower().replace("’", "'"))
    return [w for w in words if w not in CLAIM_FILLER]


def in_answer(claim, answer):
    """The referee must quote the answer. A claim mostly made of words the answer never used came from somewhere
    else, such as the owner's own question (11-07: it flagged their "copy of everyone else's shit" against my answer)."""
    words = content_words(claim)
    if not answer or len(words) < 2:
        return True
    have = set(content_words(answer))
    return sum(w in have for w in words) / len(words) >= 0.6


def filter_flags(items, has_images, searched=False, answer=""):
    kept, plans, image_claims = [], [], []
    for f in items:
        claim, why = str(f.get("claim", "")), str(f.get("why", ""))
        kind = str(f.get("kind", "")).lower()
        if not in_answer(claim, answer):
            plans.append("[not in answer] " + claim)
        elif kind == "unsearched":
            if not searched:
                kept.append(f)        # hedging can't clear it; only a search this turn does
        elif kind == "world":
            kept.append(f)            # real-world facts: hedging words don't excuse an unsearched claim
        elif kind and kind not in ("past", "present"):
            plans.append(claim)
        elif PLAN_ANY.search(claim) or PLAN_START.search(claim) or claim.rstrip().endswith("?") or HEDGE.search(claim):
            plans.append(claim)
        elif has_images and IMAGE_WHY.search(why):
            image_claims.append(claim)
        else:
            kept.append(f)
    return kept, plans, image_claims


SEARCH_TIMEOUT = 90
STOP_BUDGET = 112          # the Stop hook is killed at 120 s (settings.json); leave room to print
T_START = time.time()
SEARCH_ENGINE = "https://html.duckduckgo.com/html/"


class _SearchJob:
    """A search running in a thread. poll()/kill() match the old claude -p Popen, so main() is unchanged."""
    def __init__(self, fn):
        import threading
        self.out, self.err = None, None
        def run():
            try:
                self.out = fn()
            except Exception as e:
                self.err = e
        self.t = threading.Thread(target=run, daemon=True)
        self.t.start()

    def poll(self):
        return None if self.t.is_alive() else 0

    def kill(self):
        pass    # daemon thread; it dies with the hook


def ddg(query, n=4):
    """DuckDuckGo's plain HTML page, no key and no model (was claude -p --model haiku until 11-08: the owner wants
    nothing in the hooks spending Claude tokens). Returns '- title: snippet (url)' lines."""
    import html as _html
    import urllib.parse
    req = urllib.request.Request(SEARCH_ENGINE + "?" + urllib.parse.urlencode({"q": query}),
                                 headers={"User-Agent": "Mozilla/5.0 (Macintosh) evidence-audit"})
    with urllib.request.urlopen(req, timeout=15) as r:
        page = r.read().decode("utf-8", "replace")
    out = []
    for blk in page.split('result__body"')[1:]:      # class="links_main links_deep result__body"
        m = re.search(r'class="result__a"[^>]*href="([^"]+)"[^>]*>(.*?)</a>', blk, re.S)
        if not m:
            continue
        url = m.group(1)
        q = urllib.parse.parse_qs(urllib.parse.urlparse(url).query).get("uddg")
        url = q[0] if q else url
        if "duckduckgo.com/y.js" in url:      # ads
            continue
        title = _html.unescape(re.sub(r"<[^>]+>", "", m.group(2))).strip()
        sn = re.search(r'class="result__snippet"[^>]*>(.*?)</a>', blk, re.S)
        snippet = _html.unescape(re.sub(r"<[^>]+>", "", sn.group(1))).strip() if sn else ""
        out.append(f"- {title}: {snippet[:240]} ({url})")
        if len(out) >= n:
            break
    return out


def start_search(question, gaps):
    """The block doesn't just ask for a search: the hook runs one itself (11-02, the owner: 'make it so an actual search
    happens when it's blocked'). Started alongside the audit so both fit in the Stop hook's time. One search per gap
    (up to 3); raw results, no model in between."""
    def run():
        parts = []
        for g in gaps[:3]:
            q = re.sub(r"\s+", " ", str(g))[:160]
            hits = ddg(q)
            parts.append(f"Search: {q}\n" + ("\n".join(hits) if hits else "- no results"))
        return "\n\n".join(parts)
    return _SearchJob(run), time.time()


def finish_search(job, entry):
    proc, t0 = job
    try:
        left = min(SEARCH_TIMEOUT - (time.time() - t0), STOP_BUDGET - (time.time() - T_START))
        if left < 3:
            raise TimeoutError("no time left in the Stop hook")
        proc.t.join(timeout=left)
        if proc.t.is_alive():
            raise TimeoutError("search still running")
        if proc.err:
            raise proc.err
        text = (proc.out or "").strip()
        ok = bool(text) and "(http" in text
        entry["hook_search"] = {"ok": ok, "secs": round(time.time() - t0, 1), "engine": "duckduckgo", "cost": 0}
        return text if ok else None
    except Exception as e:
        entry["hook_search"] = {"ok": False, "error": f"{type(e).__name__}: {e}"[:200]}
        return None


import urllib.request

ALEXUS_LAN = "http://alexus:11434"
ALEXUS_TAILSCALE = "http://alexus:11434"
GJALLARHORN_MODEL = os.environ.get("GJALLARHORN_MODEL", "qwen2.5-coder:3b")
GJALLARHORN_LOG = os.path.expanduser("~/.ragnarok/gjallarhorn-audit.jsonl")


def _get_ollama_url():
    cands = []
    env_url = os.environ.get("OLLAMA_URL", "").strip()
    if env_url:
        cands.append(env_url.rstrip("/"))
    conf = os.environ.get("RAGNAROK_LOCAL_CONF") or os.path.expanduser("~/.ragnarok/local.conf")
    if os.path.isfile(conf):
        try:
            with open(conf, "r", encoding="utf-8") as f:
                for line in f:
                    line = line.strip()
                    if line and not line.startswith("#") and "=" in line:
                        k, v = line.split("=", 1)
                        k, v = k.strip(), v.strip().strip("\"'")
                        if k == "OLLAMA_URL" and v:
                            cands.append(v.rstrip("/"))
                        elif k in ("ALEXUS_HOST", "ALEXUS_TAILSCALE") and v:
                            cands.append(f"http://{v}:11434")
        except Exception:
            pass
    for base in (ALEXUS_LAN, ALEXUS_TAILSCALE):
        if base not in cands:
            cands.append(base)
    for base in cands:
        try:
            req = urllib.request.Request(f"{base}/api/tags", headers={"User-Agent": "Gjallarhorn-Referee"})
            with urllib.request.urlopen(req, timeout=1.5) as r:
                if r.status == 200:
                    return base
        except Exception:
            continue
    return None


LOCAL_REFEREE_SYSTEM = """You are an auditor verifying an AI assistant's answers against evidence.
Compare the claims in the assistant's answer against the tool outputs and conversation facts.
Tool inputs (file edits, writes, commands run) and earlier-turn tool outputs count as valid evidence.
NEVER flag opinions, metaphors, mythology, jokes, greetings, advice, future plans, questions, or general conversation.
NEVER list claims that ARE supported by the evidence.
If the answer mentions an image or screenshot, put that claim in "unchecked_image", never in "unsupported".
Be very conservative. If unsure, do not flag.

If everything in the answer is supported by the evidence, reply ONLY with:
{"all_supported": true, "unsupported": [], "unchecked_image": []}

If and ONLY if the answer makes a false factual claim that is contradicted or completely absent from the evidence, reply ONLY with:
{"all_supported": false, "unsupported": [{"claim": "<short quote from the answer>", "kind": "past|present|world|unsearched", "why": "<why the evidence does not support it>"}], "unchecked_image": []}"""


def ask_auditor(prompt):
    ollama_base = _get_ollama_url()
    if not ollama_base:
        raise RuntimeError("Alexus local Ollama referee unreachable")
    clipped = prompt if len(prompt) <= 18000 else (
        prompt[:8000] + "\n\n...[middle clipped for local referee]...\n\n" + prompt[-10000:]
    )
    full_prompt = f"{LOCAL_REFEREE_SYSTEM}\n\n{clipped}\n\nJSON output:"
    payload = {
        "model": GJALLARHORN_MODEL,
        "prompt": full_prompt,
        "stream": False,
        "format": "json",
        "keep_alive": "30m",
        # num_ctx: Ollama's default here is 4096 tokens, and a full audit prompt (up to 18,000 chars) is bigger, so it
        # was silently cut to ~2,000 tokens (measured 11-08). 8192 holds the whole clipped prompt.
        "options": {"temperature": 0, "num_ctx": 8192},
    }
    req = urllib.request.Request(
        f"{ollama_base}/api/generate",
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=min(TIMEOUT, 60)) as resp:
        body = json.loads(resp.read().decode("utf-8"))
    raw_text = body.get("response", "{}")
    m = re.search(r"\{.*\}", raw_text, re.S)
    if not m:
        raise ValueError("no JSON in local auditor reply: " + raw_text[:200])
    reply = json.loads(m.group(0))
    if reply.get("all_supported") is True:
        items = []
    else:
        items = reply.get("unsupported") or []
    # Filter out non-flags ("Supported", "Not flagged", "no evidence needed", or why without negative cue)
    ok = re.compile(r"\bno evidence (is )?needed\b|\bnot a (checkable |factual )+claim\b|\bnot a factual claim\b|\bnot flagged\b|\bacceptable\.?\s*$|^\s*supported\b|(?<!not )\bsupported( by (the )?evidence)?\.?\s*$", re.I)
    neg_cue = re.compile(r"\b(not|no\b|never|absent|missing|contradict|false|unsupported|unverified|doesn['’]t|does not|did not|didn['’]t|without|lack|fail|wrong|different|instead)\b", re.I)
    items = [
        f for f in items
        if isinstance(f, dict) and f.get("claim")
        and f.get("supported") is not True
        and not ok.search(str(f.get("why", "")))
        and neg_cue.search(str(f.get("why", "")))
    ]
    unchecked = [str(x.get("claim", x)) if isinstance(x, dict) else str(x) for x in reply.get("unchecked_image") or []]
    return items, unchecked, 0.0


def main():
    if os.environ.get("EVIDENCE_AUDIT_INNER"):
        return
    inp = json.load(sys.stdin)
    if inp.get("stop_hook_active"):
        return
    t0 = time.time()
    entry = {"session": inp.get("session_id")}
    dry = bool(os.environ.get("EVIDENCE_AUDIT_DRYRUN"))
    try:
        results, texts, images, earlier, said, hooks = load_turn(inp["transcript_path"])
        last = inp.get("last_assistant_message")
        if isinstance(last, str) and last and last not in texts:
            texts.append(last)
        answer = "\n\n".join(t for t in texts if t.strip())
        entry.update(tools=len(results), images=sum(x["count"] for x in images), earlier=len(earlier))
        gaps = unsearched_gaps(answer)
        gap = bool(gaps)
        untested = untested_fix_advice(answer, results, earlier)
        if untested and not dry:
            entry.update(flags=[{"claim": u[:160], "kind": "untested"} for u in untested[:3]])
            lines = "\n".join(f"- \"{u[:160]}\"" for u in untested[:3])
            print(json.dumps({
                "decision": "block",
                "reason": ("📯 [Alexus Local Referee / HOOK — not Claude] UNTESTED FIX (enforced in code): this answer tells "
                           "the owner to change a setting or restart something, but no command in this turn or the last one "
                           "failed in a way that backs it up:\n" + lines + "\n\nRun the thing that is failing first, read "
                           "the real error, and name the real blocker (macOS permission, Claude Code classifier or "
                           "sandbox, the app itself). Then rewrite. If the advice is wrong, tell the owner in one line "
                           "starting '🟧 Corrected:'. If it holds up after testing, keep it and reply with only: ✓"),
            }))
            return
        if not answer or (not results and not WORLD_CUE.search(answer) and not gap):
            entry["skipped"] = "no answer text" if not answer else "no tool output, no real-world talk"
            return
        if ACK.match(answer) or (len(answer.strip()) < SHORT_ANSWER and not DONE_WORDS.search(answer) and not WORLD_CUE.search(answer) and not gap):
            entry["skipped"] = f"short answer ({len(answer.strip())} chars)"
            return
        searched = any(r[0] in SEARCH_TOOLS for r in results)
        job = None
        if gaps and not searched and not dry:
            job = start_search(said[-1] if said else "", gaps)
        prompt, n_found = build_prompt(results, answer, images, earlier, said, hooks)
        entry.update(prompt_chars=len(prompt), search_hits=n_found)
        if dry:
            print(prompt)
            entry["dry_run"] = True
            return
        raw, unchecked, cost = ask_auditor(prompt)
        flags, plans, image_claims = filter_flags(raw, bool(images), searched, answer)
        if gaps and not searched and not any(str(f.get("kind", "")).lower() == "unsearched" for f in flags):
            flags += [{"claim": g[:160], "kind": "unsearched",
                       "why": "admits not knowing an outside-world fact, and no WebSearch/WebFetch ran this turn"} for g in gaps[:3]]
        entry.update(flags=flags, cost=cost, said=len(said), hooks=len(hooks))
        if plans:
            entry["dropped_plan"] = plans
        if unchecked or image_claims:
            entry["unchecked_image"] = unchecked + image_claims   # silent: logged only
        if flags:
            lines = "\n".join(f"- \"{f.get('claim')}\": {f.get('why')}" for f in flags)
            gap_flags = [f for f in flags if str(f.get("kind", "")).lower() == "unsearched"]
            if gap_flags and job is None:   # the auditor found a gap the pattern didn't: search now with the time left
                job = start_search(said[-1] if said else "", [str(f.get("claim", "")) for f in gap_flags])
            found = finish_search(job, entry) if gap_flags else None
            if gap_flags and found:
                lines += ("\n\nUNSEARCHED (R-16, enforced in code): you left an outside-world question unanswered without "
                          "looking, so the hook ran the web search itself. Results:\n\n" + found[:4000] + "\n\nRewrite "
                          "the answer with these: cite the URLs, say how weak the sources are. Tell the owner in one line "
                          "starting '🟧 Searched:' what was found and what it changes.")
            elif gap_flags:
                lines += ("\n\nUNSEARCHED (R-16, enforced in code): the hook's own search failed, so run WebSearch now "
                          "and answer with what it finds, citing it; 'not checked' does not clear this flag. Tell the owner "
                          "in one line starting '🟧 Searched:' what you found.")
            # No systemMessage banner: the owner hears about a flag only when it
            # changes the answer (10-31 ask: "silent unless it actually causes a change").
            print(json.dumps({
                "decision": "block",
                "reason": ("📯 [Alexus Local Referee / HOOK — not Claude] Evidence audit (R-09/R-11/R-14) flagged claims that the "
                           "session's tool output does not back:\n" + lines + "\n\nFix each one: check it "
                           "with a tool, or relabel it as unverified/inference. A 'world' claim (prices, what a business "
                           "takes or pays, policies, laws, availability) needs a web search, or say plainly it's "
                           "not checked. SILENT UNLESS CHANGED: "
                           "if a flag is wrong (backed earlier, or general knowledge) or needs no change, "
                           "do not mention it. Only when you change a claim, tell the owner in one line what "
                           "changed, starting with '🟧 Corrected:'. If nothing changed, reply with only: ✓"
                           ""),
            }))
        if job and job[0].poll() is None:
            job[0].kill()                  # started but not needed (no block)
    except Exception as e:
        entry["error"] = f"{type(e).__name__}: {e}"[:300]
    finally:
        entry["secs"] = round(time.time() - t0, 1)
        entry["referee_model"] = GJALLARHORN_MODEL
        if not dry:
            log(entry)
            try:
                os.makedirs(os.path.dirname(GJALLARHORN_LOG), exist_ok=True)
                with open(GJALLARHORN_LOG, "a") as gf:
                    gf.write(json.dumps(dict(entry, source=os.environ.get("RAGNAROK_ACTOR", "claude-hook"))) + "\n")
            except Exception:
                pass
        else:
            print("\n--- dry-run entry: " + json.dumps(entry), file=sys.stderr)


if __name__ == "__main__":
    main()
