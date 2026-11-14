# Control Center lock dispatch

Investigation and implementation ran as the owner's OS user, in the isolated
`control-center-lock-20261103` worktree.

## Evidence examined

- Read AGENTS.md, all of Controls/RagnarokControls.swift, Controls/project.yml,
  Controls/Info.plist, Controls/Controls.entitlements, App.swift, Auth.swift,
  make-app.sh and Package.swift. Read the selftest entry and tail before adding
  the control regression case.
- Both old tiles used OpenURLIntent with custom `ragnarok-cc` schemes. Apple's
  OpenURLIntent documentation explicitly excludes custom URL schemes:
  https://developer.apple.com/documentation/appintents/openurlintent
- Apple's control guide specifies OpenIntent and shared app/extension membership:
  https://developer.apple.com/documentation/WidgetKit/Creating-controls-to-perform-actions-across-the-system
- Installed executable existed at ~/Applications/Ragnarok.app/Contents/MacOS/Heimdall;
  installed commit resource was ef92b7c before installation.
- Read the last eight scrubbed access rows. They included a Control Center lock
  at 2026-11-04T03:18:27Z and Touch ID unlock at 03:18:41Z. This supports delayed
  delivery of the parent's direct URL test; it does not demonstrate a tile click.
- Queried scrubbed Heimdall error/fault events over 15 minutes. Output was truncated;
  only the returned subset was reviewed. Visible rows included temporary selftest
  SQLite cleanup warnings and WebContent/SwiftUI errors; these do not establish a
  control dispatch failure.
- Computer Use identified Ragnarok as running, but denied access to its UI with
  “Computer Use was not approved to use Ragnarok.” No tile was clicked and no
  window lock-state observation was possible. No alternate UI access was attempted.

## Change

Preserve both control kind identifiers and deep links. The two tiles use a shared
OpenIntent with exactly `main` and `locked` destinations. The app uses one Gate
independently of window lifetime, locks before presenting its window, and remembers
presentation requests arriving before the open-window action is installed.
Unexpected extension-side intent execution throws a descriptive error.

Explicit lock invalidates pending biometric/key results, cancels LAContext,
records already-locked requests, and suppresses automatic authentication after
locking. A new manual hardware/Touch ID request is still allowed. No password
fallback or unlock action was added. These are defensive fixes; a real pending
completion race was not reproduced.

SwiftPM builds now extract app intent metadata as well as extension metadata.
The metadata check examines the actual packaged JSON for both modules and verifies
OpenEntity routing, foreground opening, and the exact destination allowlist.

## Validation and limits

The extension compiled successfully. App and extension metadata checks passed.
The full built-app selftest passed with normal macOS access, including dispatch
order and gate invalidation checks. A sandboxed selftest had failed two unrelated
checks (explain-note save and photo-picker types); both passed outside the sandbox.

The regression uses an isolated Gate and injected window/audit callbacks; it does
not authenticate, inspect the real user's protected data, or prove real window
presentation. Actual tile clicks, background/closed-window UI behavior and cold
launch through the existing launcher handoff remain **Unverified**. The launcher
still hands off and exits when the app is started directly; intent delivery across
that cold-launch boundary requires runtime verification. Launcher and known-good
were not changed, and the running app was not restarted.
