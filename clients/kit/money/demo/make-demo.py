#!/usr/bin/env python3
"""Writes a FAKE small business's exports (bank, Square-style sales, supplier bills) with known leaks
planted in them, so money.py can be checked against answers we already know. All names are made up.

    python3 make-demo.py OUT_DIR

Planted leaks (what money.py should find):
  1. a cash advance pulling $89 every business day ("CFG MERCHANT SOLUTIONS")
  2. overdraft fees ($35 x 4) and a $15 monthly account fee
  3. card fees at 3.6% of sales
  4. two days of card sales that never reached the bank (2026-08-14 and 2026-09-22)
  5. QuickBooks went from $35 to $45 a month
  6. two Adobe subscriptions
  7. one supplier charge that went through twice (ULINE $342.18, 2026-09-03 and 09-04)
  8. iPhone 13 screens sold for less than they cost; batteries with thin profit
  9. far more batteries bought than sold
 10. 3 unpaid repair invoices
"""
import csv
import os
import random
import sys
from datetime import date, timedelta

out = sys.argv[1] if len(sys.argv) > 1 else "."
os.makedirs(out, exist_ok=True)
R = random.Random(7)
START, END = date(2026, 7, 1), date(2026, 10, 31)
days = [START + timedelta(n) for n in range((END - START).days + 1)]
biz = [d for d in days if d.weekday() < 6]          # open Mon-Sat

ITEMS = [  # sku, name, cost, price, daily demand
    ("SCR-IP13", "iPhone 13 screen repair", 89.00, 79.00, 2.2),
    ("SCR-IP14", "iPhone 14 screen repair", 95.00, 179.00, 2.0),
    ("BAT-IP12", "iPhone 12 battery", 31.00, 34.99, 3.0),
    ("CHG-USBC", "USB-C charger", 6.50, 24.99, 5.0),
    ("CASE-CLR", "Clear case", 2.10, 19.99, 6.0),
    ("SVC-DIAG", "Diagnostic", 0.00, 29.00, 2.0),
]
MISSING = {date(2026, 8, 14), date(2026, 9, 22)}

sales, bank, buys = [], [], []
rid = 1000
for d in biz:
    day_net = 0.0
    for sku, name, cost, price, lam in ITEMS:
        n = sum(1 for _ in range(12) if R.random() < lam / 12)
        for _ in range(n):
            rid += 1
            fee = round(price * 0.036, 2)
            sales.append([d.isoformat(), f"R-{rid}", name, sku, 1, f"{price:.2f}", f"{fee:.2f}", f"{price - fee:.2f}", "Paid"])
            day_net += price - fee
    if day_net and d not in MISSING:
        dep = d + timedelta(days=1 if d.weekday() < 4 else 3 if d.weekday() == 4 else 2)
        bank.append([dep, f"SQUARE INC DEPOSIT SQ{d:%m%d}", round(day_net, 2)])
# 3 unpaid invoices for business repair jobs
for d, cust, amt in [(date(2026, 8, 20), "Harbor Dental (FAKE)", 640.00), (date(2026, 9, 18), "Lakeside Realty (FAKE)", 415.00),
                     (date(2026, 10, 25), "Pine St Cafe (FAKE)", 189.00)]:
    rid += 1
    sales.append([d.isoformat(), f"INV-{rid}", "Business device repair", "SVC-B2B", 1, f"{amt:.2f}", "", "", "Unpaid"])

# supplier bills: weekly parts order, plus too many batteries
bill = 5000
for d in days:
    if d.weekday() == 1:
        bill += 1
        lines = [("SCR-IP13", 13, 89.00), ("SCR-IP14", 12, 95.00), ("BAT-IP12", 30, 31.00), ("CHG-USBC", 30, 6.50), ("CASE-CLR", 36, 2.10)]
        tot = 0
        for sku, q, c in lines:
            name = next(i[1] for i in ITEMS if i[0] == sku)
            buys.append([d.isoformat(), "PartsHub Wholesale (FAKE)", f"B-{bill}", sku, name, q, f"{c:.2f}", f"{q * c:.2f}"])
            tot += q * c
        bank.append([d + timedelta(days=2), "PARTSHUB WHOLESALE ACH", -round(tot, 2)])

for d in days:
    if d.day == 1:
        bank.append([d, "ACH PMT HARBOR REALTY RENT", -3200.00])
        bank.append([d, "MONTHLY MAINTENANCE FEE", -15.00])
    if d.day == 3:
        bank.append([d, "ADOBE *CREATIVE CLD", -59.99])
        bank.append([d, "GOOGLE *GSUITE", -14.00])
    if d.day == 5:
        bank.append([d, "INTUIT *QUICKBOOKS", -35.00 if d.month < 9 else -45.00])
        bank.append([d, "STATE FARM INSURANCE", -212.40])
    if d.day == 11:
        bank.append([d, "ADOBE *ACROPRO SUBS", -19.99])
    if d.day == 12:
        bank.append([d, "COMCAST BUSINESS", -129.95])
    if d.day == 18:
        bank.append([d, "CITY ELECTRIC UTILITY", -round(R.uniform(240, 330), 2)])
    if d.weekday() == 4 and (d - date(2026, 7, 3)).days % 14 == 0:
        bank.append([d, "GUSTO PAYROLL", -2860.00])
    if d.weekday() < 5:
        bank.append([d, "CFG MERCHANT SOLUTIONS ACH", -89.00])
    if d.day == 28:
        bank.append([d, "OWNER DRAW TRANSFER", -1500.00])
for d in [date(2026, 7, 29), date(2026, 8, 31), date(2026, 9, 29), date(2026, 10, 30)]:
    bank.append([d, "OVERDRAFT ITEM FEE", -35.00])
bank.append([date(2026, 9, 3), "ULINE *SHIP SUPPLIES", -342.18])
bank.append([date(2026, 9, 4), "ULINE *SHIP SUPPLIES", -342.18])
bank.append([date(2026, 8, 9), "USPS PO 0123", -48.20])
bank.append([date(2026, 10, 2), "USPS PO 0123", -61.75])

bank.sort(key=lambda r: (r[0], r[2] < 0))
bal = 4200.00
with open(os.path.join(out, "bank-checking.csv"), "w", newline="") as f:
    w = csv.writer(f)
    w.writerow(["Bayside Phone & Repair (FAKE) - Business Checking ...4417"])
    w.writerow([])
    w.writerow(["Date", "Description", "Withdrawals", "Deposits", "Balance"])
    for d, desc, amt in bank:
        bal += amt
        w.writerow([d.strftime("%m/%d/%Y"), desc, f"{-amt:,.2f}" if amt < 0 else "", f"{amt:,.2f}" if amt > 0 else "", f"{bal:,.2f}"])
with open(os.path.join(out, "square-sales.csv"), "w", newline="") as f:
    w = csv.writer(f)
    w.writerow(["Date", "Receipt Number", "Item", "SKU", "Qty", "Gross Sales", "Fees", "Net Total", "Status"])
    w.writerows(sorted(sales))
with open(os.path.join(out, "supplier-bills.csv"), "w", newline="") as f:
    w = csv.writer(f)
    w.writerow(["Bill Date", "Vendor", "Bill Number", "SKU", "Item", "Qty", "Unit Cost", "Line Total"])
    w.writerows(buys)
print(f"wrote FAKE demo files to {out}: {len(bank)} bank rows, {len(sales)} sales, {len(buys)} bill lines")
