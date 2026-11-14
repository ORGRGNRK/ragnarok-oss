#!/usr/bin/env python3
"""money.py -- "why is there no money at the end of the month?" for one small business.

Reads the business's own exports (CSV): bank statements, sales (POS / card processor / invoices) and
purchases (supplier bills). Works out where the money went and what to fix, in plain English.

    python3 money.py FILE.csv [FILE.csv ...] [--out DIR] [--rules rules.json] [--name "Shop name"]

A file's kind (bank / sales / purchases) is guessed from its column names. Force it with a prefix:
    bank:checking.csv  sales:square.csv  purchases:bills.csv

Writes into DIR (default ./money-report):
    report.html      the report to show the owner (one file, opens in any browser)
    report.md        the same as text
    summary.txt      a short version (fits a text message)
    findings.json    every finding with its dollars, evidence rows, fix and first step
    load.json        transactions + findings in the shape `./kit money load` puts into the database

Only Python's standard library. Reads files, writes DIR, nothing else: no network, no database.
Every dollar figure in a finding comes from rows listed under it, so the owner can check it.
"""
import argparse
import csv
import hashlib
import html
import io
import json
import os
import re
import statistics
import sys
from collections import defaultdict
from datetime import date, datetime, timedelta

HERE = os.path.dirname(os.path.abspath(__file__))

# ---------------------------------------------------------------- reading files

DATE_FORMATS = ["%Y-%m-%d", "%m/%d/%Y", "%m/%d/%y", "%Y/%m/%d", "%d-%b-%Y", "%b %d, %Y", "%m-%d-%Y",
                "%Y-%m-%dT%H:%M:%S", "%Y-%m-%d %H:%M:%S", "%m/%d/%Y %H:%M", "%m/%d/%Y %I:%M %p", "%Y-%m-%dT%H:%M:%SZ"]


def parse_date(s):
    s = (s or "").strip()
    if not s:
        return None
    for f in DATE_FORMATS:
        try:
            return datetime.strptime(s, f).date()
        except ValueError:
            pass
    m = re.match(r"(\d{4}-\d{2}-\d{2})", s)          # ISO with a time zone or fractions
    if m:
        return datetime.strptime(m.group(1), "%Y-%m-%d").date()
    return None


def parse_money(s):
    """'$1,234.50' -> 1234.5, '(12.00)' -> -12.0, '-$5' -> -5.0, '' -> None."""
    s = (s or "").strip()
    if not s:
        return None
    neg = s.startswith("(") and s.endswith(")") or s.startswith("-") or s.endswith("-") or s.upper().endswith(" DR")
    t = re.sub(r"[^0-9.]", "", s)
    if not t or t.count(".") > 1:
        return None
    v = float(t)
    return -v if neg else v


def key(h):
    return re.sub(r"[^a-z0-9]", "", (h or "").lower())


COLS = {
    "date": ["date", "transactiondate", "posteddate", "postingdate", "postdate", "txndate", "orderdate", "saledate",
             "invoicedate", "billdate", "createdat", "created", "datetime", "paiddate", "time"],
    "desc": ["description", "memo", "payee", "merchant", "details", "narrative", "transaction", "name",
             "transactiondescription", "originaldescription"],
    "amount": ["amount", "amt", "transactionamount", "value", "total", "totalamount", "billtotal", "invoicetotal"],
    "debit": ["debit", "debits", "withdrawal", "withdrawals", "moneyout", "paidout", "debitamount", "outflow"],
    "credit": ["credit", "credits", "deposit", "deposits", "moneyin", "paidin", "creditamount", "inflow"],
    "balance": ["balance", "runningbalance", "availablebalance"],
    "gross": ["gross", "grosssales", "grossamount", "subtotal", "saleamount", "total", "amount", "totalcollected"],
    "fee": ["fee", "fees", "processingfee", "processingfees", "cardfee", "transactionfee", "stripefee"],
    "net": ["net", "netamount", "nettotal", "payout", "netsales"],
    "sku": ["sku", "itemcode", "productcode", "partnumber", "itemsku", "code"],
    "item": ["item", "itemname", "product", "productname", "lineitem", "service", "itemdescription"],
    "qty": ["qty", "quantity", "units", "count", "quantitysold", "qtysold"],
    "unit": ["unitprice", "price", "priceeach", "rate", "unitcost", "cost", "costeach"],
    "status": ["status", "paymentstatus", "state", "paid"],
    "vendor": ["vendor", "supplier", "payee", "from", "billfrom", "vendorname", "suppliername"],
    "customer": ["customer", "customername", "client", "billto"],
    "due": ["duedate", "due"],
}


def find(cols, names, exclude=()):
    for n in names:
        if n in cols and cols[n] not in exclude:
            return cols[n]
    return None


def guess_kind(hkeys):
    h = set(hkeys)
    if h & {"balance", "runningbalance", "availablebalance"} or (h & set(COLS["debit"]) and h & set(COLS["credit"])):
        return "bank"
    if h & set(COLS["vendor"]) - {"payee", "from"} or h & {"unitcost", "costeach", "billdate", "billtotal"}:
        return "purchases"
    if h & set(COLS["fee"]) | set(COLS["net"]) | set(COLS["customer"]) | {"orderdate", "saledate", "invoicedate", "orderid", "invoice", "invoicenumber", "receipt", "receiptnumber"}:
        return "sales"
    return "bank"


def read_csv(path):
    with open(path, newline="", encoding="utf-8-sig", errors="replace") as f:
        text = f.read()
    lines = text.splitlines()
    # some banks put account info above the header: start at the first line that has a date-ish column name
    start = 0
    for i, ln in enumerate(lines[:30]):
        low = ln.lower()
        if "date" in low and ("," in ln or ";" in ln or "\t" in ln):
            start = i
            break
    body = "\n".join(lines[start:])
    try:
        dialect = csv.Sniffer().sniff(body[:4096], delimiters=",;\t|")
    except csv.Error:
        dialect = csv.excel
    rows = list(csv.reader(io.StringIO(body), dialect))
    if not rows:
        return [], []
    return rows[0], [r for r in rows[1:] if any(c.strip() for c in r)]


