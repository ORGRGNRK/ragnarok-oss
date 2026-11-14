#!/usr/bin/env python3
"""Convert a fresh Atlas Mobile Price Sheet export into PhoneGrader's atlas-ladder.json.

Input: either an .xlsx export (needs openpyxl) or the text dump produced by the
Drive connector's read_file (tabs as '## <Tab>' sections of CSV, or the raw JSON
result with a "content" field). Only the 'iPhone' tab is laddered.

  python3 scripts/refresh_atlas.py SHEET.(xlsx|txt|json) [--date YYYY-MM-DD]
        [--out Resources/atlas-ladder.json] [--install]

--install also copies the result to
~/Library/Application Support/PhoneGrader/atlas-ladder.imported.json
(the file the app's 'Import price list…' writes), so the running app picks it
up on next launch / reload without a rebuild.
"""
import argparse, csv, datetime as dt, io, json, os, re, shutil, sys

APP_COLS = ["SWAP", "A", "B", "C", "D", "DOA"]
HDR = {"swap / hso": "SWAP", "grade a": "A", "grade b": "B", "grade b/c": "BC",
       "grade c": "C", "grade d": "D", "doa": "DOA",
       "new / sealed": "NEW_SEALED", "new / open": "NEW_OPEN"}
LOCKS = [("carrier locked", "carrier locked"), ("unlocked", "unlocked"),
         ("at&t clean", "att clean"), ("att clean", "att clean")]


def load_tabs(path):
    if path.lower().endswith(".xlsx"):
        import openpyxl
        wb = openpyxl.load_workbook(path, data_only=True, read_only=True)
        return {ws.title: [["" if c is None else str(c) for c in r] for r in ws.iter_rows(values_only=True)]
                for ws in wb.worksheets}
    text = open(path, encoding="utf-8").read()
    if text.lstrip().startswith("{"):
        text = json.loads(text)["content"]
    tabs = {}
    for sec in re.split(r"(?m)^## ", text)[1:]:
        name, _, body = sec.partition("\n")
        tabs[name.strip()] = list(csv.reader(io.StringIO(body)))
    return tabs


def norm_model(raw):
    m = raw.strip().lower()
    m = re.sub(r"\s+", " ", m)
    m = re.sub(r"^i(\d)", r"\1", m)          # i16 pro -> 16 pro
    m = re.sub(r"^(\d+)\+", r"\1 plus", m)    # 8+ -> 8 plus
    return "iphone " + m


def money(v):
    s = str(v).strip().replace("$", "").replace(",", "")
    try:
        return float(s)
    except ValueError:
        return None


def storages(s):
    m = re.match(r"\s*(\d+)\s*(GB|TB)", s, re.I)
    if not m:
        return None, []
    n = int(m.group(1))
    if m.group(2).upper() == "TB":
        return f"{n}TB", [n * 1000, n * 1024]
    return f"{n}GB", [n]


def parse_iphone(rows):
    out, skipped, deductions, cols = {}, [], {}, None
    current = None
    for i, r in enumerate(rows, 1):
        cells = [c.strip() if isinstance(c, str) else c for c in r]
        low = [str(c).lower() for c in cells]
        if "storage" in low and "grade a" in low:
            cols = {}
            for j, c in enumerate(low):
                if c in HDR and HDR[c] not in cols:
                    cols[HDR[c]] = j
            st_col = low.index("storage"); model_col = low.index("model") if "model" in low else st_col - 1
            continue
        if cols is None or len(cells) <= st_col:
            continue
        label, sizes = storages(str(cells[st_col]))
        if not sizes:
            continue
        if str(cells[model_col]).strip():
            first, *notes = str(cells[model_col]).strip().split("\n")
            lock = next((v for k, v in LOCKS if first.lower().rstrip().endswith(k)), None)
            if lock is None:
                current = None; skipped.append(f"line {i}: no lock state in '{first}'"); continue
            base = re.sub(r"(?i)\s*(carrier locked|unlocked|at&t clean|att clean)\s*$", "", first).strip()
            current = (norm_model(base), lock, first.strip())
            deductions[first.strip()] = [n.strip() for n in notes if n.strip()]
        if current is None:
            continue
        model, lock, disp = current
        vals = {}
        for k, j in cols.items():
            vals[k] = money(cells[j]) if j < len(cells) else None
        if vals.get("SWAP") is None and "SWAP" not in cols:
            vals["SWAP"] = vals.get("A")          # table without a SWAP column
        ladder = [vals.get(c) for c in APP_COLS]
        if any(v is None for v in ladder):
            raw = {k: (cells[j] if j < len(cells) else "") for k, j in cols.items()}
            skipped.append(f"{disp} {label}: missing/PENDING grade(s) {[c for c, v in zip(APP_COLS, ladder) if v is None]} raw={raw}")
            continue
        for s in sizes:
            key = f"{model}|{s}|{lock}"
            if key in out:
                continue
            row = {"label": f"{disp.replace(disp.split()[0], 'iPhone ' + norm_model(disp.split()[0])[7:], 1) if disp.lower().startswith('i') and disp[1].isdigit() else 'iPhone ' + disp} {label}".replace("  ", " "),
                   "ladder": [int(v) if v == int(v) else v for v in ladder]}
            for extra in ("BC", "NEW_SEALED", "NEW_OPEN"):
                if vals.get(extra) is not None:
                    row[extra.lower()] = vals[extra]
            out[key] = row
    return out, skipped, deductions


