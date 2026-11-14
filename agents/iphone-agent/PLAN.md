# iPhone Commands — Portable Automation Through iPhone Mirroring

## Status

**LAUNCHER COMPLETE — installed and live-verified on 2026-08-20.**
**LAUNCHER AUTHORING COMPLETE — live-verified on 2026-08-20.**

This project creates, validates, and executes portable iPhone command documents. A command
describes **what interaction should happen** and **what state should result** without being
tied to a particular AI model, agent framework, desktop automation program, or execution
library.

The first execution target is Apple's **iPhone Mirroring** app on macOS. The core command
format must remain independent of that target so another driver (for example Appium,
WebDriverAgent, a human-assisted runner, or a future device API) can execute the same command
where its capabilities permit.

AI is optional. A person, script, conventional program, or AI can author commands. Execution
is deterministic and does not require an AI unless a selected target-resolution strategy
explicitly uses one.

---

## Product boundary

The project has three separate layers:

1. **Command documents** — portable JSON or YAML containing intent, actions, targets,
   expected states, safety requirements, and failure behavior.
2. **Runner** — validates a command, applies policy, records a receipt, and calls a driver.
   It knows the command protocol but nothing about AI providers or desktop automation tools.
3. **Drivers** — translate the protocol into a concrete control mechanism. The first driver
   operates the macOS iPhone Mirroring window.

```text
human / script / any AI
          |
          v
 portable command document
          |
          v
 validator -> policy -> runner -> receipt
                              |
                              v
                   iPhone Mirroring driver
                              |
                              v
                           iPhone
```

The portable command is the durable product. Authoring and execution implementations are
replaceable adapters.

---

## Command contract

Commands are data, not generated source code and not tool-specific macros. The canonical
representation is JSON; YAML may be accepted as an authoring convenience and normalized to
JSON before validation.

Each command contains:

- `schemaVersion`: protocol version.
- `id`, `name`, and optional `description`: stable identity and human meaning.
- `inputs`: typed values supplied at run time; secrets are referenced, never embedded.
- `preconditions`: states that must be true before execution.
- `steps`: ordered primitive actions and/or calls to other commands.
- `onFailure`: stop, retry with a bound, request help, or run a recovery command.
- `safety`: risk class and whether human confirmation is required.
- `postconditions`: observable evidence of success.

Initial portable action vocabulary:

- `openApp`
- `tap`
- `typeText`
- `swipe`
- `press`
- `capture`
- `waitFor`
- `assert`
- `confirm`
- `call`

Actions express semantics, not implementation. For example, `press: home` does not encode a
macOS menu shortcut, and `swipe: up` does not encode mouse coordinates. The active driver
maps each action to its own mechanism or reports a clear `unsupported` result.

Targets use a ranked set of portable clues rather than a dependency on one inspection API:

```json
{
  "role": "button",
  "label": "Settings",
  "text": "Settings",
  "hint": "gray gear app icon",
  "within": "home screen",
  "fallbackPoint": { "x": 0.72, "y": 0.31 }
}
```

Coordinates, when unavoidable, are normalized from `0` to `1` relative to the mirrored
iPhone content area. They are a last fallback because they are sensitive to layout changes.
A command may require a minimum target-resolution confidence before the runner acts.

Variables use an explicit form such as `${input.message}`. The runner resolves variables
before execution and rejects missing or incorrectly typed inputs.

---

## Execution semantics

For every step the runner follows the same lifecycle:

1. Capture the current observable state from the driver.
2. Check the step's precondition, if any.
3. Resolve the target and require the configured confidence threshold.
4. Apply safety policy and obtain confirmation when required.
5. Execute exactly one action.
6. Capture state again and evaluate the expected result.
7. Write a structured receipt before proceeding.

The runner never silently guesses past an ambiguity. If multiple targets match, the screen
is unexpected, the mirror is disconnected, or verification repeatedly fails, it stops with
a machine-readable reason that any caller can handle.

