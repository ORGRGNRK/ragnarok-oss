# Slice 6 — launcher command authoring

Date: 2026-08-20

Status: **complete and live-verified on the real mirrored iPhone.**

Slice 6 lets a person create a saved command from the launcher instead of hand-writing JSON.
It adds no new portable action, no new driver capability, and no online service. Authoring is
the existing local rule-based provider, reached through the existing validator, safety policy,
and recursive preflight.

## Delivered

- `LauncherService.author(text)` returns a proposal: the command identity, plain-language
  steps, the preflight verdict, and `actionsExecuted: 0`. Nothing is written and the phone is
  never touched.
- `LauncherService.save(text)` re-authors from the same text and writes the command only after
  every gate passes.
- `LauncherService.canAuthor()` so the interface hides authoring when saving is not configured.
- `POST /api/author` and `POST /api/save`, both behind the existing per-launch mutation token.
- An authoring panel in the launcher with a preview, a Save button that stays disabled until a
  clean preflight, and re-disabling on any edit to the text.
- One new local authoring pattern: `open <app> and check for <text>`.

## Why the new pattern exists

The launcher verifies through macOS Vision OCR of the mirrored screen. `inferVisibleApp` in
`src/macos-vision-resolver.ts` recognizes **only Settings**, so `app` is `undefined` for every
other app, and the plain `open <app>` pattern verifies by looking for the app's own name in
recognized screen text — which many apps never render.

`open <app> and check for <text>` lets the author name text that is actually on the resulting
screen, so the saved command can prove it worked instead of failing verification on a screen
that opened correctly. This is a limit of the current resolver, not of the protocol.

## Gates that must hold before Save

`saveBlockedReason` refuses, in order:

1. no configured commands directory;
2. an id already held by a saved command;
3. a risk above `reversible`;
4. any confirmation path anywhere in the expanded command when no confirmation provider is
   configured; and
5. any capability the launcher does not advertise.

At the time of Slice 6, rule 5 was why `swipe up` authored and previewed but could not be saved:
swipe was a valid portable action that the launcher did not yet advertise. Slice 10 added a
live-verified gesture path, so swipe now passes this gate. The gate itself remains necessary; it
prevents the interface from growing cards the active driver can never run.

## Design decisions worth keeping

- **The browser never submits a command document.** `/api/save` takes the same text and
  re-authors it. The provider is deterministic, so what is saved is exactly what was previewed,
  and the interface cannot inject an arbitrary document into the command folder.
- **File names come from the command id's final segment only**, are matched against
  `^[a-z0-9][a-z0-9-]*$`, and the resolved path must sit directly inside the command folder.
- **Writes use `wx`**, so an unknown file already in the folder is never clobbered.
- **A refused request is a 4xx, not a 500.** `statusForError` maps `PARSE_ERROR`,
  `SCHEMA_INVALID`, `UNSUPPORTED_CAPABILITY`, and `CONFIRMATION_UNAVAILABLE` to 400.

## Verification

- Strict TypeScript build passes.
- 59 automated tests pass, 7 of them new: preview without phone action, save then run, refusal
  of an unsupported action, refusal of a duplicate id, refusal to clobber an unknown file,
  rejection of an ambiguous request, and token and no-directory behavior on both routes.
- Both Swift helpers pass `swiftc -typecheck`.
- A demo-mode server exercised the whole flow over HTTP: 403 without the token, a saveable
  proposal with `actionsExecuted: 0`, a blocked `swipe up`, a 400 on `send a text to Mom`, a
  successful save that wrote `open-notes.json` and appeared in the command list, a refused
  duplicate save, and a `succeeded` receipt when running the newly authored command.
- The panel was visually driven in a browser at 1100 px: preview, enabled Save, saved
  confirmation with the new card in the list, and the amber blocked state for `swipe up`.

## Live acceptance

Passed on 2026-08-20 through the installed app against the real mirrored iPhone.

| Stage | Result |
|---|---|
| Typed | `open Notes and check for Notes` |
| Preview | `Open Notes on your iPhone, then check that the screen shows "Notes"` |
| Save | Wrote `commands/open-notes.json` at mode `600`; card appeared, list went to 3 saved |
| Run | Home, Spotlight, typed `Notes`, opened it, OCR verified `Notes` |
| Receipt | `Open Notes worked` — **1 verified step**, connection `Connected` |

The saved command contains no coordinates, no AppleScript, and no Mac-specific detail. It is a
portable document that any future driver could execute.

OCR did recognize `Notes` on the real Notes screen, so the `open <app> and check for <text>`
pattern verified as intended. Had it not, the correct response would have been to author the
routine against text the phone actually renders, not to loosen verification.

## Note on driving the panel from an automation harness

During live testing, synthetic pointer clicks from a browser-automation harness landed off
target after the command list grew and shifted the layout; a real DOM click on the same button
worked immediately. This was a harness artifact, not a launcher defect — the panel responds
normally to ordinary clicks and to Enter in the text field.
