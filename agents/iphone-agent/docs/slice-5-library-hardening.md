# Slice 5 — Command Library and Hardening

Completed on 2026-08-19.

## Result

Slice 5 completes the planned reusable-command and hardening layer without changing the
driver-independent execution model. A command can now call another typed command, constrain
its semantic version, preflight the complete dependency tree without actions, recover from a
verified failure, and resume from durable success boundaries.

No new driver was added. The iPhone Mirroring driver remains the only implementation because
the project has not demonstrated a need for another one.

## Delivered

### Versioned command library

- Commands carry a semantic `version`; older documents normalize to `1.0.0`.
- A `call` step may declare `commandVersion` using a semantic-version range.
- `InMemoryCommandRegistry` selects the newest compatible version.
- `DirectoryCommandRegistry` recursively loads validated JSON and YAML command files.
- Recursive calls are rejected with `COMMAND_CYCLE`, and unresolved or incompatible calls
  fail before phone input.
- Child inputs are checked by the same typed input preparation used for top-level commands.

### No-action preflight

`dryRunCommand` expands ordinary calls and recovery commands recursively. Its report includes:

- the exact ordered command/step paths;
- aggregate action and observation capabilities;
- missing capabilities with namespaced step IDs;
- every confirmation path;
- version, lookup, input, and cycle errors; and
- the invariant `actionsExecuted: 0`.

The CLI exposes the same path:

```text
iphone-command dry-run COMMAND --capabilities FILE [--library DIR] [--inputs FILE]
```

Unsupported dry runs return process status `2`, so scripts can distinguish them from a valid
supported report.

### Nested execution, recovery, and resume

- A call receipt keeps its own status, while child steps use stable IDs such as
  `invoke-child:open-settings`.
- The runner preflights the whole command and recovery graph against the active driver's
  capabilities before executing the first action.
- Command-level and step-level preconditions are evaluated before action; postconditions are
  evaluated before success is recorded.
- `recover` runs the named recovery command once, records it under a recovery namespace, and
  retries the failed step once.
- Resume requires the same command ID, command version, and redacted input set.
- Only steps with a durable `succeeded` receipt are skipped. Attempt numbers remain monotonic.
- A failed external, financial, destructive, or credential step is not replayed when its
  commit outcome may be uncertain. Automatic retry/recovery returns
  `COMMIT_OUTCOME_UNCERTAIN`; resume returns `RESUME_INVALID`. Both require explicit
  reconciliation instead.

### Durable visible-state templates

`FileTemplateCatalog` loads a versioned JSON manifest and JPEG files relative to that manifest.
Manifests can record global/per-template confidence and compatibility fields for mirror app
version, OS version, and frame dimensions. Callers can select compatible entries when loading.
Absolute paths, traversal, and symlink escapes are rejected.

Operational screenshots and device-specific templates are deliberately not stored in this
repository. Tests create disposable catalogs and images at run time.

### Mirror-state failures

The driver classifies host-visible state as `ready`, `paused`, `disconnected`, `locked`,
`permission`, `obscured`, or `unexpectedDialog`. It still resumes a visible paused session,
but every other blocked state stops before phone input and includes `details.mirrorState` in
the machine-readable error.

## Verification

The final verification covers protocol normalization, semantic-version selection, recursive
catalog loading, nested dry runs, cycle and capability failures, CLI dry run, nested execution,
preflight failure, recovery, completed-boundary resume, uncertain-commit resume refusal,
durable template loading and path containment, and all mirror-state classifications.

`npm run check` passes all 46 tests, the dependency audit reports zero vulnerabilities, and
the package dry run contains the built CLI, public declarations, and both protocol schemas.

The prior live iPhone Mirroring acceptance proof remains recorded in
[`slice-3-runner-mirror-driver.md`](./slice-3-runner-mirror-driver.md). Slice 5 changes were
validated with deterministic integration tests; no committing phone workflow was introduced.

## Remaining boundaries

1. Mirror-state classification is based on the host accessibility text. Paused and ready
   states were observed live earlier; the other blocked states are covered with deterministic
   fixtures until they can be encountered safely on the real device.
2. Template matching remains JPEG luminance matching. A future OCR or vision resolver can be
   added behind `MirrorObservationResolver` without changing commands.
3. Recovery commands currently receive their own defaults; the protocol does not yet map
   parent inputs into `recoveryCommandId`.
4. Resume refuses uncertain committing steps by design. A future reconciliation protocol must
   prove the external result before it can mark or retry such a step.