class Problem(Exception):
    pass


def load_file(spec):
    kind = None
    path = spec
    m = re.match(r"^(bank|sales|purchases):(.+)$", spec)
    if m:
        kind, path = m.group(1), m.group(2)
    if not os.path.isfile(path):
        raise Problem(f"no such file: {path}")
    header, rows = read_csv(path)
    hk = [key(h) for h in header]
    cols = {}
    for i, k in enumerate(hk):
        cols.setdefault(k, i)
    kind = kind or guess_kind(hk)
    name = os.path.basename(path)
    out, skipped = [], 0
    g = lambda r, i: r[i] if i is not None and i < len(r) else ""

    di = find(cols, COLS["date"])
    if di is None:
        raise Problem(f"{name}: can't find a date column (columns: {', '.join(header)})")

    for n, r in enumerate(rows, start=2):
        d = parse_date(g(r, di))
        if d is None:
            skipped += 1
            continue
        if kind == "bank":
            desc = g(r, find(cols, COLS["desc"]))
            ai, dbi, cri = find(cols, COLS["amount"]), find(cols, COLS["debit"]), find(cols, COLS["credit"])
            if dbi is not None or cri is not None:
                dv, cv = parse_money(g(r, dbi)), parse_money(g(r, cri))
                amt = (abs(cv) if cv else 0.0) - (abs(dv) if dv else 0.0)
                if dv is None and cv is None:
                    amt = parse_money(g(r, ai)) if ai is not None else None
            else:
                amt = parse_money(g(r, ai))
                ti = find(cols, ["type", "transactiontype", "drcr", "creditdebit"])
                if amt is not None and ti is not None and g(r, ti).strip().lower() in ("debit", "dr", "withdrawal", "d"):
                    amt = -abs(amt)
            if amt is None:
                skipped += 1
                continue
            out.append({"source": "bank", "file": name, "line": n, "date": d, "desc": desc.strip(), "amount": round(amt, 2)})
        elif kind == "sales":
            ui, qi_ = find(cols, ["unitprice", "price", "priceeach", "rate"]), find(cols, COLS["qty"])
            gi = find(cols, COLS["gross"], exclude=(ui,))
            qty = parse_money(g(r, qi_)) if qi_ is not None else None
            unit = parse_money(g(r, ui)) if ui is not None else None
            gross = parse_money(g(r, gi)) if gi is not None else None
            if gross is None and unit is not None:
                gross = unit * (qty or 1)
            if gross is None:
                skipped += 1
                continue
            fee = parse_money(g(r, find(cols, COLS["fee"])))
            net = parse_money(g(r, find(cols, COLS["net"])))
            if fee is None and net is not None:
                fee = round(gross - net, 2)
            item = g(r, find(cols, COLS["item"])).strip()
            out.append({"source": "sales", "file": name, "line": n, "date": d, "gross": round(gross, 2),
                        "fee": abs(fee) if fee is not None else None, "sku": g(r, find(cols, COLS["sku"])).strip(),
                        "item": item, "qty": qty if qty is not None else 1.0, "unit": unit,
                        "status": g(r, find(cols, COLS["status"])).strip().lower(),
                        "customer": g(r, find(cols, COLS["customer"])).strip(),
                        "due": parse_date(g(r, find(cols, COLS["due"]))),
                        "desc": item or g(r, find(cols, COLS["customer"])).strip() or "sale"})
        else:
            ui, qi_ = find(cols, ["unitcost", "costeach", "unitprice", "price", "cost", "rate"]), find(cols, COLS["qty"])
            ai = find(cols, ["amount", "total", "totalamount", "billtotal", "linetotal", "extendedcost", "value"], exclude=(ui,))
            qty = parse_money(g(r, qi_)) if qi_ is not None else None
            unit = parse_money(g(r, ui)) if ui is not None else None
            amt = parse_money(g(r, ai)) if ai is not None else None
            if amt is None and unit is not None:
                amt = unit * (qty or 1)
            if amt is None:
                skipped += 1
                continue
            if unit is None and qty:
                unit = abs(amt) / qty
            out.append({"source": "purchases", "file": name, "line": n, "date": d, "amount": round(abs(amt), 2),
                        "vendor": g(r, find(cols, COLS["vendor"])).strip(), "sku": g(r, find(cols, COLS["sku"])).strip(),
                        "item": g(r, find(cols, COLS["item"] + ["description"])).strip(), "qty": qty if qty is not None else 1.0,
                        "unit": abs(unit) if unit is not None else None,
                        "desc": g(r, find(cols, COLS["vendor"])).strip() or "purchase"})
    return kind, name, out, skipped, header


# ---------------------------------------------------------------- sorting spending into groups

def load_rules(extra=None):
    with open(os.path.join(HERE, "rules.json")) as f:
        rules = json.load(f)
    if extra and os.path.isfile(extra):
        with open(extra) as f:
            more = json.load(f)
        for cat, words in more.get("categories", {}).items():
            rules["categories"][cat] = list(words) + [w for w in rules["categories"].get(cat, []) if w not in words]
        for k in ("processors", "lenders"):
            rules[k] = list(more.get(k, [])) + rules[k]
    return rules


def categorize(desc, amount, rules):
    d = re.sub(r"\s+", " ", desc.lower())
    for cat, words in rules["categories"].items():
        if cat.startswith("_"):
            continue
        if cat.startswith("Money in") and amount <= 0:
            continue
        if amount > 0 and not cat.startswith("Money in") and cat not in ("Transfers", "Loans and advances"):
            continue
        for w in words:
            if has_word(d, w):
                return cat
    return "Money in: other" if amount > 0 else "Other spending"


def has_word(text, w):
    """w appears in text, not inside a longer word: "nsf" doesn't match "transfer", "rent" doesn't match "current"."""
    w = w.strip().lower()
    if not w:
        return False
    pat = ("(?<![a-z0-9])" if w[0].isalnum() else "") + re.escape(w) + ("(?![a-z0-9])" if w[-1].isalnum() else "")
    return re.search(pat, text) is not None