Every run produces a receipt containing command/version, inputs with secrets redacted,
timestamps, observations, resolved targets, actions, confirmations, verification results,
and the final outcome. Screenshots are optional artifacts referenced by path or ID rather
than embedded in the receipt.

---

## iPhone Mirroring driver (v1)

The first driver controls the iPhone through Apple's iPhone Mirroring window on this Mac. It
is responsible for implementation details such as:

- finding and focusing the correct mirror window;
- locating the exact mirrored-screen bounds inside the window;
- capturing the visible phone state;
- resolving text, icons, and normalized points;
- translating tap, typing, swipe, Home, and App Switcher actions into macOS input;
- detecting disconnected, locked, obscured, permission, and unexpected-dialog states;
- preventing clicks outside the mirrored-screen bounds.

The driver exposes capabilities at session start. The runner checks them before executing a
command and fails early if a required action or observation is unavailable.

The plan does **not** assume the iPhone accessibility tree is exposed through the mirror.
That must be verified on the actual machine. The v1 driver can use visible-state matching
and normalized geometry; richer accessibility data is an optional capability if observation
proves it exists.

---

## Safety policy

Risk is attached to the semantic action, not to the authoring program.

- `read`: observation only; no confirmation.
- `reversible`: navigation, opening apps, or editable local input; normally allowed.
- `external`: sends, posts, calls, uploads, or changes remote state; confirm immediately
  before the committing step.
- `financial`: purchases, transfers, subscriptions, or bids; always confirm.
- `destructive`: delete, erase, reset, sign out, revoke, or overwrite; always confirm.
- `credential`: passwords, passcodes, recovery keys, or authentication approval; require a
  human-controlled secure input path and never log the value.

A command cannot lower the machine's configured safety floor. Unknown actions default to
requiring confirmation.

---

## Delivery slices

### Slice 1 — Mirror proof

- Verify iPhone Mirroring works on this Mac and identify its observable/control surface.
- Prove focus, screenshot, one safe tap, typing into a harmless field, and one swipe.
- Record verified capabilities and limitations. Do not infer them from Appium/WDA behavior.

**Gate:** one safe interaction must succeed through the mirror before building the general
runner.

**Result:** Passed on 2026-08-19. See
[`docs/slice-1-mirror-proof.md`](./docs/slice-1-mirror-proof.md) for the observed capability
surface, evidence, and constraints.

### Slice 2 — Protocol and validator

- Publish JSON Schema for command documents and execution receipts.
- Implement parsing, normalization, variable resolution, capability checks, and validation.
- Add fixtures for valid, invalid, unsupported, and confirmation-required commands.

**Result:** Complete on 2026-08-19. See
[`docs/slice-2-protocol-validator.md`](./docs/slice-2-protocol-validator.md) for the delivered
schemas, public API, verification results, and Slice 3 boundary.

### Slice 3 — Mirror driver and deterministic runner

- Implement the driver interface and iPhone Mirroring adapter.
- Execute one action at a time with pre/post observation and bounded retries.
- Prove a harmless end-to-end command such as opening Settings and asserting its screen.

**Result:** Complete on 2026-08-19. The portable `Open Settings` fixture ran through the
deterministic runner and real iPhone Mirroring driver, then produced a verified `succeeded`
receipt. See [`docs/slice-3-runner-mirror-driver.md`](./docs/slice-3-runner-mirror-driver.md).

### Slice 4 — Command creation tools

- Add a guided CLI/editor that creates commands without requiring AI.
- Add import/export for canonical JSON and author-friendly YAML.
- Add an optional natural-language author adapter behind the same schema validator; no AI
  output can bypass validation or safety policy.

**Result:** Complete on 2026-08-19. The `iphone-command` CLI supports guided creation,
validation, JSON/YAML conversion, and conservative built-in text patterns. A provider-neutral
validation wrapper is available for future AI adapters. See
[`docs/slice-4-command-authoring.md`](./docs/slice-4-command-authoring.md).

