# Slice 3 — deterministic runner and iPhone Mirroring driver

Date: 2026-08-19

Status: **complete**

Slice 3 adds execution without coupling portable commands to the Mac control mechanism. The
runner knows protocol, policy, verification, and receipts. The driver translates only the
portable primitive actions into iPhone Mirroring controls.

## Delivered

- `DeterministicRunner` with one-step-at-a-time execution
- Observation capture before and after every step
- Precondition, step expectation, assertion, wait, and command postcondition evaluation
- Safety assessment and just-in-time confirmation-provider calls
- Bounded retry behavior from the command's `onFailure` declaration
- Fail-fast unsupported-capability receipts
- Receipt snapshots before action execution and before advancing to the next step
- In-memory and atomic JSON-file receipt sinks
- `PortableDriver` and `MirrorControlPort` interfaces
- `IPhoneMirroringDriver` adapter
- Paused-connection detection and deterministic Resume handling
- Home, Spotlight, typing, tap, press, and scroll translations
- Normalized fallback-point conversion through explicit mirror action bounds
- Minimum target-confidence enforcement before any coordinate tap
- Deterministic JPEG screen-template resolver for observable postconditions

Runner-owned `assert`, `waitFor`, and `confirm` actions are implemented. Reusable `call` steps
and recovery commands remain deferred to Slice 5 as originally planned.

## Live acceptance

The unchanged portable fixture at `fixtures/valid/open-settings.json` was executed against
the real iPhone Mirroring app through the compiled runner and driver.

The run produced:

| Field | Result |
|---|---|
| Receipt ID | `run-live-open-settings-20260819` |
| Command | `com.yggdrasil.iphone.open-settings` |
| Driver | `iphone-mirroring` version `0.1` |
| Starting observation | Home Screen; Settings template confidence `0.607` |
| Action | One portable `openApp` step translated through Home and Spotlight |
| Ending observation | Settings; template confidence `0.896` |
| Step verification | Passed |
| Command postcondition | Passed |
| Final status | `succeeded` |

The runner's action list and observation list were recorded in the receipt. The step required
no confirmation because its effective risk was `reversible`. The iPhone was returned to its
Home Screen after the proof.

## Verification

The package completes a strict TypeScript build and 19 automated tests. The added Slice 3
tests cover:

- receipt snapshots around a successful action;
- bounded retry after a failed observation;
- immediate stop when confirmation is denied;
- no execution when a driver capability is missing;
- paused mirror recovery;
- deterministic `openApp` translation;
- normalized, bounded fallback coordinates;
- refusal to act below the target confidence threshold; and
- matching and rejection behavior for the template resolver.

## Current limitations

1. The live proof used a Settings template calibrated from the same mirror session. Durable
   template collection, versioning, and layout compatibility are not implemented.
2. Semantic text and icon target resolution is not implemented. Taps require either a future
   resolver result or an explicit normalized fallback point.
3. The observed screenshot is low resolution. OCR has not been selected or proven.
4. Horizontal Home Screen paging is still unverified.
5. Locked, obscured, permission, and unexpected-dialog states remain untested.
6. `call`, resumable execution, and recovery commands remain Slice 5 work.

These limits are advertised rather than guessed past. The live acceptance demonstrates the
runner/driver boundary and deterministic receipt lifecycle; it does not claim the mirror
driver is hardened for arbitrary applications yet.

## Slice 4 handoff

Command-creation tools can now target the published schema and call `parseCommand` before a
document reaches the runner. A guided authoring CLI should never emit driver coordinates or
Mac shortcuts as command actions, and optional natural-language authoring must pass through
the same validator and safety policy.
