"""Image -> local Qwen vision model (Ollama) -> validated, structured data."""
import base64
import io
import json
import os
import re
import time
from datetime import date
from decimal import Decimal, InvalidOperation

import httpx
from PIL import Image, ImageOps

try:  # iPhone HEIC photos, if the browser didn't already convert them to JPEG
    from pillow_heif import register_heif_opener
    register_heif_opener()
except Exception:  # pragma: no cover
    pass

OLLAMA_URL = os.environ.get("OLLAMA_URL", "http://127.0.0.1:11434")
MODEL = os.environ.get("PIPE_MODEL", "qwen2.5vl:3b")
MAX_SIDE = int(os.environ.get("PIPE_MAX_SIDE", "1280"))
CONFIDENCE_MIN = float(os.environ.get("PIPE_CONFIDENCE_MIN", "0.75"))
TIMEOUT_S = float(os.environ.get("PIPE_MODEL_TIMEOUT", "900"))

NUM = {"type": ["number", "null"]}
STR = {"type": ["string", "null"]}
SCHEMA = {
    "type": "object",
    "properties": {
        "raw_text": {"type": "string"},
        "document_type": STR,
        "vendor": STR,
        "date": STR,
        "currency": STR,
        "language": STR,
        "line_items": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {"description": STR, "qty": NUM, "unit_price": NUM, "amount": NUM},
                "required": ["description", "qty", "unit_price", "amount"],
            },
        },
        "subtotal": NUM,
        "tax": NUM,
        "total": NUM,
        "model_confidence": {"type": "number"},
        "notes": STR,
        "transaction_time": STR,
        "card_last4": STR,
        "transaction_id": STR,
        "invoice_number": STR,
        "bill_to": STR,
        "due_date": STR,
        "payment_terms": STR,
        "discount": NUM,
    },
    "required": ["raw_text", "document_type", "vendor", "date", "currency", "language",
                 "line_items", "subtotal", "tax", "total", "model_confidence", "notes",
                 "transaction_time", "card_last4", "transaction_id",
                 "invoice_number", "bill_to", "due_date", "payment_terms", "discount"],
}

PROMPT = """You are a careful OCR and data-extraction engine. Read the document in the image.
Reply with ONLY one JSON object with these keys:
raw_text, document_type, vendor, date, currency, language, line_items, subtotal, tax, total, model_confidence, notes,
transaction_time, card_last4, transaction_id, invoice_number, bill_to, due_date, payment_terms, discount.
Rules:
- raw_text: transcribe ALL visible text, line by line, in its original language and script. Never repeat a line and
  never pad with runs of spaces.
- document_type: one of receipt, invoice, bill, bank_statement, letter, id_card, form, other. An invoice asks to be
  paid and usually has an invoice number; a receipt shows a sale already paid at the counter.
- vendor: the business or sender name as printed. On an invoice this is who issued it and gets paid, never the
  customer it is billed to.
- date: on an invoice, the invoice date (labelled Invoice Date, Inv. Date, Billing Date or Date) as YYYY-MM-DD, never
  the due date, ship date, publication or service date, a RECEIVED stamp or a date paid. Otherwise, the date of the
  purchase itself, as YYYY-MM-DD. On receipts it is usually printed next to the time of sale,
  the register/terminal/transaction/auth number, the cashier, or the totals and card-payment block (often at the top
  or near the bottom with the time). Receipts also print OTHER dates: coupon or offer expiry ("valid through",
  "expires", "offer ends", "use by"), survey or sweepstakes deadlines ("enter by", "complete within", "visit ... by"),
  and return-by dates ("returns before", "return by"). NEVER use those. A date without a year (like 9/15) is
  almost always a promo date. If you can't tell which date is the purchase date, give your best guess, explain in
  notes, and lower model_confidence below 0.7.
- transaction_time: the time of the purchase as printed (e.g. 14:32), or null.
- card_last4: the last 4 digits of the card used, or null.
- transaction_id: the transaction / receipt / order / TC / reference number, or null.
- invoice_number: the invoice number as printed, or null.
- bill_to: the customer the invoice is addressed to, or null.
- due_date: the payment due date as YYYY-MM-DD, or null.
- payment_terms: the terms as printed (e.g. Net 30, 2% 10), or null.
- currency: ISO 4217 code (USD, EUR, GBP, SAR, AED, ...). If no symbol or code is printed, use the currency of the
  country in the address and say so in notes.
- language: ISO 639-1 code of the main language (en, ar, es, ...).
- line_items: one entry per purchased item: description, qty, unit_price, amount. On invoices, amount is the money
  charged for that row and qty x unit_price must equal it. Sizes and measurements in a row (like 4 X 15.75 = 63.00
  column inches, or dimensions) are not money: use the total measure as qty and the printed rate as unit_price. Each
  extra charge (freight, setup, color, fees) is its own line item.
- subtotal: the sum of the charges before discount and tax. discount: the printed discount, agency commission or
  allowance as a positive number, or null. total: on an invoice, the printed amount due (Net, Balance Due, Amount
  Due), after discount and tax.
- Take money only from printed text. Ignore handwriting, rubber stamps, check numbers and cash discounts someone
  wrote or stamped on later. Mention them in notes instead.
- Numbers are plain JSON numbers: no currency symbols, no thousands separators (e.g. 1234.5).
- Use null for anything not visible. Never invent values.
- model_confidence: 0.0 to 1.0, how sure you are that the extracted fields are correct.
- notes: anything illegible, ambiguous or uncertain (or null)."""