### Slice 5 — Library and hardening

- Build reusable commands from smaller commands with typed inputs.
- Add versioning, compatibility checks, dry runs, resumable receipts, and recovery commands.
- Add other drivers only when there is a demonstrated need; the command protocol remains
  unchanged where possible.

**Result:** Complete on 2026-08-19. Commands have semantic versions, `call` steps can select
compatible versions from memory or directory catalogs, and recursive dry runs prove the full
dependency tree before any phone action. The runner supports namespaced nested receipts,
recovery commands, and conservative resume from completed step boundaries. Durable template
manifests and explicit mirror-state classification harden the first driver. No additional
driver was added because no demonstrated need exists. See
[`docs/slice-5-library-hardening.md`](./docs/slice-5-library-hardening.md).

### Launcher milestone

- Provide a non-technical local interface with saved commands and one Run button.
- Connect it to the real iPhone Mirroring driver without sending data over the network.
- Install a stable Mac app and make the first command easy to launch.

**Result:** Complete on 2026-08-20. The signed `iPhone Commands` app is installed in the
user Applications folder with a Desktop shortcut. Its local interface preflights commands,
blocks committing actions without just-in-time confirmation, and reports verified receipts.
The final live acceptance opened Settings through iPhone Mirroring and displayed one verified
step. A second live acceptance opened General, located About from live screen text, opened it,
verified `iOS Version`, and displayed two verified steps. See
[`docs/launcher.md`](./docs/launcher.md).

### Launcher authoring slice

- Let a person describe a safe routine in plain language inside the launcher.
- Convert only recognized, unambiguous patterns into a command document.
- Show the proposed steps in plain language and preflight before offering Save.
- Save only after validation, and only for commands the launcher can actually run.

**Result:** Complete on 2026-08-20. A routine typed as `open Notes and check for Notes` was
previewed, saved, and run through the installed app against the real mirrored iPhone, producing
`Open Notes worked` and one verified step. No new portable action, driver capability, or online
service was introduced. See
[`docs/slice-6-launcher-authoring.md`](./docs/slice-6-launcher-authoring.md).

### Slice 9 — Saved command management

- Edit launcher-authored commands from their original plain-language source.
- Revalidate and preflight every edit before replacing its exact backing file.
- Delete launcher-authored commands behind a named confirmation dialog.
- Keep built-in commands protected in both the interface and service.

**Result:** Complete on 2026-08-21. The launcher created, edited, revalidated, ran, and removed
a temporary `Press Home` command in an isolated UI acceptance test. The built-in `Open Settings`
command remained read-only. See
[`docs/slice-9-saved-command-management.md`](./docs/slice-9-saved-command-management.md).

### Slice 10 — Verified swipe support

- Translate portable direction, normalized start, and distance into a bounded mirror path.
- Deliver the gesture through a native macOS adapter without exposing pixels in commands.
- Advertise swipe only after proving visible content movement on the real mirrored iPhone.
- Add a durable command that survives Settings' remembered scroll position.

**Result:** Complete on 2026-08-21. A signed-launcher acceptance opened General on iOS 27,
used two downward gestures to reset any remembered position, verified About, then swiped upward
and verified Trackpad & Mouse. All four steps produced a successful verified receipt. The native
path uses continuous pixel scroll events anchored inside the mirror; ordinary synthetic mouse
dragging was tested and correctly rejected after it failed to move the phone page. See
[`docs/slice-10-verified-swipe.md`](./docs/slice-10-verified-swipe.md).

### Slice 11 — Schema format guard

- Preserve the reviewed byte layout of every published JSON Schema.
- Fail `npm run check` before compilation when a schema was mechanically reformatted.
- Detect new schema files that have not been added to the review lock.
- Provide an explicit lock-refresh command for legitimate, reviewed schema edits.

