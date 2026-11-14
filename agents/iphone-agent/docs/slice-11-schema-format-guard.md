# Slice 11 — schema format guard

Date: 2026-08-21

## Result

Slice 11 adds a pre-build guard for the two published JSON Schemas. `npm run check` now runs
`check:schema-format` before TypeScript compilation and tests. The guard verifies that:

- every `schemas/*.schema.json` file is valid JSON;
- the discovered schema list exactly matches the review lock; and
- every schema's exact bytes match its reviewed SHA-256 fingerprint.

The guard uses exact-byte fingerprints because the existing schemas have different intentional
layouts. The command schema keeps compact leaf objects while the receipt schema is fully expanded.
Forcing both through `JSON.stringify` or a new formatter would rewrite hundreds of lines and
destroy the history this guard exists to preserve.

## Review workflow

For an intentional schema change:

1. Make the smallest possible edit without parsing and serializing the whole document.
2. Run `npm run check:schema-format` and expect the fingerprint failure.
3. Inspect the schema diff and confirm it contains no mechanical formatting churn.
4. Run `npm run accept:schema-format` to record the reviewed new bytes.
5. Run the complete `npm run check` workflow.

The accept command is deliberately explicit. It is not a formatter and must not be used before
reviewing the schema diff.

## Acceptance

Automated coverage proves:

1. Both current published schemas pass without changing either file.
2. Parsing and serializing a copy of the compact command schema into expanded two-space JSON
   fails with the affected filename and recovery instructions.
3. Refreshing the lock after review makes that isolated copy pass again.
4. Adding a new `*.schema.json` file without a lock entry fails.

The full check runs the format guard, strict TypeScript build, and all 89 tests. This slice does
not change the schemas, validator, runtime, signed launcher, or iPhone behavior.

## Next boundary

The planned implementation slices are complete. At the end of Slice 11,
`CONFIRMATION_STALE` remained the clearest live proof gap. Slice 12 closed it with a dedicated
fixture and acceptance-only provider that stages a real screen change without altering the
runner or native dialog; see
[slice-12-confirmation-stale-acceptance.md](./slice-12-confirmation-stale-acceptance.md).
