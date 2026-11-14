#!/usr/bin/env python3
"""
ALEXUS CORE: Margin Gate Calibration Suite
Generates 130 labeled test cases (Single-Domain, Multi-Domain Hybrids, Out-of-Domain)
and sweeps margin thresholds (4% to 20%) to find the optimal Pareto frontier.
"""

import os
import sys
import glob
import json
import time
import math
import urllib.request

OLLAMA_HOST = os.environ.get("OLLAMA_HOST", "http://alexus:11434")
VAULT_DIR = os.path.expanduser("~/Developer/alexus-core/cartridges")

def get_embedding(text):
    url = f"{OLLAMA_HOST}/api/embeddings"
    data = json.dumps({"model": "nomic-embed-text", "prompt": text}).encode("utf-8")
    req = urllib.request.Request(url, data=data, headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=10) as resp:
        res = json.loads(resp.read().decode("utf-8"))
        return res["embedding"]

def cosine_similarity(v1, v2):
    dot = sum(a * b for a, b in zip(v1, v2))
    norm1 = math.sqrt(sum(a * a for a in v1))
    norm2 = math.sqrt(sum(b * b for b in v2))
    return dot / (norm1 * norm2) if norm1 and norm2 else 0.0

def load_cartridges():
    experts = []
    for f in sorted(glob.glob(os.path.join(VAULT_DIR, "*.json"))):
        with open(f, "r") as fp:
            data = json.load(fp)
            experts.append(data)
    for exp in experts:
        stds = " ".join(exp.get("standards", []))
        blob = f"{exp['domain']} {stds} {exp['description']}"
        exp["embedding"] = get_embedding(blob)
    return experts

# 130 Diverse labeled test cases
def generate_labeled_dataset():
    data = []
    
    # 1. CAN-bus single domain (25 cases)
    can_templates = [
        "Debug ISO 11898-2 dominant bit timing error at {baud}kbps",
        "Decode OBD2 PID {pid} for engine RPM telemetry on Honda S2000",
        "Throttle position calculation from raw CAN 2.0B broadcast frame",
        "Lexus IS F-Sport differential voltage mismatch on high speed CAN transceiver",
        "CAN bus arbitration collision during high frequency packet transmission"
    ]
    for b in [250, 500, 1000]:
        for p in ["0x010C", "0x0111", "0x0105", "0x010D"]:
            for t in can_templates:
                data.append({"query": t.format(baud=b, pid=p), "expected": ["expert-can-bus"], "type": "single"})
    data = data[:25]

    # 2. Async Sockets single domain (25 cases)
    async_templates = [
        "aiohttp ClientSession connection pool exhaustion with {err}",
        "Configure TCPConnector limit and keepalive timeout for rapid API polling",
        "Prevent TIME_WAIT socket leaks using asyncio.Semaphore in Python backend",
        "Handling socket hang and Operation timed out retries with exponential backoff",
        "Streaming response handling without leaking open file descriptors in aiohttp"
    ]
    for e in ["socket hang", "Operation timed out", "connection reset by peer", "ServerDisconnectedError", "ClientConnectorError"]:
        for t in async_templates:
            data.append({"query": t.format(err=e), "expected": ["expert-async-sockets"], "type": "single"})
    data = data[:50]

    # 3. Fast OCR single domain (25 cases)
    ocr_templates = [
        "Run ONNX Runtime quantized INT8 model on Linux CPU in under {ms}ms",
        "Extract alphanumeric verification code from low-resolution captcha using CRNN",
        "Preprocess grayscale image into 32-pixel height tensor for local CPU OCR",
        "Replace slow cloud 2captcha API with zero-latency local inference session",
        "Lightweight OCR memory footprint optimization under 100MB RAM"
    ]
    for ms in [15, 20, 30, 45, 50]:
        for t in ocr_templates:
            data.append({"query": t.format(ms=ms), "expected": ["expert-fast-ocr"], "type": "single"})
    data = data[:75]

    # 4. Xero Finance single domain (25 cases)
    finance_templates = [
        "Reconcile monthly profit and loss ledger against bank statement totals",
        "Calculate gross margin variance across quarterly accounting periods",
        "Deterministic balance sheet reconciliation with zero hallucination flags",
        "Aggregate Xero invoice line items and audit unlinked credit notes",
        "Detect discrepancies between general ledger debit and credit entries"
    ]
    for t in finance_templates:
        for i in range(5):
            data.append({"query": f"{t} (Dataset sample {i+1})", "expected": ["expert-xero-reporting"], "type": "single"})
    data = data[:100]

    # 5. Multi-Domain Hybrids (20 cases)
    hybrids = [
        ("Python aiohttp service that polls Xero invoices every 2 minutes without socket leaks", ["expert-async-sockets", "expert-xero-reporting"]),
        ("Background async worker downloading receipt images and extracting numbers with sub-50ms local CPU ONNX OCR", ["expert-async-sockets", "expert-fast-ocr"]),
        ("Automotive CAN-bus logger streaming OBD2 telemetry over asynchronous non-blocking TCP socket pool", ["expert-can-bus", "expert-async-sockets"]),
        ("Reconciling Xero invoices parsed from scanned paper receipts using local OCR CRNN engine", ["expert-xero-reporting", "expert-fast-ocr"]),
        ("Async client pulling financial ledger reports from Xero API with connection backpressure and retry timeout", ["expert-async-sockets", "expert-xero-reporting"]),
        ("Capture trackside camera frames, extract car numbers with local OCR, and log to telemetry stream", ["expert-fast-ocr", "expert-can-bus"]),
        ("High throughput async scraper extracting alphanumeric invoice badge codes on Linux VPS", ["expert-async-sockets", "expert-fast-ocr"]),
        ("Exporting OBD2 PID diagnostic stream and verifying monthly workshop repair billing totals", ["expert-can-bus", "expert-xero-reporting"])
    ]
    for q, exp in hybrids:
        data.append({"query": q, "expected": exp, "type": "hybrid"})
        data.append({"query": f"Enterprise implementation: {q}", "expected": exp, "type": "hybrid"})

    # 6. Out-of-Domain Distractors (10 cases)
    distractors = [
        "How do I bake sourdough bread with a crispy crust and large air pockets?",
        "Best practices for planting heirloom tomato seedlings in clay soil",
        "How to play the intro solo of Stairway to Heaven on an acoustic guitar",
        "What is the capital city of Australia and its historical founding date?",
        "Quantum mechanics explanation of wave-particle duality and double slit experiment",
        "Troubleshooting a jammed paper tray on an HP LaserJet enterprise printer",
        "Recipe for homemade Italian marinara pasta sauce with fresh basil",
        "How do airplanes generate aerodynamic lift over supercritical wings?",
        "Origin and historical timeline of the Byzantine Empire after the fall of Rome",
        "How to replace brake pads and bleed hydraulic fluid on a mountain bike"
    ]
    for d in distractors:
        data.append({"query": d, "expected": [], "type": "out_of_domain"})

    return data