**Result:** Complete on 2026-08-21. The guard records SHA-256 fingerprints for the exact current
bytes instead of forcing the command and receipt schemas through one formatter and rewriting one
file. Automated acceptance proves both a parse-and-serialize rewrite and an unlocked new schema
fail, while a reviewed lock refresh restores the clean state. See
[`docs/slice-11-schema-format-guard.md`](./docs/slice-11-schema-format-guard.md).

### Slice 12 — Deterministic live confirmation-stale acceptance

- Stage a real mirrored-screen transition inside the approval-to-action interval.
- Keep the runner, binding comparison, confirmation dialog, schemas, and launcher semantics
  unchanged.
- Require a valid stopped receipt with `CONFIRMATION_STALE`.
- Prove the confirming action never reaches the driver.

**Result:** Complete and live-verified on 2026-08-21. The acceptance-only fixture resets
General's remembered scroll position, approves its reversible About step, and presses Home before
the unchanged runner can act. The real receipt stopped as stale and `open-about` never reached the
driver. See
[`docs/slice-12-confirmation-stale-acceptance.md`](./docs/slice-12-confirmation-stale-acceptance.md).

### Slice 13 — Durable screenshot evidence

- Add a portable, read-only `capture` step backed by the existing screenshot observation.
- Materialize named frames before the mirror adapter replaces its temporary capture.
- Save local launcher evidence outside the repository with private permissions.
- Prove a real About workflow from a reset top position to a verified bottom position.

**Result:** Complete and live-verified on 2026-08-23. See
[`docs/slice-13-about-capture.md`](./docs/slice-13-about-capture.md).

### Slice 14 — Tailnet launcher exposure

- Keep the launcher listener on loopback and proxy it through tailnet-only Tailscale Serve.
- Discover the node's exact Tailscale DNS name at startup and preserve the Host allowlist.
- Fail closed to local-only behavior whenever Tailscale is stopped or unavailable.
- Verify the remote command catalog and authenticated no-action preflight from `alexus`.

**Result:** Complete and remotely verified on 2026-08-24. See
[`docs/slice-14-tailscale-launcher.md`](./docs/slice-14-tailscale-launcher.md).

The larger always-on split is specified separately in
[`docs/option-2-alexus-control-plane-plan.md`](./docs/option-2-alexus-control-plane-plan.md).

---

## First acceptance command

The first end-to-end fixture should express this without containing any AI-provider,
AppleScript, UI-automation, or pixel implementation details:

```json
{
  "schemaVersion": "0.1",
  "id": "com.yggdrasil.iphone.open-settings",
  "name": "Open Settings",
  "safety": { "risk": "reversible" },
  "steps": [
    {
      "id": "open-settings",
      "action": "openApp",
      "app": { "name": "Settings", "bundleId": "com.apple.Preferences" },
      "expect": { "screenText": "Settings" }
    }
  ],
  "postconditions": [{ "screenText": "Settings" }]
}
```

The mirror driver may implement `openApp` as Home navigation plus visual target resolution.
A future Appium driver may use a bundle identifier. Neither implementation detail belongs in
the command.

---

## Explicitly out of scope

- Requiring a particular AI model, agent SDK, or automation program.
- Storing commands as opaque recordings tied to one window size or phone layout.
- Allowing generated commands to bypass validation, verification, or confirmation policy.
- Jailbreaking, lock/activation bypass, or operating a device without its owner's consent.
- Autonomous sends, purchases, credential entry, destructive actions, or security prompts.

## Open implementation choices

These are decided by observation during Slice 1, not assumed in advance:

1. Which macOS control API can reliably focus and interact with the iPhone Mirroring window.
2. Whether the mirror exposes useful accessibility elements or only a rendered phone surface.
3. Which visible-state resolver is reliable enough for v1: OCR, template matching, a
   pluggable vision model, or a ranked combination.
4. Which harmless real workflow should become the second acceptance command after Settings.
