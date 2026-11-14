"""Receipt sanity checks that need no model: which printed date is the purchase date, and which receipts
are probably the same purchase photographed twice. Pure functions; nothing here writes to the database."""
import difflib
import re
from datetime import date, timedelta
from decimal import Decimal

# Words that put a date on a promo / coupon / survey / return-policy line instead of the sale itself.
BAD = re.compile(
    r"(expir\w*|\bexp\b\.?|\bvalid\w*|\boffer\w*|coupon\w*|survey\w*|\breturns?\b|\brefund\w*|\bbefore\b|\bthrough\b|\bthru\b"
    r"|\buntil\b|\btill\b|enter\s+by|use\s+by|\bpromo\w*|sweepstake\w*|redeem\w*|\breward\w*|\bwin\b|\bvisit\b|feedback"
    r"|\bdeadline\b|\bends?\b|\bgood\s+(for|on)\b|\bnext\s+visit\b|\bsave\s+\$|\bvoid\s+after\b)", re.I)
# Words that put a date on the transaction itself (time, register, terminal, auth, totals block...).
GOOD = re.compile(
    r"(\breg\w*|\bterm\w*|\btrans\w*|\btran\b|\btxn\b|\bauth\w*|\bappr\w*|\bcashier\b|\bstore\b|\btc#?|\bref\b|\btotal\b"
    r"|\bdate\b|\btime\b|\bsale\b|\bpurchase\b|\border\b|\binvoice\b|\bvisa\b|\bmastercard\b|\bamex\b|\bdebit\b|\bcredit\b"
    r"|\bchip\b|\bcontactless\b|\bop\b|\bemp\w*|\bserver\b|\bcheck\b|\bseq\b|\blane\b)", re.I)
# A label right before the date saying it is not the date the document was made (invoice due/paid/shipped/stamped).
NOT_ISSUE = re.compile(r"(\bdue\b|\bpaid\b|\bship\w*|\bdeliver\w*|\breceived\b|\brecd\b|\bissue\b)[^\d]{0,14}$", re.I)
TIME = re.compile(r"\b\d{1,2}:\d{2}(:\d{2})?\s*([ap]\.?m\.?)?\b", re.I)
MONTHS = {m: i for i, m in enumerate(["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"], 1)}
_MON = r"(jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec)[a-z]*\.?"
PATTERNS = [
    ("ymd", re.compile(r"(?<![\d/.-])(\d{4})[-/.](\d{1,2})[-/.](\d{1,2})(?![\d/.-])")),
    ("mdy", re.compile(r"(?<![\d/.:-])(\d{1,2})\s*[/-]\s*(\d{1,2})\s*[/-]\s*(\d{4}|\d{2})(?![\d/-])")),
    ("mony", re.compile(_MON + r"\s+(\d{1,2})(?:st|nd|rd|th)?,?\s+(\d{4})", re.I)),
    ("dmony", re.compile(r"(?<!\d)(\d{1,2})\s+" + _MON + r",?\s+(\d{4})", re.I)),
    ("md", re.compile(r"(?<![\d/.:$-])(\d{1,2})/(\d{1,2})(?![\d/.%-])")),   # 9/15 with no year (typical promo)
]


def _mk(y, m, d):
    try:
        return date(y, m, d)
    except ValueError:
        return None


