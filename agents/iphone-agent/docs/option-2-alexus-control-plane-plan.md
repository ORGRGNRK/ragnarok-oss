# Option 2 Handoff — Always-On Alexus Control Plane and Mac Execution Worker

Prepared on 2026-08-24. This document is a standalone implementation packet for another coding
agent. Start from the latest `codex/slice-14-tailscale-launcher` branch after reviewing
`HANDOFF.md`, `PLAN.md`, and `docs/slice-14-tailscale-launcher.md`.

## Task packet

Build an always-on launcher control plane on the Linux node `alexus`, while keeping all iPhone
Mirroring observation and control inside the signed macOS worker on
`christophers-macbook-air`. The browser must never call the Mac runner directly in this design.
The Mac worker must make the connection outbound, revalidate every leased command locally, and
return only a privacy-minimized structural result by default.

Do not move `MacOsMirrorControlPort`, Vision OCR, native input helpers, confirmation dialogs, or
screen binding to Linux. Do not weaken confirmation, stale-screen, capability, risk-ceiling,
single-command, or uncertain-outcome behavior. Do not add screenshots, OCR text, command inputs,
receipts, tokens, or queue contents to git.

## Outcome

When complete, a tailnet browser can open an always-on launcher page served by `alexus`, see
whether the Mac worker is online, enqueue a supported built-in command, and follow its lifecycle.
If the Mac is online and iPhone Mirroring is ready, the signed worker executes locally and the
control plane displays a validated structural result. If the Mac is offline, the job remains
bounded and expires without pretending to have run.

The first production acceptance command is `Open Settings`. Screenshot transfer, command
authoring/synchronization, secret inputs, and remote confirmation are explicitly out of the first
milestone.

## Architecture

```text
tailnet browser
      |
      v
Tailscale Serve on alexus: /iphone
      |
      v
alexus control plane (127.0.0.1, Linux)
      |  SQLite: jobs, leases, worker status, structural results
      ^
      |  outbound HTTPS long-poll + bounded lease/heartbeat
      |
signed Mac worker
      |
      v
existing validator -> dry-run -> policy -> runner -> iPhone Mirroring driver
```

Use outbound HTTPS long-polling for the first version rather than adding a WebSocket dependency.
The worker opens no inbound listener. A 20-second lease poll gives near-immediate dispatch while
surviving ordinary reconnects and proxy restarts.

## Placement and durability

### Alexus control plane

- Bind to `127.0.0.1` on a new non-conflicting port selected after a live listener check.
- Expose only a tailnet-only Tailscale Serve path such as `/iphone`; never use Funnel.
- Run under PM2 using the existing ALEXUS deployment conventions.
- Store runtime job state in a private SQLite database on `alexus`, not in the repository.
- Use WAL mode, explicit migrations, `0600` database permissions, and bounded retention.
- Add the service and port to the root machine map, startup/setup path, and `.env.example` when
  implemented, as required by the repository checklist.

### Mac execution worker

- Run inside the signed `iPhone Commands.app` identity so existing Accessibility and Screen
  Recording grants remain applicable.
- Store its scoped worker credential in macOS Keychain. Never put it in a command document,
  receipt, log, environment example value, or source file.
- Maintain one in-flight lease and one runner execution at a time.
- Keep complete receipts and screenshot artifacts local by default.

## Trust and authentication

The tailnet boundary is necessary but not sufficient for the worker API.

- The browser control plane remains behind tailnet-only HTTPS and keeps its per-page mutation
  token.
- Provision one random, revocable, worker-scoped credential on `alexus`; install it in Keychain
  through a deliberate pairing action on the Mac.
- Authenticate every worker request over HTTPS. Compare secrets in constant time.
- Bind the credential to a stable worker id and declared machine name.
- Do not accept browser-supplied worker identity headers.
- Rate-limit pairing and worker authentication failures without logging credential material.
- Rotation must allow one overlap window, then revoke the previous credential.

## Command authority