NOISE = re.compile(r"\b(pos|debit|card|purchase|recurring|payment|pmt|ach|withdrawal|checkcard|visa|mc|online|"
                   r"web|ppd|ccd|id|ref|des|indn|co|inc|llc|www|com|autopay|bill|pay|preauthorized|electronic|"
                   r"transfer|xfer|to|from)\b")


def merchant(desc):
    d = desc.lower()
    d = re.sub(r"[#*]\S*", " ", d)
    d = re.sub(r"\d+", " ", d)
    d = re.sub(r"[^a-z& ]", " ", d)
    d = NOISE.sub(" ", d)
    words = [w for w in d.split() if len(w) > 1]
    return " ".join(words[:3]) or desc.lower().strip()[:20]


# ---------------------------------------------------------------- the analysis

def money_fmt(v):
    s = f"${abs(v):,.0f}" if abs(v) >= 100 else f"${abs(v):,.2f}"
    return "-" + s if v < 0 else s


def month(d):
    return d.strftime("%Y-%m")


def months_between(a, b):
    return max(1.0, ((b - a).days + 1) / 30.44)


def row_text(t):
    if t["source"] == "bank":
        return f'{t["date"]}  {money_fmt(t["amount"]):>10}  {t["desc"]}   ({t["file"]} line {t["line"]})'
    if t["source"] == "sales":
        extra = f' fee {money_fmt(t["fee"])}' if t.get("fee") is not None else ""
        return f'{t["date"]}  {money_fmt(t["gross"]):>10}{extra}  {t["desc"]}   ({t["file"]} line {t["line"]})'
    return f'{t["date"]}  {money_fmt(t["amount"]):>10}  {t["vendor"]} {t["item"]}   ({t["file"]} line {t["line"]})'


def finding(fid, title, why, per_month, fix, first_step, evidence, effort="easy", sure=True, one_time=0.0):
    """per_month: what fixing it is worth every month. one_time: money to get back once (refunds, unpaid invoices)."""
    return {"id": fid, "title": title, "why": why, "per_month": round(per_month, 2), "one_time": round(one_time, 2), "fix": fix,
            "first_step": first_step, "effort": effort, "sure": sure,
            "evidence": [row_text(t) if isinstance(t, dict) else t for t in evidence][:25],
            "evidence_count": len(evidence)}


def recurring_groups(outs):
    """Bank money-out grouped by merchant; groups that repeat on a schedule."""
    by = defaultdict(list)
    for t in outs:
        by[merchant(t["desc"])].append(t)
    groups = []
    for m, ts in by.items():
        if len(ts) < 3:
            continue
        ts.sort(key=lambda t: t["date"])
        gaps = [(b["date"] - a["date"]).days for a, b in zip(ts, ts[1:])]
        gaps = [x for x in gaps if x > 0] or [0]
        gap = statistics.median(gaps)
        amts = [-t["amount"] for t in ts]
        med = statistics.median(amts)
        steady = sum(1 for a in amts if abs(a - med) <= max(1.0, 0.15 * med)) >= 0.7 * len(amts)
        if 25 <= gap <= 35:
            every = "month"
            per_month = med
        elif 6 <= gap <= 8:
            every = "week"
            per_month = med * 4.33
        elif 1 <= gap <= 3 and len(ts) >= 8:
            every = "business day"
            per_month = sum(amts) / months_between(ts[0]["date"], ts[-1]["date"])
        else:
            continue
        groups.append({"merchant": m, "rows": ts, "every": every, "per_month": per_month, "steady": steady,
                       "first": amts[0], "last": amts[-1], "median": med})
    return groups


