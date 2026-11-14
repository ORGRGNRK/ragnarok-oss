#!/usr/bin/env python3
"""Checks money.py against the FAKE demo business, whose leaks are known because make-demo.py planted them,
plus the small parsers. Run: python3 -I money/test_money.py   (prints ok/FAIL lines, exits 1 on any FAIL)"""
import json
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import money  # noqa: E402

fails = 0


def check(name, cond, detail=""):
    global fails
    print(("ok   " if cond else "FAIL ") + name + ("" if cond else f"  ({detail})"))
    fails += 0 if cond else 1


# parsers
check("money $1,234.50", money.parse_money("$1,234.50") == 1234.5)
check("money (12.00) is negative", money.parse_money("(12.00)") == -12.0)
check("money -$5", money.parse_money("-$5") == -5.0)
check("money blank", money.parse_money("") is None)
check("date 10/31/2026", str(money.parse_date("10/31/2026")) == "2026-10-31")
check("date ISO with time", str(money.parse_date("2026-10-31T14:02:11.000Z")) == "2026-10-31")
check("word edges: nsf not in transfer", not money.has_word("owner draw transfer", "nsf"))
check("word edges: rent in 'harbor realty rent'", money.has_word("ach pmt harbor realty rent", "rent"))
check("word edges: sq * prefix", money.has_word("sq *joes", "sq *"))
rules = money.load_rules()
check("owner draw is owner pay", money.categorize("OWNER DRAW TRANSFER", -1500, rules) == "Owner pay")
check("overdraft is a bank fee", money.categorize("OVERDRAFT ITEM FEE", -35, rules) == "Bank fees")
check("square deposit is sales money in", money.categorize("SQUARE INC DEPOSIT", 500, rules) == "Money in: sales deposits")

with tempfile.TemporaryDirectory() as tmp:
    inp, out = os.path.join(tmp, "in"), os.path.join(tmp, "out")
    subprocess.run([sys.executable, "-I", os.path.join(HERE, "demo", "make-demo.py"), inp], check=True, capture_output=True)
    files = sorted(os.path.join(inp, f) for f in os.listdir(inp))
    p = subprocess.run([sys.executable, "-I", os.path.join(HERE, "money.py"), *files, "--out", out, "--name", "Demo (FAKE)"],
                       capture_output=True, text=True)
    check("money.py runs", p.returncode == 0, p.stderr[-300:])
    r = json.load(open(os.path.join(out, "findings.json")))
    f = {x["id"]: x for x in r["findings"]}
    check("all three files read", r["counts"]["bank"] > 200 and r["counts"]["sales"] > 1000 and r["counts"]["purchases"] > 50, r["counts"])
    check("1 cash advance found", "advance-cfg-merchant-solutions" in f, list(f))
    check("  ~$89 x business days a month", 1700 < f.get("advance-cfg-merchant-solutions", {}).get("per_month", 0) < 2100)
    check("2 overdraft fees found", "bank-fees" in f and "overdraft" in f["bank-fees"]["why"])
    check("3 card fees 3.6%", "card-fees" in f and "3.6%" in f["card-fees"]["title"])
    md = f.get("missing-deposits", {})
    check("4 missing deposits: exactly 08-14 and 09-22", sorted(e[:10] for e in md.get("evidence", [])) == ["2026-08-14", "2026-09-22"], md.get("evidence"))
    check("5 QuickBooks price rise $10", f.get("price-rise-intuit", {}).get("per_month") == 10.0, [k for k in f if k.startswith("price")])
    check("  no false price rise on the electric bill", not any("electric" in k for k in f))
    check("6 two Adobe subscriptions", "overlap-adobe" in f)
    dc = f.get("double-charges", {})
    check("7 ULINE double charge only", dc.get("one_time") == 342.18 and all("ULINE" in e for e in dc.get("evidence", [])), dc.get("evidence"))
    check("8 iPhone 13 screens below cost", "sold-below-cost" in f and "scr-ip13" in f["sold-below-cost"]["why"].lower())
    check("  batteries thin margin", "thin-margin" in f and "bat-ip12" in f["thin-margin"]["why"].lower())
    check("9 batteries piling up", "stock-pileup" in f and "BAT-IP12" in f["stock-pileup"]["why"])
    check("10 unpaid invoices $1,244", f.get("unpaid-invoices", {}).get("one_time") == 1244.0)
    check("losing money flagged", "losing-money" in f)
    check("first step is an easy one", r["first_step"] and f[r["first_step"]["id"]]["effort"] == "easy", r["first_step"])
    for n in ("report.html", "report.md", "summary.txt", "load.json"):
        check(f"wrote {n}", os.path.getsize(os.path.join(out, n)) > 100)
    load = json.load(open(os.path.join(out, "load.json")))
    keys = [x["Row Key"] for x in load["Money Transactions"]]
    check("load.json row keys unique", len(keys) == len(set(keys)))
    check("summary fits a long text (<= 640 chars)", len(open(os.path.join(out, "summary.txt")).read()) <= 640)
    # a file with no date column is refused with a clear message, not a crash
    bad = os.path.join(tmp, "bad.csv")
    open(bad, "w").write("foo,bar\n1,2\n")
    p = subprocess.run([sys.executable, "-I", os.path.join(HERE, "money.py"), bad, "--out", out], capture_output=True, text=True)
    check("no date column: clear refusal", p.returncode == 2 and "date column" in p.stderr, p.stderr)

print("ALL OK" if not fails else f"{fails} FAILED")
sys.exit(1 if fails else 0)
