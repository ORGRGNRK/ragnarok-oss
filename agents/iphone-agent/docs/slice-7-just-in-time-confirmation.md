# Slice 7 — just-in-time confirmation

Date: 2026-08-20

Status: **complete and live-verified on the real mirrored iPhone**, including the stale path.

Slice 7 gives the launcher a way to ask a person a question while a command is running, and
binds their answer to the screen they were asked about. It is the gate the previous handoff
named as the highest-value next step, and the one holding back the whole committing category.

## The layer already existed

`HANDOFF.md` framed this as missing confirmation support. It was not. Before this slice:

- `runner.ts` already called `confirmIfRequired` per step, immediately before the action.
- `runtime-types.ts` already defined `ConfirmationProvider`.
- The runner already threw `CONFIRMATION_UNAVAILABLE` when none was configured.

The launcher simply never passed a provider. The missing piece was a **channel to a person while
the runner is blocked mid-run**, not another abstraction. `POST /api/run` is one-shot, so there
was no way to interrupt it and ask.

## Why a native dialog rather than a browser round-trip

The security property runs against adding layers. What is wanted is the shortest possible path
between "the runner is about to commit" and "a person looked at the real screen and said yes".
Every hop added is somewhere a confirmation can be replayed, cached, pre-answered, or spoofed by
page content.

`MacOsDialogConfirmationProvider` raises an OS-level dialog through `osascript`. It blocks the
runner naturally, needs no change to the HTTP model, and cannot be forged by anything in the
launcher page. The alternative — returning a `runId`, parking the promise, publishing
`awaitingConfirmation`, and resolving through a new endpoint — is a state machine, a timeout
policy, and more surface for the same result.

The dialog text is passed as an `argv` item, never interpolated into the script, so a command
name or a label recognized on the phone cannot close a quote and become AppleScript.

**Every outcome other than pressing Approve is a denial:** the cancel button, the Escape key,
the timeout, and any failure to draw the dialog at all. Silence never means yes.

## Binding an answer to a screen

An approval is given for a screen. It must not be spendable on a different one. After the answer
returns, the runner observes the phone again and voids the approval if anything has moved —
`CONFIRMATION_STALE`, and nothing is done.

The hard part is deciding what counts as a change. A mirrored iPhone screen is never still: the
status bar carries a clock that changes every minute and a battery reading on its own schedule.
Comparing frames, or even raw recognized text, would void approvals for reasons that have
nothing to do with what was approved — which would make the whole feature unusable in practice.

`src/screen-binding.ts` therefore drops content known to move on its own and compares what is
left, **including where it sits**: each surviving line becomes `text@x,y` on a 1/64 grid. Same
words in the same places. That implies the tap target has not moved, without needing the driver
to re-resolve targets.

Two filters, deliberately narrow — anything not recognized as volatile is kept, so an unexpected
change voids the approval rather than slipping past:

1. **Positional.** Recognized text within `STATUS_BAR_BAND` of the top of the window.
2. **Content.** Clock readings and battery percentages anywhere on screen.

### `STATUS_BAR_BAND` is measured, not assumed

The first value, 0.06, was wrong, and only live data showed it. On a live 381x824 mirror window:

```
6:10                                       topY 0.0710   status bar clock
General                                    topY 0.1165   navigation title
About                                      topY 0.4345
```

The captured window includes bezel chrome above the phone screen, so the status bar sits lower
in window-normalized coordinates than the phone's own 2% status bar would suggest. At 0.06 the
band sat **above the clock and caught nothing**. The clock was still filtered, but only by the
content pattern — meaning carrier and battery text, which is not clock-shaped, was entering the
binding and would have voided approvals for no reason.

The band is now **0.09**: clear of the clock, well clear of the navigation title. There is a
regression test pinned to the measured position. Do not re-derive this from the phone's screen
geometry; it is a property of the captured window.

## Risk ceiling

A provider raises the launcher ceiling from `reversible` to `external`. `financial`,
`destructive`, and `credential` stay blocked regardless. Each deserves its own decision rather
than arriving as a side effect of this one.

Launcher cards now report **assessed** risk rather than the declared header, so a command whose
individual steps reach higher than its own `safety.risk` can no longer present the safer number.

## Receipts

`ConfirmationReceipt` gained `shown` — the sentence, the risk, and the observation the person
was asked about — and a `stale` outcome. An approval is only auditable next to the screen it was
given for. `describeStep` moved to `src/describe.ts` so the dialog and the authoring preview
produce the same sentence.

`recordStepFailure` previously overwrote `confirmation` with a bare `{required, outcome}` in its
catch block. Correct when the gate recorded nothing richer; after this slice it destroyed
`shown` and `actor` on exactly the denial path where knowing what was displayed matters most.
It now fills in only when the gate recorded nothing, and knows `CONFIRMATION_STALE` is a stop
rather than a failure.

## Live acceptance

`commands/confirm-open-about.json` is a clone of the already-verified `open-settings-about`
with the gate switched on for the final tap. It is declared `reversible` with
`requiresConfirmation: true` on the step, **not** `external`. Tapping About does not reach
outside the phone, and mislabelling risk to make a test convenient would corrode the model this
slice exists to protect.

Verified on the real mirrored iPhone:

| | |
|---|---|
| Preflight | `open-settings-general` no confirmation, `open-about` confirmation required |
| Ordering | step 1 ran with no dialog; the run blocked at step 2 — just-in-time, not at run start |
| Approve | run succeeded, both steps verified, receipt validates against the published schema |
| Deny | run `stopped`, `CONFIRMATION_DENIED`, About never tapped, `actor: macOS dialog` and the full `shown` record kept |
| Volatile filter | the phone clock ticked 6:10 to 6:11 during the 11.3s the dialog was open, and the run still proceeded |

`CONFIRMATION_STALE` was subsequently verified live by Slice 12. Its acceptance-only provider
approves the dedicated reversible fixture and presses Home before returning to this unchanged
gate. The real receipt stopped as stale, and the confirming About tap never reached the driver.
See [slice-12-confirmation-stale-acceptance.md](./slice-12-confirmation-stale-acceptance.md).

## Next

1. A verified swipe implementation, still the oldest gap.
2. Editing and deleting saved commands from the launcher — authoring still only creates.
3. Warn in the launcher when the display is mirrored to an AirPlay screen. That halves capture
   resolution and produces confusing OCR failures that look like command bugs; it cost most of a
   session before it was identified. See the constraint note in `HANDOFF.md`.
