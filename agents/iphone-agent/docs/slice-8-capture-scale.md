# Slice 8 — capture-scale measurement

Date: 2026-08-20

Status: **complete**, verified live at full scale. The degraded path is covered by automated
tests using the real measured numbers; a live re-run with the Mac mirrored to a television is
still worth doing.

Slice 8 makes an observation report how much detail it actually carried, so that a text check
failing for lack of pixels stops looking like a broken command.

## What went wrong first

Slice 7's live acceptance test failed on `open-settings-general`. The command had worked
perfectly — the phone was on the General page — but OCR returned `AbLKrt` for `About` and
`softY4are uwlates` for `software updates`. The same failure reproduced on the *unchanged*
`open-settings-about` command, which ruled out the new code.

The cause was not in this package at all. The Mac was mirroring its display to a television over
AirPlay, which makes the television the master display and drops the whole desktop to 1920x1080
non-Retina. `screencapture` then writes 1 pixel per point instead of 2. Settings row labels land
around 14 pixels tall, right at the floor of what Vision can read.

Nothing announced this. It is not a fact about the package, it is not in any handoff, and it
could not have been in one: it changed because someone got tired of working in their room and
moved to the living room.

## Why the obvious fix was the wrong one

The first instinct was to detect AirPlay mirroring — check `system_profiler SPDisplaysDataType`
for `Mirror: On` at startup and warn. That fails twice:

1. It infers from configuration rather than measuring the result, so it has to enumerate causes.
   Sidecar, an external 1080p monitor, screen sharing, and a plain resolution change all produce
   the same degradation and would each need their own detection.
2. It is a startup check for something that can change **mid-session**. Casting to a television
   halfway through a run silently degrades every capture after that point.

## What it does instead

`screencapture` is asked for a rectangle in points and writes a file in pixels. The ratio is the
answer, and it is already sitting in the file that was just written.

`captureScale` in `src/macos-mirror-port.ts` reads the PNG's `IHDR` width — the first 24 bytes —
and divides by the requested width. It never looks at the display list. It cannot go stale, it
does not care why the scale dropped, and it re-measures on every single capture.

The reading travels as `captureScale` on `DriverObservation`, so it lands in the receipt on every
`before` and `after`. Past failures become diagnosable after the fact, not only live.

When a step's verification fails, `verifyStep` appends an explanation if the scale was below 2 —
every Mac that can run iPhone Mirroring has a 2x display. It appends nothing when the scale is
healthy or unmeasured, so this is not a standing warning; it speaks only when it is relevant.

```
Step open-settings-general verification failed: observed app does not match; screen text does
not contain "About" The screen was captured at 1x instead of 2x, so there may not have been
enough detail to read it. Check whether this Mac's display is being mirrored or extended to
another screen.
```

## Verified

- 76 automated tests, including the real measured values: a 381-point window capturing 762
  pixels reads 2, and the actual 449-pixel capture from the mirrored session reads 1.
- The scale check refuses to guess — no PNG signature, a short buffer, or a zero-width window
  all return `undefined`, and `undefined` never produces a warning.
- Live on the real phone with mirroring off: `captureScale = 2` recorded on all four
  observations of `open-settings-about`, run succeeded.

## The general lesson

Prefer a check that **measures the artifact** over one that infers from configuration, and
prefer a check in the execution path over a line in `HANDOFF.md`. The note about AirPlay written
during slice 7 was true and would not have helped, because it required a future reader to think
of it at the right moment. This check fires by itself.