def analyze(txns, rules, name=""):
    bank = [t for t in txns if t["source"] == "bank"]
    sales = [t for t in txns if t["source"] == "sales"]
    buys = [t for t in txns if t["source"] == "purchases"]
    for t in bank:
        t["category"] = categorize(t["desc"], t["amount"], rules)
        t["merchant"] = merchant(t["desc"])
    for t in sales:
        t["category"] = "Sales"
    for t in buys:
        t["category"] = "Purchases"

    alld = [t["date"] for t in txns]
    if not alld:
        raise Problem("no usable rows in the files")
    start, end = min(alld), max(alld)
    findings, picture = [], {}

    # -- the cash picture (bank)
    if bank:
        bs, be = min(t["date"] for t in bank), max(t["date"] for t in bank)
        nm = months_between(bs, be)
        ins = [t for t in bank if t["amount"] > 0 and t["category"] != "Transfers"]
        outs = [t for t in bank if t["amount"] < 0 and t["category"] != "Transfers"]
        by_month = defaultdict(lambda: [0.0, 0.0])
        for t in bank:
            if t["category"] == "Transfers":
                continue
            by_month[month(t["date"])][0 if t["amount"] > 0 else 1] += t["amount"]
        by_cat = defaultdict(float)
        for t in outs:
            by_cat[t["category"]] += -t["amount"]
        by_merch = defaultdict(float)
        for t in outs:
            by_merch[t["merchant"]] += -t["amount"]
        tin, tout = sum(t["amount"] for t in ins), -sum(t["amount"] for t in outs)
        picture = {"from": str(bs), "to": str(be), "months": round(nm, 1),
                   "in_per_month": round(tin / nm, 2), "out_per_month": round(tout / nm, 2),
                   "net_per_month": round((tin - tout) / nm, 2),
                   "by_month": [{"month": k, "in": round(v[0], 2), "out": round(-v[1], 2), "net": round(v[0] + v[1], 2)}
                                for k, v in sorted(by_month.items())],
                   "by_category": [{"category": k, "per_month": round(v / nm, 2), "share": round(v / tout, 3) if tout else 0}
                                   for k, v in sorted(by_cat.items(), key=lambda x: -x[1])],
                   "top_payees": [{"payee": k, "per_month": round(v / nm, 2)} for k, v in sorted(by_merch.items(), key=lambda x: -x[1])[:12]]}

        if tin - tout < 0:
            findings.append(finding(
                "losing-money", "More money goes out than comes in",
                f"Over {nm:.1f} months the bank shows {money_fmt(tin)} in and {money_fmt(tout)} out "
                f"(transfers between your own accounts left out). That's {money_fmt((tin - tout) / nm)} a month.",
                0, "The items below are where to start. Each one says how much it is worth a month.",
                "Read the first item on this list.", [f'{m["month"]}: in {money_fmt(m["in"])}, out {money_fmt(m["out"])}, net {money_fmt(m["net"])}'
                                                       for m in picture["by_month"]], sure=True))

        # -- bank fees: overdrafts, returned items, monthly charges
        fees = [t for t in outs if t["category"] == "Bank fees"]
        if fees:
            od = [t for t in fees if re.search(r"overdraft|nsf|insufficient|returned item|od fee|od item", t["desc"], re.I)]
            per = -sum(t["amount"] for t in fees) / nm
            findings.append(finding(
                "bank-fees", "Bank fees" + (" (including overdrafts)" if od else ""),
                f"{len(fees)} bank fees, {money_fmt(-sum(t['amount'] for t in fees))} in total"
                + (f"; {len(od)} of them are overdraft or returned-payment fees, which happen when the account runs dry before money comes in." if od else "."),
                per,
                "Ask the bank to refund the overdraft fees (banks often refund the first few when asked) and to "
                "switch on overdraft protection from savings, or move bills that hit before your deposits land "
                "to a later day of the month." if od else "Ask the bank for a no-fee business account or what balance waives the fee.",
                "Call the bank and ask them to refund the overdraft fees listed here." if od else "Call the bank and ask what it takes to waive the monthly fee.",
                fees))

        # -- daily / weekly lender pulls (merchant cash advances)
        groups = recurring_groups(outs)
        lend = [g for g in groups if g["every"] in ("business day", "week")
                and (any(has_word(g["rows"][0]["desc"].lower(), w) for w in rules["lenders"])
                     or g["rows"][0]["category"] == "Loans and advances")]
        for g in lend:
            findings.append(finding(
                "advance-" + slug(g["merchant"]), f'{money_fmt(g["median"])} taken every {g["every"]} by "{g["rows"][0]["desc"][:40]}" (looks like a cash advance)',
                f'This lender takes money every {g["every"]}: {len(g["rows"])} pulls, about {money_fmt(g["per_month"])} a month. '
                "Daily or weekly pulls like this are usually a cash advance, which is one of the most expensive "
                "ways to borrow, and it drains the account before bills are paid.",
                g["per_month"],
                "Find the contract and work out what you still owe and the real yearly cost. Don't take a new "
                "advance to pay off this one. A bank or SBA loan, or a credit union line, is usually far cheaper to refinance into.",
                "Find the advance contract and write down the payback amount and how much is left.", g["rows"], effort="hard"))

        # -- subscriptions: what they cost, price rises, look-alikes
        subs = [g for g in groups if g["every"] == "month" and g["steady"] and g not in lend]
        soft = [g for g in subs if g["rows"][0]["category"] in ("Software and subscriptions", "Phone and internet")]
        if soft:
            per = sum(g["per_month"] for g in soft)
            findings.append(finding(
                "subscriptions", f"{len(soft)} monthly subscriptions, {money_fmt(per)} a month",
                "Software, apps and services billed every month. Each one is small; together they add up. "
                "Check each one is still used by someone.",
                0, "Go down the list with whoever uses each tool. Cancel anything no one opened last month.",
                "Pick the one you're least sure about and log in to see when it was last used.",
                [f'{money_fmt(g["median"])}/month  {g["rows"][-1]["desc"]}  (last {g["rows"][-1]["date"]})' for g in sorted(soft, key=lambda g: -g["per_month"])],
                sure=False))
        def stepped_up(g):
            a = [-t["amount"] for t in g["rows"]]
            return (len(a) >= 3 and abs(a[-1] - a[-2]) <= 0.01 * a[-1] and abs(a[0] - a[1]) <= 0.01 * a[0]
                    and a[-1] > a[0] * 1.05 and a[-1] - a[0] >= 2)
        rises = [g for g in subs if stepped_up(g) and g["rows"][0]["category"] not in ("Utilities", "Vehicle and fuel")]
        for g in rises:
            findings.append(finding(
                "price-rise-" + slug(g["merchant"]), f'"{g["rows"][0]["desc"][:40]}" went up {money_fmt(g["last"] - g["first"])} a month',
                f'It started at {money_fmt(g["first"])} and is now {money_fmt(g["last"])}. Price rises on autopay are easy to miss.',
                g["last"] - g["first"],
                "Call or email and ask for the old price, or shop the same service elsewhere.",
                "Ask them to put you back on the old price.", g["rows"]))
        firsts = defaultdict(list)
        for g in soft:
            firsts[g["merchant"].split()[0]].append(g)
        for w, gs in firsts.items():
            if len(gs) > 1:
                findings.append(finding(
                    "overlap-" + slug(w), f'{len(gs)} separate "{w}" subscriptions',
                    "More than one monthly charge from the same company. Sometimes that's on purpose; often it's a "
                    "second seat or plan someone forgot about.",
                    min(g["per_month"] for g in gs),
                    "Check whether both are needed; if not, cancel one or combine them on one plan.",
                    f'Log in to the {w} account and see what each charge is for.', [r for g in gs for r in g["rows"]], sure=False))

        # -- the same charge twice
        recurring_ids = {id(t) for g in groups for t in g["rows"]}
        dups, seen = [], defaultdict(list)
        for t in sorted(outs, key=lambda t: t["date"]):
            if id(t) in recurring_ids or -t["amount"] < 20:
                continue
            k = (t["merchant"], t["amount"])
            for p in seen[k]:
                if 0 <= (t["date"] - p["date"]).days <= 3:
                    dups.append((p, t))
                    break
            seen[k].append(t)
        if dups:
            total = sum(-b["amount"] for _, b in dups)
            findings.append(finding(
                "double-charges", f"{len(dups)} charge{'s' if len(dups) > 1 else ''} that look{'' if len(dups) > 1 else 's'} like {'they' if len(dups) > 1 else 'it'} went through twice",
                f"Same payee, same amount, within 3 days: {money_fmt(total)} in total. Some may be real (two "
                "orders), so check each one.",
                0, "Ask the payee (or your card company) to refund any that were charged twice.",
                "Check the biggest one against your receipts.", [r for pair in dups for r in pair], sure=False, one_time=total))

    # -- card processing fees and missing deposits (sales vs bank)
    if sales:
        ss, se = min(t["date"] for t in sales), max(t["date"] for t in sales)
        snm = months_between(ss, se)
        gross = sum(t["gross"] for t in sales if t["status"] not in ("refunded", "void", "voided", "cancelled", "canceled"))
        with_fee = [t for t in sales if t.get("fee") is not None and t["gross"] > 0]
        picture["sales_per_month"] = round(gross / snm, 2)
        if with_fee:
            fg, ff = sum(t["gross"] for t in with_fee), sum(t["fee"] for t in with_fee)
            rate = ff / fg if fg else 0
            picture["card_fee_rate"] = round(rate, 4)
            target = rules.get("fair_card_rate", 0.029)
            if rate > target + 0.002:
                findings.append(finding(
                    "card-fees", f"Card fees are {rate * 100:.1f}% of sales",
                    f"{money_fmt(ff)} in fees on {money_fmt(fg)} of card sales. Shops your size can often get "
                    f"around {target * 100:.1f}%, so you're paying about {money_fmt((rate - target) * fg / snm)} a month more than you need to.",
                    (rate - target) * fg / snm,
                    "Ask your processor for a lower rate (show them a competing quote), or get quotes from two others. "
                    "Look for monthly fees, PCI fees and 'non-qualified' surcharges on the statement.",
                    "Call the processor and ask: \"What's my effective rate, and what can you do to lower it?\"",
                    sorted(with_fee, key=lambda t: -t["fee"])[:15], effort="medium"))
        if bank:
            proc = [t for t in bank if t["amount"] > 0 and (t["category"] == "Money in: sales deposits"
                                                            or any(has_word(t["desc"].lower(), w) for w in rules["processors"]))]
            lo, hi = max(ss, min(t["date"] for t in bank)), min(se, max(t["date"] for t in bank) - timedelta(days=3))
            if proc and hi > lo:
                sold = sum((t["gross"] - (t["fee"] or 0)) for t in sales if lo <= t["date"] <= hi and t["status"] not in ("refunded", "void", "voided", "cancelled", "canceled", "unpaid", "open", "overdue", "due"))
                dep = sum(t["amount"] for t in proc if lo <= t["date"] <= hi + timedelta(days=3))
                gap = sold - dep
                days = defaultdict(float)
                for t in sales:
                    if lo <= t["date"] <= hi and t["status"] not in ("refunded", "void", "voided", "cancelled", "canceled", "unpaid", "open", "overdue", "due"):
                        days[t["date"]] += t["gross"] - (t["fee"] or 0)
                lost = unmatched_days(days, [t for t in proc if lo <= t["date"] <= hi + timedelta(days=5)])
                lost_total = sum(v for _, v in lost)
                if sold > 0 and (lost_total > 50 or gap > max(50, 0.02 * sold)):
                    shown = lost_total if lost_total > 50 else gap
                    findings.append(finding(
                        "missing-deposits", f"{money_fmt(shown)} of card sales never reached the bank",
                        (f"{len(lost)} day{'s' if len(lost) > 1 else ''} of sales with no matching deposit. " if lost else "")
                        + f"Between {lo} and {hi} your sales records say {money_fmt(sold)} should have landed (after card fees); "
                        f"the bank shows {money_fmt(dep)} of sales deposits. Missing money like this is refunds, chargebacks, "
                        "processor holds, cash that wasn't deposited, or payouts going to another account.",
                        shown / months_between(lo, hi),
                        "Look up each day listed here in the processor's payout report. If the payout went to another "
                        "account or is on hold, call the processor; if it was cash, check that day's drawer count.",
                        "Look up the first day listed here in your processor's payout report.",
                        [f"{d}: {money_fmt(v)} of sales (after fees), no deposit matches it" for d, v in lost]
                        or [f"sales after fees {money_fmt(sold)} vs deposits {money_fmt(dep)}"], effort="medium", one_time=shown))

        # unpaid invoices
        unpaid = [t for t in sales if t["status"] in ("unpaid", "open", "overdue", "due", "sent", "outstanding")]
        if unpaid:
            old = [t for t in unpaid if (end - (t["due"] or t["date"])).days > 30]
            amt = sum(t["gross"] for t in unpaid)
            findings.append(finding(
                "unpaid-invoices", f"{money_fmt(amt)} owed to you in unpaid invoices",
                f"{len(unpaid)} invoices not paid yet" + (f", {len(old)} of them more than 30 days past due." if old else ".") +
                " That's money you've earned but can't spend.",
                0, "Send reminders today; for the oldest, call. Ask new customers to pay a deposit up front.",
                "Text or call the customer with the oldest unpaid invoice.", sorted(unpaid, key=lambda t: t["date"]), sure=True, one_time=amt))

    # -- what things cost vs what they sell for (needs SKUs or item names on both sides)
    if sales and buys:
        cost = {}
        by = defaultdict(lambda: [0.0, 0.0])
        for t in buys:
            k = (t["sku"] or t["item"]).lower()
            if k and t["unit"]:
                by[k][0] += t["unit"] * (t["qty"] or 1)
                by[k][1] += t["qty"] or 1
        for k, (c, q) in by.items():
            if q:
                cost[k] = c / q
        sold = defaultdict(lambda: [0.0, 0.0, []])
        for t in sales:
            k = (t["sku"] or t["item"]).lower()
            if k in cost and t["status"] not in ("refunded", "void", "voided", "cancelled", "canceled"):
                sold[k][0] += t["gross"]
                sold[k][1] += t["qty"] or 1
                sold[k][2].append(t)
        snm = months_between(min(t["date"] for t in sales), max(t["date"] for t in sales))
        under, thin = [], []
        for k, (rev, q, rows) in sold.items():
            price = rev / q
            margin = (price - cost[k]) / price if price else 0
            if price < cost[k]:
                under.append((k, price, cost[k], q, rows))
            elif margin < rules.get("thin_margin", 0.15):
                thin.append((k, price, cost[k], q, rows, margin))
        if under:
            loss = sum((c - p) * q for _, p, c, q, _ in under)
            findings.append(finding(
                "sold-below-cost", f"{len(under)} item{'s' if len(under) > 1 else ''} sold for less than {'they' if len(under) > 1 else 'it'} cost",
                "Your supplier bills say these cost you more than you sold them for: "
                + "; ".join(f"{k}: cost {money_fmt(c)}, sold at {money_fmt(p)} average ({q:.0f} sold)" for k, p, c, q, _ in under[:6]) + ".",
                loss / snm, "Raise the price on these, find a cheaper supplier, or stop stocking them.",
                f"Change the price of {names_of(under[0][4])} today.", [r for *_, rows in under for r in rows[:5]]))
        if thin:
            findings.append(finding(
                "thin-margin", f"{len(thin)} item{'s' if len(thin) > 1 else ''} with very little profit",
                "These sell for less than 15% above what they cost, before rent, wages and card fees: "
                + "; ".join(f"{k}: cost {money_fmt(c)}, sold at {money_fmt(p)} ({m * 100:.0f}%)" for k, p, c, q, _, m in thin[:6]) + ".",
                sum((p * 0.3 - (p - c)) * q for _, p, c, q, _, _ in thin if p * 0.3 > p - c) / snm,
                "Price these to at least 30% over cost, or treat them as a deliberate loss-leader.",
                f"Look up what competitors charge for {names_of(thin[0][4])}.", [r for *_, rows, _m in thin for r in rows[:5]], sure=False))
        # cash tied up in stock: bought many more of an item than were sold in the same period
        names = {}
        for t in buys + sales:
            k = (t["sku"] or t["item"]).lower()
            names.setdefault(k, t["sku"] or t["item"])
        piles = []
        for k, (c, q) in by.items():
            sq = sold[k][1] if k in sold else 0
            if q - sq > max(3, 0.2 * sq):
                piles.append((names.get(k, k), q, sq, (q - sq) * cost[k]))
        piles.sort(key=lambda x: -x[3])
        tied = sum(x[3] for x in piles)
        if tied > 200:
            findings.append(finding(
                "stock-pileup", f"{money_fmt(tied)} of stock bought but not sold",
                "Bought more than sold over the same months: "
                + "; ".join(f"{n}: bought {q:.0f}, sold {sq:.0f} ({money_fmt(v)} at cost)" for n, q, sq, v in piles[:6])
                + ". That's money sitting on a shelf instead of in the bank.",
                0, "Order to what actually sells, and mark down extras to turn them back into cash.",
                f"Count how many {piles[0][0]} are on the shelf, then cut the next order to match what sells in a week.",
                [f"{n}: bought {q:.0f}, sold {sq:.0f}, extra worth {money_fmt(v)} at cost" for n, q, sq, v in piles],
                effort="medium", one_time=tied))

    findings.sort(key=lambda f: (-f["per_month"], f["id"]))
    easy = [f for f in findings if f["per_month"] > 0 and f["effort"] == "easy"]
    first = (easy or [f for f in findings if f["per_month"] > 0] or findings or [None])[0]
    return {"name": name, "from": str(start), "to": str(end), "picture": picture, "findings": findings,
            "first_step": first and {"id": first["id"], "title": first["title"], "step": first["first_step"]},
            "found_per_month": round(sum(f["per_month"] for f in findings if f["sure"]), 2),
            "maybe_per_month": round(sum(f["per_month"] for f in findings if not f["sure"]), 2),
            "one_time": round(sum(f["one_time"] for f in findings), 2),
            "counts": {"bank": len(bank), "sales": len(sales), "purchases": len(buys)}}


