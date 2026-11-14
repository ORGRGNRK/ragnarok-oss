# Slice 2 — protocol and validator

Date: 2026-08-19

Status: **complete**

Slice 2 turns the draft command contract into a deterministic TypeScript package. It does not
control the Mac or iPhone; execution begins in Slice 3.

## Delivered

- Draft 2020-12 command schema at `schemas/command.schema.json`
- Draft 2020-12 execution receipt schema at `schemas/receipt.schema.json`
- Canonical `0.1` TypeScript types for commands, steps, targets, conditions, capabilities,
  inputs, safety assessments, and failures
- Strict JSON and YAML parsing
- Normalization of optional collections and the default `stop` failure behavior
- Typed runtime input validation and `${input.name}` variable resolution
- Secret input redaction for receipts
- Required-capability collection and fail-fast driver capability checks
- Risk-floor safety assessment with step-level confirmation locations
- Valid, invalid, unsupported, and confirmation-required fixtures
- Automated build and test scripts

## Public API

The package exports these main operations from `src/index.ts`:

| Operation | Purpose |
|---|---|
| `parseCommand` | Parse JSON or YAML, normalize it, and validate the command. |
| `validateCommand` | Validate an already-parsed command value. |
| `prepareCommand` | Validate runtime inputs, resolve variables, revalidate the result, and return redacted receipt inputs. |
| `requiredCapabilities` | Derive the driver actions and observation features a command requires. |
| `checkCapabilities` | Return a structured supported/unsupported result for a driver session. |
| `assertCapabilities` | Fail early with `UNSUPPORTED_CAPABILITY` when requirements are missing. |
| `assessSafety` | Compute effective command/step risk and the steps requiring confirmation. |
| `validateReceipt` | Validate a structured execution receipt. |
| `getCommandSchema` / `getReceiptSchema` | Return defensive copies of the published schemas. |

All protocol failures use `CommandProtocolError` with a stable code, message, optional JSON
Pointer path, and optional structured details.

## Important semantics

1. YAML is only an authoring format. `parseCommand` normalizes it to the same in-memory form
   as JSON.
2. Missing required inputs, unknown inputs, wrong types, duplicate step IDs, invalid defaults,
   and unresolved variables fail before execution.
3. Secrets cannot have embedded defaults. Runtime secret values are available to execution
   but become the literal `[REDACTED]` in receipt inputs.
4. Variable substitution happens everywhere except the input definitions. The resolved
   command is validated again, so a typed value cannot land in an incompatible action field.
5. Capability checks distinguish driver actions from runner-owned actions such as `assert`,
   `waitFor`, `confirm`, and `call`.
6. `requiresConfirmation: false` never lowers the risk implied by the action, step, command,
   or machine floor. External, financial, destructive, and credential risks require
   confirmation.
7. Receipt screenshots and logs are references, not embedded binary payloads.

## Verification

`npm run check` completes a strict TypeScript build followed by 10 automated tests. The tests
cover:

- both published schemas;
- the first acceptance command;
- YAML normalization and runtime variables;
- invalid command rejection;
- missing, unknown, and incorrectly typed inputs;
- secret redaction;
- required-capability derivation;
- fail-fast unsupported results;
- confirmation placement on an external committing step; and
- successful and incomplete terminal receipts.

The dependency audit reported zero known vulnerabilities after installation.

## Slice 3 boundary

Slice 3 may now implement the driver interface and deterministic runner against these types.
It must not put mirror coordinates, macOS shortcuts, OCR details, or computer-control library
calls into command documents. The runner must write receipt state around each single action;
the mirror driver must advertise only the capabilities actually verified in Slice 1.