def _sheet_id():
    """ATLAS_SHEET_ID from the environment, else ~/.ragnarok/local.conf (KEY=value, read only)."""
    if os.environ.get("ATLAS_SHEET_ID"):
        return os.environ["ATLAS_SHEET_ID"]
    try:
        for line in open(os.path.expanduser("~/.ragnarok/local.conf")):
            k, _, v = line.strip().partition("=")
            if k == "ATLAS_SHEET_ID" and v:
                return v
    except OSError:
        pass
    return ""


def next_friday(d):
    return d + dt.timedelta(days=(4 - d.weekday()) % 7)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("sheet")
    here = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    ap.add_argument("--out", default=os.path.join(here, "Resources", "atlas-ladder.json"))
    ap.add_argument("--date", default=dt.date.today().isoformat(), help="date the sheet was read (YYYY-MM-DD)")
    ap.add_argument("--sheet-id", default=_sheet_id(), help="Google Sheet id of the price sheet "
                    "(default: ATLAS_SHEET_ID from the environment or ~/.ragnarok/local.conf)")
    ap.add_argument("--install", action="store_true")
    a = ap.parse_args()

    tabs = load_tabs(a.sheet)
    if "iPhone" not in tabs:
        sys.exit(f"no 'iPhone' tab; tabs: {list(tabs)}")
    rows, skipped, deductions = parse_iphone(tabs["iPhone"])
    if len(rows) < 50:
        sys.exit(f"only {len(rows)} rows parsed -- sheet layout changed? refusing to write")

    prev = {}
    if os.path.exists(a.out):
        try: prev = json.load(open(a.out))
        except Exception: prev = {}
    d = dt.date.fromisoformat(a.date)
    fri = next_friday(d)
    models = sorted({k.split("|")[0] for k in rows})
    fams = sorted({re.match(r"iphone \d+", m).group(0) for m in models if re.match(r"iphone \d+", m)},
                  key=lambda s: int(s.split()[1]))
    doc = {
        "_README": "GENERATED by scripts/refresh_atlas.py from the private Atlas Mobile Price Sheet 'iPhone' tab. Do not hand-edit; rerun the script.",
        "_SOURCE_OF_TRUTH": f"Atlas Mobile Price Sheet (private), Google Sheet {a.sheet_id}. This file is a DATED CACHE; the sheet wins.",
        "anchored_date": a.date,
        "delivery_friday": fri.isoformat(),
        "tab_header_verbatim": f"Read {a.date}; sheet prints no delivery date -- treated as valid through Friday {fri.isoformat()}.",
        "reanchor_reminder": prev.get("reanchor_reminder", ""),
        "exit_profile_record": prev.get("exit_profile_record", ""),
        "_columns": "App ladder = SWAP/HSO, A, B, C, D, DOA. Grade B/C and NEW prices kept per row as bc/new_sealed/new_open. Tables without a SWAP column use Grade A as SWAP.",
        "columns": APP_COLS,
        "_SHEET_ANOMALIES": [f"{r['label']}: Grade A {r['ladder'][1]} above SWAP {r['ladder'][0]}" for r in rows.values() if r["ladder"][1] > r["ladder"][0]][:40],
        "rows": rows,
        "deduction_notes_by_model": deductions,
        "deduction_flags": prev.get("deduction_flags", {}),
        "_SKIPPED_ROWS": skipped,
        "quotable_families": fams,
        "not_on_current_ladder": prev.get("not_on_current_ladder", []),
        "preferred_partner": "Atlas Preferred Partner Program: 2% bonus at 2+ packages/month, free labels.",
    }
    os.makedirs(os.path.dirname(a.out), exist_ok=True)
    tmp = a.out + ".tmp"
    json.dump(doc, open(tmp, "w"), indent=1)
    os.replace(tmp, a.out)
    print(f"wrote {a.out}: {len(rows)} keys, {len(models)} models, delivery_friday {fri}, skipped {len(skipped)}")
    for s in skipped: print("  skipped:", s)
    if a.install:
        dst = os.path.expanduser("~/Library/Application Support/PhoneGrader/atlas-ladder.imported.json")
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        shutil.copy(a.out, dst); print("installed", dst)


if __name__ == "__main__":
    main()
