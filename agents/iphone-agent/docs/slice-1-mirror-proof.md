# Slice 1 — iPhone Mirroring proof

Date: 2026-08-19

Status: **passed**

This is an observation report, not a driver design. The proof used a local computer-control
bridge to operate Apple's iPhone Mirroring app. That bridge is replaceable and is not part of
the portable command contract.

## Environment verified

- macOS 27.0 (build 26A5406e)
- iPhone Mirroring 2.0
- Bundle identifier: `com.apple.ScreenContinuity`
- The mirror initially reported `Connection Paused`; choosing `Resume` connected it and
  exposed the phone's live Home Screen.

## Proof results

| Requirement | Result | Observation |
|---|---|---|
| Find and focus the mirror | Pass | The `iPhone Mirroring` window was found, raised, and reported as the focused UI element. |
| Capture visible phone state | Pass | The automation surface returned screenshots before and after each action. |
| Safe tap | Pass | A coordinate tap focused Settings Search without changing a setting or causing external state. A later coordinate tap selected a Settings search result. |
| Type into a harmless field | Pass | Text entered through iPhone Spotlight produced visible search results; text also entered into Settings Search. |
| Swipe | Pass | A vertical scroll gesture visibly moved a Settings page and the inverse gesture restored its earlier position. |
| One safe interaction through the mirror | Pass | Multiple reversible interactions succeeded, satisfying the Slice 1 gate. |

## Observed control surface

The macOS accessibility surface exposed the iPhone Mirroring window and its menus, but it did
not expose the rendered iPhone controls, labels, or rows as accessibility elements. The phone
surface must therefore be treated as rendered content on this machine unless a different API
is separately proven.

The app exposed these navigation commands:

- Home Screen (`Command-1`) — verified
- App Switcher (`Command-2`) — exposed but not exercised
- Spotlight (`Command-3`) — verified
- Control Center — exposed in the View menu but not exercised

Typing and key presses were accepted after the corresponding phone field had focus. Vertical
scrolling worked through the mirror window. A horizontal Home Screen scroll did not produce a
visible state change during this proof, so horizontal paging is not yet a verified capability.

## Driver constraints discovered

1. **Do not rely on an iPhone accessibility tree.** Only the host window and menus were
   observable through the accessibility surface used in this proof.
2. **Do not map screenshot pixels directly to action coordinates.** The captured preview was
   heavily downsampled (about 47 by 150 pixels at the largest tested view), while successful
   taps used a larger action-coordinate space. The driver must discover the phone-content
   bounds and an explicit transform before acting.
3. **Keep every coordinate inside verified phone bounds.** The proof used conservative points
   on reversible Settings and Spotlight surfaces; production code needs a hard bounds check.
4. **Verify after every action.** The phone surface supplied screenshots but no semantic state,
   so a successful input call alone is not evidence that the intended phone action occurred.
5. **Treat gestures independently.** Vertical scrolling is verified. Horizontal Home Screen
   paging remains unverified and must not be advertised as supported yet.
6. **Handle resumable connection state.** `Connection Paused` is a normal observed state with a
   `Resume` control, distinct from a hard connection failure.

## Capability snapshot for the next slice

| Capability | Status |
|---|---|
| Window discovery and focus | Verified |
| Screenshot observation | Verified, low-resolution preview |
| Coordinate tap | Verified, transform still required |
| Keyboard typing | Verified when a field is focused |
| Home navigation | Verified |
| Spotlight navigation | Verified |
| Vertical swipe/scroll | Verified |
| Horizontal swipe/page | Unverified |
| Phone-level accessibility elements | Not exposed by the tested surface |
| OCR or visual target resolution | Not selected or tested |
| Locked, obscured, permission, and unexpected-dialog detection | Not yet tested |

## Slice 2 handoff

The Slice 1 gate is satisfied. Protocol and validator work can begin without choosing the
final visual resolver. The future mirror driver should advertise only the capabilities above
that are verified, and should keep target resolution and coordinate transforms behind the
driver interface.
