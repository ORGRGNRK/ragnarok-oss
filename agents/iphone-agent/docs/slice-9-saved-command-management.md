# Slice 9 — saved command management

Date: 2026-08-21

## Result

Slice 9 adds editing and deletion for commands created inside the launcher. Built-in commands
remain read-only. The portable command schema and phone driver are unchanged.

An edit starts from the original `Authored from:` text, re-runs the deterministic author,
validator, safety assessment, and dry-run preflight, then replaces the exact backing file. An
edit cannot silently change command identity; a routine that produces a different command id
must be saved as a new command instead.

Deletion is offered only for launcher-authored commands. The service re-reads the exact backing
file and verifies its command id and authoring provenance before unlinking it. The launcher shows
a named confirmation dialog before its final Delete button.

## Safety boundary

- The browser still submits plain language, never a command document.
- Edit and delete routes require the per-launch mutation token.
- Built-in commands are rejected by the service even if a caller bypasses the UI.
- A changed or unexpected backing file fails closed.
- Registry and launcher state change only after the filesystem operation succeeds.

## Acceptance

The isolated launcher UI acceptance test:

1. Created `Press Home` from `press home`.
2. Entered Edit mode and changed its source to `press home.`.
3. Revalidated and saved the edit.
4. Ran the edited command in demo mode and received `Press Home worked` with one verified step.
5. Opened the named `Delete Press Home?` confirmation dialog.
6. Deleted the temporary command through the protected local API and reloaded the launcher.
7. Verified the temporary command disappeared and the built-in `Open Settings` command remained
   without an Edit control.

The strict TypeScript build, JavaScript syntax check, and all 84 automated tests pass.

## Next boundary

Saved-command creation and management are now complete. The next feature candidate is a verified
swipe implementation, which would unlock authored scrolling routines without changing the
command format.
