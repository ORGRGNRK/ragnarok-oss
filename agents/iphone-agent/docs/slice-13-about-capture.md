# Slice 13 — Durable About Screenshot Evidence

Completed and live-verified on 2026-08-23.

## Workflow need

The requested routine was the user-visible sequence “Spotlight → About → screenshot → scroll to
the bottom → screenshot.” Sending the literal macOS `Command-Shift-3` shortcut would couple a
portable phone command to one desktop implementation and would capture the whole desktop. The
implemented command preserves the intent: it captures only the mirrored phone and records each
named frame as receipt evidence.

## Delivered

- `capture` is a read-only runner step with a required human-readable `label`.
- Preflight requires the existing `screenshot` observation capability but no new driver action.
- A capture step materializes its current observation before a subsequent observation can replace
  the mirror adapter's temporary frame.
- `LocalScreenshotArtifactSink` writes private (`0600`) PNGs outside the repository under
  `~/Desktop/iPhone Command Captures/<receipt-id>/`.
- `commands/capture-about-top-bottom.json` opens About through Spotlight, resets Settings'
  remembered scroll position, captures the top, performs two normalized bounded upward swipes,
  verifies `Certificate Trust Settings`, and captures the bottom.
- The published command and receipt schemas gained only the reviewed `capture` entries; the
  schema-format fingerprints were intentionally refreshed after diff review.

## Verification

- `npm run check`: schema guard passed and 97/97 automated tests passed.
- Live run: seven of seven steps succeeded against the real iPhone Mirroring app.
- The top artifact visibly contains `iOS Version`.
- The bottom artifact visibly contains `Certificate Trust Settings`.
- Both artifacts remained readable after the mirror port disposed its temporary capture folder.
- The signed launcher was started and its live command catalog included
  `Capture iPhone About Top and Bottom`.

The screenshots include device identifiers because that is what the About page displays. They
remain local and are not added to git or sent to an online service.