def candidates(raw_text: str) -> list[dict]:
    """Every date printed on the receipt with its line, and whether that line reads like the sale or a promo.
    A year-less "9/15" is kept as month/day only."""
    out, lines = [], (raw_text or "").splitlines()
    for n, line in enumerate(lines):
        taken = []
        for kind, rx in PATTERNS:
            for m in rx.finditer(line):
                if any(a <= m.start() < b for a, b in taken):
                    continue
                g = m.groups()
                if kind == "ymd":
                    dt, md = _mk(int(g[0]), int(g[1]), int(g[2])), None
                elif kind == "mdy":
                    y = int(g[2])
                    if y < 100:  # 2-digit year: this century unless that lands in the future (6-10-88 is 1988)
                        y = y + 2000 if y + 2000 <= date.today().year + 1 else y + 1900
                    dt, md = _mk(y, int(g[0]), int(g[1])), None
                elif kind == "mony":
                    dt, md = _mk(int(g[2]), MONTHS[g[0][:3].lower()], int(g[1])), None
                elif kind == "dmony":
                    dt, md = _mk(int(g[2]), MONTHS[g[1][:3].lower()], int(g[0])), None
                else:
                    mo, dy = int(g[0]), int(g[1])
                    dt, md = None, ((mo, dy) if 1 <= mo <= 12 and 1 <= dy <= 31 else None)
                    if md is None:
                        continue
                if dt is None and md is None:
                    continue
                taken.append((m.start(), m.end()))
                prev = lines[n - 1] if n else ""
                alone = len(line.strip()) <= len(m.group(0)) + 4   # the date sits on its own line under a label
                bad = bool(BAD.search(line)) or (alone and bool(BAD.search(prev)))
                not_issue = bool(NOT_ISSUE.search(line[:m.start()]))
                good = not bad and not not_issue and (bool(TIME.search(line)) or bool(GOOD.search(line)) or (alone and bool(GOOD.search(prev))))
                out.append({"date": dt, "md": md or (dt.month, dt.day), "line": n, "text": line.strip()[:120],
                            "bad": bad, "good": good, "year": dt is not None})
    return out


def _same(c: dict, d: date) -> bool:
    return c["date"] == d if c["year"] else c["md"] == (d.month, d.day)


def check_date(model_date, raw_text: str, today: date | None = None) -> tuple[date | None, list[str], dict]:
    """Pick the purchase date. Returns (date to keep, problems for review, info for the log).
    Problems mean "a person should look at the date"; the receipt then goes to needs review."""
    today = today or date.today()
    soon = today + timedelta(days=1)
    cs = candidates(raw_text)
    good = sorted({c["date"] for c in cs if c["good"] and c["year"] and c["date"] <= soon})
    info = {"candidates": [{"date": c["date"].isoformat() if c["date"] else "%d/%d" % c["md"], "bad": c["bad"],
                            "good": c["good"], "line": c["text"]} for c in cs][:20], "model_date": str(model_date) if model_date else None}
    problems: list[str] = []
    best = good[-1] if len(good) == 1 else None   # one clear transaction-line date
    md = model_date
    if md is None:
        if best:
            info["filled_from_text"] = best.isoformat()
            return best, [], info
        return None, [], info   # validate() already says "no date found"
    if md > soon:
        if best:
            problems.append(f"date {md} is in the future; used {best} from the transaction line instead — check it")
            return best, problems, info
        return md, [f"date {md} is in the future — check it"], info
    same = [c for c in cs if _same(c, md)]
    if same and all(c["bad"] for c in same):
        if best and best != md:
            problems.append(f"date {md} is printed next to promo/expiry/survey wording; used {best} from the transaction line instead — check it")
            return best, problems, info
        problems.append(f"date {md} is printed next to promo/expiry/survey wording (\"{same[0]['text'][:60]}\") — check it's the purchase date")
        return md, problems, info
    if not same and good and md not in good:
        problems.append(f"date {md} isn't printed on the receipt; the transaction line says {good[-1]} — check it")
    elif len(good) > 1 and md not in good:
        problems.append(f"the receipt shows several dates ({', '.join(map(str, good))}) — check which is the purchase date")
    return md, problems, info


# ------------------------------------------------------------------ duplicates
def _vendor(v) -> str:
    v = re.sub(r"[^a-z0-9 ]", " ", (v or "").lower())
    v = re.sub(r"\b(store|inc|llc|co|corp|the|#?\d+)\b", " ", v)
    return " ".join(v.split())


def similar_vendor(a, b) -> bool:
    a, b = _vendor(a), _vendor(b)
    if not a or not b:
        return False
    return a == b or a in b or b in a or difflib.SequenceMatcher(None, a, b).ratio() >= 0.8


def _ej(d, k):
    e = d.get("extracted_json") or {}
    v = e.get(k) if isinstance(e, dict) else None
    v = re.sub(r"\s", "", str(v)) if v not in (None, "") else ""
    return v