def unmatched_days(days, deposits, tol=0.01):
    """Processors pay out one day, or a few days together (weekends). Each deposit is matched to a run of 1-3
    sales days ending 0-5 days before it whose total is within 1%. Sales days no deposit matched are returned."""
    left = {d: v for d, v in days.items() if v > 0}
    for dep in sorted(deposits, key=lambda t: t["date"]):
        cands = sorted([d for d in left if 0 <= (dep["date"] - d).days <= 5], reverse=True)
        hit = None
        for i in range(len(cands)):
            run = []
            for d in cands[i:i + 3]:
                run.append(d)
                if abs(sum(left[x] for x in run) - dep["amount"]) <= max(1.0, tol * dep["amount"]):
                    hit = run
                    break
            if hit:
                break
        for d in hit or []:
            del left[d]
    return sorted(left.items())


def names_of(rows):
    t = rows[0]
    return t["item"] or t["sku"] if t["item"] else t["sku"]


def slug(s):
    return re.sub(r"[^a-z0-9]+", "-", s.lower()).strip("-")[:40] or "x"


# ---------------------------------------------------------------- writing the report

def report_md(r, files):
    p, L = r["picture"], []
    L.append(f'# Where the money went{": " + r["name"] if r["name"] else ""}')
    L.append(f'{r["from"]} to {r["to"]}. Read from: ' + ", ".join(f"{n} ({k}, {c} rows)" for k, n, c, _ in files) + ".")
    if p.get("in_per_month") is not None:
        L += ["", "## The short version", "",
              f'- In: **{money_fmt(p["in_per_month"])}** a month. Out: **{money_fmt(p["out_per_month"])}** a month. '
              f'Left over: **{money_fmt(p["net_per_month"])}** a month.']
    if r["found_per_month"]:
        L.append(f'- Fixes below are worth about **{money_fmt(r["found_per_month"])} a month**'
                 + (f' (plus up to {money_fmt(r["maybe_per_month"])} more to check).' if r["maybe_per_month"] else "."))
    if r["one_time"]:
        L.append(f'- Money to get back once (refunds, missing deposits, unpaid invoices): **{money_fmt(r["one_time"])}**.')
    if r["first_step"]:
        L.append(f'- **Easiest first step:** {r["first_step"]["step"]}')
    if p.get("by_category"):
        L += ["", "## Where it goes (a month)", "", "| Spending | A month | Share |", "|---|---:|---:|"]
        L += [f'| {c["category"]} | {money_fmt(c["per_month"])} | {c["share"] * 100:.0f}% |' for c in p["by_category"]]
        L += ["", "## Month by month", "", "| Month | In | Out | Left |", "|---|---:|---:|---:|"]
        L += [f'| {m["month"]} | {money_fmt(m["in"])} | {money_fmt(m["out"])} | {money_fmt(m["net"])} |' for m in p["by_month"]]
    L += ["", "## What to fix, biggest first", ""]
    for i, f in enumerate(r["findings"], 1):
        worth = (f' — about {money_fmt(f["per_month"])} a month' if f["per_month"] > 0 else "") + \
                (f' ({money_fmt(f["one_time"])} to get back)' if f["one_time"] > 0 else "")
        L += [f'### {i}. {f["title"]}{worth}' + ("" if f["sure"] else " (check)"), "", f["why"], "",
              f'**Fix:** {f["fix"]}', "", f'**First step:** {f["first_step"]}', "",
              f'Rows behind this ({f["evidence_count"]}' + (", first 25" if f["evidence_count"] > 25 else "") + "):", "", "```"]
        L += f["evidence"] + ["```", ""]
    if not r["findings"]:
        L.append("Nothing stood out in these files.")
    L += ["", "---", "How this was worked out: every figure comes from the rows listed under it. "
          "\"(check)\" means it might be on purpose, so look before acting. Transfers between your own accounts are left out."]
    return "\n".join(L) + "\n"


