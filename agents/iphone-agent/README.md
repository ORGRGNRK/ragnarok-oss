# iPhone Commands

Portable, AI-agnostic and automation-program-agnostic commands executed through an iPhone
mirror.

This project separates the command from the thing that authors it and the thing that runs
it:

```text
any author -> portable command -> policy-aware runner -> mirror driver -> iPhone
```

An author may be a person, a script, a conventional application, or any AI. The first driver
targets Apple's iPhone Mirroring app on macOS. See [PLAN.md](./PLAN.md) for the command
contract, safety model, and delivery sequence.

Slice 1's live mirror proof passed on 2026-08-19. The verified capabilities and limitations
are recorded in [docs/slice-1-mirror-proof.md](./docs/slice-1-mirror-proof.md).

Slice 2's portable protocol and validator are implemented. They provide:

- canonical Draft 2020-12 JSON Schemas for commands and receipts;
- JSON and YAML parsing with canonical normalization;
- typed runtime input resolution and secret redaction;
- driver capability negotiation before execution;
- safety classification that cannot lower semantic or machine risk floors; and
- fixtures and automated tests for valid, invalid, unsupported, and confirmation-required
  commands.

Slice 3's deterministic runner and iPhone Mirroring adapter are also implemented. The live
`Open Settings` acceptance command passed through the real mirror on 2026-08-19. See
[docs/slice-3-runner-mirror-driver.md](./docs/slice-3-runner-mirror-driver.md).

Slice 4 adds the `iphone-command` authoring CLI:

```sh
# Interactive, non-AI guided creation
npm run cli -- create --format yaml --output open-settings.yaml

# Conservative local text patterns; no API or network call
npm run cli -- from-text "open Settings" --format json

# Validate or convert existing commands
npm run cli -- validate open-settings.yaml
npm run cli -- convert open-settings.yaml --to json --output open-settings.json
```

Existing output files are protected unless `--force` is supplied. See
[docs/slice-4-command-authoring.md](./docs/slice-4-command-authoring.md).

Slice 5 adds the reusable command library and hardening layer:

- semantic command versions and version-range selection for `call` steps;
- in-memory and directory-backed command catalogs;
- recursive, no-action dry runs covering nested and recovery commands;
- namespaced receipts, conservative resume, and bounded recovery execution;
- durable JPEG template manifests with layout compatibility metadata; and
- explicit paused, disconnected, locked, permission, obscured, and unexpected-dialog
  mirror-state failures.

Run a preflight from the CLI with a JSON description of the intended driver's capabilities:

```sh
npm run cli -- dry-run open-settings.yaml \
  --capabilities mirror-capabilities.json \
  --library ./commands \
  --inputs inputs.json
```

The report always includes `"actionsExecuted": 0`. See
[docs/slice-5-library-hardening.md](./docs/slice-5-library-hardening.md).

## Launcher

The local launcher is now the easiest way to use the project. Double-click
`iPhone Commands.app`, choose a saved command such as **Open iPhone About** or
**Scroll Settings General**, and press **Run**.
It provides a local-only interface, preflights every step before acting, and shows the
verified receipt in plain language. The About routine is a live-verified multi-step command:
it opens General in Settings and then locates and opens About.

Slice 10 adds live-verified swipe support. **Scroll Settings General** resets the page's
remembered position, swipes upward, and proves the gesture by observing a lower row that was not
visible before the swipe. Saved commands still use normalized coordinates rather than Mac pixels.
See [docs/slice-10-verified-swipe.md](./docs/slice-10-verified-swipe.md).

**Capture iPhone About Top and Bottom** adds named screenshot evidence. It opens About through
Spotlight, resets the remembered scroll position, saves the top frame, scrolls until
`Certificate Trust Settings` proves the bottom is visible, and saves the bottom frame. The live
launcher stores both private PNGs under `~/Desktop/iPhone Command Captures/<receipt-id>/`; see
[docs/slice-13-about-capture.md](./docs/slice-13-about-capture.md).

The first live run needs one macOS setup step:

1. Open **System Settings → Privacy & Security → Accessibility** and allow
   **iPhone Commands**.
2. Open **Screen Recording** in the same section and allow **iPhone Commands**.
3. Keep iPhone Mirroring available, return to the launcher, and press **Run** again.

### Creating a command from the launcher

The launcher can also create a saved command from plain language, with no AI and no network
call. Type a routine, press **Check it** to see the steps and a no-action preflight, then
**Save**. The Save button stays disabled until a clean preflight, and the launcher refuses to
save anything it could not actually run.

The built-in patterns are `open <app>`, `open <app> and check for <text>`,
`press <home|app switcher|back>`, `swipe <direction>`, `wait for <text>`, and `assert <text>`.
Prefer `open <app> and check for <text>`: the mirror verifies through screen text, so naming
the text you expect gives the command something it can actually prove. See
[docs/slice-6-launcher-authoring.md](./docs/slice-6-launcher-authoring.md).

### Editing and deleting saved commands

Commands created in the launcher have an **Edit** control. An edit returns to the original plain
language, then must pass **Check changes** before **Save changes** is enabled. Deletion uses a
named confirmation dialog. Built-in commands have no management control and the service rejects
direct edit or delete requests for them. See
[docs/slice-9-saved-command-management.md](./docs/slice-9-saved-command-management.md).

The launcher still binds only to `127.0.0.1`, but this Mac can proxy it through tailnet-only
Tailscale Serve at `https://<your-mac>.<tailnet>.ts.net/`. Startup allowlists only
the exact DNS name reported by local Tailscale state and otherwise fails closed to localhost.
The per-launch mutation token remains required; no screenshot bytes are served. External actions
still require just-in-time confirmation, and financial, destructive, and credential actions
remain disabled. See [docs/launcher.md](./docs/launcher.md) and
[docs/slice-14-tailscale-launcher.md](./docs/slice-14-tailscale-launcher.md).

## Development

From the ALEXUS repository root:

```sh
npm run check --workspace @alexus/iphone-agent
```

The check begins by comparing each published `schemas/*.schema.json` file with its reviewed
formatting fingerprint. If a legitimate minimal schema edit changes the bytes, review the diff
and then run `npm run accept:schema-format --workspace @alexus/iphone-agent` to refresh the lock.
See [docs/slice-11-schema-format-guard.md](./docs/slice-11-schema-format-guard.md).

The stale-confirmation gate also has a deterministic live acceptance command:

```sh
npm run accept:confirmation-stale --workspace @alexus/iphone-agent
```

It uses the real mirror to stage a screen change after acceptance-only approval, then exits
successfully only when the unchanged runner reports `CONFIRMATION_STALE` and the confirming tap
never reaches the driver. See
[docs/slice-12-confirmation-stale-acceptance.md](./docs/slice-12-confirmation-stale-acceptance.md).

For a simulated launcher that does not touch iPhone Mirroring:

```sh
IPHONE_LAUNCHER_MODE=demo npm run launcher --workspace @alexus/iphone-agent
```

The library entry point is `src/index.ts`. The published schemas are
`schemas/command.schema.json` and `schemas/receipt.schema.json`.