CURRENCY_ALIASES = {
    "$": "USD", "US$": "USD", "€": "EUR", "£": "GBP", "¥": "JPY",
    "SR": "SAR", "ر.س": "SAR", "ريال": "SAR", "د.إ": "AED", "DHS": "AED", "DH": "AED",
}


def prepare_image(data: bytes) -> tuple[str, dict]:
    """Fix phone rotation, downscale (CPU cost grows with pixels), re-encode as JPEG base64."""
    img = Image.open(io.BytesIO(data))
    img = ImageOps.exif_transpose(img).convert("RGB")
    orig = img.size
    img.thumbnail((MAX_SIDE, MAX_SIDE))
    buf = io.BytesIO()
    img.save(buf, "JPEG", quality=90)
    return base64.b64encode(buf.getvalue()).decode(), {"original_size": orig, "sent_size": img.size}


def call_model(b64: str, attempt: int = 1) -> tuple[str, int, dict]:
    """attempt 1: deterministic. attempt 2 (after bad JSON, usually a repetition loop on a
    blurry photo): a little randomness + repeat penalty and a reminder to keep raw_text short."""
    prompt = PROMPT
    opts = {"temperature": 0, "num_ctx": 8192, "num_predict": 2048}
    if attempt > 1:
        prompt += "\n- Keep raw_text under 1500 characters. Never repeat the same line. If text is unreadable, say so in notes."
        opts.update({"temperature": 0.3, "repeat_penalty": 1.2, "repeat_last_n": 256})
    msgs = [{"role": "user", "content": prompt, "images": [b64]}]
    body = {"model": MODEL, "messages": msgs, "stream": False, "format": SCHEMA,
            "keep_alive": "10m", "options": opts}
    t0 = time.monotonic()
    r = httpx.post(f"{OLLAMA_URL}/api/chat", json=body, timeout=TIMEOUT_S)
    ms = int((time.monotonic() - t0) * 1000)
    r.raise_for_status()
    j = r.json()
    stats = {k: j.get(k) for k in ("prompt_eval_count", "eval_count", "load_duration",
                                   "prompt_eval_duration", "eval_duration")}
    return j["message"]["content"], ms, stats


def parse_json(text: str):
    text = text.strip()
    m = re.search(r"\{.*\}", text, re.S)
    obj = json.loads(m.group(0) if m else text)
    if not isinstance(obj, dict):
        raise ValueError("model reply is not a JSON object")
    return obj


def dec(v):
    if v is None or v == "":
        return None
    if isinstance(v, (int, float)):
        return Decimal(str(v))
    s = re.sub(r"[^\d.,\-]", "", str(v))
    if s.count(",") and s.count("."):
        s = s.replace(",", "")
    elif s.count(",") == 1 and len(s.split(",")[1]) == 2:
        s = s.replace(",", ".")
    else:
        s = s.replace(",", "")
    try:
        return Decimal(s)
    except InvalidOperation:
        return None


def close(a: Decimal, b: Decimal) -> bool:
    return abs(a - b) <= max(Decimal("0.02"), abs(b) * Decimal("0.005"))