The control plane requests a command; the Mac remains the final authority on what can execute.

1. The worker publishes a manifest containing command id, semantic version, SHA-256 document
   digest, assessed risk, required capabilities, and availability. It publishes no inputs or
   observation content.
2. The browser can enqueue only a manifest entry currently advertised by the worker.
3. A lease contains `jobId`, `commandId`, `version`, `digest`, non-secret inputs, creation time,
   execution deadline, and attempt number.
4. The worker resolves the command from its local catalog and requires id, version, and digest to
   match the lease.
5. The worker parses, validates, assesses policy, and performs recursive dry-run again locally
   before touching the phone.
6. A mismatch or missing capability fails closed without starting a driver session.

Do not send arbitrary command documents from Linux to the Mac in the first milestone. Command
authoring and signed catalog synchronization are a later, separately reviewed slice.

## Job state machine

```text
queued -> leased -> running -> succeeded
                    |       -> stopped
                    |       -> failed
                    |       -> outcome_unknown
queued -> expired
leased -> queued          only if the worker proves execution never started
```

- Each job has a unique idempotency key and a hard execution deadline.
- A lease has a short expiry and must be heartbeated while running.
- The worker reports `startedAt` before creating the driver session.
- Once any driver action may have started, loss of the worker or lease must produce
  `outcome_unknown`; the control plane must never automatically retry it.
- Requeue is allowed only when the worker explicitly reports that execution never started.
- Cancellation is allowed while queued. After running begins it becomes a stop request, not an
  assertion that the phone stopped.
- Expired and unknown jobs remain visible until retention cleanup.

## Proposed API contract

Browser-facing:

- `GET /api/bootstrap` — commands, worker availability, queue summary, mutation token.
- `POST /api/jobs` — enqueue one advertised command using id/version/digest.
- `GET /api/jobs/:id` — current lifecycle and structural result.
- `POST /api/jobs/:id/cancel` — queued cancellation or running stop request.

Worker-facing:

- `POST /api/worker/session` — authenticate, declare version/capabilities, publish catalog
  manifest, and heartbeat availability.
- `POST /api/worker/lease` — bounded long-poll for one eligible job.
- `POST /api/worker/jobs/:id/started` — atomically mark the execution boundary.
- `POST /api/worker/jobs/:id/heartbeat` — renew an active lease.
- `POST /api/worker/jobs/:id/complete` — submit structural result plus receipt digest.
- `POST /api/worker/jobs/:id/stop-ack` — acknowledge whether a stop occurred before or after a
  possible driver action.

Publish a versioned JSON Schema for leases and structural results. Add it to the existing schema
format lock only after reviewing the minimal diff.

## Privacy-minimized result

The first milestone sends only:

- job id, command id/version/digest;
- final status and timestamps;
- step ids, action names, statuses, attempts, and verification pass/fail;
- confirmation outcome without the shown screen;
- machine-readable error code and a scrubbed message;
- SHA-256 digest of the complete local receipt.

It does not send screenshot bytes or paths, OCR/screen text, target clues, resolved coordinates,
inputs, actor names, device identifiers, or raw error details. The full validated receipt remains
on the Mac. Any later artifact synchronization requires an explicit product decision, encryption
at rest on `alexus`, retention bounds, and its own live acceptance.

## Safety invariants

- Preserve the existing risk ladder and launcher ceilings.
- Confirmation remains a native Mac dialog immediately before the committing action.
- Preserve the post-approval observation and `CONFIRMATION_STALE` void exactly.
- The Linux control plane cannot approve, synthesize, cache, or replay confirmation.
- No silence, disconnect, timeout, or missing heartbeat can mean approval or success.
- A structural result is displayed as successful only after schema validation and digest
  association with the leased job.
- Never automatically retry a job whose execution outcome is uncertain.
- Secret or credential inputs are unsupported until a human-controlled Mac-local input path is
  designed and accepted separately.
- Keep both services loopback-bound behind Tailscale Serve; never expose them to LAN or public
  Funnel by default.

