# Slice 12 — deterministic live CONFIRMATION_STALE acceptance

Date: 2026-08-21

Status: **complete and live-verified on the real mirrored iPhone.**

## Result

Slice 12 closes the last live proof gap in the just-in-time confirmation gate without changing
the gate, screen binding, native dialog, command schema, receipt schema, or launcher behavior.

`npm run accept:confirmation-stale` runs an acceptance-only command and provider against the real
iPhone Mirroring driver. It opens General, resets Settings' remembered scroll position, confirms
that About is visible, then auto-approves the reversible About step. Before that provider returns
to the unchanged runner, it presses Home through the real mirror. The runner must re-observe the
new live screen and void the approval before delivering the About tap.

## Why the harness is separate

The native dialog's Approve and Deny paths were already proven live in Slice 7. Requiring a
person to move the phone while that modal held the runner was the source of nondeterminism, not
the behavior under test. This harness therefore injects approval only for its dedicated
reversible fixture and deterministically stages the screen transition itself.

The fixture lives at `fixtures/live/confirmation-stale.json`, not in the launcher's `commands/`
directory. It cannot appear as an ordinary saved command or accidentally run without its staging
provider.

## Acceptance contract

The command has three setup actions and one confirming action:

1. Open General and verify Settings plus the General title.
2. Swipe down twice to remove dependency on Settings' remembered scroll position.
3. Verify About is visible at the known boundary.
4. Park before the confirming About tap.

After staged Home navigation, the harness requires all of the following:

- the receipt validates against the published receipt schema;
- terminal status is `stopped` with `CONFIRMATION_STALE`;
- the final confirmation outcome is `stale`;
- `open-about` has no after-observation and no resolved target; and
- only the three setup actions reached `PortableDriver.execute`.

Any mismatch exits nonzero and prints only structural receipt facts, never recognized phone text.

## Live proof

The real run passed on 2026-08-21:

```text
PASS — CONFIRMATION_STALE; open-about never reached the driver
(executed: open-settings-general, reset-general-toward-top-1, reset-general-toward-top-2).
```

A fresh visual observation after the run showed the real phone on its Home Screen, confirming
the staged transition happened. The final About tap did not run.

The full check now passes 92 automated tests. Three slice-specific tests verify that staging
happens only after approval and that the live fixture preflights with exactly one confirmation
path and zero actions.

## Boundary preserved

This result is evidence about the existing confirmation behavior, not a reason to widen it.
Financial, destructive, and credential commands remain disabled. The launcher still uses the
native macOS dialog, and every outcome other than its Approve button remains a denial.