def validate(d: dict) -> tuple[dict, list[str]]:
    """Normalise fields and run sanity checks. Any problem -> needs_review."""
    problems: list[str] = []
    out = {
        "document_type": (d.get("document_type") or None),
        "vendor": (d.get("vendor") or None),
        "currency": None, "language": (d.get("language") or None),
        "raw_text": d.get("raw_text") or "", "notes": d.get("notes") or None,
        "subtotal": dec(d.get("subtotal")), "tax": dec(d.get("tax")), "total": dec(d.get("total")),
        "discount": dec(d.get("discount")),
        "doc_date": None, "line_items": [], "model_confidence": None,
    }
    cur = (d.get("currency") or "").strip()
    out["currency"] = CURRENCY_ALIASES.get(cur, CURRENCY_ALIASES.get(cur.upper(), cur.upper() or None))
    if out["currency"] and not re.fullmatch(r"[A-Z]{3}", out["currency"]):
        problems.append(f"currency '{cur}' is not a 3-letter code")

    try:
        conf = float(d.get("model_confidence"))
        out["model_confidence"] = max(0.0, min(1.0, conf))
    except (TypeError, ValueError):
        problems.append("model gave no confidence")
    if out["model_confidence"] is not None and out["model_confidence"] < CONFIDENCE_MIN:
        problems.append(f"model confidence {out['model_confidence']:.2f} below {CONFIDENCE_MIN}")

    ds = d.get("date")
    if ds:
        try:
            out["doc_date"] = date.fromisoformat(str(ds).strip()[:10])
        except ValueError:
            problems.append(f"date '{ds}' is not YYYY-MM-DD")
    else:
        problems.append("no date found")

    if not out["vendor"]:
        problems.append("no vendor/sender found")
    if not out["raw_text"].strip():
        problems.append("no text transcribed")

    money_doc = (out["document_type"] or "").lower() in ("receipt", "invoice", "bill", "")
    if (out["document_type"] or "").lower() == "invoice" and not d.get("invoice_number"):
        problems.append("no invoice number found")
    due = d.get("due_date")
    if due:
        try:
            date.fromisoformat(str(due).strip()[:10])
        except ValueError:
            problems.append(f"due date '{due}' is not YYYY-MM-DD")
    # Discounts come off the subtotal; a model may hand one back as a negative number.
    disc = abs(out["discount"]) if out["discount"] is not None else Decimal("0")
    if money_doc and out["total"] is None:
        problems.append("no total found")

    items = d.get("line_items") or []
    for i, it in enumerate(items, 1):
        if not isinstance(it, dict):
            continue
        q, up, amt = dec(it.get("qty")), dec(it.get("unit_price")), dec(it.get("amount"))
        if amt is None and q is not None and up is not None:
            amt = (q * up).quantize(Decimal("0.01"))
        if q is not None and up is not None and amt is not None and not close(q * up, amt):
            problems.append(f"item {i}: {q} x {up} != {amt}")
        out["line_items"].append({"description": it.get("description"), "qty": q,
                                  "unit_price": up, "amount": amt})

    amounts = [it["amount"] for it in out["line_items"] if it["amount"] is not None]
    if amounts and out["total"] is not None:
        s = sum(amounts)
        sub, tax, tot = out["subtotal"], out["tax"], out["total"]
        if close(s, tot):
            pass
        elif sub is not None and close(s, sub):
            if tax is not None and not close(sub - disc + tax, tot):
                problems.append(f"subtotal {sub} - discount {disc} + tax {tax} != total {tot}" if disc
                                else f"subtotal {sub} + tax {tax} != total {tot}")
            elif tax is None and not close(sub - disc, tot):
                problems.append(f"subtotal {sub} - discount {disc} != total {tot}" if disc
                                else f"subtotal {sub} != total {tot} and no tax given")
        elif close(s - disc + (tax or 0), tot):
            pass
        else:
            problems.append(f"line items sum to {s}, total says {tot}")
    if out["line_items"] and not amounts:
        problems.append("line items have no amounts")
    if out["total"] is not None and out["total"] <= 0:
        problems.append(f"total is {out['total']}")
    if out["subtotal"] is not None and out["tax"] is None and out["total"] is not None \
            and not close(out["subtotal"] - disc, out["total"]):
        msg = (f"subtotal {out['subtotal']} - discount {disc} != total {out['total']}" if disc
               else f"subtotal {out['subtotal']} != total {out['total']} and no tax given")
        if msg not in problems:
            problems.append(msg)
    if out["subtotal"] is not None and out["tax"] is not None and out["total"] is not None \
            and not close(out["subtotal"] - disc + out["tax"], out["total"]):
        msg = (f"subtotal {out['subtotal']} - discount {disc} + tax {out['tax']} != total {out['total']}" if disc
               else f"subtotal {out['subtotal']} + tax {out['tax']} != total {out['total']}")
        if msg not in problems:
            problems.append(msg)
    return out, list(dict.fromkeys(problems))


def jsonable(o):
    if isinstance(o, Decimal):
        return float(o)
    if isinstance(o, date):
        return o.isoformat()
    if isinstance(o, dict):
        return {k: jsonable(v) for k, v in o.items()}
    if isinstance(o, list):
        return [jsonable(v) for v in o]
    return o
