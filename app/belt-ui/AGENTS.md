# AGENTS.md — Conveyor Mac app

## Current state / Next step
- SwiftUI Mac app over the conveyor bash belt. Last code commit 5d58eb4 (2026-10-26).
- Built 2026-10-26 and stub-tested only (fake AI scripts, no real AI run): files in and out (`--attach`, per-task outputs), remote Add and Check setup fixes, "Planning first" (Planning column, planner/critic pickers).
- `docs/PLAN-one-app.md` is a plan only, nothing built: combine Conveyor and LocalAI into one App-Store-first Mac app.
- 2026-10-26: no app code change for BLOCKED tasks. The belt now parks a BLOCKED task that only waits on a HUMAN step in human/, so it shows in Needs you with the normal Approve button. The Dead ends tray still has no action. `checks/files-check.sh` now finds the older-format real task in whichever tray it is in (40/40).
- Next step: the owner's decisions and open checks listed in `docs/PLAN-one-app.md`; separately, one real end-to-end run of a planned task.

**Handoff rule:** before handing off or ending a session, commit, push if a remote exists, and update the block above.

## Project
- Build: `./make-app.sh` builds `build/Conveyor.app` (ad-hoc signed; giving it to others needs a Developer ID signature and notarization).
- Sources: `Sources/Conveyor/Belt.swift` (model, log parser, run, approve), `Remote.swift` (SSH copy, approve, add), `Views.swift` (screens), `Files.swift`.
- Checks: `checks/files-check.sh` builds and runs `checks/files-check.swift` in a temp folder (no real SSH, no AI). It uses the belt at `$BELT` (default `~/conveyor`).
- Specs: `docs/SPEC-planning.md` (planning step), `docs/PLAN-one-app.md` (product plan).

## Rules
- Belt rules are binding: never tick a checklist box except a `verify: HUMAN` box after the person's real yes; never edit task files in `running/` or `verify/`.
- Don't approve, tick or requeue anything on a connected belt without the owner's explicit yes. A queued task gets run and spends AI usage.
- Avoid real-AI test runs unless the owner asks.
- Don't push, make the repo public, or delete anything without asking.