def evaluate_margin_sweep():
    print("=" * 70)
    print("🎯 ALEXUS MARGIN GATE CALIBRATION (126 LABELED SAMPLES)")
    print("=" * 70)

    experts = load_cartridges()
    dataset = generate_labeled_dataset()
    print(f"Loaded {len(experts)} cartridges. Evaluating {len(dataset)} labeled queries...\n")

    # Pre-embed all queries
    t0 = time.time()
    for item in dataset:
        item["emb"] = get_embedding(item["query"])
    print(f"Embedding completed in {(time.time() - t0):.1f}s.\n")

    # Test margin thresholds from 4% to 20%
    thresholds = [0.04, 0.06, 0.08, 0.10, 0.12, 0.14, 0.16, 0.18, 0.20]
    
    print(f"{'Margin':<8} | {'Single-Acc':<12} | {'Hybrid-Recall':<14} | {'False-Arms':<12} | {'F1-Score':<10}")
    print("-" * 65)

    best_f1 = 0.0
    best_margin = 0.08

    for margin in thresholds:
        single_correct = 0
        single_total = 0
        hybrid_hits = 0
        hybrid_total = 0
        false_arms = 0
        
        for item in dataset:
            scored = []
            for exp in experts:
                sim = cosine_similarity(item["emb"], exp["embedding"])
                scored.append((sim, exp["id"]))
            scored.sort(key=lambda x: x[0], reverse=True)

            top_sim, top_id = scored[0]
            
            # Selection logic
            selected = []
            if top_sim >= 0.52:
                selected.append(top_id)
                for s, cid in scored[1:]:
                    if s >= 0.52 and (top_sim - s) <= margin:
                        selected.append(cid)
            
            # Metric tracking
            if item["type"] == "single":
                single_total += 1
                if selected == item["expected"]:
                    single_correct += 1
                elif len(selected) > 1 and item["expected"][0] in selected:
                    false_arms += 1 # Over-arming secondary
            elif item["type"] == "hybrid":
                for exp_id in item["expected"]:
                    hybrid_total += 1
                    if exp_id in selected:
                        hybrid_hits += 1
                # Any arm outside expected is false arm
                false_arms += sum(1 for cid in selected if cid not in item["expected"])
            elif item["type"] == "out_of_domain":
                # Any arm on out-of-domain is false arm
                false_arms += len(selected)

        single_acc = (single_correct / single_total) * 100 if single_total else 0
        hybrid_rec = (hybrid_hits / hybrid_total) * 100 if hybrid_total else 0
        
        # Calculate precision & recall for F1
        total_predictions = (single_total + hybrid_total)
        precision = max(0.01, 1.0 - (false_arms / (total_predictions + false_arms)))
        recall = (hybrid_rec / 100) * 0.5 + (single_acc / 100) * 0.5
        f1 = 2 * (precision * recall) / (precision + recall)

        print(f"{margin*100:>5.1f}%  | {single_acc:>10.1f}% | {hybrid_rec:>12.1f}% | {false_arms:>10} | {f1:>8.3f}")

        if f1 > best_f1:
            best_f1 = f1
            best_margin = margin

    print("-" * 65)
    print(f"🏆 Mathematically Calibrated Margin: {best_margin*100:.1f}% (F1-Score: {best_f1:.3f})")
    print("=" * 70)

if __name__ == "__main__":
    evaluate_margin_sweep()