def report_txt(r):
    p = r["picture"]
    s = [f'{r["name"] or "Money check"} {r["from"]}..{r["to"]}']
    if p.get("net_per_month") is not None:
        s.append(f'In {money_fmt(p["in_per_month"])}/mo, out {money_fmt(p["out_per_month"])}/mo, left {money_fmt(p["net_per_month"])}/mo.')
    top = [f for f in r["findings"] if f["per_month"] > 0 or f["one_time"] > 0][:3]
    for f in top:
        s.append(f'- {f["title"]}' + (f': ~{money_fmt(f["per_month"])}/mo' if f["per_month"] > 0 else f': {money_fmt(f["one_time"])} to get back'))
    if r["first_step"]:
        s.append(f'First step: {r["first_step"]["step"]}')
    return "\n".join(s) + "\n"


CSS = """
:root{--bg:#fbfaf7;--fg:#1d1d1b;--muted:#6b6a65;--line:#e4e1d8;--card:#fff;--bad:#b3261e;--good:#1b6e3a;--accent:#8a5a00}
@media (prefers-color-scheme:dark){:root{--bg:#161614;--fg:#ecebe6;--muted:#a3a29b;--line:#34332f;--card:#1f1f1c;--bad:#ff8a80;--good:#7fd69b;--accent:#f0b85a}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--fg);font:16px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif}
main{max-width:860px;margin:0 auto;padding:32px 16px 64px}h1{font-size:28px;margin:0 0 4px}h2{font-size:19px;margin:36px 0 10px}
.muted{color:var(--muted);font-size:14px}.big{display:grid;grid-template-columns:repeat(auto-fit,minmax(170px,1fr));gap:10px;margin:18px 0}
.tile{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:12px 14px}.tile b{display:block;font-size:24px;font-variant-numeric:tabular-nums}
.first{background:var(--card);border:2px solid var(--accent);border-radius:10px;padding:14px 16px;margin:14px 0}
table{border-collapse:collapse;width:100%;font-variant-numeric:tabular-nums}td,th{padding:6px 8px;border-bottom:1px solid var(--line);text-align:left}td.n,th.n{text-align:right}
.bar{height:8px;background:var(--accent);border-radius:4px;opacity:.75}
details{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:12px 16px;margin:10px 0}summary{cursor:pointer;font-weight:600}
summary .w{float:right;color:var(--bad);font-variant-numeric:tabular-nums}.tag{font-size:12px;border:1px solid var(--line);border-radius:6px;padding:1px 6px;margin-left:6px;color:var(--muted);font-weight:400}
pre{overflow-x:auto;font-size:12.5px;background:var(--bg);border:1px solid var(--line);border-radius:6px;padding:8px}.neg{color:var(--bad)}.pos{color:var(--good)}
"""