## Delivery slices and gates

### 2A — Contract and deterministic simulator

- Add job/lease/result types and published schemas.
- Implement the state machine and SQLite repository behind interfaces.
- Add fake control-plane and fake-worker integration tests for reconnects, lease expiry,
  duplicate completion, cancellation, version mismatch, and uncertain outcome.
- Keep all live driver code untouched.

Gate: automated tests prove that no duplicate or expired lease can produce a second execution and
that a post-start disconnect cannot be requeued.

### 2B — Alexus control plane

- Build the loopback service and adapt the launcher UI to job submission/status rather than direct
  driver calls.
- Deploy under PM2 on `alexus` and add a tailnet-only Tailscale Serve path.
- Verify unavailable-worker, queued, expired, and rejected-command states from another tailnet
  node.

Gate: the UI is always reachable, but no phone action is possible because no production worker
is connected yet.

### 2C — Signed Mac worker, reversible commands only

- Add explicit worker mode to the signed app and Keychain-backed pairing.
- Publish the local command manifest and implement outbound lease polling.
- Revalidate and preflight locally; allow only `read` and `reversible` jobs.
- Return privacy-minimized results and retain the complete receipt locally.

Gate: from the `alexus` UI, `Open Settings` runs once on the real mirrored phone, produces a
validated local receipt, returns a matching structural result, and survives a simulated network
drop without duplicate execution.

### 2D — Confirmation and failure semantics

- Enable `external` jobs only after the existing native confirmation provider is wired through
  worker mode unchanged.
- Surface `awaiting local confirmation`, denial, unavailable, stale, and unknown outcomes in the
  control-plane UI.
- Run the deterministic live `CONFIRMATION_STALE` acceptance through a remotely enqueued job.

Gate: stale approval stops before the driver action, and a network loss after a possible commit is
reported as unknown and never retried.

### 2E — Optional catalog authoring and artifacts

Do not begin from momentum. Decide separately whether commands authored on `alexus` can be signed
and installed into the Mac catalog, and whether selected artifacts can be encrypted and copied to
`alexus`. Each capability needs its own protocol, threat review, retention policy, and live gate.

## Acceptance matrix

- Mac offline: enqueue is bounded, visible, and expires without execution.
- Mirror paused: worker either resumes through existing verified behavior or fails structurally.
- Mirror locked/disconnected/obscured: existing machine-readable stop is preserved.
- Capability mismatch: worker rejects before driver creation.
- Command digest mismatch: worker rejects before driver creation.
- Worker drops before `started`: job may be safely requeued after proof.
- Worker drops after `started`: job becomes `outcome_unknown`, never automatically retried.
- Duplicate lease/completion: idempotent response, no second execution.
- Confirmation denied/unavailable/stale: no committing action and no success.
- Control plane restart: SQLite state and leases recover deterministically.
- Tailnet unavailable: local launcher remains usable; worker reconnects without widening access.

## Rollout and rollback

Ship each slice behind an explicit worker-mode flag. Keep the current local/Tailscale launcher as
the fallback until all live gates pass. Rollback is:

1. Disable worker mode on the Mac; local launcher behavior remains unchanged.
2. Remove the `/iphone` Tailscale Serve route on `alexus`.
3. Stop and remove only the new PM2 control-plane process.
4. Preserve the SQLite database for audit or archive it according to the chosen retention policy.

Do not delete local receipts or screenshot artifacts as part of rollback.

## Definition of done

- Every new schema, API, state transition, and failure mode has automated coverage.
- Root machine map, startup path, connector/security docs, `.env.example`, package docs, and
  handoff are updated.
- Full package checks pass on both machines.
- The reversible live acceptance passes from the `alexus` UI exactly once.
- The stale-confirmation and post-start-disconnect acceptances prove no unsafe retry.
- The local launcher still works when the control plane or tailnet is unavailable.
- Branch is committed and pushed with a copy-paste handoff naming the verified branch and commit.
