# iPhone Commands Launcher

Last updated: 2026-08-24

Status: **built, installed, and live-verified.**

## Use it

1. Double-click **iPhone Commands** on the Desktop. The signed app is installed in your user
   Applications folder.
2. Keep iPhone Mirroring available.
3. Choose a saved command such as **Open iPhone About** or **Scroll Settings General** and press
   **Run**.
4. On the first run, allow **iPhone Commands** under both **Accessibility** and
   **Screen Recording** in **System Settings → Privacy & Security**. Return to the open
   launcher and press **Run** again.

The app starts a private local page and opens it in the default browser. Starting the app a
second time reopens the existing launcher instead of starting a duplicate.

While Tailscale and the launcher are both running, the same interface is available to this
tailnet at `https://<your-mac>.<tailnet>.ts.net/`. The phone still executes on
this Mac; tailnet access does not make the Mac or iPhone Mirroring optional.

## Delivered

- Double-clickable, ad-hoc-signed macOS app wrapper with stable bundle ID
  `co.rgnrk.iphone-commands`.
- Responsive local interface with saved commands, Run controls, live status, friendly setup
  errors, and verified success receipts.
- Safe built-in commands for opening Settings, opening About, verified General-page scrolling,
  and durable About-page screenshot evidence.
- `MacOsMirrorControlPort` for focusing iPhone Mirroring, keyboard controls, bounded taps,
  host-state capture, and screenshots.
- macOS Vision OCR adapter for verifying visible screen text and locating text targets without
  an online service.
- Native bounded-tap and continuous-scroll helpers for reliable interaction with the mirrored
  phone.
- Loopback server bound to `127.0.0.1`, strict content-security policy, no CORS, a random
  per-launch mutation token, request-size bounds, and single-command concurrency.
- Tailnet-only HTTPS proxy through Tailscale Serve. The loopback server accepts only local Host
  names plus the exact Tailscale DNS name discovered at startup; discovery failure leaves it
  local-only.
- Demo mode for end-to-end interface testing without phone actions.

Swipe is advertised by the standalone launcher after Slice 10's live proof. Commands keep
direction, start, and distance normalized; the driver clamps and translates them before the
native continuous-scroll helper runs. See
[slice-10-verified-swipe.md](./slice-10-verified-swipe.md).

The `capture` runner step records the current mirror observation without sending another phone
action. In live mode the launcher copies the temporary frame to
`~/Desktop/iPhone Command Captures/<receipt-id>/` before the next observation can replace it.
Files are mode `0600`; screenshot data remains local. See
[slice-13-about-capture.md](./slice-13-about-capture.md).

## Creating a command

The **Describe a safe routine** panel turns plain language into a saved command. It uses the
local rule-based author only; there is no AI provider and no network call. **Check it** shows
the plain-language steps and runs the recursive no-action preflight. **Save** stays disabled
until that preflight is clean, and re-disables the moment the text is edited.

Saving is refused for a duplicate command id, a risk above `reversible`, or any capability the
launcher does not advertise. The browser never submits a command document; `/api/save` re-authors from the
same text, so what lands in `commands/` is exactly what was previewed. See
[slice-6-launcher-authoring.md](./slice-6-launcher-authoring.md).

## Safety behavior

`read` and `reversible` commands run directly. `external` commands require the native
just-in-time confirmation gate at their final committing step. Financial, destructive, and
credential commands remain disabled.

Every run performs the recursive no-action preflight before connecting to iPhone Mirroring.
The existing runner still requires observation, postcondition verification, and a valid
receipt before the interface reports success.

## Verification

- Strict TypeScript build passes.
- All 98 automated tests pass.
- Desktop and 390-pixel responsive layouts were visually inspected.
- The Run button completed its full demo flow and displayed a verified success receipt.
- The packaged app launched the real live-mode server successfully.
- The real iPhone Mirroring window was observed as ready and not paused.
- The installed app correctly surfaced the initial Screen Recording block as a one-time setup
  message.
- The final live acceptance opened the real Settings app, recognized its existing General
  subpage as Settings, produced one verified step, and displayed `Open Settings worked`.
- The multi-step live acceptance opened Settings directly to General, located and tapped
  About from recognized screen text, verified `iOS Version`, produced two verified steps,
  and displayed `Open iPhone About worked`.
- The authoring live acceptance created `Open Notes` from the text
  `open Notes and check for Notes`, saved it, ran it on the real mirrored iPhone, and displayed
  `Open Notes worked` with one verified step.
- The swipe acceptance reset General's remembered scroll position, verified About, swiped upward,
  verified Trackpad & Mouse, and completed all four steps with a successful receipt.
- The deterministic stale-confirmation acceptance moved the real phone to Home after its
  acceptance-only approval; the unchanged runner stopped with `CONFIRMATION_STALE`, and the
  confirming About tap never reached the driver.
- The About capture acceptance reset the real page to `iOS Version`, materialized a named top
  PNG, reached `Certificate Trust Settings` after two bounded swipes, and materialized a named
  bottom PNG. All seven receipt steps passed.
- From `alexus`, the tailnet HTTPS endpoint returned the live macOS command catalog and accepted
  a token-authenticated `Open Settings` dry-run with `actionsExecuted: 0`.