def _day(v):
    if isinstance(v, date):
        return v
    try:
        return date.fromisoformat(str(v)[:10]) if v else None
    except ValueError:
        return None


def why_duplicate(a: dict, b: dict) -> str | None:
    """Why receipt b is probably the same purchase as receipt a, or None. Needs the same total and a similar
    vendor with dates within 3 days, or the same transaction number. Different card last-4s rule it out."""
    la, lb = _ej(a, "card_last4")[-4:], _ej(b, "card_last4")[-4:]
    if la and lb and la != lb:
        return None
    ta, tb = _ej(a, "transaction_id"), _ej(b, "transaction_id")
    if len(ta) >= 4 and ta == tb:
        return f"same transaction number {ta}"
    if a.get("total") is None or b.get("total") is None or Decimal(str(a["total"])) != Decimal(str(b["total"])) or Decimal(str(a["total"])) == 0:
        return None
    if not similar_vendor(a.get("vendor"), b.get("vendor")):
        return None
    da, db = _day(a.get("doc_date")), _day(b.get("doc_date"))
    if da and db and abs((da - db).days) > 3:
        return None
    tma, tmb = _ej(a, "transaction_time"), _ej(b, "transaction_time")
    if da and db and da == db and tma and tmb and tma[:5] != tmb[:5]:
        return None   # same shop, same total, same day, but a different time: two real purchases
    bits = ["same total", "same vendor" if _vendor(a.get("vendor")) == _vendor(b.get("vendor")) else "similar vendor"]
    bits.append("same date" if da and da == db else ("dates within 3 days" if da and db else "a date is missing"))
    if la and la == lb:
        bits.append(f"same card ··{la}")
    return ", ".join(bits)


def flags(docs: list[dict], events: list[tuple], today: date | None = None) -> dict:
    """Read-time flags for every receipt (nothing is changed in the data):
    {id: {"possible_duplicate_of", "duplicate_reason", "marked_duplicate_of", "date_flags": [...]}}.
    events: (document_id, step, detail) from the processing log, oldest first: dup_dismiss {"of"},
    dup_mark {"of"}, dup_unmark, date_ok {"date"}."""
    dismissed, marked, date_ok = set(), {}, {}
    for doc_id, step, detail in events:
        detail = detail or {}
        if step == "dup_dismiss":
            dismissed.add((doc_id, detail.get("of")))
        elif step == "dup_mark":
            marked[doc_id] = detail.get("of")
        elif step == "dup_unmark":
            marked.pop(doc_id, None)
        elif step == "date_ok":
            date_ok[doc_id] = detail.get("date")
    live = sorted((d for d in docs if d.get("status") not in ("failed", "processing")), key=lambda d: d["id"])
    out = {d["id"]: {"possible_duplicate_of": None, "duplicate_reason": None, "marked_duplicate_of": marked.get(d["id"]),
                     "date_flags": []} for d in docs}
    for i, b in enumerate(live):
        if out[b["id"]]["marked_duplicate_of"]:
            continue
        for a in live[:i]:
            if (b["id"], a["id"]) in dismissed or out[a["id"]]["marked_duplicate_of"]:
                continue
            r = why_duplicate(a, b)
            if r:
                out[b["id"]].update(possible_duplicate_of=a["id"], duplicate_reason=r)
                break
    # one date on many receipts from different shops is usually a promo date the model picked up
    by_day: dict = {}
    for d in live:
        if d.get("doc_date") and not out[d["id"]]["marked_duplicate_of"]:
            by_day.setdefault(str(d["doc_date"])[:10], set()).add(_vendor(d.get("vendor")) or f"#{d['id']}")
    for d in live:
        day = str(d["doc_date"])[:10] if d.get("doc_date") else None
        if not day or date_ok.get(d["id"]) == day:
            continue
        f = out[d["id"]]["date_flags"]
        _, probs, _ = check_date(_day(day), d.get("raw_text") or "", today)
        f.extend(probs)
        n = len(by_day.get(day, ()))
        if n >= 3:
            f.append(f"{n} receipts from different shops all have the date {day} — check it's the purchase date and not a promo date")
    return out
