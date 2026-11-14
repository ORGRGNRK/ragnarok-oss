#!/usr/bin/env python3
import subprocess
import sys
import time

test_queries = [
    ("Automotive Telemetry", "My Honda S2000 OBD2 reader is dropping frames when polling RPM and coolant temperature over CAN-bus at track speeds."),
    ("Accounting Reconciliation", "Reconcile our monthly Xero profit and loss statements against the bank ledger and flag any discrepancies."),
    ("Multi-Domain Hybrid", "Build a Python script that polls Xero invoices every 5 minutes and handles socket timeouts without leaking connections."),
    ("Out-Of-Domain Wildcard", "How do I bake sourdough bread with a crispy crust and large air pockets?")
]

print("=" * 70)
print("🧪 RUNNING META-RAG RETRIEVAL & BOUNDARY STRESS TESTS")
print("=" * 70)

for name, q in test_queries:
    print(f"\n--- [TEST: {name}] ---")
    print(f"Query: \"{q}\"")
    cmd = [os.path.expanduser("~/Developer/meta-expert-vault/meta_engine.py"), q]
    
    # We test the fast routing layer (embed + score)
    import os, json, glob, math, urllib.request
    OLLAMA_HOST = "http://alexus:11434"
    VAULT_DIR = os.path.expanduser("~/Developer/meta-expert-vault/vault")
    
    def get_emb(text):
        url = f"{OLLAMA_HOST}/api/embeddings"
        d = json.dumps({"model": "nomic-embed-text", "prompt": text}).encode()
        r = urllib.request.Request(url, data=d, headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(r, timeout=10) as resp:
            return json.loads(resp.read().decode())["embedding"]

    def cos_sim(v1, v2):
        dot = sum(a * b for a, b in zip(v1, v2))
        return dot / (math.sqrt(sum(a * a for a in v1)) * math.sqrt(sum(b * b for b in v2)))

    experts = []
    for f in glob.glob(f"{VAULT_DIR}/*.json"):
        with open(f) as fp:
            experts.append(json.load(fp))

    for exp in experts:
        exp["emb"] = get_emb(f"{exp['domain']} {exp['description']}")

    t0 = time.time()
    q_emb = get_emb(q)
    scored = [(cos_sim(q_emb, exp["emb"]), exp) for exp in experts]
    scored.sort(key=lambda x: x[0], reverse=True)
    ms = (time.time() - t0) * 1000

    print(f"⏱️ Retrieval Latency: {ms:.1f}ms")
    for sim, exp in scored:
        bar = "█" * int(sim * 25)
        print(f"  [{sim*100:5.1f}%] {bar:<25} {exp['id']}")

    top_sim, top_exp = scored[0]
    if top_sim < 0.40:
        print("  ⚠️ EDGE CASE DETECTED: Out-of-Domain Task! (Confidence below 40% threshold)")
        print("     -> Router should flag [NO_EXPERT_MATCH] instead of forcing a mismatched cartridge.")
    else:
        print(f"  ✅ MATCH CONFIRMED: Armed with {top_exp['id']}")

print("\n" + "=" * 70)
print("🏁 TEST BATTERY COMPLETE")
print("=" * 70)
