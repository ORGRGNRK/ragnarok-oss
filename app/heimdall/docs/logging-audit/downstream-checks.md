# Downstream checks — 2026-11-03

Actor: codex. OS account: the owner's. Scope: the uncommitted Heimdall changes,
connector tracked diffs around receipts/registration/authentication, and the
connector's existing test/build/install-guide checks. This was not a complete
review of the connector's untracked security harnesses or configuration files.

## Heimdall

- Release app build passed. Compiler warnings remain in AITerminal, Auth,
  HubHistory and HubOps; these files were not changed in this work.
- App self-test passed, including actor/run attribution, old app-error rows,
  secret scrubbing and the agent-result browser link.
- Agent runner and planner selfchecks passed, using fake CLIs rather than models.
- Local-config and claude-live checks passed.
- Actual LocalModelLoader code passed five transport-fixture checks: model
  discovery for Alexus and LM Studio, plus offline, malformed and empty fallbacks.
- A real local child process received the expected actor/run/origin labels and
  normalized Alexus provider endpoint. No model or network request was made.
- Logging audit validation and a mocked complete two-pass run passed. Omitted
  findings remain Unverified, display normalization works, and artifacts retain
  directory 0700 / file 0600 permissions.

A targeted configuration test initially failed: the Python agent runner accepted
`file://` model URLs and malformed hosts, unlike the app's invalid-value fallback
policy. The runner was corrected to validate HTTP(S) endpoints and hosts, preserve
valid overrides, handle IPv6 authorities and normalize API suffixes before adding
`/v1`. Regression checks are included in `ragnarok-agent selfcheck`.

Live model sessions and interactive GUI behavior were not tested. Passing these
checks is not proof of every downstream behavior. The app was not installed.

## Connector: excluded from the commit

The existing suite reported 39 passed and 21 skipped tests. Typechecking, build,
and install-guide schema validation passed. The skipped tests include the
scratch-database business/search suites; they were not enabled against live data.

Two additional offline probes reproduced problems:

1. A successful ToolHost call using a valid custom receipt sink with `write` but
   without `executeWithReceipt` or a `rows` property wrote zero receipts. The
   existing memory sink masks this path because it has `rows`. The changed
   success condition in `src/core/server.ts` does not cover all ReceiptSink
   implementations.
2. Running the s12 registration verification command with a fake `claude` that
   exits 1 still exited 0 and printed `Verified`. The `|| echo 'Verified'` fallback
   masks a failed verification; the schema validator does not execute this check.

The configured unlock-proof acceptance/rejection probe passed, but it does not
verify hardware presence or the complete installer/authentication flow. Installer
execution, database migrations, client registration, service restart and active
security harnesses were not run. Connector files were left uncommitted and their
existing changes preserved.
