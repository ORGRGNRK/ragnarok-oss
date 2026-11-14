# Ragnarok Security Test Suites (Triple Bundle)

This directory contains three comprehensive, complementary security test suites for the Ragnarok MCP platform:

---

### Suite 1: Standard Security Harness (`security_test.py`)
- **File**: `security_test.py`
- **Config**: `security-test.json` (template: `security-test.example.json`)
- **Report**: `security-test-results.json`
- **Docs**: `README.md`
- **Command**:
  ```bash
  python3 ./security_test.py --config security-test.json --allow-lock --allow-restart
  ```
- **Coverage**: T01-T12 conservative baseline probes for status, MCP lock rejection, Postgres TCP reachability, manual lock, restart fail-closed behavior, and cryptographic receipt verification.

---

### Suite 2: Reimagined Harness with Active Hardware & Secret Probes (`security_test_reimagined.py`)
- **File**: `security_test_reimagined.py`
- **Config**: `security-test.reimagined.json` (template: `security-test.reimagined.example.json`)
- **Report**: `security-test-results.reimagined.json`
- **Docs**: `README_REIMAGINED.md`
- **Command**:
  ```bash
  python3 ./security_test_reimagined.py --config security-test.reimagined.json --enable-lock --enable-restart
  ```
- **Coverage**: Modular Python std-lib harness with explicit opt-in flags, plus active probes:
  - **T10**: Hardware authorization forge/replay rejection (`HTTP 401 Unauthorized`)
  - **T13**: Sensitive credential leakage probe across exposed endpoints

---

### Suite 3: Deliberate Attack Scenarios Suite (`security-attacks-test.mjs`)
- **File**: `security-attacks-test.mjs`
- **Command**:
  ```bash
  node ./security-attacks-test.mjs
  ```
- **Coverage**: Full Node.js / Docker attack suite evaluating 8 production readiness scenarios:
  1. Direct PostgreSQL access from rogue / unauthorized containers
  2. Concurrent queries while issuing lock
  3. Replay of old hardware authorization & forged unlock calls
  4. Kill gatekeeper during active database transaction
  5. Clock tampering & monotonic lease enforcement
  6. Environment secret extraction probing across all exposed MCP tools
  7. Docker restart while unlocked (fail-closed boot state)
  8. Direct dispatch layer & HTTP host header bypass attempts