def report_html(r, files):
    e, p = html.escape, r["picture"]
    H = [f'<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">'
         f'<title>Where the money went</title><style>{CSS}</style></head><body><main>',
         f'<h1>Where the money went</h1><div class="muted">{e(r["name"] + " · ") if r["name"] else ""}{e(r["from"])} to {e(r["to"])} · read from '
         + e(", ".join(f"{n} ({k}, {c} rows)" for k, n, c, _ in files)) + "</div>"]
    if p.get("in_per_month") is not None:
        cls = "neg" if p["net_per_month"] < 0 else "pos"
        H.append('<div class="big">'
                 f'<div class="tile">Money in a month<b>{money_fmt(p["in_per_month"])}</b></div>'
                 f'<div class="tile">Money out a month<b>{money_fmt(p["out_per_month"])}</b></div>'
                 f'<div class="tile">Left over a month<b class="{cls}">{money_fmt(p["net_per_month"])}</b></div>'
                 + (f'<div class="tile">Fixes found, a month<b class="pos">{money_fmt(r["found_per_month"])}</b></div>' if r["found_per_month"] else "")
                 + (f'<div class="tile">To get back once<b class="pos">{money_fmt(r["one_time"])}</b></div>' if r["one_time"] else "")
                 + "</div>")
    if r["first_step"]:
        H.append(f'<div class="first"><b>Easiest first step:</b> {e(r["first_step"]["step"])}<div class="muted">From: {e(r["first_step"]["title"])}</div></div>')
    H.append("<h2>What to fix, biggest first</h2>")
    for f in r["findings"]:
        worth = (f'<span class="w">{money_fmt(f["per_month"])}/mo</span>' if f["per_month"] > 0 else
                 f'<span class="w">{money_fmt(f["one_time"])} back</span>' if f["one_time"] > 0 else "")
        tag = "" if f["sure"] else '<span class="tag">check first</span>'
        H.append(f'<details><summary>{e(f["title"])}{tag}{worth}</summary><p>{e(f["why"])}</p><p><b>Fix:</b> {e(f["fix"])}</p>'
                 f'<p><b>First step:</b> {e(f["first_step"])}</p><div class="muted">Rows behind this ({f["evidence_count"]}'
                 + (", first 25" if f["evidence_count"] > 25 else "") + f'):</div><pre>{e(chr(10).join(f["evidence"]))}</pre></details>')
    if not r["findings"]:
        H.append("<p>Nothing stood out in these files.</p>")
    if p.get("by_category"):
        top = max(c["per_month"] for c in p["by_category"]) or 1
        H.append('<h2>Where it goes, a month</h2><table><tr><th>Spending</th><th class="n">A month</th><th class="n">Share</th><th style="width:30%"></th></tr>')
        H += [f'<tr><td>{e(c["category"])}</td><td class="n">{money_fmt(c["per_month"])}</td><td class="n">{c["share"] * 100:.0f}%</td>'
              f'<td><div class="bar" style="width:{c["per_month"] / top * 100:.0f}%"></div></td></tr>' for c in p["by_category"]]
        H.append('</table><h2>Month by month</h2><table><tr><th>Month</th><th class="n">In</th><th class="n">Out</th><th class="n">Left</th></tr>')
        H += [f'<tr><td>{m["month"]}</td><td class="n">{money_fmt(m["in"])}</td><td class="n">{money_fmt(m["out"])}</td>'
              f'<td class="n {"neg" if m["net"] < 0 else ""}">{money_fmt(m["net"])}</td></tr>' for m in p["by_month"]]
        H.append('</table><h2>Biggest payees, a month</h2><table>')
        H += [f'<tr><td>{e(t["payee"])}</td><td class="n">{money_fmt(t["per_month"])}</td></tr>' for t in p["top_payees"]]
        H.append("</table>")
    H.append('<p class="muted">Every figure comes from the rows listed under it. "Check first" means it may be on purpose. '
             "Transfers between your own accounts are left out.</p></main></body></html>")
    return "".join(H)


