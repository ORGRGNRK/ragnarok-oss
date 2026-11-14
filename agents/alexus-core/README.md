# ALEXUS CORE (🌸⚡)

**Multi-Expert AI Harness & Autonomous Cyberdeck Engine**

ALEXUS Core is a decoupled, bare-metal AI harness built on the **Conveyor Methodology** and **Meta-RAG Multi-Expert Vault**. It performs sub-50ms vector routing across an indexed library of specialized domain micro-cartridges, verifies domain and code logic against deterministic test runners, and logs tamper-evident cryptographic receipts.

---

## ⚡ Architecture Overview

```
                      [ USER / SENSORY TASK INTAKE ]
                                    │
                      [ META-RAG INTAKE (~50ms) ]
              Vector similarity across Cartridge Vault (nomic-embed-text)
                                    │
              [ CONVEYOR PREFLIGHT CONTRACT GATE (0ms) ]
              Deterministic negative boundary check (DICOM, Medical, etc.)
                                    │
             [ DUAL-PASS EXECUTION & SUBSYSTEM SPECIALIZATION ]
              - Pass 1: Macro Domain Schema (Decomposition)
              - Pass 2: Armed Expert Cartridges (Ground-Truth In-Context Rules)
                                    │
              [ CONVEYOR VERIFICATION DYNO (Test Gate) ]
              Executes domain-specific assertion test suites in tests/
              (Enforces Shell Exit Code 0)
                                    │
               [ STAR FOX COMMS HUD & CRYPTOGRAPHIC RECEIPT ]
              Tamper-evident SHA-256 linear hash chain in receipts.jsonl
```

### Performance & Latency Characteristics
- **Cartridge Routing & Lookup (`alexus lookup`):** ~50ms (embedding cosine similarity over in-memory cache).
- **Task Synthesis & Code Generation (`alexus ask`):** 30–70s (bounded by local LLM generation speed on Ollama `llama3.2:3b`).
- **Verification Dyno (`tests/verify_*.py`):** 10–50ms (deterministic Python assertion suites).

---

## 🚀 Quickstart

### 1. Check System Status & Cartridges
```bash
./alexus status
./alexus cartridges
```

### 2. Fast Cartridge Lookup (Sub-50ms Rule Retrieval)
```bash
./alexus lookup "iPhone 15 Pro cracked front glass display"
```

### 3. Execute a Live Task
```bash
./alexus ask "Our S2000 OBD2 data is dropping RPM packets at 500kbps on track days"
```

### 4. Verify Cryptographic Receipt Ledger
```bash
./alexus verify-receipts
```

---

## 📦 Adding New Domain Cartridges (The Vault)

Drop a new `.json` cartridge into `cartridges/`:

```json
{
  "id": "expert-your-domain",
  "domain": "Domain Name",
  "description": "What this expert knows in detail...",
  "standards": ["ISO/RFC/Standard"],
  "negative_exclusions": ["excluded_keywords"],
  "knowledge_rules": [
    "Rule 1: Never estimate without ground truth",
    "Rule 2: Enforce deterministic calculations"
  ],
  "verification_command": "python3 /path/to/tests/verify_your_domain.py"
}
```

The Meta-RAG index automatically embeds and indexes the new cartridge on the next run.

---

## 🧪 Verification Dynos & Domain Test Suites

Each cartridge is backed by a deterministic test suite in `tests/`:

- `tests/verify_phone_grading.py`: Validates Atlas / wholesale used phone cosmetic rubric (Grades A/B/C/D/F), cracked glass vs display panel health calibration, aftermarket screen rules, and battery thresholds.
- `tests/verify_ledger_chain.py`: Validates SHA-256 linear chain continuity, canonical payload serialization, and tamper detection.
- `tests/verify_fido2_ctap.py`: Validates CTAP2 authenticatorData byte packing and user presence flags.
- `tests/verify_s2000_f22c.py`: Validates Honda AP2 F22C1 stroke, displacement, compression, and fuel cut RPM.
- `tests/verify_lexus_2gr.py`: Validates Toyota D-4S injection pressure and AA81E fluid check temperatures.
- `tests/verify_can_bus.py`: Validates CAN 2.0A frame parsing, 11-bit IDs, and OBD-II PID formula math.
- `tests/reproduce_socket_test.py`: Validates non-blocking async socket retries.
- `tests/verify_ocr.py`: Validates CRNN image tensor normalization constraints.
- `tests/verify_xero.py`: Validates accounting invariants (Assets = Liabilities + Equity) and variance math.

---

## 🔒 Cryptographic Provenance (Yggdrasil Write Log Parity)

Every task execution creates a tamper-evident receipt block appended to `receipts.jsonl`:
- **Chained Hashing:** Each block links to `prev_receipt_hash` using 256-bit SHA-256.
- **Payload Integrity:** Canonical JSON payload hashing prevents retrospective modification of tasks or execution outcomes.
- **Audit Command:** `./alexus verify-receipts` scans and validates the entire chain from genesis to head.

---

## 🔐 Which commands need a touch (fail-closed gate, 2026-10-30)

`verify_hardware_presence()` asks for a physical touch: an enrolled FIDO2 key (`bin/fido-auth.sh`)
first, Apple Touch ID (`bin/auth-gate`) as the fallback. It now **fails closed**:

| Situation | Before | Now |
|---|---|---|
| No terminal on stdin (script, pipe, daemon, AI tool) | allowed unless `ALEXUS_REQUIRE_AUTH=1` | **refused**, no gate is even started |
| `ALEXUS_REQUIRE_AUTH=0` | gate switched off | **ignored** (a notice is printed; the gate still runs) |
| No enrolled FIDO2 key/script **and** no `bin/auth-gate` | allowed | **refused** (build the gate: `./build-auth.sh`) |
| Key not inserted (FIDO2 exit 3) | falls back to Touch ID | unchanged; with no Touch ID gate it is refused |

A refused command prints why and exits with code 1. The FIDO2 and Touch ID checks themselves
(`bin/fido-auth.sh`, `src/auth_gate.swift`) are unchanged.

| Command | Needs a touch? |
|---|---|
| `alexus ask "<task>"` (and any unknown word, which runs as `ask`) | **yes** |
| `alexus chat` | **yes** |
| `alexus auth-test` | **yes** (it is the gate) |
| `alexus verify-receipts`, `status`, `cartridges`, `lookup`, `keys` | no (read-only) |
| `alexus setup`, `enroll-key`, `mail-setup`, `mail-daemon`, `imessage-daemon`, `imessage-reply` | no, not gated by this function (unchanged) |

Because there is no TTY, the gated commands can no longer be run headless by an agent or a
launchd job. That is the point. Tested by `python3 tests/verify_auth_gate.py` (fake gates, fake
terminal, no real key or network).

## 📌 Keep a copy of the receipt head off this machine

`./alexus verify-receipts` proves the chain in `receipts.jsonl` is internally consistent. It cannot
prove the whole file wasn't rewritten from the start by someone with access to this Mac. For that,
now and then copy the **head hash** (the last block's `receipt_hash`) somewhere this machine can't
change: a note on your phone, a message to yourself, a printout, another machine.

```bash
tail -n 1 receipts.jsonl | python3 -c 'import json,sys; r=json.load(sys.stdin); print(r["index"], r["timestamp"], r["receipt_hash"])'
```

Later, check that the block with that index still has the same hash; if it doesn't, history was
rewritten. (Nothing here sends it anywhere; copying it off the machine is a manual step on purpose.)
