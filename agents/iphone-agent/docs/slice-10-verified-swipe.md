# Slice 10 — verified swipe support

Date: 2026-08-21

## Result

Slice 10 enables the existing portable `swipe` action in the signed local launcher. Commands
describe a direction, an optional normalized starting point, and an optional normalized distance.
The mirror driver clamps the path to an 8% inset, requires at least 5% actual movement, converts
the normalized endpoints to the current mirror-window bounds, and passes only the resulting path
to the macOS adapter.

The native helper anchors the pointer inside iPhone Mirroring and emits continuous Core Graphics
pixel scroll events. This matches the input class macOS normally derives from a trackpad gesture.
A mouse-down/drag/mouse-up implementation was tried first; the live post-action frame proved it
only moved the Mac pointer and did not scroll the iPhone, so that path was removed.

## Safety and portability boundary

- Saved commands contain no AppleScript, Core Graphics details, or raw Mac pixel coordinates.
- Start and end points are clamped away from the mirror window's edges.
- A gesture that cannot move at least 5% in its requested direction fails before native input.
- `swipe` remains classified as reversible.
- Launcher authoring enables Save only after the same capability preflight used by execution.
- Success still requires a post-action observation; sending scroll events alone is not proof.

## Acceptance

The installed signed app ran `commands/scroll-settings-general.json` against a mirrored iPhone 16
Pro Max on iOS 27.0:

1. Open General through Spotlight and verify Settings plus the General title.
2. Swipe down twice to remove dependency on Settings' remembered scroll position.
3. Verify the top row, About, is visible.
4. Swipe up from normalized `(0.50, 0.78)` by `0.55`.
5. Verify Trackpad & Mouse is visible, proving content moved beyond the original top rows.

The final execution receipt succeeded with all four command steps verified. The launcher UI also
showed the durable **Scroll Settings General** command and accepted `swipe up` as a saveable
authored routine without touching the phone during preview.

The strict TypeScript build, Swift typechecks, and all 86 automated tests pass.

## Next boundary

Swipe is now a verified driver capability. The next recommended slice is a canonical-format check
for `schemas/*.json` in `npm run check`, preventing accidental full-file schema rewrites. That
guard was completed in Slice 11.