def load_json(r, txns):
    """Rows for the kit's two money tables (see money/tables.json)."""
    seen = defaultdict(int)
    rows = []
    for t in sorted(txns, key=lambda t: (t["date"], t["file"], t["line"])):
        amt = t["amount"] if t["source"] == "bank" else (t["gross"] if t["source"] == "sales" else -t["amount"])
        desc = t["desc"] if t["source"] != "purchases" else f'{t["vendor"]} {t["item"]}'.strip()
        base = f'{t["source"]}|{t["date"]}|{desc}|{amt:.2f}'
        seen[base] += 1          # the same row twice in one file is two rows; the same file loaded twice is not
        rows.append({"Row Key": hashlib.sha256(f"{base}|{seen[base]}".encode()).hexdigest()[:24],
                     "Date": str(t["date"]), "Source": t["source"], "Description": desc[:500], "Amount": round(amt, 2),
                     "Category": t.get("category", ""), "Payee": t.get("merchant", t.get("vendor", ""))[:200],
                     "From File": f'{t["file"]} line {t["line"]}'})
    fs = [{"Finding Key": f'{r["to"]}|{f["id"]}', "Report Date": r["to"], "Title": f["title"][:200],
           "Per Month": f["per_month"], "One Time": f["one_time"], "Why": f["why"], "Fix": f["fix"], "First Step": f["first_step"],
           "Check First": not f["sure"], "Evidence": "\n".join(f["evidence"])} for f in r["findings"]]
    return {"Money Transactions": rows, "Money Findings": fs}


def main(argv=None):
    ap = argparse.ArgumentParser(description="Where did the money go? Reads bank / sales / purchase CSVs.")
    ap.add_argument("files", nargs="+", help="CSV files; prefix with bank: sales: or purchases: to force the kind")
    ap.add_argument("--out", default="money-report")
    ap.add_argument("--rules", help="extra rules JSON (same shape as money/rules.json)")
    ap.add_argument("--name", default="", help="business name for the report")
    a = ap.parse_args(argv)
    rules = load_rules(a.rules)
    txns, files = [], []
    try:
        for spec in a.files:
            kind, name, rows, skipped, header = load_file(spec)
            txns += rows
            files.append((kind, name, len(rows), skipped))
            print(f"read {name}: {kind}, {len(rows)} rows" + (f" ({skipped} skipped: no date or amount)" if skipped else ""))
        r = analyze(txns, rules, a.name)
    except Problem as e:
        print(f"money: {e}", file=sys.stderr)
        return 2
    os.makedirs(a.out, exist_ok=True)
    w = lambda n, s: open(os.path.join(a.out, n), "w").write(s)
    w("report.html", report_html(r, files))
    w("report.md", report_md(r, files))
    w("summary.txt", report_txt(r))
    w("findings.json", json.dumps(r, indent=2, default=str))
    w("load.json", json.dumps(load_json(r, txns), indent=1))
    print(report_txt(r), end="")
    print(f"report: {os.path.join(a.out, 'report.html')}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
