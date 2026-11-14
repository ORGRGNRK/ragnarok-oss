# Ragnarok Security Harness — Reimagined Version

This is a fresh implementation of the smoke-test you shared, rewritten in my own form. It keeps the same conservative philosophy: unobservable = INCONCLUSIVE, never PASS.
Only run against a disposable test deployment with throwaway data.

## What changed vs your original
- Renamed internals (CheckOutcome vs Result, verdict vs status, _note vs record)
- Modular HTTP helpers (_http_get, _http_post, _mcp_invoke)
- Explicit opt-in flags: --enable-lock and --enable-restart (instead of --allow-*)
- Same 12-test coverage + additional active tests
- Output file defaults to security-test-results.reimagined.json

## Files
- `security_test_reimagined.py` — main runner (std-lib only)
- `security-test.reimagined.example.json` — example config
- `README_REIMAGINED.md` — this file

## Test Coverage
- T01 sealed / locked status reported
- T02 protected MCP tool denied while sealed
- T03 host-side Postgres TCP probe (host probe != container isolation proof)
- T04 manual lock endpoint (opt-in)
- T05 tool denied after manual lock (opt-in)
- T06 lease expiry — always INCONCLUSIVE without test TTL fixture
- T07 hardware auth replay — always INCONCLUSIVE without test authenticator
- T08 credential isolation — always INCONCLUSIVE without container inspection
- T09 restart defaults to locked (opt-in)
- T10 hardware auth rejection & invalid proof probe (active check)
- T11 receipt chain verifier (if receipt_verify_command set)
- T12 tamper detection — always INCONCLUSIVE without disposable ledger fixture
- T13 sensitive credential exposure probe across MCP tools & status

Every outcome includes a SHA-256 of its envelope for evidence chaining.

## Setup
1. Copy config:
```bash
cp security-test.reimagined.example.json security-test.reimagined.json
# edit URLs, ports, service name, etc. to match your disposable deployment
```

2. Run baseline (safe, no side effects):
```bash
chmod +x security_test_reimagined.py
./security_test_reimagined.py --config security-test.reimagined.json
```

3. Run with lock test (disposable only):
```bash
./security_test_reimagined.py --config security-test.reimagined.json --enable-lock
```

4. Run with restart test (disposable only):
```bash
./security_test_reimagined.py --config security-test.reimagined.json --enable-lock --enable-restart
```

## Interpreting Results
- PASS: probe behaved as expected for that check
- FAIL: probe succeeded in a way that needs investigation (e.g., TCP connect to DB)
- INCONCLUSIVE: not configured or cannot be safely observed - this is expected for T06-T08, T12 without fixtures

This is not a security certification.
