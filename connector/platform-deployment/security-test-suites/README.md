# Ragnarok Adversarial Security Harness

A conservative, standard-library Python smoke-test runner for a **disposable test deployment**.

## Important
This is a starter harness, not a security certification and not yet a repository-specific integration. It deliberately marks checks INCONCLUSIVE when it cannot observe them safely. Do not run disruptive tests against production data.

## Files
- `security_test.py` — executable runner
- `security-test.example.json` — example configuration

## Setup
1. Copy `security-test.example.json` to `security-test.json`.
2. Edit URLs, ports, Compose service name, project directory, and receipt verifier to match the actual repository.
3. Ensure the MCP transport URL and status/lock endpoints match your implementation. The generic JSON-RPC request may need adaptation if your MCP server requires initialization or session headers.
4. Run:

```bash
chmod +x security_test.py
./security_test.py --config security-test.json
```

To allow the runner to call the lock endpoint (only against a disposable instance):

```bash
./security_test.py --config security-test.json --allow-lock
```

To additionally restart the configured Compose service (disposable instance only):

```bash
./security_test.py --config security-test.json --allow-lock --allow-restart
```

## Test coverage
- T01 sealed status
- T02 protected MCP tool denied while sealed
- T03 host-side PostgreSQL TCP reachability probe (a host probe cannot prove agent-network isolation)
- T04 manual lock endpoint (opt-in)
- T05 protected tool denied after lock (opt-in)
- T06 lease expiry — inconclusive until a test-only short TTL is wired in
- T07 hardware response replay — inconclusive until a test authenticator fixture exists
- T08 credential isolation — requires repository/container-specific inspection
- T09 restart defaults to locked (opt-in)
- T11 receipt chain verifier (configured command)
- T12 receipt tamper detection — requires a disposable ledger fixture

Every result includes an evidence SHA-256. The report itself also receives a SHA-256. These hashes make the report content tamper-evident only if the report/hash is preserved independently; they do not prove the test environment was honest.

## Before using with a partner
Have the repository owner adapt the MCP handshake, lock endpoint, health/status endpoint, Docker network probes, active-query cancellation test, hardware authenticator replay fixture, and receipt tamper fixture to the actual code. The current harness does not claim to prove those unimplemented checks.
